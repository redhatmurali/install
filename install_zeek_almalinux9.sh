#!/bin/bash
# =============================================================================
# Zeek IDS/NSM Installation Script for AlmaLinux 9 — BUILD FROM SOURCE
# Author: NETAPORT.COM | Cybersecurity Infrastructure Series
# Description: Builds and installs Zeek from source (OBS has no EL9 packages).
#              Configures standalone mode on ens160 with systemd service.
# Tested on: AlmaLinux 9.x (RHEL 9 compatible)
# =============================================================================

set -euo pipefail

# ─── CONFIGURATION ────────────────────────────────────────────────────────────
ZEEK_VERSION="7.2.1"                        # Latest Zeek 7.x LTS
ZEEK_TAR="zeek-${ZEEK_VERSION}.tar.gz"
ZEEK_URL="https://download.zeek.org/${ZEEK_TAR}"
ZEEK_SRC="/usr/local/src/zeek-${ZEEK_VERSION}"
ZEEK_PREFIX="/opt/zeek"
MONITOR_IFACE="ens160"                      # Capture interface
LOCAL_NETS="192.168.0.0/16,10.0.0.0/8"     # Local subnets for networks.cfg
LOG_DIR="/var/log/zeek"
SCRIPT_LOG="/var/log/zeek_install.log"
BUILD_JOBS=$(nproc)                         # Use all CPU cores for compilation

# ─── COLORS ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*" | tee -a "$SCRIPT_LOG"; }
success() { echo -e "${GREEN}[OK]${NC}    $*" | tee -a "$SCRIPT_LOG"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$SCRIPT_LOG"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$SCRIPT_LOG"; exit 1; }

# ─── PRE-FLIGHT ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Run this script as root or with sudo."

mkdir -p "$(dirname "$SCRIPT_LOG")"
echo "========================================" | tee -a "$SCRIPT_LOG"
echo "  Zeek Install - $(date)"               | tee -a "$SCRIPT_LOG"
echo "========================================" | tee -a "$SCRIPT_LOG"

if ! ip link show "$MONITOR_IFACE" &>/dev/null; then
    warn "Interface '$MONITOR_IFACE' not found. Available interfaces:"
    ip -br link show | awk '{print "  " $1}'
    error "Update MONITOR_IFACE in this script and re-run."
fi

# ─── STEP 1: DEPENDENCIES ─────────────────────────────────────────────────────
info "Step 1/7 — Installing build dependencies..."
dnf install -y epel-release >> "$SCRIPT_LOG" 2>&1
dnf config-manager --set-enabled crb >> "$SCRIPT_LOG" 2>&1
dnf makecache >> "$SCRIPT_LOG" 2>&1

dnf install -y \
    cmake \
    make \
    gcc \
    gcc-c++ \
    flex \
    bison \
    libpcap-devel \
    openssl-devel \
    python3 \
    python3-devel \
    python3-pip \
    swig \
    zlib-devel \
    wget \
    curl \
    net-tools \
    ethtool \
    jq \
    bind-utils \
    tar \
    >> "$SCRIPT_LOG" 2>&1
success "Dependencies installed."

# ─── STEP 2: DOWNLOAD SOURCE ──────────────────────────────────────────────────
info "Step 2/7 — Downloading Zeek ${ZEEK_VERSION} source..."
cd /usr/local/src

if [[ -f "$ZEEK_TAR" ]]; then
    info "Tarball already present, skipping download."
else
    wget -q --show-progress "${ZEEK_URL}" -O "${ZEEK_TAR}" 2>&1 | tee -a "$SCRIPT_LOG"
fi

[[ -f "$ZEEK_TAR" ]] || error "Download failed: ${ZEEK_URL}"

info "Extracting source..."
tar -xzf "${ZEEK_TAR}"
[[ -d "$ZEEK_SRC" ]] || error "Extraction failed — directory $ZEEK_SRC not found."
success "Source ready at $ZEEK_SRC"

# ─── STEP 3: BUILD & INSTALL ──────────────────────────────────────────────────
info "Step 3/7 — Configuring and building Zeek (this takes 10-20 min)..."
cd "$ZEEK_SRC"

./configure \
    --prefix="${ZEEK_PREFIX}" \
    --with-pcap=/usr \
    >> "$SCRIPT_LOG" 2>&1 || error "configure failed — check $SCRIPT_LOG"

make -j"${BUILD_JOBS}" >> "$SCRIPT_LOG" 2>&1 || error "make failed — check $SCRIPT_LOG"
make install          >> "$SCRIPT_LOG" 2>&1 || error "make install failed — check $SCRIPT_LOG"

success "Zeek built and installed to ${ZEEK_PREFIX}"

# ─── STEP 4: PATH ─────────────────────────────────────────────────────────────
info "Step 4/7 — Configuring PATH..."
cat > /etc/profile.d/zeek.sh <<EOF
# Zeek PATH — added by install_zeek_almalinux9.sh
export PATH=\$PATH:${ZEEK_PREFIX}/bin
EOF
export PATH=$PATH:${ZEEK_PREFIX}/bin
success "PATH updated via /etc/profile.d/zeek.sh"

