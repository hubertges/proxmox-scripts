#!/usr/bin/env bash
# ==============================================================================
# ct/create_zabbix_lxc.sh
# Proxmox VE Helper Script: Automated Zabbix 8.0 LTS + PostgreSQL 17 LXC Deployment
# Style: Proxmox Community Helper Scripts (tteck / community-scripts standard)
#
# Target Hypervisor: Proxmox VE 8.x / 9.x
# Target Container:  Debian GNU/Linux 13 (Trixie) - Unprivileged LXC
# Components:        Zabbix Server 8.0, PostgreSQL 17, Zabbix Agent 2, Web GUI
# Documentation:     https://www.zabbix.com/documentation/devel/en/manual
# ==============================================================================

set -euo pipefail

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")

# Load environment configuration if available (.env)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for env_candidate in \
    "${REPO_DIR}/.env" \
    "$(pwd)/.env" \
    "/etc/pve/scripts/.env" \
    "/etc/pve/secrets/.env" \
    "/etc/pve/.env" \
    "$HOME/.env"; do
    if [[ -f "$env_candidate" ]]; then
        # shellcheck source=/dev/null
        source "$env_candidate"
        break
    fi
done

if ! command -v pveversion >/dev/null 2>&1; then
    echo -e "${RD}[!] Error: This script must be executed on your Proxmox VE host node.${CL}" >&2
    exit 1
fi

# Ensure jq is installed if possible, but do not fail if apt cannot run
if ! command -v jq >/dev/null 2>&1; then
    echo -e "${YW}[*] 'jq' package not found. Installing jq on Proxmox host...${CL}"
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y jq >/dev/null 2>&1 || true
fi

