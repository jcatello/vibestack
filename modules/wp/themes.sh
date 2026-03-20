#!/bin/bash
# /opt/vibestack/modules/wp/themes.sh
# Module: WordPress Theme Management
# Actions: list, install, uninstall, activate, update, update_all,
#          toggle_autoupdate, check_updates, get_info

source /opt/vibestack/includes/common.sh

# --- ARGUMENTS ---
WP_ACTION=$1
DOMAIN=$2
THEME_SLUG=$3
EXTRA=$4

[[ -z "$WP_ACTION" ]] && fatal_error 4100 "Theme action missing"
[[ -z "$DOMAIN" ]]    && fatal_error 4101 "Domain missing in themes.sh"

USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"
PHP_BIN=$(find /opt/remi/php*/root/usr/bin/php -type f 2>/dev/null | sort -V | tail -1)
WP_BIN="/usr/local/bin/wp"

[[ -z "$PHP_BIN" ]] && fatal_error 4102 "No PHP binary found"

wp_run() {
    sudo -u "$USER_NAME" \
        PHP_BINARY="$PHP_BIN" \
        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "$PHP_BIN" "$WP_BIN" "$@" \
        --path="$WEB_ROOT/public" \
        --allow-root \
        2>&1
}

case "$WP_ACTION" in

    "list")
        RAW=$(wp_run theme list --format=json --fields=name,title,status,version,update,update_version,auto_update)
        if ! echo "$RAW" | jq empty >/dev/null 2>&1; then
            fatal_error 4110 "Failed to retrieve theme list for $DOMAIN"
        fi
        COUNT=$(echo "$RAW" | jq 'length')
        ACTIVE=$(echo "$RAW" | jq '[.[] | select(.status=="active")] | .[0].name // "none"')
        UPDATES=$(echo "$RAW" | jq '[.[] | select(.update=="available")] | length')
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --argjson count "$COUNT" \
            --argjson active_theme "$ACTIVE" \
            --argjson updates_available "$UPDATES" \
            --argjson themes "$RAW" \
            '{domain: $domain, theme_count: $count, active_theme: $active_theme, updates_available: $updates_available, themes: $themes}')
        ;;

    "install")
        [[ -z "$THEME_SLUG" ]] && fatal_error 4111 "Theme slug required for install"
        IFS=',' read -ra SLUGS <<< "$THEME_SLUG"
        RESULTS="[]"
        for slug in "${SLUGS[@]}"; do
            slug=$(echo "$slug" | xargs)
            if [[ -n "$EXTRA" ]]; then
                OUT=$(wp_run theme install "$slug" --version="$EXTRA")
            else
                OUT=$(wp_run theme install "$slug")
            fi
            STATUS=$?
            RESULTS=$(echo "$RESULTS" | jq \
                --arg slug "$slug" --arg output "$OUT" \
                --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
                '. + [{slug: $slug, success: $success, output: $output}]')
        done
        MODULE_RESULT=$(jq -n --arg domain "$DOMAIN" --argjson results "$RESULTS" \
            '{domain: $domain, results: $results}')
        ;;

    "uninstall")
        [[ -z "$THEME_SLUG" ]] && fatal_error 4112 "Theme slug required for uninstall"
        # Prevent uninstalling the active theme
        ACTIVE=$(wp_run theme list --status=active --format=json | jq -r '.[0].name // ""')
        if [[ "$THEME_SLUG" == "$ACTIVE" ]]; then
            fatal_error 4113 "Cannot uninstall active theme '$THEME_SLUG'. Activate another theme first."
        fi
        OUT=$(wp_run theme uninstall "$THEME_SLUG")
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg slug "$THEME_SLUG" --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, slug: $slug, success: $success, output: $output}')
        ;;

    "activate")
        [[ -z "$THEME_SLUG" ]] && fatal_error 4114 "Theme slug required for activate"
        OUT=$(wp_run theme activate "$THEME_SLUG")
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg slug "$THEME_SLUG" --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, slug: $slug, success: $success, output: $output}')
        ;;

    "update")
        [[ -z "$THEME_SLUG" ]] && fatal_error 4115 "Theme slug required for update"
        IFS=',' read -ra SLUGS <<< "$THEME_SLUG"
        RESULTS="[]"
        for slug in "${SLUGS[@]}"; do
            slug=$(echo "$slug" | xargs)
            OUT=$(wp_run theme update "$slug")
            STATUS=$?
            RESULTS=$(echo "$RESULTS" | jq \
                --arg slug "$slug" --arg output "$OUT" \
                --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
                '. + [{slug: $slug, success: $success, output: $output}]')
        done
        MODULE_RESULT=$(jq -n --arg domain "$DOMAIN" --argjson results "$RESULTS" \
            '{domain: $domain, results: $results}')
        ;;

    "update_all")
        OUT=$(wp_run theme update --all)
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, output: $output}')
        ;;

    "toggle_autoupdate")
        [[ -z "$THEME_SLUG" ]] && fatal_error 4116 "Theme slug required"
        [[ "$EXTRA" != "enable" && "$EXTRA" != "disable" ]] && \
            fatal_error 4117 "Extra param must be 'enable' or 'disable'"
        OUT=$(wp_run theme auto-updates "$EXTRA" "$THEME_SLUG")
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg slug "$THEME_SLUG" --arg state "$EXTRA" --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, slug: $slug, auto_update: $state, success: $success, output: $output}')
        ;;

    "check_updates")
        RAW=$(wp_run theme list --update=available --format=json \
            --fields=name,title,version,update_version)
        if ! echo "$RAW" | jq empty >/dev/null 2>&1; then RAW="[]"; fi
        COUNT=$(echo "$RAW" | jq 'length')
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --argjson count "$COUNT" --argjson themes "$RAW" \
            '{domain: $domain, updates_available: $count, themes: $themes}')
        ;;

    "get_info")
        [[ -z "$THEME_SLUG" ]] && fatal_error 4118 "Theme slug required for get_info"
        RAW=$(wp_run theme get "$THEME_SLUG" --format=json)
        if ! echo "$RAW" | jq empty >/dev/null 2>&1; then
            fatal_error 4119 "Theme '$THEME_SLUG' not found on $DOMAIN"
        fi
        MODULE_RESULT=$(jq -n --arg domain "$DOMAIN" --argjson theme "$RAW" \
            '{domain: $domain, theme: $theme}')
        ;;

    *)
        fatal_error 4199 "Unknown theme action: $WP_ACTION. Valid: list, install, uninstall, activate, update, update_all, toggle_autoupdate, check_updates, get_info"
        ;;
esac
