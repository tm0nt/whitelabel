#!/bin/bash

# Funções de utilidade
check_command() {
        if ! command -v $1 &> /dev/null; then
                echo "Erro: $1 não está instalado. Instalando..."
                return 1
        fi
        return 0
}

# Verificar se é root
if [ "$(id -u)" -ne 0 ]; then
        echo "Por favor, execute como root ou com sudo"
        exit 1
fi

# Configurações
WORKDIR="/var/whitelabel"
REPO_URL="https://github.com/tm0nt/whitelabel"
ufw allow 1515
ufw allow 1696
ufw allow 1322
ufw allow 1313
ufw allow 81
ufw allow 5555
ufw allow 5432
# 1. Configurar ambiente
echo "Configurando ambiente em $WORKDIR..."
mkdir -p "$WORKDIR"

# 2. Criar .env se não existir
if [ ! -f "$WORKDIR/.env" ]; then
        echo "Criando arquivo .env padrão..."
        cat > "$WORKDIR/.env" <<EOL
# PostgreSQL
POSTGRESQL_USER=brx
POSTGRESQL_PASSWORD=Qw3RtY77$
POSTGRESQL_DB=trading
DATABASE_URL=postgresql://brx:Qw3RtY77\$@localhost:5432/trading?schema=public

# Portas
PORT_ADMIN=1313
PORT_TRADING=1515
PORT_AFILIADOS=1696
PORT_IMAGES=1322

# Admin
ADMIN_EMAIL=admin@bincebroker.com
ADMIN_PASSWORD=flamengo10
EOL
        chmod 600 "$WORKDIR/.env"
fi

source "$WORKDIR/.env"

# 3. Instalar dependências
echo "Instalando dependências..."
apt-get update
apt-get install -y \
        unzip \
        curl \
        wget \
        ca-certificates \
        gnupg \
        lsb-release \
        apt-transport-https \
        software-properties-common \
        git

# 4. Instalar Docker
if ! check_command docker; then
        echo "Instalando Docker..."
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update
        apt-get install -y \
                docker-ce \
                docker-ce-cli \
                containerd.io \
                docker-buildx-plugin \
                docker-compose-plugin

        ln -s /usr/libexec/docker/cli-plugins/docker-compose /usr/bin/docker-compose
        systemctl enable docker
        systemctl start docker
fi

# 5. Instalar Node.js e ferramentas
if ! check_command node; then
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
        apt-get install -y nodejs
fi

if ! check_command pm2; then
        npm install -g pm2
fi

if ! check_command pnpm; then
        npm install -g pnpm
fi

# 6. Clonar repositório
if [ -d "$WORKDIR" ]; then
        if [ -d "$WORKDIR/.git" ]; then
                echo "Diretório $WORKDIR já é um repositório git. Atualizando..."
                git -C "$WORKDIR" pull || {
                        echo "❌ Falha ao atualizar o repositório"
                        exit 1
                }
        else
                echo "⚠️ Diretório $WORKDIR existe mas não é um repositório Git. Removendo..."
                rm -rf "$WORKDIR" || {
                        echo "❌ Falha ao remover $WORKDIR"
                        exit 1
                }
        fi
fi

# Garantir que não estamos dentro do WORKDIR (muda para /tmp)
cd /tmp || exit 1

echo "Clonando repositório..."
git clone "$REPO_URL" "$WORKDIR" || {
        echo "❌ Falha ao clonar repositório do GitHub. Abortando."
        exit 1
}

# 7. Extrair whitelabel.zip (se existir)
if [ -f "$WORKDIR/whitelabel.zip" ]; then
        echo "Extraindo whitelabel.zip..."
        unzip -P "$POSTGRESQL_PASSWORD" "$WORKDIR/whitelabel.zip" -d "$WORKDIR" || {
                echo "Falha ao extrair whitelabel.zip"
                exit 1
        }
fi

# 8. Configurar PostgreSQL
echo "Configurando PostgreSQL..."
cat > "$WORKDIR/docker-compose-postgres.yml" <<EOL
version: '3.8'

services:
  postgres:
    image: postgres:15
    container_name: postgres_whitelabel
    environment:
      POSTGRES_USER: ${POSTGRESQL_USER}
      POSTGRES_PASSWORD: ${POSTGRESQL_PASSWORD}
      POSTGRES_DB: ${POSTGRESQL_DB}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    restart: always

volumes:
  postgres_data:
EOL

docker-compose -f "$WORKDIR/docker-compose-postgres.yml" up -d

# 9. Executar seed
echo "Aguardando PostgreSQL iniciar..."
sleep 15

if [ -d "$WORKDIR/trading/prisma" ]; then
        echo "Executando seed..."
        cd "$WORKDIR/trading" || exit 1
        pnpm install
        npx prisma migrate deploy
        npx prisma db seed || {
                echo "Falha ao executar seed"
                exit 1
        }
        cd "$WORKDIR" || exit 1
else
        echo "Diretório prisma não encontrado em trading/"
        exit 1
fi

# 10. Iniciar aplicações
APPS=("admin" "trading" "afiliados" "images")

for app in "${APPS[@]}"; do
        if [ -d "$WORKDIR/$app" ]; then
                echo "Iniciando $app..."
                cd "$WORKDIR/$app" || exit 1
                pnpm install

                if [ "$app" != "images" ]; then
                        pnpm install @prisma/client
                        npx prisma generate
                        pnpm build
                fi

                PORT_VAR="PORT_${app^^}"
                PORT=${!PORT_VAR}
                export PORT=$PORT

                pm2 start "pnpm start" --name "$app"
                cd "$WORKDIR" || exit 1
        else
                echo "Diretório $app não encontrado"
                exit 1
        fi
done

# 11. Configurar Nginx Proxy Manager
echo "Configurando Nginx Proxy Manager..."
cat > "$WORKDIR/docker-compose-nginx.yml" <<EOL
version: '3.8'

services:
  app:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy-manager
    restart: always
    ports:
      - '80:80'
      - '81:81'
      - '443:443'
    volumes:
      - $WORKDIR/nginx-data:/data
      - $WORKDIR/letsencrypt:/etc/letsencrypt
EOL

docker-compose -f "$WORKDIR/docker-compose-nginx.yml" up -d

# 12. Configurar PM2
pm2 save
pm2 startup | bash

# Obter IP externo
IP_EXTERNO=$(curl -s ifconfig.me || curl -s icanhazip.com || echo "seu-ip")

echo "============================================"
echo "Configuração completa!"
echo "--------------------------------------------"
echo "Acesse:"
echo "- Nginx Proxy Manager: http://${IP_EXTERNO}:81"
echo "- Admin: http://${IP_EXTERNO}:${PORT_ADMIN}"
echo "- Trading: http://${IP_EXTERNO}:${PORT_TRADING}"
echo "- Images: http://${IP_EXTERNO}:${PORT_IMAGES}"
echo "- Afiliados: http://${IP_EXTERNO}:${PORT_AFILIADOS}"

echo "--------------------------------------------"
echo "Credenciais:"
echo "- Nginx Proxy Manager: admin@example.com / changeme"
echo "- Admin: admin@bincebroker.com / Qw3RtY77$"
echo "============================================"

