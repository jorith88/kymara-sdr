#!/bin/bash
# Checks that the bundled-libraries table in README.md lists the versions that build/Kymara.app ships.
# Run after scripts/build-app.sh. On a mismatch it prints the correct table rows and exits 1.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Kymara.app
[ -d "$APP" ] || { echo "error: $APP not found; run scripts/build-app.sh first" >&2; exit 1; }

# Same lookup as build-app.sh; the Homebrew Cellar path holds the version (…/Cellar/<name>/<version>/lib/…).
RTL=""
for p in /opt/homebrew/lib/librtlsdr.0.dylib /usr/local/lib/librtlsdr.0.dylib; do
    [ -f "$p" ] && RTL=$(realpath "$p") && break
done
[ -n "$RTL" ] || { echo "error: librtlsdr not found" >&2; exit 1; }
USB=$(realpath "$(otool -L "$RTL" | awk '/libusb/ {print $1}' | head -1)")
cellar_version() { echo "$1" | sed -E 's|.*/Cellar/[^/]+/([^/]+)/.*|\1|'; }
RTL_VERSION=$(cellar_version "$RTL")
USB_VERSION=$(cellar_version "$USB")
SPARKLE_VERSION=$(plutil -extract CFBundleShortVersionString raw \
    "$APP/Contents/Frameworks/Sparkle.framework/Resources/Info.plist")

EXPECTED=(
"| [librtlsdr](https://github.com/steve-m/librtlsdr) | $RTL_VERSION | GPL-2.0-or-later | [v$RTL_VERSION](https://github.com/steve-m/librtlsdr/archive/refs/tags/v$RTL_VERSION.tar.gz) |"
"| [libusb](https://libusb.info) | $USB_VERSION | LGPL-2.1-or-later | [v$USB_VERSION](https://github.com/libusb/libusb/releases/download/v$USB_VERSION/libusb-$USB_VERSION.tar.bz2) |"
"| [Sparkle](https://sparkle-project.org) | $SPARKLE_VERSION | MIT | [$SPARKLE_VERSION](https://github.com/sparkle-project/Sparkle/tree/$SPARKLE_VERSION) |"
)

STATUS=0
for row in "${EXPECTED[@]}"; do
    if ! grep -qxF "$row" README.md; then
        [ $STATUS = 0 ] && echo "README.md license table is out of date. Replace these rows with:"
        echo "$row"
        STATUS=1
    fi
done
[ $STATUS = 0 ] && echo "README.md license table matches: librtlsdr $RTL_VERSION, libusb $USB_VERSION, Sparkle $SPARKLE_VERSION"
exit $STATUS
