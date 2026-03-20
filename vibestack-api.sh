#!/bin/bash
# /opt/vibestack/vibestack-api.sh
# BigScoots WPO — Complete WordPress Management API
# JSON-strict. Every response follows Cloudflare format.
# All actions require --uid matching this container's CONTAINER_NAME.

source /opt/vibestack/includes/common.sh

# =============================================================================
# 1. GLOBAL STATE
# =============================================================================
REQUIRE_NGINX_RELOAD=0
RELOAD_PHP_VERSIONS=""
MODULE_RESULT="{}"

# =============================================================================
# 2. ARGUMENT PARSER
# =============================================================================
ACTION=""
UID_PARAM=""
DOMAIN=""

# Site provisioning
APP_TYPE="custom"
WITH_PHP=""
WITH_DB=0
WITH_REDIS=0
PLAN="starter"
PM_MAX_CHILDREN=""
PM_MAX_REQUESTS=""

# WordPress install
WP_TITLE=""
WP_ADMIN_USER=""
WP_ADMIN_PASS=""
WP_ADMIN_EMAIL=""
WP_LOCALE=""
WP_PLUGINS=""
WP_THEMES=""

# ZFS
SNAPSHOT_LABEL=""
CLONE_TARGET=""

# Sub-action routing (for namespaced actions)
SUB_ACTION=""
PAYLOAD=""
SLUG=""
EXTRA=""

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
        --sub-action=*)      SUB_ACTION="${1#*=}" ;;
        --payload=*)         PAYLOAD="${1#*=}" ;;
        --slug=*)            SLUG="${1#*=}" ;;
        --extra=*)           EXTRA="${1#*=}" ;;
        *) fatal_error 1000 "Unknown parameter: $1" ;;
    esac
    shift
done

# =============================================================================
# 3. GLOBAL UID VERIFICATION — runs before EVERYTHING
# =============================================================================
verify_uid "$UID_PARAM"

# =============================================================================
# 4. DEPENDENCY INFERENCE
# =============================================================================
if [[ "$APP_TYPE" == "wordpress" || "$APP_TYPE" == "wp" ]]; then
    WITH_PHP=${WITH_PHP:-"8.4"}
    WITH_DB=1
    WITH_REDIS=1
    [[ -z "$WP_TITLE" ]]       && fatal_error 1010 "Missing: --wp-title"
    [[ -z "$WP_ADMIN_USER" ]]  && fatal_error 1011 "Missing: --wp-admin-user"
    [[ -z "$WP_ADMIN_PASS" ]]  && fatal_error 1012 "Missing: --wp-admin-pass"
    [[ -z "$WP_ADMIN_EMAIL" ]] && fatal_error 1013 "Missing: --wp-admin-email"
fi

