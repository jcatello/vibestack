#!/bin/bash
# /opt/vibestack/vibestack-setup.sh
# Vibe-Stack Pro: Base Server Provisioning (AlmaLinux 9)
# Mainline Edition with Native ACME & Hostname SSL

# --- 0. MANDATORY INCLUDES ---
source /opt/vibestack/includes/common.sh

echo "===================================================="
echo "        VIBE-STACK GLOBAL SETUP (MAINLINE)          "
echo "===================================================="

# 1. Add Official Nginx Repository (Mainline Branch)
cat << 'EOF' > /etc/yum.repos.d/nginx.repo
[nginx-mainline]
name=nginx mainline repo
baseurl=http://nginx.org/packages/mainline/centos/9/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF

# 2. Install Remi and EPEL Repositories
dnf install -y epel-release
dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm

# 3. Add MariaDB 11.4 LTS official repo (overrides AlmaLinux 9 default 10.5)
curl -LsS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup \
    | bash -s -- --mariadb-server-version=11.4 --skip-maxscale

# 4. Install Base Dependencies
dnf install -y nginx nginx-module-acme MariaDB-server MariaDB-client \
               curl wget unzip logrotate openssl ipset iptables \
               perl-libwww-perl bind-utils postfix jq python3

# 5. Load the ACME Module into Nginx
if ! grep -q "ngx_http_acme_module.so" /etc/nginx/nginx.conf; then
    sed -i '1iload_module modules/ngx_http_acme_module.so;' /etc/nginx/nginx.conf
fi

# Add server_names_hash_bucket_size to http block — required for long hostnames
# e.g. wpo-container-name.bigscoots-wpo.com
if ! grep -q "server_names_hash_bucket_size" /etc/nginx/nginx.conf; then
    sed -i '/http {/a\    server_names_hash_bucket_size 128;' /etc/nginx/nginx.conf
fi

# 6. Standardized Paths & Cleanup
mkdir -p /home/nginx/domains
rm -f /etc/nginx/conf.d/default.conf

# PHP Socket Persistence (Fixes AlmaLinux 9 tmpfs wipe on reboot)
echo "d /run/php-fpm 0755 nginx nginx -" > /etc/tmpfiles.d/php-fpm.conf
mkdir -p /run/php-fpm && chown nginx:nginx /run/php-fpm

# Redis socket persistence
echo "d /run/redis 0755 root root -" > /etc/tmpfiles.d/redis.conf
mkdir -p /run/redis

# 6. Global HTTPS Redirect & Native ACME State Directory
mkdir -p /var/lib/nginx/acme
chown nginx:nginx /var/lib/nginx/acme
chmod 700 /var/lib/nginx/acme

cat << 'EOF' > /etc/nginx/conf.d/00-default.conf
# Global ACME configuration
resolver 1.1.1.1 8.8.8.8 valid=300s ipv6=off;

acme_issuer letsencrypt {
    uri https://acme-v02.api.letsencrypt.org/directory;
    state_path /var/lib/nginx/acme;
    accept_terms_of_service;
}

# Global Port 80 catcher — ACME module intercepts challenges natively
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    location / {
        return 301 https://$host$request_uri;
    }
}
EOF

# 7. Hostname SSL Provisioning
SERVER_HOSTNAME=$(hostname -f)
if [[ -n "$SERVER_HOSTNAME" && "$SERVER_HOSTNAME" != "localhost" ]]; then
    cat << EOF > /etc/nginx/conf.d/01-hostname.conf
server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_HOSTNAME;
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $SERVER_HOSTNAME;

    acme_certificate letsencrypt;
    ssl_certificate \$acme_certificate;
    ssl_certificate_key \$acme_certificate_key;

    location / {
        default_type text/plain;
        return 200 "Vibe-Stack Host Node: $SERVER_HOSTNAME is online and secure.\n";
    }
}
EOF
fi

# 8. Install ConfigServer Security & Firewall (CSF)
cd /usr/src && wget https://download.configserver.dev/csf.zip
unzip -oq csf.zip && cd csf && sh install.sh

