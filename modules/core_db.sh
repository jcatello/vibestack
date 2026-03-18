#!/bin/bash
# /opt/vibestack/modules/core_db.sh
# Module: MariaDB Database & User Provisioning

# --- 0. MANDATORY INCLUDES ---
source /opt/vibestack/includes/common.sh

# --- 1. VALIDATION ---
DOMAIN=$1
[[ -z "$DOMAIN" ]] && fatal_error 1005 "Domain missing in core_db.sh"

USER_NAME=${DOMAIN//./_}
# MariaDB usernames capped at 16 chars for compatibility
DB_NAME=${USER_NAME:0:16}
DB_PASS=$(openssl rand -base64 16)

# --- 2. DATABASE CREATION ---
mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"
if [ $? -ne 0 ]; then
    fatal_error 500 "Failed to create database ${DB_NAME}."
fi

mysql -e "CREATE USER IF NOT EXISTS '${DB_NAME}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_NAME}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# --- 3. STATE & JSON RESPONSE UPDATES ---
MODULE_RESULT=$(echo "$MODULE_RESULT" | jq \
    --arg db_name "$DB_NAME" \
    --arg db_user "$DB_NAME" \
    --arg db_pass "$DB_PASS" \
    '. + {db_name: $db_name, db_user: $db_user, db_pass: $db_pass}')