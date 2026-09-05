#!/usr/bin/env bash
# ==============================================================================
# backup/pve-cluster-config-backup.sh
# Encrypted Lightweight Backup of Proxmox VE Cluster Metadata & Host Configurations
#
# Backs up the entire /etc/pve directory (LXC configs, VM configs, storage.cfg,
# corosync.conf, firewall rules, SDN, users) along with host networking, sysctl,
# and crontabs. The archive is symmetrically encrypted using AES-256-CBC (PBKDF2).
#
# Usage:
#   ./pve-cluster-config-backup.sh [OPTIONS]
#
# Options:
#   --backup              Run encrypted backup (Default)
#   --restore <file.enc>  Decrypt and extract an archive to /tmp/pve_restore/
#   --list                List existing configuration backups
#   -h, --help            Show this help message
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------------------
# 1. Environment & Configuration Loading
# ------------------------------------------------------------------------------
load_env() {
    local env_locations=(
        "${SCRIPT_DIR}/.env"
        "${SCRIPT_DIR}/../.env"
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

if [[ $EUID -ne 0 ]]; then
    echo "[-] Błąd: Ten skrypt musi być uruchomiony jako root na hoście Proxmox VE." >&2
    exit 1
fi

BACKUP_DIR="${PVE_CONFIG_BACKUP_DIR:-/var/backups/pve-cluster}"
KEEP_DAYS="${PVE_CONFIG_BACKUP_KEEP:-14}"
ENCRYPT_KEY="${PVE_CONFIG_BACKUP_KEY:-${PBS_PASSWORD:-}}"

if [[ -z "$ENCRYPT_KEY" ]]; then
    echo "[-] Błąd: Brak klucza szyfrowania (ustaw PVE_CONFIG_BACKUP_KEY lub PBS_PASSWORD w .env)!" >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# ------------------------------------------------------------------------------
# 2. Backup Execution
# ------------------------------------------------------------------------------
run_backup() {
    local node_name
    node_name=$(hostname)
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local temp_dir="/tmp/pve_backup_${node_name}_${timestamp}"
    local plain_tar="/tmp/pve_config_${node_name}_${timestamp}.tar.gz"
    local enc_file="${BACKUP_DIR}/pve_cluster_config_${node_name}_${timestamp}.tar.gz.enc"

    echo "[+] Tworzenie lekkiej kopii konfiguracji klastra dla: ${node_name}..."

    mkdir -p "$temp_dir"

    # 1. Copy /etc/pve metadata (if pmxcfs is mounted)
    if [[ -d "/etc/pve" ]]; then
        mkdir -p "${temp_dir}/etc_pve"
        # Avoid backing up virtual mounts, copy config files
        cp -a /etc/pve/*.cfg "${temp_dir}/etc_pve/" 2>/dev/null || true
        cp -a /etc/pve/*.conf "${temp_dir}/etc_pve/" 2>/dev/null || true
        cp -r /etc/pve/nodes "${temp_dir}/etc_pve/" 2>/dev/null || true
        cp -r /etc/pve/firewall "${temp_dir}/etc_pve/" 2>/dev/null || true
        cp -r /etc/pve/sdn "${temp_dir}/etc_pve/" 2>/dev/null || true
        cp -r /etc/pve/priv "${temp_dir}/etc_pve/" 2>/dev/null || true
        cp -r /etc/pve/secrets "${temp_dir}/etc_pve/" 2>/dev/null || true
        echo "[+] Skopiowano konfiguracje maszyn, kontenerów i klastra z /etc/pve."
    fi

    # 2. Copy Host Network & System Config
    mkdir -p "${temp_dir}/host_config"
    cp -a /etc/network/interfaces* "${temp_dir}/host_config/" 2>/dev/null || true
    cp -a /etc/hosts "${temp_dir}/host_config/" 2>/dev/null || true
    cp -a /etc/resolv.conf "${temp_dir}/host_config/" 2>/dev/null || true
    cp -a /etc/vzdump.conf "${temp_dir}/host_config/" 2>/dev/null || true
    cp -r /etc/sysctl.d "${temp_dir}/host_config/" 2>/dev/null || true
    cp -r /var/spool/cron "${temp_dir}/host_config/" 2>/dev/null || true

    # 3. Create TAR archive
    tar -czf "$plain_tar" -C "$temp_dir" .
    rm -rf "$temp_dir"

    # 4. Encrypt using OpenSSL AES-256-CBC (PBKDF2)
    echo "$ENCRYPT_KEY" | openssl enc -aes-256-cbc -pbkdf2 -salt -in "$plain_tar" -out "$enc_file" -pass stdin
    rm -f "$plain_tar"
    chmod 600 "$enc_file"

    local size_kb
    size_kb=$(du -k "$enc_file" | awk '{print $1}')
    echo "[+] Zaszyfrowana kopia konfiguracji klastra utworzona pomyślnie:"
    echo "    Plik: $enc_file (${size_kb} KB)"

    # 5. Rotate old backups
    echo "[+] Czyszczenie kopii starszych niż ${KEEP_DAYS} dni w ${BACKUP_DIR}..."
    find "$BACKUP_DIR" -name "pve_cluster_config_*.tar.gz.enc" -type f -mtime +"$KEEP_DAYS" -delete
    echo "[+] Gotowe."
}

# ------------------------------------------------------------------------------
# 3. Restore / Decrypt Execution
# ------------------------------------------------------------------------------
restore_backup() {
    local target_file="$1"
    if [[ ! -f "$target_file" ]]; then
        echo "[-] Błąd: Plik '$target_file' nie istnieje!" >&2
        exit 1
    fi

    local restore_dir="/tmp/pve_restore_$(date '+%s')"
    local plain_tar="/tmp/pve_restore_temp.tar.gz"

    echo "[+] Deszyfrowanie archiwum $target_file..."
    echo "$ENCRYPT_KEY" | openssl enc -d -aes-256-cbc -pbkdf2 -in "$target_file" -out "$plain_tar" -pass stdin || {
        echo "[-] Błąd deszyfrowania: niepoprawny klucz lub uszkodzony plik." >&2
        rm -f "$plain_tar"
        exit 1
    }

    mkdir -p "$restore_dir"
    tar -xzf "$plain_tar" -C "$restore_dir"
    rm -f "$plain_tar"

    echo "[+] Rozpakowano pomyślnie do: $restore_dir"
    echo "    Zawartość:"
    ls -la "$restore_dir"
}

# ------------------------------------------------------------------------------
# 4. List Backups
# ------------------------------------------------------------------------------
list_backups() {
    echo "========================================================================"
    echo "            ZASZYFROWANE KOPIE KONFIGURACJI KLASTRA PVE                 "
    echo "========================================================================"
    echo "Katalog: $BACKUP_DIR"
    echo ""
    ls -lh "$BACKUP_DIR"/*.tar.gz.enc 2>/dev/null || echo "Brak zapisanych kopii w katalogu."
    echo "========================================================================"
}

# ------------------------------------------------------------------------------
# 5. Main CLI Router
# ------------------------------------------------------------------------------
case "${1:-}" in
    --restore)
        shift
        restore_backup "${1:-}"
        ;;
    --list|-l)
        list_backups
        ;;
    --backup|-b|"")
        run_backup
        ;;
    -h|--help)
        echo "Użycie: $0 [--backup | --restore <plik.enc> | --list]"
        exit 0
        ;;
    *)
        echo "[-] Nieznana opcja: $1" >&2
        exit 1
        ;;
esac
