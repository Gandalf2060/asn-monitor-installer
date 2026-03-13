#!/bin/bash
# ==============================================================================
#   ASN MONITOR PRO - INSTALADOR v9.0 (FIXED MIRROR EDITION)
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- CONFIGURAÇÃO FIXA DO SEU SERVIDOR (NÃO MUDA) ---
MIRROR_URL="http://179.42.68.135:8080/asn_monitor_PRO_v1.zip"
INSTALL_DIR="/opt/asn-monitor"

clear
echo -e "${BLUE}==========================================================${NC}"
echo -e "${GREEN}          INSTALADOR AUTOMÁTICO ASN MONITOR PRO           ${NC}"
echo -e "${BLUE}==========================================================${NC}"

[[ $EUID -ne 0 ]] && { echo -e "${RED}[!] Erro: Execute como root.${NC}"; exit 1; }

# --- 1. CORREÇÃO DE REDE (DNS) ---
echo -e "${BLUE}[*] Corrigindo resolução de nomes...${NC}"
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# --- 2. COLETA DE DADOS (ÚNICA COISA QUE VOCÊ DIGITA) ---
echo -e "${YELLOW}>>> Dados do Cliente:${NC}"
read -p "   Domínio de Acesso: " DOMAIN
read -p "   ASN: " ASN
read -p "   Bloco IP: " SUBNET
read -p "   Email SSL: " EMAIL
read -p "   User Docker Hub: " DUSER
read -s -p "   Token Docker Hub: " DPASS
echo -e "\n"

# --- 3. LIMPEZA DE AMBIENTE ---
echo -e "${BLUE}[*] Liberando portas e limpando pacotes antigos...${NC}"
systemctl stop nginx 2>/dev/null
systemctl disable nginx 2>/dev/null
fuser -k 80/tcp 443/tcp 2>/dev/null
apt-get purge docker.io containerd runc -y -qq 2>/dev/null

# --- 4. INSTALAÇÃO DOCKER OFICIAL ---
echo -e "${BLUE}[*] Instalando Docker Engine e Compose V2...${NC}"
apt-get update -qq
apt-get install -y ca-certificates curl gnupg lsb-release unzip gettext-base certbot -qq

mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
CODENAME=$(lsb_release -cs)
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin -qq
systemctl enable docker --now

# --- 5. LOGIN DOCKER HUB ---
echo "$DPASS" | docker login -u "$DUSER" --password-stdin

# --- 6. OTIMIZAÇÃO KERNEL ---
sysctl -w vm.max_map_count=262144 > /dev/null
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# --- 7. DOWNLOAD E EXTRAÇÃO ---
echo -e "${BLUE}[*] Baixando pacote do seu Mirror ($MIRROR_URL)...${NC}"
rm -rf "$INSTALL_DIR" && mkdir -p "$INSTALL_DIR"
wget -q --show-progress "$MIRROR_URL" -O /tmp/asn_package.zip

if [ ! -s /tmp/asn_package.zip ]; then
    echo -e "${RED}[!] Erro crítico: Falha ao baixar o arquivo do seu servidor.${NC}"
    exit 1
fi

echo -e "${BLUE}[*] Extraindo arquivos...${NC}"
unzip -qo /tmp/asn_package.zip -d /tmp/asn_extract
if [ -d "/tmp/asn_extract/dist_package" ]; then
    cp -r /tmp/asn_extract/dist_package/* "$INSTALL_DIR/"
else
    cp -r /tmp/asn_extract/* "$INSTALL_DIR/"
fi
rm -rf /tmp/asn_extract /tmp/asn_package.zip
cd "$INSTALL_DIR"

# --- 8. AJUSTES DINÂMICOS ---
sed -i "s/seu-usuario/$DUSER/g" docker-compose.yml
# Ajuste de memória para 2GB (Obrigatório para servidores < 12GB RAM)
sed -i "s/-Xms4g -Xmx4g/-Xms2g -Xmx2g/g" docker-compose.yml

cat <<EOF > .env
TARGET_ASN=$ASN
TARGET_SUBNET=$SUBNET
CLIENT_DOMAIN=$DOMAIN
INTERNAL_DNS=172.18.0.53
ELASTIC_PASSWORD=9R=OOq0t-amCgsVVH=PV
SECRET_KEY=$(openssl rand -hex 24)
DEFAULT_PASS=Mudar@123
EOF

# --- 9. SSL ---
echo -e "${BLUE}[*] Configurando SSL...${NC}"
certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --expand
envsubst '${DOMAIN}' < nginx/default.conf.template > nginx/default.conf
chmod -R 755 /etc/letsencrypt/live/

# --- 10. PERMISSÕES E DEPLOY ---
mkdir -p data/{sqlite,es_data} && chmod -R 777 data/
chown -R 472:472 grafana/ dashboards/ 2>/dev/null
echo -e "${BLUE}[*] Iniciando containers...${NC}"
docker compose pull -q
docker compose up -d

# --- 11. FINALIZAÇÃO (ESPERA O BANCO LIGAR) ---
echo -e "${BLUE}[*] Aguardando Elasticsearch responder...${NC}"
for i in {1..50}; do
    if curl -s -u elastic:9R=OOq0t-amCgsVVH=PV http://localhost:9200 > /dev/null; then
        echo -e "${GREEN} OK!${NC}"
        # Inicializa banco
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
