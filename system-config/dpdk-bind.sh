#!/usr/bin/env bash
# system-config/dpdk-bind.sh
# Automated DPDK Driver Binding Utility for Cisco TRex
set -euo pipefail

TREX_PATH="${TREX_PATH:-/opt/trex/current}"
DPDK_BIND="${TREX_PATH}/dpdk_nic_bind.py"

if [[ $EUID -ne 0 ]]; then
    echo "[!] Error: This script must be run as root (sudo)." >&2
    exit 1
fi

if [[ ! -f "$DPDK_BIND" ]]; then
    echo "[!] Error: TRex dpdk_nic_bind.py not found at: ${DPDK_BIND}" >&2
    echo "    Ensure TRex is installed via install/install.sh" >&2
    exit 1
fi

show_usage() {
    cat << EOF
Usage: $0 [command] [args...]

Commands:
  status                     Display current status of all network devices
  bind-vfio <pci_id>...      Bind one or more PCI interfaces to vfio-pci driver
  bind-uio <pci_id>...       Bind one or more PCI interfaces to uio_pci_generic
  unbind-kernel <pci_id> <drv> Return interface to native kernel driver (e.g. virtio-pci, i40e)

Examples:
  sudo $0 status
  sudo $0 bind-vfio 00:10.0 00:11.0
  sudo $0 unbind-kernel 00:10.0 virtio-pci
EOF
}

cmd="${1:-status}"

case "$cmd" in
    status)
        echo "=== Current Network Interfaces DPDK Status ==="
        python3 "$DPDK_BIND" --status
        ;;
    bind-vfio)
        shift
        if [[ $# -eq 0 ]]; then
            echo "[!] Error: Provide at least one PCI address." >&2
            exit 1
        fi
        modprobe vfio-pci || true
        # Check if unsafe noiommu mode is required (common in virtualized Proxmox VirtIO)
        if [[ ! -d /sys/kernel/iommu_groups/0 && -f /sys/module/vfio/parameters/enable_unsafe_noiommu_mode ]]; then
            echo "[*] Notice: No hardware IOMMU groups detected. Enabling VFIO unsafe noiommu mode..."
            echo 1 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
        fi
        for pci in "$@"; do
            echo "[*] Binding $pci to vfio-pci..."
            python3 "$DPDK_BIND" --bind=vfio-pci "$pci"
        done
        python3 "$DPDK_BIND" --status
        ;;
    bind-uio)
        shift
        if [[ $# -eq 0 ]]; then
            echo "[!] Error: Provide at least one PCI address." >&2
            exit 1
        fi
        modprobe uio_pci_generic || modprobe uio || true
        for pci in "$@"; do
            echo "[*] Binding $pci to uio_pci_generic..."
            python3 "$DPDK_BIND" --bind=uio_pci_generic "$pci"
        done
        python3 "$DPDK_BIND" --status
        ;;
    unbind-kernel)
        shift
        if [[ $# -lt 2 ]]; then
            echo "[!] Error: Provide PCI address and kernel driver name." >&2
            exit 1
        fi
        pci="$1"
        driver="$2"
        echo "[*] Reverting $pci to kernel driver: $driver..."
        python3 "$DPDK_BIND" --bind="$driver" "$pci"
        python3 "$DPDK_BIND" --status
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
