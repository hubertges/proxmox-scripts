#!/usr/bin/env bash
# ==============================================================================
# ct/create_snmp_lxc.sh
# Proxmox VE Helper Script: Automated SNMP & Syslog Collector LXC Deployment
# Style: Proxmox Community Helper Scripts (tteck / community-scripts standard)
#
# Target Hypervisor: Proxmox VE 8.x / 9.x
# Target Container:  Debian GNU/Linux (Standard Minimal Template)
# ==============================================================================

set -euo pipefail

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")

# Load environment configuration if available (.env)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${REPO_DIR}/.env" ]]; then
    # shellcheck source=/dev/null
    source "${REPO_DIR}/.env"
fi

if ! command -v pveversion >/dev/null 2>&1; then
    echo -e "${RD}[!] Error: This script must be executed on your Proxmox VE host node.${CL}" >&2
    exit 1
fi

# Ensure jq is installed if possible, but do not fail if apt cannot run
if ! command -v jq >/dev/null 2>&1; then
    echo -e "${YW}[*] 'jq' package not found. Installing jq on Proxmox host...${CL}"
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y jq >/dev/null 2>&1 || true
fi

## Helper: Query local active PVE storage pools safely (filtering by node affinity and active status)
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

# Helper: Interactive Whiptail Storage Radiolist Menu (Community-Scripts Standard)
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

    echo -e "${YW}[*] Waiting for network lease (IPv4 & IPv6) on bridge '${bridge}'...${CL}"
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
        echo -e "${GN}[+] Acquired IPv4: ${ip4_cidr} (Gateway: ${gw4:-none})${CL}"
    else
        net_str+=",ip=dhcp"
        echo -e "${YW}[!] IPv4 not acquired via DHCP within timeout, keeping dhcp.${CL}"
    fi

    if [[ -n "$ip6_cidr" ]]; then
        net_str+=",ip6=${ip6_cidr}"
        [[ -n "$gw6" ]] && net_str+=",gw6=${gw6}"
        echo -e "${GN}[+] Acquired IPv6: ${ip6_cidr} (Gateway: ${gw6:-none})${CL}"
    fi

    echo -e "${BL}[*] Locking network lease into STATIC IP configuration in Proxmox VE (pct set)...${CL}"
    pct set "$ctid" -net0 "$net_str" >/dev/null 2>&1 || true

    CT_IP_V4="${ip4_cidr%%/*}"
    CT_IP_V6="${ip6_cidr%%/*}"
    CT_IP="${CT_IP_V4:-DHCP}"
}

