#!/usr/bin/env bash
# ==============================================================================
# install/install_zabbix.sh
# Automated, Idempotent Installer for Zabbix 8.0 LTS with PostgreSQL on Debian 13 (Trixie)
#
# Target OS: Debian GNU/Linux 13 (Trixie) - x86_64 / arm64
# Components: Zabbix Server 8.0, PostgreSQL 17, Zabbix Agent 2, Zabbix Frontend (PHP-FPM + Nginx)
# Documentation: https://www.zabbix.com/documentation/devel/en/manual
# ==============================================================================

set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()    { echo -e "\n${BOLD}${BLUE}===> $1${NC}"; }

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be executed with root privileges. Run with 'sudo bash $0'."
    exit 1
fi

# ------------------------------------------------------------------------------
# Configuration Variables
# ------------------------------------------------------------------------------
ZABBIX_DB_NAME="${ZABBIX_DB_NAME:-zabbix}"
ZABBIX_DB_USER="${ZABBIX_DB_USER:-zabbix}"
ZABBIX_DB_PASSWORD="${ZABBIX_DB_PASSWORD:-$(openssl rand -hex 16)}"
ZABBIX_SERVER_PORT="${ZABBIX_SERVER_PORT:-10051}"
ZABBIX_LOCAL_WEB_PORT="${ZABBIX_LOCAL_WEB_PORT:-8080}"
ZABBIX_RELEASE_PKG_URL="https://repo.zabbix.com/zabbix/8.0/release/debian/pool/main/z/zabbix-release/zabbix-release_latest+debian13_all.deb"

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------------------
# 1. OS Verification & Upgrade to Debian 13 (Trixie) if needed
# ------------------------------------------------------------------------------
log_step "1. Checking OS Distribution and Ensuring Debian 13 (Trixie)"

if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
else
    log_error "/etc/os-release not found. Unsupported system."
    exit 1
fi

if [[ "${ID:-}" != "debian" ]]; then
    log_warn "Current distribution is '${ID:-unknown}'. Recommended is Debian 13 (Trixie)."
fi

