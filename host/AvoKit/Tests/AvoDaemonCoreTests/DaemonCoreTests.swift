import AvoADB
import AvoIO
import AvoKit
import AvoProtocol
import AvoShimKit
import AvoTestSupport
import CryptoKit
import Foundation
import IOSurface
import Security
import Testing
@testable import AvoDaemonCore

/// Records what the daemon pushes to a client.
final class RecordingClient: NSObject, AvoClientXPC, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [DaemonEvent] = []

    var events: [DaemonEvent] { lock.withLock { _events } }

    func handleEvent(_ event: Data) {
        guard let decoded = try? AvoXPC.decode(DaemonEvent.self, from: event) else { return }
        lock.withLock { _events.append(decoded) }
    }

    func setSurfaces(_ displayID: UInt32, surfaces: [IOSurface]) {}
    func present(_ displayID: UInt32, surfaceIndex: Int, sequence: UInt64) {}

    /// Waits until an event matching `predicate` arrives.
    func wait(timeout: Duration = .seconds(5), for predicate: (DaemonEvent) -> Bool) async -> DaemonEvent? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let match = events.first(where: predicate) { return match }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

final class RecordingNotifications: NotificationPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _posted: [(String, String)] = []
    var posted: [(app: String, title: String)] { lock.withLock { _posted.map { (app: $0.0, title: $0.1) } } }

    func start(onOpen: @escaping @Sendable (String, String) -> Void) {}
    func post(_ notification: Avo_V1_Notification, appName: String, icon: Data?) {
        lock.withLock {
            _posted.append((appName, notification.title))
            _posts.append(notification)
        }
    }
    private var _removed: [String] = []
    private var onDismiss: (@Sendable (String) -> Void)?
    /// Keys taken out of Notification Center.
    var removed: [String] { lock.withLock { _removed } }
    func remove(key: String) { lock.withLock { _removed.append(key) } }
    func observeDismissals(_ onDismiss: @escaping @Sendable (String) -> Void) { lock.withLock { self.onDismiss = onDismiss } }
    /// The user closes one in Notification Center.
    func closeInNotificationCenter(_ key: String) { lock.withLock { onDismiss }?(key) }
    private var onAction: (@Sendable (String, UInt32, String?) -> Void)?
    private var _posts: [Avo_V1_Notification] = []
    /// Everything posted, as Android sent it.
    var posts: [Avo_V1_Notification] { lock.withLock { _posts } }
    func observeActions(_ onAction: @escaping @Sendable (String, UInt32, String?) -> Void) {
        lock.withLock { self.onAction = onAction }
    }
    /// The user presses one's button in Notification Center (Reply with `reply` typed).
    func press(_ key: String, button index: UInt32, reply: String? = nil) { lock.withLock { onAction }?(key, index, reply) }
}

final class RecordingNowPlaying: NowPlayingPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var onCommand: (@Sendable (Avo_V1_MediaCommand) -> Void)?
    private var _shown: [(playing: Avo_V1_NowPlaying?, appName: String, artwork: Data?)] = []
    /// Each `show`, in order.
    var shown: [(playing: Avo_V1_NowPlaying?, appName: String, artwork: Data?)] { lock.withLock { _shown } }

    func start(onCommand: @escaping @Sendable (Avo_V1_MediaCommand) -> Void) { lock.withLock { self.onCommand = onCommand } }
    func show(_ playing: Avo_V1_NowPlaying?, appName: String, artwork: Data?) {
        lock.withLock { _shown.append((playing, appName, artwork)) }
    }
    /// A media key or Control Center.
    func command(_ command: Avo_V1_MediaCommand.Command) {
        var media = Avo_V1_MediaCommand()
        media.command = command
        lock.withLock { onCommand }?(media)
    }
}

