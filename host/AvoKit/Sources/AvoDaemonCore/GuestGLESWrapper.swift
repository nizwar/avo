import AvoKit
import CryptoKit
import Foundation

/// Reports the device profile's GPU in an app's own `glGetString` from inside
/// ANGLE's GLES library instead of from a GLES layer in `/data/local/debug`
/// (`GuestGPUProfile`), which Android reads only on a debuggable build and
/// where a packer such as FLUJO's ijiami kills an app over a library.
///
/// libEGL loads ANGLE, the GLES driver `ro.hardware.egl` names, from
/// `/system/lib64`. Avo bind-mounts a wrapping `libGLESv2_angle.so`
/// (`GLESWrapperHelper`, from guest/glwrap) over ANGLE's and puts the real
/// library beside it as `libGLESv2_angle.avoreal.so`, which the wrapper needs
/// by that name: it defines only `glGetString` and ANGLE's `GL_GetString`
/// (for ES 1 contexts), so every other function comes from the real library
/// (guest/glwrap/src/gl_wrap.c). The strings, and who sees them (an app's own
/// code; never SurfaceFlinger, HWUI or WebView), are the GLES layer's.
///
/// Like Avo's Vulkan driver wrapper (`GuestVulkanWrapper`), this needs the
/// overlays of a `remount` (Google apps) and the known vendor build, and the
/// copy and its init file apply from the next boot: the init file
/// bind-mounts in `post-fs-data`, before SurfaceFlinger and zygote, on a GPU
/// start that emulates the profile's GPU and whose engine set
/// `switchProperty`. The daemon leaves it out after a GPU start that failed
/// with the wrapper (`Failure`), so nothing in Android has to be undone.
/// Without the overlays, on another build, or on a software start, HostAgent
/// keeps the GLES layer in `/data/local/debug`; a boot that runs the wrapper
/// removes the layer there and leaves `debug.gles.layers` unset.
enum GuestGLESWrapper {
    /// Where libEGL loads ANGLE from.
    static let libDir = "/system/lib64"
    static let libraryName = "libGLESv2_angle.so"
    /// The real library, beside the wrapper for it to need. `gl_wrap.c`'s
    /// `REAL_NAME` and glwrap/build.sh's stub must match.
    static let realName = "libGLESv2_angle.avoreal.so"
    static var libraryPath: String { "\(libDir)/\(libraryName)" }
    static var realPath: String { "\(libDir)/\(realName)" }

    /// The wrapper, on the system overlay of a `remount`.
    static let installedDir = "/system/etc/avo/glwrap"
    static var installedPath: String { "\(installedDir)/\(libraryName)" }
    /// On the system overlay: init's own actions may mount anywhere.
    static let initFile = "/system/etc/init/avo-glwrap.rc"
    /// Where adb pushes this build's wrapper before root moves it into place.
    static let staged = "/data/local/tmp/avo-glwrap.so"
    /// ANGLE's own label: every process loads it.
    static let label = "u:object_r:system_lib_file:s0"
    /// `1` when the engine lets the wrapper run this start (identity.prop,
    /// read before init's `post-fs-data`).
    static let switchProperty = AvoIdentity.propertyPrefix + "glwrap"

    /// This build's wrapper (GLESWrapperHelper, from guest/glwrap/build.sh)
    /// and its SHA-256, to tell whether the guest already has it.
    static let wrapper: (data: Data, sha256: String)? = {
        Data(base64Encoded: GLESWrapperHelper.library).map { ($0, GuestVulkanWrapper.sha256(of: $0)) }
    }()

    /// A vendor build whose ANGLE the wrapper is known to wrap: its
    /// fingerprint (which "Emulate this phone's hardware" leaves alone, unlike
    /// the system partition's), and ANGLE's SHA-256 (the copy beside the wrapper).
    struct Build: Equatable {
        /// `ro.vendor.build.fingerprint` of the image.
        let fingerprint: String
        /// `sha256sum` of the stock `libGLESv2_angle.so`.
        let librarySHA256: String
    }

    static let builds = [
        // AOSP Cuttlefish 16644040 (aosp_cf_arm64_only_phone-userdebug, Android 17), ANGLE 8d8796935e4f.
        Build(fingerprint: "generic/aosp_cf_arm64_only_phone/vsoc_arm64_only:17/CP2A.260605.016/16644040:userdebug/test-keys",
              librarySHA256: "97d81495474cbe1865699d220c6ceaf79f826b02af0c14018f6d3ffd014cd3dc"),
    ]

    enum State: Equatable {
        /// The wrapper runs this boot: this build's (`current`), or an older one
        /// over the real library of `build`, which can be brought up to date.
        case running(current: Bool, build: Build?)
        /// This build's wrapper and init file are in place for the next start
        /// that emulates a GPU.
        case pending
        /// A known build, the stock library still in place.
        case stock(Build)
        /// Another build: the GLES layer stays in /data/local/debug.
        case unknown
    }