CURRENT_CODENAME="${VERSION_CODENAME:-bookworm}"
if [[ "$CURRENT_CODENAME" == "bookworm" ]]; then
    log_info "Detected Debian 12 (Bookworm). Upgrading package repositories to Debian 13 (Trixie)..."
    if [[ -f /etc/apt/sources.list ]]; then
        sed -i 's/bookworm/trixie/g' /etc/apt/sources.list
    fi
    if ls /etc/apt/sources.list.d/*.sources >/dev/null 2>&1; then
        sed -i 's/bookworm/trixie/g' /etc/apt/sources.list.d/*.sources
    fi
    if ls /etc/apt/sources.list.d/*.list >/dev/null 2>&1; then
        sed -i 's/bookworm/trixie/g' /etc/apt/sources.list.d/*.list
    fi
    apt-get update -y
    apt-get dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    log_success "System upgraded to Debian 13 (Trixie)."
else
    log_info "Running on Debian '${CURRENT_CODENAME}'."
    apt-get update -y
fi

# ------------------------------------------------------------------------------
# 2. Base Prerequisites & Locale Setup
# ------------------------------------------------------------------------------
log_step "2. Installing Base Prerequisites and Setting Locales"

BASE_PACKAGES=(
    curl
    wget
    gnupg
    ca-certificates
    lsb-release
    sudo
    jq
    openssl
    locales
    tzdata
    iproute2
    net-tools
)

apt-get install -y --no-install-recommends "${BASE_PACKAGES[@]}"

# Zabbix requires UTF-8 locales
if ! grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen; then
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
fi
if ! grep -q "^pl_PL.UTF-8 UTF-8" /etc/locale.gen; then
    echo "pl_PL.UTF-8 UTF-8" >> /etc/locale.gen
fi
locale-gen
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
log_success "Base prerequisites and locales configured."

# ------------------------------------------------------------------------------
# 3. PostgreSQL Installation & Configuration
# ------------------------------------------------------------------------------
log_step "3. Installing and Configuring PostgreSQL Database Server"

apt-get install -y --no-install-recommends postgresql postgresql-contrib

systemctl enable --now postgresql
sleep 2

# Create Zabbix DB user if not present
USER_EXISTS=$(sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${ZABBIX_DB_USER}'" | tr -d '[:space:]')
if [[ "$USER_EXISTS" != "1" ]]; then
    log_info "Creating PostgreSQL role '${ZABBIX_DB_USER}'..."
    sudo -u postgres psql -c "CREATE USER ${ZABBIX_DB_USER} WITH ENCRYPTED PASSWORD '${ZABBIX_DB_PASSWORD}';"
else
    log_info "PostgreSQL role '${ZABBIX_DB_USER}' already exists. Updating password..."
    sudo -u postgres psql -c "ALTER USER ${ZABBIX_DB_USER} WITH ENCRYPTED PASSWORD '${ZABBIX_DB_PASSWORD}';"
fi

# Create Zabbix database if not present
DB_EXISTS=$(sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${ZABBIX_DB_NAME}'" | tr -d '[:space:]')
if [[ "$DB_EXISTS" != "1" ]]; then
    log_info "Creating PostgreSQL database '${ZABBIX_DB_NAME}' with UTF8 encoding..."
    sudo -u postgres psql -c "CREATE DATABASE ${ZABBIX_DB_NAME} OWNER ${ZABBIX_DB_USER} ENCODING 'UTF8';"
else
    log_info "Database '${ZABBIX_DB_NAME}' already exists."
fi
log_success "PostgreSQL server ready."

# ------------------------------------------------------------------------------
# 4. Zabbix 8.0 Repository Setup & Package Installation
# ------------------------------------------------------------------------------
log_step "4. Setting up Zabbix 8.0 Official Repository"

REPO_DEB="/tmp/zabbix-release.deb"
rm -f "$REPO_DEB"
log_info "Downloading Zabbix 8.0 repository package from ${ZABBIX_RELEASE_PKG_URL}..."
wget -qO "$REPO_DEB" "$ZABBIX_RELEASE_PKG_URL"
dpkg -i "$REPO_DEB"
rm -f "$REPO_DEB"

apt-get update -y
log_success "Zabbix 8.0 repository configured."

log_step "5. Installing Zabbix 8.0 Server, Agent 2, and Frontend Components"

ZABBIX_PACKAGES=(
    zabbix-server-pgsql
    zabbix-sql-scripts
    zabbix-agent2
    zabbix-agent2-plugin-postgresql
    zabbix-frontend-php
    zabbix-nginx-conf
    nginx
    php-fpm
)

apt-get install -y --no-install-recommends "${ZABBIX_PACKAGES[@]}"
log_success "Zabbix 8.0 components installed successfully."

# ------------------------------------------------------------------------------
# 6. Database Schema Initialisation
# ------------------------------------------------------------------------------
log_step "6. Initialising Zabbix Database Schema"

SCHEMA_FILE="/usr/share/zabbix/sql-scripts/postgresql/server.sql.gz"
if [[ ! -f "$SCHEMA_FILE" ]]; then
    # Fallback search path in case path varies by package version
    SCHEMA_FILE=$(find /usr/share -type f -name "server.sql.gz" | grep postgresql | head -n1 || true)
fi

if [[ -f "$SCHEMA_FILE" ]]; then
    TABLE_COUNT=$(sudo -u postgres psql -d "${ZABBIX_DB_NAME}" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null || echo "0")
    if [[ "$TABLE_COUNT" -eq 0 ]]; then
        log_info "Importing Zabbix schema from ${SCHEMA_FILE}..."
        # Import as postgres superuser or zabbix user
        zcat "$SCHEMA_FILE" | sudo -u postgres psql -d "${ZABBIX_DB_NAME}" >/dev/null
        # Ensure ownership of all imported tables/sequences to zabbix user
        sudo -u postgres psql -d "${ZABBIX_DB_NAME}" -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${ZABBIX_DB_USER};" >/dev/null
        sudo -u postgres psql -d "${ZABBIX_DB_NAME}" -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${ZABBIX_DB_USER};" >/dev/null
        log_success "Zabbix database schema imported successfully."
    else
        log_info "Database already populated (${TABLE_COUNT} tables found). Skipping schema import."
    fi
else
    log_warn "Schema file not found automatically. Please verify /usr/share/zabbix/sql-scripts/postgresql/."
fi

# ------------------------------------------------------------------------------
# 7. Configuring Zabbix Server (/etc/zabbix/zabbix_server.conf)
# ------------------------------------------------------------------------------
log_step "7. Configuring Zabbix Server Daemon"

SERVER_CONF="/etc/zabbix/zabbix_server.conf"
if [[ -f "$SERVER_CONF" ]]; then
    sed -i "s/^#\? \?DBHost=.*/DBHost=localhost/" "$SERVER_CONF"
    sed -i "s/^#\? \?DBName=.*/DBName=${ZABBIX_DB_NAME}/" "$SERVER_CONF"
    sed -i "s/^#\? \?DBUser=.*/DBUser=${ZABBIX_DB_USER}/" "$SERVER_CONF"
    sed -i "s/^#\? \?DBPassword=.*/DBPassword=${ZABBIX_DB_PASSWORD}/" "$SERVER_CONF"
    sed -i "s/^#\? \?ListenPort=.*/ListenPort=${ZABBIX_SERVER_PORT}/" "$SERVER_CONF"
    log_success "Updated ${SERVER_CONF}."