/// Waits for `condition`, which returns as soon as it holds. The limit is
/// generous: with every suite running at once on a busy Mac, steps the fakes
/// take in a second can take several (a 5 s limit failed a different test
/// on each full run).
func eventually(timeout: Duration = .seconds(15), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

/// Spins up a DaemonCore against the fake engine and guest in a temporary home.
struct Harness {
    let root: URL
    let paths: AvoPaths
    let engine: FakeEngine
    let agent: FakeBridgeAgent
    let core: DaemonCore
    let notifications = RecordingNotifications()
    let nowPlaying = RecordingNowPlaying()
    let adbKey: ADBKey
    let desktopAliases: Bool

    /// `desktopAliases` is off by default: Finder aliases register the shims
    /// with LaunchServices, which tests should not do needlessly.
    /// `configure` changes the saved configuration the daemon starts with.
    /// `wrap` puts another engine around the fake one (one that can pause).
    /// `screenText`: Translate Screen's engine (none by default).
    /// `bootTimeout`: how long a start waits for Android.
    init(apps: [Avo_V1_AppInfo], desktopAliases: Bool = false, configure: (inout VMConfig) -> Void = { _ in },
         wrap: (FakeEngine) -> any VMEngine = { $0 }, screenText: ScreenTextEngine? = nil,
         clipboard: any ClipboardBridge = NoClipboard(), bootTimeout: Duration = .seconds(5)) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "avo-daemon-\(UUID().uuidString.prefix(8))")
        paths = AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp"))
        try FileManager.default.createDirectory(at: paths.desktop, withIntermediateDirectories: true)
        self.desktopAliases = desktopAliases
        var config = VMConfig()
        config.createDesktopAlias = desktopAliases
        configure(&config)
        try config.save(to: paths.config)

        // Shim template: a copy of /usr/bin/true dressed as an app.
        let template = root.appending(path: "AvoShim.app")
        try FileManager.default.createDirectory(at: template.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: template.appending(path: "Contents/MacOS/AvoShim"))
        let info: [String: Any] = ["CFBundleExecutable": "AvoShim", "CFBundlePackageType": "APPL", "CFBundleIdentifier": "com.avodroid.shim"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: template.appending(path: "Contents/Info.plist"))
        var builder = ShimBuilder(template: template, hostApplication: URL(filePath: "/Applications/Avo.app"), directory: paths.shims)
        builder.registersWithLaunchServices = false

        adbKey = try ADBKey.generate()
        agent = FakeBridgeAgent(apps: apps)
        engine = FakeEngine(agent: agent, adbPublicKey: adbKey.publicKey)
        let image = AndroidImage(schema: 1, version: "16.0.0-test", sdk: 36, kernel: "kernel", initrd: nil,
                                 partitions: ["system.img"], overlayStock: "overlay.img", overlayRooted: "overlay-rooted.img",
                                 files: [])
        let profiles = DeviceProfileCatalog(profiles: [
            DeviceProfile(id: DeviceProfile.defaultID, name: "Avo Virtual Device", properties: [:]),
        ])
        let host = HostInfo(physicalMemoryBytes: 32 << 30, performanceCores: 8, efficiencyCores: 4, isAppleSilicon: true, macOSVersion: "27.0")
        core = DaemonCore(.init(paths: paths, engine: wrap(engine), adbKey: adbKey, profiles: profiles, host: host,
                                shortcuts: ShortcutManager(builder: builder, paths: paths), notifications: notifications,
                                nowPlaying: nowPlaying, clipboard: clipboard, softwareVersion: "avo-host test", bootTimeout: bootTimeout,
                                screenText: screenText,
                                loadImage: { image }))
    }

    func cleanUp() {
        if desktopAliases { LaunchServicesCleanup.unregisterApps(under: root) }
        try? FileManager.default.removeItem(at: root)
    }

    /// Waits until `count` apps are registered and each has its shim.
    func waitForShims(_ count: Int) async -> Bool {
        await eventually {
            let apps = await core.apps()
            return apps.count == count && apps.allSatisfy { $0.shortcuts.shimPath != nil }
        }
    }

    func connect(_ role: ClientHello.Role) async -> (UUID, RecordingClient) {
        let id = UUID()
        let client = RecordingClient()
        _ = await core.register(id, role: role, proxy: ClientProxy(client))
        return (id, client)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct DaemonCoreTests {
    @Test func bootSyncsAppsAndCreatesShims() async throws {
        let harness = try Harness(apps: [
            FakeBridgeAgent.app("org.fdroid.fdroid", label: "F-Droid"),
            FakeBridgeAgent.app("com.android.settings", label: "Settings"),
            FakeBridgeAgent.app("com.android.providers.media", label: "Media", launchable: false),
        ], desktopAliases: true)
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, events) = await harness.connect(.controlPanel)
        harness.engine.refuseControlConnections = 3 // Android still booting

        try await harness.core.startVM(client: panel)
        #expect(await harness.core.status().state == .running)
        #expect(await harness.core.status().androidVersion == "Android 16 (API 36)")

        // Shims are generated after the registry update (icon rendering and codesign run off the actor).
        #expect(await harness.waitForShims(2))
        let apps = await harness.core.apps()
        #expect(apps.map(\.package) == ["org.fdroid.fdroid", "com.android.settings"])
        for app in apps {
            let shim = try #require(app.shortcuts.shimPath)
            #expect(FileManager.default.fileExists(atPath: shim))
            #expect(app.shortcuts.shimCDHash?.count == 40)
            #expect(app.shortcuts.desktopAliasPath != nil) // "Buat alias di Desktop" defaults on
        }
        #expect(await events.wait { if case .vmStatus(let s) = $0 { s.state == .running } else { false } } != nil)

        // The BootConfig disk carries the daemon's ADB key for the guest to trust.
        let launch = try #require(harness.engine.launches.first)
        let disk = try Data(contentsOf: launch.bootConfigDisk)
        #expect(disk.count % 4096 == 0)
        let json = String(decoding: disk.prefix { $0 != 0 }, as: UTF8.self)
        #expect(json.contains(try harness.adbKey.androidPublicKey(comment: "avo-daemon")))
        #expect(FileManager.default.fileExists(atPath: harness.paths.dataDisk.path))
    }

    @Test func shimOpensItsOwnDisplayOnly() async throws {
        let harness = try Harness(apps: [FakeBridgeAgent.app("org.fdroid.fdroid", label: "F-Droid"),
                                         FakeBridgeAgent.app("com.example.notes", label: "Notes")])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (shim, shimEvents) = await harness.connect(.shim(package: "org.fdroid.fdroid"))

        // A shim cannot open another app's display.
        await #expect(throws: AvoError.unauthorizedCaller) {
            try await harness.core.openDisplay(OpenDisplayRequest(package: "com.example.notes", width: 800, height: 1600, dpi: 320), client: shim)
        }

        let display = try await harness.core.openDisplay(OpenDisplayRequest(package: "org.fdroid.fdroid", width: 824, height: 1784, dpi: 320),
                                                         client: shim)
        #expect(await shimEvents.wait { $0 == .displayReady(displayID: display) } != nil)
        let launches = await harness.agent.requests { if case .launch(let l) = $0 { l } else { nil } }
        #expect(launches.map(\.package) == ["org.fdroid.fdroid"])
        #expect(launches.first?.refreshRate == 60)
        #expect(launches.first?.width == 824)

        // Input for the shim's own display is forwarded; anything else is dropped.
        let mine = try InputWire.encode(.touch(TouchEvent(displayID: display, action: .down, pointers: [TouchPointer(id: 0, x: 1, y: 2)])))
        let other = try InputWire.encode(.touch(TouchEvent(displayID: display + 7, action: .down, pointers: [TouchPointer(id: 0, x: 1, y: 2)])))
        await harness.core.sendInput(Data(other), client: shim)
        await harness.core.sendInput(Data(mine), client: shim)
        #expect(await eventually { await harness.engine.input.records.count == 1 })
        #expect(await harness.engine.input.records.first == .touch(TouchEvent(displayID: display, action: .down,
                                                                              pointers: [TouchPointer(id: 0, x: 1, y: 2)])))

        // Quitting the shim closes its display in Android, and its last
        // window closing ends the app, before the display goes (else its task
        // lands on Android's own screen and the window opens again).
        await harness.core.disconnect(shim)
        #expect(await eventually { await harness.agent.requests { if case .close(let c) = $0 { c.displayID } else { nil } } == [display] })
        let order = await harness.agent.requests { request -> String? in
            switch request {
            case .forceStop(let stop): "stop \(stop.package)"
            case .close: "close"
            default: nil
            }
        }
        #expect(order == ["stop org.fdroid.fdroid", "close"])
    }

    /// An app quit while its window said "Starting…" (Android booting): the
    /// shim is gone by the time Android runs, and nothing opens for it.
    @Test func aShimGoneWhileAndroidStartsGetsNoDisplay() async throws {
        let harness = try Harness(apps: [FakeBridgeAgent.app("org.fdroid.fdroid", label: "F-Droid")])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (shim, _) = await harness.connect(.shim(package: "org.fdroid.fdroid"))
        harness.engine.refuseControlConnections = 2 // Android still booting
        let opening = Task {
            try await harness.core.openDisplay(OpenDisplayRequest(package: "org.fdroid.fdroid", width: 800, height: 1600, dpi: 320),
                                               client: shim)
        }
        #expect(await eventually { await harness.core.status().state == .starting })
        await harness.core.disconnect(shim)
        await #expect(throws: AvoError.unauthorizedCaller) { try await opening.value }
        #expect(await harness.core.status().state == .running)
        #expect(await harness.agent.requests { if case .launch(let l) = $0 { l } else { nil } }.isEmpty)
    }

    /// Quit while Android launched the app: its display is closed, the app
    /// stopped first, once the launch is done (stopped during it, the app
    /// could start after), and not kept for nobody.
    @Test func aShimGoneWhileItsAppLaunchesClosesItsDisplayAfter() async throws {
        let harness = try Harness(apps: [FakeBridgeAgent.app("org.fdroid.fdroid", label: "F-Droid")])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (shim, _) = await harness.connect(.shim(package: "org.fdroid.fdroid"))
        try await harness.core.ensureRunning()
        await harness.agent.holdLaunches()
        let opening = Task {
            try await harness.core.openDisplay(OpenDisplayRequest(package: "org.fdroid.fdroid", width: 800, height: 1600, dpi: 320),
                                               client: shim)
        }
        let launches = { await harness.agent.requests { if case .launch(let l) = $0 { l.displayID } else { nil } } }
        #expect(await eventually { await launches().count == 1 })
        await harness.core.disconnect(shim)
        let ends = {
            await harness.agent.requests { request -> String? in
                switch request {
                case .forceStop(let stop): "stop \(stop.package)"
                case .close(let close): "close \(close.displayID)"
                default: nil
                }
            }
        }
        // Nothing yet: the launch is still under way.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await ends().isEmpty)
        await harness.agent.releaseLaunches()
        await #expect(throws: AvoError.unauthorizedCaller) { try await opening.value }
        let display = try #require(await launches().first)
        #expect(await ends() == ["stop org.fdroid.fdroid", "close \(display)"])
        #expect(await harness.core.appActivity()["org.fdroid.fdroid"] == nil)
    }

    /// Files dropped on a window never replace what Android's Downloads has
    /// (its names match whatever their case), nor each other.
    @Test func droppedFilesKeepWhatDownloadsHas() async throws {
        let harness = try Harness(apps: [FakeBridgeAgent.app("org.fdroid.fdroid", label: "F-Droid")])
        defer { harness.cleanUp() }
        harness.engine.adbShellHandler = { command in
            command == "ls -1a /sdcard/Download" ? (".\n..\nphoto.jpg\nNotes.txt\n", "", 0) : ("", "unexpected", 1)
        }
        await harness.core.start()
        let (shim, _) = await harness.connect(.shim(package: "org.fdroid.fdroid"))
        let display = try await harness.core.openDisplay(OpenDisplayRequest(package: "org.fdroid.fdroid", width: 800, height: 1600, dpi: 320),
                                                         client: shim)
        var dropped: [(OwnedDescriptor, String)] = []
        for (index, name) in ["photo.jpg", "photo.jpg", "notes.txt"].enumerated() {
            let file = harness.root.appending(path: "drop-\(index)")
            try Data("file \(index)".utf8).write(to: file)
            dropped.append((try open(file), name))
        }
        try await harness.core.shareFiles(dropped, displayID: display, client: shim)

        let adbd = try #require(harness.engine.adbd)
        let pushed = await adbd.pushed
        #expect(pushed.keys.sorted() == ["/sdcard/Download/notes (2).txt", "/sdcard/Download/photo (2).jpg", "/sdcard/Download/photo (3).jpg"])
        #expect(pushed["/sdcard/Download/photo (3).jpg"]?.data == Data("file 1".utf8))
        let shares = await harness.agent.requests { if case .shareFiles(let share) = $0 { share } else { nil } }
        #expect(shares.map(\.paths) == [["/sdcard/Download/photo (2).jpg", "/sdcard/Download/photo (3).jpg", "/sdcard/Download/notes (2).txt"]])
        #expect(shares.first?.mimeTypes == ["image/jpeg", "image/jpeg", "text/plain"])
        #expect(DaemonCore.unusedName("README", taken: ["readme", "readme (2)"]) == "README (3)")
    }

    @Test func guestEventsReachTheMac() async throws {
        let harness = try Harness(apps: [FakeBridgeAgent.app("org.fdroid.fdroid", label: "F-Droid"),
                                         FakeBridgeAgent.app("com.example.notes", label: "Notes")], desktopAliases: true)
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, events) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        #expect(await harness.waitForShims(2))

        // Uninstall: the guest's AppRemoved removes the record and the shim.
        let notes = try #require(await harness.core.apps().first { $0.package == "com.example.notes" })
        try await harness.core.uninstall("com.example.notes", client: panel)
        #expect(await events.wait { $0 == .appRemoved(package: "com.example.notes") } != nil)
        #expect(!FileManager.default.fileExists(atPath: notes.shortcuts.shimPath!))
        #expect(!FileManager.default.fileExists(atPath: notes.shortcuts.desktopAliasPath!))

        // Apps installed inside Android (F-Droid, Aurora Store) get shims too.
        await harness.agent.install(FakeBridgeAgent.app("com.aurora.store", label: "Aurora Store"))
        let installed = await events.wait { if case .appInstalled(let r) = $0 { r.package == "com.aurora.store" } else { false } }
        guard case .appInstalled(let aurora)? = installed else {
            Issue.record("no appInstalled event")
            return
        }
        #expect(aurora.shortcuts.shimPath?.hasSuffix("/Aurora Store.app") == true)

        // Notifications go to Notification Center under the app's name.
        var notification = Avo_V1_Notification()
        notification.package = "org.fdroid.fdroid"
        notification.key = "0|org.fdroid.fdroid|1|null|10071"
        notification.title = "Updates available"
        await harness.agent.emit(.notification(notification))
        #expect(await eventually { harness.notifications.posted.first?.app == "F-Droid" })
        #expect(harness.notifications.posted.first?.title == "Updates available")
    }

    @Test func configurationRulesAndLiveFPS() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)

        var config = await harness.core.configurationSnapshot().config
        config.fpsLimit = 30
        let fps = try await harness.core.updateConfiguration(config, client: panel)
        #expect(fps.effect == .immediate)
        // Android gets the cap at every start (60 here, or already 30) and at the change.
        #expect(await eventually {
            let rates: [UInt32] = await harness.agent.requests { if case .setRefreshRate(let r) = $0 { r.fps } else { nil } }
            return rates.count == 2 && rates.last == 30
        })

        config.memoryMiB = 6144
        let memory = try await harness.core.updateConfiguration(config, client: panel)
        #expect(memory.effect == .restartRequired)
        #expect(await harness.core.configurationSnapshot().pendingRestart)
        #expect(try VMConfig.load(from: harness.paths.config).memoryMiB == 6144)

        // The engine made a disk but Android never wrote to it: any size goes.
        #expect(await harness.core.configurationSnapshot().dataDisk?.created == false)
        var resized = config
        resized.dataDiskGiB = 64
        let accepted = try await harness.core.updateConfiguration(resized, client: panel)
        #expect(!accepted.issues.contains { $0.field == "dataDiskGiB" })
        config = resized
        // Once Android created its storage, neither a smaller nor a bigger size.
        try FileHandle(forWritingTo: harness.paths.dataDisk).write(contentsOf: Data([1]))
        #expect(await harness.core.configurationSnapshot().dataDisk?.created == true)
        for gb in [8, 128] {
            var other = config
            other.dataDiskGiB = gb
            let rejected = try await harness.core.updateConfiguration(other, client: panel)
            #expect(rejected.issues.contains { $0.field == "dataDiskGiB" && $0.severity == .error })
            #expect(await harness.core.configurationSnapshot().config.dataDiskGiB == 64)
        }

        // Shims may not change settings.
        let (shim, _) = await harness.connect(.shim(package: "x"))
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.updateConfiguration(config, client: shim) }
    }

    @Test func shimSetsOnlyItsOwnGraphics() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        let (shimX, eventsX) = await harness.connect(.shim(package: "com.x"))
        let (shimY, _) = await harness.connect(.shim(package: "com.y"))
        let stale = await harness.core.configurationSnapshot().config

        var patch = GraphicsSettingsPatch()
        patch.shortSide = 1080
        let own = AppGraphicsOverride(profile: .games, changes: patch)
        let saved = try await harness.core.setAppGraphics("com.x", own, client: shimX)
        #expect(saved.effect == .immediate && saved.issues.isEmpty)
        #expect(try VMConfig.load(from: harness.paths.config).graphicsOverrides["com.x"] == own)
        // Shims hear configuration changes, so their windows follow them.
        #expect(await eventsX.wait { if case .configurationChanged(let c) = $0 { c.graphicsOverrides["com.x"] == own } else { false } } != nil)

        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.setAppGraphics("com.x", nil, client: shimY) }

        var invalid = GraphicsSettingsPatch()
        invalid.shortSide = 721
        let refused = try await harness.core.setAppGraphics("com.x", AppGraphicsOverride(changes: invalid), client: shimX)
        #expect(refused.issues.map(\.field) == ["graphicsOverrides.com.x.shortSide"])
        #expect(await harness.core.configurationSnapshot().config.graphicsOverrides["com.x"] == own)

        // The Control Panel may set any app; an empty override removes it.
        _ = try await harness.core.setAppGraphics("com.y", AppGraphicsOverride(profile: .apps), client: panel)
        _ = try await harness.core.setAppGraphics("com.x", AppGraphicsOverride(), client: panel)
        #expect(await harness.core.configurationSnapshot().config.graphicsOverrides.keys.sorted() == ["com.y"])

        // A panel snapshot from before those changes does not undo them.
        var edit = stale
        edit.fpsLimit = 30
        _ = try await harness.core.updateConfiguration(edit, client: panel)
        let now = await harness.core.configurationSnapshot().config
        #expect(now.fpsLimit == 30)
        #expect(now.graphicsOverrides.keys.sorted() == ["com.y"])

        // Only the shim that said hello as the package, never the engine or a stranger.
        let (engine, _) = await harness.connect(.engine)
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.setAppGraphics("com.y", own, client: engine) }
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.setAppGraphics("com.y", own, client: UUID()) }
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.setAppGraphics("com.y", nil, client: shimX) }
        #expect(await harness.core.configurationSnapshot().config.graphicsOverrides["com.y"] == AppGraphicsOverride(profile: .apps))
    }

    /// A window's settings overlay changes Android's frame rate cap, for
    /// every app, and nothing else; Android gets it at once.
    @Test func shimSetsOnlyTheFrameRateCap() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        let (shim, events) = await harness.connect(.shim(package: "com.x"))
        let before = await harness.core.configurationSnapshot().config
        #expect(before.fpsLimit != 30)

        let result = try await harness.core.setFrameRateLimit(30, client: shim)
        #expect(result.effect == .immediate && !result.issues.contains { $0.severity == .error })
        var expected = before
        expected.fpsLimit = 30
        #expect(try VMConfig.load(from: harness.paths.config) == expected)
        #expect(await events.wait { if case .configurationChanged(let c) = $0 { c.fpsLimit == 30 } else { false } } != nil)
        #expect(await eventually {
            let rates: [UInt32] = await harness.agent.requests { if case .setRefreshRate(let r) = $0 { r.fps } else { nil } }
            return rates.last == 30
        })

        // A value Android does not run at is refused and saves nothing.
        let refused = try await harness.core.setFrameRateLimit(144, client: shim)
        #expect(refused.issues.map(\.field) == ["fpsLimit"])
        #expect(try VMConfig.load(from: harness.paths.config).fpsLimit == 30)

        // The engine and callers that never said hello may not; shims still
        // may not change anything else.
        let (engine, _) = await harness.connect(.engine)
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.setFrameRateLimit(60, client: engine) }
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.setFrameRateLimit(60, client: UUID()) }
        var other = expected
        other.memoryMiB += 1024
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.updateConfiguration(other, client: shim) }
        #expect(await harness.core.configurationSnapshot().config == expected)
    }

    /// A setting that became invalid elsewhere (here: more cores than this
    /// Mac has, as after moving to a smaller Mac) never blocks one app's graphics.
    @Test func unrelatedConfigErrorsDoNotBlockAppGraphics() async throws {
        let harness = try Harness(apps: []) { $0.cpuCount = 64 }
        defer { harness.cleanUp() }
        await harness.core.start()
        let (shim, _) = await harness.connect(.shim(package: "com.x"))
        let override = AppGraphicsOverride(profile: .games)
        let result = try await harness.core.setAppGraphics("com.x", override, client: shim)
        #expect(result.issues.isEmpty)
        let saved = try VMConfig.load(from: harness.paths.config)
        #expect(saved.graphicsOverrides["com.x"] == override)
        #expect(saved.cpuCount == 64)
    }

    /// The reverse: an override a hand edit made invalid never refuses the
    /// Control Panel's own settings, which cannot change it.
    @Test func invalidOverrideDoesNotBlockConfigurationUpdates() async throws {
        var patch = GraphicsSettingsPatch()
        patch.shortSide = 721
        let harness = try Harness(apps: []) { $0.graphicsOverrides["com.x"] = AppGraphicsOverride(changes: patch) }
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        var edit = await harness.core.configurationSnapshot().config
        edit.fpsLimit = 30
        let result = try await harness.core.updateConfiguration(edit, client: panel)
        #expect(!result.issues.contains { $0.field.hasPrefix("graphicsOverrides.") })
        #expect(try VMConfig.load(from: harness.paths.config).fpsLimit == 30)
    }

    @Test func installsAnXAPKEndToEnd() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, events) = await harness.connect(.controlPanel)
        let xapk = packageFixture("fixture.xapk")

        // adbd: create/commit sessions; the commit makes Android announce the app.
        let agent = harness.agent
        harness.engine.adbShellHandler = { command in
            if command.hasPrefix("pm install-create") { return ("Success: created install session [42]\n", "", 0) }
            if command == "pm install-commit 42" {
                Task { await agent.install(FakeBridgeAgent.app("com.avodroid.fixture", label: "Avo Fixture")) }
                return ("Success\n", "", 0)
            }
            return ("", "unexpected", 1)
        }
        let installTask = Task { try await harness.core.install(InstallRequest(path: xapk.path), file: try open(xapk), client: panel) }
        try await installTask.value
        let adbd = try #require(harness.engine.adbd)

        let writes = await adbd.execWrites.map(\.command)
        #expect(writes.count == 3) // base + arm64 + xxxhdpi; x86_64 skipped
        #expect(writes.allSatisfy { $0.hasPrefix("cmd package install-write") })
        #expect(await adbd.pushed.keys.sorted() == ["/sdcard/Android/obb/com.avodroid.fixture/main.42.com.avodroid.fixture.obb"])
        let phases = events.events.compactMap { if case .installProgress(let p) = $0 { p.phase } else { nil } }
        #expect(phases.first == .inspecting)
        #expect(phases.contains(.startingVM) && phases.contains(.transferring) && phases.contains(.copyingOBB))
        #expect(phases.last == .finished)
        #expect(await eventually { await harness.core.apps().contains { $0.package == "com.avodroid.fixture" } })
    }

    @Test func rejectsPackagesAppleSiliconCannotRun() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, events) = await harness.connect(.controlPanel)
        let apk = harness.root.appending(path: "x86.apk")
        try FileManager.default.copyItem(at: packageFixture("fixture.xapk"), to: apk)
        // A text file is not a package: rejected before the VM starts.
        let text = harness.root.appending(path: "notes.apk")
        try Data("hello".utf8).write(to: text)
        await #expect(throws: (any Error).self) {
            try await harness.core.install(InstallRequest(path: text.path), file: try open(text), client: panel)
        }
        #expect(await harness.core.status().state == .stopped)
        #expect(events.events.contains { if case .installProgress(let p) = $0 { p.phase == .failed } else { false } })
    }

    @Test func engineCrashClosesWindowsAndReportsFailure() async throws {
        let harness = try Harness(apps: [FakeBridgeAgent.app("org.fdroid.fdroid", label: "F-Droid")])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (shim, events) = await harness.connect(.shim(package: "org.fdroid.fdroid"))
        let display = try await harness.core.openDisplay(OpenDisplayRequest(package: "org.fdroid.fdroid", width: 800, height: 1600, dpi: 320),
                                                         client: shim)
        harness.engine.crash()
        #expect(await events.wait { $0 == .displayClosed(displayID: display) } != nil)
        #expect(await eventually { await harness.core.status().state == .failed })
    }

    /// Android's own factory reset: avo-vmm stops instead of rebooting into
    /// recovery, and Avo erases the data as Reset Android does, then starts
    /// the fresh Android again.
    @Test func androidsFactoryResetErasesTheDataAndStartsAgain() async throws {
        let harness = try Harness(apps: [FakeBridgeAgent.app("org.fdroid.fdroid", label: "F-Droid")])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, events) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        #expect(await eventually { await harness.core.status().state == .running })
        // Avo knows the app before Android asks (the reset takes it out again).
        #expect(await events.wait { if case .appInstalled(let app) = $0 { app.package == "org.fdroid.fdroid" } else { false } } != nil)
        #expect(FileManager.default.fileExists(atPath: harness.paths.dataDisk.path))
        try Data(repeating: 7, count: 4096).write(to: harness.paths.dataDisk)
        let launches = harness.engine.launches.count

        harness.engine.exit(AndroidFactoryReset())
        #expect(await events.wait { $0 == .appRemoved(package: "org.fdroid.fdroid") } != nil)
        #expect(await eventually { harness.engine.launches.count == launches + 1 })
        #expect(await eventually { await harness.core.status().state == .running })
        // The new start made a new, unwritten data disk.
        #expect(!DataDiskStore.isWritten(harness.paths.dataDisk))
    }

    /// Android's own Restart: avo-vmm ends instead of rebooting inside, and
    /// Avo starts Android again through its usual start.
    @Test func androidsOwnRebootStartsItAgain() async throws {
        let harness = try Harness(apps: [FakeBridgeAgent.app("org.fdroid.fdroid", label: "F-Droid")])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, events) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        #expect(await eventually { await harness.core.status().state == .running })
        #expect(await events.wait { if case .appInstalled(let app) = $0 { app.package == "org.fdroid.fdroid" } else { false } } != nil)
        let launches = harness.engine.launches.count

        harness.engine.exit(AndroidRebooted())
        #expect(await eventually { harness.engine.launches.count == launches + 1 })
        #expect(await eventually { await harness.core.status().state == .running })
        // Nothing was erased: the app is still Avo's.
        #expect(!events.events.contains(.appRemoved(package: "org.fdroid.fdroid")))
    }

    @Test func incompatibleGuestIsReported() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        await harness.agent.setProtocol(version: 9, minimum: 5)
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        await #expect(throws: (any Error).self) { try await harness.core.startVM(client: panel) }
        let status = await harness.core.status()
        #expect(status.state == .failed)
        #expect(status.detail?.contains("Update Avo") == true)
    }
}

