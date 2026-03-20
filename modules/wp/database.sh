#!/bin/bash
# /opt/vibestack/modules/wp/database.sh
# Module: WordPress Database Operations
# Actions: export, import, optimize, repair, info, run_query, reset

source /opt/vibestack/includes/common.sh

WP_ACTION=$1
DOMAIN=$2
PAYLOAD=$3    # file path or SQL query or JSON depending on action

[[ -z "$WP_ACTION" ]] && fatal_error 4400 "DB action missing"
[[ -z "$DOMAIN" ]]    && fatal_error 4401 "Domain missing in database.sh"

USER_NAME=${DOMAIN//./_}
WEB_ROOT="/home/nginx/domains/$DOMAIN"
DB_NAME=${USER_NAME:0:16}
PHP_BIN=$(find /opt/remi/php*/root/usr/bin/php -type f 2>/dev/null | sort -V | tail -1)
WP_BIN="/usr/local/bin/wp"
BACKUP_DIR="/home/nginx/domains/$DOMAIN/backups/db"

mkdir -p "$BACKUP_DIR"
chown -R "${USER_NAME}:${USER_NAME}" "$BACKUP_DIR"

wp_run() {
    sudo -u "$USER_NAME" \
        PHP_BINARY="$PHP_BIN" \
        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "$PHP_BIN" "$WP_BIN" "$@" \
        --path="$WEB_ROOT/public" \
        --allow-root \
        2>&1
}

case "$WP_ACTION" in

    # -------------------------------------------------------------------------
    "export")
        TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
        EXPORT_FILE="$BACKUP_DIR/${DOMAIN}-${TIMESTAMP}.sql.gz"
        wp_run db export - | gzip > "$EXPORT_FILE"
        STATUS=$?
        FILESIZE=$(du -sh "$EXPORT_FILE" 2>/dev/null | cut -f1 || echo "unknown")
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg file "$EXPORT_FILE" \
            --arg size "$FILESIZE" \
            --arg exported_at "$TIMESTAMP" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, export_file: $file, file_size: $size, exported_at: $exported_at}')
        ;;

    # -------------------------------------------------------------------------
    "import")
        # PAYLOAD = full path to .sql or .sql.gz file
        [[ -z "$PAYLOAD" ]] && fatal_error 4410 "File path required for import"
        [[ ! -f "$PAYLOAD" ]] && fatal_error 4411 "Import file not found: $PAYLOAD"

        if [[ "$PAYLOAD" == *.gz ]]; then
            OUT=$(gunzip -c "$PAYLOAD" | wp_run db import -)
        else
            OUT=$(wp_run db import "$PAYLOAD")
        fi
        STATUS=$?

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg file "$PAYLOAD" \
            --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, imported_file: $file, output: $output}')
        ;;

    # -------------------------------------------------------------------------
    "optimize")
        OUT=$(wp_run db optimize)
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, output: $output}')
        ;;

    # -------------------------------------------------------------------------
    "repair")
        OUT=$(wp_run db repair)
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, output: $output}')
        ;;

    # -------------------------------------------------------------------------
    "info")
        RAW=$(wp_run db size --tables --format=json 2>/dev/null)
        DB_SIZE=$(wp_run db size --format=json 2>/dev/null | jq -r '.size // "unknown"')
        TABLE_COUNT=$(mysql -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" \
            --skip-column-names 2>/dev/null || echo "0")
        WP_PREFIX=$(wp_run config get table_prefix 2>/dev/null | tr -d '\n')

        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --arg db_name "$DB_NAME" \
            --arg db_size "$DB_SIZE" \
            --arg table_count "${TABLE_COUNT:-0}" \
            --arg table_prefix "${WP_PREFIX:-wp_}" \
            '{domain: $domain, db_name: $db_name, db_size: $db_size, table_count: $table_count, table_prefix: $table_prefix}')
        ;;

    # -------------------------------------------------------------------------
    "run_query")
        # PAYLOAD = SQL query string (use with caution — portal should validate)
        [[ -z "$PAYLOAD" ]] && fatal_error 4412 "SQL query required"
        # Block destructive operations unless explicitly allowed
        if echo "$PAYLOAD" | grep -iqE '^\s*(DROP\s+DATABASE|DROP\s+TABLE|TRUNCATE)'; then
            fatal_error 4413 "Destructive SQL operation blocked. Use specific API actions instead."
        fi
        OUT=$(mysql "$DB_NAME" -e "$PAYLOAD" 2>&1)
        STATUS=$?
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" --arg query "$PAYLOAD" --arg output "$OUT" \
            --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
            '{domain: $domain, success: $success, query: $query, output: $output}')
        ;;

    # -------------------------------------------------------------------------
    "list_exports")
        FILES=$(ls -1t "$BACKUP_DIR"/*.sql.gz 2>/dev/null || echo "")
        if [[ -z "$FILES" ]]; then
            EXPORT_LIST="[]"
        else
            EXPORT_LIST="["
            FIRST=true
            while IFS= read -r file; do
                SIZE=$(du -sh "$file" | cut -f1)
                MTIME=$(stat -c %y "$file" | cut -d'.' -f1)
                FNAME=$(basename "$file")
                [[ "$FIRST" == "true" ]] && FIRST=false || EXPORT_LIST+=","
                EXPORT_LIST+="{\"file\":\"$FNAME\",\"path\":\"$file\",\"size\":\"$SIZE\",\"created\":\"$MTIME\"}"
            done <<< "$FILES"
            EXPORT_LIST+="]"
        fi
        COUNT=$(echo "$EXPORT_LIST" | jq 'length')
        MODULE_RESULT=$(jq -n \
            --arg domain "$DOMAIN" \
            --argjson count "$COUNT" \
            --argjson exports "$EXPORT_LIST" \
            '{domain: $domain, export_count: $count, exports: $exports}')
        ;;

    *)
        fatal_error 4499 "Unknown DB action: $WP_ACTION. Valid: export, import, optimize, repair, info, run_query, list_exports"
        ;;
esac
