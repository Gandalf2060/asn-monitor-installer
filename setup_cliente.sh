#!/bin/bash
# ==============================================================================
#   ASN MONITOR PRO - INSTALADOR v6.0 (UNIVERSAL DISTRIBUTION EDITION)
#   Suporte: Ubuntu 20.04 / 22.04 / 24.04
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- CONFIGURAÇÃO DO SEU MIRROR (TROQUE PELO IP DO SEU SERVIDOR MESTRE) ---
MIRROR_URL="http://179.42.68.135:8080/asn_monitor_PRO_v1.zip"
INSTALL_DIR="/opt/asn-monitor"

clear
echo -e "${BLUE}==========================================================${NC}"
echo -e "${GREEN}          INSTALADOR AUTOMÁTICO ASN MONITOR PRO           ${NC}"
echo -e "${BLUE}==========================================================${NC}"

# 1. VALIDAÇÃO DE ROOT
[[ $EUID -ne 0 ]] && { echo -e "${RED}[!] Erro: Execute como root.${NC}"; exit 1; }

# 2. COLETA DE DADOS INICIAL
echo -e "${YELLOW}>>> Definições do Cliente:${NC}"
read -p "   Domínio de Acesso (ex: monitor.cliente.com.br): " DOMAIN
read -p "   Número do ASN: " ASN
read -p "   Bloco de IP: " SUBNET
read -p "   Email para SSL: " EMAIL
echo -e ""
read -p "   Usuário Docker Hub: " DUSER
read -s -p "   Personal Access Token: " DPASS
echo -e "\n"

# 3. INSTALAÇÃO DO DOCKER (MÉTODO ROBUSTO ANTI-ERROS)
echo -e "${BLUE}[*] Instalando/Reparando Docker Engine...${NC}"
# Remove versões problemáticas do Ubuntu
apt-get remove docker docker-engine docker.io containerd runc -y 2>/dev/null
# Script oficial da Docker Inc (Resolve 100% das dependências)
curl -fsSL https://get.docker.com | sh
apt-get install -y docker-compose-plugin gettext-base certbot unzip curl -qq
systemctl enable docker --now

# 4. AUTENTICAÇÃO NO DOCKER HUB
echo -e "${BLUE}[*] Autenticando no repositório privado...${NC}"
echo "$DPASS" | docker login -u "$DUSER" --password-stdin

# 5. OTIMIZAÇÃO DO KERNEL
sysctl -w vm.max_map_count=262144 > /dev/null
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# 6. DOWNLOAD E EXTRAÇÃO
echo -e "${BLUE}[*] Baixando pacote do sistema via Mirror...${NC}"
wget -q --show-progress "$MIRROR_URL" -O /tmp/asn_package.zip

if [ ! -s /tmp/asn_package.zip ]; then
    echo -e "${RED}[!] Erro: Falha ao baixar o pacote. Verifique o link do Mirror.${NC}"
    exit 1
fi

echo -e "${BLUE}[*] Organizando arquivos...${NC}"
rm -rf "$INSTALL_DIR" && mkdir -p "$INSTALL_DIR"
unzip -qo /tmp/asn_package.zip -d /tmp/asn_extract

# Move os arquivos independente da estrutura do zip
if [ -d "/tmp/asn_extract/dist_package" ]; then
    cp -r /tmp/asn_extract/dist_package/* "$INSTALL_DIR/"
else
    cp -r /tmp/asn_extract/* "$INSTALL_DIR/"
fi
rm -rf /tmp/asn_extract /tmp/asn_package.zip
cd "$INSTALL_DIR"

# 7. AJUSTES DINÂMICOS
echo -e "${BLUE}[*] Injetando configurações de performance...${NC}"
# Troca o usuário do docker-compose pelo seu
sed -i "s/seu-usuario/$DUSER/g" docker-compose.yml
# Troca memória do Elastic para 2GB (Essencial para boot rápido)
sed -i "s/-Xms4g -Xmx4g/-Xms2g -Xmx2g/g" docker-compose.yml

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

# 9. SSL E NGINX
echo -e "${BLUE}[*] Configurando SSL (Let's Encrypt)...${NC}"
# Limpa porta 80 para o certbot
fuser -k 80/tcp 443/tcp 2>/dev/null
certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --expand
envsubst '${DOMAIN}' < nginx/default.conf.template > nginx/default.conf

# 10. PERMISSÕES
mkdir -p data/{sqlite,es_data}
chmod -R 777 data/
chown -R 472:472 grafana/ dashboards/ 2>/dev/null

# 11. DEPLOY FINAL
echo -e "${BLUE}[*] Iniciando containers...${NC}"
docker compose pull -q
docker compose up -d

# 12. AGUARDAR E FINALIZAR (Healthcheck)
echo -e "${BLUE}[*] Aguardando Elasticsearch responder...${NC}"
for i in {1..30}; do
    if curl -s -u elastic:9R=OOq0t-amCgsVVH=PV http://localhost:9200 > /dev/null; do
        echo -e "${GREEN} OK!${NC}"
        break
    fi
    echo -ne "."
    sleep 5
done

echo -e "${BLUE}[*] Inicializando banco de dados...${NC}"
docker exec -it asn-reputation python3 -c "import sys; sys.path.append('/app/reputation'); from core.database import init_db; init_db()"

echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}   INSTALAÇÃO CONCLUÍDA COM SUCESSO!                      ${NC}"
echo -e "${BLUE}   ACESSO:   ${YELLOW}https://$DOMAIN${NC}"
echo -e "${BLUE}   USUÁRIO:  admin / SENHA: Mudar@123${NC}"
echo -e "${GREEN}==========================================================${NC}"
