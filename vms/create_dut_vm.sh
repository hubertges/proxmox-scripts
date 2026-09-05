#!/usr/bin/env bash
# ==============================================================================
# vms/create_dut_vm.sh
# Proxmox VE Helper Script: Automated Device Under Test (DUT) VM Deployment
# Target: VyOS / OpenWrt / MikroTik CHR / Debian Router on Proxmox VE
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
    echo -e "${RD}[!] Error: Run this script directly on your Proxmox VE host.${CL}" >&2
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

clear
cat << "BANNER"
  ____  _   _ _____   ____             _             
 |  _ \| | | |_   _| |  _ \  ___ _ __ | | ___  _   _ 
 | | | | | | | | |   | | | |/ _ \ '_ \| |/ _ \| | | |
 | |_| | |_| | | |   | |_| |  __/ |_) | | (_) | |_| |
 |____/ \___/  |_|   |____/ \___| .__/|_|\___/ \__, |
                                |_|            |___/ 
  Proxmox VE Helper Script: Router Device Under Test (DUT)
BANNER
echo -e "${BL}Automated Router Appliance Deployment for Network Testing${CL}\n"

DUT_DEFAULT="${DUT_TYPE:-vyos}"
DUT_TYPE=$(whiptail --backtitle "Proxmox DUT Deployment" --title "SELECT DUT SYSTEM" --menu \
    "Choose which router operating system to deploy as DUT:" 15 65 4 \
    "vyos" "VyOS Network OS (Enterprise Open Source)" \
    "openwrt" "OpenWrt Router (SOHO / Embedded Benchmark)" \
    "mikrotik" "MikroTik Cloud Hosted Router (RouterOS v7)" \
    "debian" "Debian Linux DUT (nftables / iproute2 / BIRD)" 3>&1 1>&2 2>&3 || echo "$DUT_DEFAULT")
DUT_TYPE="${DUT_TYPE:-$DUT_DEFAULT}"

NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
DEFAULT_VMID="${DUT_VMID:-$NEXT_ID}"
VMID=$(whiptail --backtitle "Proxmox DUT Deployment" --inputbox "Set DUT Virtual Machine ID:" 8 58 "$DEFAULT_VMID" --title "VM ID" 3>&1 1>&2 2>&3 || echo "$DEFAULT_VMID")
VMID="${VMID:-$DEFAULT_VMID}"
VM_NAME=$(whiptail --backtitle "Proxmox DUT Deployment" --inputbox "Set Hostname:" 8 58 "${DUT_HOSTNAME:-dut-${DUT_TYPE}-node}" --title "VM NAME" 3>&1 1>&2 2>&3 || echo "${DUT_HOSTNAME:-dut-${DUT_TYPE}-node}")
VM_NAME="${VM_NAME:-dut-${DUT_TYPE}-node}"

STORAGE=$(select_storage "images" "Select Storage for VM Disk" "${DEFAULT_STORAGE:-}")

WAN_BR="${WAN_BRIDGE:-vmbr10}"
LAN_BR="${LAN_BRIDGE:-vmbr20}"
MGMT_BR="${MGMT_BRIDGE:-vmbr0}"

CORES="${DUT_CORES:-4}"
RAM="${DUT_RAM_MB:-4096}"

echo -e "\n${BL}[*] Creating ${DUT_TYPE} VM [ID: ${VMID}]...${CL}"

qm create "$VMID" \
    --name "$VM_NAME" \
    --ostype l26 \
    --memory "$RAM" \
    --cores "$CORES" \
    --cpu host \
    --scsihw virtio-scsi-pci \
    --net0 "virtio,bridge=${MGMT_BR},firewall=1" \
    --net1 "virtio,bridge=${WAN_BR},firewall=0,mtu=9000" \
    --net2 "virtio,bridge=${LAN_BR},firewall=0,mtu=9000"

echo -e "${GN}[+] DUT VM ${VMID} created with WAN wired to ${WAN_BR} and LAN wired to ${LAN_BR}.${CL}"
echo -e "Attach installation ISO or disk image in Proxmox and start: ${BL}qm start ${VMID}${CL}\n"
