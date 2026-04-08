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

# Also clean up basic auth files if present
rm -f "/etc/nginx/auth/${DOMAIN}.htpasswd"
rm -f "/etc/nginx/auth/${DOMAIN}-wplogin.htpasswd"

# --- 3. PHP-FPM CLEANUP ---
# Stop and remove per-domain systemd service unit (vs-php-DOMAIN.service)
SYSTEMD_SERVICE="vs-php-${USER_NAME}.service"
if systemctl is-active "$SYSTEMD_SERVICE" >/dev/null 2>&1; then
    systemctl stop "$SYSTEMD_SERVICE" >/dev/null 2>&1
fi
if systemctl is-enabled "$SYSTEMD_SERVICE" >/dev/null 2>&1; then
    systemctl disable "$SYSTEMD_SERVICE" >/dev/null 2>&1
fi
rm -f "/etc/systemd/system/${SYSTEMD_SERVICE}"
systemctl daemon-reload >/dev/null 2>&1

# Remove pool config files and per-domain master confs across all PHP versions
for pool in /etc/opt/remi/php*/php-fpm.d/$DOMAIN.conf; do
    [ -f "$pool" ] && rm -f "$pool"
done
for master in /etc/opt/remi/php*/vibestack-${USER_NAME}.conf; do
    [ -f "$master" ] && rm -f "$master"
done

# Remove socket if still present
rm -f "/run/php-fpm/${DOMAIN}.sock"
rm -f "/run/php-fpm/${USER_NAME}.pid"

# --- 4. REDIS CLEANUP ---
REDIS_SERVICE="redis-${USER_NAME}"
if systemctl is-active "$REDIS_SERVICE" >/dev/null 2>&1; then
    systemctl stop "$REDIS_SERVICE" >/dev/null 2>&1
fi
if systemctl is-enabled "$REDIS_SERVICE" >/dev/null 2>&1; then
    systemctl disable "$REDIS_SERVICE" >/dev/null 2>&1
fi
rm -f "/etc/systemd/system/${REDIS_SERVICE}.service"
rm -f "/etc/redis/${DOMAIN}.conf"
rm -f "/run/redis/${DOMAIN}.sock"
rm -rf "/var/lib/redis/${DOMAIN}"
rm -f "/var/log/redis/${DOMAIN}.log"
systemctl daemon-reload >/dev/null 2>&1

# --- 5. DATABASE CLEANUP ---
mysql -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;"
mysql -e "DROP USER IF EXISTS '${DB_NAME}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# --- 6. FILESYSTEM & USER CLEANUP ---
rm -f "/etc/logrotate.d/$DOMAIN"

# Remove nginx from the site group before deleting it
gpasswd -d nginx "$USER_NAME" >/dev/null 2>&1

userdel -r "$USER_NAME" >/dev/null 2>&1
groupdel "$USER_NAME" >/dev/null 2>&1

rm -rf "$WEB_ROOT"

# The API router handles the final JSON response for remove_site