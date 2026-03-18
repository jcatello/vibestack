#!/bin/bash
# /opt/vibestack/vibestack-api.sh
# JSON-Strict API Router for the BigScoots WPO Portal
# All responses follow Cloudflare JSON format:
# {"success":bool,"errors":[],"messages":[],"result":{}}

# --- 0. MANDATORY INCLUDES ---
source /opt/vibestack/includes/common.sh

# --- 1. STATE & VARIABLES ---
REQUIRE_NGINX_RELOAD=0
RELOAD_PHP_VERSIONS=""

# Core params
ACTION=""
UID_PARAM=""
DOMAIN=""

# Site creation params
APP_TYPE="custom"
WITH_PHP=""
WITH_DB=0
WITH_REDIS=0
PLAN="starter"
PM_MAX_CHILDREN=""
PM_MAX_REQUESTS=""

# WordPress params
WP_TITLE=""
WP_ADMIN_USER=""
WP_ADMIN_PASS=""
WP_ADMIN_EMAIL=""
WP_LOCALE=""
WP_PLUGINS=""
WP_THEMES=""

# ZFS params
SNAPSHOT_LABEL=""
CLONE_TARGET=""

# --- 2. CLOUDFLARE-STYLE JSON RESPONDER & RELOAD HANDLER ---
cf_respond() {
    local success=$1
    local result=${2:-"null"}
    local errors=${3:-"[]"}
    local messages=${4:-"[]"}

    # Process Nginx reload safely
    if [[ "$REQUIRE_NGINX_RELOAD" -eq 1 ]]; then
        NGINX_TEST=$(nginx -t 2>&1)
        if [ $? -ne 0 ]; then
            THREAD_TS=$(send_slack_initial \
                "🚨 *Nginx Config Error* on \`$(hostname)\` (${CONTAINER_NAME}) during action: \`$ACTION\` for \`$DOMAIN\`" \
                "alerts")
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
                    THREAD_TS=$(send_slack_initial \
                        "🚨 *PHP-FPM ${ver} Config Error* on \`$(hostname)\` (${CONTAINER_NAME}) during action: \`$ACTION\` for \`$DOMAIN\`" \
                        "alerts")
                    send_slack_thread "$THREAD_TS" "\`\`\`$FPM_TEST\`\`\`" "alerts"
                    success="false"
                    errors="[{\"code\":500,\"message\":\"PHP-FPM ${ver} config test failed. Alert sent to Slack.\"}]"
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
        --action=*)          ACTION="${1#*=}" ;;
        --uid=*)             UID_PARAM="${1#*=}" ;;
        --domain=*)          DOMAIN="${1#*=}" ;;
        --app-type=*)        APP_TYPE="${1#*=}" ;;
        --with-php=*)        WITH_PHP="${1#*=}" ;;
        --with-db)           WITH_DB=1 ;;
        --with-redis)        WITH_REDIS=1 ;;
        --plan=*)            PLAN="${1#*=}" ;;
        --pm-max-children=*) PM_MAX_CHILDREN="${1#*=}" ;;
        --pm-max-requests=*) PM_MAX_REQUESTS="${1#*=}" ;;
        --wp-title=*)        WP_TITLE="${1#*=}" ;;
        --wp-admin-user=*)   WP_ADMIN_USER="${1#*=}" ;;
        --wp-admin-pass=*)   WP_ADMIN_PASS="${1#*=}" ;;
        --wp-admin-email=*)  WP_ADMIN_EMAIL="${1#*=}" ;;
        --wp-locale=*)       WP_LOCALE="${1#*=}" ;;
        --wp-plugins=*)      WP_PLUGINS="${1#*=}" ;;
        --wp-themes=*)       WP_THEMES="${1#*=}" ;;
        --snapshot-label=*)  SNAPSHOT_LABEL="${1#*=}" ;;
        --clone-target=*)    CLONE_TARGET="${1#*=}" ;;
        *) fatal_error 1000 "Unknown parameter: $1" ;;
    esac
    shift
