#!/usr/bin/env bash
# =============================================================================
#  OpenObserve v0.90.3 – Installation Script
#  Target OS  : AlmaLinux 9.x (x86_64)  |  VMware (no external DNS)
#  Mode       : Single-node, local storage
#  Web UI     : http://<VM_IP>:5080
#
#  Reference  : https://openobserve.ai/docs/operator-guide/systemd/
#  Download   : https://openobserve.ai/downloads/
#
#  IMPORTANT  : Run as root on AlmaLinux 9 VM.
#  Usage      : chmod +x openobserve-install-almalinux9.sh
#               sudo ./openobserve-install-almalinux9.sh
#
#  Optional env vars:
#    ZO_ROOT_USER_EMAIL     default: admin@admin.com   (must be valid email format)
#    ZO_ROOT_USER_PASSWORD  default: Admin2024!        <-- CHANGE THIS
#    ZO_DATA_DIR            default: /var/lib/openobserve
#    ZO_HTTP_PORT           default: 5080
# =============================================================================

set -euo pipefail

# ---------- colour helpers ---------------------------------------------------
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GRN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YLW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

[[ $EUID -ne 0 ]] && die "Run as root."

. /etc/os-release
[[ "${ID}" != "almalinux" ]] && die "AlmaLinux only. Detected: ${ID}"
[[ "${VERSION_ID}" != 9* ]]  && die "AlmaLinux 9.x required. Detected: ${VERSION_ID}"
ok "Detected ${PRETTY_NAME}"

# ---------- variables --------------------------------------------------------
# NOTE: Email must be a valid format e.g. user@domain.com
# OpenObserve enforces regex: ([a-z0-9_+.-]+)@([a-z0-9.-]+\.[a-z]{2,6})
# admin@localhost WILL FAIL — always use a proper TLD
ZO_ROOT_USER_EMAIL="${ZO_ROOT_USER_EMAIL:-admin@admin.com}"
ZO_ROOT_USER_PASSWORD="${ZO_ROOT_USER_PASSWORD:-Admin2024!}"
ZO_DATA_DIR="${ZO_DATA_DIR:-/var/lib/openobserve}"
ZO_HTTP_PORT="${ZO_HTTP_PORT:-5080}"

INSTALL_DIR="/usr/local/bin"
BINARY="${INSTALL_DIR}/openobserve"
ENV_FILE="/etc/openobserve.env"
SERVICE_FILE="/etc/systemd/system/openobserve.service"
LOG_DIR="/var/log/openobserve"
TMP_TAR="/tmp/openobserve-musl.tar.gz"

OO_VERSION="v0.90.3"

# IMPORTANT: Use the musl build — AlmaLinux 9 ships GLIBC 2.34 but the
# standard amd64 binary requires GLIBC 2.39 (exits with status=203/EXEC).
# The musl build is statically linked with no GLIBC version dependency.
# Source: https://openobserve.ai/downloads/ → Open Source → amd64-musl
DOWNLOAD_URL="https://downloads.openobserve.ai/releases/openobserve/${OO_VERSION}/openobserve-${OO_VERSION}-linux-amd64-musl.tar.gz"

