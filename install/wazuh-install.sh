#!/usr/bin/env bash

# Copyright (c) 2024-2026 community-scripts ORG
# Author: Omar Minaya / Update for Wazuh 5: hubi
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://wazuh.com/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

INSTALLER_VERSION="5.0.0-beta5"
INSTALLER_URL="https://packages-staging.xdrsiem.wazuh.info/pre-release/5.x/installation-assistant/wazuh-install-${INSTALLER_VERSION}.sh"
ARTIFACT_URL="https://packages-staging.xdrsiem.wazuh.info/pre-release/5.x/artifact-urls/artifact_urls_${INSTALLER_VERSION}.yaml"

msg_warn "WARNING: This script installs Wazuh 5 Beta (${INSTALLER_VERSION}) using the pre-release staging installer."
msg_warn "Wazuh 5 includes major architectural redesigns (Wazuh Common Schema, decoupling, new indexer engine)."
msg_warn "Installer source URL:"
msg_custom "${TAB3}${GATEWAY}${BGN}${CL}" "\e[1;34m" "→  ${INSTALLER_URL} "
echo
read -r -p "${TAB3}Do you want to continue? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^([yY][eE][sS]|[yY])$ ]]; then
  msg_error "Aborted by user. No changes have been made."
  exit 10
fi

msg_info "Installing Prerequisites"
$STD apt-get install -y curl wget gnupg apt-transport-https lsb-release ca-certificates tar
msg_ok "Installed Prerequisites"

msg_info "Preparing Wazuh 5 Installation Environment"
WORKDIR="/root/wazuh-install"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# Pobranie oficjalnego instalatora
curl -fsSL "${INSTALLER_URL}" -o "${WORKDIR}/wazuh-install.sh"
chmod +x "${WORKDIR}/wazuh-install.sh"

# Pobranie i naprawienie błędu upstreamu w wazuh-install-5.0.0-beta5.sh:
# Skrypt w linii 1035 sprawdza [ ! -f "${artifact_urls_file_name}" ] (względną ścieżkę),
# podczas gdy pobiera plik do "${base_path}/${artifact_urls_file_name}".
# Tworzymy pliki w obu formatach nazw i lokalizacjach (relative i base_path),
# oraz poprawiamy w skrypcie warunek na pełną ścieżkę.
curl -fsSL "${ARTIFACT_URL}" -o "${WORKDIR}/artifact_urls_${INSTALLER_VERSION}.yaml"
cp "${WORKDIR}/artifact_urls_${INSTALLER_VERSION}.yaml" "${WORKDIR}/artifact_urls.yaml"

sed -i 's|if \[ ! -f "\${artifact_urls_file_name}" \]; then|if \[ ! -f "\${base_path}/\${artifact_urls_file_name}" \]; then|g' "${WORKDIR}/wazuh-install.sh"

msg_ok "Prepared Wazuh 5 Installation Environment"

msg_info "Downloading and executing Wazuh 5 Installation Assistant"

# Wazuh 5 Beta AIO (All-in-one) installation flag: -a -id -d pre-release
if [ "$STD" = "silent" ]; then
  bash "${WORKDIR}/wazuh-install.sh" -a -id -d pre-release >>~/wazuh-install.output 2>&1
else
  bash "${WORKDIR}/wazuh-install.sh" -a -id -d pre-release 2>&1 | tee -a ~/wazuh-install.output
fi

# Save summary/credentials
grep -E "User|Password|https://" ~/wazuh-install.output | awk '{$1=$1};1' | sed '1i wazuh-credentials' >~/wazuh.creds || true
rm -rf "${WORKDIR}"
rm -f ~/wazuh-install.output
msg_ok "Completed Wazuh 5 Beta Setup"

# Fix LXC container rootcheck false positives
if [ -d /dev/.lxc ] && [ -f /var/ossec/etc/ossec.conf ]; then
  msg_info "Adding LXC rootcheck exclusion"
  sed -i '/<\/rootcheck>/i \    <ignore>/dev/.lxc</ignore>' /var/ossec/etc/ossec.conf
  msg_ok "Added LXC rootcheck exclusion"
fi

motd_ssh
customize
cleanup_lxc
