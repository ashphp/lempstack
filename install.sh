#!/usr/bin/env bash
set -euo pipefail

# ===== helpers =====
bold(){ tput bold 2>/dev/null || true; }
clr(){ tput setaf "$1" 2>/dev/null || true; }   # 6 = cyan
rst(){ tput sgr0 2>/dev/null || true; }
say(){ echo -e "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
randpass(){ openssl rand -base64 32 | tr -dc 'A-Za-z0-9@#%^+=_' | head -c 24; }
ask(){ # var, question, default
  local __var="$1" __q="$2" __def="${3:-}" ans
  if [ -n "$__def" ]; then
    say "$(bold)${__q}$(rst)  $(clr 6)[Default: ${__def}]$(rst)  (Enter = default)"
  else
    say "$(bold)${__q}$(rst)  $(clr 6)[Default: none]$(rst)  (Enter = none)"
  fi
  read -r -p "> " ans || exit 1
  ans="${ans:-$__def}"
  printf -v "$__var" '%s' "$ans"
}
ask_yn_no(){ # var, question (default No)
  local __var="$1" __q="$2" a
  say "$(bold)${__q}$(rst)  $(clr 6)[Default: No]$(rst)  (y/n, yes/no, 1/0, true/false; Enter = No)"
  read -r -p "> " a || exit 1
  a="$(echo "${a:-n}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  case "$a" in y|yes|1|true) printf -v "$__var" 'yes' ;; *) printf -v "$__var" 'no' ;; esac
}
logline(){ [ -n "${LOGFILE:-}" ] && echo "$*" >> "$LOGFILE"; }

# ===== preflight =====
[ -f /etc/almalinux-release ] || die "AlmaLinux required."
ELVER="$(rpm -E %rhel)"; [[ "$ELVER" =~ ^(8|9|10)$ ]] || die "Unsupported EL version: $ELVER"
need curl; need openssl
dnf -y install dnf-plugins-core curl tar unzip policycoreutils-python-utils >/dev/null

# primary IPv4 fallback when no domain
IPV4="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/){print $i; exit}}' || true)"
[ -z "$IPV4" ] && IPV4="$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"

# ===== inputs =====
DOMAIN=""
ask DOMAIN "Domain name (blank = use server IP with self-signed TLS)" ""
[ -z "$DOMAIN" ] && DOMAIN="$IPV4"

# auto default email: admin@domain for FQDN, else admin@localhost
if echo "$DOMAIN" | grep -qi '[a-z]'; then
  EMAIL_DEF="admin@${DOMAIN}"
else
  EMAIL_DEF="admin@localhost"
fi
ask EMAIL "Admin email (Let's Encrypt uses this if FQDN)" "$EMAIL_DEF"

LOGFILE="/root/lemp_install_${DOMAIN//\//_}.log"; : > "$LOGFILE"; chmod 600 "$LOGFILE"

INSTALL_WP="no"; ask_yn_no INSTALL_WP "Install WordPress (auto DB + wp-config.php + finalize)?"
CACHE_CHOICE="none"
if [ "$INSTALL_WP" = "yes" ]; then
  say "$(bold)Caching backend$(rst)  $(clr 6)[Default: none]$(rst)  Options: none, redis, memcached"
  read -r -p "> " CACHE_CHOICE || exit 1
  CACHE_CHOICE="${CACHE_CHOICE:-none}"
  [[ "$CACHE_CHOICE" =~ ^(none|redis|memcached)$ ]] || CACHE_CHOICE="none"
fi

WP_IN_SUBDIR="no"; WP_SUBDIR=""
if [ "$INSTALL_WP" = "yes" ]; then
  ask_yn_no WP_IN_SUBDIR "Place WordPress in a subfolder?"
  if [ "$WP_IN_SUBDIR" = "yes" ]; then
    ask WP_SUBDIR "Subfolder name" "blog"
    WP_SUBDIR="${WP_SUBDIR//[^a-zA-Z0-9_-]/}"; [ -n "$WP_SUBDIR" ] || die "Invalid subfolder."
  fi
fi

# ===== credentials =====
DB_ROOT_PASS="$(randpass)"
DB_NAME="wp_${DOMAIN//./_}"
DB_USER="wpuser"
DB_PASS="$(randpass)"
WP_TITLE="${DOMAIN}"
WP_ADMIN_USER="admin"
WP_ADMIN_PASS="$(randpass)"

