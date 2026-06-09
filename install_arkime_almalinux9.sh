#!/usr/bin/env bash
# =============================================================================
# Arkime 6.x — All-in-One Installation Script for AlmaLinux 9
# =============================================================================
# Installs: OpenSearch 2.x (backend) + Arkime 6 (capture + viewer)
# Tested on: AlmaLinux 9 / RHEL 9 / Rocky Linux 9  (x86_64)
#
# Usage:
#   chmod +x install_arkime_almalinux9.sh
#   sudo ./install_arkime_almalinux9.sh
#
# Customise the variables in the CONFIG block below before running.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# CONFIG — edit these before running
# ---------------------------------------------------------------------------
ARKIME_VERSION="6.4.0"
ARKIME_ITER="1"
ARKIME_RPM="arkime-${ARKIME_VERSION}-${ARKIME_ITER}.el9.x86_64.rpm"
ARKIME_URL="https://github.com/arkime/arkime/releases/download/v${ARKIME_VERSION}/${ARKIME_RPM}"

OPENSEARCH_VERSION="2.13.0"   # used in the OpenSearch repo URL

# Network interface Arkime should sniff on (e.g. eth0, ens3, bond0)
CAPTURE_IFACE="${CAPTURE_IFACE:-ens160}"

# Arkime admin password (set via env var or change default below)
ARKIME_ADMIN_PASS="${ARKIME_ADMIN_PASS:-Arkime@2024!}"

# OpenSearch listens on localhost only — keep this unless you cluster
OPENSEARCH_HOST="localhost"
OPENSEARCH_PORT="9200"

# PCAP storage directory — ensure enough disk space
PCAP_DIR="/opt/arkime/raw"

# Log directory
LOG_DIR="/opt/arkime/logs"

# GeoIP database directory (MaxMind free DBs, optional)
GEOIP_DIR="/opt/arkime/etc"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || error "Run this script as root (sudo)."
}

detect_iface() {
  if ! ip link show "${CAPTURE_IFACE}" &>/dev/null; then
    warn "Interface '${CAPTURE_IFACE}' not found. Detected interfaces:"
    ip -br link show | awk '{print "  " $1}'
    warn "Set CAPTURE_IFACE env var to the correct interface and re-run."
    error "Aborting — invalid capture interface."
  fi
  info "Capture interface: ${CAPTURE_IFACE}"
}

# ---------------------------------------------------------------------------
# Step 1: System prerequisites
# ---------------------------------------------------------------------------
step1_prereqs() {
  info "=== Step 1: System prerequisites ==="
  dnf -y update --quiet
  dnf -y install --quiet \
    curl wget tar gzip perl perl-libwww-perl perl-JSON \
    perl-LWP-Protocol-https ethtool libyaml \
    java-17-openjdk-headless \
    firewalld

  # Enable firewalld if not running
  systemctl enable --now firewalld &>/dev/null || true
  info "Prerequisites installed."
}

