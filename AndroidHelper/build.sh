#!/usr/bin/env bash
# Builds PhoneRelayHelper.apk with the Android SDK command-line tools only
# (javac, d8, aapt2, zipalign, apksigner). No Gradle, no downloads.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BUILD_TOOLS="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
PLATFORM="$(ls -d "$SDK"/platforms/android-* | sort -V | tail -1)"
ANDROID_JAR="$PLATFORM/android.jar"
JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
# d8 and apksigner are wrappers that run `java` from PATH; macOS ships none.
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"
# Signing key kept outside the repo so it is never committed. The same key must
# sign every build, or Android refuses to install an update over the old one.
KEYSTORE="${PHONE_RELAY_HELPER_KEYSTORE:-$HOME/.android/phone-relay-helper.keystore}"
OUT="$HERE/build"
APK="$OUT/PhoneRelayHelper.apk"

rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex"

# The repo path contains spaces, so file lists go through arrays.
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find "$HERE/src" -name '*.java' -print0)
"$JAVA_HOME/bin/javac" --release 11 -nowarn \
  -classpath "$ANDROID_JAR" \
  -d "$OUT/classes" \
  "${SOURCES[@]}"

CLASSES=()
while IFS= read -r -d '' file; do CLASSES+=("$file"); done < <(find "$OUT/classes" -name '*.class' -print0)
"$BUILD_TOOLS/d8" --release --min-api 30 \
  --lib "$ANDROID_JAR" \
  --output "$OUT/dex" \
  "${CLASSES[@]}"

"$BUILD_TOOLS/aapt2" link \
  -I "$ANDROID_JAR" \
  --manifest "$HERE/AndroidManifest.xml" \
  -o "$OUT/unsigned.apk"

(cd "$OUT/dex" && zip -q -j "$OUT/unsigned.apk" classes.dex)
"$BUILD_TOOLS/zipalign" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

if [[ ! -f "$KEYSTORE" ]]; then
  mkdir -p "$(dirname "$KEYSTORE")"
  "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$KEYSTORE" -storepass android -keypass android \
    -alias phonerelayhelper -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Phone Relay Helper" >/dev/null 2>&1
fi
"$BUILD_TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
  --out "$APK" "$OUT/aligned.apk"
"$BUILD_TOOLS/apksigner" verify "$APK"
echo "Built $APK"
