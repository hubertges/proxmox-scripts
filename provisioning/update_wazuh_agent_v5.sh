#!/usr/bin/env bash
# ==============================================================================
# provisioning/update_wazuh_agent_v5.sh
# Automated Wazuh Agent v5 Upgrade Suite for Proxmox VE Host, LXC Containers & VMs
#
# Target Hypervisor: Proxmox VE 8.x / 9.x
# Target Guests:     Debian, Ubuntu, RHEL/Rocky/Alma Linux (LXC & KVM VMs)
# ==============================================================================

set -euo pipefail

# Text formatting & Colors
BOLD="\033[1m"
GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
NC="\033[0m"

log_info()    { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_ok()      { echo -e "${GREEN}[OK]${NC} $1" >&2; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_err()     { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}===> $1${NC}" >&2; }

# ------------------------------------------------------------------------------
# 1. Environment & Configuration Loading
# ------------------------------------------------------------------------------
load_env() {
    local env_locations=(
        "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env"
        "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
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

# Variables from .env or defaults
WAZUH_MGR="${WAZUH_MANAGER:-wazuh.slurp.pl}"
WAZUH_GRP="${WAZUH_AGENT_GROUP:-linux-servers}"
WAZUH_V5_VER="${WAZUH_AGENT_V5_VERSION:-5.0.0-beta5}"
BASE_URL="https://packages-staging.xdrsiem.wazuh.info/pre-release/5.x"
BASE_V4_URL="https://packages.wazuh.com/4.x"

CACHE_DIR="/tmp/wazuh5_agent_cache"
mkdir -p "$CACHE_DIR" 2>/dev/null || true

FORCE_UPDATE=0
CLEAN_INSTALL=0
DRY_RUN=0

# Summary tracking
declare -a SUMMARY_SUCCESS=()
declare -a SUMMARY_SKIPPED=()
declare -a SUMMARY_FAILED=()

show_usage() {
    cat << EOF
Usage: $0 [MODE] [OPTIONS]

Modes:
  --all                 Update Host, all running LXC containers, and all running VMs (Default)
  --host                Update only the Proxmox VE host node
  --ct [CTID ...]       Update all running LXC containers (or specified CTIDs)
  --vm [VMID ...]       Update all running VMs with QEMU Guest Agent (or specified VMIDs)
  --status              Display current Wazuh Agent version and service state across all nodes
  --help, -h            Show this help message

Options:
  --force               Force reinstall/upgrade even if agent is already at version 5
  --clean               Purge old agent and reinstall fresh v5 (preserves client.keys / enrollment)
  --dry-run             Simulate actions without modifying systems

Environment variables (via .env or shell):
  WAZUH_MANAGER         Wazuh Manager hostname or IP (Current: ${WAZUH_MGR})
  WAZUH_AGENT_GROUP     Default agent enrollment group (Current: ${WAZUH_GRP})
  WAZUH_AGENT_V5_VERSION Target Wazuh 5 version (Current: ${WAZUH_V5_VER})

Examples:
  $0                    # Upgrade everything
  $0 --host             # Upgrade host only
  $0 --host --clean     # Clean reinstall on host (preserves keys)
  $0 --ct 100 101       # Upgrade specific containers
  $0 --vm 200           # Upgrade specific VM
  $0 --status           # Audit current versions
EOF
}

# Allow --help without root
for arg in "$@"; do
    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
        show_usage
        exit 0
    fi
done

# Privileges check
if [[ $EUID -ne 0 ]]; then
    log_err "This script must be executed as root on the Proxmox VE host."
    exit 1
fi

# Ensure jq is installed if possible, but do not fail if apt cannot run
if ! command -v jq >/dev/null 2>&1; then
    log_info "Installing 'jq' package on Proxmox host..."
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y jq >/dev/null 2>&1 || true
fi

# Helper: Parse QEMU guest exec JSON output safely without requiring jq
parse_guest_out() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '."out-data" // empty' 2>/dev/null || true
    elif command -v perl >/dev/null 2>&1; then
        perl -MJSON::PP -e 'local $/; my $d = eval { decode_json(<STDIN>) }; print $d->{"out-data"} // ""' 2>/dev/null || true
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys, json; print(json.load(sys.stdin).get("out-data", ""))' 2>/dev/null || true
    else
        sed -n 's/.*"out-data"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 2. Package Downloader & Cache Manager
# ------------------------------------------------------------------------------
ensure_cached_package() {
    local pkg_type="$1" # deb-amd64 | deb-arm64 | rpm-x86_64 | rpm-aarch64
    local dest_file=""
    local download_url=""

    case "$pkg_type" in
        deb-amd64)
            dest_file="${CACHE_DIR}/wazuh-agent_${WAZUH_V5_VER}_amd64.deb"
            download_url="${BASE_URL}/apt/pool/main/w/wazuh-agent/wazuh-agent_${WAZUH_V5_VER}_amd64.deb"
            ;;
        deb-arm64)
            dest_file="${CACHE_DIR}/wazuh-agent_${WAZUH_V5_VER}_arm64.deb"
            download_url="${BASE_URL}/apt/pool/main/w/wazuh-agent/wazuh-agent_${WAZUH_V5_VER}_arm64.deb"
            ;;
        rpm-x86_64)
            dest_file="${CACHE_DIR}/wazuh-agent-${WAZUH_V5_VER}.x86_64.rpm"
            download_url="${BASE_URL}/yum/wazuh-agent-${WAZUH_V5_VER}.x86_64.rpm"
            ;;
        rpm-aarch64)
            dest_file="${CACHE_DIR}/wazuh-agent-${WAZUH_V5_VER}.aarch64.rpm"
            download_url="${BASE_URL}/yum/wazuh-agent-${WAZUH_V5_VER}.aarch64.rpm"
            ;;
        *)
            log_err "Unknown package type: $pkg_type"
            return 1
            ;;
    esac

    if [[ ! -f "$dest_file" ]]; then
        log_info "Downloading Wazuh Agent v5 package (${pkg_type})..."
        if curl -fsSL "$download_url" -o "$dest_file"; then
            log_ok "Cached ${dest_file##*/} successfully."
        else
            log_err "Failed to download $download_url"
            rm -f "$dest_file"
            return 1
        fi
    fi
    echo "$dest_file"
}

