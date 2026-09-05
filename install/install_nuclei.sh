#!/usr/bin/env bash
# ==============================================================================
# install/install_nuclei.sh
# Automated, Idempotent Installer for ProjectDiscovery Nuclei Vulnerability Scanner
# Target: Debian GNU/Linux 12 / 13 (Trixie) - x86_64
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

ARCH="$(uname -m)"
if [[ "$ARCH" != "x86_64" ]]; then
    log_error "Architecture $ARCH is not supported directly by this script (x86_64 required)."
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. Install Base Packages & Tools
# ------------------------------------------------------------------------------
log_step "1. Updating Repositories and Installing System Dependencies"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y

PACKAGES=(
    curl
    wget
    ca-certificates
    unzip
    tar
    git
    jq
    pv
    nmap
    iproute2
    net-tools
)

apt-get install -y --no-install-recommends "${PACKAGES[@]}"
log_success "Base dependencies installed successfully."

# ------------------------------------------------------------------------------
# 2. Download and Install Nuclei CLI Binary
# ------------------------------------------------------------------------------
log_step "2. Fetching Latest ProjectDiscovery Nuclei Binary"

# Determine latest release via GitHub API with fallback
LATEST_TAG=$(curl -s https://api.github.com/repos/projectdiscovery/nuclei/releases/latest | jq -r '.tag_name // empty' || true)
if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
    LATEST_TAG="v3.11.1"
    log_warn "Could not fetch latest release dynamically from GitHub API; falling back to pinned ${LATEST_TAG}."
else
    log_info "Detected latest Nuclei release version: ${LATEST_TAG}"
fi

CLEAN_VERSION="${LATEST_TAG#v}"
ZIP_NAME="nuclei_${CLEAN_VERSION}_linux_amd64.zip"
DOWNLOAD_URL="https://github.com/projectdiscovery/nuclei/releases/download/${LATEST_TAG}/${ZIP_NAME}"
TEMP_DIR=$(mktemp -d)

log_info "Downloading ${DOWNLOAD_URL}..."
wget --no-check-certificate -q --show-progress -O "${TEMP_DIR}/${ZIP_NAME}" "$DOWNLOAD_URL"

log_info "Extracting Nuclei binary with PV data monitoring..."
pv "${TEMP_DIR}/${ZIP_NAME}" | unzip -q -d "$TEMP_DIR" -

if [[ -f "${TEMP_DIR}/nuclei" ]]; then
    install -m 755 "${TEMP_DIR}/nuclei" /usr/local/bin/nuclei
    log_success "Installed Nuclei CLI to /usr/local/bin/nuclei."
else
    log_error "Extracted nuclei binary not found in temporary directory!"
    rm -rf "$TEMP_DIR"
    exit 1
fi

rm -rf "$TEMP_DIR"

# ------------------------------------------------------------------------------
# 3. Initialize and Update Community Vulnerability Templates
# ------------------------------------------------------------------------------
log_step "3. Downloading and Updating Official Community Templates"

log_info "Running 'nuclei -update-templates'..."
nuclei -update-templates || {
    log_warn "Automated template update encountered a minor warning; continuing."
}

# ------------------------------------------------------------------------------
# 4. Create Specialized Router Audit Script (/usr/local/bin/scan_router.sh)
# ------------------------------------------------------------------------------
log_step "4. Installing Automated Router Security Audit Script"

cat << 'EOF' > /usr/local/bin/scan_router.sh
#!/usr/bin/env bash
# /usr/local/bin/scan_router.sh
# Automated Router Vulnerability & Misconfiguration Audit using Nuclei
# Standards Context: NIS2 Art. 21 (Vulnerability Management), ISO/IEC 15408 AVA_VAN
set -euo pipefail

TARGET_HOST="${1:-198.18.1.1}"
DUT_TYPE="${2:-generic}"
OUTPUT_DIR="${3:-/var/log/nuclei}"

mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_JSON="${OUTPUT_DIR}/audit_${DUT_TYPE}_${TIMESTAMP}.json"
REPORT_MD="${OUTPUT_DIR}/audit_${DUT_TYPE}_${TIMESTAMP}.md"

echo "============================================================"
echo "    ProjectDiscovery Nuclei Router Vulnerability Audit      "
echo "============================================================"
echo "Target DUT IP:    ${TARGET_HOST}"
echo "Router Type:      ${DUT_TYPE}"
echo "Output Report:    ${REPORT_MD}"
echo "============================================================"

# Specialized tags targeting network equipment, default credentials, CVEs, SSL, and misconfigurations
TAGS="cve,misconfig,default-login,network,ssl,panel,tech,exposure"

# Custom tags by router type
case "$DUT_TYPE" in
    cisco)     EXTRA_TAGS="cisco,ios,ios-xe" ;;
    paloalto)  EXTRA_TAGS="paloalto,pan-os" ;;
    unifi)     EXTRA_TAGS="ubiquiti,unifi" ;;
    openwrt)   EXTRA_TAGS="openwrt,luci" ;;
    mikrotik)  EXTRA_TAGS="mikrotik,routeros" ;;
    vyos)      EXTRA_TAGS="vyos" ;;
    *)         EXTRA_TAGS="" ;;
