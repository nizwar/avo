import Foundation

/// Window resizes without a re-plug (HostAgent, "Displays").
///
/// Cuttlefish's composer (RanchuHwc, device/generic/goldfish/hals/hwc3)
/// hears of a scanout's new mode (VIRTIO_GPU_EVENT_DISPLAY) and even sets it
/// on the CRTC, but tells SurfaceFlinger only when a display connects or
/// disconnects (`DrmDisplay::checkAndHandleHotplug`): Android kept the old
/// size, so a resize unplugged the display and plugged it in again. Android
/// then gave it a new display id and moved the app to display 0 and back,
/// and apps that keep objects of the display they started on broke. Flutter
/// keeps that display's InputMethodManager (TextInputPlugin's `mImm`), whose
/// `isAcceptingText()` stays false on any other display: every key typed
/// into a Flutter text field after a resize was dropped.
///
/// A copy of the known composer build changes two calls into code placed in
/// the zero padding after `.plt` (the R+X segment is extended over it):
///
/// - `checkAndHandleHotplug`'s `DrmConnector::update` notes the first mode
///   before the update; when the connector stays connected and the mode
///   changed, the function takes its "was connected" path: it sets the new
///   mode and reports a hotplug. SurfaceFlinger, which still has the
///   display, reconnects it (`Reconnecting`, a new DisplayDevice on the same
///   physical display) and DisplayManager gives the same logical display
///   its new size, as a phone's freeform window would get one;
/// - the hotplug callback's `createDisplayLocked` first destroys a display
///   the composer still has (`destroyDisplayLocked`): it would otherwise
///   keep the old one and its old configs.
///
/// A re-plug is unchanged: the display goes away before it comes back.
///
/// The composer starts before ADB does, so the copy has to be there at
/// boot: it lives on the vendor overlay of a `remount` (Google apps,
/// identity), and an init file on the system overlay bind-mounts it over the
/// APEX's file after the APEXes are activated (`post-fs-data`, before
/// `class_start hal`), only on the vendor build it was made from. Without
/// the overlays, on another build, or until Android restarts after the
/// install, resizes re-plug as before.
enum GuestComposer {
    /// The binary init starts as `vendor.hwcomposer-3`.
    static let binary = "/apex/com.android.hardware.graphics.composer/bin/hw/android.hardware.graphics.composer3-service.ranchu"
    static let staging = "/data/local/tmp/avo-composer"
    static let staged = staging + "/composer"
    /// The copy init mounts, on the vendor overlay.
    static let installedFolder = "/vendor/etc/avo"
    static let installed = installedFolder + "/composer3-service.ranchu"
    /// On the system overlay: init's own actions may mount anywhere
    /// (vendor init files run in the restricted `vendor_init`).
    static let initFile = "/system/etc/init/avo-composer.rc"
    /// The SELinux type of the file it covers: init starts the composer from it.
    static let label = "u:object_r:hal_graphics_composer_default_exec:s0"

    struct Patch: Equatable {
        /// File offset.
        let offset: Int
        let bytes: [UInt8]

