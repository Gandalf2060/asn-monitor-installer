#!/bin/bash
# ==============================================================================
#   ASN MONITOR PRO - INSTALADOR v8.5 (DNS & SYNTAX REPAIR)
#   Suporte: Ubuntu 20.04, 22.04, 24.04+
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- CONFIGURAÇÃO DO SEU MIRROR ---
MIRROR_URL="http://IP_DO_SEU_SERVIDOR_MESTRE:8080/asn_monitor_PRO_v1.zip"
INSTALL_DIR="/opt/asn-monitor"

clear
echo -e "${BLUE}==========================================================${NC}"
echo -e "${GREEN}          INSTALADOR AUTOMÁTICO ASN MONITOR PRO           ${NC}"
echo -e "${BLUE}==========================================================${NC}"

[[ $EUID -ne 0 ]] && { echo -e "${RED}[!] Erro: Execute como root.${NC}"; exit 1; }

# --- FIX DE REDE: FORÇAR DNS PARA RESOLUÇÃO DE NOMES ---
echo -e "${BLUE}[*] Corrigindo resolução de nomes (DNS)...${NC}"
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# 1. COLETA DE DADOS
echo -e "${YELLOW}>>> Definições do Cliente:${NC}"
read -p "   Domínio de Acesso: " DOMAIN
read -p "   Número do ASN: " ASN
read -p "   Bloco de IP: " SUBNET
read -p "   Email para SSL: " EMAIL
echo -e ""
read -p "   Usuário Docker Hub: " DUSER
read -s -p "   Personal Access Token: " DPASS
echo -e "\n"

# 2. LIMPEZA DE CONFLITOS
echo -e "${BLUE}[*] Liberando portas e limpando pacotes antigos...${NC}"
systemctl stop nginx 2>/dev/null
fuser -k 80/tcp 443/tcp 2>/dev/null
apt-get purge nginx nginx-common docker.io containerd runc -y -qq 2>/dev/null

# 3. INSTALAÇÃO DO DOCKER OFICIAL
echo -e "${BLUE}[*] Configurando repositórios Docker...${NC}"
apt-get update -qq
apt-get install -y ca-certificates curl gnupg lsb-release unzip gettext-base certbot -qq

mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
CODENAME=$(lsb_release -cs)
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin -qq
systemctl enable docker --now

# 4. LOGIN DOCKER HUB
echo -e "${BLUE}[*] Autenticando no Docker Hub...${NC}"
echo "$DPASS" | docker login -u "$DUSER" --password-stdin

# 5. OTIMIZAÇÃO DE KERNEL
sysctl -w vm.max_map_count=262144 > /dev/null
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# 6. DOWNLOAD E EXTRAÇÃO
echo -e "${BLUE}[*] Baixando pacote do sistema...${NC}"
wget -q --show-progress "$MIRROR_URL" -O /tmp/asn_package.zip

if [ ! -s /tmp/asn_package.zip ]; then
    echo -e "${RED}[!] Erro: Falha ao baixar o pacote. Verifique a rede e o Mirror.${NC}"
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

# 7. AJUSTES DINÂMICOS
sed -i "s/seu-usuario/$DUSER/g" docker-compose.yml
TOTAL_RAM=$(free -g | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM" -lt 12 ]; then
    echo -e "${YELLOW}[!] Memória < 12GB. Limitando Elastic a 2GB RAM.${NC}"
    sed -i "s/-Xms4g -Xmx4g/-Xms2g -Xmx2g/g" docker-compose.yml
fi

# 8. GERAÇÃO DO .ENV
cat <<EOF > .env
TARGET_ASN=$ASN
TARGET_SUBNET=$SUBNET
CLIENT_DOMAIN=$DOMAIN
INTERNAL_DNS=172.18.0.53
ELASTIC_PASSWORD=9R=OOq0t-amCgsVVH=PV
SECRET_KEY=$(openssl rand -hex 24)
DEFAULT_PASS=Mudar@123
EOF

# 9. SSL
echo -e "${BLUE}[*] Gerando SSL (Let's Encrypt)...${NC}"
certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --expand
if [ -f "nginx/default.conf.template" ]; then
    envsubst '${DOMAIN}' < nginx/default.conf.template > nginx/default.conf
    chmod -R 755 /etc/letsencrypt/live/
else
    echo -e "${RED}[!] Erro: Template do Nginx não encontrado.${NC}"
    exit 1
fi

# 10. PERMISSÕES
mkdir -p data/{sqlite,es_data}
chmod -R 777 data/
chown -R 472:472 grafana/ dashboards/ 2>/dev/null

# 11. DEPLOY
echo -e "${BLUE}[*] Iniciando containers...${NC}"
docker compose pull -q
docker compose up -d

# 12. FINALIZAÇÃO (SINTAXE CORRIGIDA)
echo -e "${BLUE}[*] Aguardando Elasticsearch responder...${NC}"
for i in {1..40}; do
    if curl -s -u elastic:9R=OOq0t-amCgsVVH=PV http://localhost:9200 > /dev/null; then
        echo -e "${GREEN} OK!${NC}"
        # Se o banco respondeu, executa o comando de init
        docker exec -it asn-reputation python3 -c "import sys; sys.path.append('/app/reputation'); from core.database import init_db; init_db()"
        break
    fi
    echo -ne "."
    sleep 5
done

echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}   INSTALAÇÃO CONCLUÍDA COM SUCESSO!${NC}"
echo -e "${BLUE}   ACESSO: https://$DOMAIN${NC}"
echo -e "=========================================================="
