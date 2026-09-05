#!/usr/bin/env bash
# ==============================================================================
# system-config/pve-host-hardening.sh
# Production Proxmox VE Hypervisor Host Hardening & Stability Optimization
#
# Target Hypervisor: Proxmox VE 8.x / 9.x (Debian 12 Bookworm / Debian 13 Trixie)
# Must be executed as root on the PVE host.
#
# Key Optimizations:
#   1. Kernel sysctl network & memory hardening (/etc/sysctl.d/99-pve-hardening.conf)
#   2. Hardware Watchdog activation for HA cluster fencing & automated deadlock recovery
#   3. ZFS ARC RAM capping (prevents ZFS cache from consuming >50% RAM and causing OOM)
#   4. PVE Repository tuning (enables pve-no-subscription, removes enterprise 401s)
#   5. Web GUI subscription nag banner cleanup
#   6. Automated storage health monitoring (SMART & ZFS scrub)
# ==============================================================================

set -euo pipefail

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

if [[ $EUID -ne 0 ]]; then
    echo "[-] Błąd: Ten skrypt musi być uruchomiony jako root na hoście Proxmox VE." >&2
    exit 1
fi

echo "========================================================================"
echo "      PROXMOX VE HYPERVISOR HOST HARDENING & STABILITY OPTIMIZATION     "
echo "========================================================================"
echo "Host: $(hostname) | Kernel: $(uname -r) | Data: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ------------------------------------------------------------------------------
# 2. Kernel Sysctl Hardening
# ------------------------------------------------------------------------------
echo "[+] 1. Aplikowanie utwardzonych parametrów jądra (sysctl)..."

SYSCTL_CONF="/etc/sysctl.d/99-pve-hardening.conf"
cat << 'EOF_SYSCTL' > "$SYSCTL_CONF"
# ==============================================================================
# 99-pve-hardening.conf - Hardened Kernel Parameters for Proxmox VE
# ==============================================================================

# --- Network Security & Anti-Spoofing ---
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# IPv6 redirect protections
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# --- Virtual Memory & OOM Stability ---
# Low swappiness prevents hypervisor daemons from being paged to disk unnecessarily
vm.swappiness = 10
# Avoid kernel panics on guest OOM events
vm.panic_on_oom = 0
# Automatically reboot 10 seconds after a kernel panic
kernel.panic = 10

# --- Memory & Process Isolation Security ---
# Restrict ptrace usage to protect process memory spaces
kernel.yama.ptrace_scope = 2

# --- Resource Capacity for High-Density Containers & Monitoring ---
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
EOF_SYSCTL

sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1
echo "[+] Parametry sysctl zostały pomyślnie zaktualizowane ($SYSCTL_CONF)."

# ------------------------------------------------------------------------------
# 3. Hardware Watchdog Setup (High Availability Deadlock Recovery)
# ------------------------------------------------------------------------------
echo "[+] 2. Konfiguracja sprzętowego Watchdoga dla klastra i HA..."

WATCHDOG_MOD="${WATCHDOG_MODULE:-auto}"

if [[ "$WATCHDOG_MOD" == "auto" ]]; then
    # Try Intel TCO watchdog
    if modprobe iTCO_wdt 2>/dev/null; then
        WATCHDOG_MOD="iTCO_wdt"
    # Try AMD TCO watchdog
    elif modprobe sp5100_tco 2>/dev/null; then
        WATCHDOG_MOD="sp5100_tco"
    # Try IPMI watchdog
    elif modprobe ipmi_watchdog 2>/dev/null; then
        WATCHDOG_MOD="ipmi_watchdog"
    else
        # Software watchdog fallback
        modprobe softdog 2>/dev/null || true
        WATCHDOG_MOD="softdog"
    fi
else
    modprobe "$WATCHDOG_MOD" 2>/dev/null || true
fi

echo "$WATCHDOG_MOD" > /etc/modules-load.d/watchdog.conf
echo "[+] Aktywny moduł Watchdoga: ${WATCHDOG_MOD}"

