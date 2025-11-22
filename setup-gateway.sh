#!/bin/bash

set -e

echo "🚀 Начало установки Traefik API Gateway"
echo "=========================================="

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Функция для логирования
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Этот скрипт должен запускаться с правами root"
    fi
}

# Ввод переменных
setup_variables() {
    log "Настройка параметров API Gateway"
    
    read -p "Введите доменное имя (example.com): " DOMAIN
    DOMAIN=${DOMAIN:-example.com}
    
    read -p "Введите email для Let's Encrypt: " EMAIL
    EMAIL=${EMAIL:-admin@$DOMAIN}
    
    read -p "Введите OpenAI API Key: " OPENAI_API_KEY
    if [[ -z "$OPENAI_API_KEY" ]]; then
        error "OpenAI API Key обязателен для работы"
    fi
    
    read -p "Введите логин для базовой аутентификации [admin]: " USERNAME
    USERNAME=${USERNAME:-admin}
    
    read -s -p "Введите пароль для базовой аутентификации: " PASSWORD
    echo
    if [[ -z "$PASSWORD" ]]; then
        error "Пароль не может быть пустым"
    fi
    
    # Генерация хеша пароля для basic auth
    BASIC_AUTH_HASH=$(echo $(htpasswd -nb $USERNAME $PASSWORD) | sed -e s/\\$/\\$\\$/g)
    
    # Генерация случайного API ключа для n8n
    N8N_API_KEY=$(openssl rand -hex 32)
    
    log "Параметры успешно настроены"
}

# Установка зависимостей
install_dependencies() {
    log "Установка системных зависимостей..."
    
    apt-get update
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        apache2-utils \
        openssl
    
    # Установка Docker
    if ! command -v docker &> /dev/null; then
        log "Установка Docker..."
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io
    fi
    
    # Установка Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        log "Установка Docker Compose..."
        curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
    
    # Включение и запуск Docker
    systemctl enable docker
    systemctl start docker
}

# Создание структуры директорий
create_directory_structure() {
    log "Создание структуры директорий..."
    
    mkdir -p /opt/api-gateway/{traefik/dynamic,services/openai-proxy,logs}
    cd /opt/api-gateway
}

# Создание конфигурационных файлов
create_config_files() {
    log "Создание конфигурационных файлов..."
    
    # Файл окружения
    cat > /opt/api-gateway/.env << EOF
# Domain Configuration
DOMAIN=$DOMAIN
EMAIL=$EMAIL

# API Keys
OPENAI_API_KEY=$OPENAI_API_KEY
N8N_API_KEY=$N8N_API_KEY

# Basic Authentication
BASIC_AUTH=$BASIC_AUTH_HASH
EOF

    # Основной конфиг Traefik
    cat > /opt/api-gateway/traefik/traefik.yml << 'EOF'
api:
  dashboard: true
  debug: false

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
  file:
    directory: "/etc/traefik/dynamic"
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: "${EMAIL}"
      storage: "/etc/traefik/acme.json"
      httpChallenge:
        entryPoint: web
EOF

    # Динамическая конфигурация
    cat > /opt/api-gateway/traefik/dynamic/middlewares.yml << 'EOF'
http:
  middlewares:
    # Базовая аутентификация
    auth-middleware:
      basicAuth:
        users:
          - "${BASIC_AUTH}"
    
    # Лимит запросов
    rate-limit-middleware:
      rateLimit:
        burst: 100
        period: 1m
    
    # Добавление заголовков для OpenAI
    openai-headers:
      headers:
        customRequestHeaders:
          Authorization: "Bearer ${OPENAI_API_KEY}"
        customResponseHeaders:
          X-Gateway: "traefik-proxy"
    
    # Безопасные заголовки
    security-headers:
      headers:
        frameDeny: true
        sslRedirect: true
        browserXssFilter: true
        contentTypeNosniff: true
        forceSTSHeader: true
        stsIncludeSubdomains: true
        stsPreload: true
        stsSeconds: 31536000

  routers:
    # OpenAI API
    openai-router:
      entryPoints:
        - websecure
      rule: "Host(`${DOMAIN}`) && PathPrefix(`/openai/`)"
      service: openai-service
      middlewares:
        - auth-middleware
        - rate-limit-middleware
        - openai-headers
        - security-headers
      tls:
        certResolver: letsencrypt
    
    # Dashboard Traefik
    traefik-dashboard:
      entryPoints:
        - websecure
      rule: "Host(`${DOMAIN}`) && (PathPrefix(`/api`) || PathPrefix(`/dashboard`))"
      service: api@internal
      middlewares:
        - auth-middleware
        - security-headers
      tls:
        certResolver: letsencrypt

  services:
    openai-service:
      loadBalancer:
        servers:
          - url: "https://api.openai.com"
EOF

    # Docker Compose
    cat > /opt/api-gateway/docker-compose.yml << 'EOF'
version: '3.8'

services:
  traefik:
    image: traefik:v2.10
    container_name: traefik-gateway
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - proxy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./traefik/dynamic:/etc/traefik/dynamic:ro
      - ./traefik/acme.json:/etc/traefik/acme.json
      - ./logs:/var/log/traefik
    environment:
      - OPENAI_API_KEY=${OPENAI_API_KEY}
      - DOMAIN=${DOMAIN}
      - EMAIL=${EMAIL}
      - BASIC_AUTH=${BASIC_AUTH}
    labels:
      - "traefik.enable=true"
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

networks:
  proxy:
    name: proxy
EOF

    # Дополнительный кастомный прокси (опционально)
    cat > /opt/api-gateway/services/openai-proxy/docker-compose.yml << 'EOF'
version: '3.8'

services:
  openai-proxy:
    image: node:18-alpine
    container_name: openai-proxy
    restart: unless-stopped
    working_dir: /app
    volumes:
      - ./:/app
    networks:
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.openai-custom.rule=Host(`${DOMAIN}`) && PathPrefix(`/v1/`)"
      - "traefik.http.routers.openai-custom.tls=true"
      - "traefik.http.routers.openai-custom.tls.certresolver=letsencrypt"
      - "traefik.http.routers.openai-custom.middlewares=auth-middleware@file"
      - "traefik.http.services.openai-custom.loadbalancer.server.port=3000"
    environment:
      - OPENAI_API_KEY=${OPENAI_API_KEY}
    
networks:
  proxy:
    external: true
    name: proxy
EOF

    # Простой Node.js прокси
    cat > /opt/api-gateway/services/openai-proxy/package.json << 'EOF'
{
  "name": "openai-proxy",
  "version": "1.0.0",
  "description": "Custom OpenAI proxy",
  "main": "index.js",
  "scripts": {
    "start": "node index.js"
  },
  "dependencies": {
    "express": "^4.18.0",
    "http-proxy-middleware": "^2.0.0"
  }
}
EOF

    cat > /opt/api-gateway/services/openai-proxy/index.js << 'EOF'
const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');

const app = express();
app.use(express.json());

// Логирование
app.use((req, res, next) => {
  console.log(`${new Date().toISOString()} - ${req.method} ${req.path}`);
  next();
});

// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'openai-proxy' });
});

