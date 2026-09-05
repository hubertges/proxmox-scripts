#!/usr/bin/env bash
# ==============================================================================
# ct/create_zabbix_lxc.sh
# Proxmox VE Helper Script: Automated Zabbix 8.0 LTS + PostgreSQL 17 LXC Deployment
# Style: Proxmox Community Helper Scripts (tteck / community-scripts standard)
#
# Target Hypervisor: Proxmox VE 8.x / 9.x
# Target Container:  Debian GNU/Linux 13 (Trixie) - Unprivileged LXC
# Components:        Zabbix Server 8.0, PostgreSQL 17, Zabbix Agent 2, Web GUI
# Documentation:     https://www.zabbix.com/documentation/devel/en/manual
# ==============================================================================

set -euo pipefail

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")

# Load environment configuration if available (.env)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for env_candidate in \
    "${REPO_DIR}/.env" \
    "$(pwd)/.env" \
    "/etc/pve/scripts/.env" \
    "/etc/pve/secrets/.env" \
    "/etc/pve/.env" \
    "$HOME/.env"; do
    if [[ -f "$env_candidate" ]]; then
        # shellcheck source=/dev/null
        source "$env_candidate"
        break
    fi
done

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

# Helper: Query local active PVE storage pools safely (filtering by node affinity and active status)
get_local_pve_storages() {
    local content_type="$1"
    local -a list=()

    # 1. Preferred: pvesm status -content <type> (evaluates active storages on the current node)
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

    # 2. Fallback: parse /etc/pve/storage.cfg filtered by the local node
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

    # If only 1 storage pool exists on this node, pick it directly
    if [[ $count -eq 1 ]]; then
        local single_name
        read -r single_name _ <<< "${storage_lines[0]}"
        echo "$single_name"
        return
    fi

    # Non-interactive / headless fallback
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

    # Build whiptail radiolist menu options: <tag> <item> <status>
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

clear
cat << "BANNER"
  _____ _____ ____  ____ _____  __   ___    ___  
 |__  /|  _  | __ )| __ )_   _| \ \ / / \  / _ \ 
   / / | |_| |  _ \|  _ \ | |    \ V / _ \| | | |
  / /_ |  _  | |_) | |_) || |     | / ___ \ |_| |
 /____||_| |_|____/|____/ |_|     |/_/   \_\___/ 
  Proxmox VE Helper Script: Zabbix 8.0 LTS + PostgreSQL 17
BANNER
echo -e "${BL}Enterprise Monitoring Platform on Debian 13 (Trixie) LXC${CL}\n"

# 1. Interactive Parameter Selection (Proxmox Helper Scripts standard)
NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")

