#!/usr/bin/env bash
set -euo pipefail

# Renkler
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/opt/ar-io-gateway"

# Root kontrolü
if [[ "$(id -u)" -ne 0 ]]; then
  echo -e "${RED}Lütfen bu scripti root olarak çalıştırın (sudo -i).${NC}" >&2
  exit 1
fi

echo -e "${YELLOW}Helper Tools (Yardımcı Komutlar) Güncelleniyor...${NC}"

# .env dosyasından domaini çek
if [ -f "${INSTALL_DIR}/.env" ]; then
    source "${INSTALL_DIR}/.env"
    DOMAIN="$ARNS_ROOT_HOST"
    echo -e "Domain tespit edildi: ${CYAN}${DOMAIN}${NC}"
else
    echo -e "${RED}Hata: .env dosyası bulunamadı. Gateway kurulu mu?${NC}"
    exit 1
fi

# Eski e-postayı kurtarmaya çalış (SSL yenileme komutu için)
EXISTING_EMAIL=""
if [ -f "/usr/local/bin/gateway-renew-cert" ]; then
    # Dosyanın içinden e-posta adresini çekmeye çalışır
    EXISTING_EMAIL=$(grep -oP '(?<=-m ")[^"]*' /usr/local/bin/gateway-renew-cert || echo "")
fi

# Eğer e-posta bulunamazsa boş geçilir (Certbot kayıtlı hesabı kullanır)
if [[ -z "$EXISTING_EMAIL" ]]; then
    EMAIL_FLAG=""
else
    EMAIL_FLAG="-m \"$EXISTING_EMAIL\""
fi

# ---------------------------------------------------------
# YENİ KOMUTLAR YAZILIYOR
# ---------------------------------------------------------

# 1. UPDATE (Senin İstediğin Özel Ayar: Checkout Main + Build + Veri Koruma)
cat >/usr/local/bin/gateway-update <<EOF
#!/usr/bin/env bash
echo -e "${YELLOW}Updating AR.IO Gateway...${NC}"
cd ${INSTALL_DIR} || exit 1

# 1. Durdur (Veri kaybetmeden -v YOK)
docker compose down

# 2. Repo'yu güncelle (Main branch garantisi)
git checkout main
git pull

# 3. Yeniden başlat ve Build et
docker compose up -d --build

echo -e "${GREEN}Update complete!${NC}"
EOF

# 2. RESTART
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

# 5. RENEW SSL (Eski e-posta ile veya e-postasız)
cat >/usr/local/bin/gateway-renew-cert <<EOF
#!/usr/bin/env bash
echo -e "${YELLOW}Renewing SSL Certificate...${NC}"
systemctl stop nginx || true
certbot certonly --manual --preferred-challenges dns --agree-tos --no-eff-email ${EMAIL_FLAG} -d ${DOMAIN} -d *.${DOMAIN}
nginx -t && systemctl restart nginx
cd ${INSTALL_DIR} || exit 1
docker compose up -d --force-recreate
echo -e "${GREEN}SSL Renewed.${NC}"
EOF

# 6. HEALTH CHECK (V12 - Link Version)
cat >/usr/local/bin/gateway-check <<EOF
#!/usr/bin/env bash
if [ -f "${INSTALL_DIR}/.env" ]; then
    source "${INSTALL_DIR}/.env"
    DOMAIN="\$ARNS_ROOT_HOST"
else
    echo "Error: .env file not found."
    exit 1
fi

echo -e "${YELLOW}Waiting 10 seconds before checking health...${NC}"
for i in {10..1}; do echo -n "\$i... " && sleep 1; done
echo
echo

echo -e "${CYAN}>>> 1. Transaction Data Test:${NC}"
echo "Please open the link below in your browser."
echo "If you see '1984', your gateway is working perfectly!"
echo
echo -e "${GREEN}https://\$DOMAIN/3lyxgbgEvqNSvJrTX2J7CfRychUD5KClFhhVLyTPNCQ${NC}"
echo

echo -e "${CYAN}>>> 2. Checking Health (/ar-io/healthcheck):${NC}"
curl -s --max-time 20 "https://\$DOMAIN/ar-io/healthcheck" | jq . || echo -e "${RED}Core Service not ready yet (Timeout/Error)${NC}"
echo

echo -e "${CYAN}>>> 3. Checking Node Info (/ar-io/info):${NC}"
curl -s --max-time 20 "https://\$DOMAIN/ar-io/info" | jq . || echo -e "${RED}Core Service not ready yet (Timeout/Error)${NC}"
echo

echo -e "${CYAN}>>> 4. Checking Observer (/ar-io/observer/info):${NC}"
curl -s --max-time 20 "https://\$DOMAIN/ar-io/observer/info" | jq . || echo -e "${RED}Observer not ready yet${NC}"
echo
EOF

# İzinleri ver
chmod +x /usr/local/bin/gateway-update
chmod +x /usr/local/bin/gateway-restart
chmod +x /usr/local/bin/gateway-logs
chmod +x /usr/local/bin/gateway-status
chmod +x /usr/local/bin/gateway-renew-cert
chmod +x /usr/local/bin/gateway-check

echo
echo -e "${GREEN}Tüm komutlar başarıyla güncellendi!${NC}"
echo "Artık 'gateway-update' komutunu güvenle kullanabilirsiniz."