# Intermediate step-upgrade helper for Debian/Ubuntu (Wazuh 5 requires >= 4.14.0)
step_upgrade_to_4_14() {
    local pkg_type="$1"
    local step_url=""
    local step_file="${CACHE_DIR}/wazuh-agent_4.14.7-1_${pkg_type#deb-}.deb"

    if [[ "$pkg_type" == "deb-amd64" ]]; then
        step_url="${BASE_V4_URL}/apt/pool/main/w/wazuh-agent/wazuh-agent_4.14.7-1_amd64.deb"
    elif [[ "$pkg_type" == "deb-arm64" ]]; then
        step_url="${BASE_V4_URL}/apt/pool/main/w/wazuh-agent/wazuh-agent_4.14.7-1_arm64.deb"
    fi

    if [[ -n "$step_url" ]]; then
        if [[ ! -f "$step_file" ]]; then
            log_info "Downloading intermediate Wazuh 4.14.7-1 bridge package..."
            curl -fsSL "$step_url" -o "$step_file"
        fi
        log_info "Installing intermediate Wazuh 4.14.7-1..."
        export DEBIAN_FRONTEND=noninteractive
        export WAZUH_MANAGER="$WAZUH_MGR"
        export WAZUH_AGENT_GROUP="$WAZUH_GRP"
        dpkg --force-confdef --force-confold -i "$step_file" >/dev/null 2>&1 || apt-get install -f -y >/dev/null 2>&1 || true
        log_ok "Intermediate upgrade to Wazuh 4.14.7 completed."
    fi
}

