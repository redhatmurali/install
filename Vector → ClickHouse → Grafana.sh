#!/usr/bin/env bash
# =============================================================================
#  MikroTik → Vector → ClickHouse → Grafana  |  Log Pipeline Installer
#  Platform : AlmaLinux 8 / 9  (RHEL-compatible, dnf / rpm / firewalld)
#  Run as   : root  or  sudo ./mikrotik_log_stack_almalinux.sh
# =============================================================================

# NOTE: No 'set -e' — we handle every error explicitly so nothing dies silently
set -uo pipefail

# ─── CONFIGURABLE VARIABLES ──────────────────────────────────────────────────
VECTOR_SYSLOG_PORT=514
CLICKHOUSE_DB="netaport"
CLICKHOUSE_TABLE="mikrotik_logs"
CLICKHOUSE_USER="vector"
CLICKHOUSE_PASSWORD="VectorPass@2025!"   # ← CHANGE before production
GRAFANA_PORT=3000
CLICKHOUSE_HTTP_PORT=8123
CLICKHOUSE_NATIVE_PORT=9000
SERVER_IP=$(hostname -I | awk '{print $1}')
LOGFILE="/var/log/mikrotik_stack_install.log"
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*" | tee -a "$LOGFILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOGFILE"; }
info() { echo -e "${CYAN}[i]${NC} $*"  | tee -a "$LOGFILE"; }
err()  { echo -e "${RED}[FATAL]${NC} $*" | tee -a "$LOGFILE"; echo ""; echo "Check full log: $LOGFILE"; exit 1; }
step() { echo -e "\n${CYAN}━━━ $* ━━━${NC}" | tee -a "$LOGFILE"; }

run() {
    # run "description" cmd arg arg ...
    local desc="$1"; shift
    echo -e "  ${CYAN}>>>${NC} ${desc}" | tee -a "$LOGFILE"
    if ! "$@" >> "$LOGFILE" 2>&1; then
        echo -e "  ${RED}FAILED${NC}: ${desc}" | tee -a "$LOGFILE"
        echo "  Last 10 lines of log:"
        tail -10 "$LOGFILE"
        err "Step failed: ${desc}"
    fi
}

# ─── ROOT CHECK ──────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo "Run as root: sudo $0"; exit 1; }

mkdir -p "$(dirname "$LOGFILE")"
echo "Install started: $(date)" > "$LOGFILE"

ALMA_VER=$(rpm -E '%{rhel}' 2>/dev/null || echo "9")

echo ""
echo "=================================================================="
echo "  MikroTik Log Pipeline  |  Vector + ClickHouse + Grafana"
echo "  AlmaLinux / RHEL ${ALMA_VER}    Log: ${LOGFILE}"
echo "=================================================================="
echo ""

# ═══════════════════════════════════════════════════════════════════
# STEP 1 — PREREQUISITES
# ═══════════════════════════════════════════════════════════════════
step "STEP 1 — System prerequisites"

run "Install base packages" \
    dnf install -y curl wget ca-certificates \
        policycoreutils-python-utils firewalld net-tools

# gnupg2 name varies — try both, ignore failure
dnf install -y gnupg2 >> "$LOGFILE" 2>&1 || \
    dnf install -y gnupg >> "$LOGFILE" 2>&1 || \
    warn "gnupg not found — continuing (usually pre-installed)"

dnf install -y epel-release >> "$LOGFILE" 2>&1 || \
    warn "epel-release not available — continuing"

log "Prerequisites installed."

# ═══════════════════════════════════════════════════════════════════
# STEP 2 — CLICKHOUSE
# ═══════════════════════════════════════════════════════════════════
step "STEP 2 — ClickHouse"

if command -v clickhouse-server &>/dev/null; then
    warn "ClickHouse already installed — skipping package install."
else
    log "Adding ClickHouse repo..."
    cat > /etc/yum.repos.d/clickhouse.repo << 'EOF'
