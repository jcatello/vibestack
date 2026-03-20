#!/bin/bash
# /opt/vibestack/modules/nginx/config.sh
# Module: Nginx Configuration & Domain Management
# Actions: get_config, add_domain, remove_domain, list_domains,
#          reload, get_ssl_status, force_ssl, toggle_http2,
#          set_client_max_body, get_access_log, get_error_log, clear_logs

source /opt/vibestack/includes/common.sh

NGINX_ACTION=$1
DOMAIN=$2
PAYLOAD=$3

[[ -z "$NGINX_ACTION" ]] && fatal_error 5300 "Nginx action missing"
[[ -z "$DOMAIN" ]]       && fatal_error 5301 "Domain missing in nginx/config.sh"

USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"
VHOST_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
LOG_DIR="$WEB_ROOT/logs"

case "$NGINX_ACTION" in

    # -------------------------------------------------------------------------
    "get_config")
        [[ ! -f "$VHOST_CONF" ]] && fatal_error 5310 "Nginx vhost not found for $DOMAIN"

        # Parse key values from vhost
        SERVER_NAMES=$(grep "server_name" "$VHOST_CONF" | grep -v "^#" | awk '{$1=""; print $0}' | tr -s ' ' | sed 's/;//g' | head -1)
        CLIENT_MAX=$(grep "client_max_body_size" "$VHOST_CONF" | awk '{print $2}' | sed 's/;//' | head -1)
        HTTP2=$(grep -c "http2 on" "$VHOST_CONF" || echo "0")
        SSL_CERT=$(grep "ssl_certificate " "$VHOST_CONF" | grep -v "key" | awk '{print $2}' | sed 's/;//' | head -1)
        ACCESS_LOG="$LOG_DIR/access.log"
        ERROR_LOG="$LOG_DIR/error.log"

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg vhost_file "$VHOST_CONF" \
            --arg server_names "$SERVER_NAMES" \
            --arg client_max_body_size "${CLIENT_MAX:-128M}" \
            --argjson http2 "$([ "$HTTP2" -gt 0 ] && echo true || echo false)" \
            --arg ssl_certificate "${SSL_CERT:-acme}" \
            --arg access_log "$ACCESS_LOG" \
            --arg error_log "$ERROR_LOG" \
            '{
                domain: $domain,
                vhost_file: $vhost_file,
                server_names: $server_names,
                client_max_body_size: $client_max_body_size,
                http2: $http2,
                ssl_certificate: $ssl_certificate,
                access_log: $access_log,
                error_log: $error_log
            }')
        ;;

    # -------------------------------------------------------------------------
    "add_domain")
        # PAYLOAD = additional domain/alias to add e.g. "www.newdomain.com"
        [[ -z "$PAYLOAD" ]]      && fatal_error 5311 "New domain required"
        [[ ! -f "$VHOST_CONF" ]] && fatal_error 5312 "Vhost not found for $DOMAIN"

        # Add to server_name lines in both server blocks
        sed -i "s/server_name ${DOMAIN}/server_name ${DOMAIN} ${PAYLOAD}/g" "$VHOST_CONF"

        # Test and reload
        NGINX_TEST=$(nginx -t 2>&1)
        if [ $? -ne 0 ]; then
            # Revert
            sed -i "s/server_name ${DOMAIN} ${PAYLOAD}/server_name ${DOMAIN}/g" "$VHOST_CONF"
            fatal_error 5313 "Nginx config test failed after adding domain. Reverted."
        fi
        systemctl reload nginx >/dev/null 2>&1

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg added "$PAYLOAD" \
            '{domain: $domain, success: true, domain_added: $added}')
        ;;

    # -------------------------------------------------------------------------
    "remove_domain")
        [[ -z "$PAYLOAD" ]]      && fatal_error 5314 "Domain to remove required"
        [[ "$PAYLOAD" == "$DOMAIN" ]] && fatal_error 5315 "Cannot remove primary domain"
        [[ ! -f "$VHOST_CONF" ]] && fatal_error 5316 "Vhost not found"

        sed -i "s/ ${PAYLOAD}//g" "$VHOST_CONF"
        NGINX_TEST=$(nginx -t 2>&1)
        if [ $? -ne 0 ]; then
            fatal_error 5317 "Nginx config test failed. Manual review needed."
        fi
        systemctl reload nginx >/dev/null 2>&1

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg removed "$PAYLOAD" \
            '{domain: $domain, success: true, domain_removed: $removed}')
        ;;

    # -------------------------------------------------------------------------
    "list_domains")
        [[ ! -f "$VHOST_CONF" ]] && fatal_error 5318 "Vhost not found for $DOMAIN"
        SERVER_NAMES=$(grep "server_name" "$VHOST_CONF" | grep -v "^#" | \
            awk '{for(i=2;i<=NF;i++) print $i}' | sed 's/;//g' | sort -u)
        DOMAIN_LIST=$(echo "$SERVER_NAMES" | jq -R . | jq -s .)
        COUNT=$(echo "$DOMAIN_LIST" | jq 'length')
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --argjson count "$COUNT" \
            --argjson domains "$DOMAIN_LIST" \
            '{domain: $domain, domain_count: $count, domains: $domains}')
        ;;

    # -------------------------------------------------------------------------
    "reload")
        NGINX_TEST=$(nginx -t 2>&1)
        if [ $? -ne 0 ]; then
            fatal_error 5319 "Nginx config test failed: $NGINX_TEST"
        fi
        systemctl reload nginx >/dev/null 2>&1
        MODULE_RESULT=$(jq -n --arg domain "$DOMAIN" \
            '{domain: $domain, success: true, nginx_reloaded: true}')
        ;;

    # -------------------------------------------------------------------------
    "get_ssl_status")
        [[ ! -f "$VHOST_CONF" ]] && fatal_error 5320 "Vhost not found"
        ACME_STATE_DIR="/var/lib/nginx/acme"
        SSL_TYPE="none"

        if grep -q "acme_certificate" "$VHOST_CONF"; then
            SSL_TYPE="acme_letsencrypt"
        elif grep -q "ssl_certificate" "$VHOST_CONF"; then
            SSL_TYPE="manual"
        fi

        # Check cert expiry if ACME
        CERT_EXPIRY="unknown"
        if [[ "$SSL_TYPE" == "acme_letsencrypt" ]]; then
            CERT_FILE=$(find "$ACME_STATE_DIR" -name "*.crt" 2>/dev/null | head -1)
            if [[ -n "$CERT_FILE" ]]; then
                CERT_EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
            fi
        fi

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg ssl_type "$SSL_TYPE" \
            --arg cert_expiry "$CERT_EXPIRY" \
            '{domain: $domain, ssl_type: $ssl_type, cert_expiry: $cert_expiry}')
        ;;

    # -------------------------------------------------------------------------
    "set_client_max_body")
        [[ -z "$PAYLOAD" ]]      && fatal_error 5321 "Size required (e.g. 256M)"
        [[ ! -f "$VHOST_CONF" ]] && fatal_error 5322 "Vhost not found"

        if grep -q "client_max_body_size" "$VHOST_CONF"; then
            sed -i "s|client_max_body_size .*|client_max_body_size ${PAYLOAD};|" "$VHOST_CONF"
        fi

        NGINX_TEST=$(nginx -t 2>&1)
        [[ $? -ne 0 ]] && fatal_error 5323 "Nginx config test failed after update"
        systemctl reload nginx >/dev/null 2>&1

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg size "$PAYLOAD" \
            '{domain: $domain, success: true, client_max_body_size: $size}')
        ;;

    # -------------------------------------------------------------------------
    "get_access_log")
        # PAYLOAD = number of lines (default 100)
        LINES="${PAYLOAD:-100}"
        LOG_FILE="$LOG_DIR/access.log"
        [[ ! -f "$LOG_FILE" ]] && fatal_error 5324 "Access log not found for $DOMAIN"
        LOG_CONTENT=$(tail -n "$LINES" "$LOG_FILE" | jq -R . | jq -s .)
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --argjson lines "${LINES}" \
            --arg log_file "$LOG_FILE" \
            --argjson log "$LOG_CONTENT" \
            '{domain: $domain, log_file: $log_file, lines_requested: $lines, log: $log}')
        ;;

    # -------------------------------------------------------------------------
    "get_error_log")
        LINES="${PAYLOAD:-100}"
        LOG_FILE="$LOG_DIR/error.log"
        [[ ! -f "$LOG_FILE" ]] && fatal_error 5325 "Error log not found for $DOMAIN"
        LOG_CONTENT=$(tail -n "$LINES" "$LOG_FILE" | jq -R . | jq -s .)
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --argjson lines "${LINES}" \
            --arg log_file "$LOG_FILE" \
            --argjson log "$LOG_CONTENT" \
            '{domain: $domain, log_file: $log_file, lines_requested: $lines, log: $log}')
        ;;

    # -------------------------------------------------------------------------
    "clear_logs")
        > "$LOG_DIR/access.log"
        > "$LOG_DIR/error.log"
        systemctl reload nginx >/dev/null 2>&1
        MODULE_RESULT=$(jq -n --arg domain "$DOMAIN" \
            '{domain: $domain, success: true, logs_cleared: true}')
        ;;

    *)
        fatal_error 5399 "Unknown Nginx action: $NGINX_ACTION. Valid: get_config, add_domain, remove_domain, list_domains, reload, get_ssl_status, set_client_max_body, get_access_log, get_error_log, clear_logs"
        ;;
esac
