import AvoIO
import AvoKit
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// The fake engine, told when the Mac slept as avo-vmm's host agent is.
final class SleepingEngine: SleepingClockEngine, @unchecked Sendable {
    let base: FakeEngine
    private let lock = NSLock()
    private var _slept: [Duration] = []
    var slept: [Duration] { lock.withLock { _slept } }

    init(_ base: FakeEngine) {
        self.base = base
    }

    var name: String { base.name }
    var exits: AsyncStream<(any Error)?> { base.exits }
    func start(_ launch: EngineLaunch) async throws { try await base.start(launch) }
    func stop() async { await base.stop() }
    func snapshot(to url: URL) async throws { try await base.snapshot(to: url) }
    func connect(port: UInt32) async throws -> any ByteStream { try await base.connect(port: port) }
    func macSlept(for duration: Duration) async { lock.withLock { _slept.append(duration) } }
}

@Suite struct MacSleepTests {
    /// The sleep is the time that passed less the time the Mac was awake.
    @Test func theSleepIsTheTimeThatPassedLessTheTimeAwake() {
        let passed = ContinuousClock.now
        let awake = SuspendingClock.now
        var sleep = MacSleep()
        _ = sleep.slept(passed: passed, awake: awake)
        #expect(sleep.slept(passed: passed + .seconds(3605), awake: awake + .seconds(5)) == .seconds(3600))
        // From that look on: awake all the time.
        #expect(sleep.slept(passed: passed + .seconds(3665), awake: awake + .seconds(65)) == .zero)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct MacWakeTests {
    /// Android ran while the Mac slept: its clock is put right. Stopped, or
    /// a sleep shorter than a second, nothing to put right.
    @Test func androidsClockIsPutRightAfterTheMacSlept() async throws {
        var sleeping: SleepingEngine?
        let harness = try Harness(apps: [], wrap: { base in
            let engine = SleepingEngine(base)
            sleeping = engine
            return engine
        })
        defer { harness.cleanUp() }
        let engine = try #require(sleeping)
        await harness.core.start()
        await harness.core.macWoke(slept: .seconds(600))
        #expect(engine.slept == [], "Android was not running")

        try await harness.core.startVMFromMenuBar()
        await harness.core.macWoke(slept: .milliseconds(300))
        await harness.core.macWoke(slept: .seconds(8 * 3600))
        #expect(engine.slept == [.seconds(8 * 3600)])
    }
}
