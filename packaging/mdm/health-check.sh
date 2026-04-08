#!/bin/bash
# =============================================================
# OncoFix Device Health Check
# =============================================================
# Run periodically via MDM to monitor device health.
# Outputs JSON for MDM dashboard ingestion.
#
# Usage: bash health-check.sh
# Cron:  */5 * * * * /opt/oncofix/health-check.sh >> /var/log/oncofix/health.log
# =============================================================

REPORT_URL="${REPORT_URL:-}"

# Gather status
BACKEND="down"
FRONTEND="down"
AI="down"
RABBITMQ="down"
DISK_USAGE=$(df /opt/oncofix --output=pcent 2>/dev/null | tail -1 | tr -d '% ')
MEMORY_USAGE=$(free | awk '/Mem:/{printf "%.0f", $3/$2 * 100}')
UPTIME=$(uptime -s 2>/dev/null || echo "unknown")
DB_SIZE="0"
UNSYNCED="0"

# Check services
systemctl is-active --quiet oncofix-backend && BACKEND="running"
curl -sf http://localhost:8082/healthz >/dev/null 2>&1 && FRONTEND="running"
systemctl is-active --quiet oncofix-ai && AI="running"
systemctl is-active --quiet rabbitmq-server && RABBITMQ="running"

# Check database
DB_FILE="/var/lib/oncofix/database.sqlite"
if [ ! -f "$DB_FILE" ]; then
    DB_FILE="/opt/oncofix/oncofix_online_backend/database.sqlite"
fi
if [ -f "$DB_FILE" ]; then
    DB_SIZE=$(du -h "$DB_FILE" | cut -f1)
    UNSYNCED=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM patients WHERE is_sync = 0;" 2>/dev/null || echo "unknown")
fi

# Device info
DEVICE_ID="unknown"
if [ -f /etc/oncofix/device-info.json ]; then
    DEVICE_ID=$(python3 -c "import json; print(json.load(open('/etc/oncofix/device-info.json'))['deviceId'])" 2>/dev/null || echo "unknown")
fi

# Build JSON report
REPORT=$(cat << EOF
{
    "deviceId": "${DEVICE_ID}",
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "hostname": "$(hostname)",
    "ip": "$(hostname -I | awk '{print $1}')",
    "services": {
        "backend": "${BACKEND}",
        "frontend": "${FRONTEND}",
        "ai": "${AI}",
        "rabbitmq": "${RABBITMQ}"
    },
    "resources": {
        "diskUsagePercent": ${DISK_USAGE:-0},
        "memoryUsagePercent": ${MEMORY_USAGE:-0},
        "systemUptime": "${UPTIME}"
    },
    "database": {
        "size": "${DB_SIZE}",
        "unsyncedRecords": "${UNSYNCED}"
    },
    "packageVersion": "$(dpkg-query -W -f='${Version}' oncofix 2>/dev/null || echo 'unknown')"
}
EOF
)

echo "$REPORT"

# Send to central server if configured
if [ -n "$REPORT_URL" ]; then
    curl -sf -X POST "$REPORT_URL" \
        -H "Content-Type: application/json" \
        -d "$REPORT" >/dev/null 2>&1 || true
fi