else
    log_error "${SERVER_CONF} not found!"
fi

# ------------------------------------------------------------------------------
# 8. Configuring Local Web Server (Nginx + PHP-FPM) on Port 8080
# ------------------------------------------------------------------------------
log_step "8. Configuring Local Frontend Web Server (Port ${ZABBIX_LOCAL_WEB_PORT})"

# Configure /etc/zabbix/nginx.conf to listen on ZABBIX_LOCAL_WEB_PORT
ZABBIX_NGINX_CONF="/etc/zabbix/nginx.conf"
if [[ -f "$ZABBIX_NGINX_CONF" ]]; then
    # Enable listen port and generic server_name
    sed -i "s/#\s*listen\s*8080;/listen ${ZABBIX_LOCAL_WEB_PORT};/" "$ZABBIX_NGINX_CONF"
    sed -i "s/#\s*server_name\s*example.com;/server_name _;/" "$ZABBIX_NGINX_CONF"
    
    # Symlink to Nginx configuration directory
    mkdir -p /etc/nginx/conf.d
    ln -sf "$ZABBIX_NGINX_CONF" /etc/nginx/conf.d/zabbix.conf
    
    # Remove default Nginx site to prevent port conflicts on 80
    rm -f /etc/nginx/sites-enabled/default
    log_success "Configured ${ZABBIX_NGINX_CONF} listening on port ${ZABBIX_LOCAL_WEB_PORT}."
fi

# Pre-configure Zabbix GUI configuration file so no setup wizard is needed
mkdir -p /etc/zabbix/web
cat << EOF > /etc/zabbix/web/zabbix.conf.php
<?php
// Zabbix GUI configuration file (auto-generated)
\$DB['TYPE']     = 'POSTGRESQL';
\$DB['SERVER']   = 'localhost';
\$DB['PORT']     = '0';
\$DB['DATABASE'] = '${ZABBIX_DB_NAME}';
\$DB['USER']     = '${ZABBIX_DB_USER}';
\$DB['PASSWORD'] = '${ZABBIX_DB_PASSWORD}';

// Schema name. Used for PostgreSQL.
\$DB['SCHEMA']   = '';

