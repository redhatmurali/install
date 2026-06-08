#!/bin/bash
# =============================================================================
# Wazuh 4.x All-in-One Installation Script for AlmaLinux 9
# Components: Wazuh Indexer + Wazuh Manager + Wazuh Dashboard (Single Node)
# Author  : NETAPORT.COM / Murali Krishna K
# Version : 1.0
# Tested  : AlmaLinux 9.x
# =============================================================================

set -euo pipefail

# ─── COLOUR OUTPUT ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }

# ─── ROOT CHECK ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Run this script as root (sudo bash $0)"

# ─── VARIABLES ────────────────────────────────────────────────────────────────
WAZUH_VERSION="4.9.2"                        # Change to target version if needed
NODE_NAME="wazuh-node-1"
NODE_IP=$(hostname -I | awk '{print $1}')    # Auto-detect primary IP
WAZUH_ADMIN_PASS="WazuhAdmin@$(date +%Y)"   # Change before production use
INDEXER_PORT=9200
DASHBOARD_PORT=443

INSTALL_LOG="/var/log/wazuh-install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$INSTALL_LOG") 2>&1

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Wazuh ${WAZUH_VERSION} — AlmaLinux 9 — All-in-One Install   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
info "Node IP   : $NODE_IP"
info "Log file  : $INSTALL_LOG"
echo ""

# ─── STEP 1: SYSTEM PREREQUISITES ────────────────────────────────────────────
info "Step 1/8 — Updating system and installing prerequisites..."
dnf update -y -q
dnf install -y -q curl wget tar openssl gnupg2 lsof net-tools policycoreutils-python-utils \
    libcap checkpolicy setroubleshoot-server
success "Prerequisites installed."

# ─── STEP 2: KERNEL / JVM TUNING ─────────────────────────────────────────────
info "Step 2/8 — Applying kernel tuning for Wazuh Indexer (OpenSearch)..."

sysctl_conf="/etc/sysctl.d/99-wazuh.conf"
cat > "$sysctl_conf" <<'EOF'
# Wazuh Indexer (OpenSearch) tuning
vm.max_map_count = 262144
net.core.somaxconn = 65535
EOF
sysctl --system -q
success "Kernel parameters applied."

# Increase open file limits
limits_conf="/etc/security/limits.d/99-wazuh.conf"
cat > "$limits_conf" <<'EOF'
wazuh-indexer  soft  nofile  65536
wazuh-indexer  hard  nofile  65536
wazuh           soft  nofile  65536
wazuh           hard  nofile  65536
EOF
success "File limits configured."

# ─── STEP 3: DISABLE SWAP ─────────────────────────────────────────────────────
info "Step 3/8 — Disabling swap (recommended for OpenSearch)..."
swapoff -a
sed -i '/\bswap\b/s/^/#/' /etc/fstab
success "Swap disabled."

# ─── STEP 4: FIREWALL RULES ───────────────────────────────────────────────────
info "Step 4/8 — Configuring firewalld rules..."
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=1514/tcp   # Wazuh agent (TCP)
    firewall-cmd --permanent --add-port=1514/udp   # Wazuh agent (UDP)
    firewall-cmd --permanent --add-port=1515/tcp   # Agent registration
    firewall-cmd --permanent --add-port=1516/tcp   # Wazuh cluster
    firewall-cmd --permanent --add-port=55000/tcp  # Wazuh API
    firewall-cmd --permanent --add-port=9200/tcp   # Wazuh Indexer REST
    firewall-cmd --permanent --add-port=9300/tcp   # Wazuh Indexer cluster
    firewall-cmd --permanent --add-port=443/tcp    # Wazuh Dashboard
    firewall-cmd --reload
    success "Firewall rules applied."
else
    warn "firewalld not running — skipping firewall configuration."
fi

# ─── STEP 5: SELINUX PERMISSIVE (optional — remove to keep enforcing) ─────────
info "Step 5/8 — Adjusting SELinux to permissive mode..."
setenforce 0 || true
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
warn "SELinux set to permissive. Harden after deployment if required."

