#!/usr/bin/env bash
# ==============================================================================
# backup/pbs-host-backup.sh
# Automated Proxmox VE Host Bare-Metal Backup to Proxmox Backup Server (PBS)
# ==============================================================================

set -euo pipefail

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

# ------------------------------------------------------------------------------
# 2. Validation & Parameter Setup
# ------------------------------------------------------------------------------
if ! command -v proxmox-backup-client >/dev/null 2>&1; then
    echo "[!] Error: proxmox-backup-client is not installed on this system." >&2
    exit 1
fi

if [[ -z "${PBS_REPOSITORY:-}" ]]; then
    echo "[!] Error: PBS_REPOSITORY is not set. Please define it in your .env file." >&2
    exit 1
fi

if [[ -z "${PBS_PASSWORD:-}" ]]; then
    echo "[!] Error: PBS_PASSWORD is not set. Please define it in your .env file." >&2
    exit 1
fi

export PBS_REPOSITORY
export PBS_PASSWORD
export PBS_FINGERPRINT="${PBS_FINGERPRINT:-}"

NODE_NAME="${PBS_NODE_NAME:-$(hostname)}"
LOG_FILE="${PBS_LOG_FILE:-/var/log/proxmox_host_backup.log}"
KEYFILE="${PBS_KEYFILE:-/etc/pve/priv/storage/mnemo-pbs.enc}"
NAMESPACE="${PBS_NAMESPACE:-BareMetal}"
DATE=$(date "+%Y-%m-%d %H:%M:%S")

mkdir -p "$(dirname "$LOG_FILE")"

echo "[$DATE] Rozpoczynam backup hosta ${NODE_NAME} do PBS [${PBS_REPOSITORY}]..." | tee -a "$LOG_FILE"

# ------------------------------------------------------------------------------
# 3. Build Backup Arguments & Exclude Rules
# ------------------------------------------------------------------------------
BACKUP_ARGS=(
    backup
    root.pxar:/
    pve.pxar:/etc/pve
    --ns "$NAMESPACE"
)

if [[ -n "$KEYFILE" && -f "$KEYFILE" ]]; then
    BACKUP_ARGS+=(--crypt-mode encrypt --keyfile "$KEYFILE")
elif [[ -n "$KEYFILE" ]]; then
    echo "[$DATE] OSTRZEŻENIE: Wskazany klucz szyfrowania ($KEYFILE) nie istnieje. Pomijam szyfrowanie." | tee -a "$LOG_FILE"
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

# Allow custom additional excludes via .env (space-separated)
if [[ -n "${PBS_EXTRA_EXCLUDES:-}" ]]; then
    read -ra EXTRA_EX <<< "$PBS_EXTRA_EXCLUDES"
    EXCLUDES+=("${EXTRA_EX[@]}")
fi

for ex in "${EXCLUDES[@]}"; do
    BACKUP_ARGS+=(--exclude "$ex")
done

# ------------------------------------------------------------------------------
# 4. Execute Backup Operation
# ------------------------------------------------------------------------------
if proxmox-backup-client "${BACKUP_ARGS[@]}" >> "$LOG_FILE" 2>&1; then
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] Backup hosta ${NODE_NAME} zakończony sukcesem." | tee -a "$LOG_FILE"
    exit 0
else
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] BŁĄD: Backup hosta ${NODE_NAME} nie powiódł się. Sprawdź logi w: $LOG_FILE" | tee -a "$LOG_FILE"
    exit 1
fi
