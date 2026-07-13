#!/bin/bash
# Build NotchDeck and assemble a signed .app bundle in dist/.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/NotchDeck"
APP="dist/NotchDeck.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/"
cp "$BIN" "$APP/Contents/MacOS/NotchDeck"

codesign --force --deep --sign - "$APP"
echo "Built $APP"
