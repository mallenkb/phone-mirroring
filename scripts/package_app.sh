#!/usr/bin/env bash
set -euo pipefail

APP="${1:-dist/Android Mirroring.app}"
APP_NAME="${APP_NAME:-Android Mirroring}"
PRODUCT_NAME="${PRODUCT_NAME:-AndroidMirrorMac}"
BUNDLE_ID="${BUNDLE_ID:-org.example.AndroidMirrorMac}"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
OPEN_AFTER_PACKAGE="${OPEN_AFTER_PACKAGE:-0}"
BUILD_DIR="scrcpy-source/build-mac"
SCRCPY_SERVER="$BUILD_DIR/server/scrcpy-server"
RESOURCE_SCRCPY_SERVER="Sources/AndroidMirrorMac/Resources/scrcpy-server"
APP_ICON="Sources/AndroidMirrorMac/Resources/AppIcon.icns"
ASSET_CATALOG="Sources/AndroidMirrorMac/Resources/Assets.car"
HOST_BIN=".build/release/AndroidMirrorMac"
RESOURCE_BUNDLE=".build/release/AndroidMirrorMac_AndroidMirrorMac.bundle"
BIN_DIR="$APP/Contents/MacOS"
RESOURCES_DIR="$APP/Contents/Resources"
HELPER_BIN_DIR="$RESOURCES_DIR/bin"
LICENSES_DIR="$RESOURCES_DIR/LICENSES"

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
mkdir -p "$BIN_DIR" "$RESOURCES_DIR" "$HELPER_BIN_DIR" "$LICENSES_DIR"

cp "$HOST_BIN" "$BIN_DIR/$PRODUCT_NAME"
chmod +x "$BIN_DIR/$PRODUCT_NAME"

if [ -d "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/AndroidMirrorMac_AndroidMirrorMac.bundle"
fi

if [ -f "$APP_ICON" ]; then
  cp "$APP_ICON" "$RESOURCES_DIR/AppIcon.icns"
fi

if [ -f "$ASSET_CATALOG" ]; then
  cp "$ASSET_CATALOG" "$RESOURCES_DIR/Assets.car"
fi

if [ -f "THIRD_PARTY_NOTICES.md" ]; then
  cp "THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
fi

if [ -f "LICENSES/scrcpy-APACHE-2.0.txt" ]; then
  cp "LICENSES/scrcpy-APACHE-2.0.txt" "$LICENSES_DIR/scrcpy-APACHE-2.0.txt"
fi

# Audio and video are handled in-process; only the scrcpy-server jar (pushed to
# the device) and adb are needed. The standalone scrcpy CLI is no longer bundled.
if [ -f "$SCRCPY_SERVER" ]; then
  cp "$SCRCPY_SERVER" "$RESOURCES_DIR/scrcpy-server"
elif [ -f "$RESOURCE_SCRCPY_SERVER" ]; then
  cp "$RESOURCE_SCRCPY_SERVER" "$RESOURCES_DIR/scrcpy-server"
else
  echo "warning: scrcpy-server was not found; mirroring will fail until it is bundled" >&2
fi

if [ -x "$TMP_HELPERS/adb" ]; then
  cp "$TMP_HELPERS/adb" "$HELPER_BIN_DIR/adb"
elif command -v adb >/dev/null 2>&1; then
  cp "$(command -v adb)" "$HELPER_BIN_DIR/adb"
else
  echo "warning: adb was not found; device discovery will require adb in the app bundle" >&2
fi

if [ -f "$HELPER_BIN_DIR/adb" ]; then
  chmod +x "$HELPER_BIN_DIR/adb"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  if [ -f "$HELPER_BIN_DIR/adb" ]; then
    codesign --force --sign "$SIGNING_IDENTITY" "$HELPER_BIN_DIR/adb"
  fi
  codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
fi

if [ "$OPEN_AFTER_PACKAGE" = "1" ]; then
  open "$APP"
fi
