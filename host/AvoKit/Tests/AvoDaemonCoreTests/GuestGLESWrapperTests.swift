import AvoKit
import Foundation
import Testing
@testable import AvoDaemonCore

@Suite struct GuestGLESWrapperTests {
    let build = GuestGLESWrapper.builds[0]

    @Test func theWrapperIsAnArm64SharedObject() throws {
        let wrapper = try #require(GuestGLESWrapper.wrapper)
        // ELF, 64-bit, little endian; e_machine 183 (AArch64).
        #expect(wrapper.data.prefix(6) == Data([0x7f, 0x45, 0x4c, 0x46, 2, 1]))
        #expect(wrapper.data[18] == 183 && wrapper.data[19] == 0)
        #expect(wrapper.sha256.count == 64)
    }

    /// libEGL takes every function from ANGLE's library by dlsym: the wrapper
    /// answers the glGetString family and needs the real library, by the
    /// name the install gives it, for the rest.
    @Test func theWrapperNeedsTheRealLibraryAndAnswersGlGetString() throws {
        let wrapper = try #require(GuestGLESWrapper.wrapper)
        for name in [GuestGLESWrapper.realName, GuestGLESWrapper.libraryName, "glGetString", "GL_GetString"] {
            #expect(wrapper.data.firstRange(of: Data(name.utf8)) != nil, "\(name)")
        }
        #expect(GuestGLESWrapper.libraryPath == "/system/lib64/libGLESv2_angle.so")
        #expect(GuestGLESWrapper.realPath == "/system/lib64/libGLESv2_angle.avoreal.so")
    }

    /// `stateCommand`'s output for a guest.
    private func output(mount: String = "", loaded: String = "", wrapper: String = "", real: String = "", initFile: String = "") -> String {
        "mount=\(mount)\nloaded=\(loaded)\nwrapper=\(wrapper)\nreal=\(real)\ninit=\(initFile)\n"
    }

    private var mountLine: String {
        "880 86 254:9 /overlay/system/upper/etc/avo/glwrap/libGLESv2_angle.so \(GuestGLESWrapper.libraryPath) ro,relatime shared:1 - overlay overlay ro"
    }
    private var initSum: String { GuestVulkanWrapper.sha256(of: Data(GuestGLESWrapper.initScript(build).utf8)) }

