#!/bin/bash
# ==============================================================================
#   ASN MONITOR PRO - INSTALADOR AUTOMÁTICO v2.5 (TOKEN & DRIVE EDITION)
#   Desenvolvido para: Ubuntu 20.04 / 22.04
# ==============================================================================

# Cores para interface
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${BLUE}==========================================================${NC}"
echo -e "${GREEN}          INSTALADOR AUTOMÁTICO ASN MONITOR PRO           ${NC}"
echo -e "${BLUE}==========================================================${NC}"

# 1. VALIDAÇÃO DE USUÁRIO ROOT
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[!] Erro: Este script precisa ser rodado como root (sudo).${NC}"
   exit 1
fi

# 2. COLETA DE INFORMAÇÕES (TUDO NO INÍCIO)
echo -e "${YELLOW}>>> Definições do Provedor:${NC}"
read -p "   Domínio de Acesso (ex: monitor.cliente.com.br): " DOMAIN
read -p "   Número do ASN: " ASN
read -p "   Bloco de IP (ex: 45.184.112.0/22): " SUBNET
read -p "   Email para SSL: " EMAIL
echo -e ""
echo -e "${YELLOW}>>> Credenciais Docker Hub (Repositório Privado):${NC}"
echo -e "${BLUE}   Nota: Se você usa login via Google/SSO, use um Access Token no campo Senha.${NC}"
read -p "   Usuário Docker Hub (ID): " DUSER
read -s -p "   Personal Access Token (ou Senha): " DPASS
echo -e "\n${BLUE}----------------------------------------------------------${NC}"

# 3. INSTALAÇÃO DE DEPENDÊNCIAS DO SISTEMA
echo -e "${BLUE}[*] Instalando Docker, Certbot e Ferramentas...${NC}"
apt update -qq
apt install -y docker.io docker-compose certbot curl wget unzip gettext-base -qq
systemctl enable docker --now

# 4. AUTENTICAÇÃO NO DOCKER HUB
echo -e "${BLUE}[*] Validando acesso ao repositório...${NC}"
echo "$DPASS" | docker login -u "$DUSER" --password-stdin
if [ $? -ne 0 ]; then
    echo -e "${RED}[!] Erro: Falha na autenticação. Verifique seu Token e Usuário.${NC}"
    exit 1
fi

# 5. OTIMIZAÇÕES DE KERNEL (ELASTICSEARCH)
echo -e "${BLUE}[*] Otimizando Kernel para Banco de Dados...${NC}"
sysctl -w vm.max_map_count=262144 > /dev/null
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# 6. DOWNLOAD DO PACOTE VIA GOOGLE DRIVE
echo -e "${BLUE}[*] Baixando pacote do sistema (Aguarde)...${NC}"
FILE_ID="1pRdBS3vsP1_xDvWa2vZc3APP05MYH-w8"
# Lógica para burlar verificação de vírus do Drive para arquivos grandes
wget --load-cookies /tmp/cookies.txt "https://docs.google.com/uc?export=download&confirm=$(wget --quiet --save-cookies /tmp/cookies.txt --keep-session-cookies --no-check-certificate 'https://docs.google.com/uc?export=download&id='$FILE_ID -O- | sed -rn 's/.*confirm=([0-9A-Za-z_]+).*/\1\n/p')&id="$FILE_ID -O /tmp/asn_package.zip --no-check-certificate
rm -rf /tmp/cookies.txt

# Validar se o download foi bem sucedido
if [ ! -s /tmp/asn_package.zip ]; then
    echo -e "${RED}[!] Erro: Falha ao baixar o arquivo do Google Drive.${NC}"
    exit 1
fi

# 7. EXTRAÇÃO E ORGANIZAÇÃO DOS ARQUIVOS
echo -e "${BLUE}[*] Extraindo e configurando diretórios...${NC}"
mkdir -p /opt/asn-monitor
unzip -qo /tmp/asn_package.zip -d /opt/asn-monitor/

