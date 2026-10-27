import AvoADB
import AvoIO
import AvoKit
import Foundation
import Synchronization
import Testing
@testable import AvoDaemonCore

/// System Status' arithmetic (GuestActivity.swift, SystemMonitor.swift):
/// toybox `ps` and the look's grep over /proc, two samples into CPU
/// percentages and states, and the Mac's GPU from IOKit.
@Suite struct GuestActivityTests {
    /// `ps -A -o PID,PPID,UID,TIME+,RSS,NAME` on Android 17 (toybox), cut down.
    static let ps = """
          PID  PPID   UID    TIME+   RSS NAME
            1     0     0  0:01.20 10840 init
            2     0     0  0:00.00     0 kthreadd
            3     2     0  0:00.04     0 rcu_gp
          401     1  1000  0:02.50  9000 servicemanager
          612     1  1000 12:03.45 22000 surfaceflinger
          880   598  1000 75:01.00 310000 system_server
         1234   598 10123  1:02.33 180000 com.example.game
         1240   598 10123  0:00.50 40000 com.example.game:remote
         1300   598 10077  0:00.10 60000 com.android.systemui
         1410   598 10090  0:00.30 50000 com.example.cached
         1500   418  2000  0:00.00  2400 ps
        """

    /// The look's `grep -sE '^(cpu|MemTotal:|MemAvailable:|-?[0-9]+$)' …`.
    static let files = """
        /proc/stat:cpu  1000 10 500 8000 100 20 30 0 0 0
        /proc/stat:cpu0 250 2 125 2000 25 5 7 0 0 0
        /proc/stat:cpu1 250 3 125 2000 25 5 8 0 0 0
        /proc/stat:cpu2 250 2 125 2000 25 5 7 0 0 0
        /proc/stat:cpu3 250 3 125 2000 25 5 8 0 0 0
        /proc/meminfo:MemTotal:        4012000 kB
        /proc/meminfo:MemAvailable:    1003000 kB
        /proc/1/oom_score_adj:-1000
        /proc/401/oom_score_adj:-1000
        /proc/612/oom_score_adj:-1000
        /proc/880/oom_score_adj:-900
        /proc/1234/oom_score_adj:0
        /proc/1240/oom_score_adj:200
        /proc/1300/oom_score_adj:-800
        /proc/1410/oom_score_adj:955
        /sys/fs/cgroup/apps/uid_10123/pid_1234/cgroup.freeze:0
        /sys/fs/cgroup/apps/uid_10090/pid_1410/cgroup.freeze:1
        """

    @Test func readsTheProcessesWithoutTheKernelsThreads() {
        let processes = GuestActivity.parseProcesses(Self.ps)
        #expect(processes.map(\.pid) == [1, 401, 612, 880, 1234, 1240, 1300, 1410, 1500])
        let game = processes[4]
        #expect(game.name == "com.example.game")
        #expect(game.uid == 10123)
        #expect(game.cpuTime == 6233)
        #expect(game.residentKiB == 180_000)
        #expect(processes[5].name == "com.example.game:remote")
        // Minutes past 59, as toybox prints them.
        #expect(processes[3].cpuTime == 450_100)
    }

    @Test func cpuTimeComesInEveryLength() {
        #expect(GuestActivity.centiseconds("0:01.23") == 123)
        #expect(GuestActivity.centiseconds("12:34.56") == 75_456)
        #expect(GuestActivity.centiseconds("1:02:03.04") == 372_304)
        #expect(GuestActivity.centiseconds("2-01:00:00.50") == (2 * 86_400 + 3_600) * 100 + 50)
        #expect(GuestActivity.centiseconds("0:07.5") == 750)
        #expect(GuestActivity.centiseconds("0:07") == 700)
        #expect(GuestActivity.centiseconds("garbage") == nil)
        #expect(GuestActivity.centiseconds("1:xx.00") == nil)
    }

