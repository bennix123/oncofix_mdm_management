#!/bin/bash
# =============================================================
# OncoFix Single Device Deployment Script
# =============================================================
# This script is pushed to devices via MDM (Scalefusion/Fleet)
# and handles the full installation + configuration.
#
# Usage (run as root on target device):
#   DEVICE_ID="OPi5_clinic_001" \
#   DEVICE_NAME="Clinic Mumbai Unit 1" \
#   GCP_CREDS_URL="https://your-secure-bucket/gcp-creds.json" \
#   DEB_URL="https://your-repo/oncofix_1.0.0_all.deb" \
#   bash deploy-device.sh
#
# All variables can also be set by MDM as env vars or script args.
# =============================================================

set -euo pipefail

LOG_FILE="/var/log/oncofix/deploy-$(date +%Y%m%d-%H%M%S).log"
mkdir -p /var/log/oncofix
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "  OncoFix Device Deployment"
echo "  $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
echo "=========================================="

# ----------------------------------------------------------
# Configuration (set via MDM env vars or defaults)
# ----------------------------------------------------------
DEVICE_ID="${DEVICE_ID:-OPi5_oncofix_default_001}"
DEVICE_NAME="${DEVICE_NAME:-OncoFix Device}"
DEVICE_LOCATION="${DEVICE_LOCATION:-unknown}"
DEB_URL="${DEB_URL:-}"
DEB_PATH="${DEB_PATH:-/tmp/oncofix.deb}"
GCP_CREDS_URL="${GCP_CREDS_URL:-}"
GCP_CREDS_PATH="${GCP_CREDS_PATH:-}"
JWT_SECRET="${JWT_SECRET:-$(openssl rand -hex 32)}"
JWT_REFRESH_SECRET="${JWT_REFRESH_SECRET:-$(openssl rand -hex 32)}"
PHOTO_KEY="${PHOTO_KEY:-$(openssl rand -hex 16)}"
BIGQUERY_DATASET="${BIGQUERY_DATASET:-oncoedge_test}"
REPORT_URL="${REPORT_URL:-}"

echo "Device ID       : $DEVICE_ID"
echo "Device Name     : $DEVICE_NAME"
echo "Device Location : $DEVICE_LOCATION"

# ----------------------------------------------------------
# 1. Install prerequisites
# ----------------------------------------------------------
echo ""
echo "[1/7] Installing prerequisites..."

apt-get update -qq

# Node.js 18
if ! command -v node &>/dev/null || [ "$(node -v | sed 's/v//' | cut -d. -f1)" -lt 18 ]; then
    echo "  Installing Node.js 18..."
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
    apt-get install -y nodejs
fi

# Ensure dependencies
apt-get install -y python3 python3-venv sqlite3 nginx rabbitmq-server curl wget -qq

echo "  Node: $(node -v), Python: $(python3 --version)"

# ----------------------------------------------------------
# 2. Download and install .deb package
# ----------------------------------------------------------
echo ""
echo "[2/7] Installing OncoFix package..."

if [ -n "$DEB_URL" ]; then
    echo "  Downloading from: $DEB_URL"
    curl -fsSL "$DEB_URL" -o "$DEB_PATH"
fi

if [ ! -f "$DEB_PATH" ]; then
    echo "ERROR: .deb file not found at $DEB_PATH"
    echo "  Set DEB_URL or place .deb at $DEB_PATH"
    exit 1
fi

dpkg -i "$DEB_PATH" || true
apt-get install -f -y  # fix any missing dependencies

# ----------------------------------------------------------
# 3. Configure device-specific settings
# ----------------------------------------------------------
echo ""
echo "[3/7] Configuring device..."

ENV_FILE="/etc/oncofix/backend.env"

