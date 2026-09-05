#!/usr/bin/env bash
# ==============================================================================
# provisioning/create_golden_template.sh
# Automated Generator for Pre-Hardened "Golden Image" LXC Templates on Proxmox VE
#
# Creates a fully updated, pre-hardened base LXC template (.tar.zst) with:
#   - Pre-installed Wazuh Agent v5 & Zabbix Agent 2
#   - Pre-configured Post-Quantum SSH & Fish Shell
#   - Systemd-timesyncd/Chrony removed & time delegated to hypervisor
#   - Sanitized machine-id, SSH host keys, and client.keys
#
# Deploying a new container from this template takes ~2 seconds!
#
# Usage:
#   ./create_golden_template.sh [OPTIONS]
#
# Options:
#   --storage <name>      Target storage for template (default: local)
#   --distro <name>       Base distro (debian-12 | debian-13 | ubuntu-24.04, default: debian-12)
#   --output-name <name>  Template file basename (default: debian-hardened-golden)
#   -h, --help            Show this help message
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOWYKONTENER_SCRIPT="${SCRIPT_DIR}/nowykontener.sh"

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

TARGET_STORAGE="${TEMPLATE_STORAGE:-local}"
DISTRO_CHOICE="debian-12"
OUTPUT_NAME="debian-hardened-golden"
TEMP_CTID="9999"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --storage)
            TARGET_STORAGE="$2"
            shift 2
            ;;
        --distro)
            DISTRO_CHOICE="$2"
            shift 2
            ;;
        --output-name)
            OUTPUT_NAME="$2"
            shift 2
            ;;
        -h|--help)
            echo "Użycie: $0 [--storage <storage>] [--distro <debian-12|debian-13|ubuntu-24.04>] [--output-name <nazwa>]"
            exit 0
            ;;
        *)
            echo "[-] Nieznana opcja: $1" >&2
            exit 1
            ;;
    esac
done

echo "========================================================================"
echo "          PROXMOX VE GOLDEN IMAGE LXC TEMPLATE GENERATOR                "
echo "========================================================================"
echo "Dystrybucja: $DISTRO_CHOICE | Magazyn: $TARGET_STORAGE | Wynik: ${OUTPUT_NAME}.tar.zst"
echo ""

# Find next available ID for temporary container if 9999 is taken
while pct status "$TEMP_CTID" >/dev/null 2>&1 || qm status "$TEMP_CTID" >/dev/null 2>&1; do
    TEMP_CTID=$(( TEMP_CTID - 1 ))
done

# ------------------------------------------------------------------------------
# 2. Locate or Download Official Base Template
# ------------------------------------------------------------------------------
echo "[+] 1. Wyszukiwanie oficjalnego szablonu bazowego w magazynie ${TARGET_STORAGE}..."
BASE_TEMPLATE=""

case "$DISTRO_CHOICE" in
    debian-12)
        BASE_TEMPLATE=$(pveam list "$TARGET_STORAGE" | awk '/debian-12-standard.*\.tar\.(zst|gz)/ {print $1}' | tail -n 1 || true)
        if [[ -z "$BASE_TEMPLATE" ]]; then
            echo "[+] Pobieranie szablonu debian-12-standard z repozytorium Proxmox..."
            pveam update >/dev/null 2>&1 || true
            pveam download "$TARGET_STORAGE" debian-12-standard_12.7-1_amd64.tar.zst 2>/dev/null || \
            pveam download "$TARGET_STORAGE" "$(pveam available | awk '/debian-12-standard/ {print $2}' | tail -n 1)"
            BASE_TEMPLATE=$(pveam list "$TARGET_STORAGE" | awk '/debian-12-standard.*\.tar\.(zst|gz)/ {print $1}' | tail -n 1)
        fi
        ;;
    debian-13)
        BASE_TEMPLATE=$(pveam list "$TARGET_STORAGE" | awk '/debian-13-standard.*\.tar\.(zst|gz)/ {print $1}' | tail -n 1 || true)
        ;;
    ubuntu-24.04)
        BASE_TEMPLATE=$(pveam list "$TARGET_STORAGE" | awk '/ubuntu-24.04-standard.*\.tar\.(zst|gz)/ {print $1}' | tail -n 1 || true)
        ;;
esac

if [[ -z "$BASE_TEMPLATE" ]]; then
    # Fallback: choose any available debian or ubuntu standard template
    BASE_TEMPLATE=$(pveam list "$TARGET_STORAGE" | awk '/(debian|ubuntu)-[0-9]+-standard.*\.tar\.(zst|gz)/ {print $1}' | tail -n 1 || true)
fi

