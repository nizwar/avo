import AvoKit
import CryptoKit
import Foundation

/// Runs the gfxstream sync layer (guest/gfxsync, `GuestGfxstreamSync`) from
/// inside the Vulkan HAL driver instead of from `/data/local/debug`, so an
/// app whose packer kills it over a library there (FLUJO's ijiami) never sees
/// one in GPU mode.
///
/// Android's libvulkan loads the HAL driver named by `ro.hardware.vulkan`
/// (ranchu) from `/apex/com.google.cf.vulkan/lib64/hw/vulkan.ranchu.so`. Avo
/// puts a directory over that `hw` one (a bind mount, like `GuestComposer`'s
/// over the composer binary) holding a wrapping `vulkan.ranchu.so`
/// (`VulkanWrapperHelper`, from guest/vkwrap), the real driver beside it as
/// `vulkan.ranchu.avoreal.so`, and the unchanged software driver
/// `vulkan.pastel.so`. The wrapper opens the real driver and runs the sync
/// layer over it (guest/vkwrap/src/vk_wrap.c). The real driver's own
/// dependencies stay in the parent `lib64` directory, which the bind mount
/// leaves in place, so it still links.
///
/// Like the composer, this needs the overlays of a `remount` and the known
/// vendor build, and the copy and its init file apply from the next boot:
/// the init file bind-mounts in `post-fs-data`, before zygote, so every app
/// starts with the wrapper. Without the overlays HostAgent keeps the layer in
/// `/data/local/debug` instead (`GuestGfxstreamSync`), and on a boot that
/// runs the wrapper it installs and names no gfxstream sync layer there.
enum GuestVulkanWrapper {
    /// The directory libvulkan loads the HAL driver from (`ro.vulkan.apex`).
    static let hwDir = "/apex/com.google.cf.vulkan/lib64/hw"
    static let driverName = "vulkan.ranchu.so"
    /// The real driver, beside the wrapper for it to open. `vk_wrap.c`'s
    /// `REAL_PATH` must match.
    static let realName = "vulkan.ranchu.avoreal.so"
    /// The software driver, copied in unchanged so it still resolves.
    static let softwareName = "vulkan.pastel.so"

    /// The replacement `hw` directory, on the vendor overlay of a `remount`.
    static let installedDir = "/vendor/etc/avo/vkhw"
    /// On the system overlay: init's own actions may mount anywhere.
    static let initFile = "/system/etc/init/avo-vkwrap.rc"
    static let staging = "/data/local/tmp/avo-vkwrap"
    /// Driver files load into app processes: a same-process HAL file.
    static let label = "u:object_r:same_process_hal_file:s0"

    /// This build's wrapper (VulkanWrapperHelper, from guest/vkwrap/build.sh)
    /// and its SHA-256, to tell whether the guest already has it.
    static let wrapper: (data: Data, sha256: String)? = {
        Data(base64Encoded: VulkanWrapperHelper.driver).map {
            ($0, SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined())
        }
    }()

    /// A vendor build whose gfxstream driver the wrapper is known to open: its
    /// fingerprint, and the driver's SHA-256 (the copy beside the wrapper).
    struct Build: Equatable {
        /// `ro.vendor.build.fingerprint` of the image.
        let fingerprint: String
        /// `sha256sum` of the stock `vulkan.ranchu.so`.
        let driverSHA256: String
    }

    static let builds = [
        // AOSP Cuttlefish 16644040 (aosp_cf_arm64_only_phone-userdebug, Android 17).
        Build(fingerprint: "generic/aosp_cf_arm64_only_phone/vsoc_arm64_only:17/CP2A.260605.016/16644040:userdebug/test-keys",
              driverSHA256: "3910089c6abe5031dc09d846a292e6d0705ee0c29e31dab3262e1e59f1366419"),
    ]

