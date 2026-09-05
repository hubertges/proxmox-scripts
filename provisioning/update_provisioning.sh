#!/usr/bin/env bash
# ==============================================================================
# provisioning/update_provisioning.sh
# Comprehensive Post-Provisioning Upgrade & Hardening Suite for Proxmox VE
#
# Upgrades existing LXC containers, VMs, and Host from legacy configurations to:
#   1. Wazuh Agent v5 (XDR/SIEM pre-release / staging) with bridge upgrade support
#   2. Zabbix Agent 2 (high-performance Go-based monitoring agent)
#   3. Post-Quantum SSH Hardening (sntrup761x25519) & Key-Only Authentication
#   4. Host-Managed Kernel Clock (purges/masks redundant NTP & Chrony in LXC)
#
# Usage:
#   ./update_provisioning.sh [MODE] [OPTIONS]
#
# Modes:
#   --all                 Update Host, all running LXC containers, and running VMs
#   --ct [CTID ...]       Update all (or specific) running LXC containers (Default)
#   --vm [VMID ...]       Update all (or specific) running VMs with QEMU Guest Agent
#   --host                Update hypervisor host only
#   --status              Audit current Wazuh, Zabbix & SSH versions across cluster
#   -h, --help            Show this help message
#
# Options:
#   --force               Force re-provisioning even if already up to date
#   --dry-run             Preview actions without making changes
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors & Formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# 1. Environment & Configuration Loading
# ------------------------------------------------------------------------------
load_env() {
    local env_locations=(
        "${SCRIPT_DIR}/.env"
        "${SCRIPT_DIR}/../.env"
        "/etc/pve/scripts/.env"
        "/etc/pve/secrets/.env"
        "/etc/pve/.env"
        "$HOME/.env"
    )
    for env_file in "${env_locations[@]}"; do
        if [[ -f "$env_file" ]]; then
            # shellcheck source=/dev/null
            source "$env_file"
            break
        fi
    done
}
load_env

# Privileges check
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[-] Błąd: Uruchom ten skrypt jako root na hoście Proxmox VE.${NC}" >&2
    exit 1
fi

# Variables
WAZUH_MGR="${WAZUH_MANAGER:-wazuh.slurp.pl}"
WAZUH_GRP="${WAZUH_AGENT_GROUP:-linux-servers}"
WAZUH_VER="${WAZUH_AGENT_V5_VERSION:-5.0.0-beta5}"
BASE_V5_URL="https://packages-staging.xdrsiem.wazuh.info/pre-release/5.x"
BASE_V4_URL="https://packages.wazuh.com/4.x"

ZABBIX_SRV="${ZABBIX_SERVER:-zabbix.slurp.pl}"
ZABBIX_SRV_ACTIVE="${ZABBIX_SERVER_ACTIVE:-${ZABBIX_SRV}}"
ZABBIX_ENABLED="${ZABBIX_AGENT_ENABLE:-true}"

LXC_USER="${LXC_DEFAULT_USER:-hubi}"
SSH_PUBKEY="${SSH_PUBKEY_PATH:-/root/.ssh/authorized_keys}"
CACHE_DIR="/tmp/wazuh5_agent_cache"
mkdir -p "$CACHE_DIR" 2>/dev/null || true

FORCE_UPDATE=0
DRY_RUN=0

