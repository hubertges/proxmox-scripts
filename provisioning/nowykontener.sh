#!/usr/bin/env bash
# ==============================================================================
# provisioning/nowykontener.sh
# Automated LXC Container Post-Creation Provisioning & Security Hardening
# Target Hypervisor: Proxmox VE 8.x / 9.x (run as root on PVE host)
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

# Check privileges
if [[ $EUID -ne 0 ]]; then
    echo "[-] Błąd: Uruchom skrypt jako root na hoście Proxmox VE." >&2
    exit 1
fi

CTID="${1:-}"
if [[ -z "$CTID" ]]; then
    echo "[-] Błąd: Podaj ID kontenera (CTID)." >&2
    echo "    Użycie: $0 <CTID>" >&2
    exit 1
fi

# Configuration Variables with .env fallback
HASLA_FILE="${HASLA_FILE:-/etc/pve/secrets/.hasla}"
LXC_USER="${LXC_DEFAULT_USER:-hubi}"
SEARCH_DOMAIN="${SEARCH_DOMAIN:-slurp.intra}"
SSH_PUBKEY="${SSH_PUBKEY_PATH:-/root/.ssh/authorized_keys}"
CHRONY_CONF="${CHRONY_CONF_PATH:-/etc/chrony/chrony.conf}"
WAZUH_MGR="${WAZUH_MANAGER:-wazuh.slurp.pl}"
WAZUH_GRP="${WAZUH_AGENT_GROUP:-linux-servers}"
WAZUH_VER="${WAZUH_AGENT_VERSION:-4.14.7-1}"

mkdir -p "$(dirname "$HASLA_FILE")"

# ------------------------------------------------------------------------------
# 2. OS Verification Inside Container
# ------------------------------------------------------------------------------
echo "=========================================================="
echo "[+] Weryfikacja kontenera: $CTID"
echo "=========================================================="

STATUS=$(pct status "$CTID" 2>/dev/null | awk "{print \$2}")
if [[ "$STATUS" != "running" ]]; then
    echo "[-] Błąd: Kontener $CTID nie jest uruchomiony (status: ${STATUS:-nieznany})." >&2
    exit 1
fi

CT_ID=$(pct exec "$CTID" -- bash -c ' . /etc/os-release 2>/dev/null && echo "${ID:-unknown}" ')
CT_CODENAME=$(pct exec "$CTID" -- bash -c ' . /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-unknown}" ')
if [[ "$CT_CODENAME" == "unknown" ]]; then
    CT_CODENAME=$(pct exec "$CTID" -- bash -c ' lsb_release -cs 2>/dev/null || echo "unknown" ')
fi

OS_SUPPORTED=0
case "$CT_ID" in
    ubuntu)
        OS_SUPPORTED=1
        ;;
    debian)
        if [[ "$CT_CODENAME" == "trixie" || "$CT_CODENAME" == "bookworm" || "$CT_CODENAME" == "sid" ]]; then
            OS_SUPPORTED=1
        fi
        ;;
    turnkey)
        OS_SUPPORTED=1
        ;;
esac

if [[ $OS_SUPPORTED -eq 0 ]]; then
    echo "[-] Błąd: Nieobsługiwany system operacyjny w kontenerze $CTID." >&2
    echo "    Wykryto: $CT_ID (codename: $CT_CODENAME). Oczekiwano Ubuntu, Debian (bookworm/trixie) lub TurnKey." >&2
    exit 1
fi

echo "[+] Wykryto obsługiwany system: $CT_ID ($CT_CODENAME)"

# ------------------------------------------------------------------------------
# 3. User Password Configuration
# ------------------------------------------------------------------------------
TARGET_USER_PASS="${LXC_USER_PASSWORD:-}"
if [[ -z "$TARGET_USER_PASS" ]]; then
    echo -n "[?] Podaj hasło dla użytkownika '$LXC_USER' (dla kontenera $CTID): "
    read -s TARGET_USER_PASS
    echo ""
fi

if [[ -z "$TARGET_USER_PASS" ]]; then
    echo "[-] Błąd: Hasło użytkownika nie może być puste." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 4. Root Password Generation & Storage
# ------------------------------------------------------------------------------
ROOT_PASS=$(openssl rand -base64 16)
echo "CTID: $CTID | User: $LXC_USER | Root Pass: $ROOT_PASS | Data: $(date)" >> "$HASLA_FILE"
chmod 600 "$HASLA_FILE" 2>/dev/null || true
echo "[+] Wygenerowano losowe hasło roota. Zapisano w $HASLA_FILE na hoście Proxmox."

echo "root:$ROOT_PASS" | pct exec "$CTID" -- chpasswd
echo "[+] Hasło roota w kontenerze zostało zaktualizowane."

# ------------------------------------------------------------------------------
# 5. Build Container Payload Script
# ------------------------------------------------------------------------------
PAYLOAD="/tmp/lxc_setup_payload_${CTID}.sh"