# Helper: Query local active PVE storage pools safely (filtering by node affinity and active status)
get_local_pve_storages() {
    local content_type="$1"
    local -a list=()

    # 1. Preferred: pvesm status -content <type> (evaluates active storages on the current node)
    if command -v pvesm >/dev/null 2>&1; then
        while IFS= read -r line; do
            local s_name s_type s_status _ _ s_avail _
            read -r s_name s_type s_status _ _ s_avail _ <<< "$line"
            if [[ -n "$s_name" && "$s_name" != "Name" ]]; then
                if [[ "$s_status" == "active" || -z "$s_status" ]]; then
                    list+=("$s_name $s_type ${s_avail:-0}")
                fi
            fi
        done < <(pvesm status -content "$content_type" 2>/dev/null || true)
    fi

    # 2. Fallback: parse /etc/pve/storage.cfg filtered by the local node
    if [[ ${#list[@]} -eq 0 && -f /etc/pve/storage.cfg ]]; then
        local my_node
        my_node=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "")
        while IFS= read -r line; do
            [[ -n "$line" ]] && list+=("$line")
        done < <(awk -v c="$content_type" -v node="$my_node" '
            /^[a-z0-9_-]+:[[:space:]]+/ {
                cur = $2
                sub(/^[a-z0-9_-]+:[[:space:]]*/, "", cur)
                sub(/[[:space:]].*$/, "", cur)
                has_content = 0
                node_match = 1
                disabled = 0
            }
            /^[[:space:]]+disable/ { disabled = 1 }
            /^[[:space:]]+nodes[[:space:]]+/ {
                nodes_list = $0
                sub(/^[[:space:]]+nodes[[:space:]]+/, "", nodes_list)
                if (node != "" && nodes_list !~ "(^|,)" node "(,|$)") {
                    node_match = 0
                }
            }
            /^[[:space:]]+content[[:space:]]+/ {
                if ($0 ~ c) has_content = 1
            }
            cur && has_content && node_match && !disabled {
                print cur " local active 0 0 0 0%"
                has_content = 0
            }
        ' /etc/pve/storage.cfg 2>/dev/null || true)
    fi

    for item in "${list[@]}"; do
        echo "$item"
    done
}

# Helper: Interactive Whiptail Storage Radiolist Menu (Community-Scripts Standard)
select_storage() {
    local content_type="$1"
    local title="$2"
    local default_stor="${3:-}"

    local -a storage_lines=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && storage_lines+=("$line")
    done < <(get_local_pve_storages "$content_type")

    local count=${#storage_lines[@]}
    if [[ $count -eq 0 ]]; then
        echo "${default_stor:-local}"
        return
    fi

    # If only 1 storage pool exists on this node, pick it directly
    if [[ $count -eq 1 ]]; then
        local single_name
        read -r single_name _ <<< "${storage_lines[0]}"
        echo "$single_name"
        return
    fi

    # Non-interactive / headless fallback
    if ! command -v whiptail >/dev/null 2>&1 || [[ ! -t 0 ]]; then
        if [[ -n "$default_stor" ]]; then
            for line in "${storage_lines[@]}"; do
                local s_name
                read -r s_name _ <<< "$line"
                if [[ "$s_name" == "$default_stor" ]]; then
                    echo "$default_stor"
                    return
                fi
            done
        fi
        local first_name
        read -r first_name _ <<< "${storage_lines[0]}"
        echo "$first_name"
        return
    fi

    # Build whiptail radiolist menu options: <tag> <item> <status>
    local menu_items=()
    local first=1
    for line in "${storage_lines[@]}"; do
        local s_name s_type s_avail_raw
        read -r s_name s_type s_avail_raw <<< "$line"
        local s_free="N/A"
        if [[ -n "$s_avail_raw" && "$s_avail_raw" =~ ^[0-9]+$ && "$s_avail_raw" -gt 0 ]]; then
            s_free=$(numfmt --to=iec --from-unit=K "$s_avail_raw" 2>/dev/null || echo "${s_avail_raw}K")
        fi

        local is_on="OFF"
        if [[ -n "$default_stor" && "$s_name" == "$default_stor" ]]; then
            is_on="ON"
        elif [[ -z "$default_stor" && $first -eq 1 ]]; then
            is_on="ON"
            first=0
        fi

        menu_items+=("$s_name" "Type: ${s_type} | Free: ${s_free}" "$is_on")
    done

    local selected
    selected=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "$title" \
        --radiolist "Select storage pool on node '$(hostname)':" \
        16 68 $((count > 8 ? 8 : count)) \
        "${menu_items[@]}" 3>&1 1>&2 2>&3) || true

    if [[ -z "$selected" ]]; then
        local first_name
        read -r first_name _ <<< "${storage_lines[0]}"
        selected="$first_name"
    fi

    echo "$selected"
}

# Helper: Configure native DHCP client (systemd-networkd) inside container
# Debian 13 (Trixie) LXC does not ship with isc-dhcp-client; systemd-networkd provides native DHCPv4 and IPv6 SLAAC
setup_container_dhcp() {
    local ctid="$1"
    echo -e "${YW}[*] Activating native DHCP client (systemd-networkd) inside container ${ctid}...${CL}"
    
    # Wait until container init namespace is responsive
    for _ in {1..15}; do
        if pct exec "$ctid" -- test -d /etc 2>/dev/null; then
            break
        fi
        sleep 1
    done

    pct exec "$ctid" -- bash -c '
        ip link set dev lo up 2>/dev/null || true
        ip link set dev eth0 up 2>/dev/null || true

        # Write systemd-networkd DHCP configuration
        mkdir -p /etc/systemd/network
        cat > /etc/systemd/network/10-eth0.network << "NETEOF"
[Match]
Name=eth0

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
UseDNS=yes
UseRoutes=yes
NETEOF
        chmod 644 /etc/systemd/network/10-eth0.network

        # Unmask, enable, and restart systemd-networkd
        systemctl unmask systemd-networkd 2>/dev/null || true
        systemctl enable --now systemd-networkd 2>/dev/null || true
        systemctl restart systemd-networkd 2>/dev/null || true

        if command -v networkctl >/dev/null 2>&1; then
            networkctl reload 2>/dev/null || true
            networkctl reconfigure eth0 2>/dev/null || true
        fi

        # Secondary fallback if legacy dhcp clients are present
        if command -v dhclient >/dev/null 2>&1; then
            dhclient -4 -v -1 eth0 2>/dev/null || true
        elif command -v dhcpcd >/dev/null 2>&1; then
            dhcpcd -4 eth0 2>/dev/null || true
        elif command -v udhcpc >/dev/null 2>&1; then
            udhcpc -i eth0 -n -q 2>/dev/null || true
        fi
    ' 2>/dev/null || true
}

# Helper: Fetch dynamic IPv4 & IPv6 leases from bridge and freeze them as STATIC in Proxmox VE
freeze_container_network() {
    local ctid="$1"
    local bridge="$2"
    local mode="${3:-DHCP}"

    local ip4_cidr="" gw4="" ip6_cidr="" gw6=""
    local nameservers searchdomain

    if [[ "$mode" == "STATIC" && -n "${STATIC_IP4:-}" ]]; then
        ip4_cidr="${STATIC_IP4}"
        gw4="${STATIC_GW4:-}"
        nameservers="${STATIC_DNS:-1.1.1.1 8.8.8.8}"
        echo -e "${GN}[+] Using pre-configured Static IPv4: ${ip4_cidr} (Gateway: ${gw4:-none})${CL}"
    else
        echo -e "${YW}[*] Waiting for network lease (IPv4 & IPv6) on bridge '${bridge}'...${CL}"
        
        # Wait up to 20s for IPv4 lease
        for i in {1..20}; do
            ip4_cidr=$(pct exec "$ctid" -- ip -4 -o addr show dev eth0 scope global 2>/dev/null | awk '{print $4}' | head -n1 || true)
            if [[ -n "$ip4_cidr" ]]; then
                break
            fi
            if [[ $i -eq 5 || $i -eq 10 || $i -eq 15 ]]; then
                pct exec "$ctid" -- bash -c "
                    ip link set dev eth0 up 2>/dev/null || true
                    systemctl restart systemd-networkd 2>/dev/null || true
                    if command -v networkctl >/dev/null 2>&1; then
                        networkctl reconfigure eth0 2>/dev/null || true
                    fi
                " 2>/dev/null || true
            fi
            sleep 1
        done

        # If no DHCP lease was received, bridge may lack a DHCP server
        if [[ -z "$ip4_cidr" ]]; then
            echo -e "\n${RD}[!] Container failed to obtain an IPv4 address via DHCP on bridge '${bridge}'!${CL}"
            echo -e "${YW}[i] This indicates bridge '${bridge}' has no active DHCP server.${CL}"

            local user_ip="" user_gw="" user_dns=""
            if command -v whiptail >/dev/null 2>&1 && [[ -t 0 ]]; then
                if whiptail --backtitle "Proxmox VE Helper Scripts" \
                    --title "DHCP TIMEOUT ON BRIDGE '${bridge}'" \
                    --yesno "Container did not receive an IPv4 address from DHCP on bridge '${bridge}'.\n\nWould you like to assign a Static IPv4 address now to continue?" 12 68; then
                    
                    user_ip=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
                        --inputbox "Enter Static IPv4 Address with CIDR prefix (e.g. 192.168.1.50/24 or 10.0.0.50/24):" 9 68 "" \
                        --title "STATIC IPV4" 3>&1 1>&2 2>&3 || true)
                    
                    if [[ -n "$user_ip" ]]; then
                        user_gw=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
                            --inputbox "Enter Default Gateway IPv4 (e.g. 192.168.1.1 or 10.0.0.1):" 9 68 "" \
                            --title "GATEWAY IPV4" 3>&1 1>&2 2>&3 || true)
                        user_dns=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
                            --inputbox "Enter DNS Nameservers:" 9 68 "1.1.1.1 8.8.8.8" \
                            --title "DNS SERVERS" 3>&1 1>&2 2>&3 || echo "1.1.1.1 8.8.8.8")
                    fi
                fi
            else
                echo -e "${YW}Please provide static IP configuration below:${CL}"
                read -r -p "Enter Static IPv4 with CIDR prefix (e.g. 192.168.1.50/24): " user_ip || true
                if [[ -n "$user_ip" ]]; then
                    read -r -p "Enter Gateway IPv4 (e.g. 192.168.1.1): " user_gw || true
                    read -r -p "Enter DNS Nameservers [1.1.1.1 8.8.8.8]: " user_dns || true
                    user_dns="${user_dns:-1.1.1.1 8.8.8.8}"
                fi
            fi

            if [[ -n "$user_ip" ]]; then
                ip4_cidr="$user_ip"
                gw4="$user_gw"
                nameservers="${user_dns:-1.1.1.1 8.8.8.8}"
                echo -e "${GN}[+] Using user-configured Static IPv4: ${ip4_cidr} (Gateway: ${gw4:-none})${CL}"
            else
                echo -e "\n${RD}[ERROR] Cannot deploy without an IPv4 address.${CL}"
                echo -e "${YW}Troubleshooting steps:${CL}"
                echo -e "  1. Check if a DHCP server is running on bridge '${bridge}'."
                echo -e "  2. If '${bridge}' is an isolated internal bridge, use Advanced Settings to assign a Static IP or pick your LAN bridge (e.g., vmbr0)."
                echo -e "  3. To clean up: run 'pct destroy ${ctid}'${CL}\n"
                exit 1
            fi
        fi

        # Give IPv6 SLAAC / DHCPv6 a few seconds
        for i in {1..6}; do
            ip6_cidr=$(pct exec "$ctid" -- ip -6 -o addr show dev eth0 scope global 2>/dev/null | grep -v 'tentative' | awk '{print $4}' | head -n1 || true)
            [[ -n "$ip6_cidr" ]] && break
            sleep 1
        done

        if [[ -z "$gw4" ]]; then
            gw4=$(pct exec "$ctid" -- ip -4 route show default dev eth0 2>/dev/null | awk '/default/ {print $3}' | head -n1 || true)
            [[ -z "$gw4" ]] && gw4=$(pct exec "$ctid" -- ip -4 route show default 2>/dev/null | awk '/default/ {print $3}' | head -n1 || true)
        fi

        gw6=$(pct exec "$ctid" -- ip -6 route show default dev eth0 2>/dev/null | awk '/default/ {print $3}' | head -n1 || true)
        [[ -z "$gw6" ]] && gw6=$(pct exec "$ctid" -- ip -6 route show default 2>/dev/null | awk '/default/ {print $3}' | head -n1 || true)

        if [[ -z "$nameservers" ]]; then
            nameservers=$(pct exec "$ctid" -- awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)
            [[ -z "$nameservers" ]] && nameservers="1.1.1.1 8.8.8.8"
        fi
        searchdomain=$(pct exec "$ctid" -- awk '/^search/ {print $2}' /etc/resolv.conf 2>/dev/null | head -n1 || true)

        if [[ "$gw6" =~ ^[fF][eE]80: ]]; then
            echo -e "${YW}[*] Link-local IPv6 gateway (${gw6}) detected; router advertisements (SLAAC) manage default route.${CL}"
            gw6=""
        fi

        echo -e "${GN}[+] Acquired IPv4: ${ip4_cidr} (Gateway: ${gw4:-none})${CL}"
        [[ -n "$ip6_cidr" ]] && echo -e "${GN}[+] Acquired IPv6: ${ip6_cidr} (Gateway: ${gw6:-SLAAC RA})${CL}"
    fi

    local net_str="name=eth0,bridge=${bridge},firewall=0,ip=${ip4_cidr}"
    [[ -n "$gw4" ]] && net_str+=",gw=${gw4}"
    if [[ -n "$ip6_cidr" ]]; then
        net_str+=",ip6=${ip6_cidr}"
        [[ -n "$gw6" ]] && net_str+=",gw6=${gw6}"
    fi

    echo -e "${BL}[*] Locking network lease into STATIC IP configuration in Proxmox VE (pct set)...${CL}"
    local set_cmd=(pct set "$ctid" -net0 "$net_str" -nameserver "$nameservers")
    [[ -n "$searchdomain" ]] && set_cmd+=(-searchdomain "$searchdomain")
    "${set_cmd[@]}" >/dev/null 2>&1 || true

    # Safeguard: Apply live configuration immediately without waiting for reboot
    pct exec "$ctid" -- bash -c "
        ip link set dev lo up 2>/dev/null || true
        ip link set dev eth0 up 2>/dev/null || true
        ip -4 addr replace '${ip4_cidr}' dev eth0 2>/dev/null || true
        ${gw4:+ip -4 route replace default via '${gw4}' dev eth0 2>/dev/null || true}
        ${ip6_cidr:+ip -6 addr replace '${ip6_cidr}' dev eth0 2>/dev/null || true}

        # Write permanent /etc/network/interfaces
        cat > /etc/network/interfaces << 'IFEOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address ${ip4_cidr}
    ${gw4:+gateway ${gw4}}
${ip6_cidr:+iface eth0 inet6 static
    address ${ip6_cidr}}
IFEOF

        # Write permanent /etc/systemd/network/10-eth0.network
        mkdir -p /etc/systemd/network
        cat > /etc/systemd/network/10-eth0.network << 'NETEOF'
[Match]
Name=eth0

[Network]
Address=${ip4_cidr}
${gw4:+Gateway=${gw4}}
DNS=${nameservers}
NETEOF

        # Ensure working nameservers in /etc/resolv.conf
        mkdir -p /etc
        > /etc/resolv.conf
        for ns in ${nameservers}; do
            echo \"nameserver \$ns\" >> /etc/resolv.conf
        done
        ${searchdomain:+echo \"search ${searchdomain}\" >> /etc/resolv.conf}
    " 2>/dev/null || true

    CT_IP_V4="${ip4_cidr%%/*}"
    CT_IP_V6="${ip6_cidr%%/*}"
    CT_IP="${CT_IP_V4}"
}

clear
cat << "BANNER"
  _____ _____ ____  ____ _____  __   ___    ___  
 |__  /|  _  | __ )| __ )_   _| \ \ / / \  / _ \ 
   / / | |_| |  _ \|  _ \ | |    \ V / _ \| | | |
  / /_ |  _  | |_) | |_) || |     | / ___ \ |_| |
 /____||_| |_|____/|____/ |_|     |/_/   \_\___/ 
  Proxmox VE Helper Script: Zabbix 8.0 LTS + PostgreSQL 17
