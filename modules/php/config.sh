#!/bin/bash
# /opt/vibestack/modules/php/config.sh
# Module: PHP Configuration Management
# Actions: get_config, update_config, get_info, change_version, restart_fpm, get_sandbox_status

source /opt/vibestack/includes/common.sh

PHP_ACTION=$1
DOMAIN=$2
PAYLOAD=$3

[[ -z "$PHP_ACTION" ]] && fatal_error 5000 "PHP action missing"
[[ -z "$DOMAIN" ]]     && fatal_error 5001 "Domain missing in php/config.sh"

USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"

# Per-domain systemd service name
SYSTEMD_SERVICE="vs-php-${USER_NAME}.service"

# Detect which PHP version this domain is using via pool file
detect_php_version() {
    local pool_file
    pool_file=$(find /etc/opt/remi/php*/php-fpm.d/ -name "${DOMAIN}.conf" 2>/dev/null | head -1)
    if [[ -n "$pool_file" ]]; then
        echo "$pool_file" | grep -oP 'php\K\d+'
    else
        echo ""
    fi
}

PHP_PKG_VER=$(detect_php_version)
[[ -z "$PHP_PKG_VER" ]] && fatal_error 5002 "No PHP-FPM pool found for domain $DOMAIN"

PHP_PKG="php${PHP_PKG_VER}"
PHP_FPM_POOL="/etc/opt/remi/${PHP_PKG}/php-fpm.d/${DOMAIN}.conf"
PHP_FPM_CONF="/etc/opt/remi/${PHP_PKG}/php-fpm.conf"
PHP_FPM_BIN="/opt/remi/${PHP_PKG}/root/usr/sbin/php-fpm"
PHP_BIN="/opt/remi/${PHP_PKG}/root/usr/bin/php"
SYSTEMD_UNIT="/etc/systemd/system/${SYSTEMD_SERVICE}"

# Helper: validate FPM config and reload per-domain service
reload_fpm() {
    FPM_TEST=$($PHP_FPM_BIN -t 2>&1)
    if [ $? -ne 0 ]; then
        THREAD_TS=$(send_slack_initial \
            "🚨 *PHP-FPM Config Error* after update on \`$(hostname)\` for \`$DOMAIN\`" "alerts")
        send_slack_thread "$THREAD_TS" "\`\`\`$FPM_TEST\`\`\`" "alerts"
        fatal_error 5013 "PHP-FPM config test failed after update. Alert sent to Slack."
    fi
    systemctl reload "$SYSTEMD_SERVICE" >/dev/null 2>&1
}

