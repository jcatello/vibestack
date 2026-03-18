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

# 3. Install Base Dependencies
dnf install -y nginx nginx-module-acme mariadb-server curl wget unzip \
               logrotate openssl ipset iptables perl-libwww-perl bind-utils \
               postfix jq

# 4. Load the ACME Module into Nginx
if ! grep -q "ngx_http_acme_module.so" /etc/nginx/nginx.conf; then
    sed -i '1iload_module modules/ngx_http_acme_module.so;' /etc/nginx/nginx.conf
fi

# 5. Standardized Paths & Cleanup
mkdir -p /home/nginx/domains
rm -f /etc/nginx/conf.d/default.conf

# PHP Socket Persistence (Fixes AlmaLinux 9 tmpfs wipe on reboot)
echo "d /run/php-fpm 0755 nginx nginx -" > /etc/tmpfiles.d/php-fpm.conf
mkdir -p /run/php-fpm && chown nginx:nginx /run/php-fpm

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

# 10. Start Base Services
systemctl enable --now nginx mariadb postfix
csf -ra && systemctl restart lfd

# 11. Phone Home
SERVER_IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')
CONTAINER_UUID=$(cat /etc/machine-id 2>/dev/null || echo "unknown-uuid")
INSTALL_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

PHONE_HOME_JSON=$(jq -n \
    --arg hostname "$SERVER_HOSTNAME" \
    --arg ip "$SERVER_IP" \
    --arg uuid "$CONTAINER_UUID" \
    --arg date "$INSTALL_DATE" \
    '{
        success: true,
        errors: [],
        messages: ["Vibe-Stack base provisioning complete"],
        result: {
            hostname: $hostname,
            ip: $ip,
            lxd_uuid: $uuid,
            completed_at: $date
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
echo "Vibestack is ready at /opt/vibestack/"