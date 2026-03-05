#!/bin/bash
# Vibe-Stack Pro: The Fortress Edition (AlmaLinux 9)
# https://github.com/jcatello/vibestack

# --- 1. GLOBAL SETUP (Usage: ./vibestack.sh setup) ---
if [ "$1" == "setup" ]; then
    echo "===================================================="
    echo "          VIBE-STACK GLOBAL SETUP                   "
    echo "===================================================="
    
    # Install Base Dependencies
    dnf install -y epel-release
    dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm
    dnf install -y nginx mariadb-server curl wget unzip certbot python3-certbot-nginx logrotate openssl \
                   ipset perl-libwww-perl bind-utils postfix

    # Standardized Paths & Compatibility Links
    mkdir -p /usr/local/nginx/conf /home/nginx/domains
    ln -s /etc/nginx/conf.d /usr/local/nginx/conf/conf.d
    
    # PHP Socket Persistence (Fixes Alma9 tmpfs wipe on reboot)
    echo "d /run/php-fpm 0755 nginx nginx -" > /etc/tmpfiles.d/php-fpm.conf
    mkdir -p /run/php-fpm && chown nginx:nginx /run/php-fpm

    # Global HTTPS Redirect with ACME challenge bypass
    cat << 'EOF' > /etc/nginx/conf.d/00-default-redirect.conf
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    location /.well-known/acme-challenge/ { root /var/lib/letsencrypt/; }
    location / { return 301 https://$host$request_uri; }
}
EOF
    mkdir -p /var/lib/letsencrypt/

    # Install ConfigServer Security & Firewall (CSF)
    cd /usr/src && wget https://download.configserver.dev/csf.zip
    unzip -oq csf.zip && cd csf && sh install.sh
    
    # Configure CSF for Production + LXD Containers
    CONF="/etc/csf/csf.conf"
    sed -i 's/^TESTING = "1"/TESTING = "0"/' $CONF
    sed -i 's/^IPV6 = "1"/IPV6 = "0"/' $CONF # Disabling IPv6 fixes LXD kernel module errors
    sed -i 's/^LF_IPSET = "0"/LF_IPSET = "1"/' $CONF
    sed -i 's/^LF_IPSET_MAXELEM = .*/LF_IPSET_MAXELEM = "4000000"/' $CONF
    sed -i 's/^TCP_IN = .*/TCP_IN = "20,21,22,25,53,80,443,2222"/' $CONF
    
    # Enable High-Risk Blocklists
    BLOCK="/etc/csf/csf.blocklists"
    sed -i 's|^#CSF_MASTER|CSF_MASTER|' $BLOCK
    sed -i 's|^#CSF_HIGHRISK|CSF_HIGHRISK|' $BLOCK

    # Start Base Services
    systemctl enable --now nginx mariadb postfix
    csf -ra && systemctl restart lfd
    
    echo "Setup Complete. Vibe-Stack is armed."
    exit 0
fi

