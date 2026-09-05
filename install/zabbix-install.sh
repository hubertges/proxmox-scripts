#!/usr/bin/env bash
# ==============================================================================
# install/zabbix-install.sh
# Compatibility wrapper pointing to install_zabbix.sh
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/install_zabbix.sh" "$@"
