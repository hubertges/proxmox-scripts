#!/usr/bin/env bash
# ==============================================================================
# scripts/update_wazuh_agent_v5.sh
# Host wrapper for Wazuh Agent v5 upgrade suite
# Forwards arguments to the cluster script in /etc/pve/scripts/ or local repo
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "/etc/pve/scripts/update_wazuh_agent_v5.sh" ]]; then
    bash "/etc/pve/scripts/update_wazuh_agent_v5.sh" "$@"
elif [[ -f "${SCRIPT_DIR}/../provisioning/update_wazuh_agent_v5.sh" ]]; then
    bash "${SCRIPT_DIR}/../provisioning/update_wazuh_agent_v5.sh" "$@"
else
    echo "[!] Error: update_wazuh_agent_v5.sh not found in /etc/pve/scripts/ or ${SCRIPT_DIR}/../provisioning/" >&2
    exit 1
fi
