#!/bin/bash
# /opt/vibestack/modules/core_nginx.sh
# Module: Base User, Directory, SSH, and Nginx Vhost Setup

# --- 0. MANDATORY INCLUDES ---
source /opt/vibestack/includes/common.sh

# --- 1. VALIDATION ---
DOMAIN=$1
[[ -z "$DOMAIN" ]] && fatal_error 1003 "Domain parameter missing in core_nginx.sh"

# --- 2. VARIABLES ---
USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"
SERVER_IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')

# --- 3. LINUX USER & ISOLATION ---
if ! getent group "$USER_NAME" &>/dev/null; then
    groupadd "$USER_NAME"
fi

if ! id "$USER_NAME" &>/dev/null; then
    useradd -m -d "$WEB_ROOT" -s /bin/bash -g "$USER_NAME" "$USER_NAME"
fi

usermod -a -G "$USER_NAME" nginx
mkdir -p "$WEB_ROOT"/{public,logs,.ssh,tmp}

# --- 4. SSH KEY GENERATION (ED25519) ---
if [ ! -f "$WEB_ROOT/.ssh/id_ed25519" ]; then
    ssh-keygen -t ed25519 -f "$WEB_ROOT/.ssh/id_ed25519" -N "" -q
    cat "$WEB_ROOT/.ssh/id_ed25519.pub" >> "$WEB_ROOT/.ssh/authorized_keys"
    chmod 700 "$WEB_ROOT/.ssh"
    chmod 600 "$WEB_ROOT/.ssh/authorized_keys"
fi

PRIVATE_KEY=$(cat "$WEB_ROOT/.ssh/id_ed25519")

chown -R "$USER_NAME:$USER_NAME" "$WEB_ROOT"
chmod 750 "$WEB_ROOT"

# Logs dir must be writable by nginx (which runs as nginx user, member of site group)
chown "$USER_NAME:nginx" "$WEB_ROOT/logs"
chmod 775 "$WEB_ROOT/logs"

# --- 5. NGINX VHOST CONFIGURATION (Native ACME) ---
cat << EOF > /etc/nginx/conf.d/$DOMAIN.conf
# HTTP Server Block (Redirects to HTTPS, ACME natively intercepts challenges)
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS Server Block
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $DOMAIN www.$DOMAIN;

    # Nginx Native ACME — handles both apex and www automatically
    acme_certificate letsencrypt;
    ssl_certificate \$acme_certificate;
    ssl_certificate_key \$acme_certificate_key;

    root $WEB_ROOT/public;
    index index.php index.html;

    access_log $WEB_ROOT/logs/access.log;
    error_log  $WEB_ROOT/logs/error.log;

    client_max_body_size 128M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
EOF

# Conditionally inject PHP-FPM routing block
if [[ -n "$WITH_PHP" ]]; then
    cat << EOF >> /etc/nginx/conf.d/$DOMAIN.conf

    location ~ \.php$ {
        try_files \$uri =404;
        include fastcgi_params;
        fastcgi_pass unix:/run/php-fpm/$DOMAIN.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
EOF
fi

# Close the server block
cat << EOF >> /etc/nginx/conf.d/$DOMAIN.conf

    location ~ /\.          { deny all; }
    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt  { log_not_found off; access_log off; allow all; }
}
EOF

# --- 6. LOGROTATE CONFIGURATION ---
cat << EOF > /etc/logrotate.d/$DOMAIN
$WEB_ROOT/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 $USER_NAME nginx
    sharedscripts
    postrotate
        [ -f /run/nginx.pid ] && kill -USR1 \$(cat /run/nginx.pid)
    endscript
}
EOF

# --- 7. STATE & JSON RESPONSE UPDATES ---
REQUIRE_NGINX_RELOAD=1

MODULE_RESULT=$(echo "$MODULE_RESULT" | jq \
    --arg domain "$DOMAIN" \
    --arg ip "$SERVER_IP" \
    --arg user "$USER_NAME" \
    --arg root "$WEB_ROOT/public" \
    --arg key "$PRIVATE_KEY" \
    '. + {domain: $domain, server_ip: $ip, username: $user, web_root: $root, ssh_private_key: $key}')
