import AvoADB
import AvoIO
import AvoKit
import Foundation
import Testing
@testable import AvoDaemonCore

@Suite struct MagiskShellTests {
    /// The shell's row in Magisk's policies: allowed (2), for good (0), quietly.
    @Test func thePolicyLetsTheShellInForGood() {
        let command = MagiskRoot.allowShellCommand
        #expect(command.contains("REPLACE INTO policies (uid,policy,until,logging,notification) VALUES(2000,2,0,0,0)"))
        #expect(command.hasPrefix("M=/debug_ramdisk/magisk;"))
        // Passed to `su 0 sh -c '…'`: no single quote of its own.
        #expect(!command.contains("'"))
    }
}

/// Against a running avo-vmm booted with a Magisk-patched init_boot, from its
/// directory (AVO_LIVE_TEST_VM, as PauseLiveTests; AVO_LIVE_MAGISK=1). With
/// Magisk fully set up and no policy for the shell, Magisk's su waits for an
/// approval on Android's own screen and every root step hangs; before the
/// setup AOSP's su answers. Either way the provisioning gets through, and the
/// shell's policy is in Magisk's database for its next start.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AVO_LIVE_TEST_VM"] != nil
                && ProcessInfo.processInfo.environment["AVO_LIVE_MAGISK"] != nil), .serialized)
struct MagiskShellLiveTests {
    @Test(.timeLimit(.minutes(5))) func rootStepsGetThroughMagisk() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["AVO_LIVE_TEST_VM"])
        #expect(FileManager.default.changeCurrentDirectoryPath(directory))
        let control = EngineControl(socketPath: "runtime/control.sock")
        let key = try ADBKey.generate()
        let agent = HostAgent(engine: control, frames: FrameBridge { _ in }, adbKey: key) { port in
            try VsockBridge.connect(socketPath: "runtime/vsock.sock", port: port)
        }
        await agent.useMagisk(true)
        let started = ContinuousClock.now
        try await agent.prepare(deadline: .now + .seconds(240))
        print("prepared in \(ContinuousClock.now - started)")
        // Our own adb, to read Magisk's database.
        let adb = ADBConnection(transport: try VsockBridge.connect(socketPath: "runtime/vsock.sock", port: HostAgent.adbPort),
                                key: key, keyComment: "avo-live-test")
        _ = try await adb.connect(timeout: .seconds(20))
        let asRoot = try await adb.shell("id -u").output.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
        let query = #"M=/debug_ramdisk/magisk; "$M" --sqlite "SELECT policy FROM policies WHERE uid=2000""#
        let policy = try await adb.shell(asRoot ? query : "su 0 sh -c '\(query)'").output
        print("adbd as root: \(asRoot); policy: \(policy)")
        #expect(policy.contains("policy=2"))
        await adb.close()
    }
}
