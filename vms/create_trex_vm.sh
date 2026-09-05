#!/usr/bin/env bash
# ==============================================================================
# vms/create_trex_vm.sh
# Proxmox VE Helper Script: Automated Cisco TRex Test Generator VM Deployment
# Style: Proxmox Community Helper Scripts (tteck / community-scripts standard)
#
# Target Hypervisor: Proxmox VE 8.x / 9.x
# Target Guest OS:    Debian GNU/Linux 13 (Trixie) Cloud-Init
# ==============================================================================

set -euo pipefail

# Text formatting & Colors
YW=$(echo "[33m")
BL=$(echo "[36m")
RD=$(echo "[01;31m")
GN=$(echo "[1;92m")
CL=$(echo "[m")

# Load environment configuration if available (.env)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${REPO_DIR}/.env" ]]; then
    # shellcheck source=/dev/null
    source "${REPO_DIR}/.env"
fi

# Check Proxmox Host Environment
if ! command -v pveversion >/dev/null 2>&1; then
    echo -e "${RD}[!] Error: This script must be executed on a Proxmox VE host.${CL}" >&2
    echo "    If you are running inside a VM/container, transfer and run this on the Proxmox hypervisor node." >&2
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

header_info() {
    clear
    cat << "BANNER"
   ____ _                 _____ ____            
  / ___(_)___  ___ ___   |_   _|  _ \ _____  __ 
 | |   | / __|/ __/ _ \    | | | |_) / _ \ \/ / 
 | |___| \__ \ (_| (_) |   | | |  _ <  __/>  <  
  \____|_|___/\___\___/    |_| |_| \_\___/_/\_\ 
  Proxmox VE Helper Script: Cisco TRex Appliance
BANNER
    echo -e "${BL}High-Performance Traffic Generation & Benchmarking Appliance${CL}\n"
}

header_info

msg_box() {
    whiptail --backtitle "Proxmox TRex Deployment" --title "$1" --msgbox "$2" 10 60
}

# 1. Check or Create Dedicated Measurement Bridges (vmbr10 & vmbr20)
WAN_BR="${WAN_BRIDGE:-vmbr10}"
LAN_BR="${LAN_BRIDGE:-vmbr20}"
MGMT_BR="${MGMT_BRIDGE:-vmbr0}"

echo -e "${YW}[*] Checking dedicated isolated measurement bridges (${WAN_BR}, ${LAN_BR})...${CL}"

if ! grep -q "${WAN_BR}" /etc/network/interfaces; then
    echo -e "${YW}[*] Creating ${WAN_BR} (WAN) and ${LAN_BR} (LAN) in /etc/network/interfaces...${CL}"
    cat >> /etc/network/interfaces << INTERFACES

# TRex Measurement Isolated Bridges
auto ${WAN_BR}
iface ${WAN_BR} inet manual
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        mtu 9000

auto ${LAN_BR}
iface ${LAN_BR} inet manual
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        mtu 9000
INTERFACES
    ifreload -a || systemctl restart networking || true
    echo -e "${GN}[+] Measurement bridges ${WAN_BR} and ${LAN_BR} activated.${CL}"
else
    echo -e "${GN}[+] Isolated measurement bridges already present.${CL}"
fi

# 2. Interactive / Default Parameter Selection
NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
DEFAULT_VMID="${TREX_VMID:-$NEXT_ID}"
VMID=$(whiptail --backtitle "Proxmox TRex Deployment" --inputbox "Set Virtual Machine ID:" 8 58 "$DEFAULT_VMID" --title "VM ID" 3>&1 1>&2 2>&3 || echo "$DEFAULT_VMID")
VMID="${VMID:-$DEFAULT_VMID}"
VM_NAME=$(whiptail --backtitle "Proxmox TRex Deployment" --inputbox "Set Virtual Machine Hostname:" 8 58 "${TREX_HOSTNAME:-trex-generator-node}" --title "VM NAME" 3>&1 1>&2 2>&3 || echo "${TREX_HOSTNAME:-trex-generator-node}")
VM_NAME="${VM_NAME:-trex-generator-node}"
VCPU_CORES=$(whiptail --backtitle "Proxmox TRex Deployment" --inputbox "Allocate vCPU Cores (Min 4, Rec 8):" 8 58 "${TREX_CORES:-8}" --title "CPU ALLOCATION" 3>&1 1>&2 2>&3 || echo "${TREX_CORES:-8}")
VCPU_CORES="${VCPU_CORES:-8}"
RAM_MB=$(whiptail --backtitle "Proxmox TRex Deployment" --inputbox "Allocate RAM in MB (Min 4096, Rec 8192):" 8 58 "${TREX_RAM_MB:-8192}" --title "RAM ALLOCATION" 3>&1 1>&2 2>&3 || echo "${TREX_RAM_MB:-8192}")
RAM_MB="${RAM_MB:-8192}"

