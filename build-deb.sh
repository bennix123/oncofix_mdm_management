#!/bin/bash
# =============================================================
# OncoFix .deb Package Builder
# =============================================================
# Run this on a Debian/Ubuntu build machine with internet access.
# Produces: oncofix_<version>_<arch>.deb
#
# Usage:
#   chmod +x build-deb.sh
#   ./build-deb.sh [version] [arch]
#
# Example:
#   ./build-deb.sh 2.0.0 arm64
#
# What the .deb installs:
#   - Backend (NestJS) on port 3000
#   - Frontend (serve) on port 5173
#   - screen.py camera script (headless mode)
#   - SQLite local DB + BigQuery sync every 5 min
#   - systemd services: oncofix-backend, oncofix-frontend
# =============================================================

set -euo pipefail

VERSION="${1:-2.0.0}"
ARCH="${2:-arm64}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
PKG_DIR="$BUILD_DIR/oncofix_${VERSION}"
OUTPUT_DEB="$SCRIPT_DIR/oncofix_${VERSION}_${ARCH}.deb"

echo "================================================"
echo "  Building OncoFix v${VERSION} Debian Package"
echo "================================================"
echo ""

# ----------------------------------------------------------
# 0. Pre-flight checks
# ----------------------------------------------------------
echo "[1/8] Pre-flight checks..."
for cmd in node npm python3 dpkg-deb; do
    if ! command -v $cmd &>/dev/null; then
        echo "ERROR: $cmd is required but not found."
        exit 1
    fi
done

if [ ! -d "$PROJECT_ROOT/oncofix_online_backend" ]; then
    echo "ERROR: oncofix_online_backend not found in $PROJECT_ROOT"
    exit 1
fi

if [ ! -d "$PROJECT_ROOT/health-intake-form" ]; then
    echo "ERROR: health-intake-form not found in $PROJECT_ROOT"
    exit 1
fi

# ----------------------------------------------------------
# 1. Clean previous build
# ----------------------------------------------------------
echo "[2/8] Cleaning previous build..."
rm -rf "$BUILD_DIR"
mkdir -p "$PKG_DIR"

# ----------------------------------------------------------
# 2. Copy Debian control files
# ----------------------------------------------------------
echo "[3/8] Copying Debian package metadata..."
cp -r "$SCRIPT_DIR/debian/DEBIAN" "$PKG_DIR/"
cp -r "$SCRIPT_DIR/debian/etc" "$PKG_DIR/"
mkdir -p "$PKG_DIR/var/lib/oncofix"
mkdir -p "$PKG_DIR/var/log/oncofix"

# Update version and architecture in control file
sed -i "s/^Version:.*/Version: ${VERSION}/" "$PKG_DIR/DEBIAN/control"
sed -i "s/^Architecture:.*/Architecture: ${ARCH}/" "$PKG_DIR/DEBIAN/control"

# Set correct permissions on maintainer scripts
chmod 755 "$PKG_DIR/DEBIAN/preinst"
chmod 755 "$PKG_DIR/DEBIAN/postinst"
chmod 755 "$PKG_DIR/DEBIAN/prerm"
chmod 755 "$PKG_DIR/DEBIAN/postrm"

# ----------------------------------------------------------
# 3. Build backend
# ----------------------------------------------------------
echo "[4/8] Building backend..."
BACKEND_SRC="$PROJECT_ROOT/oncofix_online_backend"
BACKEND_DST="$PKG_DIR/opt/oncofix/oncofix_online_backend"
mkdir -p "$BACKEND_DST"

# Install deps and build
cd "$BACKEND_SRC"
npm ci --production=false
npm run build

# Prune devDependencies to reduce package size
npm prune --production

# Copy built files and runtime deps
cp -r "$BACKEND_SRC/dist" "$BACKEND_DST/"
cp -r "$BACKEND_SRC/node_modules" "$BACKEND_DST/"
cp "$BACKEND_SRC/package.json" "$BACKEND_DST/"
cp "$BACKEND_SRC/package-lock.json" "$BACKEND_DST/" 2>/dev/null || true

# Copy screen.py (camera + GPIO + sensor script)
cp "$BACKEND_SRC/screen.py" "$BACKEND_DST/"

# Copy AI model
if [ -d "$BACKEND_SRC/monai-cancer-predictor" ]; then
    echo "    Copying AI model..."
    mkdir -p "$BACKEND_DST/monai-cancer-predictor"
    cp "$BACKEND_SRC/monai-cancer-predictor/analyze_api.py" "$BACKEND_DST/monai-cancer-predictor/"
    cp "$BACKEND_SRC/monai-cancer-predictor/predict.py" "$BACKEND_DST/monai-cancer-predictor/"
    cp "$BACKEND_SRC/monai-cancer-predictor/predict_with_gradcam.py" "$BACKEND_DST/monai-cancer-predictor/" 2>/dev/null || true
    cp "$BACKEND_SRC/monai-cancer-predictor/simple_gradcam.py" "$BACKEND_DST/monai-cancer-predictor/" 2>/dev/null || true
    cp "$BACKEND_SRC/monai-cancer-predictor/gradcam.py" "$BACKEND_DST/monai-cancer-predictor/" 2>/dev/null || true
    cp "$BACKEND_SRC/monai-cancer-predictor/main.py" "$BACKEND_DST/monai-cancer-predictor/" 2>/dev/null || true
    cp "$BACKEND_SRC/monai-cancer-predictor/generate_summary_report.py" "$BACKEND_DST/monai-cancer-predictor/" 2>/dev/null || true
    cp "$BACKEND_SRC/monai-cancer-predictor/requirements.txt" "$BACKEND_DST/monai-cancer-predictor/"
    cp "$BACKEND_SRC/monai-cancer-predictor/mouth_cancer_model1.pth" "$BACKEND_DST/monai-cancer-predictor/" 2>/dev/null || true
    # Copy logos for report generation
    cp "$BACKEND_SRC/monai-cancer-predictor/"*.png "$BACKEND_DST/monai-cancer-predictor/" 2>/dev/null || true
