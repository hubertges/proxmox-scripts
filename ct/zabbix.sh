#!/usr/bin/env bash
_CS_DEFAULT_URL="${PROXMOX_SCRIPTS_URL:-https://raw.githubusercontent.com/hubertges/proxmox-scripts/main}"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: hubi
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://www.zabbix.com/documentation/devel/en/manual

APP="Zabbix"
var_tags="${var_tags:-monitoring;network;zabbix;postgresql}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-16}"
var_arm64="${var_arm64:-yes}"
var_unprivileged="${var_unprivileged:-1}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -f /lib/systemd/system/zabbix-server.service ]]; then
    msg_error "No ${APP} Installation Found!"
    exit 1
  fi
  msg_info "Updating Zabbix 8.0 & System Packages"
  $STD apt update
  $STD apt upgrade -y
  msg_ok "Updated Zabbix 8.0 LXC successfully!"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} 8.0 LTS setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Internal Web GUI URL:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:8080${CL}"
echo -e "${INFO}${YW}Default credentials: Admin / zabbix${CL}"
echo -e "${INFO}${YW}Zabbix Server Daemon: ${IP}:10051${CL}"
echo -e "${INFO}${YW}External Nginx reverse proxy configuration available in system-config/nginx-zabbix-reverse-proxy.conf${CL}"
