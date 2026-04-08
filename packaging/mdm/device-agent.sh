#!/bin/bash
# =============================================================
# OncoFix Device Agent — Self-Hosted MDM Core
# =============================================================
# Runs as a systemd service (oncofix-agent.service).
# Every POLL_INTERVAL seconds:
#   1. Sends heartbeat to server
#   2. Polls for pending commands
#   3. Executes commands locally
#   4. Reports results back to server
#
# The device always initiates the connection — no inbound ports,
# no VPN, works through any NAT/firewall.
#
# Systemd unit: /etc/systemd/system/oncofix-agent.service
# =============================================================

set -uo pipefail

# ----------------------------------------------------------
# Configuration
# ----------------------------------------------------------
CONFIG_DIR="/etc/oncofix"
IDENTITY_FILE="$CONFIG_DIR/device-identity.json"
LOG_FILE="/var/log/oncofix/agent.log"
POLL_INTERVAL="${POLL_INTERVAL:-300}"  # 5 minutes
UPDATE_CHECK_INTERVAL="${UPDATE_CHECK_INTERVAL:-3600}"  # 1 hour

mkdir -p /var/log/oncofix

# ----------------------------------------------------------
# Read device identity
# ----------------------------------------------------------
if [ ! -f "$IDENTITY_FILE" ]; then
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") ERROR: No identity file found at $IDENTITY_FILE. Device not provisioned." >> "$LOG_FILE"
    exit 1
fi

DEVICE_ID=$(python3 -c "import json; print(json.load(open('$IDENTITY_FILE'))['deviceId'])" 2>/dev/null)
DEVICE_TOKEN=$(python3 -c "import json; print(json.load(open('$IDENTITY_FILE'))['deviceToken'])" 2>/dev/null)
SERVER_URL=$(python3 -c "import json; print(json.load(open('$IDENTITY_FILE'))['serverUrl'])" 2>/dev/null)

if [ -z "$DEVICE_ID" ] || [ -z "$DEVICE_TOKEN" ] || [ -z "$SERVER_URL" ]; then
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") ERROR: Invalid identity file. Missing deviceId, deviceToken, or serverUrl." >> "$LOG_FILE"
    exit 1
fi

log() {
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $1" >> "$LOG_FILE"
}

log "Agent started. Device=$DEVICE_ID, Server=$SERVER_URL, Interval=${POLL_INTERVAL}s"

# Track last update check time
LAST_UPDATE_CHECK=0

# ----------------------------------------------------------
# Gather device health info
# ----------------------------------------------------------
gather_health() {
    local BACKEND="down"
    local FRONTEND="down"
    local AI="down"
    local RABBITMQ="down"
    local DISK_USAGE=$(df /opt/oncofix --output=pcent 2>/dev/null | tail -1 | tr -d '% ' || echo "0")
    local MEMORY_USAGE=$(free | awk '/Mem:/{printf "%.0f", $3/$2 * 100}' 2>/dev/null || echo "0")
    local UPTIME=$(uptime -s 2>/dev/null || echo "unknown")
    local VERSION=$(dpkg-query -W -f='${Version}' oncofix 2>/dev/null || echo "unknown")

    systemctl is-active --quiet oncofix-backend 2>/dev/null && BACKEND="running"
    curl -sf --max-time 3 http://localhost:8082/healthz >/dev/null 2>&1 && FRONTEND="running"
    systemctl is-active --quiet oncofix-ai 2>/dev/null && AI="running"
    systemctl is-active --quiet rabbitmq-server 2>/dev/null && RABBITMQ="running"

    local UNSYNCED="0"
    local DB_FILE="/var/lib/oncofix/database.sqlite"
    [ ! -f "$DB_FILE" ] && DB_FILE="/opt/oncofix/oncofix_online_backend/database.sqlite"
    if [ -f "$DB_FILE" ]; then
        UNSYNCED=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM patients WHERE is_sync = 0;" 2>/dev/null || echo "0")
    fi

    cat << EOF
{
    "device_id": "$DEVICE_ID",
    "version": "$VERSION",
    "services": {
        "backend": "$BACKEND",
        "frontend": "$FRONTEND",
        "ai": "$AI",
        "rabbitmq": "$RABBITMQ"
    },
    "disk_usage_percent": $DISK_USAGE,
    "memory_usage_percent": $MEMORY_USAGE,
    "system_uptime": "$UPTIME",
    "unsynced_count": $UNSYNCED
}
EOF
}

