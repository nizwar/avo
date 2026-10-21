import Foundation
import Testing
@testable import AvoDaemonCore

@Suite struct GuestComposerTests {
    let build = GuestComposer.builds[0]

    /// `bl` from `pc` to `target` (A64), little endian.
    private func bl(_ pc: Int, _ target: Int) -> [UInt8] {
        let word = UInt32(0x9400_0000) | UInt32(truncatingIfNeeded: (target - pc) >> 2) & 0x03FF_FFFF
        return (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
    }

    @Test func theCallsGoToTheCodeInThePadding() throws {
        let update = try #require(build.patches.first { $0.offset == 0xbe058 })
        let create = try #require(build.patches.first { $0.offset == 0xad980 })
        let code = try #require(build.patches.first { $0.offset == 0xf5000 })
        #expect(update.bytes == bl(0xbe058, 0xf5000))
        #expect(create.bytes == bl(0xad980, 0xf5090))
        // Both pieces end inside the segment as extended (to 0xf7000).
        #expect(code.bytes.count > 0x90 && 0xf5000 + code.bytes.count <= 0xf7000)
        // The second piece starts with `stp x29, x30, [sp, #-48]!`, as the first does.
        #expect(Array(code.bytes[0x90..<0x94]) == Array(code.bytes[0..<4]))
        #expect(Array(code.bytes[0..<4]) == [0xfd, 0x7b, 0xbd, 0xa9])
        // The R+X segment's sizes: 0x6f000, little endian.
        for offset in [0x108, 0x110] {
            #expect(build.patches.first { $0.offset == offset }?.bytes == [0x00, 0xf0, 0x06, 0, 0, 0, 0, 0])
        }
    }

    @Test func onlyTheKnownBuildIsPatched() {
        let path = GuestComposer.binary
        #expect(GuestComposer.state(sumOutput: "\(build.sha256)  \(path)\n") == .stock(build))
        #expect(GuestComposer.state(sumOutput: "\(build.patchedSHA256)  \(path)\n") == .patched)
        #expect(GuestComposer.state(sumOutput: "\(String(repeating: "0", count: 64))  \(path)\n") == .unknown)
        #expect(GuestComposer.state(sumOutput: "") == .unknown)
    }

    @Test func theScriptChecksEverythingBeforeTheImageChanges() throws {
        let lines = GuestComposer.installScript(build).split(separator: "\n").map(String.init)
        #expect(lines.first == "set -e")
        let overlay = try #require(lines.firstIndex { $0.contains("'^overlay /vendor overlay' /proc/mounts") })
        let fingerprint = try #require(lines.firstIndex { $0.contains(build.fingerprint) })
        let remount = try #require(lines.firstIndex { $0.hasPrefix("remount") })
        let patches = lines.indices.filter { lines[$0].contains("dd of=\(GuestComposer.staged) bs=1 seek=") }
        let check = try #require(lines.firstIndex { $0.contains(build.patchedSHA256) })
        let copy = try #require(lines.firstIndex { $0 == "cp \(GuestComposer.staged) \(GuestComposer.installed)" })
        let initFile = try #require(lines.firstIndex { $0.hasSuffix("> \(GuestComposer.initFile)") })
        #expect(overlay < remount && fingerprint < remount, "nothing is written without the overlays, or on another build")
        #expect(patches.count == build.patches.count)
        #expect(patches.allSatisfy { remount < $0 && $0 < check })
        #expect(check < copy && copy < initFile, "the init file never names an unchecked copy")
        #expect(lines.contains("chcon \(GuestComposer.label) \(GuestComposer.installed)"))
    }

    @Test func initMountsTheCopyOnTheBuildItCameFrom() {
        let script = GuestComposer.initScript(build)
        #expect(script.contains("on post-fs-data && property:ro.vendor.build.fingerprint=\(build.fingerprint)\n"))
        #expect(script.contains("    mount none \(GuestComposer.installed) \(GuestComposer.binary) bind\n"))
        // It goes through `printf '%s' '…'`.
        #expect(!script.contains("'"))
    }

    @Test func escapesKeepZeroBytes() {
        #expect(GuestComposer.escapes([0xfd, 0x00, 0x01, 0xff]) == #"\375\000\001\377"#)
    }

    @Test func theModeSizeIsReadFromTheSupportedModes() {
        // Real output (abridged): `real` is the turned size, the mode is not.
        let output = """
            Displays:
            Display id 0: DisplayInfo{"Built-in Screen", displayId 0, real 720 x 1280, supportedModes [{id=1, parentModeId=-1, sfModeId=0, flags=, width=720, height=1280, fps=120.00001}], uniqueId "local:4619827259835644672"}
            Display id 38: DisplayInfo{"Built-in Screen", displayId 38, real 892 x 432, defaultMode 38, supportedModes [{id=38, parentModeId=-1, sfModeId=0, flags=, width=432, height=892, fps=120.00001}], uniqueId "local:4619827551948147201"}
            """
        let size = HostAgent.modeSize(androidID: 38, in: output)
        #expect(size?.width == 432 && size?.height == 892)
        #expect(HostAgent.modeSize(androidID: 3, in: output) == nil)
    }
}