# Storage selection
STORAGE=$(select_storage "images" "Select Storage for VM Disk" "${DEFAULT_STORAGE:-}")

CI_USER="${TREX_CI_USER:-trex}"
CI_PASS="${TREX_CI_PASSWORD:-cisco123}"

echo -e "\n${BL}[*] Deploying Cisco TRex VM [ID: ${VMID}, Cores: ${VCPU_CORES}, RAM: ${RAM_MB}MB] on storage '${STORAGE}'...${CL}"

# 3. Download Debian 13 (Trixie) Cloud-Init Base Image
IMAGE_DIR="/var/lib/vz/template/iso"
IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-genericcloud-amd64-daily.qcow2"
IMAGE_FILE="${IMAGE_DIR}/debian-13-genericcloud-amd64.qcow2"

mkdir -p "$IMAGE_DIR"
if [[ ! -f "$IMAGE_FILE" ]]; then
    echo -e "${YW}[*] Downloading Debian 13 Trixie Cloud Image...${CL}"
    wget --no-check-certificate -q --show-progress -O "$IMAGE_FILE" "$IMAGE_URL"
fi

# 4. Create KVM Virtual Machine
echo -e "${YW}[*] Creating KVM Virtual Machine with hardware-acceleration flags...${CL}"
qm create "$VMID" \
    --name "$VM_NAME" \
    --ostype l26 \
    --memory "$RAM_MB" \
    --cores "$VCPU_CORES" \
    --sockets 1 \
    --cpu host,flags=+aes;+avx;+avx2 \
    --numa 1 \
    --hugepages 2 \
    --scsihw virtio-scsi-pci

# 5. Network Interfaces Setup
echo -e "${YW}[*] Configuring triple VirtIO network topology...${CL}"
qm set "$VMID" \
    --net0 "virtio,bridge=${MGMT_BR},firewall=1" \
    --net1 "virtio,bridge=${WAN_BR},queues=4,firewall=0,mtu=9000" \
    --net2 "virtio,bridge=${LAN_BR},queues=4,firewall=0,mtu=9000"

# 6. Import Disk and Cloud-Init Drive
echo -e "${YW}[*] Importing disk and creating Cloud-Init drive...${CL}"
qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE"
DISK_NAME=$(qm config "$VMID" | grep -oE "unused0: [^,]+" | cut -d" " -f2 || echo "${STORAGE}:vm-${VMID}-disk-0")

qm set "$VMID" \
    --scsi0 "${DISK_NAME},discard=on,ssd=1" \
    --ide2 "${STORAGE}:cloudinit" \
    --boot order=scsi0 \
    --bootdisk scsi0 \
    --serial0 socket \
    --vga serial0

DISK_SIZE="${TREX_DISK_SIZE:-32G}"
qm disk resize "$VMID" scsi0 "$DISK_SIZE"

qm set "$VMID" \
    --ciuser "$CI_USER" \
    --cipassword "$CI_PASS" \
    --ipconfig0 ip=dhcp

echo -e "\n${GN}========================================================================${CL}"
echo -e "${GN}  Cisco TRex Virtual Machine Created Successfully! [VMID: ${VMID}]      ${CL}"
echo -e "${GN}========================================================================${CL}"
echo -e "Start VM with:   ${BL}qm start ${VMID}${CL}"
echo -e "Open console:    ${BL}qm terminal ${VMID}${CL}"
echo -e "Next inside VM:  ${BL}sudo bash install/install_trex.sh${CL}\n"