    enum State: Equatable {
        /// A known build, the stock driver still in place.
        case stock(Build)
        /// The wrapper is in place (its init file and this build's driver copy).
        case wrapped
        /// Another build, or no overlays: the layer stays in /data/local/debug.
        case unknown
    }

    /// The build whose driver matches `sumOutput` (`sha256sum` of the stock
    /// `vulkan.ranchu.so`), if any.
    static func build(driverSumOutput sumOutput: String) -> Build? {
        let sum = sumOutput.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return builds.first { $0.driverSHA256 == sum }
    }

    /// The init file: the directory over the APEX's `hw` one, this build only.
    static func initScript(_ build: Build) -> String {
        """
        # Avo (GuestVulkanWrapper): the gfxstream sync layer runs inside the Vulkan driver.
        on post-fs-data && property:ro.vendor.build.fingerprint=\(build.fingerprint)
            mount none \(installedDir) \(hwDir) bind

        """
    }

    /// Run as root: the wrapper and a copy of the real driver into the vendor
    /// overlay, then the init file that mounts them from the next boot. Fails
    /// (and leaves the stock driver in use) when any step does, or when there
    /// are no overlays. `wrapperBase64` is this build's wrapper.
    static func installScript(_ build: Build, wrapperBase64: String) -> String {
        [
            "set -e",
            "grep -q '^overlay /vendor overlay' /proc/mounts",
            "grep -q '^overlay /system overlay' /proc/mounts",
            "[ \"$(getprop ro.vendor.build.fingerprint)\" = '\(build.fingerprint)' ]",
            "[ \"$(sha256sum \(hwDir)/\(driverName) | cut -d ' ' -f 1)\" = \(build.driverSHA256) ]",
            "remount >/dev/null 2>&1",
            "rm -rf \(staging)",
            "mkdir -p \(staging)",
            // The real driver and the software driver, copied out from the APEX.
            "cp \(hwDir)/\(driverName) \(staging)/\(realName)",
            "cp \(hwDir)/\(softwareName) \(staging)/\(softwareName)",
            // The wrapper, as this build's bytes.
            "printf %s '\(wrapperBase64)' | base64 -d > \(staging)/\(driverName)",
            "[ \"$(sha256sum \(staging)/\(driverName) | cut -d ' ' -f 1)\" = \(wrapper?.sha256 ?? "") ]",
            "rm -rf \(installedDir)",
            "mkdir -p \(installedDir)",
            "cp \(staging)/\(realName) \(staging)/\(softwareName) \(staging)/\(driverName) \(installedDir)/",
            "chown -R root:shell \(installedDir)",
            "chmod 755 \(installedDir)",
            "chmod 644 \(installedDir)/*.so",
            "chcon \(label) \(installedDir)/*.so",
            "printf '%s' '\(initScript(build))' > \(initFile)",
            "chmod 644 \(initFile)",
            "chcon u:object_r:system_file:s0 \(initFile)",
            "rm -rf \(staging)",
            "sync",
        ].joined(separator: "\n")
    }

    /// The wrapper and its init file are in place (they apply at the next boot).
    static func pendingCheck() -> String {
        "[ -f \(initFile) ] && [ \"$(sha256sum \(installedDir)/\(driverName) 2>/dev/null | cut -d ' ' -f 1)\" "
            + "= \(wrapper?.sha256 ?? "x") ]"
    }

    /// Whether the running boot loads the wrapper: libvulkan mapped the
    /// driver from the bind-mounted directory. `mountOutput` is
    /// `grep vulkan.*lib64/hw /proc/1/mountinfo`.
    static func mounted(mountOutput: String) -> Bool {
        mountOutput.contains(hwDir)
    }

    /// Removes the wrapper's init file and directory, for turning it off (the
    /// stock driver returns at the next boot).
    static func uninstallScript() -> String {
        [
            "rm -f \(initFile)",
            "rm -rf \(installedDir)",
            "sync",
        ].joined(separator: "\n")
    }
}
