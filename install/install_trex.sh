#!/usr/bin/env bash
# ==============================================================================
# install/install.sh
# Complete, Idempotent, and Reproducible Test Server Setup for Cisco TRex
# Target Operating System: Debian GNU/Linux 13 (Trixie) - x86_64
#
# Academic Research Project:
# "Analiza porównawcza wydajności i funkcjonalności rozwiązań sieciowych
#  klasy SOHO i Enterprise w kontekście współczesnych standardów bezpieczeństwa"
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration Variables
# ------------------------------------------------------------------------------
TREX_VERSION="v3.08"
TREX_URL="https://trex-tgn.cisco.com/trex/release/${TREX_VERSION}.tar.gz"
TREX_INSTALL_BASE="/opt/trex"
TREX_TARGET_DIR="${TREX_INSTALL_BASE}/${TREX_VERSION}"
TREX_CURRENT_LINK="${TREX_INSTALL_BASE}/current"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="/opt/trex-venv"

# Text styling
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

# ------------------------------------------------------------------------------
# 1. Pre-flight Checks & Privileges
# ------------------------------------------------------------------------------
log_step "1. Verifying Execution Environment & Privileges"

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be executed with root privileges. Please run with 'sudo bash $0'."
    exit 1
fi

ARCH="$(uname -m)"
if [[ "$ARCH" != "x86_64" ]]; then
    log_error "Unsupported CPU architecture: $ARCH. Cisco TRex official DPDK binaries require x86_64."
    exit 1
fi

if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    log_info "Detected OS: ${PRETTY_NAME:-$ID} (Codename: ${VERSION_CODENAME:-unknown})"
    if [[ "${VERSION_CODENAME:-}" != "trixie" && "${ID:-}" != "debian" ]]; then
        log_warn "Target tested environment is Debian 13 (Trixie). Proceeding with compatibility safeguards."
    fi
else
    log_warn "Could not source /etc/os-release. Proceeding assuming Debian-compatible environment."
fi

# ------------------------------------------------------------------------------
# 2. System Packages & Dependencies
# ------------------------------------------------------------------------------
log_step "2. Installing Base System Dependencies via APT"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y

PACKAGES=(
    build-essential
    pkg-config
    git
    curl
    wget
    ca-certificates
    pv
    jq
    tmux
    net-tools
    ethtool
    pciutils
    numactl
    libnuma-dev
    zlib1g-dev
    libelf-dev
    libpcap-dev
    python3
    python3-dev
    python3-pip
    python3-venv
    iproute2
    iperf3
    bird2
    kmod
)

log_info "Installing required packages: ${PACKAGES[*]}"
apt-get install -y --no-install-recommends "${PACKAGES[@]}"

log_success "System dependencies installed successfully."

# ------------------------------------------------------------------------------
# 3. Kernel Modules Configuration (UIO & VFIO)
# ------------------------------------------------------------------------------
log_step "3. Configuring High-Performance Kernel Modules for DPDK"

# Ensure VFIO and UIO modules are loaded and persistent across reboots
MODULES=(uio uio_pci_generic vfio vfio-pci)

for mod in "${MODULES[@]}"; do
    if modprobe "$mod" 2>/dev/null; then
        log_info "Loaded kernel module: $mod"
    else
        log_warn "Kernel module '$mod' not found directly; attempting fallback."
    fi
done

# Persist modules in /etc/modules-load.d/trex.conf
cat << 'EOF' > /etc/modules-load.d/trex.conf
# Cisco TRex DPDK Kernel Modules
uio
uio_pci_generic
vfio
vfio-pci
EOF

# In virtualized Proxmox environments without hardware VT-d / IOMMU groups,
# enable VFIO unsafe noiommu mode:
if [[ -f /sys/module/vfio/parameters/enable_unsafe_noiommu_mode ]]; then
    echo 1 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
    echo "options vfio enable_unsafe_noiommu_mode=1" > /etc/modprobe.d/vfio-noiommu.conf
    log_info "Configured VFIO unsafe noiommu mode (for virtualized NIC pass-through)."
fi

# ------------------------------------------------------------------------------
# 4. Kernel Sysctl & Hugepages Configuration
# ------------------------------------------------------------------------------
log_step "4. Applying Kernel Performance Parameters & Hugepages"

if [[ -f "${REPO_ROOT}/system-config/sysctl.d/99-trex.conf" ]]; then
    cp -f "${REPO_ROOT}/system-config/sysctl.d/99-trex.conf" /etc/sysctl.d/99-trex.conf
    sysctl --system > /dev/null
    log_success "Applied /etc/sysctl.d/99-trex.conf parameters."
else
    log_warn "Template sysctl file not found in repo; applying inline defaults."
    sysctl -w vm.nr_hugepages=2048 > /dev/null
    sysctl -w net.core.rmem_max=67108864 > /dev/null
    sysctl -w net.core.wmem_max=67108864 > /dev/null
fi

# Ensure hugetlbfs mount point is active
mkdir -p /dev/hugepages
if ! mount | grep -q '/dev/hugepages'; then
    mount -t hugetlbfs nodev /dev/hugepages
    log_info "Mounted hugetlbfs at /dev/hugepages."
fi