[clickhouse-stable]
name=ClickHouse Stable Repository
baseurl=https://packages.clickhouse.com/rpm/stable/
gpgcheck=0
enabled=1
EOF
    # gpgcheck=0 avoids interactive key import; repo is HTTPS so still secure

    run "dnf makecache for ClickHouse" dnf makecache --repo clickhouse-stable

    run "Install clickhouse-server + client" \
        dnf install -y clickhouse-server clickhouse-client

    log "ClickHouse packages installed."
fi

run "Enable clickhouse-server"  systemctl enable clickhouse-server
run "Start clickhouse-server"   systemctl start  clickhouse-server

log "Waiting for ClickHouse to be ready..."
for i in {1..15}; do
    if clickhouse-client --query "SELECT 1" >> "$LOGFILE" 2>&1; then
        log "ClickHouse is up (attempt ${i})."
        break
    fi
    [[ $i -eq 15 ]] && err "ClickHouse did not respond after 15 attempts."
    sleep 2
done

# ═══════════════════════════════════════════════════════════════════
# STEP 3 — CLICKHOUSE SCHEMA
# ═══════════════════════════════════════════════════════════════════
step "STEP 3 — ClickHouse schema"

log "Creating database ${CLICKHOUSE_DB}..."
clickhouse-client --query \
    "CREATE DATABASE IF NOT EXISTS ${CLICKHOUSE_DB};" \
    >> "$LOGFILE" 2>&1 || err "Failed to create database"

log "Creating table ${CLICKHOUSE_TABLE}..."
clickhouse-client --database="${CLICKHOUSE_DB}" --multiquery << CHSQL >> "$LOGFILE" 2>&1 || err "Failed to create table"
CREATE TABLE IF NOT EXISTS ${CLICKHOUSE_TABLE}
(
    timestamp        DateTime64(3)  DEFAULT now64(),
    host             String,
    facility         String,
    severity         String,
    program          String,
    message          String,
    raw              String,
    mt_interface     String  DEFAULT '',
    mt_src_ip        String  DEFAULT '',
    mt_dst_ip        String  DEFAULT '',
    mt_src_port      UInt16  DEFAULT 0,
    mt_dst_port      UInt16  DEFAULT 0,
    mt_protocol      String  DEFAULT '',
    mt_action        String  DEFAULT '',
    mt_chain         String  DEFAULT '',
    mt_connection    String  DEFAULT ''
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, host, severity)
TTL timestamp + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;
CHSQL

log "Creating ClickHouse user '${CLICKHOUSE_USER}'..."
clickhouse-client --multiquery << CHSQL2 >> "$LOGFILE" 2>&1 || err "Failed to create CH user"
CREATE USER IF NOT EXISTS '${CLICKHOUSE_USER}'
    IDENTIFIED WITH plaintext_password BY '${CLICKHOUSE_PASSWORD}'
    SETTINGS readonly=0;
GRANT INSERT, SELECT ON ${CLICKHOUSE_DB}.${CLICKHOUSE_TABLE} TO '${CLICKHOUSE_USER}';
CHSQL2

log "ClickHouse schema ready."

# ═══════════════════════════════════════════════════════════════════
# STEP 4 — VECTOR
# ═══════════════════════════════════════════════════════════════════
step "STEP 4 — Vector"

if command -v vector &>/dev/null; then
    warn "Vector already installed — skipping package install."
else
    log "Adding Vector repo..."
    cat > /etc/yum.repos.d/vector.repo << 'EOF'
[vector]
name=Vector
baseurl=https://yum.vector.dev/stable/vector-0/x86_64/
enabled=1
gpgcheck=0
EOF

    run "dnf makecache for Vector" dnf makecache --repo vector
    run "Install vector"           dnf install -y vector
    log "Vector installed."
fi

# ═══════════════════════════════════════════════════════════════════
# STEP 5 — SELINUX + CAP FOR PORT 514
# ═══════════════════════════════════════════════════════════════════
step "STEP 5 — SELinux / port binding"

SELINUX_MODE=$(getenforce 2>/dev/null || echo "Disabled")
log "SELinux mode: ${SELINUX_MODE}"