    @Test func aSampleHasAndroidsCPUMemoryAndEachProcesssState() {
        let sample = GuestActivity.sample(ps: Self.ps, files: Self.files, at: .now)
        #expect(sample.cores == 4)
        #expect(sample.cpuTotal == 9660)
        #expect(sample.cpuBusy == 1560)
        #expect(sample.memoryTotal == 4_012_000 * 1024)
        #expect(sample.memoryAvailable == 1_003_000 * 1024)
        let byPID = Dictionary(uniqueKeysWithValues: sample.processes.map { ($0.pid, $0) })
        #expect(byPID[1500] == nil, "gone before the grep (ps itself)")
        #expect(byPID[1234]?.oomScoreAdj == 0)
        #expect(byPID[1240]?.oomScoreAdj == 200)
        #expect(byPID[1410]?.frozen == true)
        #expect(byPID[1234]?.frozen == false)
    }

    @Test func twoSamplesGiveEachProcessItsCPU() {
        let start = ContinuousClock.now
        let first = GuestActivity.sample(ps: Self.ps, files: Self.files, at: start)
        // Two seconds later: the game used 1.5 s of CPU, systemui 0.1 s, and
        // pid 1240 is another process now.
        let later = Self.ps
            .replacingOccurrences(of: " 1:02.33 180000 com.example.game", with: " 1:03.83 181000 com.example.game")
            .replacingOccurrences(of: " 0:00.10 60000 com.android.systemui", with: " 0:00.20 60000 com.android.systemui")
            .replacingOccurrences(of: "com.example.game:remote", with: "com.example.other")
        let laterFiles = Self.files.replacingOccurrences(of: "/proc/stat:cpu  1000 10 500 8000", with: "/proc/stat:cpu  1400 10 700 8200")
        let second = GuestActivity.sample(ps: later, files: laterFiles, at: start + .seconds(2))
        let packages: Set = ["com.example.game", "com.example.cached"]
        let processes = GuestActivity.processes(from: first, to: second, packages: packages, windows: ["com.example.game"])
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        #expect(byPID[1234]?.cpu == 75)
        #expect(byPID[1234]?.memory == 181_000 * 1024)
        #expect(byPID[1300]?.cpu == 5)
        #expect(byPID[1240]?.cpu == 0, "a pid reused by another process starts over")
        // States: an Avo window, Android's own, cached and frozen.
        #expect(byPID[1234]?.state == .window)
        #expect(byPID[1234]?.package == "com.example.game")
        #expect(byPID[1300]?.state == .system)
        #expect(byPID[1300]?.package == nil, "not an installed app")
        #expect(byPID[1410]?.state == .frozen)
        #expect(byPID[401]?.state == .system)
        // Android's CPU: (2160 - 1560) busy of (10460 - 9660) jiffies, which
        // are 2 s on 4 cores: Android's clock, not adb's timing, is the interval.
        #expect(about(GuestActivity.androidCPU(from: first, to: second), 75))
        #expect(GuestActivity.elapsed(from: first, to: second) == 2)
        var late = second
        late.at = start + .seconds(3)
        #expect(GuestActivity.elapsed(from: first, to: late) == 2)
        late.cores = 0
        #expect(GuestActivity.elapsed(from: first, to: late) == 3)
        // The first sample has no CPU yet.
        #expect(GuestActivity.processes(from: nil, to: first, packages: packages, windows: []).allSatisfy { $0.cpu == 0 })
    }

    @Test func statesFollowActivityManagersLevels() {
        #expect(AndroidProcess.State(oomScoreAdj: -900) == .system)
        #expect(AndroidProcess.State(oomScoreAdj: 0) == .foreground)
        #expect(AndroidProcess.State(oomScoreAdj: 100) == .visible)
        #expect(AndroidProcess.State(oomScoreAdj: 250) == .visible)
        #expect(AndroidProcess.State(oomScoreAdj: 500) == .background)
        #expect(AndroidProcess.State(oomScoreAdj: 999) == .cached)
        #expect(AndroidProcess.State.window < .cached)
    }

    // MARK: The Mac

