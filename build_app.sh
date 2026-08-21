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

# Pin local builds to one persistent identity so macOS privacy grants see
# rebuilds as updates of the same app instead of new ad-hoc cdhash identities.
# Fail instead of silently falling back to ad-hoc signing: that fallback would
# make Screen Recording and Accessibility permissions unstable again.
SIGNING_IDENTITY="65B98DF43D4BF99750538424213806A962381046"
if ! security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY"; then
    echo "Required AI Chalkboard code-signing identity is unavailable: $SIGNING_IDENTITY" >&2
    echo "Expected local certificate: AI Chalkboard Local Code Signing" >&2
    exit 1
fi

# The bundled executable needs a deployable identity even though SwiftPM's
# bare executable has no Info.plist.  Git emits only hexadecimal commit ids;
# retain an explicit source fallback for archives/build hosts without Git.
BUILD_IDENTIFIER="${AI_CHALKBOARD_BUILD_IDENTIFIER:-$(git rev-parse --short=12 HEAD 2>/dev/null || echo source)}"
if [[ -z "${AI_CHALKBOARD_BUILD_IDENTIFIER:-}" ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # A build made from uncommitted source must never identify itself as the
    # clean commit it diverges from.  Include staged, unstaged, and untracked
    # changes because any of them can change the executable being packaged.
    if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
        BUILD_IDENTIFIER="${BUILD_IDENTIFIER}-dirty"
    fi
fi
if [[ ! "$BUILD_IDENTIFIER" =~ ^[A-Za-z0-9._-]{1,128}$ ]]; then
    echo "Invalid AI_CHALKBOARD_BUILD_IDENTIFIER; using source fallback." >&2
    BUILD_IDENTIFIER="source"
fi

# CFBundleShortVersionString is derived from Sources/Support/BuildMetadata.swift
# (productVersion) rather than duplicated as a second literal here. A hardcoded
# copy in both places is exactly the drift trap Sources/Support/DrawingDefaults.swift
# warns about: a version bump can update one and miss the other, and the missed
# one silently keeps lying about the shipped version. Fail loudly rather than
# ever emitting an empty or malformed version into the bundled Info.plist.
PRODUCT_VERSION="$(grep -m 1 -E '^[[:space:]]*static let productVersion = "' \
    Sources/Support/BuildMetadata.swift | sed -E 's/.*static let productVersion = "([^"]*)".*/\1/')"
if [[ ! "$PRODUCT_VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
    echo "Could not determine a valid productVersion from Sources/Support/BuildMetadata.swift (got: '${PRODUCT_VERSION}')." >&2
    echo "Expected a line there like: static let productVersion = \"2.1.0\"" >&2
    exit 1
fi

echo "Creating .app bundle structure at $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp "$BUILD_DIR/AIChalkboard" "$MACOS_DIR/AIChalkboard"

cat << EOF > "$CONTENTS_DIR/Info.plist"
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
    <string>${PRODUCT_VERSION}</string>
    <key>AIChalkboardBuildIdentifier</key>
    <string>${BUILD_IDENTIFIER}</string>
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

# SwiftPM linker-signs the bare executable ad-hoc before it is placed in the
# bundle. Sign the completed bundle with the persistent local identity so the
# final code directory binds Info.plist and keeps a stable designated
# requirement across rebuilds. This app has no nested code, so --deep is
# unnecessary and would obscure future nested-signing mistakes.
codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_DIR"

echo "App bundle created successfully at $(pwd)/$APP_DIR"