BANNER
echo -e "${BL}Enterprise Monitoring Platform on Debian 13 (Trixie) LXC${CL}\n"

# 1. Interactive Parameter Selection (Proxmox Helper Scripts standard)
NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")

if command -v whiptail >/dev/null 2>&1 && [[ -t 0 ]]; then
    if whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "SETTINGS" \
        --yes-button "Default" \
        --no-button "Advanced" \
        --yesno "Use Default Settings for Zabbix 8.0 LTS LXC Container?" 10 58; then
        # Default Settings
        echo -e "${BL}Using Default Settings${CL}"
        CTID="${ZABBIX_CTID:-$NEXT_ID}"
        HOSTNAME="${ZABBIX_HOSTNAME:-zabbix8-server}"
        CORES="${ZABBIX_CORES:-2}"
        RAM="${ZABBIX_RAM_MB:-4096}"
        SWAP="${ZABBIX_SWAP_MB:-1024}"
        DISK="${ZABBIX_DISK_GB:-16}"
        MGMT_BR="${MGMT_BRIDGE:-ProxNET}"
        STORAGE=$(select_storage "rootdir" "Select Storage for Container Rootfs" "${DEFAULT_STORAGE:-}")
        NET_MODE="DHCP"
        STATIC_IP4=""
        STATIC_GW4=""
        STATIC_DNS="1.1.1.1 8.8.8.8"
    else
        # Advanced Settings
        echo -e "${YW}Using Advanced Settings${CL}"
        CTID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Container ID (CTID):" 8 58 "$NEXT_ID" --title "CONTAINER ID" 3>&1 1>&2 2>&3 || echo "$NEXT_ID")
        CTID="${CTID:-$NEXT_ID}"

        HOSTNAME=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Hostname:" 8 58 "${ZABBIX_HOSTNAME:-zabbix8-server}" --title "HOSTNAME" 3>&1 1>&2 2>&3 || echo "${ZABBIX_HOSTNAME:-zabbix8-server}")
        HOSTNAME="${HOSTNAME:-${ZABBIX_HOSTNAME:-zabbix8-server}}"

        CORES=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate CPU Cores:" 8 58 "${ZABBIX_CORES:-2}" --title "CPU ALLOCATION" 3>&1 1>&2 2>&3 || echo "${ZABBIX_CORES:-2}")
        CORES="${CORES:-2}"

        RAM=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate RAM in MB:" 8 58 "${ZABBIX_RAM_MB:-4096}" --title "RAM ALLOCATION" 3>&1 1>&2 2>&3 || echo "${ZABBIX_RAM_MB:-4096}")
        RAM="${RAM:-4096}"

        SWAP=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate Swap in MB:" 8 58 "${ZABBIX_SWAP_MB:-1024}" --title "SWAP ALLOCATION" 3>&1 1>&2 2>&3 || echo "${ZABBIX_SWAP_MB:-1024}")
        SWAP="${SWAP:-1024}"

        DISK=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate Disk Size in GB:" 8 58 "${ZABBIX_DISK_GB:-16}" --title "DISK SIZE" 3>&1 1>&2 2>&3 || echo "${ZABBIX_DISK_GB:-16}")
        DISK="${DISK:-16}"

        STORAGE=$(select_storage "rootdir" "Select Storage for Container Rootfs" "${DEFAULT_STORAGE:-}")

        MGMT_BR=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Network Bridge (ProxNET for Reverse Proxy):" 8 58 "${MGMT_BRIDGE:-ProxNET}" --title "BRIDGE" 3>&1 1>&2 2>&3 || echo "${MGMT_BRIDGE:-ProxNET}")
        MGMT_BR="${MGMT_BR:-ProxNET}"

        NET_CHOICE=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
            --title "IP CONFIGURATION" \
            --radiolist "Select IP Assignment Method on bridge '${MGMT_BR}':" 10 65 2 \
            "DHCP" "Auto-acquire IPv4/IPv6 from bridge, then freeze as static" ON \
            "STATIC" "Manually specify Static IPv4 CIDR and Gateway" OFF 3>&1 1>&2 2>&3 || echo "DHCP")
        NET_CHOICE="${NET_CHOICE:-DHCP}"

        if [[ "$NET_CHOICE" == "STATIC" ]]; then
            NET_MODE="STATIC"
            STATIC_IP4=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Static IPv4 with CIDR (e.g. 192.168.1.50/24 or 10.0.0.50/24):" 8 65 "${STATIC_IP4:-}" --title "STATIC IPV4" 3>&1 1>&2 2>&3 || true)
            STATIC_GW4=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Default Gateway IPv4 (e.g. 192.168.1.1 or 10.0.0.1):" 8 65 "${STATIC_GW4:-}" --title "GATEWAY IPV4" 3>&1 1>&2 2>&3 || true)
            STATIC_DNS=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "DNS Nameservers:" 8 65 "${STATIC_DNS:-1.1.1.1 8.8.8.8}" --title "DNS SERVERS" 3>&1 1>&2 2>&3 || echo "1.1.1.1 8.8.8.8")
        else
            NET_MODE="DHCP"
            STATIC_IP4=""
            STATIC_GW4=""
            STATIC_DNS="1.1.1.1 8.8.8.8"
        fi
    fi
