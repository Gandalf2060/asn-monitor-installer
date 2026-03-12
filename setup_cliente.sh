#!/bin/bash
# ==============================================================================
#   ASN MONITOR PRO - INSTALADOR AUTOMÁTICO v3.0 (PRIVATE MIRROR EDITION)
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# CONFIGURAÇÃO DO SEU SERVIDOR DE DOWNLOAD
# Substitua pelo IP do servidor onde você rodou o Passo 1
DOWNLOAD_URL="http://179.42.68.135:8080/asn_monitor_PRO_v1.zip"

clear
echo -e "${BLUE}==========================================================${NC}"
echo -e "${GREEN}          INSTALADOR AUTOMÁTICO ASN MONITOR PRO           ${NC}"
echo -e "${BLUE}==========================================================${NC}"

# 1. VALIDAÇÃO DE ROOT
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[!] Erro: Execute como root (sudo).${NC}"
   exit 1
fi

# 2. COLETA DE INFORMAÇÕES
echo -e "${YELLOW}>>> Definições do Provedor:${NC}"
read -p "   Domínio de Acesso (ex: monitor.cliente.com.br): " DOMAIN
read -p "   Número do ASN: " ASN
read -p "   Bloco de IP: " SUBNET
read -p "   Email para SSL: " EMAIL
echo -e ""
echo -e "${YELLOW}>>> Credenciais Docker Hub (Privado):${NC}"
read -p "   Usuário Docker Hub (ID): " DUSER
read -s -p "   Personal Access Token: " DPASS
echo -e "\n${BLUE}----------------------------------------------------------${NC}"

# 3. INSTALAÇÃO DE DEPENDÊNCIAS (MÉTODO OFICIAL DOCKER)
echo -e "${BLUE}[*] Instalando Docker Engine e Compose V2...${NC}"
apt update -qq
apt install -y ca-certificates curl gnupg lsb-release gettext-base certbot unzip -qq

# Adiciona a chave oficial do Docker
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg

# Configura o repositório estável
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update -qq
# Instala o Docker e o Plugin do Compose V2 (docker-compose-plugin)
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin -qq

systemctl enable docker --now

# 4. AUTENTICAÇÃO DOCKER HUB
echo -e "${BLUE}[*] Autenticando no Docker Hub...${NC}"
echo "$DPASS" | docker login -u "$DUSER" --password-stdin
if [ $? -ne 0 ]; then
    echo -e "${RED}[!] Erro: Falha no login do Docker Hub. Verifique seu Token.${NC}"
    exit 1
fi

# 5. OTIMIZAÇÕES DE KERNEL
sysctl -w vm.max_map_count=262144 > /dev/null
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# 6. DOWNLOAD DO PACOTE VIA LINK DIRETO
echo -e "${BLUE}[*] Baixando pacote do servidor privado...${NC}"
wget -q --show-progress "$DOWNLOAD_URL" -O /tmp/asn_package.zip

if [ ! -s /tmp/asn_package.zip ]; then
    echo -e "${RED}[!] Erro: Falha ao baixar o pacote. Verifique se o servidor de download está online.${NC}"
    exit 1
fi

# 7. EXTRAÇÃO
echo -e "${BLUE}[*] Extraindo e organizando arquivos...${NC}"
rm -rf /opt/asn-monitor && mkdir -p /opt/asn-monitor
unzip -qo /tmp/asn_package.zip -d /opt/asn-monitor/

# Normaliza se houver pasta interna 'dist_package'
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

# 9. CERTIFICADO SSL E NGINX
echo -e "${BLUE}[*] Configurando SSL e Servidor Web...${NC}"
certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m $EMAIL --expand

if [ -f "nginx/default.conf.template" ]; then
    envsubst '${DOMAIN}' < nginx/default.conf.template > nginx/default.conf
    chmod -R 755 /etc/letsencrypt/live/
else
    echo -e "${RED}[!] Erro Crítico: Arquivo template não encontrado após extração.${NC}"
    exit 1
fi

# 10. PERMISSÕES E ESTRUTURA
mkdir -p data/{sqlite,es_data}
chmod -R 777 data/
[ -f "filebeat/filebeat.yml" ] && chown root:root filebeat/filebeat.yml && chmod 644 filebeat/filebeat.yml
chown -R 472:472 grafana/ dashboards/ 2>/dev/null

# 11. DEPLOY (Ajustado para o comando novo sem hífen)
echo -e "${BLUE}[*] Iniciando containers...${NC}"
docker compose pull -q
docker compose up -d

# 12. FINALIZAÇÃO
echo -e "${BLUE}[*] Aguardando Elasticsearch...${NC}"
until curl -s -u elastic:9R=OOq0t-amCgsVVH=PV http://localhost:9200 > /dev/null; do
    echo -ne "."
    sleep 3
done

echo -e "${BLUE}[*] Inicializando banco e aplicando templates...${NC}"
docker exec -it asn-reputation python3 -c "import sys; sys.path.append('/app/reputation'); from core.database import init_db; init_db()"
curl -s -u elastic:9R=OOq0t-amCgsVVH=PV -X PUT "http://localhost:9200/_ilm/policy/forensics_policy" -H 'Content-Type: application/json' --data-binary @elastic_setup/ilm_policies.json > /dev/null
curl -s -u elastic:9R=OOq0t-amCgsVVH=PV -X PUT "http://localhost:9200/_index_template/forensics_template" -H 'Content-Type: application/json' --data-binary @index_templates.json > /dev/null

echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}   INSTALAÇÃO CONCLUÍDA COM SUCESSO!                      ${NC}"
echo -e "${BLUE}   ACESSO:   ${YELLOW}https://$DOMAIN${NC}"
echo -e "${GREEN}==========================================================${NC}"
