#!/bin/bash
# =============================================================
# OncoFix Batch Deployment via SSH
# =============================================================
# Deploy OncoFix to multiple devices via SSH from a central machine.
# Reads device list from devices.csv and runs deploy-device.sh on each.
#
# Usage:
#   chmod +x batch-deploy.sh
#   ./batch-deploy.sh devices.csv oncofix_1.0.0_all.deb
#
# devices.csv format (no header):
#   device_id,device_name,location,ip_address,ssh_user,ssh_port
#   OPi5_clinic_001,Mumbai Clinic 1,Mumbai,192.168.1.101,root,22
#   OPi5_clinic_002,Delhi Clinic 2,Delhi,192.168.1.102,root,22
# =============================================================

set -euo pipefail

DEVICES_CSV="${1:-devices.csv}"
DEB_FILE="${2:-}"
GCP_CREDS="${GCP_CREDS_FILE:-}"
SSH_KEY="${SSH_KEY:-}"
DEPLOY_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy-device.sh"
HEALTH_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/health-check.sh"
PARALLEL="${MAX_PARALLEL:-5}"
REPORT_URL="${REPORT_URL:-}"

LOG_DIR="./deploy-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

echo "================================================"
echo "  OncoFix Batch Deployment"
echo "  $(date)"
echo "================================================"
echo "  Devices file : $DEVICES_CSV"
echo "  Package      : $DEB_FILE"
echo "  Parallel     : $PARALLEL"
echo "  Logs         : $LOG_DIR"
echo ""

if [ ! -f "$DEVICES_CSV" ]; then
    echo "ERROR: Devices file not found: $DEVICES_CSV"
    exit 1
fi

if [ -n "$DEB_FILE" ] && [ ! -f "$DEB_FILE" ]; then
    echo "ERROR: .deb file not found: $DEB_FILE"
    exit 1
fi

if [ ! -f "$DEPLOY_SCRIPT" ]; then
    echo "ERROR: deploy-device.sh not found at: $DEPLOY_SCRIPT"
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"
if [ -n "$SSH_KEY" ]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
fi

# Track results
TOTAL=0
SUCCESS=0
FAILED=0
RESULTS_FILE="$LOG_DIR/results.csv"
echo "device_id,device_name,ip,status,message" > "$RESULTS_FILE"