done

# --- 4. GLOBAL UID VERIFICATION ---
# Every action must pass --uid matching this container's CONTAINER_NAME.
# Mismatch triggers a Slack alert and hard fail.
verify_uid "$UID_PARAM"

# --- 5. DEPENDENCY INFERENCE ---
if [[ "$APP_TYPE" == "wordpress" || "$APP_TYPE" == "wp" ]]; then
    WITH_PHP=${WITH_PHP:-"8.4"}
    WITH_DB=1
    WITH_REDIS=1
    [[ -z "$WP_TITLE" ]]       && fatal_error 1010 "Missing required parameter: --wp-title"
    [[ -z "$WP_ADMIN_USER" ]]  && fatal_error 1011 "Missing required parameter: --wp-admin-user"
    [[ -z "$WP_ADMIN_PASS" ]]  && fatal_error 1012 "Missing required parameter: --wp-admin-pass"
    [[ -z "$WP_ADMIN_EMAIL" ]] && fatal_error 1013 "Missing required parameter: --wp-admin-email"
fi

# --- 6. HELPER: Validate MODULE_RESULT is valid JSON after each module ---
validate_module_result() {
    local module=$1
    if ! echo "$MODULE_RESULT" | jq empty >/dev/null 2>&1; then
        THREAD_TS=$(send_slack_initial \
            "🚨 *MODULE_RESULT corruption* after \`$module\` on \`$(hostname)\` (${CONTAINER_NAME}) for \`$DOMAIN\`" \
            "alerts")
        send_slack_thread "$THREAD_TS" \
            "MODULE_RESULT was not valid JSON after sourcing ${module}. Action: ${ACTION}" \
            "alerts"
        cf_respond "false" "null" \
            "[{\"code\":500,\"message\":\"Internal state corruption after ${module}. Alert sent to Slack.\"}]" \
            "[]"
    fi
}

