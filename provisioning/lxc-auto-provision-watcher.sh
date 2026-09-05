#!/usr/bin/env bash
# ==============================================================================
# provisioning/lxc-auto-provision-watcher.sh
# Automated LXC Container Provisioning Watcher for Proxmox VE
#
# Monitors running LXC containers on the Proxmox VE node/cluster.
# When a new or unprovisioned container is started, it automatically
# executes nowykontener.sh to harden the system, install Wazuh Agent v5,
# configure SSH keys, and disable redundant NTP services.
#
# Usage:
#   ./lxc-auto-provision-watcher.sh [OPTIONS]
#
# Options:
#   --daemon              Run continuously as a background service/daemon
#   --run-once            Scan once, provision any unconfigured containers, and exit (default)
#   --interval <seconds>  Poll interval in daemon mode (default: 10)
#   --force <CTID>        Force re-provisioning of a specific container
#   -h, --help            Show this help message
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOWYKONTENER_SCRIPT="${SCRIPT_DIR}/nowykontener.sh"

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

if [[ $EUID -ne 0 ]]; then
    echo "[-] Błąd: Uruchom skrypt jako root na hoście Proxmox VE." >&2
    exit 1
fi

# Fallback path if installed to /etc/pve/scripts
if [[ ! -f "$NOWYKONTENER_SCRIPT" ]]; then
    if [[ -f "/etc/pve/scripts/nowykontener.sh" ]]; then
        NOWYKONTENER_SCRIPT="/etc/pve/scripts/nowykontener.sh"
    fi
fi

if [[ ! -f "$NOWYKONTENER_SCRIPT" ]]; then
    echo "[-] Błąd: Nie znaleziono skryptu nowykontener.sh (szukano w: $NOWYKONTENER_SCRIPT)" >&2
    exit 1
fi

# Configuration Variables
POLL_INTERVAL="${WATCHER_POLL_INTERVAL:-10}"
LOG_FILE="${WATCHER_LOG_FILE:-/var/log/lxc-auto-provision.log}"
HASLA_FILE="${HASLA_FILE:-/etc/pve/secrets/.hasla}"
STATE_DIR="/run/lxc-auto-provision"
FAIL_COOLDOWN="${WATCHER_FAIL_COOLDOWN:-300}" # 5 minutes cooldown before retrying failed CT

mkdir -p "$STATE_DIR" 2>/dev/null || true
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
mkdir -p "$(dirname "$HASLA_FILE")" 2>/dev/null || true

# ------------------------------------------------------------------------------
# 2. Logging Helpers
# ------------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local line="[$ts] [$level] $msg"
    
    echo "$line"
    echo "$line" >> "$LOG_FILE" 2>/dev/null || true
}

