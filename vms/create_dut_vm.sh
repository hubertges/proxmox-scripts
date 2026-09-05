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
    "debian" "Debian Linux DUT (nftables / iproute2 / BIRD)" 3>&1 1>&2 2>&3)

NEXT_ID=$(pvesh get /cluster/nextid)
DEFAULT_VMID="${DUT_VMID:-$NEXT_ID}"
VMID=$(whiptail --backtitle "Proxmox DUT Deployment" --inputbox "Set DUT Virtual Machine ID:" 8 58 "$DEFAULT_VMID" --title "VM ID" 3>&1 1>&2 2>&3)
VM_NAME=$(whiptail --backtitle "Proxmox DUT Deployment" --inputbox "Set Hostname:" 8 58 "${DUT_HOSTNAME:-dut-${DUT_TYPE}-node}" --title "VM NAME" 3>&1 1>&2 2>&3)

STORAGE_LIST=($(pvesh get /storage --output-format json | jq -r ".[] | select(.content | contains(\"images\")) | .storage"))
STORAGE_DEF="${DEFAULT_STORAGE:-${STORAGE_LIST[0]:-local-lvm}}"
STORAGE=$(whiptail --backtitle "Proxmox DUT Deployment" --inputbox "Target Storage Pool for Disk:" 8 58 "$STORAGE_DEF" --title "STORAGE POOL" 3>&1 1>&2 2>&3)

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
