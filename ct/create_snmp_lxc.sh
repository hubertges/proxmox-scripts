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

# 1. Interactive or Default Parameters
NEXT_ID=$(pvesh get /cluster/nextid)
DEFAULT_CTID="${SNMP_CTID:-$NEXT_ID}"
CTID=$(whiptail --backtitle "Proxmox SNMP Collector" --inputbox "Set Container ID (CTID):" 8 58 "$DEFAULT_CTID" --title "CONTAINER ID" 3>&1 1>&2 2>&3)
HOSTNAME=$(whiptail --backtitle "Proxmox SNMP Collector" --inputbox "Set Hostname:" 8 58 "${SNMP_HOSTNAME:-snmp-telemetry-collector}" --title "HOSTNAME" 3>&1 1>&2 2>&3)

STORAGE_LIST=($(pvesh get /storage --output-format json | jq -r ".[] | select(.content | contains(\"rootdir\")) | .storage"))
STORAGE_DEF="${DEFAULT_STORAGE:-${STORAGE_LIST[0]:-local-lvm}}"
STORAGE="${STORAGE_DEF}"

# 2. Template Selection & Download
TEMPLATE_STORAGE_LIST=($(pvesh get /storage --output-format json | jq -r ".[] | select(.content | contains(\"vztmpl\")) | .storage"))
TMPL_STORAGE="${TEMPLATE_STORAGE:-${TEMPLATE_STORAGE_LIST[0]:-local}}"
TEMPLATE_DIR="/var/lib/vz/template/cache"

echo -e "${YW}[*] Checking Debian standard LXC template...${CL}"
pveam update > /dev/null 2>&1 || true
AVAILABLE_TEMPLATES=($(pveam available -section system | awk '/debian-[1-9][0-9]-standard/ {print $2}'))
CHOSEN_TMPL="${AVAILABLE_TEMPLATES[0]:-debian-12-standard_12.7-1_amd64.tar.zst}"

if [[ ! -f "${TEMPLATE_DIR}/${CHOSEN_TMPL}" ]]; then
    echo -e "${YW}[*] Downloading container template ${CHOSEN_TMPL}...${CL}"
    pveam download "$TMPL_STORAGE" "$CHOSEN_TMPL"
fi

MGMT_BR="${MGMT_BRIDGE:-vmbr0}"
CORES="${SNMP_CORES:-2}"
RAM="${SNMP_RAM_MB:-2048}"

# 3. Create Unprivileged LXC Container
echo -e "${BL}[*] Creating LXC Container [CTID: ${CTID}, Hostname: ${HOSTNAME}]...${CL}"
pct create "$CTID" "${TMPL_STORAGE}:vztmpl/${CHOSEN_TMPL}" \
    --hostname "$HOSTNAME" \
    --ostype debian \
    --cores "$CORES" \
    --memory "$RAM" \
    --swap 512 \
    --storage "$STORAGE" \
    --rootfs "${STORAGE}:8" \
    --net0 "name=eth0,bridge=${MGMT_BR},firewall=0,ip=dhcp" \
    --features nesting=1 \
    --unprivileged 1 \
    --onboot 1

# 4. Start Container
echo -e "${YW}[*] Starting container ${CTID}...${CL}"
pct start "$CTID"
sleep 5

# 5. Execute Telemetry Installation Inside Container
echo -e "${BL}[*] Installing SNMP, snmptrapd, rsyslog, and poller daemon inside container...${CL}"

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install/install_snmp_collector.sh"

if [[ -f "$SCRIPT_PATH" ]]; then
    pct push "$CTID" "$SCRIPT_PATH" /tmp/install_snmp_collector.sh
    pct exec "$CTID" -- bash /tmp/install_snmp_collector.sh
    pct exec "$CTID" -- rm -f /tmp/install_snmp_collector.sh
else
    pct exec "$CTID" -- bash -c "apt-get update -y && apt-get install -y snmp snmpd snmptrapd rsyslog curl jq python3"
fi

CT_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | awk '/inet / {print $2}' | cut -d/ -f1 || echo "DHCP")

echo -e "\n${GN}========================================================================${CL}"
echo -e "${GN}  SNMP Telemetry Collector Container Deployed! [CTID: ${CTID}]           ${CL}"
echo -e "${GN}========================================================================${CL}"
echo -e "Container IP:         ${BL}${CT_IP}${CL}"
echo -e "SNMP Trap Receiver:   ${BL}${CT_IP}:162 (UDP)${CL}"
echo -e "Syslog Server:        ${BL}${CT_IP}:514 (UDP/TCP)${CL}"
echo -e "Access Console:       ${BL}pct enter ${CTID}${CL}\n"