@Suite struct EngineContractTests {
    @Test func crosvmArgumentsFollowTheContract() {
        let paths = AvoPaths(home: URL(filePath: "/Users/u"), temporaryDirectory: URL(filePath: "/tmp/T"))
        var image = AndroidImage(schema: 1, version: "16.0.0", sdk: 36, kernel: "kernel", initrd: "initrd.img",
                                 partitions: ["system.img", "vendor.img"], overlayStock: "overlay_stock.img",
                                 overlayRooted: "overlay_rooted.img", files: [])
        image.directory = URL(filePath: "/img")
        var config = VMConfig(memoryMiB: 8192, cpuCount: 6, balloonWhenIdle: true, renderer: .vulkan, rooted: true)
        var args = CrosvmEngine.arguments(for: EngineLaunch(config: config, paths: paths, image: image,
                                                           bootConfigDisk: URL(filePath: "/cfg.img")))
        let joined = args.joined(separator: " ")
        #expect(args.first == "run")
        #expect(joined.contains("--cpus num-cores=6"))
        #expect(joined.contains("--mem size=8192"))
        #expect(joined.contains("--balloon-page-reporting"))
        #expect(joined.contains("--block path=/img/system.img,ro=true,id=system"))
        #expect(joined.contains("--block path=/img/overlay_rooted.img,ro=true,id=avo_overlay")) // root checkbox
        #expect(joined.contains("--block path=/cfg.img,ro=true,id=avo_config"))
        #expect(joined.contains("vulkan=true"))
        #expect(joined.contains("--vsock cid=3,uds-path=/tmp/T/com.avodroid/vsock.sock"))
        #expect(args.last == "/img/kernel")

        config.rooted = false
        config.renderer = .gles
        config.balloonWhenIdle = false
        args = CrosvmEngine.arguments(for: EngineLaunch(config: config, paths: paths, image: image,
                                                       bootConfigDisk: URL(filePath: "/cfg.img")))
        #expect(args.joined(separator: " ").contains("overlay_stock.img,ro=true,id=avo_overlay"))
        #expect(args.joined(separator: " ").contains("vulkan=false"))
        #expect(args.contains("--no-balloon"))
    }

