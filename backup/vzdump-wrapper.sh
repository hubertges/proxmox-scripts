#!/usr/bin/env bash
# ==============================================================================
# backup/vzdump-wrapper.sh
# Vzdump Hook Wrapper Script
# Forwards all arguments ($@) to the central cluster hook script
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "/etc/pve/scripts/pbs-host-backup-hook.sh" ]]; then
    bash "/etc/pve/scripts/pbs-host-backup-hook.sh" "$@"
elif [[ -f "${SCRIPT_DIR}/pbs-host-backup-hook.sh" ]]; then
    bash "${SCRIPT_DIR}/pbs-host-backup-hook.sh" "$@"
else
    echo "[!] Error: pbs-host-backup-hook.sh not found in /etc/pve/scripts/ or ${SCRIPT_DIR}" >&2
    exit 1
fi