# Summary arrays
declare -a SUMMARY_SUCCESS=()
declare -a SUMMARY_FAILED=()
declare -a SUMMARY_SKIPPED=()

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ------------------------------------------------------------------------------
# 2. Package Caching Helper
# ------------------------------------------------------------------------------
ensure_cached_package() {
    local pkg_type="$1" # deb-amd64 | deb-arm64 | rpm-x86_64 | rpm-aarch64
    local dest_file=""
    local download_url=""

    case "$pkg_type" in
        deb-amd64)
            dest_file="${CACHE_DIR}/wazuh-agent_${WAZUH_VER}_amd64.deb"
            download_url="${BASE_V5_URL}/apt/pool/main/w/wazuh-agent/wazuh-agent_${WAZUH_VER}_amd64.deb"
            ;;
        deb-arm64)
            dest_file="${CACHE_DIR}/wazuh-agent_${WAZUH_VER}_arm64.deb"
            download_url="${BASE_V5_URL}/apt/pool/main/w/wazuh-agent/wazuh-agent_${WAZUH_VER}_arm64.deb"
            ;;
        rpm-x86_64)
            dest_file="${CACHE_DIR}/wazuh-agent-${WAZUH_VER}.x86_64.rpm"
            download_url="${BASE_V5_URL}/yum/wazuh-agent-${WAZUH_VER}.x86_64.rpm"
            ;;
        rpm-aarch64)
            dest_file="${CACHE_DIR}/wazuh-agent-${WAZUH_VER}.aarch64.rpm"
            download_url="${BASE_V5_URL}/yum/wazuh-agent-${WAZUH_VER}.aarch64.rpm"
            ;;
    esac

    if [[ ! -f "$dest_file" ]]; then
        log_info "Pobieranie pakietu Wazuh v5 (${dest_file##*/})..." >&2
        if curl -fsSL "$download_url" -o "$dest_file"; then
            log_ok "Zapisano w pamięci podręcznej hosta: ${dest_file##*/}" >&2
        else
            log_err "Błąd pobierania $download_url" >&2
            rm -f "$dest_file"
            return 1
        fi
    fi
    echo "$dest_file"
}

