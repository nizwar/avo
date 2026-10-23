# Device profiles

Templates for the "Identify as" menu in the Control Panel (Settings ›
Privacy & Security › Device profile; spec §8). Each file is `<id>.json`; the
file name must match `id`.

`avo-virtual-device.json` is the default and Avo's honest identity: a device
made by Avo, model AVO-Droid. The other templates impersonate phones, so apps
read that phone's `Build.*` fields instead. Impersonation does not pass
hardware attestation, and the Control Panel says so. Whichever template is
chosen, Avo still identifies itself to apps that check for it (the
`ro.boot.avo.*` properties and the `com.avodroid.feature.MAC` system feature; see
[docs/for-game-developers.md](../../docs/for-game-developers.md)).

```json
{
  "schema": 1,
  "id": "vendor-model",
  "name": "Vendor Model",
  "properties": {
    "ro.product.brand": "...",
    "ro.product.manufacturer": "...",
    "ro.product.model": "...",
    "ro.product.device": "...",
    "ro.build.fingerprint": "brand/product/device:release/id/incremental:type/tags"
  },
  "display": { "width": 1080, "height": 2400, "dpi": 420 },
  "hardware": {
    "soc": {
      "manufacturer": "QTI", "model": "SM8650",
      "platform": "pineapple", "board": "pineapple", "hardware": "qcom",
      "properties": { "ro.vendor.qti.soc_model": "SM8650" }
    },
    "cpu": { "clusters": [
      { "cores": 1, "implementer": 65, "part": 3458, "maxFreqKHz": 3302400 },
      { "cores": 3, "implementer": 65, "part": 3457, "maxFreqKHz": 3148800 },
      { "cores": 2, "implementer": 65, "part": 3457, "maxFreqKHz": 2956800 },
      { "cores": 2, "implementer": 65, "part": 3456, "maxFreqKHz": 2265600 }
    ] },
    "gpu": {
      "glVendor": "Qualcomm", "glRenderer": "Adreno (TM) 750",
      "vkName": "Adreno (TM) 750", "vkVendorID": 20803, "vkDriverID": 8,
      "vkDriverName": "Qualcomm Technologies Inc. Adreno Vulkan Driver"
    },
    "memoryGB": 12
  }
}
```

## `hardware` (optional): "Emulate this phone's hardware"

The `hardware` block is what the profile reports when the developer ticks
**Emulate this phone's hardware** (Settings › Privacy & Security › Device
profile). It is for testing
a build's per-device code paths — a chipset or brand check — without the
device. Like the identity, it does not pass hardware attestation, and Avo
still identifies itself. Without the checkbox (and for Avo's honest identity,
which has none), the profile changes only the device's name.

It reaches apps these ways, covering how apps actually read the hardware:

- **SoC** — read-only properties applied at boot: `ro.soc.manufacturer` /
  `ro.soc.model` (`Build.SOC_MANUFACTURER` / `SOC_MODEL`), `ro.board.platform`
  (the codename SoC-detect libraries key on), `ro.product.board`
  (`Build.BOARD`), and the vendor keys in `soc.properties` for the long tail
  (`ro.vendor.qti.*` for Snapdragon, `ro.vendor.mediatek.*` /
  `ro.mediatek.*` for Dimensity). `soc.properties` accepts only `ro.vendor.*`,
  `ro.board.*`, `ro.mediatek.*`, `ro.chipname` and `ro.hardware.chipname`, and
  never an API level, ABI or security key.
- **Hardware name** — `soc.hardware` is `ro.hardware` / `Build.HARDWARE`, what
  `getprop ro.hardware` says on the phone: `qcom` on every Snapdragon phone,
  the platform on MediaTek and Exynos ones (`mt6789`, `s5e8835`), the
  codename on a Pixel (`husky`). Left out, it is `qcom` for a `QTI` SoC and
  `platform` otherwise. The engine boots Android with it
  (`androidboot.hardware`, avo-vmm `--hardware`) in place of the image's
  `cutf_cvm`; Cuttlefish's drivers are picked by their own keys
  (`ro.hardware.egl`, `.gralloc`, `.vulkan`, ...), so they are unchanged.
  1–32 of `a-z`, `0-9`, `_` and `-`.
- **GPU** — Avo's GLES and Vulkan layers (`GuestGPUProfile`) answer an app's
  own `glGetString` and `vkGetPhysicalDeviceProperties(2)` with these values.
  `implementer`/`part` are decimal here (`65` = `0x41` ARM); `vkVendorID`,
  `vkDeviceID`, `vkDriverVersion` are numbers too (`20803` = `0x5143`
  Qualcomm). `vkDriverID` is a `VkDriverId` (`8` Qualcomm, `9` ARM).