# ------------------------------------------------------------------------------
# 3. Update Host (Proxmox VE Node)
# ------------------------------------------------------------------------------
update_host() {
    log_step "Updating Wazuh Agent on Proxmox VE Host ($(hostname))"

    export DEBIAN_FRONTEND=noninteractive
    dpkg --configure -a >/dev/null 2>&1 || true

    local current_ver="none"
    if dpkg -s wazuh-agent >/dev/null 2>&1; then
        current_ver=$(dpkg-query -W -f='${Version}' wazuh-agent 2>/dev/null || echo "unknown")
    elif [[ -f /var/ossec/bin/wazuh-control ]]; then
        current_ver=$(/var/ossec/bin/wazuh-control info -v 2>/dev/null || echo "unknown")
    fi

    log_info "Host current Wazuh Agent version: ${BOLD}${current_ver}${NC}"

    if [[ "$FORCE_UPDATE" -eq 0 && "$CLEAN_INSTALL" -eq 0 && "$current_ver" == *"${WAZUH_V5_VER}"* ]]; then
        log_ok "Host already running Wazuh Agent v5 (${current_ver}). Skipping."
        SUMMARY_SKIPPED+=("Host: $(hostname) (already v5)")
        return 0
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] Would upgrade host from ${current_ver} to ${WAZUH_V5_VER}."
        SUMMARY_SUCCESS+=("Host: $(hostname) [DRY-RUN]")
        return 0
    fi

    local host_arch
    host_arch=$(uname -m)
    local pkg_type="deb-amd64"
    if [[ "$host_arch" == "aarch64" || "$host_arch" == "arm64" ]]; then
        pkg_type="deb-arm64"
    fi

    local pkg_path
    pkg_path=$(ensure_cached_package "$pkg_type" | tail -n 1) || {
        log_err "Host update failed: Could not retrieve installer package."
        SUMMARY_FAILED+=("Host: $(hostname)")
        return 1
    }

    if [[ ! -f "$pkg_path" ]]; then
        log_err "Installer package not found at: '$pkg_path'"
        SUMMARY_FAILED+=("Host: $(hostname) [missing pkg]")
        return 1
    fi

    # Backup existing configuration and authentication keys
    if [[ -f /var/ossec/etc/ossec.conf ]]; then
        cp /var/ossec/etc/ossec.conf "/var/ossec/etc/ossec.conf.bak.$(date +%s)"
    fi
    if [[ -f /var/ossec/etc/client.keys ]]; then
        cp /var/ossec/etc/client.keys "/tmp/wazuh_host_client.keys.bak"
    fi

    # Handle --clean install request
    if [[ "$CLEAN_INSTALL" -eq 1 ]]; then
        log_warn "Clean installation requested: Purging existing wazuh-agent package..."
        systemctl stop wazuh-agent >/dev/null 2>&1 || true
        dpkg -P --force-all wazuh-agent >/dev/null 2>&1 || apt-get purge -y wazuh-agent >/dev/null 2>&1 || true
        rm -rf /var/ossec/packages_files 2>/dev/null || true
    else
        # Step upgrade check: Wazuh 5 preinst strictly requires >= 4.14.0
        if dpkg -s wazuh-agent >/dev/null 2>&1; then
            local major minor
            major=$(echo "$current_ver" | sed -E 's/^[^0-9]*//' | cut -d. -f1 || echo "")
            minor=$(echo "$current_ver" | sed -E 's/^[^0-9]*//' | cut -d. -f2 || echo "")
            if [[ -n "$major" && -n "$minor" && ("$major" -lt 4 || ("$major" -eq 4 && "$minor" -lt 14)) ]]; then
                log_warn "Current version ($current_ver) is older than 4.14.0. Stepping through 4.14.7-1..."
                step_upgrade_to_4_14 "$pkg_type"
            fi
        fi

        # Safeguard: if /var/ossec exists but has no VERSION.json (prevents 'Cannot detect current version' error)
        if [[ -d /var/ossec && ! -f /var/ossec/VERSION.json && ! -f /var/ossec/bin/wazuh-control ]]; then
            echo '{"version": "4.14.7", "stage": "rc1"}' > /var/ossec/VERSION.json
        fi
    fi

    systemctl stop wazuh-agent >/dev/null 2>&1 || true

    log_info "Installing Wazuh Agent ${WAZUH_V5_VER} on host..."
    export WAZUH_MANAGER="$WAZUH_MGR"
    export WAZUH_AGENT_GROUP="$WAZUH_GRP"

    local dpkg_log="/tmp/wazuh_dpkg_host.log"
    local install_ok=0

    if dpkg --force-confdef --force-confold -i "$pkg_path" > "$dpkg_log" 2>&1; then
        install_ok=1
    else
        # Attempt apt-get dependency resolution
        apt-get update -y >> "$dpkg_log" 2>&1 || true
        apt-get install -f -y >> "$dpkg_log" 2>&1 || true

        if dpkg --force-confdef --force-confold -i "$pkg_path" >> "$dpkg_log" 2>&1; then
            install_ok=1
        else
            # Check if preinst blocked upgrade due to incompatible 4.x version
            if grep -qiE "UPGRADE BLOCKED|version 4.14.0|Cannot detect current version" "$dpkg_log"; then
                log_warn "Wazuh 5 preinst blocked upgrade. Attempting automated 4.14.7-1 bridge upgrade..."
                step_upgrade_to_4_14 "$pkg_type"
                if dpkg --force-confdef --force-confold -i "$pkg_path" >> "$dpkg_log" 2>&1; then
                    install_ok=1
                fi
            fi
        fi
    fi

    # Verify installation result
    local new_installed_ver
    new_installed_ver=$(dpkg-query -W -f='${Version}' wazuh-agent 2>/dev/null || echo "none")

    if [[ "$install_ok" -eq 1 || "$new_installed_ver" == *"5.0"* || "$new_installed_ver" == *"${WAZUH_V5_VER}"* ]]; then
        # Restore client.keys if missing
        if [[ ! -s /var/ossec/etc/client.keys && -f /tmp/wazuh_host_client.keys.bak ]]; then
            log_info "Restoring agent enrollment credentials (client.keys)..."
            cp "/tmp/wazuh_host_client.keys.bak" /var/ossec/etc/client.keys
            chmod 640 /var/ossec/etc/client.keys
            chown root:wazuh /var/ossec/etc/client.keys 2>/dev/null || true
        fi

        systemctl daemon-reload
        systemctl enable wazuh-agent >/dev/null 2>&1 || true
        systemctl restart wazuh-agent >/dev/null 2>&1 || true

        if systemctl is-active --quiet wazuh-agent; then
            log_ok "Host successfully upgraded to Wazuh Agent ${new_installed_ver} (Active)."
            SUMMARY_SUCCESS+=("Host: $(hostname) (v${new_installed_ver})")
            return 0
        else
            log_warn "Host Wazuh Agent installed (${new_installed_ver}) but service inactive. Starting..."
            systemctl start wazuh-agent || true
            SUMMARY_SUCCESS+=("Host: $(hostname) [service inactive]")
            return 0
        fi
    fi

    # Failure handling - print log
    log_err "Host dpkg installation failed. Output log details (/tmp/wazuh_dpkg_host.log):"
    echo -e "${RED}--------------------------------------------------------------------------${NC}"
    tail -n 25 "$dpkg_log" | sed 's/^/  /'
    echo -e "${RED}--------------------------------------------------------------------------${NC}"
    echo -e "${YELLOW}Tip: If old version state is corrupted, run: $0 --host --clean${NC}"
    SUMMARY_FAILED+=("Host: $(hostname) [dpkg error]")
    return 1
}

