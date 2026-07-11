#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Phone Relay"
PRODUCT_NAME="PhoneRelay"
# Keep local rebuilds on the same identity as the installed app. macOS Local
# Network and Notification authorization are keyed to the app identity, so the
# old placeholder id caused duplicate privacy entries and blocked Wi-Fi handoff.
BUNDLE_ID="${BUNDLE_ID:-com.mallenkb.PhoneRelay}"
APP_VERSION="${APP_VERSION:-1.0.31}"
BUILD_NUMBER="${BUILD_NUMBER:-33}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://phonerelay.mallenkb.com/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-BRG3UL9d/8qtx7RJdobbGi1q87hpbEflfn1izHj/qgc=}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
EXECUTABLE_PATH="$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
BIN_DIR="$RESOURCES_DIR/bin"
LICENSES_DIR="$RESOURCES_DIR/LICENSES"
RESOURCE_SCRCPY_SERVER="$ROOT_DIR/Sources/PhoneRelay/Resources/scrcpy-server"
VENDORED_ADB="$ROOT_DIR/App/Vendor/adb"
APP_ASSETS="$ROOT_DIR/App/Assets.xcassets"
RESOURCE_BUNDLE="$ROOT_DIR/.build/debug/PhoneRelay_PhoneRelay.bundle"
SPARKLE_FRAMEWORK="$ROOT_DIR/.build/debug/Sparkle.framework"

# SwiftUI property wrappers are compiler macros on recent SDKs. Apple's
# Command Line Tools can provide `swift` without the macOS SwiftUI macro plugin,
# which fails with "SwiftUIMacros.StateMacro ... plugin not found". Prefer an
# installed full Xcode unless the caller already chose a developer directory.
if [[ -z "${DEVELOPER_DIR:-}" ]] && xcode-select -p 2>/dev/null | grep -q "/CommandLineTools$"; then
  for candidate in "/Applications/Xcode.app" "/Applications/Xcode-beta.app"; do
    plugin="$candidate/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
    if [[ -f "$plugin" ]]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi

VERIFY=false
LOGS=false
# A person running this script in Terminal is explicitly opening the app, so
# launch it in front. Non-interactive automation builds/packages only unless it
# explicitly passes --foreground, --background, --verify, or --logs.
LAUNCH=false
BACKGROUND=false
if [[ -t 0 || -t 1 ]]; then
  LAUNCH=true
fi

for arg in "$@"; do
  case "$arg" in
    --verify) VERIFY=true; LAUNCH=true ;;
    --logs) LOGS=true; LAUNCH=true ;;
    --foreground) LAUNCH=true; BACKGROUND=false ;;
    --background) LAUNCH=true; BACKGROUND=true ;;
    --build-only) LAUNCH=false ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# Serialize the complete stop -> build -> package -> launch transaction. The
# old script only checked for a running app before the lengthy build, so two
# overlapping rebuilds could both observe no process and later launch their own
# copy. mkdir is atomic on macOS and gives every workspace one launch owner.
RUN_LOCK_DIR="$ROOT_DIR/.build/phonerelay-build-and-run.lock"
RUN_LOCK_PID_FILE="$RUN_LOCK_DIR/pid"

release_run_lock() {
  rm -f "$RUN_LOCK_PID_FILE"
  rmdir "$RUN_LOCK_DIR" 2>/dev/null || true
}