// Прокси для OpenAI
app.use('/', createProxyMiddleware({
  target: 'https://api.openai.com',
  changeOrigin: true,
  onProxyReq: (proxyReq, req, res) => {
    proxyReq.setHeader('Authorization', `Bearer ${process.env.OPENAI_API_KEY}`);
  },
  onError: (err, req, res) => {
    console.error('Proxy error:', err);
    res.status(500).json({ error: 'Gateway error' });
  }
}));

const PORT = process.env.PORT || 3000;
app.listen(PORT, '0.0.0.0', () => {
  console.log(`OpenAI proxy running on port ${PORT}`);
});
EOF
}

# Создание systemd сервиса
create_systemd_service() {
    log "Создание systemd сервиса..."
    
    cat > /etc/systemd/system/api-gateway.service << EOF
[Unit]
Description=API Gateway with Traefik
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/api-gateway
ExecStart=/usr/local/bin/docker-compose up -d
ExecStop=/usr/local/bin/docker-compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable api-gateway.service
}

# Запуск сервисов
start_services() {
    log "Запуск API Gateway..."
    
    # Создаем acme.json с правильными правами
    touch /opt/api-gateway/traefik/acme.json
    chmod 600 /opt/api-gateway/traefik/acme.json
    
    # Запускаем сервисы
    cd /opt/api-gateway
    docker-compose up -d
    
    # Ждем запуска
    sleep 10
    
    # Проверяем статус
    if docker-compose ps | grep -q "Up"; then
        log "Сервисы успешно запущены"
    else
        error "Ошибка при запуске сервисов"
    fi
}

# Показ информации о установке
show_installation_info() {
    log "Установка завершена успешно!"
    echo
    echo "📊 Информация для подключения:"
    echo "================================"
    echo "Dashboard Traefik: https://$DOMAIN/dashboard/"
    echo "OpenAI Endpoint:  https://$DOMAIN/openai/v1/chat/completions"
    echo
    echo "🔐 Данные аутентификации:"
    echo "Логин: $USERNAME"
    echo "Пароль: [скрыт]"
    echo "API Key для n8n: $N8N_API_KEY"
    echo
    echo "⚙️ Команды управления:"
    echo "Просмотр логов:    cd /opt/api-gateway && docker-compose logs -f"
    echo "Остановка:         systemctl stop api-gateway"
    echo "Запуск:            systemctl start api-gateway"
    echo "Статус:            systemctl status api-gateway"
    echo
    echo "📝 Пример для n8n HTTP Request:"
    echo "URL: https://$DOMAIN/openai/v1/chat/completions"
    echo "Headers:"
    echo "  Authorization: Basic $(echo -n "$USERNAME:$PASSWORD" | base64)"
    echo "  Content-Type: application/json"
    echo
    warn "Не забудьте настроить DNS запись для домена $DOMAIN на IP этого сервера!"
}

# Основная функция
main() {
    check_root
    setup_variables
    install_dependencies
    create_directory_structure
    create_config_files
    create_systemd_service
    start_services
    show_installation_info
}

# Запуск скрипта
main "$@"