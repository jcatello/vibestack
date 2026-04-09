#!/bin/bash
# /opt/vibestack/modules/app_wp.sh
# Module: WordPress Automated Installation

# --- 0. MANDATORY INCLUDES ---
source /opt/vibestack/includes/common.sh

# --- 1. ARGUMENTS (all passed from vibestack-api.sh) ---
DOMAIN=$1
WP_TITLE=$2
WP_ADMIN_USER=$3
WP_ADMIN_PASS=$4
WP_ADMIN_EMAIL=$5
WP_LOCALE=$6
WP_PLUGINS=$7
WP_THEMES=$8
WITH_PHP=${9:-"8.4"}   # PHP version — passed from vibestack-api.sh

# --- 2. VALIDATION ---
[[ -z "$DOMAIN" ]]         && fatal_error 1006 "Domain missing in app_wp.sh"
[[ -z "$WP_TITLE" ]]       && fatal_error 1006 "WP site title missing in app_wp.sh"
[[ -z "$WP_ADMIN_USER" ]]  && fatal_error 1006 "WP admin username missing in app_wp.sh"
[[ -z "$WP_ADMIN_PASS" ]]  && fatal_error 1006 "WP admin password missing in app_wp.sh"
[[ -z "$WP_ADMIN_EMAIL" ]] && fatal_error 1006 "WP admin email missing in app_wp.sh"

USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"

# Extract DB credentials injected by core_db.sh
DB_NAME=$(echo "$MODULE_RESULT" | jq -r '.db_name // empty')
DB_USER=$(echo "$MODULE_RESULT" | jq -r '.db_user // empty')
DB_PASS=$(echo "$MODULE_RESULT" | jq -r '.db_pass // empty')

[[ -z "$DB_NAME" ]] && fatal_error 1007 "Database credentials missing. Ensure --with-db was passed."

# --- 3. WP-CLI DEPENDENCY ---
WP_BIN="/usr/local/bin/wp"
if [ ! -f "$WP_BIN" ]; then
    curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    mv wp-cli.phar "$WP_BIN"
fi

# PHP binary — use the Remi versioned binary matching the site's PHP version
PHP_PKG_VER="${WITH_PHP//./}"
PHP_BIN="/opt/remi/php${PHP_PKG_VER}/root/usr/bin/php"

# Fallback to system php if versioned binary not found
[ ! -f "$PHP_BIN" ] && PHP_BIN="/usr/bin/php"
[ ! -f "$PHP_BIN" ] && fatal_error 1008 "No PHP binary found for version ${WITH_PHP}"

# WP runner: always use full paths, set PHP binary explicitly
# sudo -u runs as site user; PATH is set explicitly to avoid login shell issues
wp_run() {
    sudo -u "$USER_NAME" \
        PHP_BINARY="$PHP_BIN" \
        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "$PHP_BIN" "$WP_BIN" "$@"
}

# --- 4. CORE DOWNLOAD ---
# --skip-content omits default themes/plugins (twenty*, hello, akismet)
wp_run core download \
    --path="$WEB_ROOT/public" \
    --skip-content \
    --quiet

[ $? -ne 0 ] && fatal_error 1009 "wp core download failed for ${DOMAIN}"

# --- 5. WP-CONFIG ---
wp_run config create \
    --path="$WEB_ROOT/public" \
    --dbname="$DB_NAME" \
    --dbuser="$DB_USER" \
    --dbpass="$DB_PASS" \
    --dbhost="localhost" \
    --quiet

[ $? -ne 0 ] && fatal_error 1010 "wp config create failed for ${DOMAIN}"

# --- 6. CORE INSTALL ---
WP_INSTALL_ARGS=(
    core install
    --path="$WEB_ROOT/public"
    --url="https://${DOMAIN}"
    --title="$WP_TITLE"
    --admin_user="$WP_ADMIN_USER"
    --admin_password="$WP_ADMIN_PASS"
    --admin_email="$WP_ADMIN_EMAIL"
    --skip-email
    --quiet
)

[[ -n "$WP_LOCALE" ]] && WP_INSTALL_ARGS+=(--locale="$WP_LOCALE")

wp_run "${WP_INSTALL_ARGS[@]}"
[ $? -ne 0 ] && fatal_error 1011 "wp core install failed for ${DOMAIN}"

# --- 7. PLUGINS ---
if [[ -n "$WP_PLUGINS" ]]; then
    IFS=',' read -ra PLUGINS <<< "$WP_PLUGINS"
    for plugin in "${PLUGINS[@]}"; do
        wp_run plugin install "$plugin" \
            --activate \
            --path="$WEB_ROOT/public" \
            --quiet
    done
fi

# --- 8. THEMES ---
if [[ -n "$WP_THEMES" ]]; then
    IFS=',' read -ra THEMES <<< "$WP_THEMES"
    for theme in "${THEMES[@]}"; do
        wp_run theme install "$theme" \
            --path="$WEB_ROOT/public" \
            --quiet
    done
fi

# --- 9. STATE & JSON RESPONSE UPDATES ---
MODULE_RESULT=$(echo "$MODULE_RESULT" | jq \
    --arg app "wordpress" \
    --arg wp_url "https://${DOMAIN}" \
    --arg wp_title "$WP_TITLE" \
    --arg wp_user "$WP_ADMIN_USER" \
    --arg wp_pass "$WP_ADMIN_PASS" \
    --arg wp_email "$WP_ADMIN_EMAIL" \
    --arg wp_locale "${WP_LOCALE:-en_US}" \
    '. + {
        app: $app,
        wp_url: $wp_url,
        wp_title: $wp_title,
        wp_admin_user: $wp_user,
        wp_admin_pass: $wp_pass,
        wp_admin_email: $wp_email,
        wp_locale: $wp_locale
    }')
