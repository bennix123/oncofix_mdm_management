#!/bin/bash
# =============================================================
# Swif.ai MDM Agent Setup for OncoFix Devices
# =============================================================
# Run this AFTER OncoFix is installed to enroll the device
# into Swif.ai MDM for remote management & HIPAA compliance.
#
# Usage:
#   SWIFAI_ENROLLMENT_URL="https://mdm.swif.ai/enroll/..." \
#   bash swifai-setup.sh
#
# Get the enrollment URL/command from:
#   Swif.ai Console > Device Management > Device Inventory > Add Devices > Linux
# =============================================================

set -euo pipefail

LOG_FILE="/var/log/oncofix/swifai-enroll-$(date +%Y%m%d-%H%M%S).log"
mkdir -p /var/log/oncofix
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Swif.ai MDM Enrollment ==="
echo "  $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
echo ""

# ----------------------------------------------------------
# Configuration (set via env vars)
# ----------------------------------------------------------
SWIFAI_ENROLLMENT_URL="${SWIFAI_ENROLLMENT_URL:-}"
SWIFAI_ENROLLMENT_SCRIPT="${SWIFAI_ENROLLMENT_SCRIPT:-}"
DEVICE_OWNER_TYPE="${DEVICE_OWNER_TYPE:-company}"  # company | byod

# ----------------------------------------------------------
# Read OncoFix device info (if installed)
# ----------------------------------------------------------
DEVICE_ID="OPi5_oncofix_default_001"
DEVICE_NAME="OncoFix Device"
if [ -f /etc/oncofix/device-info.json ]; then
    DEVICE_ID=$(python3 -c "import json; print(json.load(open('/etc/oncofix/device-info.json'))['deviceId'])" 2>/dev/null || echo "$DEVICE_ID")
    DEVICE_NAME=$(python3 -c "import json; print(json.load(open('/etc/oncofix/device-info.json'))['deviceName'])" 2>/dev/null || echo "$DEVICE_NAME")
fi

echo "  Device ID   : $DEVICE_ID"
echo "  Device Name : $DEVICE_NAME"
echo "  Owner Type  : $DEVICE_OWNER_TYPE"
echo ""

# ----------------------------------------------------------
# 1. Check if Swif agent is already installed
# ----------------------------------------------------------
echo "[1/4] Checking for existing Swif.ai agent..."

if command -v swif-agent &>/dev/null || [ -f /usr/local/bin/swif-agent ] || systemctl list-units --type=service | grep -q swif; then
    echo "  Swif.ai agent already installed. Checking status..."
    systemctl status swif* --no-pager 2>/dev/null || true
    echo ""
    echo "  To re-enroll, first remove the existing agent:"
    echo "    sudo swif-agent uninstall  (or dpkg --purge swif-agent)"
    echo ""
    read -p "  Continue anyway? (y/N): " CONTINUE
    [ "$CONTINUE" = "y" ] || [ "$CONTINUE" = "Y" ] || exit 0
fi

# ----------------------------------------------------------
# 2. Install Swif.ai agent
# ----------------------------------------------------------
echo "[2/4] Installing Swif.ai agent..."

if [ -n "$SWIFAI_ENROLLMENT_URL" ]; then
    echo "  Using enrollment URL..."
    # Swif.ai provides a curl command that downloads + installs + enrolls in one step
    # The URL from the admin console is typically:
    #   curl -fsSL https://mdm.swif.ai/enroll/<org-token>/linux/arm64 | sudo bash
    curl -fsSL "$SWIFAI_ENROLLMENT_URL" -o /tmp/swifai-enroll.sh
    chmod +x /tmp/swifai-enroll.sh
    bash /tmp/swifai-enroll.sh
    rm -f /tmp/swifai-enroll.sh

elif [ -n "$SWIFAI_ENROLLMENT_SCRIPT" ]; then
    echo "  Using provided enrollment script..."
    # If the full enrollment command is passed as a string
    eval "$SWIFAI_ENROLLMENT_SCRIPT"

else
    echo "ERROR: No enrollment method provided."
    echo ""
    echo "  Set one of these environment variables:"
    echo ""
    echo "  Option 1 - Enrollment URL (from Swif.ai console):"
    echo "    SWIFAI_ENROLLMENT_URL=\"https://mdm.swif.ai/enroll/...\""
    echo ""
    echo "  Option 2 - Full enrollment command:"
    echo "    SWIFAI_ENROLLMENT_SCRIPT=\"curl -fsSL https://... | sudo bash\""
    echo ""
    echo "  To get the enrollment command:"
    echo "    1. Log into https://app.swif.ai"
    echo "    2. Go to Device Management > Device Inventory"
    echo "    3. Click 'Add Devices' > Select 'Linux'"
    echo "    4. Choose: Processor=ARM64, Owner=Company-Owned"
    echo "    5. Select 'Command Line' method"
    echo "    6. Copy the enrollment command/URL"
    exit 1
fi

# ----------------------------------------------------------
# 3. Verify enrollment
# ----------------------------------------------------------
echo ""
echo "[3/4] Verifying Swif.ai enrollment..."

sleep 5

SWIF_STATUS="unknown"
if systemctl is-active --quiet swif* 2>/dev/null; then
    SWIF_STATUS="running"
    echo "  Swif.ai agent is running."
elif pgrep -f swif > /dev/null 2>&1; then
    SWIF_STATUS="running"
    echo "  Swif.ai agent process detected."
else
    SWIF_STATUS="check-dashboard"
    echo "  WARNING: Could not verify agent status locally."
    echo "  Check Swif.ai dashboard for enrollment confirmation."
fi

# ----------------------------------------------------------
# 4. Update device info
# ----------------------------------------------------------
echo ""
echo "[4/4] Updating device registration info..."

if [ -f /etc/oncofix/device-info.json ]; then
    # Add Swif.ai enrollment info to device metadata
    python3 -c "
import json
with open('/etc/oncofix/device-info.json', 'r') as f:
    info = json.load(f)
info['mdm'] = {
    'provider': 'swif.ai',
    'enrolledAt': '$(date -u +"%Y-%m-%dT%H:%M:%SZ")',
    'ownerType': '${DEVICE_OWNER_TYPE}',
    'agentStatus': '${SWIF_STATUS}'
}
with open('/etc/oncofix/device-info.json', 'w') as f:
    json.dump(info, f, indent=4)
print('  Device info updated with MDM metadata.')
" 2>/dev/null || echo "  WARNING: Could not update device-info.json"
fi

echo ""
echo "=== Swif.ai Enrollment Complete ==="
echo ""
echo "  Device     : $DEVICE_NAME ($DEVICE_ID)"
echo "  Agent      : $SWIF_STATUS"
echo "  Log        : $LOG_FILE"
echo ""
echo "  Next steps:"
echo "    1. Check https://app.swif.ai > Device Inventory for this device"
echo "    2. It should auto-join the 'OncoFix Kiosk Devices' Smart Group (if configured)"
echo "    3. Policies will be applied automatically by the Smart Group"
echo ""