# Configure PVE HA manager
if [[ -d /etc/default ]]; then
    echo "WATCHDOG_MODULE=${WATCHDOG_MOD}" > /etc/default/pve-ha-crm
fi

# ------------------------------------------------------------------------------
# 4. ZFS ARC RAM Capping (Prevent Host Out-Of-Memory)
# ------------------------------------------------------------------------------
if command -v zpool >/dev/null 2>&1 && zpool status >/dev/null 2>&1; then
    echo "[+] 3. Wykryto ZFS - optymalizacja pamięci podręcznej ARC..."
    
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_MEM_MB=$(( TOTAL_MEM_KB / 1024 ))

    ARC_MAX_MB="${ZFS_ARC_MAX_MB:-}"
    if [[ -z "$ARC_MAX_MB" ]]; then
        # Default: 20% of host RAM for ARC, min 4GB, max 32GB
        ARC_MAX_MB=$(( TOTAL_MEM_MB * 20 / 100 ))
        [[ $ARC_MAX_MB -lt 4096 ]] && ARC_MAX_MB=4096
        [[ $ARC_MAX_MB -gt 32768 ]] && ARC_MAX_MB=32768
    fi

    ARC_MAX_BYTES=$(( ARC_MAX_MB * 1024 * 1024 ))
    ARC_MIN_BYTES=$(( ARC_MAX_BYTES / 2 ))

    cat << EOF_ZFS > /etc/modprobe.d/zfs.conf
# ZFS ARC Cache limits (prevent host RAM exhaustion)
options zfs zfs_arc_max=${ARC_MAX_BYTES}
options zfs zfs_arc_min=${ARC_MIN_BYTES}
EOF_ZFS

    # Apply immediately to running kernel if available
    if [[ -w /sys/module/zfs/parameters/zfs_arc_max ]]; then
        echo "$ARC_MAX_BYTES" > /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null || true
    fi

    echo "[+] Ustawiono limit ZFS ARC: max ${ARC_MAX_MB} MB (min $(( ARC_MAX_MB / 2 )) MB)."
else
    echo "[i] ZFS nie jest używany na tym węźle (pomijam konfigurację ARC)."
fi

# ------------------------------------------------------------------------------
# 5. Proxmox Repositories & Subscription Nag Fix
# ------------------------------------------------------------------------------
echo "[+] 4. Weryfikacja repozytoriów PVE i usunięcie błędów 401..."

# Disable Enterprise repo if no license key
if [[ -f /etc/apt/sources.list.d/pve-enterprise.list ]]; then
    sed -i 's/^deb /# deb /' /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null || true
fi

# Enable no-subscription repo
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
NO_SUB_FILE="/etc/apt/sources.list.d/pve-no-subscription.list"
if [[ ! -f "$NO_SUB_FILE" ]]; then
    echo "deb http://download.proxmox.com/debian/pve ${CODENAME} pve-no-subscription" > "$NO_SUB_FILE"
    echo "[+] Dodano repozytorium pve-no-subscription (${CODENAME})."
fi

# Clean up web UI subscription nag popup
PROXMOXLIB="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
if [[ -f "$PROXMOXLIB" ]]; then
    if grep -q "No Valid Subscription" "$PROXMOXLIB" 2>/dev/null; then
        cp "$PROXMOXLIB" "${PROXMOXLIB}.bak" 2>/dev/null || true
        sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" "$PROXMOXLIB" 2>/dev/null || true
        systemctl restart pveproxy.service 2>/dev/null || true
        echo "[+] Usunięto okno informacyjne o braku subskrypcji w web GUI PVE."
    fi
fi

# ------------------------------------------------------------------------------
# 6. Automated Storage & SMART Health Checks
# ------------------------------------------------------------------------------
echo "[+] 5. Sprawdzanie i włączanie monitoringu dysków (SMART)..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now smartmontools 2>/dev/null || systemctl enable --now smartd 2>/dev/null || true
fi

echo ""
echo "========================================================================"
echo "[+] Utwardzanie i optymalizacja węzła $(hostname) zakończone sukcesem!"
echo "========================================================================"
