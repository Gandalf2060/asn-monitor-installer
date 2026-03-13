#!/bin/bash
# ==============================================================================
#   ASN MONITOR PRO - INSTALADOR v3.6 (BUG FIX & REPO EDITION)
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Caminho Físico (Como você está no mesmo servidor)
LOCAL_ZIP="/opt/asn-host/asn_monitor_PRO_v1.zip"
DOWNLOAD_URL="http://127.0.0.1:8080/asn_monitor_PRO_v1.zip"

clear
echo -e "${BLUE}==========================================================${NC}"
echo -e "${GREEN}          INSTALADOR AUTOMÁTICO ASN MONITOR PRO           ${NC}"
echo -e "${BLUE}==========================================================${NC}"

[[ $EUID -ne 0 ]] && { echo -e "${RED}[!] Erro: Execute como root.${NC}"; exit 1; }

# 1. COLETA DE DADOS
read -p "   Domínio de Acesso: " DOMAIN
read -p "   Número do ASN: " ASN
read -p "   Bloco de IP: " SUBNET
read -p "   Email para SSL: " EMAIL
echo -e ""
read -p "   Usuário Docker Hub: " DUSER
read -s -p "   Personal Access Token: " DPASS
echo -e ""

# 2. LIMPEZA DE PORTAS E NGINX NATIVO
echo -e "${BLUE}[*] Liberando portas 80/443...${NC}"
systemctl stop nginx 2>/dev/null
systemctl disable nginx 2>/dev/null
fuser -k 80/tcp 443/tcp 2>/dev/null

# 3. INSTALAÇÃO DOCKER (MÉTODO REPOSITÓRIO OFICIAL)
echo -e "${BLUE}[*] Instalando Docker via Repositório Oficial (Evita erro de dependência)...${NC}"
apt-get update -qq
apt-get install -y ca-certificates curl gnupg lsb-release unzip gettext-base -qq

mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
# Instala o motor docker e o plugin do compose V2
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin -qq
systemctl enable docker --now

# 4. LOGIN DOCKER HUB
echo "$DPASS" | docker login -u "$DUSER" --password-stdin

# 5. OTIMIZAÇÃO DE KERNEL
sysctl -w vm.max_map_count=262144 > /dev/null
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# 6. OBTENÇÃO DO PACOTE (DENTRO OU FORA)
rm -rf /opt/asn-monitor && mkdir -p /opt/asn-monitor
if [ -f "$LOCAL_ZIP" ]; then
    echo -e "${GREEN}[*] Usando arquivo local encontrado em $LOCAL_ZIP${NC}"
    cp "$LOCAL_ZIP" /tmp/asn_package.zip
else
    echo -e "${YELLOW}[!] Arquivo local não encontrado. Tentando via rede...${NC}"
    wget -q --show-progress "$DOWNLOAD_URL" -O /tmp/asn_package.zip
fi

# Valida se o ZIP é íntegro antes de prosseguir
if ! unzip -t /tmp/asn_package.zip > /dev/null 2>&1; then
    echo -e "${RED}[!] Erro: Arquivo ZIP corrompido ou inválido.${NC}"
    exit 1
fi

# 7. EXTRAÇÃO
echo -e "${BLUE}[*] Extraindo arquivos...${NC}"
unzip -qo /tmp/asn_package.zip -d /tmp/asn_extract
# Move tudo para /opt/asn-monitor, lidando com a pasta dist_package se ela existir
if [ -d "/tmp/asn_extract/dist_package" ]; then
    cp -r /tmp/asn_extract/dist_package/* /opt/asn-monitor/
else
    cp -r /tmp/asn_extract/* /opt/asn-monitor/
fi
rm -rf /tmp/asn_extract /tmp/asn_package.zip

cd /opt/asn-monitor

# 8. AJUSTES DINÂMICOS (USUÁRIO E MEMÓRIA)
sed -i "s/seu-usuario/$DUSER/g" docker-compose.yml
sed -i "s/-Xms4g -Xmx4g/-Xms2g -Xmx2g/g" docker-compose.yml

# 9. CONFIGURAÇÃO .ENV
cat <<EOF > .env
TARGET_ASN=$ASN
TARGET_SUBNET=$SUBNET
CLIENT_DOMAIN=$DOMAIN
INTERNAL_DNS=172.18.0.53
ELASTIC_PASSWORD=9R=OOq0t-amCgsVVH=PV
SECRET_KEY=$(openssl rand -hex 24)
DEFAULT_PASS=Mudar@123
EOF

# 10. SSL
echo -e "${BLUE}[*] Configurando SSL...${NC}"
certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m $EMAIL --expand
envsubst '${DOMAIN}' < nginx/default.conf.template > nginx/default.conf

# 11. PERMISSÕES
mkdir -p data/{sqlite,es_data}
chmod -R 777 data/
chown -R 472:472 grafana/ dashboards/ 2>/dev/null

# 12. DEPLOY (COMANDO V2)
echo -e "${BLUE}[*] Iniciando containers...${NC}"
docker compose pull -q
docker compose up -d

# 13. FINALIZAÇÃO
echo -e "${BLUE}[*] Aguardando Elasticsearch (60s)...${NC}"
for i in {1..30}; do
    if curl -s -u elastic:9R=OOq0t-amCgsVVH=PV http://localhost:9200 > /dev/null; do
        echo -e "${GREEN} OK!${NC}"
        break
    fi
    echo -ne "."
    sleep 5
done

docker exec -it asn-reputation python3 -c "import sys; sys.path.append('/app/reputation'); from core.database import init_db; init_db()"

echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}   INSTALAÇÃO CONCLUÍDA: https://$DOMAIN${NC}"
echo -e "${GREEN}==========================================================${NC}"