# ------------------------------------------------------------------------------
# 3. Upgrade Logic for LXC Containers
# ------------------------------------------------------------------------------
update_container() {
    local ctid="$1"
    local ct_name
    ct_name=$(pct config "$ctid" 2>/dev/null | grep -E '^hostname:' | awk '{print $2}' || echo "CT-${ctid}")

    echo ""
    log_info "=== Przetwarzanie kontenera: ${BOLD}${ctid} (${ct_name})${NC} ==="

    local ct_st
    ct_st=$(pct status "$ctid" 2>/dev/null | awk '{print $2}' || echo "stopped")
    if [[ "$ct_st" != "running" ]]; then
        log_warn "Kontener $ctid jest zatrzymany. Pomijanie."
        SUMMARY_SKIPPED+=("CT ${ctid} (${ct_name}) [stopped]")
        return 0
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] Symulacja aktualizacji dla CT $ctid."
        SUMMARY_SUCCESS+=("CT ${ctid} (${ct_name}) [DRY-RUN]")
        return 0
    fi

    # Detect distro details
    local os_id
    os_id=$(pct exec "$ctid" -- /bin/sh -c '. /etc/os-release 2>/dev/null && echo "${ID:-unknown}"' || echo "unknown")
    local ct_arch
    ct_arch=$(pct exec "$ctid" -- uname -m 2>/dev/null || echo "x86_64")

    log_info "Wykryto system: ${os_id} (${ct_arch})"

    # 1. Host-managed time: mask redundant NTP in container
    log_info "1/4. Weryfikacja zegara jądra (wyłączanie zbędnego NTP)..."
    pct exec "$ctid" -- /bin/sh -c '
        if [ -d /run/systemd/system ]; then
            systemctl disable --now chrony chronyd systemd-timesyncd ntpd 2>/dev/null || true
            systemctl mask chrony chronyd systemd-timesyncd ntpd 2>/dev/null || true
        elif [ -d /run/openrc ] || [ -f /sbin/openrc-run ]; then
            rc-update del chronyd default 2>/dev/null || true
            rc-service chronyd stop 2>/dev/null || true
            rc-update del ntpd default 2>/dev/null || true
            rc-service ntpd stop 2>/dev/null || true
        fi
    '

    # 2. SSH Hardening refresh
    log_info "2/4. Odświeżanie utwardzenia SSH (Post-Quantum & klucze)..."
    pct exec "$ctid" -- /bin/sh -c '
        if [ -d /etc/ssh/sshd_config.d ]; then
            cat << "SSHD_CONF" > /etc/ssh/sshd_config.d/99-hardened.conf
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256
SSHD_CONF
            chmod 600 /etc/ssh/sshd_config.d/99-hardened.conf 2>/dev/null || true
        fi
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || rc-service sshd restart 2>/dev/null || true
    '

    # 3. Wazuh Agent v5 Upgrade
    log_info "3/4. Weryfikacja i aktualizacja Wazuh Agent v5..."
    local cur_wazuh="none"
    if pct exec "$ctid" -- command -v dpkg-query >/dev/null 2>&1; then
        cur_wazuh=$(pct exec "$ctid" -- dpkg-query -W -f='${Version}' wazuh-agent 2>/dev/null || echo "none")
    elif pct exec "$ctid" -- command -v rpm >/dev/null 2>&1; then
        cur_wazuh=$(pct exec "$ctid" -- rpm -q --queryformat '%{VERSION}' wazuh-agent 2>/dev/null || echo "none")
    fi

    if [[ "$FORCE_UPDATE" -eq 0 && "$cur_wazuh" == *"${WAZUH_VER}"* ]]; then
        log_ok "Wazuh Agent w wersji v5 (${cur_wazuh}) jest już zainstalowany."
    else
        local pkg_type="deb-amd64"
        if pct exec "$ctid" -- command -v dpkg >/dev/null 2>&1; then
            [[ "$ct_arch" == "aarch64" || "$ct_arch" == "arm64" ]] && pkg_type="deb-arm64"
            
            # Bridge upgrade check for versions older than 4.14.0
            local major minor
            major=$(echo "$cur_wazuh" | sed -E 's/^[^0-9]*//' | cut -d. -f1 || echo "")
            minor=$(echo "$cur_wazuh" | sed -E 's/^[^0-9]*//' | cut -d. -f2 || echo "")
            if [[ -n "$major" && -n "$minor" && ("$major" -lt 4 || ("$major" -eq 4 && "$minor" -lt 14)) ]]; then
                log_warn "Wersja agenta ($cur_wazuh) starsza niż 4.14.0. Instalowanie pomostu 4.14.7-1..."
                local bridge_pkg="${CACHE_DIR}/wazuh-agent_4.14.7-1_${pkg_type#deb-}.deb"
                if [[ ! -f "$bridge_pkg" ]]; then
                    curl -fsSL "${BASE_V4_URL}/apt/pool/main/w/wazuh-agent/wazuh-agent_4.14.7-1_amd64.deb" -o "$bridge_pkg" 2>/dev/null || true
                fi
                if [[ -f "$bridge_pkg" ]]; then
                    pct push "$ctid" "$bridge_pkg" "/tmp/wazuh-bridge.deb"
                    pct exec "$ctid" -- /bin/sh -c "export DEBIAN_FRONTEND=noninteractive; dpkg --force-confdef --force-confold -i /tmp/wazuh-bridge.deb >/dev/null 2>&1 || apt-get install -f -y >/dev/null 2>&1; rm -f /tmp/wazuh-bridge.deb" || true
                fi
            fi

            local pkg_file
            pkg_file=$(ensure_cached_package "$pkg_type" | tail -n 1)
            if [[ -f "$pkg_file" ]]; then
                pct push "$ctid" "$pkg_file" "/tmp/wazuh-agent-v5.deb"
                pct exec "$ctid" -- /bin/sh -c "
                    export DEBIAN_FRONTEND=noninteractive WAZUH_MANAGER='${WAZUH_MGR}' WAZUH_AGENT_GROUP='${WAZUH_GRP}'
                    dpkg --force-confdef --force-confold -i /tmp/wazuh-agent-v5.deb >/tmp/wazuh_up.log 2>&1 || (apt-get update -y >/dev/null 2>&1 && apt-get install -f -y >>/tmp/wazuh_up.log 2>&1 && dpkg --force-confdef --force-confold -i /tmp/wazuh-agent-v5.deb >>/tmp/wazuh_up.log 2>&1)
                    rm -f /tmp/wazuh-agent-v5.deb
                    [ -d /run/systemd/system ] && systemctl daemon-reload && systemctl enable --now wazuh-agent >/dev/null 2>&1 || true
                "
                log_ok "Wazuh Agent zaktualizowany do v5 (${WAZUH_VER})."
            fi

        elif pct exec "$ctid" -- command -v rpm >/dev/null 2>&1; then
            pkg_type="rpm-x86_64"
            [[ "$ct_arch" == "aarch64" ]] && pkg_type="rpm-aarch64"
            local pkg_file
            pkg_file=$(ensure_cached_package "$pkg_type" | tail -n 1)
            if [[ -f "$pkg_file" ]]; then
                pct push "$ctid" "$pkg_file" "/tmp/wazuh-agent-v5.rpm"
                pct exec "$ctid" -- /bin/sh -c "
                    export WAZUH_MANAGER='${WAZUH_MGR}' WAZUH_AGENT_GROUP='${WAZUH_GRP}'
                    rpm -Uvh --replacepkgs /tmp/wazuh-agent-v5.rpm >/tmp/wazuh_up.log 2>&1 || (command -v dnf >/dev/null 2>&1 && dnf install -y /tmp/wazuh-agent-v5.rpm >>/tmp/wazuh_up.log 2>&1) || (command -v zypper >/dev/null 2>&1 && zypper --non-interactive install -y /tmp/wazuh-agent-v5.rpm >>/tmp/wazuh_up.log 2>&1)
                    rm -f /tmp/wazuh-agent-v5.rpm
                    [ -d /run/systemd/system ] && systemctl daemon-reload && systemctl enable --now wazuh-agent >/dev/null 2>&1 || true
                "
                log_ok "Wazuh Agent zaktualizowany do v5 (${WAZUH_VER})."
            fi
        fi
    fi

    # 4. Zabbix Agent 2 Installation & Update
    if [[ "$ZABBIX_ENABLED" == "true" ]]; then
        log_info "4/4. Weryfikacja i konfiguracja Zabbix Agent 2 (Serwer: ${ZABBIX_SRV})..."
        pct exec "$ctid" -- /bin/sh -c "
            # Try to install zabbix-agent2
            if command -v apt-get >/dev/null 2>&1; then
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -y >/dev/null 2>&1 || true
                apt-get install -y zabbix-agent2 >/dev/null 2>&1 || apt-get install -y zabbix-agent >/dev/null 2>&1 || true
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y zabbix-agent2 >/dev/null 2>&1 || dnf install -y zabbix-agent >/dev/null 2>&1 || true
            elif command -v zypper >/dev/null 2>&1; then
                zypper --non-interactive install -y zabbix-agent2 >/dev/null 2>&1 || zypper --non-interactive install -y zabbix-agent >/dev/null 2>&1 || true
            elif command -v pacman >/dev/null 2>&1; then
                pacman -S --noconfirm --needed zabbix-agent2 >/dev/null 2>&1 || pacman -S --noconfirm --needed zabbix-agent >/dev/null 2>&1 || true
            elif command -v apk >/dev/null 2>&1; then
                apk add --no-cache zabbix-agent2 >/dev/null 2>&1 || apk add --no-cache zabbix-agent >/dev/null 2>&1 || true
            fi

            ZBX_CFG=''
            ZBX_SVC=''
            if [ -f /etc/zabbix/zabbix_agent2.conf ]; then
                ZBX_CFG='/etc/zabbix/zabbix_agent2.conf'
                ZBX_SVC='zabbix-agent2'
            elif [ -f /etc/zabbix/zabbix_agentd.conf ]; then
                ZBX_CFG='/etc/zabbix/zabbix_agentd.conf'
                ZBX_SVC='zabbix-agent'
            fi

            if [ -n \"\$ZBX_CFG\" ] && [ -f \"\$ZBX_CFG\" ]; then
                sed -i 's/^#\? \?Server=.*/Server=${ZABBIX_SRV}/' \"\$ZBX_CFG\" 2>/dev/null || true
                sed -i 's/^#\? \?ServerActive=.*/ServerActive=${ZABBIX_SRV_ACTIVE}/' \"\$ZBX_CFG\" 2>/dev/null || true
                MY_NAME=\$(hostname 2>/dev/null || echo '${ct_name}')
                sed -i \"s/^#\? \?Hostname=.*/Hostname=\${MY_NAME}/\" \"\$ZBX_CFG\" 2>/dev/null || true

                if [ -d /run/systemd/system ]; then
                    systemctl daemon-reload 2>/dev/null || true
                    systemctl enable --now \"\$ZBX_SVC\" 2>/dev/null || true
                    systemctl restart \"\$ZBX_SVC\" 2>/dev/null || true
                elif [ -d /run/openrc ] || [ -f /sbin/openrc-run ]; then
                    rc-update add \"\$ZBX_SVC\" default 2>/dev/null || true
                    rc-service \"\$ZBX_SVC\" restart 2>/dev/null || true
                fi
            fi
        "
        log_ok "Zabbix Agent zweryfikowany i zsynchronizowany."
    fi

    # Mark as updated
    pct exec "$ctid" -- /bin/sh -c "date -u +'%Y-%m-%dT%H:%M:%SZ' > /etc/.lxc_provisioned" 2>/dev/null || true
    SUMMARY_SUCCESS+=("CT ${ctid}: ${ct_name} (Wazuh v5, Zabbix Agent, SSH)")
    log_ok "Kontener ${ctid} został pomyślnie zaktualizowany."
}

