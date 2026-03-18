#!/bin/bash
# /opt/vibestack/modules/core_php.sh
# Module: PHP-FPM Pool Provisioning with Plan Tiers & OPcache Tuning

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

# --- 2. PLAN TIER DEFAULTS ---
# These are tuned for single-domain LXD containers on ZFS
# Overridden by raw values if passed
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

# Apply raw overrides if provided
FINAL_PM_MAX_CHILDREN=${PM_MAX_CHILDREN:-$TIER_PM_MAX_CHILDREN}
FINAL_PM_MAX_REQUESTS=${PM_MAX_REQUESTS:-$TIER_PM_MAX_REQUESTS}

# --- 3. DEPENDENCY CHECK (Enterprise Package List) ---
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

# Install full package list if FPM is missing
if ! rpm -q "${PHP_PKG}-php-fpm" >/dev/null 2>&1; then
    dnf install -y "${PHP_DEPENDENCIES[@]}" >/dev/null 2>&1
fi

# Always ensure zip is present — required by WP-CLI core download
# May be missing if PHP was pre-installed before this package was added
if ! rpm -q "${PHP_PKG}-php-pecl-zip" >/dev/null 2>&1; then
    dnf install -y "${PHP_PKG}-php-pecl-zip" >/dev/null 2>&1
fi

# --- 4. FPM POOL CONFIGURATION ---
cat << EOF > /etc/opt/remi/${PHP_PKG}/php-fpm.d/$DOMAIN.conf
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

# --- 5. WP-CLI VERSIONED WRAPPER ---
if [ ! -f "/usr/local/bin/wp${PHP_PKG_VER}" ]; then
    cat << EOF > "/usr/local/bin/wp${PHP_PKG_VER}"
#!/bin/bash
/opt/remi/${PHP_PKG}/root/usr/bin/php /usr/local/bin/wp "\$@"
EOF
    chmod +x "/usr/local/bin/wp${PHP_PKG_VER}"
fi

# Ensure a global 'php' symlink exists (defaults to first installed version)
if [ ! -f "/usr/bin/php" ]; then
    ln -sf "/opt/remi/${PHP_PKG}/root/usr/bin/php" /usr/bin/php
fi

# --- 6. STATE & JSON RESPONSE UPDATES ---
RELOAD_PHP_VERSIONS+=" $PHP_PKG_VER"

MODULE_RESULT=$(echo "$MODULE_RESULT" | jq \
    --arg php "$WITH_PHP" \
    --arg plan "${PLAN:-starter}" \
    --argjson pm_max_children "$FINAL_PM_MAX_CHILDREN" \
    --argjson pm_max_requests "$FINAL_PM_MAX_REQUESTS" \
    --arg memory_limit "$TIER_MEMORY_LIMIT" \
    '. + {
        php_version: $php,
        plan: $plan,
        pm_max_children: $pm_max_children,
        pm_max_requests: $pm_max_requests,
        memory_limit: $memory_limit
    }')