CONF="/etc/csf/csf.conf"
sed -i 's/^TESTING = "1"/TESTING = "0"/' $CONF
sed -i 's/^IPV6 = "1"/IPV6 = "0"/' $CONF
sed -i 's/^LF_IPSET = "0"/LF_IPSET = "1"/' $CONF
sed -i 's/^LF_IPSET_MAXELEM = .*/LF_IPSET_MAXELEM = "4000000"/' $CONF
sed -i 's/^TCP_IN = .*/TCP_IN = "20,21,22,25,53,80,443,2222"/' $CONF

BLOCK="/etc/csf/csf.blocklists"
sed -i 's|^#CSF_MASTER|CSF_MASTER|' $BLOCK
sed -i 's|^#CSF_HIGHRISK|CSF_HIGHRISK|' $BLOCK

# 9. Secure the Vibestack config file
chmod 600 /opt/vibestack/config/vibestack.conf
chmod 700 /opt/vibestack/config

# 9b. Set SSH to port 2222
# Use drop-in file so we don't modify the main sshd_config
echo "Port 2222" > /etc/ssh/sshd_config.d/99-vibestack.conf
chmod 600 /etc/ssh/sshd_config.d/99-vibestack.conf
systemctl restart sshd

# 10. Start Base Services
systemctl daemon-reload
systemctl enable --now nginx mariadb postfix
csf -ra && systemctl restart lfd

# Disable system PHP-FPM pools — vibestack uses per-domain units only.
systemctl stop php-fpm php84-php-fpm 2>/dev/null || true
systemctl disable php-fpm php84-php-fpm 2>/dev/null || true

# MariaDB: disable reverse DNS on connections
# MariaDB 11.4 config path varies — try both locations
MARIADB_CONF=""
[ -f /etc/my.cnf.d/server.cnf ] && MARIADB_CONF="/etc/my.cnf.d/server.cnf"
[ -f /etc/mysql/conf.d/mysql.cnf ] && MARIADB_CONF="/etc/mysql/conf.d/mysql.cnf"
[ -z "$MARIADB_CONF" ] && MARIADB_CONF="/etc/my.cnf.d/server.cnf" && mkdir -p /etc/my.cnf.d

if [[ -n "$MARIADB_CONF" ]] && ! grep -q "skip-name-resolve" "$MARIADB_CONF" 2>/dev/null; then
    cat << 'EOF' >> "$MARIADB_CONF"

[mysqld]
skip-name-resolve
innodb_buffer_pool_size = 128M
query_cache_type = 0
EOF
    systemctl restart mariadb
fi

# Global php symlink — points to php84 by default
ln -sf /opt/remi/php84/root/usr/bin/php /usr/bin/php

# 11. Install base PHP for phpMyAdmin
# phpMyAdmin needs a PHP-FPM pool to serve requests. We install php84 as the
# base system PHP and create a dedicated phpmyadmin pool. This is separate from
# any per-site pools created by core_php.sh — those get their own vs-php-* units.
echo "Installing base PHP 8.4 for phpMyAdmin..."
PMA_PHP_PKG="php84"
if ! rpm -q "${PMA_PHP_PKG}-php-fpm" >/dev/null 2>&1; then
    dnf install -y \
        "${PMA_PHP_PKG}-php-fpm" \
        "${PMA_PHP_PKG}-php-cli" \
        "${PMA_PHP_PKG}-php-mysqlnd" \
        "${PMA_PHP_PKG}-php-mbstring" \
        "${PMA_PHP_PKG}-php-xml" \
        "${PMA_PHP_PKG}-php-json" \
        "${PMA_PHP_PKG}-php-opcache" \
        >/dev/null 2>&1
fi

# Create phpmyadmin pool config
mkdir -p /etc/opt/remi/${PMA_PHP_PKG}/php-fpm.d/
cat << 'PHPEOF' > /etc/opt/remi/php84/php-fpm.d/phpmyadmin.conf
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
PHPEOF