    @Test func aGuestWithTheStockLibraryCanTakeTheWrapper() {
        #expect(GuestGLESWrapper.state(output: output(loaded: build.librarySHA256)) == .stock(build))
        let wrapper = GuestGLESWrapper.wrapper?.sha256 ?? ""
        #expect(GuestGLESWrapper.state(output: output(loaded: build.librarySHA256, wrapper: String(repeating: "0", count: 64),
                                                      real: build.librarySHA256, initFile: initSum)) == .stock(build))
        #expect(GuestGLESWrapper.state(output: output(loaded: build.librarySHA256, wrapper: wrapper,
                                                      real: build.librarySHA256, initFile: "")) == .stock(build))
    }

    @Test func thisBuildsInstallWaitsForTheNextStart() {
        let wrapper = GuestGLESWrapper.wrapper?.sha256 ?? ""
        #expect(GuestGLESWrapper.state(output: output(loaded: build.librarySHA256, wrapper: wrapper, real: build.librarySHA256,
                                                      initFile: initSum)) == .pending)
    }

    @Test func aMountedWrapperRunsThisBoot() {
        let wrapper = GuestGLESWrapper.wrapper?.sha256 ?? ""
        #expect(GuestGLESWrapper.state(output: output(mount: mountLine, loaded: wrapper, wrapper: wrapper, real: build.librarySHA256))
            == .running(current: true, build: build))
        let old = String(repeating: "1", count: 64)
        #expect(GuestGLESWrapper.state(output: output(mount: mountLine, loaded: old, wrapper: old, real: build.librarySHA256))
            == .running(current: false, build: build))
    }

    @Test func anotherBuildKeepsTheLayerInDataLocal() {
        #expect(GuestGLESWrapper.state(output: output(loaded: String(repeating: "0", count: 64))) == .unknown)
        #expect(GuestGLESWrapper.state(output: "") == .unknown)
    }

    @Test func theInitFileMountsOnlyOnAStartTheEngineAllows() {
        let lines = GuestGLESWrapper.initScript(build).split(separator: "\n").map(String.init)
        #expect(lines.contains("on post-fs-data && property:ro.boot.avo.glwrap=1 && property:ro.vendor.build.fingerprint=\(build.fingerprint)"))
        #expect(lines.contains("    mount none \(GuestGLESWrapper.installedPath) \(GuestGLESWrapper.libraryPath) bind"))
        #expect(!GuestGLESWrapper.initScript(build).contains("'"), "it is written inside single quotes")
    }

    @Test func theInstallCopiesTheRealLibraryAndWritesTheInitFileLast() throws {
        let wrapper = try #require(GuestGLESWrapper.wrapper)
        let lines = GuestGLESWrapper.installScript(build).split(separator: "\n").map(String.init)
        #expect(lines.first == "set -e")
        #expect(lines.contains("grep -q '^overlay /system overlay' /proc/mounts"))
        #expect(lines.contains { $0.contains("ro.vendor.build.fingerprint") && $0.contains(build.fingerprint) })
        #expect(lines.contains { $0.contains(GuestGLESWrapper.libraryPath) && $0.contains(build.librarySHA256) })
        #expect(lines.contains { $0.contains(GuestGLESWrapper.staged) && $0.contains(wrapper.sha256) })
        #expect(!GuestGLESWrapper.installScript(build).contains("base64"))
        // The real library is renamed into place from a name no one loads.
        let copy = try #require(lines.firstIndex(of: "cp \(GuestGLESWrapper.libraryPath) \(GuestGLESWrapper.realPath).new"))
        let rename = try #require(lines.firstIndex(of: "mv -f \(GuestGLESWrapper.realPath).new \(GuestGLESWrapper.realPath)"))
        #expect(copy < rename)
        #expect(lines.contains("chcon \(GuestGLESWrapper.label) \(GuestGLESWrapper.installedPath)"))
        let remount = try #require(lines.firstIndex(of: "remount >/dev/null 2>&1"))
        let oldInit = try #require(lines.firstIndex(of: "rm -f \(GuestGLESWrapper.initFile)"))
        let newInit = try #require(lines.firstIndex(of: "mv -f \(GuestGLESWrapper.initFile).new \(GuestGLESWrapper.initFile)"))
        #expect(remount < oldInit && oldInit < copy && rename < newInit)
        #expect(lines.last == "sync")
    }

    @Test func anUpdateRenamesThisBuildsWrapperIntoPlace() throws {
        let wrapper = try #require(GuestGLESWrapper.wrapper)
        let dir = GuestGLESWrapper.installedDir
        let lines = GuestGLESWrapper.updateScript(build).split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.contains(GuestGLESWrapper.realPath) && $0.contains(build.librarySHA256) })
        #expect(lines.contains { $0.contains(GuestGLESWrapper.staged) && $0.contains(wrapper.sha256) })
        #expect(lines.contains("mv -f \(dir)/.libGLESv2_angle.so.new \(GuestGLESWrapper.installedPath)"))
        #expect(!lines.contains("rm -rf \(dir)"))
    }

    @Test func turningItOffRemovesItsFiles() {
        let lines = GuestGLESWrapper.uninstallScript().split(separator: "\n").map(String.init)
        #expect(lines.contains("rm -f \(GuestGLESWrapper.initFile)"))
        #expect(lines.contains("rm -rf \(GuestGLESWrapper.installedDir)"))
        #expect(lines.contains("rm -f \(GuestGLESWrapper.realPath)"))
    }

    // MARK: The daemon's side

    private func temporaryPaths() -> (root: URL, paths: AvoPaths) {
        let root = FileManager.default.temporaryDirectory.appending(path: "avo-glwrap-\(UUID().uuidString.prefix(8))")
        return (root, AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp")))
    }

    @Test func aGPUStartThatFailedWithTheWrapperTurnsThisBuildOfItOff() throws {
        let (root, paths) = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = try #require(GuestGLESWrapper.wrapper)
        #expect(GuestGLESWrapper.allowed(paths: paths))
        try GuestGLESWrapper.Failure(sha256: wrapper.sha256, failure: .crashed, date: Date()).save(paths: paths)
        #expect(!GuestGLESWrapper.allowed(paths: paths))
        // The Vulkan wrapper keeps its own record.
        #expect(GuestVulkanWrapper.allowed(paths: paths))
        GuestGLESWrapper.noteInstalled(true, paths: paths)
        #expect(GuestGLESWrapper.installed(paths: paths) && !GuestVulkanWrapper.installed(paths: paths))
    }

    /// Only a GPU start that emulates the profile's GPU switches it on: a
    /// software start keeps the GLES layer.
    @Test func theEngineSwitchesItOnForAGPUStartThatEmulatesAGPU() {
        let markers: (AvoIdentity.Renderer) -> AvoIdentity.Markers = {
            AvoIdentity.Markers(version: "0.3.1", hostOS: "macOS 27.0.1", hostChip: "Apple M4 Pro", renderer: $0)
        }
        let emulator = AndroidEmulator(directory: URL(filePath: "/emu"), version: "37.1.11", build: nil)
        let phone = DeviceProfile(id: "p", name: "P", properties: [:],
                                  hardware: DeviceHardware(gpu: .init(glVendor: "Qualcomm", glRenderer: "Adreno (TM) 750")))
        func file(_ plan: GPUPlan, profile: DeviceProfile = phone, emulate: Bool = true, allowed: Bool = true) -> String {
            VMMEngine.identityProperties(profile: profile, plan: plan, emulateHardware: emulate, glesWrapper: allowed, markers: markers)
        }
        #expect(file(.gpu(emulator)).contains("\nro.boot.avo.glwrap=1\n"))
        #expect(!file(.software(.chosen, nil)).contains("glwrap"))
        #expect(!file(.gpu(emulator), emulate: false).contains("glwrap"))
        #expect(!file(.gpu(emulator), profile: .avo).contains("glwrap"))
        #expect(!file(.gpu(emulator), allowed: false).contains("glwrap"))
    }
}
