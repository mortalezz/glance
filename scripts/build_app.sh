#!/bin/bash
set -e

APP_NAME="Glance"
APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Building ${APP_NAME} in release mode..."
swift build -c release

echo "Packaging ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# Copy binary
cp ".build/release/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

# Copy AppIcon if available
if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# Create Info.plist with modern macOS privacy descriptions and file/folder associations
cat <<EOF > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.glance.mac</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.3</string>
    <key>CFBundleVersion</key>
    <string>5</string>
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
    <string>Glance needs permission to view RAW and image files on camera SD cards and external drives.</string>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>Glance needs permission to view images stored on network volumes.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
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
                <string>public.directory</string>
            </array>
        </dict>
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
    </array>
</dict>
</plist>
EOF

# Strip quarantine and provenance attributes from the bundle
echo "Clearing quarantine flags..."
xattr -cr "${APP_DIR}" 2>/dev/null || true

# Properly seal and ad-hoc sign the app bundle
echo "Ad-hoc signing ${APP_DIR}..."
codesign --force --deep --options runtime --entitlements scripts/entitlements.plist --sign - "${APP_DIR}"

echo "Successfully built and signed ${APP_DIR}!"
echo "Run with: open ${APP_DIR} /path/to/folder"
