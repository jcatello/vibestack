#!/bin/bash
# /opt/vibestack/modules/wp/settings.sh
# Module: WordPress Site Settings & Operations
# Actions: get_option, set_option, flush_cache, flush_transients,
#          toggle_debug, search_replace, run_cron, get_cron,
#          get_site_info, set_maintenance, get_constants

source /opt/vibestack/includes/common.sh

WP_ACTION=$1
DOMAIN=$2
PAYLOAD=$3    # JSON payload or single value depending on action

[[ -z "$WP_ACTION" ]] && fatal_error 4300 "Settings action missing"
[[ -z "$DOMAIN" ]]    && fatal_error 4301 "Domain missing in settings.sh"

USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"
PHP_BIN=$(find /opt/remi/php*/root/usr/bin/php -type f 2>/dev/null | sort -V | tail -1)
WP_BIN="/usr/local/bin/wp"

[[ -z "$PHP_BIN" ]] && fatal_error 4302 "No PHP binary found"

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
    "get_site_info")
        SITEURL=$(wp_run option get siteurl 2>/dev/null | tr -d '\n')
        BLOGNAME=$(wp_run option get blogname 2>/dev/null | tr -d '\n')
        BLOGDESC=$(wp_run option get blogdescription 2>/dev/null | tr -d '\n')
        ADMIN_EMAIL=$(wp_run option get admin_email 2>/dev/null | tr -d '\n')
        WP_VERSION=$(wp_run core version 2>/dev/null | tr -d '\n')
        LANG=$(wp_run option get WPLANG 2>/dev/null | tr -d '\n')
        ACTIVE_THEME=$(wp_run theme list --status=active --format=json | jq -r '.[0].name // "unknown"')
        PLUGIN_COUNT=$(wp_run plugin list --format=json 2>/dev/null | jq 'length')
        ACTIVE_PLUGINS=$(wp_run plugin list --status=active --format=json 2>/dev/null | jq 'length')
        USER_COUNT=$(wp_run user list --format=json 2>/dev/null | jq 'length')

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg siteurl "$SITEURL" \
            --arg blogname "$BLOGNAME" \
            --arg blogdescription "$BLOGDESC" \
            --arg admin_email "$ADMIN_EMAIL" \
            --arg wp_version "$WP_VERSION" \
            --arg language "$LANG" \
            --arg active_theme "$ACTIVE_THEME" \
            --argjson plugin_count "${PLUGIN_COUNT:-0}" \
            --argjson active_plugin_count "${ACTIVE_PLUGINS:-0}" \
            --argjson user_count "${USER_COUNT:-0}" \
            '{
                domain: $domain,
                siteurl: $siteurl,
                blogname: $blogname,
                blogdescription: $blogdescription,
                admin_email: $admin_email,
                wp_version: $wp_version,
                language: $language,
                active_theme: $active_theme,
                plugin_count: $plugin_count,
                active_plugin_count: $active_plugin_count,
                user_count: $user_count
            }')
        ;;

    # -------------------------------------------------------------------------
    "get_option")
        [[ -z "$PAYLOAD" ]] && fatal_error 4310 "Option name required"
        VALUE=$(wp_run option get "$PAYLOAD" 2>/dev/null)
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg option "$PAYLOAD" --arg value "$VALUE" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, option: $option, value: $value, success: $success}')
        ;;

    # -------------------------------------------------------------------------
    "set_option")
        # PAYLOAD = {"option":"blogname","value":"My Site"}
        [[ -z "$PAYLOAD" ]] && fatal_error 4311 "JSON payload required: {option, value}"
        OPT_NAME=$(echo "$PAYLOAD" | jq -r '.option // empty')
        OPT_VALUE=$(echo "$PAYLOAD" | jq -r '.value // empty')
        [[ -z "$OPT_NAME" ]] && fatal_error 4312 "option name required"
        OUT=$(wp_run option update "$OPT_NAME" "$OPT_VALUE")
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg option "$OPT_NAME" --arg value "$OPT_VALUE" \
            --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, option: $option, value: $value, success: $success, output: $output}')
        ;;

    # -------------------------------------------------------------------------
    "flush_cache")
        OUT=$(wp_run cache flush)
        STATUS=$?
        # Also flush Redis object cache if plugin active
        REDIS_OUT=$(wp_run redis flush 2>/dev/null || echo "Redis plugin not active")
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg output "$OUT" --arg redis_output "$REDIS_OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, object_cache_flushed: true, output: $output, redis_output: $redis_output}')
        ;;

    # -------------------------------------------------------------------------
    "flush_transients")
        COUNT=$(wp_run transient delete --expired --all 2>&1 | grep -oP '\d+' | head -1 || echo "0")
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg deleted "${COUNT:-0}" \
            '{domain: $domain, transients_deleted: $deleted, success: true}')
        ;;

    # -------------------------------------------------------------------------
    "toggle_debug")
        # PAYLOAD = "enable" or "disable"
        [[ "$PAYLOAD" != "enable" && "$PAYLOAD" != "disable" ]] && \
            fatal_error 4313 "Payload must be 'enable' or 'disable'"

        WP_CONFIG="$WEB_ROOT/public/wp-config.php"
        [[ ! -f "$WP_CONFIG" ]] && fatal_error 4314 "wp-config.php not found for $DOMAIN"

        if [[ "$PAYLOAD" == "enable" ]]; then
            wp_run config set WP_DEBUG true --raw
            wp_run config set WP_DEBUG_LOG true --raw
            wp_run config set WP_DEBUG_DISPLAY false --raw
            DEBUG_LOG="$WEB_ROOT/public/wp-content/debug.log"
            MODE="enabled"
        else
            wp_run config set WP_DEBUG false --raw
            wp_run config set WP_DEBUG_LOG false --raw
            wp_run config set WP_DEBUG_DISPLAY false --raw
            MODE="disabled"
        fi

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg mode "$MODE" \
            '{domain: $domain, debug: $mode, success: true}')
        ;;

    # -------------------------------------------------------------------------
    "search_replace")
        # PAYLOAD = {"from":"oldurl.com","to":"newurl.com","dry_run":false}
        [[ -z "$PAYLOAD" ]] && fatal_error 4315 "JSON payload required: {from, to, dry_run}"
        SR_FROM=$(echo "$PAYLOAD" | jq -r '.from // empty')
        SR_TO=$(echo "$PAYLOAD" | jq -r '.to // empty')
        SR_DRY=$(echo "$PAYLOAD" | jq -r '.dry_run // false')

        [[ -z "$SR_FROM" || -z "$SR_TO" ]] && fatal_error 4316 "from and to required"

        CMD_ARGS=(search-replace "$SR_FROM" "$SR_TO" --all-tables --report-changed-only)
        [[ "$SR_DRY" == "true" ]] && CMD_ARGS+=(--dry-run)

        OUT=$(wp_run "${CMD_ARGS[@]}")
        STATUS=$?

        REPLACEMENTS=$(echo "$OUT" | grep -oP '\d+ replacements' | grep -oP '\d+' || echo "0")

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg from "$SR_FROM" \
            --arg to "$SR_TO" \
            --argjson dry_run "$([ "$SR_DRY" == "true" ] && echo true || echo false)" \
            --arg replacements "${REPLACEMENTS:-0}" \
            --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, from: $from, to: $to, dry_run: $dry_run, replacements: $replacements, success: $success, output: $output}')
        ;;

    # -------------------------------------------------------------------------
    "run_cron")
        OUT=$(wp_run cron event run --due-now)
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, output: $output}')
        ;;

    # -------------------------------------------------------------------------
    "get_cron")
        RAW=$(wp_run cron event list --format=json \
            --fields=hook,next_run,recurrence,args 2>/dev/null)
        if ! echo "$RAW" | jq empty >/dev/null 2>&1; then RAW="[]"; fi
        COUNT=$(echo "$RAW" | jq 'length')
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --argjson count "$COUNT" --argjson events "$RAW" \
            '{domain: $domain, cron_event_count: $count, events: $events}')
        ;;

    # -------------------------------------------------------------------------
    "set_maintenance")
        # PAYLOAD = "enable" or "disable"
        [[ "$PAYLOAD" != "enable" && "$PAYLOAD" != "disable" ]] && \
            fatal_error 4317 "Payload must be 'enable' or 'disable'"
        MAINT_FILE="$WEB_ROOT/public/.maintenance"
        if [[ "$PAYLOAD" == "enable" ]]; then
            echo "<?php \$upgrading = $(date +%s);" > "$MAINT_FILE"
            chown "${USER_NAME}:${USER_NAME}" "$MAINT_FILE"
            MODE="enabled"
        else
            rm -f "$MAINT_FILE"
            MODE="disabled"
        fi
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg mode "$MODE" \
            '{domain: $domain, maintenance_mode: $mode, success: true}')
        ;;

    # -------------------------------------------------------------------------
    "update_core")
        OUT=$(wp_run core update)
        STATUS=$?
        NEW_VERSION=$(wp_run core version 2>/dev/null | tr -d '\n')
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg output "$OUT" \
            --arg new_version "$NEW_VERSION" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, new_version: $new_version, output: $output}')
        ;;

    # -------------------------------------------------------------------------
    "update_db")
        OUT=$(wp_run core update-db)
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, output: $output}')
        ;;

    *)
        fatal_error 4399 "Unknown settings action: $WP_ACTION. Valid: get_site_info, get_option, set_option, flush_cache, flush_transients, toggle_debug, search_replace, run_cron, get_cron, set_maintenance, update_core, update_db"
        ;;
esac