# --- 2. REMOVE SITE LOGIC (Usage: ./vibestack.sh remove domain.com) ---
if [ "$1" == "remove" ]; then
    DOMAIN=$2
    if [[ -z "$DOMAIN" ]]; then
        echo "Usage: ./vibestack.sh remove domain.com"
        exit 1
    fi

    USER_NAME=${DOMAIN//./_}
    WEB_ROOT="/home/nginx/domains/$DOMAIN"

    echo "WARNING: This will delete everything for $DOMAIN!"
    read -p "Are you sure? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi

    # Cleanup: PHP Pools, Nginx, DB, Logrotate, User
    find /etc/opt/remi/php*/php-fpm.d/ -name "$DOMAIN.conf" -delete
    rm -f "/etc/nginx/conf.d/$DOMAIN.conf"
    mysql -e "DROP DATABASE IF EXISTS ${USER_NAME:0:16};"
    mysql -e "DROP USER IF EXISTS '${USER_NAME:0:16}'@'localhost';"
    rm -f "/etc/logrotate.d/$DOMAIN"
    userdel -r "$USER_NAME"
    rm -rf "$WEB_ROOT"

    systemctl reload nginx
    echo "DELETED: $DOMAIN has been purged."
    exit 0
fi

# --- 3. ADD SITE LOGIC (Usage: ./vibestack.sh domain.com 8.4) ---
DOMAIN=$1
PHP_VER=$2

if [[ -z "$DOMAIN" || -z "$PHP_VER" ]]; then
    echo "Usage: ./vibestack.sh domain.com <php_version>"
    echo "Example: ./vibestack.sh example.com 8.4"
    exit 1
fi

USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"
PHP_PKG="php${PHP_VER//./}"
DB_NAME=${USER_NAME:0:16}
DB_PASS=$(openssl rand -base64 12)
SERVER_IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')

# Install Specific PHP Binary
dnf install -y ${PHP_PKG}-php-fpm ${PHP_PKG}-php-mysqlnd ${PHP_PKG}-php-opcache ${PHP_PKG}-php-gd ${PHP_PKG}-php-mbstring -y

# User & Permission Isolation
useradd -m -d "$WEB_ROOT" -s /bin/bash "$USER_NAME"
chmod 750 "$WEB_ROOT"
mkdir -p "$WEB_ROOT"/{public,logs,.ssh,ssl,tmp}
chown -R "$USER_NAME:$USER_NAME" "$WEB_ROOT"
usermod -a -G "$USER_NAME" nginx

# Automated ED25519 SSH Key
ssh-keygen -t ed25519 -f "$WEB_ROOT/.ssh/id_ed25519" -N "" -q
cat "$WEB_ROOT/.ssh/id_ed25519.pub" >> "$WEB_ROOT/.ssh/authorized_keys"
chown -R "$USER_NAME:$USER_NAME" "$WEB_ROOT/.ssh"
chmod 700 "$WEB_ROOT/.ssh" && chmod 600 "$WEB_ROOT/.ssh/authorized_keys"
PRIVATE_KEY=$(cat "$WEB_ROOT/.ssh/id_ed25519")

# Fortress PHP Pool Configuration
cat << EOF > /etc/opt/remi/${PHP_PKG}/php-fpm.d/$DOMAIN.conf
[$USER_NAME]
user = $USER_NAME
group = nginx
listen = /run/php-fpm/$DOMAIN.sock
listen.owner = nginx
listen.group = nginx
pm = ondemand
pm.max_children = 20
pm.max_requests = 2500
chdir = $WEB_ROOT/public
php_admin_value[open_basedir] = $WEB_ROOT/public:$WEB_ROOT/tmp:/usr/share:/tmp:/dev/urandom
php_admin_value[memory_limit] = 256M
EOF

# Database Setup
mysql -e "CREATE DATABASE ${DB_NAME};"
mysql -e "CREATE USER '${DB_NAME}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_NAME}'@'localhost';"

# Self-Signed SSL (Placeholder)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "$WEB_ROOT/ssl/selfsigned.key" -out "$WEB_ROOT/ssl/selfsigned.crt" -subj "/CN=$DOMAIN" > /dev/null 2>&1

# Nginx Vhost Configuration (HTTPS Only)
cat << EOF > /etc/nginx/conf.d/$DOMAIN.conf
server {
    listen 443 ssl;
    server_name $DOMAIN;
    root $WEB_ROOT/public;
    index index.php index.html;

    ssl_certificate $WEB_ROOT/ssl/selfsigned.crt;
    ssl_certificate_key $WEB_ROOT/ssl/selfsigned.key;
    
    client_max_body_size 128M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php-fpm/$DOMAIN.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

# Auto-Logrotate Config
cat << EOF > /etc/logrotate.d/$DOMAIN
$WEB_ROOT/logs/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    create 0640 $USER_NAME nginx
    postrotate
        /bin/kill -USR1 \$(cat /run/nginx.pid 2>/dev/null) 2>/dev/null || true
    endscript
}
EOF

# Restart & Cleanup
systemctl restart ${PHP_PKG}-php-fpm && systemctl reload nginx

clear
echo "===================================================="
echo "          VIBE-STACK SITE CREATED                   "
echo "===================================================="
echo "Domain:       $DOMAIN"
echo "IP Address:   $SERVER_IP"
echo "Username:     $USER_NAME"
echo "SSH Access:   ssh $USER_NAME@$SERVER_IP"
echo "----------------------------------------------------"
echo "DATABASE INFO:"
echo "DB Name/User: $DB_NAME"
echo "DB Password:  $DB_PASS"
echo "----------------------------------------------------"
echo "PRIVATE SSH KEY (ED25519):"
echo "$PRIVATE_KEY"
echo "----------------------------------------------------"
echo "Web Root: $WEB_ROOT/public"
echo "===================================================="