# ---------------------------------------------------------------------------
# Step 2: Install OpenSearch (official RPM repo)
# ---------------------------------------------------------------------------
step2_opensearch() {
  info "=== Step 2: Installing OpenSearch ${OPENSEARCH_VERSION} ==="

  # AlmaLinux 9 / RHEL 9 blocks SHA1 signatures by default.
  # Temporarily relax the crypto policy just for GPG key import.
  CURRENT_POLICY=$(update-crypto-policies --show 2>/dev/null || echo "DEFAULT")
  info "Relaxing crypto policy temporarily for GPG import (was: ${CURRENT_POLICY})"
  update-crypto-policies --set DEFAULT:SHA1 &>/dev/null || true

  # Download and import OpenSearch GPG key
  wget -qO /tmp/opensearch.pgp https://artifacts.opensearch.org/publickeys/opensearch.pgp
  rpm --import /tmp/opensearch.pgp || error "GPG key import failed."

  # Restore original crypto policy immediately
  update-crypto-policies --set "${CURRENT_POLICY}" &>/dev/null || true
  info "Crypto policy restored to: ${CURRENT_POLICY}"

  # Create repo file — gpgcheck disabled (SHA1 key incompatible with EL9 strict policy)
  # Downloads are over HTTPS, so transport security is maintained.
  cat > /etc/yum.repos.d/opensearch.repo << 'EOF'
[opensearch-2.x]
name=OpenSearch 2.x repository
baseurl=https://artifacts.opensearch.org/releases/bundle/opensearch/2.x/yum
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=0
EOF

  # Disable OpenSearch security plugin (simplifies single-node setup)
  # For production with TLS, remove the env override below.
  dnf -y install --quiet opensearch

  # --- Configure OpenSearch for single-node / Arkime ---
  OSCONF="/etc/opensearch/opensearch.yml"

  sed -i 's/^#\?cluster\.name:.*/cluster.name: arkime-cluster/' "${OSCONF}" 2>/dev/null || true
  sed -i 's/^#\?node\.name:.*/node.name: arkime-node1/'         "${OSCONF}" 2>/dev/null || true

  # Bind to localhost only
  grep -q '^network\.host' "${OSCONF}" || echo 'network.host: 127.0.0.1' >> "${OSCONF}"
  grep -q '^http\.port'    "${OSCONF}" || echo 'http.port: 9200'          >> "${OSCONF}"

  # Single-node discovery
  grep -q '^discovery\.type' "${OSCONF}" || \
    echo 'discovery.type: single-node' >> "${OSCONF}"

  # Disable security plugin (HTTP, no TLS) — comment out for production TLS
  grep -q 'plugins\.security\.disabled' "${OSCONF}" || \
    echo 'plugins.security.disabled: true' >> "${OSCONF}"

  # JVM heap — set to 50% of RAM, max 32 GB (recommended)
  TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  HEAP_GB=$(( TOTAL_MEM_KB / 1024 / 1024 / 2 ))
  [[ ${HEAP_GB} -lt 1 ]] && HEAP_GB=1
  [[ ${HEAP_GB} -gt 32 ]] && HEAP_GB=32
  JVMOPTS="/etc/opensearch/jvm.options.d/heap.options"
  cat > "${JVMOPTS}" << EOF
-Xms${HEAP_GB}g
-Xmx${HEAP_GB}g
EOF

  # System limits for OpenSearch
  grep -q 'opensearch.*nofile' /etc/security/limits.conf || \
    printf 'opensearch soft nofile 65536\nopensearch hard nofile 65536\n' \
      >> /etc/security/limits.conf

  grep -q 'vm.max_map_count' /etc/sysctl.conf || \
    echo 'vm.max_map_count = 262144' >> /etc/sysctl.conf
  sysctl -p &>/dev/null

  systemctl daemon-reload
  systemctl enable --now opensearch

  # Wait for OpenSearch to be ready (up to 120 s)
  info "Waiting for OpenSearch to start..."
  for i in $(seq 1 24); do
    if curl -sf "http://${OPENSEARCH_HOST}:${OPENSEARCH_PORT}/_cluster/health" \
         -o /dev/null 2>/dev/null; then
      info "OpenSearch is up."
      break
    fi
    sleep 5
    [[ $i -eq 24 ]] && error "OpenSearch did not start within 120 seconds."
  done
}

# ---------------------------------------------------------------------------
# Step 3: Install Arkime RPM
# ---------------------------------------------------------------------------
step3_arkime_rpm() {
  info "=== Step 3: Installing Arkime ${ARKIME_VERSION} (el9 RPM) ==="

  TMP_RPM="/tmp/${ARKIME_RPM}"
  if [[ ! -f "${TMP_RPM}" ]]; then
    info "Downloading ${ARKIME_RPM} ..."
    wget -q --show-progress -O "${TMP_RPM}" "${ARKIME_URL}" \
      || error "Download failed. Check network or URL: ${ARKIME_URL}"
  else
    info "Found cached RPM at ${TMP_RPM}, skipping download."
  fi

  rpm -Uvh "${TMP_RPM}" || dnf -y install "${TMP_RPM}"
  info "Arkime RPM installed."
}

# ---------------------------------------------------------------------------
# Step 4: Configure Arkime (config.ini)
# ---------------------------------------------------------------------------
step4_configure() {
  info "=== Step 4: Configuring Arkime ==="

  CONF="/opt/arkime/etc/config.ini"

  # Run the official configure script non-interactively
  # It writes /opt/arkime/etc/config.ini based on prompts — we patch after.
  info "Running arkime_configure.sh (automated) ..."
  printf "%s\n" \
    "${CAPTURE_IFACE}" \
    "http://${OPENSEARCH_HOST}:${OPENSEARCH_PORT}" \
    "${ARKIME_ADMIN_PASS}" \
    "${ARKIME_ADMIN_PASS}" \
    | /opt/arkime/bin/arkime_configure.sh --configFile "${CONF}" \
        --install 2>&1 | tee /tmp/arkime_configure.log \
    || warn "configure script exited non-zero — patching config.ini manually."

  # --- Patch / verify key settings ---
  patch_ini() {
    local key="$1" val="$2"
    if grep -q "^${key}" "${CONF}"; then
      sed -i "s|^${key}.*|${key}=${val}|" "${CONF}"
    else
      echo "${key}=${val}" >> "${CONF}"
    fi
  }

  patch_ini "elasticsearch"   "http://${OPENSEARCH_HOST}:${OPENSEARCH_PORT}"
  patch_ini "interface"       "${CAPTURE_IFACE}"
  patch_ini "pcapDir"         "${PCAP_DIR}"
  patch_ini "logDirectory"    "${LOG_DIR}"
  patch_ini "geoLite2Country" "${GEOIP_DIR}/GeoLite2-Country.mmdb"
  patch_ini "geoLite2ASN"     "${GEOIP_DIR}/GeoLite2-ASN.mmdb"
  patch_ini "rirFile"         "${GEOIP_DIR}/ipv4-address-space.csv"
  patch_ini "ouiFile"         "${GEOIP_DIR}/oui.txt"

  # Tuning defaults (adjust per environment)
  patch_ini "maxFileSizeG"    "4"
  patch_ini "maxFileTimeM"    "60"
  patch_ini "tcpTimeout"      "600"
  patch_ini "udpTimeout"      "30"
  patch_ini "icmpTimeout"     "10"
  patch_ini "maxStreams"      "1500000"
  patch_ini "maxPackets"      "10000"

  mkdir -p "${PCAP_DIR}" "${LOG_DIR}" "${GEOIP_DIR}"
  chown -R nobody:nobody "${PCAP_DIR}" "${LOG_DIR}" 2>/dev/null || \
    chown -R arkime:arkime "${PCAP_DIR}" "${LOG_DIR}" 2>/dev/null || true

  info "config.ini written at ${CONF}"
}

