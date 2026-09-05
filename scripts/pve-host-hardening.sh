#!/usr/bin/env bash
# ==============================================================================
# scripts/pve-host-hardening.sh
# Host wrapper for cluster pve-host-hardening.sh
# Forwards arguments to /etc/pve/scripts/ or local repo
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "/etc/pve/scripts/pve-host-hardening.sh" ]]; then
    bash "/etc/pve/scripts/pve-host-hardening.sh" "$@"
elif [[ -f "${SCRIPT_DIR}/../system-config/pve-host-hardening.sh" ]]; then
    bash "${SCRIPT_DIR}/../system-config/pve-host-hardening.sh" "$@"
else
    echo "[!] Error: pve-host-hardening.sh not found in /etc/pve/scripts/ or ${SCRIPT_DIR}/../system-config/" >&2
    exit 1
fi