else
    CTID="${ZABBIX_CTID:-$NEXT_ID}"
    HOSTNAME="${ZABBIX_HOSTNAME:-zabbix8-server}"
    CORES="${ZABBIX_CORES:-2}"
    RAM="${ZABBIX_RAM_MB:-4096}"
    SWAP="${ZABBIX_SWAP_MB:-1024}"
    DISK="${ZABBIX_DISK_GB:-16}"
    MGMT_BR="${MGMT_BRIDGE:-ProxNET}"
    STORAGE=$(select_storage "rootdir" "Select Storage for Container Rootfs" "${DEFAULT_STORAGE:-}")
    if [[ -n "${STATIC_IP4:-}" ]]; then
        NET_MODE="STATIC"
        STATIC_GW4="${STATIC_GW4:-}"
        STATIC_DNS="${STATIC_DNS:-1.1.1.1 8.8.8.8}"
    else
        NET_MODE="DHCP"
        STATIC_IP4=""
        STATIC_GW4=""
        STATIC_DNS="1.1.1.1 8.8.8.8"
    fi
fi

# 2. Template Selection & Download
TMPL_STORAGE=$(select_storage "vztmpl" "Select Template Storage Pool" "${TEMPLATE_STORAGE:-}")

echo -e "${YW}[*] Checking Debian standard LXC template...${CL}"
pveam update > /dev/null 2>&1 || true

