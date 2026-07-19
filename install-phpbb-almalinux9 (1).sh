#!/usr/bin/env bash
#===============================================================================
# phpBB one-click installer for AlmaLinux 9  (serve by IP, no domain required)
# Stack: Nginx + PHP-FPM 8.2 + MariaDB  |  SELinux-enforcing safe  |  firewalld
#
# Usage:
#   sudo ./install-phpbb-almalinux9.sh
#
# Optional overrides (env vars):
#   PHPBB_VERSION=3.3.14   WEBROOT=/var/www/phpbb   DB_NAME=phpbb
#   DB_USER=phpbb          PHP_TZ=Asia/Kolkata      FORCE=1  (overwrite webroot)
#===============================================================================
set -euo pipefail

#--- Config -------------------------------------------------------------------
WEBROOT="${WEBROOT:-/var/www/phpbb}"
DB_NAME="${DB_NAME:-phpbb}"
DB_USER="${DB_USER:-phpbb}"
PHP_TZ="${PHP_TZ:-Asia/Kolkata}"
PHP_STREAM="${PHP_STREAM:-php:8.2}"
DB_PASS="$(head -c 200 /dev/urandom | tr -dc 'A-Za-z0-9' | cut -c1-20)"
CREDS_FILE="/root/phpbb-credentials.txt"