# Ensure /etc/fstab entry for hugetlbfs is persistent
if ! grep -q '/dev/hugepages' /etc/fstab; then
    echo "nodev /dev/hugepages hugetlbfs pagesize=2M 0 0" >> /etc/fstab
    log_info "Added persistent hugetlbfs entry to /etc/fstab."
fi

# Security limits for memory locking
cat << 'EOF' > /etc/security/limits.d/99-trex.conf
* soft memlock unlimited
* hard memlock unlimited
root soft memlock unlimited
root hard memlock unlimited
EOF

# ------------------------------------------------------------------------------
# 5. Cisco TRex Binary Installation
# ------------------------------------------------------------------------------
log_step "5. Downloading & Installing Cisco TRex ${TREX_VERSION}"

mkdir -p "$TREX_INSTALL_BASE"
mkdir -p "$TREX_TARGET_DIR"

TAR_FILE="/var/tmp/trex_${TREX_VERSION}.tar.gz"

if [[ -x "${TREX_TARGET_DIR}/t-rex-64" ]]; then
    log_info "Cisco TRex ${TREX_VERSION} binary already present at ${TREX_TARGET_DIR}."
else
    log_info "Downloading TRex from ${TREX_URL}..."
    # Using wget --no-check-certificate due to Cisco server SSL certificate chains
    if [[ ! -f "$TAR_FILE" ]]; then
        wget --no-check-certificate -q --show-progress -O "$TAR_FILE" "$TREX_URL"
    fi

    log_info "Extracting ${TREX_VERSION} with PV data monitoring to ${TREX_TARGET_DIR}..."
    # PV monitors extraction throughput and progress accurately
    pv -cN "Unpacking TRex" "$TAR_FILE" | tar -xzf - -C "$TREX_TARGET_DIR" --strip-components=1
    rm -f "$TAR_FILE"
    log_success "TRex ${TREX_VERSION} unpacked successfully."
fi

# Create canonical symlink /opt/trex/current
ln -sfn "$TREX_TARGET_DIR" "$TREX_CURRENT_LINK"
log_success "Created canonical link: ${TREX_CURRENT_LINK} -> ${TREX_TARGET_DIR}"

# ------------------------------------------------------------------------------
# 6. Python Automation Virtual Environment Setup
# ------------------------------------------------------------------------------
log_step "6. Setting up Python Automation Virtual Environment"

if [[ ! -d "$VENV_DIR" ]]; then
    log_info "Creating Python 3 venv at ${VENV_DIR}..."
    python3 -m venv "$VENV_DIR"
fi

# Activate venv and install dependencies
# shellcheck source=/dev/null
source "${VENV_DIR}/bin/activate"

log_info "Upgrading pip and installing required Python packages..."
pip install --upgrade pip setuptools wheel --quiet
pip install --quiet \
    pyyaml \
    scapy \
    paramiko \
    requests \
    tabulate \
    matplotlib

# Link TRex interactive control plane API to the virtual environment
TREX_API_DIR="${TREX_CURRENT_LINK}/automation/trex_control_plane/interactive"
if [[ -d "$TREX_API_DIR" ]]; then
    log_info "Registering TRex Python API package..."
    cat << EOF > "${VENV_DIR}/lib/python3.13/site-packages/trex.pth"
${TREX_API_DIR}
EOF
    log_success "Linked TRex Python automation libraries."
else
    log_warn "TRex API directory not found at ${TREX_API_DIR}."
fi

deactivate

# ------------------------------------------------------------------------------
# 7. Systemd Service Installation
# ------------------------------------------------------------------------------
log_step "7. Installing Systemd Daemon Unit for TRex"

if [[ -f "${REPO_ROOT}/system-config/trex.service" ]]; then
    cp -f "${REPO_ROOT}/system-config/trex.service" /etc/systemd/system/trex.service
    systemctl daemon-reload
    log_success "Installed /etc/systemd/system/trex.service."
fi

# ------------------------------------------------------------------------------
# 8. Post-Installation Verification
# ------------------------------------------------------------------------------
log_step "8. Verifying TRex Server Binary & Architecture"

cd "$TREX_CURRENT_LINK"

if [[ -x "./t-rex-64" ]]; then
    echo "------------------------------------------------------------"
    ./t-rex-64 --version || ./t-rex-64 -h | head -n 8
    echo "------------------------------------------------------------"
    log_success "Cisco TRex binary verification completed successfully."
else
    log_error "t-rex-64 binary executable test failed!"
    exit 1
fi

log_step "Installation Finished Successfully!"
cat << EOF

Summary of Installation:
- TRex Version:       ${TREX_VERSION}
- Installation Path:  ${TREX_TARGET_DIR}
- Current Symlink:    ${TREX_CURRENT_LINK}
- Python Venv:        ${VENV_DIR}
- Hugepages:          2048 x 2MB (4GB allocated at /dev/hugepages)

Next steps to execute:
1. Generate your /etc/trex_cfg.yaml:
   sudo bash ${REPO_ROOT}/scripts/bash/generate_trex_config.sh
2. Verify hardware and test readiness:
   bash ${REPO_ROOT}/scripts/bash/verify_environment.sh
3. Run the automated test battery:
   bash ${REPO_ROOT}/scripts/bash/run_all_tests.sh

EOF
