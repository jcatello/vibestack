#!/bin/bash
# /opt/vibestack/modules/core_php.sh
# Module: PHP-FPM Pool Provisioning

# --- 0. MANDATORY INCLUDES ---
[ -f /bigscoots/includes/common.sh ] && source /bigscoots/includes/common.sh

# --- 1. VALIDATION ---
DOMAIN=$1
WITH_PHP=$2

[[ -z "$DOMAIN" || -z "$WITH_PHP" ]] && fatal_error 1004 "Domain or PHP version missing in core_php.sh"

USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"
PHP_PKG_VER="${WITH_PHP//./}"
PHP_PKG="php${PHP_PKG_VER}"

# --- 2. DEPENDENCY CHECK ---
# Ensure the specific PHP version and common extensions are installed
if ! rpm -q ${PHP_PKG}-php-fpm >/dev/null 2>&1; then
    dnf install -y ${PHP_PKG}-php-fpm ${PHP_PKG}-php-mysqlnd ${PHP_PKG}-php-opcache \
                   ${PHP_PKG}-php-gd ${PHP_PKG}-php-mbstring ${PHP_PKG}-php-xml \
                   ${PHP_PKG}-php-bcmath ${PHP_PKG}-php-intl -y >/dev/null 2>&1
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

# --- 4. STATE & JSON RESPONSE UPDATES ---
# Add this specific version to the reload queue
RELOAD_PHP_VERSIONS+=" $PHP_PKG_VER"

# Inject PHP info into the final JSON response
MODULE_RESULT=$(echo "$MODULE_RESULT" | jq \
    --arg php "$WITH_PHP" \
    '. + {php_version: $php}')