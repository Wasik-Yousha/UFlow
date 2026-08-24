#!/usr/bin/env bash
# Builds UFlow in Release and packages it as a shareable disk image.
#
#   ./scripts/make-dmg.sh            -> dist/UFlow-1.0.dmg
#
# The app is signed with whatever identity the project is configured for. If
# that is a self-signed certificate, see "Opening it on someone else's Mac" in
# README.md — the download will be blocked by Gatekeeper until they allow it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' YouFlow/Sources/Info.plist)"
DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Release/UFlow.app"
STAGE="$ROOT/build/dmg-stage"
OUT="$ROOT/dist/UFlow-$VERSION.dmg"

echo "==> Building UFlow $VERSION (Release)"
xcodebuild -project YouFlow.xcodeproj -scheme YouFlow -configuration Release \
           -derivedDataPath "$DERIVED" build \
  | grep -E "error:|warning: unable|BUILD" || true
[ -d "$APP" ] || { echo "Build produced no app at $APP"; exit 1; }

echo "==> Staging"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/UFlow.app"
ln -s /Applications "$STAGE/Applications"     # drag-to-install target

# Anyone who downloads this in a browser gets a quarantine flag and will be
# stopped by Gatekeeper, so ship the way past it inside the image itself.
cat > "$STAGE/Read Me First.txt" <<'NOTE'
UFlow
=====

1. Drag UFlow onto the Applications folder beside it.

2. The first time you open it, macOS will refuse, because UFlow is signed
   with a self-signed certificate rather than an Apple Developer ID.

   Go to  System Settings > Privacy & Security , scroll down, and click
   "Open Anyway" next to the message about UFlow.

   (Right-click > Open does NOT work for this on recent macOS versions.)

   To skip that step entirely next time, install from a terminal instead --
   downloads made with curl are not quarantined, so nothing blocks them:

       curl -fsSL https://raw.githubusercontent.com/Wasik-Yousha/UFlow/main/scripts/install.sh | bash

3. UFlow needs three permissions, and will ask for each one:

       Microphone         to hear you
       Input Monitoring   to see the global hotkey from other apps
       Accessibility      to type the transcript where you were working

4. Press Fn + Y anywhere to start dictating, and again to stop.
   Change the hotkey in Settings (Cmd + comma).
NOTE

# A custom volume icon, so the mounted image looks like the app. Built small
# on the fly: the app's own .icns carries a 1024px representation and would be
# most of the disk image's size for something only ever seen at 128px.
ICONSET="$ROOT/build/VolumeIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for px in 16 32 128 256; do
    sips -z $px $px "$ROOT/YouFlow/Resources/LogoMark.png" \
         --out "$ICONSET/icon_${px}x${px}.png" >/dev/null 2>&1
    sips -z $((px*2)) $((px*2)) "$ROOT/YouFlow/Resources/LogoMark.png" \
         --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null 2>&1
done
iconutil -c icns "$ICONSET" -o "$STAGE/.VolumeIcon.icns" 2>/dev/null || true
rm -rf "$ICONSET"
SetFile -a C "$STAGE" 2>/dev/null || true

echo "==> Creating disk image"
mkdir -p "$ROOT/dist"
rm -f "$OUT"
hdiutil create -volname "UFlow" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"

echo "==> Done: $OUT"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Authority|TeamIdentifier" || true
echo
echo "Size: $(du -h "$OUT" | cut -f1)"