if [[ "$SELINUX_MODE" == "Enforcing" ]]; then
    if command -v semanage &>/dev/null; then
        semanage port -a -t syslogd_port_t -p udp ${VECTOR_SYSLOG_PORT} >> "$LOGFILE" 2>&1 \
            || semanage port -m -t syslogd_port_t -p udp ${VECTOR_SYSLOG_PORT} >> "$LOGFILE" 2>&1 \
            || warn "semanage: port already labelled or failed — continuing"
        log "SELinux: UDP ${VECTOR_SYSLOG_PORT} labelled syslogd_port_t"
    else
        warn "semanage not found — install policycoreutils-python-utils manually if SELinux blocks vector"
    fi
fi

# setcap on the binary
if command -v setcap &>/dev/null; then
    VECTOR_BIN=$(command -v vector)
    setcap 'cap_net_bind_service=+ep' "${VECTOR_BIN}" >> "$LOGFILE" 2>&1         && log "cap_net_bind_service granted to ${VECTOR_BIN}"         || warn "setcap failed — will use systemd override instead"
else
    warn "setcap not found — will use systemd override for port binding"
fi

# systemd service override — grant AmbientCapabilities so vector can bind port <1024
# This works regardless of whether setcap succeeded, and survives package upgrades
log "Writing systemd override for vector port binding..."
mkdir -p /etc/systemd/system/vector.service.d
cat > /etc/systemd/system/vector.service.d/override.conf << 'SVCEOF'
[Service]
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStart=
ExecStart=/usr/bin/vector --config /etc/vector/vector.yaml
SVCEOF
systemctl daemon-reload >> "$LOGFILE" 2>&1
log "systemd override written."

# ═══════════════════════════════════════════════════════════════════
# STEP 6 — VECTOR CONFIG
# ═══════════════════════════════════════════════════════════════════
step "STEP 6 — Vector configuration"

mkdir -p /etc/vector
mkdir -p /var/lib/vector
# Ensure vector user owns its data dir — common cause of startup failure
if id vector &>/dev/null; then
    chown -R vector:vector /var/lib/vector /etc/vector
    chmod 750 /var/lib/vector
    log "Ownership set: vector:vector on /var/lib/vector and /etc/vector"
else
    warn "vector user not found — ownership not set"
fi

# ── Write the VRL transform file separately (quoted heredoc = no shell expansion) ──
cat > /etc/vector/mikrotik_parse.vrl << 'VRLEOF'
# Normalise core syslog fields
.timestamp = to_unix_timestamp!(now(), unit: "milliseconds")
.host      = string(.host)     ?? "unknown"
.facility  = string(.facility) ?? "unknown"
.severity  = string(.severity) ?? "info"
.program   = string(.appname)  ?? "mikrotik"
.message   = string(.message)  ?? ""
.raw       = encode_json!(.)

# msg is a local copy for matching — string() on a String field is infallible
msg = to_string!(.message)

# mt_action (input / forward / output)
.mt_action = ""
if match(msg, r'(?i)(?:^|[ ])(?:input|forward|output)(?:[ ]|$|:)') {
  parsed = parse_regex!(msg, r'(?i)(?P<action>input|forward|output)')
  .mt_action = downcase(string!(parsed.action))
}

# mt_chain=<value>
.mt_chain = ""
if match(msg, r'chain=') {
  parsed = parse_regex!(msg, r'chain=(?P<v>[^ ,]+)')
  .mt_chain = string!(parsed.v)
}

# mt_interface  in:<iface>
.mt_interface = ""
if match(msg, r'in:') {
  parsed = parse_regex!(msg, r'in:(?P<v>[^ ,]+)')
  .mt_interface = string!(parsed.v)
}

# mt_protocol  proto <TCP|UDP|...>
.mt_protocol = ""
if match(msg, r'proto ') {
  parsed = parse_regex!(msg, r'proto (?P<v>[^ ,]+)')
  .mt_protocol = string!(parsed.v)
}