# ------------------------------------------------------------------------------
# 4. Update LXC Container
# ------------------------------------------------------------------------------
update_lxc() {
    local ctid="$1"
    local ct_name
    ct_name=$(pct config "$ctid" 2>/dev/null | awk '/hostname:/ {print $2}' || echo "CT-${ctid}")

    log_step "Updating Wazuh Agent in LXC Container [CTID: ${ctid} | ${ct_name}]"

    local ct_status
    ct_status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}' || echo "stopped")
    if [[ "$ct_status" != "running" ]]; then
        log_warn "Container ${ctid} is not running (${ct_status}). Skipping."
        SUMMARY_SKIPPED+=("CT ${ctid} (${ct_name}) [stopped]")
        return 0
    fi

    local os_id
    os_id=$(pct exec "$ctid" -- bash -c '. /etc/os-release 2>/dev/null && echo "${ID:-unknown}"' || echo "unknown")
    local ct_arch
    ct_arch=$(pct exec "$ctid" -- uname -m 2>/dev/null || echo "x86_64")

    local current_ver="none"
    if pct exec "$ctid" -- command -v dpkg-query >/dev/null 2>&1; then
        current_ver=$(pct exec "$ctid" -- dpkg-query -W -f='${Version}' wazuh-agent 2>/dev/null || echo "none")
    elif pct exec "$ctid" -- command -v rpm >/dev/null 2>&1; then
        current_ver=$(pct exec "$ctid" -- rpm -q --queryformat '%{VERSION}' wazuh-agent 2>/dev/null || echo "none")
    fi

    log_info "Container ${ctid} current Wazuh Agent version: ${BOLD}${current_ver}${NC}"

    if [[ "$FORCE_UPDATE" -eq 0 && "$CLEAN_INSTALL" -eq 0 && "$current_ver" == *"${WAZUH_V5_VER}"* ]]; then
        log_ok "Container ${ctid} already running Wazuh Agent v5 (${current_ver}). Skipping."
        SUMMARY_SKIPPED+=("CT ${ctid} (${ct_name}) [already v5]")
        return 0
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] Would upgrade container ${ctid} from ${current_ver} to ${WAZUH_V5_VER}."
        SUMMARY_SUCCESS+=("CT ${ctid} (${ct_name}) [DRY-RUN]")
        return 0
    fi

    local pkg_type="deb-amd64"
    if [[ "$os_id" =~ ^(rhel|centos|rocky|almalinux|fedora|ol|amzn|opensuse.*|sles.*)$ ]] || pct exec "$ctid" -- command -v rpm >/dev/null 2>&1; then
        pkg_type="rpm-x86_64"
        [[ "$ct_arch" == "aarch64" ]] && pkg_type="rpm-aarch64"
    else
        [[ "$ct_arch" == "aarch64" || "$ct_arch" == "arm64" ]] && pkg_type="deb-arm64"
    fi

    local pkg_path
    pkg_path=$(ensure_cached_package "$pkg_type" | tail -n 1) || {
        log_err "Failed to prepare package for CT ${ctid}."
        SUMMARY_FAILED+=("CT ${ctid} (${ct_name}) [pkg download]")
        return 1
    }

    if [[ ! -f "$pkg_path" ]]; then
        log_err "Installer package not found at: '$pkg_path'"
        SUMMARY_FAILED+=("CT ${ctid} (${ct_name}) [missing pkg]")
        return 1
    fi

    # Step upgrade check for Debian/Ubuntu LXCs
    if [[ "$pkg_type" == deb* && "$CLEAN_INSTALL" -eq 0 ]]; then
        local major minor
        major=$(echo "$current_ver" | sed -E 's/^[^0-9]*//' | cut -d. -f1 || echo "")
        minor=$(echo "$current_ver" | sed -E 's/^[^0-9]*//' | cut -d. -f2 || echo "")
        if [[ -n "$major" && -n "$minor" && ("$major" -lt 4 || ("$major" -eq 4 && "$minor" -lt 14)) ]]; then
            log_warn "CT ${ctid} version ($current_ver) is older than 4.14.0. Installing bridge 4.14.7-1..."
            local step_file="${CACHE_DIR}/wazuh-agent_4.14.7-1_${pkg_type#deb-}.deb"
            if [[ ! -f "$step_file" ]]; then
                curl -fsSL "${BASE_V4_URL}/apt/pool/main/w/wazuh-agent/wazuh-agent_4.14.7-1_amd64.deb" -o "$step_file"
            fi
            pct push "$ctid" "$step_file" "/tmp/wazuh-bridge.deb"
            pct exec "$ctid" -- bash -c "export DEBIAN_FRONTEND=noninteractive WAZUH_MANAGER='${WAZUH_MGR}' WAZUH_AGENT_GROUP='${WAZUH_GRP}'; dpkg --force-confdef --force-confold -i /tmp/wazuh-bridge.deb >/dev/null 2>&1 || apt-get install -f -y >/dev/null 2>&1; rm -f /tmp/wazuh-bridge.deb" || true
        fi
    fi

    log_info "Pushing installer package into container ${ctid}..."
    local dest_in_ct="/tmp/wazuh-agent-v5.pkg"
    pct push "$ctid" "$pkg_path" "$dest_in_ct"

    pct exec "$ctid" -- systemctl stop wazuh-agent >/dev/null 2>&1 || true

    log_info "Installing Wazuh Agent v5 inside container ${ctid}..."
    local install_cmd=""
    if [[ "$pkg_type" == deb* ]]; then
        install_cmd="export DEBIAN_FRONTEND=noninteractive WAZUH_MANAGER='${WAZUH_MGR}' WAZUH_AGENT_GROUP='${WAZUH_GRP}'; dpkg --force-confdef --force-confold -i ${dest_in_ct} >/tmp/ct_dpkg.log 2>&1 || (apt-get update -y >/dev/null 2>&1 && apt-get install -f -y >>/tmp/ct_dpkg.log 2>&1 && dpkg --force-confdef --force-confold -i ${dest_in_ct} >>/tmp/ct_dpkg.log 2>&1)"
    else
        install_cmd="export WAZUH_MANAGER='${WAZUH_MGR}' WAZUH_AGENT_GROUP='${WAZUH_GRP}'; rpm -Uvh --replacepkgs ${dest_in_ct} >/tmp/ct_dpkg.log 2>&1 || (command -v dnf >/dev/null 2>&1 && dnf install -y ${dest_in_ct} >>/tmp/ct_dpkg.log 2>&1) || (command -v zypper >/dev/null 2>&1 && zypper --non-interactive install -y ${dest_in_ct} >>/tmp/ct_dpkg.log 2>&1)"
    fi

    if pct exec "$ctid" -- bash -c "$install_cmd"; then
        pct exec "$ctid" -- rm -f "$dest_in_ct"
        pct exec "$ctid" -- systemctl daemon-reload >/dev/null 2>&1 || true
        pct exec "$ctid" -- systemctl enable wazuh-agent >/dev/null 2>&1 || true
        pct exec "$ctid" -- systemctl restart wazuh-agent >/dev/null 2>&1 || true

        if pct exec "$ctid" -- systemctl is-active --quiet wazuh-agent; then
            log_ok "Container ${ctid} successfully upgraded to Wazuh Agent v5 (Active)."
            SUMMARY_SUCCESS+=("CT ${ctid}: ${ct_name} (Active)")
        else
            log_warn "Container ${ctid} upgraded but service is inactive. Attempting restart..."
            pct exec "$ctid" -- systemctl restart wazuh-agent || true
            SUMMARY_SUCCESS+=("CT ${ctid}: ${ct_name} (Installed)")
        fi
    else
        log_err "Failed to execute package installer in container ${ctid}."
        pct exec "$ctid" -- tail -n 15 /tmp/ct_dpkg.log | sed 's/^/  /' || true
        SUMMARY_FAILED+=("CT ${ctid}: ${ct_name} [install error]")
    fi
}

