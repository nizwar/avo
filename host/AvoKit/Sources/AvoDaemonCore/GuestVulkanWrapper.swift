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
/// (`VulkanWrapperHelper`, from guest/vkwrap) and the real driver beside it
/// as `vulkan.ranchu.avoreal.so`; the software driver (`vulkan.pastel.so`)
/// needs no copy, since only GPU starts mount it. The wrapper opens the real
/// driver and runs the sync layer over it (guest/vkwrap/src/vk_wrap.c). The
/// real driver's own dependencies stay in the parent `lib64` directory, which
/// the bind mount leaves in place, so it still links.
///
/// Like the composer, this needs the overlays of a `remount` (Google apps)
/// and the known vendor build, and the copy and its init file apply from the
/// next boot: the init file bind-mounts in `post-fs-data`, before
/// SurfaceFlinger and zygote, so every process of a GPU start uses the
/// wrapper, SurfaceFlinger and SystemUI too (their ANGLE then offers OpenGL
/// ES 3.1, as apps' does). It mounts only on a GPU start whose engine set
/// `switchProperty`: the daemon leaves it out after a GPU start that failed
/// with the wrapper (`Failure`), so nothing in Android has to be undone.
/// Without the overlays, or on another vendor build, HostAgent keeps the
/// layer in `/data/local/debug` (`GuestGfxstreamSync`); a boot that runs the
/// wrapper removes the layer there.
enum GuestVulkanWrapper {
    /// The directory libvulkan loads the HAL driver from (`ro.vulkan.apex`).
    static let hwDir = "/apex/com.google.cf.vulkan/lib64/hw"
    static let driverName = "vulkan.ranchu.so"
    /// The real driver, beside the wrapper for it to open. `vk_wrap.c`'s
    /// `REAL_PATH` must match.
    static let realName = "vulkan.ranchu.avoreal.so"

    /// The replacement `hw` directory, on the vendor overlay of a `remount`.
    static let installedDir = "/vendor/etc/avo/vkhw"
    /// On the system overlay: init's own actions may mount anywhere.
    static let initFile = "/system/etc/init/avo-vkwrap.rc"
    /// Where adb pushes this build's wrapper before root moves it into place.
    static let staged = "/data/local/tmp/avo-vkwrap.so"
    /// Driver files load into app processes: a same-process HAL file.
    static let label = "u:object_r:same_process_hal_file:s0"
    /// `1` when the engine lets the wrapper run this start (identity.prop,
    /// read before init's `post-fs-data`).
    static let switchProperty = AvoIdentity.propertyPrefix + "vkwrap"