# --- 7. ROUTER ---
case "$ACTION" in

    # =========================================================================
    "create_site")
        [[ -z "$DOMAIN" ]] && fatal_error 1001 "Missing required parameter: --domain"

        MODULE_RESULT="{}"

        # 1. Base Nginx / Linux user setup (always runs)
        source /opt/vibestack/modules/core_nginx.sh "$DOMAIN" \
            >> /opt/vibestack/logs/api-actions.log 2>&1
        validate_module_result "core_nginx.sh"

        # 2. PHP-FPM pool (conditional)
        if [[ -n "$WITH_PHP" ]]; then
            source /opt/vibestack/modules/core_php.sh \
                "$DOMAIN" "$WITH_PHP" "$PLAN" "$PM_MAX_CHILDREN" "$PM_MAX_REQUESTS" \
                >> /opt/vibestack/logs/api-actions.log 2>&1
            validate_module_result "core_php.sh"
        fi

        # 3. Database (conditional)
        if [[ "$WITH_DB" -eq 1 ]]; then
            source /opt/vibestack/modules/core_db.sh "$DOMAIN" \
                >> /opt/vibestack/logs/api-actions.log 2>&1
            validate_module_result "core_db.sh"
        fi

        # 4. Redis (conditional)
        if [[ "$WITH_REDIS" -eq 1 ]]; then
            source /opt/vibestack/modules/core_redis.sh "$DOMAIN" \
                >> /opt/vibestack/logs/api-actions.log 2>&1
            validate_module_result "core_redis.sh"
        fi

        # 5. WordPress (conditional)
        if [[ "$APP_TYPE" == "wordpress" || "$APP_TYPE" == "wp" ]]; then
            source /opt/vibestack/modules/app_wp.sh \
                "$DOMAIN" "$WP_TITLE" "$WP_ADMIN_USER" "$WP_ADMIN_PASS" \
                "$WP_ADMIN_EMAIL" "$WP_LOCALE" "$WP_PLUGINS" "$WP_THEMES" \
                >> /opt/vibestack/logs/api-actions.log 2>&1
            validate_module_result "app_wp.sh"
        fi

        # Stamp the container UID and plan into the final response
        MODULE_RESULT=$(echo "$MODULE_RESULT" | jq \
            --arg uid "$CONTAINER_NAME" \
            --arg plan "$PLAN" \
            '. + {container_uid: $uid, plan: $plan}')

        cf_respond "true" "$MODULE_RESULT" "[]" \
            "[\"Site ${DOMAIN} provisioned successfully on ${CONTAINER_NAME}.\"]"
        ;;

    # =========================================================================
    "remove_site")
        [[ -z "$DOMAIN" ]] && fatal_error 1001 "Missing required parameter: --domain"

        source /opt/vibestack/modules/site_remove.sh "$DOMAIN" \
            >> /opt/vibestack/logs/api-actions.log 2>&1

        cf_respond "true" \
            "{\"domain\":\"$DOMAIN\",\"container\":\"$CONTAINER_NAME\",\"status\":\"removed\"}" \
            "[]" \
            "[\"Site ${DOMAIN} removed successfully.\"]"
        ;;

    # =========================================================================
    "snapshot_site")
        [[ -z "$SNAPSHOT_LABEL" ]] && fatal_error 3002 "Missing required parameter: --snapshot-label"

        source /opt/vibestack/modules/zfs.sh "snapshot" "$SNAPSHOT_LABEL" \
            >> /opt/vibestack/logs/api-actions.log 2>&1

        cf_respond "true" "$MODULE_RESULT" "[]" \
            "[\"Snapshot created for ${CONTAINER_NAME}.\"]"
        ;;

    # =========================================================================
    "restore_site")
        [[ -z "$SNAPSHOT_LABEL" ]] && fatal_error 3002 "Missing required parameter: --snapshot-label"

        source /opt/vibestack/modules/zfs.sh "restore" "$SNAPSHOT_LABEL" \
            >> /opt/vibestack/logs/api-actions.log 2>&1

        cf_respond "true" "$MODULE_RESULT" "[]" \
            "[\"Container ${CONTAINER_NAME} restored to snapshot: ${SNAPSHOT_LABEL}.\"]"
        ;;

    # =========================================================================
    "clone_site")
        [[ -z "$SNAPSHOT_LABEL" ]] && fatal_error 3002 "Missing required parameter: --snapshot-label"
        [[ -z "$CLONE_TARGET" ]]   && fatal_error 3006 "Missing required parameter: --clone-target"

        source /opt/vibestack/modules/zfs.sh "clone" "$SNAPSHOT_LABEL" "$CLONE_TARGET" \
            >> /opt/vibestack/logs/api-actions.log 2>&1

        cf_respond "true" "$MODULE_RESULT" "[]" \
            "[\"Container ${CONTAINER_NAME} cloned to ${CLONE_TARGET}.\"]"
        ;;

    # =========================================================================
    "destroy_snapshot")
        [[ -z "$SNAPSHOT_LABEL" ]] && fatal_error 3002 "Missing required parameter: --snapshot-label"

        source /opt/vibestack/modules/zfs.sh "destroy" "$SNAPSHOT_LABEL" \
            >> /opt/vibestack/logs/api-actions.log 2>&1

        cf_respond "true" "$MODULE_RESULT" "[]" \
            "[\"Snapshot ${SNAPSHOT_LABEL} destroyed on ${CONTAINER_NAME}.\"]"
        ;;

    # =========================================================================
    "list_snapshots")
        source /opt/vibestack/modules/zfs.sh "list" \
            >> /opt/vibestack/logs/api-actions.log 2>&1

        cf_respond "true" "$MODULE_RESULT" "[]" \
            "[\"Snapshots listed for ${CONTAINER_NAME}.\"]"
        ;;

    # =========================================================================
    *)
        fatal_error 1002 "Invalid or missing --action. Valid actions: create_site, remove_site, snapshot_site, restore_site, clone_site, destroy_snapshot, list_snapshots"
        ;;
esac