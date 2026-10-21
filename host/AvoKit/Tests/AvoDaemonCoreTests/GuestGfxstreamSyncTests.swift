import Foundation
import Testing
@testable import AvoDaemonCore

@Suite struct GuestGfxstreamSyncTests {
    @Test func theLayerIsAnArm64SharedObject() throws {
        let layer = try #require(GuestGfxstreamSync.layer)
        // ELF, 64-bit, little endian; e_machine 183 (AArch64).
        #expect(layer.data.prefix(6) == Data([0x7f, 0x45, 0x4c, 0x46, 2, 1]))
        #expect(layer.data[18] == 183 && layer.data[19] == 0)
        #expect(layer.sha256.count == 64)
    }

    @Test func theGuestCopyIsComparedByHash() throws {
        let sha = try #require(GuestGfxstreamSync.layer?.sha256)
        let path = GuestGfxstreamSync.path
        #expect(GuestGfxstreamSync.installed(sumOutput: "") == .missing)
        #expect(GuestGfxstreamSync.installed(sumOutput: "sha256sum: \(path): No such file or directory\n") == .missing)
        #expect(GuestGfxstreamSync.installed(sumOutput: "\(sha)  \(path)\n") == .current)
        #expect(GuestGfxstreamSync.installed(sumOutput: "\(sha.uppercased())  \(path)") == .current)
        #expect(GuestGfxstreamSync.installed(sumOutput: "\(String(repeating: "0", count: 64))  \(path)\n") == .outdated)
    }

    @Test func theInstallRenamesIntoPlace() throws {
        let script = GuestGfxstreamSync.installScript()
        let lines = script.split(separator: "\n").map(String.init)
        #expect(lines.first == "set -e")
        // The loader only reads libVkLayer*.so: the copy stays invisible until the rename.
        let copy = try #require(lines.first { $0.hasPrefix("cp ") })
        #expect(copy.hasSuffix("/.avo-gfxsync.new"))
        #expect(lines.contains("mv -f \(GuestGfxstreamSync.directory)/.avo-gfxsync.new \(GuestGfxstreamSync.path)"))
        #expect(lines.last == "rm -f \(GuestGfxstreamSync.staging)")
        #expect(GuestGfxstreamSync.path == "/data/local/debug/vulkan/libVkLayer_avo_gfxstream_sync.so")
    }

    @Test func theLayerIsNamedOutsideTheProfilesProperty() {
        // debug.vulkan.layers belongs to the device profile's GPU layer.
        #expect(GuestGfxstreamSync.enableCommand == "setprop debug.vulkan.layer.9 VK_LAYER_AVO_gfxstream_sync")
    }

    @Test func aStartWithoutTheGPURemovesTheLayer() {
        let lines = GuestGfxstreamSync.removeScript().split(separator: "\n").map(String.init)
        #expect(lines == [
            "set -e",
            "rm -f /data/local/debug/vulkan/libVkLayer_avo_gfxstream_sync.so /data/local/debug/vulkan/.avo-gfxsync.new",
            // The profile's layers may still be there: only empty folders go.
            "rmdir /data/local/debug/vulkan /data/local/debug 2>/dev/null || true",
        ])
    }
}

@Suite struct GuestGPUDebugLayersTests {
    @Test func theCheckReadsTheFourSettingsInOrder() {
        #expect(GuestGPUDebugLayers.checkCommand == "settings get global enable_gpu_debug_layers; "
            + "settings get global gpu_debug_app; settings get global gpu_debug_layers; "
            + "settings get global gpu_debug_layers_gles")
    }

    @Test func anAppIsOverriddenOnlyWithTheSettingOnAndALayerList() {
        func override(_ values: [String]) -> GuestGPUDebugLayers.Override? {
            GuestGPUDebugLayers.override(checkOutput: values.joined(separator: "\n") + "\n")
        }
        let validation = "VK_LAYER_KHRONOS_validation"
        #expect(override(["1", "com.example.game", validation, "null"])
            == .init(app: "com.example.game", vulkan: validation, gles: nil))
        #expect(override(["1", "com.example.game", "null", "libGLES_glesvalidation.so"])
            == .init(app: "com.example.game", vulkan: nil, gles: "libGLES_glesvalidation.so"))
        // Off, no app, or no lists: Avo's layers load as usual.
        #expect(override(["0", "com.example.game", validation, "null"]) == nil)
        #expect(override(["null", "com.example.game", validation, "null"]) == nil)
        #expect(override(["1", "null", validation, "null"]) == nil)
        #expect(override(["1", "", validation, ""]) == nil)
        #expect(override(["1", "com.example.game", "null", "null"]) == nil)
        #expect(GuestGPUDebugLayers.override(checkOutput: "") == nil)
        #expect(GuestGPUDebugLayers.override(checkOutput: "1\r\ncom.example.game\r\n\(validation)\r\nnull\r\n")?.vulkan == validation)
    }

    @Test func theNoticeNamesTheAppAndWhatItLoads() {
        let notice = GuestGPUDebugLayers.Override(app: "com.example.game", vulkan: "VK_LAYER_KHRONOS_validation", gles: nil).notice
        #expect(notice.contains("com.example.game"))
        #expect(notice.contains("VK_LAYER_KHRONOS_validation"))
        #expect(notice.contains("not Avo's Vulkan layers"))
        #expect(!notice.contains("GLES"))
    }
}
