#!/usr/bin/env bash
# ==============================================================================
# provisioning/nowykontener.sh
# Universal Multi-Distro LXC Container Provisioning & Security Hardening
# Target Hypervisor: Proxmox VE 8.x / 9.x (run as root on PVE host)
#
# Supported Distro Families:
#   - Debian / Ubuntu / TurnKey / Mint / Kali / Parrot / Pop!_OS
#   - RHEL / Fedora / CentOS Stream / Rocky Linux / AlmaLinux / Oracle Linux
#   - openSUSE (Leap & Tumbleweed) / SLES
#   - Arch Linux / Manjaro
#   - Alpine Linux
#   - Generic Linux (fallback)
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
WAZUH_MGR="${WAZUH_MANAGER:-wazuh.slurp.pl}"
WAZUH_GRP="${WAZUH_AGENT_GROUP:-linux-servers}"
WAZUH_VER="${WAZUH_AGENT_V5_VERSION:-5.0.0-beta5}"
BASE_V5_URL="https://packages-staging.xdrsiem.wazuh.info/pre-release/5.x"
CACHE_DIR="/tmp/wazuh5_agent_cache"
mkdir -p "$CACHE_DIR" 2>/dev/null || true
mkdir -p "$(dirname "$HASLA_FILE")"

# ------------------------------------------------------------------------------
# 2. Multi-Distro OS Inspection Inside Container
# ------------------------------------------------------------------------------
echo "=========================================================="
echo "[+] Weryfikacja kontenera: $CTID"
echo "=========================================================="

STATUS=$(pct status "$CTID" 2>/dev/null | awk '{print $2}' || echo "stopped")
if [[ "$STATUS" != "running" ]]; then
    echo "[-] Błąd: Kontener $CTID nie jest uruchomiony (status: ${STATUS})." >&2
    exit 1
fi

# Query OS info safely via /bin/sh inside container
OS_INFO=$(pct exec "$CTID" -- /bin/sh -c '
    if [ -f /etc/os-release ]; then
        . /etc/os-release
    elif [ -f /usr/lib/os-release ]; then
        . /usr/lib/os-release
    fi
    echo "ID=${ID:-unknown}"
    echo "ID_LIKE=${ID_LIKE:-}"
    echo "VERSION_ID=${VERSION_ID:-}"
    echo "VERSION_CODENAME=${VERSION_CODENAME:-}"
    echo "PRETTY_NAME=${PRETTY_NAME:-Linux}"
' 2>/dev/null || echo "ID=unknown")

CT_ID=$(echo "$OS_INFO" | grep "^ID=" | head -n 1 | cut -d= -f2- | tr -d '"\r' || echo "unknown")
CT_ID_LIKE=$(echo "$OS_INFO" | grep "^ID_LIKE=" | head -n 1 | cut -d= -f2- | tr -d '"\r' || echo "")
CT_CODENAME=$(echo "$OS_INFO" | grep "^VERSION_CODENAME=" | head -n 1 | cut -d= -f2- | tr -d '"\r' || echo "")
CT_PRETTY_NAME=$(echo "$OS_INFO" | grep "^PRETTY_NAME=" | head -n 1 | cut -d= -f2- | tr -d '"\r' || echo "Linux")

# Detect init system
CT_INIT="generic"
if pct exec "$CTID" -- test -d /run/systemd/system 2>/dev/null; then
    CT_INIT="systemd"
elif pct exec "$CTID" -- test -d /run/openrc 2>/dev/null || pct exec "$CTID" -- test -f /sbin/openrc-run 2>/dev/null; then
    CT_INIT="openrc"
fi

# Classify Distro Family & Package Type
CT_FAMILY="generic"
PKG_FORMAT="generic"

case "$CT_ID" in
    debian|ubuntu|turnkey|linuxmint|pop|elementary|zorin|kali|parrot|raspbian|devuan)
        CT_FAMILY="debian"
        PKG_FORMAT="deb"
        ;;
    rhel|centos|rocky|almalinux|fedora|ol|amzn)
        CT_FAMILY="rhel"
        PKG_FORMAT="rpm"
        ;;
    opensuse*|sles*|sled*)
        CT_FAMILY="suse"
        PKG_FORMAT="rpm"
        ;;
    arch|archlinux|manjaro|endeavouros|artix|garuda)
        CT_FAMILY="arch"
        PKG_FORMAT="pacman"
        ;;
    alpine)
        CT_FAMILY="alpine"
        PKG_FORMAT="apk"
        ;;
    *)
        if [[ "$CT_ID_LIKE" =~ debian|ubuntu ]]; then
            CT_FAMILY="debian"
            PKG_FORMAT="deb"
        elif [[ "$CT_ID_LIKE" =~ rhel|fedora|centos ]]; then
            CT_FAMILY="rhel"
            PKG_FORMAT="rpm"
        elif [[ "$CT_ID_LIKE" =~ suse ]]; then
            CT_FAMILY="suse"
            PKG_FORMAT="rpm"
        elif [[ "$CT_ID_LIKE" =~ arch ]]; then
            CT_FAMILY="arch"
            PKG_FORMAT="pacman"
        elif [[ "$CT_ID_LIKE" =~ alpine ]]; then
            CT_FAMILY="alpine"
            PKG_FORMAT="apk"
        else
            if pct exec "$CTID" -- command -v dpkg >/dev/null 2>&1; then
                CT_FAMILY="debian"
                PKG_FORMAT="deb"
            elif pct exec "$CTID" -- command -v rpm >/dev/null 2>&1; then
                CT_FAMILY="rhel"
                PKG_FORMAT="rpm"
            elif pct exec "$CTID" -- command -v pacman >/dev/null 2>&1; then
                CT_FAMILY="arch"
                PKG_FORMAT="pacman"
            elif pct exec "$CTID" -- command -v apk >/dev/null 2>&1; then
                CT_FAMILY="alpine"
                PKG_FORMAT="apk"
            elif pct exec "$CTID" -- command -v zypper >/dev/null 2>&1; then
                CT_FAMILY="suse"
                PKG_FORMAT="rpm"
            fi
        fi
        ;;
