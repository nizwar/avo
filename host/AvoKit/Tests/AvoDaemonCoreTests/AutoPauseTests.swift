import AvoIO
import AvoKit
import AvoProtocol
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// The fake engine, able to pause (what avo-vmm's `pause` and `resume` do
/// is tested in the engine).
final class PausingEngine: PausableEngine, @unchecked Sendable {
    let base: FakeEngine
    private let lock = NSLock()
    private var _pauses = 0
    private var _resumes: [Duration] = []
    private var _paused = false
    private var wake: (@Sendable () async -> Void)?
    var activityNow = EngineActivity(cpuTime: .zero)

    init(_ base: FakeEngine) {
        self.base = base
    }

    var pauses: Int { lock.withLock { _pauses } }
    var resumes: [Duration] { lock.withLock { _resumes } }
    var isPaused: Bool { lock.withLock { _paused } }

    var name: String { base.name }
    var exits: AsyncStream<EngineExit> { base.exits }
    func start(_ launch: EngineLaunch) async throws { try await base.start(launch) }
    func snapshot(to url: URL) async throws { try await base.snapshot(to: url) }
    func connect(port: UInt32) async throws -> any ByteStream { try await base.connect(port: port) }

    func stop() async {
        lock.withLock { _paused = false }
        await base.stop()
    }

    func pause() async throws {
        lock.withLock {
            _pauses += 1
            _paused = true
        }
    }

    func resume(pausedFor: Duration) async throws {
        lock.withLock {
            _resumes.append(pausedFor)
            _paused = false
        }
    }

    func activity() async -> EngineActivity { lock.withLock { activityNow } }
    func onUse(_ wake: @escaping @Sendable () async -> Void) { lock.withLock { self.wake = wake } }

    /// What VMMEngine does before handing out a fingerprint or Google apps guest.
    func use() async {
        guard let wake = lock.withLock({ _paused ? self.wake : nil }) else { return }
        await wake()
    }

    func setActivity(_ change: (inout EngineActivity) -> Void) {
        lock.withLock { change(&activityNow) }
    }
}

@Suite struct AutoPausePolicyTests {
    let start = ContinuousClock.now

    func look(_ policy: inout AutoPausePolicy, _ sample: AutoPausePolicy.Sample, now: ContinuousClock.Instant) -> Bool {
        policy.shouldPause(sample, now: now)
    }

    func sample(minutes: Int = 15, windows: Int = 0, busy: Set<AutoPauseReason> = [], lastUse: Duration = .zero,
                cpu: Double? = 0.05) -> AutoPausePolicy.Sample {
        AutoPausePolicy.Sample(minutes: minutes, running: true, windows: windows, busy: busy, lastUse: start + lastUse, cpu: cpu)
    }

    @Test func pausesAfterTheChosenTimeIdle() {
        var policy = AutoPausePolicy()
        #expect(!look(&policy, sample(), now: start))
        #expect(!look(&policy, sample(), now: start + .seconds(14 * 60)))
        #expect(look(&policy, sample(), now: start + .seconds(15 * 60)))
        var five = AutoPausePolicy()
        #expect(!look(&five, sample(minutes: 5), now: start))
        #expect(look(&five, sample(minutes: 5), now: start + .seconds(5 * 60)))
    }

    @Test func neverWhenOff() {
        var policy = AutoPausePolicy()
        #expect(!look(&policy, sample(minutes: 0), now: start))
        #expect(!look(&policy, sample(minutes: 0), now: start + .seconds(24 * 3600)))
    }

    /// A window, work under way or a busy Android start the idle time over.
    @Test func anythingUnderWayStartsTheTimeOver() {
        for blocked in [sample(windows: 1), sample(busy: [.adb]), sample(busy: [.sound]), sample(busy: [.install]),
                        sample(cpu: 0.8)] {
            var policy = AutoPausePolicy()
            #expect(!look(&policy, sample(), now: start))
            #expect(!look(&policy, blocked, now: start + .seconds(10 * 60)))
            // Counted from the first look without it, not from the start.
            #expect(!look(&policy, sample(), now: start + .seconds(16 * 60)))
            #expect(!look(&policy, sample(), now: start + .seconds(30 * 60)))
            #expect(look(&policy, sample(), now: start + .seconds(31 * 60)))
        }
    }

