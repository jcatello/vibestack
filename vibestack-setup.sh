#!/bin/bash
# Vibe-Stack Pro: Base Server Provisioning (AlmaLinux 9)
# Mainline Edition with Native ACME & Hostname SSL
# Run this ONCE on a fresh OS before deploying the API.

# --- MANDATORY INCLUDES ---
[ -f /bigscoots/includes/common.sh ] && source /bigscoots/includes/common.sh

echo "===================================================="
echo "          VIBE-STACK GLOBAL SETUP (MAINLINE)        "
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

# 3. Install Base Dependencies (Includes native ACME, jq, and iptables for CSF)
dnf install -y nginx nginx-module-acme mariadb-server curl wget unzip \
               logrotate openssl ipset iptables perl-libwww-perl bind-utils \
               postfix jq

# 4. Load the ACME Module into Nginx
# Dynamic modules must be loaded at the very top of nginx.conf, outside of any blocks.
if ! grep -q "ngx_http_acme_module.so" /etc/nginx/nginx.conf; then
    sed -i '1iload_module modules/ngx_http_acme_module.so;' /etc/nginx/nginx.conf
fi

# 5. Standardized Paths
mkdir -p /usr/local/nginx/conf /home/nginx/domains
ln -s /etc/nginx/conf.d /usr/local/nginx/conf/conf.d

# PHP Socket Persistence (Fixes Alma9 tmpfs wipe on reboot)
echo "d /run/php-fpm 0755 nginx nginx -" > /etc/tmpfiles.d/php-fpm.conf
mkdir -p /run/php-fpm && chown nginx:nginx /run/php-fpm

# 6. Global HTTPS Redirect & Default ACME Handling
# Set up a default state directory for the native ACME client to store account keys
mkdir -p /var/lib/nginx/acme
chown nginx:nginx /var/lib/nginx/acme
chmod 700 /var/lib/nginx/acme

cat << 'EOF' > /etc/nginx/conf.d/00-default.conf
# Global ACME configuration
resolver 1.1.1.1 8.8.8.8 valid=300s;

acme_issuer LetEncrypt {
    uri https://acme-v02.api.letsencrypt.org/directory;
    state_path /var/lib/nginx/acme;
    accept_terms_of_service;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    
    # The native ACME module automatically intercepts HTTP-01 challenges on port 80
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

    acme_certificate LetEncrypt;
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

# 9. Start Base Services
# Starting Nginx here will automatically trigger the ACME module to fetch the hostname SSL
systemctl enable --now nginx mariadb postfix
csf -ra && systemctl restart lfd

# 10. API Directory Prep
mkdir -p /opt/vibestack/{modules,logs,config}

# 11. Phone Home Configuration
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

echo "===================================================="
echo "          SETUP COMPLETE. PHONING HOME...           "
echo "===================================================="
echo "$PHONE_HOME_JSON"
echo "===================================================="
echo "Nginx Version: $(nginx -v 2>&1)"
echo "You can now drop your API files into /opt/vibestack/"

# Placeholder for your actual WPO backend API call:
# curl -s -X POST "https://api.wpo.bigscoots.com/v1/server/register" \
#      -H "Content-Type: application/json" \
#      -H "Authorization: Bearer YOUR_TOKEN" \
#      -d "$PHONE_HOME_JSON"