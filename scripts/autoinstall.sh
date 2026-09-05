#!/usr/bin/env bash
# ==============================================================================
# scripts/autoinstall.sh
# Host Wrapper for Cluster autoinstall.sh
# Forwards all arguments ($@) to the central cluster script in /etc/pve/scripts/
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "/etc/pve/scripts/autoinstall.sh" ]]; then
    bash "/etc/pve/scripts/autoinstall.sh" "$@"
elif [[ -f "${SCRIPT_DIR}/../provisioning/autoinstall.sh" ]]; then
    bash "${SCRIPT_DIR}/../provisioning/autoinstall.sh" "$@"
else
    echo "[!] Błąd: Nie znaleziono autoinstall.sh w /etc/pve/scripts/ ani w repozytorium!" >&2
    exit 1
fi