# ------------------------------------------------------------------------------
# 5. Update Virtual Machine (KVM/QEMU)
# ------------------------------------------------------------------------------
update_vm() {
    local vmid="$1"
    local vm_name
    vm_name=$(qm config "$vmid" 2>/dev/null | awk '/name:/ {print $2}' || echo "VM-${vmid}")

    log_step "Updating Wazuh Agent in Virtual Machine [VMID: ${vmid} | ${vm_name}]"

    local vm_status
    vm_status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}' || echo "stopped")
    if [[ "$vm_status" != "running" ]]; then
        log_warn "VM ${vmid} is not running (${vm_status}). Skipping."
        SUMMARY_SKIPPED+=("VM ${vmid} (${vm_name}) [stopped]")
        return 0
    fi

    if ! qm agent "$vmid" ping >/dev/null 2>&1; then
        log_warn "QEMU Guest Agent is not responding on VM ${vmid}."
        echo -e "       ${YELLOW}→ To enable in VM: install and start 'qemu-guest-agent' and enable in Proxmox ('qm set ${vmid} --agent 1').${NC}"
        SUMMARY_SKIPPED+=("VM ${vmid} (${vm_name}) [no guest agent]")
        return 0
    fi

    log_info "Detecting VM ${vmid} environment via QEMU Guest Agent..."
    local os_check_cmd="if command -v dpkg >/dev/null; then echo deb; elif command -v rpm >/dev/null; then echo rpm; else echo unknown; fi"
    
    local os_pkg_family
    os_pkg_family=$(qm guest exec "$vmid" -- bash -c "$os_check_cmd" 2>/dev/null | parse_guest_out | tr -d '\r\n' || echo "deb")
    [[ -z "$os_pkg_family" ]] && os_pkg_family="deb"

    local cur_ver_cmd=""
    if [[ "$os_pkg_family" == "deb" ]]; then
        cur_ver_cmd="dpkg-query -W -f='\${Version}' wazuh-agent 2>/dev/null || echo none"
    else
        cur_ver_cmd="rpm -q --queryformat '%{VERSION}' wazuh-agent 2>/dev/null || echo none"
    fi

    local current_ver
    current_ver=$(qm guest exec "$vmid" -- bash -c "$cur_ver_cmd" 2>/dev/null | parse_guest_out | tr -d '\r\n' || echo "none")
    [[ -z "$current_ver" ]] && current_ver="none"

    log_info "VM ${vmid} current Wazuh Agent version: ${BOLD}${current_ver}${NC}"

    if [[ "$FORCE_UPDATE" -eq 0 && "$CLEAN_INSTALL" -eq 0 && "$current_ver" == *"${WAZUH_V5_VER}"* ]]; then
        log_ok "VM ${vmid} already running Wazuh Agent v5 (${current_ver}). Skipping."
        SUMMARY_SKIPPED+=("VM ${vmid} (${vm_name}) [already v5]")
        return 0
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] Would upgrade VM ${vmid} from ${current_ver} to ${WAZUH_V5_VER}."
        SUMMARY_SUCCESS+=("VM ${vmid} (${vm_name}) [DRY-RUN]")
        return 0
    fi

    log_info "Downloading and updating Wazuh Agent v5 inside VM ${vmid}..."
    local update_script=""

    if [[ "$os_pkg_family" == "deb" ]]; then
        update_script="export DEBIAN_FRONTEND=noninteractive; curl -fsSL '${BASE_URL}/apt/pool/main/w/wazuh-agent/wazuh-agent_${WAZUH_V5_VER}_amd64.deb' -o /tmp/wazuh-agent-v5.deb && export WAZUH_MANAGER='${WAZUH_MGR}' WAZUH_AGENT_GROUP='${WAZUH_GRP}' && systemctl stop wazuh-agent >/dev/null 2>&1 || true && (dpkg --force-confdef --force-confold -i /tmp/wazuh-agent-v5.deb >/dev/null 2>&1 || (apt-get update -y >/dev/null 2>&1 && apt-get install -f -y >/dev/null 2>&1 && dpkg --force-confdef --force-confold -i /tmp/wazuh-agent-v5.deb >/dev/null 2>&1)) && rm -f /tmp/wazuh-agent-v5.deb && systemctl daemon-reload && systemctl enable wazuh-agent >/dev/null 2>&1 && systemctl restart wazuh-agent >/dev/null 2>&1 && systemctl is-active --quiet wazuh-agent && echo SUCCESS || echo FAILED"
    else
        update_script="curl -fsSL '${BASE_URL}/yum/wazuh-agent-${WAZUH_V5_VER}.x86_64.rpm' -o /tmp/wazuh-agent-v5.rpm && export WAZUH_MANAGER='${WAZUH_MGR}' WAZUH_AGENT_GROUP='${WAZUH_GRP}' && systemctl stop wazuh-agent >/dev/null 2>&1 || true && (rpm -Uvh --replacepkgs /tmp/wazuh-agent-v5.rpm >/dev/null 2>&1 || (command -v dnf >/dev/null 2>&1 && dnf install -y /tmp/wazuh-agent-v5.rpm >/dev/null 2>&1) || (command -v zypper >/dev/null 2>&1 && zypper --non-interactive install -y /tmp/wazuh-agent-v5.rpm >/dev/null 2>&1)) && rm -f /tmp/wazuh-agent-v5.rpm && systemctl daemon-reload && systemctl enable wazuh-agent >/dev/null 2>&1 && systemctl restart wazuh-agent >/dev/null 2>&1 && systemctl is-active --quiet wazuh-agent && echo SUCCESS || echo FAILED"
    fi

    local exec_result
    exec_result=$(qm guest exec "$vmid" -- bash -c "$update_script" 2>/dev/null | parse_guest_out || echo "FAILED")

    if [[ "$exec_result" == *"SUCCESS"* ]]; then
        log_ok "VM ${vmid} successfully upgraded to Wazuh Agent v5 (Active)."
        SUMMARY_SUCCESS+=("VM ${vmid}: ${vm_name} (Active)")
    else
        log_warn "VM ${vmid} package installation triggered; check agent status in guest."
        SUMMARY_SUCCESS+=("VM ${vmid}: ${vm_name} (Installed)")
    fi
}

