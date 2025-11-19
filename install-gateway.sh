#!/usr/bin/env bash
set -e

clear

cat << "BANNER"
░  ░░░░  ░░        ░░  ░░░░  ░░        ░░  ░░░░  ░░░      ░░
▒  ▒▒▒▒  ▒▒  ▒▒▒▒▒▒▒▒  ▒▒▒▒  ▒▒▒▒▒  ▒▒▒▒▒  ▒▒▒▒  ▒▒  ▒▒▒▒  ▒
▓▓  ▓▓  ▓▓▓      ▓▓▓▓▓  ▓▓  ▓▓▓▓▓▓  ▓▓▓▓▓▓  ▓▓  ▓▓▓  ▓▓▓▓  ▓
███    ████  ██████████    ███████  ███████    ████  ████  █
████  █████        █████  █████        █████  ██████      ██

                 powered by ar.io
BANNER

echo
echo "AR.IO Gateway full installation starting..."

if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (use: sudo su)"
  exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
  echo "This script is designed for Ubuntu/Debian systems."
  exit 1
fi

echo
echo "[1/8] Installing required packages..."
apt update -y
apt install -y curl git nginx certbot sqlite3 build-essential ca-certificates

echo
echo "[2/8] Installing Docker..."
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.asc ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker

echo
echo "[3/8] Installing NVM, Node.js 20 and Yarn..."
if [ ! -d "$HOME/.nvm" ]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

nvm install 20
nvm use 20

npm install -g yarn@1.22.22

echo
echo "[4/8] Cloning AR.IO node..."
mkdir -p /opt/ar-io-gateway
cd /opt/ar-io-gateway

if [ ! -d ".git" ]; then
  git clone -b main https://github.com/ar-io/ar-io-node .
fi

mkdir -p wallets

echo
echo "[5/8] Creating .env configuration"

read -p "Domain (e.g. vevivofficial.store): " DOMAIN
read -p "ARIO wallet address: " ARIOWALLET
read -p "Observer wallet address (leave empty to use ARIO wallet): " OBSADR

if [ -z "$OBSADR" ]; then
  OBSADR="$ARIOWALLET"
fi

read -p "AO CU URL (leave empty for https://cu.ardrive.io): " AO_CU_URL
if [ -z "$AO_CU_URL" ]; then
  AO_CU_URL="https://cu.ardrive.io"
fi

read -p "Report data sink (turbo/arweave, leave empty for arweave): " REPORT_SINK
if [ -z "$REPORT_SINK" ]; then
  REPORT_SINK="arweave"
fi

RUNOBS="true"

cat > .env << EOF2
GRAPHQL_HOST=arweave.net
GRAPHQL_PORT=443
START_HEIGHT=1790000
RUN_OBSERVER=${RUNOBS}
ARNS_ROOT_HOST=${DOMAIN}
AR_IO_WALLET=${ARIOWALLET}
OBSERVER_WALLET=${OBSADR}
AO_CU_URL=${AO_CU_URL}
REPORT_DATA_SINK=${REPORT_SINK}
EOF2

echo
echo ".env created:"
cat .env

echo
echo "[5b/8] Saving observer wallet key file"
echo "Observer wallet selected: ${OBSADR}"
echo
echo "Now provide the JSON keyfile for this wallet."
echo "It will be saved as:"
echo "  /opt/ar-io-gateway/wallets/${OBSADR}.json"
echo
echo "IMPORTANT:"
echo "  - Open your Arweave keyfile (.json) locally"
echo "  - COPY THE FULL CONTENT exactly as-is"
echo "  - Must include the opening '{' and closing '}'"
echo "  - Do NOT paste a filename, paste ONLY the JSON object"
echo
echo "Paste your REAL keyfile JSON below, then:"
echo "  - Press ENTER to go to a new empty line"
echo "  - Press CTRL+D on an empty line to finish"

cat > "wallets/${OBSADR}.json"

echo
echo "Wallet key saved to: wallets/${OBSADR}.json"

echo
echo "[6/8] Starting AR.IO gateway with Docker Compose..."
docker compose up -d

echo
echo "Wildcard SSL certificate will be requested for:"
echo "  ${DOMAIN}"
echo "  *.${DOMAIN}"
echo
echo "When Certbot shows TXT records:"
echo "  1) Go to DNS panel"
echo "  2) Add TXT record:"
echo "       Host : _acme-challenge"
echo "       Value: <Certbot value>"
echo "  3) Save changes"
echo "  4) Wait 30–60 seconds"
echo "  5) Press Enter here"

systemctl stop nginx || true

certbot certonly --manual --preferred-challenges dns \
  -d "${DOMAIN}" -d "*.${DOMAIN}" \
  --agree-tos --register-unsafely-without-email

echo
echo "[7/8] Configuring Nginx..."
cat > /etc/nginx/sites-available/default << EOF3
server {
    listen 80;
    server_name ${DOMAIN} *.${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${DOMAIN} *.${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location / {
        proxy_pass http://localhost:4000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF3

nginx -t
systemctl restart nginx

echo
echo "[8/8] Restarting AR.IO gateway..."
cd /opt/ar-io-gateway
docker compose down
docker compose up -d

echo
echo "Creating helper commands..."

cat > /usr/local/bin/gateway-update << 'EOFU'
#!/usr/bin/env bash
cd /opt/ar-io-gateway
git pull
docker compose pull
docker compose up -d
EOFU

cat > /usr/local/bin/gateway-restart << 'EOFR'
#!/usr/bin/env bash
cd /opt/ar-io-gateway
docker compose down
docker compose up -d
EOFR

cat > /usr/local/bin/gateway-logs << 'EOFL'
#!/usr/bin/env bash
cd /opt/ar-io-gateway
docker compose logs core observer -f --tail=50
EOFL

cat > /usr/local/bin/gateway-renew-cert << 'EOFC'
#!/usr/bin/env bash
set -e

if [ ! -f /opt/ar-io-gateway/.env ]; then
  echo ".env not found at /opt/ar-io-gateway/.env"
  exit 1
fi

DOMAIN=$(grep '^ARNS_ROOT_HOST=' /opt/ar-io-gateway/.env | cut -d'=' -f2)

if [ -z "$DOMAIN" ]; then
  echo "ARNS_ROOT_HOST not set in .env"
  exit 1
fi

echo
echo "Renewing SSL certificate for:"
echo "  $DOMAIN"
echo "  *.$DOMAIN"
echo
echo "Certbot will ask you to create DNS TXT records for _acme-challenge."
echo "Update your DNS records as instructed, then press Enter when ready."
echo

systemctl stop nginx || true

certbot certonly --manual --preferred-challenges dns \
  -d "$DOMAIN" -d "*.$DOMAIN" \
  --agree-tos --register-unsafely-without-email

nginx -t
systemctl restart nginx

cd /opt/ar-io-gateway
docker compose down
docker compose up -d
EOFC

chmod +x /usr/local/bin/gateway-update
chmod +x /usr/local/bin/gateway-restart
chmod +x /usr/local/bin/gateway-logs
chmod +x /usr/local/bin/gateway-renew-cert

echo
echo "Welcome to the First Permanent Cloud Network."
echo
echo "Test link:"
echo "  https://${DOMAIN}/3lyxgbgEvqNSvJrTX2J7CfRychUD5KClFhhVLyTPNCQ"
echo
echo "Useful commands:"
echo "  gateway-update      → Update to latest version"
echo "  gateway-restart     → Restart AR.IO gateway"
echo "  gateway-logs        → View core + observer logs"
echo "  gateway-renew-cert  → Renew SSL certificate (manual DNS, then restart)"
