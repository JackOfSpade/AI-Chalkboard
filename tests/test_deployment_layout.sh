#!/usr/bin/env bash
# Regression guard for the deployed MCP executable's location. By default this
# checks a bundle assembled by the normal signing path. --assemble-test-bundle
# explicitly creates an ad-hoc-signed test bundle so the check is usable on a
# clean Mac or hosted macOS CI without the private release-signing key.
set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly test_dir
repo_root="$(cd "$test_dir/.." && pwd -P)"
readonly repo_root
cd "$repo_root"

case "${1:-}" in
    "")
        bundle_dir="dist"
        ;;
    --assemble-test-bundle)
        bash ./build_app.sh --test-ad-hoc-signing
        bundle_dir=".test-dist"
        ;;
    *)
        echo "Usage: $0 [--assemble-test-bundle]" >&2
        exit 64
        ;;
esac

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [--assemble-test-bundle]" >&2
    exit 64
fi

readonly bundle_app="$bundle_dir/AIChalkboard.app"
readonly bundle_executable="$bundle_app/Contents/MacOS/AIChalkboard"
readonly bundle_plist="$bundle_app/Contents/Info.plist"

test -x "$bundle_executable"
test -f "$bundle_plist"
plutil -lint "$bundle_plist"
bundle_short_version="$(plutil -extract CFBundleShortVersionString raw -o - "$bundle_plist")"
readonly bundle_short_version
bundle_build_version="$(plutil -extract CFBundleVersion raw -o - "$bundle_plist")"
readonly bundle_build_version
source_product_version="$(grep -m 1 -E '^[[:space:]]*static let productVersion = "' \
    Sources/Support/BuildMetadata.swift | sed -E 's/.*static let productVersion = "([^"]*)".*/\1/')"
readonly source_product_version
source_bundle_version="$(grep -m 1 -E '^[[:space:]]*static let bundleVersion = "' \
    Sources/Support/BuildMetadata.swift | sed -E 's/.*static let bundleVersion = "([^"]*)".*/\1/')"
readonly source_bundle_version
# The release and build versions have deliberately separate source constants.
# CFBundleVersion is Apple's one-to-three-component non-negative-integer build
# format, so pre-1.0 values such as "0" and "0.7" remain valid. Git revisions
# stay in the custom identifier because they cannot satisfy this contract.
test "$bundle_short_version" = "$source_product_version"
test "$bundle_build_version" = "$source_bundle_version"
bundle_version_pattern='^[0-9]+(\.[0-9]+){0,2}$'
readonly bundle_version_pattern
[[ "$bundle_build_version" =~ $bundle_version_pattern ]]
for valid_bundle_version in 0 0.7 0.7.11 1 1.2 1.2.3; do
    [[ "$valid_bundle_version" =~ $bundle_version_pattern ]]
done
for invalid_bundle_version in '' .1 1. 1..0 1.2.3.4 v1 1-beta -1 '1 2'; do
    if [[ "$invalid_bundle_version" =~ $bundle_version_pattern ]]; then
        echo "Invalid CFBundleVersion unexpectedly accepted: $invalid_bundle_version" >&2
        exit 1
    fi
done
test "$(plutil -extract NSHighResolutionCapable raw -o - "$bundle_plist")" = true
test "$(plutil -extract NSHighResolutionMagnifyAllowed raw -o - "$bundle_plist")" = false
codesign --verify --strict --verbose=2 "$bundle_app"
swift build -c release
test -x .build/release/AIChalkboard
test -x "$bundle_executable"

grep -Fqx 'readonly release_dist_dir="dist"' build_app.sh
grep -Fqx 'readonly test_dist_dir=".test-dist"' build_app.sh
grep -Fqx 'APP_DIR="$dist_dir/$APP_NAME"' build_app.sh
grep -Fqx '    codesign --force --timestamp=none --sign "$stable_signing_identity" "$APP_DIR"' build_app.sh
grep -Fqx '    codesign --force --sign - "$APP_DIR"' build_app.sh
grep -Fqx 'DEFAULT_BINARY_PATH = "./dist/AIChalkboard.app/Contents/MacOS/AIChalkboard"' test_mcp_stdio.py
grep -Fqx 'binary_path="$(pwd -P)/dist/AIChalkboard.app/Contents/MacOS/AIChalkboard"' README.md
grep -Fqx '      "command": "/replace/this/with/the/path/printed/above/AIChalkboard",' README.md
! grep -Fq '/Users/jack/Desktop/My Apps/AI-Chalkboard' README.md