    @Test func imageVerificationChecksSignatureAndHashes() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "avo-images-\(UUID().uuidString.prefix(8))")
        let dir = root.appending(path: "16.0.1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["kernel", "system.img", "overlay_stock.img", "overlay_rooted.img"]
        var files: [AndroidImage.File] = []
        for name in names {
            let data = Data(name.utf8)
            try data.write(to: dir.appending(path: name))
            files.append(.init(name: name, sha256: SHA256Hex.of(data), size: Int64(data.count)))
        }
        let image = AndroidImage(schema: 1, version: "16.0.1", sdk: 36, kernel: "kernel", initrd: nil, partitions: ["system.img"],
                                 overlayStock: "overlay_stock.img", overlayRooted: "overlay_rooted.img", files: files)
        let manifest = try JSONEncoder().encode(image)
        try manifest.write(to: dir.appending(path: AndroidImage.manifestName))
        let key = Curve25519SigningKey()
        try key.signature(for: manifest).write(to: dir.appending(path: AndroidImage.signatureName))

        let loaded = try AndroidImage.load(from: dir)
        try loaded.verify(publicKey: key.publicKey)
        #expect(try AndroidImage.installed(in: root).version == "16.0.1")
        #expect(throws: AvoError.imageMissing) { try AndroidImage.installed(in: root.appending(path: "nothing")) }

        // Tampering with a file or the manifest fails verification.
        try Data("evil".utf8).write(to: dir.appending(path: "system.img"))
        #expect(throws: (any Error).self) { try loaded.verify(publicKey: key.publicKey) }
        #expect(throws: (any Error).self) { try loaded.verify(publicKey: Curve25519SigningKey().publicKey) }
    }
}

typealias Curve25519SigningKey = Curve25519.Signing.PrivateKey

enum SHA256Hex {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Opens a file the way a client does before handing it to the daemon.
func open(_ url: URL) throws -> OwnedDescriptor {
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw POSIXError(.ENOENT) }
    return OwnedDescriptor(descriptor)
}

/// Package fixtures live with the AvoPackages tests (made by make-fixtures.sh).
func packageFixture(_ name: String) -> URL {
    URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../AvoPackagesTests/Fixtures/\(name)").standardizedFileURL
}
