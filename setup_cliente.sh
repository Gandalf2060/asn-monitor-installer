#!/bin/bash
# ==============================================================================
#   ASN MONITOR PRO - INSTALADOR v3.3 (SAME-SERVER EDITION)
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Se o ZIP estiver nesta mesma máquina, aponte o caminho físico aqui:
LOCAL_ZIP="/opt/asn-host/asn_monitor_PRO_v1.zip"
# Se não achar local, ele tenta baixar deste IP:
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
read -p "   Domínio de Acesso (ex: monitor.cliente.com.br): " DOMAIN
read -p "   Número do ASN: " ASN
read -p "   Bloco de IP: " SUBNET
read -p "   Email para SSL: " EMAIL
echo -e ""
read -p "   Usuário Docker Hub (ID): " DUSER
read -s -p "   Personal Access Token: " DPASS
echo -e ""

# 2. INSTALAÇÃO DE DEPENDÊNCIAS
echo -e "${BLUE}[*] Instalando dependências e limpando porta 80...${NC}"
systemctl stop nginx 2>/dev/null
apt update -qq
apt install -y docker.io docker-compose certbot curl wget unzip gettext-base -qq

# 3. LOGIN DOCKER HUB
echo "$DPASS" | docker login -u "$DUSER" --password-stdin

# 4. PREPARAÇÃO DO PACOTE
mkdir -p /opt/asn-monitor
if [ -f "$LOCAL_ZIP" ]; then
    echo -e "${GREEN}[*] Arquivo local detectado. Usando $LOCAL_ZIP${NC}"
    cp "$LOCAL_ZIP" /tmp/asn_package.zip
else
    echo -e "${BLUE}[*] Baixando pacote via rede...${NC}"
    wget -q "$DOWNLOAD_URL" -O /tmp/asn_package.zip
fi

# 5. EXTRAÇÃO
echo -e "${BLUE}[*] Extraindo arquivos...${NC}"
unzip -qo /tmp/asn_package.zip -d /opt/asn-monitor/
if [ -d "/opt/asn-monitor/dist_package" ]; then
    mv /opt/asn-monitor/dist_package/* /opt/asn-monitor/
    mv /opt/asn-monitor/dist_package/.* /opt/asn-monitor/ 2>/dev/null
    rm -rf /opt/asn-monitor/dist_package
fi

cd /opt/asn-monitor
sed -i "s/seu-usuario/$DUSER/g" docker-compose.yml
sysctl -w vm.max_map_count=262144 > /dev/null

# 6. SSL (Standalone)
echo -e "${BLUE}[*] Obtendo Certificado SSL...${NC}"
certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m $EMAIL --expand
envsubst '${DOMAIN}' < nginx/default.conf.template > nginx/default.conf

# 7. PERMISSÕES
mkdir -p data/{sqlite,es_data}
chmod -R 777 data/
chown -R 472:472 grafana/ dashboards/ 2>/dev/null

# 8. DEPLOY
echo -e "${BLUE}[*] Subindo containers principais...${NC}"
docker-compose pull -q
docker-compose up -d

# 9. FINALIZAÇÃO
echo -e "${BLUE}[*] Aguardando Elasticsearch iniciar...${NC}"
until curl -s -u elastic:9R=OOq0t-amCgsVVH=PV http://localhost:9200 > /dev/null; do
    echo -ne "."
    sleep 5
done

docker exec -it asn-reputation python3 -c "import sys; sys.path.append('/app/reputation'); from core.database import init_db; init_db()"

echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}   INSTALAÇÃO CONCLUÍDA NO MESMO SERVIDOR!                ${NC}"
echo -e "${BLUE}   URL: https://$DOMAIN${NC}"
echo -e "${BLUE}   ARQUIVO HOST: http://$(curl -s ifconfig.me):8080/ (Ativo)${NC}"
echo -e "${GREEN}==========================================================${NC}"