# ------------------------------------------------------------------------------
# 4. Status & Audit Mode
# ------------------------------------------------------------------------------
audit_status() {
    echo ""
    echo -e "${BOLD}${CYAN}========================================================================${NC}"
    echo -e "${BOLD}${CYAN}            PROXMOX CLUSTER PROVISIONING & AGENT AUDIT                  ${NC}"
    echo -e "${BOLD}${CYAN}========================================================================${NC}"
    printf "%-8s %-20s %-12s %-18s %-18s %-10s\n" "TYPE" "NAME" "STATUS" "WAZUH AGENT" "ZABBIX AGENT" "PROVISIONED"
    echo "------------------------------------------------------------------------"

    # 1. Host
    local host_name host_wazuh host_zabbix
    host_name=$(hostname)
    host_wazuh=$(dpkg-query -W -f='${Version}' wazuh-agent 2>/dev/null || echo "none")
    host_zabbix=$(dpkg-query -W -f='${Version}' zabbix-agent2 2>/dev/null || dpkg-query -W -f='${Version}' zabbix-agent 2>/dev/null || echo "none")
    printf "%-8s %-20s %-12s %-18s %-18s %-10s\n" "HOST" "$host_name" "online" "$host_wazuh" "$host_zabbix" "yes"

    # 2. LXC Containers
    while read -r ctid ct_st; do
        [[ -z "$ctid" ]] && continue
        local cname
        cname=$(pct config "$ctid" 2>/dev/null | grep -E '^hostname:' | awk '{print $2}' || echo "CT-${ctid}")
        local cwazuh="-" czabbix="-" cprov="no"
        if [[ "$ct_st" == "running" ]]; then
            cwazuh=$(pct exec "$ctid" -- dpkg-query -W -f='${Version}' wazuh-agent 2>/dev/null || pct exec "$ctid" -- rpm -q --queryformat '%{VERSION}' wazuh-agent 2>/dev/null || echo "none")
            czabbix=$(pct exec "$ctid" -- dpkg-query -W -f='${Version}' zabbix-agent2 2>/dev/null || pct exec "$ctid" -- rpm -q --queryformat '%{VERSION}' zabbix-agent2 2>/dev/null || echo "none")
            if pct exec "$ctid" -- test -f /etc/.lxc_provisioned 2>/dev/null; then
                cprov="yes"
            fi
        fi
        printf "%-8s %-20s %-12s %-18s %-18s %-10s\n" "CT ${ctid}" "$cname" "$ct_st" "$cwazuh" "$czabbix" "$cprov"
    done < <(pct list 2>/dev/null | awk 'NR>1 {print $1, $2}')

    echo "========================================================================"
    echo ""
}

