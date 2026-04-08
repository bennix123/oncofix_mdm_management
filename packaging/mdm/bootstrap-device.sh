#!/bin/bash
# =============================================================
# OncoFix Device Bootstrap — Full Setup in One Script
# =============================================================
# Single script to set up a fresh OrangePi5 (or any ARM64/x86
# Linux device) with the complete OncoFix stack + Swif.ai MDM.
#
# What it does:
#   1. Installs system dependencies (Node.js, Python, RabbitMQ, Nginx)
#   2. Installs OncoFix .deb package (backend + frontend + AI)
#   3. Configures device-specific settings (device ID, secrets, etc.)
#   4. Sets up BigQuery credentials for cloud sync
#   5. Starts all OncoFix services
#   6. Enrolls device into Swif.ai MDM
#   7. Verifies everything is running
#
# Usage (run as root on a fresh device):
#
#   sudo DEVICE_ID="OPi5_clinic_mumbai_001" \
#        DEVICE_NAME="Clinic Mumbai Unit 1" \
#        DEVICE_LOCATION="Mumbai" \
#        DEB_URL="https://your-repo/oncofix_1.0.0_all.deb" \
#        GCP_CREDS_URL="https://your-bucket/gcp-creds.json" \
#        SWIFAI_ENROLLMENT_URL="https://mdm.swif.ai/enroll/..." \
#        bash bootstrap-device.sh
#
# Minimal usage (local .deb, no cloud sync, no MDM):
#
#   sudo DEB_PATH="/tmp/oncofix_1.0.0_all.deb" \
#        bash bootstrap-device.sh
#
# =============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/oncofix/bootstrap-$(date +%Y%m%d-%H%M%S).log"
mkdir -p /var/log/oncofix
exec > >(tee -a "$LOG_FILE") 2>&1

# ----------------------------------------------------------
# Configuration (all overridable via env vars)
# ----------------------------------------------------------

# Device identity
DEVICE_ID="${DEVICE_ID:-OPi5_oncofix_$(hostname -s | tr '[:upper:]' '[:lower:]')_$(date +%s)}"
DEVICE_NAME="${DEVICE_NAME:-OncoFix $(hostname -s)}"
DEVICE_LOCATION="${DEVICE_LOCATION:-unknown}"

# OncoFix package
DEB_URL="${DEB_URL:-}"
DEB_PATH="${DEB_PATH:-/tmp/oncofix.deb}"

# BigQuery sync (optional)
GCP_CREDS_URL="${GCP_CREDS_URL:-}"
GCP_CREDS_PATH="${GCP_CREDS_PATH:-}"
BIGQUERY_DATASET="${BIGQUERY_DATASET:-oncoedge_test}"

# Secrets (auto-generated if not provided)
JWT_SECRET="${JWT_SECRET:-$(openssl rand -hex 32)}"
JWT_REFRESH_SECRET="${JWT_REFRESH_SECRET:-$(openssl rand -hex 32)}"
PHOTO_KEY="${PHOTO_KEY:-$(openssl rand -hex 16)}"

# Swif.ai MDM (optional — skip enrollment if not provided)
SWIFAI_ENROLLMENT_URL="${SWIFAI_ENROLLMENT_URL:-}"
SWIFAI_ENROLLMENT_SCRIPT="${SWIFAI_ENROLLMENT_SCRIPT:-}"

# Reporting (optional)
REPORT_URL="${REPORT_URL:-}"

TOTAL_STEPS=8

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         OncoFix Device Bootstrap                        ║"
echo "║         $(date -u +"%Y-%m-%d %H:%M:%S UTC")                       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Device ID       : $DEVICE_ID"
echo "  Device Name     : $DEVICE_NAME"
echo "  Location        : $DEVICE_LOCATION"
echo "  Architecture    : $(uname -m)"
echo "  OS              : $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
echo "  BigQuery sync   : $([ -n "$GCP_CREDS_URL$GCP_CREDS_PATH" ] && echo 'yes' || echo 'no (can add later)')"
echo "  Swif.ai MDM     : $([ -n "$SWIFAI_ENROLLMENT_URL$SWIFAI_ENROLLMENT_SCRIPT" ] && echo 'yes' || echo 'no (can add later)')"
echo ""

# ==========================================================
# STEP 1: System Dependencies
# ==========================================================
echo "[$((1))/${TOTAL_STEPS}] Installing system dependencies..."

