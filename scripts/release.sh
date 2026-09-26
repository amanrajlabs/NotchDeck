#!/bin/bash
# Build a universal NotchDeck.app and zip it for a GitHub release.
#
#   ./scripts/release.sh    ->  dist/NotchDeck-<version>.zip
#
# The zip is ad-hoc signed, NOT notarized: macOS quarantines it on download
# and users must approve it once (see "Install" in README.md).
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh universal

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
ZIP="dist/NotchDeck-$VERSION.zip"

rm -f "$ZIP"
# ditto, not `zip`: it preserves the bundle's symlinks and signature.
ditto -c -k --sequesterRsrc --keepParent dist/NotchDeck.app "$ZIP"

codesign --verify --deep --strict dist/NotchDeck.app
echo "Release: $ZIP ($(du -h "$ZIP" | cut -f1))"