esac

echo "[+] Wykryto system: ${CT_PRETTY_NAME}"
echo "    ID: ${CT_ID} | Rodzina: ${CT_FAMILY} | Pakiety: ${PKG_FORMAT} | Init: ${CT_INIT}"

# ------------------------------------------------------------------------------
# 3. User Password Configuration (Interactive or Automated)
# ------------------------------------------------------------------------------
TARGET_USER_PASS="${LXC_USER_PASSWORD:-}"
if [[ -z "$TARGET_USER_PASS" ]]; then
    if [[ -t 0 ]]; then
        echo -n "[?] Podaj hasło dla użytkownika '$LXC_USER' (dla kontenera $CTID): "
        read -s TARGET_USER_PASS
        echo ""
    else
        # Non-interactive mode (e.g. from watcher daemon)
        TARGET_USER_PASS=$(openssl rand -base64 12)
        echo "[+] Tryb nieinteraktywny: wygenerowano losowe hasło dla użytkownika '$LXC_USER'."
    fi
fi

if [[ -z "$TARGET_USER_PASS" ]]; then
    TARGET_USER_PASS=$(openssl rand -base64 12)
fi

# ------------------------------------------------------------------------------
# 4. Root Password Generation & Storage
# ------------------------------------------------------------------------------
ROOT_PASS=$(openssl rand -base64 16)
echo "CTID: $CTID | Distro: $CT_ID | User: $LXC_USER (Pass: $TARGET_USER_PASS) | Root Pass: $ROOT_PASS | Data: $(date)" >> "$HASLA_FILE"
chmod 600 "$HASLA_FILE" 2>/dev/null || true
echo "[+] Wygenerowano hasła dla kontenera $CTID. Zapisano w $HASLA_FILE."

# Update root password inside container
pct exec "$CTID" -- /bin/sh -c "echo 'root:$ROOT_PASS' | chpasswd 2>/dev/null || (command -v passwd >/dev/null && echo -e '$ROOT_PASS\n$ROOT_PASS' | passwd root 2>/dev/null) || true"
echo "[+] Hasło roota w kontenerze zostało zaktualizowane."

# ------------------------------------------------------------------------------
# 5. Prepare Wazuh Agent v5 Package on Host (DEB or RPM)
# ------------------------------------------------------------------------------
CT_ARCH=$(pct exec "$CTID" -- uname -m 2>/dev/null || echo "x86_64")