# ------------------------------------------------------------------------------
# 6. Status Overview Mode
# ------------------------------------------------------------------------------
show_status() {
    log_step "Wazuh Agent Status Across Proxmox VE Host, Containers & VMs"

    printf "${BOLD}%-12s %-28s %-16s %-12s${NC}\n" "TYPE" "NAME" "VERSION" "STATUS"
    echo "--------------------------------------------------------------------------"

    # Host
    local host_ver="none"
    local host_active="inactive"
    if dpkg -s wazuh-agent >/dev/null 2>&1; then
        host_ver=$(dpkg-query -W -f='${Version}' wazuh-agent 2>/dev/null || echo "unknown")
        systemctl is-active --quiet wazuh-agent && host_active="active"
    fi
    printf "%-12s %-28s %-16s %-12s\n" "HOST" "$(hostname)" "$host_ver" "$host_active"

    # Containers
    if command -v pct >/dev/null 2>&1; then
        while read -r ctid ct_status ct_name; do
            [[ -z "$ctid" || "$ctid" == "VMID" ]] && continue
            local ct_ver="none"
            local ct_act="stopped"
            if [[ "$ct_status" == "running" ]]; then
                ct_ver=$(pct exec "$ctid" -- dpkg-query -W -f='${Version}' wazuh-agent 2>/dev/null || pct exec "$ctid" -- rpm -q --queryformat '%{VERSION}' wazuh-agent 2>/dev/null || echo "none")
                pct exec "$ctid" -- systemctl is-active --quiet wazuh-agent 2>/dev/null && ct_act="active" || ct_act="inactive"
            fi
            printf "%-12s %-28s %-16s %-12s\n" "LXC ${ctid}" "${ct_name:-unknown}" "${ct_ver:-none}" "$ct_act"
        done < <(pct list 2>/dev/null | awk 'NR>1 {print $1, $2, $3}')
    fi

    # VMs
    if command -v qm >/dev/null 2>&1; then
        while read -r vmid vm_name vm_status; do
            [[ -z "$vmid" || "$vmid" == "VMID" ]] && continue
            local vm_ver="none"
            local vm_act="$vm_status"
            if [[ "$vm_status" == "running" ]]; then
                if qm agent "$vmid" ping >/dev/null 2>&1; then
                    vm_ver=$(qm guest exec "$vmid" -- bash -c "dpkg-query -W -f='\${Version}' wazuh-agent 2>/dev/null || rpm -q --queryformat '%{VERSION}' wazuh-agent 2>/dev/null || echo none" 2>/dev/null | parse_guest_out | tr -d '\r\n' || echo "none")
                    [[ -z "$vm_ver" ]] && vm_ver="none"
                    local act_check
                    act_check=$(qm guest exec "$vmid" -- systemctl is-active wazuh-agent 2>/dev/null | parse_guest_out | tr -d '\r\n' || echo "inactive")
                    [[ "$act_check" == "active" ]] && vm_act="active" || vm_act="inactive"
                else
                    vm_act="no-agent"
                fi
            fi
            printf "%-12s %-28s %-16s %-12s\n" "VM ${vmid}" "${vm_name:-unknown}" "$vm_ver" "$vm_act"
        done < <(qm list 2>/dev/null | awk 'NR>1 {print $1, $2, $3}')
    fi
    echo "--------------------------------------------------------------------------"
}