cat << INNER_EOF > "$PAYLOAD"
#!/usr/bin/env bash
export DEBIAN_FRONTEND=noninteractive
ERR_LOG="/tmp/ct_setup_errors.log"
> "\$ERR_LOG"

log_err() {
    local step="\$1"
    local log_file="\$2"
    echo "--> [BŁĄD] \$step" >> "\$ERR_LOG"
    if [[ -n "\$log_file" && -f "\$log_file" ]]; then
        echo "    Szczegóły:" >> "\$ERR_LOG"
        tail -n 15 "\$log_file" | sed "s/^/    /" >> "\$ERR_LOG"
    fi
}

OS_ID=\$(. /etc/os-release 2>/dev/null && echo "\${ID:-unknown}")
OS_CODENAME=\$(. /etc/os-release 2>/dev/null && echo "\${VERSION_CODENAME:-unknown}")
if [[ "\$OS_CODENAME" == "unknown" ]]; then
    OS_CODENAME=\$(lsb_release -cs 2>/dev/null || echo "bookworm")
fi

echo "[CT] 1. Instalacja podstawowych narzędzi administracyjnych..."
apt-get update -y
apt-get install -y ca-certificates curl wget gnupg lsb-release apt-transport-https debian-archive-keyring \
                   pv fish fortunes-pl cowsay chrony sudo \
                   unattended-upgrades apt-listchanges ufw fail2ban libpam-tmpdir needrestart debsums rkhunter

apt-get install -y fastfetch || echo "[CT] Pakiet fastfetch niedostępny w bieżącym repozytorium (pomijam)."

echo "[CT] 2. Modernizacja źródeł APT..."
if [[ "\$OS_ID" == "debian" ]]; then
    if [[ -f /etc/apt/sources.list ]]; then
        mv /etc/apt/sources.list /etc/apt/sources.list.bak
    fi

    if [[ ! -f /etc/apt/sources.list.d/debian.sources ]]; then
        add_apt_source() {
            local line="\$1"
            local file="\$2"
            if ! grep -Fq "\$line" "\$file" 2>/dev/null; then
                echo "\$line" >> "\$file"
            fi
        }
        touch /etc/apt/sources.list.d/debian.list
        add_apt_source "deb http://deb.debian.org/debian \$OS_CODENAME main contrib non-free non-free-firmware" /etc/apt/sources.list.d/debian.list
        add_apt_source "deb http://deb.debian.org/debian \${OS_CODENAME}-updates main contrib non-free non-free-firmware" /etc/apt/sources.list.d/debian.list
        add_apt_source "deb http://security.debian.org/debian-security \${OS_CODENAME}-security main contrib non-free non-free-firmware" /etc/apt/sources.list.d/debian.list
    fi
else
    echo "[CT] System \$OS_ID (\$OS_CODENAME) używa własnych repozytoriów. Pomijam modyfikację sources.list."
fi

apt-get update -y && apt-get upgrade -y && apt-get autoremove -y

