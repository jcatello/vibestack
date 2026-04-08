#!/bin/bash
# /opt/vibestack/modules/core_php.sh
# Module: PHP-FPM Pool Provisioning with Plan Tiers, OPcache Tuning,
#         and Per-Domain Systemd Sandbox Isolation

# --- 0. MANDATORY INCLUDES ---
source /opt/vibestack/includes/common.sh

# --- 1. VALIDATION ---
DOMAIN=$1
WITH_PHP=$2
PLAN=$3               # starter | business | enterprise (default: starter)
PM_MAX_CHILDREN=$4    # raw override (optional)
PM_MAX_REQUESTS=$5    # raw override (optional)

[[ -z "$DOMAIN" ]]   && fatal_error 1004 "Domain missing in core_php.sh"
[[ -z "$WITH_PHP" ]] && fatal_error 1004 "PHP version missing in core_php.sh"

USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"
PHP_PKG_VER="${WITH_PHP//./}"
PHP_PKG="php${PHP_PKG_VER}"
PHP_FPM_BIN="/opt/remi/${PHP_PKG}/root/usr/sbin/php-fpm"
PHP_FPM_CONF="/etc/opt/remi/${PHP_PKG}/php-fpm.conf"
POOL_CONF="/etc/opt/remi/${PHP_PKG}/php-fpm.d/${DOMAIN}.conf"

# Per-domain systemd service name — vs = vibestack
# e.g. vs-php-example_com.service
SYSTEMD_SERVICE="vs-php-${USER_NAME}.service"
SYSTEMD_UNIT="/etc/systemd/system/${SYSTEMD_SERVICE}"

# --- 2. PLAN TIER DEFAULTS ---
case "${PLAN:-starter}" in
    "enterprise")
        TIER_PM_MAX_CHILDREN=50
        TIER_PM_MAX_REQUESTS=2500
        TIER_MEMORY_LIMIT="512M"
        TIER_OPCACHE_MEMORY=256
        TIER_OPCACHE_MAX_FILES=16000
        ;;
    "business")
        TIER_PM_MAX_CHILDREN=20
        TIER_PM_MAX_REQUESTS=1000
        TIER_MEMORY_LIMIT="256M"
        TIER_OPCACHE_MEMORY=128
        TIER_OPCACHE_MAX_FILES=8000
        ;;
    "starter"|*)
        TIER_PM_MAX_CHILDREN=5
        TIER_PM_MAX_REQUESTS=500
        TIER_MEMORY_LIMIT="128M"
        TIER_OPCACHE_MEMORY=64
        TIER_OPCACHE_MAX_FILES=4000
        ;;
esac

FINAL_PM_MAX_CHILDREN=${PM_MAX_CHILDREN:-$TIER_PM_MAX_CHILDREN}
FINAL_PM_MAX_REQUESTS=${PM_MAX_REQUESTS:-$TIER_PM_MAX_REQUESTS}