# ===== paths =====
WEBROOT="/var/www/${DOMAIN}/html"
WP_PATH="$WEBROOT"; [ "$INSTALL_WP" = "yes" ] && [ "$WP_IN_SUBDIR" = "yes" ] && WP_PATH="$WEBROOT/$WP_SUBDIR"
NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"

# ===== log inputs =====
logline "Domain=$DOMAIN"
logline "Email=$EMAIL"
logline "Install_WordPress=$INSTALL_WP"
logline "Cache=$CACHE_CHOICE"
logline "WP_Subdir=$WP_IN_SUBDIR ${WP_SUBDIR:-}"
logline "DB_ROOT_PASS=$DB_ROOT_PASS"
logline "DB_NAME=$DB_NAME"
logline "DB_USER=$DB_USER"
logline "DB_PASS=$DB_PASS"
logline "WP_TITLE=$WP_TITLE"
logline "WP_ADMIN_USER=$WP_ADMIN_USER"
logline "WP_ADMIN_PASS=$WP_ADMIN_PASS"
logline "Webroot=$WEBROOT"
logline "Logfile=$LOGFILE"

# ===== repos =====
if [ "$ELVER" = "8" ]; then dnf config-manager --set-enabled powertools || dnf config-manager --set-enabled PowerTools || true; else dnf config-manager --set-enabled crb || true; fi
dnf -y install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${ELVER}.noarch.rpm"
dnf -y install "https://rpms.remirepo.net/enterprise/remi-release-${ELVER}.rpm"
dnf -y module reset php || true
if dnf -y module list php | grep -q 'remi-8\.4'; then PHP_STREAM="remi-8.4"; else PHP_STREAM="remi-8.3"; fi
dnf -y module enable php:"$PHP_STREAM"

# ===== install stack =====
dnf -y install nginx mariadb-server
dnf -y install php php-fpm php-cli php-mysqlnd php-gd php-json php-mbstring php-xml php-zip php-intl php-bcmath php-curl php-opcache php-soap php-dom
dnf -y install certbot python3-certbot-nginx || true
# caches (+ PHP ext) when selected
if [ "$INSTALL_WP" = "yes" ]; then
  case "$CACHE_CHOICE" in
    redis)     dnf -y install redis php-redis ;;
    memcached) dnf -y install memcached php-pecl-memcached ;;
  esac
fi

# ===== services =====
sed -ri 's/^user\s*=.*/user = nginx/' /etc/php-fpm.d/www.conf
sed -ri 's/^group\s*=.*/group = nginx/' /etc/php-fpm.d/www.conf
sed -ri 's@^;?listen\s*=.*@listen = /run/php-fpm/www.sock@' /etc/php-fpm.d/www.conf
sed -ri 's@^;?listen.owner\s*=.*@listen.owner = nginx@' /etc/php-fpm.d/www.conf
sed -ri 's@^;?listen.group\s*=.*@listen.group = nginx@' /etc/php-fpm.d/www.conf
sed -ri 's@^;?listen.mode\s*=.*@listen.mode = 0660@' /etc/php-fpm.d/www.conf
systemctl enable --now php-fpm mariadb nginx

# start and bind caches if selected
if [ "$INSTALL_WP" = "yes" ]; then
  if [ "$CACHE_CHOICE" = "redis" ]; then
    systemctl enable --now redis
  elif [ "$CACHE_CHOICE" = "memcached" ]; then
    systemctl enable --now memcached
    sed -ri 's/^-l .*/-l 127.0.0.1/' /etc/sysconfig/memcached || true
    systemctl restart memcached
  fi
fi

# ===== MariaDB secure + WP DB =====
mysqladmin --user=root password "$DB_ROOT_PASS" 2>/dev/null || true
mysql --user=root --password="$DB_ROOT_PASS" -e "DELETE FROM mysql.user WHERE User='';" || true
mysql --user=root --password="$DB_ROOT_PASS" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');" || true
mysql --user=root --password="$DB_ROOT_PASS" -e "DROP DATABASE IF EXISTS test;" || true
mysql --user=root --password="$DB_ROOT_PASS" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" || true
mysql --user=root --password="$DB_ROOT_PASS" -e "FLUSH PRIVILEGES;" || true

if [ "$INSTALL_WP" = "yes" ]; then
mysql --user=root --password="$DB_ROOT_PASS" <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
fi