acquire_run_lock() {
  mkdir -p "$ROOT_DIR/.build"
  if mkdir "$RUN_LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$RUN_LOCK_PID_FILE"
    return 0
  fi

  # Give a process that just created the directory a moment to publish its PID.
  local owner_pid=""
  for _ in {1..10}; do
    owner_pid="$(sed -n '1p' "$RUN_LOCK_PID_FILE" 2>/dev/null || true)"
    [[ -n "$owner_pid" ]] && break
    sleep 0.05
  done

  if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
    echo "Phone Relay build-and-run is already active (pid $owner_pid); skipping duplicate launch."
    exit 0
  fi

  # Recover a stale lock left by an interrupted shell, then acquire it once.
  rm -f "$RUN_LOCK_PID_FILE"
  rmdir "$RUN_LOCK_DIR" 2>/dev/null || {
    echo "Unable to recover stale build-and-run lock: $RUN_LOCK_DIR" >&2
    exit 1
  }
  mkdir "$RUN_LOCK_DIR"
  printf '%s\n' "$$" > "$RUN_LOCK_PID_FILE"
}

acquire_run_lock
trap release_run_lock EXIT

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

# Kill old instances only for an intentional launch. A build-only automation
# must not close the app the user already has open.
if "$LAUNCH"; then
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
fi

cd "$ROOT_DIR"
scripts/verify_tracked_artifacts.sh
swift build --product "$BUILD_PRODUCT"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$RESOURCES_DIR" "$FRAMEWORKS_DIR" "$BIN_DIR" "$LICENSES_DIR"
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

if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
  cp -R "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/Sparkle.framework"
else
  echo "warning: Sparkle.framework was not found at $SPARKLE_FRAMEWORK; in-app updates will not run in this bundle" >&2
fi

if [[ -f "$ROOT_DIR/THIRD_PARTY_NOTICES.md" ]]; then
  cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
fi

if [[ -f "$ROOT_DIR/LICENSES/scrcpy-APACHE-2.0.txt" ]]; then
  cp "$ROOT_DIR/LICENSES/scrcpy-APACHE-2.0.txt" "$LICENSES_DIR/scrcpy-APACHE-2.0.txt"
fi

cp "$RESOURCE_SCRCPY_SERVER" "$RESOURCES_DIR/scrcpy-server"
cp "$VENDORED_ADB" "$BIN_DIR/adb"
chmod +x "$BIN_DIR/adb"

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
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_ED_KEY</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUEnableInstallerLauncherService</key>
  <true/>
  <key>SUAllowsAutomaticUpdates</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>86400</integer>
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

ensure_framework_rpath() {
  local executable="$1"
  local rpath="@executable_path/../Frameworks"
  if ! otool -l "$executable" | grep -Fq "path $rpath "; then
    install_name_tool -add_rpath "$rpath" "$executable"
  fi
}

ensure_framework_rpath "$EXECUTABLE_PATH"

if command -v codesign >/dev/null 2>&1; then
  if [[ -d "$FRAMEWORKS_DIR/Sparkle.framework" ]]; then
    codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$FRAMEWORKS_DIR/Sparkle.framework"
  fi
  sign_if_macho "$EXECUTABLE_PATH"
  sign_if_macho "$BIN_DIR/adb"
  codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
fi

# Non-interactive build-only callers stop here. They neither start a hidden app
# nor interfere with an app the user already opened.
if ! "$LAUNCH"; then
  echo "$APP_NAME built at $APP_BUNDLE"
  exit 0
fi

# Intentional opens are foreground by default. Background launch exists only
# for an explicit --background caller.
# Do not use `open -n`: it explicitly requests another application instance and
# can multiply connection/mirror windows when launch requests overlap.
if "$BACKGROUND"; then
  /usr/bin/open -g "$APP_BUNDLE" --args --launched-in-background
else
  /usr/bin/open "$APP_BUNDLE"
fi

if "$VERIFY"; then
  for _ in {1..20}; do
    if pgrep -x "$PRODUCT_NAME" >/dev/null; then
      sleep 1
      if pgrep -x "$PRODUCT_NAME" >/dev/null; then
        echo "$APP_NAME is running."
        exit 0
      fi
    fi
    sleep 0.25
  done
  echo "$APP_NAME did not stay running." >&2
  exit 1
fi

if "$LOGS"; then
  /usr/bin/log stream --info --predicate "process == '$PRODUCT_NAME'"
fi
