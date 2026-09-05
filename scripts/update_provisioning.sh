#!/usr/bin/env bash
# ==============================================================================
# scripts/update_provisioning.sh
# Host wrapper for cluster update_provisioning.sh suite
# Forwards arguments to /etc/pve/scripts/ or local repo
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "/etc/pve/scripts/update_provisioning.sh" ]]; then
    bash "/etc/pve/scripts/update_provisioning.sh" "$@"
elif [[ -f "${SCRIPT_DIR}/../provisioning/update_provisioning.sh" ]]; then
    bash "${SCRIPT_DIR}/../provisioning/update_provisioning.sh" "$@"
else
    echo "[!] Error: update_provisioning.sh not found in /etc/pve/scripts/ or ${SCRIPT_DIR}/../provisioning/" >&2
    exit 1
fi