fi

# Create runtime dirs (empty, will be populated at install)
mkdir -p "$BACKEND_DST/uploads"
mkdir -p "$BACKEND_DST/logs"
mkdir -p "$BACKEND_DST/backups"
mkdir -p "$BACKEND_DST/public/photos"
mkdir -p "$BACKEND_DST/photos"
mkdir -p "$BACKEND_DST/data"

# Symlink .env to centralized config
ln -sf /etc/oncofix/backend.env "$BACKEND_DST/.env"

# ----------------------------------------------------------
# 4. Build frontend
# ----------------------------------------------------------
echo "[5/8] Building frontend..."
FRONTEND_SRC="$PROJECT_ROOT/health-intake-form"
FRONTEND_DST="$PKG_DIR/opt/oncofix/health-intake-form"
mkdir -p "$FRONTEND_DST"

cd "$FRONTEND_SRC"

# Copy frontend env for build (uses port 3000 API)
cp "$SCRIPT_DIR/debian/etc/oncofix/frontend.env" "$FRONTEND_SRC/.env" 2>/dev/null || true

npm ci
npm run build

# Only need the built dist folder and package.json
cp -r "$FRONTEND_SRC/dist" "$FRONTEND_DST/"
cp "$FRONTEND_SRC/package.json" "$FRONTEND_DST/"

# ----------------------------------------------------------
# 5. Create version info file
# ----------------------------------------------------------
echo "[6/8] Writing version info..."
cat > "$PKG_DIR/opt/oncofix/VERSION" << EOF
version=${VERSION}
build_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
build_host=$(hostname)
node_version=$(node -v)
EOF

# ----------------------------------------------------------
# 6. Set ownership and permissions
# ----------------------------------------------------------
echo "[7/8] Setting permissions..."
# Ensure scripts are executable
find "$PKG_DIR/DEBIAN" -type f -name "pre*" -o -name "post*" | xargs chmod 755
# Config files readable by owner only
chmod 600 "$PKG_DIR/etc/oncofix/backend.env"
chmod 600 "$PKG_DIR/etc/oncofix/frontend.env"

# Calculate and set Installed-Size (in KB)
INSTALLED_SIZE=$(du -sk "$PKG_DIR" | cut -f1)
sed -i "s/^Installed-Size:.*/Installed-Size: ${INSTALLED_SIZE}/" "$PKG_DIR/DEBIAN/control"

# ----------------------------------------------------------
# 7. Build the .deb
# ----------------------------------------------------------
echo "[8/8] Building .deb package..."
cd "$SCRIPT_DIR"

# WSL workaround: /mnt/ filesystems don't support Unix permissions.
if echo "$PKG_DIR" | grep -q '/mnt/'; then
    echo "    Detected WSL mount — building in native Linux tmpdir..."
    NATIVE_BUILD="/tmp/oncofix-deb-build"
    rm -rf "$NATIVE_BUILD"
    cp -a "$PKG_DIR" "$NATIVE_BUILD"
    chmod 0755 "$NATIVE_BUILD/DEBIAN"
    find "$NATIVE_BUILD/DEBIAN" -type f -exec chmod 0755 {} \;
    chmod 0644 "$NATIVE_BUILD/DEBIAN/control"
    chmod 0644 "$NATIVE_BUILD/DEBIAN/conffiles"
    dpkg-deb -Zxz --build "$NATIVE_BUILD" "$OUTPUT_DEB"
    rm -rf "$NATIVE_BUILD"
else
    dpkg-deb -Zxz --build "$PKG_DIR" "$OUTPUT_DEB"
fi

# Show result
DEB_SIZE=$(du -h "$OUTPUT_DEB" | cut -f1)
echo ""
echo "================================================"
echo "  Package built successfully!"
echo "================================================"
echo "  File    : $OUTPUT_DEB"
echo "  Size    : $DEB_SIZE"
echo "  Version : $VERSION"
echo ""
echo "  Install on target device:"
echo "    sudo apt install ./oncofix_${VERSION}_${ARCH}.deb"
echo ""
echo "  After install:"
echo "    1. Edit /etc/oncofix/backend.env (JWT_SECRET, PHOTO_ENCRYPTION_KEY)"
echo "    2. Copy BigQuery credentials:"
echo "       scp bigquery-credentials.json oncofix@device:/opt/oncofix/oncofix_online_backend/"
echo "       sudo chown oncofix:oncofix /opt/oncofix/oncofix_online_backend/bigquery-credentials.json"
echo "    3. Register the device (one-time):"
echo "       curl -X POST http://localhost:3000/api/v1/devices/register ..."
echo "    4. Reboot and everything starts automatically"
echo ""
echo "  Services:"
echo "    Backend  : http://localhost:3000/api/v1  (systemctl status oncofix-backend)"
echo "    Frontend : http://localhost:5173         (systemctl status oncofix-frontend)"
echo ""