if [[ "$PKG_FORMAT" == "deb" ]]; then
    WAZUH_DEB_NAME="wazuh-agent_${WAZUH_VER}_amd64.deb"
    [[ "$CT_ARCH" == "aarch64" || "$CT_ARCH" == "arm64" ]] && WAZUH_DEB_NAME="wazuh-agent_${WAZUH_VER}_arm64.deb"
    WAZUH_URL="${BASE_V5_URL}/apt/pool/main/w/wazuh-agent/${WAZUH_DEB_NAME}"
    HOST_PKG_CACHE="${CACHE_DIR}/${WAZUH_DEB_NAME}"

    if [[ ! -f "$HOST_PKG_CACHE" ]]; then
        echo "[+] Pobieranie pakietu Wazuh Agent v5 (${WAZUH_DEB_NAME}) do pamięci podręcznej..."
        curl -fsSL "$WAZUH_URL" -o "$HOST_PKG_CACHE" || {
            echo "[-] Błąd pobierania pakietu Wazuh v5 z $WAZUH_URL" >&2
            rm -f "$HOST_PKG_CACHE"
        }
    fi

    if [[ -f "$HOST_PKG_CACHE" ]]; then
        echo "[+] Przesyłanie pakietu Wazuh Agent v5 (.deb) do kontenera $CTID..."
        pct push "$CTID" "$HOST_PKG_CACHE" "/tmp/wazuh-agent-v5.deb"
    fi

elif [[ "$PKG_FORMAT" == "rpm" ]]; then
    WAZUH_RPM_NAME="wazuh-agent-${WAZUH_VER}.x86_64.rpm"
    [[ "$CT_ARCH" == "aarch64" || "$CT_ARCH" == "arm64" ]] && WAZUH_RPM_NAME="wazuh-agent-${WAZUH_VER}.aarch64.rpm"
    WAZUH_URL="${BASE_V5_URL}/yum/${WAZUH_RPM_NAME}"
    HOST_PKG_CACHE="${CACHE_DIR}/${WAZUH_RPM_NAME}"

    if [[ ! -f "$HOST_PKG_CACHE" ]]; then
        echo "[+] Pobieranie pakietu Wazuh Agent v5 (${WAZUH_RPM_NAME}) do pamięci podręcznej..."
        curl -fsSL "$WAZUH_URL" -o "$HOST_PKG_CACHE" || {
            echo "[-] Błąd pobierania pakietu Wazuh v5 z $WAZUH_URL" >&2
            rm -f "$HOST_PKG_CACHE"
        }
    fi

    if [[ -f "$HOST_PKG_CACHE" ]]; then
        echo "[+] Przesyłanie pakietu Wazuh Agent v5 (.rpm) do kontenera $CTID..."
        pct push "$CTID" "$HOST_PKG_CACHE" "/tmp/wazuh-agent-v5.rpm"
    fi
fi

# ------------------------------------------------------------------------------
# 6. Build Multi-Distro Container Payload Script
# ------------------------------------------------------------------------------
PAYLOAD="/tmp/lxc_setup_payload_${CTID}.sh"

cat << INNER_EOF > "$PAYLOAD"
#!/bin/sh
set -eu

ERR_LOG="/tmp/ct_setup_errors.log"
> "\$ERR_LOG"

log_err() {
    step="\$1"
    log_file="\${2:-}"
    echo "--> [BŁĄD] \$step" >> "\$ERR_LOG"
    if [ -n "\$log_file" ] && [ -f "\$log_file" ]; then
        echo "    Szczegóły:" >> "\$ERR_LOG"
        tail -n 15 "\$log_file" | sed "s/^/    /" >> "\$ERR_LOG"
    fi
}

echo "[CT] 1. Wyłączanie zbędnych usług synchronizacji czasu NTP (czas pilnowany przez host PVE)..."
if [ -d /run/systemd/system ]; then
    systemctl disable --now chrony chronyd systemd-timesyncd ntpd 2>/dev/null || true
    systemctl mask chrony chronyd systemd-timesyncd ntpd 2>/dev/null || true
