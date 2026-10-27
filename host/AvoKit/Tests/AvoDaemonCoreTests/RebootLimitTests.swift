import AvoKit
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

@Suite struct RebootLimitTests {
    let start = ContinuousClock.now

    /// Three starts after reboots that came before Android was ready; the
    /// fourth reboot within ten minutes leaves it stopped.
    /// Whether each reboot, at these seconds from `start`, starts Android again.
    func starts(_ limit: inout RebootLimit, at seconds: [Int]) -> [Bool] {
        seconds.map { limit.reboot(at: start + .seconds($0)) }
    }

    @Test func threeStartsThenAndroidStaysStopped() {
        var limit = RebootLimit()
        #expect(starts(&limit, at: [0, 40, 80, 120]) == [true, true, true, false])
    }

    /// Reboots ten minutes apart are no loop, and one after Android got
    /// ready counts anew (Android's own Restart, now and then).
    @Test func readyOrLongAgoCountsAnew() {
        var limit = RebootLimit()
        #expect(starts(&limit, at: [0, 60, 120, 11 * 60]) == [true, true, true, true], "the first ones are more than ten minutes old")

        var ready = RebootLimit()
        #expect(starts(&ready, at: [0, 60, 120]) == [true, true, true])
        ready.ready()
        #expect(starts(&ready, at: [240]) == [true])
        #expect(ready.reboots.count == 1)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct RebootLoopTests {
    /// Android reboots before it is ready, again and again: Avo starts it
    /// three times, then leaves it stopped and says so, as a failed start.
    @Test func androidThatKeepsRestartingIsLeftStopped() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        try AndroidStartStopTests.bootedBefore(harness)
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        // From now on Android never gets ready.
        harness.engine.refuseControlConnections = Int.max
        for attempt in 1...RebootLimit.starts {
            let launches = harness.engine.launches.count
            harness.engine.exit(AndroidRebooted())
            #expect(await eventually { harness.engine.launches.count == launches + 1 }, "start \(attempt)")
            #expect(await eventually { await harness.core.status().state == .starting })
        }
        let launches = harness.engine.launches.count
        harness.engine.exit(AndroidRebooted())
        #expect(await eventually { await harness.core.status().state == .failed })
        #expect(await harness.core.status().detail == DaemonCore.keepsRestartingMessage)
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.engine.launches.count == launches, "not started again")
        #expect(!harness.engine.isRunning)

        // Started by hand, it gets its three tries again.
        harness.engine.refuseControlConnections = 0
        try await harness.core.startVM(client: panel)
        #expect(await harness.core.status().state == .running)
    }
}
