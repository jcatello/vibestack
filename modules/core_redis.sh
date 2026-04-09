#!/bin/bash
# /opt/vibestack/modules/core_redis.sh
# Module: Per-Site Redis Instance (Unix Socket)
# One Redis instance per container, scoped to the site user via unix socket

# --- 0. MANDATORY INCLUDES ---
source /opt/vibestack/includes/common.sh

# --- 1. VALIDATION ---
DOMAIN=$1
[[ -z "$DOMAIN" ]] && fatal_error 1009 "Domain missing in core_redis.sh"

USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"
REDIS_SOCKET="/run/redis/${DOMAIN}.sock"
REDIS_CONF="/etc/redis/${DOMAIN}.conf"
REDIS_SERVICE="redis-${USER_NAME}"
REDIS_LOGFILE="/var/log/redis/${DOMAIN}.log"
REDIS_DATADIR="/var/lib/redis/${DOMAIN}"

# --- 2. INSTALL REDIS ---
if ! rpm -q redis >/dev/null 2>&1; then
    dnf install -y redis >/dev/null 2>&1
fi

# --- 3. DIRECTORY SETUP ---
mkdir -p /run/redis /etc/redis /var/log/redis "$REDIS_DATADIR"
chown "$USER_NAME:$USER_NAME" "$REDIS_DATADIR"
chown nginx:nginx /run/redis

# --- 4. PER-SITE REDIS CONFIGURATION ---
# Bound to unix socket only — no TCP port, no network exposure
cat << EOF > "$REDIS_CONF"
# Redis configuration for $DOMAIN
# Managed by vibestack — do not edit manually

# Network — unix socket only, no TCP
port 0
unixsocket $REDIS_SOCKET
unixsocketperm 770

# Security
requirepass $(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)

# Persistence — disabled for object cache use case
save ""
appendonly no

# Memory — capped per plan, evict LRU when full (ideal for WP object cache)
maxmemory 64mb
maxmemory-policy allkeys-lru

# Logging
loglevel notice
logfile $REDIS_LOGFILE

# Data directory
dir $REDIS_DATADIR

# Daemonize — handled by systemd
daemonize no
EOF

# Capture the generated password for the JSON response
REDIS_PASSWORD=$(grep "requirepass" "$REDIS_CONF" | awk '{print $2}')

# Set permissions — only site user and nginx can access
chown "${USER_NAME}:nginx" "$REDIS_CONF"
chmod 640 "$REDIS_CONF"

# --- 5. SYSTEMD SERVICE (per-site instance) ---
cat << EOF > "/etc/systemd/system/${REDIS_SERVICE}.service"
[Unit]
Description=Redis (per-site) for $DOMAIN
After=network.target

[Service]
Type=simple
User=$USER_NAME
Group=nginx
ExecStart=/usr/bin/redis-server $REDIS_CONF
Restart=on-failure
RestartSec=5

RuntimeDirectory=redis
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${REDIS_SERVICE}" >/dev/null 2>&1

# Set socket ownership after service starts
sleep 1
chown "${USER_NAME}:nginx" "$REDIS_SOCKET" 2>/dev/null || true
chmod 660 "$REDIS_SOCKET" 2>/dev/null || true

# --- 6. STATE & JSON RESPONSE UPDATES ---
MODULE_RESULT=$(echo "$MODULE_RESULT" | jq \
    --arg redis_socket "$REDIS_SOCKET" \
    --arg redis_password "$REDIS_PASSWORD" \
    --arg redis_service "$REDIS_SERVICE" \
    '. + {
        redis_socket: $redis_socket,
        redis_password: $redis_password,
        redis_service: $redis_service
    }')
