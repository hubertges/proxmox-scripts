#!/usr/bin/env bash
# ==============================================================================
# install/install_snmp_collector.sh
# Automated, Idempotent SNMP & Syslog Telemetry Collector for Debian (12/13)
# Designed for dedicated management/administrative LXC container or VM
#
# Academic Research Project:
# "Analiza porównawcza wydajności i funkcjonalności rozwiązań sieciowych
#  klasy SOHO i Enterprise w kontekście współczesnych standardów bezpieczeństwa"
# ==============================================================================

set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()    { echo -e "\n${BOLD}${BLUE}===> $1${NC}"; }

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be executed with root privileges. Run with 'sudo bash $0'."
    exit 1
fi

log_step "1. Updating Repositories and Installing SNMP & Telemetry Packages"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y

PACKAGES=(
    snmp
    snmpd
    snmptrapd
    rsyslog
    curl
    wget
    jq
    python3
    python3-pip
    python3-venv
    logrotate
    iproute2
    net-tools
)

apt-get install -y --no-install-recommends "${PACKAGES[@]}"
log_success "Packages installed successfully."

# ------------------------------------------------------------------------------
# 2. Directory Structure Setup
# ------------------------------------------------------------------------------
log_step "2. Setting up Logging Directories"

LOG_DIR="/var/log/snmp"
ROUTER_LOG_DIR="/var/log/routers"
mkdir -p "$LOG_DIR" "$ROUTER_LOG_DIR"
chmod 755 "$LOG_DIR" "$ROUTER_LOG_DIR"

# ------------------------------------------------------------------------------
# 3. SNMP Trap Handler Configuration (/usr/local/bin/snmp_trap_handler.sh)
# ------------------------------------------------------------------------------
log_step "3. Creating Automated SNMP Trap Handler"

cat << 'EOF' > /usr/local/bin/snmp_trap_handler.sh
#!/usr/bin/env bash
# /usr/local/bin/snmp_trap_handler.sh
# Handles incoming SNMP traps from DUT routers and writes structured JSON & log
set -euo pipefail

LOG_FILE="/var/log/snmp/traps.log"
JSON_FILE="/var/log/snmp/traps.json"

read -r HOST_IP
read -r IP_INFO

# Read OID and value pairs
VARBINDS=""
while read -r OID VAL; do
    if [[ -n "$OID" ]]; then
        VARBINDS="${VARBINDS}${OID} = ${VAL}; "
    fi
done

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Write formatted human-readable entry
echo "[${TIMESTAMP}] TRAP from ${HOST_IP} (${IP_INFO}) | Details: ${VARBINDS}" >> "$LOG_FILE"

# Write structured JSON entry for academic metrics ingestion
jq -c -n \
    --arg ts "$TIMESTAMP" \
    --arg host "$HOST_IP" \
    --arg ipinfo "$IP_INFO" \
    --arg details "$VARBINDS" \
    '{timestamp: $ts, source_host: $host, transport_info: $ipinfo, varbinds: $details}' >> "$JSON_FILE"

exit 0
EOF

chmod +x /usr/local/bin/snmp_trap_handler.sh
log_success "Created /usr/local/bin/snmp_trap_handler.sh."

# ------------------------------------------------------------------------------
# 4. Configuring snmptrapd (/etc/snmp/snmptrapd.conf)
# ------------------------------------------------------------------------------
log_step "4. Configuring SNMP Trap Receiver (snmptrapd)"

# Supports both SNMPv2c (community: lab_telemetry / public)
# and secure SNMPv3 (SHA auth + AES priv) per NIS2 / KSC standards
cat << 'EOF' > /etc/snmp/snmptrapd.conf
# /etc/snmp/snmptrapd.conf
# Net-SNMP Trap Daemon Configuration for Router Telemetry

# Disable DNS reverse lookup for minimal latency
doNotLogTraps no
doNotFork no

# SNMPv2c Communities (ReadOnly for Traps)
authCommunity log,execute,net lab_telemetry
authCommunity log,execute,net public

# SNMPv3 User Configuration (AuthPriv: SHA + AES)
# Conforms to Polish KSC / NIS2 Article 21 encryption requirements
# Format: createUser -e <engine_id> <username> SHA <auth_pass> AES <priv_pass>
createUser -e 0x8000000001020304 secadmin SHA labAuthPass123! AES labPrivPass123!
authUser log,execute,net secadmin priv

