import AvoADB
import AvoIO
import AvoKit
import AvoPackages
import AvoProtocol
import AvoShimKit
import CoreGraphics
import Foundation
import IOSurface
import os
import UniformTypeIdentifiers

/// A client's XPC proxy, safe to keep in the actor (NSXPC proxies are thread-safe).
public struct ClientProxy: @unchecked Sendable {
    public let proxy: any AvoClientXPC

    public init(_ proxy: any AvoClientXPC) {
        self.proxy = proxy
    }

    func send(_ event: DaemonEvent) {
        proxy.handleEvent(AvoXPC.encode(event))
    }
}

/// IOSurface swapchains from the engine, passed through to App Shims.
public struct SurfaceList: @unchecked Sendable {
    public let surfaces: [IOSurface]

    public init(_ surfaces: [IOSurface]) {
        self.surfaces = surfaces
    }
}

/// The Runtime Daemon's state and behaviour, independent of XPC plumbing.
public actor DaemonCore {
    public struct Dependencies: Sendable {
        public var paths: AvoPaths
        public var engine: any VMEngine
        public var adbKey: ADBKey
        public var profiles: DeviceProfileCatalog
        public var host: HostInfo
        public var shortcuts: ShortcutManager
        public var notifications: any NotificationPresenter
        public var nowPlaying: any NowPlayingPresenter
        public var clipboard: any ClipboardBridge
        public var launcher: any AppLauncher
        public var softwareVersion: String
        public var bootTimeout: Duration
        public var loadImage: @Sendable () throws -> AndroidImage
        /// Unmounts of the volume Android's data is on (DiskArbitration; none in tests).
        public var volumes: (any VolumeWatching)?
        /// The `AvoCuttlefishImages` developer setting (an image folder).
        public var imageOverride: String?
        /// Translate Screen's engine, one for every app (ScreenTextEngine.swift; none in tests).
        public var screenText: ScreenTextEngine?

        public init(paths: AvoPaths, engine: any VMEngine, adbKey: ADBKey, profiles: DeviceProfileCatalog, host: HostInfo,
                    shortcuts: ShortcutManager, notifications: any NotificationPresenter = NoNotifications(),
                    nowPlaying: any NowPlayingPresenter = NoNowPlaying(), clipboard: any ClipboardBridge = NoClipboard(), launcher: any AppLauncher = NoLauncher(),
                    softwareVersion: String, bootTimeout: Duration = .seconds(180), volumes: (any VolumeWatching)? = nil,
                    imageOverride: String? = nil, screenText: ScreenTextEngine? = nil,
                    loadImage: @escaping @Sendable () throws -> AndroidImage) {
            self.paths = paths
            self.engine = engine
            self.adbKey = adbKey
            self.profiles = profiles
            self.host = host
            self.shortcuts = shortcuts
            self.notifications = notifications
            self.nowPlaying = nowPlaying
            self.clipboard = clipboard
            self.launcher = launcher
            self.softwareVersion = softwareVersion
            self.bootTimeout = bootTimeout
            self.volumes = volumes
            self.imageOverride = imageOverride
            self.screenText = screenText
            self.loadImage = loadImage
        }
    }

    public typealias ClientID = UUID

    struct Client {
        let role: ClientHello.Role
        let proxy: ClientProxy
    }

    struct Display {
        let id: UInt32
        let package: String
        let owner: ClientID
        var width: UInt32
        var height: UInt32
        var dpi: UInt32
        var ready = false
        /// False while the window is minimized or hidden.
        var visible = true
        /// Its app runs in the background (the blue light): hidden on purpose.
        var inBackground = false
        /// Android is launching its app, and `openDisplay` waits for it.
        var opening = false
    }

    let deps: Dependencies
    /// For the extensions in other files (SharedFolderBridge.swift).
    nonisolated var dependencies: Dependencies { deps }
    public nonisolated let vm: VMManager
    public nonisolated let registry: AppRegistry
    /// Settings › Fingerprints and the windows' fingerprint menus (Fingerprints.swift).
    nonisolated let fingerprints: FingerprintCenter
    /// Where Android's data is (Settings › Storage › Location, StorageLocations.swift).
    nonisolated let storage: StorageLocations
    /// What Android's GPS reports: this Mac, a place or a route (LocationCenter.swift).
    nonisolated let location: LocationCenter
    private let adb: ADBForwarder
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Daemon")

    private(set) var config: VMConfig
    /// Configuration the running VM booted with (for "restart needed").
    var bootedConfig: VMConfig?
    /// Android's display rate that boot (FrameRates.androidRate).
    private var bootedDisplayRate = FrameRates.standardRate
    private var clients: [ClientID: Client] = [:]
    private var displays: [UInt32: Display] = [:]
    private var nextDisplayID: UInt32 = 1
    /// Where the engine keeps what Android plays, for App Shims' screen recordings.
    private var audioTap: AudioTapLocation?
    private var lastClipboardFromGuest: String?
    /// The Mac's clipboard is shared (Settings › Devices › Clipboard), and
    /// watched now: only while Android runs, not paused (`watchClipboard`).
    private var clipboardShared = false
    private var clipboardWatched = false
    private var androidAwake = false
    /// Android's notifications since the daemon started, newest first.
    private var recentNotifications: [AndroidNotification] = []
    /// The notifications Android shows now, key → package: the apps' Dock
    /// badges. Unlike `recentNotifications` it is never cut short.
    private var activeNotifications: [String: String] = [:]
    /// The artwork of what Android plays, as it last sent it (NowPlaying
    /// sends it only when it changes).
    private var nowPlayingArtwork: Data?
    /// Android widgets on the Mac (DaemonWidgets.swift).
    var placedWidgets: [PlacedWidget]
    /// The shortcuts being made again (`rebuildShortcuts`).
    private var shortcutRebuild: Task<Void, Never>?
    /// Shim builds under way, one at a time for each app (`serializedShimBuild`).
    private var shimBuilds: [String: Task<Void, Never>] = [:]
    /// In-process watchers of the VM status (the menu bar). `vm.statusUpdates`
    /// is an AsyncStream, which hands each element to one reader only, so
    /// this actor is its only reader and passes every update on.
    private var statusObservers: [UUID: AsyncStream<VMStatus>.Continuation] = [:]
    private var configObservers: [UUID: AsyncStream<VMConfig>.Continuation] = [:]
    /// Apps with an Android process (from `ps`, while a Control Panel watches).
    private var runningPackages: Set<String> = []
    private var lastActivity: [String: AppActivity] = [:]
    private var started = false
    /// When Android was last asked about its storage (`dataDiskStatus`).
    var storageCheckedAt: ContinuousClock.Instant?
    /// The Google apps install (or the recovery of an interrupted one)
    /// running now, one at a time; its latest progress, and whether it can
    /// still stop (nothing in Android changed yet).
    private(set) var googleAppsRun: Task<URL?, any Error>? { didSet { publishGoogleAppsBusy() } }
    /// Root being prepared (Magisk; `rootIfAsked`).
    private var rootRun: Task<Void, Never>?
    /// The first start with Magisk is under way: Android rebooting before it
    /// is ready means Magisk does not start this Android (it would reboot
    /// over and over), so root goes off again (`rootFailedToBoot`).
    private var rootTrial = false
    private var googleAppsRunID: UUID?
    private var googleAppsRecovering = false
    /// The run is a Remove (or finishes one), not an install.
    private var googleAppsRemoving = false
    private var googleAppsProgress: GoogleAppsProgress?
    private var googleAppsCancellable = false { didSet { publishGoogleAppsBusy() } }
    /// The user stopped the run itself (cancelGoogleApps), before it changed Android.
    private var googleAppsCancelRequested = false
    /// Android was stopped by force while the run changed it: the run
    /// neither restarts nor repairs it, the next start does (GoogleAppsJournal).
    private var googleAppsInterrupted = false
    /// Installs stopped before their request reached the daemon.
    private var cancelledGoogleApps: Set<UUID> = []
    private var googleAppsBusyObservers: [UUID: AsyncStream<GoogleAppsWork?>.Continuation] = [:]
    private var lastGoogleAppsBusy: GoogleAppsWork?
    /// How much each app is used, from its windows (AppUsageRecorder.swift).
    var usage: AppUsageRecorder
    /// A change of where Android's data is runs (starts wait for it).
    private(set) var storageChanging = false
    /// A storage status for the Control Panels is on its way (volumes change in bursts).
    private var storagePublishPending = false
    /// Pause When Idle and what it waits for (AutoPause.swift).
    var autoPause = AutoPauseState()
    /// Work that stops Android to start it again (Restart, Try GPU Again,
    /// Android's own reboot or reset, a checkpoint's restore, Reset Android)
    /// and starts on their way: Android passes through "stopped" in them,
    /// which is no moment to restart on an update (`claimRestartForUpdate`).
    var restartWork = 0
    private var starting = 0
    /// This daemon ends to restart on an updated Avo, or ends for good (a
    /// logout, a shutdown, its agent stopped): nothing starts Android any more.
    private(set) var exitingForUpdate = false
    private var exiting = false
    /// Android's reboots of its own since it was last ready (RebootLimit).
    private var reboots = RebootLimit()
    /// What the running Android's statuses still ask for (StartSync).
    private var startSync = StartSync()
    /// How long the Mac slept since it last woke (`macWoke`).
    private var macSleep = MacSleep()
    /// Clients whose Location panel is open (`locationStatus(watch:)`).
    var locationWatchers: Set<ClientID> = []
    /// Control Panels whose System Status shows (`systemActivity(watch:)`), and its sampling (SystemMonitor.swift).
    var activityWatchers: Set<ClientID> = []
    var systemMonitor = SystemMonitorState()

    public init(_ deps: Dependencies) {
        self.deps = deps
        config = (try? VMConfig.load(from: deps.paths.config)) ?? VMConfig.recommended(for: deps.host)
        registry = AppRegistry(paths: deps.paths)
        let paths = deps.paths
        let imageOverride = deps.imageOverride
        let storage = StorageLocations(paths: paths) { AndroidImageStore(paths: paths).installed(override: imageOverride) }
        self.storage = storage
        let vm = VMManager(engine: deps.engine, paths: deps.paths, softwareVersion: deps.softwareVersion,
                           adbKey: deps.adbKey, bootTimeout: deps.bootTimeout,
                           preflight: { try await storage.prepareForStart() },
                           started: { [version = deps.softwareVersion] in await storage.stamp(avoVersion: version) },
                           loadImage: deps.loadImage)
        self.vm = vm
        fingerprints = FingerprintCenter(paths: deps.paths, engine: deps.engine)
        usage = AppUsageRecorder(url: deps.paths.usage)
        placedWidgets = Self.loadWidgets(deps.paths)
        adb = ADBForwarder { try await vm.adbSocket() }
        location = LocationCenter(engine: deps.engine as? any LocationEngine, wake: { try? await vm.wake() },
                                  store: deps.paths.config.deletingLastPathComponent().appending(path: "location.json"))
    }

    /// Starts the event pumps. Call once after init.
    public func start() {
        guard !started else { return }
        started = true
        let vm = self.vm
        Task { [weak self] in
            for await event in vm.guestEvents { await self?.handleGuest(event) }
        }
        Task { [weak self] in
            for await status in vm.statusUpdates { await self?.vmStatusChanged(status) }
        }
        Task { [weak self] in
            for await _ in vm.factoryResets { await self?.androidAskedForFactoryReset() }
        }
        Task { [weak self] in
            for await _ in vm.reboots { await self?.androidRebooted() }
        }
        let fingerprints = self.fingerprints
        Task { [weak self] in
            for await status in fingerprints.updates { await self?.broadcast(.fingerprints(status), to: { $0 != .engine }) }
        }
        Task { [weak self] in
            guard let statuses = await self?.statusChanges() else { return }
            // A paused Android is still there: it wakes when a finger is asked for,
            // but not for the watcher's looks, or it would never stay paused.
            for await status in statuses {
                await fingerprints.androidChanged(status.isPaused ? .running : status.state)
                await fingerprints.androidPaused(status.isPaused)
            }
        }
        if let engine = deps.engine as? any ScreenLockEngine {
            let updates = engine.screenLockUpdates
            Task { [weak self] in
                for await lock in updates { await self?.screenLockChanged(lock) }
            }
        }
        // Android stopped answering (the Control Panel offers a Restart).
        if let engine = deps.engine as? any ResponsivenessEngine {
            let updates = engine.responsiveness
            Task {
                for await since in updates { await vm.setNotResponding(since: since) }
            }
        }
        // Before start, which already asks macOS: its answer reaches the Control Panel.
        deps.notifications.observePermission { [weak self] permission in
            Task { await self?.broadcast(.macNotifications(permission), to: { $0 == .controlPanel }) }
        }
        deps.notifications.observeDismissals { [weak self] key in
            Task { await self?.dismissNotifications([key]) }
        }
        deps.notifications.observeActions { [weak self] key, index, reply in
            Task { await self?.performNotificationAction(key: key, index: index, reply: reply) }
        }
        deps.nowPlaying.start { [weak self] command in
            Task { await self?.sendMediaCommand(command) }
        }
        deps.notifications.start { [weak self] package, key in
            Task { await self?.openNotification(package: package, key: key) }
        }
        shareClipboard(config.shareClipboard)
        if config.translationAtStartup { deps.screenText?.wake() }
        let adb = self.adb
        let config = self.config
        Task { await adb.update(enabled: config.adbEnabled, port: config.adbPort) }
        // Where Android's data is: found again (a renamed volume), and
        // guarded against an eject while Android uses it.
        let storage = self.storage
        Task { _ = await storage.status() }
        // What a restore or a move Avo did not see to its end left (DaemonStorageSafety.swift).
        startStorageSafety()
        if let volumes = deps.volumes {
            let volumeGuard = storage.volumeGuard
            volumes.start(refusal: { volumeGuard.refusal(for: $0) }) { [weak self] event in
                Task { await self?.volumeEvent(event) }
            }
        }
        // Every 4 s while Android runs, not paused: which apps have a process,
        // and the time the ones on screen are used. Nothing while it is not.
        Task { [weak self] in
            guard let statuses = await self?.statusChanges() else { return }
            for await status in statuses where status.state == .running {
                while await self?.vm.status.state == .running {
                    try? await Task.sleep(for: .seconds(4))
                    await self?.pollRunningApps()
                    await self?.usageTick()
                }
            }
        }
        startAutoPause()
        startLocation()
    }

    // MARK: App activity (Control Panel list, Dock-like states)

    func appActivity() -> [String: AppActivity] {
        var result: [String: AppActivity] = [:]
        for package in runningPackages { result[package] = .background }
        // A shim in the Dock without a window: the app waits in the background.
        for client in clients.values { if case .shim(let package) = client.role { result[package] = .background } }
        for display in displays.values {
            if display.visible {
                result[display.package] = .open
            } else if display.inBackground {
                // Sent to the background on purpose (a window's blue light): not minimized.
                if result[display.package] == nil { result[display.package] = .background }
            } else if result[display.package] != .open {
                result[display.package] = .minimized
            }
        }
        return result
    }

    private func publishActivity() {
        let now = appActivity()
        guard now != lastActivity else { return }
        lastActivity = now
        broadcast(.appActivity(now), to: isControlPanel)
    }

    /// Which installed apps have a process, while someone looks at the list
    /// (System Status' samples tell while it shows: `processesSampled`).
    private func pollRunningApps() async {
        guard !systemMonitor.hasFreshProcesses() else { return }
        // An Android that stopped answering is not asked again and again.
        guard clients.values.contains(where: { $0.role == .controlPanel }), await vm.status.state == .running,
              await !vm.status.isNotResponding, let adb = try? await vm.adbConnection(),
              let output = try? await adb.shell("ps -A -o NAME", timeout: .seconds(10)).output else { return }
        let packages = Set(await registry.all().map(\.package))
        runningPackages = Self.packages(inProcessList: output, among: packages)
        publishActivity()
    }

    /// The installed apps System Status found a process of (SystemMonitor.swift).
    func processesSampled(_ packages: Set<String>) {
        runningPackages = packages
        publishActivity()
    }

    /// `ps -A -o NAME`: processes are named after their package (or `package:service`).
    static func packages(inProcessList output: String, among packages: Set<String>) -> Set<String> {
        var running: Set<String> = []
        for line in output.split(separator: "\n") {
            let name = line.trimmingCharacters(in: .whitespaces)
            let package = name.split(separator: ":", maxSplits: 1).first.map(String.init) ?? name
            if packages.contains(package) { running.insert(package) }
        }
        return running
    }

    private var settings: VMManager.Settings {
        let profile = deps.profiles.profile(id: config.deviceProfileID)
        return VMManager.Settings(config: config, profile: profile, displayRate: FrameRates.androidRate(cap: config.fpsLimit),
                                  androidScreen: config.androidScreen(device: profile?.display, backingScale: Self.mainBackingScale))
    }

    /// A new window's backing scale: the Mac's main display's pixels per point.
    static var mainBackingScale: Double {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()), mode.width > 0 else { return 2 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    /// The frame rate cap needs Android at another display rate than it
    /// booted with (60 → 120 Hz, 120 → 75): Android's own display does not
    /// change rate while it runs. A cap that divides the rate applies live.
    private func frameRateNeedsRestart(_ fps: Int) -> Bool {
        bootedConfig != nil && FrameRates.needsRestart(cap: fps, running: bootedDisplayRate)
    }

    // MARK: Clients

    public func register(_ id: ClientID, role: ClientHello.Role, proxy: ClientProxy) async -> DaemonHello {
        clients[id] = Client(role: role, proxy: proxy)
        if role == .controlPanel {
            proxy.send(.appActivity(appActivity()))
            proxy.send(.notifications(recentNotifications))
            proxy.send(.widgets(placedWidgets))
            proxy.send(.macNotifications(await deps.notifications.permission()))
        } else {
            if case .shim = role, let audioTap { proxy.send(.audioTap(audioTap)) }
            if case .shim(let package) = role { proxy.send(.notificationCount(package: package, count: notificationCount(of: package))) }
            if role == .shim(package: AndroidWidgets.package) { proxy.send(.widgets(placedWidgets)) }
            publishActivity()
        }
        return DaemonHello(daemonVersion: deps.softwareVersion, status: await vm.status)
    }

    public func role(of id: ClientID) -> ClientHello.Role? { clients[id]?.role }

    public func disconnect(_ id: ClientID) async {
        clients[id] = nil
        locationWatchers.remove(id)
        if activityWatchers.remove(id) != nil { await updateSampling() }
        defer { publishActivity() }
        // A shim that quits (or crashes) closes its windows' displays. One
        // whose app Android is launching closes once it has (`openDisplay`):
        // stopped now, the app could still start after, and its display
        // closing then would put it on Android's own screen.
        for display in displays.values where display.owner == id && !display.opening {
            await closeDisplay(display.id, client: id)
        }
    }

    func broadcast(_ event: DaemonEvent, to filter: (ClientHello.Role) -> Bool = { _ in true }) {
        for client in clients.values where filter(client.role) { client.proxy.send(event) }
    }

    func send(_ event: DaemonEvent, toClient id: ClientID) {
        clients[id]?.proxy.send(event)
    }

    /// The Library's usage statistics (AppUsageRecorder.swift), for Control Panels.
    func publishUsage(_ usage: [AppUsage]) { broadcast(.appUsage(usage), to: isControlPanel) }

    func isControlPanel(_ role: ClientHello.Role) -> Bool { role == .controlPanel }

    /// Who hears `configurationChanged`: the Control Panel, and App Shims,
    /// whose windows follow graphics changes (the engine has no use for it).
    private func receivesConfiguration(_ role: ClientHello.Role) -> Bool { role != .engine }

    func requireControlPanel(_ id: ClientID) throws {
        guard clients[id]?.role == .controlPanel else { throw AvoError.unauthorizedCaller }
    }

    // MARK: VM

    public func status() async -> VMStatus { await vm.status }

    public func startVM(client: ClientID) async throws {
        try requireControlPanel(client)
        try await ensureRunning()
    }

    public func stopVM(client: ClientID) async throws {
        try requireControlPanel(client)
        try await clearForVMChange(.stop)
        await vm.stop(callingOffRestart: true)
    }

    public func restartVM(client: ClientID) async throws {
        try requireControlPanel(client)
        restartWork += 1
        defer { restartWork -= 1 }
        try await clearForVMChange(.restart)
        await vm.stop()
        try await ensureRunning()
    }

    /// Graphics › "Try GPU Again": forgets a failed GPU boot and restarts
    /// Android, which then tries the GPU once more.
    public func retryGPU(client: ClientID) async throws {
        try requireControlPanel(client)
        restartWork += 1
        defer { restartWork -= 1 }
        try await clearForVMChange(.restart)
        GPUFallbackRecord.remove(paths: deps.paths)
        (deps.engine as? any GPUFallbackEngine)?.forgetGPUCrashes()
        // A software start removed the gfxstream sync layer the GPU start names.
        await (deps.engine as? any GPULayerEngine)?.stageGPULayers(profile: false, gfxstreamSync: true)
        await vm.stop()
        try await ensureRunning()
    }

    /// The engine's GPU shader cache (`GPUCache`).
    public func gpuCacheStatus(client: ClientID) throws -> GPUCacheStatus {
        try requireControlPanel(client)
        return GPUCache.status(home: deps.paths.home)
    }

    /// Graphics › "Clear GPU cache": empties it whether or not Android runs
    /// (a running engine keeps what it has loaded until it stops).
    public func clearGPUCache(client: ClientID) throws -> GPUCacheStatus {
        try requireControlPanel(client)
        return try GPUCache.clear(home: deps.paths.home)
    }

    public func takeSnapshot(client: ClientID) async throws {
        try requireControlPanel(client)
        try await clearForVMChange(.snapshot)
        try await vm.takeSnapshot()
    }

    /// Sistem › Reset Android: wipes the data disk and snapshots, keeps the
    /// image. Google apps go with the data disk (their overlay lives there),
    /// so Settings › Google services goes back to None.
    public func resetAndroid(client: ClientID) async throws {
        try requireControlPanel(client)
        restartWork += 1
        defer { restartWork -= 1 }
        try await eraseAndroid()
    }

    /// Android's own factory reset (Settings › System › Reset options, or a
    /// device admin): avo-vmm stops instead of rebooting into recovery, which
    /// Avo does not have. Avo erases the data as Reset Android does and
    /// starts the fresh Android, as a phone comes back after its reset.
    func androidAskedForFactoryReset() async {
        restartWork += 1
        defer { restartWork -= 1 }
        await vm.restartTaken()
        do {
            // Android itself wants its data gone: an install of Google apps goes with it.
            try await eraseAndroid(force: true)
            try await ensureRunning(restarting: true)
        } catch is CancellationError {
            logger.notice("Android stays stopped after its factory reset: it was stopped meanwhile")
        } catch {
            logger.error("factory reset from Android: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Android rebooted itself (its Restart, `adb reboot`): avo-vmm ended, and
    /// the usual start brings the new boot up, prepared as every boot is
    /// (displays, location, the shared folder, audio, layers).
    func androidRebooted() async {
        restartWork += 1
        defer { restartWork -= 1 }
        await vm.restartTaken()
        if rootTrial { rootFailedToBoot() }
        // Rebooting again and again before it gets ready (the installer of
        // Google apps restarts Android itself, and has its own limits): it
        // stays stopped, and says so, instead of starting over for good.
        if googleAppsRun == nil, !reboots.reboot(at: .now) {
            reboots.ready()
            await vm.reportFailure(Self.keepsRestartingMessage)
            return
        }
        do {
            try await ensureRunning(restarting: true)
        } catch is CancellationError {
            logger.notice("Android stays stopped after its reboot: it was stopped meanwhile")
        } catch {
            logger.error("starting Android after its reboot: \(error.localizedDescription, privacy: .public)")
        }
    }

    static var keepsRestartingMessage: String {
        String(localized: "Android keeps restarting, so Avo stopped it. Start Android to try again.", bundle: .avoKit)
    }

    private func eraseAndroid(force: Bool = false) async throws {
        // Never Avo's side without the data itself (DaemonStorageSafety.swift).
        try await refuseEraseWithoutData()
        try await clearForVMChange(.reset, force: force)
        await vm.stop()
        // Its drive may have gone, or a move begun, while Android stopped.
        try await refuseEraseWithoutData()
        let left = try eraseAndroidData()
        publishCheckpoints()
        // Fingerprints live in Android's data (Settings › Fingerprints empties).
        await fingerprints.forget()
        usageForget(nil)
        if config.gms == .bringYourOwn {
            var new = config
            new.gms = .none
            apply(new)
        }
        for app in await registry.all() {
            deps.shortcuts.remove(app.shortcuts)
            await registry.remove(app.package)
            broadcast(.appRemoved(package: app.package))
        }
        if let error = Self.resetLeftovers(left) { throw error }
    }

    /// Start Android from the daemon's own menu bar item (same process, no XPC caller).
    public func startVMFromMenuBar() async throws {
        try await ensureRunning()
    }

    /// The menu bar's Stop Android. Refused while Google apps change Android,
    /// unless `force` (the user chose Stop Anyway): the next start then
    /// finishes or takes out that install.
    public func stopVMFromMenuBar(force: Bool = false) async throws {
        try await clearForVMChange(.stop, force: force)
        await vm.stop(callingOffRestart: true)
    }

    /// Quit Avo from the menu bar: stops an install that has not changed
    /// Android yet, then Android. Refused like `stopVMFromMenuBar`.
    public func quitFromMenuBar(force: Bool = false) async throws {
        try await clearForVMChange(.stop, force: force)
        if let run = googleAppsRun, googleAppsCancellable {
            googleAppsCancelRequested = true
            run.cancel()
        }
        await vm.stop(callingOffRestart: true)
    }

    /// Whether Google apps change Android now, and how (stop, restart and
    /// reset wait; nil when not), then every change.
    public func googleAppsBusyChanges() -> AsyncStream<GoogleAppsWork?> {
        let (stream, continuation) = AsyncStream.makeStream(of: GoogleAppsWork?.self, bufferingPolicy: .bufferingNewest(4))
        let id = UUID()
        googleAppsBusyObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeGoogleAppsBusyObserver(id) } }
        continuation.yield(googleAppsWork)
        return stream
    }

    private func removeGoogleAppsBusyObserver(_ id: UUID) {
        googleAppsBusyObservers[id] = nil
    }

    private var googleAppsBusy: Bool { googleAppsRun != nil && !googleAppsCancellable }

    private var googleAppsWork: GoogleAppsWork? {
        googleAppsBusy ? (googleAppsRemoving ? .removing : .installing) : nil
    }

    private func publishGoogleAppsBusy() {
        let work = googleAppsWork
        guard work != lastGoogleAppsBusy else { return }
        lastGoogleAppsBusy = work
        for observer in googleAppsBusyObservers.values { observer.yield(work) }
    }

    /// Stop, restart, snapshot and reset while Google apps install (GoogleAppsGuard).
    func clearForVMChange(_ action: GoogleAppsGuard.Action, force: Bool = false) async throws {
        switch GoogleAppsGuard.decide(action, installing: googleAppsRun != nil, cancellable: googleAppsCancellable, force: force) {
        case .allow:
            if googleAppsBusy {
                logger.notice("Android stopped by force while Google apps were being installed")
                googleAppsInterrupted = true
            }
        case .cancelInstall:
            googleAppsCancelRequested = true
            googleAppsRun?.cancel()
            _ = await googleAppsRun?.result
        case .refuse:
            throw AvoError.internalError(GoogleAppsGuard.refusal)
        }
    }

    /// `restarting`: Android's start again after its own reboot or reset,
    /// which a stop since then calls off (VMManager.ensureRunning).
    func ensureRunning(restarting: Bool = false) async throws {
        starting += 1
        defer { starting -= 1 }
        try refuseWhileExiting()
        if storageChanging { throw AvoError.storage(.changing) }
        // A commit Avo did not see to its end (it quit, or Android was
        // stopped by force): finished or taken out before anything else.
        if googleAppsRecovering, let run = googleAppsRun { _ = await run.result }
        // The installer starts and stops Android itself meanwhile; a start
        // from here could kill the VM a rescue is repairing over adbd.
        if googleAppsBusy, await vm.status.state != .running {
            throw AvoError.internalError(GoogleAppsGuard.refusal)
        }
        if googleAppsRun == nil, let journal = GoogleAppsJournal.load(deps.paths) {
            if let engine = deps.engine as? any SystemAppsEngine {
                try await recoverGoogleApps(journal, engine: engine)
            } else {
                GoogleAppsJournal.remove(deps.paths)
            }
        }
        try await bootVM(restarting: restarting)
    }

    private func bootVM(restarting: Bool = false) async throws {
        starting += 1
        defer { starting -= 1 }
        try refuseWhileExiting()
        await checkpointBeforeNewerAndroid()
        let settings = self.settings
        try await vm.ensureRunning(settings, restarting: restarting)
        if bootedConfig == nil {
            bootedConfig = settings.config
            bootedDisplayRate = settings.displayRate
        }
    }

    // MARK: The Mac's sleep

    /// The Mac woke (NSWorkspace.didWakeNotification): Android's clock stood
    /// still while it slept, and is put right as after a pause. A paused
    /// Android's pause counts the sleep too: it is put right as it goes on.
    public func macWoke() async {
        await macWoke(slept: macSleep.slept())
    }

    func macWoke(slept: Duration) async {
        guard slept >= .seconds(1), await vm.status.state == .running,
              let engine = deps.engine as? any SleepingClockEngine else { return }
        logger.notice("the Mac slept \(slept, privacy: .public) with Android running: its clock is put right")
        await engine.macSlept(for: slept)
    }

    // MARK: Updates (AppUpdateWatcher)

    /// Whether this daemon may end now to restart on an updated Avo: Android
    /// holds nothing, and nothing is about to start it, change it or need it
    /// (a start, a restart, a reboot of Android's own, Google apps, a move of
    /// its data, an install, root). Once it may, nothing starts Android any
    /// more: the new daemon does.
    public func claimRestartForUpdate() async -> Bool {
        guard !exitingForUpdate else { return true }
        guard await vm.holdsNothing, restartWork == 0, starting == 0, googleAppsRun == nil, !storageChanging,
              autoPause.installs == 0, rootRun == nil else { return false }
        exitingForUpdate = true
        // A start that went all the way while the engine was asked.
        guard await vm.holdsNothing else {
            exitingForUpdate = false
            return false
        }
        return true
    }

    static var restartingForUpdateMessage: String {
        String(localized: "Avo is restarting to finish its update. Try again in a moment.", bundle: .avoKit)
    }

    private func refuseWhileExiting() throws {
        if exitingForUpdate { throw AvoError.internalError(Self.restartingForUpdateMessage) }
        if exiting { throw AvoError.internalError(String(localized: "Avo is quitting.", bundle: .avoKit)) }
    }

    /// The daemon ends (the Mac logs out or shuts down, its agent is
    /// stopped): Android powers off first, as with Quit Avo, also while
    /// Google apps change it (the next start sees that through), so what it
    /// has not written yet is not lost. Returns by `limit` at the latest:
    /// launchd ends the daemon by force a little later, and avo-vmm powers
    /// Android off by itself once the daemon is gone. Nothing starts Android after.
    public func powerOffForExit(within limit: Duration) async {
        exiting = true
        logger.notice("the daemon ends: powering Android off")
        _ = try? await Deadline.run(limit, what: "power off") { [weak self] in try await self?.quitFromMenuBar(force: true) }
    }

    /// The VM status now, then every change.
    public func statusChanges() async -> AsyncStream<VMStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: VMStatus.self, bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        statusObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeStatusObserver(id) } }
        continuation.yield(await vm.status)
        return stream
    }

    private func removeStatusObserver(_ id: UUID) {
        statusObservers[id] = nil
    }

    /// The configuration now, then every saved change (in-process watchers).
    public func configChanges() -> AsyncStream<VMConfig> {
        let (stream, continuation) = AsyncStream.makeStream(of: VMConfig.self, bufferingPolicy: .bufferingNewest(4))
        let id = UUID()
        configObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeConfigObserver(id) } }
        continuation.yield(config)
        return stream
    }

    private func removeConfigObserver(_ id: UUID) {
        configObservers[id] = nil
    }

    private func vmStatusChanged(_ status: VMStatus) async {
        broadcast(.vmStatus(status))
        for observer in statusObservers.values { observer.yield(status) }
        // Android's disks are open from the start until the engine stopped.
        storage.volumeGuard.setAndroidActive(status.state != .stopped && status.state != .notInstalled)
        // Back from a pause, Android is as it was: no new start to catch up on.
        let resumed = autoPause.wasPaused && status.state == .running
        autoPause.wasPaused = status.isPaused
        androidAwake = status.state == .running
        watchClipboard(fresh: !resumed)
        switch status.state {
        case .running:
            guard !resumed else {
                await androidResumed()
                break
            }
            // Ready: its reboots from now on count anew.
            reboots.ready()
            switch startSync.work(for: status) {
            case .start:
                await syncApps()
                // Android keeps the cap in its settings: this start follows the
                // configuration, also one changed while Android was stopped.
                await applyFrameRateLimit(config.fpsLimit)
                rootIfAsked()
                storageCheckedAt = nil
                _ = await dataDiskStatus()
                Task { await refreshWidgetRules() }
            case .apps:
                await syncApps()
                Task { await refreshWidgetRules() }
            case .none:
                break
            }
        case .starting, .stopping:
            startSync = StartSync()
        case .stopped, .failed, .notInstalled:
            startSync = StartSync()
            bootedConfig = nil
            for display in displays.values { clients[display.owner]?.proxy.send(.displayClosed(displayID: display.id)) }
            usageWindowsClosed()
            displays.removeAll()
            runningPackages.removeAll()
            publishActivity()
            // Android's notifications went with it; the next start reports them again.
            setActiveNotifications { $0.removeAll() }
            // And what it played.
            nowPlayingArtwork = nil
            deps.nowPlaying.show(nil, appName: "", artwork: nil)
        default:
            break
        }
    }

    /// After boot, the guest's package list is authoritative.
    private func syncApps() async {
        guard let control = try? await vm.controlSession(),
              let apps = try? await control.listApps(includeIcons: true) else { return }
        for info in apps where info.launchable {
            await appInstalled(info, replacing: false, announce: false)
        }
        // An app goes only with its package. One Android has but cannot open
        // right now (its launcher activity does not resolve, as while a
        // screen lock keeps Android locked) keeps its record and shim.
        let installed = Set(apps.map(\.package))
        let known = await registry.all()
        if installed.isEmpty, !known.isEmpty {
            // Every app gone at once is a listing that failed, not uninstalls.
            logger.error("Android listed no apps; keeping the \(known.count) Avo has")
        } else {
            for gone in await registry.retain(only: installed) {
                deps.shortcuts.remove(gone.shortcuts)
            }
        }
        let all = await registry.all()
        for app in all { broadcast(.appInstalled(app), to: isControlPanel) }
    }

    // MARK: Configuration

    public func configurationSnapshot() async -> ConfigurationSnapshot {
        let adbStatus: ADBStatus? = switch await adb.state {
        case .off: nil
        case .listening(let port): ADBStatus(port: port)
        case let .failed(port, problem): ADBStatus(port: port, problem: problem)
        }
        let games = await registry.all().filter { $0.isGame == true }
        return ConfigurationSnapshot(config: config, host: deps.host, profiles: deps.profiles.profiles,
                                     pendingRestart: (bootedConfig.map { config.effect(of: $0) == .restartRequired } ?? false)
                                         || frameRateNeedsRestart(config.fpsLimit),
                                     adb: adbStatus, dataDisk: await dataDiskStatus(), storageLocation: await storage.status(),
                                     sharedFolder: await sharedFolderStatus(),
                                     games: Set(games.map(\.package)),
                                     gameOrientations: Dictionary(uniqueKeysWithValues: games.compactMap { app in
                                         app.orientation.map { (app.package, $0) }
                                     }))
    }

    public func updateConfiguration(_ new: VMConfig, client: ClientID) async throws -> ConfigUpdateResult {
        try requireControlPanel(client)
        // Overrides change only through setAppGraphics: the panel's copy may
        // predate a change an app's window just made.
        var new = new
        new.graphicsOverrides = config.graphicsOverrides
        // This update cannot change the overrides, so one a hand edit made
        // invalid must not refuse it either (setAppGraphics fixes that one).
        var issues = new.validate(previous: config, host: deps.host).filter { !$0.field.hasPrefix("graphicsOverrides.") }
        if deps.profiles.profile(id: new.deviceProfileID) == nil {
            issues.append(ConfigIssue(field: "deviceProfileID", severity: .error, message: String(localized: "Unknown device profile.", bundle: .avoKit)))
        }
        // Android's storage keeps the size it was created with (DataDiskStatus).
        if let issue = DataDiskStore.sizeChangeIssue(from: config, to: new, status: DataDiskStore(paths: deps.paths).status()) {
            issues.append(issue)
        }
        var effect = new.effect(of: config)
        if new.fpsLimit != config.fpsLimit, frameRateNeedsRestart(new.fpsLimit) { effect = .restartRequired }
        guard !issues.contains(where: { $0.severity == .error }) else {
            return ConfigUpdateResult(effect: effect, issues: issues)
        }
        // Root on or another phone: Android's data as it is now is kept first.
        if let reason = Self.checkpointReason(from: config, to: new) {
            await autoCheckpoint(reason)
            new.graphicsOverrides = config.graphicsOverrides
        }
        let old = config
        config = new
        try new.save(to: deps.paths.config)

        // A Renderer change gives the GPU a new try at the next start.
        if new.rendererMode != old.rendererMode {
            GPUFallbackRecord.remove(paths: deps.paths)
            (deps.engine as? any GPUFallbackEngine)?.forgetGPUCrashes()
        }
        // The GPU layers the next start names go in now, so the restart these
        // settings need begins with them; the ones it drops go at that start.
        if new.emulateHardware != old.emulateHardware || new.deviceProfileID != old.deviceProfileID
            || new.rendererMode != old.rendererMode, let engine = deps.engine as? any GPULayerEngine {
            let profile = deps.profiles.profile(id: new.deviceProfileID)
            await engine.stageGPULayers(profile: GuestGPUProfile.emulatesGPU(profile, emulateHardware: new.emulateHardware),
                                        gfxstreamSync: new.rendererMode != .software)
        }
        if new.fpsLimit != old.fpsLimit { await applyFrameRateLimit(new.fpsLimit) }
        if new.adbEnabled != old.adbEnabled || new.adbPort != old.adbPort {
            await adb.update(enabled: new.adbEnabled, port: new.adbPort)
        }
        // Root on: Android starts again with Magisk at once (off waits for the next start).
        if new.rooted, !old.rooted { rootIfAsked() }
        // Settings › Devices: the running Android follows at once (a
        // camera it has shows its new source; other camera changes wait for
        // the next start).
        if new.shareClipboard != old.shareClipboard { shareClipboard(new.shareClipboard) }
        // Settings › General › Translate Screen: turned on, the engine gets ready now.
        if new.translationAtStartup, !old.translationAtStartup { deps.screenText?.wake() }
        if new.wifiEnabled != old.wifiEnabled || new.networkSpeed != old.networkSpeed || new.shareMacBluetooth != old.shareMacBluetooth
            || new.cellularCommand != old.cellularCommand || new.cameraSources != old.cameraSources
            || new.microphoneEnabled != old.microphoneEnabled,
           let engine = deps.engine as? any DeviceSettingsEngine {
            await engine.applyDeviceSettings(new)
        }
        if new.createDesktopAlias != old.createDesktopAlias || new.addToDock != old.addToDock {
            await rebuildShortcuts(of: nil, for: new)
        }
        publish(new)
        return ConfigUpdateResult(effect: effect, issues: issues)
    }

    /// Sets (nil or empty removes) one app's graphics override, for the
    /// Control Panel or that app's own shim. Only this override is
    /// validated, so a setting that became invalid elsewhere (more memory
    /// than this Mac can give, after moving to another Mac) never blocks it.
    public func setAppGraphics(_ package: String, _ change: AppGraphicsOverride?, client: ClientID) throws -> ConfigUpdateResult {
        if case .shim(package)? = clients[client]?.role {} else { try requireControlPanel(client) }
        let issues = change?.changes.validate(field: "graphicsOverrides.\(package)") ?? []
        guard !issues.contains(where: { $0.severity == .error }) else { return ConfigUpdateResult(effect: .immediate, issues: issues) }
        var new = config
        new.graphicsOverrides[package] = (change?.isEmpty ?? true) ? nil : change
        guard new != config else { return ConfigUpdateResult(effect: .immediate, issues: issues) }
        try new.save(to: deps.paths.config)
        config = new
        publish(new)
        return ConfigUpdateResult(effect: .immediate, issues: issues)
    }

    /// Sets Android's frame rate cap and nothing else, for the Control Panel
    /// or any App Shim (a window's settings overlay): the cap is Android's,
    /// the same in every app, and applies at once, unless it needs another
    /// display rate (`.restartRequired`; frameRateNeedsRestart). Only the
    /// cap is validated, as in setAppGraphics; the engine may not change it.
    public func setFrameRateLimit(_ fps: Int, client: ClientID) async throws -> ConfigUpdateResult {
        switch clients[client]?.role {
        case .controlPanel?, .shim?: break
        default: throw AvoError.unauthorizedCaller
        }
        var new = config
        new.fpsLimit = fps
        let issues = new.validate(previous: config, host: deps.host).filter { $0.field == "fpsLimit" }
        guard !issues.contains(where: { $0.severity == .error }), new != config else {
            return ConfigUpdateResult(effect: .immediate, issues: issues)
        }
        try new.save(to: deps.paths.config)
        config = new
        publish(new)
        await applyFrameRateLimit(fps)
        return ConfigUpdateResult(effect: frameRateNeedsRestart(fps) ? .restartRequired : .immediate, issues: issues)
    }

    /// Hands Android its frame rate cap (HostAgent: `peak_refresh_rate`).
    private func applyFrameRateLimit(_ fps: Int) async {
        guard let control = try? await vm.controlSession() else { return }
        var request = Avo_V1_SetRefreshRate()
        request.fps = UInt32(fps)
        _ = try? await control.request(.setRefreshRate(request))
    }

    /// Android's storage for Settings › Storage: asked again from Android
    /// while it runs and answers (at most every 15 s), else what it said
    /// last. Every Control Panel and new window waits for it.
    private func dataDiskStatus() async -> DataDiskStatus {
        let store = DataDiskStore(paths: deps.paths)
        let status = await vm.status
        if status.state == .running, !status.isNotResponding, let engine = deps.engine as? any GuestStorageEngine,
           storageCheckedAt.map({ ContinuousClock.now - $0 > .seconds(15) }) ?? true {
            storageCheckedAt = .now
            if let storage = await engine.androidStorage() { store.remember(storage) }
        }
        return store.status()
    }

    /// Tells every client and in-process watcher about a saved configuration.
    private func publish(_ new: VMConfig) {
        broadcast(.configurationChanged(new), to: receivesConfiguration)
        for observer in configObservers.values { observer.yield(new) }
    }

    // MARK: Apps

    public func apps() async -> [AppRecord] { await registry.all() }

    public func icon(for package: String) async -> Data? { await registry.icon(for: package) }

    public func install(_ request: InstallRequest, file: OwnedDescriptor, client: ClientID) async throws {
        try requireControlPanel(client)
        autoPause.installs += 1
        defer { autoPause.installs -= 1 }
        let proxy = clients[client]?.proxy
        let vm = self.vm
        let settings = self.settings
        do {
            let package = try await InstallPipeline().run(
                request, file: file,
                ensureRunning: { [weak self] in
                    // Through the core: an interrupted Google apps commit
                    // is seen through before Android boots with it.
                    if let self {
                        try await self.ensureRunning()
                    } else {
                        try await vm.ensureRunning(settings)
                    }
                },
                adb: { try await vm.adbConnection() },
                report: { proxy?.send(.installProgress($0)) })
            proxy?.send(.installProgress(InstallProgress(id: request.id, phase: .creatingShortcuts, package: package)))
            proxy?.send(.installProgress(InstallProgress(id: request.id, phase: .finished, fraction: 1, package: package)))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            proxy?.send(.installProgress(InstallProgress(id: request.id, phase: .failed, message: message)))
            throw error
        }
    }

    public func uninstall(_ package: String, client: ClientID) async throws {
        try requireControlPanel(client)
        // `pm uninstall` cannot take out a system app (the Play Store, the
        // Google app): it fails, or only removes the app's own update.
        if let record = await registry.record(package), record.systemApp {
            throw AvoError.internalError(String(localized: "\(record.displayName) is part of Android’s system apps and cannot be uninstalled. Reset Android removes Google apps.",
                                                bundle: .avoKit))
        }
        var request = Avo_V1_Uninstall()
        request.package = package
        try await vm.controlSession().request(.uninstall(request))
    }

    public func forceStop(_ package: String, client: ClientID) async throws {
        // The Control Panel, or the app's own shim when it quits (Dock › Quit).
        if case .shim(package)? = clients[client]?.role {} else { try requireControlPanel(client) }
        var request = Avo_V1_ForceStop()
        request.package = package
        try await vm.controlSession().request(.forceStop(request))
        // Stopped from the Control Panel: the app leaves the Dock too, like
        // swiping it away on a phone, and stops counting as running.
        for other in clients.values {
            if case .shim(package) = other.role { other.proxy.send(.appStopped(package: package)) }
        }
        runningPackages.remove(package)
        publishActivity()
    }

    public func deleteAppData(_ package: String, client: ClientID) async throws {
        try requireControlPanel(client)
        var request = Avo_V1_DeleteAppData()
        request.package = package
        try await vm.controlSession().request(.deleteAppData(request))
    }

    public func permissions(for package: String, client: ClientID) async throws -> [AppPermission] {
        try requireControlPanel(client)
        return try await vm.controlSession().permissions(for: package).map {
            AppPermission(name: $0.name, label: $0.label, granted: $0.granted, runtime: $0.runtime)
        }
    }

    public func setPermission(_ permission: String, granted: Bool, for package: String, client: ClientID) async throws {
        try requireControlPanel(client)
        var request = Avo_V1_SetPermission()
        request.package = package
        request.permission = permission
        request.granted = granted
        try await vm.controlSession().request(.setPermission(request))
    }

    public func recreateShortcuts(for package: String?, client: ClientID) async throws {
        try requireControlPanel(client)
        await rebuildShortcuts(of: package.map { [$0] }, for: config)
    }

    /// Makes the shortcuts of these apps (every app's: nil) again for
    /// `config`, one app after another off this actor: each copies its shim
    /// and waits for codesign, and frames and input pass through here
    /// meanwhile. The Dock restarts once at the end, not once an app. One
    /// batch at a time, in the order asked.
    private func rebuildShortcuts(of packages: Set<String>?, for config: VMConfig) async {
        let previous = shortcutRebuild
        let batch = Task { [weak self] in
            await previous?.value
            await self?.performShortcutRebuild(of: packages, for: config)
        }
        shortcutRebuild = batch
        await batch.value
    }

    private func performShortcutRebuild(of packages: Set<String>?, for config: VMConfig) async {
        var dockChanged = false
        for app in await registry.all() where packages?.contains(app.package) ?? true {
            let changed = await serializedShimBuild(app.package) { [weak self] in
                await self?.remakeShortcuts(of: app.package, for: config) ?? false
            }
            dockChanged = dockChanged || changed
        }
        if dockChanged { Shortcuts.restartDock() }
    }

    /// One app's shortcuts made again for `config`, from its record as the
    /// builds before left it; whether its Dock tile came or went.
    private func remakeShortcuts(of package: String, for config: VMConfig) async -> Bool {
        guard let app = await registry.record(package) else { return false }
        let shortcuts = deps.shortcuts
        let made = await Task.detached { shortcuts.apply(app, info: nil, config: config, restartDock: false) }.value
        // Uninstalled meanwhile: what was made for it goes too.
        guard var current = await registry.record(package) else {
            shortcuts.remove(made)
            return false
        }
        current.shortcuts = made
        await registry.update(current)
        return made.inDock != app.shortcuts.inDock
    }

    /// Runs `build` once the shim builds of `package` asked before it have
    /// ended. Two at once could swap their shims in one order and record
    /// their hashes in the other: the hash the daemon lets the shim in by
    /// (`shimHashes`) would then be the one of a shim no longer on disk.
    private func serializedShimBuild<T: Sendable>(_ package: String, _ build: @escaping @Sendable () async -> T) async -> T {
        let previous = shimBuilds[package]
        let task = Task {
            await previous?.value
            return await build()
        }
        let done = Task { _ = await task.value }
        shimBuilds[package] = done
        defer { if shimBuilds[package] == done { shimBuilds[package] = nil } }
        return await task.value
    }

    /// Code directory hashes of every shim the daemon created (XPC caller check).
    public func shimHashes() async -> [String: String] {
        var result: [String: String] = [:]
        for app in await registry.all() {
            if let hash = app.shortcuts.shimCDHash { result[app.package] = hash }
        }
        return result
    }

    // MARK: Google apps (Settings › System, spec: Strategi GMS)

    public func googleAppsStatus(client: ClientID) async throws -> GoogleAppsStatus {
        try requireControlPanel(client)
        guard let engine = deps.engine as? any SystemAppsEngine else { return GoogleAppsStatus(supported: false) }
        var status = GoogleAppsStatus(supported: true)
        let android = await vm.status
        if android.state == .running, !android.isNotResponding, let guest = try? await engine.systemApps() {
            status = await guest.googleAppsStatus()
            // Installed before Avo kept the record: the Android running now has them.
            if status.installed == true, googleAppsRun == nil, GoogleAppsRecord.load(deps.paths) == nil {
                try? GoogleAppsRecord(android: AndroidImageStore(paths: deps.paths).bootRecord()?.release).save(deps.paths)
            }
        }
        status.progress = googleAppsRun == nil ? nil : googleAppsProgress
        return status
    }

    /// Installs a MindTheGapps package from the cache (the Control Panel's
    /// copy of a file the user chose) or from a GitHub release. Progress goes
    /// to every Control Panel; Android restarts up to three times.
    public func installGoogleApps(_ request: GoogleAppsInstallRequest, client: ClientID) async throws {
        try requireControlPanel(client)
        let cache = deps.paths.googleAppsCache
        // Stopped while the request was on its way.
        if cancelledGoogleApps.remove(request.id) != nil {
            if case .local(let path) = request.source, let copy = try? Self.cachedItem(path, in: cache) { Self.removeCopy(copy, cache: cache) }
            let progress = GoogleAppsProgress(id: request.id, phase: .cancelled, message: Self.googleAppsCancelledMessage)
            publishGoogleApps(progress)
            throw AvoError.internalError(Self.googleAppsCancelledMessage)
        }
        guard googleAppsRun == nil else {
            throw AvoError.installFailed(String(localized: "Google apps are already being installed.", bundle: .avoKit))
        }
        var copy: URL?
        if case .local(let path) = request.source { copy = try Self.cachedItem(path, in: cache) }
        Self.pruneCopies(in: cache, keeping: copy)
        defer { if let copy { Self.removeCopy(copy, cache: cache) } }
        guard let engine = deps.engine as? any SystemAppsEngine else {
            throw AvoError.unsupportedPackage(String(localized: "This Android image cannot take Google apps.", bundle: .avoKit))
        }
        // Only the installer sets it, once Android lists Google Play (the
        // installer also asks Android's own list).
        guard config.gms != .bringYourOwn else { throw AvoError.internalError(GoogleAppsInstaller.alreadyInstalled) }
        // Those of another Android version are still on its storage, unused
        // (GoogleAppsRecord): a package over them could not be undone.
        if let record = GoogleAppsRecord.load(deps.paths) {
            throw AvoError.internalError(GoogleAppsInstaller.leftOver(record.android))
        }
        if GoogleAppsJournal.load(deps.paths) != nil {
            // An interrupted commit is seen through first (kept or taken
            // out), so the new install starts from an Android Avo knows.
            try await ensureRunning()
            guard cancelledGoogleApps.remove(request.id) == nil else {
                publishGoogleApps(GoogleAppsProgress(id: request.id, phase: .cancelled, message: Self.googleAppsCancelledMessage))
                throw AvoError.internalError(Self.googleAppsCancelledMessage)
            }
            guard googleAppsRun == nil else {
                throw AvoError.installFailed(String(localized: "Google apps are already being installed.", bundle: .avoKit))
            }
        }
        // Android as it is without them, to go back to (they change its system partitions).
        await autoCheckpoint(.googleApps)
        guard cancelledGoogleApps.remove(request.id) == nil else {
            publishGoogleApps(GoogleAppsProgress(id: request.id, phase: .cancelled, message: Self.googleAppsCancelledMessage))
            throw AvoError.internalError(Self.googleAppsCancelledMessage)
        }
        guard googleAppsRun == nil else {
            throw AvoError.installFailed(String(localized: "Google apps are already being installed.", bundle: .avoKit))
        }
        let local = copy
        try await superviseGoogleApps(request.id, cancellable: true) { [weak self] report in
            guard let self else { return nil }
            return try await self.runGoogleApps(request, engine: engine, local: local, report: report)
        }
    }

    /// Stops the install `id` (any, when nil) while it is still preparing or
    /// downloading. One whose request has not arrived yet is refused when it does.
    public func cancelGoogleApps(_ id: UUID? = nil, client: ClientID) async throws {
        try requireControlPanel(client)
        guard let run = googleAppsRun, id == nil || id == googleAppsRunID else {
            if let id {
                if cancelledGoogleApps.count > 16 { cancelledGoogleApps.removeAll() }
                cancelledGoogleApps.insert(id)
            }
            return
        }
        guard googleAppsCancellable else {
            throw AvoError.installFailed(String(localized: "Android is already being changed; the install can no longer stop.", bundle: .avoKit))
        }
        googleAppsCancelRequested = true
        run.cancel()
    }

    static var googleAppsCancelledMessage: String {
        String(localized: "Install stopped. Android was not changed.", bundle: .avoKit)
    }

    /// Remove (Settings › Google Apps): takes the Google apps Avo installed
    /// out of Android's system partitions and uninstalls what Google Play's
    /// updates left of them, keeping every other app and its data. Android
    /// restarts once (not at all when the files were gone already). Progress
    /// goes to every Control Panel, as an install's does.
    public func removeGoogleApps(_ id: UUID, client: ClientID) async throws {
        try requireControlPanel(client)
        guard googleAppsRun == nil else { throw AvoError.installFailed(Self.googleAppsBusyMessage) }
        guard let engine = deps.engine as? any SystemAppsEngine else {
            throw AvoError.unsupportedPackage(String(localized: "This Android image cannot take Google apps.", bundle: .avoKit))
        }
        // Those of another Android version are on storage this Android does
        // not mount: only Reset Android takes them out.
        if let installed = GoogleAppsRecord.load(deps.paths)?.android,
           let running = AndroidImageStore(paths: deps.paths).bootRecord()?.release, installed.version != running.version {
            throw AvoError.internalError(GoogleAppsInstaller.leftOver(installed))
        }
        if GoogleAppsJournal.load(deps.paths) != nil {
            // An interrupted install or Remove is seen through first.
            try await ensureRunning()
            guard googleAppsRun == nil else { throw AvoError.installFailed(Self.googleAppsBusyMessage) }
        }
        await autoCheckpoint(.googleAppsRemoval)
        guard googleAppsRun == nil else { throw AvoError.installFailed(Self.googleAppsBusyMessage) }
        do {
            try await superviseGoogleApps(id, cancellable: false, removal: true) { [weak self] report in
                guard let installer = await self?.googleAppsInstaller(id, engine: engine, report: report) else { return nil }
                try await installer.remove()
                return nil
            }
        } catch GoogleAppsRemovalError.stillListed {
            // Nothing for the next start to finish.
            GoogleAppsJournal.remove(deps.paths)
            throw GoogleAppsRemovalError.stillListed
        }
    }

    static var googleAppsBusyMessage: String {
        String(localized: "Avo is already changing Google apps.", bundle: .avoKit)
    }

    /// Runs an install, a Remove or a recovery (one at a time), publishing
    /// its progress in order and how it ended.
    private func superviseGoogleApps(_ id: UUID, cancellable: Bool, recovering: Bool = false, removal: Bool = false,
                                     _ body: @escaping @Sendable (@escaping GoogleAppsInstaller.Report) async throws -> URL?) async throws {
        // Progress from download and push callbacks, published in order.
        let (updates, sink) = AsyncStream.makeStream(of: GoogleAppsProgress.self)
        let pump = Task { [weak self] in
            for await progress in updates { await self?.publishGoogleApps(progress) }
        }
        let report: GoogleAppsInstaller.Report = { sink.yield($0) }
        googleAppsCancellable = cancellable
        googleAppsCancelRequested = false
        googleAppsInterrupted = false
        googleAppsRecovering = recovering
        googleAppsRemoving = removal
        googleAppsRunID = id
        let task = Task { try await body(report) }
        googleAppsRun = task
        defer {
            googleAppsRun = nil
            googleAppsRunID = nil
            googleAppsRecovering = false
            googleAppsRemoving = false
            googleAppsCancellable = false
            googleAppsInterrupted = false
            googleAppsCancelRequested = false
        }
        let outcome = await task.result
        sink.finish()
        await pump.value
        switch outcome {
        case .success(let download):
            // Kept after a failure, so trying again does not download it again.
            if let download { try? FileManager.default.removeItem(at: download) }
            publishGoogleApps(GoogleAppsProgress(id: id, phase: .finished, fraction: 1, removal: removal))
        case .failure(let error):
            var progress = Self.googleAppsEnd(error, id: id, cancelRequested: googleAppsCancelRequested)
            progress.removal = removal
            logger.error("Google apps: \(progress.message ?? "", privacy: .public)")
            publishGoogleApps(progress)
            throw error is CancellationError ? AvoError.internalError(progress.message ?? "") : error
        }
    }

    /// How a run that threw is shown: the user's own stop before Android
    /// changed is not an error; any other stop is.
    static func googleAppsEnd(_ error: any Error, id: UUID, cancelRequested: Bool) -> GoogleAppsProgress {
        if error is CancellationError {
            return cancelRequested
                ? GoogleAppsProgress(id: id, phase: .cancelled, message: googleAppsCancelledMessage)
                : GoogleAppsProgress(id: id, phase: .failed, message: String(localized: "Google apps were not installed: Android was stopped during the install.", bundle: .avoKit))
        }
        return GoogleAppsProgress(id: id, phase: .failed, message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
    }

    /// Returns the download to delete once installed.
    private func runGoogleApps(_ request: GoogleAppsInstallRequest, engine: any SystemAppsEngine, local: URL?,
                               report: @escaping GoogleAppsInstaller.Report) async throws -> URL? {
        let id = request.id
        report(GoogleAppsProgress(id: id, phase: .preparing))
        let file: URL
        var download: URL?
        switch request.source {
        case .local:
            guard let local else { throw AvoError.internalError("no package") }
            file = local
        case .github(let link):
            let downloader = GoogleAppsDownloader(directory: deps.paths.googleAppsCache.appending(path: "downloads", directoryHint: .isDirectory))
            file = try await downloader.download(link, verifying: { report(GoogleAppsProgress(id: id, phase: .verifying)) }) { received, total in
                report(GoogleAppsProgress(id: id, phase: .downloading, fraction: total == 0 ? nil : min(1, Double(received) / Double(total))))
            }
            download = file
            report(GoogleAppsProgress(id: id, phase: .preparing))
        }
        try Task.checkCancellation()
        let package: GoogleAppsPackage
        do {
            package = try await Task.detached { try GoogleAppsPackage(url: file) }.value
        } catch let error as GoogleAppsError {
            throw AvoError.unsupportedPackage(error.localizedDescription)
        } catch let error as PackageError {
            throw AvoError.unsupportedPackage(error.localizedDescription)
        }
        try Task.checkCancellation()

        // From here on Android changes, so the rest runs to its end: a task
        // of its own, which cancelling this one does not reach. Stopping,
        // restarting and resetting Android wait meanwhile (clearForVMChange).
        googleAppsCancellable = false
        let installer = googleAppsInstaller(id, engine: engine, report: report)
        try await Task { try await installer.run(package) }.value
        return download
    }

    /// Finishes or takes out a commit Avo did not see to its end, before
    /// Android is used again.
    private func recoverGoogleApps(_ journal: GoogleAppsJournal, engine: any SystemAppsEngine) async throws {
        let id = journal.id
        if let system = journal.systemPackages {
            logger.notice("Google apps: finishing an interrupted Remove")
            do {
                try await superviseGoogleApps(id, cancellable: false, recovering: true, removal: true) { [weak self] report in
                    guard let installer = await self?.googleAppsInstaller(id, engine: engine, report: report) else { return nil }
                    try await installer.finishRemoval(Set(system))
                    return nil
                }
            } catch GoogleAppsRemovalError.interrupted {
                throw GoogleAppsRemovalError.interrupted
            } catch {
                // What is left boots safely (apps go out before their
                // allowlists), and Remove can be chosen again: Android starts.
                GoogleAppsJournal.remove(deps.paths)
            }
            return
        }
        logger.notice("Google apps: seeing an interrupted install through")
        do {
            try await superviseGoogleApps(id, cancellable: false, recovering: true) { [weak self] report in
                guard let installer = await self?.googleAppsInstaller(id, engine: engine, report: report) else { return nil }
                try await installer.recover()
                return nil
            }
        } catch GoogleAppsInstallError.untouched {
            // Nothing was copied in: Android starts as it is.
        } catch GoogleAppsInstallError.restored {
            // Taken out, and Android restarted as it was.
        }
    }

    // MARK: Root (MagiskRoot)

    /// With root on, a start without Magisk (root just turned on, or a new
    /// Android version) gets Magisk: its init_boot is patched once per image
    /// inside the running Android, then Android starts again with it. When
    /// that fails, root turns off again and the Mac says why.
    private func rootIfAsked() {
        guard config.rooted, rootRun == nil, let engine = deps.engine as? any RootEngine else { return }
        rootRun = Task { [weak self] in
            await self?.prepareRoot(engine)
        }
    }

    private func prepareRoot(_ engine: any RootEngine) async {
        defer { rootRun = nil }
        guard await vm.status.state == .running, config.rooted, await !engine.bootedRooted() else { return }
        do {
            if await !engine.hasPatchedImage() { try await engine.prepareRoot() }
            // Turned off meanwhile: the patched copy waits for the next time.
            guard config.rooted else { return }
            logger.notice("root: starting Android again with Magisk")
            await vm.stop()
            bootedConfig = nil
            rootTrial = true
            try await bootVM()
            rootTrial = false
        } catch {
            logger.error("root: \(String(describing: error), privacy: .public)")
            // Android rebooted (androidRebooted may have seen to it first) or
            // did not get ready with Magisk: it starts again without.
            if rootTrial {
                rootFailedToBoot()
                try? await ensureRunning()
                return
            }
            turnRootOff((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// The first start with Magisk did not get Android ready: root goes off,
    /// and the kernel's log of that start is kept beside the patched image.
    private func rootFailedToBoot() {
        rootTrial = false
        let log = MagiskRoot.failedBootLog(deps.paths)
        try? FileManager.default.createDirectory(at: MagiskRoot.directory(deps.paths), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: log)
        try? FileManager.default.copyItem(at: deps.paths.instance.appending(path: "kernel.log"), to: log)
        logger.error("root: Android did not start with Magisk; root is off again (kernel log: \(log.path, privacy: .public))")
        turnRootOff(String(localized: "Android restarted while it started with Magisk, so Avo started it again without root. Your apps and data are as they were.", bundle: .avoKit))
    }

    /// Root back off, saved, with a notification saying why.
    private func turnRootOff(_ reason: String) {
        guard config.rooted else { return }
        var off = config
        off.rooted = false
        config = off
        try? off.save(to: deps.paths.config)
        publish(off)
        var notification = Avo_V1_Notification()
        notification.package = AvoIdentifiers.daemonBundleID
        notification.key = "avo-root"
        notification.title = String(localized: "Root could not be turned on", bundle: .avoKit)
        notification.body = reason
        deps.notifications.post(notification, appName: "Avo", icon: nil)
    }

    private func googleAppsInstaller(_ id: UUID, engine: any SystemAppsEngine,
                                     report: @escaping GoogleAppsInstaller.Report) -> GoogleAppsInstaller {
        var installer = GoogleAppsInstaller(
            id: id,
            ensureRunning: { [weak self] in try await self?.bootForGoogleApps() },
            restart: { [weak self] in try await self?.restartForGoogleApps() },
            guest: { try await engine.systemApps() },
            report: report)
        installer.rescue = { [weak self] in try await self?.rescueGoogleApps() }
        installer.committing = { [weak self] in await self?.googleAppsCommitting(id) }
        installer.committed = { [weak self] in await self?.googleAppsCommitted() }
        installer.restored = { [weak self] in await self?.googleAppsRestored() }
        installer.removing = { [weak self] system in await self?.googleAppsRemovalStarts(id, system: system) }
        installer.removed = { [weak self] in await self?.googleAppsRemoved() }
        installer.interrupted = { [weak self] in await self?.googleAppsInterrupted ?? true }
        return installer
    }

    private func publishGoogleApps(_ progress: GoogleAppsProgress) {
        // Byte counts arrive per chunk: pass on whole percents.
        if let last = googleAppsProgress, last.id == progress.id, last.phase == progress.phase, last.message == progress.message,
           let before = last.fraction, let now = progress.fraction, abs(now - before) < 0.01, now < 1 { return }
        googleAppsProgress = progress
        broadcast(.googleAppsProgress(progress), to: isControlPanel)
    }

    private func bootForGoogleApps() async throws {
        guard !googleAppsInterrupted else { throw GoogleAppsInstallError.interrupted }
        try await bootVM()
    }

    /// Restarts the engine (the vbmeta flags and overlay apply at its start).
    /// Never after the user stopped Android by force.
    private func restartForGoogleApps() async throws {
        guard !googleAppsInterrupted else { throw GoogleAppsInstallError.interrupted }
        await vm.stop()
        bootedConfig = nil
        try await bootForGoogleApps()
    }

    /// Takes out a commit over a fresh adbd connection: Android may never
    /// get ready with it (system_server crashing), but adbd is up.
    private func rescueGoogleApps() async throws {
        let layout = GoogleAppsCommit.Layout(staging: HostAgent.googleAppsStaging)
        let result = try await vm.rescueShell(GoogleAppsCommit.rootCommand(GoogleAppsCommit.rollbackScript(layout: layout)),
                                             timeout: .seconds(120))
        guard result.succeeded else {
            let detail = (result.errorOutput + "\n" + result.output).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AvoError.installFailed(String(localized: "removing the copied files failed", bundle: .avoKit)
                                         + (detail.isEmpty ? "" : ": " + String(detail.suffix(600))))
        }
    }

    /// Before the commit: an interruption from here on is seen through at
    /// the next start.
    private func googleAppsCommitting(_ id: UUID) {
        do {
            try GoogleAppsJournal(id: id, started: Date()).save(deps.paths)
        } catch {
            logger.error("Google apps: could not note the commit: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func googleAppsRestored() {
        GoogleAppsJournal.remove(deps.paths)
    }

    /// Before Remove takes files out: an interruption from here on is
    /// finished at the next start.
    private func googleAppsRemovalStarts(_ id: UUID, system: Set<String>) {
        do {
            try GoogleAppsJournal(id: id, started: Date(), systemPackages: system.sorted()).save(deps.paths)
        } catch {
            logger.error("Google apps: could not note the removal: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Android lists no Google Play any more: Settings › Google services
    /// goes back to None, and Google apps can be installed again.
    private func googleAppsRemoved() {
        GoogleAppsJournal.remove(deps.paths)
        GoogleAppsRecord.remove(deps.paths)
        bootedConfig?.gms = .none
        guard config.gms == .bringYourOwn else { return }
        var new = config
        new.gms = .none
        apply(new)
    }

    /// Android booted with Google apps and lists Google Play: Settings ›
    /// System › Google services follows what Android has now, and the boot
    /// that has them counts as booted with it (no restart is "pending").
    private func googleAppsCommitted() {
        GoogleAppsJournal.remove(deps.paths)
        // Which Android has them, so another version can say they no longer fit.
        do {
            try GoogleAppsRecord(android: AndroidImageStore(paths: deps.paths).bootRecord()?.release).save(deps.paths)
        } catch {
            logger.error("Google apps: could not note the install: \(error.localizedDescription, privacy: .public)")
        }
        bootedConfig?.gms = .bringYourOwn
        guard config.gms != .bringYourOwn else { return }
        var new = config
        new.gms = .bringYourOwn
        apply(new)
    }

    /// Saves a configuration the daemon changed itself and tells every watcher.
    func apply(_ new: VMConfig) {
        config = new
        try? new.save(to: deps.paths.config)
        publish(new)
    }

    /// A `.local` source must be the Control Panel's copy inside the cache.
    static func cachedItem(_ path: String, in cache: URL) throws -> URL {
        let url = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
        let root = cache.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.path.hasPrefix(root + "/"), FileManager.default.fileExists(atPath: url.path) else {
            throw AvoError.unsupportedPackage(String(localized: "The package was not handed to Avo’s cache folder.", bundle: .avoKit))
        }
        return url
    }

    /// Removes the Control Panel's copy, with its folder (`cache/<id>/<name>`).
    static func removeCopy(_ url: URL, cache: URL) {
        let root = cache.standardizedFileURL.resolvingSymlinksInPath().path
        let parent = url.deletingLastPathComponent()
        let ownFolder = parent.path != root && parent.deletingLastPathComponent().path == root && parent.lastPathComponent != "downloads"
        try? FileManager.default.removeItem(at: ownFolder ? parent : url)
    }

    /// Copies an install that never finished left behind (the daemon quit
    /// meanwhile); an hour old, so a Control Panel still copying keeps its own.
    static func pruneCopies(in cache: URL, keeping current: URL?, now: Date = Date()) {
        let keep = current.map { $0.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().lastPathComponent }
        let items = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for item in items where item.lastPathComponent != "downloads" && item.lastPathComponent != keep {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > 3600 { try? FileManager.default.removeItem(at: item) }
        }
    }

    // MARK: Displays

    public func openDisplay(_ request: OpenDisplayRequest, client: ClientID) async throws -> UInt32 {
        guard case .shim(let package)? = clients[client]?.role, package == request.package else {
            throw AvoError.unauthorizedCaller
        }
        try await ensureRunning()
        // Android's lock screen covers every display until it is unlocked:
        // the window shows its own lock instead and asks again after.
        try await refuseWhileLocked()
        // The shim went away while Android started (its app quit while the
        // window said "Starting…"): nothing opens for it.
        guard clients[client] != nil else { throw AvoError.unauthorizedCaller }
        let id = nextDisplayID
        nextDisplayID &+= 1
        displays[id] = Display(id: id, package: package, owner: client, width: request.width, height: request.height, dpi: request.dpi,
                               opening: true)

        var launch = Avo_V1_Launch()
        launch.package = package
        launch.displayID = id
        launch.width = request.width
        launch.height = request.height
        launch.dpi = request.dpi
        launch.refreshRate = UInt32(bootedDisplayRate)
        launch.notificationKey = request.notificationKey ?? ""
        launch.dataUri = request.dataURI ?? ""
        launch.mimeType = request.mimeType ?? ""
        if package == AndroidWidgets.package {
            // A widget panel: its widget, nothing the panel says otherwise.
            guard let widget = placedWidgets.first(where: { $0.id == request.widget }) else {
                displays[id] = nil
                throw AvoError.displayUnavailable("no such widget")
            }
            launch.component = AndroidWidgets.activity
            launch.dataUri = AndroidWidgets.launchURI(slot: widget.id, provider: widget.provider)
            launch.notificationKey = ""
            launch.mimeType = ""
        }
        do {
            try await vm.controlSession().request(.launch(launch))
        } catch {
            displays[id] = nil
            // Locked meanwhile: the window waits for the unlock.
            try await refuseWhileLocked()
            throw error
        }
        displays[id]?.opening = false
        // Gone while Android launched the app: its display goes now, with the
        // app, rather than staying open for nobody.
        guard clients[client] != nil else {
            await closeDisplay(id, client: client)
            throw AvoError.unauthorizedCaller
        }
        await vm.setOpenDisplays(displays.count)
        // Gone meanwhile: `disconnect` closed the display.
        guard clients[client] != nil else { throw AvoError.unauthorizedCaller }
        // A widget is no app the Library counts time for.
        if package != AndroidWidgets.package { usageWindowOpened(id, package: package) }
        publishActivity()
        return id
    }

    private func ownedDisplay(_ id: UInt32, by client: ClientID) -> Display? {
        guard let display = displays[id], display.owner == client else { return nil }
        return display
    }

    /// Returns once the agent replied, which HostAgent sends after Android has
    /// the newest size and the app is back on the display; a display that is
    /// gone (closed meanwhile) is nothing to wait for.
    public func resizeDisplay(_ id: UInt32, width: UInt32, height: UInt32, dpi: UInt32, client: ClientID) async throws {
        guard var display = ownedDisplay(id, by: client) else { return }
        display.width = width
        display.height = height
        display.dpi = dpi
        displays[id] = display
        var request = Avo_V1_Resize()
        request.displayID = id
        request.width = width
        request.height = height
        request.dpi = dpi
        // A resize during a launch waits for it, then for each re-plug
        // (up to 15 s each for Android to add the display).
        _ = try await vm.controlSession().request(.resize(request), timeout: .seconds(60))
    }

    public func closeDisplay(_ id: UInt32, client: ClientID) async {
        guard let display = ownedDisplay(id, by: client) else { return }
        displays[id] = nil
        usageWindowClosed(id)
        // Closing an app's last window ends the app (Close, ⌘W, Quit, or the
        // shim going away), as a force stop does. Before its display goes:
        // unplugged first, the app's task would land on Android's own screen,
        // which the task watch takes for a new start, opening the window again.
        if !displays.values.contains(where: { $0.package == display.package }) {
            var stop = Avo_V1_ForceStop()
            stop.package = display.package
            _ = try? await vm.controlSession().request(.forceStop(stop))
            runningPackages.remove(display.package)
            await location.appClosed(display.package)
        }
        var request = Avo_V1_Close()
        request.displayID = id
        _ = try? await vm.controlSession().request(.close(request))
        await vm.setOpenDisplays(displays.count)
        publishActivity()
    }

    public func setDisplayVisible(_ id: UInt32, visible: Bool, client: ClientID) async {
        guard ownedDisplay(id, by: client) != nil else { return }
        displays[id]?.visible = visible
        usageVisibility(id, visible: visible)
        publishActivity()
        var request = Avo_V1_SetDisplayVisibility()
        request.displayID = id
        request.visible = visible
        _ = try? await vm.controlSession().request(.setDisplayVisibility(request))
    }

    public func setDisplayInBackground(_ id: UInt32, inBackground: Bool, client: ClientID) async {
        guard ownedDisplay(id, by: client) != nil else { return }
        displays[id]?.inBackground = inBackground
        publishActivity()
    }

    /// The window became the Mac's key window (Avo_V1_FocusDisplay). The
    /// Bridge Agent's displays have their own focus and answer unsupported.
    public func focusDisplay(_ id: UInt32, client: ClientID) async {
        guard let display = ownedDisplay(id, by: client) else { return }
        // An app's own location goes with its window (LocationCenter).
        await location.appFocused(display.package)
        var request = Avo_V1_FocusDisplay()
        request.displayID = id
        _ = try? await vm.controlSession().request(.focusDisplay(request))
    }

    public func sendInput(_ record: Data, client: ClientID) async {
        let owned = Set(displays.values.filter { $0.owner == client }.map(\.id))
        guard !owned.isEmpty else { return }
        // A paste uses what was just copied on the Mac, not what the clipboard
        // sync last saw.
        if clipboardShared, Self.isPaste(record), let text = deps.clipboard.takeChange() {
            await hostClipboardChanged(text)
        }
        do {
            try await vm.inputChannel().forward(record, allowedDisplays: owned)
        } catch {
            logger.debug("dropped input: \(String(describing: error), privacy: .public)")
        }
    }

    /// Drag and drop from Finder: copy into /sdcard/Download and share with
    /// the app. A file Downloads has already stays: the new one takes the
    /// next free name, as Avo's screenshots do on the Mac. Once copied, the
    /// files are in Downloads whatever the app makes of them, so a share
    /// Android cannot pass on (the host side of an image without the Bridge
    /// Agent shares nothing) fails nothing.
    public func shareFiles(_ files: [(OwnedDescriptor, String)], displayID: UInt32, client: ClientID) async throws {
        guard ownedDisplay(displayID, by: client) != nil else { throw AvoError.unauthorizedCaller }
        let adb = try await vm.adbConnection()
        let folder = "/sdcard/Download"
        // Nothing listed when the folder is not there yet.
        let listing = (try? await adb.shell("ls -1a " + folder))?.output ?? ""
        var taken = Set(listing.split(separator: "\n").map { $0.lowercased() })
        var request = Avo_V1_ShareFiles()
        request.displayID = displayID
        for (file, name) in files {
            let safeName = Self.unusedName(name.replacingOccurrences(of: "/", with: "-"), taken: taken)
            taken.insert(safeName.lowercased())
            let remote = folder + "/" + safeName
            try await adb.push(Self.stream(file), to: remote, mode: 0o660)
            request.paths.append(remote)
            let ext = (safeName as NSString).pathExtension
            request.mimeTypes.append(UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream")
        }
        do {
            try await vm.controlSession().request(.shareFiles(request))
        } catch {
            logger.notice("shared files stay in Downloads: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `name`, or `<name> (2).<ext>` and so on when `taken` (lowercased: the
    /// names in Android's shared storage match whatever their case) has it.
    static func unusedName(_ name: String, taken: Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
            number += 1
        }
        return candidate
    }

    /// Streams an open file with backpressure.
    static func stream(_ file: OwnedDescriptor) -> ChunkPipe {
        ChunkPipe { send in
            var offset: off_t = 0
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            while true {
                let n = buffer.withUnsafeMutableBytes { pread(file.value, $0.baseAddress, $0.count, offset) }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AvoError.internalError(String(cString: strerror(errno)))
                }
                if n == 0 { return }
                try send(Data(buffer[0..<n]))
                offset += off_t(n)
            }
        }
    }

    // MARK: Engine frames

    public func engineSetSurfaces(_ id: UInt32, surfaces: SurfaceList) {
        guard let display = displays[id], let owner = clients[display.owner] else { return }
        owner.proxy.proxy.setSurfaces(id, surfaces: surfaces.surfaces)
    }

    public func enginePresent(_ id: UInt32, surfaceIndex: Int, sequence: UInt64) {
        guard let display = displays[id], let owner = clients[display.owner] else { return }
        usage.framePresented(display: id)
        owner.proxy.proxy.present(id, surfaceIndex: surfaceIndex, sequence: sequence)
    }

    /// The engine's ring of what Android plays (`FrameDelivery.audioTap`): App Shims record from it.
    public func engineAudioTap(_ location: AudioTapLocation) {
        audioTap = location
        broadcast(.audioTap(location)) { if case .shim = $0 { true } else { false } }
    }

    // MARK: Guest events

    func handleGuest(_ event: ControlSession.Payload) async {
        switch event {
        case .appInstalled(let installed):
            await appInstalled(installed.app, replacing: installed.replacing, announce: true)
        case .appRemoved(let removed):
            guard !removed.replacing, let record = await registry.remove(removed.package) else { return }
            usageForget(removed.package)
            deps.shortcuts.remove(record.shortcuts)
            broadcast(.appRemoved(package: removed.package), to: isControlPanel)
        case .displayReady(let ready):
            guard var display = displays[ready.displayID] else { return }
            display.ready = true
            displays[ready.displayID] = display
            clients[display.owner]?.proxy.send(.displayReady(displayID: ready.displayID))
        case .taskStarted(let started):
            // Started outside a window (adb, another app): give it one.
            guard let shim = await registry.record(started.package)?.shortcuts.shimPath else { return }
            try? await deps.launcher.open(shim: URL(filePath: shim), arguments: [])
        case .taskClosed(let closed):
            guard let display = displays.removeValue(forKey: closed.displayID) else { return }
            usageWindowClosed(closed.displayID)
            clients[display.owner]?.proxy.send(.displayClosed(displayID: closed.displayID))
            await vm.setOpenDisplays(displays.count)
            // The app ended: it is no longer running at all.
            runningPackages.remove(closed.package.isEmpty ? display.package : closed.package)
            if !displays.values.contains(where: { $0.package == display.package }) { await location.appClosed(display.package) }
            publishActivity()
        case .displayContentChanged(let changed):
            guard let display = displays[changed.displayID] else { return }
            clients[display.owner]?.proxy.send(.displayTitle(displayID: changed.displayID, title: changed.title))
        case .orientationRequest(let request):
            guard let display = displays[request.displayID] else { return }
            clients[display.owner]?.proxy.send(.orientationRequest(displayID: request.displayID,
                                                                    orientation: Self.orientation(request.orientation)))
        case .notification(let notification):
            let app = await registry.record(notification.package)
            let appName = app?.displayName ?? notification.package
            deps.notifications.post(notification, appName: appName, icon: await registry.icon(for: notification.package))
            // Ongoing ones and empty group summaries are not worth a row.
            guard !notification.ongoing, !(notification.title.isEmpty && notification.body.isEmpty) else { return }
            setActiveNotifications { $0[notification.key] = notification.package }
            let posted = notification.postedAtMs > 0 ? Date(timeIntervalSince1970: Double(notification.postedAtMs) / 1000) : Date()
            recentNotifications.removeAll { $0.key == notification.key }
            recentNotifications.insert(AndroidNotification(key: notification.key, package: notification.package, appName: appName,
                                                           title: notification.title, body: notification.body, postedAt: posted), at: 0)
            if recentNotifications.count > Self.notificationLimit { recentNotifications.removeLast() }
            await publishNotifications()
        case .notificationRemoved(let removed):
            deps.notifications.remove(key: removed.key)
            // Dismissed or withdrawn in Android: gone from the list as well.
            recentNotifications.removeAll { $0.key == removed.key }
            setActiveNotifications { $0[removed.key] = nil }
            await publishNotifications()
        case .nowPlaying(let playing):
            if playing.artworkChanged { nowPlayingArtwork = playing.artworkJpeg.isEmpty ? nil : playing.artworkJpeg }
            guard !playing.package.isEmpty else {
                nowPlayingArtwork = nil
                deps.nowPlaying.show(nil, appName: "", artwork: nil)
                return
            }
            let appName = await registry.record(playing.package)?.displayName ?? playing.package
            deps.nowPlaying.show(playing, appName: appName, artwork: nowPlayingArtwork)
        case .clipboardChanged(let changed) where clipboardShared:
            lastClipboardFromGuest = changed.text
            deps.clipboard.set(changed.text)
        default:
            break
        }
    }

    private func appInstalled(_ info: Avo_V1_AppInfo, replacing: Bool, announce: Bool) async {
        guard info.launchable else { return }
        let (_, iconChanged, labelChanged) = await registry.apply(info)
        await serializedShimBuild(info.package) { [weak self] in
            await self?.makeShim(for: info, changed: iconChanged || labelChanged)
        }
        if announce, let record = await registry.record(info.package) { broadcast(.appInstalled(record), to: isControlPanel) }
    }

    /// Makes `info`'s shim when its icon or name changed, it is missing, or
    /// another Avo.app made it (Avo was replaced or moved: its windows would
    /// run that Avo's code), from the record as the builds before left it.
    private func makeShim(for info: Avo_V1_AppInfo, changed: Bool) async {
        guard let record = await registry.record(info.package) else { return }
        let shimMissing = record.shortcuts.shimPath.map { !FileManager.default.fileExists(atPath: $0) } ?? true
        let shimForAnotherAvo = !shimMissing && deps.shortcuts.madeForAnotherAvo(record.shortcuts)
        guard changed || shimMissing || shimForAnotherAvo else { return }
        let shortcuts = deps.shortcuts
        let config = self.config
        let made = await Task.detached { shortcuts.apply(record, info: info, config: config) }.value
        // Uninstalled meanwhile: what was made for it goes too.
        guard var current = await registry.record(info.package) else {
            shortcuts.remove(made)
            return
        }
        current.shortcuts = made
        await registry.update(current)
    }

    // MARK: Notifications (Control Panel list)

    static let notificationLimit = 200

    private func publishNotifications() async {
        broadcast(.notifications(recentNotifications), to: isControlPanel)
    }

    // MARK: Notifications (Dock badges)

    func notificationCount(of package: String) -> Int {
        Self.counts(activeNotifications)[package, default: 0]
    }

    private static func counts(_ notifications: [String: String]) -> [String: Int] {
        notifications.values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    /// Changes what Android shows, and tells the App Shims of each app
    /// whose count changed.
    private func setActiveNotifications(_ change: (inout [String: String]) -> Void) {
        let old = Self.counts(activeNotifications)
        change(&activeNotifications)
        let new = Self.counts(activeNotifications)
        for package in Set(old.keys).union(new.keys) where old[package] != new[package] {
            broadcast(.notificationCount(package: package, count: new[package, default: 0])) { $0 == .shim(package: package) }
        }
    }

    /// The Notifications pane and Settings › System ask again while they
    /// show it: System Settings tells nobody when the user changes it there.
    public func notificationPermission(client: ClientID) async throws -> MacNotificationPermission {
        try requireControlPanel(client)
        return await deps.notifications.permission()
    }

    /// Request Permission (Control Panel): the daemon posts the notifications,
    /// so it is the one macOS has to allow.
    public func requestNotificationPermission(client: ClientID) async throws -> MacNotificationPermission {
        try requireControlPanel(client)
        return await deps.notifications.requestPermission()
    }

    public func openNotification(key: String, client: ClientID) async throws {
        try requireControlPanel(client)
        guard let notification = recentNotifications.first(where: { $0.key == key }) else { return }
        await openNotification(package: notification.package, key: key)
    }

    /// Clear All: gone from Avo's list, Notification Center and Android.
    public func clearNotifications(client: ClientID) async throws {
        try requireControlPanel(client)
        await dismissNotifications(recentNotifications.map(\.key))
    }

    /// A row's dismiss button (or an app's group): gone from Avo's list,
    /// Notification Center and Android, as a swipe on a phone.
    public func dismissNotifications(_ keys: [String], client: ClientID) async throws {
        try requireControlPanel(client)
        await dismissNotifications(keys)
    }

    /// Also when the user closes one in Notification Center.
    private func dismissNotifications(_ keys: [String]) async {
        let keys = Set(keys)
        guard !keys.isEmpty else { return }
        for key in keys { deps.notifications.remove(key: key) }
        recentNotifications.removeAll { keys.contains($0.key) }
        setActiveNotifications { active in for key in keys { active[key] = nil } }
        await publishNotifications()
        guard let control = try? await vm.controlSession() else { return }
        for key in keys.sorted() {
            var dismiss = Avo_V1_DismissNotification()
            dismiss.key = key
            _ = try? await control.request(.dismissNotification(dismiss))
        }
    }

    /// Clicked in Notification Center or in Avo's list: the app opens, and
    /// Android drops the notification when the app made it go away on
    /// opening (FLAG_AUTO_CANCEL), as a tap on a phone does; Android's
    /// removal then takes it off the list.
    private func openNotification(package: String, key: String) async {
        guard let shim = await registry.record(package)?.shortcuts.shimPath else { return }
        if let display = displays.values.first(where: { $0.package == package }), let control = try? await vm.controlSession() {
            // The app has a window already, which reopening the shim only
            // brings to the front: Android opens the notification there.
            try? await deps.launcher.open(shim: URL(filePath: shim), arguments: [])
            var open = Avo_V1_OpenNotification()
            open.key = key
            open.displayID = display.id
            _ = try? await control.request(.openNotification(open))
        } else {
            // The new window starts with the notification (Launch.notificationKey).
            try? await deps.launcher.open(shim: URL(filePath: shim), arguments: ["--notification-key", key])
        }
    }

    /// A notification's button pressed in Notification Center (Reply with
    /// what was typed): Android fires it, and the app's own update or removal
    /// of the notification follows as usual.
    private func performNotificationAction(key: String, index: UInt32, reply: String?) async {
        guard let control = try? await vm.controlSession() else { return }
        var action = Avo_V1_PerformNotificationAction()
        action.key = key
        action.index = index
        action.replyText = reply ?? ""
        _ = try? await control.request(.performNotificationAction(action))
    }

    /// Play, pause, next… from the Mac's media keys or Control Center.
    private func sendMediaCommand(_ command: Avo_V1_MediaCommand) async {
        guard let control = try? await vm.controlSession() else { return }
        _ = try? await control.request(.mediaCommand(command))
    }

    /// Ctrl+V (⌘V in an app window) going down.
    static func isPaste(_ record: Data) -> Bool {
        var decoder = InputRecordDecoder()
        decoder.append(record)
        guard case .key(let event)? = try? decoder.next() else { return false }
        return event.action == .down && event.keyCode == 50 && event.metaState & 0x1000 != 0
    }

    /// Settings › Devices › Clipboard: the Mac's clipboard is read and
    /// written only while it is shared.
    private func shareClipboard(_ on: Bool) {
        guard on != clipboardShared else { return }
        clipboardShared = on
        watchClipboard(fresh: false)
    }

    /// macOS tells nobody when the clipboard changes, so it is looked at
    /// twice a second: only while it is shared and Android runs, not paused.
    /// What was copied while Android was paused reaches it as it goes on; what
    /// was copied while it was stopped (`fresh`: a new start) stays on the Mac.
    private func watchClipboard(fresh: Bool) {
        let watch = clipboardShared && androidAwake
        guard watch != clipboardWatched else { return }
        clipboardWatched = watch
        if watch {
            if fresh { _ = deps.clipboard.takeChange() }
            deps.clipboard.start { [weak self] text in
                Task { await self?.hostClipboardChanged(text) }
            }
        } else {
            deps.clipboard.stop()
        }
    }

    func hostClipboardChanged(_ text: String) async {
        // Copying on the Mac does not wake a paused Android: it gets the text when it goes on.
        guard clipboardShared else { return }
        if text != lastClipboardFromGuest, await vm.status.isPaused {
            autoPause.clipboard = text
            return
        }
        guard text != lastClipboardFromGuest, let control = try? await vm.controlSession() else { return }
        var request = Avo_V1_SetClipboard()
        request.text = text
        _ = try? await control.request(.setClipboard(request))
    }

    static func orientation(_ value: Avo_V1_Orientation) -> DisplayOrientation {
        switch value {
        case .portrait: .portrait
        case .landscape: .landscape
        case .reversePortrait: .reversePortrait
        case .reverseLandscape: .reverseLandscape
        default: .unspecified
        }
    }
}

// MARK: - Screen lock (Android started with a screen lock: ScreenLockEngine)

extension DaemonCore {
    /// The engine's report, into the VM status every client watches: the
    /// Control Panel's unlock sheet and banner, and the lock over each App
    /// Shim window. While Android runs, that status change also syncs the
    /// apps (`vmStatusChanged`), so after an unlock apps come back with
    /// their shims and icons.
    func screenLockChanged(_ lock: AndroidScreenLock?) async {
        let before = await vm.status.screenLock
        await vm.setScreenLock(lock)
        if before != nil, lock == nil, await vm.status.screenLock == nil { logger.notice("Android was unlocked") }
    }

    /// Throws `AvoError.androidLocked` while Android's screen lock keeps it
    /// locked, asking the engine itself: its report may still be on its way.
    func refuseWhileLocked() async throws {
        guard let engine = deps.engine as? any ScreenLockEngine, let lock = await engine.screenLock() else { return }
        if await vm.status.screenLock == nil { await vm.setScreenLock(lock) }
        throw AvoError.androidLocked
    }

    /// The credential typed in the Control Panel or an App Shim's window,
    /// passed to Android (never logged or kept). Returns once Android is
    /// unlocked, or at once when it is not locked.
    public func unlockAndroid(credential: String, client: ClientID) async throws {
        switch clients[client]?.role {
        case .controlPanel?, .shim?: break
        default: throw AvoError.unauthorizedCaller
        }
        guard let engine = deps.engine as? any ScreenLockEngine else {
            throw AvoError.internalError(String(localized: "Avo cannot unlock this Android.", bundle: .avoKit))
        }
        guard let lock = await engine.screenLock() else { return }
        // Not even the form of a pattern, PIN or password: not Android's.
        guard let checked = ScreenLockCredential(credential, kind: lock.credential) else {
            throw AvoError.screenLockRejected(throttled: false)
        }
        try await engine.unlockScreen(checked)
    }
}

// MARK: - Translate Screen (App Shims; ScreenTextEngine.swift)

extension DaemonCore {
    /// Translate Screen turned on in an app's window: the engine gets ready
    /// (unless it is already, from the daemon's start or another app).
    public func wakeScreenText(client: ClientID) throws {
        try screenText(for: client).wakeForWindow()
    }

    public func readScreenText(_ request: ScreenTextRequest, pixels: Data, client: ClientID) async throws -> ScreenTextReading {
        try await screenText(for: client).read(request, pixels: pixels)
    }

    public func translateTexts(_ request: TranslationRequest, client: ClientID) async throws -> [String] {
        try await screenText(for: client).translate(request)
    }

    public func knownTranslations(_ request: TranslationRequest, client: ClientID) async throws -> [String?] {
        await (try screenText(for: client)).known(request)
    }

    /// The engine, for App Shims only.
    private func screenText(for client: ClientID) throws -> ScreenTextEngine {
        guard case .shim? = role(of: client) else { throw AvoError.unauthorizedCaller }
        guard let engine = dependencies.screenText else { throw AvoError.internalError("Translate Screen is not available.") }
        return engine
    }
}

// MARK: - Where Android's data is (Settings › Storage › Location, StorageLocations.swift)

extension DaemonCore {
    public func storageLocation(client: ClientID) async throws -> StorageLocationStatus {
        try requireControlPanel(client)
        return await storage.status()
    }

    /// A folder the user chose, looked at before anything changes (nil: Avo's own storage).
    public func inspectStorageLocation(_ path: String?, client: ClientID) async throws -> StorageCandidate {
        try requireControlPanel(client)
        return await storage.inspect(path)
    }

    /// Moves Android's data, uses data already there or starts fresh there.
    /// Android must be stopped (`stopAndroid` stops it); starts wait meanwhile.
    public func changeStorageLocation(_ request: StorageChangeRequest, client: ClientID) async throws {
        try requireControlPanel(client)
        guard !storageChanging else {
            throw AvoError.internalError(String(localized: "Avo is already changing where Android’s data is.", bundle: .avoKit))
        }
        guard googleAppsRun == nil else { throw AvoError.internalError(GoogleAppsGuard.refusal) }
        storageChanging = true
        defer { storageChanging = false }
        switch await vm.status.state {
        case .stopped, .notInstalled:
            break
        case .failed:
            // The engine may still hold the disks after a failed start.
            await vm.stop()
        default:
            guard request.stopAndroid else {
                throw AvoError.internalError(String(localized: "Android is running. Stop Android to change where its data is.", bundle: .avoKit))
            }
            publishStorageProgress(StorageChangeProgress(id: request.id, phase: .stopping))
            try await clearForVMChange(.stop)
            await vm.stop()
        }
        // Progress in order, from the copy's thread.
        let (updates, sink) = AsyncStream.makeStream(of: StorageChangeProgress.self)
        let pump = Task { [weak self] in
            for await progress in updates { await self?.publishStorageProgress(progress) }
        }
        let outcome: StorageLocations.Outcome
        do {
            outcome = try await storage.perform(request) { sink.yield($0) }
        } catch {
            sink.finish()
            await pump.value
            await publishStorage()
            throw error
        }
        sink.finish()
        await pump.value
        await adopt(outcome)
        await publishStorage()
    }

    public func cancelStorageChange(client: ClientID) async throws {
        try requireControlPanel(client)
        await storage.cancel()
    }

    /// Erases the copy of Android's data left in Avo's own storage.
    public func removeInternalStorageCopy(client: ClientID) async throws {
        try requireControlPanel(client)
        guard !storageChanging else { throw AvoError.storage(.changing) }
        try await storage.removeInternalCopy()
        await publishStorage()
    }

    /// Avo's side follows the data now in use: the size it has, whether it
    /// has Google apps, its fingers, and (fresh data) no apps yet.
    private func adopt(_ outcome: StorageLocations.Outcome) async {
        storageCheckedAt = nil
        bootedConfig = nil
        var new = config
        switch outcome {
        case .moved:
            break
        case .adopted(let manifest):
            if let googleApps = manifest?.googleApps {
                if googleApps { new.gms = .bringYourOwn } else if new.gms == .bringYourOwn { new.gms = .none }
            }
            // The size the data's Android created its storage with (Settings › Storage).
            if let seen = DataDiskStore(paths: deps.paths).status().android, VMConfig.dataDiskRangeGB.contains(seen.settingsTotalGB) {
                new.dataDiskGiB = seen.settingsTotalGB
            }
        case .fresh(let gb):
            new.dataDiskGiB = gb
            if new.gms == .bringYourOwn { new.gms = .none }
            // A new Android has none of the apps: their shims go, as after Reset Android.
            usageForget(nil)
            for app in await registry.all() {
                deps.shortcuts.remove(app.shortcuts)
                await registry.remove(app.package)
                broadcast(.appRemoved(package: app.package))
            }
        }
        if new != config { apply(new) }
        await fingerprints.reload()
    }

    private func publishStorageProgress(_ progress: StorageChangeProgress) {
        broadcast(.storageProgress(progress), to: isControlPanel)
    }

    /// Tells Control Panels where Android's data is now.
    func publishStorage() async {
        broadcast(.storageLocation(await storage.status()), to: isControlPanel)
    }

    /// A volume came or went: a missing drive that is back clears its banner.
    /// An eject of the data's volume while Android runs was refused: Android
    /// stops (its disks are flushed by a clean power off) and the user ejects
    /// again. A drive that went without asking: Android stops at once.
    func volumeEvent(_ event: VolumeEvent) async {
        switch event {
        case .changed:
            guard !storagePublishPending else { return }
            storagePublishPending = true
            try? await Task.sleep(for: .milliseconds(500))
            storagePublishPending = false
            await publishStorage()
        case .unmountRefused(let mountPoint), .disappeared(let mountPoint):
            guard let volume = storage.volumeGuard.dataVolume, VolumeGuard.normalized(volume.mountPoint) == VolumeGuard.normalized(mountPoint)
            else { return }
            let gone: Bool = if case .disappeared = event { true } else { false }
            logger.notice("\(gone ? "the volume went" : "eject asked", privacy: .public) for \(mountPoint, privacy: .public): stopping Android")
            let reason = gone
                ? String(localized: "“\(volume.name)” was disconnected while Android used it. Connect it again, then start Android.", bundle: .avoKit)
                : String(localized: "Android stopped so “\(volume.name)” can be ejected. Eject it again.", bundle: .avoKit)
            try? await clearForVMChange(.stop, force: true)
            await vm.stop(reason: reason, callingOffRestart: true)
            await publishStorage()
        }
    }
}

// MARK: - Pause When Idle and the menu bar (AutoPause.swift)

extension DaemonCore {
    /// What keeps Android from pausing now, other than being used: Avo's
    /// windows (App Shim displays and Control Panels) and work under way.
    func autoPauseBlockers() async -> (windows: Int, busy: Set<AutoPauseReason>, engine: EngineActivity?) {
        var busy: Set<AutoPauseReason> = []
        if autoPause.installs > 0 { busy.insert(.install) }
        if googleAppsRun != nil { busy.insert(.googleApps) }
        if storageChanging { busy.insert(.storage) }
        if await location.isPlaying { busy.insert(.location) }
        if await adb.sessionCount() > 0 { busy.insert(.adb) }
        let engine = await (deps.engine as? any PausableEngine)?.activity()
        if engine?.playing == true { busy.insert(.sound) }
        if engine?.recording == true { busy.insert(.recording) }
        let panels = clients.values.filter { $0.role == .controlPanel }.count
        return (displays.count + panels, busy, engine)
    }

    /// The menu bar's panel: what runs, what was used last, and the engine.
    public func menuBarSnapshot() async -> MenuBarSnapshot {
        let recent = usage.all.compactMap { record in (record.lastActive ?? record.lastOpened).map { (record.package, $0) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
        return MenuBarSnapshot(activity: appActivity(), recent: recent,
                               engine: await (deps.engine as? any PausableEngine)?.activity())
    }
}

// MARK: - What a start catches up on (`vmStatusChanged`)

/// A running Android's statuses: the start's own work once a start (its
/// apps with their icons, the frame rate cap, root, its storage), not at
/// every change of its windows, renderer or lock; the apps listed again
/// once Android is unlocked or answers again; nothing while it does not
/// answer (asking would only hold the next statuses back).
struct StartSync: Sendable {
    enum Work: Sendable, Equatable {
        case none
        /// The apps again: Android lists the ones it could not open before.
        case apps
        case start
    }

    private var seen = false
    private var bootedAt: Date?
    private var done = false
    private var locked = false
    private var answering = true

    mutating func work(for status: VMStatus) -> Work {
        if !seen || status.bootedAt != bootedAt {
            self = StartSync()
            seen = true
            bootedAt = status.bootedAt
        }
        let unlocked = locked && status.screenLock == nil
        let answersAgain = !answering && !status.isNotResponding
        locked = status.screenLock != nil
        answering = !status.isNotResponding
        guard answering else { return .none }
        if !done {
            done = true
            return .start
        }
        return unlocked || answersAgain ? .apps : .none
    }
}
