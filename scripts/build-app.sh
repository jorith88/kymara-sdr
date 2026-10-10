#!/bin/bash
# Builds "Kymara.app" (arm64, release) into ./build, bundling librtlsdr + libusb when available.
set -euo pipefail
cd "$(dirname "$0")/.."

# RADE's sources are not checked in; an app without them would silently lack RADE mode.
./scripts/fetch-rade.sh --if-needed

swift build -c release --arch arm64
BIN_DIR=$(swift build -c release --arch arm64 --show-bin-path)
APP="build/Kymara.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN_DIR/Kymara" "$APP/Contents/MacOS/Kymara"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

if ! nm "$APP/Contents/MacOS/Kymara" | grep " T _rade_rx_process$" >/dev/null; then
    echo "error: the build has no RADE decoder (Sources/CRADE/vendor incomplete?)" >&2
    exit 1
fi
# The licenses of Sparkle (MIT, plus the code it includes) and of the code compiled in for RADE (BSD) ask for their
# notices to ship with the binary (librtlsdr's and libusb's are added where they are bundled, below).
LIC="$APP/Contents/Resources/Licenses"
mkdir -p "$LIC"
cp .build/checkouts/Sparkle/LICENSE "$LIC/Sparkle.txt"
cp Sources/CRADE/vendor/rade/LICENSE "$LIC/rade_c.txt"
cp Sources/CRADE/vendor/opus/COPYING "$LIC/Opus.txt"
cp Sources/CRADE/vendor/freedv/LICENSE "$LIC/freedv-backend.txt"

# Sparkle (in-app updates) is linked as @rpath/Sparkle.framework. ditto keeps the framework's symlinks, and
# the framework keeps Sparkle's own signature.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Kymara"

# Bundle librtlsdr and its libusb dependency so the app runs without Homebrew.
RTL=""
for p in /opt/homebrew/lib/librtlsdr.0.dylib /usr/local/lib/librtlsdr.0.dylib; do
    [ -f "$p" ] && RTL=$(realpath "$p") && break
done
# The Homebrew keg (…/Cellar/<name>/<version>) holds each library's AUTHORS and COPYING; they ship with the app.
bundle_license() {  # dylib name
    local keg
    keg=$(dirname "$(dirname "$1")")
    cat "$keg/AUTHORS" <(echo) "$keg/COPYING" > "$LIC/$2.txt"
}
if [ -n "$RTL" ]; then
    FW="$APP/Contents/Frameworks"
    bundle_license "$RTL" librtlsdr
    cp "$RTL" "$FW/librtlsdr.0.dylib"
    chmod u+w "$FW/librtlsdr.0.dylib"
    install_name_tool -id "@rpath/librtlsdr.0.dylib" "$FW/librtlsdr.0.dylib"
    USB_REF=$(otool -L "$RTL" | awk '/libusb/ {print $1}' | head -1)
    if [ -n "$USB_REF" ]; then
        cp "$(realpath "$USB_REF")" "$FW/libusb-1.0.0.dylib"
        bundle_license "$(realpath "$USB_REF")" libusb
        chmod u+w "$FW/libusb-1.0.0.dylib"
        install_name_tool -id "@rpath/libusb-1.0.0.dylib" "$FW/libusb-1.0.0.dylib"
        install_name_tool -change "$USB_REF" "@loader_path/libusb-1.0.0.dylib" "$FW/librtlsdr.0.dylib"
        codesign --force --sign - "$FW/libusb-1.0.0.dylib"
    fi
    codesign --force --sign - "$FW/librtlsdr.0.dylib"
    echo "Bundled $(basename "$RTL")"
else
    echo "warning: librtlsdr not found; the RTL-SDR source will need 'brew install librtlsdr'" >&2
fi

codesign --force --sign - "$APP"
echo "Built: $APP"
