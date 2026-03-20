#!/bin/bash
# /opt/vibestack/modules/system/phpmyadmin.sh
# Module: phpMyAdmin Installation & Management
# Called once by vibestack-setup.sh
# Actions: install, rotate_path, rotate_credentials, get_info

source /opt/vibestack/includes/common.sh

PMA_ACTION=${1:-"install"}

# phpMyAdmin config lives in vibestack.conf
# PMA_PATH, PMA_USER, PMA_PASS are read/written here
CONF_FILE="/opt/vibestack/config/vibestack.conf"
PMA_BASE="/usr/share/phpmyadmin"
PMA_NGINX_CONF="/etc/nginx/conf.d/00-phpmyadmin.conf"
PMA_HTPASSWD="/etc/nginx/auth/phpmyadmin.htpasswd"
HTPASSWD_DIR="/etc/nginx/auth"

mkdir -p "$HTPASSWD_DIR"
chmod 750 "$HTPASSWD_DIR"
chown root:nginx "$HTPASSWD_DIR"

# Generate a random URL path (8 chars, alphanumeric, no obvious patterns)
generate_path() {
    tr -dc 'a-z0-9' < /dev/urandom | head -c 8
}

# Write htpasswd using openssl apr1 (no htpasswd binary required)
write_htpasswd() {
    local user=$1 pass=$2
    local hashed
    hashed=$(openssl passwd -apr1 "$pass")
    echo "${user}:${hashed}" > "$PMA_HTPASSWD"
    chmod 640 "$PMA_HTPASSWD"
    chown root:nginx "$PMA_HTPASSWD"
}

# Update a key in vibestack.conf
update_conf_key() {
    local key=$1 val=$2
    if grep -q "^${key}=" "$CONF_FILE"; then
        sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$CONF_FILE"
    else
        echo "${key}=\"${val}\"" >> "$CONF_FILE"
    fi
}

case "$PMA_ACTION" in

    # -------------------------------------------------------------------------
    "install")
        echo "Installing phpMyAdmin..."

        # 1. Install phpMyAdmin and dependencies
        dnf install -y epel-release >/dev/null 2>&1
        dnf install -y phpMyAdmin >/dev/null 2>&1

        # phpMyAdmin package may install to /usr/share/phpMyAdmin — normalise
        if [ -d "/usr/share/phpMyAdmin" ] && [ ! -d "$PMA_BASE" ]; then
            PMA_BASE="/usr/share/phpMyAdmin"
        fi

        # 2. Configure phpMyAdmin to use unix socket (no TCP, more secure)
        PMA_CONF_FILE=$(find /etc/phpMyAdmin /etc/phpmyadmin -name "config.inc.php" 2>/dev/null | head -1)
        if [[ -z "$PMA_CONF_FILE" ]]; then
            PMA_CONF_FILE="$PMA_BASE/config.inc.php"
        fi

        # Set blowfish secret for session encryption
        BLOWFISH=$(tr -dc 'a-zA-Z0-9!@#$%^&*' < /dev/urandom | head -c 32)

        if [[ -f "$PMA_CONF_FILE" ]]; then
            # Update blowfish secret
            if grep -q "blowfish_secret" "$PMA_CONF_FILE"; then
                sed -i "s|cfg\['blowfish_secret'\] = .*|cfg['blowfish_secret'] = '${BLOWFISH}';|" "$PMA_CONF_FILE"
            fi
            # Ensure socket connection
            sed -i "s|cfg\['Servers'\]\[.*\]\['host'\].*|cfg['Servers'][\$i]['host'] = 'localhost';|" "$PMA_CONF_FILE"
        fi

        # 3. Generate random URL path + credentials
        PMA_PATH=$(generate_path)
        PMA_USER="dbadmin"
        PMA_PASS=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 20)

        # 4. Store in vibestack.conf
        update_conf_key "PMA_PATH" "$PMA_PATH"
        update_conf_key "PMA_USER" "$PMA_USER"
        update_conf_key "PMA_PASS" "$PMA_PASS"

        # 5. Write htpasswd
        write_htpasswd "$PMA_USER" "$PMA_PASS"

        # 6. Get server hostname for the vhost
        SERVER_HOSTNAME=$(hostname -f)

        # 7. Write Nginx location block into 01-hostname.conf
        # phpMyAdmin runs on the hostname vhost, not on any customer domain
        # Inject into existing hostname conf or create a dedicated include

        # Find the best PHP binary available
        PHP_BIN=$(find /opt/remi/php*/root/usr/bin/php -type f 2>/dev/null | sort -V | tail -1)
        PHP_PKG=$(find /opt/remi/php*/root/usr/bin/php -type f 2>/dev/null | sort -V | tail -1 | grep -oP 'php\d+')
        PHP_SOCK=""

        # phpMyAdmin needs its own PHP-FPM pool since it runs as root/nginx context
        # Use the system php-fpm if available, otherwise use first remi php
        if systemctl is-active "php-fpm" >/dev/null 2>&1; then
            PHP_SOCK="/run/php-fpm/www.sock"
        elif [[ -n "$PHP_PKG" ]]; then
            # Create a dedicated phpmyadmin pool
            PMA_POOL="/etc/opt/remi/${PHP_PKG}/php-fpm.d/phpmyadmin.conf"
            cat << EOF > "$PMA_POOL"
