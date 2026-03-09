#!/bin/bash
# /opt/vibestack/vibestack-api.sh
# JSON-Strict API Router for the BigScoots Portal

# --- 0. MANDATORY INCLUDES ---
[ -f /bigscoots/includes/common.sh ] && source /bigscoots/includes/common.sh

# --- 1. STATE & VARIABLES ---
REQUIRE_NGINX_RELOAD=0
RELOAD_PHP_VERSIONS="" # Space-separated list, e.g., "81 84"

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
            # Slack Alert: Parent Message
            THREAD_TS=$(send_slack_initial "🚨 *Nginx Config Error* on \`$(hostname)\` during API action: \`$ACTION\` for \`$DOMAIN\`" "alerts")
            
            # Slack Alert: Threaded Details
            send_slack_thread "$THREAD_TS" "\`\`\`$NGINX_TEST\`\`\`" "alerts"
            
            # Override success to false and return API error
            success="false"
            errors='[{"code":500,"message":"Nginx configuration test failed. Alert sent to Slack with details."}]'
            result="null"
        else
            systemctl reload nginx >/dev/null 2>&1
        fi
    fi

    # Process PHP-FPM pool reloads safely
    if [[ "$success" == "true" && -n "$RELOAD_PHP_VERSIONS" ]]; then
        UNIQUE_PHP_VERSIONS=$(echo "$RELOAD_PHP_VERSIONS" | tr ' ' '\n' | sort -u | tr '\n' ' ')
        
        for ver in $UNIQUE_PHP_VERSIONS; do
            if [[ -n "$ver" ]]; then
                # Remi repository absolute path for FPM binary testing
                FPM_BIN="/opt/remi/php${ver}/root/usr/sbin/php-fpm"
                
                if [ -x "$FPM_BIN" ]; then
                    FPM_TEST=$($FPM_BIN -t 2>&1)
                    if [ $? -ne 0 ]; then
                        # Slack Alert: Parent Message
                        THREAD_TS=$(send_slack_initial "🚨 *PHP-FPM $ver Config Error* on \`$(hostname)\` during API action: \`$ACTION\` for \`$DOMAIN\`" "alerts")
                        
                        # Slack Alert: Threaded Details
                        send_slack_thread "$THREAD_TS" "\`\`\`$FPM_TEST\`\`\`" "alerts"
                        
                        success="false"
                        errors="[{\"code\":500,\"message\":\"PHP-FPM $ver configuration test failed. Alert sent to Slack.\"}]"
                        result="null"
                        break # Stop trying to reload other PHP versions if one fails
                    else
                        systemctl reload "php${ver}-php-fpm" >/dev/null 2>&1
                    fi
                fi
            fi
        done
    fi

    # Output strict Cloudflare format to stdout
    printf '{"success":%s,"errors":%s,"messages":%s,"result":%s}\n' \
        "$success" "$errors" "$messages" "$result"

    if [ "$success" == "false" ]; then exit 1; else exit 0; fi
}

# Helper for fatal errors
fatal_error() {
    local code=$1
    local msg=$2
    cf_respond "false" "null" "[{\"code\":$code,\"message\":\"$msg\"}]" "[]"
}

# --- 3. DYNAMIC ARGUMENT PARSER ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --action=*) ACTION="${1#*=}" ;;
        --domain=*) DOMAIN="${1#*=}" ;;
        --app-type=*) APP_TYPE="${1#*=}" ;;
        --with-php=*) WITH_PHP="${1#*=}" ;;
        --with-db) WITH_DB=1 ;;
        --wp-plugins=*) WP_PLUGINS="${1#*=}" ;;
        --wp-themes=*) WP_THEMES="${1#*=}" ;;
        *) fatal_error 1000 "Unknown parameter: $1" ;;
    esac
    shift
done

# --- 4. DEPENDENCY INFERENCE ---
# If WordPress is requested, automatically require PHP and DB if not specified
if [[ "$APP_TYPE" == "wordpress" || "$APP_TYPE" == "wp" ]]; then
    WITH_PHP=${WITH_PHP:-"8.4"} # Default to 8.4 for WP if not specified
    WITH_DB=1
fi

# --- 5. ROUTER LOGIC ---
case "$ACTION" in
    "create_site")
        [[ -z "$DOMAIN" ]] && fatal_error 1001 "Missing required parameter: --domain"

        # Initialize an empty JSON object to collect data from modules
        MODULE_RESULT="{}"

        # 1. Base Nginx/Linux User Setup (Always runs)
        source /opt/vibestack/modules/core_nginx.sh "$DOMAIN" >> /opt/vibestack/logs/api-actions.log 2>&1

        # 2. PHP Pool Setup (Conditional)
        if [[ -n "$WITH_PHP" ]]; then
            source /opt/vibestack/modules/core_php.sh "$DOMAIN" "$WITH_PHP" >> /opt/vibestack/logs/api-actions.log 2>&1
        fi

        # 3. Database Setup (Conditional)
        if [[ "$WITH_DB" -eq 1 ]]; then
            source /opt/vibestack/modules/core_db.sh "$DOMAIN" >> /opt/vibestack/logs/api-actions.log 2>&1
        fi

        # 4. App Layer: WordPress (Conditional)
        if [[ "$APP_TYPE" == "wordpress" || "$APP_TYPE" == "wp" ]]; then
            source /opt/vibestack/modules/app_wp.sh "$DOMAIN" "$WP_PLUGINS" "$WP_THEMES" >> /opt/vibestack/logs/api-actions.log 2>&1
        fi

        # Success! Return the collected data to the portal
        cf_respond "true" "$MODULE_RESULT" "[]" "[\"Site $DOMAIN provisioned successfully.\"]"
        ;;

    "remove_site")
        [[ -z "$DOMAIN" ]] && fatal_error 1001 "Missing required parameter: --domain"
        source /opt/vibestack/modules/site_remove.sh "$DOMAIN" >> /opt/vibestack/logs/api-actions.log 2>&1
        cf_respond "true" "{\"domain\":\"$DOMAIN\",\"status\":\"removed\"}" "[]" "[\"Site removed.\"]"
        ;;

    *)
        fatal_error 1002 "Invalid or missing --action"
        ;;
esac