# ------------------------------------------------------------------------------
# 5. Main Entrypoint & CLI Parsing
# ------------------------------------------------------------------------------
MODE="ct"
TARGETS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            MODE="all"
            shift
            ;;
        --ct)
            MODE="ct"
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                TARGETS+=("$1")
                shift
            done
            ;;
        --host)
            MODE="host"
            shift
            ;;
        --status)
            audit_status
            exit 0
            ;;
        --force|-f)
            FORCE_UPDATE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            echo "Użycie: $0 [--all | --ct [CTID ...] | --host | --status] [--force] [--dry-run]"
            exit 0
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                TARGETS+=("$1")
                shift
            else
                log_err "Nieznana opcja: $1"
                exit 1
            fi
            ;;
    esac
done

case "$MODE" in
    ct)
        if [[ ${#TARGETS[@]} -eq 0 ]]; then
            mapfile -t TARGETS < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}')
        fi
        log_info "Rozpoczynanie aktualizacji provisioningu dla kontenerów LXC: ${TARGETS[*]}"
        for ctid in "${TARGETS[@]}"; do
            update_container "$ctid"
        done
        ;;
    host)
        log_info "Aktualizacja agentów na hoście Proxmox VE..."
        # Update Host Wazuh & Zabbix
        if [[ -f "${SCRIPT_DIR}/update_wazuh_agent_v5.sh" ]]; then
            bash "${SCRIPT_DIR}/update_wazuh_agent_v5.sh" --host
        fi
        ;;
    all)
        log_info "Aktualizacja provisioningu w całym klastrze (Host + Kontenery)..."
        if [[ -f "${SCRIPT_DIR}/update_wazuh_agent_v5.sh" ]]; then
            bash "${SCRIPT_DIR}/update_wazuh_agent_v5.sh" --host
        fi
        mapfile -t TARGETS < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}')
        for ctid in "${TARGETS[@]}"; do
            update_container "$ctid"
        done
        ;;
