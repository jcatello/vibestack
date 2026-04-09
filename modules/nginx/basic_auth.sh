#!/bin/bash
# /opt/vibestack/modules/nginx/basic_auth.sh
# Module: HTTP Basic Authentication Management
# Actions: enable_site, disable_site, enable_wplogin, disable_wplogin,
#          update_credentials, list

source /opt/vibestack/includes/common.sh

AUTH_ACTION=$1
DOMAIN=$2
PAYLOAD=$3    # JSON: {"user":"username","password":"pass","realm":"Private"}

[[ -z "$AUTH_ACTION" ]] && fatal_error 5500 "Auth action missing"
[[ -z "$DOMAIN" ]]      && fatal_error 5501 "Domain missing in basic_auth.sh"

USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"
VHOST_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
HTPASSWD_DIR="/etc/nginx/auth"
HTPASSWD_FILE="${HTPASSWD_DIR}/${DOMAIN}.htpasswd"
WPLOGIN_HTPASSWD="${HTPASSWD_DIR}/${DOMAIN}-wplogin.htpasswd"

mkdir -p "$HTPASSWD_DIR"
chmod 750 "$HTPASSWD_DIR"
chown root:nginx "$HTPASSWD_DIR"

# Helper: write htpasswd entry using openssl (no htpasswd binary required)
write_htpasswd() {
    local file=$1
    local user=$2
    local pass=$3
    local hashed
    hashed=$(openssl passwd -apr1 "$pass")
    echo "${user}:${hashed}" > "$file"
    chmod 640 "$file"
    chown root:nginx "$file"
}

# Helper: test nginx config and reload
nginx_reload() {
    local test_output
    test_output=$(nginx -t 2>&1)
    if [ $? -ne 0 ]; then
        THREAD_TS=$(send_slack_initial "🚨 *Nginx Config Error* after basic_auth change on \`$(hostname)\` for \`$DOMAIN\`" "alerts")
        send_slack_thread "$THREAD_TS" "\`\`\`$test_output\`\`\`" "alerts"
        fatal_error 5510 "Nginx config test failed after auth change. Check Slack for details."
    fi
    systemctl reload nginx >/dev/null 2>&1
}

# Helper: inject or remove an auth block inside the HTTPS server block
inject_auth_block() {
    local marker=$1       # unique comment marker so we can find/remove it
    local block=$2        # nginx config lines to inject
    local vhost=$3

    # Remove existing block if present
    perl -i -0pe "s|# AUTH_BLOCK_${marker}_START.*?# AUTH_BLOCK_${marker}_END\n||gs" "$vhost"

    # Inject before the closing brace of the HTTPS server block
    # We find the last closing brace and insert before it
    python3 - "$vhost" "$marker" "$block" << 'PYEOF'
import sys, re

vhost_path = sys.argv[1]
marker     = sys.argv[2]
block      = sys.argv[3]

with open(vhost_path, 'r') as f:
    content = f.read()

injection = f"\n    # AUTH_BLOCK_{marker}_START\n{block}\n    # AUTH_BLOCK_{marker}_END\n"

# Insert before the last closing brace in the file
pos = content.rfind('\n}')
if pos == -1:
    pos = content.rfind('}')

content = content[:pos] + injection + content[pos:]

with open(vhost_path, 'w') as f:
    f.write(content)
PYEOF
}

remove_auth_block() {
    local marker=$1
    local vhost=$2
    perl -i -0pe "s|\n    # AUTH_BLOCK_${marker}_START.*?    # AUTH_BLOCK_${marker}_END\n||gs" "$vhost"
}