    /// Prints, as `key=value` lines: the bind mount over `libraryPath` in
    /// init's mount namespace (empty without one), then the SHA-256 of the
    /// library libEGL loads, of the installed wrapper and real library, and
    /// of the init file (empty for a missing file). Run as root.
    static let stateCommand: String = {
        func sum(_ path: String) -> String { "$(sha256sum \(path) 2>/dev/null | cut -d ' ' -f 1)" }
        return [
            "echo \"mount=$(grep -m 1 ' \(libraryPath) ' /proc/1/mountinfo)\"",
            "echo \"loaded=\(sum(libraryPath))\"",
            "echo \"wrapper=\(sum(installedPath))\"",
            "echo \"real=\(sum(realPath))\"",
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
        if value("mount").contains(" \(libraryPath) ") {
            return .running(current: value("wrapper") == wrapper?.sha256, build: builds.first { $0.librarySHA256 == value("real") })
        }
        guard let build = builds.first(where: { $0.librarySHA256 == value("loaded") }) else { return .unknown }
        let installed = value("wrapper") == wrapper?.sha256 && value("real") == build.librarySHA256
            && value("init") == GuestVulkanWrapper.sha256(of: Data(initScript(build).utf8))
        return installed ? .pending : .stock(build)
    }

    /// The init file: the wrapper over ANGLE's library on a start the engine
    /// lets it run, this build only.
    static func initScript(_ build: Build) -> String {
        """
        # Avo (GuestGLESWrapper): apps read the GPU names of the device profile from inside ANGLE.
        on post-fs-data && property:\(switchProperty)=1 && property:ro.vendor.build.fingerprint=\(build.fingerprint)
            mount none \(installedPath) \(libraryPath) bind

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

    /// Run as root after adb pushed this build's wrapper to `staged`: a copy
    /// of the real library beside ANGLE's and the wrapper go onto the system
    /// overlay, then the init file that mounts the wrapper from the next
    /// start that may run it. The old init file goes first, so a failed step
    /// leaves nothing to mount; the step fails without the overlay.
    static func installScript(_ build: Build) -> String {
        ([
            "set -e",
            "umask 022",
            "grep -q '^overlay /system overlay' /proc/mounts",
            "[ \"$(getprop ro.vendor.build.fingerprint)\" = '\(build.fingerprint)' ]",
            "[ \"$(sha256sum \(libraryPath) | cut -d ' ' -f 1)\" = \(build.librarySHA256) ]",
            stagedCheck,
            "remount >/dev/null 2>&1",
            "rm -f \(initFile)",
            "rm -rf \(installedDir)",
            "mkdir -p \(installedDir)",
            // The real library: copied under a name no one loads, then renamed.
            "cp \(libraryPath) \(realPath).new",
            "chown root:root \(realPath).new",
            "chmod 644 \(realPath).new",
            "chcon \(label) \(realPath).new",
            "mv -f \(realPath).new \(realPath)",
            "cp \(staged) \(installedPath)",
            "chown -R root:root \(installedDir)",
            "chmod 755 \(installedDir)",
            "chmod 644 \(installedPath)",
            "chcon \(label) \(installedPath)",
        ] + initLines(build) + [
            "rm -f \(staged)",
            "sync",
        ]).joined(separator: "\n")
    }

    /// Run as root on a boot an older wrapper runs: this build's replaces it,
    /// renamed into place (processes that loaded the old one keep it; a bind
    /// mount shows the file it was made from, so the new one is seen from
    /// the next boot), and the init file is this build's.
    static func updateScript(_ build: Build) -> String {
        ([
            "set -e",
            "umask 022",
            "[ \"$(sha256sum \(realPath) | cut -d ' ' -f 1)\" = \(build.librarySHA256) ]",
            stagedCheck,
            "remount >/dev/null 2>&1",
            "cp \(staged) \(installedDir)/.\(libraryName).new",
            "chown root:root \(installedDir)/.\(libraryName).new",
            "chmod 644 \(installedDir)/.\(libraryName).new",
            "chcon \(label) \(installedDir)/.\(libraryName).new",
            "mv -f \(installedDir)/.\(libraryName).new \(installedPath)",
        ] + initLines(build) + [
            "rm -f \(staged)",
            "sync",
        ]).joined(separator: "\n")
    }

    /// Removes the wrapper's init file, directory and copy of the real
    /// library (the stock library returns at the next boot).
    static func uninstallScript() -> String {
        [
            "remount >/dev/null 2>&1",
            "rm -f \(initFile)",
            "rm -rf \(installedDir)",
            "rm -f \(realPath)",
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

        static func url(_ paths: AvoPaths) -> URL { paths.vm.appending(path: "glwrap-failed.json") }

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

    /// Whether `plan`'s start runs the wrapper if Android has it: a GPU start
    /// that emulates the profile's GPU and may run it. A software start keeps
    /// the GLES layer, as a failure there has no GPU launch to fall back from.
    static func switchedOn(allowed: Bool, plan: GPUPlan, emulatesGPU: Bool) -> Bool {
        allowed && plan.isGPU && emulatesGPU
    }

    /// Android had the wrapper at its last ready boot (installed, pending or
    /// running), so a GPU start that fails before Android is ready may be its doing.
    static func installedURL(_ paths: AvoPaths) -> URL { paths.vm.appending(path: "glwrap-installed") }

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
