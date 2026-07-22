#!/usr/bin/env bash
#===============================================================================
#  phpBB x20 - ONE-COMMAND INSTALLER for AlmaLinux 9 (local VMware lab, IP only)
#
#  RUN:   sudo ./phpbb20.sh
#
#  Result: 20 fully installed phpBB boards at
#          http://<VM-IP>:8001  ...  http://<VM-IP>:8020
#          index page at http://<VM-IP>/
#          passwords in /root/phpbb-credentials/
#
#  WITH SELF-SIGNED SSL:
#         sudo SSL=1 ./phpbb20.sh
#         -> https://<VM-IP>:9001 ... :9020   (http ports 301-redirect to https)
#         -> ONE cert shared by all 20, with the IP in subjectAltName
#
#  Optional (only if you need them):
#     sudo COUNT=5 ./phpbb20.sh          # fewer boards
#     sudo IP=192.168.1.106 ./phpbb20.sh # pin the IP instead of auto-detect
#     sudo FORCE=1 ./phpbb20.sh          # wipe and rebuild everything
#     sudo PHPBB_VER=3.3.16 ./phpbb20.sh # install a specific phpBB version
#     sudo PHPBB_VER=auto ./phpbb20.sh   # always grab the newest 3.3.x
#
#  Default phpBB version: 3.3.17
# certutil -addstore -f Root "D:\phpbb-lab.crt"
# sudo SSL=1 FORCE=1 ./phpbb20.sh
#===============================================================================
set -euo pipefail

COUNT="${COUNT:-20}"
BASE_PORT="${BASE_PORT:-8001}"
SSL="${SSL:-0}"
TLS_BASE_PORT="${TLS_BASE_PORT:-9001}"
CRT="/etc/pki/tls/certs/phpbb-lab.crt"
KEY="/etc/pki/tls/private/phpbb-lab.key"
PREFIX="phpbb"
WEBROOT_BASE="/var/www"
PHP_TZ="${PHP_TZ:-Asia/Kolkata}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
CREDS_DIR="/root/phpbb-credentials"

