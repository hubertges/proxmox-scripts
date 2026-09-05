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
│   ├── nowykontener.sh           # Single LXC provisioner & hardening script
│   └── setup_lxc.sh -> nowykontener.sh # Convenience symlink
├── scripts/
│   └── autoinstall.sh            # Host wrapper forwarding to /etc/pve/scripts/autoinstall.sh
├── vms/
│   ├── create_trex_vm.sh         # Deploy Cisco TRex generator VM with Cloud-Init & DPDK tuning
│   └── create_dut_vm.sh          # Deploy Router DUT VM (VyOS, OpenWrt, MikroTik, Debian)
├── ct/
│   ├── create_snmp_lxc.sh        # Deploy SNMP & Syslog Telemetry Collector LXC
│   ├── create_nuclei_lxc.sh      # Deploy ProjectDiscovery Nuclei Scanner LXC
│   └── wazuh.sh                  # Deploy Wazuh 5 Beta All-in-One LXC
├── install/
│   ├── install_trex.sh           # TRex DPDK installation & systemd daemon setup
│   ├── install_snmp_collector.sh # SNMP daemon & syslog poller setup
│   ├── install_nuclei.sh         # Nuclei scanner & templates setup
│   └── wazuh-install.sh          # Wazuh 5 container install assistant
├── distributed/
│   └── wazuh5-distributed.sh     # Multi-node Wazuh 5 cluster installer
├── system-config/
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

### 2. LXC Provisioning & Security Hardening (`provisioning/`)

- **`provisioning/nowykontener.sh`** (Single container) & **`provisioning/autoinstall.sh`** (Batch mode):
  - **OS Compatibility**: Ubuntu, Debian 12 (Bookworm), Debian 13 (Trixie), TurnKey Linux.
  - **SSH Hardening**: Disables root login (`PermitRootLogin no`), disables password login (`PasswordAuthentication no`), enables post-quantum key exchange (`sntrup761x25519-sha512@openssh.com`) and ED25519.
  - **User Configuration**: Creates non-root administrative user (e.g., `hubi`), sets up Fish shell with `fastfetch` and `cowsay`/`fortune`.
  - **System Hardening**: Installs `ufw`, `fail2ban`, `unattended-upgrades`, `needrestart`, `debsums`, `rkhunter`.
  - **Wazuh Agent Integration**: Automatically downloads and installs `wazuh-agent`, connects to `WAZUH_MANAGER`, and assigns to `WAZUH_AGENT_GROUP`.
  - **Chrony & Clock**: Synchronizes chrony configuration and enables `-x` slew mode for LXC compatibility.
  - **Password Vault**: Automatically generates strong random root passwords and records them in `$HASLA_FILE` (`/etc/pve/secrets/.hasla`).

### 3. Virtual Machines (`vms/`)

- **`vms/create_trex_vm.sh`**: Cisco TRex traffic generator VM with Debian 13 cloud image, NUMA, 2M hugepages, multiqueue VirtIO, and isolated measurement bridges (`vmbr10`/`vmbr20`).
- **`vms/create_dut_vm.sh`**: Router Device Under Test (DUT) deployment for VyOS, OpenWrt, MikroTik RouterOS v7 CHR, or Debian.

### 4. Dedicated LXC Containers (`ct/`)

- **`ct/create_snmp_lxc.sh`**: Debian LXC collector for SNMP traps (port 162) and Syslog (port 514).
- **`ct/create_nuclei_lxc.sh`**: ProjectDiscovery Nuclei vulnerability scanner LXC with official templates.
- **`ct/wazuh.sh`**: Wazuh 5 Beta All-in-One LXC in Proxmox Community Helper Scripts format.

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

---

## 📄 License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.
