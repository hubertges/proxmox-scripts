#!/usr/bin/env bash
# ==============================================================================
# scripts/create_golden_template.sh
# Host wrapper for cluster create_golden_template.sh
# Forwards arguments to /etc/pve/scripts/ or local repo
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "/etc/pve/scripts/create_golden_template.sh" ]]; then
    bash "/etc/pve/scripts/create_golden_template.sh" "$@"
elif [[ -f "${SCRIPT_DIR}/../provisioning/create_golden_template.sh" ]]; then
    bash "${SCRIPT_DIR}/../provisioning/create_golden_template.sh" "$@"
else
    echo "[!] Error: create_golden_template.sh not found in /etc/pve/scripts/ or ${SCRIPT_DIR}/../provisioning/" >&2
    exit 1
fi