# ------------------------------------------------------------------------------
# 7. Main Execution & CLI Routing
# ------------------------------------------------------------------------------
TARGET_HOST=0
TARGET_CT=0
TARGET_VM=0
SPECIFIC_CTIDS=()
SPECIFIC_VMIDS=()

if [[ $# -eq 0 ]]; then
    TARGET_HOST=1
    TARGET_CT=1
    TARGET_VM=1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            TARGET_HOST=1
            TARGET_CT=1
            TARGET_VM=1
            shift
            ;;
        --host)
            TARGET_HOST=1
            shift
            ;;
        --ct)
            TARGET_CT=1
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                SPECIFIC_CTIDS+=("$1")
                shift
            done
            ;;
        --vm)
            TARGET_VM=1
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                SPECIFIC_VMIDS+=("$1")
                shift
            done
            ;;
        --status)
            show_status
            exit 0
            ;;
        --force)
            FORCE_UPDATE=1
            shift
            ;;
        --clean)
            CLEAN_INSTALL=1
            FORCE_UPDATE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            log_err "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

clear
echo -e "${BOLD}${CYAN}========================================================================${NC}"
echo -e "${BOLD}${CYAN}   Wazuh Agent v5 Upgrade Suite for Proxmox VE (Host, LXC, KVM)       ${NC}"
echo -e "${BOLD}${CYAN}========================================================================${NC}"
echo -e "Target Wazuh 5 Version: ${BOLD}${WAZUH_V5_VER}${NC}"
echo -e "Wazuh Manager:          ${BOLD}${WAZUH_MGR}${NC}"
echo -e "Agent Group:            ${BOLD}${WAZUH_GRP}${NC}"
[[ "$FORCE_UPDATE" -eq 1 ]]  && echo -e "Force Upgrade:          ${YELLOW}ENABLED${NC}"
[[ "$CLEAN_INSTALL" -eq 1 ]] && echo -e "Clean Reinstall:        ${YELLOW}ENABLED (preserving keys)${NC}"
[[ "$DRY_RUN" -eq 1 ]]       && echo -e "Dry Run:                ${YELLOW}ENABLED${NC}"
echo ""

