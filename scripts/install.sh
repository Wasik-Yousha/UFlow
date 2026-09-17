#!/usr/bin/env bash
#
# UFlow installer.
#
# Do NOT copy this file into Terminal — zsh chokes on the first line
# ("event not found"). Paste only this one line:
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
    # Follow the releases/latest redirect to its tag rather than asking
    # api.github.com: the API allows 60 anonymous calls an hour per IP, which
    # a shared office or campus network exhausts, failing the install.
    tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" || true)"
    tag="${tag##*/}"
    case "$tag" in v[0-9]*) ;; *) die "Could not find the latest release of $REPO. Check your connection and try again." ;; esac
    url="https://github.com/$REPO/releases/download/$tag/UFlow-${tag#v}.dmg"

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
    # The polite quit needs an Automation grant that may be refused or never
    # answered. Left running, the old process survives the copy and `open`
    # below just refocuses it — the install looks like it did nothing.
    for _ in 1 2 3 4 5; do pgrep -qf "$APP/Contents/MacOS/UFlow" || break; sleep 1; done
    pkill -f "$APP/Contents/MacOS/UFlow" 2>/dev/null || true
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

Hold Fn anywhere to dictate. Change the hotkey in Settings (Cmd+,).

EOF

open "$APP"
