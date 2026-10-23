# Avo for game and app developers

Avo is an open-source Mac app that runs Android apps on Apple Silicon. Android
runs in a lightweight virtual machine (Avo's own engine on Apple's
Hypervisor.framework), and every Android app gets its own Mac window, Dock
icon and notifications. Players use a keyboard, a mouse or trackpad and,
optionally, a game controller; Avo's key mapping turns those into the touches
a mobile game expects.

Avo does not pretend to be a phone. By default it tells apps exactly what it
is, and it keeps stating that on every boot even when a user picks a phone
profile. This page describes how to detect Avo, what hardware and software
your app sees, and what we ask of publishers. It is kept in sync with the code
(`AvoIdentity` and `DeviceProfile` in `host/AvoKit`); version 1 of the
identity scheme is described here.

## Detecting Avo

| Marker | Value | When |
| --- | --- | --- |
| Property `ro.boot.avo.schema` | `1` | every boot, whichever device profile is chosen |
| Property `ro.boot.avo.version` | Avo's version, e.g. `0.2.0` | every boot |
| Property `ro.boot.avo.host.os` | `macOS 27.0.1` (name, major.minor.patch) | every boot |
| Property `ro.boot.avo.host.chip` | the Mac's chip, e.g. `Apple M4 Pro` | every boot |
| Property `ro.boot.avo.renderer` | `gpu` or `software` (what renders Android this boot) | every boot |
| Property `ro.boot.avo.input` | `keyboard,mouse,touch,gamepad` (see [Input](#input)) | every boot |
| System feature `com.avodroid.feature.MAC`, version `1` | `PackageManager.hasSystemFeature` | where Avo can add it to Android, see below; before 0.3.0 Preview 2 it was `dev.avo.feature.MAC` |
| `Build.MANUFACTURER`, `Build.BRAND` | `Avo` | with the default identity |
| `Build.MODEL` | `AVO-Droid` | with the default identity |
| `Build.DEVICE`, `Build.PRODUCT` | `avo_droid` | with the default identity |
| `Build.FINGERPRINT` | `Avo/avo_droid/avo_droid:17/<build id>/<incremental>:userdebug/test-keys` | with the default identity |

**Which one to check.** The `ro.boot.avo.*` properties are the one marker
that is always there: Avo's engine sets them before Android starts, on every
boot, and a device profile cannot change or remove them. Check
`ro.boot.avo.schema` first.

- The system feature, like Google Play Games on PC's
  `com.google.android.play.feature.HPE_EXPERIENCE`, needs a file in Android's
  `/product` partition. The Android image Avo boots today (AOSP Cuttlefish)
  keeps `/product` read-only under verified boot, so Avo can only add the
  feature once a user has installed Google apps (their installer makes
  `/product` writable through an overlay): Avo adds it the first time
  Android starts with Google apps, and apps see it from the start after
  that. Avo's own Android image, in development, always declares it.
- `Build.*` follows the device profile the user picked under Settings ›
  Privacy & Security › Device profile › Identify as. The default, "Avo
  (AVO-Droid)", is
  the honest identity in the table. The other profiles impersonate phones
  (for apps that only work on certain models), so `Build.*` then names that
  phone while the `ro.boot.avo.*` properties still say Avo.

**Stability.** Names under `ro.boot.avo.` and the feature name do not change.
A later schema only adds properties or `ro.boot.avo.input` words, and raises
the schema and the feature's version together, so
`hasSystemFeature("com.avodroid.feature.MAC", 1)` stays true. Values are one line
of printable ASCII of at most 91 bytes, so `__system_property_get` returns
them whole; a fact Avo cannot read is `unknown`. The fingerprint's build
fields (`17/<build id>/<incremental>`) are the Android image's own and change
when Avo updates the image.

Why `ro.boot.`: these are the properties a boot loader hands to Android, and
Avo's engine is that boot loader. The names have their own SELinux context
(`bootloader_prop`) that every process may read, and they work whether the
engine passes them as boot parameters (`androidboot.avo.*`) or in its
properties file.

### Kotlin

```kotlin
import android.content.Context
import android.os.Build

/** True on Avo, whichever device profile the user picked. */
fun isAvo(context: Context): Boolean =
    avoProperty("ro.boot.avo.schema").isNotEmpty() ||
        context.packageManager.hasSystemFeature("com.avodroid.feature.MAC")

/** An Avo property, or "" when it is not set (not Avo). */
fun avoProperty(name: String): String = try {
    ProcessBuilder("/system/bin/getprop", name).start()
        .inputStream.bufferedReader().use { it.readLine().orEmpty() }
} catch (e: java.io.IOException) {
    ""
}

/** The default identity (users can choose a phone profile instead). */
val looksLikeAvo = Build.MANUFACTURER == "Avo" && Build.MODEL == "AVO-Droid"
```

### Java

```java
boolean avoFeature = context.getPackageManager().hasSystemFeature("com.avodroid.feature.MAC");

// android.os.SystemProperties is not in the public SDK; get(String) works
// through reflection today (Android lists it as an unsupported, greylisted
// interface). Prefer getprop (above) or the NDK (below) in new code.
static String systemProperty(String name) {
    try {
        Class<?> c = Class.forName("android.os.SystemProperties");
        return (String) c.getMethod("get", String.class).invoke(null, name);
    } catch (ReflectiveOperationException e) {
        return "";
    }
}
```

### Native code (C/C++, Unreal Engine, Unity native plugins)

`__system_property_get` and `__system_property_read_callback` are public NDK
APIs in `<sys/system_properties.h>`:

```c
#include <stdlib.h>
#include <string.h>
#include <sys/system_properties.h>

/* Returns the schema (1, 2, ...) on Avo, 0 elsewhere. */
int avo_schema(void) {
    char value[PROP_VALUE_MAX] = "";
    return __system_property_get("ro.boot.avo.schema", value) > 0 ? atoi(value) : 0;
}

/* API 26+: */
static void copy_value(void *out, const char *name, const char *value, uint32_t serial) {
    strlcpy((char *)out, value, PROP_VALUE_MAX);
}
void avo_chip(char out[PROP_VALUE_MAX]) {
    const prop_info *info = __system_property_find("ro.boot.avo.host.chip");
    out[0] = '\0';
    if (info) __system_property_read_callback(info, copy_value, out);
}
```

Unreal Engine's Android device profiles match on the device make and model
(`Build.MANUFACTURER`, `Build.MODEL`) and on the GPU's `GL_RENDERER`, so a
rule for make `Avo` or a renderer containing `Apple M` picks a profile for
Avo. In Unity, `hasSystemFeature` is one JNI call:

```csharp
using UnityEngine;

static bool IsAvo() {
    using var player = new AndroidJavaClass("com.unity3d.player.UnityPlayer");
    using var activity = player.GetStatic<AndroidJavaObject>("currentActivity");
    using var pm = activity.Call<AndroidJavaObject>("getPackageManager");
    return pm.Call<bool>("hasSystemFeature", "com.avodroid.feature.MAC");
}
```

From a terminal:

```sh
adb shell getprop | grep ro.boot.avo
adb shell pm list features | grep avo     # feature:com.avodroid.feature.MAC=1
```

## What your app runs on

### Android

- AOSP Android 17 (API 37), the Cuttlefish arm64 build
  `aosp_cf_arm64_only_phone-userdebug` (`Build.TYPE` `userdebug`,
  `Build.TAGS` `test-keys`).
- `Build.BOARD` `cutf`, `Build.HARDWARE` `cutf_cvm` and `Build.SOC_MANUFACTURER`
  / `SOC_MODEL` `Google` / `vsoc_arm64_only` describe Cuttlefish's virtual
  hardware, which is what Android really runs on. The Mac's chip is in
  `ro.boot.avo.host.chip`. With "Emulate this phone's hardware" on, these,
  the CPU, the GPU strings and the memory are the chosen phone's instead
  (`profiles/devices/README.md`); the `ro.boot.avo.*` markers stay.
- Avo ships no Google apps. Users may install a Google apps package
  themselves and register the device at Google's page for uncertified
  devices. Play Integrity's device integrity verdict fails on Avo, and keys
  come from a software KeyMint (not hardware-backed) with an unlocked boot
  state: Avo cannot pass hardware attestation and does not try to. If you
  admit devices with Play Integrity or attestation, use the markers above to
  allow Avo explicitly.

### CPU and memory

- 64-bit ARM only: `Build.SUPPORTED_ABIS` is `[arm64-v8a]`. There is no
  32-bit ARM and no x86 translation, so ship arm64-v8a native libraries.
- The virtual CPUs run on the Mac's Apple Silicon cores. The user picks how
  many (default 4, up to the Mac's core count) and how much memory Android
  has: 2 to 16 GB, 4 GB by default, at least 8 GB in the "heavy games"
  preset on Macs that have room for it. 4 KiB pages.

### Graphics

- **GPU** (`ro.boot.avo.renderer` = `gpu`; Settings › Graphics › Renderer is
  Automatic by default and uses the GPU when the Android Emulator 37 or
  later is installed on the Mac): Android's OpenGL ES and Vulkan go through
  gfxstream to MoltenVK and Metal on the Mac's GPU. Apps get OpenGL ES 3.1
  (ANGLE on Vulkan) and Vulkan at feature level 1.3
  (`android.hardware.vulkan.version`; the driver reports API 1.4). No ES 3.2
  and no geometry shaders (MoltenVK). GLES `flat` varyings take their value
  from the *first* vertex of each primitive, not the last as OpenGL ES says
  (MoltenVK has no last-vertex mode); give every vertex of a primitive the
  same flat value. For example:
  - `GL_VENDOR`: `Google Inc. (Apple)`
  - `GL_RENDERER`: `ANGLE (Apple, Vulkan 1.4.323 (Virtio-GPU GFXStream (Apple M4 Pro) (0x1B000209)), Apple-26.0.99)`
  - Vulkan device name: `Virtio-GPU GFXStream (Apple M4 Pro)`
- **Software** (`software`): SwiftShader on the Mac's CPU, also OpenGL ES 3.1
  and Vulkan 1.3 (`GL_RENDERER` contains `SwiftShader`). It is much slower;
  pick your lowest graphics tier. A GPU start that fails restarts Android in
  software, and the property then says `software`.
- **Display**: 60 Hz. Every app runs on its own Android display sized to its
  Mac window, or at a fixed 540p to 1080p resolution the user picks for
  games and upscales on the Mac.

### Input

`ro.boot.avo.input` lists how players control apps:

| Word | What Android sees |
| --- | --- |
| `keyboard` | A hardware keyboard, `Avo Keyboard` (alphabetic; virtio vendor `1af4`), with real key events. Keys for a window whose display is not the focused one are injected with Android's `input` command. |
| `mouse` | The Mac's mouse or trackpad. Android has no mouse device: clicks and drags arrive as touches, and scrolling as swipes or scroll events. In Game Mode with FPS controls Avo captures the pointer on the Mac and turns its motion into drags in the game's camera area. |
| `touch` | `Avo Touch Screen 0` to `15`, one per display: the touches above, and the touches key mapping makes from keys (tap, hold, joystick, swipe). |
| `gamepad` | `Xbox Wireless Controller`, an Xbox One S controller to Android (`045e:02ea`, Android's stock Xbox layout), named like a real one because some games (Call of Duty: Mobile) accept only controllers whose name they know. It is plugged in only while a game controller connected to the Mac drives it, so a game does not switch to controller prompts when nobody uses one. |

A player on Avo is almost always using a keyboard and a mouse or trackpad.

### Other differences from a phone

- Sound plays through the Mac. AAudio's low-latency MMAP path is not
  available; AAudio and Oboe fall back to the shared path.
- Audio focus is shared, as on a Mac where every window plays at once
  (Android's multi audio focus): when another app asks for focus, yours keeps
  it and gets no `AUDIOFOCUS_LOSS`. Calls and transient requests
  (notifications, ducking) work as on a phone.
- Network: Wi-Fi ("VirtWifi") behind NAT on the Mac; a test SIM with mobile
  data when the user turns it on, no telephony. The back and front cameras
  are emulated or one of the Mac's cameras (the external camera HAL:
  hardware level EXTERNAL, Motion-JPEG up to 1080p at 30 fps, no flash or
  zoom). Bluetooth turns on when the Android Emulator is installed
  (a virtual controller) and reaches the Bluetooth LE devices the Mac sees
  (GATT through the Mac; no classic Bluetooth, no pairing yet). GPS reports the Mac's location when the user
  allows it.

## What we ask of publishers

1. **Treat Avo as a PC-class device**, the way Google Play Games on PC is
   treated: a computer with a keyboard and a mouse, not a phone. Where your
   game separates touch players from keyboard-and-mouse or PC players,
   please match Avo players with keyboard-and-mouse players.
2. **Pick graphics settings for Apple M-series GPUs.** With
   `ro.boot.avo.renderer` = `gpu`, `GL_RENDERER` and the Vulkan device name
   contain the chip (`Apple M4 Pro`); M-series GPUs handle high settings.
   With `software`, use the lowest tier.
3. **Allow or classify Avo explicitly** with the markers above instead of
   generic emulator heuristics, and tell us what else you need to see.
   Please do not ban accounts for playing on Avo; Avo players are playing
   your game, on a Mac.

## Transparency

- **Avo does not hide.** The markers are on every boot, also when a user
  impersonates a phone for compatibility.
- **No root for apps, unless the user turns it on.** Android is an AOSP
  userdebug build: `su` exists but only Android's shell and root users may
  run it, which apps never are. Avo's own daemon uses that shell over ADB to
  set Android up (displays, input routing, clipboard, notifications,
  installing Google apps). Only the daemon reaches ADB, unless the user
  turns on ADB support, which lets developer tools on that Mac connect too.
  Settings › System › Developer › Root access adds Magisk (downloaded from
  its GitHub release, patched into init_boot's ramdisk); apps then ask
  Magisk for root, and Magisk asks the user. It is off by default.
- **What is not locked down**, so you can judge it: SELinux runs in
  permissive mode in current builds, the verified boot state is unlocked
  (orange), and installing Google apps turns off dm-verity and adds an
  overlay over the system partitions.
- **No tampering features.** Avo does not read or write app memory, inject
  code, change game speed or modify APKs.
- **Key mapping limits.** Profiles in FPS mode may not use repeated taps (no
  automatic rapid fire), macros, or swipes through the aim area (no recoil
  compensation), and Avo has no aim assist or auto-aim. Outside FPS mode a
  profile may repeat a tap while a key is held (at most every 50 ms) or play
  a short sequence of taps and holds, for games that are not shooters. MOBA
  "smart cast" aims where the mouse cursor points, as on PC.
- **Open source.** The macOS host and the guest components are Apache 2.0;
  GPL parts are kept separate. You can read exactly what Avo does.

## Testing your game on Avo

1. Get a Mac with Apple Silicon and macOS 15 or later, and Avo from its
   [GitHub Releases](https://github.com/nizwar/avo/releases) page, or build
   it from source (see the [README](../README.md)).
2. For the GPU renderer, install the Android Emulator 37 or later with
   Android Studio's SDK Manager. Avo uses its gfxstream libraries.
3. Install your game: drop an `.apk`, `.xapk`, `.apkm` or `.apks` (with OBB
   files) on Avo, or use adb.
4. Turn on Settings › System › Developer › ADB support. `adb devices` then
   lists Avo as `emulator-5554` (or run `adb connect 127.0.0.1:5555`), and
   `adb logcat`, `adb install` and Android Studio work as usual.
5. Check what your game sees:
   `adb shell getprop | grep ro.boot.avo`, `adb shell pm list features | grep avo`.
6. To see your game under a phone identity, choose a profile under Settings
   › Privacy & Security › Device profile › Identify as and restart
   Android. Google Play may keep showing the old device details until it
   refreshes its device information.

## Testing a build's per-device code paths

If your build branches on the device — a chipset check, a GPU family, a
brand — you can test those branches on Avo without the phone. Pick a profile
under Settings › Privacy & Security › Device profile and turn on **Emulate
this phone's hardware**, then restart Android. Your app then reads that
phone's SoC, CPU and GPU, so a path gated on "is this a Snapdragon / an
Adreno / a Dimensity" runs as it would on the device.

What each surface reads, so you know which checks are covered:

- **`Build.*` and `getprop`** — `Build.SOC_MANUFACTURER` / `SOC_MODEL`,
  `Build.BOARD`, `ro.board.platform`, `ro.soc.*`, and the vendor keys
  (`ro.vendor.qti.*`, `ro.vendor.mediatek.*` / `ro.mediatek.*`). This is how
  most "which chipset" checks work, and it is fully covered.
- **GLES** — your app's own `glGetString` reports the profile's GPU instead
  of ANGLE: `GL_VENDOR` `Qualcomm`, `GL_RENDERER` `Adreno (TM) 750`,
  `GL_VERSION` `OpenGL ES 3.1 V@0762.11 (...)` (the real ES version number,
  the profile's driver), and `GL_SHADING_LANGUAGE_VERSION` without ANGLE's
  `(ANGLE ...)` suffix. This holds whichever library you call it through
  (Java's `GLES20`/`GLES30`, `libGLESv2`/`libGLESv3`, `eglGetProcAddress`).
- **Vulkan** — `vkGetPhysicalDeviceProperties(2)` on your app's own instance
  reports the profile's `deviceName`, `vendorID`, `driverID` and driver name.
- **CPU** — `/proc/cpuinfo` and `/sys/devices/system/cpu` report the target's
  cores (their MIDR) and clocks, a cpufreq policy per cluster as on the
  phone, so the NDK's cpufeatures agrees. With fewer Android cores than the
  phone has (Settings › Performance), the phone's fastest are kept. The
  clocks are names only: your threads run at the Mac's speed on every core.

What stays this Mac's, on purpose — so your app still runs and the result is
honest:

- **What draws GLES.** Avo still draws GLES through ANGLE on the Mac's GPU;
  only the names change. `GL_EXTENSIONS` is ANGLE's real list (including its
  `GL_ANGLE_*` extensions), and Android's own renderers (HWUI, WebView) keep
  the real strings. If your engine turns on vendor workarounds from
  `GL_RENDERER` (an Adreno or Mali path), those run on ANGLE too — which is
  what you are testing, but a rendering difference there may be the
  workaround, not the device.
- **Drivers and HALs.** `ro.hardware`, the ABI list, the API level and the
  GPU's real abilities (extensions, limits, Vulkan version) are unchanged. An
  app that loads a Qualcomm-only `.so` or calls a vendor HAL still takes its
  fallback path — which is the useful signal that the path is not portable.
- Avo keeps identifying itself (`ro.boot.avo.*`, `com.avodroid.feature.MAC`)
  whatever the profile, and none of this passes hardware attestation. It is a
  development aid, not a disguise.

Add a device by sending a profile (see
[profiles/devices](../profiles/devices/README.md)).

## Contact

Publisher contact: **[placeholder: contact address to be
announced]**. Until then, open an issue in Avo's repository.
