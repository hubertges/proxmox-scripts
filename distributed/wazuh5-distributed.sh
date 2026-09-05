#!/usr/bin/env bash

# ============================================================================
# Wazuh 5.0 Beta 5 — Distributed Proxmox LXC Deployment
# Creates 3 LXC containers:
#   1. Wazuh Indexer   (OpenSearch-based distributed search engine)
#   2. Wazuh Manager   (Core analysis engine & agent communication)
#   3. Wazuh Dashboard (Web UI management portal)
# Based on: https://documentation.wazuh.com/5.0-beta/installation-guide/
# Inspired by: Proxmox VE Helper-Scripts (community-scripts)
# ============================================================================

set -euo pipefail

BL="\e[36m"
GN="\e[32m"
RD="\e[31m"
YW="\e[33m"
CL="\e[0m"
BFR="\r\033[K"

msg_info()  { echo -ne " ${BL}[INFO]${CL}  $1..."; }
msg_ok()    { echo -e "${BFR} ${GN}[OK]${CL}    $1"; }
msg_error() { echo -e "${BFR} ${RD}[ERROR]${CL} $1"; }
msg_warn()  { echo -e "${BFR} ${YW}[WARN]${CL}  $1"; }

header() {
  clear
  cat <<'EOF'
   _       __                 __        ______
  | |     / /___ _____  __  __/ /_     / ____/
  | | /| / / __ `/_  / / / / / __ \   /___ \
  | |/ |/ / /_/ / / /_/ /_/ / / / /  ____/ /
  |__/|__/\__,_/ /___/\__,_/_/ /_/  /_____/   BETA (Distributed LXC)

  Proxmox VE Automated Distributed Deployment
  3 Containers: Wazuh Indexer · Wazuh Manager · Wazuh Dashboard
EOF
  echo ""
}

preflight() {
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "This script must be run as root on your Proxmox VE host."
    exit 1
  fi
  if ! command -v pveversion &>/dev/null; then
    msg_error "pveversion not found. Execute this on a Proxmox VE node."
    exit 1
  fi
  if ! command -v pct &>/dev/null; then
    msg_error "pct tool is required."
    exit 1
  fi
  msg_ok "Environment: Proxmox VE $(pveversion | awk -F'/' '{print $2}')"
}

# Defaults & Auto-detection of Storages
BRIDGE="${BRIDGE:-vmbr0}"

# Auto-detect storage supporting 'rootdir' if not specified
if [[ -z "${STORAGE:-}" ]]; then
  STORAGE=$(pvesh get /storage --output-format json 2>/dev/null | grep -oP '(?<="storage":")[^"]+' | while read -r st; do
    if pvesh get "/storage/$st" --output-format json 2>/dev/null | grep -q 'rootdir'; then
      # verify it is enabled/active
      if pvesh get "/storage/$st/status" &>/dev/null || true; then
        echo "$st"
        break
      fi
    fi
  done || true)
  STORAGE="${STORAGE:-local-lvm}"
fi

# Auto-detect storage supporting 'vztmpl' (templates) if not specified
if [[ -z "${TEMPLATE_STORAGE:-}" ]]; then
  TEMPLATE_STORAGE=$(pvesh get /storage --output-format json 2>/dev/null | grep -oP '(?<="storage":")[^"]+' | while read -r st; do
    if pvesh get "/storage/$st" --output-format json 2>/dev/null | grep -q 'vztmpl'; then
      # verify storage is not disabled
      if ! pvesh get "/storage/$st" --output-format json 2>/dev/null | grep -q '"disable":1'; then
        echo "$st"
        break
      fi
    fi
  done || true)
  TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
fi

OSTEMPLATE="${OSTEMPLATE:-ubuntu-24.04-standard_24.04-2_amd64.tar.zst}"

INDEXER_CTID="${INDEXER_CTID:-}"
MANAGER_CTID="${MANAGER_CTID:-}"
DASHBOARD_CTID="${DASHBOARD_CTID:-}"

INDEXER_NET="${INDEXER_NET:-dhcp}"
MANAGER_NET="${MANAGER_NET:-dhcp}"
DASHBOARD_NET="${DASHBOARD_NET:-dhcp}"

INDEXER_CPU="${INDEXER_CPU:-4}"
INDEXER_RAM="${INDEXER_RAM:-4096}"
INDEXER_DISK="${INDEXER_DISK:-50}"

MANAGER_CPU="${MANAGER_CPU:-2}"
MANAGER_RAM="${MANAGER_RAM:-2048}"
MANAGER_DISK="${MANAGER_DISK:-20}"

DASHBOARD_CPU="${DASHBOARD_CPU:-2}"
DASHBOARD_RAM="${DASHBOARD_RAM:-2048}"
DASHBOARD_DISK="${DASHBOARD_DISK:-20}"

WAZUH_INSTALLER_URL="https://packages-staging.xdrsiem.wazuh.info/pre-release/5.x/installation-assistant/wazuh-install-5.0.0-beta5.sh"
WAZUH_INSTALLER="wazuh-install-5.0.0-beta5.sh"
CT_PREFIX="${CT_PREFIX:-wazuh}"

get_next_ctid() {
  pvesh get /cluster/nextid 2>/dev/null
}

ensure_template() {
  msg_info "Checking template storage [${TEMPLATE_STORAGE}] and container storage [${STORAGE}]"
  
  # Check if template is already present on any storage
  local found_tmpl=""
  found_tmpl=$(pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | grep -oP '\S+ubuntu-24\.04\S+' | head -n1 || true)
  
  if [[ -n "$found_tmpl" ]]; then
    OSTEMPLATE=$(basename "$found_tmpl")
    msg_ok "Using cached template: ${OSTEMPLATE}"
    return 0
  fi

  # Check if OSTEMPLATE exists in available list
  msg_warn "Template not cached locally on ${TEMPLATE_STORAGE}. Updating pveam and downloading..."
  pveam update &>/dev/null || true

  # Find latest available ubuntu 24.04 template name if default fails
  local avail_tmpl
  avail_tmpl=$(pveam available --section system 2>/dev/null | grep -oP 'ubuntu-24\.04-standard\S+' | head -n1 || true)
  if [[ -n "$avail_tmpl" ]]; then
    OSTEMPLATE="$avail_tmpl"
  fi

  pveam download "${TEMPLATE_STORAGE}" "${OSTEMPLATE}" || {
    msg_error "Failed to download template to storage '${TEMPLATE_STORAGE}'."
    echo ""
    echo -e "${YW}Available active storages for templates (vztmpl):${CL}"
    pvesh get /storage --output-format json 2>/dev/null | grep -oP '(?<="storage":")[^"]+' | while read -r s; do
      if pvesh get "/storage/$s" 2>/dev/null | grep -q 'vztmpl'; then
        echo "  - $s"
      fi
    done
    echo ""
    echo -e "${YW}Tip: You can specify storage explicitly, e.g.:${CL}"
    echo "  TEMPLATE_STORAGE=twoj-storage STORAGE=twoj-storage-dla-dyskow bash wazuh5-distributed.sh"
    exit 1
  }
  msg_ok "OS template ready: ${OSTEMPLATE}"
}

create_container() {
  local ctid="$1" hostname="$2" cpu="$3" ram="$4" disk="$5" net_cfg="$6"
  msg_info "Creating LXC Container ${ctid} (${hostname})"
  local net_param
  if [[ "$net_cfg" == "dhcp" ]]; then
    net_param="name=eth0,bridge=${BRIDGE},ip=dhcp"
  else
    net_param="name=eth0,bridge=${BRIDGE},ip=${net_cfg}"
  fi

  pct create "${ctid}" "${TEMPLATE_STORAGE}:vztmpl/${OSTEMPLATE}" \
    --hostname "${hostname}" \
    --cores "${cpu}" \
    --memory "${ram}" \
    --swap 512 \
    --rootfs "${STORAGE}:${disk}" \
    --net0 "${net_param}" \
    --ostype ubuntu \
    --unprivileged 0 \
    --features nesting=1,keyctl=1 \
    --onboot 1 \
    --start 0 \
    --password "wazuh" \
    --description "Wazuh 5.0 Beta 5 - ${hostname}" &>/dev/null
  msg_ok "LXC Container ${ctid} created"
}

start_container() {
  local ctid="$1"
  msg_info "Starting container ${ctid}"
  pct start "${ctid}" &>/dev/null
  local retries=30
  while [[ $retries -gt 0 ]]; do
    if pct exec "${ctid}" -- bash -c "true" &>/dev/null; then
      break
    fi
    sleep 2
    ((retries--))
  done
  msg_ok "Container ${ctid} is running"
}

get_container_ip() {
  local ctid="$1"
  local ip=""
  local attempts=15
  while [[ $attempts -gt 0 ]]; do
    ip=$(pct exec "${ctid}" -- bash -c "hostname -I 2>/dev/null | awk '{print \$1}'" 2>/dev/null || echo "")
    if [[ -n "$ip" && "$ip" != "127.0.0.1" ]]; then
      echo "$ip"
      return 0
    fi
    sleep 2
    ((attempts--))
  done
  echo "unknown"
}

exec_in_ct() {
  local ctid="$1"
  shift
  pct exec "${ctid}" -- bash -c "$*"
}

setup_container_base() {
  local ctid="$1"
  msg_info "Installing basic utilities in CT ${ctid}"
  exec_in_ct "${ctid}" "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq &>/dev/null
    apt-get install -y -qq curl wget gnupg apt-transport-https lsb-release ca-certificates tar &>/dev/null
  "
  msg_ok "CT ${ctid} initialized"
}

download_installer() {
  local ctid="$1"
  msg_info "Fetching Wazuh 5 installer in CT ${ctid}"
  exec_in_ct "${ctid}" "
    cd /root
    curl -fsSL '${WAZUH_INSTALLER_URL}' -o '${WAZUH_INSTALLER}'
    chmod +x '${WAZUH_INSTALLER}'
  "
  msg_ok "Installer prepared in CT ${ctid}"
}

main() {
  header
  preflight

  if [[ -z "$INDEXER_CTID" ]]; then
    INDEXER_CTID=$(get_next_ctid)
  fi
  if [[ -z "$MANAGER_CTID" ]]; then
    MANAGER_CTID=$((INDEXER_CTID + 1))
    while pct status "$MANAGER_CTID" &>/dev/null; do ((MANAGER_CTID++)); done
  fi
  if [[ -z "$DASHBOARD_CTID" ]]; then
    DASHBOARD_CTID=$((MANAGER_CTID + 1))
    while pct status "$DASHBOARD_CTID" &>/dev/null; do ((DASHBOARD_CTID++)); done
  fi

  echo -e "${BL}Deployment Summary:${CL}"
  echo -e "  • Wazuh Indexer   → CT ${GN}${INDEXER_CTID}${CL} (${INDEXER_CPU} cores, ${INDEXER_RAM}MB RAM, ${INDEXER_DISK}GB disk)"
  echo -e "  • Wazuh Manager   → CT ${GN}${MANAGER_CTID}${CL} (${MANAGER_CPU} cores, ${MANAGER_RAM}MB RAM, ${MANAGER_DISK}GB disk)"
  echo -e "  • Wazuh Dashboard → CT ${GN}${DASHBOARD_CTID}${CL} (${DASHBOARD_CPU} cores, ${DASHBOARD_RAM}MB RAM, ${DASHBOARD_DISK}GB disk)"
  echo ""
  read -r -p "Proceed with creation? [y/N]: " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[yYtT]$ ]]; then
    echo "Aborted."
    exit 0
  fi
  echo ""

  ensure_template

  create_container "$INDEXER_CTID"   "${CT_PREFIX}-indexer"   "$INDEXER_CPU"   "$INDEXER_RAM"   "$INDEXER_DISK"   "$INDEXER_NET"
  create_container "$MANAGER_CTID"   "${CT_PREFIX}-manager"   "$MANAGER_CPU"   "$MANAGER_RAM"   "$MANAGER_DISK"   "$MANAGER_NET"
  create_container "$DASHBOARD_CTID" "${CT_PREFIX}-dashboard" "$DASHBOARD_CPU" "$DASHBOARD_RAM" "$DASHBOARD_DISK" "$DASHBOARD_NET"

  start_container "$INDEXER_CTID"
  start_container "$MANAGER_CTID"
  start_container "$DASHBOARD_CTID"

  INDEXER_IP=$(get_container_ip "$INDEXER_CTID")
  MANAGER_IP=$(get_container_ip "$MANAGER_CTID")
  DASHBOARD_IP=$(get_container_ip "$DASHBOARD_CTID")

  echo ""
  echo -e "${BL}Assigned IPs:${CL}"
  echo -e "  Indexer:   ${GN}${INDEXER_IP}${CL}"
  echo -e "  Manager:   ${GN}${MANAGER_IP}${CL}"
  echo -e "  Dashboard: ${GN}${DASHBOARD_IP}${CL}"
  echo ""

  if [[ "$INDEXER_IP" == "unknown" || "$MANAGER_IP" == "unknown" || "$DASHBOARD_IP" == "unknown" ]]; then
    msg_error "Could not retrieve IP address for one or more containers."
    exit 1
  fi

  setup_container_base "$INDEXER_CTID"
  setup_container_base "$MANAGER_CTID"
  setup_container_base "$DASHBOARD_CTID"

  download_installer "$INDEXER_CTID"
  download_installer "$MANAGER_CTID"
  download_installer "$DASHBOARD_CTID"

  msg_info "Generating Wazuh cluster configuration and TLS certificates"
  exec_in_ct "$INDEXER_CTID" "
    cd /root
    cat > config.yml <<CONFIGEOF
nodes:
  indexer:
    - name: indexer
      ip: \"${INDEXER_IP}\"
  manager:
    - name: manager
      ip: \"${MANAGER_IP}\"
  dashboard:
    - name: dashboard
      ip: \"${DASHBOARD_IP}\"
CONFIGEOF

    bash ${WAZUH_INSTALLER} --generate-config-files &>/dev/null
  "
  msg_ok "Certificates generated"

  msg_info "Syncing certificates across nodes"
  pct pull "$INDEXER_CTID" /root/wazuh-install-files.tar /tmp/wazuh-install-files.tar &>/dev/null
  pct push "$MANAGER_CTID" /tmp/wazuh-install-files.tar /root/wazuh-install-files.tar &>/dev/null
  pct push "$DASHBOARD_CTID" /tmp/wazuh-install-files.tar /root/wazuh-install-files.tar &>/dev/null
  rm -f /tmp/wazuh-install-files.tar
  msg_ok "Certificates synchronized"

  msg_info "Installing Wazuh Indexer (CT ${INDEXER_CTID})..."
  exec_in_ct "$INDEXER_CTID" "cd /root && bash ${WAZUH_INSTALLER} --wazuh-indexer indexer -id -d pre-release &>/dev/null"
  msg_ok "Wazuh Indexer installed"

  msg_info "Starting and initializing Indexer cluster..."
  exec_in_ct "$INDEXER_CTID" "cd /root && bash ${WAZUH_INSTALLER} --start-cluster &>/dev/null"
  msg_ok "Indexer cluster initialized"

  msg_info "Installing Wazuh Manager (CT ${MANAGER_CTID})..."
  exec_in_ct "$MANAGER_CTID" "cd /root && bash ${WAZUH_INSTALLER} --wazuh-server manager -id -d pre-release &>/dev/null"
  msg_ok "Wazuh Manager installed"

  msg_info "Installing Wazuh Dashboard (CT ${DASHBOARD_CTID})..."
  exec_in_ct "$DASHBOARD_CTID" "cd /root && bash ${WAZUH_INSTALLER} --wazuh-dashboard dashboard -id -d pre-release &>/dev/null"
  msg_ok "Wazuh Dashboard installed"

  echo ""
  echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${GN}  Wazuh 5.0 Beta 5 Distributed Deployment Succeeded!${CL}"
  echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "  Dashboard: https://${DASHBOARD_IP}"
  echo -e "  User:      admin"
  echo -e "  Password:  admin"
  echo -e "  LXC Root:  wazuh"
  echo ""
}

main "$@"
