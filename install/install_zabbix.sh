#!/usr/bin/env bash
# ==============================================================================
# install/install_zabbix.sh
# Automated, Idempotent Installer for Zabbix LTS with MySQL / MariaDB on Debian
#
# Target OS: Debian GNU/Linux 12 (Bookworm) / 13 (Trixie) - x86_64 / arm64
# Components: Zabbix Server, MySQL (MariaDB), Zabbix Agent 2, Zabbix Frontend (PHP-FPM + Nginx)
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
# Network & DNS Verification Safeguard
# ------------------------------------------------------------------------------
ip link set dev lo up 2>/dev/null || true
ip link set dev eth0 up 2>/dev/null || true

# Ensure working DNS resolution in /etc/resolv.conf
if ! grep -q "^nameserver" /etc/resolv.conf 2>/dev/null; then
    log_warn "Empty /etc/resolv.conf detected! Adding public fallback DNS servers..."
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
fi

# ------------------------------------------------------------------------------
# Configuration Variables
# ------------------------------------------------------------------------------
ZABBIX_DB_NAME="${ZABBIX_DB_NAME:-zabbix}"
ZABBIX_DB_USER="${ZABBIX_DB_USER:-zabbix}"
ZABBIX_DB_PASSWORD="${ZABBIX_DB_PASSWORD:-$(openssl rand -hex 16)}"
ZABBIX_SERVER_PORT="${ZABBIX_SERVER_PORT:-10051}"
ZABBIX_LOCAL_WEB_PORT="${ZABBIX_LOCAL_WEB_PORT:-8080}"
ZABBIX_VERSION="${ZABBIX_VERSION:-7.0}"

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------------------
# 1. OS Verification & Distribution Detection
# ------------------------------------------------------------------------------
log_step "1. Checking OS Distribution and Release"

if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
else
    log_error "/etc/os-release not found. Unsupported system."
    exit 1
fi

CURRENT_CODENAME="${VERSION_CODENAME:-bookworm}"
if [[ "$CURRENT_CODENAME" == "trixie" || "${VERSION_ID:-}" == "13"* ]]; then
    log_info "Running on Debian 13 (Trixie)."
    DEB_VER="13"
else
    log_info "Running on Debian 12 (Bookworm)."
    DEB_VER="12"
fi

# Configure Zabbix repository URL (supports Debian 12/13 with fallback)
ZABBIX_RELEASE_PKG_URL="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/debian/pool/main/z/zabbix-release/zabbix-release_latest+debian${DEB_VER}_all.deb"
if ! curl -sI "$ZABBIX_RELEASE_PKG_URL" 2>/dev/null | grep -qE "HTTP/[123.]+ 200"; then
    ZABBIX_RELEASE_PKG_URL="https://repo.zabbix.com/zabbix/7.0/debian/pool/main/z/zabbix-release/zabbix-release_latest+debian${DEB_VER}_all.deb"
fi

apt-get update -y
log_success "Package indices updated."

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
# 3. MySQL / MariaDB Installation & Configuration
# ------------------------------------------------------------------------------
log_step "3. Installing and Configuring MySQL / MariaDB Server"

apt-get install -y --no-install-recommends mariadb-server mariadb-client

systemctl daemon-reload
systemctl enable --now mariadb 2>/dev/null || systemctl enable --now mysql 2>/dev/null || true
sleep 2

# Ensure database service is running
if ! systemctl is-active --quiet mariadb && ! systemctl is-active --quiet mysql; then
    systemctl start mariadb 2>/dev/null || systemctl start mysql 2>/dev/null || true
    sleep 2
fi

