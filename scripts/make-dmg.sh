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

echo "==> Creating disk image"
mkdir -p "$ROOT/dist"
rm -f "$OUT"
hdiutil create -volname "UFlow" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"

echo "==> Done: $OUT"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Authority|TeamIdentifier" || true
echo
echo "Size: $(du -h "$OUT" | cut -f1)"
