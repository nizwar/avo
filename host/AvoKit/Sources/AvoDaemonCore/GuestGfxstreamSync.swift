import CryptoKit
import Foundation

/// Avo's Vulkan layer against a deadlock in the guest's gfxstream Vulkan
/// driver (vulkan.ranchu, AOSP's Mesa gfxstream), from guest/gfxsync.
///
/// In GPU mode an app that draws with Vulkan on several threads, such as a
/// Flutter app (Impeller) next to HWUI (ANGLE), stops for good: the driver
/// keeps its one lock while a present waits for the host (vkQueueWaitIdle),
/// while another thread has already taken its place in the host's command
/// order for a vkDestroy*() and waits for that lock before it sends the
/// command. The host runs commands strictly in that order, so the present's
/// wait never comes back; every Vulkan thread of the app then blocks on the
/// lock and Android shows "isn't responding". The layer waits for presents
/// outside the driver's lock and keeps destroys apart from the submissions
/// that must still wait inside it (guest/gfxsync/src/vk_layer.c).
///
/// It also splits fragment output arrays into separate outputs as shader
/// modules are made (guest/gfxsync/src/frag_outputs.c): the host's MoltenVK
/// cannot make a pipeline from one, such as ANGLE's gl_FragData[8], when the
/// subpass has fewer colour attachments ("'color' attribute must be made
/// explicit"), which games such as Need for Speed No Limits hit.
///
/// And it gives ANGLE's own instance `VK_EXT_provoking_vertex`, which the
/// driver and MoltenVK lack: without it the image's ANGLE offers no OpenGL ES
/// above 2.0, with it apps get ES 3.2 (the layer also turns ANGLE's
/// exposeES32ForTesting on). The layer drops the extension again on
/// its way to the driver, so `flat` varyings come from a primitive's first
/// vertex rather than its last.
///
/// The loader takes layers from `/data/local/debug/vulkan` on a userdebug
/// (`ro.debuggable=1`) image and loads the ones `debug.vulkan.layer.N` names
/// (beside `debug.vulkan.layers`, which the device profile's GPU layer uses).
/// A named layer the loader did not find when the process started makes
/// vkCreateInstance fail (VK_ERROR_LAYER_NOT_PRESENT), and with it ANGLE,
/// HWUI and system_server. So the property is set only on a boot that began
/// with the file in place: the boot that first installs it waits for the next.
///
/// A boot without the GPU removes the file again (`removeScript`): unnamed,
/// libvulkan still opens it in every app, and some apps kill themselves over
/// a library from `/data/local` (GuestGPUProfile says which). A setting that
/// asks for the GPU again puts it back at once (HostAgent.stageGPULayers), so
/// the restart it needs begins with the file.
enum GuestGfxstreamSync {
    static let layerName = "VK_LAYER_AVO_gfxstream_sync"
    static let fileName = "libVkLayer_avo_gfxstream_sync.so"
    static let directory = "/data/local/debug/vulkan"
    static let path = "\(directory)/\(fileName)"
    /// Where adb pushes the layer before root moves it into place.
    static let staging = "/data/local/tmp/avo-gfxsync"
    /// The last of the numbered layer properties the loader always reads (0…9).
    static let property = "debug.vulkan.layer.9"
    /// The gfxstream driver: `ro.hardware.vulkan` in GPU mode (guest.rs).
    static let gpuModeDriver = "ranchu"

    /// This build's layer (GfxstreamSyncHelper, from guest/gfxsync/build.sh) and its SHA-256.
    static let layer: (data: Data, sha256: String)? = {
        Data(base64Encoded: GfxstreamSyncHelper.vulkan).map { ($0, SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()) }
    }()

    enum Installed: Equatable {
        /// No layer in the guest yet: no process this boot can load it.
        case missing
        /// An older build: processes found it at start, so this boot may enable it once replaced.
        case outdated
        case current
    }

