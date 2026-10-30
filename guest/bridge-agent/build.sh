#!/usr/bin/env bash
# Development build of the Bridge Agent with the Android SDK and NDK (no AOSP
# tree needed). Produces build/AvoBridgeAgent.apk signed with a local debug key.
#
# The APK only gets its privileges when installed as a platform-signed
# privileged app in the Avo image (Android.bp). This build checks that the
# code compiles against the public SDK plus compile-only stubs, and produces a
# package for development images.
#
#   ANDROID_HOME=~/Library/Android/sdk ./build.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
API=36
MIN_API=34
BT="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -1)"
JAR="$SDK/platforms/android-$API/android.jar"
NDK="$SDK/ndk/$(ls "$SDK/ndk" | sort -V | tail -1)"
PROTOBUF_VERSION=4.34.1
OUT="$HERE/build"

[[ -f "$JAR" ]] || { echo "missing $JAR (install platforms;android-$API)" >&2; exit 1; }
mkdir -p "$OUT"/{deps,classes,stub-classes,r,dex,lib/arm64-v8a}

# 1. Protocol bindings (Java lite) from proto/.
"$ROOT/scripts/gen-proto.sh" --java-only >/dev/null

# 2. protobuf-javalite runtime.
PROTOBUF_JAR="$OUT/deps/protobuf-javalite-$PROTOBUF_VERSION.jar"
if [[ ! -f "$PROTOBUF_JAR" ]]; then
  curl -fsSL -o "$PROTOBUF_JAR" \
    "https://repo1.maven.org/maven2/com/google/protobuf/protobuf-javalite/$PROTOBUF_VERSION/protobuf-javalite-$PROTOBUF_VERSION.jar"
fi

# 3. Compile-only stubs for hidden framework classes (never packaged).
find "$HERE/stubs/src" -name '*.java' > "$OUT/stub-sources.txt"
javac --release 17 -nowarn -cp "$JAR" -d "$OUT/stub-classes" @"$OUT/stub-sources.txt"
(cd "$OUT/stub-classes" && jar cf "$OUT/stubs.jar" .)

# 4. Resources and manifest.
"$BT/aapt2" compile --dir "$HERE/res" -o "$OUT/res.zip"
"$BT/aapt2" link -I "$JAR" --manifest "$HERE/AndroidManifest.xml" --min-sdk-version $MIN_API \
  --target-sdk-version $API --version-code 1 --version-name "0.1.0" \
  --java "$OUT/r" -o "$OUT/base.apk" "$OUT/res.zip"

# 5. Java.
{ find "$HERE/src" -name '*.java'; find "$OUT/r" -name '*.java'; find "$ROOT/guest/bridge-agent/build/gen" -name '*.java'; } > "$OUT/sources.txt"
rm -rf "$OUT/classes" && mkdir -p "$OUT/classes"
javac --release 17 -Xlint:-options -cp "$JAR:$OUT/stubs.jar:$PROTOBUF_JAR" -d "$OUT/classes" @"$OUT/sources.txt"

# 6. Dex (app classes + protobuf runtime; stubs only on the classpath).
rm -rf "$OUT/dex" && mkdir -p "$OUT/dex"
"$BT/d8" --release --min-api $MIN_API --lib "$JAR" --classpath "$OUT/stubs.jar" --output "$OUT/dex" \
  $(find "$OUT/classes" -name '*.class') "$PROTOBUF_JAR"

# 7. JNI library (vsock; gfxstream posting is AOSP-only).
CXX="$NDK/toolchains/llvm/prebuilt/$(ls "$NDK/toolchains/llvm/prebuilt" | head -1)/bin/aarch64-linux-android$MIN_API-clang++"
"$CXX" -shared -fPIC -O2 -std=c++20 -Wall -Werror -static-libstdc++ \
  -o "$OUT/lib/arm64-v8a/libavobridge_jni.so" "$HERE/jni/avobridge_jni.cpp"

# 8. Cross-language check: decode the host encoder's golden records with the
#    same accessors the injector uses (plain JVM), and the touch profile's
#    ranges.
mkdir -p "$OUT/test-classes"
javac --release 17 -d "$OUT/test-classes" "$HERE/src/com/avodroid/bridge/input/InputRecords.java" \
    "$HERE/src/com/avodroid/bridge/input/TouchProfile.java" \
    "$HERE/test/InputRecordsTest.java" "$HERE/test/TouchProfileTest.java"
java -cp "$OUT/test-classes" InputRecordsTest "$ROOT/proto/testdata/input-v1.bin"
java -cp "$OUT/test-classes" TouchProfileTest

# 9. Package, align and sign.
cp "$OUT/base.apk" "$OUT/unsigned.apk"
(cd "$OUT/dex" && zip -q "$OUT/unsigned.apk" classes*.dex)
(cd "$OUT" && zip -q -0 "$OUT/unsigned.apk" lib/arm64-v8a/libavobridge_jni.so)
"$BT/zipalign" -P 16 -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
KEYSTORE="$OUT/debug.keystore"
if [[ ! -f "$KEYSTORE" ]]; then
  keytool -genkeypair -keystore "$KEYSTORE" -storepass android -keypass android -alias avo-debug \
    -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Avo Debug" >/dev/null 2>&1
fi
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
  --out "$OUT/AvoBridgeAgent.apk" "$OUT/aligned.apk"
"$BT/apksigner" verify "$OUT/AvoBridgeAgent.apk"
echo "built $OUT/AvoBridgeAgent.apk"
