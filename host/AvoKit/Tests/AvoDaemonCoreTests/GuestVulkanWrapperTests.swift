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

    @Test func theRealDriverPathMatchesTheWrappersOwn() {
        // vk_wrap.c opens REAL_PATH; the install puts the real driver there.
        #expect(GuestVulkanWrapper.hwDir == "/apex/com.google.cf.vulkan/lib64/hw")
        #expect(GuestVulkanWrapper.realName == "vulkan.ranchu.avoreal.so")
    }

    @Test func aStockBuildIsFoundByItsDriverHash() {
        #expect(GuestVulkanWrapper.build(driverSumOutput: "\(build.driverSHA256)  \(GuestVulkanWrapper.hwDir)/vulkan.ranchu.so")
            == build)
        #expect(GuestVulkanWrapper.build(driverSumOutput: "\(String(repeating: "0", count: 64))  x") == nil)
        #expect(GuestVulkanWrapper.build(driverSumOutput: "") == nil)
    }

    @Test func theInitFileMountsTheDirectoryOverTheApexOnThisBuild() {
        let lines = GuestVulkanWrapper.initScript(build).split(separator: "\n").map(String.init)
        #expect(lines.contains("on post-fs-data && property:ro.vendor.build.fingerprint=\(build.fingerprint)"))
        #expect(lines.contains("    mount none \(GuestVulkanWrapper.installedDir) \(GuestVulkanWrapper.hwDir) bind"))
    }

    @Test func theInstallStagesBothDriversAndTheWrapperThenWritesTheInitFile() throws {
        let wrapper = try #require(GuestVulkanWrapper.wrapper)
        let script = GuestVulkanWrapper.installScript(build, wrapperBase64: "QUJD")
        let lines = script.split(separator: "\n").map(String.init)
        #expect(lines.first == "set -e")
        // Only the known build, with the overlays of a remount.
        #expect(lines.contains("grep -q '^overlay /vendor overlay' /proc/mounts"))
        #expect(lines.contains("grep -q '^overlay /system overlay' /proc/mounts"))
        #expect(lines.contains { $0.contains("ro.vendor.build.fingerprint") && $0.contains(build.fingerprint) })
        #expect(lines.contains { $0.contains(build.driverSHA256) })
        #expect(lines.contains("remount >/dev/null 2>&1"))
        // The real driver and the software driver are copied from the APEX,
        // the wrapper is written from its bytes and checked by hash.
        let dir = GuestVulkanWrapper.installedDir
        #expect(lines.contains("cp \(GuestVulkanWrapper.hwDir)/vulkan.ranchu.so \(GuestVulkanWrapper.staging)/\(GuestVulkanWrapper.realName)"))
        #expect(lines.contains("cp \(GuestVulkanWrapper.hwDir)/\(GuestVulkanWrapper.softwareName) \(GuestVulkanWrapper.staging)/\(GuestVulkanWrapper.softwareName)"))
        #expect(lines.contains("printf %s 'QUJD' | base64 -d > \(GuestVulkanWrapper.staging)/vulkan.ranchu.so"))
        #expect(lines.contains { $0.contains(wrapper.sha256) })
        #expect(lines.contains { $0.hasPrefix("chcon \(GuestVulkanWrapper.label) \(dir)") })
        // The init file is written from the init script (it spans newlines).
        #expect(script.contains("printf '%s' '\(GuestVulkanWrapper.initScript(build))' > \(GuestVulkanWrapper.initFile)"))
        #expect(lines.last == "sync")
    }

    @Test func theMountIsSeenInTheInitNamespace() {
        #expect(GuestVulkanWrapper.mounted(
            mountOutput: "879 86 7:0 / /apex/com.google.cf.vulkan/lib64/hw rw,relatime shared:1 - ext4 ..."))
        #expect(!GuestVulkanWrapper.mounted(mountOutput: ""))
    }

    @Test func turningItOffRemovesTheInitFileAndDirectory() {
        let lines = GuestVulkanWrapper.uninstallScript().split(separator: "\n").map(String.init)
        #expect(lines.contains("rm -f \(GuestVulkanWrapper.initFile)"))
        #expect(lines.contains("rm -rf \(GuestVulkanWrapper.installedDir)"))
    }
}
