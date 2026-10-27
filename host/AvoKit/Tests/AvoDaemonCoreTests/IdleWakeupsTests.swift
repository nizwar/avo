import AvoADB
import AvoIO
import AvoKit
import AvoTestSupport
import Foundation
import Synchronization
import Testing
@testable import AvoDaemonCore

/// What wakes the Mac while Android is paused or stopped: nothing that
/// would only wait on it.
@Suite(.serialized, .timeLimit(.minutes(1))) struct IdleWakeupsTests {
    /// The Mac's clipboard is looked at only while Android runs: a pause
    /// stops the looks, going on starts them again.
    @Test func theClipboardIsWatchedOnlyWhileAndroidRuns() async throws {
        var pausing: PausingEngine?
        let clipboard = RecordingClipboard()
        let harness = try Harness(apps: [], wrap: { base in
            let engine = PausingEngine(base)
            pausing = engine
            return engine
        }, clipboard: clipboard)
        defer { harness.cleanUp() }
        _ = try #require(pausing)
        await harness.core.start()
        #expect(clipboard.calls == [])
        try await harness.core.startVMFromMenuBar()
        #expect(await eventually { clipboard.calls == ["start"] })
        // The start's own work done (it uses Android, which would wake it).
        await AutoPauseDaemonTests().settle(harness.core)
        try await harness.core.pauseFromMenuBar()
        #expect(await eventually { clipboard.calls == ["start", "stop"] })
        try await harness.core.resumeFromMenuBar()
        #expect(await eventually { clipboard.calls == ["start", "stop", "start"] })
        try await harness.core.stopVMFromMenuBar()
        #expect(await eventually { clipboard.calls == ["start", "stop", "start", "stop"] })
    }

    /// The host agent's watches wait out a pause instead of waking every
    /// few seconds to find Android still paused.
    @Test func theHostAgentsWatchesWaitOutAPause() async throws {
        let commands = Mutex<[(String, ContinuousClock.Instant)]>([])
        let key = try ADBKey.generate()
        let agent = HostAgent(engine: EngineControl(socketPath: "/nonexistent/avo-control.sock"), frames: FrameBridge { _ in },
                              adbKey: key) { _ in
            let (host, guest) = try UnixSocket.pair()
            let adbd = FakeADBD(fileDescriptor: guest, publicKey: key.publicKey!, maxPayload: 256 * 1024)
            Task {
                await adbd.setShellHandler { command in
                    commands.withLock { $0.append((command, .now)) }
                    if command.hasPrefix("getprop sys.boot_completed") { return ("1\n", "", 0) }
                    // On Wi-Fi already: the start's own steps are over at once.
                    if command.hasPrefix("cmd wifi status") { return ("Wifi is connected to \"VirtWifi\"\n", "", 0) }
                    return ("", "", 0)
                }
                await adbd.run()
            }
            return FileDescriptorStream(fileDescriptor: host, label: "fake-host-adb")
        }
        try await agent.prepare(deadline: .now + .seconds(30))
        func asked(since start: ContinuousClock.Instant) -> [String] {
            commands.withLock { $0.filter { $0.1 >= start }.map(\.0) }
        }
        // Running: the look every 2 s, the package poll every 3 s.
        let running = ContinuousClock.now
        #expect(await eventually(timeout: .seconds(10)) { asked(since: running).count >= 2 })

        await agent.setPaused(true)
        try await Task.sleep(for: .milliseconds(500))
        let paused = ContinuousClock.now
        try await Task.sleep(for: .seconds(4))
        #expect(asked(since: paused) == [], "nothing asked of a paused Android")

        await agent.setPaused(false)
        let resumed = ContinuousClock.now
        #expect(await eventually(timeout: .seconds(10)) { !asked(since: resumed).isEmpty })
        await agent.shutdown()
    }
}
