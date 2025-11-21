#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run this script as root (use sudo)." >&2
  exit 1
fi

clear

cat <<'EOF'
░  ░░░░  ░░        ░░  ░░░░  ░░        ░░  ░░░░  ░░░      ░░
▒  ▒▒▒▒  ▒▒  ▒▒▒▒▒▒▒▒  ▒▒▒▒  ▒▒▒▒▒  ▒▒▒▒▒  ▒▒▒▒  ▒▒  ▒▒▒▒  ▒
▓▓  ▓▓  ▓▓▓      ▓▓▓▓▓  ▓▓  ▓▓▓▓▓▓  ▓▓▓▓▓▓  ▓▓  ▓▓▓  ▓▓▓▓  ▓
███    ████  ██████████    ███████  ███████    ████  ████  █
████  █████        █████  █████        █████  ██████      ██

Welcome to the First Permanent Cloud Network
EOF

echo
echo "[1/7] Domain configuration"
read -rp "Enter your gateway domain (example: vevivoofficial.xyz): " DOMAIN
if [[ -z "${DOMAIN}" ]]; then
  echo "Domain cannot be empty." >&2
  exit 1
fi

echo
echo "[2/7] Wallet configuration"
read -rp "Enter your ARIO wallet address (AR_IO_WALLET): " ARIO_WALLET
if [[ -z "${ARIO_WALLET}" ]]; then
  echo "AR_IO_WALLET cannot be empty." >&2
  exit 1
fi

echo
read -rp "Enter Observer wallet address (leave empty to use ARIO wallet): " OBSADR
if [[ -z "${OBSADR}" ]]; then
  OBSADR="${ARIO_WALLET}"
  echo "Observer wallet will use ARIO wallet: ${OBSADR}"
fi

echo
echo "[3/7] AO / report configuration"
read -rp "Enter AO CU URL (press Enter for default https://cu.ardrive.io): " AO_CU_URL
if [[ -z "${AO_CU_URL}" ]]; then
  AO_CU_URL="https://cu.ardrive.io"
fi
echo "AO_CU_URL set to: ${AO_CU_URL}"

echo
echo "Choose REPORT_DATA_SINK (turbo / arweave)."
read -rp "Press Enter for default 'arweave': " REPORT_DATA_SINK
if [[ -z "${REPORT_DATA_SINK}" ]]; then
  REPORT_DATA_SINK="arweave"
fi
echo "REPORT_DATA_SINK set to: ${REPORT_DATA_SINK}"

INSTALL_DIR="/opt/ar-io-gateway"

echo
echo "[4/7] Installing base packages (this may take a while)..."
apt update -y
apt upgrade -y
apt install -y curl openssh-server git certbot nginx sqlite3 build-essential ca-certificates software-properties-common
systemctl enable ssh

echo
echo "[4b/7] Installing Docker..."
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt update -y
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

echo
echo "[4c/7] Installing Node.js (via nvm) and Yarn..."
if [[ ! -d "/root/.nvm" ]]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1090
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm install 20.11.1
nvm use 20.11.1
npm install -g yarn@1.22.22

echo
echo "[5/7] Fetching AR.IO gateway repository..."
if [[ ! -d "${INSTALL_DIR}" ]]; then
  git clone -b main https://github.com/ar-io/ar-io-node "${INSTALL_DIR}"
fi

cd "${INSTALL_DIR}"

if [[ -f ".env" ]]; then
  echo ".env already exists, it will be overwritten with new values."
fi

START_HEIGHT=1790000

echo
echo "[5a/7] Writing .env file..."
cat > .env <<EOF
GRAPHQL_HOST=arweave.net
GRAPHQL_PORT=443
START_HEIGHT=${START_HEIGHT}
RUN_OBSERVER=true
ARNS_ROOT_HOST=${DOMAIN}
AR_IO_WALLET=${ARIO_WALLET}
OBSERVER_WALLET=${OBSADR}
AO_CU_URL=${AO_CU_URL}
REPORT_DATA_SINK=${REPORT_DATA_SINK}
EOF

echo ".env content:"
cat .env

mkdir -p wallets

echo
echo "[5b/7] Saving observer wallet keyfile"
echo "Observer wallet: ${OBSADR}"
echo
echo "IMPORTANT:"
echo "  - Open your Arweave keyfile (.json) on your computer"
echo "  - Select ALL of the content and copy it"
echo "  - Paste it here exactly as it is (no changes)"
echo "  - Do NOT paste the filename, only the file content"
echo "  - After pasting:"
echo "      1) Press ENTER to go to a new empty line"
echo "      2) Press CTRL+D to finish"
echo

cat > "wallets/${OBSADR}.json"

echo
echo "Keyfile saved to: wallets/${OBSADR}.json"

echo
echo "[5c/7] Starting Docker services..."
docker compose pull
docker compose up -d

echo
echo "[6/7] Obtaining SSL certificates with Certbot (DNS challenge for wildcard)..."
systemctl stop nginx || true

certbot certonly \
  --manual \
  --preferred-challenges dns \
  -d "${DOMAIN}" \
  -d "*.${DOMAIN}"

echo
echo "Certbot finished. Now configuring Nginx..."

cat > /etc/nginx/sites-available/default <<EOF
# Force redirects from HTTP to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} *.${DOMAIN};

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# Forward traffic to your node and provide SSL certificates
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${DOMAIN} *.${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location / {
        proxy_pass http://localhost:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
    }

    location /grafana/ {
        proxy_pass http://localhost:1024/grafana/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

echo
echo "[6b/7] Testing and restarting Nginx..."
nginx -t
systemctl restart nginx

echo
echo "[6c/7] Restarting gateway stack with final configuration..."
cd "${INSTALL_DIR}"
docker compose down
docker compose up -d

echo
echo "[7/7] Installation finished."
echo
echo "You can test your gateway with:"
echo "  curl -I https://${DOMAIN}/3lyxgbgEvqNSvJrTX2J7CfRychUD5KClFhhVLyTPNCQ"
echo
echo "Useful commands:"
echo "  cd ${INSTALL_DIR}"
echo "  docker compose ps                          # Show running services"
echo "  docker compose logs core -f -n 50          # Follow core logs"
echo "  docker compose logs observer -f -n 50      # Follow observer logs"
echo "  docker compose pull && docker compose up -d # Update to latest images"
echo
echo "Certificate renew (run before expiry, DNS TXT steps required again):"
echo "  certbot certonly --manual --preferred-challenges dns -d ${DOMAIN} -d *.${DOMAIN}"
echo "  nginx -t && systemctl restart nginx"
echo "  cd ${INSTALL_DIR} && docker compose restart"
echo
echo "Welcome to the First Permanent Cloud Network."
