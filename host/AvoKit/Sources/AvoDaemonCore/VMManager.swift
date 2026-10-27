import AvoADB
import AvoIO
import AvoKit
import AvoProtocol
import Foundation
import os

/// Owns the VM lifecycle and the three guest channels (Control, Input, ADB).
///
/// Boot: verify image → write BootConfig → start engine → connect Control
/// (retrying while Android boots) → Hello → connect Input → running. The VM
/// stays up in the background so opening apps feels instant (spec goal 4).
public actor VMManager {
    public struct Settings: Sendable {
        public var config: VMConfig
        public var profile: DeviceProfile?
        /// Every Android display's refresh rate for this boot (FrameRates.androidRate).
        public var displayRate: Int
        /// Android's own screen, display 0 (VMConfig.androidScreen).
        public var androidScreen: DisplayRequest

        public init(config: VMConfig, profile: DeviceProfile?, displayRate: Int = FrameRates.standardRate,
                    androidScreen: DisplayRequest = DisplayRequest(width: 720, height: 1280, dpi: 320)) {
            self.config = config
            self.profile = profile
            self.displayRate = displayRate
            self.androidScreen = androidScreen
        }
    }

    private let engine: any VMEngine
    private let paths: AvoPaths
    private let softwareVersion: String
    private let adbKey: ADBKey
    private let loadImage: @Sendable () throws -> AndroidImage
    /// Runs before every start (Android's data must be where Avo keeps it).
    private let preflight: @Sendable () async throws -> Void
    /// Runs once Android answers, before the start counts as done (notes who used the data).
    private let started: @Sendable () async -> Void
    private let bootTimeout: Duration
    /// A boot on a data disk Android never wrote: it formats the data and
    /// prepares ART and every app first, minutes before the agent listens.
    private let firstBootTimeout: Duration
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "VM")

    public private(set) var status = VMStatus.stopped
    private var control: ControlSession?
    private var input: InputChannel?
    private var adb: ADBConnection?
    private var booting: Task<Void, any Error>?
    /// Android rebooted itself or asked for its reset, and the daemon has
    /// not taken that up yet (it starts Android again: `restartTaken`).
    private var restartPending = false
    private var pumps: [Task<Void, Never>] = []
    /// Pauses and wakes, one after the other ("Pause" below).
    private var pauseTransition: Task<Void, Never>?
    private var pausedAt: ContinuousClock.Instant?
    /// When something last used Android through this manager (a channel, a
    /// start, a wake): Pause When Idle counts its idle time from there.
    public private(set) var lastUse = ContinuousClock.now

    /// Guest events from every Control session, across reboots.
    public nonisolated let guestEvents: AsyncStream<ControlSession.Payload>
    private let guestSink: AsyncStream<ControlSession.Payload>.Continuation
    public nonisolated let statusUpdates: AsyncStream<VMStatus>
    private let statusSink: AsyncStream<VMStatus>.Continuation
    /// Android asked for a factory reset; the VM is stopped (AndroidFactoryReset).
    public nonisolated let factoryResets: AsyncStream<Void>
    private let factoryResetSink: AsyncStream<Void>.Continuation
    /// Android rebooted itself; the VM is stopped (AndroidRebooted).
    public nonisolated let reboots: AsyncStream<Void>
    private let rebootSink: AsyncStream<Void>.Continuation

    public init(engine: any VMEngine, paths: AvoPaths, softwareVersion: String, adbKey: ADBKey,
                bootTimeout: Duration = .seconds(180), firstBootTimeout: Duration = .seconds(900),
                preflight: @escaping @Sendable () async throws -> Void = {},
                started: @escaping @Sendable () async -> Void = {},
                loadImage: @escaping @Sendable () throws -> AndroidImage) {
        self.engine = engine
        self.paths = paths
        self.softwareVersion = softwareVersion
        self.adbKey = adbKey
        self.bootTimeout = bootTimeout
        self.firstBootTimeout = firstBootTimeout
        self.preflight = preflight
        self.started = started
        self.loadImage = loadImage
        (guestEvents, guestSink) = AsyncStream.makeStream(of: ControlSession.Payload.self, bufferingPolicy: .bufferingNewest(4096))
        (statusUpdates, statusSink) = AsyncStream.makeStream(of: VMStatus.self, bufferingPolicy: .bufferingNewest(16))
        (factoryResets, factoryResetSink) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        (reboots, rebootSink) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let exits = engine.exits
        Task { [weak self] in
            for await error in exits { await self?.engineExited(error) }
        }
        // What the engine hands out itself (fingerprints, Google apps) wakes Android too.
        (engine as? any PausableEngine)?.onUse { [weak self] in try? await self?.wake() }
    }

    // MARK: Lifecycle

    /// Starts the VM if needed and waits until the Bridge Agent answers.
    public func ensureRunning(_ settings: @autoclosure @Sendable () -> Settings) async throws {
        // Paused: it goes on (a failed wake starts it again below).
        if usedWhilePaused() { try? await wake() }
        if status.state == .running, let control, await control.isOpen { return }
        if let booting { return try await booting.value }
        let settings = settings()
        let task = Task { try await self.boot(settings) }
        booting = task
        defer { if booting == task { booting = nil } }
        do {
            try await task.value
        } catch {
            // Called off by a stop or by Android's own reboot, which tidy up
            // and say what happened themselves (the next boot may be under way).
            if error is CancellationError || task.isCancelled || booting != task { throw error }
            await teardown()
            update(VMStatus(state: error as? AvoError == .imageMissing ? .notInstalled : .failed,
                            detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            // Nothing of a failed start runs on: avo-vmm would keep its memory,
            // its CPU and the disks, and its host agent wait for Android, until
            // the next start. (Its exit, as it ends, is no news: `engineExited`.)
            await engine.stop()
            throw error
        }
    }

    private func boot(_ settings: Settings) async throws {
        update(VMStatus(state: .starting, detail: "Starting Android"))
        try await preflight()
        let image = try loadImage()
        try paths.createDirectories()
        let dataDisk = DataDiskStore(paths: paths)
        let firstBoot = try dataDisk.ensure(gb: settings.config.dataDiskGiB)
        dataDisk.clearFactoryResetProtection()

        var adbKeys = [try adbKey.androidPublicKey(comment: "avo-daemon")]
        // ADB support: adb on this Mac authenticates with its own key.
        if settings.config.adbEnabled,
           let key = try? String(contentsOf: paths.home.appending(path: ".android/adbkey.pub"), encoding: .utf8) {
            adbKeys.append(key.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let bootConfig = BootConfig(adbKeys: adbKeys, profile: settings.profile, config: settings.config,
                                    density: Int(settings.androidScreen.dpi))
        let configDisk = paths.vm.appending(path: "avo_config.img")
        try bootConfig.write(to: configDisk)
        // Stopped meanwhile (Stop shows while Android starts): no engine starts.
        // After each wait below likewise, the status stays the stop's, and what
        // this start opened itself closes; the stop ends the engine.
        try Task.checkCancellation()
        try await engine.start(EngineLaunch(config: settings.config, paths: paths, image: image, bootConfigDisk: configDisk,
                                            profile: settings.profile, displayRate: settings.displayRate,
                                            androidScreen: settings.androidScreen))
        try Task.checkCancellation()

        update(VMStatus(state: .starting, detail: String(localized: "Waiting for Android to boot", bundle: .avoKit)))
        let session = try await connectControl(timeout: firstBoot ? max(bootTimeout, firstBootTimeout) : bootTimeout)
        let hello: Avo_V1_Hello
        do {
            hello = try await session.start()
            try Task.checkCancellation()
        } catch {
            await session.close()
            throw error
        }
        control = session
        pumps.append(Task { [weak self] in
            for await event in session.events { await self?.forward(event) }
            await self?.controlClosed(session)
        })

        let inputStream = try await engine.connect(port: AvoProtocol.Port.input)
        let channel = InputChannel(stream: inputStream)
        do {
            try await channel.start()
            try Task.checkCancellation()
        } catch {
            await channel.close()
            throw error
        }
        input = channel
        await started()

        try Task.checkCancellation()
        update(VMStatus(state: .running, androidVersion: Self.androidVersion(sdk: Int(hello.androidSdk)),
                        protocolVersion: await session.negotiatedVersion, bootedAt: Date()))
        logger.notice("Android ready: \(hello.softwareVersion, privacy: .public)")
    }

    /// Retries until the Bridge Agent listens (it starts late in boot). The
    /// Mac asleep is no time Android had to boot.
    private func connectControl(timeout: Duration) async throws -> ControlSession {
        let deadline = SuspendingClock.now + timeout
        var lastError: (any Error)?
        while SuspendingClock.now < deadline {
            try Task.checkCancellation()
            do {
                let stream = try await engine.connect(port: AvoProtocol.Port.control)
                return ControlSession(stream: stream, softwareVersion: softwareVersion)
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw AvoError.timedOut("Android boot (\(lastError.map { "\($0)" } ?? "no answer"))")
    }

    /// Android holds nothing, and nothing here is about to start it again:
    /// no start under way, no reboot of Android's own still to take up.
    public var holdsNothing: Bool { !status.state.holdsAndroid && booting == nil && !restartPending }

    /// The daemon took up Android's reboot or reset (`reboots`, `factoryResets`).
    public func restartTaken() {
        restartPending = false
    }

    /// Android, stopped after a reboot of its own, is not started again (it
    /// kept rebooting before it was ready): it failed, and the status says why.
    public func reportFailure(_ detail: String) {
        guard status.state == .stopped else { return }
        logger.error("\(detail, privacy: .public)")
        update(VMStatus(state: .failed, detail: detail))
    }

    /// `reason`: why Android stopped, shown with the status (an eject).
    /// A start under way ends too, with nothing of it left running.
    public func stop(reason: String? = nil) async {
        guard status.state != .stopped else { return }
        // A paused engine runs Android again for its power off (VMMEngine.stop).
        pausedAt = nil
        update(VMStatus(state: .stopping))
        let boot = booting
        boot?.cancel()
        await teardown()
        await engine.stop()
        if let boot {
            // The start winds down (its engine start, its waits); an engine
            // that came up after the stop above ends now.
            _ = await boot.result
            await teardown()
            await engine.stop()
        }
        update(VMStatus(state: .stopped, detail: reason))
    }

    public func restart(_ settings: @autoclosure @Sendable () -> Settings) async throws {
        await stop()
        try await ensureRunning(settings())
    }

    /// Writes a quick-boot snapshot (spec: "Quick boot dari snapshot").
    public func takeSnapshot() async throws {
        guard status.state == .running else { throw AvoError.vmNotRunning }
        try paths.createDirectories()
        try await engine.snapshot(to: paths.snapshots.appending(path: "quickboot.snap"))
    }

    private func teardown() async {
        for pump in pumps { pump.cancel() }
        pumps.removeAll()
        // Let go first: the session's pump, ending as it closes, must not
        // take this for a channel lost while Android runs (`controlClosed`).
        let (control, input, adb) = (self.control, self.input, self.adb)
        self.control = nil
        self.input = nil
        self.adb = nil
        await control?.close()
        await input?.close()
        await adb?.close()
    }

    private func engineExited(_ error: (any Error)?) async {
        // The engine of a stop, or of a start that failed (both stop it
        // themselves), says nothing new as it ends.
        switch status.state {
        case .stopped, .stopping, .failed, .notInstalled: return
        default: break
        }
        // Android ran (or was paused) and nothing stopped it: its engine ended
        // by itself. A start under way stops its engine when it fails.
        let unexpected = status.state != .starting
        pausedAt = nil
        // Android itself rebooted or asked for a reset: a boot still waiting
        // for its Control channel ends now instead of at its timeout
        // (minutes), and makes way for the next start. Only these: the exit
        // of an engine stopped on purpose can come after the next boot began.
        if error is AndroidRebooted || error is AndroidFactoryReset {
            booting?.cancel()
            booting = nil
        }
        await teardown()
        if error is AndroidFactoryReset {
            logger.notice("Android asked for a factory reset")
            restartPending = true
            await engine.stop()
            update(VMStatus(state: .stopped, detail: String(localized: "Erasing Android’s data", bundle: .avoKit)))
            factoryResetSink.yield()
            return
        }
        if error is AndroidRebooted {
            logger.notice("Android rebooted itself; starting it again")
            restartPending = true
            await engine.stop()
            update(VMStatus(state: .stopped, detail: String(localized: "Android is restarting", bundle: .avoKit)))
            rebootSink.yield()
            return
        }
        if let error {
            update(VMStatus(state: .failed, detail: (error as? LocalizedError)?.errorDescription ?? "\(error)"))
        } else {
            update(.stopped)
        }
        // What it left (its host agent and watches) goes now, not at the next start.
        if unexpected { await engine.stop() }
    }

    private func controlClosed(_ session: ControlSession) async {
        guard control === session, status.state == .running else { return }
        logger.error("Control channel closed while running")
        update(VMStatus(state: .failed, detail: String(localized: "Android stopped responding", bundle: .avoKit)))
        // A failed Android holds nothing: its engine powers it off and ends.
        await teardown()
        await engine.stop()
    }

    // MARK: Channels

    // Every channel wakes a paused Android first: using it is what resumes it.

    public func controlSession() async throws -> ControlSession {
        if usedWhilePaused() { try await wake() }
        guard let control, status.state == .running else { throw AvoError.vmNotRunning }
        return control
    }

    public func inputChannel() async throws -> InputChannel {
        if usedWhilePaused() { try await wake() }
        guard let input, status.state == .running else { throw AvoError.vmNotRunning }
        return input
    }

    /// The ADB channel, connected on first use.
    public func adbConnection() async throws -> ADBConnection {
        if usedWhilePaused() { try await wake() }
        if let adb { return adb }
        guard status.state == .running else { throw AvoError.vmNotRunning }
        let stream = try await engine.connect(port: AvoProtocol.Port.adb)
        let connection = ADBConnection(transport: stream, key: adbKey, keyComment: "avo-daemon")
        _ = try await connection.connect(timeout: .seconds(20))
        adb = connection
        return connection
    }

    /// Runs `command` over a fresh adbd connection, also while Android has
    /// not finished booting or keeps restarting (system_server crashing):
    /// adbd is up long before `sys.boot_completed`. For repairs only (taking
    /// out a Google apps install that broke the boot). Throws `vmNotRunning`
    /// at once when the engine is not running.
    public func rescueShell(_ command: String, timeout: Duration) async throws -> ShellResult {
        if usedWhilePaused() { try? await wake() }
        // The Mac asleep is no time the repair had.
        let deadline = SuspendingClock.now + timeout
        var lastError: (any Error)?
        while SuspendingClock.now < deadline {
            try Task.checkCancellation()
            let stream: any ByteStream
            do {
                stream = try await engine.connect(port: AvoProtocol.Port.adb)
            } catch AvoError.vmNotRunning {
                throw AvoError.vmNotRunning
            } catch {
                lastError = error
                try await Task.sleep(for: .seconds(1))
                continue
            }
            let connection = ADBConnection(transport: stream, key: adbKey, keyComment: "avo-daemon")
            do {
                _ = try await connection.connect(timeout: .seconds(15))
                // A repair may take its caller's whole time.
                let result = try await connection.shell(command, timeout: timeout)
                await connection.close()
                return result
            } catch {
                await connection.close()
                lastError = error
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw AvoError.timedOut("ADB (\(lastError.map { "\($0)" } ?? "no answer"))")
    }

    /// A socket to adbd in Android for `adb` on the Mac ("ADB support").
    public func adbSocket() async throws -> Int32 {
        if usedWhilePaused() { try await wake() }
        guard status.state == .running else { throw AvoError.vmNotRunning }
        return try await engine.connectSocket(port: AvoProtocol.Port.adb)
    }

    // MARK: Helpers

    private func forward(_ event: ControlSession.Payload) {
        guestSink.yield(event)
    }

    private func update(_ new: VMStatus) {
        var new = new
        if new.state == .running || new.state == .starting { new.openDisplays = status.openDisplays }
        // The engine reports the renderer on its own (setRenderer).
        new.renderer = status.renderer
        // And Android's screen lock (setScreenLock), which lasts one run: a
        // new start (also one after a lost Control channel) begins without.
        if new.state == .running ? status.state == .starting || status.state == .running
                                 : new.state == .starting && status.state == .starting {
            new.screenLock = status.screenLock
        }
        status = new
        statusSink.yield(new)
    }

    /// Android's screen lock while it keeps Android locked, from the engine
    /// (ScreenLockEngine); kept only while Android starts or runs.
    public func setScreenLock(_ lock: AndroidScreenLock?) {
        let lock = status.state == .running || status.state == .starting || status.isPaused ? lock : nil
        guard status.screenLock != lock else { return }
        status.screenLock = lock
        statusSink.yield(status)
    }

    public func setOpenDisplays(_ count: Int) {
        status.openDisplays = count
        statusSink.yield(status)
    }

    /// Android stopped answering, or answers again (ResponsivenessEngine);
    /// kept only while it runs.
    public func setNotResponding(since: Date?) {
        let since = status.state == .running ? since : nil
        guard status.notRespondingSince != since else { return }
        status.notRespondingSince = since
        if since != nil { logger.error("Android is not responding") }
        statusSink.yield(status)
    }

    /// GPU or software rendering, from the engine (VMMEngine.renderer).
    public func setRenderer(_ renderer: RendererStatus?) {
        guard status.renderer != renderer else { return }
        status.renderer = renderer
        statusSink.yield(status)
    }

    // MARK: Pause (Pause When Idle and the menu bar; PausableEngine)

    /// Whether this engine can pause Android at all.
    public nonisolated var canPause: Bool { engine is any PausableEngine }

    /// Pauses a running Android: its vCPUs stop, it keeps its place and uses
    /// no CPU until anything uses it (`wake`). `idleSince`: Pause When Idle's
    /// decision, dropped when Android was used after it.
    public func pause(automatic: Bool, idleSince: ContinuousClock.Instant? = nil) async throws {
        try await serialized { try await self.performPause(automatic: automatic, idleSince: idleSince) }
    }

    /// Lets a paused Android go on; at once when it is not paused.
    public func wake() async throws {
        guard usedWhilePaused() else { return }
        try await serialized { try await self.performResume() }
    }

    /// Notes a use; whether Android is paused (or a pause is under way) for it.
    private func usedWhilePaused() -> Bool {
        lastUse = .now
        return status.isPaused || pauseTransition != nil
    }

    /// One pause or wake at a time, in the order asked.
    private func serialized(_ body: @escaping @Sendable () async throws -> Void) async throws {
        let previous = pauseTransition
        let task = Task {
            await previous?.value
            try await body()
        }
        let done = Task { _ = await task.result }
        pauseTransition = done
        defer { if pauseTransition == done { pauseTransition = nil } }
        try await task.value
    }

    private func performPause(automatic: Bool, idleSince: ContinuousClock.Instant?) async throws {
        guard status.state == .running, control != nil, let engine = engine as? any PausableEngine else { return }
        if let idleSince, lastUse > idleSince { return }
        setPause(.suspending, VMPause(since: Date(), automatic: automatic))
        do {
            try await engine.pause()
        } catch {
            if status.state == .suspending { setPause(.running, nil) }
            logger.error("could not pause Android: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        // Stopped or failed meanwhile.
        guard status.state == .suspending else { return }
        pausedAt = .now
        await control?.holdKeepalive(true)
        setPause(.suspended, status.pause)
        logger.notice("Android paused (\(automatic ? "idle" : "by the user", privacy: .public))")
    }

    private func performResume() async throws {
        guard status.state == .suspended, let engine = engine as? any PausableEngine else { return }
        let pausedFor = pausedAt.map { ContinuousClock.now - $0 } ?? .zero
        try await engine.resume(pausedFor: pausedFor)
        await control?.holdKeepalive(false)
        guard status.state == .suspended else { return }
        pausedAt = nil
        setPause(.running, nil)
        logger.notice("Android resumed after \(pausedFor, privacy: .public)")
    }

    /// Runs `body` while Android's disks hold still: at once while Android is
    /// stopped or paused; while it runs, its vCPUs stop for that moment (the
    /// engine handles every disk request on a vCPU, so none is half done)
    /// and go on afterwards, its clock as if nothing happened. The status
    /// does not change: it is a checkpoint's clone, over in a moment.
    public func holdingStill(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await serialized { try await self.performHold(body) }
    }

    private func performHold(_ body: @Sendable () throws -> Void) async throws {
        switch status.state {
        case .stopped, .notInstalled, .suspended:
            try body()
        case .running:
            guard let engine = engine as? any PausableEngine else {
                throw AvoError.internalError(String(localized: "This engine cannot hold Android still. Stop Android first.", bundle: .avoKit))
            }
            let start = ContinuousClock.now
            try await engine.pause()
            let result = Result { try body() }
            try await engine.resume(pausedFor: ContinuousClock.now - start)
            try result.get()
        default:
            throw AvoError.internalError(String(localized: "Android is starting or stopping. Try again in a moment.", bundle: .avoKit))
        }
    }

    /// Pausing keeps everything else of the status (windows, renderer, lock),
    /// except whether Android answered: a paused one is not asked.
    private func setPause(_ state: VMState, _ pause: VMPause?) {
        status.state = state
        status.pause = pause
        status.notRespondingSince = nil
        statusSink.yield(status)
    }

    static func androidVersion(sdk: Int) -> String {
        let names = [34: "Android 14", 35: "Android 15", 36: "Android 16", 37: "Android 17"]
        return names[sdk].map { "\($0) (API \(sdk))" } ?? "API \(sdk)"
    }
}
