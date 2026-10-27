import AppKit
import AvoKeymap
import AvoKit
import AvoPackages
import AvoWindowHost
import Observation
import os
import Security
import ServiceManagement

/// State of the Control Panel, fed by the Runtime Daemon over XPC.
@MainActor
@Observable
final class ControlPanelModel {
    enum DaemonState: Equatable {
        case connecting
        case connected
        case needsApproval
        case unavailable(String)
    }

    /// A package the user opened, waiting for confirmation or installing.
    struct PendingInstall: Identifiable {
        let id = UUID()
        let url: URL
        var summary: PackageSummary?
        var inspectionError: String?
        /// The daemon's install of it, once Install was clicked: progress of
        /// any other install is not this sheet's.
        var requestID: UUID?
        var startedAt: Date?
        var progress: InstallProgress?
        var finishedPackage: String?

        /// What messages call it: the app's name once inspected.
        var displayName: String { summary?.label ?? url.lastPathComponent }
    }

    private(set) var daemonState: DaemonState = .connecting
    /// The Runtime Daemon's version, from its hello (Report a Problem).
    private(set) var daemonVersion: String?
    private(set) var status = VMStatus.stopped {
        didSet {
            screenLockSeen(after: oldValue)
            if daemonUpdatePending, !status.state.holdsAndroid { finishDaemonUpdate() }
        }
    }
    /// The daemon that runs is another build than the one in this Avo.app
    /// (Avo was updated while Android ran): Android keeps running on it, and
    /// it restarts on this build once Android stops (Settings › About offers
    /// to restart Android; AppUpdater.swift).
    private(set) var daemonUpdatePending = false
    /// The agent's plist changed with the update and launchd still holds the old one.
    private var daemonAgentOutdated = false
    /// A daemon that did not answer had its agent loaded again (`repairAgent`); Retry allows another.
    @ObservationIgnored private var agentRepaired = false
    /// The daemon's Mach service: the former one while the agent of an Avo
    /// from before com.avodroid still runs it (DaemonAgent.legacyLabel), until
    /// it gives way to this build's (`finishDaemonUpdate`).
    private var daemonMachService = AvoIdentifiers.daemonMachService
    /// Android stopped for the update starts again on the new daemon.
    private var startAndroidAfterDaemonUpdate = false
    /// The unlock sheet (ScreenLockViews.swift): it opens by itself when
    /// Android reports it started locked; Cancel leaves the banner's Unlock….
    var unlockSheetShown = false
    private(set) var apps: [AppRecord] = []
    /// What each running app is doing (open, minimized, background).
    private(set) var activity: [String: AppActivity] = [:]
    private(set) var icons: [String: NSImage] = [:]
    /// Android's recent notifications, newest first.
    private(set) var notifications: [AndroidNotification] = []
    /// Android widgets on the Mac (Library › Widgets).
    private(set) var widgets: [PlacedWidget] = []
    /// The widgets Android's apps offer, as last asked (nil: not yet).
    private(set) var widgetProviders: [WidgetProvider]?
    /// Why the last ask failed (Android not running, Avo Widgets not ready yet).
    private(set) var widgetProvidersProblem: String?
    /// Whether macOS shows Avo's notifications (System Settings › Notifications);
    /// nil until the daemon says (MacNotificationsViews.swift).
    private(set) var macNotifications: MacNotificationPermission?
    /// Request Permission waits for the daemon's reply.
    private(set) var requestingNotificationPermission = false
    /// Bumped by each request, so an older look does not undo its answer.
    @ObservationIgnored private var notificationPermissionGeneration = 0
    private(set) var snapshot: ConfigurationSnapshot?
    private(set) var configIssues: [ConfigIssue] = []
    var pendingInstall: PendingInstall?
    var lastError: String?
    /// Settings › System › Google apps: what Android has (nil until asked).
    private(set) var googleApps: GoogleAppsStatus?
    /// The install running now, or how the last one ended.
    private(set) var googleAppsProgress: GoogleAppsProgress?
    /// A "Check Again" (or a poll) is asking Android.
    private(set) var isRefreshingGoogleApps = false
    private var refreshGoogleAppsAgain = false
    /// Android said verified boot is off (it stays off, also after Reset
    /// Android), kept while Android is stopped and cannot be asked.
    private(set) var verityKnownOff = false
    /// Which Android has the Google apps on Android's storage (the daemon's
    /// `GoogleAppsRecord`, beside the data disk); read with each refresh.
    private(set) var googleAppsRecord: GoogleAppsRecord?
    /// The Control Panel's own first step, copying the package into the
    /// cache, before the daemon has the request.
    private var googleAppsCopy: (id: UUID, task: Task<Void, Never>)?
    /// Installed apps with a usable key mapping, which makes them games for
    /// Settings › Graphics (the same rule app windows use).
    private(set) var keyMappedPackages: Set<String> = []
    /// Settings › Fingerprints (FingerprintsPane.swift): Android's fingers, nil until asked.
    var fingerprints: FingerprintStatus?
    /// A fingerprint change is on its way to Android.
    var fingerprintsBusy = false
    /// Settings › Devices › Location: every app's location and the apps with
    /// their own, while the pane shows (nil until asked).
    var location: LocationStatus?
    /// What shows the location now: the Settings pane, the Location window
    /// (`watchLocation`).
    @ObservationIgnored var locationWatchers = 0
    /// Packages opened while another had the install sheet, in turn.
    @ObservationIgnored private var queuedInstalls: [URL] = []
    @ObservationIgnored private var lastVMAction: ContinuousClock.Instant?
    /// Installs hidden while they ran (Hide), by request, with their names.
    @ObservationIgnored private var hiddenInstalls: [UUID: String] = [:]
    /// How much each app was used, by package (the Library's statistics).
    private(set) var usage: [String: AppUsage] = [:]
    /// Library › System Status (SystemStatusView.swift), fed while it shows.
    let systemStatus = SystemStatusModel()