log_info()  { log "INFO" "$@"; }
log_ok()    { log "OK" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_err()   { log "ERROR" "$@"; }

# ------------------------------------------------------------------------------
# 3. Container Status Checks
# ------------------------------------------------------------------------------
is_container_running() {
    local ctid="$1"
    local st
    st=$(pct status "$ctid" 2>/dev/null | awk '{print $2}' || echo "stopped")
    [[ "$st" == "running" ]]
}

is_container_ready() {
    local ctid="$1"
    # 1. Verify systemd is running inside container
    if ! pct exec "$ctid" -- test -e /run/systemd/system 2>/dev/null; then
        return 1
    fi
    # 2. Check if apt / dpkg locks are currently held (e.g. by initial cloud-init or boot scripts)
    if pct exec "$ctid" -- fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
       pct exec "$ctid" -- fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
       pct exec "$ctid" -- fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

is_container_provisioned() {
    local ctid="$1"

    # Check 1: Marker file inside container
    if pct exec "$ctid" -- test -f /etc/.lxc_provisioned 2>/dev/null; then
        return 0
    fi

    # Check 2: Entry exists in .hasla
    if [[ -f "$HASLA_FILE" ]] && grep -q "CTID: ${ctid} " "$HASLA_FILE" 2>/dev/null; then
        return 0
    fi

    return 1
}

has_failed_recently() {
    local ctid="$1"
    local fail_marker="${STATE_DIR}/ct_${ctid}.failed"
    if [[ -f "$fail_marker" ]]; then
        local fail_time
        fail_time=$(stat -c %Y "$fail_marker" 2>/dev/null || echo 0)
        local now
        now=$(date +%s)
        local diff=$(( now - fail_time ))
        if [[ $diff -lt $FAIL_COOLDOWN ]]; then
            return 0
        fi
    fi
    return 1
}

mark_container_failed() {
    local ctid="$1"
    touch "${STATE_DIR}/ct_${ctid}.failed"
}

clear_container_failure() {
    local ctid="$1"
    rm -f "${STATE_DIR}/ct_${ctid}.failed"
}

# ------------------------------------------------------------------------------
# 4. Container Provisioning Handler
# ------------------------------------------------------------------------------
provision_ct() {
    local ctid="$1"
    local force="${2:-0}"

    if ! is_container_running "$ctid"; then
        return 0
    fi

    if [[ "$force" -ne 1 ]]; then
        if is_container_provisioned "$ctid"; then
            return 0
        fi

        if has_failed_recently "$ctid"; then
            return 0
        fi
    fi

    log_info "Wykryto nowy lub nieskonfigurowany kontener: CTID $ctid. Oczekiwanie na gotowość systemu..."

    # Wait up to 60s for container systemd and apt to be ready
    local ready=0
    for _ in {1..30}; do
        if is_container_ready "$ctid"; then
            ready=1
            break
        fi
        sleep 2
    done

    if [[ $ready -ne 1 ]]; then
        log_warn "Kontener $ctid nie osiągnął stanu gotowości (systemd/apt lock zajęty). Ponowienie w kolejnym cyklu."
        return 1
    fi

    # Small settle buffer
    sleep 2

    log_info "Rozpoczynanie auto-provisioningu kontenera CTID $ctid..."
    
    local prov_log="/tmp/ct_prov_${ctid}.log"
    if bash "$NOWYKONTENER_SCRIPT" "$ctid" > "$prov_log" 2>&1; then
        log_ok "Kontener CTID $ctid został pomyślnie skonfigurowany (Wazuh v5, użytkownik, SSH, NTP pominięte)."
        clear_container_failure "$ctid"
        rm -f "$prov_log"
        return 0
    else
        log_err "Błąd auto-provisioningu dla CTID $ctid! Zapisano log do: $LOG_FILE"
        echo "--- LOG BŁĘDU CTID $ctid ---" >> "$LOG_FILE"
        cat "$prov_log" >> "$LOG_FILE" 2>/dev/null || true
        echo "--- KONIEC LOGU BŁĘDU ---" >> "$LOG_FILE"
        mark_container_failed "$ctid"
        rm -f "$prov_log"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 5. Scan Cycle
# ------------------------------------------------------------------------------
scan_and_provision() {
    local running_cts=()
    mapfile -t running_cts < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}')

    for ctid in "${running_cts[@]}"; do
        [[ -z "$ctid" ]] && continue
        if ! is_container_provisioned "$ctid"; then
            provision_ct "$ctid" 0 || true
        fi
    done
}

# ------------------------------------------------------------------------------
# 6. Main Entrypoint & CLI Parsing
# ------------------------------------------------------------------------------
MODE="run-once"
FORCE_CTID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --daemon|-d)
            MODE="daemon"
            shift
            ;;
        --run-once|-1)
            MODE="run-once"
            shift
            ;;
        --interval|-i)
            POLL_INTERVAL="$2"
            shift 2
            ;;
        --force|-f)
            FORCE_CTID="$2"
            shift 2
            ;;
        -h|--help)
            echo "Użycie: $0 [--daemon | --run-once] [--interval <sekundy>] [--force <CTID>]"
            exit 0
            ;;
        *)
            echo "[-] Nieznana opcja: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -n "$FORCE_CTID" ]]; then
    log_info "Wymuszone uruchomienie provisioningu dla CTID: $FORCE_CTID"
    clear_container_failure "$FORCE_CTID"
    pct exec "$FORCE_CTID" -- rm -f /etc/.lxc_provisioned 2>/dev/null || true
    provision_ct "$FORCE_CTID" 1
    exit 0
fi

if [[ "$MODE" == "run-once" ]]; then
    log_info "Uruchamianie jednorazowego skanowania kontenerów..."
    scan_and_provision
    log_info "Skanowanie zakończone."
    exit 0
fi

# Daemon Mode
log_info "Uruchamianie usługi LXC Auto-Provision Watcher (interwał: ${POLL_INTERVAL}s)..."
log_info "Logi zapisywane do: $LOG_FILE"

trap 'log_info "Zatrzymywanie LXC Auto-Provision Watcher..."; exit 0' SIGTERM SIGINT

while true; do
    scan_and_provision
    sleep "$POLL_INTERVAL"
done
