#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AndroidMirrorMac"
PRODUCT_NAME="AndroidMirrorMac"
BUNDLE_ID="local.androidmirrormac"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
EXECUTABLE_PATH="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

VERIFY=false
LOGS=false

for arg in "$@"; do
  case "$arg" in
    --verify) VERIFY=true ;;
    --logs) LOGS=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

pkill -x "$APP_NAME" 2>/dev/null || true

cd "$ROOT_DIR"
swift build --product "$PRODUCT_NAME"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp ".build/debug/$PRODUCT_NAME" "$EXECUTABLE_PATH"
chmod +x "$EXECUTABLE_PATH"

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
