#!/usr/bin/env bash
# Builds the package fixtures used by AvoPackagesTests with the Android SDK's
# aapt2 (no third-party APKs). The outputs are committed; rerun this script only
# when the fixtures need to change.
#
#   ANDROID_HOME=~/Library/Android/sdk ./make-fixtures.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../../.." && pwd)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/36.0.0"
JAR="$SDK/platforms/android-36/android.jar"
AAPT2="$BT/aapt2"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/res/values" "$WORK/res/values-id" "$WORK/res/mipmap-xxxhdpi" "$WORK/res/mipmap-xxhdpi" \
         "$WORK/res/mipmap-anydpi-v26" "$WORK/res/drawable"

cat > "$WORK/AndroidManifest.xml" <<'XML'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.avodroid.fixture" android:versionCode="42" android:versionName="1.4.2">
  <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="36"/>
  <uses-permission android:name="android.permission.INTERNET"/>
  <uses-permission android:name="android.permission.CAMERA"/>
  <uses-permission android:name="android.permission.CAMERA"/>
  <application android:label="@string/app_name" android:icon="@mipmap/ic_launcher" android:hasCode="false"/>
</manifest>
XML
# Twenty filler strings with only app_name translated make the values-id
# table sparse when --enable-sparse-encoding is used.
{
  echo '<resources>'
  for i in $(seq -w 1 20); do echo "  <string name=\"a_filler_$i\">Filler $i</string>"; done
  echo '  <string name="app_name">Avo Fixture</string>'
  echo '</resources>'
} > "$WORK/res/values/strings.xml"
cat > "$WORK/res/values-id/strings.xml" <<'XML'
<resources><string name="app_name">Contoh Avo</string></resources>
XML
cat > "$WORK/res/values/colors.xml" <<'XML'
<resources><color name="ic_launcher_background">#FFD8E8A7</color></resources>
XML
cat > "$WORK/res/mipmap-anydpi-v26/ic_launcher.xml" <<'XML'
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@color/ic_launcher_background"/>
  <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
  <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>
</adaptive-icon>
XML
cat > "$WORK/res/drawable/ic_launcher_monochrome.xml" <<'XML'
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp" android:viewportWidth="108" android:viewportHeight="108">
  <path android:fillColor="#FF000000" android:pathData="M54,30a24,24 0 1,0 0.1,0z"/>
</vector>
XML
rsvg-convert -w 192 -h 192 "$ROOT/branding/svg/avo-avatar.svg" -o "$WORK/res/mipmap-xxxhdpi/ic_launcher.png"
rsvg-convert -w 144 -h 144 "$ROOT/branding/svg/avo-avatar.svg" -o "$WORK/res/mipmap-xxhdpi/ic_launcher.png"
rsvg-convert -w 432 -h 432 "$ROOT/branding/svg/avo-mark.svg" -o "$WORK/res/mipmap-xxxhdpi/ic_launcher_foreground.png"

"$AAPT2" compile --dir "$WORK/res" -o "$WORK/compiled.zip"

# Plain APK and a variant using compact + sparse resource encoding.
"$AAPT2" link -I "$JAR" --manifest "$WORK/AndroidManifest.xml" -o "$HERE/plain.apk" "$WORK/compiled.zip"
# aapt2 only emits compact entries for minSdk >= 35 (Android 15 can read them).
sed 's/android:minSdkVersion="26"/android:minSdkVersion="35"/' "$WORK/AndroidManifest.xml" > "$WORK/AndroidManifest35.xml"
"$AAPT2" link -I "$JAR" --manifest "$WORK/AndroidManifest35.xml" -o "$HERE/compact.apk" \
  --enable-compact-entries --enable-sparse-encoding "$WORK/compiled.zip"

# Base + density split (the launcher bitmap lives only in the split).
"$AAPT2" link -I "$JAR" --manifest "$WORK/AndroidManifest.xml" -o "$WORK/base.apk" \
  --split "$WORK/split_config.xxxhdpi.apk:xxxhdpi" "$WORK/compiled.zip"

