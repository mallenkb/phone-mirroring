#!/usr/bin/env bash
set -euo pipefail

APP="${1:-dist/PhoneRelay.app}"

if [[ ! -d "$APP" ]]; then
  echo "error: app bundle not found: $APP" >&2
  exit 1
fi

INFO="$APP/Contents/Info.plist"
ADB_HELPER="$APP/Contents/Resources/bin/adb"
SCRCPY_SERVER="$APP/Contents/Resources/scrcpy-server"

if [[ ! -x "$ADB_HELPER" ]]; then
  echo "error: release app is missing the executable adb helper: $ADB_HELPER" >&2
  exit 1
fi
if [[ ! -f "$SCRCPY_SERVER" ]]; then
  echo "error: release app is missing scrcpy-server: $SCRCPY_SERVER" >&2
  exit 1
fi
for architecture in x86_64 arm64; do
  if ! lipo -archs "$ADB_HELPER" | tr ' ' '\n' | grep -Fxq "$architecture"; then
    echo "error: bundled adb is missing the $architecture architecture" >&2
    exit 1
  fi
done
if ! /usr/bin/unzip -tqq "$SCRCPY_SERVER"; then
  echo "error: bundled scrcpy-server is not a valid jar/zip archive" >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Print :NSLocalNetworkUsageDescription" "$INFO" >/dev/null
bonjour_services="$(/usr/libexec/PlistBuddy -c "Print :NSBonjourServices" "$INFO")"
for service in _adb._tcp _adb-tls-connect._tcp _adb-tls-pairing._tcp; do
  if ! printf '%s\n' "$bonjour_services" | grep -qx "    $service"; then
    echo "error: Info.plist is missing Bonjour service $service" >&2
    exit 1
  fi
done

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

app_entitlements="$tmpdir/app-entitlements.plist"
codesign -d --entitlements :- "$APP" >"$app_entitlements" 2>/dev/null || {
  echo "error: could not read app entitlements from $APP" >&2
  exit 1
}

if [[ -f "$APP/Contents/embedded.provisionprofile" ]]; then
  profile_plist="$tmpdir/embedded-profile.plist"
  security cms -D -i "$APP/Contents/embedded.provisionprofile" >"$profile_plist" 2>/dev/null || {
    echo "error: could not decode embedded provisioning profile." >&2
    exit 1
  }

  provisions_all_devices="$(/usr/libexec/PlistBuddy -c "Print :ProvisionsAllDevices" "$profile_plist" 2>/dev/null || true)"
  if [[ "$provisions_all_devices" != "true" ]]; then
    echo "error: embedded provisioning profile is not a direct-distribution profile." >&2
    exit 1
  fi

  profile_app_id="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$profile_plist" 2>/dev/null || true)"
  signed_app_id="$(/usr/libexec/PlistBuddy -c "Print :com.apple.application-identifier" "$app_entitlements" 2>/dev/null || true)"
  if [[ -n "$profile_app_id" && -n "$signed_app_id" && "$profile_app_id" != "$signed_app_id" ]]; then
    echo "error: embedded provisioning profile does not match the signed app identifier." >&2
    exit 1
  fi
fi

if plutil -extract com.apple.security.app-sandbox raw "$app_entitlements" -o - >/dev/null 2>&1; then
  echo "error: release app must not be sandboxed; App Sandbox breaks adb Wi-Fi handoff." >&2
  exit 1
fi

for forbidden in \
  com.apple.security.cs.allow-dyld-environment-variables \
  com.apple.security.cs.disable-library-validation; do
  if plutil -extract "$forbidden" raw "$app_entitlements" -o - >/dev/null 2>&1; then
    echo "error: release app contains forbidden hardened-runtime exception: $forbidden" >&2
    exit 1
  fi
done

while IFS= read -r -d '' helper; do
  helper_entitlements="$tmpdir/$(basename "$helper").entitlements.plist"
  if codesign -d --entitlements :- "$helper" >"$helper_entitlements" 2>/dev/null; then
    for forbidden in com.apple.security.app-sandbox com.apple.security.inherit; do
      if plutil -extract "$forbidden" raw "$helper_entitlements" -o - >/dev/null 2>&1; then
        echo "error: release helper must not carry $forbidden: $helper" >&2
        exit 1
      fi
    done
  fi
done < <(find "$APP/Contents" -type f \( -name adb -o -name 'scrcpy-server' \) -print0)

codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null
echo "Release artifact verified: $APP"
