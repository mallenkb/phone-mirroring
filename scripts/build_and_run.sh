#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Android Mirroring"
PRODUCT_NAME="AndroidMirrorMac"
# Overridable so release builds can use a real reverse-DNS id without churning
# the dev identity (Notification Center authorization is keyed to the id).
BUNDLE_ID="${BUNDLE_ID:-org.example.AndroidMirrorMac}"
APP_VERSION="${APP_VERSION:-0.1.0}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
EXECUTABLE_PATH="$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
BIN_DIR="$RESOURCES_DIR/bin"
LICENSES_DIR="$RESOURCES_DIR/LICENSES"
SCRCPY_SERVER="$ROOT_DIR/scrcpy-source/build-mac/server/scrcpy-server"
RESOURCE_SCRCPY_SERVER="$ROOT_DIR/Sources/AndroidMirrorMac/Resources/scrcpy-server"
APP_ICON="$ROOT_DIR/Sources/AndroidMirrorMac/Resources/AppIcon.icns"
APP_ASSETS="$ROOT_DIR/Sources/AndroidMirrorMac/Resources/Assets.car"
RESOURCE_BUNDLE="$ROOT_DIR/.build/debug/AndroidMirrorMac_AndroidMirrorMac.bundle"

VERIFY=false
LOGS=false

for arg in "$@"; do
  case "$arg" in
    --verify) VERIFY=true ;;
    --logs) LOGS=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

collect_app_pids() {
  {
    pgrep -x "$PRODUCT_NAME" 2>/dev/null || true
    pgrep -f "$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME" 2>/dev/null || true
    pgrep -f "$ROOT_DIR/.build/.*/$PRODUCT_NAME" 2>/dev/null || true
  } | sort -u
}

old_pids="$(collect_app_pids)"
if [[ -n "$old_pids" ]]; then
  for pid in $old_pids; do
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  done
  sleep 0.5
  for pid in $old_pids; do
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
fi

cd "$ROOT_DIR"
swift build --product "$PRODUCT_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$RESOURCES_DIR" "$BIN_DIR" "$LICENSES_DIR"
cp ".build/debug/$PRODUCT_NAME" "$EXECUTABLE_PATH"
chmod +x "$EXECUTABLE_PATH"

if [[ -f "$APP_ICON" ]]; then
  cp "$APP_ICON" "$RESOURCES_DIR/AppIcon.icns"
else
  echo "warning: AppIcon.icns was not found; the app bundle will use the default icon" >&2
fi

if [[ -f "$APP_ASSETS" ]]; then
  cp "$APP_ASSETS" "$RESOURCES_DIR/Assets.car"
fi

if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/AndroidMirrorMac_AndroidMirrorMac.bundle"
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
  <string>$APP_VERSION</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
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
  <string>Android Mirroring connects to your phone over your Wi-Fi network for wireless mirroring and automatic reconnect.</string>
</dict>
</plist>
PLIST

sign_if_macho() {
  local path="$1"
  if [[ -f "$path" ]] && file "$path" | grep -q "Mach-O"; then
    codesign --force --sign - "$path"
  fi
}

if command -v codesign >/dev/null 2>&1; then
  sign_if_macho "$EXECUTABLE_PATH"
  sign_if_macho "$BIN_DIR/adb"
  codesign --force --options runtime --sign - "$APP_BUNDLE"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
fi

/usr/bin/open -n "$APP_BUNDLE"

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
