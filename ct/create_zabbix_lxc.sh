#!/usr/bin/env bash
# ==============================================================================
# ct/create_zabbix_lxc.sh
# Forwarding launcher to Proxmox VE Helper Scripts native ct/zabbix.sh
# ==============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/zabbix.sh" "$@"

