import AvoKit
import CryptoKit
import Foundation

/// Installs Avo's GPU layers in the guest so an app's own renderer reads the
/// device profile's GPU (`DeviceHardware.GPU`) when "Emulate this phone's
/// hardware" is on. They live in `/data/local/debug/gles` and
/// `/data/local/debug/vulkan`, which Android's loaders read on a userdebug
/// (`ro.debuggable=1`) device; the engine sets the `debug.avo.gl.*` and
/// `debug.avo.vk.*` values at boot (`DeviceHardware.gpuProperties`), and the
/// daemon names the layers in `debug.gles.layers` / `debug.vulkan.layers`
/// on a boot that began with the files here, so they load into every app
/// started after that.
///
/// - The GLES layer answers an app's own `glGetString` (vendor, renderer,
///   version) instead of ANGLE, which draws GLES on Avo.
/// - The Vulkan layer answers an app's own `vkGetPhysicalDeviceProperties`.
///
/// Both leave SurfaceFlinger, HWUI, WebView and ANGLE's own Vulkan instance
/// with the real GPU, so the screen still draws.
///
/// libvulkan looks for layers once, as a process starts, and a named layer it
/// did not find then makes vkCreateInstance fail (as GuestGfxstreamSync
/// says). So a layer is named only on a boot that began with its file in
/// place, of any build.
///
/// The files are there only for a boot that emulates a GPU, though. On a
/// userdebug image libvulkan opens every `libVkLayer*.so` in
/// `/data/local/debug/vulkan` to list its layers, named or not, and apps whose
/// packer refuses libraries from `/data/local` kill themselves when one turns
/// up (FLUJO's ijiami: SIGKILL from its RenderThread, then Android restarts
/// it in a loop). A boot that emulates none removes them (`removeScript`),
/// and Settings that ask the next start for a GPU put them in at once
/// (HostAgent.stageGPULayers), so the restart they need already begins with
/// them. Only a setting changed while Android was off waits a boot more.
enum GuestGPUProfile {
    static let debugDir = "/data/local/debug"
    static let glesDir = "\(debugDir)/gles"
    static let vulkanDir = "\(debugDir)/vulkan"
    static let staging = "/data/local/tmp/avo-gpuprofile"
    static let vulkanFile = "libVkLayer_avo_profile.so"

    /// This build's layers (GPUProfileHelper, from guest/gpuprofile/build.sh)
    /// and their SHA-256, to tell whether the guest already has them.
    static let layers: [(name: String, dir: String, data: Data, sha256: String)] = {
        func decode(_ base64: String) -> (Data, String)? {
            Data(base64Encoded: base64).map { ($0, SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()) }
        }
        var out: [(String, String, Data, String)] = []
        if let (data, sha) = decode(GPUProfileHelper.gles) { out.append((DeviceHardware.glesLayer, glesDir, data, sha)) }
        if let (data, sha) = decode(GPUProfileHelper.vulkan) { out.append((vulkanFile, vulkanDir, data, sha)) }
        return out
    }()

    /// The layers' file names (the GLES layer's is also its name).
    static let names = Set(layers.map(\.name))

    /// The script that moves the staged layers into `/data/local/debug` as
    /// root: the loaders need them owned by the app domain (`apk_data_file`)
    /// and world-readable. Each is renamed into place from a name no loader
    /// reads (libvulkan reads `libVkLayer*.so`, libEGL only the names it is
    /// given), so no process maps a half-written file, and one that mapped
    /// the old build keeps it intact.
    static func installScript() -> String {
        var lines = [
            "set -e",
            "mkdir -p \(glesDir) \(vulkanDir)",
            "chmod 755 \(debugDir) \(glesDir) \(vulkanDir)",
            "chcon u:object_r:apk_data_file:s0 \(debugDir) \(glesDir) \(vulkanDir)",
        ]
        for layer in layers {
            let temporary = "\(layer.dir)/.avo-gpuprofile.new"
            lines += [
                "cp \(staging)/\(layer.name) \(temporary)",
                "chmod 644 \(temporary)",
                "chcon u:object_r:apk_data_file:s0 \(temporary)",
                "mv -f \(temporary) \(layer.dir)/\(layer.name)",
            ]
        }
        lines.append("rm -rf \(staging)")
        return lines.joined(separator: "\n")
    }

    /// Removes the layers, and the folders that leaves empty, for a boot that
    /// emulates no GPU: `rmdir` keeps a folder another layer is in (the
    /// gfxstream sync layer's).
    static func removeScript() -> String {
        let files = layers.flatMap { ["\($0.dir)/\($0.name)", "\($0.dir)/.avo-gpuprofile.new"] }
        return [
            "set -e",
            "rm -f " + files.joined(separator: " "),
            "rmdir \(glesDir) \(vulkanDir) \(debugDir) 2>/dev/null || true",
        ].joined(separator: "\n")
    }

    /// Whether a start with `profile` emulates its GPU: the engine then sets
    /// the `debug.avo.gl.*` / `debug.avo.vk.*` values that name the layers.
    static func emulatesGPU(_ profile: DeviceProfile?, emulateHardware: Bool) -> Bool {
        emulateHardware && !(profile?.hardware?.gpuProperties().isEmpty ?? true)
    }

    /// Prints the values that turn the layers on, one line each (empty when
    /// unset): the Vulkan device name, then the three GLES strings.
    static let checkCommand =
        "getprop debug.avo.vk.name; getprop debug.avo.gl.vendor; getprop debug.avo.gl.renderer; getprop debug.avo.gl.version"

    /// The `setprop`s that load the layers this boot, from `checkCommand`'s
    /// output: the GLES layer when the profile has a GLES string, the Vulkan
    /// layer when it has a Vulkan name, each only when its file is in
    /// `present` (`present(sumOutput:)`). Empty when nothing is emulated.
    static func enableCommands(checkOutput: String, present: Set<String>) -> [String] {
        let values = checkOutput.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var commands: [String] = []
        if values.dropFirst().prefix(3).contains(where: { !$0.isEmpty }), present.contains(DeviceHardware.glesLayer) {
            commands.append("setprop debug.gles.layers \(DeviceHardware.glesLayer)")
        }
        if let name = values.first, !name.isEmpty, present.contains(vulkanFile) {
            commands.append("setprop debug.vulkan.layers \(DeviceHardware.vulkanLayer)")
        }
        return commands
    }

    /// Whether every layer in `output` (one `sha256sum` line each) already
    /// matches this build, so the install can be skipped.
    static func upToDate(sumOutput output: String) -> Bool {
        let sums = checksums(output)
        return layers.allSatisfy { sums[$0.name] == $0.sha256 }
    }

    /// The layers `output` finds in the guest, of any build. Read before this
    /// boot's install, they are the ones every process of the boot can find.
    static func present(sumOutput output: String) -> Set<String> {
        names.intersection(checksums(output).keys)
    }

    /// File name → SHA-256, from `sha256sum` lines.
    private static func checksums(_ output: String) -> [String: String] {
        output.split(separator: "\n").reduce(into: [String: String]()) { sums, line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0].count == 64, parts[0].allSatisfy(\.isHexDigit) else { return }
            sums[String(parts[1]).split(separator: "/").last.map(String.init) ?? String(parts[1])] = String(parts[0]).lowercased()
        }
    }
}
