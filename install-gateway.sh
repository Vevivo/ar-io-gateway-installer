#!/usr/bin/env bash
set -euo pipefail

# Renk Tanımlamaları
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

if [[ "$(id -u)" -ne 0 ]]; then
  echo -e "${RED}Please run this script as root (use sudo).${NC}" >&2
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
        --- AR.IO Gateway Installer by Vevivo ---
EOF

echo
echo -e "${CYAN}This installer will set up an AR.IO gateway with:${NC}"
echo "  - Docker services (core, envoy, observer, redis, autoheal)"
echo "  - Let's Encrypt SSL via Certbot (wildcard, DNS challenge)"
echo "  - Nginx reverse proxy"
echo "  - Helper commands for easy management"
echo

INSTALL_DIR="/opt/ar-io-gateway"
TMP_KEYFILE="/root/.observer-keyfile.tmp"

###############################################################################
# [1/7] BASIC CONFIGURATION
###############################################################################
echo -e "${YELLOW}[1/7] Basic configuration${NC}"

read -rp "Enter your gateway domain (example: vevivoofficial.xyz): " DOMAIN
if [[ -z "${DOMAIN}" ]]; then
  echo -e "${RED}Domain cannot be empty.${NC}" >&2
  exit 1
fi

read -rp "Enter your ARIO wallet address (AR_IO_WALLET): " ARIO_WALLET
if [[ -z "${ARIO_WALLET}" ]]; then
  echo -e "${RED}AR_IO_WALLET cannot be empty.${NC}" >&2
  exit 1
fi

echo
read -rp "Enter Observer wallet address (press Enter to use AR_IO_WALLET): " OBSADR
if [[ -z "${OBSADR}" ]]; then
  OBSADR="${ARIO_WALLET}"
  echo -e "${GREEN}Observer wallet set to AR_IO_WALLET.${NC}"
fi

echo
read -rp "Enter AO CU URL (press Enter for default https://cu.ardrive.io): " AO_CU_URL
if [[ -z "${AO_CU_URL}" ]]; then
  AO_CU_URL="https://cu.ardrive.io"
fi

echo
echo "Choose REPORT_DATA_SINK (turbo / arweave)."
read -rp "Press Enter for default 'arweave': " REPORT_DATA_SINK
if [[ -z "${REPORT_DATA_SINK}" ]]; then
  REPORT_DATA_SINK="arweave"
fi

echo
read -rp "Enter email address for Certbot (Let's Encrypt notifications): " CERTBOT_EMAIL
if [[ -z "${CERTBOT_EMAIL}" ]]; then
  echo -e "${RED}Email cannot be empty for Certbot registration.${NC}" >&2
  exit 1
fi

echo
echo -e "${YELLOW}[1b/7] Observer wallet keyfile${NC}"
echo "Observer wallet: ${OBSADR}"
echo
echo -e "${CYAN}IMPORTANT:${NC}"
echo "  1) Open your Arweave keyfile (.json) on your computer."
echo "  2) Copy ALL content inside the file."
echo "  3) Paste it below."
echo "  4) Press ENTER after pasting."
echo "  5) Press CTRL+D to save and continue."
echo

# Keyfile input
cat > "${TMP_KEYFILE}"

echo
echo -e "${GREEN}Keyfile temporarily saved.${NC}"

START_HEIGHT=1790000

###############################################################################
# [2/7] SYSTEM PACKAGES, DOCKER, NODE, JQ
###############################################################################
echo
echo -e "${YELLOW}[2/7] Installing base packages (including jq)...${NC}"