if command -v whiptail >/dev/null 2>&1 && [[ -t 0 ]]; then
    if whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "SETTINGS" \
        --yes-button "Default" \
        --no-button "Advanced" \
        --yesno "Use Default Settings for Zabbix 8.0 LTS LXC Container?" 10 58; then
        # Default Settings
        echo -e "${BL}Using Default Settings${CL}"
        CTID="${ZABBIX_CTID:-$NEXT_ID}"
        HOSTNAME="${ZABBIX_HOSTNAME:-zabbix8-server}"
        CORES="${ZABBIX_CORES:-2}"
        RAM="${ZABBIX_RAM_MB:-4096}"
        SWAP="${ZABBIX_SWAP_MB:-1024}"
        DISK="${ZABBIX_DISK_GB:-16}"
        MGMT_BR="${MGMT_BRIDGE:-vmbr0}"
        STORAGE=$(select_storage "rootdir" "Select Storage for Container Rootfs" "${DEFAULT_STORAGE:-}")
    else
        # Advanced Settings
        echo -e "${YW}Using Advanced Settings${CL}"
        CTID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Container ID (CTID):" 8 58 "$NEXT_ID" --title "CONTAINER ID" 3>&1 1>&2 2>&3 || echo "$NEXT_ID")
        CTID="${CTID:-$NEXT_ID}"

        HOSTNAME=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Hostname:" 8 58 "${ZABBIX_HOSTNAME:-zabbix8-server}" --title "HOSTNAME" 3>&1 1>&2 2>&3 || echo "${ZABBIX_HOSTNAME:-zabbix8-server}")
        HOSTNAME="${HOSTNAME:-${ZABBIX_HOSTNAME:-zabbix8-server}}"

        CORES=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate CPU Cores:" 8 58 "${ZABBIX_CORES:-2}" --title "CPU ALLOCATION" 3>&1 1>&2 2>&3 || echo "${ZABBIX_CORES:-2}")
        CORES="${CORES:-2}"

        RAM=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate RAM in MB:" 8 58 "${ZABBIX_RAM_MB:-4096}" --title "RAM ALLOCATION" 3>&1 1>&2 2>&3 || echo "${ZABBIX_RAM_MB:-4096}")
        RAM="${RAM:-4096}"

        SWAP=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate Swap in MB:" 8 58 "${ZABBIX_SWAP_MB:-1024}" --title "SWAP ALLOCATION" 3>&1 1>&2 2>&3 || echo "${ZABBIX_SWAP_MB:-1024}")
        SWAP="${SWAP:-1024}"

        DISK=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate Disk Size in GB:" 8 58 "${ZABBIX_DISK_GB:-16}" --title "DISK SIZE" 3>&1 1>&2 2>&3 || echo "${ZABBIX_DISK_GB:-16}")
        DISK="${DISK:-16}"

        STORAGE=$(select_storage "rootdir" "Select Storage for Container Rootfs" "${DEFAULT_STORAGE:-}")

        MGMT_BR=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Network Bridge:" 8 58 "${MGMT_BRIDGE:-vmbr0}" --title "BRIDGE" 3>&1 1>&2 2>&3 || echo "${MGMT_BRIDGE:-vmbr0}")
        MGMT_BR="${MGMT_BR:-vmbr0}"
    fi
else
    CTID="${ZABBIX_CTID:-$NEXT_ID}"
    HOSTNAME="${ZABBIX_HOSTNAME:-zabbix8-server}"
    CORES="${ZABBIX_CORES:-2}"
    RAM="${ZABBIX_RAM_MB:-4096}"
    SWAP="${ZABBIX_SWAP_MB:-1024}"
    DISK="${ZABBIX_DISK_GB:-16}"
    MGMT_BR="${MGMT_BRIDGE:-vmbr0}"
    STORAGE=$(select_storage "rootdir" "Select Storage for Container Rootfs" "${DEFAULT_STORAGE:-}")
fi

# 2. Template Selection & Download
TMPL_STORAGE=$(select_storage "vztmpl" "Select Template Storage Pool" "${TEMPLATE_STORAGE:-}")

echo -e "${YW}[*] Checking Debian standard LXC template...${CL}"
pveam update > /dev/null 2>&1 || true

mapfile -t AVAILABLE_DEBIAN13 < <(pveam available -section system 2>/dev/null | awk '/debian-13-standard/ {print $2}' || true)
mapfile -t AVAILABLE_DEBIAN12 < <(pveam available -section system 2>/dev/null | awk '/debian-12-standard/ {print $2}' || true)