# src/dst IP:port  10.0.0.1:1234->8.8.8.8:53
.mt_src_ip   = ""
.mt_dst_ip   = ""
.mt_src_port = 0
.mt_dst_port = 0
if match(msg, r'[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+:[0-9]+->[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+:[0-9]+') {
  parsed = parse_regex!(msg, r'(?P<si>[0-9]{1,3}[.][0-9]{1,3}[.][0-9]{1,3}[.][0-9]{1,3}):(?P<sp>[0-9]+)->(?P<di>[0-9]{1,3}[.][0-9]{1,3}[.][0-9]{1,3}[.][0-9]{1,3}):(?P<dp>[0-9]+)')
  .mt_src_ip   = string!(parsed.si)
  .mt_dst_ip   = string!(parsed.di)
  .mt_src_port = to_int!(parsed.sp)
  .mt_dst_port = to_int!(parsed.dp)
}

# connection-state=<value>
.mt_connection = ""
if match(msg, r'connection-state=') {
  parsed = parse_regex!(msg, r'connection-state=(?P<v>[^ ,]+)')
  .mt_connection = string!(parsed.v)
}

VRLEOF

# ── Write vector.yaml — proper YAML format (Vector RPM on RHEL requires .yaml) ──
cat > /etc/vector/vector.yaml << VECTOREOF
data_dir: /var/lib/vector

sources:
  mikrotik_syslog:
    type: syslog
    mode: udp
    address: "0.0.0.0:${VECTOR_SYSLOG_PORT}"
    host_key: host
  internal_metrics:
    type: internal_metrics

transforms:
  parse_mikrotik:
    type: remap
    inputs: [mikrotik_syslog]
    file: /etc/vector/mikrotik_parse.vrl

sinks:
  clickhouse_sink:
    type: clickhouse
    inputs: [parse_mikrotik]
    endpoint: "http://127.0.0.1:${CLICKHOUSE_HTTP_PORT}"
    database: "${CLICKHOUSE_DB}"
    table: "${CLICKHOUSE_TABLE}"
    auth:
      strategy: basic
      user: "${CLICKHOUSE_USER}"
      password: "${CLICKHOUSE_PASSWORD}"
    batch:
      max_bytes: 10485760
      timeout_secs: 5
    buffer:
      type: disk
      max_size: 536870912
      when_full: block
    request:
      retry_attempts: 5
      retry_initial_backoff_secs: 1
  prometheus_exporter:
    type: prometheus_exporter
    inputs: [internal_metrics]
    address: "0.0.0.0:9598"
VECTOREOF

log "Validating Vector config..."
VALIDATE_OUT=$(vector validate /etc/vector/vector.yaml 2>&1)
VALIDATE_RC=$?
echo "$VALIDATE_OUT" >> "$LOGFILE"
if [[ $VALIDATE_RC -ne 0 ]]; then
    echo ""
    echo "===== Vector validation errors ====="
    echo "$VALIDATE_OUT"
    echo "===================================="
    err "Vector config validation failed"
fi
log "Vector config valid."

run "Enable vector" systemctl enable vector

log "Starting vector service..."
systemctl restart vector >> "$LOGFILE" 2>&1 || true
sleep 5

if systemctl is-active --quiet vector; then
    log "Vector is running."
else
    echo ""
    echo "===== Vector service failed — journal output ====="
    journalctl -u vector --no-pager -n 40 2>&1 | tee -a "$LOGFILE"
    echo ""
    echo "===== Vector config file ====="
    cat /etc/vector/vector.yaml
    echo ""
    echo "===== VRL file ====="
    cat /etc/vector/mikrotik_parse.vrl
    echo "=================================================="
    err "Vector failed to start"
fi

# ═══════════════════════════════════════════════════════════════════
# STEP 7 — GRAFANA
# ═══════════════════════════════════════════════════════════════════
step "STEP 7 — Grafana"

if command -v grafana-server &>/dev/null; then
    warn "Grafana already installed — skipping package install."
else
    log "Adding Grafana repo..."
    cat > /etc/yum.repos.d/grafana.repo << 'EOF'
[grafana]
name=Grafana OSS
baseurl=https://rpm.grafana.com
repo_gpgcheck=0
enabled=1
gpgcheck=0
EOF

    run "dnf makecache for Grafana" dnf makecache --repo grafana
    run "Install grafana"           dnf install -y grafana
    log "Grafana installed."
