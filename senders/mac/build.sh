#!/bin/bash
# Builds KerfSender.app for macOS 10.12 Sierra and later.
#
# Needs only the Xcode command line tools (any recent Xcode works: the app is plain
# Objective-C, so nothing from Swift has to run on 10.12). Run from anywhere:
#     senders/mac/build.sh
# The app is written to senders/mac/build/KerfSender.app and zipped next to it.
#
# The Intel slice targets 10.12; the Apple silicon slice targets 11.0 (the first macOS on
# those Macs). Set ARCHS="x86_64" to build Intel only.
set -euo pipefail
cd "$(dirname "$0")"

ARCHS="${ARCHS:-x86_64 arm64}"
OUT=build
APP="$OUT/KerfSender.app"
SRC=KerfSender
SOURCES=("$SRC"/*.m)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/obj"

SLICES=()
for arch in $ARCHS; do
  if [ "$arch" = "arm64" ]; then min=11.0; else min=10.12; fi
  bin="$OUT/obj/KerfSender-$arch"
  xcrun clang -arch "$arch" -mmacosx-version-min="$min" \
    -fobjc-arc -fmodules -O2 -Wall -Wno-deprecated-declarations \
    -framework Cocoa -framework IOKit \
    "${SOURCES[@]}" -o "$bin"
  SLICES+=("$bin")
done
xcrun lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/KerfSender"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Reuse KerfKutter's icon when the Xcode asset catalog has one.
ICONSET=../../Resources/Assets.xcassets/AppIcon.appiconset
if [ -d "$ICONSET" ] && command -v iconutil >/dev/null; then
  tmp="$OUT/obj/AppIcon.iconset"
  rm -rf "$tmp" && mkdir -p "$tmp"
  for f in "$ICONSET"/*.png; do cp "$f" "$tmp/"; done
  iconutil -c icns "$tmp" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
fi

# Ad-hoc signature so the Apple silicon slice runs; on 10.12 it is simply ignored.
codesign --force --sign - "$APP" >/dev/null

(cd "$OUT" && rm -f KerfSender-mac.zip && ditto -c -k --keepParent KerfSender.app KerfSender-mac.zip)
echo "Built $APP"
for arch in $ARCHS; do
  echo "  $arch: minimum macOS $(xcrun vtool -arch "$arch" -show-build "$APP/Contents/MacOS/KerfSender" 2>/dev/null | awk '/minos/ {print $2}')"
done