// Encryption
\$DB['ENCRYPTION']  = false;
\$DB['VERIFY_HOST']  = false;
\$DB['KEY_FILE']     = '';
\$DB['CERT_FILE']    = '';
\$DB['CA_FILE']      = '';

\$ZBX_SERVER      = 'localhost';
\$ZBX_SERVER_PORT = '${ZABBIX_SERVER_PORT}';
\$ZBX_SERVER_NAME = 'Zabbix 8.0 Monitoring';

\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
EOF

chown -R www-data:www-data /etc/zabbix/web
chmod 640 /etc/zabbix/web/zabbix.conf.php
log_success "Zabbix web frontend pre-configured at /etc/zabbix/web/zabbix.conf.php."

# ------------------------------------------------------------------------------
# 9. Configure Zabbix Agent 2
# ------------------------------------------------------------------------------
log_step "9. Configuring Zabbix Agent 2"

AGENT_CONF="/etc/zabbix/zabbix_agent2.conf"
if [[ -f "$AGENT_CONF" ]]; then
    sed -i "s/^Server=127.0.0.1/Server=127.0.0.1/" "$AGENT_CONF"
    sed -i "s/^ServerActive=127.0.0.1/ServerActive=127.0.0.1/" "$AGENT_CONF"
    sed -i "s/^Hostname=Zabbix server/Hostname=Zabbix server/" "$AGENT_CONF"
    log_success "Configured ${AGENT_CONF}."
fi

# ------------------------------------------------------------------------------
# 10. Enable and Start Services
# ------------------------------------------------------------------------------
log_step "10. Enabling and Starting Services"

# Detect installed PHP-FPM service name
PHP_FPM_SVC=$(systemctl list-unit-files --type=service 2>/dev/null | grep -oE 'php[0-9.]*-fpm\.service' | head -n1 || echo "php-fpm.service")

systemctl daemon-reload
systemctl enable --now postgresql
systemctl enable --now zabbix-server
systemctl enable --now zabbix-agent2
if systemctl list-unit-files | grep -q "$PHP_FPM_SVC"; then
    systemctl enable --now "$PHP_FPM_SVC"
    systemctl restart "$PHP_FPM_SVC"
fi

if nginx -t >/dev/null 2>&1; then
    systemctl enable --now nginx
    systemctl restart nginx
    log_success "Nginx restarted successfully."
else
    log_warn "Nginx config test returned warnings. Please check 'nginx -t'."
fi

systemctl restart zabbix-server
systemctl restart zabbix-agent2
log_success "All Zabbix 8.0 services enabled and started."

# ------------------------------------------------------------------------------
# 11. Generate External Nginx Reverse Proxy Configuration & Save Credentials
# ------------------------------------------------------------------------------
log_step "11. Generating External Nginx Reverse Proxy Configuration"

CT_IP=$(ip -4 addr show eth0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 || hostname -I | awk '{print $1}')
PROXY_CONF="/etc/zabbix/nginx-external-reverse-proxy.conf"

cat << EOF > "$PROXY_CONF"
# ==============================================================================
# Nginx Reverse Proxy Configuration for Zabbix 8.0 LTS
# Add this configuration to your EXTERNAL Nginx container/server!
# Location on external Nginx container: /etc/nginx/conf.d/zabbix.conf
# ==============================================================================

upstream zabbix_backend {
    # Points to the Zabbix 8.0 LXC container internal web listener:
    server ${CT_IP}:${ZABBIX_LOCAL_WEB_PORT};
    keepalive 32;
}

# Optional WebSocket connection upgrade mapping (put inside http {} or keep here if included in conf.d):
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name zabbix.yourdomain.local; # Replace with your FQDN or IP

    # Set maximum upload size for importing large XML/YAML templates and media
    client_max_body_size 64M;

    # Performance & Proxy Timeouts (tuned for long report generations)
    proxy_connect_timeout 60s;
    proxy_send_timeout    600s;
    proxy_read_timeout    600s;
    send_timeout          600s;

    # Proxy Headers
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # WebSocket support for Zabbix 7/8 live updates and dashboards
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;

    location / {
        proxy_pass http://zabbix_backend;
    }
}