    /// What `sha256sum <path>` (nothing when the file is missing) says about the guest's copy.
    static func installed(sumOutput output: String) -> Installed {
        guard let line = output.split(separator: "\n").first(where: { $0.hasSuffix(fileName) }),
              let sum = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
        else { return .missing }
        return String(sum).lowercased() == layer?.sha256 ? .current : .outdated
    }

    /// Moves the staged layer into place as root, readable by every app. A
    /// rename, so no process ever maps a half-written file, and under a name
    /// the loader skips until then (it reads `libVkLayer*.so` only).
    static func installScript() -> String {
        let temporary = "\(directory)/.avo-gfxsync.new"
        return [
            "set -e",
            "mkdir -p \(directory)",
            "chmod 755 /data/local/debug \(directory)",
            "cp \(staging) \(temporary)",
            "chmod 644 \(temporary)",
            "chcon u:object_r:apk_data_file:s0 /data/local/debug \(directory) \(temporary)",
            "mv -f \(temporary) \(path)",
            "rm -f \(staging)",
        ].joined(separator: "\n")
    }

    /// Removes the layer, and the folders that leaves empty, for a boot
    /// without the GPU: `rmdir` keeps a folder another layer is in.
    static func removeScript() -> String {
        [
            "set -e",
            "rm -f \(path) \(directory)/.avo-gfxsync.new",
            "rmdir \(directory) /data/local/debug 2>/dev/null || true",
        ].joined(separator: "\n")
    }

    /// Names the layer for every Vulkan instance created from now on.
    static let enableCommand = "setprop \(property) \(layerName)"
}

/// Android's own GPU debug layers (Developer options › "Enable GPU debug
/// layers", or a GPU profiler such as AGI). While `enable_gpu_debug_layers`
/// is on and `gpu_debug_app` names an app, Android loads `gpu_debug_layers`
/// into every Vulkan instance of that app, ANGLE's included, in place of the
/// layers `debug.vulkan.layers` and `debug.vulkan.layer.N` name, and
/// `gpu_debug_layers_gles` in place of `debug.gles.layers`. Unless those
/// lists name Avo's layers, the app runs without them: no guard against the
/// gfxstream deadlock, no MoltenVK shader fixes, no profile GPU. The settings
/// belong to the user (or to the profiler, which sets and clears them around
/// a capture), so the daemon only says so in its log.
enum GuestGPUDebugLayers {
    static let settings = ["enable_gpu_debug_layers", "gpu_debug_app", "gpu_debug_layers", "gpu_debug_layers_gles"]
    /// Prints the settings, one line each (`null` when unset).
    static let checkCommand = settings.map { "settings get global \($0)" }.joined(separator: "; ")

    /// The app whose layers the settings replace, and the lists it loads
    /// instead (nil where a list is empty, and Avo's layers still load).
    struct Override: Equatable {
        var app: String
        var vulkan: String?
        var gles: String?

        var notice: String {
            var replaced: [String] = []
            if let vulkan { replaced.append("its Vulkan, ANGLE's included, loads only \(vulkan) (gpu_debug_layers), not Avo's Vulkan layers") }
            if let gles { replaced.append("its GLES loads only \(gles) (gpu_debug_layers_gles), not Avo's GLES layer") }
            return "Android's GPU debug layers are on for \(app): " + replaced.joined(separator: "; ")
                + " (Developer options › Enable GPU debug layers turns them off)"
        }
    }

    /// From `checkCommand`'s output; nil when the settings replace no app's layers.
    static func override(checkOutput output: String) -> Override? {
        let values = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        func value(_ index: Int) -> String? {
            values.indices.contains(index) && !values[index].isEmpty && values[index] != "null" ? values[index] : nil
        }
        guard let enabled = value(0).flatMap({ Int($0) }), enabled != 0, let app = value(1),
              value(2) != nil || value(3) != nil else { return nil }
        return Override(app: app, vulkan: value(2), gles: value(3))
    }
}
