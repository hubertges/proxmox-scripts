#!/usr/bin/env bash
# ==============================================================================
# scripts/nowykontener.sh
# Host wrapper for LXC container provisioning script
# Forwards arguments to the cluster script in /etc/pve/scripts/ or local repo
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "/etc/pve/scripts/nowykontener.sh" ]]; then
    bash "/etc/pve/scripts/nowykontener.sh" "$@"
elif [[ -f "${SCRIPT_DIR}/../provisioning/nowykontener.sh" ]]; then
    bash "${SCRIPT_DIR}/../provisioning/nowykontener.sh" "$@"
else
    echo "[!] Error: nowykontener.sh not found in /etc/pve/scripts/ or ${SCRIPT_DIR}/../provisioning/" >&2
    exit 1
fi
