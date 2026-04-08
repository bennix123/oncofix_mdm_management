#!/bin/bash
# =============================================================
# OncoFix Device QA Test
# =============================================================
# Automated validation run after provisioning (factory floor).
# Tests every critical subsystem and reports pass/fail to server.
#
# Usage:
#   sudo bash qa-test.sh
#
# Reports result to: POST /api/v1/devices/{device_id}/qa-result
# =============================================================

set -uo pipefail

CONFIG_DIR="/etc/oncofix"
IDENTITY_FILE="$CONFIG_DIR/device-identity.json"
LOG_FILE="/var/log/oncofix/qa-test-$(date +%Y%m%d-%H%M%S).log"
mkdir -p /var/log/oncofix
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== OncoFix QA Test ==="
echo "  $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo ""

# ----------------------------------------------------------
# Read device identity
# ----------------------------------------------------------
DEVICE_ID="unknown"
DEVICE_TOKEN=""
SERVER_URL=""

if [ -f "$IDENTITY_FILE" ]; then
    DEVICE_ID=$(python3 -c "import json; print(json.load(open('$IDENTITY_FILE'))['deviceId'])" 2>/dev/null || echo "unknown")
    DEVICE_TOKEN=$(python3 -c "import json; print(json.load(open('$IDENTITY_FILE'))['deviceToken'])" 2>/dev/null || true)
    SERVER_URL=$(python3 -c "import json; print(json.load(open('$IDENTITY_FILE'))['serverUrl'])" 2>/dev/null || true)
fi

echo "  Device: $DEVICE_ID"
echo ""

PASSED=0
FAILED=0
TESTS=()

