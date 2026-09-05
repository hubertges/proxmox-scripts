#!/usr/bin/env bash
# ==============================================================================
# ct/create_nuclei_lxc.sh
# Proxmox VE Helper Script: Automated ProjectDiscovery Nuclei Scanner LXC Deployment
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
  _   _ _   _  ____ _     _____ ___   ____   ____    _    _   _ 
 | \ | | | | |/ ___| |   | ____|_ _| / ___| / ___|  / \  | \ | |
 |  \| | | | | |   | |   |  _|  | |  \___ \| |     / _ \ |  \| |
 | |\  | |_| | |___| |___| |___ | |   ___) | |___ / ___ \| |\  |
 |_| \_|\___/ \____|_____|_____|___| |____/ \____/_/   \_\_| \_|
  Proxmox VE Helper Script: ProjectDiscovery Nuclei Scanner LXC
BANNER
echo -e "${BL}Automated Vulnerability & Compliance Assessment for Network DUTs${CL}\n"

# 1. Interactive or Default Parameters
NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
DEFAULT_CTID="${NUCLEI_CTID:-$NEXT_ID}"

if command -v whiptail >/dev/null 2>&1 && [[ -t 0 ]]; then
    CTID=$(whiptail --backtitle "Proxmox Nuclei Scanner" --inputbox "Set Container ID (CTID):" 8 58 "$DEFAULT_CTID" --title "CONTAINER ID" 3>&1 1>&2 2>&3 || echo "$DEFAULT_CTID")
    HOSTNAME=$(whiptail --backtitle "Proxmox Nuclei Scanner" --inputbox "Set Hostname:" 8 58 "${NUCLEI_HOSTNAME:-nuclei-vulnerability-scanner}" --title "HOSTNAME" 3>&1 1>&2 2>&3 || echo "${NUCLEI_HOSTNAME:-nuclei-vulnerability-scanner}")
else
    CTID="$DEFAULT_CTID"
    HOSTNAME="${NUCLEI_HOSTNAME:-nuclei-vulnerability-scanner}"
fi
CTID="${CTID:-$DEFAULT_CTID}"
HOSTNAME="${HOSTNAME:-${NUCLEI_HOSTNAME:-nuclei-vulnerability-scanner}}"

mapfile -t STORAGE_LIST < <(get_pve_storage "rootdir")
STORAGE_DEF="${DEFAULT_STORAGE:-${STORAGE_LIST[0]:-local-lvm}}"
STORAGE="${STORAGE_DEF}"

# 2. Template Selection & Download
mapfile -t TEMPLATE_STORAGE_LIST < <(get_pve_storage "vztmpl")
TMPL_STORAGE="${TEMPLATE_STORAGE:-${TEMPLATE_STORAGE_LIST[0]:-local}}"
TEMPLATE_DIR="/var/lib/vz/template/cache"

echo -e "${YW}[*] Checking Debian standard LXC template...${CL}"
pveam update > /dev/null 2>&1 || true
mapfile -t AVAILABLE_TEMPLATES < <(pveam available -section system 2>/dev/null | awk '/debian-[1-9][0-9]-standard/ {print $2}' || true)
CHOSEN_TMPL="${AVAILABLE_TEMPLATES[0]:-debian-12-standard_12.7-1_amd64.tar.zst}"

if ! pveam list "$TMPL_STORAGE" 2>/dev/null | grep -q "$CHOSEN_TMPL" && [[ ! -f "${TEMPLATE_DIR}/${CHOSEN_TMPL}" ]]; then
    echo -e "${YW}[*] Downloading container template ${CHOSEN_TMPL}...${CL}"
    pveam download "$TMPL_STORAGE" "$CHOSEN_TMPL"
fi

MGMT_BR="${MGMT_BRIDGE:-vmbr0}"
CORES="${NUCLEI_CORES:-2}"
RAM="${NUCLEI_RAM_MB:-2048}"

# 3. Create Unprivileged LXC Container
echo -e "${BL}[*] Creating LXC Container [CTID: ${CTID}, Hostname: ${HOSTNAME}]...${CL}"
pct create "$CTID" "${TMPL_STORAGE}:vztmpl/${CHOSEN_TMPL}" \
    --hostname "$HOSTNAME" \
    --ostype debian \
    --cores "$CORES" \
    --memory "$RAM" \
    --swap 512 \
    --storage "$STORAGE" \
    --rootfs "${STORAGE}:12" \
    --net0 "name=eth0,bridge=${MGMT_BR},firewall=0,ip=dhcp" \
    --features nesting=1 \
    --unprivileged 1 \
    --onboot 1

# 4. Start Container
echo -e "${YW}[*] Starting container ${CTID}...${CL}"
pct start "$CTID"
sleep 5

# 5. Execute Nuclei Installation Inside Container
echo -e "${BL}[*] Installing ProjectDiscovery Nuclei CLI and official templates...${CL}"

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install/install_nuclei.sh"

if [[ -f "$SCRIPT_PATH" ]]; then
    pct push "$CTID" "$SCRIPT_PATH" /tmp/install_nuclei.sh
    pct exec "$CTID" -- bash /tmp/install_nuclei.sh
    pct exec "$CTID" -- rm -f /tmp/install_nuclei.sh
else
    pct exec "$CTID" -- bash -c "apt-get update -y && apt-get install -y curl unzip jq ca-certificates && curl -sSL https://raw.githubusercontent.com/projectdiscovery/nuclei/main/install.sh | bash"
fi

CT_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | awk '/inet / {print $2}' | cut -d/ -f1 || echo "DHCP")

echo -e "\n${GN}========================================================================${CL}"
echo -e "${GN}  ProjectDiscovery Nuclei LXC Container Deployed! [CTID: ${CTID}]       ${CL}"
echo -e "${GN}========================================================================${CL}"
echo -e "Container IP:         ${BL}${CT_IP}${CL}"
echo -e "Access Console:       ${BL}pct enter ${CTID}${CL}"
echo -e "Run Router Scan:      ${BL}pct exec ${CTID} -- scan_router.sh 198.18.1.1 unifi${CL}\n"
