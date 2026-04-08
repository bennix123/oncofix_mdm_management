#!/bin/bash
# =============================================================
# OncoFix First-Boot Auto-Provisioning
# =============================================================
# Runs once on first boot via oncofix-provision.service.
# Reads hardware info, registers with the server, writes
# device-specific config, then disables itself.
#
# Systemd unit: /etc/systemd/system/oncofix-provision.service
# =============================================================

set -euo pipefail

LOG_FILE="/var/log/oncofix/provision-$(date +%Y%m%d-%H%M%S).log"
mkdir -p /var/log/oncofix
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== OncoFix First-Boot Provisioning ==="
echo "  $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo ""

# ----------------------------------------------------------
# Configuration
# ----------------------------------------------------------
SERVER_URL="${PROVISION_SERVER_URL:-https://api.oncofix.com/api/v1}"
CONFIG_DIR="/etc/oncofix"
IDENTITY_FILE="$CONFIG_DIR/device-identity.json"
ENV_FILE="$CONFIG_DIR/backend.env"
GCP_CREDS_FILE="$CONFIG_DIR/gcp-credentials.json"
MAX_RETRIES=10
RETRY_DELAY=30

mkdir -p "$CONFIG_DIR"

# ----------------------------------------------------------
# Skip if already provisioned
# ----------------------------------------------------------
if [ -f "$IDENTITY_FILE" ]; then
    echo "Device already provisioned. Identity file exists: $IDENTITY_FILE"
    echo "Disabling provision service."
    systemctl disable oncofix-provision.service 2>/dev/null || true
    exit 0
fi

# ----------------------------------------------------------
# 1. Read hardware info
# ----------------------------------------------------------
echo "[1/6] Reading hardware info..."

MAC_ADDRESS=$(cat /sys/class/net/$(ip route show default | awk '/default/ {print $5}' | head -1)/address 2>/dev/null || echo "unknown")
CPU_SERIAL=$(cat /proc/cpuinfo | grep Serial | awk '{print $3}' 2>/dev/null || echo "unknown")
BOARD_MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo "unknown")
HOSTNAME=$(hostname)

echo "  MAC Address  : $MAC_ADDRESS"
echo "  CPU Serial   : $CPU_SERIAL"
echo "  Board Model  : $BOARD_MODEL"
echo "  Hostname     : $HOSTNAME"

# ----------------------------------------------------------
# 2. Wait for network
# ----------------------------------------------------------
echo ""
echo "[2/6] Waiting for network connectivity..."

for i in $(seq 1 $MAX_RETRIES); do
    if curl -sf --max-time 5 "$SERVER_URL/health" >/dev/null 2>&1; then
        echo "  Server reachable."
        break
    fi
    echo "  Attempt $i/$MAX_RETRIES — server not reachable, retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
done

if ! curl -sf --max-time 5 "$SERVER_URL/health" >/dev/null 2>&1; then
    echo "ERROR: Cannot reach server at $SERVER_URL after $MAX_RETRIES attempts."
    echo "  Check network connectivity and server URL."
    exit 1
fi

# ----------------------------------------------------------
# 3. Register with server
# ----------------------------------------------------------
echo ""
echo "[3/6] Registering device with server..."

PROVISION_RESPONSE=$(curl -sf --max-time 30 \
    -X POST "$SERVER_URL/devices/provision" \
    -H "Content-Type: application/json" \
    -d "{
        \"mac_address\": \"$MAC_ADDRESS\",
        \"cpu_serial\": \"$CPU_SERIAL\",
        \"board_model\": \"$BOARD_MODEL\",
        \"hostname\": \"$HOSTNAME\"
    }" 2>&1) || {
    echo "ERROR: Provisioning request failed."
    echo "  Response: $PROVISION_RESPONSE"
    exit 1
}

echo "  Server responded."

# Parse response
DEVICE_ID=$(echo "$PROVISION_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['device_id'])" 2>/dev/null)
DEVICE_TOKEN=$(echo "$PROVISION_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['device_token'])" 2>/dev/null)
JWT_SECRET=$(echo "$PROVISION_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('jwt_secret',''))" 2>/dev/null || true)
REFRESH_SECRET=$(echo "$PROVISION_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('refresh_secret',''))" 2>/dev/null || true)
PHOTO_KEY=$(echo "$PROVISION_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('photo_key',''))" 2>/dev/null || true)
BQ_CREDS_B64=$(echo "$PROVISION_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('bigquery_creds',''))" 2>/dev/null || true)

