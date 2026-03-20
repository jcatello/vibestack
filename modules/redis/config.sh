#!/bin/bash
# /opt/vibestack/modules/redis/config.sh
# Module: Redis Configuration & Management
# Actions: get_config, update_config, flush, restart, stats, enable, disable

source /opt/vibestack/includes/common.sh

REDIS_ACTION=$1
DOMAIN=$2
PAYLOAD=$3

[[ -z "$REDIS_ACTION" ]] && fatal_error 5200 "Redis action missing"
[[ -z "$DOMAIN" ]]       && fatal_error 5201 "Domain missing in redis/config.sh"

USER_NAME=${DOMAIN//./_}
REDIS_CONF="/etc/redis/${DOMAIN}.conf"
REDIS_SOCKET="/run/redis/${DOMAIN}.sock"
REDIS_SERVICE="redis-${USER_NAME}"

redis_cmd() {
    if [[ -f "$REDIS_CONF" ]]; then
        REDIS_PASS=$(grep "requirepass" "$REDIS_CONF" | awk '{print $2}')
        redis-cli -s "$REDIS_SOCKET" -a "$REDIS_PASS" --no-auth-warning "$@" 2>/dev/null
    else
        fatal_error 5202 "Redis not configured for domain $DOMAIN"
    fi
}

case "$REDIS_ACTION" in

    # -------------------------------------------------------------------------
    "get_config")
        [[ ! -f "$REDIS_CONF" ]] && fatal_error 5210 "Redis config not found for $DOMAIN"

        get_conf_val() { grep "^$1 " "$REDIS_CONF" | awk '{print $2}'; }

        MAXMEM=$(get_conf_val "maxmemory")
        MAXMEM_POLICY=$(get_conf_val "maxmemory-policy")
        LOGLEVEL=$(get_conf_val "loglevel")
        SAVE=$(get_conf_val "save")
        APPENDONLY=$(get_conf_val "appendonly")
        SERVICE_STATUS=$(systemctl is-active "$REDIS_SERVICE" 2>/dev/null || echo "unknown")

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg socket "$REDIS_SOCKET" \
            --arg service "$REDIS_SERVICE" \
            --arg status "$SERVICE_STATUS" \
            --arg maxmemory "${MAXMEM:-64mb}" \
            --arg maxmemory_policy "${MAXMEM_POLICY:-allkeys-lru}" \
            --arg loglevel "${LOGLEVEL:-notice}" \
            --arg persistence_save "${SAVE:-disabled}" \
            --arg appendonly "${APPENDONLY:-no}" \
            '{
                domain: $domain,
                socket: $socket,
                service: $service,
                status: $status,
                maxmemory: $maxmemory,
                maxmemory_policy: $maxmemory_policy,
                loglevel: $loglevel,
                persistence_save: $persistence_save,
                appendonly: $appendonly
            }')
        ;;

    # -------------------------------------------------------------------------
    "update_config")
        [[ -z "$PAYLOAD" ]]    && fatal_error 5211 "JSON payload required"
        [[ ! -f "$REDIS_CONF" ]] && fatal_error 5212 "Redis config not found for $DOMAIN"

        set_conf_val() {
            local key=$1 val=$2
            if grep -q "^${key} " "$REDIS_CONF"; then
                sed -i "s|^${key} .*|${key} ${val}|" "$REDIS_CONF"
            else
                echo "${key} ${val}" >> "$REDIS_CONF"
            fi
        }

        CHANGES=()

        VAL=$(echo "$PAYLOAD" | jq -r '.maxmemory // empty')
        [[ -n "$VAL" ]] && set_conf_val "maxmemory" "$VAL" && CHANGES+=("maxmemory=$VAL")

        VAL=$(echo "$PAYLOAD" | jq -r '.maxmemory_policy // empty')
        [[ -n "$VAL" ]] && set_conf_val "maxmemory-policy" "$VAL" && CHANGES+=("maxmemory-policy=$VAL")

        VAL=$(echo "$PAYLOAD" | jq -r '.loglevel // empty')
        [[ -n "$VAL" ]] && set_conf_val "loglevel" "$VAL" && CHANGES+=("loglevel=$VAL")

        # Restart to apply
        systemctl restart "$REDIS_SERVICE" >/dev/null 2>&1
        sleep 1

        # Fix socket permissions after restart
        chown "${USER_NAME}:nginx" "$REDIS_SOCKET" 2>/dev/null || true
        chmod 660 "$REDIS_SOCKET" 2>/dev/null || true

        CHANGES_JSON=$(printf '%s\n' "${CHANGES[@]}" | jq -R . | jq -s .)
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --argjson changes "$CHANGES_JSON" \
            '{domain: $domain, success: true, changes_applied: $changes}')
        ;;

    # -------------------------------------------------------------------------
    "flush")
        OUT=$(redis_cmd FLUSHALL)
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, cache_flushed: true}')
        ;;

    # -------------------------------------------------------------------------
    "stats")
        [[ ! -f "$REDIS_CONF" ]] && fatal_error 5213 "Redis not configured for $DOMAIN"
        INFO=$(redis_cmd INFO all 2>/dev/null)

        parse_info() { echo "$INFO" | grep "^$1:" | cut -d':' -f2 | tr -d '\r'; }

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg used_memory "$(parse_info used_memory_human)" \
            --arg peak_memory "$(parse_info used_memory_peak_human)" \
            --arg connected_clients "$(parse_info connected_clients)" \
            --arg total_commands "$(parse_info total_commands_processed)" \
            --arg keyspace_hits "$(parse_info keyspace_hits)" \
            --arg keyspace_misses "$(parse_info keyspace_misses)" \
            --arg uptime_seconds "$(parse_info uptime_in_seconds)" \
            --arg total_keys "$(redis_cmd DBSIZE 2>/dev/null | tr -d '\r')" \
            '{
                domain: $domain,
                used_memory: $used_memory,
                peak_memory: $peak_memory,
                connected_clients: $connected_clients,
                total_commands_processed: $total_commands,
                keyspace_hits: $keyspace_hits,
                keyspace_misses: $keyspace_misses,
                uptime_seconds: $uptime_seconds,
                total_keys: $total_keys
            }')
        ;;

    # -------------------------------------------------------------------------
    "restart")
        systemctl restart "$REDIS_SERVICE" >/dev/null 2>&1
        STATUS=$?
        sleep 1
        chown "${USER_NAME}:nginx" "$REDIS_SOCKET" 2>/dev/null || true
        chmod 660 "$REDIS_SOCKET" 2>/dev/null || true
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg service "$REDIS_SERVICE" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, service: $service}')
        ;;

    # -------------------------------------------------------------------------
    "enable")
        systemctl enable --now "$REDIS_SERVICE" >/dev/null 2>&1
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg service "$REDIS_SERVICE" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, redis: "enabled", service: $service}')
        ;;

    # -------------------------------------------------------------------------
    "disable")
        systemctl disable --now "$REDIS_SERVICE" >/dev/null 2>&1
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg service "$REDIS_SERVICE" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, redis: "disabled", service: $service}')
        ;;

    *)
        fatal_error 5299 "Unknown Redis action: $REDIS_ACTION. Valid: get_config, update_config, flush, stats, restart, enable, disable"
        ;;
esac
