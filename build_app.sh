#!/bin/bash
set -e

echo "Building AI Chalkboard release binary..."
swift build -c release

BUILD_DIR=".build/release"
APP_NAME="AIChalkboard.app"
APP_DIR="$BUILD_DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Creating .app bundle structure at $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp "$BUILD_DIR/AIChalkboard" "$MACOS_DIR/AIChalkboard"

cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AIChalkboard</string>
    <key>CFBundleIdentifier</key>
    <string>com.aichalkboard.overlay</string>
    <key>CFBundleName</key>
    <string>AI Chalkboard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHighResolutionMagnifyAllowed</key>
    <false/>
    <key>LSUIElement</key>
    <false/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>AI Chalkboard captures a selected display locally to verify annotation placement. Captures exclude AI Chalkboard overlays and are not written to disk.</string>
</dict>
</plist>
EOF

# SwiftPM linker-signs the bare executable before it is placed in the bundle.
# Sign the completed bundle again so the final code directory binds Info.plist
# (including the bundle identifier and Retina capability) instead of leaving
# those launch-critical settings outside the signature.
codesign --force --deep --sign - "$APP_DIR"

echo "App bundle created successfully at $(pwd)/$APP_DIR"