# Set device-specific values
sed -i "s|^DEFAULT_DEVICE_ID=.*|DEFAULT_DEVICE_ID=${DEVICE_ID}|" "$ENV_FILE"
sed -i "s|^JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET}|" "$ENV_FILE"
sed -i "s|^JWT_REFRESH_SECRET=.*|JWT_REFRESH_SECRET=${JWT_REFRESH_SECRET}|" "$ENV_FILE"
sed -i "s|^PHOTO_ENCRYPTION_KEY=.*|PHOTO_ENCRYPTION_KEY=${PHOTO_KEY}|" "$ENV_FILE"
sed -i "s|^BIGQUERY_DATASET=.*|BIGQUERY_DATASET=${BIGQUERY_DATASET}|" "$ENV_FILE"

# ----------------------------------------------------------
# 4. Place GCP credentials (for BigQuery sync)
# ----------------------------------------------------------
echo ""
echo "[4/7] Setting up BigQuery credentials..."

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
    echo "  WARNING: No GCP credentials provided. BigQuery sync will fail."
    echo "  Place credentials at /etc/oncofix/gcp-credentials.json later."
fi

# ----------------------------------------------------------
# 5. Initialize database
# ----------------------------------------------------------
echo ""
echo "[5/7] Initializing database..."

if [ ! -f /var/lib/oncofix/database.sqlite ]; then
    cd /opt/oncofix/oncofix_online_backend
    # Seed creates initial schema + test data
    sudo -u oncofix node -e "
        // Quick schema init - the backend auto-creates tables on first run
        console.log('Database will be initialized on first backend start.');
    " || true
    echo "  Database will initialize on first start."
else
    echo "  Existing database found, preserving data."
fi

# ----------------------------------------------------------
# 6. Start services
# ----------------------------------------------------------
echo ""
echo "[6/7] Starting services..."

systemctl daemon-reload
systemctl enable --now rabbitmq-server
systemctl enable --now oncofix-backend
systemctl enable --now oncofix-ai
systemctl enable --now nginx

# Wait and verify
sleep 5

BACKEND_STATUS="FAILED"
if systemctl is-active --quiet oncofix-backend; then
    BACKEND_STATUS="RUNNING"
fi

FRONTEND_STATUS="FAILED"
if curl -sf http://localhost:8082/healthz >/dev/null 2>&1; then
    FRONTEND_STATUS="RUNNING"
fi

AI_STATUS="FAILED"
if systemctl is-active --quiet oncofix-ai; then
    AI_STATUS="RUNNING"
fi

RABBITMQ_STATUS="FAILED"
if systemctl is-active --quiet rabbitmq-server; then
    RABBITMQ_STATUS="RUNNING"
fi

# ----------------------------------------------------------
# 7. Write device registration metadata
# ----------------------------------------------------------
echo ""
echo "[7/7] Registering device..."

cat > /etc/oncofix/device-info.json << EOF
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
    "os": "$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')",
    "status": {
        "backend": "${BACKEND_STATUS}",
        "frontend": "${FRONTEND_STATUS}",
        "ai": "${AI_STATUS}",
        "rabbitmq": "${RABBITMQ_STATUS}"
    }
}
EOF

chmod 644 /etc/oncofix/device-info.json

# Report back to MDM/central server if URL provided
if [ -n "$REPORT_URL" ]; then
    curl -sf -X POST "$REPORT_URL" \
        -H "Content-Type: application/json" \
        -d @/etc/oncofix/device-info.json || \
        echo "WARNING: Failed to report to $REPORT_URL"
fi

echo ""
echo "=========================================="
echo "  Deployment Complete!"
echo "=========================================="
echo ""
echo "  Device ID : $DEVICE_ID"
echo "  Backend   : $BACKEND_STATUS (port 443)"
echo "  Frontend  : $FRONTEND_STATUS (port 8082)"
echo "  AI Model  : $AI_STATUS"
echo "  RabbitMQ  : $RABBITMQ_STATUS"
echo ""
echo "  Access: http://$(hostname -I | awk '{print $1}'):8082"
echo "  Log  : $LOG_FILE"
echo ""

# Exit with error if critical services failed
if [ "$BACKEND_STATUS" != "RUNNING" ]; then
    echo "ERROR: Backend not running! Check: journalctl -u oncofix-backend"
    exit 1
fi
