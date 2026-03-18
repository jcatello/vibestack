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
if ! command -v wp &> /dev/null; then
    curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
fi

# --- 4. CORE DOWNLOAD ---
# --skip-content omits default themes/plugins (twenty*, hello, akismet)
sudo -u "$USER_NAME" -i wp core download \
    --path="$WEB_ROOT/public" \
    --skip-content \
    --quiet

# --- 5. WP-CONFIG ---
sudo -u "$USER_NAME" -i wp config create \
    --path="$WEB_ROOT/public" \
    --dbname="$DB_NAME" \
    --dbuser="$DB_USER" \
    --dbpass="$DB_PASS" \
    --dbhost="localhost" \
    --quiet

# --- 6. CORE INSTALL ---
# Build command as array so locale can be cleanly optional
WP_INSTALL_CMD=(
    sudo -u "$USER_NAME" -i wp core install
    --path="$WEB_ROOT/public"
    --url="https://${DOMAIN}"
    --title="$WP_TITLE"
    --admin_user="$WP_ADMIN_USER"
    --admin_password="$WP_ADMIN_PASS"
    --admin_email="$WP_ADMIN_EMAIL"
    --skip-email
    --quiet
)

if [[ -n "$WP_LOCALE" ]]; then
    WP_INSTALL_CMD+=(--locale="$WP_LOCALE")
fi

"${WP_INSTALL_CMD[@]}"

# --- 7. PLUGINS ---
if [[ -n "$WP_PLUGINS" ]]; then
    IFS=',' read -ra PLUGINS <<< "$WP_PLUGINS"
    for plugin in "${PLUGINS[@]}"; do
        sudo -u "$USER_NAME" -i wp plugin install "$plugin" \
            --activate \
            --path="$WEB_ROOT/public" \
            --quiet
    done
fi

# --- 8. THEMES ---
if [[ -n "$WP_THEMES" ]]; then
    IFS=',' read -ra THEMES <<< "$WP_THEMES"
    for theme in "${THEMES[@]}"; do
        sudo -u "$USER_NAME" -i wp theme install "$theme" \
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