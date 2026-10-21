import Foundation
import Testing
@testable import AvoDaemonCore

@Suite struct GuestAudioHalTests {
    let build = GuestAudioHal.builds[0]

    @Test func theLatencyIsOneInstruction() throws {
        // `mov w0, #0x55` and `mov w0, #0xa` as llvm-objdump shows them in
        // ModulePrimary::getNominalLatencyMs (85 ms, and 10 ms for MMAP).
        #expect(GuestAudioHal.movW0(85) == 0x5280_0AA0)
        #expect(GuestAudioHal.movW0(10) == 0x5280_0140)
        let latency = try #require(build.words.first { $0.offset == 0x9bc24 })
        #expect(latency.original == GuestAudioHal.movW0(85))
        #expect(latency.replacement == GuestAudioHal.movW0(20))
        #expect(GuestAudioHal.escapes(latency.replacement) == #"\200\002\200\122"#)
    }

    @Test func theInputPipeStubIsWhatLlvmObjdumpShows() {
        // The words as llvm-objdump shows them in the stock and patched HAL.
        #expect(build.words.map(\.original) == [0x5280_0AA0, 0x9401_1751, 0xd503_201f, 0xd503_201f])
        #expect(build.words.map(\.replacement) == [0x5280_0280, 0x9400_033f, 0x9ac3_2021, 0x1401_1411])
        // `bl 0x11a4d0`, `bl 0xd5488`, `lsl x1, x1, x3`, `b 0x11a4d0`.
        #expect(GuestAudioHal.branch(from: 0xd478c, to: 0x11a4d0, link: true) == 0x9401_1751)
        #expect(GuestAudioHal.branch(from: 0xd478c, to: 0xd5488, link: true) == 0x9400_033f)
        #expect(GuestAudioHal.lslX(1, 1, by: 3) == 0x9ac3_2021)
        #expect(GuestAudioHal.branch(from: 0xd548c, to: 0x11a4d0, link: false) == 0x1401_1411)
        // A branch back encodes its negative offset in 26 bits.
        #expect(GuestAudioHal.branch(from: 0xd5488, to: 0xd478c, link: false) == 0x17ff_fcc1)
    }

    @Test func onlyTheKnownBuildIsPatched() {
        let path = GuestAudioHal.binary
        #expect(GuestAudioHal.installed(sumOutput: "\(build.sha256)  \(path)\n") == .stock(build))
        #expect(GuestAudioHal.installed(sumOutput: "\(build.patchedSHA256)  \(path)\n") == .patched)
        // A copy patched by an earlier Avo stays until Android starts again.
        #expect(GuestAudioHal.installed(sumOutput: "0cf1e05d7b1466c89c56486178baf432518a210b768c67745109030aeec51982  \(path)\n") == .patched)
        #expect(GuestAudioHal.installed(sumOutput: "\(String(repeating: "0", count: 64))  \(path)\n") == .unknown)
        #expect(GuestAudioHal.installed(sumOutput: "") == .unknown)
        #expect(GuestAudioHal.installed(sumOutput: "sha256sum: \(path): No such file or directory") == .unknown)
    }

    @Test func theScriptChecksTheCopyBeforeAnythingChanges() throws {
        let lines = GuestAudioHal.installScript(build).split(separator: "\n").map(String.init)
        #expect(lines.first == "set -e")
        let patches = lines.indices.filter { lines[$0].contains("dd of=\(GuestAudioHal.staged) bs=1 seek=") }
        #expect(patches.count == build.words.count)
        let latency = try #require(lines.firstIndex { $0.contains("dd of=\(GuestAudioHal.staged) bs=1 seek=\(0x9bc24) conv=notrunc") })
        #expect(lines[latency].hasPrefix(#"printf '\200\002\200\122'"#))
        for word in build.words {
            #expect(lines.contains("printf '\(GuestAudioHal.escapes(word.replacement))' | dd of=\(GuestAudioHal.staged) bs=1 seek=\(word.offset) conv=notrunc 2>/dev/null"))
        }
        let check = try #require(lines.firstIndex { $0.contains(build.patchedSHA256) })
        let mount = try #require(lines.firstIndex { $0 == "mount -o bind \(GuestAudioHal.staged) \(GuestAudioHal.binary)" })
        let property = try #require(lines.firstIndex { $0.hasPrefix("setprop \(GuestAudioHal.periodProperty) 2") })
        #expect(patches.allSatisfy { $0 < check } && check < mount && mount < property, "nothing is mounted unchecked, no property without the mount")
        #expect(lines.contains("chcon u:object_r:hal_audio_default_exec:s0 \(GuestAudioHal.staged)"))
        // Without the property the patched HAL comes off again.
        #expect(lines.last == "[ \"$(getprop \(GuestAudioHal.periodProperty))\" = 2 ] || { umount \(GuestAudioHal.binary); exit 1; }")
        // Not where GuestAudioPolicy stages its files (cleared every boot).
        #expect(!GuestAudioHal.staging.hasPrefix(GuestAudioPolicy.staging + "/") && GuestAudioHal.staging != GuestAudioPolicy.staging)
    }

    @Test func thePatchedCopyMatchesItsHash() throws {
        // The patch applied to a stand-in for the binary changes exactly the
        // four bytes the script writes for each word.
        let end = try #require(build.words.map(\.offset).max()) + 8
        var data = Data(repeating: 0, count: end)
        for word in build.words {
            withUnsafeBytes(of: word.original.littleEndian) { data.replaceSubrange(word.offset..<word.offset + 4, with: $0) }
            let escapes = GuestAudioHal.escapes(word.replacement).split(separator: "\\").map { UInt8($0, radix: 8)! }
            data.replaceSubrange(word.offset..<word.offset + 4, with: escapes)
        }
        for word in build.words {
            let patched = data[word.offset..<word.offset + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            #expect(patched == word.replacement)
        }
    }
}
