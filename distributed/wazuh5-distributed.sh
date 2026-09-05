#!/usr/bin/env bash

# ============================================================================
# Wazuh 5.0 Beta 5 — Distributed Proxmox LXC Deployment
# Creates 3 LXC containers:
#   1. Wazuh Indexer   (OpenSearch-based distributed search engine)
#   2. Wazuh Manager   (Core analysis engine & agent communication)
#   3. Wazuh Dashboard (Web UI management portal)
#
# Network Architecture:
#   • net0 (Frontend / Reverse Proxy):
#     Bridge 'ProxNET' with dynamic DHCP/SLAAC acquisition, immediately
#     frozen to STATIC IPv4 and IPv6 configuration in Proxmox VE.
#   • net1 (Private Cluster SDN):
#     SDN VNet 'wazuhcl' (Alias: 'Wazuh-cluster-net', VLAN > 1500, Tag: 1669)
#     Subnet: 10.69.101.0/24 (Address space 10.69.101-250.0/24 for expansion)
#     - Indexer:   10.69.101.10/24
#     - Manager:   10.69.101.11/24
#     - Dashboard: 10.69.101.12/24
#
# Inspired by: Proxmox VE Helper-Scripts (community-scripts standard)
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

# Load repository environment configuration (.env)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${REPO_DIR}/.env" ]]; then
    # shellcheck source=/dev/null
    source "${REPO_DIR}/.env"
fi

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
  Dual Network: ProxNET (Reverse Proxy) + Wazuh-cluster-net (SDN VLAN > 1500)
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
  if ! command -v jq &>/dev/null; then
    msg_info "Installing jq on host"
    DEBIAN_FRONTEND=noninteractive apt-get update -y &>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y jq &>/dev/null || true
    msg_ok "jq ready"
  fi
  msg_ok "Environment: Proxmox VE $(pveversion | awk -F'/' '{print $2}')"
}

