import AvoIO
import AvoKit
import AvoProtocol
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// What a start or a stop leaves behind when it does not go as planned:
/// an engine is never left running for an Android that failed or stopped.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AndroidStartStopTests {
    /// Android has written its data before: its starts get the usual time,
    /// not a first boot's 15 minutes.
    static func bootedBefore(_ harness: Harness) throws {
        try harness.paths.createDirectories()
        try Data([1]).write(to: harness.paths.dataDisk)
    }

    /// Android never got ready (the boot timed out): the start fails and
    /// its engine stops, instead of keeping its memory, CPU and disks.
    @Test func aStartThatTimesOutLeavesNoEngineRunning() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        try Self.bootedBefore(harness)
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        harness.engine.refuseControlConnections = Int.max
        await #expect(throws: (any Error).self) { try await harness.core.startVM(client: panel) }
        let status = await harness.core.status()
        #expect(status.state == .failed)
        #expect(status.detail?.contains("timed out") == true, "the start's own failure, not the engine's exit")
        #expect(!harness.engine.isRunning)
    }

    /// Stop while Android starts, before the engine is up (avo-vmm's own
    /// start, which a stop does not cut short): it ends stopped, with no
    /// engine left, and the start does not take the status back.
    @Test func stopWhileTheEngineStartsEndsWithAndroidStopped() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        harness.engine.startDelay = .milliseconds(500)
        let start = Task { try await harness.core.startVM(client: panel) }
        #expect(await eventually { await harness.core.status().state == .starting })
        try await harness.core.stopVM(client: panel)
        #expect(await harness.core.status().state == .stopped)
        #expect(!harness.engine.isRunning)
        await #expect(throws: (any Error).self) { try await start.value }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await harness.core.status().state == .stopped)
        #expect(!harness.engine.isRunning)
    }

    /// Stop while Android boots (the engine up, Android not answering yet).
    @Test func stopWhileAndroidBootsEndsWithAndroidStopped() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        try Self.bootedBefore(harness)
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        harness.engine.refuseControlConnections = Int.max
        let start = Task { try await harness.core.startVM(client: panel) }
        #expect(await eventually { await harness.core.status().detail == "Waiting for Android to boot" })
        try await harness.core.stopVM(client: panel)
        await #expect(throws: (any Error).self) { try await start.value }
        #expect(await harness.core.status().state == .stopped)
        #expect(!harness.engine.isRunning)
        // Android starts again as usual.
        harness.engine.refuseControlConnections = 0
        try await harness.core.startVM(client: panel)
        #expect(await harness.core.status().state == .running)
    }

    /// Stop while Android waits to be started again after its own reboot
    /// ("Android is restarting"): the stop wins, the start again does not
    /// happen, and the status says stopped. (The core's pumps are not
    /// started: nothing but this test takes the reboot up.)
    @Test func aStopWinsOverAndroidsOwnRestart() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        try Self.bootedBefore(harness)
        let vm = harness.core.vm
        let settings = VMManager.Settings(config: VMConfig(), profile: nil)
        try await vm.ensureRunning(settings)
        harness.engine.exit(AndroidRebooted())
        #expect(await eventually { await vm.status.detail == "Android is restarting" })
        await vm.stop(callingOffRestart: true)
        #expect(await vm.status.state == .stopped)
        #expect(await vm.status.detail == nil)
        let launches = harness.engine.launches.count
        await #expect(throws: CancellationError.self) { try await vm.ensureRunning(settings, restarting: true) }
        #expect(harness.engine.launches.count == launches)
        #expect(await vm.status.state == .stopped)
        // A start of the user's own goes ahead, and so does the next reboot's start again.
        try await vm.ensureRunning(settings)
        #expect(await vm.status.state == .running)
        harness.engine.exit(AndroidRebooted())
        #expect(await eventually { await vm.status.detail == "Android is restarting" })
        try await vm.ensureRunning(settings, restarting: true)
        #expect(await vm.status.state == .running)
    }

    /// Stop pressed as Android reboots itself: whichever comes first, Android
    /// ends stopped and is not started again behind the stop.
    @Test func aStopAsAndroidRebootsLeavesItStopped() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        try Self.bootedBefore(harness)
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        harness.engine.exit(AndroidRebooted())
        try await harness.core.stopVM(client: panel)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await harness.core.status().state == .stopped)
        #expect(!harness.engine.isRunning)
    }

    /// The Control channel closed while Android ran: Android failed, and its
    /// engine powers it off instead of running on unseen.
    @Test func aLostControlChannelStopsTheEngine() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        let stops = harness.engine.stops
        await harness.agent.dropConnection()
        #expect(await eventually { await harness.core.status().state == .failed })
        #expect(await harness.core.status().detail == "Android stopped responding")
        #expect(await eventually { harness.engine.stops > stops })
        #expect(!harness.engine.isRunning)
    }

    /// The engine crashed while Android booted: the start fails at once with
    /// the crash, not at the boot's time limit, and nothing of it runs on.
    @Test func aCrashWhileAndroidBootsFailsTheStartAtOnce() async throws {
        let harness = try Harness(apps: [], bootTimeout: .seconds(40))
        defer { harness.cleanUp() }
        try Self.bootedBefore(harness)
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        harness.engine.refuseControlConnections = Int.max
        let start = Task { try await harness.core.startVM(client: panel) }
        #expect(await eventually { await harness.core.status().detail == "Waiting for Android to boot" })
        let stops = harness.engine.stops
        let crashed = ContinuousClock.now
        harness.engine.crash()
        await #expect(throws: AvoError.vmStartFailed("engine crashed")) { try await start.value }
        #expect(ContinuousClock.now - crashed < .seconds(10))
        let status = await harness.core.status()
        #expect(status.state == .failed)
        #expect(status.detail?.contains("engine crashed") == true)
        #expect(harness.engine.stops > stops, "its host agent and watches go too")
        // Android starts again as usual.
        harness.engine.refuseControlConnections = 0
        try await harness.core.startVM(client: panel)
        #expect(await harness.core.status().state == .running)
    }

    /// The engine a restart stopped takes its time to end: its exit, coming
    /// once the next start is under way, changes nothing of that start.
    @Test func aLateExitOfAnEarlierEngineLeavesTheNextStartAlone() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        try Self.bootedBefore(harness)
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        let first = try #require(harness.engine.launches.last)
        harness.engine.refuseControlConnections = Int.max
        let restart = Task { try await harness.core.restartVM(client: panel) }
        #expect(await eventually { await harness.core.status().detail == "Waiting for Android to boot" })
        harness.engine.exit(AvoError.vmStartFailed("engine crashed"), of: first)
        harness.engine.exit(AndroidRebooted(), of: first)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await harness.core.status().detail == "Waiting for Android to boot")
        harness.engine.refuseControlConnections = 0
        try await restart.value
        #expect(await harness.core.status().state == .running)
        #expect(harness.engine.launches.count == 2, "not started again for the earlier engine's reboot")
    }

    /// An engine that ended by itself while Android ran is tidied up at
    /// once (its host agent and watches), not at the next start.
    @Test func anEngineThatEndedByItselfIsTidiedUp() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        let stops = harness.engine.stops
        harness.engine.crash()
        #expect(await eventually { await harness.core.status().state == .failed })
        #expect(await eventually { harness.engine.stops == stops + 1 })
        // Its own exit as it is tidied up changes nothing.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await harness.core.status().state == .failed)
        #expect(await harness.core.status().detail?.contains("engine crashed") == true)
    }
}