fi

run "Enable grafana-server"  systemctl enable grafana-server
run "Start grafana-server"   systemctl start  grafana-server

log "Waiting for Grafana to respond..."
for i in {1..15}; do
    if curl -sf "http://127.0.0.1:${GRAFANA_PORT}/api/health" >> "$LOGFILE" 2>&1; then
        log "Grafana is up (attempt ${i})."
        break
    fi
    [[ $i -eq 15 ]] && err "Grafana did not respond after 15 attempts — see ${LOGFILE}"
    sleep 2
done

# ═══════════════════════════════════════════════════════════════════
# STEP 8 — GRAFANA CLICKHOUSE PLUGIN
# ═══════════════════════════════════════════════════════════════════
step "STEP 8 — Grafana ClickHouse plugin"

if grafana-cli --pluginsDir /var/lib/grafana/plugins \
        plugins ls 2>/dev/null | grep -q "grafana-clickhouse-datasource"; then
    warn "ClickHouse plugin already installed."
else
    log "Installing grafana-clickhouse-datasource plugin..."
    grafana-cli --pluginsDir /var/lib/grafana/plugins \
        plugins install grafana-clickhouse-datasource >> "$LOGFILE" 2>&1 \
        || warn "Plugin install returned non-zero — it may still work; check Grafana UI."
fi

# ═══════════════════════════════════════════════════════════════════
# STEP 9 — GRAFANA PROVISIONING
# ═══════════════════════════════════════════════════════════════════
step "STEP 9 — Grafana datasource + dashboard provisioning"

mkdir -p /etc/grafana/provisioning/datasources
mkdir -p /etc/grafana/provisioning/dashboards
mkdir -p /var/lib/grafana/dashboards

cat > /etc/grafana/provisioning/datasources/clickhouse.yaml << DSEOF
apiVersion: 1
datasources:
  - name: ClickHouse-MikroTik
    type: grafana-clickhouse-datasource
    uid: clickhouse-mikrotik
    access: proxy
    isDefault: true
    jsonData:
      host: 127.0.0.1
      port: ${CLICKHOUSE_NATIVE_PORT}
      username: ${CLICKHOUSE_USER}
      defaultDatabase: ${CLICKHOUSE_DB}
      tlsSkipVerify: true
    secureJsonData:
      password: "${CLICKHOUSE_PASSWORD}"
    editable: true
DSEOF

cat > /etc/grafana/provisioning/dashboards/mikrotik.yaml << DBEOF
apiVersion: 1
providers:
  - name: MikroTik
    folder: MikroTik
    type: file
    options:
      path: /var/lib/grafana/dashboards
DBEOF