    /// This build's wrapper (VulkanWrapperHelper, from guest/vkwrap/build.sh)
    /// and its SHA-256, to tell whether the guest already has it.
    static let wrapper: (data: Data, sha256: String)? = {
        Data(base64Encoded: VulkanWrapperHelper.driver).map { ($0, sha256(of: $0)) }
    }()

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

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
        /// The wrapper runs this boot: this build's (`current`), or an older one
        /// over the real driver of `build`, which can be brought up to date.
        case running(current: Bool, build: Build?)
        /// This build's wrapper and init file are in place for the next GPU start.
        case pending
        /// A known build, the stock driver still in place.
        case stock(Build)
        /// Another build: the layer stays in /data/local/debug.
        case unknown
    }

    /// Prints, as `key=value` lines: the bind mount over `hwDir` in init's
    /// mount namespace (empty without one), then the SHA-256 of the driver
    /// libvulkan loads, of the installed wrapper and real driver, and of the
    /// init file (empty for a missing file). Run as root.
    static let stateCommand: String = {
        func sum(_ path: String) -> String { "$(sha256sum \(path) 2>/dev/null | cut -d ' ' -f 1)" }
        return [
            "echo \"mount=$(grep -m 1 ' \(hwDir) ' /proc/1/mountinfo)\"",
            "echo \"loaded=\(sum("\(hwDir)/\(driverName)"))\"",
            "echo \"wrapper=\(sum("\(installedDir)/\(driverName)"))\"",
            "echo \"real=\(sum("\(installedDir)/\(realName)"))\"",
            "echo \"init=\(sum(initFile))\"",
        ].joined(separator: "; ")
    }()

    /// What `stateCommand` printed says about the guest.
    static func state(output: String) -> State {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            values[String(parts[0])] = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        }
        func value(_ key: String) -> String { values[key] ?? "" }
        if value("mount").contains(" \(hwDir) ") {
            return .running(current: value("wrapper") == wrapper?.sha256, build: builds.first { $0.driverSHA256 == value("real") })
        }
        guard let build = builds.first(where: { $0.driverSHA256 == value("loaded") }) else { return .unknown }
        let installed = value("wrapper") == wrapper?.sha256 && value("real") == build.driverSHA256
            && value("init") == sha256(of: Data(initScript(build).utf8))
        return installed ? .pending : .stock(build)
    }

    /// The init file: the directory over the APEX's `hw` one on a GPU start
    /// the engine lets the wrapper run, this build only.
    static func initScript(_ build: Build) -> String {
        """
        # Avo (GuestVulkanWrapper): the gfxstream sync layer runs inside the Vulkan driver.
        on post-fs-data && property:\(switchProperty)=1 && property:ro.boot.hardware.vulkan=ranchu && property:ro.vendor.build.fingerprint=\(build.fingerprint)
            mount none \(installedDir) \(hwDir) bind

        """
    }

    /// Writes this build's init file, renamed into place (run as root, overlays writable).
    private static func initLines(_ build: Build) -> [String] {
        [
            "printf '%s' '\(initScript(build))' > \(initFile).new",
            "chmod 644 \(initFile).new",
            "chcon u:object_r:system_file:s0 \(initFile).new",
            "mv -f \(initFile).new \(initFile)",
        ]
    }

    /// Checks the wrapper adb pushed to `staged` against this build's.
    private static var stagedCheck: String {
        "[ \"$(sha256sum \(staged) | cut -d ' ' -f 1)\" = \(wrapper?.sha256 ?? "x") ]"
    }

    /// Run as root after adb pushed this build's wrapper to `staged`: the
    /// wrapper and a copy of the real driver go onto the vendor overlay, then
    /// the init file that mounts them from the next GPU start. The old init
    /// file goes first, so a failed step leaves nothing to mount; the step
    /// fails without the overlays. The overlay's scratch partition is
    /// mounted `sync`: the 5 MB copy takes a while.
    static func installScript(_ build: Build) -> String {
        ([
            "set -e",
            // Folders a restrictive shell (umask 077) would make root's alone.
            "umask 022",
            "grep -q '^overlay /vendor overlay' /proc/mounts",
            "grep -q '^overlay /system overlay' /proc/mounts",
            "[ \"$(getprop ro.vendor.build.fingerprint)\" = '\(build.fingerprint)' ]",
            "[ \"$(sha256sum \(hwDir)/\(driverName) | cut -d ' ' -f 1)\" = \(build.driverSHA256) ]",
            stagedCheck,
            "remount >/dev/null 2>&1",
            "rm -f \(initFile)",
            "rm -rf \(installedDir)",
            "mkdir -p \(installedDir)",
            // The real driver, copied out from the APEX.
            "cp \(hwDir)/\(driverName) \(installedDir)/\(realName)",
            "cp \(staged) \(installedDir)/\(driverName)",
            "chown -R root:shell \(installedDir)",
            "chmod 755 \(installedDir)",
            "chmod 644 \(installedDir)/*.so",
            "chcon \(label) \(installedDir)/*.so",
        ] + initLines(build) + [
            "rm -f \(staged)",
            "sync",
        ]).joined(separator: "\n")
    }

    /// Run as root on a boot an older wrapper runs: this build's replaces it,
    /// renamed into place (processes that loaded the old one keep it; the
    /// ones started from now on load this one), and the init file is this
    /// build's.
    static func updateScript(_ build: Build) -> String {
        ([
            "set -e",
            "umask 022",
            "[ \"$(sha256sum \(installedDir)/\(realName) | cut -d ' ' -f 1)\" = \(build.driverSHA256) ]",
            stagedCheck,
            "remount >/dev/null 2>&1",
            "cp \(staged) \(installedDir)/.\(driverName).new",
            "chown root:shell \(installedDir)/.\(driverName).new",
            "chmod 644 \(installedDir)/.\(driverName).new",
            "chcon \(label) \(installedDir)/.\(driverName).new",
            "mv -f \(installedDir)/.\(driverName).new \(installedDir)/\(driverName)",
        ] + initLines(build) + [
            "rm -f \(staged)",
            "sync",
        ]).joined(separator: "\n")
    }

    /// Removes the wrapper's init file and directory (the stock driver
    /// returns at the next boot).
    static func uninstallScript() -> String {
        [
            "remount >/dev/null 2>&1",
            "rm -f \(initFile)",
            "rm -rf \(installedDir)",
            "sync",
        ].joined(separator: "\n")
    }

    // MARK: The daemon's side

    /// A GPU start that failed while the wrapper ran, kept in
    /// ~/Library/Application Support/Avo/vm: later starts leave
    /// `switchProperty` out for this build of the wrapper, and a newer build
    /// gets its own try.
    struct Failure: Codable, Equatable {
        var sha256: String
        var failure: GPUFailure
        var date: Date

        static func url(_ paths: AvoPaths) -> URL { paths.vm.appending(path: "vkwrap-failed.json") }

        static func load(paths: AvoPaths) -> Failure? {
            guard let data = try? Data(contentsOf: url(paths)) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Failure.self, from: data)
        }

        func save(paths: AvoPaths) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(at: paths.vm, withIntermediateDirectories: true)
            try encoder.encode(self).write(to: Self.url(paths), options: .atomic)
        }
    }

    /// Whether a start may let the wrapper run: there is one, and it has not
    /// failed a GPU start.
    static func allowed(paths: AvoPaths) -> Bool {
        guard let sha = wrapper?.sha256 else { return false }
        return Failure.load(paths: paths)?.sha256 != sha
    }

    /// Android had the wrapper at its last ready boot (installed, pending or
    /// running), so a GPU start that fails before Android is ready may be its doing.
    static func installedURL(_ paths: AvoPaths) -> URL { paths.vm.appending(path: "vkwrap-installed") }

    static func noteInstalled(_ installed: Bool, paths: AvoPaths) {
        let url = installedURL(paths)
        if installed {
            try? Data().write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func installed(paths: AvoPaths) -> Bool {
        FileManager.default.fileExists(atPath: installedURL(paths).path)
    }
}