# ─── STEP 6: ADD WAZUH REPOSITORY ────────────────────────────────────────────
info "Step 6/8 — Adding Wazuh repository..."

rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH

cat > /etc/yum.repos.d/wazuh.repo <<EOF
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=EL-\$releasever - Wazuh
baseurl=https://packages.wazuh.com/4.x/yum/
protect=1
EOF
success "Wazuh repo added."

# ─── STEP 7: DOWNLOAD WAZUH INSTALLER ────────────────────────────────────────
info "Step 7/8 — Downloading Wazuh installation assistant..."
cd /tmp
curl -sO https://packages.wazuh.com/4.9/wazuh-install.sh
curl -sO https://packages.wazuh.com/4.9/config.yml
chmod +x wazuh-install.sh
success "Wazuh installer downloaded."

# ─── STEP 8: GENERATE CONFIG AND INSTALL ─────────────────────────────────────
info "Step 8/8 — Generating config.yml and running all-in-one install..."

# Write a single-node config.yml
cat > /tmp/config.yml <<EOF
nodes:
  indexer:
    - name: ${NODE_NAME}
      ip: "${NODE_IP}"
  server:
    - name: ${NODE_NAME}
      ip: "${NODE_IP}"
  dashboard:
    - name: ${NODE_NAME}
      ip: "${NODE_IP}"
EOF

info "Running wazuh-install.sh -a (all-in-one)... This may take 5–15 minutes."
bash /tmp/wazuh-install.sh -a -i    # -i = ignore system checks (AlmaLinux compat)

# ─── POST-INSTALL: SAVE CREDENTIALS ──────────────────────────────────────────
CREDS_FILE="/root/wazuh-credentials.txt"
cat > "$CREDS_FILE" <<EOF
# Wazuh Installation Credentials
# Generated: $(date)
# ─────────────────────────────────
Dashboard URL  : https://${NODE_IP}
Default User   : admin
Password       : (check wazuh-install-files.tar — extracted below)

Wazuh API URL  : https://${NODE_IP}:55000
API User       : wazuh
API Password   : (see wazuh-passwords.txt in wazuh-install-files/)

Indexer URL    : https://${NODE_IP}:9200
EOF
chmod 600 "$CREDS_FILE"

# Extract the generated passwords tar
if [[ -f /tmp/wazuh-install-files.tar ]]; then
    tar -xf /tmp/wazuh-install-files.tar -C /root/
    info "Credentials extracted to /root/wazuh-install-files/"
fi

# ─── SERVICE STATUS ───────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  Wazuh ${WAZUH_VERSION} Installation Complete!${RESET}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "${BOLD}Service Status:${RESET}"
for svc in wazuh-indexer wazuh-manager wazuh-dashboard; do
    status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    if [[ "$status" == "active" ]]; then
        echo -e "  ${GREEN}●${RESET} ${svc}: ${GREEN}${status}${RESET}"
    else
        echo -e "  ${RED}●${RESET} ${svc}: ${RED}${status}${RESET}"
    fi
done

echo ""
echo -e "${BOLD}Access:${RESET}"
echo -e "  Dashboard : ${CYAN}https://${NODE_IP}${RESET}"
echo -e "  API       : ${CYAN}https://${NODE_IP}:55000${RESET}"
echo -e "  Indexer   : ${CYAN}https://${NODE_IP}:9200${RESET}"
echo ""
echo -e "${BOLD}Credentials file:${RESET} ${YELLOW}/root/wazuh-credentials.txt${RESET}"
echo -e "${BOLD}Install log:${RESET}      ${YELLOW}${INSTALL_LOG}${RESET}"
echo ""
echo -e "${YELLOW}NOTE: Check /root/wazuh-install-files/wazuh-passwords.txt for all passwords.${RESET}"
echo ""

# ─── OPTIONAL: ENABLE WAZUH AGENT ON THIS HOST ───────────────────────────────
# Uncomment below to also enroll this host as an agent
# WAZUH_MANAGER="${NODE_IP}" \
# WAZUH_AGENT_GROUP="default" \
# bash /var/ossec/bin/agent-auth -m "${NODE_IP}"
# systemctl enable --now wazuh-agent

exit 0