        init(offset: Int, hex: String) {
            self.offset = offset
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                bytes.append(UInt8(hex[index..<next], radix: 16)!)
                index = next
            }
            self.bytes = bytes
        }
    }

    /// One known build of the composer and what changes in it.
    struct Build: Equatable {
        let sha256: String
        let patchedSHA256: String
        /// `ro.vendor.build.fingerprint` of the image it comes from.
        let fingerprint: String
        let patches: [Patch]
    }

    static let builds = [
        // AOSP Cuttlefish 16644040 (aosp_cf_arm64_only_phone-userdebug, Android 17).
        Build(sha256: "2eec23c2c515a5fb453cc6bcf246520084733edcba73f4ae42c4b4356dd01215",
              patchedSHA256: "4f0f3a3fab63976bfa36b95fec67f92b62d70d5075e06094a26c115f61a37404",
              fingerprint: "generic/aosp_cf_arm64_only_phone/vsoc_arm64_only:17/CP2A.260605.016/16644040:userdebug/test-keys",
              patches: [
                  // R+X LOAD: p_filesz and p_memsz 0x6cff0 → 0x6f000 (to 0xf7000; the next segment is at 0xf8000).
                  Patch(offset: 0x108, hex: "00f0060000000000"),
                  Patch(offset: 0x110, hex: "00f0060000000000"),
                  // 0xf5000: the `update` wrapper; 0xf5090: destroy before create.
                  Patch(offset: 0xf5000, hex: """
                      fd7bbda9fd030091f65f01a9f81300f9f60300aaf7031faaf8031faabf060071e100005408a441a91f0109eb80000054\
                      080140f9170140f918e140f80d1cff97bf060071c1010054c80640b91f05007161010054c8a641a91f0109eb00010054\
                      080140f9090140f90ae140f83f0117eb400158fa4000005455008052f81340f9f65f41a9fd7bc3a8c0035fd61f2003d5\
                      fd7bbda9fd030091f35301a9f55b02a9f30300aaf40301aaf503022af60303aa094040f9890100b42a1140f95f0114eb\
                      c00000546b000054290140f9faffff17290540f9f8ffff17e00313aae10314aa9cddfe97e00313aae10314aae203152a\
                      e30316aaf55b42a9f35341a9fd7bc3a88cdcfe17
                      """),
                  // checkAndHandleHotplug: `bl DrmConnector::update` → `bl 0xf5000`.
                  Patch(offset: 0xbe058, hex: "eadb0094"),
                  // The hotplug callback: `bl createDisplayLocked` → `bl 0xf5090`.
                  Patch(offset: 0xad980, hex: "c41d0194"),
              ]),
    ]

    enum State: Equatable {
        /// A known build, still as the image has it.
        case stock(Build)
        /// The patched copy runs: resizes keep the display.
        case patched
        /// Another build: left as it is.
        case unknown
    }

    /// From `sha256sum <binary>`.
    static func state(sumOutput: String) -> State {
        let sum = sumOutput.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if let build = builds.first(where: { $0.sha256 == sum }) { return .stock(build) }
        if builds.contains(where: { $0.patchedSHA256 == sum }) { return .patched }
        return .unknown
    }

    /// `printf` octal escapes for `bytes`.
    static func escapes(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "\\%03o", $0) }.joined()
    }

    /// The init file: the copy over the APEX's file, on `build`'s image only.
    static func initScript(_ build: Build) -> String {
        """
        # Avo (GuestComposer): the composer tells SurfaceFlinger about new window sizes.
        on post-fs-data && property:ro.vendor.build.fingerprint=\(build.fingerprint)
            mount none \(installed) \(binary) bind

        """
    }

    /// Run as root: the copy, checked against its hash, then the init file
    /// that uses it from the next boot on. Fails (and leaves the image's
    /// composer in use) when any step does, or when there are no overlays.
    static func installScript(_ build: Build) -> String {
        var lines = [
            "set -e",
            "grep -q '^overlay /vendor overlay' /proc/mounts",
            "grep -q '^overlay /system overlay' /proc/mounts",
            "[ \"$(getprop ro.vendor.build.fingerprint)\" = '\(build.fingerprint)' ]",
            "remount >/dev/null 2>&1",
            "rm -rf \(staging)",
            "mkdir -p \(staging)",
            "cp \(binary) \(staged)",
        ]
        for patch in build.patches {
            lines.append("printf '\(escapes(patch.bytes))' | dd of=\(staged) bs=1 seek=\(patch.offset) conv=notrunc 2>/dev/null")
        }
        lines += [
            "[ \"$(sha256sum \(staged) | cut -d ' ' -f 1)\" = \(build.patchedSHA256) ]",
            "mkdir -p \(installedFolder)",
            "cp \(staged) \(installed)",
            "chown root:shell \(installed)",
            "chmod 755 \(installed)",
            "chcon \(label) \(installed)",
            "printf '%s' '\(initScript(build))' > \(initFile)",
            "chmod 644 \(initFile)",
            "chcon u:object_r:system_file:s0 \(initFile)",
            "rm -rf \(staging)",
            "sync",
        ]
        return lines.joined(separator: "\n")
    }

    /// The copy and its init file are in place already (they apply at the next boot).
    static func pendingCheck(_ build: Build) -> String {
        "[ -f \(initFile) ] && [ \"$(sha256sum \(installed) 2>/dev/null | cut -d ' ' -f 1)\" = \(build.patchedSHA256) ]"
    }
}
