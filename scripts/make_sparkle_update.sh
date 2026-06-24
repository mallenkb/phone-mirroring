#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_IN="${1:-$ROOT/dist/PhoneRelay.app}"
OUT_DIR="${SPARKLE_OUT_DIR:-$ROOT/dist/sparkle}"
SPARKLE_BIN="${SPARKLE_BIN:-$ROOT/.build/release}"
GENERATE_APPCAST="${GENERATE_APPCAST:-}"

[ -d "$APP_IN" ] || { echo "error: app not found at $APP_IN (run scripts/package_app.sh first)" >&2; exit 1; }

if [ -z "$GENERATE_APPCAST" ]; then
  if [ -x "$SPARKLE_BIN/generate_appcast" ]; then
    GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
  elif [ -x "$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" ]; then
    GENERATE_APPCAST="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
  elif [ -x "$ROOT/.build-codex/artifacts/sparkle/Sparkle/bin/generate_appcast" ]; then
    GENERATE_APPCAST="$ROOT/.build-codex/artifacts/sparkle/Sparkle/bin/generate_appcast"
  else
    echo "error: Sparkle generate_appcast tool not found. Run swift build first or set GENERATE_APPCAST." >&2
    exit 1
  fi
fi

APP_DIR="$(cd "$(dirname "$APP_IN")" && pwd)"
APP_IN="$APP_DIR/$(basename "$APP_IN")"
VERSION="$(defaults read "$APP_IN/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
BUILD_NUMBER="$(defaults read "$APP_IN/Contents/Info" CFBundleVersion 2>/dev/null || true)"
[ -n "$VERSION" ] || { echo "error: could not read CFBundleShortVersionString from $APP_IN" >&2; exit 1; }
[ -n "$BUILD_NUMBER" ] || { echo "error: could not read CFBundleVersion from $APP_IN" >&2; exit 1; }

ZIP_NAME="${SPARKLE_ZIP_NAME:-PhoneRelay-$VERSION.zip}"
ZIP_PATH="$OUT_DIR/$ZIP_NAME"
DOWNLOAD_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-https://github.com/mallenkb/phone-mirroring/releases/download/v$VERSION/}"
RELEASE_LINK="${SPARKLE_RELEASE_LINK:-https://github.com/mallenkb/phone-mirroring/releases/tag/v$VERSION}"

mkdir -p "$OUT_DIR"
rm -f "$ZIP_PATH"

echo "Creating Sparkle update archive -> $ZIP_PATH"
ditto -c -k --keepParent "$APP_IN" "$ZIP_PATH"

if [ -n "${SPARKLE_RELEASE_NOTES:-}" ] && [ -f "$SPARKLE_RELEASE_NOTES" ]; then
  cp "$SPARKLE_RELEASE_NOTES" "$OUT_DIR/${ZIP_NAME%.*}.${SPARKLE_RELEASE_NOTES##*.}"
fi

args=(
  "--download-url-prefix" "$DOWNLOAD_PREFIX"
  "--link" "$RELEASE_LINK"
  "--maximum-versions" "${SPARKLE_MAXIMUM_VERSIONS:-3}"
  "$OUT_DIR"
)

echo "Generating Sparkle appcast in $OUT_DIR"
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GENERATE_APPCAST" --ed-key-file - "${args[@]}"
elif [ -n "${SPARKLE_ED_KEY_FILE:-}" ]; then
  "$GENERATE_APPCAST" --ed-key-file "$SPARKLE_ED_KEY_FILE" "${args[@]}"
else
  "$GENERATE_APPCAST" "${args[@]}"
fi

echo "Wrote:"
echo "  $ZIP_PATH"
echo "  $OUT_DIR/appcast.xml"
