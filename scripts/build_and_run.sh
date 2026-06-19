#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Phone Relay"
PRODUCT_NAME="Phone Relay"
# Keep local rebuilds on the same identity as the installed app. macOS Local
# Network and Notification authorization are keyed to the app identity, so the
# old placeholder id caused duplicate privacy entries and blocked Wi-Fi handoff.
BUNDLE_ID="${BUNDLE_ID:-com.mallenkb.PhoneRelay}"
APP_VERSION="${APP_VERSION:-1.0.9}"
BUILD_NUMBER="${BUILD_NUMBER:-16}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
EXECUTABLE_PATH="$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
BIN_DIR="$RESOURCES_DIR/bin"
LICENSES_DIR="$RESOURCES_DIR/LICENSES"
SCRCPY_SERVER="$ROOT_DIR/scrcpy-source/build-mac/server/scrcpy-server"
RESOURCE_SCRCPY_SERVER="$ROOT_DIR/Sources/PhoneRelay/Resources/scrcpy-server"
APP_ASSETS="$ROOT_DIR/App/Assets.xcassets"
RESOURCE_BUNDLE="$ROOT_DIR/.build/debug/PhoneRelay_PhoneRelay.bundle"

VERIFY=false
LOGS=false
BACKGROUND=false

for arg in "$@"; do
  case "$arg" in
    --verify) VERIFY=true ;;
    --logs) LOGS=true ;;
    --foreground) BACKGROUND=false ;;
    --background) BACKGROUND=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# The SwiftPM product is "PhoneRelayBinary"; the binary is renamed to
# $PRODUCT_NAME inside the bundle (CFBundleExecutable).
BUILD_PRODUCT="PhoneRelayBinary"

collect_app_pids() {
  {
    pgrep -x "$PRODUCT_NAME" 2>/dev/null || true
    pgrep -x "$BUILD_PRODUCT" 2>/dev/null || true
    pgrep -f "$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME" 2>/dev/null || true
    pgrep -f "$ROOT_DIR/.build/.*/$PRODUCT_NAME" 2>/dev/null || true
  } | sort -u
}

wait_for_app_exit() {
  for _ in {1..30}; do
    if [[ -z "$(collect_app_pids)" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# Kill old instances and wait until they are actually gone before launching a
# new one, so two copies never overlap (the app also self-terminates duplicate
# instances as a safety net).
old_pids="$(collect_app_pids)"
if [[ -n "$old_pids" ]]; then
  for pid in $old_pids; do
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  done
  if ! wait_for_app_exit; then
    for pid in $old_pids; do
      pkill -KILL -P "$pid" 2>/dev/null || true
      kill -KILL "$pid" 2>/dev/null || true
    done
    if ! wait_for_app_exit; then
      echo "warning: an existing $PRODUCT_NAME instance is still running; the new copy will defer to it" >&2
    fi
  fi
fi

cd "$ROOT_DIR"
swift build --product "$BUILD_PRODUCT"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$RESOURCES_DIR" "$BIN_DIR" "$LICENSES_DIR"
cp ".build/debug/$BUILD_PRODUCT" "$EXECUTABLE_PATH"
chmod +x "$EXECUTABLE_PATH"

if [[ -d "$APP_ASSETS" ]]; then
  ASSET_BUILD_DIR="$(mktemp -d)"
  xcrun actool "$APP_ASSETS" \
    --compile "$ASSET_BUILD_DIR" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ASSET_BUILD_DIR/asset-info.plist" >/dev/null
  if [[ -f "$ASSET_BUILD_DIR/Assets.car" ]]; then
    cp "$ASSET_BUILD_DIR/Assets.car" "$RESOURCES_DIR/Assets.car"
  fi
  if [[ -f "$ASSET_BUILD_DIR/AppIcon.icns" ]]; then
    cp "$ASSET_BUILD_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
  fi
  rm -rf "$ASSET_BUILD_DIR"
fi

if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/PhoneRelay_PhoneRelay.bundle"
fi

if [[ -f "$ROOT_DIR/THIRD_PARTY_NOTICES.md" ]]; then
  cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
fi

if [[ -f "$ROOT_DIR/LICENSES/scrcpy-APACHE-2.0.txt" ]]; then
  cp "$ROOT_DIR/LICENSES/scrcpy-APACHE-2.0.txt" "$LICENSES_DIR/scrcpy-APACHE-2.0.txt"
fi

if [[ -f "$SCRCPY_SERVER" ]]; then
  cp "$SCRCPY_SERVER" "$RESOURCES_DIR/scrcpy-server"
elif [[ -f "$RESOURCE_SCRCPY_SERVER" ]]; then
  cp "$RESOURCE_SCRCPY_SERVER" "$RESOURCES_DIR/scrcpy-server"
else
  echo "warning: scrcpy-server was not found; mirroring will fail until it is bundled" >&2
fi

if command -v adb >/dev/null 2>&1; then
  cp "$(command -v adb)" "$BIN_DIR/adb"
  chmod +x "$BIN_DIR/adb"
else
  echo "warning: adb was not found; device discovery will require adb in the app bundle" >&2
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Phone Relay for Android connects to your phone over your Wi-Fi network for wireless mirroring and automatic reconnect.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_adb._tcp</string>
    <string>_adb-tls-connect._tcp</string>
    <string>_adb-tls-pairing._tcp</string>
  </array>
</dict>
</plist>
PLIST

# Prefer a real Apple Development identity when one is in the keychain: TCC
# grants (Local Network, Notifications) are keyed to the signing identity, and
# ad-hoc signatures change every build, which silently revokes them.
if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
  # Prefer the Nokofio Platforms Ltd development cert; fall back to any
  # Apple Development identity, then ad-hoc.
  SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' \
    | grep "Marlon Alenya" | head -1)
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
  fi
  SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
fi

sign_if_macho() {
  local path="$1"
  if [[ -f "$path" ]] && file "$path" | grep -q "Mach-O"; then
    codesign --force --sign "$SIGNING_IDENTITY" "$path"
  fi
}

if command -v codesign >/dev/null 2>&1; then
  sign_if_macho "$EXECUTABLE_PATH"
  sign_if_macho "$BIN_DIR/adb"
  codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
fi

# Launch in the foreground by default so starting Phone Relay always brings the
# app forward. Pass --background only for scripted rebuild loops that should not
# steal focus.
if "$BACKGROUND"; then
  /usr/bin/open -n -g "$APP_BUNDLE" --args --launched-in-background
else
  /usr/bin/open -n "$APP_BUNDLE"
fi

if "$VERIFY"; then
  for _ in {1..20}; do
    if pgrep -x "$PRODUCT_NAME" >/dev/null; then
      echo "$APP_NAME is running."
      break
    fi
    sleep 0.25
  done
  pgrep -x "$PRODUCT_NAME" >/dev/null
fi

if "$LOGS"; then
  /usr/bin/log stream --info --predicate "process == '$PRODUCT_NAME'"
fi
