#!/bin/bash
# Builds "GPU Watch.app" with just the Command Line Tools. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="GPU Watch"
APP=".build/$APP_NAME.app"
ICON_DIR=".build/AppIcon.iconset"

swift build -c release --product GPUWatch
BIN="$(swift build -c release --show-bin-path)/GPUWatch"

# The icon only needs drawing once.
if [ ! -f .build/AppIcon.icns ]; then
    rm -rf "$ICON_DIR"
    mkdir -p "$ICON_DIR"
    swift scripts/make_icon.swift .build/icon_1024.png
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" .build/icon_1024.png --out "$ICON_DIR/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" .build/icon_1024.png --out "$ICON_DIR/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICON_DIR" -o .build/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GPUWatch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP" "/Applications/$APP_NAME.app"
    echo "Installed /Applications/$APP_NAME.app"
else
    echo "Built $APP"
fi
