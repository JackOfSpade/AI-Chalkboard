#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly script_dir
cd "$script_dir"

readonly stable_signing_identity="65B98DF43D4BF99750538424213806A962381046"
signing_mode="stable"
readonly release_dist_dir="dist"
readonly test_dist_dir=".test-dist"

case "${1:-}" in
    "")
        ;;
    --test-ad-hoc-signing)
        # This opt-in exists only to exercise bundle assembly on clean macOS
        # machines and CI runners that cannot have the developer's private key.
        # It must never become the default: an ad-hoc signature has no persistent
        # designated requirement, so it cannot preserve existing TCC grants.
        signing_mode="test-ad-hoc"
        ;;
    *)
        echo "Usage: $0 [--test-ad-hoc-signing]" >&2
        exit 64
        ;;
esac

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [--test-ad-hoc-signing]" >&2
    exit 64
fi

echo "Building AI Chalkboard release binary..."
swift build -c release

BUILD_DIR=".build/release"
dist_dir="$release_dist_dir"
if [[ "$signing_mode" == "test-ad-hoc" ]]; then
    # Keep the test artifact completely separate from dist/, whose bundle may
    # carry a stable signature and existing macOS privacy grants.
    dist_dir="$test_dist_dir"
fi
APP_NAME="AIChalkboard.app"
APP_DIR="$dist_dir/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Pin local builds to one persistent identity so macOS privacy grants see
# rebuilds as updates of the same app instead of new ad-hoc cdhash identities.
# Fail instead of silently falling back to ad-hoc signing: that fallback would
# make Screen Recording and Accessibility permissions unstable again.
if [[ "$signing_mode" == "stable" ]]; then
    if ! security find-identity -v -p codesigning | grep -Fq "$stable_signing_identity"; then
        echo "Required AI Chalkboard code-signing identity is unavailable: $stable_signing_identity" >&2
        echo "Expected local certificate: AI Chalkboard Local Code Signing" >&2
        exit 1
    fi
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

# Both standard bundle versions are read from BuildMetadata so packaging has no
# version literals of its own. `bundleVersion` is an independently incremented
# distribution build number, not a Git revision: dirty suffixes and commit ids
# are unsuitable for CFBundleVersion and instead remain in the custom identifier
# below. This stays deterministic for source archives and build hosts without
# Git. Fail loudly rather than emitting malformed bundle metadata.
PRODUCT_VERSION="$(grep -m 1 -E '^[[:space:]]*static let productVersion = "' \
    Sources/Support/BuildMetadata.swift | sed -E 's/.*static let productVersion = "([^"]*)".*/\1/')"
if [[ ! "$PRODUCT_VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
    echo "Could not determine a valid productVersion from Sources/Support/BuildMetadata.swift (got: '${PRODUCT_VERSION}')." >&2
    echo "Expected a line there like: static let productVersion = \"2.1.0\"." >&2
    exit 1
fi
BUNDLE_VERSION="$(grep -m 1 -E '^[[:space:]]*static let bundleVersion = "' \
    Sources/Support/BuildMetadata.swift | sed -E 's/.*static let bundleVersion = "([^"]*)".*/\1/')"
# Apple's current CFBundleVersion contract is one to three period-separated
# non-negative integers. In particular, the single-component value "0" means
# 0.0.0, so do not reject pre-1.0 builds or force a three-part representation.
if [[ ! "$BUNDLE_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "Could not determine a valid bundleVersion from Sources/Support/BuildMetadata.swift (got: '${BUNDLE_VERSION}')." >&2
    echo "Expected a line there like: static let bundleVersion = \"1\"; increment it before each distributed build." >&2
    exit 1
fi
readonly BUNDLE_VERSION

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
    <key>CFBundleVersion</key>
    <string>${BUNDLE_VERSION}</string>
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
# bundle. Production assembly signs the completed bundle with the persistent
# local identity so the final code directory binds Info.plist and keeps a stable
# designated requirement across rebuilds. This app has no nested code, so --deep
# is unnecessary and would obscure future nested-signing mistakes.
if [[ "$signing_mode" == "stable" ]]; then
    codesign --force --timestamp=none --sign "$stable_signing_identity" "$APP_DIR"
else
    echo "WARNING: creating test-only ad-hoc-signed bundle; do not use it as a release build." >&2
    codesign --force --sign - "$APP_DIR"
fi

echo "App bundle created successfully at $script_dir/$APP_DIR"
