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

                    Powered by AR.IO
EOF

echo
echo "This installer will set up an AR.IO gateway with:"
echo "  - Docker services (core, envoy, observer, redis, autoheal)"
echo "  - Let's Encrypt SSL via Certbot (wildcard, DNS challenge)"
echo "  - Nginx reverse proxy"
echo "  - Observer enabled by default"
echo

INSTALL_DIR="/opt/ar-io-gateway"
TMP_KEYFILE="/root/.observer-keyfile.tmp"

###############################################################################
# [1/7] BASIC CONFIGURATION (all questions here, one time)
###############################################################################
echo "[1/7] Basic configuration"

read -rp "Enter your gateway domain (example: vevivoofficial.xyz): " DOMAIN
if [[ -z "${DOMAIN}" ]]; then
  echo "Domain cannot be empty." >&2
  exit 1
fi

read -rp "Enter your ARIO wallet address (AR_IO_WALLET): " ARIO_WALLET
if [[ -z "${ARIO_WALLET}" ]]; then
  echo "AR_IO_WALLET cannot be empty." >&2
  exit 1
fi

echo
read -rp "Enter Observer wallet address (press Enter to use AR_IO_WALLET): " OBSADR
if [[ -z "${OBSADR}" ]]; then
  OBSADR="${ARIO_WALLET}"
  echo "Observer wallet will use AR_IO_WALLET: ${OBSADR}"
fi

echo
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

echo
echo "[1b/7] Observer wallet keyfile"
echo "Observer wallet: ${OBSADR}"
echo
echo "IMPORTANT:"
echo "  - Open your Arweave keyfile (.json) on your computer."
echo "  - Select ALL of the content and copy it."
echo "  - Paste it here exactly as it is (no changes)."
echo "  - Do NOT paste the filename, only the file content."
echo "  - After pasting:"
echo "      1) Press ENTER to go to a new empty line."
echo "      2) Press CTRL+D to finish."
echo

# Keyfile'ı geçici bir yerde tutuyoruz, repo klonlandıktan sonra wallets/ içine taşıyacağız
cat > "${TMP_KEYFILE}"

echo
echo "Keyfile temporarily saved to: ${TMP_KEYFILE}"
echo "Setup will continue without asking again."

START_HEIGHT=1790000

###############################################################################
# [2/7] SYSTEM PACKAGES, DOCKER, NODE
###############################################################################
echo
echo "[2/7] Installing base packages (apt, nginx, certbot, etc)..."
apt update -y
apt upgrade -y
apt install -y curl openssh-server git certbot nginx sqlite3 build-essential ca-certificates software-properties-common
systemctl enable ssh

echo
echo "[2b/7] Installing Docker..."
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
echo "[2c/7] Installing Node.js (via nvm) and Yarn..."
if [[ ! -d "/root/.nvm" ]]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1090
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm install 20.11.1
nvm use 20.11.1
npm install -g yarn@1.22.22

###############################################################################
# [3/7] CLONE AR.IO NODE
###############################################################################
echo
echo "[3/7] Fetching AR.IO gateway repository..."
if [[ ! -d "${INSTALL_DIR}" ]]; then
  git clone -b main https://github.com/ar-io/ar-io-node "${INSTALL_DIR}"
fi

cd "${INSTALL_DIR}"

###############################################################################
# [4/7] .ENV CREATION
###############################################################################
echo
echo "[4/7] Writing .env file..."
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

echo
echo ".env created with:"
cat .env

###############################################################################
# [5/7] MOVE OBSERVER KEYFILE INTO wallets/
###############################################################################
echo
echo "[5/7] Moving observer keyfile into wallets/ directory..."
mkdir -p wallets

if [[ -f "${TMP_KEYFILE}" ]]; then
  mv "${TMP_KEYFILE}" "wallets/${OBSADR}.json"
  echo "Observer keyfile moved to: wallets/${OBSADR}.json"