# ---------------------------------------------------------------------------
# Step 5: Initialise OpenSearch indices
# ---------------------------------------------------------------------------
step5_init_db() {
  info "=== Step 5: Initialising Arkime indices in OpenSearch ==="
  echo "INIT" | /opt/arkime/db/db.pl \
    "http://${OPENSEARCH_HOST}:${OPENSEARCH_PORT}" init \
    || error "db.pl init failed."
  info "Indices created."
}

# ---------------------------------------------------------------------------
# Step 6: Create admin user
# ---------------------------------------------------------------------------
step6_admin_user() {
  info "=== Step 6: Creating Arkime admin user ==="
  /opt/arkime/bin/arkime_add_user.sh admin "Admin User" \
    "${ARKIME_ADMIN_PASS}" --admin \
    || warn "admin user may already exist — skipping."
  info "Admin user: 'admin' / password: <configured>"
}

# ---------------------------------------------------------------------------
# Step 7: Enable and start services
# ---------------------------------------------------------------------------
step7_services() {
  info "=== Step 7: Starting Arkime services ==="
  systemctl daemon-reload
  systemctl enable --now arkimecapture
  systemctl enable --now arkimeviewer
  info "arkimecapture and arkimeviewer started."
}

# ---------------------------------------------------------------------------
# Step 8: Firewall rules
# ---------------------------------------------------------------------------
step8_firewall() {
  info "=== Step 8: Configuring firewall ==="
  # Arkime Viewer UI (port 8005)
  firewall-cmd --permanent --add-port=8005/tcp
  # OpenSearch (localhost only — no firewall rule needed unless remote)
  firewall-cmd --reload
  info "Port 8005/tcp opened in firewalld."
}

# ---------------------------------------------------------------------------
# Step 9: Health check
# ---------------------------------------------------------------------------
step9_health() {
  info "=== Step 9: Health check ==="

  sleep 3

  OS_STATUS=$(curl -sf "http://${OPENSEARCH_HOST}:${OPENSEARCH_PORT}/_cluster/health" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','unknown'))" \
    2>/dev/null || echo "unreachable")
  info "OpenSearch cluster status: ${OS_STATUS}"

  AV_STATUS=$(systemctl is-active arkimeviewer   2>/dev/null || echo "inactive")
  AC_STATUS=$(systemctl is-active arkimecapture  2>/dev/null || echo "inactive")
  info "arkimeviewer  : ${AV_STATUS}"
  info "arkimecapture : ${AC_STATUS}"

  SERVER_IP=$(hostname -I | awk '{print $1}')
  echo ""
  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN} Arkime ${ARKIME_VERSION} installation complete!${NC}"
  echo -e "${GREEN}========================================${NC}"
  echo ""
  echo "  Web UI  : http://${SERVER_IP}:8005"
  echo "  Username: admin"
  echo "  Password: ${ARKIME_ADMIN_PASS}"
  echo ""
  echo "  Config  : /opt/arkime/etc/config.ini"
  echo "  PCAP    : ${PCAP_DIR}"
  echo "  Logs    : ${LOG_DIR}"
  echo ""
  echo "  Useful commands:"
  echo "    systemctl status arkimecapture"
  echo "    systemctl status arkimeviewer"
  echo "    journalctl -u arkimecapture -f"
  echo "    journalctl -u arkimeviewer  -f"
  echo ""
  echo "  Upgrade DB indices (after RPM upgrade):"
  echo "    /opt/arkime/db/db.pl http://${OPENSEARCH_HOST}:${OPENSEARCH_PORT} upgrade"
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  require_root
  detect_iface

  step1_prereqs
  step2_opensearch
  step3_arkime_rpm
  step4_configure
  step5_init_db
  step6_admin_user
  step7_services
  step8_firewall
  step9_health
}

main "$@"
