# Proxmox VE Automation & Lab Helper Scripts 🚀

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Proxmox VE](https://img.shields.io/badge/Proxmox%20VE-8.x%20%7C%209.x-E57000?logo=proxmox&logoColor=white)](https://www.proxmox.com)
[![Proxmox Backup Server](https://img.shields.io/badge/PBS-Compatible-orange?logo=proxmox&logoColor=white)](https://www.proxmox.com/en/proxmox-backup-server)
[![Debian](https://img.shields.io/badge/Debian-12%20%7C%2013-A81D33?logo=debian&logoColor=white)](https://www.debian.org)
[![Bash](https://img.shields.io/badge/Language-Bash%20%2F%20Shell-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)

A modular toolkit of automated deployment scripts, LXC security hardening & onboarding, host bare-metal backups to Proxmox Backup Server (PBS), and hypervisor tuning for **Proxmox Virtual Environment (PVE 8.x / 9.x)** and clusters.

---

## 📋 Table of Contents

- [Overview](#overview)
- [Repository Structure](#repository-structure)
- [Security & Environment Variables (.env)](#security--environment-variables-env)
- [Included Scripts & Modules](#included-scripts--modules)
  - [1. Host Bare-Metal Backups to PBS (`backup/`)](#1-host-bare-metal-backups-to-pbs-backup)
  - [2. LXC Provisioning & Security Hardening (`provisioning/`)](#2-lxc-provisioning--security-hardening-provisioning)
  - [3. Virtual Machines (`vms/`)](#3-virtual-machines-vms)
  - [4. Dedicated LXC Containers (`ct/`)](#4-dedicated-lxc-containers-ct)
  - [5. Guest Appliance Installers (`install/`)](#5-guest-appliance-installers-install)
  - [6. Multi-Node Distributed Deployments (`distributed/`)](#6-multi-node-distributed-deployments-distributed)
  - [7. System Tuning & DPDK Utilities (`system-config/`)](#7-system-tuning--dpdk-utilities-system-config)
- [Cluster Deployment Guide (/etc/pve/scripts/)](#cluster-deployment-guide-etcpvescripts)
- [Quickstart & Usage Examples](#quickstart--usage-examples)
- [License](#license)

---

## 🌐 Overview

This repository provides centralized, cluster-aware management scripts for Proxmox VE nodes:
1. **Automated Bare-Metal Host Backups** to Proxmox Backup Server (PBS) with client-side encryption and hook integration into scheduled `vzdump` jobs.
2. **Batch LXC Provisioning & Hardening** with automatic APT source modernization, post-quantum SSH hardening, user isolation, Chrony sync, and automatic Wazuh Agent onboarding.
3. **High-Performance Traffic Generators & Router DUTs** (Cisco TRex line-rate packet generator, VyOS, OpenWrt, MikroTik CHR).
4. **Security & Telemetry Appliances** (ProjectDiscovery Nuclei scanner, SNMP/Syslog collector, Wazuh 5 Beta).

---

## 📁 Repository Structure

```text
proxmox-scripts/
├── .env.example                  # Environment configuration template (never commit real .env!)
├── .gitignore                    # Strictly ignores .env, secret files, keys, and credentials
├── LICENSE                       # MIT License
├── README.md                     # Documentation and user guide
├── backup/
│   ├── pbs-host-backup.sh        # Standalone bare-metal host backup to Proxmox Backup Server
│   ├── pbs-host-backup-hook.sh   # Dynamic vzdump hook script (runs host backup on job-start)
│   └── vzdump-wrapper.sh         # vzdump hook wrapper calling the cluster hook script
├── provisioning/
│   ├── autoinstall.sh            # Batch LXC provisioner & hardening engine
│   ├── lxc-auto-provision-watcher.sh # Background watcher daemon for newly started containers
│   ├── lxc-provision-hook.sh     # Proxmox container hookscript (alternative to daemon)
│   ├── nowykontener.sh           # Single LXC provisioner & hardening script (Wazuh v5, host-managed clock)
│   ├── setup_lxc.sh -> nowykontener.sh # Convenience symlink
│   └── update_wazuh_agent_v5.sh  # Automated Wazuh Agent v5 upgrade suite (Host, LXC, VM)
├── scripts/
│   ├── autoinstall.sh            # Host wrapper forwarding to /etc/pve/scripts/autoinstall.sh
│   ├── lxc-auto-provision-watcher.sh # Host wrapper forwarding to lxc-auto-provision-watcher.sh
│   ├── nowykontener.sh           # Host wrapper forwarding to nowykontener.sh
│   └── update_wazuh_agent_v5.sh  # Host wrapper forwarding to update_wazuh_agent_v5.sh
├── vms/
│   ├── create_trex_vm.sh         # Deploy Cisco TRex generator VM with Cloud-Init & DPDK tuning
│   └── create_dut_vm.sh          # Deploy Router DUT VM (VyOS, OpenWrt, MikroTik, Debian)
├── ct/
│   ├── create_snmp_lxc.sh        # Deploy SNMP & Syslog Telemetry Collector LXC
│   ├── create_nuclei_lxc.sh      # Deploy ProjectDiscovery Nuclei Scanner LXC
│   ├── create_zabbix_lxc.sh      # Deploy Zabbix 8.0 LTS + PostgreSQL 17 LXC (Debian 13)
│   ├── zabbix.sh                 # Zabbix 8.0 LXC (Community-Scripts format)
│   └── wazuh.sh                  # Deploy Wazuh 5 Beta All-in-One LXC
├── install/
│   ├── install_trex.sh           # TRex DPDK installation & systemd daemon setup
│   ├── install_snmp_collector.sh # SNMP daemon & syslog poller setup
│   ├── install_nuclei.sh         # Nuclei scanner & templates setup
│   ├── install_zabbix.sh         # Zabbix 8.0 + PostgreSQL 17 installer for Debian 13
│   └── wazuh-install.sh          # Wazuh 5 container install assistant
├── distributed/
│   └── wazuh5-distributed.sh     # Multi-node Wazuh 5 cluster installer
├── system-config/
│   ├── setup_sdn_cluster_net.sh  # Automated Proxmox SDN VNet (Wazuh-cluster-net, VLAN > 1500, 10.69.101.0/24)
│   ├── lxc-auto-provision.service# Systemd service unit for automated LXC provisioning watcher
│   ├── nginx-zabbix-reverse-proxy.conf # Production Nginx reverse proxy configuration for Zabbix
│   ├── dpdk-bind.sh              # Automated DPDK driver binding utility (vfio-pci)
│   ├── cpu-affinity.conf         # CPU pinning and core isolation settings
│   ├── grub-tuning.conf          # Kernel boot parameters (isolcpus, default_hugepagesz)
│   ├── hugepages.conf            # Hugepages allocation configuration
│   └── trex_cfg.yaml.template    # TRex dual-port DPDK configuration template
└── docs/
    └── PROXMOX_GUIDE.md          # Comprehensive PVE hypervisor DPDK/SR-IOV tuning guide
```

---

## 🔐 Security & Environment Variables (.env)

> [!IMPORTANT]
> **Never commit your `.env` file to Git!**
> All real tokens, passwords, encryption keys, and internal domains are kept strictly in your local `.env`.
> The `.gitignore` file enforces this rule across all branches.

All scripts feature a cluster-aware `load_env` function that checks the following locations in order:
1. `$(dirname "$0")/.env` (current script directory)
2. `$(dirname "$0")/../.env` (parent repository directory)
3. `/etc/pve/scripts/.env` (central shared cluster directory)
4. `/etc/pve/secrets/.env` (protected cluster secrets directory)
5. `/etc/pve/.env`
6. `$HOME/.env`

### Setting up `.env`:
```bash
cp .env.example .env
nano .env
```

---

## 💻 Included Scripts & Modules

### 1. Host Bare-Metal Backups to PBS (`backup/`)

- **`backup/pbs-host-backup.sh`**:
  - Performs root filesystem (`/`) and `/etc/pve` backup to Proxmox Backup Server using `proxmox-backup-client`.
  - Supports client-side AES-GCM encryption with `--crypt-mode encrypt --keyfile "$PBS_KEYFILE"`.
  - Backs up into a designated PBS namespace (e.g. `BareMetal`).
  - Automatically excludes `/dev`, `/proc`, `/sys`, `/run`, `/var/lib/lxc`, `/var/lib/vz`, `/mnt/pve`, and caches.
  - Sourced from `.env`: `PBS_REPOSITORY`, `PBS_PASSWORD`, `PBS_FINGERPRINT`, `PBS_KEYFILE`, `PBS_NAMESPACE`.

- **`backup/pbs-host-backup-hook.sh` & `backup/vzdump-wrapper.sh`**:
  - Integration with Proxmox scheduled backup jobs (`vzdump`).
  - Executes during the `job-start` phase, backing up the hypervisor host right as the container/VM backup job begins.
  - Dynamically reads the node hostname (`$(hostname)`).

### 2. LXC Provisioning & Wazuh Agent v5 Upgrade Suite (`provisioning/`)

- **`provisioning/update_wazuh_agent_v5.sh`** (Host, LXC, KVM VMs):
  - **Comprehensive Multi-Target Upgrade**: Upgrades the Proxmox host hypervisor, all running LXC containers, and all running QEMU KVM VMs (via QEMU Guest Agent) to the latest **Wazuh Agent v5** (`5.0.0-beta5` or version set in `.env`).
  - **Local Host Caching**: Downloads official `.deb` and `.rpm` packages once to `/tmp/wazuh5_agent_cache/` on the host, pushing them into containers and VMs without wasting bandwidth.
  - **Configuration Preservation**: Preserves existing `ossec.conf` while ensuring manager registration to `$WAZUH_MANAGER` and group `$WAZUH_AGENT_GROUP`.
  - **Audit & Status Mode (`--status`)**: Produces a clean tabular report of current Wazuh Agent versions and active/inactive states across host, containers, and VMs.
  - **Flexible CLI Targeting**:
    - `--all`: Upgrade host, containers, and VMs in one command.
    - `--host`: Upgrade host hypervisor node only.
    - `--ct [CTID ...]`: Upgrade all running or specified LXC containers.
    - `--vm [VMID ...]`: Upgrade all running or specified KVM virtual machines.
    - `--force`: Reinstall or force upgrade even if already at v5.
    - `--dry-run`: Simulate upgrades without modifying packages.

- **`provisioning/nowykontener.sh`** (Single container) & **`provisioning/autoinstall.sh`** (Batch mode):
  - **Universal Multi-Distro Support ("Distrohopping-Proof")**:
    - **Debian / Ubuntu family**: Debian 11/12/13/sid, Ubuntu 20.04/22.04/24.04/24.10, TurnKey Linux, Linux Mint, Pop!_OS, Kali Linux, ParrotOS, Devuan.
    - **RHEL / Fedora family**: Fedora, Rocky Linux 8/9, AlmaLinux 8/9, CentOS Stream 9, RHEL, Oracle Linux.
    - **SUSE family**: openSUSE Leap 15.x, openSUSE Tumbleweed, SUSE Linux Enterprise (SLES).
    - **Arch family**: Arch Linux, Manjaro, EndeavourOS.
    - **Alpine Linux**: Alpine 3.18+, edge (with OpenRC init support).
    - **Generic Linux fallback**: Dynamically inspects `/etc/os-release`, package managers (`apt`, `dnf`, `zypper`, `pacman`, `apk`), and init systems.
  - **SSH Hardening**: Disables root login (`PermitRootLogin no`), disables password login (`PasswordAuthentication no`), enables post-quantum key exchange (`sntrup761x25519-sha512@openssh.com`) and ED25519.
  - **User & Sudo Configuration**: Dynamically creates administrative user (e.g., `hubi`) with correct distro sudo groups (`sudo` vs `wheel`), prefers `fish` shell with fallback to `bash`/`sh`. Supports non-interactive automated password generation when run in background.
  - **System Hardening**: Installs firewall (`ufw` or `firewalld`), intrusion prevention (`fail2ban`), unattended updates, and integrity tools according to distro ecosystem.
  - **Wazuh Agent v5 Integration**: Automatically selects and caches either `.deb` or `.rpm` packages on the Proxmox host, pushes to the container, and installs via native package manager (`dpkg`, `rpm`, `dnf`, `zypper`).
  - **Host-Managed Clock (No Guest NTP)**: Disables and masks redundant NTP services (`chrony`, `systemd-timesyncd`, `ntpd`, OpenRC `chronyd`) inside containers. Linux containers directly share the hypervisor kernel clock, avoiding capability errors and redundant external NTP lookups.
  - **State Tracking**: Statically marks configured containers with `/etc/.lxc_provisioned` and records credentials in `$HASLA_FILE` (`/etc/pve/secrets/.hasla`).

- **`provisioning/lxc-auto-provision-watcher.sh`** & **`system-config/lxc-auto-provision.service`**:
  - **Automated Container Onboarding Daemon**: Continuously watches for newly created and started LXC containers across all Linux distributions.
  - **Zero-Touch Provisioning**: As soon as a new container boots and reaches operational readiness (systemd or OpenRC initialized, package locks released), the daemon automatically runs `nowykontener.sh` in the background.
  - **Universal Lock Detection**: Proactively detects locks across APT/dpkg, RPM/dnf, Pacman, and APK before attempting package installation.
  - **Failure Backoff**: Implements smart retry cooldowns to avoid spinning on containers experiencing transient issues.
  - **Systemd Integration**: Provided as a system service for unattended background operation across node reboots.

- **`provisioning/lxc-provision-hook.sh`**:
  - Proxmox container hookscript (`pct set <CTID> -hookscript ...`) responding to the `post-start` lifecycle event as an alternative to the systemd daemon.

### 3. Virtual Machines (`vms/`)

- **`vms/create_trex_vm.sh`**: Cisco TRex traffic generator VM with Debian 13 cloud image, NUMA, 2M hugepages, multiqueue VirtIO, and isolated measurement bridges (`vmbr10`/`vmbr20`).
- **`vms/create_dut_vm.sh`**: Router Device Under Test (DUT) deployment for VyOS, OpenWrt, MikroTik RouterOS v7 CHR, or Debian.

### 4. Dedicated LXC Containers (`ct/`) & Network Architecture

> [!NOTE]
> **ProxNET & Automatic Static IP Freezing**:
> All container creation helper scripts default to network bridge **`ProxNET`** (designed for backend application containers sitting behind an Nginx Reverse Proxy).
> Containers initially acquire dynamic IPv4 (DHCP) and IPv6 (SLAAC/DHCPv6) addresses on boot, and then the helper scripts automatically freeze those exact addresses and default gateways into permanent **STATIC** configurations in Proxmox VE (`pct set <CTID> -net0 ...`).

- **`ct/create_snmp_lxc.sh`**: Debian LXC collector for SNMP traps (port 162) and Syslog (port 514).
- **`ct/create_nuclei_lxc.sh`**: ProjectDiscovery Nuclei vulnerability scanner LXC with official templates.
- **`ct/create_zabbix_lxc.sh`** & **`ct/zabbix.sh`**:
  - Deploys a dedicated **Zabbix 8.0 LTS** monitoring container on **Debian 13 (Trixie)** with **PostgreSQL 17**.
  - Includes Zabbix Server 8.0 daemon, PostgreSQL 17 database with automated schema initialization, Zabbix Agent 2, and pre-configured PHP 8.4 frontend.
  - Exposes the internal web interface on port `8080` (ready for reverse proxying) and server trapper on port `10051`.
- **`ct/wazuh.sh`**: Wazuh 5 Beta All-in-One LXC in Proxmox Community Helper Scripts format.

### 5. Distributed Clusters & SDN Networking (`distributed/` & `system-config/`)

- **`system-config/setup_sdn_cluster_net.sh`**:
  - Automates the provisioning of an isolated Proxmox Software Defined Network (SDN) VNet:
    - **SDN Zone**: `ClusterZone` (VLAN mode on `ProxNET`)
    - **SDN VNet**: `wazuhcl` (Alias: `Wazuh-cluster-net`)
    - **802.1Q VLAN**: Tag `1669` (VLAN > 1500 for strict cluster isolation)
    - **Cluster Subnet**: `10.69.101.0/24` (Gateway: `10.69.101.1`), with reserved address space from `10.69.101.0/24` to `10.69.250.0/24` for multi-node service and cluster expansion.
    - Commits and executes `pvesdn reload`.

- **`distributed/wazuh5-distributed.sh`**:
  - Deploys a production-grade 3-node **Wazuh 5.0 Beta 5** cluster across dedicated LXC containers (Indexer, Manager, Dashboard).
  - **Dual-Homed Network Architecture**:
    - **`net0` (Frontend / Reverse Proxy)**: Connected to bridge `ProxNET`, acquires dynamic IPv4/IPv6 leases and automatically freezes them to static IPs.
    - **`net1` (Cluster SDN Fabric)**: Connected to SDN VNet `wazuhcl` (or tagged VLAN 1669 fallback) with dedicated static IPs:
      - **Wazuh Indexer**: `10.69.101.10/24`
      - **Wazuh Manager**: `10.69.101.11/24`
      - **Wazuh Dashboard**: `10.69.101.12/24`
    - Wazuh node-to-node TLS certificates and internal communication (`config.yml`) bind strictly to the high-speed SDN cluster network (`10.69.101.X`), isolating internal OpenSearch replication and event indexing from frontend traffic.

### 6. Guest Appliance Installers (`install/`)

- **`install/install_zabbix.sh`**: Idempotent installer for Zabbix 8.0 LTS, PostgreSQL 17, locales, DB schema import, automated `/etc/zabbix/web/zabbix.conf.php` generation, and external Nginx reverse proxy template generation.
- **`install/install_trex.sh`**: TRex DPDK installation & systemd daemon setup.
- **`install/install_snmp_collector.sh`**: SNMP daemon & syslog poller setup.
- **`install/install_nuclei.sh`**: Nuclei scanner & templates setup.
- **`install/wazuh-install.sh`**: Wazuh 5 container install assistant.


---

## 🏛️ Cluster Deployment Guide (`/etc/pve/scripts/`)

In a multi-node Proxmox VE cluster, `/etc/pve/` is synchronized across all cluster nodes via `pmxcfs`. Deploying your scripts and `.env` to `/etc/pve/scripts/` makes them immediately available on every hypervisor node in the cluster.

```bash
# 1. Create central script directory on any cluster node:
mkdir -p /etc/pve/scripts /etc/pve/secrets

# 2. Copy scripts from this repository:
cp backup/* /etc/pve/scripts/
cp provisioning/* /etc/pve/scripts/

# 3. Create cluster environment file:
cp .env.example /etc/pve/scripts/.env
nano /etc/pve/scripts/.env

# 4. Secure the cluster secrets:
chmod 600 /etc/pve/scripts/.env
chmod 700 /etc/pve/secrets

# 5. Set up the vzdump backup hook in /etc/vzdump.conf (on each node or globally):
echo "script: /etc/pve/scripts/vzdump-wrapper.sh" >> /etc/vzdump.conf
```

---

## 🚀 Quickstart & Usage Examples

### Run Bare-Metal Host Backup to PBS:
```bash
bash backup/pbs-host-backup.sh
```

### Provision and Harden a Single LXC Container:
```bash
bash provisioning/nowykontener.sh 105
```

### Batch Provision All Unconfigured Running Containers:
```bash
bash provisioning/autoinstall.sh
```

### Batch Provision Specific Containers:
```bash
bash provisioning/autoinstall.sh 101 102 103
```

### Run LXC Auto-Provision Watcher (One-shot check):
```bash
bash provisioning/lxc-auto-provision-watcher.sh --run-once
```

### Run LXC Auto-Provision Watcher as Background Daemon:
```bash
bash provisioning/lxc-auto-provision-watcher.sh --daemon
```

### Install and Enable LXC Auto-Provision Systemd Service:
```bash
# Copy systemd service and reload
cp system-config/lxc-auto-provision.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now lxc-auto-provision.service

# Check watcher status and logs
systemctl status lxc-auto-provision.service
journalctl -u lxc-auto-provision.service -f
# or check dedicated log
tail -f /var/log/lxc-auto-provision.log
```

### Audit Wazuh Agent Versions Across Host, LXCs, and VMs:
```bash
bash provisioning/update_wazuh_agent_v5.sh --status
```

### Upgrade Wazuh Agent to v5 Across Everything (Host, All LXCs, All VMs):
```bash
bash provisioning/update_wazuh_agent_v5.sh --all
```

### Deploy Zabbix 8.0 LTS LXC Container (Debian 13 Trixie + PostgreSQL 17):
```bash
bash ct/create_zabbix_lxc.sh
```

### Configure External Nginx Reverse Proxy (on your other Nginx container):
```bash
# 1. Copy the reverse proxy template to your existing Nginx container:
pct push <NGINX_CTID> system-config/nginx-zabbix-reverse-proxy.conf /etc/nginx/conf.d/zabbix.conf

# 2. Update the upstream IP to match your newly deployed Zabbix LXC IP:
pct exec <NGINX_CTID> -- sed -i 's/<ZABBIX_CONTAINER_IP>/<YOUR_ZABBIX_IP>/g' /etc/nginx/conf.d/zabbix.conf

# 3. Test and reload Nginx:
pct exec <NGINX_CTID> -- nginx -t && pct exec <NGINX_CTID> -- systemctl reload nginx
```

### Setup Proxmox Software Defined Network (SDN) Cluster Network:
```bash
# Creates SDN Zone, VNet 'wazuhcl' (Wazuh-cluster-net, VLAN 1669), and Subnet 10.69.101.0/24
bash system-config/setup_sdn_cluster_net.sh
```

### Deploy Wazuh 5.0 Beta 5 Distributed Cluster (3 Containers with Dual Networks):
```bash
# Creates Indexer, Manager, and Dashboard on ProxNET + Wazuh-cluster-net SDN
bash distributed/wazuh5-distributed.sh
```

### Deploy ProjectDiscovery Nuclei Scanner LXC:
```bash
bash ct/create_nuclei_lxc.sh
```

### Deploy SNMP & Syslog Telemetry Collector LXC:
```bash
bash ct/create_snmp_lxc.sh
```

---

## 📄 License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.