apt-get update -qq

# Node.js 18
if ! command -v node &>/dev/null || [ "$(node -v | sed 's/v//' | cut -d. -f1)" -lt 18 ]; then
    echo "  Installing Node.js 18..."
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
    apt-get install -y nodejs
fi

# Python, RabbitMQ, Nginx, SQLite, etc.
apt-get install -y -qq \
    python3 python3-venv \
    sqlite3 \
    nginx \
    rabbitmq-server erlang-base \
    curl wget openssl \
    jq

echo "  Node.js  : $(node -v)"
echo "  Python   : $(python3 --version)"
echo "  Nginx    : $(nginx -v 2>&1 | awk -F/ '{print $2}')"
echo "  RabbitMQ : $(rabbitmqctl version 2>/dev/null || echo 'installed')"
echo ""

# ==========================================================
# STEP 2: Install OncoFix .deb Package
# ==========================================================
echo "[2/${TOTAL_STEPS}] Installing OncoFix package..."

if [ -n "$DEB_URL" ]; then
    echo "  Downloading: $DEB_URL"
    curl -fsSL "$DEB_URL" -o "$DEB_PATH"
fi

if [ ! -f "$DEB_PATH" ]; then
    echo ""
    echo "  ERROR: OncoFix .deb not found at $DEB_PATH"
    echo "  Provide either:"
    echo "    DEB_URL=https://...    (remote download)"
    echo "    DEB_PATH=/tmp/oncofix_1.0.0_all.deb    (local file)"
    exit 1
fi

dpkg -i "$DEB_PATH" || true
apt-get install -f -y  # fix any missing dependencies
echo "  Package installed: $(dpkg-query -W -f='${Package} ${Version}' oncofix 2>/dev/null || echo 'oncofix')"
echo ""

# ==========================================================
# STEP 3: Configure Device
# ==========================================================
echo "[3/${TOTAL_STEPS}] Configuring device-specific settings..."

ENV_FILE="/etc/oncofix/backend.env"

if [ -f "$ENV_FILE" ]; then
    sed -i "s|^DEFAULT_DEVICE_ID=.*|DEFAULT_DEVICE_ID=${DEVICE_ID}|" "$ENV_FILE"
    sed -i "s|^JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET}|" "$ENV_FILE"
    sed -i "s|^JWT_REFRESH_SECRET=.*|JWT_REFRESH_SECRET=${JWT_REFRESH_SECRET}|" "$ENV_FILE"
    sed -i "s|^PHOTO_ENCRYPTION_KEY=.*|PHOTO_ENCRYPTION_KEY=${PHOTO_KEY}|" "$ENV_FILE"
    sed -i "s|^BIGQUERY_DATASET=.*|BIGQUERY_DATASET=${BIGQUERY_DATASET}|" "$ENV_FILE"
    echo "  backend.env configured."
else
    echo "  WARNING: $ENV_FILE not found. Package may not have installed correctly."
fi
echo ""

# ==========================================================
# STEP 4: BigQuery Credentials (optional)
# ==========================================================
echo "[4/${TOTAL_STEPS}] Setting up BigQuery credentials..."

if [ -n "$GCP_CREDS_URL" ]; then
    echo "  Downloading GCP credentials..."
    curl -fsSL "$GCP_CREDS_URL" -o /etc/oncofix/gcp-credentials.json
    chmod 600 /etc/oncofix/gcp-credentials.json
    chown oncofix:oncofix /etc/oncofix/gcp-credentials.json
    echo "  GCP credentials installed."
elif [ -n "$GCP_CREDS_PATH" ] && [ -f "$GCP_CREDS_PATH" ]; then
    cp "$GCP_CREDS_PATH" /etc/oncofix/gcp-credentials.json
    chmod 600 /etc/oncofix/gcp-credentials.json
    chown oncofix:oncofix /etc/oncofix/gcp-credentials.json
    echo "  GCP credentials copied from $GCP_CREDS_PATH."
else
    echo "  Skipped — no GCP credentials provided."
    echo "  BigQuery sync will be disabled until credentials are added."
    echo "  Add later: place JSON at /etc/oncofix/gcp-credentials.json"
fi
echo ""

# ==========================================================
# STEP 5: Initialize Database
# ==========================================================
echo "[5/${TOTAL_STEPS}] Initializing database..."

