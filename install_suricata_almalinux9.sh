#!/usr/bin/env bash
# =============================================================================
# Suricata Installation Script for AlmaLinux 9
# Based on official OISF documentation
# Usage: sudo bash install_suricata_almalinux9.sh
# =============================================================================

set -euo pipefail

# --- Colour helpers ----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Root check --------------------------------------------------------------
[[ $EUID -ne 0 ]] && error "Run this script as root or with sudo."

# --- Variables ---------------------------------------------------------------
INTERFACE="${1:-eth0}"          # Override: sudo bash script.sh ens3
SURICATA_CONF="/etc/suricata/suricata.yaml"
LOG_DIR="/var/log/suricata"

# =============================================================================
# STEP 1 – System update
# =============================================================================
info "Updating system packages..."
dnf -y update
success "System updated."

# =============================================================================
# STEP 2 – Enable required repositories
# =============================================================================
info "Installing EPEL and dnf-plugins-core..."
dnf -y install epel-release dnf-plugins-core

info "Enabling CRB (CodeReady Builder) repository for AlmaLinux 9..."
dnf config-manager --set-enable crb
success "Repositories configured."

# =============================================================================
# STEP 3 – Install Suricata from EPEL
# =============================================================================
info "Installing Suricata..."
dnf -y install suricata
success "Suricata installed: $(suricata --build-info | grep 'Version' | head -1)"

# =============================================================================
# STEP 4 – Update Suricata rules via suricata-update
# =============================================================================
info "Updating Suricata rules (Emerging Threats Open)..."
suricata-update
success "Rules updated."

# List available free rule sources (informational, no exit on fail)
info "Listing available free rule sources..."
suricata-update list-sources --free || warn "Could not list rule sources – continuing."

# =============================================================================
# STEP 5 – Configure the monitored network interface
# =============================================================================
if ! ip link show "$INTERFACE" &>/dev/null; then
    warn "Interface '$INTERFACE' not found. Detecting default interface..."
    INTERFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    [[ -z "$INTERFACE" ]] && error "Cannot determine default interface. Pass it as argument: sudo bash $0 <interface>"
    warn "Using detected interface: $INTERFACE"
fi

info "Setting monitored interface to: $INTERFACE"
sed -i "s/^  - interface: .*/  - interface: $INTERFACE/" "$SURICATA_CONF"
success "Interface set to $INTERFACE in $SURICATA_CONF"

# =============================================================================
# STEP 6 – Configure HOME_NET (optional – edit as needed)
# =============================================================================
# Uncomment and adjust if your network range differs from RFC-1918 defaults
# HOME_NET="[192.168.0.0/16,10.0.0.0/8,172.16.0.0/12]"
# sed -i "s|HOME_NET:.*|HOME_NET: \"$HOME_NET\"|" "$SURICATA_CONF"

# =============================================================================
# STEP 7 – Set up log directory permissions
# =============================================================================
info "Ensuring log directory exists and has correct permissions..."
mkdir -p "$LOG_DIR"
chown -R suricata:suricata "$LOG_DIR" 2>/dev/null || true
success "Log directory: $LOG_DIR"

# =============================================================================
# STEP 8 – Validate configuration
# =============================================================================
info "Validating Suricata configuration..."
suricata -T -c "$SURICATA_CONF" && success "Configuration is valid." || error "Configuration validation failed. Check $SURICATA_CONF"

# =============================================================================
# STEP 9 – Enable and start Suricata service
# =============================================================================
info "Enabling and starting Suricata service..."
systemctl enable --now suricata
sleep 3

if systemctl is-active --quiet suricata; then
    success "Suricata service is running."
else
    error "Suricata failed to start. Check: journalctl -u suricata -n 50"
fi

# =============================================================================
# STEP 10 – Configure firewalld (drop noisy rules if needed)
# =============================================================================
if systemctl is-active --quiet firewalld; then
    info "firewalld is active – Suricata runs in IDS mode and needs no firewall changes."
    info "If running in IPS/NFQ mode, you would add NFQUEUE rules here."
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Suricata installation complete on AlmaLinux 9${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "  Monitored interface : ${CYAN}$INTERFACE${NC}"
echo -e "  Config file         : ${CYAN}$SURICATA_CONF${NC}"
echo -e "  Log directory       : ${CYAN}$LOG_DIR${NC}"
echo -e "  Rules directory     : ${CYAN}/var/lib/suricata/rules/${NC}"
echo ""
echo -e "  Useful commands:"
echo -e "    ${YELLOW}systemctl status suricata${NC}          – service status"
echo -e "    ${YELLOW}suricata-update${NC}                    – refresh rules"
echo -e "    ${YELLOW}tail -f $LOG_DIR/fast.log${NC}  – live alerts"
echo -e "    ${YELLOW}tail -f $LOG_DIR/eve.json${NC}  – full JSON log"
echo -e "    ${YELLOW}journalctl -u suricata -f${NC}          – service logs"
echo -e "${GREEN}============================================================${NC}"