# ===== webroot, SELinux =====
mkdir -p "$WEBROOT"
chown -R nginx:nginx "/var/www/${DOMAIN}"
chmod -R 755 "/var/www/${DOMAIN}"
semanage fcontext -a -t httpd_sys_content_t "/var/www/${DOMAIN}(/.*)?" || true
semanage fcontext -a -t httpd_sys_rw_content_t "/var/www/${DOMAIN}/html/wp-content(/.*)?" || true
restorecon -R "/var/www/${DOMAIN}" || true
setsebool -P httpd_can_network_connect 1

# ===== Nginx vhost (with optional subfolder permalink rule) =====
{
cat <<NGX
server {
    listen 80;
    server_name $DOMAIN;

    root $WEBROOT;
    index index.php index.html;

    location /.well-known/acme-challenge/ { root $WEBROOT; }
NGX

if [ "$INSTALL_WP" = "yes" ] && [ "$WP_IN_SUBDIR" = "yes" ]; then
cat <<NGX
    # WordPress in subfolder: permalink rewrite
    location /$WP_SUBDIR/ {
        try_files \$uri \$uri/ /$WP_SUBDIR/index.php?\$args;
    }
NGX
fi

cat <<'NGX'
    # Generic front controller
    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_pass unix:/run/php-fpm/www.sock;
        fastcgi_read_timeout 180;
    }

    location ~* \.(?:bak|orig|save|swp|sql)$ { deny all; }
}
NGX
} > "$NGINX_CONF"

nginx -t && systemctl reload nginx

# ===== TLS (LE if FQDN, else self-signed) =====
LE_OK=0
if echo "$DOMAIN" | grep -qi '[a-z]'; then
  set +e
  certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --redirect --noninteractive
  RC=$?; set -e
  [ $RC -eq 0 ] && LE_OK=1
fi
if [ $LE_OK -ne 1 ]; then
  mkdir -p /etc/ssl/localcerts
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -keyout /etc/ssl/localcerts/"$DOMAIN".key \
    -out    /etc/ssl/localcerts/"$DOMAIN".crt \
    -subj "/CN=$DOMAIN"

  cat > "/etc/nginx/conf.d/${DOMAIN}_ssl_fallback.conf" <<EOF
server {
    listen 443 ssl http2; server_name $DOMAIN;
    ssl_certificate     /etc/ssl/localcerts/$DOMAIN.crt;
    ssl_certificate_key /etc/ssl/localcerts/$DOMAIN.key;
    root $WEBROOT; index index.php index.html;
$( [ "$INSTALL_WP" = "yes" ] && [ "$WP_IN_SUBDIR" = "yes" ] && echo "    location /$WP_SUBDIR/ { try_files \$uri \$uri/ /$WP_SUBDIR/index.php?\$args; }" )
    location / { try_files \$uri \$uri/ /index.php?\$args; }
    location ~ \.php\$ { include fastcgi_params; fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name; fastcgi_pass unix:/run/php-fpm/www.sock; fastcgi_read_timeout 180; }
}
server { listen 80; server_name $DOMAIN; return 301 https://\$host\$request_uri; }
EOF
  nginx -t && systemctl reload nginx
fi

# ===== WordPress: download, wp-config, finalize (no plugins) =====
if [ "$INSTALL_WP" = "yes" ]; then
  mkdir -p "$WP_PATH"
  TMPW="/tmp/wp.tar.gz"
  curl -fsSL https://wordpress.org/latest.tar.gz -o "$TMPW"
  tar -xzf "$TMPW" -C /tmp
  rsync -a /tmp/wordpress/ "$WP_PATH"/
  rm -rf /tmp/wordpress "$TMPW"

  # salts
  SALTS="$(curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/ || true)"
  if [ -z "$SALTS" ]; then
    SALTS=$(for i in {1..8}; do k=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 64); echo "define('SALT_$i','$k');"; done)
  fi

  # wp-config.php
  cat > "$WP_PATH/wp-config.php" <<PHP