elif [ -d /run/openrc ] || [ -f /sbin/openrc-run ]; then
    rc-update del chronyd default 2>/dev/null || true
    rc-service chronyd stop 2>/dev/null || true
    rc-update del ntpd default 2>/dev/null || true
    rc-service ntpd stop 2>/dev/null || true
fi

echo "[CT] 2. Instalacja narzędzi administracyjnych dla rodziny '${CT_FAMILY}' (${CT_ID})..."
case "${CT_FAMILY}" in
    debian)
        export DEBIAN_FRONTEND=noninteractive
        # Modernize Debian repositories if Debian
        if [ "${CT_ID}" = "debian" ] && [ -f /etc/apt/sources.list ] && [ ! -f /etc/apt/sources.list.d/debian.sources ]; then
            mv /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || true
            touch /etc/apt/sources.list.d/debian.list
            echo "deb http://deb.debian.org/debian ${CT_CODENAME} main contrib non-free non-free-firmware" > /etc/apt/sources.list.d/debian.list
            echo "deb http://deb.debian.org/debian ${CT_CODENAME}-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list.d/debian.list
            echo "deb http://security.debian.org/debian-security ${CT_CODENAME}-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list.d/debian.list
        fi

        apt-get update -y
        apt-get install -y ca-certificates curl wget gnupg lsb-release apt-transport-https debian-archive-keyring sudo openssh-server
        apt-get install -y pv fish fortunes-pl cowsay unattended-upgrades apt-listchanges ufw fail2ban libpam-tmpdir needrestart debsums rkhunter 2>/dev/null || true
        apt-get install -y fastfetch 2>/dev/null || true

        # Auto-upgrades configuration
        cat << 'APTCONF' > /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null || true
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
APTCONF
        ;;

    rhel)
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y epel-release 2>/dev/null || true
            dnf install -y ca-certificates curl wget gnupg2 sudo openssh-server openssh-clients 2>/dev/null || true
            dnf install -y fish cowsay firewalld fail2ban 2>/dev/null || true
            dnf install -y fastfetch 2>/dev/null || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y epel-release 2>/dev/null || true
            yum install -y ca-certificates curl wget sudo openssh-server openssh-clients 2>/dev/null || true
        fi
        [ -d /run/systemd/system ] && systemctl enable sshd 2>/dev/null || true
        ;;

    suse)
        zypper --non-interactive refresh 2>/dev/null || true
        zypper --non-interactive install -y ca-certificates curl wget sudo openssh 2>/dev/null || true
        zypper --non-interactive install -y fish fail2ban firewalld fastfetch 2>/dev/null || true
        [ -d /run/systemd/system ] && systemctl enable sshd 2>/dev/null || true
        ;;

    arch)
        pacman -Sy --noconfirm 2>/dev/null || true
        pacman -S --noconfirm --needed ca-certificates curl wget sudo openssh 2>/dev/null || true
        pacman -S --noconfirm --needed fish fastfetch ufw fail2ban 2>/dev/null || true
        [ -d /run/systemd/system ] && systemctl enable sshd 2>/dev/null || true
        ;;

    alpine)
        apk update 2>/dev/null || true
        apk add --no-cache ca-certificates curl wget sudo shadow bash openssh 2>/dev/null || apk add --no-cache ca-certificates curl wget sudo openssh 2>/dev/null || true
        apk add --no-cache fish fail2ban 2>/dev/null || true
        if [ -d /run/openrc ] || [ -f /sbin/openrc-run ]; then
            rc-update add sshd default 2>/dev/null || rc-update add ssh default 2>/dev/null || true
            ssh-keygen -A 2>/dev/null || true
            rc-service sshd start 2>/dev/null || true
        fi
        ;;

    *)
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y && apt-get install -y ca-certificates curl wget sudo openssh-server 2>/dev/null || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y ca-certificates curl wget sudo openssh-server 2>/dev/null || true
        elif command -v zypper >/dev/null 2>&1; then
            zypper --non-interactive install -y ca-certificates curl wget sudo openssh 2>/dev/null || true
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Sy --noconfirm --needed ca-certificates curl wget sudo openssh 2>/dev/null || true
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache ca-certificates curl wget sudo shadow bash openssh 2>/dev/null || true
        fi
        ;;
esac