# Pass all received traps (default) to our handler script
traphandle default /usr/local/bin/snmp_trap_handler.sh
EOF

# Ensure snmptrapd listens on all interfaces (UDP 162)
cat << 'EOF' > /etc/default/snmptrapd
# Options for snmptrapd
TRAPDOPTS='-On -p /run/snmptrapd.pid udp:162'
EOF

systemctl daemon-reload
systemctl enable --now snmptrapd
log_success "snmptrapd configured and activated on UDP 162."

# ------------------------------------------------------------------------------
# 5. Configuring Centralized Syslog Receiver (rsyslog on UDP/TCP 514)
# ------------------------------------------------------------------------------
log_step "5. Configuring rsyslog Centralized Logging for Routers"

cat << 'EOF' > /etc/rsyslog.d/50-router-telemetry.conf
# /etc/rsyslog.d/50-router-telemetry.conf
# Centralized Syslog Receiver for DUT Routers (Cisco, UniFi, Palo Alto, OpenWrt, VyOS)

# Provide UDP syslog reception
module(load="imudp")
input(type="imudp" port="514")

# Provide TCP syslog reception
module(load="imtcp")
input(type="imtcp" port="514")

# Dynamic template: store logs in /var/log/routers/<remote_ip>.log
$template RouterLogFile,"/var/log/routers/%fromhost-ip%.log"

# Route incoming traffic from remote router hosts to dynamic files
if ($fromhost-ip != '127.0.0.1') then ?RouterLogFile
& stop
EOF

systemctl restart rsyslog
log_success "rsyslog configured to accept router syslog events on UDP/TCP 514."

# ------------------------------------------------------------------------------
# 6. Periodic SNMP Router Poller Daemon (/usr/local/bin/snmp_router_poller.py)
# ------------------------------------------------------------------------------
log_step "6. Creating Periodic SNMP Telemetry Poller"

cat << 'EOF' > /usr/local/bin/snmp_router_poller.py
#!/usr/bin/env python3
"""
Periodic SNMP Poller for DUT Routers
Polls CPU utilization, memory consumption, and 64-bit interface throughput counters
from target routers (Cisco, Palo Alto, UniFi, OpenWrt, VyOS, MikroTik).
Outputs time-series metrics to /var/log/snmp/router_metrics.csv and JSON.
"""

import sys
import os
import time
import json
import subprocess
from datetime import datetime, timezone

METRICS_CSV = "/var/log/snmp/router_metrics.csv"
METRICS_JSON = "/var/log/snmp/router_metrics.json"
CONFIG_FILE = "/etc/snmp/monitored_routers.json"

DEFAULT_ROUTERS = [
    {"name": "DUT-Router", "ip": "198.18.1.1", "community": "lab_telemetry", "type": "generic"}
]

# Standard SNMP OIDs
OID_SYS_UPTIME = "1.3.6.1.2.1.1.3.0"
OID_CPU_LOAD_HR = "1.3.6.1.2.1.25.3.3.1.2.1"     # Host Resources MIB CPU
OID_CISCO_CPU_5M = "1.3.6.1.4.1.9.9.109.1.1.1.1.5.1" # Cisco cpmCPUTotal5minRev
OID_IF_IN_OCTETS = "1.3.6.1.2.1.31.1.1.1.6.1"   # ifHCInOctets (64-bit Port 1)
OID_IF_OUT_OCTETS = "1.3.6.1.2.1.31.1.1.1.10.1" # ifHCOutOctets (64-bit Port 1)

def get_snmp_value(ip, community, oid):
    """Executes snmpget via subprocess for maximum compatibility without extra C-libs."""
    try:
        cmd = ["snmpget", "-v2c", "-c", community, "-Oqv", "-t", "1", "-r", "1", ip, oid]
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=2)
        if res.returncode == 0:
            return res.stdout.strip()
    except Exception:
        pass
    return "0"

def init_csv():
    if not os.path.exists(METRICS_CSV):
        with open(METRICS_CSV, "w") as f:
            f.write("timestamp,router_name,router_ip,cpu_load_pct,if_in_bytes,if_out_bytes\n")

