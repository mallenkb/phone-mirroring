#!/usr/bin/env bash
set -euo pipefail

APP="${1:-dist/AndroidMirrorMac.app}"
BUILD_DIR="scrcpy-source/build-mac"
SCRCPY_SERVER="$BUILD_DIR/server/scrcpy-server"
RESOURCE_SCRCPY_SERVER="Sources/AndroidMirrorMac/Resources/scrcpy-server"
HOST_BIN=".build/release/AndroidMirrorMac"
BIN_DIR="$APP/Contents/MacOS"

swift build -c release

TMP_HELPERS="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_HELPERS"
}
trap cleanup EXIT

if [ -x "$APP/Contents/MacOS/adb" ]; then
  cp "$APP/Contents/MacOS/adb" "$TMP_HELPERS/adb"
elif [ -x "$APP/Contents/Resources/bin/adb" ]; then
  cp "$APP/Contents/Resources/bin/adb" "$TMP_HELPERS/adb"
fi

rm -rf "$APP"
mkdir -p "$BIN_DIR" "$APP/Contents/Resources"

cp "$HOST_BIN" "$BIN_DIR/AndroidMirrorMac"
chmod +x "$BIN_DIR/AndroidMirrorMac"

# Audio and video are handled in-process; only the scrcpy-server jar (pushed to
# the device) and adb are needed. The standalone scrcpy CLI is no longer bundled.
if [ -f "$SCRCPY_SERVER" ]; then
  cp "$SCRCPY_SERVER" "$BIN_DIR/scrcpy-server"
elif [ -f "$RESOURCE_SCRCPY_SERVER" ]; then
  cp "$RESOURCE_SCRCPY_SERVER" "$BIN_DIR/scrcpy-server"
else
  echo "warning: scrcpy-server was not found; mirroring will fail until it is bundled" >&2
fi

if [ -x "$TMP_HELPERS/adb" ]; then
  cp "$TMP_HELPERS/adb" "$BIN_DIR/adb"
elif command -v adb >/dev/null 2>&1; then
  cp "$(command -v adb)" "$BIN_DIR/adb"
else
  echo "warning: adb was not found; device discovery will require adb in the app bundle" >&2
fi

if [ -f "$BIN_DIR/adb" ]; then
  chmod +x "$BIN_DIR/adb"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>AndroidMirrorMac</string>
  <key>CFBundleIdentifier</key>
  <string>com.mallenkb.AndroidMirrorScrcpy</string>
  <key>CFBundleName</key>
  <string>Android Mirror Scrcpy</string>
  <key>CFBundleDisplayName</key>
  <string>Android Mirror Scrcpy</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$BIN_DIR/adb" 2>/dev/null || true
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

open "$APP"
