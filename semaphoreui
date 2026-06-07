#!/usr/bin/env bash
# =============================================================================
#  Semaphore UI 2.18.9 – Installation Script
#  Target OS  : AlmaLinux 9.x (x86_64)  |  VMware (no external DNS)
#  Database   : MariaDB (local, mysql_native_password auth)
#  Ansible    : pip virtualenv (no EPEL needed)
#  Web UI     : http://<VM_IP>:3000
#
#  Reference  : https://semaphoreui.com/docs/admin-guide/installation
#  GitHub     : https://github.com/semaphoreui/semaphore/releases/tag/v2.18.9
#
#  IMPORTANT  : Run as root on a fresh AlmaLinux 9 VM.
#  Usage      : chmod +x semaphore-install-almalinux9.sh
#               sudo ./semaphore-install-almalinux9.sh
#
#  Optional env vars (set before running to override defaults):
#    SEMAPHORE_VERSION   default: 2.18.9
#    SEMAPHORE_PORT      default: 3000
#    DB_NAME             default: semaphore
#    DB_USER             default: semaphore
#    DB_PASS             default: SemPass2024!   <-- CHANGE THIS
#    ADMIN_USER          default: admin
#    ADMIN_PASS          default: Admin2024!     <-- CHANGE THIS
#    ADMIN_EMAIL         default: admin@localhost
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
SEMAPHORE_VERSION="${SEMAPHORE_VERSION:-2.18.9}"
SEMAPHORE_PORT="${SEMAPHORE_PORT:-3000}"
DB_NAME="${DB_NAME:-semaphore}"
DB_USER="${DB_USER:-semaphore}"
DB_PASS="${DB_PASS:-SemPass2024!}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-Admin2024!}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@localhost}"