# Colors
G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[1;36m'; N='\033[0m'
say(){ echo -e "${C}==>${N} $*"; }
ok(){  echo -e "${G}  ✔${N} $*"; }
warn(){ echo -e "${Y}  ! ${N} $*"; }
die(){ echo -e "${R}  x  $*${N}" >&2; exit 1; }

#--- Preflight ----------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Run as root (use sudo)."
grep -qE 'platform:el9|VERSION_ID="9' /etc/os-release || warn "This isn't el9 — proceeding anyway."
grep -qi almalinux /etc/os-release && ok "AlmaLinux 9 detected" || warn "Non-AlmaLinux RHEL family detected."

if [ -e "$WEBROOT" ] && [ -n "$(ls -A "$WEBROOT" 2>/dev/null)" ]; then
  [ "${FORCE:-0}" = "1" ] || die "$WEBROOT already exists and is not empty. Re-run with FORCE=1 to overwrite."
  warn "FORCE=1 set — wiping $WEBROOT"; rm -rf "${WEBROOT:?}"/*
fi

SERVER_IP="${SERVER_IP:-$(hostname -I | awk '{print $1}')}"
[ -n "$SERVER_IP" ] || SERVER_IP="<your-server-ip>"

#--- Resolve latest phpBB 3.3.x ----------------------------------------------
say "Resolving latest phpBB 3.3.x release"
LATEST_JSON="$(curl -fsSL https://version.phpbb.com/phpbb/3.3.json 2>/dev/null || true)"
if [ -n "$LATEST_JSON" ]; then
  PHPBB_VERSION="${PHPBB_VERSION:-$(python3 -c "import sys,json;print(json.load(sys.stdin)['stable']['3.3']['current'])" <<<"$LATEST_JSON" 2>/dev/null || true)}"
  PHPBB_URL="$(python3 -c "import sys,json;print(json.load(sys.stdin)['stable']['3.3']['download'])" <<<"$LATEST_JSON" 2>/dev/null || true)"
fi
PHPBB_VERSION="${PHPBB_VERSION:-3.3.14}"
PHPBB_URL="${PHPBB_URL:-https://download.phpbb.com/pub/release/3.3/${PHPBB_VERSION}/phpBB-${PHPBB_VERSION}.tar.bz2}"
ok "phpBB ${PHPBB_VERSION}"

#--- Packages -----------------------------------------------------------------
say "Installing packages"
dnf install -y epel-release >/dev/null 2>&1 || true
dnf install -y curl wget tar bzip2 policycoreutils-python-utils firewalld nginx mariadb-server >/dev/null

say "Enabling PHP module stream ${PHP_STREAM}"
dnf module reset -y php >/dev/null
dnf module enable -y "$PHP_STREAM" >/dev/null
dnf install -y php php-fpm php-cli php-mysqlnd php-gd php-mbstring php-xml \
               php-opcache php-zip php-intl php-bcmath >/dev/null
ok "Nginx, MariaDB and PHP $(php -r 'echo PHP_VERSION;') installed"

#--- PHP tuning ---------------------------------------------------------------
say "Applying PHP settings"
cat >/etc/php.d/99-phpbb.ini <<EOF
date.timezone = "${PHP_TZ}"
memory_limit = 256M
upload_max_filesize = 20M
post_max_size = 22M
max_execution_time = 120
cgi.fix_pathinfo = 0
mysqli.default_socket = /var/lib/mysql/mysql.sock
pdo_mysql.default_socket = /var/lib/mysql/mysql.sock
EOF
# Make sure nginx is allowed on the php-fpm socket (RHEL ships this, ensure it)
grep -q '^listen.acl_users = apache,nginx' /etc/php-fpm.d/www.conf 2>/dev/null || \
  sed -i 's/^;*listen.acl_users.*/listen.acl_users = apache,nginx/' /etc/php-fpm.d/www.conf

#--- Nginx --------------------------------------------------------------------
say "Configuring Nginx"
[ -f /etc/nginx/nginx.conf.orig ] || cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig
cat >/etc/nginx/nginx.conf <<'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;
include /usr/share/nginx/modules/*.conf;

events { worker_connections 1024; }

http {
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log main;
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    types_hash_max_size 4096;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    client_max_body_size 20M;
    gzip on;
    include /etc/nginx/conf.d/*.conf;
}
EOF

cat >/etc/nginx/conf.d/phpbb.conf <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/phpbb;
    index index.php index.html index.htm;

    location / {
        try_files $uri $uri/ @rewriteapp;
    }

    location @rewriteapp {
        rewrite ^(.*)$ /app.php/$1 last;
    }

    # Deny access to internal phpBB files.
    location ~ /(config\.php|common\.php|cache|files|images/avatars/upload|includes|(?<!ext/)phpbb(?!\w+)|store|vendor) {
        deny all;
        internal;
    }

    # Pass PHP scripts to php-fpm.
    location ~ \.php(/|$) {
        fastcgi_pass unix:/run/php-fpm/www.sock;
        fastcgi_split_path_info ^(.+\.php)(/.*)$;
        if (!-f $document_root$fastcgi_script_name) { return 404; }
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        include fastcgi_params;
    }

    # Correctly serve the web installer.
    location /install/ {
        try_files $uri $uri/ @rewrite_installapp;
        location ~ \.php(/|$) {
            fastcgi_pass unix:/run/php-fpm/www.sock;
            fastcgi_split_path_info ^(.+\.php)(/.*)$;
            if (!-f $document_root$fastcgi_script_name) { return 404; }
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            fastcgi_param PATH_INFO $fastcgi_path_info;
            include fastcgi_params;
        }
    }

    location @rewrite_installapp {
        rewrite ^(.*)$ /install/app.php/$1 last;
    }

    # Deny access to VCS directories.
    location ~ /\.(svn|git) {
        deny all;
        internal;
    }
}
EOF
nginx -t

#--- Download & deploy phpBB --------------------------------------------------
say "Downloading phpBB ${PHPBB_VERSION}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fL --retry 3 -o "$TMP/phpbb.tar.bz2" "$PHPBB_URL"
tar xjf "$TMP/phpbb.tar.bz2" -C "$TMP"
mkdir -p "$WEBROOT"
cp -a "$TMP/phpBB3/." "$WEBROOT/"
ok "Deployed to $WEBROOT"

#--- Permissions --------------------------------------------------------------
say "Setting ownership & permissions (php-fpm runs as 'apache')"
# Pre-create config.php so the installer can write it
[ -f "$WEBROOT/config.php" ] || : > "$WEBROOT/config.php"
chown -R apache:apache "$WEBROOT"
find "$WEBROOT" -type d -exec chmod 755 {} \;
find "$WEBROOT" -type f -exec chmod 644 {} \;
chmod 660 "$WEBROOT/config.php"

#--- SELinux ------------------------------------------------------------------
if command -v selinuxenabled >/dev/null && selinuxenabled; then
  say "Applying SELinux contexts"
  semanage fcontext -a -t httpd_sys_content_t   "${WEBROOT}(/.*)?"                       2>/dev/null || true
  for d in cache store files "images/avatars/upload"; do
    semanage fcontext -a -t httpd_sys_rw_content_t "${WEBROOT}/${d}(/.*)?"               2>/dev/null || true
  done
  semanage fcontext -a -t httpd_sys_rw_content_t "${WEBROOT}/config\.php"                2>/dev/null || true
  restorecon -RF "$WEBROOT" >/dev/null
  setsebool -P httpd_can_network_connect_db on
  ok "SELinux configured (still enforcing)"
else
  warn "SELinux disabled — skipping contexts"
fi

#--- MariaDB ------------------------------------------------------------------
say "Starting MariaDB and creating database"
systemctl enable --now mariadb >/dev/null
mysql <<SQL
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db IN ('test','test\\_%');
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost'  IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1'  IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
ok "Database '${DB_NAME}' and user '${DB_USER}' created"

#--- Firewall & services ------------------------------------------------------
say "Opening HTTP in firewalld and starting services"
systemctl enable --now firewalld >/dev/null 2>&1 || true
firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
firewall-cmd --reload >/dev/null 2>&1 || true
systemctl enable --now php-fpm >/dev/null
systemctl enable --now nginx  >/dev/null
systemctl restart php-fpm nginx

#--- Save credentials ---------------------------------------------------------
cat >"$CREDS_FILE" <<EOF
phpBB installation — $(date)
URL (finish setup in browser): http://${SERVER_IP}/
Database driver in wizard:     MySQL with MySQLi Extension
Database server hostname:      127.0.0.1
Database server port:          (leave blank / 3306)
Database name:                 ${DB_NAME}
Database username:             ${DB_USER}
Database password:             ${DB_PASS}
Table prefix:                  phpbb_
EOF
chmod 600 "$CREDS_FILE"

#--- Done ---------------------------------------------------------------------
echo
echo -e "${G}================ phpBB is ready for browser setup ================${N}"
echo -e "  Open:            ${C}http://${SERVER_IP}/${N}"
echo -e "  In the wizard, DATABASE step, enter:"
echo -e "    Driver:        MySQL with MySQLi Extension"
echo -e "    Hostname:      ${Y}127.0.0.1${N}   Port: (blank)"
echo -e "    DB name:       ${Y}${DB_NAME}${N}"
echo -e "    Username:      ${Y}${DB_USER}${N}"
echo -e "    Password:      ${Y}${DB_PASS}${N}"
echo -e "    Table prefix:  ${Y}phpbb_${N}"
echo -e "  (Also saved to ${C}${CREDS_FILE}${N})"
echo
echo -e "  ${Y}AFTER the wizard finishes, lock it down:${N}"
echo -e "    rm -rf ${WEBROOT}/install"
echo -e "    chmod 644 ${WEBROOT}/config.php"
echo -e "    restorecon -RF ${WEBROOT}"
echo -e "${G}=================================================================${N}"