# ABI config splits carry only native libraries.
abi_split() { # name abi
  local dir="$WORK/abi-$1"
  mkdir -p "$dir/lib/$2"
  cat > "$dir/AndroidManifest.xml" <<XML
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.avodroid.fixture" split="config.$1" android:isFeatureSplit="false">
  <application android:hasCode="false"/>
</manifest>
XML
  "$AAPT2" link -I "$JAR" --manifest "$dir/AndroidManifest.xml" -o "$WORK/split_config.$1.apk"
  printf '\x7fELF-fixture' > "$dir/lib/$2/libfixture.so"
  (cd "$dir" && zip -q "$WORK/split_config.$1.apk" "lib/$2/libfixture.so")
}
abi_split arm64_v8a arm64-v8a
abi_split x86_64 x86_64
abi_split armeabi_v7a armeabi-v7a

# An APK with only 32-bit ARM code.
cp "$HERE/plain.apk" "$HERE/arm32-only.apk"
mkdir -p "$WORK/lib32/lib/armeabi-v7a"
printf '\x7fELF-fixture' > "$WORK/lib32/lib/armeabi-v7a/libold.so"
(cd "$WORK/lib32" && zip -q "$HERE/arm32-only.apk" lib/armeabi-v7a/libold.so)

# XAPK (APKPure): manifest.json, splits and an OBB expansion.
X="$WORK/xapk" && mkdir -p "$X/Android/obb/com.avodroid.fixture"
cp "$WORK/base.apk" "$X/com.avodroid.fixture.apk"
cp "$WORK/split_config.xxxhdpi.apk" "$WORK/split_config.arm64_v8a.apk" "$WORK/split_config.x86_64.apk" "$X/"
head -c 70000 /dev/urandom > "$X/Android/obb/com.avodroid.fixture/main.42.com.avodroid.fixture.obb"
cat > "$X/manifest.json" <<'JSON'
{"xapk_version": 2, "package_name": "com.avodroid.fixture", "name": "Avo Fixture",
 "version_code": "42", "version_name": "1.4.2",
 "split_apks": [{"file": "com.avodroid.fixture.apk", "id": "base"},
                {"file": "split_config.xxxhdpi.apk", "id": "config.xxxhdpi"},
                {"file": "split_config.arm64_v8a.apk", "id": "config.arm64_v8a"},
                {"file": "split_config.x86_64.apk", "id": "config.x86_64"}],
 "expansions": [{"file": "Android/obb/com.avodroid.fixture/main.42.com.avodroid.fixture.obb",
                 "install_location": "EXTERNAL_STORAGE",
                 "install_path": "Android/obb/com.avodroid.fixture/main.42.com.avodroid.fixture.obb"}]}
JSON
rm -f "$HERE/fixture.xapk"
# APKs stored (so nested reads are in place), OBB deflated.
(cd "$X" && zip -q -0 "$HERE/fixture.xapk" *.apk && zip -q "$HERE/fixture.xapk" manifest.json Android/obb/com.avodroid.fixture/*.obb)

# APKM (APKMirror): info.json + deflated splits (exercises nested extraction).
M="$WORK/apkm" && mkdir -p "$M"
cp "$WORK/base.apk" "$M/base.apk"
cp "$WORK/split_config.xxxhdpi.apk" "$WORK/split_config.armeabi_v7a.apk" "$M/"
echo '{"apkm_version": 5, "pname": "com.avodroid.fixture", "versioncode": "42", "release_version": "1.4.2", "app_name": "Avo Fixture"}' > "$M/info.json"
rm -f "$HERE/fixture.apkm"
(cd "$M" && zip -q -9 "$HERE/fixture.apkm" info.json *.apk)

# APKS (bundletool layout): splits/ plus a standalone APK that must be ignored.
S="$WORK/apks" && mkdir -p "$S/splits" "$S/standalones"
cp "$WORK/base.apk" "$S/splits/base-master.apk"
cp "$WORK/split_config.xxxhdpi.apk" "$S/splits/base-xxxhdpi.apk"
cp "$WORK/split_config.arm64_v8a.apk" "$S/splits/base-arm64_v8a.apk"
cp "$HERE/plain.apk" "$S/standalones/standalone-arm64_v8a.apk"
printf 'fake-toc' > "$S/toc.pb"
rm -f "$HERE/fixture.apks"
(cd "$S" && zip -q -r "$HERE/fixture.apks" toc.pb splits standalones)

# Not a package.
printf 'just text' > "$HERE/not-a-package.apk"
ls -la "$HERE"