VM_IP=$(ip -4 addr show scope global | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
[[ -z "$VM_IP" ]] && die "Could not detect a non-loopback IPv4 address."

RPM_URL="https://github.com/semaphoreui/semaphore/releases/download/v${SEMAPHORE_VERSION}/semaphore_${SEMAPHORE_VERSION}_linux_amd64.rpm"
CONFIG_DIR="/etc/semaphore"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/semaphore.service"
VENV_DIR="/opt/semaphore-venv"
SEMAPHORE_HOME="/var/lib/semaphore"
TMP_DIR="/tmp/semaphore"

echo ""
echo -e "${GRN}==========================================================${NC}"
echo -e "${GRN}  Semaphore UI ${SEMAPHORE_VERSION} Installer – AlmaLinux 9${NC}"
echo -e "${GRN}==========================================================${NC}"
echo -e "  VM IP       : ${VM_IP}"
echo -e "  Web UI port : ${SEMAPHORE_PORT}"
echo -e "  Database    : MariaDB  (db=${DB_NAME}, user=${DB_USER})"
echo -e "  Admin user  : ${ADMIN_USER}"
echo ""

# =============================================================================
# PRE-FLIGHT – DNS check + stale repo cleanup
# =============================================================================
info "=== PRE-FLIGHT: DNS check and repo cleanup ==="

# Remove any stale semaphore yum repo files from previous failed attempts.
# This script installs via direct GitHub RPM download — no semaphoreui.com repo needed.
for f in /etc/yum.repos.d/semaphore*.repo /etc/yum.repos.d/semaphoreui*.repo; do
    [[ -f "$f" ]] && { warn "Removing stale repo file: $f"; rm -f "$f"; }
done
ok "Repo cleanup done."

# Ensure DNS works — VMware minimal installs often have no nameserver configured.
DNS_OK=false
for ns in 8.8.8.8 8.8.4.4 1.1.1.1; do
    if getent hosts github.com &>/dev/null; then
        DNS_OK=true
        break
    fi
    warn "DNS not resolving – adding nameserver ${ns} to /etc/resolv.conf"
    sed -i "1s/^/nameserver ${ns}\n/" /etc/resolv.conf
    sleep 1
done
$DNS_OK || getent hosts github.com &>/dev/null && DNS_OK=true

if ! $DNS_OK; then
    die "DNS resolution still failing.\n       Manual fix: echo 'nameserver 8.8.8.8' >> /etc/resolv.conf"
fi
ok "DNS resolution is working."

# Make DNS persistent so it survives reboots (NetworkManager overwrites resolv.conf by default)
NM_CONF="/etc/NetworkManager/conf.d/99-dns-override.conf"
if [[ ! -f "${NM_CONF}" ]]; then
    cat > "${NM_CONF}" <<EOF
[main]
dns=none
EOF
    {
        echo "# Managed by semaphore-install script"
        echo "nameserver 8.8.8.8"
        echo "nameserver 8.8.4.4"
        grep "^nameserver" /etc/resolv.conf 2>/dev/null | grep -v "8.8.8.8\|8.8.4.4" || true
    } > /etc/resolv.conf
    systemctl reload NetworkManager 2>/dev/null || true
    ok "DNS made persistent (8.8.8.8, 8.8.4.4)."
fi

# =============================================================================
# STEP 1 – System update + dependencies
# =============================================================================
info "=== STEP 1: System update and dependencies ==="

dnf upgrade -y
dnf install -y \
    git \
    wget \
    curl \
    tar \
    python3 \
    python3-pip \
    python3-devel \
    gcc \
    sshpass \
    mariadb-server \
    mariadb

# python3-virtualenv does not exist on EL9 minimal — venv is built into Python 3.9
python3 -m ensurepip --upgrade 2>/dev/null || true
python3 -m pip install --quiet --upgrade pip virtualenv

ok "System packages installed."

# =============================================================================
# STEP 2 – MariaDB setup
# =============================================================================
info "=== STEP 2: MariaDB setup ==="

systemctl enable --now mariadb
ok "MariaDB started."

# AlmaLinux 9 MariaDB defaults to unix_socket auth — the semaphore Go driver
# connects over TCP with a password, so we must use mysql_native_password
# explicitly. Without this, the driver presents as user ''@'localhost' and fails.
mysql -u root <<SQL
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${DB_PASS}');
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# Verify auth plugin is correct
PLUGIN=$(mysql -u root -se "SELECT plugin FROM mysql.user WHERE User='${DB_USER}' AND Host='localhost';")
info "  Auth plugin for '${DB_USER}': ${PLUGIN}"
[[ "$PLUGIN" == "mysql_native_password" ]] || die "DB user does not have mysql_native_password."

# Verify TCP login works (same method Semaphore's Go driver uses)
mysql -u "${DB_USER}" -p"${DB_PASS}" -h 127.0.0.1 \
    -e "SELECT 'TCP login OK';" "${DB_NAME}" \
    && ok "MariaDB TCP login verified." \
    || die "MariaDB TCP login FAILED. Check password and auth plugin."

ok "MariaDB database '${DB_NAME}' and user '${DB_USER}' ready."

# =============================================================================
# STEP 3 – Ansible via Python virtualenv
# =============================================================================
info "=== STEP 3: Installing Ansible in a Python virtualenv ==="

# python3 -m venv is built into Python 3.9 on EL9 minimal
if python3 -m venv "${VENV_DIR}" 2>/dev/null; then
    ok "venv created with python3 -m venv"
else
    warn "python3 -m venv failed, trying pip virtualenv..."
    python3 -m pip install --quiet virtualenv
    python3 -m virtualenv "${VENV_DIR}"
fi

"${VENV_DIR}/bin/pip" install --upgrade pip --quiet
"${VENV_DIR}/bin/pip" install --quiet \
    ansible \
    netaddr \
    jmespath \
    passlib \
    requests

ANSIBLE_BIN="${VENV_DIR}/bin/ansible"
ok "Ansible installed: $(${ANSIBLE_BIN} --version | head -1)"

# =============================================================================
# STEP 4 – Download and install Semaphore RPM
# =============================================================================
info "=== STEP 4: Downloading Semaphore v${SEMAPHORE_VERSION} RPM ==="

TMP_RPM="/tmp/semaphore_${SEMAPHORE_VERSION}_linux_amd64.rpm"
wget -q --show-progress -O "${TMP_RPM}" "${RPM_URL}" || \
    die "Download failed. Check: https://github.com/semaphoreui/semaphore/releases"

dnf install -y "${TMP_RPM}"
rm -f "${TMP_RPM}"

SEMAPHORE_BIN=$(command -v semaphore)
ok "Semaphore RPM installed: $(semaphore version)"

# =============================================================================
# STEP 5 – System user and directories
# =============================================================================
info "=== STEP 5: Creating semaphore system user ==="

if ! id semaphore &>/dev/null; then
    useradd --system --no-create-home --shell /sbin/nologin \
        --home-dir "${SEMAPHORE_HOME}" semaphore
fi

mkdir -p "${CONFIG_DIR}" "${SEMAPHORE_HOME}" "${TMP_DIR}"
chown -R semaphore:semaphore "${SEMAPHORE_HOME}" "${TMP_DIR}"
ok "User and directories ready."

# =============================================================================
# STEP 6 – Generate config.json
# =============================================================================
info "=== STEP 6: Writing ${CONFIG_FILE} ==="

COOKIE_HASH=$(openssl rand -hex 16)
COOKIE_ENCRYPT=$(openssl rand -hex 16)
ACCESS_KEY_ENCRYPT=$(openssl rand -hex 16)

# IMPORTANT: Semaphore v2.x requires flat top-level keys with "dialect" field.
# A nested "mysql:{}" block is NOT read correctly and causes the binary to fall
# back to BoltDB, panicking on the interface address as a file path.
cat > "${CONFIG_FILE}" <<EOF
{
  "dialect": "mysql",
  "db_host": "127.0.0.1:3306",
  "db_user": "${DB_USER}",
  "db_pass": "${DB_PASS}",
  "db_name": "${DB_NAME}",
  "interface": "",
  "port": "${SEMAPHORE_PORT}",
  "tmp_path": "${TMP_DIR}",
  "cookie_hash": "${COOKIE_HASH}",
  "cookie_encryption": "${COOKIE_ENCRYPT}",
  "access_key_encryption": "${ACCESS_KEY_ENCRYPT}",
  "email_alert": false,
  "telegram_alert": false,
  "slack_alert": false,
  "ldap_enable": false,
  "ldap_needtls": false,
  "web_host": "http://${VM_IP}:${SEMAPHORE_PORT}",
  "ansible_path": "${VENV_DIR}/bin"
}
EOF

# Semaphore user must be able to read its own config
chown semaphore:semaphore "${CONFIG_FILE}"
chmod 640 "${CONFIG_FILE}"
ok "Config written to ${CONFIG_FILE}"

# =============================================================================
# STEP 7 – Database migrations + admin user
# =============================================================================
info "=== STEP 7: Running database migrations ==="

# Semaphore v2.18 migrate/server subcommands do not reliably read --config alone.
# Setting SEMAPHORE_DB_* env vars forces the Go driver to use TCP+password auth
# instead of falling back to unix socket (which presents as user ''@'localhost').
export SEMAPHORE_CONFIG_PATH="${CONFIG_FILE}"
export SEMAPHORE_DB_DIALECT=mysql
export SEMAPHORE_DB_HOST="127.0.0.1:3306"
export SEMAPHORE_DB_USER="${DB_USER}"
export SEMAPHORE_DB_PASS="${DB_PASS}"
export SEMAPHORE_DB_NAME="${DB_NAME}"

"${SEMAPHORE_BIN}" migrate --config "${CONFIG_FILE}"
ok "Database schema migrated."

info "  Creating admin user '${ADMIN_USER}'..."
"${SEMAPHORE_BIN}" user add \
    --admin \
    --login    "${ADMIN_USER}" \
    --name     "Administrator" \
    --email    "${ADMIN_EMAIL}" \
    --password "${ADMIN_PASS}" \
    --config   "${CONFIG_FILE}" || warn "Admin user may already exist — continuing."

unset SEMAPHORE_CONFIG_PATH SEMAPHORE_DB_DIALECT SEMAPHORE_DB_HOST
unset SEMAPHORE_DB_USER SEMAPHORE_DB_PASS SEMAPHORE_DB_NAME

# Lock down ownership after all CLI operations are done as root
chown -R semaphore:semaphore "${CONFIG_DIR}" "${SEMAPHORE_HOME}" "${TMP_DIR}"
chmod 640 "${CONFIG_FILE}"
ok "Admin user '${ADMIN_USER}' ready."

# =============================================================================
# STEP 8 – systemd service
# =============================================================================
info "=== STEP 8: Creating systemd service ==="

# IMPORTANT lessons learned:
# 1. PrivateTmp=yes + ReadWritePaths=/tmp/semaphore causes status=226/NAMESPACE
#    on AlmaLinux 9 — systemd can't bind-mount a pre-created dir into its private
#    namespace. Removed entirely.
# 2. The server subcommand also needs SEMAPHORE_DB_* env vars — without them it
#    ignores config file DB credentials and connects as the Linux user via socket,
#    resulting in "Access denied for user ''@'localhost'".
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Semaphore Ansible UI
Documentation=https://semaphoreui.com/docs
After=network.target mariadb.service
Wants=mariadb.service

[Service]
Type=simple
User=semaphore
Group=semaphore
WorkingDirectory=${SEMAPHORE_HOME}

# DB credentials must be passed as env vars — Semaphore v2.18 does not reliably
# read them from config file when running as a non-root service user.
Environment=SEMAPHORE_DB_DIALECT=mysql
Environment=SEMAPHORE_DB_HOST=127.0.0.1:3306
Environment=SEMAPHORE_DB_USER=${DB_USER}
Environment=SEMAPHORE_DB_PASS=${DB_PASS}
Environment=SEMAPHORE_DB_NAME=${DB_NAME}

ExecStart=${SEMAPHORE_BIN} server --config ${CONFIG_FILE}
Restart=on-failure
RestartSec=10s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=semaphore

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now semaphore
ok "Semaphore service enabled and started."

# =============================================================================
# STEP 9 – Firewall
# =============================================================================
info "=== STEP 9: Firewall configuration ==="

if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${SEMAPHORE_PORT}/tcp" 2>/dev/null || true
    firewall-cmd --reload
    ok "Port ${SEMAPHORE_PORT}/tcp open in firewalld."
else
    warn "firewalld not running — ensure port ${SEMAPHORE_PORT} is reachable."
fi

# =============================================================================
# STEP 10 – Health check
# =============================================================================
info "=== STEP 10: Waiting for Semaphore to become ready ==="

READY=false
for i in {1..15}; do
    if curl -sf "http://127.0.0.1:${SEMAPHORE_PORT}/api/ping" &>/dev/null; then
        READY=true
        break
    fi
    info "  Waiting... (${i}/15)"
    sleep 3
done

echo ""
systemctl --no-pager status semaphore | head -8
echo ""

if $READY; then
    ok "Semaphore is live and responding."
else
    warn "Semaphore did not respond within timeout. Check: journalctl -u semaphore -n 30"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${GRN}==========================================================${NC}"
echo -e "${GRN}  Semaphore UI ${SEMAPHORE_VERSION} installation COMPLETE${NC}"
echo -e "${GRN}==========================================================${NC}"
echo ""
echo -e "  Web UI    :  ${CYN}http://${VM_IP}:${SEMAPHORE_PORT}${NC}"
echo -e "  Username  :  ${YLW}${ADMIN_USER}${NC}"
echo -e "  Password  :  ${YLW}${ADMIN_PASS}${NC}"
echo ""
echo -e "  Config    :  ${CONFIG_FILE}"
echo -e "  Logs      :  ${CYN}journalctl -u semaphore -f${NC}"
echo -e "  Restart   :  ${CYN}systemctl restart semaphore${NC}"
echo ""
echo -e "${YLW}FIRST-USE CHECKLIST in the web UI:${NC}"
echo -e "  1. Key Store    → Add SSH private key for managed hosts"
echo -e "  2. Inventory    → Add your host inventory file"
echo -e "  3. Repositories → Point to Git repo with your playbooks"
echo -e "  4. Templates    → Create Task Template (playbook + inventory + key)"
echo -e "  5. Tasks        → Run your first playbook!"
echo ""
echo -e "${YLW}Access from VMware host — add to Windows hosts file:${NC}"
echo -e "  ${CYN}C:\\Windows\\System32\\drivers\\etc\\hosts${NC}"
echo -e "  ${VM_IP}  semaphore.lab.local  semaphore"
echo -e "  Then browse: ${CYN}http://semaphore.lab.local:${SEMAPHORE_PORT}${NC}"
echo ""
