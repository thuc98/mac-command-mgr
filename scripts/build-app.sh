#!/bin/bash
# Builds build/CommandManager.app (status-bar only, LSUIElement) and ad-hoc signs it.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product CommandManager
swift build -c "$CONFIG" --product cmgr
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/CommandManager.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CommandManager" "$APP/Contents/MacOS/CommandManager"
# CLI + MCP server; the app links it into your PATH as `cmgr` on every launch.
cp "$BIN_DIR/cmgr" "$APP/Contents/MacOS/cmgr"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate: swift scripts/make-icon.swift

# Ad-hoc signature (not sandboxed). Use a Developer ID + notarization for distribution.
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/cmgr"
codesign --force --sign - --timestamp=none "$APP"

echo "Built $APP"
echo "Run: open $APP   (move it to /Applications before enabling Open at login)"
