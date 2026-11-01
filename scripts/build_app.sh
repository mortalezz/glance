#!/bin/bash
set -euo pipefail

# Build script for Glance macOS Application Bundle (.app)
# Packages Glance into a standalone native macOS application with full app metadata,
# iconsets, and ad-hoc code signing.

APP_NAME="Glance"
BUILD_DIR=".build/release"
APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Building Glance in release mode..."
swift build -c release --disable-sandbox

echo "Packaging ${APP_NAME}.app..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy compiled binary
cp "${BUILD_DIR}/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"

# Copy App Icons (AppIcon is Dark default; AppIcon-Light, AppIcon-Dark, AppIcon-Tinted available for dynamic switching)
for icon in AppIcon.icns AppIcon-Dark.icns AppIcon-Light.icns AppIcon-Tinted.icns; do
    if [ -f "$icon" ]; then
        cp "$icon" "${RESOURCES_DIR}/$icon"
    fi
done

# Create Info.plist
cat << 'EOF' > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Glance</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.glance.mac</string>
    <key>CFBundleName</key>
    <string>Glance</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.3.2</string>
    <key>CFBundleVersion</key>
    <string>13</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Glance needs permission to view images in your Downloads folder.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Glance needs permission to view images in your Documents folder.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Glance needs permission to view images on your Desktop.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Glance needs permission to view images on removable volumes.</string>
    <key>NSDocumentClass</key>
    <string>NSDocument</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Image</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.image</string>
                <string>public.camera-raw-image</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Folder</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

# Clear extended attributes / quarantine
echo "Clearing quarantine flags..."
xattr -cr "${APP_DIR}" 2>/dev/null || true

# Code sign with ad-hoc identity & entitlements
echo "Ad-hoc signing ${APP_NAME}.app..."
if [ -f "scripts/entitlements.plist" ]; then
    codesign --force --deep --sign - --entitlements "scripts/entitlements.plist" "${APP_DIR}"
else
    codesign --force --deep --sign - "${APP_DIR}"
fi

echo "Successfully built and signed ${APP_NAME}.app!"
echo "Run with: open ${APP_NAME}.app /path/to/folder"