# Create per-service master conf for phpMyAdmin (same pattern as per-domain sites)
PHP_PMA_LOG_DIR="/var/opt/remi/${PMA_PHP_PKG}/log/php-fpm"
mkdir -p "$PHP_PMA_LOG_DIR"

cat << 'MASTEREOF' > /etc/opt/remi/php84/vibestack-phpmyadmin.conf
[global]
error_log = /var/opt/remi/php84/log/php-fpm/phpmyadmin-error.log
daemonize = no

include=/etc/opt/remi/php84/php-fpm.d/phpmyadmin.conf
MASTEREOF

# Create dedicated systemd unit for phpMyAdmin PHP-FPM
# This avoids enabling the shared php84-php-fpm service which causes
# boot-time race conditions with per-domain vs-php-* units
cat << 'UNITEOF' > /etc/systemd/system/vs-php-phpmyadmin.service
[Unit]
Description=PHP-FPM pool for phpMyAdmin (vibestack)
After=network.target

[Service]
Type=notify
ExecStart=/opt/remi/php84/root/usr/sbin/php-fpm --nodaemonize --fpm-config /etc/opt/remi/php84/vibestack-phpmyadmin.conf
ExecReload=/bin/kill -USR2 $MAINPID
ExecStop=/bin/kill -SIGQUIT $MAINPID
KillMode=mixed
KillSignal=SIGQUIT
TimeoutStopSec=5
RuntimeDirectory=php-fpm
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable --now vs-php-phpmyadmin >/dev/null 2>&1

# Wait for socket
for i in {1..10}; do
    [ -S /run/php-fpm/phpmyadmin.sock ] && break
    sleep 1
done

chown nginx:nginx /run/php-fpm/phpmyadmin.sock 2>/dev/null || true
chmod 660 /run/php-fpm/phpmyadmin.sock 2>/dev/null || true

# 12. Install phpMyAdmin
source /opt/vibestack/modules/system/phpmyadmin.sh install
PMA_RESULT="$MODULE_RESULT"

# Re-source vibestack.conf to pick up PMA_PATH, PMA_USER, PMA_PASS
source /opt/vibestack/config/vibestack.conf

# 12. Phone Home
SERVER_IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')
CONTAINER_UUID=$(cat /etc/machine-id 2>/dev/null || echo "unknown-uuid")
INSTALL_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

PHONE_HOME_JSON=$(jq -n \
    --arg hostname "$SERVER_HOSTNAME" \
    --arg ip "$SERVER_IP" \
    --arg uuid "$CONTAINER_UUID" \
    --arg date "$INSTALL_DATE" \
    --arg pma_url "https://${SERVER_HOSTNAME}/${PMA_PATH}/" \
    --arg pma_user "$PMA_USER" \
    --arg pma_pass "$PMA_PASS" \
    '{
        success: true,
        errors: [],
        messages: ["Vibe-Stack base provisioning complete"],
        result: {
            hostname: $hostname,
            ip: $ip,
            lxd_uuid: $uuid,
            completed_at: $date,
            phpmyadmin: {
                url: $pma_url,
                basic_auth_user: $pma_user,
                basic_auth_pass: $pma_pass
            }
        }
    }')

THREAD_TS=$(send_slack_initial "✅ *Vibe-Stack Setup Complete* on \`$SERVER_HOSTNAME\` (\`$SERVER_IP\`)" "alerts")
send_slack_thread "$THREAD_TS" "\`\`\`$PHONE_HOME_JSON\`\`\`" "alerts"

echo "===================================================="
echo "        SETUP COMPLETE. PHONING HOME...             "
echo "===================================================="
echo "$PHONE_HOME_JSON"
echo "===================================================="
echo "Nginx Version: $(nginx -v 2>&1)"
echo "phpMyAdmin:    https://${SERVER_HOSTNAME}/${PMA_PATH}/"
echo "Vibestack is ready at /opt/vibestack/"
