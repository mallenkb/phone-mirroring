#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AndroidMirrorMac"
PRODUCT_NAME="AndroidMirrorMac"
BUNDLE_ID="local.androidmirrormac"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
EXECUTABLE_PATH="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
SCRCPY_SERVER="$ROOT_DIR/scrcpy-source/build-mac/server/scrcpy-server"
RESOURCE_SCRCPY_SERVER="$ROOT_DIR/Sources/AndroidMirrorMac/Resources/scrcpy-server"

VERIFY=false
LOGS=false

for arg in "$@"; do
  case "$arg" in
    --verify) VERIFY=true ;;
    --logs) LOGS=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

old_pids="$(pgrep -x "$APP_NAME" 2>/dev/null || true)"
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
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp ".build/debug/$PRODUCT_NAME" "$EXECUTABLE_PATH"
chmod +x "$EXECUTABLE_PATH"

if [[ -f "$SCRCPY_SERVER" ]]; then
  cp "$SCRCPY_SERVER" "$APP_BUNDLE/Contents/MacOS/scrcpy-server"
elif [[ -f "$RESOURCE_SCRCPY_SERVER" ]]; then
  cp "$RESOURCE_SCRCPY_SERVER" "$APP_BUNDLE/Contents/MacOS/scrcpy-server"
else
  echo "warning: scrcpy-server was not found; mirroring will fail until it is bundled" >&2
fi

if command -v adb >/dev/null 2>&1; then
  cp "$(command -v adb)" "$APP_BUNDLE/Contents/MacOS/adb"
  chmod +x "$APP_BUNDLE/Contents/MacOS/adb"
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
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
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

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/adb" 2>/dev/null || true
  codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true
fi

/usr/bin/open -n "$APP_BUNDLE"

if "$VERIFY"; then
  for _ in {1..20}; do
    if pgrep -x "$APP_NAME" >/dev/null; then
      echo "$APP_NAME is running."
      break
    fi
    sleep 0.25
  done
  pgrep -x "$APP_NAME" >/dev/null
fi

if "$LOGS"; then
  /usr/bin/log stream --info --predicate "process == '$APP_NAME'"
fi
