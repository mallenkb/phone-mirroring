#!/usr/bin/env bash
#
# Sign (Developer ID + hardened runtime), notarize, and staple the app so it
# runs on other Macs without Gatekeeper warnings. The local
# scripts/build_and_run.sh uses ad-hoc signing, which only works on this
# machine — use this for sharing.
#
# Requires a paid Apple Developer account. Provide credentials via env vars:
#   DEVELOPER_ID  Developer ID Application identity, e.g.
#                 "Developer ID Application: Jane Dev (AB12CD34EF)"
#   APPLE_ID      your Apple ID email
#   TEAM_ID       your 10-character Team ID
#   APP_PASSWORD  an app-specific password from appleid.apple.com
#
# Usage:  ./scripts/notarize.sh [path/to/App.app]
set -euo pipefail

APP="${1:-dist/PhoneRelay.app}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="$ROOT_DIR/scripts/PhoneRelay.release.entitlements"

: "${DEVELOPER_ID:?Set DEVELOPER_ID (Developer ID Application identity)}"
: "${APPLE_ID:?Set APPLE_ID (your Apple ID email)}"
: "${TEAM_ID:?Set TEAM_ID (10-character Team ID)}"
: "${APP_PASSWORD:?Set APP_PASSWORD (app-specific password)}"

if [[ ! -d "$APP" ]]; then
  echo "App bundle not found: $APP (run scripts/build_and_run.sh first)" >&2
  exit 1
fi

echo "==> Signing nested helpers (adb, scrcpy-server)"
# The app is unsandboxed (Wi-Fi adb/handoff needs it; see app-sandbox notes), so
# helpers must NOT carry sandbox-inherit entitlements — a sandbox-inherit helper
# is killed at exec (exit 133) when its parent is not sandboxed.
while IFS= read -r -d '' bin; do
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$bin"
done < <(find "$APP/Contents" -type f \( -name adb -o -name 'scrcpy-server' \) -print0)

echo "==> Signing the main executable + app bundle"
# Inside-out signing: helpers above, executables, then the bundle. No --deep —
# it is deprecated for signing and would stamp the app's entitlements onto
# every nested helper.
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$DEVELOPER_ID" "$APP/Contents/MacOS/"*
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$DEVELOPER_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Verifying release entitlements"
"$ROOT_DIR/scripts/verify_release_artifact.sh" "$APP"

echo "==> Submitting to Apple notary service (this can take a few minutes)"
ZIP="${APP%.app}.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
  --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" --wait

echo "==> Stapling the notarization ticket"
xcrun stapler staple "$APP"
rm -f "$ZIP"
echo "Done. $APP is signed, notarized, and ready to distribute."
