#!/bin/bash
# ==============================================================================
#   ASN MONITOR PRO - INSTALADOR AUTOMÁTICO (ULTIMATE VERSION)
#   Suporte: Ubuntu 20.04 / 22.04
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

# 2. COLETA DE DADOS
echo -e "${YELLOW}>>> Definições do Provedor:${NC}"
read -p "   Domínio de Acesso (ex: monitor.provedor.com.br): " DOMAIN
read -p "   Número do ASN (ex: 269396): " ASN
read -p "   Bloco de IP (ex: 45.184.112.0/22): " SUBNET
read -p "   Email para SSL: " EMAIL
echo -e "${YELLOW}>>> Repositório Docker Hub:${NC}"
read -p "   Seu Usuário Docker Hub: " DUSER
echo -e "${BLUE}----------------------------------------------------------${NC}"

# 3. INSTALAÇÃO DE PACOTES ESSENCIAIS
echo -e "${BLUE}[*] Preparando repositórios e instalando Docker/Certbot...${NC}"
apt update -qq
# Instala Docker, Compose V2, Certbot, Unzip e ferramentas de processamento de texto
apt install -y docker.io docker-compose certbot curl wget unzip gettext-base -qq
systemctl enable docker --now

# 4. OTIMIZAÇÃO DE KERNEL (Obrigatório para Elasticsearch)
echo -e "${BLUE}[*] Otimizando Kernel para Banco de Dados...${NC}"
sysctl -w vm.max_map_count=262144 > /dev/null
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# 5. DOWNLOAD E EXTRAÇÃO DO PACOTE
echo -e "${BLUE}[*] Baixando pacote do sistema do Google Drive...${NC}"
FILE_ID="1pRdBS3vsP1_xDvWa2vZc3APP05MYH-w8"
CONFIRM=$(curl -sc /tmp/gcookie "https://drive.google.com/uc?export=download&id=${FILE_ID}" | grep -o 'confirm=[^&?%]*' | sed 's/confirm=//')
curl -Lb /tmp/gcookie "https://drive.google.com/uc?export=download&id=${FILE_ID}&confirm=${CONFIRM}" -o /tmp/asn_package.zip

mkdir -p /opt/asn-monitor
unzip -qo /tmp/asn_package.zip -d /opt/asn-monitor/
# Normaliza estrutura se estiver dentro de subpasta no ZIP
if [ -d "/opt/asn-monitor/dist_package" ]; then
    cp -r /opt/asn-monitor/dist_package/* /opt/asn-monitor/
    rm -rf /opt/asn-monitor/dist_package
fi
cd /opt/asn-monitor

# 6. CONFIGURAÇÃO DE SEGURANÇA E AMBIENTE
echo -e "${BLUE}[*] Gerando chaves de segurança exclusivas...${NC}"
cat <<EOF > .env
TARGET_ASN=$ASN
TARGET_SUBNET=$SUBNET
CLIENT_DOMAIN=$DOMAIN
INTERNAL_DNS=172.18.0.53
ELASTIC_PASSWORD=9R=OOq0t-amCgsVVH=PV
SECRET_KEY=$(openssl rand -hex 24)
DEFAULT_PASS=Mudar@123
EOF

# 7. EMISSÃO DE SSL E NGINX
echo -e "${BLUE}[*] Configurando HTTPS (Let's Encrypt)...${NC}"
# Para o certbot funcionar no modo standalone, a porta 80 precisa estar livre
certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m $EMAIL
envsubst '${DOMAIN}' < nginx/default.conf.template > nginx/default.conf
chmod -R 755 /etc/letsencrypt/live/

# 8. RENOVAÇÃO AUTOMÁTICA DO SSL (Cronjob)
if ! crontab -l | grep -q "certbot renew"; then
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --post-hook 'docker restart asn-nginx'") | crontab -
    echo -e "${BLUE}[*] Agendamento de renovação SSL configurado.${NC}"
fi

# 9. LOGIN E DEPLOY
echo -e "${YELLOW}>>> Login necessário para baixar imagens privadas:${NC}"
docker login -u "$DUSER"

echo -e "${BLUE}[*] Subindo containers (Aguarde)...${NC}"
docker-compose pull -q
docker-compose up -d

# 10. VERIFICAÇÃO DE SAÚDE E BOOTSTRAP
echo -e "${BLUE}[*] Aguardando o Banco de Dados estabilizar...${NC}"
# Loop que espera o Elasticsearch responder antes de continuar
until curl -s -u elastic:9R=OOq0t-amCgsVVH=PV http://localhost:9200 > /dev/null; do
    echo -ne "."
    sleep 2
done
echo -e "${GREEN} OK!${NC}"

echo -e "${BLUE}[*] Inicializando tabelas e usuário Admin...${NC}"
docker exec -it asn-reputation python3 -c "import sys; sys.path.append('/app/reputation'); from core.database import init_db; init_db()"

echo -e "${BLUE}[*] Aplicando Templates de Inteligência Forense...${NC}"
curl -s -u elastic:9R=OOq0t-amCgsVVH=PV -X PUT "http://localhost:9200/_ilm/policy/forensics_policy" -H 'Content-Type: application/json' --data-binary @elastic_setup/ilm_policies.json > /dev/null
curl -s -u elastic:9R=OOq0t-amCgsVVH=PV -X PUT "http://localhost:9200/_index_template/forensics_template" -H 'Content-Type: application/json' --data-binary @index_templates.json > /dev/null

echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}   INSTALAÇÃO CONCLUÍDA COM SUCESSO!                      ${NC}"
echo -e "${BLUE}   URL:      ${YELLOW}https://$DOMAIN${NC}"
echo -e "${BLUE}   USUÁRIO:  admin"
echo -e "${BLUE}   SENHA:    Mudar@123"
echo -e "${GREEN}==========================================================${NC}"