# =============================================================================
# 5. CLOUDFLARE RESPONDER + RELOAD HANDLER
# =============================================================================
cf_respond() {
    local success=$1
    local result=${2:-"null"}
    local errors=${3:-"[]"}
    local messages=${4:-"[]"}

    if [[ "$REQUIRE_NGINX_RELOAD" -eq 1 ]]; then
        NGINX_TEST=$(nginx -t 2>&1)
        if [ $? -ne 0 ]; then
            THREAD_TS=$(send_slack_initial "🚨 *Nginx Config Error* on \`$(hostname)\` (${CONTAINER_NAME}) — action: \`$ACTION\` domain: \`$DOMAIN\`" "alerts")
            send_slack_thread "$THREAD_TS" "\`\`\`$NGINX_TEST\`\`\`" "alerts"
            success="false"
            errors='[{"code":500,"message":"Nginx configuration test failed. Alert sent to Slack."}]'
            result="null"
        else
            systemctl reload nginx >/dev/null 2>&1
        fi
    fi

    if [[ "$success" == "true" && -n "$RELOAD_PHP_VERSIONS" ]]; then
        UNIQUE=$(echo "$RELOAD_PHP_VERSIONS" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')
        for ver in $UNIQUE; do
            FPM_BIN="/opt/remi/php${ver}/root/usr/sbin/php-fpm"
            if [ -x "$FPM_BIN" ]; then
                FPM_TEST=$($FPM_BIN -t 2>&1)
                if [ $? -ne 0 ]; then
                    THREAD_TS=$(send_slack_initial "🚨 *PHP-FPM ${ver} Config Error* on \`$(hostname)\` (${CONTAINER_NAME})" "alerts")
                    send_slack_thread "$THREAD_TS" "\`\`\`$FPM_TEST\`\`\`" "alerts"
                    success="false"
                    errors="[{\"code\":500,\"message\":\"PHP-FPM ${ver} config test failed.\"}]"
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

# Validate MODULE_RESULT is valid JSON after sourcing modules
validate_module_result() {
    local module=$1
    if ! echo "$MODULE_RESULT" | jq empty >/dev/null 2>&1; then
        THREAD_TS=$(send_slack_initial "🚨 *MODULE_RESULT corruption* after \`$module\` on \`$(hostname)\` (${CONTAINER_NAME}) domain: \`$DOMAIN\`" "alerts")
        send_slack_thread "$THREAD_TS" "MODULE_RESULT corrupted after ${module}. Action: ${ACTION}" "alerts"
        cf_respond "false" "null" "[{\"code\":500,\"message\":\"State corruption after ${module}.\"}]" "[]"
        exit 1
    fi
}

# Helper: source a module and capture its MODULE_RESULT
run_module() {
    local module_path=$1
    shift
    source "$module_path" "$@" >> /opt/vibestack/logs/api-actions.log 2>&1
    validate_module_result "$(basename $module_path)"
}

# =============================================================================
# 6. ACTION ROUTER
# =============================================================================
case "$ACTION" in

# =============================================================================
# SITE PROVISIONING
# =============================================================================

    "create_site")
        [[ -z "$DOMAIN" ]] && fatal_error 1001 "Missing: --domain"
        MODULE_RESULT="{}"

        run_module /opt/vibestack/modules/core_nginx.sh "$DOMAIN"

        if [[ -n "$WITH_PHP" ]]; then
            run_module /opt/vibestack/modules/core_php.sh \
                "$DOMAIN" "$WITH_PHP" "$PLAN" "$PM_MAX_CHILDREN" "$PM_MAX_REQUESTS"
        fi

        if [[ "$WITH_DB" -eq 1 ]]; then
            run_module /opt/vibestack/modules/core_db.sh "$DOMAIN"
        fi

        if [[ "$WITH_REDIS" -eq 1 ]]; then
            run_module /opt/vibestack/modules/core_redis.sh "$DOMAIN"
        fi

        if [[ "$APP_TYPE" == "wordpress" || "$APP_TYPE" == "wp" ]]; then
            run_module /opt/vibestack/modules/app_wp.sh \
                "$DOMAIN" "$WP_TITLE" "$WP_ADMIN_USER" "$WP_ADMIN_PASS" \
                "$WP_ADMIN_EMAIL" "$WP_LOCALE" "$WP_PLUGINS" "$WP_THEMES" "$WITH_PHP"
        fi

        MODULE_RESULT=$(echo "$MODULE_RESULT" | jq \
            --arg uid "$CONTAINER_NAME" --arg plan "$PLAN" \
            '. + {container_uid: $uid, plan: $plan}')

        cf_respond "true" "$MODULE_RESULT" "[]" \
            "[\"Site ${DOMAIN} provisioned successfully on ${CONTAINER_NAME}.\"]"
        ;;

    "remove_site")
        [[ -z "$DOMAIN" ]] && fatal_error 1001 "Missing: --domain"
        run_module /opt/vibestack/modules/site_remove.sh "$DOMAIN"
        cf_respond "true" \
            "{\"domain\":\"$DOMAIN\",\"container\":\"$CONTAINER_NAME\",\"status\":\"removed\"}" \
            "[]" "[\"Site ${DOMAIN} removed.\"]"
        ;;

# =============================================================================
# WORDPRESS — PLUGINS
# =============================================================================

    "plugin")
        [[ -z "$DOMAIN" ]]     && fatal_error 1001 "Missing: --domain"
        [[ -z "$SUB_ACTION" ]] && fatal_error 1014 "Missing: --sub-action (list|install|uninstall|activate|deactivate|update|update_all|toggle_autoupdate|check_updates|get_info)"
        run_module /opt/vibestack/modules/wp/plugins.sh "$SUB_ACTION" "$DOMAIN" "$SLUG" "$EXTRA"
        cf_respond "true" "$MODULE_RESULT" "[]" "[\"Plugin action '${SUB_ACTION}' completed for ${DOMAIN}.\"]"
        ;;

