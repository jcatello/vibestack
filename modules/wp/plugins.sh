#!/bin/bash
# /opt/vibestack/modules/wp/plugins.sh
# Module: WordPress Plugin Management
# Actions: list, install, uninstall, activate, deactivate, update, update_all,
#          toggle_autoupdate, check_updates, get_info

source /opt/vibestack/includes/common.sh

# --- ARGUMENTS ---
WP_ACTION=$1
DOMAIN=$2
PLUGIN_SLUG=$3     # Comma-separated for bulk actions
EXTRA=$4           # Extra param (e.g. version for install)

[[ -z "$WP_ACTION" ]] && fatal_error 4000 "Plugin action missing"
[[ -z "$DOMAIN" ]]    && fatal_error 4001 "Domain missing in plugins.sh"

USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"
PHP_BIN=$(find /opt/remi/php*/root/usr/bin/php -type f 2>/dev/null | sort -V | tail -1)
WP_BIN="/usr/local/bin/wp"

[[ -z "$PHP_BIN" ]] && fatal_error 4002 "No PHP binary found"
[[ ! -f "$WP_BIN" ]] && fatal_error 4003 "WP-CLI not found at $WP_BIN"

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

    # -------------------------------------------------------------------------
    "list")
        RAW=$(wp_run plugin list --format=json --fields=name,title,status,version,update,update_version,auto_update)
        if ! echo "$RAW" | jq empty >/dev/null 2>&1; then
            fatal_error 4010 "Failed to retrieve plugin list for $DOMAIN"
        fi
        COUNT=$(echo "$RAW" | jq 'length')
        UPDATES=$(echo "$RAW" | jq '[.[] | select(.update=="available")] | length')
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --argjson count "$COUNT" \
            --argjson updates_available "$UPDATES" \
            --argjson plugins "$RAW" \
            '{domain: $domain, plugin_count: $count, updates_available: $updates_available, plugins: $plugins}')
        ;;

    # -------------------------------------------------------------------------
    "install")
        [[ -z "$PLUGIN_SLUG" ]] && fatal_error 4011 "Plugin slug required for install"
        IFS=',' read -ra SLUGS <<< "$PLUGIN_SLUG"
        RESULTS="[]"
        for slug in "${SLUGS[@]}"; do
            slug=$(echo "$slug" | xargs) # trim whitespace
            if [[ -n "$EXTRA" ]]; then
                OUT=$(wp_run plugin install "$slug" --version="$EXTRA" --activate)
            else
                OUT=$(wp_run plugin install "$slug" --activate)
            fi
            STATUS=$?
            RESULTS=$(echo "$RESULTS" | jq \
                --arg slug "$slug" \
                --arg output "$OUT" \
                --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
                '. + [{slug: $slug, success: $success, output: $output}]')
        done
        MODULE_RESULT=$(jq -n --arg domain "$DOMAIN" --argjson results "$RESULTS" \
            '{domain: $domain, results: $results}')
        ;;

    # -------------------------------------------------------------------------
    "uninstall")
        [[ -z "$PLUGIN_SLUG" ]] && fatal_error 4012 "Plugin slug required for uninstall"
        IFS=',' read -ra SLUGS <<< "$PLUGIN_SLUG"
        RESULTS="[]"
        for slug in "${SLUGS[@]}"; do
            slug=$(echo "$slug" | xargs)
            OUT=$(wp_run plugin deactivate "$slug" && wp_run plugin uninstall "$slug")
            STATUS=$?
            RESULTS=$(echo "$RESULTS" | jq \
                --arg slug "$slug" \
                --arg output "$OUT" \
                --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
                '. + [{slug: $slug, success: $success, output: $output}]')
        done
        MODULE_RESULT=$(jq -n --arg domain "$DOMAIN" --argjson results "$RESULTS" \
            '{domain: $domain, results: $results}')
        ;;

    # -------------------------------------------------------------------------
    "activate")
        [[ -z "$PLUGIN_SLUG" ]] && fatal_error 4013 "Plugin slug required for activate"
        IFS=',' read -ra SLUGS <<< "$PLUGIN_SLUG"
        RESULTS="[]"
        for slug in "${SLUGS[@]}"; do
            slug=$(echo "$slug" | xargs)
            OUT=$(wp_run plugin activate "$slug")
            STATUS=$?
            RESULTS=$(echo "$RESULTS" | jq \
                --arg slug "$slug" --arg output "$OUT" \
                --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
                '. + [{slug: $slug, success: $success, output: $output}]')
        done
        MODULE_RESULT=$(jq -n --arg domain "$DOMAIN" --argjson results "$RESULTS" \
            '{domain: $domain, results: $results}')
        ;;

    # -------------------------------------------------------------------------
    "deactivate")
        [[ -z "$PLUGIN_SLUG" ]] && fatal_error 4014 "Plugin slug required for deactivate"
        IFS=',' read -ra SLUGS <<< "$PLUGIN_SLUG"
        RESULTS="[]"
        for slug in "${SLUGS[@]}"; do
            slug=$(echo "$slug" | xargs)
            OUT=$(wp_run plugin deactivate "$slug")
            STATUS=$?
            RESULTS=$(echo "$RESULTS" | jq \
                --arg slug "$slug" --arg output "$OUT" \
                --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
                '. + [{slug: $slug, success: $success, output: $output}]')
        done
        MODULE_RESULT=$(jq -n --arg domain "$DOMAIN" --argjson results "$RESULTS" \
            '{domain: $domain, results: $results}')
        ;;

    # -------------------------------------------------------------------------
    "update")
        [[ -z "$PLUGIN_SLUG" ]] && fatal_error 4015 "Plugin slug required for update"
        IFS=',' read -ra SLUGS <<< "$PLUGIN_SLUG"
        RESULTS="[]"
        for slug in "${SLUGS[@]}"; do
            slug=$(echo "$slug" | xargs)
            OUT=$(wp_run plugin update "$slug")
            STATUS=$?
            RESULTS=$(echo "$RESULTS" | jq \
                --arg slug "$slug" --arg output "$OUT" \
                --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
                '. + [{slug: $slug, success: $success, output: $output}]')
        done
        MODULE_RESULT=$(jq -n --arg domain "$DOMAIN" --argjson results "$RESULTS" \
            '{domain: $domain, results: $results}')
        ;;

    # -------------------------------------------------------------------------
    "update_all")
        OUT=$(wp_run plugin update --all --format=json)
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, output: $output}')
        ;;

    # -------------------------------------------------------------------------
    "toggle_autoupdate")
        [[ -z "$PLUGIN_SLUG" ]] && fatal_error 4016 "Plugin slug required"
        # EXTRA = "enable" or "disable"
        [[ "$EXTRA" != "enable" && "$EXTRA" != "disable" ]] && \
            fatal_error 4017 "Extra param must be 'enable' or 'disable'"
        IFS=',' read -ra SLUGS <<< "$PLUGIN_SLUG"
        RESULTS="[]"
        for slug in "${SLUGS[@]}"; do
            slug=$(echo "$slug" | xargs)
            OUT=$(wp_run plugin auto-updates "$EXTRA" "$slug")
            STATUS=$?
            RESULTS=$(echo "$RESULTS" | jq \
                --arg slug "$slug" --arg output "$OUT" --arg state "$EXTRA" \
                --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
                '. + [{slug: $slug, auto_update: $state, success: $success, output: $output}]')
        done
        MODULE_RESULT=$(jq -n --arg domain "$DOMAIN" --argjson results "$RESULTS" \
            '{domain: $domain, results: $results}')
        ;;

    # -------------------------------------------------------------------------
    "check_updates")
        RAW=$(wp_run plugin list --update=available --format=json \
            --fields=name,title,version,update_version)
        if ! echo "$RAW" | jq empty >/dev/null 2>&1; then
            RAW="[]"
        fi
        COUNT=$(echo "$RAW" | jq 'length')
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --argjson count "$COUNT" \
            --argjson plugins "$RAW" \
            '{domain: $domain, updates_available: $count, plugins: $plugins}')
        ;;

    # -------------------------------------------------------------------------
    "get_info")
        [[ -z "$PLUGIN_SLUG" ]] && fatal_error 4018 "Plugin slug required for get_info"
        RAW=$(wp_run plugin get "$PLUGIN_SLUG" --format=json)
        if ! echo "$RAW" | jq empty >/dev/null 2>&1; then
            fatal_error 4019 "Plugin '$PLUGIN_SLUG' not found on $DOMAIN"
        fi
        MODULE_RESULT=$(jq -n --arg domain "$DOMAIN" --argjson plugin "$RAW" \
            '{domain: $domain, plugin: $plugin}')
        ;;

    *)
        fatal_error 4099 "Unknown plugin action: $WP_ACTION. Valid: list, install, uninstall, activate, deactivate, update, update_all, toggle_autoupdate, check_updates, get_info"
        ;;
esac