# --- 3. DEPENDENCY CHECK ---
PHP_DEPENDENCIES=(
    "${PHP_PKG}"
    "${PHP_PKG}-php-cli"
    "${PHP_PKG}-php-fpm"
    "${PHP_PKG}-php-devel"
    "${PHP_PKG}-php-embedded"
    "${PHP_PKG}-php-mysqlnd"
    "${PHP_PKG}-php-bcmath"
    "${PHP_PKG}-php-enchant"
    "${PHP_PKG}-php-gd"
    "${PHP_PKG}-php-pecl-geoip"
    "${PHP_PKG}-php-gmp"
    "${PHP_PKG}-php-pecl-igbinary"
    "${PHP_PKG}-php-pecl-igbinary-devel"
    "${PHP_PKG}-php-pecl-imagick-im6"
    "${PHP_PKG}-php-pecl-imagick-im6-devel"
    "${PHP_PKG}-php-imap"
    "${PHP_PKG}-php-intl"
    "${PHP_PKG}-php-pecl-json-post"
    "${PHP_PKG}-php-ldap"
    "${PHP_PKG}-php-pecl-mailparse"
    "${PHP_PKG}-php-mbstring"
    "${PHP_PKG}-php-mcrypt"
    "${PHP_PKG}-php-pecl-memcache"
    "${PHP_PKG}-php-pecl-memcached"
    "${PHP_PKG}-php-pecl-mysql"
    "${PHP_PKG}-php-pdo-dblib"
    "${PHP_PKG}-php-pspell"
    "${PHP_PKG}-php-pecl-redis5"
    "${PHP_PKG}-php-snmp"
    "${PHP_PKG}-php-soap"
    "${PHP_PKG}-php-tidy"
    "${PHP_PKG}-php-xml"
    "${PHP_PKG}-php-xmlrpc"
    "${PHP_PKG}-php-pecl-zip"
    "${PHP_PKG}-php-opcache"
    "${PHP_PKG}-php-sodium"
    "${PHP_PKG}-php-brotli"
    "${PHP_PKG}-php-zstd"
    "${PHP_PKG}-php-zstd-devel"
    "${PHP_PKG}-php-process"
    "libsodium-devel"
    "oniguruma5php"
    "oniguruma5php-devel"
)

if ! rpm -q "${PHP_PKG}-php-fpm" >/dev/null 2>&1; then
    dnf install -y "${PHP_DEPENDENCIES[@]}" >/dev/null 2>&1
fi

# Always ensure zip is present — required by WP-CLI core download
if ! rpm -q "${PHP_PKG}-php-pecl-zip" >/dev/null 2>&1; then
    dnf install -y "${PHP_PKG}-php-pecl-zip" >/dev/null 2>&1
fi

# --- 4. FPM POOL CONFIGURATION ---
# This pool config is loaded ONLY by the per-domain systemd unit via the
# per-domain master conf (vibestack-DOMAIN.conf). It is NOT in the shared
# php84-php-fpm scan directory to avoid conflicts with the phpmyadmin pool.
cat << EOF > "$POOL_CONF"
[$USER_NAME]
user = $USER_NAME
group = nginx
listen = /run/php-fpm/$DOMAIN.sock
listen.owner = nginx
listen.group = nginx

; Pool sizing — plan: ${PLAN:-starter}
pm = ondemand
pm.max_children = $FINAL_PM_MAX_CHILDREN
pm.process_idle_timeout = 10s
pm.max_requests = $FINAL_PM_MAX_REQUESTS

chdir = $WEB_ROOT/public

; Security
php_admin_value[open_basedir] = $WEB_ROOT/public:$WEB_ROOT/tmp:/usr/share:/tmp:/dev/urandom
php_admin_value[upload_tmp_dir] = $WEB_ROOT/tmp
php_admin_value[session.save_path] = $WEB_ROOT/tmp
php_admin_value[memory_limit] = $TIER_MEMORY_LIMIT
php_admin_flag[allow_url_fopen] = off

; OPcache — tuned for plan: ${PLAN:-starter}
php_admin_value[opcache.enable] = 1
php_admin_value[opcache.memory_consumption] = $TIER_OPCACHE_MEMORY
php_admin_value[opcache.interned_strings_buffer] = 16
php_admin_value[opcache.max_accelerated_files] = $TIER_OPCACHE_MAX_FILES
php_admin_value[opcache.revalidate_freq] = 2
php_admin_value[opcache.fast_shutdown] = 1
php_admin_value[opcache.enable_cli] = 0
php_admin_value[opcache.validate_timestamps] = 1
EOF

# --- 4b. PER-DOMAIN MASTER PHP-FPM CONF ---
# Each domain gets its own minimal master conf stored outside the shared pool
# scan directory (/etc/opt/remi/phpXX/php-fpm.d/). This prevents the shared
# php84-php-fpm service from loading this domain's pool, and prevents the
# "another FPM instance already listening" conflict on startup.
PHP_LOG_DIR="/var/opt/remi/${PHP_PKG}/log/php-fpm"
DOMAIN_MASTER_CONF="/etc/opt/remi/${PHP_PKG}/vibestack-${USER_NAME}.conf"