    private var client: DaemonClient?
    /// The daemon connection, for the panes' own calls (FingerprintsPane.swift).
    var daemonClient: DaemonClient? { client }
    private var eventTask: Task<Void, Never>?
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "ControlPanel")
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    var config: VMConfig? { snapshot?.config }
    var host: HostInfo { snapshot?.host ?? HostInfo.current() }
    var profiles: [DeviceProfile] { snapshot?.profiles ?? [] }
    var pendingRestart: Bool { snapshot?.pendingRestart ?? false }
    /// Android's storage (Settings › Storage); nil from an older daemon.
    var dataDisk: DataDiskStatus? { snapshot?.dataDisk }
    /// The engine's GPU shader cache (Settings › Storage), nil until asked.
    private(set) var gpuCache: GPUCacheStatus?
    /// Where Android's data is (Settings › Storage › Location); nil from an older daemon.
    private(set) var storageLocation: StorageLocationStatus? {
        // Each Android version's data, to offer again when versions change (AndroidDataMemory).
        didSet { if let storageLocation { AndroidDataMemory.note(storageLocation) } }
    }
    /// A change of where Android's data is, as the daemon reports it.
    private(set) var storageProgress: StorageChangeProgress?
    /// Settings › Android › Checkpoints (CheckpointViews.swift), nil until asked.
    private(set) var checkpoints: CheckpointStatus?
    /// A checkpoint is being made or restored (the buttons wait).
    private(set) var checkpointWork: CheckpointWork?
    /// A Google apps install runs (Reset and Save Snapshot wait).
    var isInstallingGoogleApps: Bool { googleAppsProgress.map { !$0.isDone } ?? false }
    /// It is changing Android, which Avo restarts by itself meanwhile:
    /// stopping, restarting or resetting Android has to wait.
    var googleAppsChangingAndroid: Bool { googleAppsProgress?.changesAndroid ?? false }
    /// Google apps are in Android: it lists them, or (while Android is
    /// stopped and cannot be asked) the installer set the mode, which only
    /// it and Reset Android change.
    var googleAppsInstalled: Bool { googleApps?.installed == true || config?.gms == .bringYourOwn }

    // MARK: Connection

    /// Development runs the daemon with launchctl instead (see host/README.md).
    private var managesDaemonAgent: Bool {
        !ProcessInfo.processInfo.arguments.contains("-AvoSkipDaemonRegistration")
    }

    /// Avo runs from the copy macOS makes of an app opened where it was
    /// downloaded (App Translocation): its daemon would be registered there,
    /// a place that goes away.
    var runsFromTemporaryCopy: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    func start() {
        refreshKeyMappingsWhenActive()
        guard managesDaemonAgent else {
            connect()
            return
        }
        // Left by a hand setup from before Avo installed its daemon itself: only the launch argument counts.
        UserDefaults.standard.removeObject(forKey: "AvoSkipDaemonRegistration")
        // A LaunchAgent of Avo's own, whatever the signature (DaemonAgent says why).
        Task { @MainActor [weak self] in
            await self?.unregisterLoginItem()
            let legacy = await DaemonAgent.legacyAgentHoldsAndroid()
            let outdated = await DaemonAgent.install()
            self?.daemonMachService = legacy ? AvoIdentifiers.formerDaemonMachService : AvoIdentifiers.daemonMachService
            self?.daemonAgentOutdated = outdated
            self?.connect()
        }
    }

    /// A Login Item from an earlier Developer ID build would hold the daemon's Mach service.
    private func unregisterLoginItem() async {
        let service = SMAppService.agent(plistName: "\(AvoIdentifiers.daemonLabel).plist")
        guard service.status != .notRegistered, service.status != .notFound else { return }
        do {
            try await service.unregister()
        } catch {
            logger.notice("former Login Item not removed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The cdhash of the daemon inside this Avo.app (what launchd's launch constraint checks).
    private static func daemonCodeHash() -> String? {
        let daemon = Bundle.main.bundleURL.appending(path: "Contents/Library/Helpers/AvoDaemon.app")
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(daemon as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let unique = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Waits for Avo to be allowed in Login Items, then starts its agent and
    /// connects (the banner says what to do meanwhile).
    private func connectOnceApproved() async {
        while !Task.isCancelled, DaemonAgent.requiresApproval() {
            try? await Task.sleep(for: .seconds(3))
        }
        guard !Task.isCancelled else { return }
        daemonState = .connecting
        daemonAgentOutdated = await DaemonAgent.install()
        connect()
    }

    /// After a hello that failed: an agent launchd holds from where Avo was
    /// before (moved to Applications, or updated while its daemon was
    /// stopped) cannot start, and launchd only restarts what it has. A daemon
    /// that does not run holds no Android, so the agent is loaded again from
    /// this Avo's plist, once until Retry. True when it was.
    private func repairAgent(after error: any Error) async -> Bool {
        guard managesDaemonAgent, !agentRepaired, error as? AvoError != .unauthorizedCaller else { return false }
        guard await !DaemonAgent.isRunning() else { return false }
        agentRepaired = true
        logger.notice("daemon agent loaded again after: \(error.localizedDescription, privacy: .public)")
        await DaemonAgent.reload(plistChanged: true)
        daemonAgentOutdated = false
        return true
    }

    /// The banner's Retry: the agent installed again (and loaded again if it
    /// is stale), then a new connection.
    func retryDaemon() {
        agentRepaired = false
        daemonState = .connecting
        guard managesDaemonAgent else {
            connect()
            return
        }
        Task { @MainActor [weak self] in
            let outdated = await DaemonAgent.install()
            self?.daemonAgentOutdated = outdated
            self?.connect()
        }
    }

    func connect() {
        eventTask?.cancel()
        client?.invalidate()
        let client = DaemonClient(role: .controlPanel, version: "avo-control-panel \(Self.version)", machService: daemonMachService)
        self.client = client
        eventTask = Task { [weak self] in
            do {
                let hello = try await client.hello()
                self?.daemonState = .connected
                self?.daemonVersion = hello.daemonVersion
                self?.checkDaemonBuild(hello)
                self?.status = hello.status
                self?.systemStatus.connected(client)
                // Settings › Devices › Location › Choose… (AvoWindowHost/LocationPanel.swift).
                ControlPanelLocationWindow.connect(client) { [weak self] on in self?.watchLocation(on) }
                if let self, locationWatchers > 0, let status = try? await client.location(watch: true) { location = status }
                await self?.refresh()
            } catch {
                guard let self else { return }
                // Login Items › Allow in the Background is off for Avo: launchd
                // will not start the daemon until it is on.
                if managesDaemonAgent, DaemonAgent.requiresApproval() {
                    daemonState = .needsApproval
                    await connectOnceApproved()
                    return
                }
                daemonState = .unavailable(Self.isOutdated && error as? AvoError == .unauthorizedCaller
                    ? String(localized: "Avo was updated while it was open. Quit Avo and open it again.")
                    : error.localizedDescription)
                if await repairAgent(after: error) {
                    connect()
                    return
                }
                // The daemon may still be starting (or restarting): keep trying.
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled, case .unavailable = daemonState { connect() }
                return
            }
            for await event in client.events {
                self?.handle(event)
            }
            // The daemon went away (update, crash): try again shortly.
            self?.daemonState = .connecting
            // An install it was running ended with it (the one this panel
            // started also fails its call, which says so).
            if let progress = self?.googleAppsProgress, !progress.isDone { self?.googleAppsProgress = nil }
            self?.lostDaemonMidway()
            try? await Task.sleep(for: .seconds(2))
            self?.connect()
        }
    }

    // MARK: After an update

    /// What this Avo.app's daemon says in its hello (AppUpdate.daemonVersion).
    private static var expectedDaemonVersion: String {
        AppUpdate.daemonVersion(short: version, build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                                code: daemonCodeHash())
    }

    /// A daemon left from the build before an update (or with a plist the
    /// update changed) restarts on this build at once while Android holds
    /// nothing; while Android runs it stays, and restarts once Android stops.
    private func checkDaemonBuild(_ hello: DaemonHello) {
        // Development: a daemon run by hand keeps its own way.
        guard !ProcessInfo.processInfo.arguments.contains("-AvoSkipDaemonRegistration") else { return }
        let decision = AppUpdate.daemonDecision(running: hello.daemonVersion, expected: Self.expectedDaemonVersion,
                                                androidRunning: hello.status.state.holdsAndroid)
        // This build's daemon, and launchd holds this build's plist: nothing to do.
        if decision == .current, !daemonAgentOutdated {
            daemonUpdatePending = false
            if startAndroidAfterDaemonUpdate {
                startAndroidAfterDaemonUpdate = false
                Task { try? await client?.startVM() }
            }
            return
        }
        daemonUpdatePending = true
        if hello.status.state.holdsAndroid {
            logger.notice("the daemon is \(hello.daemonVersion, privacy: .public): it restarts on this build once Android stops")
        } else {
            finishDaemonUpdate()
        }
    }

    /// Restarts the daemon on this build (Android holds nothing now); the connection comes back by itself.
    private func finishDaemonUpdate() {
        guard daemonUpdatePending else { return }
        daemonUpdatePending = false
        let plistChanged = daemonAgentOutdated
        daemonAgentOutdated = false
        Task { @MainActor [weak self] in
            await DaemonAgent.reload(plistChanged: plistChanged)
            // This build's agent is in place: the reconnection goes to it.
            self?.daemonMachService = AvoIdentifiers.daemonMachService
        }
    }

    /// Settings › About's Restart Android: Android stops as with Stop
    /// Android, the daemon restarts on this build, and Android starts again on it.
    func restartAndroidForUpdate() {
        guard daemonUpdatePending, let client else { return }
        startAndroidAfterDaemonUpdate = true
        Task {
            do {
                try await client.stopVM()
            } catch {
                startAndroidAfterDaemonUpdate = false
                lastError = error.localizedDescription
            }
        }
    }

    /// Stops Android so an update installs cleanly (AppUpdater's Stop
    /// Android and Install): nil once Android holds nothing, within a
    /// minute; otherwise why not, for the player.
    func stopAndroidForUpdate() async -> String? {
        guard let client else { return String(localized: "Avo’s background service isn’t running yet.") }
        do {
            try await client.stopVM()
        } catch {
            return error.localizedDescription
        }
        for _ in 0..<120 where status.state.holdsAndroid {
            try? await Task.sleep(for: .milliseconds(500))
        }
        return status.state.holdsAndroid ? String(localized: "It was still running after a minute.") : nil
    }

    /// This process runs code its app bundle no longer has (Avo was updated
    /// or rebuilt underneath it); the daemon may then refuse it.
    private static var isOutdated: Bool {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return false }
        return SecCodeCheckValidity(me, [], nil) != errSecSuccess
    }

    func refresh() async {
        guard let client else { return }
        // Apart, so a daemon from before usage statistics (which never
        // answers the call) holds nothing else up.
        Task {
            if let list = try? await client.appUsage() { usage = Dictionary(list.map { ($0.package, $0) }, uniquingKeysWith: { $1 }) }
        }
        do {
            async let snapshot = client.configuration()
            async let apps = client.apps()
            self.snapshot = try await snapshot
            storageLocation = self.snapshot?.storageLocation
            self.apps = try await apps
            refreshKeyMappings()
            for app in self.apps { await loadIcon(app.package) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handle(_ event: DaemonEvent) {
        switch event {
        case .appActivity(let activity):
            self.activity = activity
        case .vmStatus(let status):
            self.status = status
            if status.state != .running && !status.isPaused { activity = [:] }
            if status.state == .running || status.state == .stopped || status.state == .failed {
                Task { await refreshConfiguration() }
            }
        case .appInstalled(let record):
            apps.removeAll { $0.package == record.package }
            apps.append(record)
            apps.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            Task { await loadIcon(record.package, force: true) }
            refreshKeyMappings()
        case .appRemoved(let package):
            apps.removeAll { $0.package == package }
            icons[package] = nil
        case .installProgress(let progress):
            installProgressed(progress)
        case .configurationChanged(let config):
            snapshot?.config = config
        case .notifications(let list):
            notifications = list
        case .widgets(let list):
            widgets = list
        case .macNotifications(let permission):
            notificationPermissionGeneration += 1
            macNotifications = permission
        case .googleAppsProgress(let progress):
            if googleAppsCopy?.id == progress.id { googleAppsCopy = nil }
            googleAppsProgress = progress
            if progress.isDone { Task { await refreshGoogleApps() } }
        case .fingerprints(let status):
            fingerprints = status
        case .location(let status):
            location = status
            ControlPanelLocationWindow.update(status)
        case .appUsage(let list):
            usage = Dictionary(list.map { ($0.package, $0) }, uniquingKeysWith: { $1 })
        case .storageLocation(let location):
            storageLocation = location
            Task { await refreshConfiguration() }
        case .storageProgress(let progress):
            storageProgress = progress
        case .checkpoints(let status):
            checkpoints = status
        case .systemActivity(let activity):
            systemStatus.receive(activity)
        default:
            break
        }
    }

    private func refreshConfiguration() async {
        if let snapshot = try? await client?.configuration() {
            self.snapshot = snapshot
            if let location = snapshot.storageLocation { storageLocation = location }
        }
    }

    private func loadIcon(_ package: String, force: Bool = false) async {
        guard force || icons[package] == nil, let data = try? await client?.icon(for: package) else { return }
        icons[package] = NSImage(data: data)
    }

    // MARK: VM

    func startVM() { perform { try await $0.startVM() } }
    func stopVM() {
        guard takesVMAction() else { return }
        performUnlessInstalling { try await $0.stopVM() }
    }
    func restartVM() {
        guard takesVMAction() else { return }
        performUnlessInstalling { try await $0.restartVM() }
    }

    /// Stop and Restart a second time within a second (a double-click,
    /// before the daemon's new state arrives) ask nothing more.
    private func takesVMAction() -> Bool {
        let now = ContinuousClock.now
        if let last = lastVMAction, now - last < .seconds(1) { return false }
        lastVMAction = now
        return true
    }
    func retryGPU() { performUnlessInstalling { try await $0.retryGPU() } }
    func takeSnapshot() { performUnlessInstalling { try await $0.takeSnapshot() } }

    func resetAndroid() {
        guard !googleAppsChangingAndroid else {
            lastError = Self.googleAppsBusyMessage
            return
        }
        // Google apps go with the data disk: an old result no longer holds.
        if let progress = googleAppsProgress, progress.isDone { googleAppsProgress = nil }
        stopCopyingGoogleApps()
        perform { try await $0.resetAndroid() }
    }

    /// Settings › Storage › Change Size: erases Android's data (as Reset
    /// Android does), then sets the size the next start creates its storage
    /// with. Android's storage cannot change size while it holds data
    /// (DataDiskStatus says why).
    func eraseAndResizeStorage(to gb: Int) {
        guard !googleAppsChangingAndroid else {
            lastError = Self.googleAppsBusyMessage
            return
        }
        if let progress = googleAppsProgress, progress.isDone { googleAppsProgress = nil }
        stopCopyingGoogleApps()
        guard let client else { return }
        Task {
            do {
                try await client.resetAndroid()
                var config = try await client.configuration().config
                config.dataDiskGiB = gb
                let result = try await client.updateConfiguration(config)
                configIssues = result.issues
                if let issue = result.issues.first(where: { $0.severity == .error }) { lastError = issue.message }
            } catch {
                lastError = error.localizedDescription
            }
            await refreshConfiguration()
        }
    }

    /// The GPU shader cache's size (Settings › Storage).
    func refreshGPUCache() async {
        gpuCache = try? await client?.gpuCacheStatus()
    }

    func clearGPUCache() {
        guard let client else { return }
        Task {
            do {
                gpuCache = try await client.clearGPUCache()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: Where Android's data is (Settings › Storage › Location)

    /// What the daemon finds in a folder the user chose (nil: Avo's own
    /// storage). On a removable volume macOS may ask first whether Avo may.
    func inspectStorage(_ path: String?) async throws -> StorageCandidate {
        try await requireClient().inspectStorageLocation(path)
    }

    /// Returns once Android's data is in its new place; progress arrives meanwhile.
    func changeStorage(_ request: StorageChangeRequest) async throws {
        storageProgress = StorageChangeProgress(id: request.id, phase: .checking)
        defer { Task { await refreshConfiguration() } }
        do {
            try await requireClient().changeStorageLocation(request)
        } catch {
            // Refused before it began, or the daemon went away: no progress
            // will come, and Change Location… must work again.
            if let progress = storageProgress, progress.id == request.id, !progress.isDone {
                storageProgress = StorageChangeProgress(id: request.id, phase: .failed, message: error.localizedDescription)
            }
            throw error
        }
    }

    /// The daemon went away: what it was doing for this panel ended with it.
    /// Its call for a storage change fails too, and says so; hidden installs
    /// would never say how they ended.
    private func lostDaemonMidway() {
        if let progress = storageProgress, !progress.isDone {
            storageProgress = StorageChangeProgress(id: progress.id, phase: .failed)
        }
        if !hiddenInstalls.isEmpty {
            let names = hiddenInstalls.values.sorted().formatted(.list(type: .and))
            hiddenInstalls = [:]
            lastError = String(localized: "Avo’s background service stopped while installing \(names). If it is not in the Library, install it again.")
        }
    }

    func cancelStorageChange() { perform { try await $0.cancelStorageChange() } }

    /// Asks the daemon where Android's data is now (after System Settings
    /// changed Avo's access, or a drive was connected).
    func refreshStorageLocation() async {
        if let location = try? await client?.storageLocation() { storageLocation = location }
    }

    func removeInternalStorageCopy() {
        guard let client else { return }
        Task {
            do {
                try await client.removeInternalStorageCopy()
            } catch {
                lastError = error.localizedDescription
            }
            await refreshConfiguration()
        }
    }

    // MARK: Checkpoints (Settings › Android › Checkpoints)

    enum CheckpointWork { case creating, restoring }

    func refreshCheckpoints() async {
        if let status = try? await client?.checkpoints() { checkpoints = status }
    }

    func createCheckpoint(named name: String) {
        performCheckpointWork(.creating) { _ = try await $0.createCheckpoint(named: name) }
    }

    /// Android restarts with the checkpoint's data when it runs; its apps follow then.
    func restoreCheckpoint(_ checkpoint: Checkpoint) {
        performCheckpointWork(.restoring) { try await $0.restoreCheckpoint(checkpoint.id) }
    }

    func deleteCheckpoint(_ checkpoint: Checkpoint) {
        guard let client else { return }
        Task {
            do {
                try await client.deleteCheckpoint(checkpoint.id)
            } catch {
                lastError = error.localizedDescription
            }
            await refreshCheckpoints()
        }
    }

    private func performCheckpointWork(_ work: CheckpointWork, _ action: @escaping @Sendable (DaemonClient) async throws -> Void) {
        guard let client, checkpointWork == nil else { return }
        checkpointWork = work
        Task {
            do {
                try await action(client)
            } catch {
                lastError = error.localizedDescription
            }
            checkpointWork = nil
            await refreshCheckpoints()
            await refreshConfiguration()
        }
    }

    // MARK: The shared folder (Settings › Storage › Shared Folder)

    var sharedFolder: SharedFolderStatus? { snapshot?.sharedFolder }

    /// What the daemon finds in a folder the user chose to share.
    func inspectSharedFolder(_ path: String) async throws -> SharedFolderStatus {
        try await requireClient().inspectSharedFolder(path)
    }

    /// Asks again (after System Settings changed Avo's access, or a drive was connected).
    func refreshSharedFolder() async {
        await refreshConfiguration()
    }

    static var googleAppsBusyMessage: String {
        String(localized: "Avo is changing Google apps and restarts Android by itself meanwhile. Wait until it finishes.")
    }

    /// The daemon refuses too; this says so without asking it.
    private func performUnlessInstalling(_ action: @escaping @Sendable (DaemonClient) async throws -> Void) {
        guard !googleAppsChangingAndroid else {
            lastError = Self.googleAppsBusyMessage
            return
        }
        perform(action)
    }

    private func perform(_ action: @escaping @Sendable (DaemonClient) async throws -> Void) {
        guard let client else { return }
        Task {
            do {
                try await action(client)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: Configuration

    /// Applies a change right away; the daemon reports whether it needs a restart.
    func update(_ change: (inout VMConfig) -> Void) {
        guard var config = snapshot?.config, let client else { return }
        change(&config)
        guard config != snapshot?.config else { return }
        let previous = snapshot?.config
        snapshot?.config = config
        Task {
            do {
                let result = try await client.updateConfiguration(config)
                configIssues = result.issues
                if result.issues.contains(where: { $0.severity == .error }), let previous {
                    snapshot?.config = previous
                }
                await refreshConfiguration()
            } catch {
                lastError = error.localizedDescription
                if let previous { snapshot?.config = previous }
            }
        }
    }

    func issue(for field: String) -> ConfigIssue? {
        configIssues.first { $0.field == field }
    }

    // MARK: Graphics (Settings › Graphics, an app's Graphics Settings)

    /// Sets (nil removes) one app's graphics override. Overrides never travel
    /// with `update`: the daemon keeps its own, so a window's View menu and
    /// this panel cannot undo each other's changes.
    func setAppGraphics(_ override: AppGraphicsOverride?, for package: String) {
        guard var config = snapshot?.config, let client else { return }
        let stored = (override?.isEmpty ?? true) ? nil : override
        guard config.graphicsOverrides[package] != stored else { return }
        let previous = config.graphicsOverrides[package]
        config.graphicsOverrides[package] = stored
        snapshot?.config = config
        Task {
            do {
                let result = try await client.setAppGraphics(stored, for: package)
                configIssues = result.issues
                if result.issues.contains(where: { $0.severity == .error }) {
                    snapshot?.config.graphicsOverrides[package] = previous
                }
                await refreshConfiguration()
            } catch {
                lastError = error.localizedDescription
                snapshot?.config.graphicsOverrides[package] = previous
            }
        }
    }

    /// Whether `package` counts as a game when it chose no profile.
    func hasKeyMapping(_ package: String) -> Bool {
        keyMappedPackages.contains(package)
    }

    /// Looks for usable key mappings (the user's, else the bundled one) off
    /// the main actor: each check reads and validates a JSON file.
    func refreshKeyMappings() {
        let packages = apps.map(\.package)
        let bundled = Bundle.main.resourceURL?.appending(path: "profiles/keymaps", directoryHint: .isDirectory)
        keyMappingGeneration += 1
        let generation = keyMappingGeneration
        Task {
            let found = await Task.detached(priority: .utility) {
                Set(packages.filter { KeymapProfile.usable(for: $0, bundledDirectory: bundled) != nil })
            }.value
            // An older scan (of a shorter app list) finishing last must not win.
            guard generation == keyMappingGeneration, found != keyMappedPackages else { return }
            keyMappedPackages = found
        }
    }

    @ObservationIgnored private var keyMappingGeneration = 0
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    /// A key mapping made (or removed) in an app's window counts once Avo
    /// is in front again: the Library's Games and Apps, and the preset an
    /// app's page starts its graphics from, as the window has them.
    private func refreshKeyMappingsWhenActive() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                    queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshKeyMappings() }
        }
    }

    /// The settings `package`'s windows use now.
    func graphics(for package: String) -> ResolvedGraphics? {
        let app = apps.first { $0.package == package }
        return config?.graphics(for: package, hasKeyMapping: hasKeyMapping(package), isGame: app?.isGame == true,
                                orientation: app?.orientation)
    }

    /// Android lists the app as a game (its manifest says so). The Library's
    /// `isGame(_:)` asks more: whether the app uses the Games preset.
    func listedAsGame(_ package: String) -> Bool {
        apps.first { $0.package == package }?.isGame == true
    }

    // MARK: Apps

    func open(_ app: AppRecord) {
        guard let shim = app.shortcuts.shimPath else {
            lastError = String(localized: "\(app.displayName) has no shortcut yet. Use “Recreate Shortcuts” in Settings › General.")
            return
        }
        NSWorkspace.shared.openApplication(at: URL(filePath: shim), configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens the app with its key mapping editor over the game (its page's
    /// Create Key Mapping…): a running app is asked, one that starts is
    /// told by its launch (ShimRequest).
    func editKeyMapping(_ app: AppRecord) {
        guard let shim = app.shortcuts.shimPath else {
            lastError = String(localized: "\(app.displayName) has no shortcut yet. Use “Recreate Shortcuts” in Settings › General.")
            return
        }
        let identifier = AvoIdentifiers.shimBundleIdentifier(for: app.package)
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: \.isFinishedLaunching) {
            // Asked and brought forward, not reopened: a reopen opens another
            // window when none shows (a minimized one), as a Dock click does.
            DistributedNotificationCenter.default().postNotificationName(ShimRequest.editKeyMapping, object: app.package, userInfo: nil,
                                                                         deliverImmediately: true)
            _ = running.activate(from: .current)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [ShimRequest.editKeyMappingArgument]
        NSWorkspace.shared.openApplication(at: URL(filePath: shim), configuration: configuration)
    }

    // MARK: Notifications

    /// Opens its app; Android drops it when the app says opening does (the
    /// daemon's list follows).
    func open(_ notification: AndroidNotification) { perform { try await $0.openNotification(notification.key) } }

    /// Gone here at once; the daemon dismisses them in Notification Center
    /// and Android too, as a swipe on a phone.
    func dismiss(_ dismissed: [AndroidNotification]) {
        let keys = Set(dismissed.map(\.key))
        notifications.removeAll { keys.contains($0.key) }
        perform { try await $0.dismissNotifications(Array(keys)) }
    }

    func clearNotifications() {
        notifications = []
        perform { try await $0.clearNotifications() }
    }

    // MARK: Widgets

    func refreshWidgetProviders() async {
        guard let client else { return }
        do {
            widgetProviders = try await client.widgetProviders()
            widgetProvidersProblem = nil
        } catch {
            widgetProvidersProblem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func addWidget(_ provider: WidgetProvider) {
        perform { _ = try await $0.addWidget(provider.provider) }
    }

    func removeWidget(_ widget: PlacedWidget) {
        widgets.removeAll { $0.id == widget.id }
        perform { try await $0.removeWidget(widget.id) }
    }

    /// System Settings › Notifications › Avo (the daemon posts them).
    func openNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(AvoIdentifiers.daemonBundleID)")!
        NSWorkspace.shared.open(url)
    }

    /// Request Permission: the daemon, which posts the notifications, asks
    /// macOS; its alert appears while macOS has no answer yet, and the
    /// user's answer arrives as an event.
    func requestNotificationPermission() {
        guard let client, !requestingNotificationPermission else { return }
        requestingNotificationPermission = true
        notificationPermissionGeneration += 1
        Task {
            defer { requestingNotificationPermission = false }
            do {
                let permission = try await client.requestNotificationPermission()
                notificationPermissionGeneration += 1
                macNotifications = permission
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Asks the daemon again: System Settings tells nobody when the user
    /// changes Avo's notifications there.
    func refreshNotificationPermission() async {
        guard let client, !requestingNotificationPermission else { return }
        let generation = notificationPermissionGeneration
        guard let permission = try? await client.notificationPermission(),
              generation == notificationPermissionGeneration, permission != macNotifications else { return }
        macNotifications = permission
    }

    func uninstall(_ app: AppRecord) { perform { try await $0.uninstall(app.package) } }
    func forceStop(_ app: AppRecord) { perform { try await $0.forceStop(app.package) } }
    func deleteData(_ app: AppRecord) { perform { try await $0.deleteAppData(app.package) } }
    func recreateShortcuts() { perform { try await $0.recreateShortcuts() } }

    func permissions(for app: AppRecord) async -> [AppPermission] {
        (try? await client?.permissions(for: app.package)) ?? []
    }

    // MARK: Android's volume (Settings › Devices › Sound)

    /// Android's media volume while Settings shows it; nil while Android is not running.
    private(set) var androidVolume: AndroidVolume?
    /// The level the slider asked for while a change was on its way: the latest wins.
    @ObservationIgnored private var volumeWanted: Int?
    @ObservationIgnored private var volumeSending = false

    func loadAndroidVolume() async {
        guard let client, status.state == .running else {
            androidVolume = nil
            return
        }
        let volume = try? await client.androidVolume()
        // Not over a level the slider is sending.
        if volumeWanted == nil, !volumeSending { androidVolume = volume }
    }

    /// The slider moved: Android follows, one change at a time, the latest level last.
    func setAndroidVolume(_ level: Int) {
        guard var shown = androidVolume, shown.level != level else { return }
        shown.level = level
        androidVolume = shown
        volumeWanted = level
        guard !volumeSending else { return }
        volumeSending = true
        Task { await sendAndroidVolume() }
    }

    private func sendAndroidVolume() async {
        while let level = volumeWanted {
            volumeWanted = nil
            let result = try? await client?.setAndroidVolume(level)
            if volumeWanted == nil, let result { androidVolume = result }
        }
        volumeSending = false
    }

    func setPermission(_ permission: AppPermission, granted: Bool, for app: AppRecord) async {
        do {
            try await client?.setPermission(permission.name, granted: granted, for: app.package)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Installing (spec §3)

    static let packageExtensions: Set<String> = ["apk", "xapk", "apkm", "apks"]

    /// Shows the confirmation sheet for a package file (double-click, drop, File › Install).
    /// Asks for a package file and installs it (toolbar, menu, Apps pane).
    func chooseAndInstall() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.packageExtensions.compactMap { .init(filenameExtension: $0) }
        panel.prompt = String(localized: "Install")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prepareInstall(url)
    }

    func prepareInstall(_ url: URL) {
        guard Self.packageExtensions.contains(url.pathExtension.lowercased()) else {
            lastError = String(localized: "\(url.lastPathComponent) is not an Android package.")
            return
        }
        // One sheet at a time: a package opened meanwhile waits its turn.
        if let current = pendingInstall {
            if current.url != url, !queuedInstalls.contains(url) { queuedInstalls.append(url) }
            return
        }
        var pending = PendingInstall(url: url)
        pendingInstall = pending
        Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let summary = try PackageArchive(url: url).summary
                pending.summary = summary
            } catch {
                pending.inspectionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            await MainActor.run { [pending] in
                if self.pendingInstall?.id == pending.id { self.pendingInstall = pending }
            }
        }
    }

    func confirmInstall() {
        // Once: a second click is not a second install.
        guard var pending = pendingInstall, pending.requestID == nil, let client else { return }
        let request = InstallRequest(path: pending.url.path)
        pending.requestID = request.id
        pending.startedAt = Date()
        pending.progress = InstallProgress(id: request.id, phase: .inspecting)
        pendingInstall = pending
        Task {
            do {
                try await client.install(request)
            } catch {
                installProgressed(InstallProgress(id: request.id, phase: .failed, message: error.localizedDescription))
            }
        }
    }

    /// Progress of an install: its sheet's, or one hidden while it ran,
    /// which says how it ended only if it failed (a finished one shows up
    /// in the Library).
    private func installProgressed(_ progress: InstallProgress) {
        if var pending = pendingInstall, pending.requestID == progress.id {
            pending.progress = progress
            if progress.phase == .finished { pending.finishedPackage = progress.package }
            pendingInstall = pending
            return
        }
        guard progress.phase == .finished || progress.phase == .failed,
              let name = hiddenInstalls.removeValue(forKey: progress.id) else { return }
        if progress.phase == .failed {
            lastError = String(localized: "\(name) was not installed. \(progress.message ?? String(localized: "Installation failed."))")
        }
    }

    /// Closes the sheet (Cancel, Done, Hide). An install still running goes
    /// on, hidden; the next package opened meanwhile gets the sheet.
    func dismissInstall() {
        if let pending = pendingInstall, let id = pending.requestID, let phase = pending.progress?.phase,
           phase != .finished, phase != .failed {
            hiddenInstalls[id] = pending.displayName
        }
        pendingInstall = nil
        guard !queuedInstalls.isEmpty else { return }
        let next = queuedInstalls.removeFirst()
        // After this sheet has gone, or the next one would not show.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.prepareInstall(next)
        }
    }

    // MARK: Google apps (Settings › System, spec: Strategi GMS)

    func refreshGoogleApps() async {
        googleAppsRecord = GoogleAppsRecord.load(AvoPaths())
        guard let client else { return }
        // One question at a time (each runs several commands in Android);
        // one asked meanwhile follows it.
        guard !isRefreshingGoogleApps else {
            refreshGoogleAppsAgain = true
            return
        }
        isRefreshingGoogleApps = true
        defer { isRefreshingGoogleApps = false }
        repeat {
            refreshGoogleAppsAgain = false
            guard let status = try? await client.googleAppsStatus() else { return }
            googleApps = status
            if let off = status.verityDisabled { verityKnownOff = off }
            // The daemon notes it once Android lists them.
            googleAppsRecord = GoogleAppsRecord.load(AvoPaths())
            if let progress = status.progress {
                // An answer from before the install ended does not bring it back.
                if !(googleAppsProgress?.id == progress.id && googleAppsProgress?.isDone == true) { googleAppsProgress = progress }
            } else if let last = googleAppsProgress, last.phase == .finished, !last.removal, status.installed == false {
                // Installed once, gone now (Reset Android). A failure, and
                // what Remove did, stay shown.
                googleAppsProgress = nil
            }
        } while refreshGoogleAppsAgain
    }

    /// A MindTheGapps .zip, or the folder it unzips to, for `line` (the
    /// package line that fits Android, when known).
    func chooseGoogleAppsPackage(for line: GoogleAppsLine?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.prompt = String(localized: "Choose")
        if let line {
            panel.message = String(localized: "Choose \(line.name) for Android \(line.android): the .zip, or the folder it unzips to.")
        } else {
            panel.message = String(localized: "Choose the MindTheGapps package for this Android’s version: the .zip, or the folder it unzips to.")
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The daemon does not read Downloads or Documents itself (privacy
    /// prompts): the package is copied into Avo's cache first, which APFS
    /// does as a clone, and the daemon removes the copy when done.
    func installGoogleApps(from url: URL) {
        let id = UUID()
        googleAppsProgress = GoogleAppsProgress(id: id, phase: .preparing)
        let task = Task {
            do {
                let copy = try await Self.copyIntoCache(url)
                // Stopped meanwhile: the copy (which cannot be interrupted)
                // goes, and the daemon never hears of it.
                guard !Task.isCancelled, googleAppsCopy?.id == id else {
                    try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
                    return
                }
                googleAppsCopy = nil
                try await requireClient().installGoogleApps(GoogleAppsInstallRequest(id: id, source: .local(path: copy.path)))
            } catch {
                googleAppsFailed(id, error)
            }
        }
        googleAppsCopy = (id, task)
    }

    func downloadGoogleApps(from link: String) {
        let id = UUID()
        googleAppsProgress = GoogleAppsProgress(id: id, phase: .preparing)
        Task {
            do {
                try await requireClient().installGoogleApps(GoogleAppsInstallRequest(id: id, source: .github(url: link)))
            } catch {
                googleAppsFailed(id, error)
            }
        }
    }

    /// Remove: the daemon takes Google apps out and reports like an install.
    func removeGoogleApps() {
        let id = UUID()
        googleAppsProgress = GoogleAppsProgress(id: id, phase: .startingVM, removal: true)
        Task {
            do {
                try await requireClient().removeGoogleApps(id: id)
            } catch {
                googleAppsFailed(id, error, removal: true)
            }
        }
    }

    /// Stop: before the daemon has the request it is the Control Panel's
    /// own copy that stops; otherwise the daemon stops the install (also
    /// one whose request is still on its way).
    func cancelGoogleApps() {
        guard let progress = googleAppsProgress, !progress.isDone else { return }
        if googleAppsCopy?.id == progress.id {
            stopCopyingGoogleApps()
            return
        }
        let id = progress.id
        perform { try await $0.cancelGoogleApps(id: id) }
    }

    private func stopCopyingGoogleApps() {
        guard let copy = googleAppsCopy else { return }
        copy.task.cancel()
        googleAppsCopy = nil
        googleAppsProgress = GoogleAppsProgress(id: copy.id, phase: .cancelled,
                                                message: String(localized: "Install stopped. Android was not changed."))
    }

    private func requireClient() throws -> DaemonClient {
        guard let client else { throw AvoError.daemonUnreachable(String(localized: "not connected")) }
        return client
    }

    /// The daemon reports its own failures as progress; this covers the
    /// rest (copying the package, the connection).
    private func googleAppsFailed(_ id: UUID, _ error: any Error, removal: Bool = false) {
        if googleAppsCopy?.id == id { googleAppsCopy = nil }
        guard googleAppsProgress?.id != id || googleAppsProgress?.isDone != true else { return }
        googleAppsProgress = GoogleAppsProgress(id: id, phase: .failed, message: error.localizedDescription, removal: removal)
    }

    private nonisolated static func copyIntoCache(_ url: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let folder = AvoPaths().googleAppsCache.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appending(path: url.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: url, to: copy)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
            return copy
        }.value
    }
}

// MARK: - Screen lock (Android started with a screen lock: VMStatus.screenLock)

extension ControlPanelModel {
    /// Android's screen lock while it keeps Android locked (nil while not running).
    var screenLock: AndroidScreenLock? { status.state == .running ? status.screenLock : nil }

    /// Opens the unlock sheet as Android reports a lock (after a start, or
    /// when this panel connects to a locked Android), closes it once unlocked.
    fileprivate func screenLockSeen(after old: VMStatus) {
        let wasLocked = old.state == .running && old.screenLock != nil
        if screenLock != nil, !wasLocked { unlockSheetShown = true }
        if screenLock == nil { unlockSheetShown = false }
    }

    /// Passes the credential to Android (`DaemonClient.unlockAndroid`); returns
    /// once Android is unlocked. The credential is not kept.
    func unlockAndroid(credential: String) async throws {
        try await requireClient().unlockAndroid(credential: credential)
    }
}