- **Build** — the identity's fingerprint names the whole build, as on the
  phone: `ro.build.id`, `ro.build.version.incremental`, `ro.build.display.id`
  (`Build.ID`, `INCREMENTAL`, `DISPLAY`), the description and flavor, every
  partition's fingerprint, ID and incremental, and every partition's product
  names (`ro.product.vendor.model`, ...), which otherwise stay the image's
  (`aosp_cf_arm64_only_phone`, "Cuttlefish arm64 phone"). A value the
  identity sets itself wins. `Build.TYPE` and `Build.TAGS` follow the
  fingerprint too (`user`, `release-keys`); what Android really allows stays
  in `ro.debuggable`. The vendor partition's build (`ro.vendor.build.*`)
  stays the image's, which Avo's guest patches check before they apply.
  Android treats the change like an update once (it clears its code caches
  on the next boot).
- **Memory** — `memoryGB` is the phone's RAM as sold (the base model's when
  it comes in several sizes). Android gets that much while the checkbox is
  on, in place of Settings › Performance › Memory, as far as the Mac allows
  (2–16 GB, leaving macOS its share; the Control Panel says when it is
  less), so `/proc/meminfo` and an app's memory checks see the phone.
- **CPU** — each cluster's core model (an ARM MIDR: `implementer`, `part`,
  and optionally `variant` and `revision`) and count, and the per-cluster
  `maxFreqKHz` / `minFreqKHz` (300 MHz when left out). The engine presents
  these so `/proc/cpuinfo` and `/sys/devices/system/cpu` agree (a cpufreq
  policy per cluster, as on the phone), and the NDK's cpufeatures reads the
  target CPU. Clusters may be listed in any order: Android numbers them from
  the slowest. With fewer Android cores than the phone has (Settings ›
  Performance), the phone's fastest clusters are kept; with more, its
  slowest grows. Use the MIDR the phone reports: Qualcomm's Kryo 2xx–4xx
  and Oryon cores have their own implementer (`81` = `0x51`) and parts.
  A Cortex-A73 (`0xD09`) is never presented, because Linux's workaround
  for its erratum 858921 slows every app's clock; an early Cortex-A53
  (r0p0–r0p2) is presented as r0p4.

What stays this Mac's, by design (changing it would break apps or drivers, and
it is honest): the HALs and driver keys (`ro.hardware.*`), the ABI list and
API level, and the GPU's real abilities (extensions, limits, Vulkan version,
and the GLES version in `GL_VERSION`). An app that gates a
path on a Qualcomm-only `.so` or HAL therefore still takes the fallback path —
which is itself the useful signal for a developer.

Rules enforced by `DeviceProfile.validate()` (AvoKit) and CI:

- An impersonation template must set the five properties above.
- The default sets `ro.product.brand`, `manufacturer`, `model`, `name` and
  `device`, and no fingerprint: Android derives `ro.build.fingerprint` from
  brand, name and device plus the image's own release, build ID,
  incremental, type and tags
  (`Avo/avo_droid/avo_droid:17/CP2A.260605.016/16373615:userdebug/test-keys`
  on the current image).
- Only identity properties may be set: `ro.product.<brand|manufacturer|model|name|device>`,
  the same per partition (`ro.product.vendor.model`), `ro.build.fingerprint`,
  `ro.build.description`, `ro.build.product`, `ro.build.display.id`,
  `ro.build.id`, `ro.build.version.incremental`, `ro.build.tags`,
  `ro.build.type`, `ro.build.flavor`, `ro.soc.manufacturer` and
  `ro.soc.model`, and every partition's names: `ro.product.<partition>.*`
  and `ro.<partition>.build.fingerprint`, `.id`, `.version.incremental`,
  `.type` and `.tags` (any partition but `vendor`'s build, including a
  phone's own such as Transsion's `tr_region`), for a phone whose system
  image comes from another build than its vendor one (Qualcomm's QSSI). An
  empty value blanks a partition the phone does not have. Security state
  (`ro.debuggable`, `ro.secure`, verified boot), hardware (`ro.hardware*`,
  which picks drivers and init scripts), ABI lists, API levels and Avo's own
  `ro.boot.avo.*` markers are rejected.
- Brand, name and device go into the fingerprint, so they have no spaces,
  `/` or `:`.
- Brand names are used only so apps see a familiar device; they are not Avo
  branding.
- `hardware` is optional and validated too: `soc.manufacturer`/`model` are
  required when `soc` is present, `soc.properties` is limited to the prefixes
  above, `soc.hardware` to a hardware name, `memoryGB` to 1–64, and CPU core
  counts and frequencies must be sane.

The templates span the common chipset families, so a build can be tested
against each GPU and SoC vendor: Qualcomm Snapdragon (Adreno), MediaTek
Dimensity and Helio (Arm Mali / PowerVR), Samsung Exynos (Xclipse / Mali),
Google Tensor (Arm Mali) and Unisoc. To add a device, copy an existing file,
fill in values from the device's stock `build.prop` and GPU driver strings
(`dumpsys SurfaceFlinger`, `cmd gpu vkjson` on the real phone), and open a
pull request.
