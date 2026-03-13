#!/bin/bash
# ==============================================================================
#   ASN MONITOR PRO - INSTALADOR v9.2 (PRODUCTION READY)
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

MIRROR_URL="http://179.42.68.135:8080/asn_monitor_PRO_v1.zip"
INSTALL_DIR="/opt/asn-monitor"

clear
echo -e "${BLUE}==========================================================${NC}"
echo -e "${GREEN}          INSTALADOR AUTOMÁTICO ASN MONITOR PRO           ${NC}"
echo -e "${BLUE}==========================================================${NC}"

# --- 1. REPARO DE REDE E PORTAS ---
echo "nameserver 8.8.8.8" > /etc/resolv.conf
systemctl stop nginx 2>/dev/null
fuser -k 80/tcp 443/tcp 2>/dev/null

# --- 2. COLETA DE DADOS ---
read -p "   Domínio de Acesso: " DOMAIN
read -p "   ASN: " ASN
read -p "   Bloco IP: " SUBNET
read -p "   Email SSL: " EMAIL
read -p "   User Docker Hub: " DUSER
read -s -p "   Token Docker Hub: " DPASS
echo -e "\n"

# Exportamos para que o envsubst lá na frente funcione
export CLIENT_DOMAIN="$DOMAIN"

# --- 3. DOCKER ENGINE ---
echo -e "${BLUE}[*] Preparando Docker...${NC}"
curl -fsSL https://get.docker.com | sh
apt-get install -y docker-compose-plugin gettext-base certbot unzip -qq
echo "$DPASS" | docker login -u "$DUSER" --password-stdin

# --- 4. PACOTE E EXTRAÇÃO ---
rm -rf "$INSTALL_DIR" && mkdir -p "$INSTALL_DIR"
wget -q --show-progress "$MIRROR_URL" -O /tmp/asn_package.zip
unzip -qo /tmp/asn_package.zip -d /tmp/asn_extract
if [ -d "/tmp/asn_extract/dist_package" ]; then
    cp -r /tmp/asn_extract/dist_package/* "$INSTALL_DIR/"
else
    cp -r /tmp/asn_extract/* "$INSTALL_DIR/"
fi
cd "$INSTALL_DIR"

# --- 5. AJUSTES DINÂMICOS NO TEMPLATE E COMPOSE ---
echo -e "${BLUE}[*] Ajustando configurações internas...${NC}"
sed -i "s/seu-usuario/$DUSER/g" docker-compose.yml
sed -i "s/-Xms4g -Xmx4g/-Xms2g -Xmx2g/g" docker-compose.yml

# Corrige os nomes dos containers no Nginx (Universal)
sed -i "s/asn-app/asn-reputation/g" nginx/default.conf.template
sed -i "s/asn-reputation:5001/asn-forensics:5001/g" nginx/default.conf.template

# --- 6. ENV E SSL ---
cat <<EOF > .env
TARGET_ASN=$ASN
TARGET_SUBNET=$SUBNET
CLIENT_DOMAIN=$DOMAIN
INTERNAL_DNS=172.18.0.53
ELASTIC_PASSWORD=9R=OOq0t-amCgsVVH=PV
SECRET_KEY=$(openssl rand -hex 24)
DEFAULT_PASS=Mudar@123
EOF

echo -e "${BLUE}[*] Obtendo certificado SSL...${NC}"
certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --expand

# O envsubst agora substitui ${CLIENT_DOMAIN} corretamente
envsubst '${CLIENT_DOMAIN}' < nginx/default.conf.template > nginx/default.conf

# --- 7. DEPLOY ---
mkdir -p data/{sqlite,es_data} && chmod -R 777 data/
chown -R 472:472 grafana/ dashboards/ 2>/dev/null
docker compose pull -q
docker compose up -d

# --- 8. FINALIZAÇÃO ---
echo -e "${BLUE}[*] Aguardando Elasticsearch responder...${NC}"
for i in {1..50}; do
    if curl -s -u elastic:9R=OOq0t-amCgsVVH=PV http://localhost:9200 > /dev/null; then
        echo -e "${GREEN} OK!${NC}"
        # Inicializa o banco de dados
        docker exec -it asn-reputation python3 -c "import sys; sys.path.append('/app/reputation'); from core.database import init_db; init_db()"
        # Injeta templates forenses
        curl -s -u elastic:9R=OOq0t-amCgsVVH=PV -X PUT "http://localhost:9200/_ilm/policy/forensics_policy" -H 'Content-Type: application/json' --data-binary @elastic_setup/ilm_policies.json > /dev/null
        curl -s -u elastic:9R=OOq0t-amCgsVVH=PV -X PUT "http://localhost:9200/_index_template/forensics_template" -H 'Content-Type: application/json' --data-binary @index_templates.json > /dev/null
        break
    fi
    echo -ne "."
    sleep 4
done

echo -e "\n${GREEN}==========================================================${NC}"
echo -e "${GREEN}   INSTALAÇÃO CONCLUÍDA: https://$DOMAIN${NC}"
echo -e "=========================================================="
