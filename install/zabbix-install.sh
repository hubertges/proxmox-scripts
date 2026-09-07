#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: MickLesk (CanbiZ) / Hubert Ges
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://www.zabbix.com/

if [[ -z "${FUNCTIONS_FILE_PATH:-}" ]]; then
  FUNCTIONS_FILE_PATH="$(curl -fsSL https://raw.githubusercontent.com/community-scripts/core/main/lxc/install.func)"
fi
# shellcheck source=/dev/null
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"

color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# ------------------------------------------------------------------------------
# 1. Disable & Mask Chrony / Timesync Daemons (LXC uses hypervisor clock)
# ------------------------------------------------------------------------------
msg_info "Disabling chrony and timesync daemons"
$STD systemctl disable --now chrony chronyd systemd-timesyncd ntpd 2>/dev/null || true
$STD systemctl mask chrony chronyd systemd-timesyncd ntpd 2>/dev/null || true
$STD apt-get remove --purge -y chrony 2>/dev/null || true
msg_ok "Chrony disabled"

# ------------------------------------------------------------------------------
# 2. Administrator & Database Password Resolution
# ------------------------------------------------------------------------------
ZABBIX_PASS="${ZABBIX_PASS:-${ZABBIX_ADMIN_PASSWORD:-${ADMIN_PASSWORD:-}}}"
if [[ -z "$ZABBIX_PASS" ]]; then
  if command -v whiptail >/dev/null 2>&1 && [[ -t 0 ]]; then
    ZABBIX_PASS=$(whiptail --title "Zabbix Password" --passwordbox "Enter Zabbix & Database Administrator Password (leave empty for random):" 10 65 3>&1 1>&2 2>&3 || true)
  fi
fi
if [[ -z "$ZABBIX_PASS" ]]; then
  ZABBIX_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c16)
fi

# ------------------------------------------------------------------------------
# 3. PostgreSQL Database Setup via Community Scripts built-in functions
# ------------------------------------------------------------------------------
PG_VERSION="17" setup_postgresql
PG_DB_NAME="zabbixdb" PG_DB_USER="zabbix" PG_DB_PASS="$ZABBIX_PASS" PG_DB_SCHEMA_PERMS="true" setup_postgresql_db
sudo -u postgres psql -d "$PG_DB_NAME" -c "ALTER SCHEMA public OWNER TO $PG_DB_USER;" &>/dev/null || true
sudo -u postgres psql -d "$PG_DB_NAME" -c "GRANT ALL ON SCHEMA public TO $PG_DB_USER;" &>/dev/null || true

