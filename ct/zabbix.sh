#!/usr/bin/env bash
_CS_DEFAULT_URL="${PROXMOX_SCRIPTS_URL:-https://raw.githubusercontent.com/hubertges/proxmox-scripts/main}"
export COMMUNITY_SCRIPTS_URL="${COMMUNITY_SCRIPTS_URL:-$_CS_DEFAULT_URL}"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: hubi
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://www.zabbix.com/

APP="Zabbix"
var_tags="${var_tags:-monitoring;zabbix8;postgresql}"
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

# Zapytaj o hasło w GUI (whiptail)
if command -v whiptail >/dev/null 2>&1 && [[ -t 0 ]]; then
  PASS1=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
    --title "HASŁO ZABBIX & BAZY DANYCH" \
    --passwordbox "Wprowadź hasło dla administratora Zabbix (GUI), bazy danych oraz kontenera:\n(Pozostaw puste, aby wygenerować silne losowe hasło)" 12 65 \
    3>&1 1>&2 2>&3 || true)

  if [[ -n "$PASS1" ]]; then
    PASS2=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
      --title "POTWIERDZENIE HASŁA" \
      --passwordbox "Powtórz hasło administratora:" 10 65 \
      3>&1 1>&2 2>&3 || true)
    if [[ "$PASS1" != "$PASS2" ]]; then
      whiptail --backtitle "Proxmox VE Helper Scripts" --title "BŁĄD" --msgbox "Hasła nie są identyczne! Zostanie wygenerowane bezpieczne losowe hasło." 8 65
      PASS1=""
    fi
  fi
fi

if [[ -z "${PASS1:-}" ]]; then
  ZABBIX_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c16)
else
  ZABBIX_PASS="$PASS1"
fi

export ZABBIX_PASS
export var_pw="$ZABBIX_PASS"
export LXC_USER_PASSWORD="$ZABBIX_PASS"

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -f /etc/zabbix/zabbix_server.conf ]]; then
    msg_error "No ${APP} Installation Found!"
    exit 1
  fi
  msg_info "Updating Zabbix & System Packages"
  $STD apt update
  $STD apt upgrade -y
  msg_ok "Updated Zabbix LXC successfully!"
  exit
}

start
build_container
description

# Automatyczny provisioning z repozytorium hubertges/proxmox-scripts
msg_info "Inicjalizacja automatycznego provisioningu z repozytorium..."
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
PROV_SCRIPT=""
if [[ -f "${REPO_ROOT}/provisioning/nowykontener.sh" ]]; then
  PROV_SCRIPT="${REPO_ROOT}/provisioning/nowykontener.sh"
elif [[ -f "${REPO_ROOT}/provisioning/setup_lxc.sh" ]]; then
  PROV_SCRIPT="${REPO_ROOT}/provisioning/setup_lxc.sh"
fi

if [[ -n "$PROV_SCRIPT" ]]; then
  LXC_USER_PASSWORD="${ZABBIX_PASS}" bash "$PROV_SCRIPT" "$CTID" || msg_warn "Provisioning zakończył się ostrzeżeniami"
  msg_ok "Provisioning zakończony pomyślnie z repozytorium lokalnego"
else
  PROV_URL="https://raw.githubusercontent.com/hubertges/proxmox-scripts/main/provisioning/nowykontener.sh"
  TMP_PROV="/tmp/nowykontener_${CTID}.sh"
  if curl -fsSL "$PROV_URL" -o "$TMP_PROV" 2>/dev/null; then
    LXC_USER_PASSWORD="${ZABBIX_PASS}" bash "$TMP_PROV" "$CTID" || msg_warn "Provisioning zakończył się ostrzeżeniami"
    rm -f "$TMP_PROV"
    msg_ok "Provisioning zakończony pomyślnie ze zdalnego repozytorium"
  else
    msg_warn "Nie udało się pobrać skryptu provisioningu ze zdalnego repozytorium"
  fi
fi

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} 8.0+ setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Web GUI URL:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}/zabbix${CL} (lub http://${IP}:8080/zabbix)"
echo -e "${INFO}${YW}Web Admin User:       ${GN}Admin${CL}"
echo -e "${INFO}${YW}Web Admin Password:   ${GN}${ZABBIX_PASS}${CL}"
echo -e "${INFO}${YW}PostgreSQL Database:  ${GN}zabbixdb${CL}"
echo -e "${INFO}${YW}PostgreSQL User:      ${GN}zabbix${CL}"
echo -e "${INFO}${YW}PostgreSQL Password:  ${GN}${ZABBIX_PASS}${CL}"
echo -e "${INFO}${YW}Zabbix Server Daemon: ${GN}${IP}:10051 (TCP)${CL}"
echo -e "${INFO}${YW}Credentials File:     ${GN}/root/zabbix.creds${CL}"
echo -e "${INFO}${YW}Reverse Proxy config: ${GN}system-config/nginx-zabbix-reverse-proxy.conf${CL}"

