#!/usr/bin/env bash
_CS_DEFAULT_URL="${PROXMOX_SCRIPTS_URL:-https://raw.githubusercontent.com/hubertges/proxmox-scripts/main}"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Omar Minaya / Update for Wazuh 5: hubi
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://wazuh.com/

APP="Wazuh"
var_tags="${var_tags:-security;monitoring;siem;xdr}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-50}"
var_arm64="${var_arm64:-yes}"
var_unprivileged="${var_unprivileged:-0}"

# Auto-detect newest available Ubuntu version on the host catalog, or let user choose
detect_latest_ubuntu() {
  local latest=""
  if command -v pveam >/dev/null 2>&1; then
    latest=$(pveam available --section system 2>/dev/null | grep -oP 'ubuntu-\K[0-9]+\.[0-9]+(?=-standard)' | sort -V | tail -n1)
  fi
  echo "${latest:-24.04}"
}

LATEST_UBUNTU=$(detect_latest_ubuntu)

# If not set via env var and running interactively on Proxmox, offer OS version choice
if [[ -z "${var_os:-}" ]] && command -v pveversion >/dev/null 2>&1; then
  if command -v whiptail >/dev/null 2>&1 && [[ -t 0 ]]; then
    OS_CHOICE=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
      --title "Wazuh 5 - Wybór systemu Ubuntu" \
      --radiolist "Wybierz wersję Ubuntu dla kontenera Wazuh 5:\n(Domyślnie najnowsza dostępna)" 12 65 3 \
      "$LATEST_UBUNTU" "Ubuntu $LATEST_UBUNTU (Najnowsze dostępne w PVE)" ON \
      "24.04" "Ubuntu 24.04 LTS (Rekomendowane przez Wazuh)" OFF \
      "debian" "Debian 13 (Trixie)" OFF \
      3>&1 1>&2 2>&3 || echo "$LATEST_UBUNTU")
    
    if [[ "$OS_CHOICE" == "debian" ]]; then
      var_os="debian"
      var_version="13"
    else
      var_os="ubuntu"
      var_version="${OS_CHOICE:-$LATEST_UBUNTU}"
    fi
  else
    var_os="${var_os:-ubuntu}"
    var_version="${var_version:-$LATEST_UBUNTU}"
  fi
else
  var_os="${var_os:-ubuntu}"
  var_version="${var_version:-$LATEST_UBUNTU}"
fi

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -f /lib/systemd/system/wazuh-manager.service && ! -f /lib/systemd/system/wazuh-server.service ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  msg_info "Updating Wazuh LXC"
  $STD apt update
  $STD apt upgrade -y
  msg_ok "Updated Wazuh LXC"
  msg_ok "Updated successfully!"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}https://${IP}:443${CL}"
echo -e "${INFO}${YW}Default credentials: admin / admin${CL}"
