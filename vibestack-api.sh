#!/bin/bash
# /opt/vibestack/vibestack-api.sh
# JSON-Strict API Router for the BigScoots Portal

# --- 0. MANDATORY INCLUDES ---
source /opt/vibestack/includes/common.sh

# --- 1. STATE & VARIABLES ---
REQUIRE_NGINX_RELOAD=0
RELOAD_PHP_VERSIONS=""  # Space-separated list e.g. "81 84"

ACTION=""
DOMAIN=""
APP_TYPE="custom"
WITH_PHP=""
WITH_DB=0
WP_PLUGINS=""
WP_THEMES=""

# --- 2. CLOUDFLARE-STYLE JSON RESPONDER & RELOAD HANDLER ---
# Usage: cf_respond <success:true|false> <result_json> <errors_json> <messages_json>
cf_respond() {
    local success=$1
    local result=${2:-"null"}
    local errors=${3:-"[]"}
    local messages=${4:-"[]"}

    # Process Nginx reload safely
    if [[ "$REQUIRE_NGINX_RELOAD" -eq 1 ]]; then
        NGINX_TEST=$(nginx -t 2>&1)
        if [ $? -ne 0 ]; then
            THREAD_TS=$(send_slack_initial "🚨 *Nginx Config Error* on \`$(hostname)\` during action: \`$ACTION\` for \`$DOMAIN\`" "alerts")
            send_slack_thread "$THREAD_TS" "\`\`\`$NGINX_TEST\`\`\`" "alerts"
            success="false"
            errors='[{"code":500,"message":"Nginx configuration test failed. Alert sent to Slack."}]'
            result="null"
        else
            systemctl reload nginx >/dev/null 2>&1
        fi
    fi

    # Process PHP-FPM pool reloads safely
    if [[ "$success" == "true" && -n "$RELOAD_PHP_VERSIONS" ]]; then
        UNIQUE_PHP_VERSIONS=$(echo "$RELOAD_PHP_VERSIONS" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')

        for ver in $UNIQUE_PHP_VERSIONS; do
            FPM_BIN="/opt/remi/php${ver}/root/usr/sbin/php-fpm"
            if [ -x "$FPM_BIN" ]; then
                FPM_TEST=$($FPM_BIN -t 2>&1)
                if [ $? -ne 0 ]; then
                    THREAD_TS=$(send_slack_initial "🚨 *PHP-FPM ${ver} Config Error* on \`$(hostname)\` during action: \`$ACTION\` for \`$DOMAIN\`" "alerts")
                    send_slack_thread "$THREAD_TS" "\`\`\`$FPM_TEST\`\`\`" "alerts"
                    success="false"
                    errors="[{\"code\":500,\"message\":\"PHP-FPM ${ver} configuration test failed. Alert sent to Slack.\"}]"
                    result="null"
                    break
                else
                    systemctl reload "php${ver}-php-fpm" >/dev/null 2>&1
                fi
            fi
        done
    fi

    printf '{"success":%s,"errors":%s,"messages":%s,"result":%s}\n' \
        "$success" "$errors" "$messages" "$result"

    if [ "$success" == "false" ]; then exit 1; else exit 0; fi
}

# --- 3. DYNAMIC ARGUMENT PARSER ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --action=*)     ACTION="${1#*=}" ;;
        --domain=*)     DOMAIN="${1#*=}" ;;
        --app-type=*)   APP_TYPE="${1#*=}" ;;
        --with-php=*)   WITH_PHP="${1#*=}" ;;
        --with-db)      WITH_DB=1 ;;
        --wp-plugins=*) WP_PLUGINS="${1#*=}" ;;
        --wp-themes=*)  WP_THEMES="${1#*=}" ;;
        *) fatal_error 1000 "Unknown parameter: $1" ;;
    esac
    shift
done

# --- 4. DEPENDENCY INFERENCE ---
# WordPress always needs PHP and a DB
if [[ "$APP_TYPE" == "wordpress" || "$APP_TYPE" == "wp" ]]; then
    WITH_PHP=${WITH_PHP:-"8.4"}
    WITH_DB=1
fi

# --- 5. HELPER: Validate MODULE_RESULT is still valid JSON after each module ---
validate_module_result() {
    local module=$1
    if ! echo "$MODULE_RESULT" | jq empty >/dev/null 2>&1; then
        THREAD_TS=$(send_slack_initial "🚨 *MODULE_RESULT corruption* after \`$module\` on \`$(hostname)\` for \`$DOMAIN\`" "alerts")
        send_slack_thread "$THREAD_TS" "MODULE_RESULT was not valid JSON after sourcing $module" "alerts"
        cf_respond "false" "null" "[{\"code\":500,\"message\":\"Internal state corruption after $module. Alert sent to Slack.\"}]" "[]"
    fi
}

# --- 6. ROUTER LOGIC ---
case "$ACTION" in

    "create_site")
        [[ -z "$DOMAIN" ]] && fatal_error 1001 "Missing required parameter: --domain"

        MODULE_RESULT="{}"

        # 1. Base Nginx/Linux User Setup (always runs)
        source /opt/vibestack/modules/core_nginx.sh "$DOMAIN" >> /opt/vibestack/logs/api-actions.log 2>&1
        validate_module_result "core_nginx.sh"

        # 2. PHP Pool Setup (conditional)
        if [[ -n "$WITH_PHP" ]]; then
            source /opt/vibestack/modules/core_php.sh "$DOMAIN" "$WITH_PHP" >> /opt/vibestack/logs/api-actions.log 2>&1
            validate_module_result "core_php.sh"
        fi

        # 3. Database Setup (conditional)
        if [[ "$WITH_DB" -eq 1 ]]; then
            source /opt/vibestack/modules/core_db.sh "$DOMAIN" >> /opt/vibestack/logs/api-actions.log 2>&1
            validate_module_result "core_db.sh"
        fi

        # 4. App Layer: WordPress (conditional)
        if [[ "$APP_TYPE" == "wordpress" || "$APP_TYPE" == "wp" ]]; then
            source /opt/vibestack/modules/app_wp.sh "$DOMAIN" "$WP_PLUGINS" "$WP_THEMES" >> /opt/vibestack/logs/api-actions.log 2>&1
            validate_module_result "app_wp.sh"
        fi

        cf_respond "true" "$MODULE_RESULT" "[]" "[\"Site $DOMAIN provisioned successfully.\"]"
        ;;

    "remove_site")
        [[ -z "$DOMAIN" ]] && fatal_error 1001 "Missing required parameter: --domain"

        source /opt/vibestack/modules/site_remove.sh "$DOMAIN" >> /opt/vibestack/logs/api-actions.log 2>&1

        cf_respond "true" "{\"domain\":\"$DOMAIN\",\"status\":\"removed\"}" "[]" "[\"Site $DOMAIN removed successfully.\"]"
        ;;

    *)
        fatal_error 1002 "Invalid or missing --action. Valid actions: create_site, remove_site"
        ;;
esac