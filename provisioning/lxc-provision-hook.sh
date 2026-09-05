#!/usr/bin/env bash
# ==============================================================================
# provisioning/lxc-provision-hook.sh
# Proxmox VE Container Hookscript for Automated Provisioning
#
# Can be attached directly to any LXC container or template:
#   pct set <CTID> -hookscript local:snippets/lxc-provision-hook.sh
#
# Lifecycle Phases passed by Proxmox VE:
#   $1 = CTID / VMID
#   $2 = Phase (pre-start, post-start, pre-stop, post-stop)
# ==============================================================================

set -euo pipefail

CTID="${1:-}"
PHASE="${2:-}"

if [[ -z "$CTID" || -z "$PHASE" ]]; then
    echo "Usage: $0 <CTID> <PHASE>" >&2
    exit 1
fi

LOG_FILE="/var/log/lxc-auto-provision.log"
HASLA_FILE="/etc/pve/secrets/.hasla"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOWYKONTENER_SCRIPT="${SCRIPT_DIR}/nowykontener.sh"
if [[ ! -f "$NOWYKONTENER_SCRIPT" ]]; then
    if [[ -f "/etc/pve/scripts/nowykontener.sh" ]]; then
        NOWYKONTENER_SCRIPT="/etc/pve/scripts/nowykontener.sh"
    fi
fi

log() {
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [HOOK-$PHASE] [CTID $CTID] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

case "$PHASE" in
    post-start)
        log "Kontener uruchomiony. Sprawdzanie stanu provisioningu..."
        
        # Check if already provisioned
        if pct exec "$CTID" -- test -f /etc/.lxc_provisioned 2>/dev/null; then
            log "Kontener $CTID jest już skonfigurowany (znaleziono /etc/.lxc_provisioned). Pomijanie."
            exit 0
        fi

        if [[ -f "$HASLA_FILE" ]] && grep -q "CTID: ${CTID} " "$HASLA_FILE" 2>/dev/null; then
            log "Kontener $CTID posiada już wpis w $HASLA_FILE. Pomijanie."
            exit 0
        fi

        if [[ ! -f "$NOWYKONTENER_SCRIPT" ]]; then
            log "BŁĄD: Nie znaleziono skryptu nowykontener.sh!"
            exit 0
        fi

        log "Uruchamianie asynchronicznego auto-provisioningu dla CTID $CTID..."
        
        # Run provisioning asynchronously in background to avoid blocking container startup
        (
            # Wait for container init system to mount /proc inside container
            for _ in {1..30}; do
                if pct exec "$CTID" -- test -d /proc/1 2>/dev/null; then
                    break
                fi
                sleep 2
            done
            sleep 3

            log "Rozpoczynanie konfiguracji wewnętrznej przez $NOWYKONTENER_SCRIPT..."
            if bash "$NOWYKONTENER_SCRIPT" "$CTID" >> "$LOG_FILE" 2>&1; then
                log "SUKCES: Auto-provisioning dla CTID $CTID zakończony pomyślnie."
            else
                log "BŁĄD: Auto-provisioning dla CTID $CTID nie powiódł się. Szczegóły w $LOG_FILE."
            fi
        ) &
        ;;
    pre-start|pre-stop|post-stop)
        # No action required for these phases
        ;;
    *)
        log "Nieznana faza: $PHASE"
        ;;
esac

exit 0