ZEEK_BIN="${ZEEK_PREFIX}/bin"

# ─── STEP 5: CONFIGURE ZEEKCTL ────────────────────────────────────────────────
info "Step 5/7 — Configuring ZeekControl..."

NODE_CFG="${ZEEK_PREFIX}/etc/node.cfg"
NETWORKS_CFG="${ZEEK_PREFIX}/etc/networks.cfg"
ZEEKCTL_CFG="${ZEEK_PREFIX}/etc/zeekctl.cfg"

cat > "$NODE_CFG" <<EOF
# ZeekControl Node Configuration — Standalone Mode
[zeek]
type=standalone
host=localhost
interface=${MONITOR_IFACE}
EOF

> "$NETWORKS_CFG"
IFS=',' read -ra NETS <<< "$LOCAL_NETS"
for NET in "${NETS[@]}"; do
    echo "${NET}    Local Network" >> "$NETWORKS_CFG"
done

mkdir -p "$LOG_DIR" "${ZEEK_PREFIX}/spool"
sed -i "s|^LogDir.*|LogDir = ${LOG_DIR}|"         "$ZEEKCTL_CFG" 2>/dev/null || true
sed -i "s|^SpoolDir.*|SpoolDir = ${ZEEK_PREFIX}/spool|" "$ZEEKCTL_CFG" 2>/dev/null || true
sed -i "s|^MailTo.*|MailTo = |"                   "$ZEEKCTL_CFG" 2>/dev/null || true
sed -i "s|^MailConnectionSummary.*|MailConnectionSummary = 0|" "$ZEEKCTL_CFG" 2>/dev/null || true

success "ZeekControl configured."

# ─── STEP 6: DISABLE NIC OFFLOADING ──────────────────────────────────────────
info "Step 6/7 — Disabling NIC offloading on ${MONITOR_IFACE}..."

cat > /etc/udev/rules.d/99-zeek-offload.rules <<EOF
ACTION=="add", SUBSYSTEM=="net", KERNEL=="${MONITOR_IFACE}", \
  RUN+="/sbin/ethtool -K %k rx off tx off gso off gro off lro off tso off"
EOF

ethtool -K "$MONITOR_IFACE" rx off tx off gso off gro off lro off tso off 2>/dev/null \
    && success "NIC offloading disabled." \
    || warn "Could not disable all offload features — verify: ethtool -k $MONITOR_IFACE"

# ─── STEP 7: INITIALIZE & START ZEEK ──────────────────────────────────────────
info "Step 7/7 — Initializing ZeekControl and starting Zeek..."

"${ZEEK_BIN}/zeekctl" install >> "$SCRIPT_LOG" 2>&1
"${ZEEK_BIN}/zeekctl" start  >> "$SCRIPT_LOG" 2>&1

sleep 3
STATUS=$("${ZEEK_BIN}/zeekctl" status 2>&1)
echo "$STATUS" | tee -a "$SCRIPT_LOG"

if echo "$STATUS" | grep -q "running"; then
    success "Zeek is RUNNING."
else
    warn "Zeek may not be running. Check: zeekctl status"
fi

# ─── SYSTEMD SERVICE ──────────────────────────────────────────────────────────
info "Creating systemd service..."
cat > /etc/systemd/system/zeek.service <<EOF
[Unit]
Description=Zeek Network Security Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${ZEEK_BIN}/zeekctl start
ExecStop=${ZEEK_BIN}/zeekctl stop
ExecReload=${ZEEK_BIN}/zeekctl restart

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zeek.service >> "$SCRIPT_LOG" 2>&1
success "Zeek systemd service enabled."

# ─── SUMMARY ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Zeek ${ZEEK_VERSION} Installation Complete!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "  Install Prefix : ${ZEEK_PREFIX}"
echo -e "  Monitor Iface  : ${MONITOR_IFACE}"
echo -e "  Log Directory  : ${LOG_DIR}"
echo -e "  Install Log    : ${SCRIPT_LOG}"
echo ""
echo -e "  ${CYAN}Useful Commands:${NC}"
echo -e "    zeekctl status                          — Check status"
echo -e "    zeekctl stop / start / restart          — Lifecycle"
echo -e "    zeekctl deploy                          — Apply config changes"
echo -e "    tail -f ${LOG_DIR}/current/conn.log    — Live connections"
echo -e "    tail -f ${LOG_DIR}/current/notice.log  — Live alerts"
echo ""
echo -e "  ${YELLOW}Next Steps:${NC}"
echo -e "    pip3 install zkg && zkg autoconfig      — Zeek Package Manager"
echo -e "    Ship logs to Vector → ClickHouse pipeline"
echo -e "${GREEN}============================================================${NC}"
