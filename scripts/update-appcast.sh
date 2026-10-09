#!/bin/bash
# Adds build/Kymara-<version>.dmg to appcast.xml, the Sparkle update feed the app reads from the main branch.
# Usage: scripts/update-appcast.sh <version> <release-notes.md>
# Signs the DMG with the EdDSA key in the login keychain (created once with Sparkle's generate_keys).
# Versions with a "-" (beta, rc) go in the "beta" channel, which the app only offers with pre-releases enabled.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$1"
NOTES="$2"
DMG="build/Kymara-$VERSION.dmg"
BIN=.build/artifacts/sparkle/Sparkle/bin
[ -x "$BIN/sign_update" ] || swift package resolve
[ -f "$DMG" ] || { echo "error: $DMG not found" >&2; exit 1; }

BUILD=$(plutil -extract CFBundleVersion raw Resources/Info.plist)
MIN_OS=$(plutil -extract LSMinimumSystemVersion raw Resources/Info.plist)
if grep -q "<sparkle:version>$BUILD</sparkle:version>" appcast.xml; then
    echo "error: build $BUILD is already in appcast.xml" >&2
    exit 1
fi
SIGNATURE=$("$BIN/sign_update" "$DMG")   # → sparkle:edSignature="…" length="…"
CHANNEL=""
[[ "$VERSION" == *-* ]] && CHANNEL="            <sparkle:channel>beta</sparkle:channel>"
# The update dialog shows the notes without the install instructions.
HTML=$(sed '/^## Install/,$d' "$NOTES" | gh api markdown -f mode=gfm -F text=@-)

ITEM=$(mktemp)
trap 'rm -f "$ITEM"' EXIT
cat > "$ITEM" <<EOF
        <item>
            <title>Kymara $VERSION</title>
            <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
$CHANNEL
            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
            <description><![CDATA[$HTML]]></description>
            <enclosure url="https://github.com/jorith88/kymara-sdr/releases/download/v$VERSION/Kymara-$VERSION.dmg" $SIGNATURE type="application/octet-stream"/>
        </item>
EOF
sed -i '' '/^$/d' "$ITEM"

# Newest item first, right after the channel header.
awk -v item="$ITEM" '{ print } /<!-- items -->/ { while ((getline line < item) > 0) print line }' \
    appcast.xml > appcast.xml.tmp && mv appcast.xml.tmp appcast.xml
xmllint --noout appcast.xml
echo "Added $VERSION (build $BUILD) to appcast.xml"
