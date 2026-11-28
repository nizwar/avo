#!/usr/bin/env bash
# Select a disposable guest with ANDROID_SERIAL and install Avo Input first.
# Select it for the editor suite, or pass --android-keyboard to test another selected IME.
set -euo pipefail
: "${ANDROID_SERIAL:?Select a test Android guest with ANDROID_SERIAL}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
BT="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -1)"
JAR="$SDK/platforms/android-36/android.jar"
PKG=com.avodroid.tests.input
DISPLAY_ID="${DISPLAY_ID:-0}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
mkdir "$OUT/classes" "$OUT/dex"
"$BT/aapt2" link -I "$JAR" --manifest "$HERE/AndroidManifest.xml" -o "$OUT/test.apk"
javac --release 17 -cp "$JAR" -d "$OUT/classes" "$HERE/Editor.java"
"$BT/d8" --release --min-api 34 --lib "$JAR" --output "$OUT/dex" "$OUT"/classes/com/avodroid/tests/input/*.class
(cd "$OUT/dex" && zip -q -j "$OUT/test.apk" classes.dex)
"$BT/zipalign" -f 4 "$OUT/test.apk" "$OUT/aligned.apk"
"$BT/apksigner" sign --ks "$HERE/../../widgets/debug.p12" --ks-pass pass:android --key-pass pass:android "$OUT/aligned.apk"
"$ADB" install "$OUT/aligned.apk" >/dev/null
cleanup() {
    "$ADB" uninstall "$PKG" >/dev/null || true
    rm -rf "$OUT"
}
trap cleanup EXIT

python3 "$HERE/keyboard.py" "$ADB" "$DISPLAY_ID" "$@"