[phpmyadmin]
user = nginx
group = nginx
listen = /run/php-fpm/phpmyadmin.sock
listen.owner = nginx
listen.group = nginx
pm = ondemand
pm.max_children = 5
pm.process_idle_timeout = 30s
pm.max_requests = 200
chdir = /
php_admin_value[open_basedir] = ${PMA_BASE}:/tmp:/usr/share:/var/lib/php
php_admin_value[memory_limit] = 128M
EOF
            systemctl reload "${PHP_PKG}-php-fpm" >/dev/null 2>&1
            sleep 1
            PHP_SOCK="/run/php-fpm/phpmyadmin.sock"
        fi

        [[ -z "$PHP_SOCK" ]] && fatal_error 5601 "No PHP-FPM socket available for phpMyAdmin"

        # 8. Write Nginx config
        cat << EOF > "$PMA_NGINX_CONF"
# phpMyAdmin — managed by vibestack
# Path: /${PMA_PATH}
# Credentials stored in /opt/vibestack/config/vibestack.conf

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${SERVER_HOSTNAME};

    acme_certificate letsencrypt;
    ssl_certificate \$acme_certificate;
    ssl_certificate_key \$acme_certificate_key;

    # Block direct access to everything except our random path
    location / {
        return 404;
    }

    location /${PMA_PATH}/ {
        alias ${PMA_BASE}/;
        index index.php;

        # Basic auth protection
        auth_basic "Database Administration";
        auth_basic_user_file ${PMA_HTPASSWD};

        location ~ ^/${PMA_PATH}/(.+\.php)$ {
            auth_basic "Database Administration";
            auth_basic_user_file ${PMA_HTPASSWD};
            alias ${PMA_BASE}/\$1;
            fastcgi_pass unix:${PHP_SOCK};
            fastcgi_index index.php;
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME ${PMA_BASE}/\$1;
            fastcgi_param PATH_INFO \$fastcgi_path_info;
        }

        location ~* ^/${PMA_PATH}/(.+\.(css|js|png|jpg|gif|ico|svg|woff|woff2|ttf))$ {
            alias ${PMA_BASE}/\$1;
            expires 7d;
            add_header Cache-Control "public";
        }
    }
}
EOF

        # Test and reload nginx
        NGINX_TEST=$(nginx -t 2>&1)
        if [ $? -ne 0 ]; then
            THREAD_TS=$(send_slack_initial "🚨 *Nginx Config Error* after phpMyAdmin install on \`$(hostname)\`" "alerts")
            send_slack_thread "$THREAD_TS" "\`\`\`$NGINX_TEST\`\`\`" "alerts"
            fatal_error 5602 "Nginx config test failed after phpMyAdmin install."
        fi
        systemctl reload nginx >/dev/null 2>&1

        MODULE_RESULT=$(jq -n \
            --arg hostname "$SERVER_HOSTNAME" \
            --arg path "/$PMA_PATH" \
            --arg url "https://${SERVER_HOSTNAME}/${PMA_PATH}/" \
            --arg user "$PMA_USER" \
            --arg pass "$PMA_PASS" \
            '{
                phpmyadmin_installed: true,
                url: $url,
                path: $path,
                hostname: $hostname,
                basic_auth_user: $user,
                basic_auth_pass: $pass,
                note: "Credentials also stored in /opt/vibestack/config/vibestack.conf"
            }')

        echo "phpMyAdmin installed at https://${SERVER_HOSTNAME}/${PMA_PATH}/"
        echo "User: $PMA_USER  Pass: $PMA_PASS"
        ;;

    # -------------------------------------------------------------------------
    "rotate_path")
        # Generate a new random path, update conf and nginx config
        source "$CONF_FILE"
        OLD_PATH="${PMA_PATH:-unknown}"
        NEW_PATH=$(generate_path)

        update_conf_key "PMA_PATH" "$NEW_PATH"

        if [[ -f "$PMA_NGINX_CONF" ]]; then
            sed -i "s|/${OLD_PATH}/|/${NEW_PATH}/|g" "$PMA_NGINX_CONF"
            sed -i "s|# Path: /.*|# Path: /${NEW_PATH}|" "$PMA_NGINX_CONF"
        fi

        NGINX_TEST=$(nginx -t 2>&1)
        [[ $? -ne 0 ]] && fatal_error 5603 "Nginx config test failed after path rotation."
        systemctl reload nginx >/dev/null 2>&1

        SERVER_HOSTNAME=$(hostname -f)
        MODULE_RESULT=$(jq -n \
            --arg old_path "/$OLD_PATH" \
            --arg new_path "/$NEW_PATH" \
            --arg url "https://${SERVER_HOSTNAME}/${NEW_PATH}/" \
            '{success: true, old_path: $old_path, new_path: $new_path, new_url: $url}')
        ;;

    # -------------------------------------------------------------------------
    "rotate_credentials")
        source "$CONF_FILE"
        NEW_PASS=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 20)
        PMA_USER="${PMA_USER:-dbadmin}"

        write_htpasswd "$PMA_USER" "$NEW_PASS"
        update_conf_key "PMA_PASS" "$NEW_PASS"

        MODULE_RESULT=$(jq -n \
            --arg user "$PMA_USER" \
            --arg pass "$NEW_PASS" \
            '{success: true, user: $user, new_password: $pass}')
        ;;

    # -------------------------------------------------------------------------
    "get_info")
        source "$CONF_FILE" 2>/dev/null || true
        SERVER_HOSTNAME=$(hostname -f)
        PMA_STATUS="not_installed"
        [[ -f "$PMA_NGINX_CONF" ]] && PMA_STATUS="installed"

        MODULE_RESULT=$(jq -n \
            --arg status "$PMA_STATUS" \
            --arg hostname "$SERVER_HOSTNAME" \
            --arg path "/${PMA_PATH:-unknown}" \
            --arg url "https://${SERVER_HOSTNAME}/${PMA_PATH:-}/" \
            --arg user "${PMA_USER:-}" \
            '{
                status: $status,
                hostname: $hostname,
                path: $path,
                url: $url,
                basic_auth_user: $user
            }')
        ;;

    *)
        fatal_error 5699 "Unknown phpMyAdmin action: $PMA_ACTION. Valid: install, rotate_path, rotate_credentials, get_info"
        ;;
esac