echo "[CT] 3. Konfiguracja użytkownika ${LXC_USER} i uprawnień sudo..."
# Determine preferred shell
USER_SHELL="/bin/sh"
if command -v fish >/dev/null 2>&1; then
    USER_SHELL="\$(command -v fish)"
elif command -v bash >/dev/null 2>&1; then
    USER_SHELL="\$(command -v bash)"
fi

# Determine sudo group
SUDO_GRP="wheel"
if grep -q "^sudo:" /etc/group 2>/dev/null; then
    SUDO_GRP="sudo"
fi

if ! id -u "${LXC_USER}" >/dev/null 2>&1; then
    if command -v useradd >/dev/null 2>&1; then
        useradd -m -s "\$USER_SHELL" -G "\$SUDO_GRP" "${LXC_USER}" 2>/dev/null || useradd -m -s "\$USER_SHELL" "${LXC_USER}" 2>/dev/null || true
    elif command -v adduser >/dev/null 2>&1; then
        adduser -D -s "\$USER_SHELL" "${LXC_USER}" 2>/dev/null || adduser -s "\$USER_SHELL" "${LXC_USER}" 2>/dev/null || true
        addgroup "${LXC_USER}" "\$SUDO_GRP" 2>/dev/null || true
    fi
fi

if command -v usermod >/dev/null 2>&1; then
    usermod -aG "\$SUDO_GRP" "${LXC_USER}" 2>/dev/null || true
    usermod -s "\$USER_SHELL" "${LXC_USER}" 2>/dev/null || true
fi

mkdir -p /etc/sudoers.d
echo "${LXC_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${LXC_USER}"
chmod 440 "/etc/sudoers.d/90-${LXC_USER}" 2>/dev/null || true

mkdir -p "/home/${LXC_USER}/.ssh"
chmod 700 "/home/${LXC_USER}/.ssh"

echo "[CT] 4. Bezpieczna konfiguracja serwera SSH (Post-Quantum & klucze)..."
SSHD_CFG="/etc/ssh/sshd_config"
if [ -f "\$SSHD_CFG" ]; then
    cp "\$SSHD_CFG" "\${SSHD_CFG}.bak" 2>/dev/null || true
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "\$SSHD_CFG" 2>/dev/null || true
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "\$SSHD_CFG" 2>/dev/null || true
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "\$SSHD_CFG" 2>/dev/null || true
fi

if [ -d /etc/ssh/sshd_config.d ]; then
    cat << 'SSHD_CONF' > /etc/ssh/sshd_config.d/99-hardened.conf
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256
SSHD_CONF
    chmod 600 /etc/ssh/sshd_config.d/99-hardened.conf 2>/dev/null || true
fi

echo "[CT] 5. Instalacja Wazuh-Agent v5 (${WAZUH_VER})..."
if [ -f /tmp/wazuh-agent-v5.deb ]; then
    export WAZUH_MANAGER="${WAZUH_MGR}"
    export WAZUH_AGENT_GROUP="${WAZUH_GRP}"
    
    if dpkg --force-confdef --force-confold -i /tmp/wazuh-agent-v5.deb > /tmp/wazuh_install.log 2>&1 || (apt-get install -f -y >> /tmp/wazuh_install.log 2>&1 && dpkg --force-confdef --force-confold -i /tmp/wazuh-agent-v5.deb >> /tmp/wazuh_install.log 2>&1); then
        [ -d /run/systemd/system ] && systemctl daemon-reload 2>/dev/null || true
        [ -d /run/systemd/system ] && systemctl enable --now wazuh-agent 2>/dev/null || true
        rm -f /tmp/wazuh-agent-v5.deb
    else
        log_err "Instalacja pakietu Wazuh Agent v5 (deb)" "/tmp/wazuh_install.log"
    fi

