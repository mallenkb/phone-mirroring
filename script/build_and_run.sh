#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Android Mirroring"
PRODUCT_NAME="AndroidMirrorMac"
BUNDLE_ID="com.mallenkb.AndroidMirrorMac"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
EXECUTABLE_PATH="$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
BIN_DIR="$RESOURCES_DIR/bin"
SCRCPY_SERVER="$ROOT_DIR/scrcpy-source/build-mac/server/scrcpy-server"
RESOURCE_SCRCPY_SERVER="$ROOT_DIR/Sources/AndroidMirrorMac/Resources/scrcpy-server"
APP_ICON="$ROOT_DIR/Sources/AndroidMirrorMac/Resources/AppIcon.icns"
APP_ASSETS="$ROOT_DIR/Sources/AndroidMirrorMac/Resources/Assets.car"

VERIFY=false
LOGS=false

for arg in "$@"; do
  case "$arg" in
    --verify) VERIFY=true ;;
    --logs) LOGS=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

old_pids="$(pgrep -x "$PRODUCT_NAME" 2>/dev/null || true)"
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
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$RESOURCES_DIR" "$BIN_DIR"
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
  codesign --force --deep --options runtime --sign - "$APP_BUNDLE"
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
