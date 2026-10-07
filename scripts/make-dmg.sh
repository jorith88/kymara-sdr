#!/bin/bash
# Builds Kymara.app and packages it as build/Kymara-<version>.dmg (drag-to-Applications layout).
# Usage: scripts/make-dmg.sh [version]   (default: CFBundleShortVersionString from Info.plist)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)}"
./scripts/build-app.sh

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Kymara.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="build/Kymara-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Kymara $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
echo "Built: $DMG"