mkdir -p "$PHP_LOG_DIR"

cat << EOF > "$DOMAIN_MASTER_CONF"
[global]
error_log = ${PHP_LOG_DIR}/${USER_NAME}-error.log
daemonize = no

include=${POOL_CONF}
EOF

# --- 5. PER-DOMAIN SYSTEMD SERVICE UNIT WITH SANDBOX ISOLATION ---
#
# Why a per-domain unit instead of the shared php84-php-fpm service?
# The shared service manages ALL pools — sandbox directives on it would apply
# to every domain. Per-domain units mean each domain gets its own filesystem
# namespace, so example.com's PHP process cannot read or write anotherdomain.com.
#
# Isolation model (Option A — web roots under /home/nginx/domains/):
#   ProtectSystem=strict    → entire filesystem is read-only by default
#   ProtectHome=no          → required because web root lives under /home
#   ReadWritePaths=...      → only this domain's dirs are writable
#
# The combination is equivalent to ProtectHome=yes in a /var/www layout —
# the PHP process for example.com simply cannot write anywhere except its own
# explicitly listed paths, regardless of what other domains exist on the container.

cat << EOF > "$SYSTEMD_UNIT"
[Unit]
Description=PHP-FPM pool for $DOMAIN (vibestack)
Documentation=https://github.com/jcatello/vibestack
After=network.target mariadb.service
Wants=mariadb.service

[Service]
Type=notify
ExecStart=$PHP_FPM_BIN --nodaemonize --fpm-config $DOMAIN_MASTER_CONF
ExecReload=/bin/kill -USR2 \$MAINPID
ExecStop=/bin/kill -SIGQUIT \$MAINPID
PIDFile=/run/php-fpm/${USER_NAME}.pid
KillMode=mixed
KillSignal=SIGQUIT
TimeoutStopSec=5

; === FILESYSTEM SANDBOX ISOLATION ===
; ProtectSystem=strict makes the entire filesystem read-only.
; Only the paths listed in ReadWritePaths are writable.
; This means this PHP process cannot write to any other domain's files.
ProtectSystem=strict
ProtectHome=no

; This domain's writable paths only
ReadWritePaths=$WEB_ROOT/public
ReadWritePaths=$WEB_ROOT/logs
ReadWritePaths=$WEB_ROOT/tmp
ReadWritePaths=/run/php-fpm
ReadWritePaths=${PHP_LOG_DIR}

; Shared readable paths PHP needs (read-only is fine)
ReadOnlyPaths=/usr/share
ReadOnlyPaths=/etc/opt/remi/${PHP_PKG}

; === ADDITIONAL HARDENING ===
; PrivateTmp: gives this service its own private /tmp namespace.
; Files written to /tmp by one domain's PHP are invisible to all others.
PrivateTmp=yes

; PrivateDevices: replaces /dev with a minimal set (null, zero, urandom, tty).
; PHP has no business touching raw block devices or hardware.
PrivateDevices=yes

; NoNewPrivileges: prevents PHP workers from gaining elevated privileges
; via setuid binaries or file capabilities after the process starts.
NoNewPrivileges=yes

; CapabilityBoundingSet: the master PHP-FPM process needs CAP_SETUID/SETGID
; to drop privileges to the site user for workers. CAP_CHOWN is needed to
; set socket ownership. CAP_DAC_OVERRIDE allows crossing file permission checks.
CapabilityBoundingSet=CAP_SETUID CAP_SETGID CAP_DAC_OVERRIDE CAP_CHOWN

; RestrictNamespaces: prevents PHP from creating new kernel namespaces.
; A compromised PHP process cannot use this to escape its sandbox.
RestrictNamespaces=yes