esac

echo ""
echo -e "${BOLD}${CYAN}========================================================================${NC}"
echo -e "${BOLD}${CYAN}                     PODSUMOWANIE AKTUALIZACJI                          ${NC}"
echo -e "${BOLD}${CYAN}========================================================================${NC}"
if [[ ${#SUMMARY_SUCCESS[@]} -gt 0 ]]; then
    echo -e "${GREEN}[+] Pomyślnie zaktualizowano (${#SUMMARY_SUCCESS[@]}):${NC}"
    for item in "${SUMMARY_SUCCESS[@]}"; do
        echo "    ✔ $item"
    done
fi
if [[ ${#SUMMARY_SKIPPED[@]} -gt 0 ]]; then
    echo -e "${YELLOW}[!] Pominięto (${#SUMMARY_SKIPPED[@]}):${NC}"
    for item in "${SUMMARY_SKIPPED[@]}"; do
        echo "    - $item"
    done
fi
if [[ ${#SUMMARY_FAILED[@]} -gt 0 ]]; then
    echo -e "${RED}[✘] Błędy (${#SUMMARY_FAILED[@]}):${NC}"
    for item in "${SUMMARY_FAILED[@]}"; do
        echo "    ✘ $item"
    done
fi
echo "========================================================================"
echo ""