# Optional HTTPS Virtual Host with SSL Termination:
# server {
#     listen 443 ssl http2;
#     server_name zabbix.yourdomain.local;
#
#     ssl_certificate     /etc/ssl/certs/zabbix.crt;
#     ssl_certificate_key /etc/ssl/private/zabbix.key;
#     ssl_protocols       TLSv1.2 TLSv1.3;
#     ssl_ciphers         HIGH:!aNULL:!MD5;
#
#     client_max_body_size 64M;
#     proxy_connect_timeout 60s;
#     proxy_send_timeout    600s;
#     proxy_read_timeout    600s;
#
#     proxy_http_version 1.1;
#     proxy_set_header Connection "";
#     proxy_set_header Host \$host;
#     proxy_set_header X-Real-IP \$remote_addr;
#     proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
#     proxy_set_header X-Forwarded-Proto https;
#     proxy_set_header Upgrade \$http_upgrade;
#     proxy_set_header Connection \$connection_upgrade;
#
#     location / {
#         proxy_pass http://zabbix_backend;
#     }
# }
EOF

CREDS_FILE="/etc/zabbix/zabbix_credentials.txt"
cat << EOF > "$CREDS_FILE"
# Zabbix 8.0 Deployment Credentials & Details
Generated: $(date -u)
Target OS: Debian 13 (Trixie)
Container IP: ${CT_IP}

[Database - PostgreSQL 17]
DB Name:     ${ZABBIX_DB_NAME}
DB User:     ${ZABBIX_DB_USER}
DB Password: ${ZABBIX_DB_PASSWORD}

[Zabbix Server]
Listen Port: ${ZABBIX_SERVER_PORT}

[Web Frontend]
Internal URL: http://${CT_IP}:${ZABBIX_LOCAL_WEB_PORT}
Default Web User:     Admin
Default Web Password: zabbix

[External Nginx Reverse Proxy Config]
Configuration File: ${PROXY_CONF}
Backend Upstream:   http://${CT_IP}:${ZABBIX_LOCAL_WEB_PORT}
EOF

chmod 600 "$CREDS_FILE"
cp "$CREDS_FILE" /root/zabbix_credentials.txt 2>/dev/null || true

log_step "Installation Summary"
echo -e "${GREEN}========================================================================${NC}"
echo -e "${GREEN}  Zabbix 8.0 with PostgreSQL 17 Installed Successfully!                 ${NC}"
echo -e "${GREEN}========================================================================${NC}"
echo -e "Container IP:              ${BLUE}${CT_IP}${NC}"
echo -e "Zabbix Server Port:        ${BLUE}${ZABBIX_SERVER_PORT}${NC}"
echo -e "Internal Web GUI:          ${BLUE}http://${CT_IP}:${ZABBIX_LOCAL_WEB_PORT}${NC}"
echo -e "Default Web Login:         ${YELLOW}Admin${NC} / ${YELLOW}zabbix${NC}"
echo -e "PostgreSQL Database:       ${YELLOW}${ZABBIX_DB_NAME}${NC} (User: ${YELLOW}${ZABBIX_DB_USER}${NC})"
echo -e "Database Password saved:   ${BLUE}${CREDS_FILE}${NC}"
echo -e "\n${BOLD}${YELLOW}--> External Nginx Configuration:${NC}"
echo -e "A reverse proxy configuration for your other Nginx container has been generated at:"
echo -e "${BLUE}${PROXY_CONF}${NC}"
echo -e "Add its contents to ${YELLOW}/etc/nginx/conf.d/zabbix.conf${NC} on your Nginx container."
echo -e "${GREEN}========================================================================${NC}\n"