if [ ! -f /var/lib/oncofix/database.sqlite ]; then
    echo "  Database will be created on first backend start."
else
    echo "  Existing database found — preserving data."
fi
echo ""

# ==========================================================
# STEP 6: Start OncoFix Services
# ==========================================================
echo "[6/${TOTAL_STEPS}] Starting OncoFix services..."

systemctl daemon-reload

# Start in dependency order
systemctl enable --now rabbitmq-server
echo "  RabbitMQ  : $(systemctl is-active rabbitmq-server)"

systemctl enable --now oncofix-backend
echo "  Backend   : $(systemctl is-active oncofix-backend)"

systemctl enable --now oncofix-ai
echo "  AI Model  : $(systemctl is-active oncofix-ai)"

systemctl enable --now nginx
echo "  Nginx     : $(systemctl is-active nginx)"

# Give services a moment to fully start
sleep 5

# Quick health verification
BACKEND_OK=false
FRONTEND_OK=false

if curl -sf -k https://localhost/api/v1/health >/dev/null 2>&1 || \
   curl -sf http://localhost:443/api/v1/health >/dev/null 2>&1; then
    BACKEND_OK=true
fi

if curl -sf http://localhost:8082 >/dev/null 2>&1; then
    FRONTEND_OK=true
fi

echo ""
echo "  Health check:"
echo "    Backend API (443)   : $($BACKEND_OK && echo 'OK' || echo 'starting...')"
echo "    Frontend (8082)     : $($FRONTEND_OK && echo 'OK' || echo 'starting...')"
echo ""

# ==========================================================
# STEP 7: Enroll into Swif.ai MDM
# ==========================================================
echo "[7/${TOTAL_STEPS}] Swif.ai MDM enrollment..."

if [ -n "$SWIFAI_ENROLLMENT_URL" ] || [ -n "$SWIFAI_ENROLLMENT_SCRIPT" ]; then

    # Write device info first (so swifai-setup.sh can read it)
    cat > /etc/oncofix/device-info.json << DEVEOF
{
    "deviceId": "${DEVICE_ID}",
    "deviceName": "${DEVICE_NAME}",
    "location": "${DEVICE_LOCATION}",
    "installedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "packageVersion": "$(dpkg-query -W -f='${Version}' oncofix 2>/dev/null || echo 'unknown')",
    "nodeVersion": "$(node -v)",
    "pythonVersion": "$(python3 --version 2>&1 | awk '{print $2}')",
    "hostname": "$(hostname)",
    "ip": "$(hostname -I | awk '{print $1}')",
    "arch": "$(uname -m)",
    "os": "$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
}
DEVEOF
    chmod 644 /etc/oncofix/device-info.json

    if [ -n "$SWIFAI_ENROLLMENT_URL" ]; then
        echo "  Downloading Swif.ai agent..."
        curl -fsSL "$SWIFAI_ENROLLMENT_URL" -o /tmp/swifai-enroll.sh
        chmod +x /tmp/swifai-enroll.sh
        bash /tmp/swifai-enroll.sh
        rm -f /tmp/swifai-enroll.sh
    elif [ -n "$SWIFAI_ENROLLMENT_SCRIPT" ]; then
        echo "  Running enrollment script..."
        eval "$SWIFAI_ENROLLMENT_SCRIPT"
    fi

    # Verify enrollment
    sleep 5
    SWIF_STATUS="enrolled"
    if systemctl is-active --quiet swif* 2>/dev/null; then
        SWIF_STATUS="running"
    elif pgrep -f swif > /dev/null 2>&1; then
        SWIF_STATUS="running"
    else
        SWIF_STATUS="check-dashboard"
    fi

    # Update device info with MDM status
    python3 -c "
import json
with open('/etc/oncofix/device-info.json', 'r') as f:
    info = json.load(f)
info['mdm'] = {
    'provider': 'swif.ai',
    'enrolledAt': '$(date -u +"%Y-%m-%dT%H:%M:%SZ")',
    'ownerType': 'company',
    'agentStatus': '${SWIF_STATUS}'
}
with open('/etc/oncofix/device-info.json', 'w') as f:
    json.dump(info, f, indent=4)
" 2>/dev/null || true

    echo "  Swif.ai agent: $SWIF_STATUS"
    echo "  Device will auto-join Smart Group based on OS=Linux filter."

