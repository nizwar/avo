import AvoKit
import Foundation
import Testing
@testable import AvoDaemonCore

@Suite struct GuestVulkanWrapperTests {
    let build = GuestVulkanWrapper.builds[0]

    @Test func theWrapperIsAnArm64SharedObject() throws {
        let wrapper = try #require(GuestVulkanWrapper.wrapper)
        // ELF, 64-bit, little endian; e_machine 183 (AArch64).
        #expect(wrapper.data.prefix(6) == Data([0x7f, 0x45, 0x4c, 0x46, 2, 1]))
        #expect(wrapper.data[18] == 183 && wrapper.data[19] == 0)
        #expect(wrapper.sha256.count == 64)
    }

    /// The GPU profile layer rides in the wrapper (guest/gpuprofile, linked
    /// in beside the sync layer): the wrapper enters it by its renamed
    /// avo_profile_* entry points, so the spoof needs no layer in
    /// /data/local/debug and no debug.vulkan.layers (HostAgent).
    @Test func theProfileLayerRidesInTheWrapper() throws {
        let wrapper = try #require(GuestVulkanWrapper.wrapper)
        let symbols = ["avo_profile_create_instance", "avo_profile_create_device", "avo_profile_vkGetInstanceProcAddr"]
        #expect(symbols.filter { wrapper.data.firstRange(of: Data($0.utf8)) == nil }.isEmpty,
                "the profile layer's entry points are in the wrapper")
    }

    @Test func theRealDriverPathMatchesTheWrappersOwn() {
        // vk_wrap.c opens REAL_PATH; the install puts the real driver there.
        #expect(GuestVulkanWrapper.hwDir == "/apex/com.google.cf.vulkan/lib64/hw")
        #expect(GuestVulkanWrapper.realName == "vulkan.ranchu.avoreal.so")
    }

    /// `stateCommand`'s output for a guest.
    private func output(mount: String = "", loaded: String = "", wrapper: String = "", real: String = "", initFile: String = "") -> String {
        "mount=\(mount)\nloaded=\(loaded)\nwrapper=\(wrapper)\nreal=\(real)\ninit=\(initFile)\n"
    }

    private var mountLine: String { "879 86 7:0 / \(GuestVulkanWrapper.hwDir) rw,relatime shared:1 - ext4 /dev/block/dm-12 rw" }
    private var initSum: String { GuestVulkanWrapper.sha256(of: Data(GuestVulkanWrapper.initScript(build).utf8)) }

    @Test func aGuestWithTheStockDriverCanTakeTheWrapper() {
        #expect(GuestVulkanWrapper.state(output: output(loaded: build.driverSHA256)) == .stock(build))
        // An older install, or a different init file, is installed again.
        let wrapper = GuestVulkanWrapper.wrapper?.sha256 ?? ""
        #expect(GuestVulkanWrapper.state(output: output(loaded: build.driverSHA256, wrapper: String(repeating: "0", count: 64),
                                                        real: build.driverSHA256, initFile: initSum)) == .stock(build))
        #expect(GuestVulkanWrapper.state(output: output(loaded: build.driverSHA256, wrapper: wrapper,
                                                        real: build.driverSHA256, initFile: "")) == .stock(build))
    }

    @Test func thisBuildsInstallWaitsForTheNextGPUStart() {
        let wrapper = GuestVulkanWrapper.wrapper?.sha256 ?? ""
        #expect(GuestVulkanWrapper.state(output: output(loaded: build.driverSHA256, wrapper: wrapper, real: build.driverSHA256,
                                                        initFile: initSum)) == .pending)
    }

    @Test func aMountedWrapperRunsThisBoot() {
        let wrapper = GuestVulkanWrapper.wrapper?.sha256 ?? ""
        #expect(GuestVulkanWrapper.state(output: output(mount: mountLine, loaded: wrapper, wrapper: wrapper, real: build.driverSHA256))
            == .running(current: true, build: build))
        // An older wrapper over a known driver can be brought up to date.
        let old = String(repeating: "1", count: 64)
        #expect(GuestVulkanWrapper.state(output: output(mount: mountLine, loaded: old, wrapper: old, real: build.driverSHA256))
            == .running(current: false, build: build))
    }

    @Test func anotherVendorBuildKeepsTheLayerInDataLocal() {
        #expect(GuestVulkanWrapper.state(output: output(loaded: String(repeating: "0", count: 64))) == .unknown)
        #expect(GuestVulkanWrapper.state(output: output()) == .unknown)
        #expect(GuestVulkanWrapper.state(output: "") == .unknown)
    }

    @Test func theInitFileMountsOnlyOnAGPUStartTheEngineAllows() {
        let lines = GuestVulkanWrapper.initScript(build).split(separator: "\n").map(String.init)
        #expect(lines.contains("on post-fs-data && property:ro.boot.avo.vkwrap=1 && property:ro.boot.hardware.vulkan=ranchu"
            + " && property:ro.vendor.build.fingerprint=\(build.fingerprint)"))
        #expect(lines.contains("    mount none \(GuestVulkanWrapper.installedDir) \(GuestVulkanWrapper.hwDir) bind"))
        #expect(!GuestVulkanWrapper.initScript(build).contains("'"), "it is written inside single quotes")
    }

    @Test func theInstallTakesThePushedWrapperAndWritesTheInitFileLast() throws {
        let wrapper = try #require(GuestVulkanWrapper.wrapper)
        let lines = GuestVulkanWrapper.installScript(build).split(separator: "\n").map(String.init)
        #expect(lines.first == "set -e")
        // Only the known build, with the overlays of a remount and this build's wrapper.
        #expect(lines.contains("grep -q '^overlay /vendor overlay' /proc/mounts"))
        #expect(lines.contains("grep -q '^overlay /system overlay' /proc/mounts"))
        #expect(lines.contains { $0.contains("ro.vendor.build.fingerprint") && $0.contains(build.fingerprint) })
        #expect(lines.contains { $0.contains(build.driverSHA256) })
        #expect(lines.contains { $0.contains(GuestVulkanWrapper.staged) && $0.contains(wrapper.sha256) })
        // No bytes in the script: adb pushed them.
        #expect(!GuestVulkanWrapper.installScript(build).contains("base64"))
        let dir = GuestVulkanWrapper.installedDir
        #expect(lines.contains("cp \(GuestVulkanWrapper.hwDir)/vulkan.ranchu.so \(dir)/\(GuestVulkanWrapper.realName)"))
        // Only GPU starts mount it: the software driver needs no copy.
        #expect(!lines.contains { $0.contains("vulkan.pastel.so") })
        #expect(lines.contains("umask 022"), "a restrictive shell would make the folder root's alone")
        #expect(lines.contains("cp \(GuestVulkanWrapper.staged) \(dir)/vulkan.ranchu.so"))
        #expect(lines.contains { $0.hasPrefix("chcon \(GuestVulkanWrapper.label) \(dir)") })
        // The old init file goes before the files change, the new one comes last, by rename.
        let remount = try #require(lines.firstIndex(of: "remount >/dev/null 2>&1"))
        let oldInit = try #require(lines.firstIndex(of: "rm -f \(GuestVulkanWrapper.initFile)"))
        let wipe = try #require(lines.firstIndex(of: "rm -rf \(dir)"))
        let newInit = try #require(lines.firstIndex(of: "mv -f \(GuestVulkanWrapper.initFile).new \(GuestVulkanWrapper.initFile)"))
        #expect(remount < oldInit && oldInit < wipe && wipe < newInit)
        #expect(GuestVulkanWrapper.installScript(build).contains("printf '%s' '\(GuestVulkanWrapper.initScript(build))' > \(GuestVulkanWrapper.initFile).new"))
        #expect(lines.last == "sync")
    }

    @Test func anUpdateRenamesThisBuildsWrapperOverTheRunningOne() throws {
        let wrapper = try #require(GuestVulkanWrapper.wrapper)
        let dir = GuestVulkanWrapper.installedDir
        let lines = GuestVulkanWrapper.updateScript(build).split(separator: "\n").map(String.init)
        #expect(lines.first == "set -e")
        #expect(lines.contains { $0.contains("\(dir)/\(GuestVulkanWrapper.realName)") && $0.contains(build.driverSHA256) })
        #expect(lines.contains { $0.contains(GuestVulkanWrapper.staged) && $0.contains(wrapper.sha256) })
        #expect(lines.contains("mv -f \(dir)/.vulkan.ranchu.so.new \(dir)/vulkan.ranchu.so"))
        #expect(lines.contains("mv -f \(GuestVulkanWrapper.initFile).new \(GuestVulkanWrapper.initFile)"))
        #expect(!lines.contains("rm -rf \(dir)"), "the running wrapper's folder stays")
    }

    @Test func turningItOffRemovesTheInitFileAndDirectory() {
        let lines = GuestVulkanWrapper.uninstallScript().split(separator: "\n").map(String.init)
        #expect(lines.first == "remount >/dev/null 2>&1")
        #expect(lines.contains("rm -f \(GuestVulkanWrapper.initFile)"))
        #expect(lines.contains("rm -rf \(GuestVulkanWrapper.installedDir)"))
    }

    @Test func theStateCommandReadsInitsMountsAndTheFiles() {
        let command = GuestVulkanWrapper.stateCommand
        #expect(command.contains("/proc/1/mountinfo"))
        for path in ["\(GuestVulkanWrapper.hwDir)/vulkan.ranchu.so", "\(GuestVulkanWrapper.installedDir)/vulkan.ranchu.so",
                     "\(GuestVulkanWrapper.installedDir)/\(GuestVulkanWrapper.realName)", GuestVulkanWrapper.initFile] {
            #expect(command.contains("sha256sum \(path) "), "\(path)")
        }
    }

    // MARK: The daemon's side

    private func temporaryPaths() -> (root: URL, paths: AvoPaths) {
        let root = FileManager.default.temporaryDirectory.appending(path: "avo-vkwrap-\(UUID().uuidString.prefix(8))")
        return (root, AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp")))
    }

    @Test func aGPUStartThatFailedWithTheWrapperTurnsThisBuildOfItOff() throws {
        let (root, paths) = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = try #require(GuestVulkanWrapper.wrapper)
        #expect(GuestVulkanWrapper.allowed(paths: paths))
        try GuestVulkanWrapper.Failure(sha256: wrapper.sha256, failure: .crashed, date: Date()).save(paths: paths)
        #expect(!GuestVulkanWrapper.allowed(paths: paths))
        // A newer wrapper gets its own try.
        try GuestVulkanWrapper.Failure(sha256: String(repeating: "0", count: 64), failure: .crashed, date: Date()).save(paths: paths)
        #expect(GuestVulkanWrapper.allowed(paths: paths))
    }

    @Test func theDaemonRemembersWhetherAndroidHasTheWrapper() {
        let (root, paths) = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: paths.vm, withIntermediateDirectories: true)
        #expect(!GuestVulkanWrapper.installed(paths: paths))
        GuestVulkanWrapper.noteInstalled(true, paths: paths)
        #expect(GuestVulkanWrapper.installed(paths: paths))
        GuestVulkanWrapper.noteInstalled(false, paths: paths)
        #expect(!GuestVulkanWrapper.installed(paths: paths))
    }

    @Test func theEngineSwitchesTheWrapperOnInTheIdentityFile() {
        let markers: (AvoIdentity.Renderer) -> AvoIdentity.Markers = {
            AvoIdentity.Markers(version: "0.2.0", hostOS: "macOS 27.0.1", hostChip: "Apple M4 Pro", renderer: $0)
        }
        let on = VMMEngine.identityProperties(profile: .avo, plan: .software(.chosen, nil), vulkanWrapper: true, markers: markers)
        let off = VMMEngine.identityProperties(profile: .avo, plan: .software(.chosen, nil), markers: markers)
        #expect(on.contains("\nro.boot.avo.vkwrap=1\n"))
        #expect(!off.contains("vkwrap"))
        #expect(on == off + "ro.boot.avo.vkwrap=1\n")
    }

    /// Settings › Graphics' "OpenGL ES" below 3.2 rides in the identity file
    /// of a GPU start (the sync layer reads debug.avo.gl.max; Android reports
    /// the same choice). Software has no layer, and 3.2 is the bootconfig's.
    @Test func aChosenGLESVersionRidesInTheIdentityFile() {
        let markers: (AvoIdentity.Renderer) -> AvoIdentity.Markers = {
            AvoIdentity.Markers(version: "0.2.0", hostOS: "macOS 27.0.1", hostChip: "Apple M4 Pro", renderer: $0)
        }
        let emulator = AndroidEmulator(directory: URL(filePath: "/emu"), version: "37.1.11", build: nil)
        let gpu = VMMEngine.identityProperties(profile: .avo, plan: .gpu(emulator), gles: .v3_0, markers: markers)
        #expect(gpu.contains("debug.avo.gl.max=3.0\n"))
        #expect(gpu.contains("ro.opengles.version=196608\n"))
        // The default writes nothing: the layer and the bootconfig say 3.2.
        let def = VMMEngine.identityProperties(profile: .avo, plan: .gpu(emulator), markers: markers)
        #expect(!def.contains("debug.avo.gl.max"))
        // Software has no layer to read it.
        let software = VMMEngine.identityProperties(profile: .avo, plan: .software(.chosen, nil), gles: .v3_0,
                                                    markers: markers)
        #expect(!software.contains("debug.avo.gl.max"))
    }
}
