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

# System now-playing helper (vendored, BSD-3): a framework loaded by
# /usr/bin/perl, whose com.apple.perl identity passes the MediaRemote
# entitlement check. Gives browser/any-app media info.
ADAPTER_SRC="Vendor/mediaremote-adapter"
FRAMEWORK_DIR="$APP/Contents/Resources/MediaRemoteAdapter.framework"
mkdir -p "$FRAMEWORK_DIR"
clang -dynamiclib -fobjc-arc -fmodules -arch arm64 \
    -I"$ADAPTER_SRC" -I"$ADAPTER_SRC/include" -I"$ADAPTER_SRC/src" \
    -framework Foundation -framework AppKit \
    -install_name @rpath/MediaRemoteAdapter.framework/MediaRemoteAdapter \
    -o "$FRAMEWORK_DIR/MediaRemoteAdapter" \
    "$ADAPTER_SRC"/src/adapter/*.m \
    "$ADAPTER_SRC"/src/private/MediaRemote.m \
    "$ADAPTER_SRC"/src/utility/*.m
cp "$ADAPTER_SRC/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
codesign --force --sign - "$FRAMEWORK_DIR/MediaRemoteAdapter"

codesign --force --deep --sign - "$APP"
echo "Built $APP"