elif [ -f /tmp/wazuh-agent-v5.rpm ]; then
    export WAZUH_MANAGER="${WAZUH_MGR}"
    export WAZUH_AGENT_GROUP="${WAZUH_GRP}"
    
    if rpm -Uvh --replacepkgs /tmp/wazuh-agent-v5.rpm > /tmp/wazuh_install.log 2>&1 || \
       (command -v dnf >/dev/null 2>&1 && dnf install -y /tmp/wazuh-agent-v5.rpm >> /tmp/wazuh_install.log 2>&1) || \
       (command -v zypper >/dev/null 2>&1 && zypper --non-interactive install -y /tmp/wazuh-agent-v5.rpm >> /tmp/wazuh_install.log 2>&1); then
        [ -d /run/systemd/system ] && systemctl daemon-reload 2>/dev/null || true
        [ -d /run/systemd/system ] && systemctl enable --now wazuh-agent 2>/dev/null || true
        rm -f /tmp/wazuh-agent-v5.rpm
    else
        log_err "Instalacja pakietu Wazuh Agent v5 (rpm)" "/tmp/wazuh_install.log"
    fi

else
    echo "[CT] Wazuh Agent: brak oficjalnego pakietu dla ${CT_ID} w kanale v5 beta - pomijam instalację agenta (system zabezpieczony pomyślnie)."
fi

# Clean caches
command -v apt-get >/dev/null 2>&1 && apt-get clean 2>/dev/null || true
command -v dnf >/dev/null 2>&1 && dnf clean all 2>/dev/null || true
command -v zypper >/dev/null 2>&1 && zypper clean --all 2>/dev/null || true
command -v pacman >/dev/null 2>&1 && pacman -Sc --noconfirm 2>/dev/null || true

# Mark container as successfully provisioned
date -u +'%Y-%m-%dT%H:%M:%SZ' > /etc/.lxc_provisioned 2>/dev/null || true
INNER_EOF

# ------------------------------------------------------------------------------
# 7. Execute Payload Inside Container
# ------------------------------------------------------------------------------
echo "[+] Przesyłanie skryptu konfiguracyjnego do kontenera..."
pct push "$CTID" "$PAYLOAD" "/tmp/setup.sh"
pct exec "$CTID" -- chmod +x "/tmp/setup.sh"

echo "[+] Uruchamianie konfiguracji wewnątrz kontenera (${CT_PRETTY_NAME})..."
pct exec "$CTID" -- /bin/sh -c "/tmp/setup.sh && (echo \"${LXC_USER}:${TARGET_USER_PASS}\" | chpasswd 2>/dev/null || (command -v passwd >/dev/null && echo -e \"${TARGET_USER_PASS}\n${TARGET_USER_PASS}\" | passwd \"${LXC_USER}\" 2>/dev/null) || true)"

# ------------------------------------------------------------------------------
# 8. Host Integration: SSH Keys & Network Domain
# ------------------------------------------------------------------------------
echo "[+] Kopiowanie autoryzowanych kluczy SSH z hosta do użytkownika ${LXC_USER}..."
if [[ -f "$SSH_PUBKEY" ]]; then
    pct push "$CTID" "$SSH_PUBKEY" "/home/${LXC_USER}/.ssh/authorized_keys"
    pct exec "$CTID" -- chown -R "${LXC_USER}" "/home/${LXC_USER}/.ssh" 2>/dev/null || true
    pct exec "$CTID" -- chmod 700 "/home/${LXC_USER}/.ssh" 2>/dev/null || true
    pct exec "$CTID" -- chmod 600 "/home/${LXC_USER}/.ssh/authorized_keys" 2>/dev/null || true
else
    echo "[-] Ostrzeżenie: Plik kluczy $SSH_PUBKEY nie istnieje na hoście Proxmox!"
fi

if [[ -n "$SEARCH_DOMAIN" ]]; then
    echo "[+] Ustawianie domeny wyszukiwania DNS na: ${SEARCH_DOMAIN}..."
    pct set "$CTID" -searchdomain "$SEARCH_DOMAIN"
fi