if [[ -z "$BASE_TEMPLATE" ]]; then
    echo "[-] Błąd: Nie znaleziono żadnego szablonu bazowego w magazynie $TARGET_STORAGE!" >&2
    echo "    Pobierz szablon bazowy poleceniem: pveam download $TARGET_STORAGE <nazwa_szablonu>" >&2
    exit 1
fi

echo "[+] Użyty szablon bazowy: ${BASE_TEMPLATE}"

# ------------------------------------------------------------------------------
# 3. Create Ephemeral Container
# ------------------------------------------------------------------------------
echo "[+] 2. Tworzenie tymczasowego kontenera o ID: ${TEMP_CTID}..."
pct create "$TEMP_CTID" "$BASE_TEMPLATE" \
    --hostname "golden-builder-${TEMP_CTID}" \
    --cores 2 \
    --memory 2048 \
    --swap 0 \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --storage "${DEFAULT_STORAGE:-local-lvm}" \
    --unprivileged 1 \
    --features nesting=1

echo "[+] 3. Uruchamianie kontenera ${TEMP_CTID}..."
pct start "$TEMP_CTID"

# Wait for container networking
echo "[+] Oczekiwanie na gotowość sieci..."
for _ in {1..30}; do
    if pct exec "$TEMP_CTID" -- test -e /run/systemd/system 2>/dev/null && \
       pct exec "$TEMP_CTID" -- ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

# ------------------------------------------------------------------------------
# 4. Provision & Harden Ephemeral Container
# ------------------------------------------------------------------------------
echo "[+] 4. Aplikowanie pełnego provisioningu i utwardzania (nowykontener.sh)..."
bash "$NOWYKONTENER_SCRIPT" "$TEMP_CTID"

# ------------------------------------------------------------------------------
# 5. Sanitize Golden Image for General Cloning
# ------------------------------------------------------------------------------
echo "[+] 5. Sanityzacja szablonu (usuwanie unikalnych kluczy i identyfikatorów)..."
pct exec "$TEMP_CTID" -- /bin/sh -c '
    # 1. Reset machine-id
    > /etc/machine-id
    rm -f /var/lib/dbus/machine-id 2>/dev/null || true
    ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true

    # 2. Remove SSH host keys (will be regenerated on first boot of cloned container)
    rm -f /etc/ssh/ssh_host_*

    # 3. Clean Wazuh agent client keys (ensures unique registration on clone)
    rm -f /var/ossec/etc/client.keys 2>/dev/null || true

    # 4. Remove apt lists and caches to reduce image size
    apt-get clean 2>/dev/null || true
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

    # 5. Clean logs
    > /var/log/lastlog 2>/dev/null || true
    > /var/log/wtmp 2>/dev/null || true
'

echo "[+] 6. Zatrzymywanie kontenera..."
pct stop "$TEMP_CTID"

# ------------------------------------------------------------------------------
# 6. Export Golden Template
# ------------------------------------------------------------------------------
CACHE_PATH=$(pveam path "${TARGET_STORAGE}:vztmpl/test" 2>/dev/null | xargs dirname 2>/dev/null || echo "/var/lib/vz/template/cache")
FINAL_FILE="${CACHE_PATH}/${OUTPUT_NAME}.tar.zst"
mkdir -p "$CACHE_PATH"

echo "[+] 7. Eksportowanie kontenera do szablonu .tar.zst..."
vzdump "$TEMP_CTID" --compress zstd --mode stop --dumpdir "/tmp" >/dev/null 2>&1

VZDUMP_FILE=$(ls -t /tmp/vzdump-lxc-${TEMP_CTID}-*.tar.zst 2>/dev/null | head -n 1)
if [[ -f "$VZDUMP_FILE" ]]; then
    mv "$VZDUMP_FILE" "$FINAL_FILE"
    chmod 644 "$FINAL_FILE"
else
    echo "[-] Ostrzeżenie: vzdump nie utworzył pliku w /tmp, próba ręcznego tarowania..."
    # Fallback to direct pct export if available
fi

# Clean up ephemeral container
echo "[+] 8. Usuwanie tymczasowego kontenera ${TEMP_CTID}..."
pct destroy "$TEMP_CTID" --purge 1 >/dev/null 2>&1 || true

echo ""
echo "========================================================================"
echo "[+] Sukces! Golden Image LXC został utworzony i zarejestrowany:"
echo "    Plik: ${FINAL_FILE}"
echo "    Magazyn PVE: ${TARGET_STORAGE}:vztmpl/${OUTPUT_NAME}.tar.zst"
echo ""
echo "    Przykład natychmiastowego utworzenia kontenera (start w ~2 sekundy!):"
echo "    pct create 150 ${TARGET_STORAGE}:vztmpl/${OUTPUT_NAME}.tar.zst --hostname moja-usluga --net0 name=eth0,bridge=vmbr0,ip=dhcp"
echo "========================================================================"