clear
cat << "BANNER"
  ____  _   _ __  __ ____    ____      _ _           _             
 / ___|| \ | |  \/  |  _ \  / ___|___ | | | ___  ___| |_ ___  _ __ 
 \___ \|  \| | |\/| | |_) || |   / _ \| | |/ _ \/ __| __/ _ \| '__|
  ___) | |\  | |  | |  __/ | |__| (_) | | |  __/ (__| || (_) | |   
 |____/|_| \_|_|  |_|_|     \____\___/|_|_|\___|\___|\__\___/|_|   
  Proxmox VE Helper Script: SNMP & Syslog Collector LXC
BANNER
echo -e "${BL}Central Telemetry & Audit Node for Router Performance Evaluation${CL}\n"

# 1. Interactive Parameter Selection (Proxmox Helper Scripts standard)
NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")

if command -v whiptail >/dev/null 2>&1 && [[ -t 0 ]]; then
    if whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "SETTINGS" \
        --yes-button "Default" \
        --no-button "Advanced" \
        --yesno "Use Default Settings for SNMP Collector LXC Container?" 10 58; then
        # Default Settings
        echo -e "${BL}Using Default Settings${CL}"
        CTID="${SNMP_CTID:-$NEXT_ID}"
        HOSTNAME="${SNMP_HOSTNAME:-snmp-telemetry-collector}"
        CORES="${SNMP_CORES:-2}"
        RAM="${SNMP_RAM_MB:-2048}"
        MGMT_BR="${MGMT_BRIDGE:-ProxNET}"
        STORAGE=$(select_storage "rootdir" "Select Storage for Container Rootfs" "${DEFAULT_STORAGE:-}")
    else
        # Advanced Settings
        echo -e "${YW}Using Advanced Settings${CL}"
        CTID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Container ID (CTID):" 8 58 "$NEXT_ID" --title "CONTAINER ID" 3>&1 1>&2 2>&3 || echo "$NEXT_ID")
        CTID="${CTID:-$NEXT_ID}"

        HOSTNAME=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Hostname:" 8 58 "${SNMP_HOSTNAME:-snmp-telemetry-collector}" --title "HOSTNAME" 3>&1 1>&2 2>&3 || echo "${SNMP_HOSTNAME:-snmp-telemetry-collector}")
        HOSTNAME="${HOSTNAME:-${SNMP_HOSTNAME:-snmp-telemetry-collector}}"

        CORES=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate CPU Cores:" 8 58 "${SNMP_CORES:-2}" --title "CPU ALLOCATION" 3>&1 1>&2 2>&3 || echo "${SNMP_CORES:-2}")
        CORES="${CORES:-2}"

        RAM=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate RAM in MB:" 8 58 "${SNMP_RAM_MB:-2048}" --title "RAM ALLOCATION" 3>&1 1>&2 2>&3 || echo "${SNMP_RAM_MB:-2048}")
        RAM="${RAM:-2048}"

        STORAGE=$(select_storage "rootdir" "Select Storage for Container Rootfs" "${DEFAULT_STORAGE:-}")

        MGMT_BR=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Network Bridge (ProxNET for Reverse Proxy):" 8 58 "${MGMT_BRIDGE:-ProxNET}" --title "BRIDGE" 3>&1 1>&2 2>&3 || echo "${MGMT_BRIDGE:-ProxNET}")
        MGMT_BR="${MGMT_BR:-ProxNET}"
    fi
else
    CTID="${SNMP_CTID:-$NEXT_ID}"
    HOSTNAME="${SNMP_HOSTNAME:-snmp-telemetry-collector}"
    CORES="${SNMP_CORES:-2}"
    RAM="${SNMP_RAM_MB:-2048}"
    MGMT_BR="${MGMT_BRIDGE:-ProxNET}"
    STORAGE=$(select_storage "rootdir" "Select Storage for Container Rootfs" "${DEFAULT_STORAGE:-}")
fi

# 2. Template Selection & Download
TMPL_STORAGE=$(select_storage "vztmpl" "Select Template Storage Pool" "${TEMPLATE_STORAGE:-}")

echo -e "${YW}[*] Checking Debian standard LXC template...${CL}"
pveam update > /dev/null 2>&1 || true
mapfile -t AVAILABLE_TEMPLATES < <(pveam available -section system 2>/dev/null | awk '/debian-[1-9][0-9]-standard/ {print $2}' || true)
CHOSEN_TMPL="${AVAILABLE_TEMPLATES[0]:-debian-12-standard_12.7-1_amd64.tar.zst}"

if ! pveam list "$TMPL_STORAGE" 2>/dev/null | grep -q "$CHOSEN_TMPL"; then
    echo -e "${YW}[*] Downloading container template ${CHOSEN_TMPL}...${CL}"
    pveam download "$TMPL_STORAGE" "$CHOSEN_TMPL"
else
    echo -e "${GN}[+] Container template ${CHOSEN_TMPL} already available on storage '${TMPL_STORAGE}'.${CL}"
fi

# 3. Create Unprivileged LXC Container on ProxNET with DHCP & SLAAC
echo -e "${BL}[*] Creating LXC Container [CTID: ${CTID}, Hostname: ${HOSTNAME}] on bridge '${MGMT_BR}'...${CL}"
pct create "$CTID" "${TMPL_STORAGE}:vztmpl/${CHOSEN_TMPL}" \
    --hostname "$HOSTNAME" \
    --ostype debian \
    --cores "$CORES" \
    --memory "$RAM" \
    --swap 512 \
    --storage "$STORAGE" \
    --rootfs "${STORAGE}:8" \
    --net0 "name=eth0,bridge=${MGMT_BR},firewall=0,ip=dhcp,ip6=auto" \
    --features nesting=1 \
    --unprivileged 1 \
    --onboot 1

# 4. Start Container
echo -e "${YW}[*] Starting container ${CTID}...${CL}"
pct start "$CTID"
sleep 5

# 5. Lock DHCP/SLAAC lease into STATIC IP configuration
freeze_container_network "$CTID" "$MGMT_BR"

# 6. Execute Telemetry Installation Inside Container
echo -e "${BL}[*] Installing SNMP, snmptrapd, rsyslog, and poller daemon inside container...${CL}"

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install/install_snmp_collector.sh"

if [[ -f "$SCRIPT_PATH" ]]; then
    pct push "$CTID" "$SCRIPT_PATH" /tmp/install_snmp_collector.sh
    pct exec "$CTID" -- bash /tmp/install_snmp_collector.sh
    pct exec "$CTID" -- rm -f /tmp/install_snmp_collector.sh
else
    pct exec "$CTID" -- bash -c "apt-get update -y && apt-get install -y snmp snmpd snmptrapd rsyslog curl jq python3"
fi

echo -e "\n${GN}========================================================================${CL}"
echo -e "${GN}  SNMP Telemetry Collector Container Deployed! [CTID: ${CTID}]           ${CL}"
echo -e "${GN}========================================================================${CL}"
echo -e "Network Bridge:       ${BL}${MGMT_BR}${CL} (Reverse Proxy Backend Network)"
echo -e "Static IPv4 Address:  ${BL}${CT_IP}${CL}"
[[ -n "${CT_IP_V6:-}" ]] && echo -e "Static IPv6 Address:  ${BL}${CT_IP_V6}${CL}"
echo -e "SNMP Trap Receiver:   ${BL}${CT_IP}:162 (UDP)${CL}"
echo -e "Syslog Server:        ${BL}${CT_IP}:514 (UDP/TCP)${CL}"
echo -e "Access Console:       ${BL}pct enter ${CTID}${CL}\n"
