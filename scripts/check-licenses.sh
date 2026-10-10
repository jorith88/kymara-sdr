#!/bin/bash
# Checks that the bundled-libraries table in README.md lists the versions that build/Kymara.app ships, and that
# the app carries the license notices of Sparkle and of the code compiled in for RADE.
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

# RADE: source code compiled in at the commits fetch-rade.sh pinned (recorded in the vendor folder).
VERSION_FILE=Sources/CRADE/vendor/VERSION
[ -f "$VERSION_FILE" ] || { echo "error: $VERSION_FILE not found; run scripts/fetch-rade.sh" >&2; exit 1; }
pinned() { tr ' ' '\n' < "$VERSION_FILE" | sed -n "s/^$1=//p"; }
RADE_C=$(pinned RADE_C_COMMIT)
OPUS=$(pinned OPUS_COMMIT)
FREEDV=$(pinned FREEDV_BACKEND_COMMIT)
for f in Sparkle.txt rade_c.txt Opus.txt freedv-backend.txt; do
    [ -f "$APP/Contents/Resources/Licenses/$f" ] || { echo "error: $APP lacks Contents/Resources/Licenses/$f" >&2; exit 1; }
done

EXPECTED=(
"| [librtlsdr](https://github.com/steve-m/librtlsdr) | $RTL_VERSION | GPL-2.0-or-later | [v$RTL_VERSION](https://github.com/steve-m/librtlsdr/archive/refs/tags/v$RTL_VERSION.tar.gz) |"
"| [libusb](https://libusb.info) | $USB_VERSION | LGPL-2.1-or-later | [v$USB_VERSION](https://github.com/libusb/libusb/releases/download/v$USB_VERSION/libusb-$USB_VERSION.tar.bz2) |"
"| [Sparkle](https://sparkle-project.org) | $SPARKLE_VERSION | MIT | [$SPARKLE_VERSION](https://github.com/sparkle-project/Sparkle/tree/$SPARKLE_VERSION) |"
"| [rade_c](https://github.com/freedv/rade_c) (RADE V1 receiver) | ${RADE_C:0:7} | BSD-2-Clause | [${RADE_C:0:7}](https://github.com/freedv/rade_c/tree/$RADE_C) + [patches](scripts/patches) |"
"| [Opus](https://opus-codec.org) (FARGAN vocoder) | ${OPUS:0:7} | BSD-3-Clause | [${OPUS:0:7}](https://github.com/xiph/opus/tree/$OPUS) |"
"| [freedv-backend](https://github.com/tmiw/freedv-backend) (RADE callsign decoder) | ${FREEDV:0:7} | BSD-2-Clause | [${FREEDV:0:7}](https://github.com/tmiw/freedv-backend/tree/$FREEDV) |"
)

STATUS=0
for row in "${EXPECTED[@]}"; do
    if ! grep -qxF "$row" README.md; then
        [ $STATUS = 0 ] && echo "README.md license table is out of date. Replace these rows with:"
        echo "$row"
        STATUS=1
    fi
done
[ $STATUS = 0 ] && echo "README.md license table matches: librtlsdr $RTL_VERSION, libusb $USB_VERSION, Sparkle $SPARKLE_VERSION," \
    "rade_c ${RADE_C:0:7}, Opus ${OPUS:0:7}, freedv-backend ${FREEDV:0:7}"
exit $STATUS