G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[1;36m'; N='\033[0m'
say(){ echo -e "\n${C}==>${N} $*"; }
ok(){  echo -e "${G}  ok${N} $*"; }
warn(){ echo -e "${Y}  ! ${N} $*"; }
die(){ echo -e "${R}  x  $*${N}" >&2; exit 1; }
rndpw(){ head -c 400 /dev/urandom | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-20}"; }

#===============================================================================
# 0. Preflight
#===============================================================================
[ "$(id -u)" -eq 0 ] || die "Run as root:  sudo ./phpbb20.sh"
grep -qE 'platform:el9|VERSION_ID="9' /etc/os-release || warn "Not AlmaLinux 9 - continuing anyway."

IP="${IP:-$(hostname -I | awk '{print $1}')}"
[ -n "$IP" ] || die "No IP found. Run with: sudo IP=192.168.1.106 ./phpbb20.sh"
END_PORT=$(( BASE_PORT + COUNT - 1 ))
TLS_END_PORT=$(( TLS_BASE_PORT + COUNT - 1 ))

if [ "$SSL" = "1" ]; then
  PROTO="https://"; PUB_BASE="$TLS_BASE_PORT"; YML_SECURE="true"
else
  PROTO="http://";  PUB_BASE="$BASE_PORT";     YML_SECURE="false"
fi
PUB_END=$(( PUB_BASE + COUNT - 1 ))

echo
echo -e "${G}  phpBB x${COUNT} installer${N}"
echo -e "  IP:     ${C}${IP}${N}"
echo -e "  Boards: ${C}${PROTO}${IP}:${PUB_BASE}${N} .. ${C}${PROTO}${IP}:${PUB_END}${N}"
[ "$SSL" = "1" ] && echo -e "  SSL:    ${C}self-signed, http ${BASE_PORT}-${END_PORT} redirects to https${N}"
echo

if ip -4 addr show | grep -q dynamic; then
  warn "This IP looks DHCP-assigned. Each board stores it in its database,"
  warn "so a lease change breaks all ${COUNT}. Set a static IP / DHCP reservation."
  echo
fi

RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
[ "$RAM_MB" -ge $(( COUNT * 200 + 1024 )) ] || \
  warn "RAM ${RAM_MB}MB is tight for ${COUNT} boards. Pools are ondemand so idle is fine."

#===============================================================================
# 1. Packages
#===============================================================================
say "Installing Nginx + PHP 8.2 + MariaDB"
dnf install -y epel-release >/dev/null 2>&1 || true
dnf install -y curl tar bzip2 policycoreutils-python-utils firewalld \
               nginx mariadb-server >/dev/null
dnf module reset  -y php >/dev/null
dnf module enable -y php:8.2 >/dev/null
dnf install -y php php-fpm php-cli php-mysqlnd php-gd php-mbstring php-xml \
               php-opcache php-zip php-intl php-bcmath >/dev/null
ok "PHP $(php -r 'echo PHP_VERSION;') installed"

#===============================================================================
# 2. PHP config
#===============================================================================
say "Configuring PHP"
cat >/etc/php.d/99-phpbb.ini <<EOF
date.timezone = "${PHP_TZ}"
memory_limit = 256M
upload_max_filesize = 20M
post_max_size = 22M
max_execution_time = 120
cgi.fix_pathinfo = 0
opcache.enable = 1
opcache.memory_consumption = 256
opcache.interned_strings_buffer = 32
opcache.max_accelerated_files = 130000
opcache.revalidate_freq = 60
EOF
# each board gets its own pool, so retire the shared default one
[ -f /etc/php-fpm.d/www.conf ] && mv -f /etc/php-fpm.d/www.conf /etc/php-fpm.d/www.conf.disabled
mkdir -p /var/log/php-fpm /var/lib/php/session /var/lib/php/tmp
ok "PHP configured"

#===============================================================================
# 3. MariaDB
#===============================================================================
say "Starting MariaDB"
INNODB=$(( RAM_MB / 4 )); [ "$INNODB" -lt 256 ] && INNODB=256
cat >/etc/my.cnf.d/99-phpbb.cnf <<EOF
[mysqld]
max_connections = $(( COUNT * 15 + 50 ))
table_open_cache = 4000
innodb_buffer_pool_size = ${INNODB}M
innodb_file_per_table = 1
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
EOF
systemctl enable --now mariadb >/dev/null
systemctl restart mariadb
mysql -e "DELETE FROM mysql.user WHERE User=''; DROP DATABASE IF EXISTS test; FLUSH PRIVILEGES;" 2>/dev/null || true
ok "MariaDB ready"

#===============================================================================
# 4. Nginx base config
#===============================================================================
say "Configuring Nginx"
[ -f /etc/nginx/nginx.conf.orig ] || cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig
cat >/etc/nginx/nginx.conf <<'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;
include /usr/share/nginx/modules/*.conf;
events { worker_connections 4096; }
http {
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" "$http_user_agent"';
    access_log /var/log/nginx/access.log main;
    sendfile on; tcp_nopush on; keepalive_timeout 65;
    types_hash_max_size 4096;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    client_max_body_size 20M;
    gzip on;
    include /etc/nginx/conf.d/*.conf;
}
EOF
rm -f /etc/nginx/conf.d/*.conf
ok "Nginx base written"

#===============================================================================
# 5. SELinux + firewall for the port range
#===============================================================================
SEL=0
if command -v selinuxenabled >/dev/null && selinuxenabled; then
  SEL=1
  say "SELinux: allowing tcp ${BASE_PORT}-${END_PORT}"
  semanage port -a -t http_port_t -p tcp "${BASE_PORT}-${END_PORT}" 2>/dev/null \
    || semanage port -m -t http_port_t -p tcp "${BASE_PORT}-${END_PORT}" 2>/dev/null || true
  if [ "$SSL" = "1" ]; then
    semanage port -a -t http_port_t -p tcp "${TLS_BASE_PORT}-${TLS_END_PORT}" 2>/dev/null \
      || semanage port -m -t http_port_t -p tcp "${TLS_BASE_PORT}-${TLS_END_PORT}" 2>/dev/null || true
  fi
  setsebool -P httpd_can_network_connect_db on
  ok "SELinux ports registered"
fi

say "Opening firewall"
systemctl enable --now firewalld >/dev/null 2>&1 || true
firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
firewall-cmd --permanent --add-port="${BASE_PORT}-${END_PORT}/tcp" >/dev/null 2>&1 || true
[ "$SSL" = "1" ] && firewall-cmd --permanent --add-port="${TLS_BASE_PORT}-${TLS_END_PORT}/tcp" >/dev/null 2>&1 || true
firewall-cmd --reload >/dev/null 2>&1 || true
ok "Firewall open"

#===============================================================================
# 5b. Self-signed certificate (one cert, all 20 boards)
#===============================================================================
if [ "$SSL" = "1" ]; then
  say "Generating self-signed certificate for ${IP}"
  # subjectAltName=IP:... is mandatory - a CN-only cert is rejected outright
  # by every current browser, warning page or not.
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "$KEY" -out "$CRT" \
    -subj "/C=IN/O=phpBB Lab/CN=${IP}" \
    -addext "subjectAltName=IP:${IP}" \
    -addext "basicConstraints=CA:FALSE" \
    -addext "keyUsage=digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1 \
    || die "openssl failed to generate the certificate."
  chmod 644 "$CRT"; chmod 600 "$KEY"
  chown root:root "$CRT" "$KEY"
  restorecon "$CRT" "$KEY" 2>/dev/null || true
  ok "Cert valid 10 years: $CRT"
fi

#===============================================================================
# 6. Download phpBB once
#===============================================================================
say "Downloading phpBB"
# Pinned by default. Set PHPBB_VER=auto to track whatever phpbb.com says is current,
# or PHPBB_VER=3.3.16 etc. to pin a different one.
PHPBB_VER="${PHPBB_VER:-3.3.17}"

if [ "$PHPBB_VER" = "auto" ]; then
  PHPBB_VER="$(curl -fsSL --max-time 20 https://version.phpbb.com/phpbb/3.3.json 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['stable']['3.3']['current'])" 2>/dev/null || true)"
  [ -n "$PHPBB_VER" ] || { PHPBB_VER="3.3.17"; warn "Version lookup failed - falling back to ${PHPBB_VER}"; }
fi

VER="$PHPBB_VER"
URL="https://download.phpbb.com/pub/release/3.3/${VER}/phpBB-${VER}.tar.bz2"

# Fail loudly on a bad version rather than silently installing something else
curl -fsIL --max-time 20 "$URL" >/dev/null 2>&1 \
  || die "phpBB ${VER} not found at ${URL} - check the version number or your internet access."

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fL --retry 3 -o "$TMP/p.tar.bz2" "$URL"
tar xjf "$TMP/p.tar.bz2" -C "$TMP"
[ -d "$TMP/phpBB3" ] || die "Download or extract failed."

# confirm what actually landed on disk
DISK_VER="$(grep -oP "PHPBB_VERSION',\s*'\K[0-9.]+" "$TMP/phpBB3/includes/constants.php" 2>/dev/null || echo "$VER")"
ok "phpBB ${DISK_VER} staged"
[ "$DISK_VER" = "$VER" ] || warn "Requested ${VER} but package reports ${DISK_VER}"

mkdir -p "$CREDS_DIR"; chmod 700 "$CREDS_DIR"

#===============================================================================
# 7. Build each board
#===============================================================================
say "Provisioning ${COUNT} boards"
for i in $(seq 1 "$COUNT"); do
  IDX=$(printf '%02d' "$i")
  NAME="${PREFIX}${IDX}"
  ROOT="${WEBROOT_BASE}/${NAME}"
  PORT=$(( BASE_PORT + i - 1 ))
  TLSPORT=$(( TLS_BASE_PORT + i - 1 ))
  PUBPORT=$(( PUB_BASE + i - 1 ))
  DBPW="$(rndpw 24)"
  ADPW="$(rndpw 16)"
  SOCK="/run/php-fpm/${NAME}.sock"

  if [ -e "$ROOT" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then
    [ "${FORCE:-0}" = "1" ] || die "$ROOT exists. Re-run with:  sudo FORCE=1 ./phpbb20.sh"
    rm -rf "${ROOT:?}"/*
  fi

  id -u "$NAME" >/dev/null 2>&1 || useradd --system --home-dir "$ROOT" --shell /sbin/nologin "$NAME"

  mkdir -p "$ROOT"
  cp -a "$TMP/phpBB3/." "$ROOT/"
  : > "$ROOT/config.php"
  chown -R "$NAME:$NAME" "$ROOT"
  find "$ROOT" -type d -exec chmod 755 {} \;
  find "$ROOT" -type f -exec chmod 644 {} \;
  chmod 660 "$ROOT/config.php"
  chmod -R 775 "$ROOT/cache" "$ROOT/store" "$ROOT/files" "$ROOT/images/avatars/upload" 2>/dev/null || true

  mkdir -p "/var/lib/php/session/$NAME" "/var/lib/php/tmp/$NAME"
  chown "$NAME:$NAME" "/var/lib/php/session/$NAME" "/var/lib/php/tmp/$NAME"
  chmod 700 "/var/lib/php/session/$NAME" "/var/lib/php/tmp/$NAME"

  cat >"/etc/php-fpm.d/${NAME}.conf" <<EOF
[${NAME}]
user = ${NAME}
group = ${NAME}
listen = ${SOCK}
listen.owner = ${NAME}
listen.group = nginx
listen.mode = 0660
listen.acl_users = nginx
pm = ondemand
pm.max_children = 8
pm.process_idle_timeout = 15s
pm.max_requests = 500
php_admin_value[error_log] = /var/log/php-fpm/${NAME}-error.log
php_admin_flag[log_errors] = on
php_admin_value[session.save_path] = /var/lib/php/session/${NAME}
php_admin_value[upload_tmp_dir]    = /var/lib/php/tmp/${NAME}
php_admin_value[sys_temp_dir]      = /var/lib/php/tmp/${NAME}
EOF

  if [ "$SSL" = "1" ]; then
    LISTEN_BLOCK="    listen ${TLSPORT} ssl;
    listen [::]:${TLSPORT} ssl;
    ssl_certificate     ${CRT};
    ssl_certificate_key ${KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL${IDX}:5m;
    ssl_session_timeout 1h;"
    REDIRECT_BLOCK="
server {
    listen ${PORT};
    listen [::]:${PORT};
    server_name _;
    return 301 https://${IP}:${TLSPORT}\$request_uri;
}"
  else
    LISTEN_BLOCK="    listen ${PORT};
    listen [::]:${PORT};"
    REDIRECT_BLOCK=""
  fi

  cat >"/etc/nginx/conf.d/${NAME}.conf" <<EOF
server {
${LISTEN_BLOCK}
    server_name _;
    root ${ROOT};
    index index.php index.html;
    access_log /var/log/nginx/${NAME}-access.log main;
    error_log  /var/log/nginx/${NAME}-error.log;

    location / { try_files \$uri \$uri/ @rewriteapp; }
    location @rewriteapp { rewrite ^(.*)\$ /app.php/\$1 last; }

    location ~ /(config\.php|common\.php|cache|files|images/avatars/upload|includes|(?<!ext/)phpbb(?!\w+)|store|vendor) {
        deny all; internal;
    }

    location ~ \.php(/|\$) {
        fastcgi_pass unix:${SOCK};
        fastcgi_split_path_info ^(.+\.php)(/.*)\$;
        if (!-f \$document_root\$fastcgi_script_name) { return 404; }
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        include fastcgi_params;
    }

    location /install/ {
        try_files \$uri \$uri/ @installapp;
        location ~ \.php(/|\$) {
            fastcgi_pass unix:${SOCK};
            fastcgi_split_path_info ^(.+\.php)(/.*)\$;
            if (!-f \$document_root\$fastcgi_script_name) { return 404; }
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            fastcgi_param PATH_INFO \$fastcgi_path_info;
            include fastcgi_params;
        }
    }
    location @installapp { rewrite ^(.*)\$ /install/app.php/\$1 last; }
    location ~ /\.(svn|git) { deny all; internal; }
}
${REDIRECT_BLOCK}
EOF

  if [ "$SEL" = "1" ]; then
    semanage fcontext -a -t httpd_sys_content_t "${ROOT}(/.*)?" 2>/dev/null || true
    for d in cache store files "images/avatars/upload"; do
      semanage fcontext -a -t httpd_sys_rw_content_t "${ROOT}/${d}(/.*)?" 2>/dev/null || true
    done
    semanage fcontext -a -t httpd_sys_rw_content_t "${ROOT}/config\.php" 2>/dev/null || true
    restorecon -RF "$ROOT" >/dev/null 2>&1 || true
  fi

  [ "${FORCE:-0}" = "1" ] && mysql -e "DROP DATABASE IF EXISTS \`${NAME}\`;"
  mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${NAME}'@'localhost' IDENTIFIED BY '${DBPW}';
ALTER  USER '${NAME}'@'localhost' IDENTIFIED BY '${DBPW}';
GRANT ALL PRIVILEGES ON \`${NAME}\`.* TO '${NAME}'@'localhost';
FLUSH PRIVILEGES;
SQL

  cat >"${CREDS_DIR}/${NAME}.txt" <<EOF
Board:        ${NAME}
URL:          ${PROTO}${IP}:${PUBPORT}/
Admin login:  ${ADMIN_USER}
Admin pass:   ${ADPW}
Admin email:  ${ADMIN_EMAIL}

Webroot:      ${ROOT}
DB name:      ${NAME}
DB user:      ${NAME}
DB pass:      ${DBPW}
Table prefix: phpbb_
EOF
  chmod 600 "${CREDS_DIR}/${NAME}.txt"

  # NOTE: this must live somewhere the board's own user can read - the installer
  # runs as ${NAME}, which has no access to /root.
  cat >"${ROOT}/.install.yml" <<EOF
installer:
    admin:
        name: ${ADMIN_USER}
        password: ${ADPW}
        email: ${ADMIN_EMAIL}
    board:
        lang: en
        name: Board ${IDX}
        description: phpBB test board ${IDX}
    database:
        dbms: mysqli
        dbhost: localhost
        dbport: 3306
        dbuser: ${NAME}
        dbpasswd: ${DBPW}
        dbname: ${NAME}
        table_prefix: phpbb_
    email:
        enabled: false
        smtp_delivery: false
        smtp_host: null
        smtp_auth: null
        smtp_user: null
        smtp_pass: null
    server:
        cookie_secure: ${YML_SECURE}
        server_protocol: '${PROTO}'
        force_server_vars: false
        server_name: ${IP}
        server_port: ${PUBPORT}
        script_path: /
EOF
  chmod 600 "${ROOT}/.install.yml"
  chown "${NAME}:${NAME}" "${ROOT}/.install.yml"
  echo -ne "\r  provisioned ${i}/${COUNT}   "
done
echo; ok "All ${COUNT} boards provisioned"

#===============================================================================
# 8. Start services
#===============================================================================
say "Starting services"
nginx -t
systemctl enable --now php-fpm nginx >/dev/null
systemctl restart php-fpm nginx
ok "$(ls /etc/php-fpm.d/*.conf | wc -l) PHP-FPM pools + nginx running"

#===============================================================================
# 9. Headless phpBB install
#===============================================================================
say "Running phpBB setup on each board (this is the slow part)"
FAILED=""
for i in $(seq 1 "$COUNT"); do
  IDX=$(printf '%02d' "$i")
  NAME="${PREFIX}${IDX}"
  ROOT="${WEBROOT_BASE}/${NAME}"

  if runuser -u "$NAME" -- php "$ROOT/install/phpbbcli.php" install \
       "$ROOT/.install.yml" >"/root/.inst-${NAME}.log" 2>&1; then

    # unique cookie name: browsers ignore the port, so all boards on one IP
    # would otherwise share a single cookie and log each other out
    mysql "$NAME" -e "UPDATE phpbb_config SET config_value='phpbb3_${IDX}' WHERE config_name='cookie_name';" 2>/dev/null || true

    rm -f "$ROOT/.install.yml"
    rm -rf "$ROOT/install"
    chmod 644 "$ROOT/config.php"
    chown "$NAME:$NAME" "$ROOT/config.php"
    rm -rf "$ROOT/cache/production/"* 2>/dev/null || true
    [ "$SEL" = "1" ] && restorecon -RF "$ROOT" >/dev/null 2>&1 || true
    echo -ne "\r  installed ${i}/${COUNT}   "
  else
    FAILED="${FAILED} ${NAME}"
    echo -ne "\r"
    warn "${NAME} failed:"
    sed 's/^/      /' "/root/.inst-${NAME}.log" | tail -15
  fi
done
echo

#===============================================================================
# 10. Index page on port 80
#===============================================================================
mkdir -p /var/www/html
{
  echo '<!doctype html><meta charset="utf-8"><title>phpBB lab</title>'
  echo '<style>body{font:16px/1.8 system-ui;margin:40px;max-width:600px}'
  echo 'a{display:block;padding:5px 0}code{background:#eee;padding:2px 6px;border-radius:3px}</style>'
  echo "<h1>phpBB lab</h1><p>${COUNT} boards on <code>${IP}</code></p>"
  for i in $(seq 1 "$COUNT"); do
    IDX=$(printf '%02d' "$i"); P=$(( PUB_BASE + i - 1 ))
    echo "<a href=\"${PROTO}${IP}:${P}/\">Board ${IDX} &mdash; ${PROTO}${IP}:${P}</a>"
  done
} > /var/www/html/index.html
cat >/etc/nginx/conf.d/00-index.conf <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/html;
    index index.html;
}
EOF
[ "$SEL" = "1" ] && restorecon -RF /var/www/html >/dev/null 2>&1 || true
nginx -t && systemctl reload nginx

#===============================================================================
# Done
#===============================================================================
echo
echo -e "${G}================================================================${N}"
echo -e "${G}  DONE${N}"
echo -e "${G}================================================================${N}"
echo -e "  Open this first:  ${C}http://${IP}/${N}"
echo -e "  Boards:           ${C}${PROTO}${IP}:${PUB_BASE}${N} .. ${C}${PROTO}${IP}:${PUB_END}${N}"
echo -e "  Admin username:   ${Y}${ADMIN_USER}${N}  (password differs per board)"
echo -e "  Passwords:        ${C}${CREDS_DIR}/${N}"
echo
echo -e "  See all logins:   ${C}grep -H 'Admin pass' ${CREDS_DIR}/*.txt${N}"

if [ "$SSL" = "1" ]; then
  echo
  echo -e "  ${Y}Self-signed cert: browsers will warn until you trust it.${N}"
  echo -e "  Click through, or import it once on each client machine:"
  echo -e "    ${C}scp root@${IP}:${CRT} .${N}"
  echo -e "    Windows:  certutil -addstore -f Root phpbb-lab.crt"
  echo -e "    Linux:    sudo cp phpbb-lab.crt /etc/pki/ca-trust/source/anchors/ && sudo update-ca-trust"
  echo -e "    macOS:    sudo security add-trusted-cert -d -k /Library/Keychains/System.keychain phpbb-lab.crt"
  echo -e "  Firefox uses its own store: Settings > Privacy > Certificates > View > Import"
fi

if [ -n "$FAILED" ]; then
  echo
  warn "These boards need finishing in the browser:${FAILED}"
  warn "Their setup wizard is still at ${PROTO}${IP}:PORT/install/"
fi
echo -e "${G}================================================================${N}"
