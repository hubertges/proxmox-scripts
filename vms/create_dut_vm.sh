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

# Helper: Query PVE storage pools safely without requiring jq
get_pve_storage() {
    local content="$1"
    local storages=()

    if command -v jq >/dev/null 2>&1; then
        mapfile -t storages < <(pvesh get /storage --output-format json 2>/dev/null | jq -r ".[] | select(.content | contains(\"${content}\")) | .storage" 2>/dev/null || true)
    fi

    if [[ ${#storages[@]} -eq 0 ]] && command -v perl >/dev/null 2>&1; then
        mapfile -t storages < <(pvesh get /storage --output-format json 2>/dev/null | perl -MJSON::PP -e '
            my $target = shift;
            local $/;
            my $raw = <STDIN>;
            eval {
                my $data = decode_json($raw);
                for my $s (@$data) {
                    if (exists $s->{content} && index($s->{content}, $target) != -1) {
                        print $s->{storage} . "\n";
                    }
                }
            };
        ' "$content" 2>/dev/null || true)
    fi

    if [[ ${#storages[@]} -eq 0 && -f /etc/pve/storage.cfg ]]; then
        mapfile -t storages < <(awk -v c="$content" '
            /^[a-z0-9_-]+: / { cur = $2 }
            cur && $1 == "content" && $0 ~ c { print cur }
        ' /etc/pve/storage.cfg 2>/dev/null || true)
    fi

    for s in "${storages[@]}"; do
        [[ -n "$s" ]] && echo "$s"
    done
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

mapfile -t STORAGE_LIST < <(get_pve_storage "images")
STORAGE_DEF="${DEFAULT_STORAGE:-${STORAGE_LIST[0]:-local-lvm}}"
STORAGE=$(whiptail --backtitle "Proxmox DUT Deployment" --inputbox "Target Storage Pool for Disk:" 8 58 "$STORAGE_DEF" --title "STORAGE POOL" 3>&1 1>&2 2>&3 || echo "$STORAGE_DEF")
STORAGE="${STORAGE:-$STORAGE_DEF}"

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
