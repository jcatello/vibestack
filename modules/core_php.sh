#!/bin/bash
# /opt/vibestack/modules/core_php.sh
# Module: PHP-FPM Pool Provisioning

# --- 0. MANDATORY INCLUDES ---
source /opt/vibestack/includes/common.sh

# --- 1. VALIDATION ---
DOMAIN=$1
WITH_PHP=$2

[[ -z "$DOMAIN" ]] && fatal_error 1004 "Domain missing in core_php.sh"
[[ -z "$WITH_PHP" ]] && fatal_error 1004 "PHP version missing in core_php.sh"

USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"
PHP_PKG_VER="${WITH_PHP//./}"
PHP_PKG="php${PHP_PKG_VER}"

# --- 2. DEPENDENCY CHECK (Enterprise Package List) ---
PHP_DEPENDENCIES=(
    "${PHP_PKG}"
    "${PHP_PKG}-php-fpm"
    "${PHP_PKG}-php-devel"
    "${PHP_PKG}-php-embedded"
    "${PHP_PKG}-php-mysqlnd"
    "${PHP_PKG}-php-bcmath"
    "${PHP_PKG}-php-enchant"
    "${PHP_PKG}-php-gd"
    "${PHP_PKG}-php-pecl-geoip"
    "${PHP_PKG}-php-gmp"
    "${PHP_PKG}-php-pecl-igbinary"
    "${PHP_PKG}-php-pecl-igbinary-devel"
    "${PHP_PKG}-php-pecl-imagick-im6"
    "${PHP_PKG}-php-pecl-imagick-im6-devel"
    "${PHP_PKG}-php-imap"
    "${PHP_PKG}-php-intl"
    "${PHP_PKG}-php-pecl-json-post"
    "${PHP_PKG}-php-ldap"
    "${PHP_PKG}-php-pecl-mailparse"
    "${PHP_PKG}-php-mbstring"
    "${PHP_PKG}-php-mcrypt"
    "${PHP_PKG}-php-pecl-memcache"
    "${PHP_PKG}-php-pecl-memcached"
    "${PHP_PKG}-php-pecl-mysql"
    "${PHP_PKG}-php-pdo-dblib"
    "${PHP_PKG}-php-pspell"
    "${PHP_PKG}-php-pecl-redis5"
    "${PHP_PKG}-php-snmp"
    "${PHP_PKG}-php-soap"
    "${PHP_PKG}-php-tidy"
    "${PHP_PKG}-php-xml"
    "${PHP_PKG}-php-xmlrpc"
    "${PHP_PKG}-php-pecl-zip"
    "${PHP_PKG}-php-opcache"
    "${PHP_PKG}-php-sodium"
    "${PHP_PKG}-php-brotli"
    "${PHP_PKG}-php-zstd"
    "${PHP_PKG}-php-zstd-devel"
    "${PHP_PKG}-php-process"
    "libsodium-devel"
    "oniguruma5php"
    "oniguruma5php-devel"
)

if ! rpm -q "${PHP_PKG}-php-fpm" >/dev/null 2>&1; then
    dnf install -y "${PHP_DEPENDENCIES[@]}" >/dev/null 2>&1
fi

# --- 3. FPM POOL CONFIGURATION ---
cat << EOF > /etc/opt/remi/${PHP_PKG}/php-fpm.d/$DOMAIN.conf
[$USER_NAME]
user = $USER_NAME
group = nginx
listen = /run/php-fpm/$DOMAIN.sock
listen.owner = nginx
listen.group = nginx
pm = ondemand
pm.max_children = 50
pm.process_idle_timeout = 10s
pm.max_requests = 1000
chdir = $WEB_ROOT/public
php_admin_value[open_basedir] = $WEB_ROOT/public:$WEB_ROOT/tmp:/usr/share:/tmp:/dev/urandom
php_admin_value[upload_tmp_dir] = $WEB_ROOT/tmp
php_admin_value[session.save_path] = $WEB_ROOT/tmp
php_admin_value[memory_limit] = 256M
EOF

# --- 4. WP-CLI VERSIONED WRAPPER ---
# Creates e.g. /usr/local/bin/wp84 for PHP 8.4 specifically
if [ ! -f "/usr/local/bin/wp${PHP_PKG_VER}" ]; then
    cat << EOF > "/usr/local/bin/wp${PHP_PKG_VER}"
#!/bin/bash
/opt/remi/${PHP_PKG}/root/usr/bin/php /usr/local/bin/wp "\$@"
EOF
    chmod +x "/usr/local/bin/wp${PHP_PKG_VER}"
fi

# Ensure a global 'php' symlink exists (defaults to first installed version)
if [ ! -f "/usr/bin/php" ]; then
    ln -sf "/opt/remi/${PHP_PKG}/root/usr/bin/php" /usr/bin/php
fi

# --- 5. STATE & JSON RESPONSE UPDATES ---
RELOAD_PHP_VERSIONS+=" $PHP_PKG_VER"

MODULE_RESULT=$(echo "$MODULE_RESULT" | jq \
    --arg php "$WITH_PHP" \
    '. + {php_version: $php}')