esac

if [[ -n "$EXTRA_TAGS" ]]; then
    FULL_TAGS="${TAGS},${EXTRA_TAGS}"
else
    FULL_TAGS="${TAGS}"
fi

echo -e "\n[*] Executing Nuclei scan with tags: ${FULL_TAGS}..."

nuclei \
    -target "${TARGET_HOST}" \
    -tags "${FULL_TAGS}" \
    -severity info,low,medium,high,critical \
    -json-export "${REPORT_JSON}" \
    -markdown-export "${REPORT_MD}" \
    -stats \
    -rate-limit 150 \
    -timeout 5 || true

echo -e "\n[+] Audit completed! Results saved to:"
echo "    JSON: ${REPORT_JSON}"
echo "    MD:   ${REPORT_MD}"

if [[ -f "${REPORT_JSON}" && -s "${REPORT_JSON}" ]]; then
    CRIT_COUNT=$(jq -s '[.[] | select(.info.severity=="critical")] | length' "${REPORT_JSON}" 2>/dev/null || echo 0)
    HIGH_COUNT=$(jq -s '[.[] | select(.info.severity=="high")] | length' "${REPORT_JSON}" 2>/dev/null || echo 0)
    MED_COUNT=$(jq -s '[.[] | select(.info.severity=="medium")] | length' "${REPORT_JSON}" 2>/dev/null || echo 0)
    LOW_COUNT=$(jq -s '[.[] | select(.info.severity=="low")] | length' "${REPORT_JSON}" 2>/dev/null || echo 0)

    echo -e "\n=== Vulnerability Summary for ${DUT_TYPE} (${TARGET_HOST}) ==="
    echo "Critical: $CRIT_COUNT"
    echo "High:     $HIGH_COUNT"
    echo "Medium:   $MED_COUNT"
    echo "Low:      $LOW_COUNT"
fi
EOF

chmod +x /usr/local/bin/scan_router.sh
log_success "Created /usr/local/bin/scan_router.sh."

# ------------------------------------------------------------------------------
# 5. Verification
# ------------------------------------------------------------------------------
log_step "5. Verifying Nuclei Installation"

if command -v nuclei >/dev/null 2>&1; then
    echo "------------------------------------------------------------"
    nuclei -version
    echo "------------------------------------------------------------"
    log_success "Nuclei CLI installed and verified successfully."
else
    log_error "Nuclei binary verification failed!"
    exit 1
fi

log_step "Installation Finished Successfully!"
cat << EOF

Summary:
- Nuclei Binary:     /usr/local/bin/nuclei
- Router Audit Tool: /usr/local/bin/scan_router.sh
- Usage Example:     scan_router.sh 198.18.1.1 unifi
- Reports Directory: /var/log/nuclei/

EOF
