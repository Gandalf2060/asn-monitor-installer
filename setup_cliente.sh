#!/bin/bash
# ==============================================================================
#   ASN MONITOR PRO - INSTALADOR AUTOMÁTICO (DRIVE VERSION)
# ==============================================================================

# Cores para o terminal
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

clear
echo -e "${BLUE}==========================================================${NC}"
echo -e "${GREEN}          INSTALADOR AUTOMÁTICO ASN MONITOR PRO           ${NC}"
echo -e "${BLUE}==========================================================${NC}"

# 1. VALIDAÇÃO DE ROOT
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[!] Erro: Este script precisa ser rodado como root (sudo).${NC}"
   exit 1
fi

# 2. COLETA DE DADOS DO CLIENTE
echo -e "${YELLOW}>>> Configurações de Identidade:${NC}"
read -p "   Domínio de Acesso (ex: monitor.provedor.com.br): " DOMAIN
read -p "   Número do ASN (ex: 269396): " ASN
read -p "   Bloco de IP (ex: 45.184.112.0/22): " SUBNET
read -p "   Email para Notificações SSL: " EMAIL
echo -e "${YELLOW}>>> Credenciais de Repositório Privado:${NC}"
read -p "   Seu Usuário Docker Hub: " DUSER
echo -e "${BLUE}----------------------------------------------------------${NC}"

# 3. PREPARAR SISTEMA
echo -e "${BLUE}[*] Instalando dependências do sistema...${NC}"
apt update -qq
apt install -y docker.io docker-compose certbot curl wget unzip gettext-base -qq
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# 4. DOWNLOAD DO PACOTE VIA GOOGLE DRIVE
echo -e "${BLUE}[*] Baixando pacote do sistema (Google Drive)...${NC}"
FILE_ID="1pRdBS3vsP1_xDvWa2vZc3APP05MYH-w8"
# Comando para burlar a verificação de arquivos grandes do Drive
CONFIRM=$(curl -sc /tmp/gcookie "https://drive.google.com/uc?export=download&id=${FILE_ID}" | grep -o 'confirm=[^&?%]*' | sed 's/confirm=//')
curl -Lb /tmp/gcookie "https://drive.google.com/uc?export=download&id=${FILE_ID}&confirm=${CONFIRM}" -o /tmp/asn_package.zip

# 5. ESTRUTURA DE PASTAS
echo -e "${BLUE}[*] Organizando arquivos...${NC}"
mkdir -p /opt/asn-monitor
unzip -o /tmp/asn_package.zip -d /opt/asn-monitor/
# Move o conteúdo da pasta dist_package (gerada pelo seu script anterior) para a raiz do monitor
cd /opt/asn-monitor/dist_package
cp -r . ..
cd ..
rm -rf dist_package

# 6. CONFIGURAÇÃO DO AMBIENTE (.env)
echo -e "${BLUE}[*] Gerando chaves de segurança...${NC}"
cat <<EOF > .env
TARGET_ASN=$ASN
TARGET_SUBNET=$SUBNET
CLIENT_DOMAIN=$DOMAIN
INTERNAL_DNS=172.18.0.53
ELASTIC_PASSWORD=9R=OOq0t-amCgsVVH=PV
SECRET_KEY=$(openssl rand -hex 16)
DEFAULT_PASS=Mudar@123
EOF

# 7. CONFIGURAÇÃO NGINX E SSL
echo -e "${BLUE}[*] Configurando SSL e Servidor Web...${NC}"
envsubst '${DOMAIN}' < nginx/default.conf.template > nginx/default.conf
certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m $EMAIL
chmod -R 755 /etc/letsencrypt/live/

# 8. PERMISSÕES E LOGIN DOCKER
echo -e "${BLUE}[*] Preparando containers...${NC}"
chown root:root filebeat/filebeat.yml && chmod 644 filebeat/filebeat.yml
chown -R 472:472 grafana/ dashboards/
mkdir -p data/{sqlite,es_data} && chmod -R 777 data/

echo -e "${YELLOW}>>> Por favor, faça login para baixar as imagens privadas:${NC}"
docker login -u "$DUSER"

# 9. DEPLOY FINAL
echo -e "${BLUE}[*] Iniciando sistema (isso pode levar alguns minutos)...${NC}"
docker-compose pull
docker-compose up -d

# 10. INICIALIZAÇÃO DO BANCO
echo -e "${BLUE}[*] Aguardando inicialização do banco (20s)...${NC}"
sleep 20
docker exec -it asn-reputation python3 -c "import sys; sys.path.append('/app/reputation'); from core.database import init_db; init_db()"

# 11. TEMPLATES E POLÍTICAS ELASTIC
echo -e "${BLUE}[*] Aplicando inteligência forense...${NC}"
curl -u elastic:9R=OOq0t-amCgsVVH=PV -X PUT "http://localhost:9200/_ilm/policy/forensics_policy" -H 'Content-Type: application/json' --data-binary @elastic_setup/ilm_policies.json
curl -u elastic:9R=OOq0t-amCgsVVH=PV -X PUT "http://localhost:9200/_index_template/forensics_template" -H 'Content-Type: application/json' --data-binary @index_templates.json

echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}   INSTALAÇÃO CONCLUÍDA COM SUCESSO!                      ${NC}"
echo -e "${BLUE}   ACESSO: ${YELLOW}https://$DOMAIN${NC}"
echo -e "${BLUE}   USUÁRIO: ${NC}admin"
echo -e "${BLUE}   SENHA: ${NC}Mudar@123"
echo -e "${GREEN}==========================================================${NC}"