cat > /var/lib/grafana/dashboards/mikrotik_logs.json << 'DASHEOF'
{
  "title": "MikroTik Logs",
  "uid": "mikrotik-logs-v1",
  "schemaVersion": 38,
  "version": 1,
  "refresh": "30s",
  "time": { "from": "now-1h", "to": "now" },
  "tags": ["mikrotik", "firewall", "syslog"],
  "panels": [
    {
      "id": 1,
      "title": "Log Rate (per minute)",
      "type": "timeseries",
      "gridPos": { "x": 0, "y": 0, "w": 24, "h": 6 },
      "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse-mikrotik" },
      "targets": [{ "rawSql": "SELECT toStartOfMinute(timestamp) AS t, count() AS logs FROM netaport.mikrotik_logs WHERE timestamp >= $__fromTime AND timestamp <= $__toTime GROUP BY t ORDER BY t", "format": "time_series" }]
    },
    {
      "id": 2,
      "title": "Severity Distribution",
      "type": "piechart",
      "gridPos": { "x": 0, "y": 6, "w": 8, "h": 6 },
      "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse-mikrotik" },
      "targets": [{ "rawSql": "SELECT severity, count() AS cnt FROM netaport.mikrotik_logs WHERE timestamp >= $__fromTime AND timestamp <= $__toTime GROUP BY severity", "format": "table" }]
    },
    {
      "id": 3,
      "title": "Top Source IPs",
      "type": "table",
      "gridPos": { "x": 8, "y": 6, "w": 8, "h": 6 },
      "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse-mikrotik" },
      "targets": [{ "rawSql": "SELECT mt_src_ip AS source_ip, count() AS hits FROM netaport.mikrotik_logs WHERE timestamp >= $__fromTime AND timestamp <= $__toTime AND mt_src_ip != '' GROUP BY mt_src_ip ORDER BY hits DESC LIMIT 20", "format": "table" }]
    },
    {
      "id": 4,
      "title": "Top Destination Ports",
      "type": "table",
      "gridPos": { "x": 16, "y": 6, "w": 8, "h": 6 },
      "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse-mikrotik" },
      "targets": [{ "rawSql": "SELECT mt_dst_port AS dst_port, mt_protocol AS proto, count() AS hits FROM netaport.mikrotik_logs WHERE timestamp >= $__fromTime AND timestamp <= $__toTime AND mt_dst_port > 0 GROUP BY mt_dst_port, mt_protocol ORDER BY hits DESC LIMIT 20", "format": "table" }]
    },
    {
      "id": 5,
      "title": "Firewall Actions",
      "type": "barchart",
      "gridPos": { "x": 0, "y": 12, "w": 12, "h": 6 },
      "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse-mikrotik" },
      "targets": [{ "rawSql": "SELECT mt_action AS action, count() AS cnt FROM netaport.mikrotik_logs WHERE timestamp >= $__fromTime AND timestamp <= $__toTime AND mt_action != '' GROUP BY mt_action ORDER BY cnt DESC", "format": "table" }]
    },
    {
      "id": 6,
      "title": "Interface Traffic",
      "type": "barchart",
      "gridPos": { "x": 12, "y": 12, "w": 12, "h": 6 },
      "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse-mikrotik" },
      "targets": [{ "rawSql": "SELECT mt_interface AS interface, count() AS cnt FROM netaport.mikrotik_logs WHERE timestamp >= $__fromTime AND timestamp <= $__toTime AND mt_interface != '' GROUP BY mt_interface ORDER BY cnt DESC", "format": "table" }]
    },
    {
      "id": 7,
      "title": "Raw Logs",
      "type": "logs",
      "gridPos": { "x": 0, "y": 18, "w": 24, "h": 10 },
      "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse-mikrotik" },
      "targets": [{ "rawSql": "SELECT timestamp AS time, host, severity, program, message FROM netaport.mikrotik_logs WHERE timestamp >= $__fromTime AND timestamp <= $__toTime ORDER BY timestamp DESC LIMIT 500", "format": "logs" }],
      "options": { "dedupStrategy": "none", "enableLogDetails": true, "showTime": true }
    }
  ]
}
DASHEOF

chown -R grafana:grafana /var/lib/grafana/dashboards /etc/grafana/provisioning
run "Restart Grafana to load provisioning" systemctl restart grafana-server

log "Waiting for Grafana to come back up..."
for i in {1..15}; do
    if curl -sf "http://127.0.0.1:${GRAFANA_PORT}/api/health" >> "$LOGFILE" 2>&1; then
        log "Grafana is up."; break
    fi
    sleep 2
done

# ═══════════════════════════════════════════════════════════════════
# STEP 10 — FIREWALLD
# ═══════════════════════════════════════════════════════════════════
step "STEP 10 — Firewalld"

run "Enable firewalld"  systemctl enable firewalld
run "Start firewalld"   systemctl start  firewalld

firewall-cmd --permanent --add-port=${VECTOR_SYSLOG_PORT}/udp >> "$LOGFILE" 2>&1
firewall-cmd --permanent --add-port=${GRAFANA_PORT}/tcp       >> "$LOGFILE" 2>&1
# ClickHouse stays localhost-only by default
# Uncomment to expose:
# firewall-cmd --permanent --add-port=${CLICKHOUSE_HTTP_PORT}/tcp
# firewall-cmd --permanent --add-port=${CLICKHOUSE_NATIVE_PORT}/tcp
firewall-cmd --reload >> "$LOGFILE" 2>&1
log "Firewall rules applied."

