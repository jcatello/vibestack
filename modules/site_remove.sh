#!/bin/bash
# /opt/vibestack/modules/site_remove.sh
# Module: Complete Site Purge

# --- 0. MANDATORY INCLUDES ---
[ -f /bigscoots/includes/common.sh ] && source /bigscoots/includes/common.sh

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
# Find and remove any FPM pool associated with this domain, regardless of PHP version
for pool in /etc/opt/remi/php*/php-fpm.d/$DOMAIN.conf; do
    if [ -f "$pool" ]; then
        # Extract the version number directly from the path (e.g., gets "84" from "/etc/opt/remi/php84/...")
        PHP_PKG_VER=$(echo "$pool" | grep -oP 'php\K\d+')
        rm -f "$pool"
        # Queue this specific version for a reload
        RELOAD_PHP_VERSIONS+=" $PHP_PKG_VER"
    fi
done

# --- 4. DATABASE CLEANUP ---
mysql -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;"
mysql -e "DROP USER IF EXISTS '${DB_NAME}'@'localhost';"

# --- 5. FILESYSTEM & USER CLEANUP ---
rm -f "/etc/logrotate.d/$DOMAIN"
userdel -r "$USER_NAME" >/dev/null 2>&1
rm -rf "$WEB_ROOT"

# The master router handles the JSON response for the remove action, so we don't need to append to MODULE_RESULT here.