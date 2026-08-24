#!/usr/bin/env bash
# Regression guard for the deployed MCP executable's location.  Run only after
# `build_app.sh` has made the signed app bundle; this script itself never signs
# or packages anything.
set -euo pipefail

readonly deployed_executable="dist/AIChalkboard.app/Contents/MacOS/AIChalkboard"

test -x "$deployed_executable"
swift build -c release
test -x .build/release/AIChalkboard
test -x "$deployed_executable"

grep -Fqx 'DIST_DIR="dist"' build_app.sh
grep -Fqx "APP_DIR=\"\$DIST_DIR/\$APP_NAME\"" build_app.sh
grep -Fqx 'DEFAULT_BINARY_PATH = "./dist/AIChalkboard.app/Contents/MacOS/AIChalkboard"' test_mcp_stdio.py
grep -Fqx '      "command": "/Users/jack/Desktop/My Apps/AI-Chalkboard/dist/AIChalkboard.app/Contents/MacOS/AIChalkboard",' README.md