# ----------------------------------------------------------
# 1. Send heartbeat
# ----------------------------------------------------------
send_heartbeat() {
    local HEALTH_DATA
    HEALTH_DATA=$(gather_health)

    local HTTP_CODE
    HTTP_CODE=$(curl -sf --max-time 15 -o /dev/null -w "%{http_code}" \
        -X POST "$SERVER_URL/devices/heartbeat" \
        -H "Content-Type: application/json" \
        -H "X-Device-ID: $DEVICE_ID" \
        -H "X-Device-Token: $DEVICE_TOKEN" \
        -d "$HEALTH_DATA" 2>/dev/null) || HTTP_CODE="000"

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
        log "Heartbeat sent OK"
    else
        log "WARN: Heartbeat failed (HTTP $HTTP_CODE)"
    fi
}

# ----------------------------------------------------------
# 2. Poll for commands
# ----------------------------------------------------------
poll_commands() {
    local RESPONSE
    RESPONSE=$(curl -sf --max-time 15 \
        -X GET "$SERVER_URL/devices/commands" \
        -H "X-Device-ID: $DEVICE_ID" \
        -H "X-Device-Token: $DEVICE_TOKEN" 2>/dev/null) || {
        log "WARN: Command poll failed"
        return
    }

    # Check if there are commands (response is a JSON array)
    local CMD_COUNT
    CMD_COUNT=$(echo "$RESPONSE" | python3 -c "import sys,json; cmds=json.load(sys.stdin); print(len(cmds) if isinstance(cmds, list) else 0)" 2>/dev/null || echo "0")

    if [ "$CMD_COUNT" = "0" ]; then
        return
    fi

    log "Received $CMD_COUNT command(s)"

    # Process each command
    echo "$RESPONSE" | python3 -c "
import sys, json
cmds = json.load(sys.stdin)
if isinstance(cmds, list):
    for cmd in cmds:
        print(json.dumps(cmd))
" 2>/dev/null | while IFS= read -r CMD_JSON; do
        execute_command "$CMD_JSON"
    done
}

# ----------------------------------------------------------
# 3. Execute a command
# ----------------------------------------------------------
execute_command() {
    local CMD_JSON="$1"
    local CMD_ID CMD_TYPE

    CMD_ID=$(echo "$CMD_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('command_id',''))" 2>/dev/null)
    CMD_TYPE=$(echo "$CMD_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('command_type',''))" 2>/dev/null)

    log "Executing command: $CMD_TYPE (id=$CMD_ID)"

    local STATUS="success"
    local OUTPUT=""

    case "$CMD_TYPE" in
        restart_backend)
            OUTPUT=$(sudo systemctl restart oncofix-backend 2>&1) || STATUS="failed"
            ;;
        restart_ai)
            OUTPUT=$(sudo systemctl restart oncofix-ai 2>&1) || STATUS="failed"
            ;;
        restart_all)
            OUTPUT=$(sudo systemctl restart oncofix-backend oncofix-ai 2>&1) || STATUS="failed"
            sudo systemctl reload nginx 2>/dev/null || true
            ;;
        reboot)
            report_command_result "$CMD_ID" "success" "Rebooting now..."
            sudo reboot
            return
            ;;
        update)
            local DEB_URL
            DEB_URL=$(echo "$CMD_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('deb_url',''))" 2>/dev/null)
            local CHECKSUM
            CHECKSUM=$(echo "$CMD_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('checksum',''))" 2>/dev/null)

            if [ -z "$DEB_URL" ]; then
                STATUS="failed"
                OUTPUT="No deb_url provided"
            else
                OUTPUT=$(DEB_URL="$DEB_URL" bash /opt/oncofix/update-device.sh 2>&1) || STATUS="failed"
            fi
            ;;
        upload_logs)
            local LOGS
            LOGS=$(journalctl -u oncofix-backend -u oncofix-ai --since "24 hours ago" --no-pager 2>/dev/null | tail -500)
            curl -sf --max-time 30 \
                -X POST "$SERVER_URL/devices/$DEVICE_ID/logs" \
                -H "Content-Type: application/json" \
                -H "X-Device-ID: $DEVICE_ID" \
                -H "X-Device-Token: $DEVICE_TOKEN" \
                -d "{\"logs\": $(echo "$LOGS" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)}" \
                >/dev/null 2>&1 || STATUS="failed"
            OUTPUT="Uploaded last 24h of logs"
            ;;
        run_healthcheck)
            OUTPUT=$(bash /opt/oncofix/health-check.sh 2>&1) || STATUS="failed"
            ;;
        *)
            STATUS="failed"
            OUTPUT="Unknown command type: $CMD_TYPE"
            ;;
    esac

    log "  Result: $STATUS"
    report_command_result "$CMD_ID" "$STATUS" "$OUTPUT"
}