if [ -z "$DEVICE_ID" ] || [ -z "$DEVICE_TOKEN" ]; then
    echo "ERROR: Invalid server response — missing device_id or device_token."
    echo "  Response: $PROVISION_RESPONSE"
    exit 1
fi

echo "  Device ID    : $DEVICE_ID"
echo "  Token        : ${DEVICE_TOKEN:0:8}..."

# ----------------------------------------------------------
# 4. Write config files
# ----------------------------------------------------------
echo ""
echo "[4/6] Writing device configuration..."

# Device identity
cat > "$IDENTITY_FILE" << EOF
{
    "deviceId": "$DEVICE_ID",
    "deviceToken": "$DEVICE_TOKEN",
    "macAddress": "$MAC_ADDRESS",
    "cpuSerial": "$CPU_SERIAL",
    "boardModel": "$BOARD_MODEL",
    "provisionedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "serverUrl": "$SERVER_URL"
}
EOF
chmod 600 "$IDENTITY_FILE"
echo "  Written: $IDENTITY_FILE"

# Backend env (append device-specific values)
if [ -f "$ENV_FILE" ]; then
    # Remove old device-specific lines if any
    sed -i '/^DEFAULT_DEVICE_ID=/d' "$ENV_FILE"
    sed -i '/^DEVICE_TOKEN=/d' "$ENV_FILE"
    sed -i '/^JWT_SECRET=/d' "$ENV_FILE"
    sed -i '/^JWT_REFRESH_SECRET=/d' "$ENV_FILE"
    sed -i '/^PHOTO_ENCRYPTION_KEY=/d' "$ENV_FILE"
fi

cat >> "$ENV_FILE" << EOF

# Device-specific (set by provisioning)
DEFAULT_DEVICE_ID=$DEVICE_ID
DEVICE_TOKEN=$DEVICE_TOKEN
EOF

[ -n "$JWT_SECRET" ] && echo "JWT_SECRET=$JWT_SECRET" >> "$ENV_FILE"
[ -n "$REFRESH_SECRET" ] && echo "JWT_REFRESH_SECRET=$REFRESH_SECRET" >> "$ENV_FILE"
[ -n "$PHOTO_KEY" ] && echo "PHOTO_ENCRYPTION_KEY=$PHOTO_KEY" >> "$ENV_FILE"

chmod 600 "$ENV_FILE"
echo "  Updated: $ENV_FILE"

# BigQuery credentials
if [ -n "$BQ_CREDS_B64" ]; then
    echo "$BQ_CREDS_B64" | base64 -d > "$GCP_CREDS_FILE"
    chmod 600 "$GCP_CREDS_FILE"
    chown oncofix:oncofix "$GCP_CREDS_FILE" 2>/dev/null || true
    echo "  Written: $GCP_CREDS_FILE"
fi

chown -R oncofix:oncofix "$CONFIG_DIR" 2>/dev/null || true

# ----------------------------------------------------------
# 5. Restart services & send first heartbeat
# ----------------------------------------------------------
echo ""
echo "[5/6] Restarting services..."

systemctl daemon-reload
systemctl restart oncofix-backend 2>/dev/null || true
sleep 5

# Send first heartbeat
echo "  Sending first heartbeat..."
HEARTBEAT_STATUS="failed"
curl -sf --max-time 10 \
    -X POST "$SERVER_URL/devices/heartbeat" \
    -H "Content-Type: application/json" \
    -H "X-Device-ID: $DEVICE_ID" \
    -H "X-Device-Token: $DEVICE_TOKEN" \
    -d "{
        \"device_id\": \"$DEVICE_ID\",
        \"status\": \"provisioned\",
        \"version\": \"$(dpkg-query -W -f='\${Version}' oncofix 2>/dev/null || echo 'unknown')\"
    }" >/dev/null 2>&1 && HEARTBEAT_STATUS="ok"

echo "  Heartbeat: $HEARTBEAT_STATUS"

# ----------------------------------------------------------
# 6. Disable provisioning, enable agent
# ----------------------------------------------------------
echo ""
echo "[6/6] Finalizing..."

# Disable this service (runs only once)
systemctl disable oncofix-provision.service 2>/dev/null || true
echo "  Disabled: oncofix-provision.service"

# Enable the device agent (heartbeat + command polling)
systemctl enable oncofix-agent.service 2>/dev/null || true
systemctl start oncofix-agent.service 2>/dev/null || true
echo "  Enabled: oncofix-agent.service"

echo ""
echo "=== Provisioning Complete ==="
echo "  Device ID : $DEVICE_ID"
echo "  Status    : provisioned"
echo "  Log       : $LOG_FILE"
echo ""
