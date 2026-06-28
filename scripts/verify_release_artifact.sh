#!/usr/bin/env bash
set -euo pipefail

APP="${1:-dist/PhoneRelay.app}"

if [[ ! -d "$APP" ]]; then
  echo "error: app bundle not found: $APP" >&2
  exit 1
fi

if [[ -f "$APP/Contents/embedded.provisionprofile" ]]; then
  echo "error: release app must not embed a provisioning profile." >&2
  echo "Developer ID releases should be signed directly; embedded profiles can pull in App Store-style capabilities." >&2
  exit 1
fi

INFO="$APP/Contents/Info.plist"
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