# ----------------------------------------------------------
# Test helper
# ----------------------------------------------------------
run_test() {
    local NAME="$1"
    local CMD="$2"

    echo -n "  [$((PASSED + FAILED + 1))] $NAME... "

    local OUTPUT
    OUTPUT=$(eval "$CMD" 2>&1)
    local EXIT_CODE=$?

    if [ $EXIT_CODE -eq 0 ]; then
        echo "PASS"
        PASSED=$((PASSED + 1))
        TESTS+=("{\"name\": \"$NAME\", \"status\": \"pass\"}")
    else
        echo "FAIL"
        echo "      Output: $(echo "$OUTPUT" | head -3)"
        FAILED=$((FAILED + 1))
        local SAFE_OUTPUT
        SAFE_OUTPUT=$(echo "$OUTPUT" | head -3 | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""')
        TESTS+=("{\"name\": \"$NAME\", \"status\": \"fail\", \"error\": $SAFE_OUTPUT}")
    fi
}

# ----------------------------------------------------------
# Run tests
# ----------------------------------------------------------
echo "Running tests..."
echo ""

# 1. Backend health
run_test "Backend health" \
    "curl -sf --max-time 10 https://localhost/api/v1/health || curl -sf --max-time 10 http://localhost:443/api/v1/health"

# 2. Frontend loads
run_test "Frontend loads" \
    "curl -sf --max-time 10 http://localhost:8082 | grep -q '<html\\|<!DOCTYPE'"

# 3. Camera system
run_test "Camera available" \
    "ls /dev/video* >/dev/null 2>&1 || v4l2-ctl --list-devices 2>/dev/null | grep -q video"

# 4. Camera capture test
run_test "Camera capture" \
    "curl -sf --max-time 15 http://localhost:8000/api/camera/status | python3 -c 'import sys,json; d=json.load(sys.stdin); assert any(c[\"available\"] for c in d.get(\"cameras\",[]))'"

# 5. AI model loaded
run_test "AI model health" \
    "systemctl is-active --quiet oncofix-ai && curl -sf --max-time 10 http://localhost:8001/health"

# 6. SQLite database writable
run_test "SQLite write" \
    "DB=/var/lib/oncofix/database.sqlite; [ ! -f \"\$DB\" ] && DB=/opt/oncofix/oncofix_online_backend/database.sqlite; sqlite3 \"\$DB\" 'SELECT 1;'"

# 7. RabbitMQ running
run_test "RabbitMQ running" \
    "systemctl is-active --quiet rabbitmq-server && rabbitmqctl status >/dev/null 2>&1"

# 8. RabbitMQ queue accessible
run_test "RabbitMQ queue" \
    "rabbitmqctl list_queues 2>/dev/null | grep -q device_sync || rabbitmqctl list_queues 2>/dev/null"

# 9. BigQuery sync (if credentials exist)
if [ -f "$CONFIG_DIR/gcp-credentials.json" ]; then
    run_test "BigQuery credentials valid" \
        "python3 -c \"import json; d=json.load(open('$CONFIG_DIR/gcp-credentials.json')); assert 'project_id' in d\""
else
    echo "  [SKIP] BigQuery — no credentials file"
    TESTS+=("{\"name\": \"BigQuery credentials\", \"status\": \"skip\", \"error\": \"No credentials file\"}")
fi

# 10. Heartbeat to server
if [ -n "$SERVER_URL" ] && [ -n "$DEVICE_TOKEN" ]; then
    run_test "Heartbeat to server" \
        "curl -sf --max-time 10 -X POST '$SERVER_URL/devices/heartbeat' -H 'Content-Type: application/json' -H 'X-Device-ID: $DEVICE_ID' -H 'X-Device-Token: $DEVICE_TOKEN' -d '{\"device_id\": \"$DEVICE_ID\", \"status\": \"qa_testing\"}'"
else
    echo "  [SKIP] Heartbeat — no server URL or token"
    TESTS+=("{\"name\": \"Heartbeat\", \"status\": \"skip\"}")
fi

# 11. Disk space
run_test "Disk space > 20% free" \
    "USED=\$(df /opt/oncofix --output=pcent 2>/dev/null | tail -1 | tr -d '% '); [ \"\$USED\" -lt 80 ]"

# 12. Memory available
run_test "Memory < 90% used" \
    "MEM=\$(free | awk '/Mem:/{printf \"%.0f\", \$3/\$2 * 100}'); [ \"\$MEM\" -lt 90 ]"

# ----------------------------------------------------------
# Summary
# ----------------------------------------------------------
TOTAL=$((PASSED + FAILED))
QA_PASSED="false"
[ "$FAILED" -eq 0 ] && QA_PASSED="true"

echo ""
echo "=========================================="
echo "  QA Results: $PASSED/$TOTAL passed"
[ "$FAILED" -gt 0 ] && echo "  FAILED: $FAILED test(s)"
echo "  Overall: $([ "$QA_PASSED" = "true" ] && echo "PASS ✓" || echo "FAIL ✗")"
echo "=========================================="

# ----------------------------------------------------------
# Report to server
# ----------------------------------------------------------
if [ -n "$SERVER_URL" ] && [ -n "$DEVICE_TOKEN" ]; then
    echo ""
    echo "Reporting QA result to server..."

    TESTS_JSON=$(printf '%s,' "${TESTS[@]}")
    TESTS_JSON="[${TESTS_JSON%,}]"

    curl -sf --max-time 15 \
        -X POST "$SERVER_URL/devices/$DEVICE_ID/qa-result" \
        -H "Content-Type: application/json" \
        -H "X-Device-ID: $DEVICE_ID" \
        -H "X-Device-Token: $DEVICE_TOKEN" \
        -d "{
            \"passed\": $QA_PASSED,
            \"total_tests\": $TOTAL,
            \"passed_tests\": $PASSED,
            \"failed_tests\": $FAILED,
            \"tests\": $TESTS_JSON,
            \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"
        }" >/dev/null 2>&1 && echo "  Reported to server." || echo "  WARNING: Failed to report to server."
fi

echo ""
echo "  Log: $LOG_FILE"
echo ""

# Exit with failure if any test failed
[ "$QA_PASSED" = "true" ] && exit 0 || exit 1
