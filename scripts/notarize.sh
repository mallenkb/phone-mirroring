#!/usr/bin/env bash
#
# Sign (Developer ID + hardened runtime), notarize, and staple the app so it
# runs on other Macs without Gatekeeper warnings. The local build_and_run.sh
# uses ad-hoc signing, which only works on this machine — use this for sharing.
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

APP="${1:-dist/Android Mirroring.app}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="$ROOT_DIR/scripts/AndroidMirrorMac.release.entitlements"

: "${DEVELOPER_ID:?Set DEVELOPER_ID (Developer ID Application identity)}"
: "${APPLE_ID:?Set APPLE_ID (your Apple ID email)}"
: "${TEAM_ID:?Set TEAM_ID (10-character Team ID)}"
: "${APP_PASSWORD:?Set APP_PASSWORD (app-specific password)}"

if [[ ! -d "$APP" ]]; then
  echo "App bundle not found: $APP (run script/build_and_run.sh first)" >&2
  exit 1
fi

echo "==> Signing nested helpers (adb, scrcpy-server)"
while IFS= read -r -d '' bin; do
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$bin"
done < <(find "$APP/Contents" -type f \( -name adb -o -name 'scrcpy-server' \) -print0)

echo "==> Signing the main executable + app bundle"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$DEVELOPER_ID" "$APP/Contents/MacOS/"*
codesign --force --options runtime --timestamp --deep \
  --entitlements "$ENTITLEMENTS" --sign "$DEVELOPER_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Verifying release entitlements"
ENTITLEMENTS_OUT="$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)"
if printf '%s\n' "$ENTITLEMENTS_OUT" | grep -Eq 'com\.apple\.security\.cs\.(allow-dyld-environment-variables|disable-library-validation)'; then
  echo "Release app contains forbidden hardened-runtime exceptions." >&2
  exit 1
fi

echo "==> Submitting to Apple notary service (this can take a few minutes)"
ZIP="${APP%.app}.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
  --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" --wait

echo "==> Stapling the notarization ticket"
xcrun stapler staple "$APP"
rm -f "$ZIP"
echo "Done. $APP is signed, notarized, and ready to distribute."