    @Test func aUseStartsTheTimeOver() {
        var policy = AutoPausePolicy()
        #expect(!look(&policy, sample(), now: start))
        #expect(!look(&policy, sample(lastUse: .seconds(10 * 60)), now: start + .seconds(15 * 60)))
        #expect(policy.idleSince == start + .seconds(10 * 60))
        #expect(look(&policy, sample(lastUse: .seconds(10 * 60)), now: start + .seconds(25 * 60)))
    }

    @Test func notRunningIsNeverIdle() {
        var policy = AutoPausePolicy()
        var stopped = sample()
        stopped.running = false
        #expect(!look(&policy, stopped, now: start))
        #expect(policy.idleSince == nil)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct AutoPauseDaemonTests {
    func harness(minutes: Int = 15) throws -> (Harness, PausingEngine) {
        var pausing: PausingEngine?
        let harness = try Harness(apps: [FakeBridgeAgent.app("org.fdroid.fdroid", label: "F-Droid")],
                                  configure: { $0.autoPauseMinutes = minutes },
                                  wrap: { base in
                                      let engine = PausingEngine(base)
                                      pausing = engine
                                      return engine
                                  })
        return (harness, pausing!)
    }

    /// Two looks the chosen time apart, with nothing in between: once the
    /// start's background work (app sync, the Mac's state) has stopped using
    /// Android, as a use after the decision rightly keeps it running. Under
    /// a loaded test run that work can outlast the start by a while.
    func idleLooks(_ core: DaemonCore, minutes: Int = 15) async {
        await settle(core)
        let now = ContinuousClock.now
        await core.autoPauseTick(now: now)
        await core.autoPauseTick(now: now + .seconds(minutes * 60 + 1))
    }

    /// Waits (up to 10 s) until neither the last use nor what keeps Android
    /// busy has changed for 300 ms.
    func settle(_ core: DaemonCore) async {
        let deadline = ContinuousClock.now + .seconds(10)
        var last = (await core.vm.lastUse, await core.autoPauseBlockers().busy)
        var steady = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            let now = (await core.vm.lastUse, await core.autoPauseBlockers().busy)
            if now != last {
                last = now
                steady = .now
            } else if ContinuousClock.now - steady >= .milliseconds(300) {
                return
            }
        }
    }

    @Test func idleAndroidPausesAndGoesOnWhenAWindowOpens() async throws {
        let (harness, engine) = try harness()
        defer { harness.cleanUp() }
        await harness.core.start()
        try await harness.core.startVMFromMenuBar()
        #expect(await harness.waitForShims(1))
        let listings = await harness.agent.requests { if case .listApps = $0 { true } else { nil } }.count

        await idleLooks(harness.core)
        #expect(engine.pauses == 1)
        let paused = await harness.core.status()
        #expect(paused.state == .suspended)
        #expect(paused.pause?.automatic == true)
        #expect(paused.androidVersion != nil, "the rest of the status stays")

        // A resume is no new start: the apps are not listed again.
        try await harness.core.resumeFromMenuBar()
        #expect(await harness.core.status().state == .running)
        #expect(await harness.core.status().pause == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.agent.requests { if case .listApps = $0 { true } else { nil } }.count == listings)

        // Opening an app is a use: Android goes on.
        await idleLooks(harness.core)
        #expect(engine.pauses == 2)
        let (shim, events) = await harness.connect(.shim(package: "org.fdroid.fdroid"))
        let display = try await harness.core.openDisplay(OpenDisplayRequest(package: "org.fdroid.fdroid", width: 800, height: 1600, dpi: 320),
                                                         client: shim)
        #expect(await events.wait { $0 == .displayReady(displayID: display) } != nil)
        #expect(engine.resumes.count == 2)
        #expect(await harness.core.status().state == .running)

        // A window is open: no pause, however long.
        await idleLooks(harness.core)
        #expect(engine.pauses == 2)
    }

