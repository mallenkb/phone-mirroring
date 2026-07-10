#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/scripts/release-artifacts.sha256"
ADB_ARTIFACT="$ROOT_DIR/App/Vendor/adb"
SCRCPY_SERVER_ARTIFACT="$ROOT_DIR/Sources/PhoneRelay/Resources/scrcpy-server"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -f "$MANIFEST" ]] || fail "release artifact manifest is missing: $MANIFEST"
[[ -x "$ADB_ARTIFACT" ]] || fail "tracked adb artifact is missing or not executable: $ADB_ARTIFACT"
[[ -f "$SCRCPY_SERVER_ARTIFACT" ]] || fail "tracked scrcpy-server artifact is missing: $SCRCPY_SERVER_ARTIFACT"

(
  cd "$ROOT_DIR"
  shasum -a 256 -c "scripts/release-artifacts.sha256"
)

for architecture in x86_64 arm64; do
  if ! lipo -verify_arch "$architecture" "$ADB_ARTIFACT" >/dev/null 2>&1; then
    fail "tracked adb artifact is missing the $architecture architecture"
  fi
done

if ! /usr/bin/unzip -tqq "$SCRCPY_SERVER_ARTIFACT"; then
  fail "tracked scrcpy-server artifact is not a valid jar/zip archive"
fi

echo "Tracked release artifacts verified."