echo "[CT] 3. Konfiguracja automatycznych aktualizacji (unattended-upgrades)..."
if [[ "\$OS_ID" == "ubuntu" ]]; then
    cat << APTCONF > /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Origins-Pattern {
    "origin=Ubuntu,archive=\${OS_CODENAME}-security";
    "origin=Ubuntu,archive=\${OS_CODENAME}-updates";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
APTCONF
else
    cat << APTCONF > /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=\${OS_CODENAME}-security,label=Debian-Security";
    "origin=Debian,codename=\${OS_CODENAME}-updates";
    "origin=TurnKey GNU/Linux,codename=\${OS_CODENAME}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
APTCONF
fi

cat << 'APTCONF2' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
APTCONF2

echo "[CT] 4. Konfiguracja użytkownika ${LXC_USER}..."
if ! id -u "${LXC_USER}" >/dev/null 2>&1; then
    useradd -m -s /usr/bin/fish -G sudo,adm "${LXC_USER}"
fi
mkdir -p "/home/${LXC_USER}/.ssh"
mkdir -p "/home/${LXC_USER}/.config/fish"

echo "[CT] Usuwanie domyślnych kluczy roota..."
rm -rf /root/.ssh/* 2>/dev/null || true

echo "[CT] Konfiguracja powłoki Fish..."
cat << 'FISHCONF' > "/home/${LXC_USER}/.config/fish/config.fish"
if status is-interactive
    if command -v fastfetch >/dev/null
        fastfetch
        echo ""
    end
    if command -v fortunes >/dev/null && command -v cowsay >/dev/null
        /usr/games/fortune | /usr/games/cowsay -f (ls /usr/share/cowsay/cows/ | shuf -n 1)
    end
end
FISHCONF

chown -R "${LXC_USER}:${LXC_USER}" "/home/${LXC_USER}/.config"

echo "[CT] 5. Utwardzanie SSH (blokada roota i haseł, post-quantum KEX)..."
if [[ -f /etc/ssh/sshd_config ]]; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    
    if ! grep -q "KexAlgorithms" /etc/ssh/sshd_config; then
        echo "KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org" >> /etc/ssh/sshd_config
    fi
    if ! grep -q "PubkeyAcceptedAlgorithms" /etc/ssh/sshd_config; then
        echo "PubkeyAcceptedAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com" >> /etc/ssh/sshd_config
    fi
fi

echo "[CT] 6. Konfiguracja Chrony dla LXC (-x flag)..."
if grep -q "^DAEMON_OPTS=" /etc/default/chrony 2>/dev/null; then
    sed -i 's/^DAEMON_OPTS=.*/DAEMON_OPTS="-x"/' /etc/default/chrony
else
    echo 'DAEMON_OPTS="-x"' >> /etc/default/chrony
fi

echo "[CT] 7. Instalacja Wazuh-Agent (${WAZUH_VER}) podłączanego do ${WAZUH_MGR}..."
cd /tmp
WAZUH_DEB="wazuh-agent_${WAZUH_VER}_amd64.deb"
curl -sL "https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/\${WAZUH_DEB}" -o "./\${WAZUH_DEB}"

if [[ -f "./\${WAZUH_DEB}" ]]; then
    WAZUH_MANAGER="${WAZUH_MGR}" WAZUH_AGENT_GROUP="${WAZUH_GRP}" dpkg -i "./\${WAZUH_DEB}" > /tmp/wazuh_install.log 2>&1 || log_err "Instalacja pakietu Wazuh (dpkg)" "/tmp/wazuh_install.log"
    systemctl daemon-reload
    systemctl enable wazuh-agent || log_err "Włączanie usługi wazuh-agent" ""
    systemctl start wazuh-agent || log_err "Startowanie usługi wazuh-agent" ""
else
    log_err "Pobieranie paczki wazuh-agent (brak pliku)" ""
fi
rm -f "./\${WAZUH_DEB}"
apt-get clean
INNER_EOF

# ------------------------------------------------------------------------------
# 6. Execute Payload Inside Container
# ------------------------------------------------------------------------------
echo "[+] Przesyłanie skryptu konfiguracyjnego do kontenera..."
pct push "$CTID" "$PAYLOAD" "/tmp/setup.sh"
pct exec "$CTID" -- chmod +x "/tmp/setup.sh"

echo "[+] Uruchamianie konfiguracji wewnątrz kontenera (APT, pakiety, SSH, Wazuh)..."
pct exec "$CTID" -- bash -c "/tmp/setup.sh && echo "${LXC_USER}:${TARGET_USER_PASS}" | chpasswd"

# ------------------------------------------------------------------------------
# 7. Host Integration: SSH Keys, Chrony & Network Domain
# ------------------------------------------------------------------------------
echo "[+] Kopiowanie autoryzowanych kluczy SSH z hosta do użytkownika ${LXC_USER}..."
if [[ -f "$SSH_PUBKEY" ]]; then
    pct push "$CTID" "$SSH_PUBKEY" "/home/${LXC_USER}/.ssh/authorized_keys"
    pct exec "$CTID" -- chown -R "${LXC_USER}:${LXC_USER}" "/home/${LXC_USER}/.ssh"
    pct exec "$CTID" -- chmod 700 "/home/${LXC_USER}/.ssh"
    pct exec "$CTID" -- chmod 600 "/home/${LXC_USER}/.ssh/authorized_keys"
else
    echo "[-] Ostrzeżenie: Plik kluczy $SSH_PUBKEY nie istnieje na hoście Proxmox!"
fi

if [[ -f "$CHRONY_CONF" ]]; then
    echo "[+] Kopiowanie konfiguracji chrony.conf z hosta..."
    pct push "$CTID" "$CHRONY_CONF" "/etc/chrony/chrony.conf"
    pct exec "$CTID" -- systemctl restart chrony || true
fi

if [[ -n "$SEARCH_DOMAIN" ]]; then
    echo "[+] Ustawianie domeny wyszukiwania DNS na: ${SEARCH_DOMAIN}..."
    pct set "$CTID" -searchdomain "$SEARCH_DOMAIN"
fi

# Restarts & Cleanup
echo "[+] Restartowanie usług sieciowych i czyszczenie..."
pct exec "$CTID" -- systemctl restart ssh 2>/dev/null || pct exec "$CTID" -- systemctl restart sshd 2>/dev/null || true
pct exec "$CTID" -- rm -f "/tmp/setup.sh"
rm -f "$PAYLOAD"

echo "=========================================================="
echo "[+] Kontener $CTID został pomyślnie skonfigurowany!"
echo "    Użytkownik: ${LXC_USER} (logowanie przez klucze SSH)"
echo "=========================================================="

if pct exec "$CTID" -- [ -s "/tmp/ct_setup_errors.log" ]; then
    echo "##########################################################"
    echo "# UWAGA: WYKRYTO BŁĘDY W TRAKCIE KONFIGURACJI KONTENERA  #"
    echo "##########################################################"
    pct exec "$CTID" -- cat "/tmp/ct_setup_errors.log"
    echo "##########################################################"
else
    echo "[+] Skrypt wewnętrzny zakończył się sukcesem (brak błędów)."
fi
echo ""
