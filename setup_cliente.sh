#!/bin/bash
# ==============================================================================
#   ASN MONITOR PRO - INSTALADOR AUTOMÁTICO
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${BLUE}==========================================================${NC}"
echo -e "${GREEN}          INSTALADOR AUTOMÁTICO ASN MONITOR PRO           ${NC}"
echo -e "${BLUE}==========================================================${NC}"

# 1. VALIDAÇÃO DE ROOT
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[!] Erro: Execute como root (sudo).${NC}"
   exit 1
fi

# 2. COLETA DE DADOS INICIAL (TUDO DE UMA VEZ)
echo -e "${YELLOW}>>> Definições do Provedor:${NC}"
read -p "   Domínio de Acesso: " DOMAIN
read -p "   Número do ASN: " ASN
read -p "   Bloco de IP: " SUBNET
read -p "   Email para SSL: " EMAIL
echo -e ""
echo -e "${YELLOW}>>> Credenciais Docker Hub (Imagens Privadas):${NC}"
read -p "   Usuário Docker Hub: " DUSER
read -s -p "   Senha Docker Hub: " DPASS
echo -e "\n${BLUE}----------------------------------------------------------${NC}"

# 3. INSTALAÇÃO DE PACOTES
echo -e "${BLUE}[*] Instalando Docker e ferramentas base...${NC}"
apt update -qq
apt install -y docker.io docker-compose certbot curl wget unzip gettext-base -qq
systemctl enable docker --now

# 4. LOGIN DOCKER HUB (FEITO LOGO NO INÍCIO)
echo -e "${BLUE}[*] Autenticando no Docker Hub...${NC}"
echo "$DPASS" | docker login -u "$DUSER" --password-stdin
if [ $? -ne 0 ]; then
    echo -e "${RED}[!] Erro: Falha no login do Docker Hub. Verifique usuário e senha.${NC}"
    exit 1
fi

# 5. OTIMIZAÇÃO DE KERNEL
sysctl -w vm.max_map_count=262144 > /dev/null
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# 6. DOWNLOAD DO PACOTE (MÉTODO ROBUSTO PARA GOOGLE DRIVE)
echo -e "${BLUE}[*] Baixando pacote do Google Drive...${NC}"
FILE_ID="1pRdBS3vsP1_xDvWa2vZc3APP05MYH-w8"

# Tenta baixar usando o método de confirmação para arquivos grandes
wget --load-cookies /tmp/cookies.txt "https://docs.google.com/uc?export=download&confirm=$(wget --quiet --save-cookies /tmp/cookies.txt --keep-session-cookies --no-check-certificate 'https://docs.google.com/uc?export=download&id='$FILE_ID -O- | sed -rn 's/.*confirm=([0-9A-Za-z_]+).*/\1\n/p')&id="$FILE_ID -O /tmp/asn_package.zip --no-check-certificate
rm -rf /tmp/cookies.txt

# Validação do Zip
if [ ! -s /tmp/asn_package.zip ]; then
    echo -e "${RED}[!] Erro: Falha ao baixar o arquivo do Google Drive.${NC}"
    exit 1
fi

# 7. EXTRAÇÃO E ORGANIZAÇÃO
echo -e "${BLUE}[*] Extraindo arquivos...${NC}"
mkdir -p /opt/asn-monitor
unzip -qo /tmp/asn_package.zip -d /opt/asn-monitor/

# Verifica se a extração criou a pasta 'dist_package' e move o conteúdo para a raiz
if [ -d "/opt/asn-monitor/dist_package" ]; then
    mv /opt/asn-monitor/dist_package/* /opt/asn-monitor/
    mv /opt/asn-monitor/dist_package/.* /opt/asn-monitor/ 2>/dev/null
    rm -rf /opt/asn-monitor/dist_package
fi

cd /opt/asn-monitor

# 8. CONFIGURAÇÃO .ENV
cat <<EOF > .env
TARGET_ASN=$ASN
TARGET_SUBNET=$SUBNET
CLIENT_DOMAIN=$DOMAIN
INTERNAL_DNS=172.18.0.53
ELASTIC_PASSWORD=9R=OOq0t-amCgsVVH=PV
SECRET_KEY=$(openssl rand -hex 24)
DEFAULT_PASS=Mudar@123
EOF

# 9. SSL E NGINX
echo -e "${BLUE}[*] Configurando SSL (Let's Encrypt)...${NC}"
certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m $EMAIL
if [ -f "nginx/default.conf.template" ]; then
    envsubst '${DOMAIN}' < nginx/default.conf.template > nginx/default.conf
else
    echo -e "${RED}[!] Erro: Arquivo nginx/default.conf.template não encontrado no ZIP.${NC}"
    exit 1
fi
chmod -R 755 /etc/letsencrypt/live/

# 10. DEPLOY
echo -e "${BLUE}[*] Baixando imagens e subindo containers...${NC}"
docker-compose pull -q
docker-compose up -d

# 11. BOOTSTRAP E TEMPLATES
echo -e "${BLUE}[*] Aguardando Elasticsearch iniciar (pode demorar)...${NC}"
until curl -s -u elastic:9R=OOq0t-amCgsVVH=PV http://localhost:9200 > /dev/null; do
    echo -ne "."
    sleep 3
done
echo -e "${GREEN} OK!${NC}"

echo -e "${BLUE}[*] Inicializando banco de dados...${NC}"
docker exec -it asn-reputation python3 -c "import sys; sys.path.append('/app/reputation'); from core.database import init_db; init_db()"

echo -e "${BLUE}[*] Aplicando lógica forense...${NC}"
curl -s -u elastic:9R=OOq0t-amCgsVVH=PV -X PUT "http://localhost:9200/_ilm/policy/forensics_policy" -H 'Content-Type: application/json' --data-binary @elastic_setup/ilm_policies.json > /dev/null
curl -s -u elastic:9R=OOq0t-amCgsVVH=PV -X PUT "http://localhost:9200/_index_template/forensics_template" -H 'Content-Type: application/json' --data-binary @index_templates.json > /dev/null

echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}   INSTALAÇÃO CONCLUÍDA COM SUCESSO!                      ${NC}"
echo -e "${BLUE}   URL:      ${YELLOW}https://$DOMAIN${NC}"
echo -e "${BLUE}   LOGIN:    admin / Mudar@123"
echo -e "${GREEN}==========================================================${NC}"