case "$PHP_ACTION" in

    # -------------------------------------------------------------------------
    "get_config")
        [[ ! -f "$PHP_FPM_POOL" ]] && fatal_error 5010 "PHP-FPM pool config not found: $PHP_FPM_POOL"

        get_pool_val() { grep "^$1" "$PHP_FPM_POOL" | awk -F'=' '{print $2}' | xargs; }
        get_php_val()  { grep "php_admin_value\[$1\]" "$PHP_FPM_POOL" | awk -F'=' '{print $2}' | xargs; }
        get_php_flag() { grep "php_admin_flag\[$1\]" "$PHP_FPM_POOL" | awk -F'=' '{print $2}' | xargs; }

        # Check sandbox status from systemd unit
        SANDBOX_ACTIVE=false
        [[ -f "$SYSTEMD_UNIT" ]] && grep -q "ProtectSystem=strict" "$SYSTEMD_UNIT" && SANDBOX_ACTIVE=true

        SERVICE_STATUS=$(systemctl is-active "$SYSTEMD_SERVICE" 2>/dev/null || echo "inactive")

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg php_version "${PHP_PKG_VER:0:1}.${PHP_PKG_VER:1}" \
            --arg php_pkg "$PHP_PKG" \
            --arg pool_file "$PHP_FPM_POOL" \
            --arg systemd_service "$SYSTEMD_SERVICE" \
            --arg service_status "$SERVICE_STATUS" \
            --argjson sandbox_active "$SANDBOX_ACTIVE" \
            --arg pm_mode "$(get_pool_val 'pm ')" \
            --arg pm_max_children "$(get_pool_val 'pm.max_children')" \
            --arg pm_process_idle_timeout "$(get_pool_val 'pm.process_idle_timeout')" \
            --arg pm_max_requests "$(get_pool_val 'pm.max_requests')" \
            --arg slowlog "$(get_pool_val 'slowlog')" \
            --arg request_slowlog_timeout "$(get_pool_val 'request_slowlog_timeout')" \
            --arg memory_limit "$(get_php_val 'memory_limit')" \
            --arg upload_max_filesize "$(get_php_val 'upload_max_filesize')" \
            --arg post_max_size "$(get_php_val 'post_max_size')" \
            --arg max_execution_time "$(get_php_val 'max_execution_time')" \
            --arg max_input_time "$(get_php_val 'max_input_time')" \
            --arg max_input_vars "$(get_php_val 'max_input_vars')" \
            --arg opcache_enable "$(get_php_val 'opcache.enable')" \
            --arg opcache_memory "$(get_php_val 'opcache.memory_consumption')" \
            --arg opcache_max_files "$(get_php_val 'opcache.max_accelerated_files')" \
            --arg opcache_revalidate_freq "$(get_php_val 'opcache.revalidate_freq')" \
            --arg allow_url_fopen "$(get_php_flag 'allow_url_fopen')" \
            '{
                domain: $domain,
                php_version: $php_version,
                php_package: $php_pkg,
                pool_file: $pool_file,
                systemd_service: $systemd_service,
                service_status: $service_status,
                sandbox_active: $sandbox_active,
                fpm: {
                    pm_mode: $pm_mode,
                    pm_max_children: $pm_max_children,
                    pm_process_idle_timeout: $pm_process_idle_timeout,
                    pm_max_requests: $pm_max_requests,
                    slowlog: $slowlog,
                    request_slowlog_timeout: $request_slowlog_timeout
                },
                php: {
                    memory_limit: $memory_limit,
                    upload_max_filesize: $upload_max_filesize,
                    post_max_size: $post_max_size,
                    max_execution_time: $max_execution_time,
                    max_input_time: $max_input_time,
                    max_input_vars: $max_input_vars,
                    allow_url_fopen: $allow_url_fopen
                },
                opcache: {
                    enabled: $opcache_enable,
                    memory_consumption: $opcache_memory,
                    max_accelerated_files: $opcache_max_files,
                    revalidate_freq: $opcache_revalidate_freq
                }
            }')
        ;;

    # -------------------------------------------------------------------------
    "update_config")
        [[ -z "$PAYLOAD" ]]    && fatal_error 5011 "JSON payload required for update_config"
        [[ ! -f "$PHP_FPM_POOL" ]] && fatal_error 5012 "PHP-FPM pool config not found"

        set_pool_val() {
            local key=$1 val=$2
            if grep -q "^${key}" "$PHP_FPM_POOL"; then
                sed -i "s|^${key}.*|${key} = ${val}|" "$PHP_FPM_POOL"
            else
                echo "${key} = ${val}" >> "$PHP_FPM_POOL"
            fi
        }
        set_php_val() {
            local key=$1 val=$2
            if grep -q "php_admin_value\[${key}\]" "$PHP_FPM_POOL"; then
                sed -i "s|php_admin_value\[${key}\].*|php_admin_value[${key}] = ${val}|" "$PHP_FPM_POOL"
            else
                echo "php_admin_value[${key}] = ${val}" >> "$PHP_FPM_POOL"
            fi
        }
        set_php_flag() {
            local key=$1 val=$2
            if grep -q "php_admin_flag\[${key}\]" "$PHP_FPM_POOL"; then
                sed -i "s|php_admin_flag\[${key}\].*|php_admin_flag[${key}] = ${val}|" "$PHP_FPM_POOL"
            else
                echo "php_admin_flag[${key}] = ${val}" >> "$PHP_FPM_POOL"
            fi
        }

        CHANGES=()

        VAL=$(echo "$PAYLOAD" | jq -r '.pm_max_children // empty')
        [[ -n "$VAL" ]] && set_pool_val "pm.max_children" "$VAL" && CHANGES+=("pm.max_children=$VAL")

        VAL=$(echo "$PAYLOAD" | jq -r '.pm_max_requests // empty')
        [[ -n "$VAL" ]] && set_pool_val "pm.max_requests" "$VAL" && CHANGES+=("pm.max_requests=$VAL")

        VAL=$(echo "$PAYLOAD" | jq -r '.pm_process_idle_timeout // empty')
        [[ -n "$VAL" ]] && set_pool_val "pm.process_idle_timeout" "$VAL" && CHANGES+=("pm.process_idle_timeout=$VAL")

        VAL=$(echo "$PAYLOAD" | jq -r '.request_slowlog_timeout // empty')
        if [[ -n "$VAL" ]]; then
            SLOWLOG_PATH="$WEB_ROOT/logs/slow.log"
            set_pool_val "request_slowlog_timeout" "$VAL"
            set_pool_val "slowlog" "$SLOWLOG_PATH"
            CHANGES+=("request_slowlog_timeout=$VAL")
        fi

        VAL=$(echo "$PAYLOAD" | jq -r '.pm_status_path // empty')
        [[ -n "$VAL" ]] && set_pool_val "pm.status_path" "$VAL" && CHANGES+=("pm.status_path=$VAL")

        VAL=$(echo "$PAYLOAD" | jq -r '.memory_limit // empty')
        [[ -n "$VAL" ]] && set_php_val "memory_limit" "$VAL" && CHANGES+=("memory_limit=$VAL")

        VAL=$(echo "$PAYLOAD" | jq -r '.max_execution_time // empty')
        [[ -n "$VAL" ]] && set_php_val "max_execution_time" "$VAL" && CHANGES+=("max_execution_time=$VAL")

        VAL=$(echo "$PAYLOAD" | jq -r '.max_input_time // empty')
        [[ -n "$VAL" ]] && set_php_val "max_input_time" "$VAL" && CHANGES+=("max_input_time=$VAL")

        VAL=$(echo "$PAYLOAD" | jq -r '.max_input_vars // empty')
        [[ -n "$VAL" ]] && set_php_val "max_input_vars" "$VAL" && CHANGES+=("max_input_vars=$VAL")

        VAL=$(echo "$PAYLOAD" | jq -r '.upload_max_filesize // empty')
        [[ -n "$VAL" ]] && set_php_val "upload_max_filesize" "$VAL" && CHANGES+=("upload_max_filesize=$VAL")

        VAL=$(echo "$PAYLOAD" | jq -r '.post_max_size // empty')
        [[ -n "$VAL" ]] && set_php_val "post_max_size" "$VAL" && CHANGES+=("post_max_size=$VAL")

        VAL=$(echo "$PAYLOAD" | jq -r '.opcache_enable // empty')
        [[ -n "$VAL" ]] && set_php_val "opcache.enable" "$VAL" && CHANGES+=("opcache.enable=$VAL")

        VAL=$(echo "$PAYLOAD" | jq -r '.opcache_memory // empty')
        [[ -n "$VAL" ]] && set_php_val "opcache.memory_consumption" "$VAL" && CHANGES+=("opcache.memory_consumption=$VAL")

        VAL=$(echo "$PAYLOAD" | jq -r '.opcache_max_files // empty')
        [[ -n "$VAL" ]] && set_php_val "opcache.max_accelerated_files" "$VAL" && CHANGES+=("opcache.max_accelerated_files=$VAL")

        VAL=$(echo "$PAYLOAD" | jq -r '.opcache_revalidate_freq // empty')
        [[ -n "$VAL" ]] && set_php_val "opcache.revalidate_freq" "$VAL" && CHANGES+=("opcache.revalidate_freq=$VAL")

        reload_fpm

        CHANGES_JSON=$(printf '%s\n' "${CHANGES[@]}" | jq -R . | jq -s .)
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg php_version "${PHP_PKG_VER:0:1}.${PHP_PKG_VER:1}" \
            --arg service "$SYSTEMD_SERVICE" \
            --argjson changes "$CHANGES_JSON" \
            '{domain: $domain, php_version: $php_version, systemd_service: $service, success: true, changes_applied: $changes}')
        ;;

    # -------------------------------------------------------------------------
    "get_info")
        PHP_VERSION=$("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null)
        PHP_EXTENSIONS=$("$PHP_BIN" -r 'echo implode(",", get_loaded_extensions());' 2>/dev/null)
        SERVICE_STATUS=$(systemctl is-active "$SYSTEMD_SERVICE" 2>/dev/null || echo "inactive")
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg php_version "$PHP_VERSION" \
            --arg php_binary "$PHP_BIN" \
            --arg extensions "$PHP_EXTENSIONS" \
            --arg service "$SYSTEMD_SERVICE" \
            --arg service_status "$SERVICE_STATUS" \
            '{domain: $domain, php_version: $php_version, php_binary: $php_binary, systemd_service: $service, service_status: $service_status, extensions: $extensions}')
        ;;

    # -------------------------------------------------------------------------
    "change_version")
        [[ -z "$PAYLOAD" ]] && fatal_error 5014 "New PHP version required"
        NEW_VER="${PAYLOAD//./}"
        NEW_PKG="php${NEW_VER}"
        NEW_FPM_BIN="/opt/remi/${NEW_PKG}/root/usr/sbin/php-fpm"
        NEW_FPM_CONF="/etc/opt/remi/${NEW_PKG}/php-fpm.conf"
        NEW_POOL="/etc/opt/remi/${NEW_PKG}/php-fpm.d/${DOMAIN}.conf"
        NEW_SYSTEMD_UNIT="/etc/systemd/system/${SYSTEMD_SERVICE}"

        # Install new PHP version if needed
        if ! rpm -q "${NEW_PKG}-php-fpm" >/dev/null 2>&1; then
            dnf install -y \
                "${NEW_PKG}-php-cli" "${NEW_PKG}-php-fpm" "${NEW_PKG}-php-opcache" \
                "${NEW_PKG}-php-mysqlnd" "${NEW_PKG}-php-mbstring" "${NEW_PKG}-php-xml" \
                "${NEW_PKG}-php-pecl-zip" "${NEW_PKG}-php-gd" "${NEW_PKG}-php-intl" \
                >/dev/null 2>&1
        fi

        # Copy pool config to new PHP version directory
        cp "$PHP_FPM_POOL" "$NEW_POOL"

        # Remove old pool config
        rm -f "$PHP_FPM_POOL"

        # Update the per-domain systemd unit to point to new PHP binary and conf
        sed -i \
            -e "s|ExecStart=.*php-fpm.*|ExecStart=${NEW_FPM_BIN} --nodaemonize --fpm-config ${NEW_FPM_CONF} --fpm-config-allow-unknown-options|" \
            -e "s|ReadOnlyPaths=.*/etc/opt/remi/php.*|ReadOnlyPaths=/etc/opt/remi/${NEW_PKG}|" \
            "$NEW_SYSTEMD_UNIT"

        systemctl daemon-reload
        systemctl restart "$SYSTEMD_SERVICE" >/dev/null 2>&1
        STATUS=$?

        # Update global php symlink
        ln -sf "/opt/remi/${NEW_PKG}/root/usr/bin/php" /usr/bin/php

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg old_version "${PHP_PKG_VER:0:1}.${PHP_PKG_VER:1}" \
            --arg new_version "$PAYLOAD" \
            --arg service "$SYSTEMD_SERVICE" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, old_php_version: $old_version, new_php_version: $new_version, systemd_service: $service}')
        ;;

    # -------------------------------------------------------------------------
    "restart_fpm")
        # Targets the per-domain unit only — no other domain is affected
        systemctl restart "$SYSTEMD_SERVICE" >/dev/null 2>&1
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg service "$SYSTEMD_SERVICE" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, service_restarted: $service}')
        ;;

    # -------------------------------------------------------------------------
    "get_sandbox_status")
        # Returns what sandbox restrictions are active for this domain's PHP process
        [[ ! -f "$SYSTEMD_UNIT" ]] && fatal_error 5015 "Systemd unit not found: $SYSTEMD_UNIT"

        get_unit_val() { grep "^$1=" "$SYSTEMD_UNIT" | cut -d= -f2; }

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg service "$SYSTEMD_SERVICE" \
            --arg protect_system "$(get_unit_val 'ProtectSystem')" \
            --arg protect_home "$(get_unit_val 'ProtectHome')" \
            --arg private_tmp "$(get_unit_val 'PrivateTmp')" \
            --arg private_devices "$(get_unit_val 'PrivateDevices')" \
            --arg no_new_privileges "$(get_unit_val 'NoNewPrivileges')" \
            --arg capability_bounding_set "$(get_unit_val 'CapabilityBoundingSet')" \
            --arg restrict_namespaces "$(get_unit_val 'RestrictNamespaces')" \
            --arg restrict_realtime "$(get_unit_val 'RestrictRealtime')" \
            --arg lock_personality "$(get_unit_val 'LockPersonality')" \
            --arg restrict_suid_sgid "$(get_unit_val 'RestrictSUIDSGID')" \
            --arg syscall_filter "$(get_unit_val 'SystemCallFilter')" \
            '{
                domain: $domain,
                systemd_service: $service,
                sandbox: {
                    ProtectSystem: $protect_system,
                    ProtectHome: $protect_home,
                    PrivateTmp: $private_tmp,
                    PrivateDevices: $private_devices,
                    NoNewPrivileges: $no_new_privileges,
                    CapabilityBoundingSet: $capability_bounding_set,
                    RestrictNamespaces: $restrict_namespaces,
                    RestrictRealtime: $restrict_realtime,
                    LockPersonality: $lock_personality,
                    RestrictSUIDSGID: $restrict_suid_sgid,
                    SystemCallFilter: $syscall_filter
                }
            }')
        ;;

    *)
        fatal_error 5099 "Unknown PHP action: $PHP_ACTION. Valid: get_config, update_config, get_info, change_version, restart_fpm, get_sandbox_status"
        ;;
esac