<?php
define('DB_NAME', '${DB_NAME}');
define('DB_USER', '${DB_USER}');
define('DB_PASSWORD', '${DB_PASS}');
define('DB_HOST', 'localhost');
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', '');
${SALTS}
\$table_prefix = 'wp_';
define('WP_DEBUG', false);
if (!defined('ABSPATH')) define('ABSPATH', __DIR__ . '/');
require ABSPATH . 'wp-settings.php';
PHP

  chown -R nginx:nginx "$WP_PATH"
  mkdir -p "$WP_PATH/wp-content/uploads"
  chown -R nginx:nginx "$WP_PATH/wp-content"
  semanage fcontext -a -t httpd_sys_rw_content_t "$WP_PATH/wp-content(/.*)?" || true
  restorecon -R "$WP_PATH/wp-content" || true

  # one-time finalize (no plugins)
  SITE_URL="https://${DOMAIN}"; [ "$WP_IN_SUBDIR" = "yes" ] && SITE_URL="${SITE_URL}/${WP_SUBDIR}"
  INSTALLER="$WP_PATH/install_once.php"
  cat > "$INSTALLER" <<'PHP'
<?php
define('WP_INSTALLING', true);
require __DIR__ . '/wp-load.php';
require ABSPATH . 'wp-admin/includes/upgrade.php';
require ABSPATH . 'wp-includes/pluggable.php';
$site_title='__WP_TITLE__'; $admin_user='__WP_ADMIN_USER__'; $admin_pass='__WP_ADMIN_PASS__'; $admin_email='__WP_ADMIN_EMAIL__'; $site_url='__SITE_URL__';
if (!get_option('blogname')) {
    wp_install($site_title, $admin_user, $admin_email, true, '', $admin_pass);
    if ($site_url) { update_option('siteurl', $site_url); update_option('home', $site_url); }
    update_option('permalink_structure', '/%postname%/'); flush_rewrite_rules();
}
echo "OK"; @unlink(__FILE__);
PHP
  sed -i "s|__WP_TITLE__|$(printf '%s' "$WP_TITLE" | sed "s|[&/]|\\&|g")|g" "$INSTALLER"
  sed -i "s|__WP_ADMIN_USER__|$(printf '%s' "$WP_ADMIN_USER" | sed "s|[&/]|\\&|g")|g" "$INSTALLER"
  sed -i "s|__WP_ADMIN_PASS__|$(printf '%s' "$WP_ADMIN_PASS" | sed "s|[&/]|\\&|g")|g" "$INSTALLER"
  sed -i "s|__WP_ADMIN_EMAIL__|$(printf '%s' "$EMAIL" | sed "s|[&/]|\\&|g")|g" "$INSTALLER"
  sed -i "s|__SITE_URL__|$(printf '%s' "$SITE_URL" | sed "s|[&/]|\\&|g")|g" "$INSTALLER"
  chown nginx:nginx "$INSTALLER"
  curl -fsS "http://$DOMAIN$( [ "$WP_IN_SUBDIR" = "yes" ] && echo "/$WP_SUBDIR" )/install_once.php" -H "Host: $DOMAIN" -m 30 >/dev/null || true
fi

# ===== firewall =====
if systemctl is-active --quiet firewalld; then
  firewall-cmd --add-service=http --permanent
  firewall-cmd --add-service=https --permanent
  firewall-cmd --reload
fi

# ===== summary =====
PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
[ -z "$PHP_VER" ] && PHP_VER="$(php -v | head -n1 | awk '{print $2}')"
{
  say ""
  say "$(bold)$(clr 6)==================== INSTALLATION SUMMARY ====================$(rst)"
  say "Site: https://${DOMAIN}"
  say "Web root: ${WEBROOT}"
  say "PHP: ${PHP_VER} (stream: ${PHP_STREAM})"
  say "Caching: ${CACHE_CHOICE}"
  if [ "$INSTALL_WP" = "yes" ]; then
    LOGIN_URL="https://${DOMAIN}$( [ "$WP_IN_SUBDIR" = "yes" ] && echo "/$WP_SUBDIR" )/wp-admin"
    say "WordPress path: ${WP_PATH}"
    say "Login URL: ${LOGIN_URL}"
    say "WP admin: ${WP_ADMIN_USER}"
    say "WP admin password: ${WP_ADMIN_PASS}"
    say "WP DB: ${DB_NAME} / ${DB_USER} / ${DB_PASS}"
  fi
  say ""
  say "$(bold)=== MariaDB ROOT password ===$(rst) ${DB_ROOT_PASS}"
  say "Credentials log: ${LOGFILE}"
  say "$(bold)$(clr 6)=============================================================$(rst)"
} | tee -a "$LOGFILE"
chmod 600 "$LOGFILE"