else
    echo "  Skipped — no Swif.ai enrollment URL provided."
    echo "  To enroll later, run:"
    echo "    SWIFAI_ENROLLMENT_URL=\"...\" bash swifai-setup.sh"
fi
echo ""

# ==========================================================
# STEP 8: Write Device Registration & Setup Health Cron
# ==========================================================
echo "[8/${TOTAL_STEPS}] Finalizing setup..."

# Write/update device info (in case step 7 was skipped)
if [ ! -f /etc/oncofix/device-info.json ]; then
    cat > /etc/oncofix/device-info.json << DEVEOF
{
    "deviceId": "${DEVICE_ID}",
    "deviceName": "${DEVICE_NAME}",
    "location": "${DEVICE_LOCATION}",
    "installedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "packageVersion": "$(dpkg-query -W -f='${Version}' oncofix 2>/dev/null || echo 'unknown')",
    "nodeVersion": "$(node -v)",
    "pythonVersion": "$(python3 --version 2>&1 | awk '{print $2}')",
    "hostname": "$(hostname)",
    "ip": "$(hostname -I | awk '{print $1}')",
    "arch": "$(uname -m)",
    "os": "$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
}
DEVEOF
    chmod 644 /etc/oncofix/device-info.json
fi

# Install health-check cron (every 5 minutes)
HEALTH_SCRIPT="/opt/oncofix/health-check.sh"
if [ -f "$SCRIPT_DIR/health-check.sh" ]; then
    cp "$SCRIPT_DIR/health-check.sh" "$HEALTH_SCRIPT"
    chmod +x "$HEALTH_SCRIPT"
elif [ -f /opt/oncofix/health-check.sh ]; then
    echo "  Health check script already in place."
else
    echo "  NOTE: health-check.sh not found. Skipping cron setup."
    HEALTH_SCRIPT=""
fi

if [ -n "$HEALTH_SCRIPT" ]; then
    CRON_LINE="*/5 * * * * REPORT_URL=${REPORT_URL} /bin/bash ${HEALTH_SCRIPT} >> /var/log/oncofix/health.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "health-check.sh"; echo "$CRON_LINE") | crontab -
    echo "  Health check cron installed (every 5 min)."
fi

# Report to central server if configured
if [ -n "$REPORT_URL" ]; then
    curl -sf -X POST "$REPORT_URL" \
        -H "Content-Type: application/json" \
        -d @/etc/oncofix/device-info.json || \
        echo "  WARNING: Failed to report to $REPORT_URL"
fi

# ==========================================================
# Summary
# ==========================================================
BACKEND_STATUS="$(systemctl is-active oncofix-backend 2>/dev/null || echo 'unknown')"
AI_STATUS="$(systemctl is-active oncofix-ai 2>/dev/null || echo 'unknown')"
RABBITMQ_STATUS="$(systemctl is-active rabbitmq-server 2>/dev/null || echo 'unknown')"
NGINX_STATUS="$(systemctl is-active nginx 2>/dev/null || echo 'unknown')"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         Bootstrap Complete!                             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Device ID    : $DEVICE_ID"
echo "  Device Name  : $DEVICE_NAME"
echo "  Location     : $DEVICE_LOCATION"
echo ""
echo "  Services:"
echo "    Backend API  : $BACKEND_STATUS  (port 443)"
echo "    Frontend     : $NGINX_STATUS  (port 8082)"
echo "    AI Model     : $AI_STATUS"
echo "    RabbitMQ     : $RABBITMQ_STATUS"
echo "    Swif.ai MDM  : $([ -n "$SWIFAI_ENROLLMENT_URL$SWIFAI_ENROLLMENT_SCRIPT" ] && echo 'enrolled' || echo 'not enrolled')"
echo ""
echo "  Access:"
echo "    Frontend  : http://$(hostname -I | awk '{print $1}'):8082"
echo "    API       : https://$(hostname -I | awk '{print $1}')/api/v1/health"
echo ""
echo "  Logs:"
echo "    Bootstrap : $LOG_FILE"
echo "    Backend   : journalctl -u oncofix-backend -f"
echo "    AI        : journalctl -u oncofix-ai -f"
echo ""

if [ "$BACKEND_STATUS" != "active" ]; then
    echo "  WARNING: Backend not running!"
    echo "  Debug: sudo journalctl -u oncofix-backend -n 50 --no-pager"
    echo ""
    exit 1
fi

echo "  Device is ready for patient screening."
echo ""
