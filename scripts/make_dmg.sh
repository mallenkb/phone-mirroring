#!/usr/bin/env bash
set -euo pipefail

# Assembles the Phone Relay disk image: stages the app + an Applications symlink,
# renders the themed background (scripts/dmg_background.swift), and drives Finder
# to lay out the icons over it before converting to a compressed .dmg.
#
# Usage:   scripts/make_dmg.sh [path/to/Phone Relay.app]
# Env:     VOL_NAME, DMG_APP_NAME, APP_VERSION, OUT  (all optional)
#
# Note: laying out the window uses AppleScript to control Finder, so the first
# run may surface a one-time macOS Automation permission prompt for the terminal.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_IN="${1:-$ROOT/dist/PhoneRelay.app}"
VOL_NAME="${VOL_NAME:-Phone Relay Installer}"

[ -d "$APP_IN" ] || { echo "error: app not found at $APP_IN (run scripts/package_app.sh first)"; exit 1; }
APP_DIR="$(cd "$(dirname "$APP_IN")" && pwd)"
APP_IN="$APP_DIR/$(basename "$APP_IN")"
APP_BASENAME="$(basename "$APP_IN")"
STAGED_APP_BASENAME="${DMG_APP_NAME:-Phone Relay.app}"
[[ "$STAGED_APP_BASENAME" == *.app ]] || STAGED_APP_BASENAME="$STAGED_APP_BASENAME.app"

APP_VERSION="${APP_VERSION:-$(defaults read "$APP_IN/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)}"
OUT="${OUT:-$ROOT/dist/PhoneRelay${APP_VERSION:+-$APP_VERSION}.dmg}"

STAGE="$(mktemp -d)"
RW_DMG="$(mktemp -u).dmg"
MOUNT="/Volumes/$VOL_NAME"
cleanup() {
  hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
  rm -rf "$STAGE" "$RW_DMG"
}
trap cleanup EXIT

echo "Staging $APP_BASENAME as $STAGED_APP_BASENAME ..."
mkdir -p "$STAGE/.background"
cp -R "$APP_IN" "$STAGE/$STAGED_APP_BASENAME"
ln -s /Applications "$STAGE/Applications"
swift "$ROOT/scripts/dmg_background.swift" "$STAGE/.background/background.png"
# Enforce 144 dpi so the 1440×880 px image is treated as a 720×440 pt window
# background (matching the window bounds + Finder icon positions below).
sips -s dpiWidth 144 -s dpiHeight 144 "$STAGE/.background/background.png" >/dev/null

echo "Creating writable image ..."
hdiutil create -srcfolder "$STAGE" -volname "$VOL_NAME" -fs HFS+ -format UDRW -ov "$RW_DMG" >/dev/null
hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
hdiutil attach "$RW_DMG" -nobrowse -mountpoint "$MOUNT" >/dev/null

echo "Laying out window ..."
osascript <<OSA || echo "warning: Finder layout step failed (Automation permission?). The .dmg is still built but icons may be unpositioned."
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 920, 560}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 150
    set text size of theViewOptions to 15
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "$STAGED_APP_BASENAME" of container window to {205, 222}
    set position of item "Applications" of container window to {515, 222}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

sync
hdiutil detach "$MOUNT" >/dev/null
echo "Compressing -> $OUT"
rm -f "$OUT"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null

echo "Wrote $OUT"