if [[ ${#AVAILABLE_DEBIAN13[@]} -gt 0 && -n "${AVAILABLE_DEBIAN13[0]}" ]]; then
    CHOSEN_TMPL="${AVAILABLE_DEBIAN13[0]}"
    echo -e "${GN}[+] Found native Debian 13 (Trixie) template: ${CHOSEN_TMPL}${CL}"
else
    CHOSEN_TMPL="${AVAILABLE_DEBIAN12[0]:-debian-12-standard_12.7-1_amd64.tar.zst}"
    echo -e "${YW}[i] Using Debian template ${CHOSEN_TMPL} (installer will ensure Debian 13 Trixie upgrade)${CL}"
fi

if ! pveam list "$TMPL_STORAGE" 2>/dev/null | grep -q "$CHOSEN_TMPL"; then
    echo -e "${YW}[*] Downloading container template ${CHOSEN_TMPL}...${CL}"
    pveam download "$TMPL_STORAGE" "$CHOSEN_TMPL"
else
    echo -e "${GN}[+] Container template ${CHOSEN_TMPL} already available on storage '${TMPL_STORAGE}'.${CL}"
fi

# 3. Create Unprivileged LXC Container
echo -e "${BL}[*] Creating LXC Container [CTID: ${CTID}, Hostname: ${HOSTNAME}]...${CL}"
pct create "$CTID" "${TMPL_STORAGE}:vztmpl/${CHOSEN_TMPL}" \
    --hostname "$HOSTNAME" \
    --ostype debian \
    --cores "$CORES" \
    --memory "$RAM" \
    --swap "$SWAP" \
    --storage "$STORAGE" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${MGMT_BR},firewall=0,ip=dhcp" \
    --features nesting=1 \
    --unprivileged 1 \
    --onboot 1

# 4. Start Container
echo -e "${YW}[*] Starting container ${CTID}...${CL}"
pct start "$CTID"
sleep 5

# 5. Execute Zabbix 8.0 Installation Inside Container
echo -e "${BL}[*] Installing PostgreSQL 17, Zabbix 8.0, Agent 2, and Web Frontend...${CL}"

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/install/install_zabbix.sh"

if [[ ! -f "$SCRIPT_PATH" ]]; then
    INSTALL_URL="https://raw.githubusercontent.com/hubertges/proxmox-scripts/main/install/install_zabbix.sh"
    echo -e "${YW}[*] Local installer not found, fetching from GitHub (${INSTALL_URL})...${CL}"
    SCRIPT_PATH="/tmp/install_zabbix.sh"
    curl -fsSL "$INSTALL_URL" -o "$SCRIPT_PATH" 2>/dev/null || wget -qO "$SCRIPT_PATH" "$INSTALL_URL"
fi

if [[ -f "$SCRIPT_PATH" ]]; then
    pct push "$CTID" "$SCRIPT_PATH" /tmp/install_zabbix.sh
    # Pass optional DB password from .env if set
    if [[ -n "${ZABBIX_DB_PASSWORD:-}" ]]; then
        pct exec "$CTID" -- env ZABBIX_DB_PASSWORD="${ZABBIX_DB_PASSWORD}" bash /tmp/install_zabbix.sh
    else
        pct exec "$CTID" -- bash /tmp/install_zabbix.sh
    fi
    pct exec "$CTID" -- rm -f /tmp/install_zabbix.sh
else
    echo -e "${RD}[!] Installer script not found at ${SCRIPT_PATH}!${CL}" >&2
    exit 1
fi

echo -e "${YW}[*] Waiting for container network interface and IP allocation...${CL}"
CT_IP=""
for i in {1..15}; do
    CT_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 || true)
    if [[ -n "$CT_IP" ]]; then
        break
    fi
    sleep 1
done
CT_IP="${CT_IP:-DHCP}"

echo -e "\n${GN}========================================================================${CL}"
echo -e "${GN}  Zabbix 8.0 LTS LXC Container Deployed! [CTID: ${CTID}]                 ${CL}"
echo -e "${GN}========================================================================${CL}"
echo -e "Container IP:         ${BL}${CT_IP}${CL}"
echo -e "Internal Web GUI:     ${BL}http://${CT_IP}:8080${CL}"
echo -e "Default Web Login:    ${YW}Admin${CL} / ${YW}zabbix${CL}"
echo -e "Zabbix Server Port:   ${BL}${CT_IP}:10051 (TCP)${CL}"
echo -e "Console Access:       ${BL}pct enter ${CTID}${CL}"
echo -e "\n${YW}--> External Nginx Configuration:${CL}"
echo -e "Nginx reverse proxy configuration template for your other container:"
echo -e "${BL}${REPO_DIR}/system-config/nginx-zabbix-reverse-proxy.conf${CL}"
echo -e "Add it to ${YW}/etc/nginx/conf.d/zabbix.conf${CL} on your Nginx container with:"
echo -e "  ${BL}server ${CT_IP}:8080;${CL}\n"
