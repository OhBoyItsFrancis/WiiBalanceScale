#!/bin/bash
# Builds a double-clickable WiiBalanceScale.app (and a .zip of it) in macOS/build/.
# Requires Xcode or the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/WiiBalanceScale.app"
rm -rf build
mkdir -p build

# Universal (Apple silicon + Intel) build when the toolchain supports it, otherwise native only.
ARCH_FLAGS=(--arch arm64 --arch x86_64)
if ! swift build -c release "${ARCH_FLAGS[@]}"; then
    echo "Universal build failed; building for this Mac's architecture only."
    ARCH_FLAGS=()
    swift build -c release
fi
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/WiiBalanceScale" "$APP/Contents/MacOS/WiiBalanceScale"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon from the original application's icon.
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z $SIZE $SIZE Resources/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" > /dev/null
    sips -z $((SIZE * 2)) $((SIZE * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Ad-hoc signature so macOS will run it locally (it is not notarized).
codesign --force --sign - "$APP"

ditto -c -k --keepParent "$APP" build/WiiBalanceScale.zip
echo "Built $(pwd)/$APP"
