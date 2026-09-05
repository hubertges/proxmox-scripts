#!/usr/bin/env bash
# ==============================================================================
# scripts/lxc-auto-provision-watcher.sh
# Host wrapper for LXC auto-provision watcher daemon
# Forwards arguments to the cluster script in /etc/pve/scripts/ or local repo
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "/etc/pve/scripts/lxc-auto-provision-watcher.sh" ]]; then
    bash "/etc/pve/scripts/lxc-auto-provision-watcher.sh" "$@"
elif [[ -f "${SCRIPT_DIR}/../provisioning/lxc-auto-provision-watcher.sh" ]]; then
    bash "${SCRIPT_DIR}/../provisioning/lxc-auto-provision-watcher.sh" "$@"
else
    echo "[!] Error: lxc-auto-provision-watcher.sh not found in /etc/pve/scripts/ or ${SCRIPT_DIR}/../provisioning/" >&2
    exit 1
fi