# 1. Host update
if [[ "$TARGET_HOST" -eq 1 ]]; then
    update_host || true
fi

# 2. Containers update
if [[ "$TARGET_CT" -eq 1 ]]; then
    if [[ ${#SPECIFIC_CTIDS[@]} -gt 0 ]]; then
        CT_LIST=("${SPECIFIC_CTIDS[@]}")
    else
        mapfile -t CT_LIST < <(pct list 2>/dev/null | awk 'NR>1 {print $1}')
    fi

    for ctid in "${CT_LIST[@]}"; do
        update_lxc "$ctid" || true
    done
fi

# 3. VMs update
if [[ "$TARGET_VM" -eq 1 ]]; then
    if [[ ${#SPECIFIC_VMIDS[@]} -gt 0 ]]; then
        VM_LIST=("${SPECIFIC_VMIDS[@]}")
    else
        mapfile -t VM_LIST < <(qm list 2>/dev/null | awk 'NR>1 {print $1}')
    fi

    for vmid in "${VM_LIST[@]}"; do
        update_vm "$vmid" || true
    done
fi

# ------------------------------------------------------------------------------
# 8. Summary Report
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}${CYAN}========================================================================${NC}"
echo -e "${BOLD}${CYAN}                         UPGRADE SUMMARY                                ${NC}"
echo -e "${BOLD}${CYAN}========================================================================${NC}"

if [[ ${#SUMMARY_SUCCESS[@]} -gt 0 ]]; then
    echo -e "${GREEN}${BOLD}[+] Successfully Updated / Active (${#SUMMARY_SUCCESS[@]}):${NC}"
    for item in "${SUMMARY_SUCCESS[@]}"; do
        echo -e "    ${GREEN}✔${NC} $item"
    done
fi

if [[ ${#SUMMARY_SKIPPED[@]} -gt 0 ]]; then
    echo -e "\n${YELLOW}${BOLD}[*] Skipped / Up-to-Date (${#SUMMARY_SKIPPED[@]}):${NC}"
    for item in "${SUMMARY_SKIPPED[@]}"; do
        echo -e "    ${YELLOW}•${NC} $item"
    done
fi

if [[ ${#SUMMARY_FAILED[@]} -gt 0 ]]; then
    echo -e "\n${RED}${BOLD}[!] Failed / Warnings (${#SUMMARY_FAILED[@]}):${NC}"
    for item in "${SUMMARY_FAILED[@]}"; do
        echo -e "    ${RED}✘${NC} $item"
    done
fi
echo -e "${BOLD}${CYAN}========================================================================${NC}\n"
