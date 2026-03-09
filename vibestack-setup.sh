#!/bin/bash
# Vibe-Stack Pro: Base Server Provisioning (AlmaLinux 9)
# Mainline Edition with Native ACME Support
# Run this ONCE on a fresh OS before deploying the API.

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

# 3. Install Base Dependencies (Replaced Certbot with native ACME module)
dnf install -y nginx nginx-module-acme mariadb-server curl wget unzip \
               logrotate openssl ipset perl-libwww-perl bind-utils \
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
# We set up a default state directory for the native ACME client to store account keys
mkdir -p /var/lib/nginx/acme
chown nginx:nginx /var/lib/nginx/acme
chmod 700 /var/lib/nginx/acme

cat << 'EOF' > /etc/nginx/conf.d/00-default.conf
# Global ACME configuration
acme_client LetEncrypt https://acme-v02.api.letsencrypt.org/directory;
acme_state_dir /var/lib/nginx/acme;

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    
    # Let Nginx handle the ACME challenge natively, then redirect everything else
    location /.well-known/acme-challenge/ { 
        acme_challenge LetEncrypt; 
    }
    
    location / { 
        return 301 https://$host$request_uri; 
    }
}
EOF

# 7. Install ConfigServer Security & Firewall (CSF)
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

# 8. Start Base Services
systemctl enable --now nginx mariadb postfix
csf -ra && systemctl restart lfd

# 9. API Directory Prep
mkdir -p /opt/vibestack/{modules,logs,config}

echo "===================================================="
echo "Setup Complete."
echo "Nginx Version: $(nginx -v 2>&1)"
echo "You can now drop your API files into /opt/vibestack/"
echo "===================================================="