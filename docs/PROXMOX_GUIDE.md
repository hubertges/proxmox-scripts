# Przewodnik Konfiguracji Środowiska Proxmox VE dla Generatora Cisco TRex i DUT

Niniejszy dokument przedstawia precyzyjny zbiór procedur, komend CLI oraz wywołań API hiperwizora Proxmox VE (PVE 8/9, jądro Proxmox `pve-kernel` 6.x/7.x) niezbędnych do przygotowania maszyn wirtualnych (VM) dla generatora ruchu Cisco TRex oraz badanego routera (DUT).

---

## 1. Pobieranie Parametrów Środowiska Proxmox (Komendy Audytowe)

Aby uzyskać kompletną specyfikację maszyny wirtualnej, sieci oraz procesora bez konieczności zgadywania, wykonaj poniższe polecenia w powłoce węzła Proxmox VE:

### A. Pobranie pełnej konfiguracji maszyny wirtualnej (CLI)
```bash
# Zastąp <VMID> numerem ID maszyny wirtualnej (np. 100)
qm config <VMID>
```
*Zwraca: przydział vCPU, model procesora, flagi NUMA, pamięć RAM, kontrolery dyskowe oraz podłączone karty sieciowe.*

### B. Pobranie parametrów maszyny przez Proxmox REST API (`pvesh`)
```bash
# Odczyt statusu i konfiguracji węzła przez CLI API
pvesh get /nodes/{node}/qemu/<VMID>/config --output-format json-pretty

# Odczyt podsumowania zasobów sprzętowych węzła (CPU, RAM, KVM)
pvesh get /nodes/{node}/status --output-format json-pretty
```

### C. Weryfikacja fizycznych kart sieciowych i wsparcia IOMMU (Host)
```bash
# Sprawdzenie obecności kontrolerów sieciowych i przypisanych sterowników
lspci -nnk | grep -i -A 3 net

# Weryfikacja aktywności grup IOMMU (VT-d / AMD-Vi) na hoście
dmesg | grep -E -i "iommu|dmar"
find /sys/kernel/iommu_groups/ -type l
```

---

## 2. Optymalna Konfiguracja Maszyny Wirtualnej TRex na Proxmox VE

W celu wyeliminowania fluktuacji opóźnień (jittera) i zagwarantowania przepustowości bliskiej sprzętowej (line-rate) w środowisku wirtualnym, VM dla TRex musi zostać skonfigurowana zgodnie z poniższymi regułami.

### Krok 1: Wymuszenie typu procesora `host`
DPDK wewnątrz TRex wymaga instrukcji SSE4.2, AVX, AVX2 oraz optymalizacji AES. Domyślny procesor `kvm64` powoduje spadek wydajności nawet o 70%.
```bash
qm set <VMID> --cpu host,flags=+aes;+avx;+avx2
```

### Krok 2: Aktywacja architektury NUMA i pinowanie pamięci
```bash
qm set <VMID> --numa 1
qm set <VMID> --cores 8 --sockets 1
```

### Krok 3: Konfiguracja kart sieciowych
W zależności od dostępnego sprzętu stosuje się jedno z dwóch podejść:

#### Wariant A: Karty wirtualne VirtIO-Net z Multiqueue (Środowisko laboratoryjne / testy funkcjonalne)
Dla standardowych mostków sieciowych (`vmbr0`, `vmbr1`) ustaw model `virtio` z liczbą kolejek odpowiadającą liczbie dedykowanych rdzeni worker DPDK:
```bash
# Interfejs Port 0 (WAN do DUT) - dedykowany vlan lub bridge vmbr1
qm set <VMID> --net0 virtio,bridge=vmbr1,queues=4,firewall=0,mtu=9000

# Interfejs Port 1 (LAN do DUT) - dedykowany vlan lub bridge vmbr2
qm set <VMID> --net1 virtio,bridge=vmbr2,queues=4,firewall=0,mtu=9000
```
> [!IMPORTANT]
> Opcja `firewall=0` na interfejsach w Proxmoxie jest krytyczna – wyłącza filtry `ebtables`/`iptables` na interfejsach `tap` hosta, które zniekształcają pomiary RFC 2544.

#### Wariant B: PCIe Passthrough / SR-IOV Virtual Functions (Maksymalna wydajność >10 Gbps)
Przekazanie fizycznej karty (lub funkcji wirtualnej SR-IOV) bezpośrednio do VM TRex:
```bash
# Przypisanie urządzenia PCI z ID odczytanego z 'lspci' (np. 03:10.0)
qm set <VMID> --hostpci0 0000:03:10.0,pcie=1
qm set <VMID> --hostpci1 0000:03:10.1,pcie=1
```

### Krok 4: Włączenie Hugepages na poziomie maszyny KVM
Aby hypervisor nie swapował pamięci DPDK maszyny wirtualnej, alokuj Hugepages 2M na poziomie Proxmox VE:
```bash
qm set <VMID> --hugepages 2
```

---

## 3. Topologia Połączeń Proxmox: TRex <--> DUT

Dla zapewnienia deterministycznych pomiarów, pakiety generowane przez TRex nie mogą współdzielić mostków z ruchem zarządzającym:

```
+-------------------------------------------------------------------------+
|                              PROXMOX HOST                               |
|                                                                         |
|  +---------------------------+             +-------------------------+  |
|  |     TRex Generator VM     |             |       Router DUT        |  |
|  |                           |             | (Cisco CSR / VyOS / ROS)|  |
|  |  [Port 0: 198.18.1.2] ----+--[vmbr10]---+-- [WAN: 198.18.1.1]     |  |
|  |                           |             |                         |  |
|  |  [Port 1: 198.19.1.2] ----+--[vmbr20]---+-- [LAN: 198.19.1.1]     |  |
|  |                           |             |                         |  |
|  |  [eth0: Mgmt / SSH] ------+--[vmbr0]----+-- [Mgmt: SSH / Telemetry|  |
|  +---------------------------+             +-------------------------+  |
+-------------------------------------------------------------------------+
```

Konfiguracja dedykowanych mostków izolowanych w `/etc/network/interfaces` na hoście Proxmox:
```text
auto vmbr10
iface vmbr10 inet manual
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        mtu 9000
# Izolowany mostek pomiarowy WAN (TRex Port 0 <-> DUT WAN)

auto vmbr20
iface vmbr20 inet manual
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        mtu 9000
# Izolowany mostek pomiarowy LAN (TRex Port 1 <-> DUT LAN)
```

Po edycji zrestartuj interfejsy na hoście poleceniem:
```bash
ifreload -a
```
