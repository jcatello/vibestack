#!/bin/bash
# /opt/vibestack/modules/app_wp.sh
# Module: WordPress Automated Installation

# --- 0. MANDATORY INCLUDES ---
[ -f /bigscoots/includes/common.sh ] && source /bigscoots/includes/common.sh

# --- 1. VALIDATION ---
DOMAIN=$1
WP_PLUGINS=$2
WP_THEMES=$3

[[ -z "$DOMAIN" ]] && fatal_error 1006 "Domain missing in app_wp.sh"

USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"

# Extract the DB credentials that core_db.sh injected into our JSON payload
DB_NAME=$(echo "$MODULE_RESULT" | jq -r '.db_name // empty')
DB_USER=$(echo "$MODULE_RESULT" | jq -r '.db_user // empty')
DB_PASS=$(echo "$MODULE_RESULT" | jq -r '.db_pass // empty')

[[ -z "$DB_NAME" ]] && fatal_error 1007 "Database credentials missing for WordPress install. Ensure --with-db was passed."

# --- 2. WP-CLI DEPENDENCY ---
if ! command -v wp &> /dev/null; then
    curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
fi

# --- 3. CORE INSTALLATION (Executing as the site user) ---
sudo -u "$USER_NAME" -i wp core download --path="$WEB_ROOT/public" --quiet
sudo -u "$USER_NAME" -i wp config create --path="$WEB_ROOT/public" \
    --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" --dbhost="localhost" --quiet

# --- 4. PLUGINS ---
if [[ -n "$WP_PLUGINS" ]]; then
    IFS=',' read -ra PLUGINS <<< "$WP_PLUGINS"
    for plugin in "${PLUGINS[@]}"; do
        sudo -u "$USER_NAME" -i wp plugin install "$plugin" --activate --path="$WEB_ROOT/public" --quiet
    done
fi

# --- 5. THEMES ---
if [[ -n "$WP_THEMES" ]]; then
    IFS=',' read -ra THEMES <<< "$WP_THEMES"
    for theme in "${THEMES[@]}"; do
        sudo -u "$USER_NAME" -i wp theme install "$theme" --path="$WEB_ROOT/public" --quiet
    done
fi

# --- 6. STATE & JSON RESPONSE UPDATES ---
MODULE_RESULT=$(echo "$MODULE_RESULT" | jq '. + {app: "wordpress"}')