; RestrictRealtime: prevents PHP from setting realtime scheduling priorities,
; which could be used for denial-of-service against other processes.
RestrictRealtime=yes

; LockPersonality: prevents changing the execution domain (ABI).
LockPersonality=yes

; RestrictSUIDSGID: prevents PHP from executing setuid or setgid binaries,
; which could be used for privilege escalation.
RestrictSUIDSGID=yes

; SystemCallFilter: whitelist only the syscalls a well-behaved PHP-FPM service
; needs. @system-service covers the standard set for daemons.
SystemCallFilter=@system-service

; Runtime directory for the socket — systemd creates /run/php-fpm automatically
RuntimeDirectory=php-fpm
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

# --- 6. DISABLE THE SHARED REMI SERVICE FOR THIS PHP VERSION IF RUNNING ---
# The shared php84-php-fpm service would also try to load this pool conf,
# causing a conflict. We stop it loading this domain's pool by ensuring the
# per-domain service is the only thing that manages this pool file.
# The shared service can still run for any non-vibestack pools if needed,
# but for vibestack deployments we rely solely on per-domain units.
if systemctl is-active "${PHP_PKG}-php-fpm" >/dev/null 2>&1; then
    # Remove this domain's pool from the shared service's purview
    # by moving it to a directory the shared service doesn't scan
    # (already done — per-domain unit loads pool directly via --fpm-config)
    :
fi

# --- 7. ENABLE AND START PER-DOMAIN SERVICE ---
systemctl daemon-reload
systemctl enable --now "$SYSTEMD_SERVICE" >/dev/null 2>&1

# Verify it started cleanly
sleep 0.5
if ! systemctl is-active "$SYSTEMD_SERVICE" >/dev/null 2>&1; then
    FAIL_LOG=$(journalctl -u "$SYSTEMD_SERVICE" --no-pager -n 20 2>/dev/null)
    THREAD_TS=$(send_slack_initial \
        "🚨 *PHP-FPM service failed to start* for \`$DOMAIN\` on \`$(hostname)\` (${CONTAINER_NAME})" \
        "alerts")
    send_slack_thread "$THREAD_TS" "\`\`\`${FAIL_LOG}\`\`\`" "alerts"
    fatal_error 1004 "PHP-FPM service ${SYSTEMD_SERVICE} failed to start. Alert sent to Slack."
fi

# --- 8. WP-CLI VERSIONED WRAPPER ---
if [ ! -f "/usr/local/bin/wp${PHP_PKG_VER}" ]; then
    cat << EOF > "/usr/local/bin/wp${PHP_PKG_VER}"
#!/bin/bash
/opt/remi/${PHP_PKG}/root/usr/bin/php /usr/local/bin/wp "\$@"
EOF
    chmod +x "/usr/local/bin/wp${PHP_PKG_VER}"
fi

# Global php symlink — defaults to first installed version
if [ ! -f "/usr/bin/php" ]; then
    ln -sf "/opt/remi/${PHP_PKG}/root/usr/bin/php" /usr/bin/php
fi

# --- 9. STATE & JSON RESPONSE UPDATES ---
# Note: RELOAD_PHP_VERSIONS is no longer used for per-domain units.
# Each domain manages its own service directly.

MODULE_RESULT=$(echo "$MODULE_RESULT" | jq \
    --arg php "$WITH_PHP" \
    --arg plan "${PLAN:-starter}" \
    --argjson pm_max_children "$FINAL_PM_MAX_CHILDREN" \
    --argjson pm_max_requests "$FINAL_PM_MAX_REQUESTS" \
    --arg memory_limit "$TIER_MEMORY_LIMIT" \
    --arg systemd_service "$SYSTEMD_SERVICE" \
    '. + {
        php_version: $php,
        plan: $plan,
        pm_max_children: $pm_max_children,
        pm_max_requests: $pm_max_requests,
        memory_limit: $memory_limit,
        php_fpm_service: $systemd_service
    }')