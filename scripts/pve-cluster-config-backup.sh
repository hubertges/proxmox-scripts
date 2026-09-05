#!/usr/bin/env bash
# ==============================================================================
# scripts/pve-cluster-config-backup.sh
# Host wrapper for cluster pve-cluster-config-backup.sh
# Forwards arguments to /etc/pve/scripts/ or local repo
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "/etc/pve/scripts/pve-cluster-config-backup.sh" ]]; then
    bash "/etc/pve/scripts/pve-cluster-config-backup.sh" "$@"
elif [[ -f "${SCRIPT_DIR}/../backup/pve-cluster-config-backup.sh" ]]; then
    bash "${SCRIPT_DIR}/../backup/pve-cluster-config-backup.sh" "$@"
else
    echo "[!] Error: pve-cluster-config-backup.sh not found in /etc/pve/scripts/ or ${SCRIPT_DIR}/../backup/" >&2
    exit 1
fi
