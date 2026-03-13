#!/bin/bash
# ==============================================================================
#   ASN MONITOR PRO - INSTALADOR v3.4 (REPAIR & CLEAN EDITION)
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

LOCAL_ZIP="/opt/asn-host/asn_monitor_PRO_v1.zip"
DOWNLOAD_URL="http://127.0.0.1:8080/asn_monitor_PRO_v1.zip"

clear
echo -e "${BLUE}==========================================================${NC}"
echo -e "${GREEN}          INSTALADOR AUTOMÁTICO ASN MONITOR PRO           ${NC}"
echo -e "${BLUE}==========================================================${NC}"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[!] Erro: Execute como root.${NC}"
   exit 1
fi

# 1. COLETA DE DADOS
read -p "   Domínio de Acesso (ex: monitor.provedor.com.br): " DOMAIN
read -p "   Número do ASN: " ASN
read -p "   Bloco de IP: " SUBNET
read -p "   Email para SSL: " EMAIL
echo -e ""
read -p "   Usuário Docker Hub (ID): " DUSER
read -s -p "   Personal Access Token: " DPASS
echo -e ""

# 2. INSTALAÇÃO DO DOCKER (MÉTODO OFICIAL - SEM ERRO DE DEPENDÊNCIA)
echo -e "${BLUE}[*] Instalando Docker Engine e Compose V2...${NC}"
apt-get remove docker docker-engine docker.io containerd runc -y 2>/dev/null
apt-get update -qq
apt-get install -y ca-certificates curl gnupg lsb-release gettext-base certbot unzip -qq

mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin -qq
systemctl enable docker --now

# 3. LOGIN DOCKER HUB
echo "$DPASS" | docker login -u "$DUSER" --password-stdin

# 4. PREPARAÇÃO E LIMPEZA
echo -e "${BLUE}[*] Limpando instalações anteriores...${NC}"
# Remove pastas de configuração mas PRESERVA a pasta 'data' (se quiser manter bancos)
# Se quiser apagar tudo, use: rm -rf /opt/asn-monitor
mkdir -p /opt/asn-monitor

# 5. EXTRAÇÃO
if [ -f "$LOCAL_ZIP" ]; then
    echo -e "${GREEN}[*] Usando arquivo local $LOCAL_ZIP${NC}"
    cp "$LOCAL_ZIP" /tmp/asn_package.zip
else
    echo -e "${BLUE}[*] Baixando pacote via rede...${NC}"
    wget -q "$DOWNLOAD_URL" -O /tmp/asn_package.zip
fi

echo -e "${BLUE}[*] Extraindo arquivos...${NC}"
unzip -qo /tmp/asn_package.zip -d /tmp/asn_extract
# Move os arquivos limpando o destino antes
for dir in dashboards elastic_setup filebeat forensics grafana logstash nginx reputation; do
    rm -rf /opt/asn-monitor/$dir
    [ -d "/tmp/asn_extract/dist_package/$dir" ] && mv /tmp/asn_extract/dist_package/$dir /opt/asn-monitor/
done
cp /tmp/asn_extract/dist_package/docker-compose.yml /opt/asn-monitor/ 2>/dev/null
rm -rf /tmp/asn_extract /tmp/asn_package.zip

cd /opt/asn-monitor
sed -i "s/seu-usuario/$DUSER/g" docker-compose.yml
sysctl -w vm.max_map_count=262144 > /dev/null

# 6. SSL
echo -e "${BLUE}[*] Configurando SSL...${NC}"
systemctl stop nginx 2>/dev/null
certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m $EMAIL --expand
envsubst '${DOMAIN}' < nginx/default.conf.template > nginx/default.conf

# 7. PERMISSÕES
mkdir -p data/{sqlite,es_data}
chmod -R 777 data/
chown -R 472:472 grafana/ dashboards/ 2>/dev/null

# 8. DEPLOY (COMANDO V2 - SEM HÍFEN)
echo -e "${BLUE}[*] Subindo containers...${NC}"
docker compose pull -q
docker compose up -d

# 9. FINALIZAÇÃO
echo -e "${BLUE}[*] Aguardando Elasticsearch (60s)...${NC}"
until curl -s -u elastic:9R=OOq0t-amCgsVVH=PV http://localhost:9200 > /dev/null; do
    echo -ne "."
    sleep 3
done

docker exec -it asn-reputation python3 -c "import sys; sys.path.append('/app/reputation'); from core.database import init_db; init_db()"

echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}   INSTALAÇÃO CONCLUÍDA!${NC}"
echo -e "${BLUE}   URL: https://$DOMAIN${NC}"
echo -e "${GREEN}==========================================================${NC}"
