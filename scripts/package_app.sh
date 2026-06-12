#!/usr/bin/env bash
set -euo pipefail

APP="${1:-dist/PhoneRelay.app}"
APP_NAME="${APP_NAME:-PhoneRelay}"
PRODUCT_NAME="${PRODUCT_NAME:-PhoneRelay}"
BUNDLE_ID="${BUNDLE_ID:-com.mallenkb.PhoneRelay}"
APP_VERSION="${APP_VERSION:-0.1.1}"
BUILD_NUMBER="${BUILD_NUMBER:-2}"
# Prefer a real Apple Development identity when one is in the keychain: TCC
# grants (Local Network, Notifications) are keyed to the signing identity, and
# ad-hoc signatures change every build, which silently revokes them.
if [ -z "${SIGNING_IDENTITY:-}" ]; then
  # Prefer the Nokofio Platforms Ltd development cert; fall back to any
  # Apple Development identity, then ad-hoc.
  SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' \
    | grep "Marlon Alenya" | head -1 || true)
  if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1 || true)
  fi
  SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
fi
OPEN_AFTER_PACKAGE="${OPEN_AFTER_PACKAGE:-0}"
BUILD_DIR="scrcpy-source/build-mac"
SCRCPY_SERVER="$BUILD_DIR/server/scrcpy-server"
RESOURCE_SCRCPY_SERVER="Sources/PhoneRelay/Resources/scrcpy-server"
ASSET_CATALOG="App/Assets.xcassets"
# The SwiftPM product is "PhoneRelay" (Dock name for debug runs); the
# binary is renamed to $PRODUCT_NAME inside the bundle (CFBundleExecutable).
HOST_BIN=".build/release/PhoneRelayBinary"
RESOURCE_BUNDLE=".build/release/PhoneRelay_PhoneRelay.bundle"
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
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/PhoneRelay_PhoneRelay.bundle"
fi

if [ -d "$ASSET_CATALOG" ]; then
  ASSET_BUILD_DIR="$TMP_HELPERS/assets"
  mkdir -p "$ASSET_BUILD_DIR"
  xcrun actool "$ASSET_CATALOG" \
    --compile "$ASSET_BUILD_DIR" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ASSET_BUILD_DIR/asset-info.plist" >/dev/null
  if [ -f "$ASSET_BUILD_DIR/Assets.car" ]; then
    cp "$ASSET_BUILD_DIR/Assets.car" "$RESOURCES_DIR/Assets.car"
  fi
  if [ -f "$ASSET_BUILD_DIR/AppIcon.icns" ]; then
    cp "$ASSET_BUILD_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
  fi
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
  <key>NSLocalNetworkUsageDescription</key>
  <string>PhoneRelay for Android connects to your phone over your Wi-Fi network for wireless mirroring and automatic reconnect.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_adb._tcp</string>
    <string>_adb-tls-connect._tcp</string>
    <string>_adb-tls-pairing._tcp</string>
  </array>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  if [ -f "$HELPER_BIN_DIR/adb" ]; then
    codesign --force --sign "$SIGNING_IDENTITY" "$HELPER_BIN_DIR/adb"
  fi
  codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
fi

if [ "$OPEN_AFTER_PACKAGE" = "1" ]; then
  open "$APP"
fi
