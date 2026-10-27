import AvoIO
import AvoKit
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// The fake engine, slow to power Android off (an Android that takes its time, or hangs).
final class SlowStoppingEngine: VMEngine, @unchecked Sendable {
    let base: FakeEngine
    let stopTakes: Duration

    init(_ base: FakeEngine, stopTakes: Duration) {
        self.base = base
        self.stopTakes = stopTakes
    }

    var name: String { base.name }
    var exits: AsyncStream<(any Error)?> { base.exits }
    func start(_ launch: EngineLaunch) async throws { try await base.start(launch) }
    func snapshot(to url: URL) async throws { try await base.snapshot(to: url) }
    func connect(port: UInt32) async throws -> any ByteStream { try await base.connect(port: port) }

    func stop() async {
        let delay = stopTakes
        await Task.detached { try? await Task.sleep(for: delay) }.value
        await base.stop()
    }
}

/// The daemon's own end (a logout, a shutdown, its agent stopped).
@Suite(.serialized, .timeLimit(.minutes(1))) struct DaemonExitTests {
    /// Android powers off first, and nothing starts it after.
    @Test func androidPowersOffBeforeTheDaemonEnds() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        await harness.core.powerOffForExit(within: .seconds(10))
        #expect(await harness.core.status().state == .stopped)
        #expect(!harness.engine.isRunning)
        await #expect(throws: (any Error).self) { try await harness.core.startVM(client: panel) }
        #expect(harness.engine.launches.count == 1)
    }

    /// An Android that does not power off in time holds the daemon only
    /// until the limit: launchd would end it by force soon after.
    @Test func aSlowPowerOffHoldsTheDaemonOnlyUntilTheLimit() async throws {
        let harness = try Harness(apps: [], wrap: { SlowStoppingEngine($0, stopTakes: .seconds(20)) })
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        let started = ContinuousClock.now
        await harness.core.powerOffForExit(within: .milliseconds(500))
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