# Query local active PVE storage pools safely (filtering by node affinity and active status)
get_local_pve_storages() {
    local content_type="$1"
    local -a list=()

    if command -v pvesm >/dev/null 2>&1; then
        while IFS= read -r line; do
            local s_name s_type s_status _ _ s_avail _
            read -r s_name s_type s_status _ _ s_avail _ <<< "$line"
            if [[ -n "$s_name" && "$s_name" != "Name" ]]; then
                if [[ "$s_status" == "active" || -z "$s_status" ]]; then
                    list+=("$s_name $s_type ${s_avail:-0}")
                fi
            fi
        done < <(pvesm status -content "$content_type" 2>/dev/null || true)
    fi

    if [[ ${#list[@]} -eq 0 && -f /etc/pve/storage.cfg ]]; then
        local my_node
        my_node=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "")
        while IFS= read -r line; do
            [[ -n "$line" ]] && list+=("$line")
        done < <(awk -v c="$content_type" -v node="$my_node" '
            /^[a-z0-9_-]+:[[:space:]]+/ {
                cur = $2
                sub(/^[a-z0-9_-]+:[[:space:]]*/, "", cur)
                sub(/[[:space:]].*$/, "", cur)
                has_content = 0
                node_match = 1
                disabled = 0
            }
            /^[[:space:]]+disable/ { disabled = 1 }
            /^[[:space:]]+nodes[[:space:]]+/ {
                nodes_list = $0
                sub(/^[[:space:]]+nodes[[:space:]]+/, "", nodes_list)
                if (node != "" && nodes_list !~ "(^|,)" node "(,|$)") {
                    node_match = 0
                }
            }
            /^[[:space:]]+content[[:space:]]+/ {
                if ($0 ~ c) has_content = 1
            }
            cur && has_content && node_match && !disabled {
                print cur " local active 0 0 0 0%"
                has_content = 0
            }
        ' /etc/pve/storage.cfg 2>/dev/null || true)
    fi

    for item in "${list[@]}"; do
        echo "$item"
    done
}

# Interactive Whiptail Storage Radiolist Menu (Community-Scripts Standard)
select_storage() {
    local content_type="$1"
    local title="$2"
    local default_stor="${3:-}"

    local -a storage_lines=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && storage_lines+=("$line")
    done < <(get_local_pve_storages "$content_type")

    local count=${#storage_lines[@]}
    if [[ $count -eq 0 ]]; then
        echo "${default_stor:-local}"
        return
    fi

    if [[ $count -eq 1 ]]; then
        local single_name
        read -r single_name _ <<< "${storage_lines[0]}"
        echo "$single_name"
        return
    fi

    if ! command -v whiptail >/dev/null 2>&1 || [[ ! -t 0 ]]; then
        if [[ -n "$default_stor" ]]; then
            for line in "${storage_lines[@]}"; do
                local s_name
                read -r s_name _ <<< "$line"
                if [[ "$s_name" == "$default_stor" ]]; then
                    echo "$default_stor"
                    return
                fi
            done
        fi
        local first_name
        read -r first_name _ <<< "${storage_lines[0]}"
        echo "$first_name"
        return
    fi

    local menu_items=()
    local first=1
    for line in "${storage_lines[@]}"; do
        local s_name s_type s_avail_raw
        read -r s_name s_type s_avail_raw <<< "$line"
        local s_free="N/A"
        if [[ -n "$s_avail_raw" && "$s_avail_raw" =~ ^[0-9]+$ && "$s_avail_raw" -gt 0 ]]; then
            s_free=$(numfmt --to=iec --from-unit=K "$s_avail_raw" 2>/dev/null || echo "${s_avail_raw}K")
        fi

        local is_on="OFF"
        if [[ -n "$default_stor" && "$s_name" == "$default_stor" ]]; then
            is_on="ON"
        elif [[ -z "$default_stor" && $first -eq 1 ]]; then
            is_on="ON"
            first=0
        fi

        menu_items+=("$s_name" "Type: ${s_type} | Free: ${s_free}" "$is_on")
    done

    local selected
    selected=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "$title" \
        --radiolist "Select storage pool on node '$(hostname)':" \
        16 68 $((count > 8 ? 8 : count)) \
        "${menu_items[@]}" 3>&1 1>&2 2>&3) || true

    if [[ -z "$selected" ]]; then
        local first_name
        read -r first_name _ <<< "${storage_lines[0]}"
        selected="$first_name"
    fi

    echo "$selected"
}

# Helper: Fetch dynamic IPv4 & IPv6 leases from ProxNET and freeze them as STATIC in Proxmox VE
freeze_container_network() {
    local ctid="$1"
    local bridge="$2"

    msg_info "Waiting for network lease (IPv4 & IPv6) on CT ${ctid} (${bridge})"
    local ip4_cidr="" gw4="" ip6_cidr="" gw6=""
    
    # Wait for IPv4 lease
    for i in {1..30}; do
        ip4_cidr=$(pct exec "$ctid" -- ip -4 -o addr show dev eth0 scope global 2>/dev/null | awk '{print $4}' | head -n1 || true)
        if [[ -n "$ip4_cidr" ]]; then
            break
        fi
        sleep 1
    done

    # Give IPv6 SLAAC / DHCPv6 a few seconds to finish router solicitation & DAD
    for i in {1..10}; do
        ip6_cidr=$(pct exec "$ctid" -- ip -6 -o addr show dev eth0 scope global 2>/dev/null | grep -v 'tentative' | awk '{print $4}' | head -n1 || true)
        if [[ -n "$ip6_cidr" ]]; then
            break
        fi
        sleep 1
    done

    gw4=$(pct exec "$ctid" -- ip -4 route show default dev eth0 2>/dev/null | awk '/default/ {print $3}' | head -n1 || true)
    [[ -z "$gw4" ]] && gw4=$(pct exec "$ctid" -- ip -4 route show default 2>/dev/null | awk '/default/ {print $3}' | head -n1 || true)

    gw6=$(pct exec "$ctid" -- ip -6 route show default dev eth0 2>/dev/null | awk '/default/ {print $3}' | head -n1 || true)
    [[ -z "$gw6" ]] && gw6=$(pct exec "$ctid" -- ip -6 route show default 2>/dev/null | awk '/default/ {print $3}' | head -n1 || true)

    local net_str="name=eth0,bridge=${bridge},firewall=0"
    if [[ -n "$ip4_cidr" ]]; then
        net_str+=",ip=${ip4_cidr}"
        [[ -n "$gw4" ]] && net_str+=",gw=${gw4}"
    else
        net_str+=",ip=dhcp"
    fi

    if [[ -n "$ip6_cidr" ]]; then
        net_str+=",ip6=${ip6_cidr}"
        [[ -n "$gw6" ]] && net_str+=",gw6=${gw6}"
    fi

    pct set "$ctid" -net0 "$net_str" >/dev/null 2>&1 || true

    local ret_ip4="${ip4_cidr%%/*}"
    local ret_ip6="${ip6_cidr%%/*}"
    msg_ok "CT ${ctid} locked to STATIC IP: ${ret_ip4:-DHCP}${ret_ip6:+, IPv6: ${ret_ip6}}"
    echo "${ret_ip4:-DHCP}"
}

# Resolve cluster interface net1 configuration string (SDN VNet vs VLAN Bridge)
get_cluster_net_param() {
    local ip="$1"
    local netmask="${CLUSTER_NETMASK:-24}"

    if pvesdn vnet list 2>/dev/null | grep -qw "$SDN_VNET" || ip link show "$SDN_VNET" >/dev/null 2>&1; then
        echo "name=eth1,bridge=${SDN_VNET},firewall=0,ip=${ip}/${netmask}"
    else
        echo "name=eth1,bridge=${BRIDGE},tag=${CLUSTER_VLAN_TAG},firewall=0,ip=${ip}/${netmask}"
    fi
}

# ----------------------------------------------------------------------------
# Defaults & Global Parameters
# ----------------------------------------------------------------------------
BRIDGE="${MGMT_BRIDGE:-ProxNET}"
SDN_VNET="${SDN_VNET:-wazuhcl}"
SDN_ALIAS="${SDN_ALIAS:-Wazuh-cluster-net}"
CLUSTER_VLAN_TAG="${CLUSTER_VLAN_TAG:-1669}"
CLUSTER_NETMASK="${CLUSTER_NETMASK:-24}"

INDEXER_CLUSTER_IP="${INDEXER_CLUSTER_IP:-10.69.101.10}"
MANAGER_CLUSTER_IP="${MANAGER_CLUSTER_IP:-10.69.101.11}"
DASHBOARD_CLUSTER_IP="${DASHBOARD_CLUSTER_IP:-10.69.101.12}"

OSTEMPLATE="${OSTEMPLATE:-ubuntu-24.04-standard_24.04-2_amd64.tar.zst}"

INDEXER_CTID="${INDEXER_CTID:-}"
MANAGER_CTID="${MANAGER_CTID:-}"
DASHBOARD_CTID="${DASHBOARD_CTID:-}"

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
  pvesh get /cluster/nextid 2>/dev/null || echo "100"
}

ensure_template() {
  msg_info "Checking template on '${TEMPLATE_STORAGE}'"
  
  local found_tmpl=""
  found_tmpl=$(pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | grep -oP '\S+ubuntu-24\.04\S+' | head -n1 || true)
  
  if [[ -n "$found_tmpl" ]]; then
    OSTEMPLATE=$(basename "$found_tmpl")
    msg_ok "Using cached template: ${OSTEMPLATE}"
    return 0
  fi

  msg_warn "Template not cached locally on '${TEMPLATE_STORAGE}'. Updating pveam and downloading..."
  pveam update &>/dev/null || true

  local avail_tmpl
  avail_tmpl=$(pveam available --section system 2>/dev/null | grep -oP 'ubuntu-24\.04-standard\S+' | head -n1 || true)
  if [[ -n "$avail_tmpl" ]]; then
    OSTEMPLATE="$avail_tmpl"
  fi

  pveam download "${TEMPLATE_STORAGE}" "${OSTEMPLATE}" || {
    msg_error "Failed to download template to storage '${TEMPLATE_STORAGE}'."
    exit 1
  }
  msg_ok "OS template ready: ${OSTEMPLATE}"
}

create_container() {
  local ctid="$1" hostname="$2" cpu="$3" ram="$4" disk="$5" cluster_ip="$6"
  msg_info "Creating LXC Container ${ctid} (${hostname})"
  
  local net1_param
  net1_param=$(get_cluster_net_param "$cluster_ip")

  pct create "${ctid}" "${TEMPLATE_STORAGE}:vztmpl/${OSTEMPLATE}" \
    --hostname "${hostname}" \
    --cores "${cpu}" \
    --memory "${ram}" \
    --swap 512 \
    --storage "${STORAGE}" \
    --rootfs "${STORAGE}:${disk}" \
    --net0 "name=eth0,bridge=${BRIDGE},firewall=0,ip=dhcp,ip6=auto" \
    --net1 "${net1_param}" \
    --ostype ubuntu \
    --unprivileged 0 \
    --features nesting=1,keyctl=1 \
    --onboot 1 \
    --start 0 \
    --password "wazuh" \
    --description "Wazuh 5.0 Beta 5 - ${hostname}" &>/dev/null
  msg_ok "LXC Container ${ctid} created (Dual-homed: ProxNET + Wazuh-cluster-net)"
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

  # 1. Interactive Parameter Selection (Community-Scripts Standard)
  local next_id
  next_id=$(get_next_ctid)

  if command -v whiptail >/dev/null 2>&1 && [[ -t 0 ]]; then
      if whiptail --backtitle "Proxmox VE Helper Scripts" \
          --title "SETTINGS" \
          --yes-button "Default" \
          --no-button "Advanced" \
          --yesno "Use Default Settings for Wazuh 5 Distributed Cluster (3 Containers)?\n\n• Frontend Bridge:  ${BRIDGE}\n• Cluster SDN VNet: ${SDN_VNET} (VLAN ${CLUSTER_VLAN_TAG})\n• Cluster Subnet:   10.69.101.0/24 (10.69.101.10-12)\n• Storage:          Auto-detected local pool" 14 68; then
          # Default Settings
          STORAGE=$(select_storage "rootdir" "Select Storage for Container Disks" "${DEFAULT_STORAGE:-}")
          TEMPLATE_STORAGE=$(select_storage "vztmpl" "Select Storage for Container Templates" "${TEMPLATE_STORAGE:-}")
          INDEXER_CTID="${INDEXER_CTID:-$next_id}"
          MANAGER_CTID="${MANAGER_CTID:-$((INDEXER_CTID + 1))}"
          DASHBOARD_CTID="${DASHBOARD_CTID:-$((MANAGER_CTID + 1))}"
      else
          # Advanced Settings
          INDEXER_CTID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Wazuh Indexer CTID:" 8 58 "$next_id" --title "INDEXER CTID" 3>&1 1>&2 2>&3 || echo "$next_id")
          INDEXER_CTID="${INDEXER_CTID:-$next_id}"

          local def_mgr=$((INDEXER_CTID + 1))
          MANAGER_CTID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Wazuh Manager CTID:" 8 58 "$def_mgr" --title "MANAGER CTID" 3>&1 1>&2 2>&3 || echo "$def_mgr")
          MANAGER_CTID="${MANAGER_CTID:-$def_mgr}"

          local def_dsh=$((MANAGER_CTID + 1))
          DASHBOARD_CTID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Wazuh Dashboard CTID:" 8 58 "$def_dsh" --title "DASHBOARD CTID" 3>&1 1>&2 2>&3 || echo "$def_dsh")
          DASHBOARD_CTID="${DASHBOARD_CTID:-$def_dsh}"

          STORAGE=$(select_storage "rootdir" "Select Storage for Container Disks" "${DEFAULT_STORAGE:-}")
          TEMPLATE_STORAGE=$(select_storage "vztmpl" "Select Storage for Container Templates" "${TEMPLATE_STORAGE:-}")

          BRIDGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Frontend Bridge (ProxNET for Reverse Proxy):" 8 58 "${BRIDGE}" --title "FRONTEND BRIDGE" 3>&1 1>&2 2>&3 || echo "${BRIDGE}")
          BRIDGE="${BRIDGE:-ProxNET}"

          SDN_VNET=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Cluster SDN VNet (or bridge name):" 8 58 "${SDN_VNET}" --title "SDN VNET" 3>&1 1>&2 2>&3 || echo "${SDN_VNET}")
          SDN_VNET="${SDN_VNET:-wazuhcl}"
      fi
  else
      STORAGE=$(select_storage "rootdir" "Select Storage for Container Disks" "${DEFAULT_STORAGE:-}")
      TEMPLATE_STORAGE=$(select_storage "vztmpl" "Select Storage for Container Templates" "${TEMPLATE_STORAGE:-}")
      INDEXER_CTID="${INDEXER_CTID:-$next_id}"
      MANAGER_CTID="${MANAGER_CTID:-$((INDEXER_CTID + 1))}"
      DASHBOARD_CTID="${DASHBOARD_CTID:-$((MANAGER_CTID + 1))}"
  fi

  # Auto-resolve non-colliding CTIDs
  while pct status "$MANAGER_CTID" &>/dev/null; do ((MANAGER_CTID++)); done
  while pct status "$DASHBOARD_CTID" &>/dev/null || [[ "$DASHBOARD_CTID" -eq "$MANAGER_CTID" ]]; do ((DASHBOARD_CTID++)); done

  echo -e "\n${BL}Deployment Summary:${CL}"
  echo -e "  • Frontend Network:      Bridge '${GN}${BRIDGE}${CL}' (ProxNET / Reverse Proxy, DHCP -> Static)"
  echo -e "  • Cluster Network:       SDN '${GN}${SDN_VNET}${CL}' (Alias: ${SDN_ALIAS}, VLAN: ${CLUSTER_VLAN_TAG})"
  echo -e "  • Wazuh Indexer   → CT ${GN}${INDEXER_CTID}${CL} (${INDEXER_CPU} cores, ${INDEXER_RAM}MB RAM, ${INDEXER_DISK}GB disk | Cluster IP: ${INDEXER_CLUSTER_IP})"
  echo -e "  • Wazuh Manager   → CT ${GN}${MANAGER_CTID}${CL} (${MANAGER_CPU} cores, ${MANAGER_RAM}MB RAM, ${MANAGER_DISK}GB disk | Cluster IP: ${MANAGER_CLUSTER_IP})"
  echo -e "  • Wazuh Dashboard → CT ${GN}${DASHBOARD_CTID}${CL} (${DASHBOARD_CPU} cores, ${DASHBOARD_RAM}MB RAM, ${DASHBOARD_DISK}GB disk | Cluster IP: ${DASHBOARD_CLUSTER_IP})"
  echo -e "  • Storage:               Disk: ${GN}${STORAGE}${CL} | Template: ${GN}${TEMPLATE_STORAGE}${CL}"
  echo ""

  ensure_template

  # 2. Container Creation (Dual-Homed)
  create_container "$INDEXER_CTID"   "${CT_PREFIX}-indexer"   "$INDEXER_CPU"   "$INDEXER_RAM"   "$INDEXER_DISK"   "$INDEXER_CLUSTER_IP"
  create_container "$MANAGER_CTID"   "${CT_PREFIX}-manager"   "$MANAGER_CPU"   "$MANAGER_RAM"   "$MANAGER_DISK"   "$MANAGER_CLUSTER_IP"
  create_container "$DASHBOARD_CTID" "${CT_PREFIX}-dashboard" "$DASHBOARD_CPU" "$DASHBOARD_RAM" "$DASHBOARD_DISK" "$DASHBOARD_CLUSTER_IP"

  # 3. Start Containers
  start_container "$INDEXER_CTID"
  start_container "$MANAGER_CTID"
  start_container "$DASHBOARD_CTID"

  # 4. Freeze dynamic DHCP/SLAAC lease on ProxNET (eth0) into permanent STATIC configuration
  msg_info "Locking frontend network leases into STATIC configurations"
  INDEXER_ETH0_IP=$(freeze_container_network "$INDEXER_CTID" "$BRIDGE")
  MANAGER_ETH0_IP=$(freeze_container_network "$MANAGER_CTID" "$BRIDGE")
  DASHBOARD_ETH0_IP=$(freeze_container_network "$DASHBOARD_CTID" "$BRIDGE")

  echo ""
  echo -e "${BL}Network Assignments:${CL}"
  echo -e "  Indexer:   Frontend (ProxNET): ${GN}${INDEXER_ETH0_IP}${CL}  | Cluster SDN: ${BL}${INDEXER_CLUSTER_IP}${CL}"
  echo -e "  Manager:   Frontend (ProxNET): ${GN}${MANAGER_ETH0_IP}${CL}  | Cluster SDN: ${BL}${MANAGER_CLUSTER_IP}${CL}"
  echo -e "  Dashboard: Frontend (ProxNET): ${GN}${DASHBOARD_ETH0_IP}${CL}  | Cluster SDN: ${BL}${DASHBOARD_CLUSTER_IP}${CL}"
  echo ""

  # 5. Base utilities & installer preparation
  setup_container_base "$INDEXER_CTID"
  setup_container_base "$MANAGER_CTID"
  setup_container_base "$DASHBOARD_CTID"

  download_installer "$INDEXER_CTID"
  download_installer "$MANAGER_CTID"
  download_installer "$DASHBOARD_CTID"

  # 6. Generate Wazuh cluster configuration and TLS certificates bound to private SDN Cluster IPs
  msg_info "Generating Wazuh cluster configuration & TLS certs bound to Cluster SDN IPs"
  exec_in_ct "$INDEXER_CTID" "
    cd /root
    cat > config.yml <<CONFIGEOF
nodes:
  indexer:
    - name: indexer
      ip: \"${INDEXER_CLUSTER_IP}\"
  manager:
    - name: manager
      ip: \"${MANAGER_CLUSTER_IP}\"
  dashboard:
    - name: dashboard
      ip: \"${DASHBOARD_CLUSTER_IP}\"
CONFIGEOF

    bash ${WAZUH_INSTALLER} --generate-config-files &>/dev/null
  "
  msg_ok "Certificates generated for cluster network ${INDEXER_CLUSTER_IP}, ${MANAGER_CLUSTER_IP}, ${DASHBOARD_CLUSTER_IP}"

  # 7. Synchronize certificates across nodes
  msg_info "Syncing certificates across cluster nodes"
  pct pull "$INDEXER_CTID" /root/wazuh-install-files.tar /tmp/wazuh-install-files.tar &>/dev/null
  pct push "$MANAGER_CTID" /tmp/wazuh-install-files.tar /root/wazuh-install-files.tar &>/dev/null
  pct push "$DASHBOARD_CTID" /tmp/wazuh-install-files.tar /root/wazuh-install-files.tar &>/dev/null
  rm -f /tmp/wazuh-install-files.tar
  msg_ok "Certificates synchronized"

  # 8. Install cluster components
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
  echo -e "${GN}  Wazuh 5.0 Beta 5 Distributed Cluster Deployed!             ${CL}"
  echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "  Frontend Bridge:     ${BL}${BRIDGE}${CL} (Reverse Proxy Backend)"
  echo -e "  Cluster SDN VNet:    ${BL}${SDN_VNET}${CL} (VLAN ${CLUSTER_VLAN_TAG}, Subnet 10.69.101.0/24)"
  echo -e "  Dashboard Static IP: ${GN}${DASHBOARD_ETH0_IP}${CL} (Cluster SDN: ${BL}${DASHBOARD_CLUSTER_IP}${CL})"
  echo -e "  Manager Static IP:   ${GN}${MANAGER_ETH0_IP}${CL} (Cluster SDN: ${BL}${MANAGER_CLUSTER_IP}${CL})"
  echo -e "  Indexer Static IP:   ${GN}${INDEXER_ETH0_IP}${CL} (Cluster SDN: ${BL}${INDEXER_CLUSTER_IP}${CL})"
  echo -e "  Web GUI Access:      ${BL}https://${DASHBOARD_ETH0_IP}${CL}"
  echo -e "  Default Credentials: ${YW}admin${CL} / ${YW}admin${CL}"
  echo -e "  LXC Root Password:   ${YW}wazuh${CL}"
  echo ""
  echo -e "${YW}--> Reverse Proxy Configuration (ProxNET):${CL}"
  echo -e "Configure your Nginx Reverse Proxy container on bridge '${BRIDGE}':"
  echo -e "  proxy_pass https://${DASHBOARD_ETH0_IP}:443;"
  echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
}

main "$@"
