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
  _____ _____ ____  ____ _____  __   ___    ___  
 |__  /|  _  | __ )| __ )_   _| \ \ / / \  / _ \ 
   / / | |_| |  _ \|  _ \ | |    \ V / _ \| | | |
  / /_ |  _  | |_) | |_) || |     | / ___ \ |_| |
 /____||_| |_|____/|____/ |_|     |/_/   \_\___/ 
  Proxmox VE Helper Script: Zabbix 8.0 LTS + PostgreSQL 17
BANNER
echo -e "${BL}Enterprise Monitoring Platform on Debian 13 (Trixie) LXC${CL}\n"

# 1. Interactive or Default Parameters
NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
DEFAULT_CTID="${ZABBIX_CTID:-$NEXT_ID}"

if command -v whiptail >/dev/null 2>&1 && [[ -t 0 ]]; then
    CTID=$(whiptail --backtitle "Proxmox Zabbix 8.0 Deployer" --inputbox "Set Container ID (CTID):" 8 58 "$DEFAULT_CTID" --title "CONTAINER ID" 3>&1 1>&2 2>&3 || echo "$DEFAULT_CTID")
    HOSTNAME=$(whiptail --backtitle "Proxmox Zabbix 8.0 Deployer" --inputbox "Set Hostname:" 8 58 "${ZABBIX_HOSTNAME:-zabbix8-server}" --title "HOSTNAME" 3>&1 1>&2 2>&3 || echo "${ZABBIX_HOSTNAME:-zabbix8-server}")
else
    CTID="$DEFAULT_CTID"
    HOSTNAME="${ZABBIX_HOSTNAME:-zabbix8-server}"
fi
CTID="${CTID:-$DEFAULT_CTID}"
HOSTNAME="${HOSTNAME:-${ZABBIX_HOSTNAME:-zabbix8-server}}"

mapfile -t STORAGE_LIST < <(get_pve_storage "rootdir")
STORAGE_DEF="${DEFAULT_STORAGE:-${STORAGE_LIST[0]:-local-lvm}}"
STORAGE="${STORAGE_DEF}"

# 2. Template Selection & Download
mapfile -t TEMPLATE_STORAGE_LIST < <(get_pve_storage "vztmpl")
TMPL_STORAGE="${TEMPLATE_STORAGE:-${TEMPLATE_STORAGE_LIST[0]:-local}}"
TEMPLATE_DIR="/var/lib/vz/template/cache"

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

if ! pveam list "$TMPL_STORAGE" 2>/dev/null | grep -q "$CHOSEN_TMPL" && [[ ! -f "${TEMPLATE_DIR}/${CHOSEN_TMPL}" ]]; then
    echo -e "${YW}[*] Downloading container template ${CHOSEN_TMPL}...${CL}"
    pveam download "$TMPL_STORAGE" "$CHOSEN_TMPL"
fi

MGMT_BR="${MGMT_BRIDGE:-vmbr0}"
CORES="${ZABBIX_CORES:-2}"
RAM="${ZABBIX_RAM_MB:-4096}"
SWAP="${ZABBIX_SWAP_MB:-1024}"
DISK="${ZABBIX_DISK_GB:-16}"

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