# ----------------------------------------------------------
# 4. Report command result
# ----------------------------------------------------------
report_command_result() {
    local CMD_ID="$1"
    local STATUS="$2"
    local OUTPUT="$3"

    # Truncate output to 4KB to avoid huge payloads
    OUTPUT=$(echo "$OUTPUT" | head -c 4096)

    curl -sf --max-time 15 \
        -X POST "$SERVER_URL/devices/command-result" \
        -H "Content-Type: application/json" \
        -H "X-Device-ID: $DEVICE_ID" \
        -H "X-Device-Token: $DEVICE_TOKEN" \
        -d "{
            \"command_id\": \"$CMD_ID\",
            \"status\": \"$STATUS\",
            \"output\": $(echo "$OUTPUT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""')
        }" >/dev/null 2>&1 || log "WARN: Failed to report command result for $CMD_ID"
}

# ----------------------------------------------------------
# 5. Check for OTA updates (hourly)
# ----------------------------------------------------------
check_for_updates() {
    local NOW
    NOW=$(date +%s)
    local ELAPSED=$((NOW - LAST_UPDATE_CHECK))

    if [ "$ELAPSED" -lt "$UPDATE_CHECK_INTERVAL" ]; then
        return
    fi
    LAST_UPDATE_CHECK=$NOW

    local CURRENT_VERSION
    CURRENT_VERSION=$(dpkg-query -W -f='${Version}' oncofix 2>/dev/null || echo "0.0.0")

    local RESPONSE
    RESPONSE=$(curl -sf --max-time 15 \
        "$SERVER_URL/devices/update-check?current_version=$CURRENT_VERSION" \
        -H "X-Device-ID: $DEVICE_ID" \
        -H "X-Device-Token: $DEVICE_TOKEN" 2>/dev/null) || {
        log "WARN: Update check failed"
        return
    }

    local UPDATE_AVAILABLE
    UPDATE_AVAILABLE=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('update_available', False))" 2>/dev/null || echo "False")

    if [ "$UPDATE_AVAILABLE" = "True" ]; then
        local NEW_VERSION DEB_URL CHECKSUM MANDATORY
        NEW_VERSION=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version',''))" 2>/dev/null)
        DEB_URL=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('deb_url',''))" 2>/dev/null)
        CHECKSUM=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('checksum',''))" 2>/dev/null)
        MANDATORY=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('mandatory', False))" 2>/dev/null)

        log "Update available: $CURRENT_VERSION → $NEW_VERSION (mandatory=$MANDATORY)"

        if [ -n "$DEB_URL" ]; then
            log "Downloading and installing update..."
            local UPDATE_OUTPUT
            UPDATE_OUTPUT=$(DEB_URL="$DEB_URL" bash /opt/oncofix/update-device.sh 2>&1) || {
                log "ERROR: Update to $NEW_VERSION failed"
                return
            }
            log "Update to $NEW_VERSION complete"
        fi
    fi
}

# ----------------------------------------------------------
# Main loop
# ----------------------------------------------------------
while true; do
    send_heartbeat
    poll_commands
    check_for_updates

    sleep "$POLL_INTERVAL"
done
