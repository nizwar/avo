import AppKit
import AVFoundation
import AvoADB
import AvoDaemonCore
import AvoHazeUI
import AvoKit
import AvoShimKit
import AvoWindowHost
import CryptoKit
import os
import Security

/// The Runtime Daemon process: a LaunchAgent (registered by Avo.app) that
/// owns the VM, vends the XPC service and shows the menu bar item.
@MainActor
final class DaemonAppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Daemon")
    private var service: DaemonService?
    private var menuBar: MenuBarController?
    /// Android widgets on the Mac, in floating panels (Library › Widgets).
    private var widgetPanels: WidgetPanels?
    /// Avo's appearance on the menu bar item's panel and the widgets.
    private var appearance: HazeAppearanceFollower?
    private var location: MacLocation?
    private var macState: MacSystemState?
    /// Restarts the daemon on a new Avo once an update replaced Avo.app (AppUpdateWatcher.swift).
    private var updateWatcher: AppUpdateWatcher?
    /// The Mac waking from sleep (DaemonCore.macWoke).
    private var wakeObserver: (any NSObjectProtocol)?
    /// SIGTERM: launchd stopping the agent (a logout, a shutdown, a bootout).
    /// Android powers off, then the menu bar item leaves, then the daemon ends.
    private var terminationSignal: (any DispatchSourceSignal)?
    /// Android is being powered off for the daemon's end, and what ends the
    /// daemon then (`endAfterAndroid`).
    private var endings: [@MainActor () -> Void]?
    /// launchd ends an agent by force 20 s after its SIGTERM: Android's power
    /// off is given this, and the daemon ends after it.
    private static let powerOffLimit: Duration = .seconds(15)

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        watchTermination()
        do {
            try start()
        } catch {
            logger.fault("daemon failed to start: \(error.localizedDescription, privacy: .public)")
            exit(1)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBar?.remove()
    }

    /// Logging out or shutting down asks every app to quit: Android powers
    /// off first, instead of being left to avo-vmm's watch of its parent
    /// (what Android had not written yet would be lost).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard service != nil else { return .terminateNow }
        endAfterAndroid { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// SIGTERM takes the same way; then the menu bar item leaves the menu
    /// bar, and the signal ends the daemon as before (launchd's KeepAlive
    /// tells a signal from a successful exit).
    private func watchTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return Self.endBySignal() }
                self.endAfterAndroid { [weak self] in
                    self?.menuBar?.remove()
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(MenuBarController.removalGraceMilliseconds)) {
                        Self.endBySignal()
                    }
                }
            }
        }
        source.resume()
        terminationSignal = source
    }

    private static func endBySignal() {
        signal(SIGTERM, SIG_DFL)
        raise(SIGTERM)
    }

    /// Powers Android off (within `powerOffLimit`), then `end`s the daemon;
    /// a second way to end while it does ends with the first.
    private func endAfterAndroid(_ end: @escaping @MainActor () -> Void) {
        guard let core = service?.core else { return end() }
        if endings != nil {
            endings?.append(end)
            return
        }
        endings = [end]
        Task { @MainActor [weak self] in
            await core.powerOffForExit(within: Self.powerOffLimit)
            for end in self?.endings ?? [] { end() }
        }
    }

    private func start() throws {
        let avoApp = Self.hostApplication()
        let paths = AvoPaths()
        try paths.createDirectories()

        let profiles = (try? DeviceProfileCatalog(directory: avoApp.appending(path: "Contents/Resources/profiles/devices")))
            ?? DeviceProfileCatalog(profiles: [.avo])
        let template = avoApp.appending(path: "Contents/Library/Shim/AvoShim.app")
        let builder = FileManager.default.fileExists(atPath: template.path)
            ? ShimBuilder(template: template, hostApplication: avoApp, directory: paths.shims) : nil

        let imageKey = Self.imagePublicKey()
        let logger = self.logger
        let adbKey = try ADBKey.loadOrCreate(at: paths.adbKey)
        // avo-vmm booting an AOSP Cuttlefish build, whose image is looked up
        // at every start (the Setup Assistant or Settings › System › Android
        // version may install or choose one meanwhile; none: "not installed").
        // Without avo-vmm, the crosvm contract (docs/engine.md).
        let vmm = avoApp.appending(path: "Contents/MacOS/avo-vmm")
        let cuttlefishOverride = UserDefaults.standard.string(forKey: "AvoCuttlefishImages")
        let engine: any VMEngine
        let loadImage: @Sendable () throws -> AndroidImage
        if FileManager.default.isExecutableFile(atPath: vmm.path) {
            let cuttlefish = CuttlefishImage.find(paths: paths, override: cuttlefishOverride)
            engine = VMMEngine(executable: vmm, images: cuttlefish ?? paths.images, adbKey: adbKey, avoVersion: Self.version)
            loadImage = { try CuttlefishImage.prepareStart(paths: paths, override: cuttlefishOverride) }
            logger.notice("engine: avo-vmm")
        } else {
            engine = CrosvmEngine(executable: avoApp.appending(path: "Contents/MacOS/crosvm"))
            loadImage = {
                let config = (try? VMConfig.load(from: paths.config)) ?? VMConfig()
                let root = config.imageLocation.map { URL(filePath: $0) } ?? paths.images
                let image = try AndroidImage.installed(in: root)
                if let imageKey {
                    try image.verify(publicKey: imageKey)
                } else {
                    logger.warning("no image signing key in this build; skipping image verification")
                }
                return image
            }
        }
        let deps = DaemonCore.Dependencies(
            paths: paths,
            engine: engine,
            adbKey: adbKey,
            profiles: profiles,
            host: HostInfo.current(),
            shortcuts: ShortcutManager(builder: builder, paths: paths),
            notifications: UserNotificationPresenter(),
            // What Android plays, in Control Center and on the media keys.
            nowPlaying: MacNowPlaying(),
            clipboard: PasteboardBridge(),
            launcher: WorkspaceLauncher(),
            // With the build, so the Control Panel tells a daemon left from before an update.
            softwareVersion: AppUpdate.daemonVersion(short: Self.version, build: Self.build, code: Self.codeHash()),
            // Android's data on an external drive: an eject waits until Android stopped.
            volumes: DiskArbitrationWatcher(),
            imageOverride: cuttlefishOverride,
            // Translate Screen's text engine, one for every app.
            screenText: ScreenTextEngine(),
            loadImage: loadImage)
        let core = DaemonCore(deps)
        Task { await core.start() }
        // Android's clock stood still while the Mac slept: it is put right.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                         queue: .main) { _ in
            Task { await core.macWoke() }
        }
        if let vmm = engine as? VMMEngine {
            // The Mac's location for Android's GPS while Android runs and the
            // setting allows, unless a window's Location panel chose a place
            // or a route instead (LocationCenter).
            let location = MacLocation { fix in Task { await core.macLocationChanged(fix) } }
            self.location = location
            Task { @MainActor in
                for await status in await core.statusChanges() { location.update(running: status.state == .running) }
            }
            Task { @MainActor in
                for await config in await core.configChanges() { location.update(sharing: config.shareLocation) }
            }
            // Android follows the Mac's appearance, time zone, clock, languages
            // and battery, in order and only the latest.
            let (macStates, macStateSink) = AsyncStream.makeStream(of: MacState.self, bufferingPolicy: .bufferingNewest(1))
            let macState = MacSystemState { macStateSink.yield($0) }
            self.macState = macState
            Task {
                for await state in macStates { await vmm.setMacState(state) }
            }
            Task { @MainActor in
                for await status in await core.statusChanges() { macState.update(running: status.state == .running) }
            }
            // Links Android apps open, in the Mac's browser, mail app and Maps.
            Task { @MainActor in
                for await url in vmm.links { MacLinks.open(url, logger: logger) }
            }
            // GPU or software rendering, for the Control Panel's Graphics pane.
            Task {
                for await renderer in vmm.renderer { await core.vm.setRenderer(renderer) }
            }
            // Frames go to the App Shim that owns the display, in order.
            Task {
                for await delivery in vmm.frames {
                    switch delivery {
                    case let .surfaces(id, surfaces): await core.engineSetSurfaces(id, surfaces: SurfaceList(surfaces))
                    case let .present(id, index, sequence): await core.enginePresent(id, surfaceIndex: index, sequence: sequence)
                    case .firstFrame: break
                    case .microphone: Self.askForMicrophone(logger: logger)
                    case let .audioTap(location): await core.engineAudioTap(location)
                    }
                }
            }
        }

        // launchd names the job in XPC_SERVICE_NAME. An older Avo's job (dev.avo,
        // until the Control Panel moves it to this build's: DaemonAgent) runs
        // this daemon after a restart and vends only its own Mach service.
        let job = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? ""
        let machService = job.hasPrefix(AvoIdentifiers.formerPrefix + ".")
            ? AvoIdentifiers.formerDaemonMachService : AvoIdentifiers.daemonMachService
        let listener = NSXPCListener(machServiceName: machService)
        let service = DaemonService(core: core, policy: Self.callerPolicy(avoApp: avoApp), listener: listener)
        service.resume()
        self.service = service
        let panels = WidgetPanels()
        widgetPanels = panels
        Task { @MainActor in
            let id = await core.registerInProcess(role: .shim(package: AndroidWidgets.package), proxy: ClientProxy(panels.client))
            panels.connect(WidgetPanelsBackend(
                openDisplay: { try await core.openDisplay($0, client: id) },
                resizeDisplay: { try await core.resizeDisplay($0, width: $1, height: $2, dpi: $3, client: id) },
                closeDisplay: { await core.closeDisplay($0, client: id) },
                sendInput: { await core.sendInput($0, client: id) },
                removeWidget: { try await core.removeWidget($0, client: id) }))
        }
        let menuBar = MenuBarController(core: core, avoApp: avoApp)
        self.menuBar = menuBar
        // Settings › General › Appearance. The daemon's own appearance stays
        // the Mac's: Android's dark theme follows that (MacSystemState).
        appearance = HazeAppearanceSetting.avo.follow { [weak menuBar, weak panels] choice in
            menuBar?.appearance = choice.nsAppearance
            panels?.appearance = choice.nsAppearance
        }
        let updateWatcher = AppUpdateWatcher(avoApp: avoApp, core: core, logger: logger)
        updateWatcher.beforeExit = { [weak menuBar] in menuBar?.remove() }
        updateWatcher.start()
        self.updateWatcher = updateWatcher
        menuBar.updatePending = { [weak updateWatcher] in updateWatcher?.updatePending == true }
        menuBar.restartForUpdate = { [weak updateWatcher] force in try await updateWatcher?.restartAndroid(force: force) }
        // The daemon before this one stopped Android to restart on this build: Android goes on.
        if AppUpdateWatcher.takeStartRequest() { Task { try? await core.startVMFromMenuBar() } }
        logger.notice("daemon ready (Avo.app at \(avoApp.path, privacy: .public))")
        logger.notice("microphone permission: \(Self.microphoneStatus, privacy: .public)")
    }

    /// Avo.app/Contents/Library/Helpers/AvoDaemon.app → Avo.app
    /// The engine records from the Mac's microphone in the daemon's name
    /// (engine/hvf/vmm/src/virtio/sound.rs), but macOS does not ask on a
    /// background engine's behalf: the daemon asks when Android first
    /// records. Until the user allows it, Android hears silence.
    nonisolated static func askForMicrophone(logger: Logger) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            logger.notice("microphone permission \(granted ? "allowed" : "denied", privacy: .public)")
        }
    }

    nonisolated static var microphoneStatus: String {
        ["not asked yet", "restricted", "denied", "allowed"][min(AVCaptureDevice.authorizationStatus(for: .audio).rawValue, 3)]
    }

    static func hostApplication() -> URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent() // Helpers
            .deletingLastPathComponent() // Library
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // Avo.app
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// This daemon's code directory hash, read at its start (when the code on
    /// disk is the code that runs): what the Control Panel compares with the
    /// daemon in its Avo.app.
    static func codeHash() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let unique = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// Release builds carry the team that signed them; local builds are ad hoc.
    static func callerPolicy(avoApp: URL) -> CallerPolicy {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return .teamID(team)
        }
        return .development(appBundle: avoApp)
    }

    /// Ed25519 key that signs Android image manifests (Info.plist `AvoImagePublicKey`, base64).
    static func imagePublicKey() -> Curve25519.Signing.PublicKey? {
        guard let base64 = Bundle.main.object(forInfoDictionaryKey: "AvoImagePublicKey") as? String,
              let data = Data(base64Encoded: base64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }
}