# =============================================================================
# WORDPRESS — THEMES
# =============================================================================

    "theme")
        [[ -z "$DOMAIN" ]]     && fatal_error 1001 "Missing: --domain"
        [[ -z "$SUB_ACTION" ]] && fatal_error 1014 "Missing: --sub-action (list|install|uninstall|activate|update|update_all|toggle_autoupdate|check_updates|get_info)"
        run_module /opt/vibestack/modules/wp/themes.sh "$SUB_ACTION" "$DOMAIN" "$SLUG" "$EXTRA"
        cf_respond "true" "$MODULE_RESULT" "[]" "[\"Theme action '${SUB_ACTION}' completed for ${DOMAIN}.\"]"
        ;;

# =============================================================================
# WORDPRESS — USERS
# =============================================================================

    "wp_user")
        [[ -z "$DOMAIN" ]]     && fatal_error 1001 "Missing: --domain"
        [[ -z "$SUB_ACTION" ]] && fatal_error 1014 "Missing: --sub-action (list|get|create|delete|update|set_role|reset_password|list_roles)"
        run_module /opt/vibestack/modules/wp/users.sh "$SUB_ACTION" "$DOMAIN" "$PAYLOAD"
        cf_respond "true" "$MODULE_RESULT" "[]" "[\"User action '${SUB_ACTION}' completed for ${DOMAIN}.\"]"
        ;;

# =============================================================================
# WORDPRESS — SETTINGS & OPERATIONS
# =============================================================================

    "wp_settings")
        [[ -z "$DOMAIN" ]]     && fatal_error 1001 "Missing: --domain"
        [[ -z "$SUB_ACTION" ]] && fatal_error 1014 "Missing: --sub-action"
        run_module /opt/vibestack/modules/wp/settings.sh "$SUB_ACTION" "$DOMAIN" "$PAYLOAD"
        cf_respond "true" "$MODULE_RESULT" "[]" "[\"Settings action '${SUB_ACTION}' completed for ${DOMAIN}.\"]"
        ;;

# =============================================================================
# WORDPRESS — DATABASE
# =============================================================================

    "wp_db")
        [[ -z "$DOMAIN" ]]     && fatal_error 1001 "Missing: --domain"
        [[ -z "$SUB_ACTION" ]] && fatal_error 1014 "Missing: --sub-action (export|import|optimize|repair|info|run_query|list_exports)"
        run_module /opt/vibestack/modules/wp/database.sh "$SUB_ACTION" "$DOMAIN" "$PAYLOAD"
        cf_respond "true" "$MODULE_RESULT" "[]" "[\"DB action '${SUB_ACTION}' completed for ${DOMAIN}.\"]"
        ;;

# =============================================================================
# PHP CONFIGURATION
# =============================================================================

    "php_config")
        [[ -z "$DOMAIN" ]]     && fatal_error 1001 "Missing: --domain"
        [[ -z "$SUB_ACTION" ]] && fatal_error 1014 "Missing: --sub-action (get_config|update_config|get_info|change_version|restart_fpm)"
        run_module /opt/vibestack/modules/php/config.sh "$SUB_ACTION" "$DOMAIN" "$PAYLOAD"
        cf_respond "true" "$MODULE_RESULT" "[]" "[\"PHP action '${SUB_ACTION}' completed for ${DOMAIN}.\"]"
        ;;

# =============================================================================
# REDIS CONFIGURATION
# =============================================================================

    "redis_config")
        [[ -z "$DOMAIN" ]]     && fatal_error 1001 "Missing: --domain"
        [[ -z "$SUB_ACTION" ]] && fatal_error 1014 "Missing: --sub-action (get_config|update_config|flush|stats|restart|enable|disable)"
        run_module /opt/vibestack/modules/redis/config.sh "$SUB_ACTION" "$DOMAIN" "$PAYLOAD"
        cf_respond "true" "$MODULE_RESULT" "[]" "[\"Redis action '${SUB_ACTION}' completed for ${DOMAIN}.\"]"
        ;;

# =============================================================================
# NGINX CONFIGURATION
# =============================================================================

    "nginx_config")
        [[ -z "$DOMAIN" ]]     && fatal_error 1001 "Missing: --domain"
        [[ -z "$SUB_ACTION" ]] && fatal_error 1014 "Missing: --sub-action"
        run_module /opt/vibestack/modules/nginx/config.sh "$SUB_ACTION" "$DOMAIN" "$PAYLOAD"
        REQUIRE_NGINX_RELOAD=0  # nginx module handles its own reload
        cf_respond "true" "$MODULE_RESULT" "[]" "[\"Nginx action '${SUB_ACTION}' completed for ${DOMAIN}.\"]"
        ;;

