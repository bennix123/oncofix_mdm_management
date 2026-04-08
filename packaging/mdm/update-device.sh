#!/bin/bash
# =============================================================
# OncoFix Device Update Script
# =============================================================
# Pushed via MDM to update devices to a new version.
#
# Usage:
#   DEB_URL="https://your-repo/oncofix_1.1.0_all.deb" bash update-device.sh
# =============================================================

set -euo pipefail

LOG_FILE="/var/log/oncofix/update-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

DEB_URL="${DEB_URL:-}"
DEB_PATH="${DEB_PATH:-/tmp/oncofix-update.deb}"

echo "=========================================="
echo "  OncoFix Device Update"
echo "  $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
echo "=========================================="

CURRENT_VER=$(dpkg-query -W -f='${Version}' oncofix 2>/dev/null || echo "not-installed")
echo "Current version: $CURRENT_VER"

# Download new package
if [ -n "$DEB_URL" ]; then
    echo "Downloading update from: $DEB_URL"
    curl -fsSL "$DEB_URL" -o "$DEB_PATH"
fi

if [ ! -f "$DEB_PATH" ]; then
    echo "ERROR: No .deb file found."
    exit 1
fi

NEW_VER=$(dpkg-deb -f "$DEB_PATH" Version)
echo "New version    : $NEW_VER"

# Backup current database before update
echo "Backing up database..."
DB_FILE="/var/lib/oncofix/database.sqlite"
if [ ! -f "$DB_FILE" ]; then
    DB_FILE="/opt/oncofix/oncofix_online_backend/database.sqlite"
fi
if [ -f "$DB_FILE" ]; then
    BACKUP_DIR="/var/lib/oncofix/backups"
    mkdir -p "$BACKUP_DIR"
    cp "$DB_FILE" "$BACKUP_DIR/database-pre-update-$(date +%Y%m%d-%H%M%S).sqlite"
    echo "  Database backed up."
fi

# Stop services
echo "Stopping services..."
systemctl stop oncofix-backend 2>/dev/null || true
systemctl stop oncofix-ai 2>/dev/null || true

# Install update (config files in /etc/oncofix are preserved via conffiles)
echo "Installing update..."
dpkg -i "$DEB_PATH" || true
apt-get install -f -y

# Restart services (postinst handles this, but just in case)
systemctl daemon-reload
systemctl start oncofix-backend
systemctl start oncofix-ai
systemctl reload nginx

#when downlaod its ready to install
# save the data in the backup dir
#then it will get install by closing the applicatio first 
#if the update get failed we have to manage exception where user have to manage operation and wait for the next
#update trigger
#note 
#whenver app get open we should call this script and check 

# Verify
sleep 5
BACKEND_OK="NO"
systemctl is-active --quiet oncofix-backend && BACKEND_OK="YES"

INSTALLED_VER=$(dpkg-query -W -f='${Version}' oncofix 2>/dev/null || echo "unknown")

echo ""
echo "=========================================="
echo "  Update Complete!"
echo "=========================================="
echo "  Previous : $CURRENT_VER"
echo "  Installed: $INSTALLED_VER"
echo "  Backend  : $BACKEND_OK"
echo ""

# Update device-info.json
if [ -f /etc/oncofix/device-info.json ]; then
    python3 -c "
import json
with open('/etc/oncofix/device-info.json', 'r+') as f:
    info = json.load(f)
    info['packageVersion'] = '$INSTALLED_VER'
    info['lastUpdated'] = '$(date -u +"%Y-%m-%dT%H:%M:%SZ")'
    f.seek(0)
    json.dump(info, f, indent=4)
    f.truncate()
" 2>/dev/null || true
fi

# Cleanup
rm -f "$DEB_PATH"

if [ "$BACKEND_OK" != "YES" ]; then
    echo "ERROR: Backend failed after update!"
    exit 1
fi