deploy_device() {
    local DEVICE_ID="$1"
    local DEVICE_NAME="$2"
    local LOCATION="$3"
    local IP="$4"
    local SSH_USER="$5"
    local SSH_PORT="${6:-22}"
    local DEVICE_LOG="$LOG_DIR/${DEVICE_ID}.log"

    echo "  [$DEVICE_ID] Deploying to $IP..."

    {
        echo "=== Deployment: $DEVICE_ID ($IP) ==="
        echo "Started: $(date)"

        # Test SSH connectivity
        if ! ssh $SSH_OPTS -p "$SSH_PORT" "$SSH_USER@$IP" "echo ok" &>/dev/null; then
            echo "FAILED: Cannot SSH to $IP:$SSH_PORT"
            echo "$DEVICE_ID,$DEVICE_NAME,$IP,FAILED,SSH connection failed" >> "$RESULTS_FILE"
            return 1
        fi

        # Upload .deb package
        if [ -n "$DEB_FILE" ]; then
            echo "Uploading .deb package..."
            scp $SSH_OPTS -P "$SSH_PORT" "$DEB_FILE" "$SSH_USER@$IP:/tmp/oncofix.deb"
        fi

        # Upload deploy script
        scp $SSH_OPTS -P "$SSH_PORT" "$DEPLOY_SCRIPT" "$SSH_USER@$IP:/tmp/deploy-device.sh"

        # Upload health check script
        scp $SSH_OPTS -P "$SSH_PORT" "$HEALTH_SCRIPT" "$SSH_USER@$IP:/tmp/health-check.sh"

        # Upload GCP credentials if provided
        if [ -n "$GCP_CREDS" ] && [ -f "$GCP_CREDS" ]; then
            scp $SSH_OPTS -P "$SSH_PORT" "$GCP_CREDS" "$SSH_USER@$IP:/tmp/gcp-credentials.json"
        fi

        # Run deployment
        ssh $SSH_OPTS -p "$SSH_PORT" "$SSH_USER@$IP" \
            "DEVICE_ID='$DEVICE_ID' \
             DEVICE_NAME='$DEVICE_NAME' \
             DEVICE_LOCATION='$LOCATION' \
             DEB_PATH='/tmp/oncofix.deb' \
             GCP_CREDS_PATH='/tmp/gcp-credentials.json' \
             REPORT_URL='$REPORT_URL' \
             bash /tmp/deploy-device.sh"

        local EXIT_CODE=$?

        # Install health check cron
        ssh $SSH_OPTS -p "$SSH_PORT" "$SSH_USER@$IP" \
            "cp /tmp/health-check.sh /opt/oncofix/health-check.sh && \
             chmod +x /opt/oncofix/health-check.sh && \
             (crontab -l 2>/dev/null | grep -v health-check; echo '*/5 * * * * REPORT_URL=$REPORT_URL /opt/oncofix/health-check.sh >> /var/log/oncofix/health.log 2>&1') | crontab -"

        if [ $EXIT_CODE -eq 0 ]; then
            echo "SUCCESS"
            echo "$DEVICE_ID,$DEVICE_NAME,$IP,SUCCESS,Deployed OK" >> "$RESULTS_FILE"
        else
            echo "FAILED with exit code $EXIT_CODE"
            echo "$DEVICE_ID,$DEVICE_NAME,$IP,FAILED,Exit code $EXIT_CODE" >> "$RESULTS_FILE"
        fi

        # Cleanup remote temp files
        ssh $SSH_OPTS -p "$SSH_PORT" "$SSH_USER@$IP" \
            "rm -f /tmp/oncofix.deb /tmp/deploy-device.sh /tmp/health-check.sh /tmp/gcp-credentials.json" 2>/dev/null || true

        echo "Finished: $(date)"
    } > "$DEVICE_LOG" 2>&1

    return ${PIPESTATUS[0]:-0}
}

# Read CSV and deploy
PIDS=()
while IFS=',' read -r DEVICE_ID DEVICE_NAME LOCATION IP SSH_USER SSH_PORT; do
    # Skip empty lines and comments
    [[ -z "$DEVICE_ID" || "$DEVICE_ID" =~ ^# ]] && continue

    TOTAL=$((TOTAL + 1))

    # Run deployment in background (limited parallelism)
    deploy_device "$DEVICE_ID" "$DEVICE_NAME" "$LOCATION" "$IP" "$SSH_USER" "$SSH_PORT" &
    PIDS+=($!)

    # Throttle parallelism
    if [ ${#PIDS[@]} -ge "$PARALLEL" ]; then
        # Wait for first batch
        for PID in "${PIDS[@]}"; do
            wait "$PID" && SUCCESS=$((SUCCESS + 1)) || FAILED=$((FAILED + 1))
        done
        PIDS=()
    fi
done < "$DEVICES_CSV"

# Wait for remaining
for PID in "${PIDS[@]}"; do
    wait "$PID" && SUCCESS=$((SUCCESS + 1)) || FAILED=$((FAILED + 1))
done

echo ""
echo "================================================"
echo "  Batch Deployment Summary"
echo "================================================"
echo "  Total   : $TOTAL"
echo "  Success : $SUCCESS"
echo "  Failed  : $FAILED"
echo "  Results : $RESULTS_FILE"
echo "  Logs    : $LOG_DIR/"
echo ""

if [ "$FAILED" -gt 0 ]; then
    echo "  Failed devices:"
    grep "FAILED" "$RESULTS_FILE" | while IFS=',' read -r DID DNAME DIP DSTATUS DMSG; do
        echo "    - $DID ($DIP): $DMSG"
    done
    echo ""
fi
