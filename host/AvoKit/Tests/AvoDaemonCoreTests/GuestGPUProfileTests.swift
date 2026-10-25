import AvoKit
import Foundation
import Testing
@testable import AvoDaemonCore

@Suite struct GuestGPUProfileTests {
    @Test func bothLayersAreArm64SharedObjects() {
        #expect(GuestGPUProfile.layers.map(\.name) == ["libGLES_avo_profile.so", "libVkLayer_avo_profile.so"])
        #expect(GuestGPUProfile.layers.map(\.dir) == ["/data/local/debug/gles", "/data/local/debug/vulkan"])
        for layer in GuestGPUProfile.layers {
            // ELF, 64-bit, little endian; e_machine 183 (AArch64).
            #expect(layer.data.prefix(6) == Data([0x7f, 0x45, 0x4c, 0x46, 2, 1]), "\(layer.name)")
            #expect(layer.data[18] == 183 && layer.data[19] == 0, "\(layer.name)")
            #expect(layer.sha256.count == 64)
        }
    }

    @Test func theInstallRenamesEachLayerIntoItsLoadersDirectory() throws {
        let lines = GuestGPUProfile.installScript().split(separator: "\n").map(String.init)
        #expect(lines.first == "set -e")
        #expect(lines.contains("mkdir -p /data/local/debug/gles /data/local/debug/vulkan"))
        #expect(lines.contains("chcon u:object_r:apk_data_file:s0 /data/local/debug /data/local/debug/gles /data/local/debug/vulkan"))
        for (dir, name) in [("gles", "libGLES_avo_profile.so"), ("vulkan", "libVkLayer_avo_profile.so")] {
            // Copied under a name no loader reads, labelled, then renamed over the old copy.
            let temporary = "/data/local/debug/\(dir)/.avo-gpuprofile.new"
            let copy = try #require(lines.firstIndex(of: "cp /data/local/tmp/avo-gpuprofile/\(name) \(temporary)"))
            let label = try #require(lines.firstIndex(of: "chcon u:object_r:apk_data_file:s0 \(temporary)"))
            let rename = try #require(lines.firstIndex(of: "mv -f \(temporary) /data/local/debug/\(dir)/\(name)"))
            #expect(lines.contains("chmod 644 \(temporary)"))
            #expect(copy < label && label < rename)
        }
        #expect(!lines.contains { $0.hasPrefix("cp ") && $0.hasSuffix(".so") })
        #expect(lines.last == "rm -rf /data/local/tmp/avo-gpuprofile")
    }

