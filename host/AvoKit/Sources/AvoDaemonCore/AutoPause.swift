import AvoKit
import Foundation
import os

// Pause When Idle (Settings › Performance): Android pauses after a while
// with no Avo window open and nothing under way, and goes on by itself as
// soon as anything uses it (VMManager.wake: a window, avoctl, adb, a
// notification). A paused Android holds its place, its vCPUs stopped and
// its clock standing still (engine/hvf/vmm/src/pause.rs); it uses no CPU,
// and nothing in it runs: notifications and background work wait too.

/// What keeps Android from pausing besides a window or being used.
public enum AutoPauseReason: String, Sendable, Hashable, CaseIterable {
    /// An app installs (InstallPipeline).
    case install
    /// Google apps install, or an interrupted install is seen through.
    case googleApps
    /// Android's data moves (Settings › Storage › Location).
    case storage
    /// adb, Android Studio or scrcpy is connected through ADB support.
    case adb
    /// Android plays sound, or records from the microphone.
    case sound
    case recording
    /// A route plays to Android's GPS (an app window's Location panel).
    case location
}

/// When to pause: pure, so the rules are testable.
struct AutoPausePolicy: Sendable {
    /// How often the daemon looks.
    static let interval: Duration = .seconds(30)
    /// More CPU than this (in cores, averaged since the last look) is
    /// Android at work on its own: a download, an app updating. Android
    /// with nothing to do uses about a tenth of one.
    static let busyCPU = 0.3

    struct Sample: Sendable {
        /// The setting (0: never).
        var minutes: Int
        /// Android runs (not starting, stopping or paused already).
        var running: Bool
        /// App windows and Control Panels.
        var windows: Int
        var busy: Set<AutoPauseReason>
        /// When anything last used Android (VMManager.lastUse).
        var lastUse: ContinuousClock.Instant
        /// The engine's CPU since the last look, in cores (nil: not known).
        var cpu: Double?
    }

    /// Since when Android is idle, as far as the looks so far tell.
    private(set) var idleSince: ContinuousClock.Instant?

    /// Whether Android should pause now. The idle time starts over at every
    /// use and while anything keeps Android running.
    mutating func shouldPause(_ sample: Sample, now: ContinuousClock.Instant) -> Bool {
        guard sample.minutes > 0, sample.running, sample.windows == 0, sample.busy.isEmpty,
              (sample.cpu ?? 0) < Self.busyCPU else {
            idleSince = nil
            return false
        }
        let since = max(idleSince ?? now, sample.lastUse)
        idleSince = since
        return now - since >= .seconds(sample.minutes * 60)
    }

    mutating func reset() {
        idleSince = nil
    }
}

/// The daemon's side of Pause When Idle (`DaemonCore.autoPause`).
struct AutoPauseState: Sendable {
    var policy = AutoPausePolicy()
    /// App installs under way.
    var installs = 0
    /// The last status was a pause (the next running one is a resume).
    var wasPaused = false
    /// Copied on the Mac while Android was paused: it gets it when it goes on.
    var clipboard: String?
    /// The engine's CPU time at the last look.
    var lastCPU: (time: Duration, at: ContinuousClock.Instant)?
}

/// What the menu bar's panel shows besides the status.
public struct MenuBarSnapshot: Sendable {
    /// Apps with a window or a process (`AppActivity`).
    public var activity: [String: AppActivity]
    /// Packages by when a window of theirs was last on screen, newest first.
    public var recent: [String]
    /// The engine's sound, CPU and memory (nil for engines that cannot tell).
    public var engine: EngineActivity?

    public init(activity: [String: AppActivity] = [:], recent: [String] = [], engine: EngineActivity? = nil) {
        self.activity = activity
        self.recent = recent
        self.engine = engine
    }
}

private let log = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Pause")

extension DaemonCore {
    func startAutoPause() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AutoPausePolicy.interval)
                await self?.autoPauseTick()
            }
        }
    }

    /// One look: pauses Android once it was idle for the chosen time.
    func autoPauseTick(now: ContinuousClock.Instant = .now) async {
        guard await vm.status.state == .running, vm.canPause else {
            autoPause.policy.reset()
            autoPause.lastCPU = nil
            return
        }
        let (windows, busy, engine) = await autoPauseBlockers()
        var cpu: Double?
        if let time = engine?.cpuTime {
            if let last = autoPause.lastCPU, now > last.at { cpu = (time - last.time) / (now - last.at) }
            autoPause.lastCPU = (time, now)
        }
        let sample = AutoPausePolicy.Sample(minutes: config.autoPauseMinutes, running: true, windows: windows, busy: busy,
                                            lastUse: await vm.lastUse, cpu: cpu)
        guard autoPause.policy.shouldPause(sample, now: now), let since = autoPause.policy.idleSince else { return }
        autoPause.policy.reset()
        log.notice("pausing Android: idle for \(self.config.autoPauseMinutes) minutes")
        do {
            // Not when anything used Android since the decision.
            try await vm.pause(automatic: true, idleSince: since)
        } catch {
            log.error("Pause When Idle: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Android goes on after a pause: what changed meanwhile reaches it.
    func androidResumed() async {
        autoPause.policy.reset()
        autoPause.lastCPU = nil
        if let text = autoPause.clipboard {
            autoPause.clipboard = nil
            // Apart from the status updates, as it waits on Android.
            Task { await hostClipboardChanged(text) }
        }
    }

    /// The menu bar's Pause Android: like Pause When Idle, now.
    public func pauseFromMenuBar() async throws {
        try await vm.pause(automatic: false)
    }

    /// The menu bar's Resume: Android goes on (as anything that uses it does).
    public func resumeFromMenuBar() async throws {
        try await vm.wake()
    }
}