mapfile -t AVAILABLE_DEBIAN13 < <(pveam available -section system 2>/dev/null | awk '/debian-13-standard/ {print $2}' || true)
mapfile -t AVAILABLE_DEBIAN12 < <(pveam available -section system 2>/dev/null | awk '/debian-12-standard/ {print $2}' || true)

if [[ ${#AVAILABLE_DEBIAN13[@]} -gt 0 && -n "${AVAILABLE_DEBIAN13[0]}" ]]; then
    CHOSEN_TMPL="${AVAILABLE_DEBIAN13[0]}"
    echo -e "${GN}[+] Found native Debian 13 (Trixie) template: ${CHOSEN_TMPL}${CL}"
else
    CHOSEN_TMPL="${AVAILABLE_DEBIAN12[0]:-debian-12-standard_12.7-1_amd64.tar.zst}"
    echo -e "${YW}[i] Using Debian template ${CHOSEN_TMPL} (installer will ensure Debian 13 Trixie upgrade)${CL}"
fi

if ! pveam list "$TMPL_STORAGE" 2>/dev/null | grep -q "$CHOSEN_TMPL"; then
    echo -e "${YW}[*] Downloading container template ${CHOSEN_TMPL}...${CL}"
    pveam download "$TMPL_STORAGE" "$CHOSEN_TMPL"
else
    echo -e "${GN}[+] Container template ${CHOSEN_TMPL} already available on storage '${TMPL_STORAGE}'.${CL}"
fi

# 3. Create Unprivileged LXC Container on ProxNET
echo -e "${BL}[*] Creating LXC Container [CTID: ${CTID}, Hostname: ${HOSTNAME}] on bridge '${MGMT_BR}'...${CL}"
if [[ "$NET_MODE" == "STATIC" && -n "${STATIC_IP4:-}" ]]; then
    create_net="name=eth0,bridge=${MGMT_BR},firewall=0,ip=${STATIC_IP4}"
    [[ -n "${STATIC_GW4:-}" ]] && create_net+=",gw=${STATIC_GW4}"
    pct create "$CTID" "${TMPL_STORAGE}:vztmpl/${CHOSEN_TMPL}" \
        --hostname "$HOSTNAME" \
        --ostype debian \
        --cores "$CORES" \
        --memory "$RAM" \
        --swap "$SWAP" \
        --storage "$STORAGE" \
        --rootfs "${STORAGE}:${DISK}" \
        --net0 "$create_net" \
        --nameserver "${STATIC_DNS:-1.1.1.1 8.8.8.8}" \
        --features nesting=1 \
        --unprivileged 1 \
        --onboot 1
else
    # DHCP Mode: DO NOT pass ip6=auto during creation to prevent ifupdown dual-stack boot crash in Debian 13
    pct create "$CTID" "${TMPL_STORAGE}:vztmpl/${CHOSEN_TMPL}" \
        --hostname "$HOSTNAME" \
        --ostype debian \
        --cores "$CORES" \
        --memory "$RAM" \
        --swap "$SWAP" \
        --storage "$STORAGE" \
        --rootfs "${STORAGE}:${DISK}" \
        --net0 "name=eth0,bridge=${MGMT_BR},firewall=0,ip=dhcp" \
        --features nesting=1 \
        --unprivileged 1 \
        --onboot 1
fi

# 4. Start Container
echo -e "${YW}[*] Starting container ${CTID}...${CL}"
pct start "$CTID"

if [[ "$NET_MODE" == "DHCP" ]]; then
    setup_container_dhcp "$CTID"
fi

# 5. Lock DHCP/SLAAC lease into STATIC IP configuration
freeze_container_network "$CTID" "$MGMT_BR" "$NET_MODE"

# Verify external connectivity before launching installer
echo -e "${YW}[*] Verifying internet access and DNS resolution from inside container...${CL}"
connected=0
for attempt in {1..5}; do
    if pct exec "$CTID" -- ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 || \
       pct exec "$CTID" -- ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 || \
       pct exec "$CTID" -- getent hosts debian.org >/dev/null 2>&1; then
        echo -e "${GN}[+] Internet connectivity verified.${CL}"
        connected=1
        break
    else
        echo -e "${YW}[!] Attempt $attempt: Re-asserting default route and nameservers...${CL}"
        pct exec "$CTID" -- bash -c "
            ip link set dev eth0 up 2>/dev/null || true
            [[ -n '${gw4:-}' ]] && ip -4 route replace default via '${gw4}' dev eth0 2>/dev/null || true
            grep -q nameserver /etc/resolv.conf 2>/dev/null || echo 'nameserver 1.1.1.1' > /etc/resolv.conf
        " 2>/dev/null || true
        sleep 1
    fi
done

if [[ $connected -eq 0 ]]; then
    echo -e "${YW}[!] Warning: Container could not reach public internet via bridge '${MGMT_BR}'.${CL}"
    echo -e "${YW}[i] Continuing if internal repo/proxy is configured...${CL}"
fi

# 6. Execute Zabbix 8.0 Installation Inside Container
echo -e "${BL}[*] Installing PostgreSQL 17, Zabbix 8.0, Agent 2, and Web Frontend...${CL}"

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/install/install_zabbix.sh"

if [[ ! -f "$SCRIPT_PATH" ]]; then
    INSTALL_URL="https://raw.githubusercontent.com/hubertges/proxmox-scripts/main/install/install_zabbix.sh"
    echo -e "${YW}[*] Local installer not found, fetching from GitHub (${INSTALL_URL})...${CL}"
    SCRIPT_PATH="/tmp/install_zabbix.sh"
    curl -fsSL "$INSTALL_URL" -o "$SCRIPT_PATH" 2>/dev/null || wget -qO "$SCRIPT_PATH" "$INSTALL_URL"
fi

if [[ -f "$SCRIPT_PATH" ]]; then
    pct push "$CTID" "$SCRIPT_PATH" /tmp/install_zabbix.sh
    # Pass optional DB password from .env if set
    if [[ -n "${ZABBIX_DB_PASSWORD:-}" ]]; then
        pct exec "$CTID" -- env ZABBIX_DB_PASSWORD="${ZABBIX_DB_PASSWORD}" bash /tmp/install_zabbix.sh
    else
        pct exec "$CTID" -- bash /tmp/install_zabbix.sh
    fi
    pct exec "$CTID" -- rm -f /tmp/install_zabbix.sh
else
    echo -e "${RD}[!] Installer script not found at ${SCRIPT_PATH}!${CL}" >&2
    exit 1
fi

echo -e "\n${GN}========================================================================${CL}"
echo -e "${GN}  Zabbix 8.0 LTS LXC Container Deployed! [CTID: ${CTID}]                 ${CL}"
echo -e "${GN}========================================================================${CL}"
echo -e "Network Bridge:       ${BL}${MGMT_BR}${CL} (Reverse Proxy Backend Network)"
echo -e "Static IPv4 Address:  ${BL}${CT_IP}${CL}"
[[ -n "${CT_IP_V6:-}" ]] && echo -e "Static IPv6 Address:  ${BL}${CT_IP_V6}${CL}"
echo -e "Internal Web GUI:     ${BL}http://${CT_IP}:8080${CL}"
echo -e "Default Web Login:    ${YW}Admin${CL} / ${YW}zabbix${CL}"
echo -e "Zabbix Server Port:   ${BL}${CT_IP}:10051 (TCP)${CL}"
echo -e "Console Access:       ${BL}pct enter ${CTID}${CL}"
echo -e "\n${YW}--> External Nginx Configuration (ProxNET):${CL}"
echo -e "Nginx reverse proxy configuration template for your Nginx container:"
echo -e "${BL}${REPO_DIR}/system-config/nginx-zabbix-reverse-proxy.conf${CL}"
echo -e "Add it to ${YW}/etc/nginx/conf.d/zabbix.conf${CL} on your Nginx container with:"
echo -e "  ${BL}server ${CT_IP}:8080;${CL}\n"