    @Test func theProfilesValuesPickTheLayersToLoad() {
        let gles = "setprop debug.gles.layers libGLES_avo_profile.so"
        let vulkan = "setprop debug.vulkan.layers VK_LAYER_AVO_profile"
        let all = GuestGPUProfile.names
        // getprop prints an empty line for an unset property.
        #expect(GuestGPUProfile.enableCommands(checkOutput: "\n\n\n\n", present: all).isEmpty)
        #expect(GuestGPUProfile.enableCommands(checkOutput: "", present: all).isEmpty)
        #expect(GuestGPUProfile.enableCommands(checkOutput: "Adreno (TM) 750\nQualcomm\nAdreno (TM) 750\nV@0762.11\n", present: all)
            == [gles, vulkan])
        #expect(GuestGPUProfile.enableCommands(checkOutput: "Adreno (TM) 750\n\n\n\n", present: all) == [vulkan])
        #expect(GuestGPUProfile.enableCommands(checkOutput: "\nQualcomm\n\n\n", present: all) == [gles])
        #expect(GuestGPUProfile.enableCommands(checkOutput: "\r\n\r\n\r\nV@0762.11\r\n", present: all) == [gles])
    }

    @Test func aLayerIsNamedOnlyOnABootThatBeganWithItsFile() throws {
        let check = "Adreno (TM) 750\nQualcomm\nAdreno (TM) 750\nV@0762.11\n"
        let gles = try #require(GuestGPUProfile.layers.first)
        let vulkan = try #require(GuestGPUProfile.layers.last)
        // Avo's first boot: nothing there yet, so nothing named until the next.
        #expect(GuestGPUProfile.present(sumOutput: "").isEmpty)
        #expect(GuestGPUProfile.enableCommands(checkOutput: check, present: []).isEmpty)
        // An older build of each counts: processes found it as they started.
        let old = String(repeating: "0", count: 64)
        let both = "\(old)  \(gles.dir)/\(gles.name)\n\(old)  \(vulkan.dir)/\(vulkan.name)\n"
        #expect(GuestGPUProfile.present(sumOutput: both) == GuestGPUProfile.names)
        #expect(!GuestGPUProfile.upToDate(sumOutput: both))
        // Only the Vulkan layer (an older daemon): its property now, the GLES one next boot.
        let present = GuestGPUProfile.present(sumOutput: "\(vulkan.sha256)  \(vulkan.dir)/\(vulkan.name)\n")
        #expect(present == ["libVkLayer_avo_profile.so"])
        #expect(GuestGPUProfile.enableCommands(checkOutput: check, present: present)
            == ["setprop debug.vulkan.layers VK_LAYER_AVO_profile"])
        // Error lines (were stderr to show) are not files.
        #expect(GuestGPUProfile.present(sumOutput: "sha256sum: \(gles.dir)/\(gles.name): No such file or directory\n").isEmpty)
    }

    /// Unnamed, libvulkan still opens the Vulkan layer in every app, and apps
    /// that refuse libraries from /data/local (FLUJO) kill themselves over it.
    @Test func aBootThatEmulatesNoGPURemovesBothLayers() {
        let lines = GuestGPUProfile.removeScript().split(separator: "\n").map(String.init)
        #expect(lines.first == "set -e")
        let remove = lines.first { $0.hasPrefix("rm -f ") } ?? ""
        for layer in GuestGPUProfile.layers {
            #expect(remove.contains(" \(layer.dir)/\(layer.name)"), "\(layer.name)")
            #expect(remove.contains(" \(layer.dir)/.avo-gpuprofile.new"), "\(layer.name)")
        }
        // Only folders left empty go: the gfxstream sync layer may still be in vulkan/.
        #expect(lines.last == "rmdir /data/local/debug/gles /data/local/debug/vulkan /data/local/debug 2>/dev/null || true")
        #expect(!lines.contains { $0.contains("rm -rf") })
    }

    @Test func onlyAProfileWithAGPUEmulatesOne() {
        let phone = DeviceProfile(id: "phone", name: "Phone", properties: [:],
                                  hardware: DeviceHardware(gpu: .init(glVendor: "Qualcomm", glRenderer: "Adreno (TM) 750")))
        let socOnly = DeviceProfile(id: "soc", name: "SoC", properties: [:],
                                    hardware: DeviceHardware(soc: .init(manufacturer: "Qualcomm", model: "SM8650")))
        #expect(GuestGPUProfile.emulatesGPU(phone, emulateHardware: true))
        #expect(!GuestGPUProfile.emulatesGPU(phone, emulateHardware: false))
        #expect(!GuestGPUProfile.emulatesGPU(socOnly, emulateHardware: true))
        #expect(!GuestGPUProfile.emulatesGPU(DeviceProfile.avo, emulateHardware: true))
        #expect(!GuestGPUProfile.emulatesGPU(nil, emulateHardware: true))
    }

    @Test func theGuestCopiesAreComparedByHash() throws {
        let output = GuestGPUProfile.layers.map { "\($0.sha256)  \($0.dir)/\($0.name)" }.joined(separator: "\n")
        #expect(GuestGPUProfile.upToDate(sumOutput: output))
        // A guest that has only the Vulkan layer (an older daemon) gets both.
        let vulkan = try #require(GuestGPUProfile.layers.last)
        #expect(!GuestGPUProfile.upToDate(sumOutput: "\(vulkan.sha256)  \(vulkan.dir)/\(vulkan.name)"))
        #expect(!GuestGPUProfile.upToDate(sumOutput: ""))
    }

    // MARK: A boot the Vulkan driver wrapper runs (the layer rides inside it)

    /// The wrapper carries the profile layer inside the HAL driver
    /// (guest/vkwrap), so only the GLES layer goes in /data/local/debug.
    @Test func aBootWithTheWrapperInstallsOnlyTheGlesLayer() throws {
        let gles = try #require(GuestGPUProfile.layers.first)
        #expect(GuestGPUProfile.layersToInstall(vulkan: false).map(\.name) == [gles.name])
        let lines = GuestGPUProfile.installScript(vulkan: false).split(separator: "\n").map(String.init)
        #expect(lines.contains("mkdir -p /data/local/debug/gles"))
        #expect(lines.contains("chmod 755 /data/local/debug /data/local/debug/gles"))
        #expect(lines.contains("chcon u:object_r:apk_data_file:s0 /data/local/debug /data/local/debug/gles"))
        let copy = try #require(lines.firstIndex(of: "cp /data/local/tmp/avo-gpuprofile/\(gles.name) /data/local/debug/gles/.avo-gpuprofile.new"))
        let rename = try #require(lines.firstIndex(of: "mv -f /data/local/debug/gles/.avo-gpuprofile.new /data/local/debug/gles/\(gles.name)"))
        #expect(copy < rename)
        #expect(!lines.contains { $0.contains(GuestGPUProfile.vulkanDir) }, "the Vulkan loader's folder stays untouched")
        #expect(lines.last == "rm -rf /data/local/tmp/avo-gpuprofile")
    }

    /// debug.vulkan.layers stays unset on such a boot: the /data/local/debug
    /// path needs ro.debuggable=1, the wrapper does not.
    @Test func aBootWithTheWrapperNamesNoVulkanLayer() {
        let check = "Adreno (TM) 750\nQualcomm\nAdreno (TM) 750\nV@0762.11\n"
        let gles = "setprop debug.gles.layers libGLES_avo_profile.so"
        #expect(GuestGPUProfile.enableCommands(checkOutput: check, present: GuestGPUProfile.names, vulkan: false) == [gles])
        // A Vulkan name alone names nothing: the wrapper answers it.
        #expect(GuestGPUProfile.enableCommands(checkOutput: "Adreno (TM) 750\n\n\n\n", present: GuestGPUProfile.names,
                                               vulkan: false).isEmpty)
    }

    @Test func theGlesLayerAloneIsUpToDateForTheWrapper() throws {
        let gles = try #require(GuestGPUProfile.layers.first)
        #expect(GuestGPUProfile.upToDate(sumOutput: "\(gles.sha256)  \(gles.dir)/\(gles.name)", vulkan: false))
        #expect(!GuestGPUProfile.upToDate(sumOutput: "", vulkan: false))
    }

    /// The file a boot without the wrapper left goes: unnamed, libvulkan
    /// would still open it in every app.
    @Test func aBootWithTheWrapperTakesTheVulkanLayerAway() {
        let lines = GuestGPUProfile.removeVulkanScript().split(separator: "\n").map(String.init)
        #expect(lines.first == "set -e")
        #expect(lines.contains("rm -f /data/local/debug/vulkan/libVkLayer_avo_profile.so"
                               + " /data/local/debug/vulkan/.avo-gpuprofile.new"))
        #expect(lines.last == "rmdir /data/local/debug/vulkan 2>/dev/null || true")
        // The GLES layer and its folder stay.
        #expect(!lines.contains { $0.contains(GuestGPUProfile.glesDir) })
    }
    // MARK: A boot the ANGLE wrapper runs (GuestGLESWrapper)

    /// The ANGLE wrapper answers glGetString from inside ANGLE: with the
    /// Vulkan driver wrapper too, nothing of the profile goes in /data/local/debug.
    @Test func aBootWithTheANGLEWrapperInstallsNoGlesLayer() throws {
        let vulkan = try #require(GuestGPUProfile.layers.last)
        #expect(GuestGPUProfile.layersToInstall(gles: false).map(\.name) == [vulkan.name])
        #expect(GuestGPUProfile.layersToInstall(vulkan: false, gles: false).isEmpty)
        let lines = GuestGPUProfile.installScript(gles: false).split(separator: "\n").map(String.init)
        #expect(!lines.contains { $0.contains(GuestGPUProfile.glesDir) }, "the GLES loader's folder stays untouched")
        #expect(GuestGPUProfile.upToDate(sumOutput: "\(vulkan.sha256)  \(vulkan.dir)/\(vulkan.name)", gles: false))
        #expect(GuestGPUProfile.upToDate(sumOutput: "", vulkan: false, gles: false))
    }

    /// debug.gles.layers stays unset on such a boot: the /data/local/debug
    /// path needs ro.debuggable=1, the wrapper does not.
    @Test func aBootWithTheANGLEWrapperNamesNoGlesLayer() {
        let check = "Adreno (TM) 750\nQualcomm\nAdreno (TM) 750\nV@0762.11\n"
        #expect(GuestGPUProfile.enableCommands(checkOutput: check, present: GuestGPUProfile.names, gles: false)
            == ["setprop debug.vulkan.layers \(DeviceHardware.vulkanLayer)"])
        #expect(GuestGPUProfile.enableCommands(checkOutput: check, present: GuestGPUProfile.names, vulkan: false, gles: false).isEmpty)
        #expect(GuestGPUProfile.wantsGLES(checkOutput: check))
        #expect(!GuestGPUProfile.wantsGLES(checkOutput: "Adreno (TM) 750\n\n\n\n"))
    }

    /// The file a boot without the wrapper left goes; the Vulkan one stays.
    @Test func aBootWithTheANGLEWrapperTakesTheGlesLayerAway() {
        let lines = GuestGPUProfile.removeGLESScript().split(separator: "\n").map(String.init)
        #expect(lines.first == "set -e")
        #expect(lines.contains("rm -f /data/local/debug/gles/\(DeviceHardware.glesLayer) /data/local/debug/gles/.avo-gpuprofile.new"))
        #expect(!lines.contains { $0.contains(GuestGPUProfile.vulkanDir) })
    }
}