else
  echo "WARNING: Temporary keyfile ${TMP_KEYFILE} not found. Observer may fail to upload reports." >&2
fi

###############################################################################
# [6/7] DOCKER SERVICES
###############################################################################
echo
echo "[6/7] Starting Docker services (core, envoy, observer, redis, autoheal)..."
docker compose pull
docker compose up -d

echo
echo "Docker services started. You can check with:"
echo "  cd ${INSTALL_DIR}"
echo "  docker compose ps"
echo

###############################################################################
# [7/7] CERTBOT + NGINX
###############################################################################
echo
echo "[7/7] Obtaining SSL certificates with Certbot (DNS challenge for wildcard)..."
echo
echo "Certbot will now ask you to create DNS TXT records."
echo "When you see something like:"
echo "  _acme-challenge.${DOMAIN}"
echo "with a random value:"
echo "  snbD0McCsC... (example)"
echo
echo "Steps:"
echo "  1) Go to your DNS provider (for example: Namecheap)."
echo "  2) Add a TXT record:"
echo "       Host  : _acme-challenge"
echo "       Value : <the value shown by Certbot>"
echo "  3) Wait 30–60 seconds for DNS to propagate."
echo "  4) Then press ENTER in this terminal when Certbot asks."
echo
echo "If Certbot asks for a SECOND TXT record, add it the same way"
echo "and do NOT delete the first one until Certbot finishes."
echo

systemctl stop nginx || true

certbot certonly \
  --manual \
  --preferred-challenges dns \
  -d "${DOMAIN}" \
  -d "*.${DOMAIN}"

echo
echo "Certbot finished. Now configuring Nginx with your domain and certificates..."

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
echo "Testing Nginx configuration..."
nginx -t
echo "Restarting Nginx..."
systemctl restart nginx

echo
echo "Restarting gateway stack with final configuration..."
cd "${INSTALL_DIR}"
docker compose down
docker compose up -d

###############################################################################
# Helper command shortcuts
###############################################################################
echo
echo "Creating helper commands under /usr/local/bin ..."

cat >/usr/local/bin/gateway-update <<EOF
#!/usr/bin/env bash
cd ${INSTALL_DIR} || exit 1
docker compose pull
docker compose up -d
EOF

cat >/usr/local/bin/gateway-restart <<EOF
#!/usr/bin/env bash
cd ${INSTALL_DIR} || exit 1
docker compose restart
EOF

cat >/usr/local/bin/gateway-logs <<EOF
#!/usr/bin/env bash
cd ${INSTALL_DIR} || exit 1
docker compose logs core observer -f
EOF

cat >/usr/local/bin/gateway-renew-cert <<EOF
#!/usr/bin/env bash
echo "Starting manual certificate renewal for ${DOMAIN} ..."
echo
echo "Certbot will again ask you to create DNS TXT records:"
echo "  Host : _acme-challenge"
echo "  Value: <token provided by Certbot>"
echo
systemctl stop nginx || true
certbot certonly --manual --preferred-challenges dns -d ${DOMAIN} -d *.${DOMAIN}
nginx -t && systemctl restart nginx
cd ${INSTALL_DIR} || exit 1
docker compose restart
EOF

chmod +x /usr/local/bin/gateway-update
chmod +x /usr/local/bin/gateway-restart
chmod +x /usr/local/bin/gateway-logs
chmod +x /usr/local/bin/gateway-renew-cert

echo
echo "Installation finished."
echo
echo "You can test your gateway with:"
echo "  curl -I https://${DOMAIN}/3lyxgbgEvqNSvJrTX2J7CfRychUD5KClFhhVLyTPNCQ"
echo
echo "Useful commands:"
echo "  gateway-update      → Update to latest version"
echo "  gateway-restart     → Restart AR.IO gateway"
echo "  gateway-logs        → View core + observer logs"
echo "  gateway-renew-cert  → Renew SSL certificate (manual DNS, then restart)"
echo
echo "Welcome to the First Permanent Cloud Network."