# Normaliza se os arquivos estiverem dentro da pasta 'dist_package' no ZIP
if [ -d "/opt/asn-monitor/dist_package" ]; then
    mv /opt/asn-monitor/dist_package/* /opt/asn-monitor/
    mv /opt/asn-monitor/dist_package/.* /opt/asn-monitor/ 2>/dev/null
    rm -rf /opt/asn-monitor/dist_package
fi

cd /opt/asn-monitor

# 8. GERAÇÃO DO ARQUIVO DE AMBIENTE (.env)
cat <<EOF > .env
TARGET_ASN=$ASN
TARGET_SUBNET=$SUBNET
CLIENT_DOMAIN=$DOMAIN
INTERNAL_DNS=172.18.0.53
ELASTIC_PASSWORD=9R=OOq0t-amCgsVVH=PV
SECRET_KEY=$(openssl rand -hex 24)
DEFAULT_PASS=Mudar@123
EOF

# 9. CERTIFICADO SSL E NGINX
echo -e "${BLUE}[*] Gerando certificado SSL (Let's Encrypt)...${NC}"
certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m $EMAIL

if [ -f "nginx/default.conf.template" ]; then
    envsubst '${DOMAIN}' < nginx/default.conf.template > nginx/default.conf
    chmod -R 755 /etc/letsencrypt/live/
else
    echo -e "${RED}[!] Erro: Template do Nginx não encontrado.${NC}"
    exit 1
fi

# 10. PERMISSÕES E ESTRUTURA DE DADOS
mkdir -p data/{sqlite,es_data}
chmod -R 777 data/
chown root:root filebeat/filebeat.yml && chmod 644 filebeat/filebeat.yml
chown -R 472:472 grafana/ dashboards/

# 11. DEPLOY DOS CONTAINERS
echo -e "${BLUE}[*] Baixando imagens do Docker Hub e iniciando...${NC}"
docker-compose pull -q
docker-compose up -d

# 12. AGUARDAR INICIALIZAÇÃO E FINALIZAR
echo -e "${BLUE}[*] Aguardando o banco de dados estabilizar...${NC}"
# Espera o Elasticsearch responder (timeout de 120s)
MAX_RETRIES=40
COUNT=0
until curl -s -u elastic:9R=OOq0t-amCgsVVH=PV http://localhost:9200 > /dev/null; do
    echo -ne "."
    sleep 3
    COUNT=$((COUNT+1))
    if [ $COUNT -ge $MAX_RETRIES ]; then
        echo -e "${RED}\n[!] Erro: O banco demorou demais para iniciar.${NC}"
        break
    fi
done
echo -e "${GREEN} OK!${NC}"

echo -e "${BLUE}[*] Inicializando tabelas e usuário mestre...${NC}"
docker exec -it asn-reputation python3 -c "import sys; sys.path.append('/app/reputation'); from core.database import init_db; init_db()"

echo -e "${BLUE}[*] Aplicando templates forenses...${NC}"
curl -s -u elastic:9R=OOq0t-amCgsVVH=PV -X PUT "http://localhost:9200/_ilm/policy/forensics_policy" -H 'Content-Type: application/json' --data-binary @elastic_setup/ilm_policies.json > /dev/null
curl -s -u elastic:9R=OOq0t-amCgsVVH=PV -X PUT "http://localhost:9200/_index_template/forensics_template" -H 'Content-Type: application/json' --data-binary @index_templates.json > /dev/null

echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}   INSTALAÇÃO CONCLUÍDA COM SUCESSO!                      ${NC}"
echo -e "${BLUE}   ACESSO:   ${YELLOW}https://$DOMAIN${NC}"
echo -e "${BLUE}   LOGIN:    admin${NC}"
echo -e "${BLUE}   SENHA:    Mudar@123${NC}"
echo -e "${GREEN}==========================================================${NC}"