# =============================================================================
# BASIC AUTH
# =============================================================================

    "basic_auth")
        [[ -z "$DOMAIN" ]]     && fatal_error 1001 "Missing: --domain"
        [[ -z "$SUB_ACTION" ]] && fatal_error 1014 "Missing: --sub-action (enable_site|disable_site|enable_wplogin|disable_wplogin|update_credentials|list)"
        run_module /opt/vibestack/modules/nginx/basic_auth.sh "$SUB_ACTION" "$DOMAIN" "$PAYLOAD"
        cf_respond "true" "$MODULE_RESULT" "[]" "[\"Basic auth action '${SUB_ACTION}' completed for ${DOMAIN}.\"]"
        ;;

# =============================================================================
# PHPMYADMIN
# =============================================================================

    "phpmyadmin")
        [[ -z "$SUB_ACTION" ]] && fatal_error 1014 "Missing: --sub-action (rotate_path|rotate_credentials|get_info)"
        run_module /opt/vibestack/modules/system/phpmyadmin.sh "$SUB_ACTION"
        cf_respond "true" "$MODULE_RESULT" "[]" "[\"phpMyAdmin action '${SUB_ACTION}' completed.\"]"
        ;;

# =============================================================================
# SYSTEM / CONTAINER INFO
# =============================================================================

    "system")
        [[ -z "$SUB_ACTION" ]] && fatal_error 1014 "Missing: --sub-action (get_resources|get_disk|get_services|restart_services|get_container_info)"
        run_module /opt/vibestack/modules/system/info.sh "$SUB_ACTION" "$DOMAIN" "$PAYLOAD"
        cf_respond "true" "$MODULE_RESULT" "[]" "[\"System action '${SUB_ACTION}' completed.\"]"
        ;;

# =============================================================================
# ZFS SNAPSHOTS
# =============================================================================

    "snapshot_site")
        [[ -z "$SNAPSHOT_LABEL" ]] && fatal_error 3002 "Missing: --snapshot-label"
        run_module /opt/vibestack/modules/zfs.sh "snapshot" "$SNAPSHOT_LABEL"
        cf_respond "true" "$MODULE_RESULT" "[]" "[\"Snapshot created for ${CONTAINER_NAME}.\"]"
        ;;

    "restore_site")
        [[ -z "$SNAPSHOT_LABEL" ]] && fatal_error 3002 "Missing: --snapshot-label"
        run_module /opt/vibestack/modules/zfs.sh "restore" "$SNAPSHOT_LABEL"
        cf_respond "true" "$MODULE_RESULT" "[]" "[\"Restored ${CONTAINER_NAME} to snapshot: ${SNAPSHOT_LABEL}.\"]"
        ;;

    "clone_site")
        [[ -z "$SNAPSHOT_LABEL" ]] && fatal_error 3002 "Missing: --snapshot-label"
        [[ -z "$CLONE_TARGET" ]]   && fatal_error 3006 "Missing: --clone-target"
        run_module /opt/vibestack/modules/zfs.sh "clone" "$SNAPSHOT_LABEL" "$CLONE_TARGET"
        cf_respond "true" "$MODULE_RESULT" "[]" "[\"Cloned ${CONTAINER_NAME} to ${CLONE_TARGET}.\"]"
        ;;

    "destroy_snapshot")
        [[ -z "$SNAPSHOT_LABEL" ]] && fatal_error 3002 "Missing: --snapshot-label"
        run_module /opt/vibestack/modules/zfs.sh "destroy" "$SNAPSHOT_LABEL"
        cf_respond "true" "$MODULE_RESULT" "[]" "[\"Snapshot ${SNAPSHOT_LABEL} destroyed.\"]"
        ;;

    "list_snapshots")
        run_module /opt/vibestack/modules/zfs.sh "list"
        cf_respond "true" "$MODULE_RESULT" "[]" "[\"Snapshots listed for ${CONTAINER_NAME}.\"]"
        ;;

# =============================================================================
# UNKNOWN
# =============================================================================

    *)
        fatal_error 1002 "Invalid or missing --action. Valid actions: create_site, remove_site, plugin, theme, wp_user, wp_settings, wp_db, php_config, redis_config, nginx_config, basic_auth, phpmyadmin, system, snapshot_site, restore_site, clone_site, destroy_snapshot, list_snapshots"
        ;;
esac