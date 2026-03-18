#!/bin/bash
# /opt/vibestack/modules/app_wp.sh
# Module: WordPress Automated Installation

# --- 0. MANDATORY INCLUDES ---
source /opt/vibestack/includes/common.sh

# --- 1. VALIDATION ---
DOMAIN=$1
WP_PLUGINS=$2
WP_THEMES=$3

[[ -z "$DOMAIN" ]] && fatal_error 1006 "Domain missing in app_wp.sh"

USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"

# Extract DB credentials injected by core_db.sh
DB_NAME=$(echo "$MODULE_RESULT" | jq -r '.db_name // empty')
DB_USER=$(echo "$MODULE_RESULT" | jq -r '.db_user // empty')
DB_PASS=$(echo "$MODULE_RESULT" | jq -r '.db_pass // empty')

[[ -z "$DB_NAME" ]] && fatal_error 1007 "Database credentials missing. Ensure --with-db was passed."

# --- 2. WP-CLI DEPENDENCY ---
if ! command -v wp &> /dev/null; then
    curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
fi

# --- 3. CORE DOWNLOAD & CONFIG ---
sudo -u "$USER_NAME" -i wp core download \
    --path="$WEB_ROOT/public" \
    --quiet

sudo -u "$USER_NAME" -i wp config create \
    --path="$WEB_ROOT/public" \
    --dbname="$DB_NAME" \
    --dbuser="$DB_USER" \
    --dbpass="$DB_PASS" \
    --dbhost="localhost" \
    --quiet

# --- 4. CORE INSTALL ---
# Generate a secure admin password and use the domain as the site title placeholder
WP_ADMIN_PASS=$(openssl rand -base64 16)
WP_ADMIN_USER="admin"
WP_ADMIN_EMAIL="admin@${DOMAIN}"

sudo -u "$USER_NAME" -i wp core install \
    --path="$WEB_ROOT/public" \
    --url="https://${DOMAIN}" \
    --title="${DOMAIN}" \
    --admin_user="$WP_ADMIN_USER" \
    --admin_password="$WP_ADMIN_PASS" \
    --admin_email="$WP_ADMIN_EMAIL" \
    --skip-email \
    --quiet

# --- 5. PLUGINS ---
if [[ -n "$WP_PLUGINS" ]]; then
    IFS=',' read -ra PLUGINS <<< "$WP_PLUGINS"
    for plugin in "${PLUGINS[@]}"; do
        sudo -u "$USER_NAME" -i wp plugin install "$plugin" \
            --activate \
            --path="$WEB_ROOT/public" \
            --quiet
    done
fi

# --- 6. THEMES ---
if [[ -n "$WP_THEMES" ]]; then
    IFS=',' read -ra THEMES <<< "$WP_THEMES"
    for theme in "${THEMES[@]}"; do
        sudo -u "$USER_NAME" -i wp theme install "$theme" \
            --path="$WEB_ROOT/public" \
            --quiet
    done
fi

# --- 7. STATE & JSON RESPONSE UPDATES ---
MODULE_RESULT=$(echo "$MODULE_RESULT" | jq \
    --arg app "wordpress" \
    --arg wp_user "$WP_ADMIN_USER" \
    --arg wp_pass "$WP_ADMIN_PASS" \
    --arg wp_email "$WP_ADMIN_EMAIL" \
    '. + {app: $app, wp_admin_user: $wp_user, wp_admin_pass: $wp_pass, wp_admin_email: $wp_email}')