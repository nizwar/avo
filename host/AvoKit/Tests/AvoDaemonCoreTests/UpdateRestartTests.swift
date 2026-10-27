import AvoKit
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// When the daemon may end to restart on an updated Avo (AppUpdateWatcher
/// asks `claimRestartForUpdate`): only while Android holds nothing and
/// nothing is about to start it, and nothing starts it after that.
@Suite(.serialized, .timeLimit(.minutes(1))) struct UpdateRestartTests {
    @Test func onlyOnceAndroidStoppedAndThenNothingStartsIt() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        #expect(await !harness.core.claimRestartForUpdate(), "Android runs")

        try await harness.core.stopVM(client: panel)
        #expect(await harness.core.claimRestartForUpdate())
        // The new daemon starts Android: this one no longer does, from anywhere.
        await #expect(throws: AvoError.internalError(DaemonCore.restartingForUpdateMessage)) {
            try await harness.core.startVM(client: panel)
        }
        await #expect(throws: (any Error).self) { try await harness.core.startVMFromMenuBar() }
        #expect(await harness.core.status().state == .stopped)
        #expect(harness.engine.launches.count == 1)
    }

    /// Android's own reboot passes through "stopped" before it starts again:
    /// never a moment to restart on.
    @Test func neverWhileAndroidRestartsItself() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        let launches = harness.engine.launches.count
        harness.engine.exit(AndroidRebooted())
        let deadline = ContinuousClock.now + .seconds(10)
        var claimed = false
        while ContinuousClock.now < deadline {
            if await harness.core.claimRestartForUpdate() {
                claimed = true
                break
            }
            if harness.engine.launches.count > launches, await harness.core.status().state == .running { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!claimed)
        #expect(await harness.core.status().state == .running)
    }

    /// Restart from the Control Panel likewise, its engine slow to start.
    @Test func neverDuringARestart() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        harness.engine.startDelay = .milliseconds(300)
        let restart = Task { try await harness.core.restartVM(client: panel) }
        var claimed = false
        while !claimed, await harness.core.status().state != .running || harness.engine.launches.count < 2 {
            claimed = await harness.core.claimRestartForUpdate()
            try await Task.sleep(for: .milliseconds(1))
        }
        try await restart.value
        #expect(!claimed)
        #expect(await harness.core.status().state == .running)
    }
}
