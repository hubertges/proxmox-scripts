#!/usr/bin/env bash
# ==============================================================================
# backup/pbs-host-backup-hook.sh
# Dynamic vzdump Hook Script: Automatic Bare-Metal Host Backup to PBS on Job Start
# ==============================================================================

set -euo pipefail

PHASE="${1:-}"
NODE_NAME="$(hostname)"

# Proxmox vzdump hook phases: job-start, job-end, job-abort, backup-start, etc.
if [[ "$PHASE" != "job-start" ]]; then
    exit 0
fi

# ------------------------------------------------------------------------------
# 1. Environment & Configuration Loading
# ------------------------------------------------------------------------------
load_env() {
    local env_locations=(
        "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env"
        "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
        "/etc/pve/scripts/.env"
        "/etc/pve/secrets/.env"
        "/etc/pve/.env"
        "$HOME/.env"
    )
    for env_file in "${env_locations[@]}"; do
        if [[ -f "$env_file" ]]; then
            # shellcheck source=/dev/null
            source "$env_file"
            break
        fi
    done
}
load_env

echo "====================================================================="
echo "Rozpoczynam backup hosta ${NODE_NAME} do PBS w ramach zadania vzdump"
echo "Data rozpoczęcia: $(date '+%Y-%m-%d %H:%M:%S')"
echo "====================================================================="

if ! command -v proxmox-backup-client >/dev/null 2>&1; then
    echo "[!] Ostrzeżenie: Brak zainstalowanego proxmox-backup-client. Pomijam backup hosta."
    exit 0
fi

if [[ -z "${PBS_REPOSITORY:-}" || -z "${PBS_PASSWORD:-}" ]]; then
    echo "[!] Ostrzeżenie: PBS_REPOSITORY lub PBS_PASSWORD nie są ustawione w .env! Pomijam backup hosta."
    exit 0
fi

export PBS_REPOSITORY
export PBS_PASSWORD
export PBS_FINGERPRINT="${PBS_FINGERPRINT:-}"

KEYFILE="${PBS_KEYFILE:-/etc/pve/priv/storage/mnemo-pbs.enc}"
NAMESPACE="${PBS_NAMESPACE:-BareMetal}"

BACKUP_ARGS=(
    backup
    root.pxar:/
    pve.pxar:/etc/pve
    --ns "$NAMESPACE"
)

if [[ -n "$KEYFILE" && -f "$KEYFILE" ]]; then
    BACKUP_ARGS+=(--crypt-mode encrypt --keyfile "$KEYFILE")
fi

EXCLUDES=(
    "/dev/**"
    "/sys/**"
    "/proc/**"
    "/run/**"
    "/var/run/**"
    "/tmp/**"
    "/var/tmp/**"
    "/var/lib/lxc/**"
    "/var/lib/vz/**"
    "/mnt/pve/**"
    "/OMEGA_PULOK/**"
    "/var/cache/**"
)

if [[ -n "${PBS_EXTRA_EXCLUDES:-}" ]]; then
    read -ra EXTRA_EX <<< "$PBS_EXTRA_EXCLUDES"
    EXCLUDES+=("${EXTRA_EX[@]}")
fi

for ex in "${EXCLUDES[@]}"; do
    BACKUP_ARGS+=(--exclude "$ex")
done

if proxmox-backup-client "${BACKUP_ARGS[@]}"; then
    echo "====================================================================="
    echo "SUKCES: Backup hosta ${NODE_NAME} do PBS zakończony pomyślnie."
    echo "====================================================================="
    exit 0
else
    echo "====================================================================="
    echo "BŁĄD: Backup hosta ${NODE_NAME} do PBS nie powiódł się!"
    echo "====================================================================="
    exit 1
fi