    @Test func readsAProcesssGPUTimeFromIOKit() {
        let usage: [[String: Any]] = [["API": "Metal", "accumulatedGPUTime": NSNumber(value: 1_500_000_000), "lastSubmittedTime": NSNumber(value: 1)],
                                      ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 500)]]
        #expect(MacGPU.gpuTime(in: usage) == 1_500_000_500)
        #expect(MacGPU.gpuTime(in: nil) == 0)
        #expect(MacGPU.gpuTime(in: "nonsense") == 0)
        // The real registry answers (without entitlements) or says nothing.
        let reading = MacGPU.read(processTimeOf: getpid())
        if let utilization = reading.utilization { #expect((0...100).contains(utilization)) }
    }
}

/// An engine that only samples (it never runs Android): what System Status asks of it.
private final class SamplingEngine: VMEngine, ActivityEngine, @unchecked Sendable {
    let name = "sampling"
    let exits = AsyncStream<EngineExit> { _ in }
    let sink = Mutex<(@Sendable (GuestActivity.Sample) -> Void)?>(nil)
    let sinkChanges = Mutex(0)

    func start(_ launch: EngineLaunch) async throws { throw AvoError.vmNotRunning }
    func stop() async {}
    func snapshot(to url: URL) async throws {}
    func connect(port: UInt32) async throws -> any ByteStream { throw AvoError.vmNotRunning }

    func sampleProcesses(_ sink: (@Sendable (GuestActivity.Sample) -> Void)?) async {
        self.sink.withLock { $0 = sink }
        sinkChanges.withLock { $0 += 1 }
    }

    func windowFrames() async -> [String: UInt64] { [:] }
    var engineProcessID: pid_t? { nil }
}

/// The daemon samples only while a Control Panel watches, and stops when it
/// stops watching or goes.
@Suite(.serialized, .timeLimit(.minutes(1))) struct SystemMonitorTests {
    @Test func samplesOnlyWhileAControlPanelWatches() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "avo-status-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp"))
        let engine = SamplingEngine()
        let core = DaemonCore(.init(paths: paths, engine: engine, adbKey: try ADBKey.generate(),
                                    profiles: DeviceProfileCatalog(profiles: []), host: HostInfo.current(),
                                    shortcuts: ShortcutManager(builder: nil, paths: paths),
                                    softwareVersion: "avo-host test", loadImage: { throw AvoError.vmNotRunning }))
        let (panel, panelID) = (RecordingClient(), UUID())
        _ = await core.register(panelID, role: .controlPanel, proxy: ClientProxy(panel))
        let shimID = UUID()
        _ = await core.register(shimID, role: .shim(package: "dev.example"), proxy: ClientProxy(RecordingClient()))

        await #expect(throws: AvoError.unauthorizedCaller) { try await core.systemActivity(watch: true, client: shimID) }
        #expect(engine.sink.withLock { $0 } == nil)

        // Watching: the engine samples, and what it finds reaches the panel
        // (Android is not running here: the Mac's side only).
        let first = try await core.systemActivity(watch: true, client: panelID)
        #expect(first.processes.isEmpty)
        let sink = try #require(engine.sink.withLock { $0 })
        sink(GuestActivity.sample(ps: GuestActivityTests.ps, files: GuestActivityTests.files, at: .now))
        #expect(await panel.wait { if case .systemActivity = $0 { true } else { false } } != nil)
        // A second watch by the same panel changes nothing.
        _ = try await core.systemActivity(watch: true, client: panelID)
        #expect(engine.sinkChanges.withLock { $0 } == 1)

        _ = try await core.systemActivity(watch: false, client: panelID)
        #expect(engine.sink.withLock { $0 } == nil)

        // A panel that goes stops it too.
        _ = try await core.systemActivity(watch: true, client: panelID)
        #expect(engine.sink.withLock { $0 } != nil)
        await core.disconnect(panelID)
        #expect(engine.sink.withLock { $0 } == nil)
    }
}

private func about(_ value: Double?, _ expected: Double) -> Bool {
    value.map { abs($0 - expected) < 0.001 } ?? false
}

private extension String {
    func suffixString(_ count: Int) -> String { String(suffix(count)) }
}
