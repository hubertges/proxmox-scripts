#!/usr/bin/env bash
# ==============================================================================
# provisioning/autoinstall.sh
# Batch LXC Container Provisioning & Security Hardening on Proxmox VE
# Usage: ./autoinstall.sh [CTID1 CTID2 ...]
# If no arguments are passed, it scans and processes all unconfigured running containers.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

HASLA_FILE="${HASLA_FILE:-/etc/pve/secrets/.hasla}"
LXC_USER="${LXC_DEFAULT_USER:-hubi}"

# ------------------------------------------------------------------------------
# 2. Determine Containers to Process
# ------------------------------------------------------------------------------
if [[ $# -gt 0 ]]; then
    CTIDS=("$@")
    echo "[+] Tryb ręczny - wybrano kontenery do przetworzenia: ${CTIDS[*]}"
else
    mapfile -t CTIDS < <(pct list 2>/dev/null | awk "NR>1 {print \$1}")
    echo "[+] Tryb automatyczny - skanowanie wszystkich kontenerów w klastrze..."
fi

if [[ ${#CTIDS[@]} -eq 0 ]]; then
    echo "[-] Brak kontenerów do przetworzenia."
    exit 0
fi

# ------------------------------------------------------------------------------
# 3. Optional Single Password Prompt for Batch Mode
# ------------------------------------------------------------------------------
if [[ -z "${LXC_USER_PASSWORD:-}" ]]; then
    echo -n "[?] Podaj wspólne hasło dla użytkownika '$LXC_USER' (pozostaw puste, aby pytać dla każdego kontenera): "
    read -s BATCH_PASS
    echo ""
    if [[ -n "$BATCH_PASS" ]]; then
        export LXC_USER_PASSWORD="$BATCH_PASS"
    fi
fi

# ------------------------------------------------------------------------------
# 4. Iterate Over Containers
# ------------------------------------------------------------------------------
for CTID in "${CTIDS[@]}"; do
    STATUS=$(pct status "$CTID" 2>/dev/null | awk "{print \$2}" || true)

    if [[ -z "$STATUS" ]]; then
        echo "[-] Kontener $CTID nie istnieje. Pomijanie..."
        echo ""
        continue
    fi

    if [[ "$STATUS" != "running" ]]; then
        echo "[-] Kontener $CTID jest wyłączony (status: $STATUS). Pomijanie..."
        echo ""
        continue
    fi

    # Check if already processed
    if pct exec "$CTID" -- test -f /etc/.lxc_provisioned 2>/dev/null; then
        echo "[!] Kontener $CTID posiada już znacznik konfiguracji (/etc/.lxc_provisioned). Pomijanie..."
        echo ""
        continue
    fi

    if [[ -f "$HASLA_FILE" ]] && grep -q "CTID: $CTID " "$HASLA_FILE"; then
        echo "[!] Kontener $CTID figuruje już w bazie haseł ($HASLA_FILE). Pomijanie..."
        echo ""
        continue
    fi

    # Execute provisioning
    bash "${SCRIPT_DIR}/nowykontener.sh" "$CTID" || {
        echo "[-] Błąd podczas konfiguracji kontenera $CTID. Przechodzę do następnego..."
    }
done

echo "[+] Wszystkie wybrane kontenery zostały przetworzone."
