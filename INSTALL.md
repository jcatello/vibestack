#!/bin/bash
# Vibestack Fresh Install Runbook — AlmaLinux 9
# Run as root on a fresh LXD container

# =============================================================================
# STEP 1 — Install git and clone the repo
# =============================================================================
dnf install -y git

git clone https://github.com/jcatello/vibestack /opt/vibestack

# =============================================================================
# STEP 2 — Write vibestack.conf BEFORE running setup
# setup.sh sources common.sh which needs this file to exist.
# WPO normally writes this at deploy time — on a fresh manual install,
# create it now with your actual values.
# =============================================================================
mkdir -p /opt/vibestack/config
mkdir -p /opt/vibestack/logs

cat << 'EOF' > /opt/vibestack/config/vibestack.conf
SLACK_WEBHOOK_URL="https://n8n.bigscoots.dev/webhook/slack/add-message"
SLACK_TOKEN="e82e6baf-7942-43b7-b5c3-46e2dacb15a0"
CONTAINER_NAME="wpo-886fb14592ca4bc8995e168688ec0c9e"
SERVICE_ID="12345"
ZFS_NODE="vps194"
ZFS_LXD_BASE="vps194/lxd/containers"
EOF

chmod 600 /opt/vibestack/config/vibestack.conf
chmod 700 /opt/vibestack/config

# =============================================================================
# STEP 3 — Make scripts executable
# =============================================================================
chmod +x /opt/vibestack/vibestack-setup.sh
chmod +x /opt/vibestack/vibestack-api.sh
find /opt/vibestack/modules -name "*.sh" -exec chmod +x {} \;

# =============================================================================
# STEP 4 — Run setup
# =============================================================================
bash /opt/vibestack/vibestack-setup.sh

# =============================================================================
# STEP 5 — Verify
# =============================================================================
# Check nginx is up
systemctl status nginx --no-pager

# Check phpMyAdmin path (stored in vibestack.conf after setup)
source /opt/vibestack/config/vibestack.conf
echo "phpMyAdmin: https://$(hostname -f)/${PMA_PATH}/"
echo "PMA user:   $PMA_USER"
echo "PMA pass:   $PMA_PASS"

# Test the API returns valid JSON
bash /opt/vibestack/vibestack-api.sh \
    --action=system \
    --uid="$CONTAINER_NAME" \
    --sub-action=get_container_info | jq .