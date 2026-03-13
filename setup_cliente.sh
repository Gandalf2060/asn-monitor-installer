#!/bin/bash
# ==============================================================================
#   ASN MONITOR PRO - INSTALADOR v8.0 (SMART OS DETECTION EDITION)
#   Suporte Dinâmico: Ubuntu 20.04, 22.04, 24.04+
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- CONFIGURAÇÃO DO SEU MIRROR ---
MIRROR_URL="http://179.42.68.135:8080/asn_monitor_PRO_v1.zip"
INSTALL_DIR="/opt/asn-monitor"

clear
echo -e "${BLUE}==========================================================${NC}"
echo -e "${GREEN}          INSTALADOR INTELIGENTE ASN MONITOR PRO          ${NC}"
echo -e "${BLUE}==========================================================${NC}"

# 1. DETECÇÃO DE VERSÃO DO SISTEMA
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
    CODENAME=$VERSION_CODENAME
else
    echo -e "${RED}[!] Erro: Não foi possível detectar a versão do Linux.${NC}"
    exit 1
fi

echo -e "${BLUE}[*] Sistema detectado: $NAME ($VER $CODENAME)${NC}"

if [[ "$OS" != "ubuntu" ]]; then
    echo -e "${RED}[!] Este script foi otimizado apenas para Ubuntu.${NC}"
    exit 1
fi

# 2. COLETA DE DADOS
read -p "   Domínio de Acesso: " DOMAIN
read -p "   Número do ASN: " ASN
read -p "   Bloco de IP: " SUBNET
read -p "   Email para SSL: " EMAIL
echo -e ""
read -p "   Usuário Docker Hub: " DUSER
read -s -p "   Personal Access Token: " DPASS
echo -e "\n"

# 3. LIMPEZA DE CONFLITOS (NGINX NATIVO)
echo -e "${BLUE}[*] Liberando portas e limpando Nginx nativo...${NC}"
systemctl stop nginx 2>/dev/null
systemctl disable nginx 2>/dev/null
apt-get purge nginx nginx-common -y -qq 2>/dev/null
fuser -k 80/tcp 443/tcp 2>/dev/null

# 4. INSTALAÇÃO ESPECÍFICA DO DOCKER POR VERSÃO
echo -e "${BLUE}[*] Configurando repositórios oficiais da Docker para $CODENAME...${NC}"
apt-get update -qq
apt-get install -y ca-certificates curl gnupg lsb-release unzip gettext-base certbot -qq

# Preparar diretório de chaves (Diferente em versões antigas vs novas)
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg

# Adicionar repositório baseado no codinome detectado (focal, jammy, noble...)
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
echo -e "${BLUE}[*] Instalando Docker Engine e Compose V2...${NC}"
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin -qq
systemctl enable docker --now

# 5. LOGIN DOCKER HUB
echo "$DPASS" | docker login -u "$DUSER" --password-stdin

# 6. OTIMIZAÇÃO DE KERNEL
sysctl -w vm.max_map_count=262144 > /dev/null
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# 7. DOWNLOAD E EXTRAÇÃO
echo -e "${BLUE}[*] Baixando pacote do sistema via Mirror...${NC}"
wget -q --show-progress "$MIRROR_URL" -O /tmp/asn_package.zip

if [ ! -s /tmp/asn_package.zip ]; then
    echo -e "${RED}[!] Erro: Falha ao baixar o pacote.${NC}"
    exit 1
fi

rm -rf "$INSTALL_DIR" && mkdir -p "$INSTALL_DIR"
unzip -qo /tmp/asn_package.zip -d /tmp/asn_extract

if [ -d "/tmp/asn_extract/dist_package" ]; then
    cp -r /tmp/asn_extract/dist_package/* "$INSTALL_DIR/"
else
    cp -r /tmp/asn_extract/* "$INSTALL_DIR/"
fi
rm -rf /tmp/asn_extract /tmp/asn_package.zip
cd "$INSTALL_DIR"

# 8. AJUSTES DINÂMICOS (USUÁRIO E MEMÓRIA)
sed -i "s/seu-usuario/$DUSER/g" docker-compose.yml
# Ajuste Inteligente de Memória: Se o servidor for pequeno, usa 2GB, se for grande usa 4GB
TOTAL_RAM=$(free -g | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM" -lt 12 ]; then
    echo -e "${YELLOW}[!] Memória detectada < 12GB. Limitando Elasticsearch a 2GB RAM.${NC}"
    sed -i "s/-Xms4g -Xmx4g/-Xms2g -Xmx2g/g" docker-compose.yml
fi

# 9. GERAÇÃO DO .ENV
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
echo -e "${BLUE}[*] Gerando SSL (Let's Encrypt)...${NC}"
certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --expand
envsubst '${DOMAIN}' < nginx/default.conf.template > nginx/default.conf
chmod -R 755 /etc/letsencrypt/live/

# 11. PERMISSÕES
mkdir -p data/{sqlite,es_data}
chmod -R 777 data/
chown -R 472:472 grafana/ dashboards/ 2>/dev/null

# 12. DEPLOY
echo -e "${BLUE}[*] Iniciando containers...${NC}"
docker compose pull -q
docker compose up -d

# 13. FINALIZAÇÃO (Healthcheck)
echo -e "${BLUE}[*] Aguardando Elasticsearch responder...${NC}"
for i in {1..40}; do
    if curl -s -u elastic:9R=OOq0t-amCgsVVH=PV http://localhost:9200 > /dev/null; do
        echo -e "${GREEN} OK!${NC}"
        break
    fi
    echo -ne "."
    sleep 5
done

docker exec -it asn-reputation python3 -c "import sys; sys.path.append('/app/reputation'); from core.database import init_db; init_db()"

echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}   INSTALAÇÃO CONCLUÍDA NO $NAME $VER!${NC}"
echo -e "${BLUE}   ACESSO: https://$DOMAIN${NC}"
echo -e "=========================================================="