def poll_once(routers):
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    for r in routers:
        ip = r["ip"]
        comm = r.get("community", "lab_telemetry")
        name = r.get("name", ip)

        # Query CPU (try Cisco specific, fallback to Host Resources)
        cpu = get_snmp_value(ip, comm, OID_CISCO_CPU_5M)
        if not cpu.isdigit() or cpu == "0":
            cpu = get_snmp_value(ip, comm, OID_CPU_LOAD_HR)
        cpu_val = int(cpu) if cpu.isdigit() else 0

        in_octets = get_snmp_value(ip, comm, OID_IF_IN_OCTETS)
        out_octets = get_snmp_value(ip, comm, OID_IF_OUT_OCTETS)

        in_b = int(in_octets) if in_octets.isdigit() else 0
        out_b = int(out_octets) if out_octets.isdigit() else 0

        # Log to CSV
        with open(METRICS_CSV, "a") as f:
            f.write(f"{ts},{name},{ip},{cpu_val},{in_b},{out_b}\n")

        # Log to JSON lines
        entry = {
            "timestamp": ts,
            "router_name": name,
            "router_ip": ip,
            "cpu_load_pct": cpu_val,
            "if_in_bytes": in_b,
            "if_out_bytes": out_b
        }
        with open(METRICS_JSON, "a") as f:
            f.write(json.dumps(entry) + "\n")

def main():
    init_csv()
    routers = DEFAULT_ROUTERS
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r") as f:
                routers = json.load(f)
        except Exception as e:
            print(f"Error loading {CONFIG_FILE}: {e}")

    print(f"[*] SNMP Poller active for {len(routers)} router(s). Polling every 5 seconds...")
    while True:
        try:
            poll_once(routers)
        except Exception as e:
            print(f"[!] Polling cycle error: {e}")
        time.sleep(5)

if __name__ == "__main__":
    main()
EOF

chmod +x /usr/local/bin/snmp_router_poller.py

# Create default configuration file
cat << 'EOF' > /etc/snmp/monitored_routers.json
[
  {
    "name": "DUT_Cisco_IOSXE",
    "ip": "198.18.1.1",
    "community": "lab_telemetry",
    "type": "cisco"
  },
  {
    "name": "DUT_UniFi_UDM",
    "ip": "198.18.1.1",
    "community": "lab_telemetry",
    "type": "unifi"
  },
  {
    "name": "DUT_PaloAlto_PA",
    "ip": "198.18.1.1",
    "community": "lab_telemetry",
    "type": "paloalto"
  },
  {
    "name": "DUT_OpenWrt_Node",
    "ip": "198.18.1.1",
    "community": "lab_telemetry",
    "type": "openwrt"
  }
]
EOF

# Create systemd service for poller
cat << 'EOF' > /etc/systemd/system/snmp-router-poller.service
[Unit]
Description=SNMP Periodic Router Telemetry Poller
After=network.target snmptrapd.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/snmp_router_poller.py
Restart=always
RestartSec=10s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now snmp-router-poller.service
log_success "SNMP Poller daemon installed and activated as systemd service."

# ------------------------------------------------------------------------------
# 7. Log Rotation Configuration
# ------------------------------------------------------------------------------
log_step "7. Configuring Logrotate"

cat << 'EOF' > /etc/logrotate.d/snmp-telemetry
/var/log/snmp/*.log /var/log/snmp/*.json /var/log/snmp/*.csv /var/log/routers/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOF

log_step "SNMP & Syslog Telemetry Collector Installation Completed!"
cat << EOF

Summary of Deployed Services:
- SNMP Trap Receiver (snmptrapd):   Port UDP 162 (SNMPv2c 'lab_telemetry' & SNMPv3 'secadmin')
- Trap Handler Script:              /usr/local/bin/snmp_trap_handler.sh
- Traps Log:                        /var/log/snmp/traps.log and traps.json
- Central Syslog (rsyslog):         Port UDP 514 and TCP 514
- Router Syslogs:                   /var/log/routers/<router_ip>.log
- Active SNMP Poller Daemon:        /usr/local/bin/snmp_router_poller.py (systemd: snmp-router-poller)
- Monitored Routers Config:         /etc/snmp/monitored_routers.json
- Polled Metrics Output:            /var/log/snmp/router_metrics.csv and .json

EOF
