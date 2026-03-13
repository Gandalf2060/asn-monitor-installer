#!/bin/bash
# ==============================================================================
#   ASN MONITOR PRO - INSTALADOR v3.5 (ULTIMATE STABILITY)
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Substitua pelo IP real do seu servidor de arquivos
DOWNLOAD_URL="http://IP_DO_SEU_SERVIDOR:8080/asn_monitor_PRO_v1.zip"

clear
echo -e "${BLUE}==========================================================${NC}"
echo -e "${GREEN}          INSTALADOR AUTOMÁTICO ASN MONITOR PRO           ${NC}"
echo -e "${BLUE}==========================================================${NC}"

# 1. VALIDAÇÃO DE ROOT E AMBIENTE
[[ $EUID -ne 0 ]] && { echo -e "${RED}[!] Erro: Execute como root.${NC}"; exit 1; }

# 2. COLETA DE DADOS
read -p "   Domínio de Acesso: " DOMAIN
read -p "   Número do ASN: " ASN
read -p "   Bloco de IP: " SUBNET
read -p "   Email para SSL: " EMAIL
echo -e ""
read -p "   Usuário Docker Hub (ID): " DUSER
read -s -p "   Personal Access Token: " DPASS
echo -e ""

# 3. LIMPEZA DE PORTAS E INSTALAÇÃO DE DEPENDÊNCIAS
echo -e "${BLUE}[*] Preparando ambiente e limpando porta 80...${NC}"
systemctl stop nginx 2>/dev/null
systemctl disable nginx 2>/dev/null
fuser -k 80/tcp 2>/dev/null

apt update -qq
apt install -y docker.io docker-compose certbot curl wget unzip gettext-base -qq
systemctl enable docker --now

# 4. LOGIN DOCKER HUB
echo "$DPASS" | docker login -u "$DUSER" --password-stdin

# 5. OTIMIZAÇÃO DE KERNEL (CRÍTICO PARA ELASTIC)
sysctl -w vm.max_map_count=262144 > /dev/null
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# 6. DOWNLOAD E EXTRAÇÃO (ROBUSTA)
echo -e "${BLUE}[*] Baixando pacote do sistema...${NC}"
wget -q --show-progress "$DOWNLOAD_URL" -O /tmp/asn_package.zip

echo -e "${BLUE}[*] Extraindo e limpando diretórios antigos...${NC}"
rm -rf /opt/asn-monitor
mkdir -p /opt/asn-monitor
unzip -qo /tmp/asn_package.zip -d /tmp/asn_extract

# Move os arquivos para o local correto independente da estrutura do ZIP
if [ -d "/tmp/asn_extract/dist_package" ]; then
    cp -r /tmp/asn_extract/dist_package/* /opt/asn-monitor/
else
    cp -r /tmp/asn_extract/* /opt/asn-monitor/
fi
rm -rf /tmp/asn_extract /tmp/asn_package.zip
cd /opt/asn-monitor

# 7. AJUSTES DINÂMICOS NO DOCKER-COMPOSE (MEMÓRIA E USUÁRIO)
# Ajustamos o Elastic para 2GB para o boot ser rápido e estável
sed -i "s/seu-usuario/$DUSER/g" docker-compose.yml
sed -i "s/-Xms4g -Xmx4g/-Xms2g -Xmx2g/g" docker-compose.yml

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

# 9. SSL
echo -e "${BLUE}[*] Configurando Certificado SSL...${NC}"
certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m $EMAIL --expand
envsubst '${DOMAIN}' < nginx/default.conf.template > nginx/default.conf

# 10. PERMISSÕES
mkdir -p data/{sqlite,es_data}
chmod -R 777 data/
chown -R 472:472 grafana/ dashboards/ 2>/dev/null

# 11. DEPLOY
echo -e "${BLUE}[*] Iniciando containers...${NC}"
docker-compose pull -q
docker-compose up -d

# 12. HEALTHCHECK DO ELASTICSEARCH (REVISADO)
echo -e "${BLUE}[*] Aguardando Elasticsearch responder... (Aprox. 60s)${NC}"
for i in {1..30}; do
    if curl -s -u elastic:9R=OOq0t-amCgsVVH=PV http://localhost:9200 > /dev/null; then
        echo -e "${GREEN} OK!${NC}"
        break
    fi
    echo -ne "."
    sleep 5
    if [ $i -eq 30 ]; then
        echo -e "${RED} Timeout! Verifique os logs com 'docker logs asn-elastic'${NC}"
    fi
done

# 13. INICIALIZAÇÃO DO BANCO E POLÍTICAS
echo -e "${BLUE}[*] Finalizando configurações internas...${NC}"
docker exec -it asn-reputation python3 -c "import sys; sys.path.append('/app/reputation'); from core.database import init_db; init_db()"
curl -s -u elastic:9R=OOq0t-amCgsVVH=PV -X PUT "http://localhost:9200/_ilm/policy/forensics_policy" -H 'Content-Type: application/json' --data-binary @elastic_setup/ilm_policies.json > /dev/null
curl -s -u elastic:9R=OOq0t-amCgsVVH=PV -X PUT "http://localhost:9200/_index_template/forensics_template" -H 'Content-Type: application/json' --data-binary @index_templates.json > /dev/null

echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}   INSTALAÇÃO FINALIZADA COM SUCESSO!                     ${NC}"
echo -e "${BLUE}   URL: https://$DOMAIN                                   ${NC}"
echo -e "${GREEN}==========================================================${NC}"