log_info "Configuring database '${ZABBIX_DB_NAME}' and user '${ZABBIX_DB_USER}'..."
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS \`${ZABBIX_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${ZABBIX_DB_USER}'@'localhost' IDENTIFIED BY '${ZABBIX_DB_PASSWORD}';
ALTER USER '${ZABBIX_DB_USER}'@'localhost' IDENTIFIED BY '${ZABBIX_DB_PASSWORD}';
CREATE USER IF NOT EXISTS '${ZABBIX_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${ZABBIX_DB_PASSWORD}';
ALTER USER '${ZABBIX_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${ZABBIX_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${ZABBIX_DB_NAME}\`.* TO '${ZABBIX_DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${ZABBIX_DB_NAME}\`.* TO '${ZABBIX_DB_USER}'@'127.0.0.1';
SET GLOBAL log_bin_trust_function_creators = 1;
FLUSH PRIVILEGES;
EOF

log_success "MySQL / MariaDB server ready."

# ------------------------------------------------------------------------------
# 4. Zabbix Official Repository Setup & Package Installation
# ------------------------------------------------------------------------------
log_step "4. Setting up Zabbix Official Repository"

REPO_DEB="/tmp/zabbix-release.deb"
rm -f "$REPO_DEB"
log_info "Downloading Zabbix repository package from ${ZABBIX_RELEASE_PKG_URL}..."
wget -qO "$REPO_DEB" "$ZABBIX_RELEASE_PKG_URL"
dpkg -i "$REPO_DEB"
rm -f "$REPO_DEB"

apt-get update -y
log_success "Zabbix repository configured."

log_step "5. Installing Zabbix Server (MySQL), Agent 2, and Frontend Components"

ZABBIX_PACKAGES=(
    zabbix-server-mysql
    zabbix-sql-scripts
    zabbix-agent2
    zabbix-frontend-php
    zabbix-nginx-conf
    php-mysql
    nginx
    php-fpm
)

apt-get install -y --no-install-recommends "${ZABBIX_PACKAGES[@]}"
apt-get install -y --no-install-recommends zabbix-agent2-plugin-mysql 2>/dev/null || true
log_success "Zabbix components installed successfully."

# ------------------------------------------------------------------------------
# 6. Database Schema Initialisation
# ------------------------------------------------------------------------------
log_step "6. Initialising Zabbix Database Schema"

SCHEMA_FILE="/usr/share/zabbix-sql-scripts/mysql/server.sql.gz"
if [[ ! -f "$SCHEMA_FILE" ]]; then
    SCHEMA_FILE="/usr/share/doc/zabbix-sql-scripts/mysql/server.sql.gz"
fi
if [[ ! -f "$SCHEMA_FILE" ]]; then
    SCHEMA_FILE=$(find /usr/share -type f -name "server.sql.gz" 2>/dev/null | grep mysql | head -n1 || true)
fi

if [[ -f "$SCHEMA_FILE" ]]; then
    TABLE_COUNT=$(mysql -u root -N -B -e "SELECT count(*) FROM information_schema.tables WHERE table_schema='${ZABBIX_DB_NAME}';" 2>/dev/null || echo "0")
    if [[ "$TABLE_COUNT" -eq 0 ]]; then
        log_info "Importing Zabbix schema from ${SCHEMA_FILE}..."
        mysql -u root -e "SET GLOBAL log_bin_trust_function_creators = 1;" 2>/dev/null || true
        zcat "$SCHEMA_FILE" | mysql --default-character-set=utf8mb4 -u root "${ZABBIX_DB_NAME}"
        mysql -u root -e "SET GLOBAL log_bin_trust_function_creators = 0;" 2>/dev/null || true
        mysql -u root -e "GRANT ALL PRIVILEGES ON \`${ZABBIX_DB_NAME}\`.* TO '${ZABBIX_DB_USER}'@'localhost'; GRANT ALL PRIVILEGES ON \`${ZABBIX_DB_NAME}\`.* TO '${ZABBIX_DB_USER}'@'127.0.0.1'; FLUSH PRIVILEGES;" 2>/dev/null || true
        log_success "Zabbix database schema imported successfully."
    else
        log_info "Database already populated (${TABLE_COUNT} tables found). Skipping schema import."
    fi
else
    log_warn "Schema file not found automatically. Please verify /usr/share/zabbix-sql-scripts/mysql/."
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
\$DB['TYPE']     = 'MYSQL';
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
\$ZBX_SERVER_NAME = 'Zabbix Monitoring';

\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
EOF

chown -R www-data:www-data /etc/zabbix/web
chmod 640 /etc/zabbix/web/zabbix.conf.php
log_success "Zabbix web frontend pre-configured at /etc/zabbix/web/zabbix.conf.php."

# ------------------------------------------------------------------------------
# 9. Configure Zabbix Agent 2 & MySQL Monitoring Credentials
# ------------------------------------------------------------------------------
log_step "9. Configuring Zabbix Agent 2"

AGENT_CONF="/etc/zabbix/zabbix_agent2.conf"
if [[ -f "$AGENT_CONF" ]]; then
    sed -i "s/^Server=127.0.0.1/Server=127.0.0.1/" "$AGENT_CONF"
    sed -i "s/^ServerActive=127.0.0.1/ServerActive=127.0.0.1/" "$AGENT_CONF"
    sed -i "s/^Hostname=Zabbix server/Hostname=Zabbix server/" "$AGENT_CONF"
    log_success "Configured ${AGENT_CONF}."
fi

# Configure MySQL monitoring user and .my.cnf for Zabbix Agent 2
log_info "Configuring MySQL monitoring credentials for Zabbix Agent 2..."
mysql -u root <<EOF 2>/dev/null || true
CREATE USER IF NOT EXISTS 'zbx_monitor'@'localhost' IDENTIFIED BY '${ZABBIX_DB_PASSWORD}';
ALTER USER 'zbx_monitor'@'localhost' IDENTIFIED BY '${ZABBIX_DB_PASSWORD}';
GRANT REPLICATION CLIENT, PROCESS, SHOW DATABASES, SHOW VIEW ON *.* TO 'zbx_monitor'@'localhost';
FLUSH PRIVILEGES;
EOF

mkdir -p /var/lib/zabbix
cat << EOF > /var/lib/zabbix/.my.cnf
[client]
user = zbx_monitor
password = ${ZABBIX_DB_PASSWORD}
EOF
chown -R zabbix:zabbix /var/lib/zabbix 2>/dev/null || true
chmod 600 /var/lib/zabbix/.my.cnf 2>/dev/null || true

# ------------------------------------------------------------------------------
# 10. Enable and Start Services
# ------------------------------------------------------------------------------
log_step "10. Enabling and Starting Services"

# Detect installed PHP-FPM service name
PHP_FPM_SVC=$(systemctl list-unit-files --type=service 2>/dev/null | grep -oE 'php[0-9.]*-fpm\.service' | head -n1 || echo "php-fpm.service")

systemctl daemon-reload
systemctl enable --now mariadb 2>/dev/null || systemctl enable --now mysql 2>/dev/null || true
systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null || true

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
log_success "All Zabbix services enabled and started."

# ------------------------------------------------------------------------------
# 11. Generate External Nginx Reverse Proxy Configuration & Save Credentials
# ------------------------------------------------------------------------------
log_step "11. Generating External Nginx Reverse Proxy Configuration"

CT_IP=$(ip -4 addr show eth0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 || hostname -I | awk '{print $1}')
PROXY_CONF="/etc/zabbix/nginx-external-reverse-proxy.conf"

cat << EOF > "$PROXY_CONF"
# ==============================================================================
# Nginx Reverse Proxy Configuration for Zabbix
# Add this configuration to your EXTERNAL Nginx container/server!
# Location on external Nginx container: /etc/nginx/conf.d/zabbix.conf
# ==============================================================================

upstream zabbix_backend {
    # Points to the Zabbix LXC container internal web listener:
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

    # WebSocket support for Zabbix live updates and dashboards
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;

    location / {
        proxy_pass http://zabbix_backend;
    }
}
EOF

CREDS_FILE="/etc/zabbix/zabbix_credentials.txt"
cat << EOF > "$CREDS_FILE"
# Zabbix Deployment Credentials & Details
Generated: $(date -u)
Target OS: Debian ${DEB_VER} (${CURRENT_CODENAME})
Container IP: ${CT_IP}

[Database - MySQL / MariaDB]
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
echo -e "${GREEN}  Zabbix with MySQL / MariaDB Installed Successfully!                   ${NC}"
echo -e "${GREEN}========================================================================${NC}"
echo -e "Container IP:              ${BLUE}${CT_IP}${NC}"
echo -e "Zabbix Server Port:        ${BLUE}${ZABBIX_SERVER_PORT}${NC}"
echo -e "Internal Web GUI:          ${BLUE}http://${CT_IP}:${ZABBIX_LOCAL_WEB_PORT}${NC}"
echo -e "Default Web Login:         ${YELLOW}Admin${NC} / ${YELLOW}zabbix${NC}"
echo -e "MySQL Database:            ${YELLOW}${ZABBIX_DB_NAME}${NC} (User: ${YELLOW}${ZABBIX_DB_USER}${NC})"
echo -e "Database Password saved:   ${BLUE}${CREDS_FILE}${NC}"
echo -e "\n${BOLD}${YELLOW}--> External Nginx Configuration:${NC}"
echo -e "A reverse proxy configuration for your other Nginx container has been generated at:"
echo -e "${BLUE}${PROXY_CONF}${NC}"
echo -e "Add its contents to ${YELLOW}/etc/nginx/conf.d/zabbix.conf${NC} on your Nginx container."
echo -e "${GREEN}========================================================================${NC}\n"
