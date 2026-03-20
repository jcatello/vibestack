#!/bin/bash
# /opt/vibestack/modules/wp/users.sh
# Module: WordPress User Management
# Actions: list, create, delete, update, get, set_role, reset_password, list_roles

source /opt/vibestack/includes/common.sh

WP_ACTION=$1
DOMAIN=$2
# For create/update: remaining params passed as JSON string
# e.g. '{"username":"john","email":"john@example.com","role":"editor","password":"pass"}'
USER_JSON=$3

[[ -z "$WP_ACTION" ]] && fatal_error 4200 "User action missing"
[[ -z "$DOMAIN" ]]    && fatal_error 4201 "Domain missing in users.sh"

USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"
PHP_BIN=$(find /opt/remi/php*/root/usr/bin/php -type f 2>/dev/null | sort -V | tail -1)
WP_BIN="/usr/local/bin/wp"

[[ -z "$PHP_BIN" ]] && fatal_error 4202 "No PHP binary found"

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

    "list")
        RAW=$(wp_run user list --format=json \
            --fields=ID,user_login,user_email,display_name,roles,user_registered)
        if ! echo "$RAW" | jq empty >/dev/null 2>&1; then
            fatal_error 4210 "Failed to retrieve user list for $DOMAIN"
        fi
        COUNT=$(echo "$RAW" | jq 'length')
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --argjson count "$COUNT" \
            --argjson users "$RAW" \
            '{domain: $domain, user_count: $count, users: $users}')
        ;;

    "get")
        # USER_JSON = user login, email, or ID
        [[ -z "$USER_JSON" ]] && fatal_error 4211 "User identifier required for get"
        RAW=$(wp_run user get "$USER_JSON" --format=json)
        if ! echo "$RAW" | jq empty >/dev/null 2>&1; then
            fatal_error 4212 "User '$USER_JSON' not found on $DOMAIN"
        fi
        MODULE_RESULT=$(jq -n --arg domain "$DOMAIN" --argjson user "$RAW" \
            '{domain: $domain, user: $user}')
        ;;

    "create")
        [[ -z "$USER_JSON" ]] && fatal_error 4213 "User JSON required for create"
        WP_USERNAME=$(echo "$USER_JSON" | jq -r '.username // empty')
        WP_EMAIL=$(echo "$USER_JSON" | jq -r '.email // empty')
        WP_ROLE=$(echo "$USER_JSON" | jq -r '.role // "subscriber"')
        WP_PASS=$(echo "$USER_JSON" | jq -r '.password // empty')
        WP_FIRST=$(echo "$USER_JSON" | jq -r '.first_name // empty')
        WP_LAST=$(echo "$USER_JSON" | jq -r '.last_name // empty')

        [[ -z "$WP_USERNAME" ]] && fatal_error 4214 "username required in user JSON"
        [[ -z "$WP_EMAIL" ]]    && fatal_error 4215 "email required in user JSON"

        # Generate password if not provided
        [[ -z "$WP_PASS" ]] && WP_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

        CMD_ARGS=(user create "$WP_USERNAME" "$WP_EMAIL"
            --role="$WP_ROLE"
            --user_pass="$WP_PASS"
            --send-email=false)
        [[ -n "$WP_FIRST" ]] && CMD_ARGS+=(--first_name="$WP_FIRST")
        [[ -n "$WP_LAST" ]]  && CMD_ARGS+=(--last_name="$WP_LAST")

        OUT=$(wp_run "${CMD_ARGS[@]}")
        STATUS=$?
        NEW_ID=$(echo "$OUT" | grep -oP 'user id \K\d+' || echo "")

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg username "$WP_USERNAME" \
            --arg email "$WP_EMAIL" \
            --arg role "$WP_ROLE" \
            --arg password "$WP_PASS" \
            --arg user_id "$NEW_ID" \
            --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, user_id: $user_id, username: $username, email: $email, role: $role, password: $password, output: $output}')
        ;;

    "delete")
        [[ -z "$USER_JSON" ]] && fatal_error 4216 "User identifier required for delete"
        # Reassign posts to admin (user ID 1) before deleting
        OUT=$(wp_run user delete "$USER_JSON" --reassign=1 --yes)
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg user "$USER_JSON" --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, user: $user, output: $output}')
        ;;

    "update")
        [[ -z "$USER_JSON" ]] && fatal_error 4217 "User JSON required for update"
        WP_USER_ID=$(echo "$USER_JSON" | jq -r '.id // empty')
        [[ -z "$WP_USER_ID" ]] && fatal_error 4218 "id required in user JSON for update"

        CMD_ARGS=(user update "$WP_USER_ID")
        EMAIL=$(echo "$USER_JSON" | jq -r '.email // empty')
        FIRST=$(echo "$USER_JSON" | jq -r '.first_name // empty')
        LAST=$(echo "$USER_JSON"  | jq -r '.last_name // empty')
        DISPLAY=$(echo "$USER_JSON" | jq -r '.display_name // empty')

        [[ -n "$EMAIL" ]]   && CMD_ARGS+=(--user_email="$EMAIL")
        [[ -n "$FIRST" ]]   && CMD_ARGS+=(--first_name="$FIRST")
        [[ -n "$LAST" ]]    && CMD_ARGS+=(--last_name="$LAST")
        [[ -n "$DISPLAY" ]] && CMD_ARGS+=(--display_name="$DISPLAY")

        OUT=$(wp_run "${CMD_ARGS[@]}")
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg user_id "$WP_USER_ID" --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, user_id: $user_id, output: $output}')
        ;;

    "set_role")
        [[ -z "$USER_JSON" ]] && fatal_error 4219 "JSON required: {\"user\":\"login\",\"role\":\"editor\"}"
        WP_USER=$(echo "$USER_JSON" | jq -r '.user // empty')
        WP_ROLE=$(echo "$USER_JSON" | jq -r '.role // empty')
        [[ -z "$WP_USER" || -z "$WP_ROLE" ]] && fatal_error 4220 "user and role required"
        OUT=$(wp_run user set-role "$WP_USER" "$WP_ROLE")
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg user "$WP_USER" --arg role "$WP_ROLE" --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, user: $user, role: $role, output: $output}')
        ;;

    "reset_password")
        [[ -z "$USER_JSON" ]] && fatal_error 4221 "User identifier required for reset_password"
        # Generate secure password
        NEW_PASS=$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9!@#$%' | head -c 20)
        OUT=$(wp_run user update "$USER_JSON" --user_pass="$NEW_PASS")
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg user "$USER_JSON" \
            --arg new_password "$NEW_PASS" --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, user: $user, new_password: $new_password, output: $output}')
        ;;

    "list_roles")
        RAW=$(wp_run role list --format=json --fields=name,capabilities)
        if ! echo "$RAW" | jq empty >/dev/null 2>&1; then RAW="[]"; fi
        MODULE_RESULT=$(jq -n --arg domain "$DOMAIN" --argjson roles "$RAW" \
            '{domain: $domain, roles: $roles}')
        ;;

    *)
        fatal_error 4299 "Unknown user action: $WP_ACTION. Valid: list, get, create, delete, update, set_role, reset_password, list_roles"
        ;;
esac