# Opcjonalne/automatyczne zamrożenie dzierżawy DHCP/SLAAC na stały adres statyczny w PVE
FREEZE_NET="${FREEZE_NETWORK_STATIC:-true}"
if [[ "$FREEZE_NET" == "true" ]]; then
    NET0_CONF=$(pct config "$CTID" 2>/dev/null | grep '^net0:' || true)
    if [[ "$NET0_CONF" =~ "ip=dhcp" || "$NET0_CONF" =~ "ip6=auto" || "$NET0_CONF" =~ "bridge=ProxNET" ]]; then
        echo "[+] Sprawdzanie i zamrażanie dzierżawy DHCP/SLAAC na adres statyczny w Proxmox VE..."
        IP4_CIDR=$(pct exec "$CTID" -- ip -4 -o addr show dev eth0 scope global 2>/dev/null | awk '{print $4}' | head -n1 || true)
        GW4=$(pct exec "$CTID" -- ip -4 route show default dev eth0 2>/dev/null | awk '/default/ {print $3}' | head -n1 || true)
        [[ -z "$GW4" ]] && GW4=$(pct exec "$CTID" -- ip -4 route show default 2>/dev/null | awk '/default/ {print $3}' | head -n1 || true)

        IP6_CIDR=$(pct exec "$CTID" -- ip -6 -o addr show dev eth0 scope global 2>/dev/null | grep -v 'tentative' | awk '{print $4}' | head -n1 || true)
        GW6=$(pct exec "$CTID" -- ip -6 route show default dev eth0 2>/dev/null | awk '/default/ {print $3}' | head -n1 || true)
        [[ -z "$GW6" ]] && GW6=$(pct exec "$CTID" -- ip -6 route show default 2>/dev/null | awk '/default/ {print $3}' | head -n1 || true)

        # Capture active nameservers from container
        NAMESERVERS=$(pct exec "$CTID" -- awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)
        if [[ -z "$NAMESERVERS" ]]; then
            NAMESERVERS="1.1.1.1 8.8.8.8"
        fi

        # CRITICAL: Link-local IPv6 gateway (fe80::...) CANNOT be used in Proxmox gw6 without device scope!
        if [[ "$GW6" =~ ^[fF][eE]80: ]]; then
            GW6=""
        fi

        BR_NAME=$(echo "$NET0_CONF" | grep -oP 'bridge=\K[^,]+' || echo "ProxNET")

        if [[ -n "$IP4_CIDR" ]]; then
            NEW_NET0="name=eth0,bridge=${BR_NAME},firewall=0,ip=${IP4_CIDR}"
            [[ -n "$GW4" ]] && NEW_NET0+=",gw=${GW4}"
            if [[ -n "$IP6_CIDR" ]]; then
                NEW_NET0+=",ip6=${IP6_CIDR}"
                [[ -n "$GW6" ]] && NEW_NET0+=",gw6=${GW6}"
            fi
            echo "[+] Ustawiono statyczny adres IP w Proxmox VE: IPv4=${IP4_CIDR} (GW: ${GW4:-brak})${IP6_CIDR:+, IPv6=${IP6_CIDR}}"
            pct set "$CTID" -net0 "$NEW_NET0" -nameserver "$NAMESERVERS" >/dev/null 2>&1 || true

            # Re-assert routes and resolv.conf inside container
            pct exec "$CTID" -- bash -c "
                ip link set dev eth0 up 2>/dev/null || true
                ip -4 addr replace '$IP4_CIDR' dev eth0 2>/dev/null || true
                [[ -n '$GW4' ]] && ip -4 route replace default via '$GW4' dev eth0 2>/dev/null || true
                [[ -n '$IP6_CIDR' ]] && ip -6 addr replace '$IP6_CIDR' dev eth0 2>/dev/null || true
                mkdir -p /etc
                if ! grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; then
                    for ns in $NAMESERVERS; do
                        echo \"nameserver \$ns\" >> /etc/resolv.conf
                    done
                fi
            " 2>/dev/null || true
        fi
    fi
fi

# Restarts & Cleanup
echo "[+] Restartowanie usług sieciowych i czyszczenie..."
pct exec "$CTID" -- /bin/sh -c "systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || rc-service sshd restart 2>/dev/null || /etc/init.d/ssh restart 2>/dev/null || /etc/init.d/sshd restart 2>/dev/null || true"
pct exec "$CTID" -- rm -f "/tmp/setup.sh"
rm -f "$PAYLOAD"

echo "=========================================================="
echo "[+] Kontener $CTID (${CT_PRETTY_NAME}) został pomyślnie skonfigurowany!"
echo "    Użytkownik: ${LXC_USER} (logowanie przez klucze SSH)"
echo "    Rodzina: ${CT_FAMILY} | Format: ${PKG_FORMAT}"
echo "    NTP: czas pilnowany bezpośrednio z jądra hosta PVE"
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
