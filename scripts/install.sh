#!/usr/bin/env bash
#
# UFlow installer.
#
#   curl -fsSL https://raw.githubusercontent.com/Wasik-Yousha/UFlow/main/scripts/install.sh | bash
#
# Downloads the latest release, installs to /Applications, and launches it.
#
# Why this is smoother than downloading the .dmg in a browser: macOS attaches a
# quarantine flag to browser downloads, and Gatekeeper refuses to open an app
# carrying one unless it is notarized by Apple. curl does not set that flag, so
# an app installed this way opens normally. Nothing is being bypassed that the
# user has not chosen — they ran this script deliberately.
#
# Local testing:  ./scripts/install.sh dist/UFlow-1.0.dmg

set -euo pipefail

REPO="${UFLOW_REPO:-Wasik-Yousha/UFlow}"
APP="/Applications/UFlow.app"
MOUNT=""
DMG=""
CLEANUP_DMG=0

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
    [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    [ "$CLEANUP_DMG" = 1 ] && [ -n "$DMG" ] && rm -f "$DMG"
    return 0
}
trap cleanup EXIT

[ "$(uname -s)" = "Darwin" ] || die "UFlow is a macOS app."

# macOS 26 or later — the Speech framework this is built on does not exist before that.
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 26 ] || die "UFlow needs macOS 26 or later (this is $(sw_vers -productVersion))."

# ---------------------------------------------------------------- get the disk image
if [ $# -ge 1 ]; then
    DMG="$1"
    [ -f "$DMG" ] || die "No such file: $DMG"
    say "Using local image $DMG"
else
    say "Looking up the latest UFlow release"
    url="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
           | grep '"browser_download_url"' | grep '\.dmg"' | head -1 | cut -d'"' -f4 || true)"
    [ -n "$url" ] || die "No .dmg found in the latest release of $REPO."

    DMG="$(mktemp -t uflow).dmg"
    CLEANUP_DMG=1
    say "Downloading $(basename "$url")"
    curl -fL# "$url" -o "$DMG"

    # Verify against the SHA256SUMS published with the release. This catches a
    # truncated or corrupted download; it is not a signature, since both files
    # come from the same place. Real authenticity needs notarization.
    sums_url="${url%/*}/SHA256SUMS"
    if expected="$(curl -fsSL "$sums_url" 2>/dev/null | grep -F "$(basename "$url")" | cut -d' ' -f1)" \
       && [ -n "$expected" ]; then
        actual="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
        [ "$actual" = "$expected" ] || die "Checksum mismatch — expected $expected, got $actual. Not installing."
        say "Checksum verified"
    else
        warn "No SHA256SUMS published for this release; skipping checksum check."
    fi
fi

# ---------------------------------------------------------------- install
if pgrep -qf "$APP/Contents/MacOS/UFlow" 2>/dev/null; then
    say "Quitting the running copy"
    osascript -e 'tell application "UFlow" to quit' 2>/dev/null || true
    sleep 1
fi

say "Mounting"
MOUNT="$(hdiutil attach "$DMG" -nobrowse -readonly | grep -o '/Volumes/.*' | head -1)"
[ -n "$MOUNT" ] || die "Could not mount the disk image."
[ -d "$MOUNT/UFlow.app" ] || die "That image does not contain UFlow.app."

say "Installing to /Applications"
rm -rf "$APP"
cp -R "$MOUNT/UFlow.app" "$APP"

# Belt and braces: clear the flag even if the image itself carried one.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

say "Installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
cat <<'EOF'

UFlow will ask for three permissions on first launch. All are required:

  Microphone         to hear you
  Input Monitoring   to see the global hotkey while another app is focused
  Accessibility      to type the transcript into the app you were using

Press Fn + Y anywhere to dictate. Change the hotkey in Settings (Cmd+,).

EOF

open "$APP"
