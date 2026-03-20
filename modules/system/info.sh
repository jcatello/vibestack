#!/bin/bash
# /opt/vibestack/modules/system/info.sh
# Module: System & Container Monitoring
# Actions: get_resources, get_disk, get_services, get_processes,
#          restart_services, get_container_info

source /opt/vibestack/includes/common.sh

SYS_ACTION=$1
DOMAIN=$2
PAYLOAD=$3

[[ -z "$SYS_ACTION" ]] && fatal_error 5400 "System action missing"

case "$SYS_ACTION" in

    # -------------------------------------------------------------------------
    "get_resources")
        # CPU
        CPU_CORES=$(nproc)
        CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)

        # Memory
        MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
        MEM_USED=$(free -m | awk '/^Mem:/{print $3}')
        MEM_FREE=$(free -m | awk '/^Mem:/{print $4}')
        MEM_CACHED=$(free -m | awk '/^Mem:/{print $6}')
        MEM_PERCENT=$(echo "scale=1; $MEM_USED * 100 / $MEM_TOTAL" | bc 2>/dev/null || echo "0")

        # Load average
        LOAD_1=$(cat /proc/loadavg | awk '{print $1}')
        LOAD_5=$(cat /proc/loadavg | awk '{print $2}')
        LOAD_15=$(cat /proc/loadavg | awk '{print $3}')

        # Uptime
        UPTIME=$(uptime -p 2>/dev/null | sed 's/up //')

        MODULE_RESULT=$(jq -n \
            --argjson cpu_cores "$CPU_CORES" \
            --arg cpu_usage "$CPU_USAGE" \
            --argjson mem_total_mb "$MEM_TOTAL" \
            --argjson mem_used_mb "$MEM_USED" \
            --argjson mem_free_mb "$MEM_FREE" \
            --argjson mem_cached_mb "$MEM_CACHED" \
            --arg mem_usage_percent "$MEM_PERCENT" \
            --arg load_1min "$LOAD_1" \
            --arg load_5min "$LOAD_5" \
            --arg load_15min "$LOAD_15" \
            --arg uptime "$UPTIME" \
            --arg container "$CONTAINER_NAME" \
            '{
                container: $container,
                cpu: {cores: $cpu_cores, usage_percent: $cpu_usage},
                memory: {
                    total_mb: $mem_total_mb,
                    used_mb: $mem_used_mb,
                    free_mb: $mem_free_mb,
                    cached_mb: $mem_cached_mb,
                    usage_percent: $mem_usage_percent
                },
                load_average: {_1min: $load_1min, _5min: $load_5min, _15min: $load_15min},
                uptime: $uptime
            }')
        ;;

    # -------------------------------------------------------------------------
    "get_disk")
        # Overall disk
        DISK_TOTAL=$(df -BG / | awk 'NR==2{print $2}' | tr -d 'G')
        DISK_USED=$(df -BG /  | awk 'NR==2{print $3}' | tr -d 'G')
        DISK_FREE=$(df -BG /  | awk 'NR==2{print $4}' | tr -d 'G')
        DISK_PERCENT=$(df /   | awk 'NR==2{print $5}' | tr -d '%')

        # Per-domain breakdown if domain provided
        if [[ -n "$DOMAIN" ]]; then
            WEB_ROOT="/home/nginx/domains/$DOMAIN"
            DOMAIN_SIZE=$(du -sh "$WEB_ROOT/public" 2>/dev/null | cut -f1 || echo "0")
            DB_NAME="${DOMAIN//./_}"
            DB_NAME="${DB_NAME:0:16}"
            DB_SIZE=$(mysql -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) \
                FROM information_schema.tables WHERE table_schema='${DB_NAME}';" \
                --skip-column-names 2>/dev/null | tr -d '\n')
            LOG_SIZE=$(du -sh "$WEB_ROOT/logs" 2>/dev/null | cut -f1 || echo "0")
            BACKUP_SIZE=$(du -sh "$WEB_ROOT/backups" 2>/dev/null | cut -f1 || echo "0")
        fi

        MODULE_RESULT=$(jq -n \
            --arg container "$CONTAINER_NAME" \
            --arg domain "${DOMAIN:-}" \
            --argjson disk_total_gb "$DISK_TOTAL" \
            --argjson disk_used_gb "$DISK_USED" \
            --argjson disk_free_gb "$DISK_FREE" \
            --arg disk_usage_percent "$DISK_PERCENT" \
            --arg domain_files_size "${DOMAIN_SIZE:-n/a}" \
            --arg domain_db_size_mb "${DB_SIZE:-n/a}" \
            --arg domain_logs_size "${LOG_SIZE:-n/a}" \
            --arg domain_backups_size "${BACKUP_SIZE:-n/a}" \
            '{
                container: $container,
                domain: $domain,
                disk: {
                    total_gb: $disk_total_gb,
                    used_gb: $disk_used_gb,
                    free_gb: $disk_free_gb,
                    usage_percent: $disk_usage_percent
                },
                domain_usage: {
                    files: $domain_files_size,
                    database_mb: $domain_db_size_mb,
                    logs: $domain_logs_size,
                    backups: $domain_backups_size
                }
            }')
        ;;

    # -------------------------------------------------------------------------
    "get_services")
        check_service() {
            local svc=$1
            systemctl is-active "$svc" 2>/dev/null
        }

        NGINX_STATUS=$(check_service nginx)
        MARIADB_STATUS=$(check_service mariadb)

        # Detect PHP-FPM services
        PHP_SERVICES=$(systemctl list-units --type=service --state=active 2>/dev/null | \
            grep "php.*fpm" | awk '{print $1}' | jq -R . | jq -s .)

        # Detect Redis services for domains
        REDIS_SERVICES=$(systemctl list-units --type=service --state=active 2>/dev/null | \
            grep "redis-" | awk '{print $1}' | jq -R . | jq -s .)

        MODULE_RESULT=$(jq -n \
            --arg container "$CONTAINER_NAME" \
            --arg nginx "$NGINX_STATUS" \
            --arg mariadb "$MARIADB_STATUS" \
            --argjson php_fpm_services "$PHP_SERVICES" \
            --argjson redis_services "$REDIS_SERVICES" \
            '{
                container: $container,
                services: {
                    nginx: $nginx,
                    mariadb: $mariadb,
                    php_fpm: $php_fpm_services,
                    redis: $redis_services
                }
            }')
        ;;

    # -------------------------------------------------------------------------
    "restart_services")
        # PAYLOAD = comma-separated: "nginx,mariadb,php84-php-fpm"
        [[ -z "$PAYLOAD" ]] && fatal_error 5410 "Service list required"
        IFS=',' read -ra SERVICES <<< "$PAYLOAD"
        RESULTS="[]"
        for svc in "${SERVICES[@]}"; do
            svc=$(echo "$svc" | xargs)
            systemctl restart "$svc" >/dev/null 2>&1
            STATUS=$?
            RESULTS=$(echo "$RESULTS" | jq \
                --arg service "$svc" \
                --argjson success "$([ $STATUS -eq 0 ] && echo true || echo false)" \
                '. + [{service: $service, restarted: $success}]')
        done
        MODULE_RESULT=$(jq -n \
            --arg container "$CONTAINER_NAME" \
            --argjson results "$RESULTS" \
            '{container: $container, results: $results}')
        ;;

    # -------------------------------------------------------------------------
    "get_container_info")
        HOSTNAME=$(hostname -f)
        SERVER_IP=$(curl -s https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
        OS_VERSION=$(cat /etc/redhat-release 2>/dev/null || echo "unknown")
        KERNEL=$(uname -r)
        NGINX_VERSION=$(nginx -v 2>&1 | grep -oP 'nginx/\K[\d.]+')
        MARIADB_VERSION=$(mysql --version 2>/dev/null | grep -oP 'Distrib \K[\d.]+')
        PHP_VERSIONS=$(find /opt/remi/php*/root/usr/bin/php -type f 2>/dev/null | \
            while read -r bin; do $bin -r 'echo PHP_VERSION;' 2>/dev/null; done | \
            jq -R . | jq -s .)

        MODULE_RESULT=$(jq -n \
            --arg container "$CONTAINER_NAME" \
            --arg service_id "$SERVICE_ID" \
            --arg hostname "$HOSTNAME" \
            --arg ip "$SERVER_IP" \
            --arg os "$OS_VERSION" \
            --arg kernel "$KERNEL" \
            --arg nginx_version "$NGINX_VERSION" \
            --arg mariadb_version "$MARIADB_VERSION" \
            --argjson php_versions "$PHP_VERSIONS" \
            '{
                container: $container,
                service_id: $service_id,
                hostname: $hostname,
                ip: $ip,
                os: $os,
                kernel: $kernel,
                stack: {
                    nginx: $nginx_version,
                    mariadb: $mariadb_version,
                    php_versions: $php_versions
                }
            }')
        ;;

    *)
        fatal_error 5499 "Unknown system action: $SYS_ACTION. Valid: get_resources, get_disk, get_services, restart_services, get_container_info"
        ;;
esac
