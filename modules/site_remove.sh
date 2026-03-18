#!/bin/bash
# /opt/vibestack/modules/site_remove.sh
# Module: Complete Site Purge

# --- 0. MANDATORY INCLUDES ---
source /opt/vibestack/includes/common.sh

# --- 1. VALIDATION ---
DOMAIN=$1
[[ -z "$DOMAIN" ]] && fatal_error 1008 "Domain missing in site_remove.sh"

USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"
DB_NAME=${USER_NAME:0:16}

# --- 2. NGINX CLEANUP ---
if [ -f "/etc/nginx/conf.d/$DOMAIN.conf" ]; then
    rm -f "/etc/nginx/conf.d/$DOMAIN.conf"
    REQUIRE_NGINX_RELOAD=1
fi

# --- 3. PHP-FPM CLEANUP ---
# Find and remove FPM pools for this domain across all PHP versions
for pool in /etc/opt/remi/php*/php-fpm.d/$DOMAIN.conf; do
    if [ -f "$pool" ]; then
        PHP_PKG_VER=$(echo "$pool" | grep -oP 'php\K\d+')
        rm -f "$pool"
        RELOAD_PHP_VERSIONS+=" $PHP_PKG_VER"
    fi
done

# --- 4. DATABASE CLEANUP ---
mysql -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;"
mysql -e "DROP USER IF EXISTS '${DB_NAME}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# --- 5. FILESYSTEM & USER CLEANUP ---
rm -f "/etc/logrotate.d/$DOMAIN"

# Remove nginx from the site group before deleting it
gpasswd -d nginx "$USER_NAME" >/dev/null 2>&1

userdel -r "$USER_NAME" >/dev/null 2>&1
groupdel "$USER_NAME" >/dev/null 2>&1

rm -rf "$WEB_ROOT"

# The API router (vibestack-api.sh) handles the final JSON response for remove_site