# ═══════════════════════════════════════════════════════════════════
# STEP 11 — HEALTH CHECK
# ═══════════════════════════════════════════════════════════════════
step "STEP 11 — Health check"

ERRORS=0
ok()   { echo -e "  ${GREEN}[OK]${NC}   $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; ERRORS=$((ERRORS+1)); }

systemctl is-active --quiet clickhouse-server && ok  "clickhouse-server running" || fail "clickhouse-server NOT running"
systemctl is-active --quiet vector            && ok  "vector running"             || fail "vector NOT running"
systemctl is-active --quiet grafana-server    && ok  "grafana-server running"     || fail "grafana-server NOT running"
systemctl is-active --quiet firewalld         && ok  "firewalld running"          || fail "firewalld NOT running"

curl -sf "http://127.0.0.1:${CLICKHOUSE_HTTP_PORT}/ping" >> "$LOGFILE" 2>&1 \
    && ok "ClickHouse HTTP ping OK" \
    || fail "ClickHouse HTTP not reachable"

clickhouse-client --user="${CLICKHOUSE_USER}" \
    --password="${CLICKHOUSE_PASSWORD}" \
    --query="SELECT count() FROM ${CLICKHOUSE_DB}.${CLICKHOUSE_TABLE}" >> "$LOGFILE" 2>&1 \
    && ok "ClickHouse auth + table OK" \
    || fail "ClickHouse user/table check failed"

curl -sf "http://127.0.0.1:${GRAFANA_PORT}/api/health" >> "$LOGFILE" 2>&1 \
    && ok "Grafana API healthy" \
    || fail "Grafana API not responding"

# ─── MIKROTIK COMMANDS ───────────────────────────────────────────────────────
echo ""
echo "=================================================================="
echo "  MikroTik Configuration  — paste into Winbox Terminal / SSH"
echo "=================================================================="
echo ""
echo -e "  ${CYAN}/system logging action${NC}"
echo "  add name=remote-vector target=remote \\"
echo "      remote=${SERVER_IP} remote-port=${VECTOR_SYSLOG_PORT} \\"
echo "      bsd-syslog=yes syslog-facility=daemon syslog-severity=auto"
echo ""
echo -e "  ${CYAN}/system logging${NC}"
echo "  add action=remote-vector topics=firewall"
echo "  add action=remote-vector topics=info"
echo "  add action=remote-vector topics=warning"
echo "  add action=remote-vector topics=error"
echo "  add action=remote-vector topics=critical"
echo ""

# ─── SUMMARY ─────────────────────────────────────────────────────────────────
echo "=================================================================="
echo "  Summary"
echo "=================================================================="
echo ""
info "Server IP       : ${SERVER_IP}"
info "MikroTik syslog : UDP ${SERVER_IP}:${VECTOR_SYSLOG_PORT}"
info "Grafana UI      : http://${SERVER_IP}:${GRAFANA_PORT}   (admin/admin)"
info "Dashboard       : MikroTik Logs  (folder: MikroTik)"
info "ClickHouse DB   : ${CLICKHOUSE_DB}.${CLICKHOUSE_TABLE}  (localhost only)"
info "Full install log: ${LOGFILE}"
echo ""
info "Useful commands:"
info "  journalctl -u vector            -f"
info "  journalctl -u grafana-server    -f"
info "  journalctl -u clickhouse-server -f"
info "  vector tap --inputs-of clickhouse_sink   # live log preview"
echo ""

if [[ ${ERRORS} -eq 0 ]]; then
    echo -e "${GREEN}=================================================================="
    echo -e "  ALL CHECKS PASSED — Pipeline is READY"
    echo -e "  Open: http://${SERVER_IP}:${GRAFANA_PORT}"
    echo -e "==================================================================${NC}"
else
    echo -e "${RED}=================================================================="
    echo -e "  ${ERRORS} check(s) FAILED"
    echo -e "  Review: ${LOGFILE}"
    echo -e "  Or run: journalctl -u <service> --no-pager -n 50"
    echo -e "==================================================================${NC}"
    exit 1
fi
echo ""