    @Test func windowsWorkAndSettingsKeepAndroidRunning() async throws {
        let (harness, engine) = try harness()
        defer { harness.cleanUp() }
        await harness.core.start()
        try await harness.core.startVMFromMenuBar()

        // The Control Panel is open.
        let (panel, _) = await harness.connect(.controlPanel)
        await idleLooks(harness.core)
        #expect(engine.pauses == 0)
        await harness.core.disconnect(panel)

        // Android plays sound, or keeps a CPU busy (a download).
        engine.setActivity { $0.playing = true }
        await idleLooks(harness.core)
        #expect(engine.pauses == 0)
        engine.setActivity { $0.playing = false }
        let now = ContinuousClock.now
        engine.setActivity { $0.cpuTime = .seconds(1) }
        await harness.core.autoPauseTick(now: now)
        engine.setActivity { $0.cpuTime = .seconds(1 + 15 * 60) } // a whole core all along
        await harness.core.autoPauseTick(now: now + .seconds(15 * 60 + 1))
        #expect(engine.pauses == 0)

        // Never, in Settings.
        var config = await harness.core.config
        config.autoPauseMinutes = 0
        let (settings, _) = await harness.connect(.controlPanel)
        _ = try await harness.core.updateConfiguration(config, client: settings)
        await harness.core.disconnect(settings)
        await idleLooks(harness.core)
        #expect(engine.pauses == 0)
    }

    @Test func theMenuBarPausesAndResumesAndStopWakesFirst() async throws {
        let (harness, engine) = try harness(minutes: 0)
        defer { harness.cleanUp() }
        await harness.core.start()
        try await harness.core.startVMFromMenuBar()
        // The start's app sync is done: it would wake a pause it came after.
        #expect(await harness.waitForShims(1))

        try await harness.core.pauseFromMenuBar()
        #expect(await harness.core.status().state == .suspended)
        #expect(await harness.core.status().pause?.automatic == false)
        // Pausing twice is harmless; reading the status does not wake it.
        try await harness.core.pauseFromMenuBar()
        _ = await harness.core.status()
        #expect(engine.pauses == 1)

        // Copying on the Mac does not wake it; Android gets the text when it goes on.
        await harness.core.hostClipboardChanged("copied while paused")
        #expect(engine.resumes.isEmpty)
        try await harness.core.resumeFromMenuBar()
        #expect(await harness.core.status().state == .running)
        #expect(await eventually {
            await harness.agent.requests { if case .setClipboard(let c) = $0 { c.text } else { nil } } == ["copied while paused"]
        })

        // What the engine hands out itself (a fingerprint, Google apps) wakes it.
        try await harness.core.pauseFromMenuBar()
        await engine.use()
        #expect(engine.resumes.count == 2)
        #expect(await harness.core.status().state == .running)

        // So does adb on the Mac (ADB support asks for a socket to adbd).
        try await harness.core.pauseFromMenuBar()
        _ = try? await harness.core.vm.adbSocket()
        #expect(engine.resumes.count == 3)
        #expect(await harness.core.status().state == .running)

        // Stopping a paused Android.
        try await harness.core.pauseFromMenuBar()
        try await harness.core.stopVMFromMenuBar()
        #expect(await harness.core.status().state == .stopped)
        #expect(await harness.core.status().pause == nil)
        // Pausing a stopped Android does nothing.
        try await harness.core.pauseFromMenuBar()
        #expect(engine.pauses == 4)
    }

    /// A use between the decision and the pause wins.
    @Test func aUseRightBeforeThePauseKeepsAndroidRunning() async throws {
        let (harness, engine) = try harness()
        defer { harness.cleanUp() }
        await harness.core.start()
        try await harness.core.startVMFromMenuBar()
        let decided = ContinuousClock.now
        _ = try await harness.core.vm.controlSession()
        try await harness.core.vm.pause(automatic: true, idleSince: decided)
        #expect(engine.pauses == 0)
        #expect(await harness.core.status().state == .running)
    }

    /// The fingerprint watcher's looks would wake a paused Android every two seconds.
    @Test func fingerprintsLeaveAPausedAndroidAlone() async throws {
        let (harness, _) = try harness(minutes: 0)
        defer { harness.cleanUp() }
        await harness.core.start()
        try await harness.core.startVMFromMenuBar()
        #expect(await harness.waitForShims(1))
        try await harness.core.pauseFromMenuBar()
        #expect(await eventually { await harness.core.fingerprints.paused })
        try await harness.core.resumeFromMenuBar()
        #expect(await eventually { await !harness.core.fingerprints.paused })
    }
}