# APT Listelerini temizle (404 hatasını önlemek için kritik adım)
echo "Cleaning apt lists to fix potential 404 errors..."
rm -rf /var/lib/apt/lists/*
apt-get clean
apt-get update -y

apt upgrade -y
# 'jq' paketini ekledim, JSON çıktılarını okunaklı görmek için
apt install -y curl openssh-server git certbot nginx sqlite3 build-essential ca-certificates software-properties-common jq
systemctl enable ssh

echo
echo -e "${YELLOW}[2b/7] Checking Docker...${NC}"
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing Docker..."
  
  # Önceki hatalı kurulumları temizlemeye çalış
  dpkg --configure -a || true
  
  # Resmi script ile kurulum
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
  rm get-docker.sh
  
  echo "Docker installed successfully."
else
  echo "Docker is already installed."
fi

echo
echo -e "${YELLOW}[2c/7] Installing Node.js & Yarn...${NC}"
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
echo -e "${YELLOW}[3/7] Fetching AR.IO gateway repository...${NC}"
if [[ ! -d "${INSTALL_DIR}" ]]; then
  git clone -b main https://github.com/ar-io/ar-io-node "${INSTALL_DIR}"
else
  echo "Directory exists, pulling latest changes..."
  cd "${INSTALL_DIR}" && git pull
fi

cd "${INSTALL_DIR}"

###############################################################################
# [4/7] .ENV CREATION
###############################################################################
echo
echo -e "${YELLOW}[4/7] Writing .env file...${NC}"
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

###############################################################################
# [5/7] MOVE OBSERVER KEYFILE
###############################################################################
echo
echo -e "${YELLOW}[5/7] Configuring wallets...${NC}"
mkdir -p wallets

if [[ -f "${TMP_KEYFILE}" ]]; then
  mv "${TMP_KEYFILE}" "wallets/${OBSADR}.json"
  echo -e "${GREEN}Observer keyfile set: wallets/${OBSADR}.json${NC}"
else
  echo -e "${RED}WARNING: Keyfile not found.${NC}" >&2
fi

###############################################################################
# [6/7] DOCKER SERVICES
###############################################################################
echo
echo -e "${YELLOW}[6/7] Starting Docker services...${NC}"
docker compose pull
docker compose up -d

###############################################################################
# [7/7] CERTBOT + NGINX
###############################################################################
echo
echo -e "${YELLOW}[7/7] SSL Setup (Certbot)...${NC}"
echo
echo -e "${CYAN}--- ATTENTION ---${NC}"
echo "Certbot will ask you to create DNS TXT records."
echo "1. Go to your DNS Provider (e.g., Namecheap)."
echo "2. Add the TXT record shown."
echo "3. WAIT 1 minute before pressing Enter."
echo

systemctl stop nginx || true

certbot certonly \
  --manual \
  --preferred-challenges dns \
  --agree-tos \
  --no-eff-email \
  -m "${CERTBOT_EMAIL}" \
  -d "${DOMAIN}" \
  -d "*.${DOMAIN}"

echo
echo -e "${GREEN}Certbot finished. Configuring Nginx...${NC}"

cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} *.${DOMAIN};
    location / {
        return 301 https://\$host\$request_uri;
    }
}

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
        proxy_set_header X-AR-IO-Origin \$http_x_ar_io_origin;
        proxy_set_header X-AR-IO-Origin-Node-Release \$http_x_ar_io_origin_node_release;
        proxy_set_header X-AR-IO-Hops \$http_x_ar_io_hops;
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

echo "Restarting Nginx..."
nginx -t && systemctl restart nginx

echo "Finalizing gateway stack..."
cd "${INSTALL_DIR}"
docker compose down
docker compose up -d

###############################################################################
# HELPER COMMANDS
###############################################################################
echo
echo -e "${YELLOW}Creating helper commands...${NC}"

# 1. UPDATE
cat >/usr/local/bin/gateway-update <<EOF
#!/usr/bin/env bash
echo -e "${YELLOW}Updating AR.IO Gateway...${NC}"
cd ${INSTALL_DIR} || exit 1
git pull
docker compose pull
docker compose up -d --remove-orphans
echo -e "${GREEN}Update complete!${NC}"
EOF

# 2. RESTART (FULL STOP & START)
cat >/usr/local/bin/gateway-restart <<EOF
#!/usr/bin/env bash
echo -e "${YELLOW}Stopping all services...${NC}"
cd ${INSTALL_DIR} || exit 1
docker compose down
echo -e "${YELLOW}Starting all services...${NC}"
docker compose up -d
echo -e "${GREEN}Gateway has been fully restarted!${NC}"
EOF

# 3. LOGS
cat >/usr/local/bin/gateway-logs <<EOF
#!/usr/bin/env bash
cd ${INSTALL_DIR} || exit 1
docker compose logs -f --tail=100 core observer
EOF

# 4. STATUS
cat >/usr/local/bin/gateway-status <<EOF
#!/usr/bin/env bash
cd ${INSTALL_DIR} || exit 1
echo -e "${CYAN}=== Docker Status ===${NC}"
docker compose ps
echo
echo -e "${CYAN}=== Resources ===${NC}"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"
EOF

# 5. RENEW SSL
cat >/usr/local/bin/gateway-renew-cert <<EOF
#!/usr/bin/env bash
echo -e "${YELLOW}Renewing SSL Certificate...${NC}"
systemctl stop nginx || true
certbot certonly --manual --preferred-challenges dns --agree-tos --no-eff-email -m "${CERTBOT_EMAIL}" -d ${DOMAIN} -d *.${DOMAIN}
nginx -t && systemctl restart nginx
cd ${INSTALL_DIR} || exit 1
docker compose up -d --force-recreate
echo -e "${GREEN}SSL Renewed.${NC}"
EOF

# 6. HEALTH CHECK
cat >/usr/local/bin/gateway-check <<EOF
#!/usr/bin/env bash
# .env dosyasından domaini otomatik çeker
if [ -f "${INSTALL_DIR}/.env" ]; then
    source "${INSTALL_DIR}/.env"
    DOMAIN="\$ARNS_ROOT_HOST"
else
    echo "Error: .env file not found."
    exit 1
fi

echo -e "${YELLOW}Testing API Endpoints for: https://\$DOMAIN${NC}"
echo

echo -e "${CYAN}>>> Checking Health (/ar-io/healthcheck):${NC}"
# jq kullanarak çıktıyı renklendirir
curl -s "https://\$DOMAIN/ar-io/healthcheck" | jq . || echo "Raw output: \$(curl -s "https://\$DOMAIN/ar-io/healthcheck")"
echo

echo -e "${CYAN}>>> Checking Node Info (/ar-io/info):${NC}"
curl -s "https://\$DOMAIN/ar-io/info" | jq . || echo "Raw output: \$(curl -s "https://\$DOMAIN/ar-io/info")"
echo

echo -e "${CYAN}>>> Checking Observer (/ar-io/observer/info):${NC}"
curl -s "https://\$DOMAIN/ar-io/observer/info" | jq . || echo "Raw output: \$(curl -s "https://\$DOMAIN/ar-io/observer/info")"
echo
EOF

chmod +x /usr/local/bin/gateway-update
chmod +x /usr/local/bin/gateway-restart
chmod +x /usr/local/bin/gateway-logs
chmod +x /usr/local/bin/gateway-status
chmod +x /usr/local/bin/gateway-renew-cert
chmod +x /usr/local/bin/gateway-check

echo
echo -e "${GREEN}Installation finished successfully!${NC}"
echo -e "${YELLOW}Waiting 20 seconds for Gateway to initialize before health check...${NC}"
sleep 20

# Kurulum sonunda otomatik test
/usr/local/bin/gateway-check

echo
echo "------------------------------------------------------------------"
echo "Gateway URL     : https://${DOMAIN}"
echo "------------------------------------------------------------------"
echo -e "${CYAN}COMMAND LIST:${NC}"
echo "  gateway-update   : Update node safely"
echo "  gateway-restart  : Full Stop & Start"
echo "  gateway-check    : Check Health & API Info"
echo "  gateway-status   : Check Docker resources"
echo "  gateway-logs     : View live logs"
echo "------------------------------------------------------------------"
echo "Welcome to the AR.IO Network."
