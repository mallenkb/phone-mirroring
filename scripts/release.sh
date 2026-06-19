#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TAG="${1:-}"

usage() {
  echo "Usage: scripts/release.sh vX.Y.Z" >&2
  exit 2
}

[[ -n "$TAG" ]] || usage

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: tag must match vX.Y.Z, got: $TAG" >&2
  exit 1
fi

VERSION="${TAG#v}"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: working tree has uncommitted changes; commit or stash them before releasing" >&2
  git status --short
  exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "error: tag already exists locally: $TAG" >&2
  exit 1
fi

if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "error: tag already exists on origin: $TAG" >&2
  exit 1
fi

CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/PhoneRelay/Info.plist)"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Sources/PhoneRelay/Info.plist)"
BUILD_NUMBER="$CURRENT_BUILD"
VERSION_CHANGED=0

if [[ "$CURRENT_VERSION" != "$VERSION" ]]; then
  VERSION_CHANGED=1
  if [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
    BUILD_NUMBER="$((CURRENT_BUILD + 1))"
  else
    echo "error: current build number is not numeric: $CURRENT_BUILD" >&2
    exit 1
  fi

  echo "Updating release metadata: $CURRENT_VERSION ($CURRENT_BUILD) -> $VERSION ($BUILD_NUMBER)"

  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Sources/PhoneRelay/Info.plist
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" Sources/PhoneRelay/Info.plist

  perl -0pi -e "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/g; s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/g" App/PhoneRelay.xcodeproj/project.pbxproj
  perl -0pi -e "s/APP_VERSION=\"\\\$\\{APP_VERSION:-[^}]+\\}\"/APP_VERSION=\"\\\${APP_VERSION:-$VERSION}\"/g; s/BUILD_NUMBER=\"\\\$\\{BUILD_NUMBER:-[^}]+\\}\"/BUILD_NUMBER=\"\\\${BUILD_NUMBER:-$BUILD_NUMBER}\"/g" scripts/build_and_run.sh scripts/package_app.sh
else
  echo "Release metadata already matches $TAG; no version commit needed."
fi

echo "Running tests..."
swift test

APP_VERSION_AFTER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/PhoneRelay/Info.plist)"
if [[ "$APP_VERSION_AFTER" != "$VERSION" ]]; then
  echo "error: app version $APP_VERSION_AFTER does not match tag $TAG" >&2
  exit 1
fi

if [[ "$VERSION_CHANGED" = "1" ]]; then
  git add Sources/PhoneRelay/Info.plist App/PhoneRelay.xcodeproj/project.pbxproj scripts/build_and_run.sh scripts/package_app.sh
  git commit -m "Release Phone Relay $TAG"
fi

echo "Creating tag $TAG..."
git tag -a "$TAG" -m "Phone Relay $TAG"

echo "Pushing commit and tag..."
git push origin HEAD
git push origin "$TAG"

echo "Release tag pushed. GitHub Actions will build and publish Phone Relay-$VERSION.dmg."