VM_IP=$(ip -4 addr show scope global | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
[[ -z "$VM_IP" ]] && die "Could not detect VM IP address."

echo ""
echo -e "${GRN}==========================================================${NC}"
echo -e "${GRN}  OpenObserve ${OO_VERSION} Installer – AlmaLinux 9 (VMware)${NC}"
echo -e "${GRN}==========================================================${NC}"
echo -e "  VM IP        : ${VM_IP}"
echo -e "  Web UI port  : ${ZO_HTTP_PORT}"
echo -e "  Data dir     : ${ZO_DATA_DIR}"
echo -e "  Admin email  : ${ZO_ROOT_USER_EMAIL}"
echo -e "  Binary       : musl (GLIBC-independent)"
echo ""

# =============================================================================
# PRE-FLIGHT – DNS check
# =============================================================================
info "=== PRE-FLIGHT: DNS and network check ==="

for ns in 8.8.8.8 8.8.4.4; do
    getent hosts downloads.openobserve.ai &>/dev/null && break
    warn "DNS not resolving – adding nameserver ${ns}"
    sed -i "1s/^/nameserver ${ns}\n/" /etc/resolv.conf
    sleep 1
done

getent hosts downloads.openobserve.ai &>/dev/null \
    || die "DNS resolution failed.\n       Fix: echo 'nameserver 8.8.8.8' >> /etc/resolv.conf"
ok "DNS resolution working."

# Make DNS persistent across reboots
NM_CONF="/etc/NetworkManager/conf.d/99-dns-override.conf"
if [[ ! -f "${NM_CONF}" ]]; then
    cat > "${NM_CONF}" <<EOF
[main]
dns=none
EOF
    { echo "nameserver 8.8.8.8"; echo "nameserver 8.8.4.4"; } > /etc/resolv.conf
    systemctl reload NetworkManager 2>/dev/null || true
    ok "DNS made persistent (8.8.8.8, 8.8.4.4)."
fi

# =============================================================================
# STEP 1 – System update + dependencies
# =============================================================================
info "=== STEP 1: System update and dependencies ==="

dnf upgrade -y
dnf install -y curl tar openssl

ok "System packages ready."

# =============================================================================
# STEP 2 – Create openobserve system user and directories
# =============================================================================
info "=== STEP 2: Creating openobserve system user ==="

if ! id openobserve &>/dev/null; then
    useradd --system --no-create-home --shell /sbin/nologin \
        --home-dir "${ZO_DATA_DIR}" openobserve
    ok "System user 'openobserve' created."
else
    ok "System user 'openobserve' already exists."
fi

mkdir -p "${ZO_DATA_DIR}" "${LOG_DIR}"
chown -R openobserve:openobserve "${ZO_DATA_DIR}" "${LOG_DIR}"
ok "Directories ready: ${ZO_DATA_DIR}  ${LOG_DIR}"

# =============================================================================
# STEP 3 – Download OpenObserve musl binary
# =============================================================================
info "=== STEP 3: Downloading OpenObserve ${OO_VERSION} (musl) ==="
info "  Source: ${DOWNLOAD_URL}"

curl -L --fail --progress-bar -o "${TMP_TAR}" "${DOWNLOAD_URL}" \
    || die "Download failed.\n       Visit: https://openobserve.ai/downloads/"

ok "Download complete: $(ls -lh ${TMP_TAR} | awk '{print $5}')"

# =============================================================================
# STEP 4 – Extract and install binary
# =============================================================================
info "=== STEP 4: Installing OpenObserve binary ==="

tar -xzf "${TMP_TAR}" -C /tmp/
rm -f "${TMP_TAR}"

if [[ -f "/tmp/openobserve" ]]; then
    mv /tmp/openobserve "${BINARY}"
else
    EXTRACTED=$(find /tmp -maxdepth 3 -name "openobserve" -type f 2>/dev/null | head -1)
    [[ -z "$EXTRACTED" ]] && die "Could not find extracted binary. Contents: $(ls /tmp)"
    mv "${EXTRACTED}" "${BINARY}"
fi

chmod +x "${BINARY}"

# Fix SELinux context — without this systemd gets AVC denied on execute
# (exits status=203/EXEC with: avc: denied { execute } tcontext=user_tmp_t)
restorecon -v "${BINARY}" 2>/dev/null || chcon -t bin_t "${BINARY}" 2>/dev/null || true

ok "Binary installed: ${BINARY}"
info "  Version: $("${BINARY}" --version 2>/dev/null || echo 'unknown')"

# =============================================================================
# STEP 5 – Environment file
# =============================================================================
info "=== STEP 5: Writing environment file ${ENV_FILE} ==="

cat > "${ENV_FILE}" <<EOF
# OpenObserve configuration
# Reference: https://openobserve.ai/docs/environment-variables/

# Admin credentials (only used on FIRST start to create root user)
# Email MUST be valid format: user@domain.com — @localhost will cause panic/crash
ZO_ROOT_USER_EMAIL=${ZO_ROOT_USER_EMAIL}
ZO_ROOT_USER_PASSWORD=${ZO_ROOT_USER_PASSWORD}

# Data directory
ZO_DATA_DIR=${ZO_DATA_DIR}

# HTTP server — bind on all interfaces so VM host can reach it
ZO_HTTP_PORT=${ZO_HTTP_PORT}
ZO_HTTP_ADDR=0.0.0.0

# Logging
ZO_LOG_LEVEL=info

# Single-node mode
ZO_NODE_ROLE=all

# Disable sending usage telemetry to OpenObserve Inc.
ZO_TELEMETRY=false
EOF

chmod 640 "${ENV_FILE}"
chown root:openobserve "${ENV_FILE}"
ok "Environment file written: ${ENV_FILE}"

# =============================================================================
# STEP 6 – systemd service
# =============================================================================
info "=== STEP 6: Creating systemd service ==="

# NOTE: No PrivateTmp or ReadWritePaths — these cause status=226/NAMESPACE
# on AlmaLinux 9 systemd (same issue seen with Semaphore installation).
# Running as root initially confirmed working; switched to openobserve user
# after SELinux context fix (chcon -t bin_t).
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=OpenObserve Observability Platform
Documentation=https://openobserve.ai/docs/
After=syslog.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openobserve
Group=openobserve
LimitNOFILE=65535
EnvironmentFile=${ENV_FILE}
ExecStart=${BINARY}
ExecStop=/bin/kill -s QUIT \$MAINPID
Restart=on-failure
RestartSec=10s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=openobserve
WorkingDirectory=${ZO_DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now openobserve
ok "OpenObserve service enabled and started."

# =============================================================================
# STEP 7 – Firewall
# =============================================================================
info "=== STEP 7: Firewall configuration ==="

if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${ZO_HTTP_PORT}/tcp" 2>/dev/null || true
    firewall-cmd --reload
    ok "Port ${ZO_HTTP_PORT}/tcp opened in firewalld."
else
    warn "firewalld not running — ensure port ${ZO_HTTP_PORT} is reachable."
fi

# =============================================================================
# STEP 8 – Health check
# =============================================================================
info "=== STEP 8: Waiting for OpenObserve to become ready ==="

READY=false
for i in {1..20}; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://127.0.0.1:${ZO_HTTP_PORT}/healthz" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        READY=true
        break
    fi
    info "  Waiting... (${i}/20) — HTTP ${HTTP_CODE}"
    sleep 3
done

echo ""
systemctl --no-pager status openobserve | head -8
echo ""

if $READY; then
    ok "OpenObserve is live — health check passed."
else
    warn "Did not respond in time. Check: journalctl -u openobserve -n 30 --no-pager"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${GRN}==========================================================${NC}"
echo -e "${GRN}  OpenObserve ${OO_VERSION} installation COMPLETE${NC}"
echo -e "${GRN}==========================================================${NC}"
echo ""
echo -e "  Web UI    :  ${CYN}http://${VM_IP}:${ZO_HTTP_PORT}${NC}"
echo -e "  Email     :  ${YLW}${ZO_ROOT_USER_EMAIL}${NC}"
echo -e "  Password  :  ${YLW}${ZO_ROOT_USER_PASSWORD}${NC}"
echo ""
echo -e "  Config    :  ${ENV_FILE}"
echo -e "  Data      :  ${ZO_DATA_DIR}"
echo -e "  Logs      :  ${CYN}journalctl -u openobserve -f${NC}"
echo -e "  Restart   :  ${CYN}systemctl restart openobserve${NC}"
echo -e "  Health    :  ${CYN}curl http://127.0.0.1:${ZO_HTTP_PORT}/healthz${NC}"
echo ""
echo -e "${YLW}SEND A TEST LOG:${NC}"
echo -e "  ${CYN}curl -u ${ZO_ROOT_USER_EMAIL}:${ZO_ROOT_USER_PASSWORD} \\${NC}"
echo -e "  ${CYN}  http://127.0.0.1:${ZO_HTTP_PORT}/api/default/test_stream/_json \\${NC}"
echo -e "  ${CYN}  -d '[{\"level\":\"info\",\"message\":\"Hello OpenObserve!\"}]'${NC}"
echo ""
echo -e "${YLW}Add to Windows hosts file for FQDN access:${NC}"
echo -e "  ${VM_IP}  openobserve.lab.local"
echo -e "  Then: ${CYN}http://openobserve.lab.local:${ZO_HTTP_PORT}${NC}"
echo ""