# ------------------------------------------------------------------------------
# 4. Version Detection (Zabbix 8.0+ minimum, newest available)
# ------------------------------------------------------------------------------
msg_info "Detecting latest Zabbix version"
LATEST_ZBX=$(curl -fsSL https://repo.zabbix.com/zabbix/ 2>/dev/null | grep -oP '(?<=href=")[0-9]+\.[0-9]+(?=/")' | sort -V | tail -n1 || echo "8.0")
if [[ -n "$LATEST_ZBX" ]] && printf '%s\n%s\n' "8.0" "$LATEST_ZBX" | sort -V -C 2>/dev/null; then
  ZABBIX_VERSION="$LATEST_ZBX"
else
  ZABBIX_VERSION="8.0"
fi
msg_ok "Selected Zabbix ${ZABBIX_VERSION}"

# ------------------------------------------------------------------------------
# 5. Configure Zabbix Official Repository on Debian 13 (Trixie)
# ------------------------------------------------------------------------------
msg_info "Configuring Zabbix ${ZABBIX_VERSION} Official Repository"
cd /tmp
ZABBIX_DEB_URL="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/debian/pool/main/z/zabbix-release/zabbix-release_latest+debian13_all.deb"
if ! curl -sI "$ZABBIX_DEB_URL" 2>/dev/null | grep -qE "HTTP/[123.]+ 200"; then
  ZABBIX_DEB_URL="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_${ZABBIX_VERSION}+debian13_all.deb"
fi
curl -fsSL "$ZABBIX_DEB_URL" -o /tmp/zabbix-release.deb
$STD dpkg -i /tmp/zabbix-release.deb
rm -f /tmp/zabbix-release.deb
$STD apt-get update
msg_ok "Configured Zabbix ${ZABBIX_VERSION} Official Repository"

# ------------------------------------------------------------------------------
# 6. Install Zabbix Server, Web Frontend, and Agent 2
# ------------------------------------------------------------------------------
msg_info "Installing Zabbix ${ZABBIX_VERSION} Components"
$STD apt-get install -y --no-install-recommends \
  zabbix-server-pgsql \
  zabbix-frontend-php \
  php-pgsql \
  libapache2-mod-php \
  zabbix-apache-conf \
  zabbix-sql-scripts \
  zabbix-agent2 \
  zabbix-agent2-plugin-postgresql \
  fping
msg_ok "Installed Zabbix ${ZABBIX_VERSION} Components"

# ------------------------------------------------------------------------------
# 7. Database Schema Initialization
# ------------------------------------------------------------------------------
msg_info "Initializing Zabbix Database Schema"
SCHEMA_FILE=""
for s in \
  "/usr/share/zabbix/sql-scripts/postgresql/server.sql.gz" \
  "/usr/share/zabbix-sql-scripts/postgresql/server.sql.gz" \
  "/usr/share/doc/zabbix-sql-scripts/postgresql/server.sql.gz"; do
  if [[ -f "$s" ]]; then
    SCHEMA_FILE="$s"
    break
  fi
done
if [[ -z "$SCHEMA_FILE" ]]; then
  SCHEMA_FILE=$(find /usr/share -type f -name "server.sql.gz" 2>/dev/null | grep -E "postgresql|pgsql" | head -n1)
fi

if [[ -n "$SCHEMA_FILE" && -f "$SCHEMA_FILE" ]]; then
  zcat "$SCHEMA_FILE" | sudo -u "$PG_DB_USER" psql -d "$PG_DB_NAME" &>/dev/null
  msg_ok "Initialized Zabbix Database Schema"
else
  msg_error "Could not find server.sql.gz schema file!"
  exit 1
fi

# ------------------------------------------------------------------------------
# 8. Configure Zabbix Server Daemon
# ------------------------------------------------------------------------------
msg_info "Configuring Zabbix Server Daemon"
sed -i "s/^#\? \?DBHost=.*/DBHost=localhost/" /etc/zabbix/zabbix_server.conf
sed -i "s/^#\? \?DBName=.*/DBName=${PG_DB_NAME}/" /etc/zabbix/zabbix_server.conf
sed -i "s/^#\? \?DBUser=.*/DBUser=${PG_DB_USER}/" /etc/zabbix/zabbix_server.conf
sed -i "s/^#\? \?DBPassword=.*/DBPassword=${ZABBIX_PASS}/" /etc/zabbix/zabbix_server.conf

if command -v fping >/dev/null 2>&1; then
  sed -i "s|^#\? \?FpingLocation=.*|FpingLocation=$(command -v fping)|" /etc/zabbix/zabbix_server.conf
fi
if command -v fping6 >/dev/null 2>&1; then
  sed -i "s|^#\? \?Fping6Location=.*|Fping6Location=$(command -v fping6)|" /etc/zabbix/zabbix_server.conf
fi
msg_ok "Configured Zabbix Server Daemon"

# ------------------------------------------------------------------------------
# 9. Pre-configure Zabbix Web Frontend (/etc/zabbix/web/zabbix.conf.php)
# ------------------------------------------------------------------------------
msg_info "Configuring Zabbix Web Frontend"
mkdir -p /etc/zabbix/web
cat << EOF > /etc/zabbix/web/zabbix.conf.php
<?php
// Zabbix GUI configuration file
\$DB['TYPE']     = 'POSTGRESQL';
\$DB['SERVER']   = 'localhost';
\$DB['PORT']     = '0';
\$DB['DATABASE'] = '${PG_DB_NAME}';
\$DB['USER']     = '${PG_DB_USER}';
\$DB['PASSWORD'] = '${ZABBIX_PASS}';

// Schema name. Used for PostgreSQL.
\$DB['SCHEMA']   = '';

// Encryption
\$DB['ENCRYPTION']  = false;
\$DB['VERIFY_HOST']  = false;
\$DB['KEY_FILE']     = '';
\$DB['CERT_FILE']    = '';
\$DB['CA_FILE']      = '';

\$ZBX_SERVER      = 'localhost';
\$ZBX_SERVER_PORT = '10051';
\$ZBX_SERVER_NAME = 'Zabbix';

\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
EOF
chown -R www-data:www-data /etc/zabbix/web
chmod 640 /etc/zabbix/web/zabbix.conf.php
msg_ok "Configured Zabbix Web Frontend"

# ------------------------------------------------------------------------------
# 10. Configure Administrator Password in Database
# ------------------------------------------------------------------------------
msg_info "Setting Zabbix Administrator Password"
if command -v php >/dev/null 2>&1; then
  ADMIN_HASH=$(php -r "echo password_hash('${ZABBIX_PASS}', PASSWORD_BCRYPT);")
  sudo -u "$PG_DB_USER" psql -d "$PG_DB_NAME" -c "UPDATE users SET passwd = '${ADMIN_HASH}' WHERE username = 'Admin';" &>/dev/null || true
fi
msg_ok "Configured Zabbix Administrator Password"

# ------------------------------------------------------------------------------
# 11. Configure Web Server Ports & Redirects (Port 80 and 8080)
# ------------------------------------------------------------------------------
msg_info "Configuring Web Server Ports & Redirect"
if ! grep -q "Listen 8080" /etc/apache2/ports.conf 2>/dev/null; then
  echo "Listen 8080" >> /etc/apache2/ports.conf
fi
if [[ -f /etc/apache2/sites-available/000-default.conf ]]; then
  sed -i 's/<VirtualHost \*:80>/<VirtualHost *:80 *:8080>/' /etc/apache2/sites-available/000-default.conf
fi
mkdir -p /var/www/html
cat << 'EOF' > /var/www/html/index.html
<!DOCTYPE html>
<html><head><meta http-equiv="refresh" content="0; url=/zabbix/"></head><body><a href="/zabbix/">Redirecting to Zabbix...</a></body></html>
EOF
msg_ok "Configured Web Server Ports & Redirect"

# ------------------------------------------------------------------------------
# 12. Configure Zabbix Agent 2
# ------------------------------------------------------------------------------
msg_info "Configuring Zabbix Agent 2"
sed -i "s/^Server=127.0.0.1/Server=127.0.0.1/" /etc/zabbix/zabbix_agent2.conf
sed -i "s/^ServerActive=127.0.0.1/ServerActive=127.0.0.1/" /etc/zabbix/zabbix_agent2.conf
sed -i "s/^Hostname=Zabbix server/Hostname=Zabbix server/" /etc/zabbix/zabbix_agent2.conf
if [ -f /etc/zabbix/zabbix_agent2.d/plugins.d/nvidia.conf ]; then
  sed -i 's|^Plugins.NVIDIA.System.Path=.*|# Plugins.NVIDIA.System.Path=/usr/libexec/zabbix/zabbix-agent2-plugin-nvidia-gpu|' \
    /etc/zabbix/zabbix_agent2.d/plugins.d/nvidia.conf
fi
msg_ok "Configured Zabbix Agent 2"

# ------------------------------------------------------------------------------
# 13. Re-verify Chrony / Timesync Daemons Masked
# ------------------------------------------------------------------------------
$STD systemctl disable --now chrony chronyd systemd-timesyncd ntpd 2>/dev/null || true
$STD systemctl mask chrony chronyd systemd-timesyncd ntpd 2>/dev/null || true

# ------------------------------------------------------------------------------
# 14. Enable and Start Services
# ------------------------------------------------------------------------------
msg_info "Starting Services"
systemctl restart zabbix-server zabbix-agent2 apache2
systemctl enable -q --now zabbix-server zabbix-agent2 apache2
msg_ok "Started Services"

# ------------------------------------------------------------------------------
# 15. Store Deployment Credentials
# ------------------------------------------------------------------------------
CT_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
cat << EOF > /root/zabbix.creds
==================================================
Zabbix ${ZABBIX_VERSION} Deployment Credentials
==================================================
Web Interface:    http://${CT_IP}/zabbix (or :8080/zabbix)
Default Username: Admin
Password:         ${ZABBIX_PASS}

Database:         ${PG_DB_NAME}
Database User:    ${PG_DB_USER}
Database Pass:    ${ZABBIX_PASS}

Server Port:      10051 (TCP)
==================================================
EOF
chmod 600 /root/zabbix.creds

motd_ssh
customize
cleanup_lxc
