#!/bin/bash
# =============================================================
# Scalefusion MDM Agent Setup for OncoFix Devices
# =============================================================
# Run this AFTER OncoFix is installed to register the device
# with Scalefusion MDM for remote management.
#
# Usage:
#   SCALEFUSION_TOKEN="your-enrollment-token" bash scalefusion-setup.sh
# =============================================================

set -euo pipefail

SCALEFUSION_TOKEN="${SCALEFUSION_TOKEN:-}"
DEVICE_GROUP="${DEVICE_GROUP:-OncoFix-Devices}"

if [ -z "$SCALEFUSION_TOKEN" ]; then
    echo "ERROR: SCALEFUSION_TOKEN is required."
    echo "Get it from: Scalefusion Dashboard > Devices > Enroll Device > Linux"
    exit 1
fi

echo "=== Scalefusion MDM Registration ==="

# 1. Install Scalefusion agent
echo "[1/4] Installing Scalefusion agent..."
if ! command -v scalefusion-agent &>/dev/null; then
    # Download and install
    wget -q https://downloads.scalefusion.com/linux/scalefusion-agent.deb -O /tmp/scalefusion-agent.deb
    dpkg -i /tmp/scalefusion-agent.deb || apt-get install -f -y
    rm -f /tmp/scalefusion-agent.deb
fi

# 2. Read device info
echo "[2/4] Reading device info..."
DEVICE_ID="OPi5_oncofix_default_001"
DEVICE_NAME="OncoFix Device"
if [ -f /etc/oncofix/device-info.json ]; then
    DEVICE_ID=$(python3 -c "import json; print(json.load(open('/etc/oncofix/device-info.json'))['deviceId'])" 2>/dev/null || echo "$DEVICE_ID")
    DEVICE_NAME=$(python3 -c "import json; print(json.load(open('/etc/oncofix/device-info.json'))['deviceName'])" 2>/dev/null || echo "$DEVICE_NAME")
fi

# 3. Enroll device
echo "[3/4] Enrolling device with Scalefusion..."
scalefusion-agent enroll \
    --token "$SCALEFUSION_TOKEN" \
    --device-name "$DEVICE_NAME ($DEVICE_ID)" \
    --group "$DEVICE_GROUP"

# 4. Enable agent service
echo "[4/4] Enabling Scalefusion agent service..."
systemctl enable scalefusion-agent
systemctl start scalefusion-agent

# Verify
sleep 3
if systemctl is-active --quiet scalefusion-agent; then
    echo ""
    echo "=== Scalefusion Registration Complete ==="
    echo "  Device  : $DEVICE_NAME ($DEVICE_ID)"
    echo "  Group   : $DEVICE_GROUP"
    echo "  Status  : $(scalefusion-agent status 2>/dev/null || echo 'check dashboard')"
    echo ""
    echo "  View in Scalefusion Dashboard to manage remotely."
else
    echo "WARNING: Scalefusion agent not running. Check: journalctl -u scalefusion-agent"
fi