case "$AUTH_ACTION" in

    # -------------------------------------------------------------------------
    "enable_site")
        [[ -z "$PAYLOAD" ]] && fatal_error 5511 "JSON payload required: {user, password, realm}"
        [[ ! -f "$VHOST_CONF" ]] && fatal_error 5512 "Vhost not found for $DOMAIN"

        AUTH_USER=$(echo "$PAYLOAD" | jq -r '.user // empty')
        AUTH_PASS=$(echo "$PAYLOAD" | jq -r '.password // empty')
        AUTH_REALM=$(echo "$PAYLOAD" | jq -r '.realm // "Restricted"')

        [[ -z "$AUTH_USER" || -z "$AUTH_PASS" ]] && fatal_error 5513 "user and password required"

        write_htpasswd "$HTPASSWD_FILE" "$AUTH_USER" "$AUTH_PASS"

        BLOCK="    auth_basic \"${AUTH_REALM}\";
    auth_basic_user_file ${HTPASSWD_FILE};"

        inject_auth_block "SITE" "$BLOCK" "$VHOST_CONF"
        nginx_reload

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg user "$AUTH_USER" \
            --arg realm "$AUTH_REALM" \
            --arg htpasswd "$HTPASSWD_FILE" \
            '{domain: $domain, success: true, basic_auth: "enabled", scope: "site", user: $user, realm: $realm, htpasswd_file: $htpasswd}')
        ;;

    # -------------------------------------------------------------------------
    "disable_site")
        [[ ! -f "$VHOST_CONF" ]] && fatal_error 5514 "Vhost not found for $DOMAIN"

        remove_auth_block "SITE" "$VHOST_CONF"
        rm -f "$HTPASSWD_FILE"
        nginx_reload

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            '{domain: $domain, success: true, basic_auth: "disabled", scope: "site"}')
        ;;

    # -------------------------------------------------------------------------
    "enable_wplogin")
        [[ -z "$PAYLOAD" ]] && fatal_error 5515 "JSON payload required: {user, password, realm}"
        [[ ! -f "$VHOST_CONF" ]] && fatal_error 5516 "Vhost not found for $DOMAIN"

        AUTH_USER=$(echo "$PAYLOAD" | jq -r '.user // empty')
        AUTH_PASS=$(echo "$PAYLOAD" | jq -r '.password // empty')
        AUTH_REALM=$(echo "$PAYLOAD" | jq -r '.realm // "WordPress Login"')

        [[ -z "$AUTH_USER" || -z "$AUTH_PASS" ]] && fatal_error 5517 "user and password required"

        write_htpasswd "$WPLOGIN_HTPASSWD" "$AUTH_USER" "$AUTH_PASS"

        # This is a location block — injected as a nested location inside the server block
        BLOCK="    location = /wp-login.php {
        auth_basic \"${AUTH_REALM}\";
        auth_basic_user_file ${WPLOGIN_HTPASSWD};
        include fastcgi_params;
        fastcgi_pass unix:/run/php-fpm/${DOMAIN}.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }"

        inject_auth_block "WPLOGIN" "$BLOCK" "$VHOST_CONF"
        nginx_reload

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg user "$AUTH_USER" \
            --arg realm "$AUTH_REALM" \
            --arg htpasswd "$WPLOGIN_HTPASSWD" \
            '{domain: $domain, success: true, basic_auth: "enabled", scope: "wp-login.php", user: $user, realm: $realm, htpasswd_file: $htpasswd}')
        ;;

    # -------------------------------------------------------------------------
    "disable_wplogin")
        [[ ! -f "$VHOST_CONF" ]] && fatal_error 5518 "Vhost not found for $DOMAIN"

        remove_auth_block "WPLOGIN" "$VHOST_CONF"
        rm -f "$WPLOGIN_HTPASSWD"
        nginx_reload

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            '{domain: $domain, success: true, basic_auth: "disabled", scope: "wp-login.php"}')
        ;;

    # -------------------------------------------------------------------------
    "update_credentials")
        # Updates password for either scope — PAYLOAD: {scope: "site|wplogin", user, password}
        [[ -z "$PAYLOAD" ]] && fatal_error 5519 "JSON payload required: {scope, user, password}"

        SCOPE=$(echo "$PAYLOAD" | jq -r '.scope // empty')
        AUTH_USER=$(echo "$PAYLOAD" | jq -r '.user // empty')
        AUTH_PASS=$(echo "$PAYLOAD" | jq -r '.password // empty')

        [[ -z "$SCOPE" || -z "$AUTH_USER" || -z "$AUTH_PASS" ]] && \
            fatal_error 5520 "scope, user, and password required"

        if [[ "$SCOPE" == "site" ]]; then
            [[ ! -f "$HTPASSWD_FILE" ]] && fatal_error 5521 "Site basic auth not enabled for $DOMAIN"
            write_htpasswd "$HTPASSWD_FILE" "$AUTH_USER" "$AUTH_PASS"
        elif [[ "$SCOPE" == "wplogin" ]]; then
            [[ ! -f "$WPLOGIN_HTPASSWD" ]] && fatal_error 5522 "wp-login basic auth not enabled for $DOMAIN"
            write_htpasswd "$WPLOGIN_HTPASSWD" "$AUTH_USER" "$AUTH_PASS"
        else
            fatal_error 5523 "scope must be 'site' or 'wplogin'"
        fi

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg scope "$SCOPE" \
            --arg user "$AUTH_USER" \
            '{domain: $domain, success: true, scope: $scope, user: $user, message: "Credentials updated"}')
        ;;

    # -------------------------------------------------------------------------
    "list")
        SITE_ENABLED=false
        WPLOGIN_ENABLED=false
        SITE_USER=""
        WPLOGIN_USER=""

        [[ -f "$HTPASSWD_FILE" ]] && SITE_ENABLED=true && \
            SITE_USER=$(cut -d: -f1 "$HTPASSWD_FILE" 2>/dev/null)
        [[ -f "$WPLOGIN_HTPASSWD" ]] && WPLOGIN_ENABLED=true && \
            WPLOGIN_USER=$(cut -d: -f1 "$WPLOGIN_HTPASSWD" 2>/dev/null)

        # Check if nginx conf has the auth blocks
        SITE_CONF_PRESENT=false
        WPLOGIN_CONF_PRESENT=false
        if [[ -f "$VHOST_CONF" ]]; then
            grep -q "AUTH_BLOCK_SITE_START" "$VHOST_CONF" && SITE_CONF_PRESENT=true
            grep -q "AUTH_BLOCK_WPLOGIN_START" "$VHOST_CONF" && WPLOGIN_CONF_PRESENT=true
        fi

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --argjson site_enabled "$SITE_ENABLED" \
            --arg site_user "$SITE_USER" \
            --argjson wplogin_enabled "$WPLOGIN_ENABLED" \
            --arg wplogin_user "$WPLOGIN_USER" \
            '{
                domain: $domain,
                site_auth: {
                    enabled: $site_enabled,
                    user: $site_user
                },
                wplogin_auth: {
                    enabled: $wplogin_enabled,
                    user: $wplogin_user
                }
            }')
        ;;

    *)
        fatal_error 5599 "Unknown auth action: $AUTH_ACTION. Valid: enable_site, disable_site, enable_wplogin, disable_wplogin, update_credentials, list"
        ;;
esac
