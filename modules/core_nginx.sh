#!/bin/bash
# /opt/vibestack/modules/core_nginx.sh
# Module: Base User, Directory, SSH, and Nginx Vhost Setup

# --- 0. MANDATORY INCLUDES ---
[ -f /bigscoots/includes/common.sh ] && source /bigscoots/includes/common.sh

# --- 1. VALIDATION ---
DOMAIN=$1
[[ -z "$DOMAIN" ]] && fatal_error 1003 "Domain parameter missing in core_nginx.sh"

# --- 2. VARIABLES ---
USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"
SERVER_IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')

# --- 3. LINUX USER & ISOLATION ---
if ! id "$USER_NAME" &>/dev/null; then
    useradd -m -d "$WEB_ROOT" -s /bin/bash "$USER_NAME"
fi

# Ensure the nginx service can read the user's files
usermod -a -G "$USER_NAME" nginx

# Create the Fortress directory structure
mkdir -p "$WEB_ROOT"/{public,logs,.ssh,ssl,tmp}

# --- 4. SSH KEY GENERATION (ED25519) ---
if [ ! -f "$WEB_ROOT/.ssh/id_ed25519" ]; then
    ssh-keygen -t ed25519 -f "$WEB_ROOT/.ssh/id_ed25519" -N "" -q
    cat "$WEB_ROOT/.ssh/id_ed25519.pub" >> "$WEB_ROOT/.ssh/authorized_keys"
    chmod 700 "$WEB_ROOT/.ssh"
    chmod 600 "$WEB_ROOT/.ssh/authorized_keys"
fi

PRIVATE_KEY=$(cat "$WEB_ROOT/.ssh/id_ed25519")

# --- 5. SSL PLACEHOLDER (Self-Signed) ---
if [ ! -f "$WEB_ROOT/ssl/selfsigned.crt" ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$WEB_ROOT/ssl/selfsigned.key" \
        -out "$WEB_ROOT/ssl/selfsigned.crt" \
        -subj "/CN=$DOMAIN" > /dev/null 2>&1
fi

# Apply ownership to all generated files
chown -R "$USER_NAME:$USER_NAME" "$WEB_ROOT"

# Lock down the web root (750 ensures only the user and the nginx group can enter)
chmod 750 "$WEB_ROOT"

# --- 6. NGINX VHOST CONFIGURATION ---
# We build the config dynamically based on what the router requested
cat << EOF > /etc/nginx/conf.d/$DOMAIN.conf
server {
    listen 443 ssl;
    server_name $DOMAIN;
    root $WEB_ROOT/public;
    index index.php index.html;

    ssl_certificate $WEB_ROOT/ssl/selfsigned.crt;
    ssl_certificate_key $WEB_ROOT/ssl/selfsigned.key;
    
    access_log $WEB_ROOT/logs/access.log;
    error_log $WEB_ROOT/logs/error.log;

    client_max_body_size 128M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
EOF

# Conditionally inject PHP-FPM routing only if PHP was requested
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

# Close out the server block with standard security defaults
cat << EOF >> /etc/nginx/conf.d/$DOMAIN.conf

    location ~ /\. { deny all; }
    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt { log_not_found off; access_log off; allow all; }
}
EOF

# --- 7. LOGROTATE CONFIGURATION ---
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

# --- 8. STATE & JSON RESPONSE UPDATES ---
# Flag the router to reload Nginx at the end of the run
REQUIRE_NGINX_RELOAD=1

# Safely inject the new data into the master MODULE_RESULT JSON object using jq
MODULE_RESULT=$(echo "$MODULE_RESULT" | jq \
    --arg domain "$DOMAIN" \
    --arg ip "$SERVER_IP" \
    --arg user "$USER_NAME" \
    --arg root "$WEB_ROOT/public" \
    --arg key "$PRIVATE_KEY" \
    '. + {domain: $domain, server_ip: $ip, username: $user, web_root: $root, ssh_private_key: $key}')