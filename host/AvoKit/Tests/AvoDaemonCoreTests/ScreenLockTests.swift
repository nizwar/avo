import AvoADB
import AvoIO
import AvoKit
import AvoProtocol
import AvoShimKit
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// What Android's shell prints, and the commands that unlock it (HostAgent's
/// "Screen lock"); outputs as Android 17 (Cuttlefish) gives them.
@Suite struct GuestScreenLockTests {
    @Test func readsWhetherAndroidIsLocked() {
        let boot = """
            ce=
            user=RUNNING_LOCKED
             User "Owner" (id=0, flags=0xc13) (current): trusted=0, trustManaged=0, deviceLocked=1, isActiveUnlockRunning=0, strongAuthRequired=0x1
            """
        #expect(GuestScreenLock.state(boot) == .init(storageLocked: true, keyguardLocked: true))
        #expect(GuestScreenLock.state(boot).locked)
        // `verify` opened the storage; the lock screen still covers every display.
        let verified = "ce=true\nuser=RUNNING_UNLOCKED\n User \"Owner\" (id=0, flags=0xc13) (current): trusted=0, deviceLocked=1\n"
        #expect(GuestScreenLock.state(verified) == .init(storageLocked: false, keyguardLocked: true))
        #expect(GuestScreenLock.state(verified).locked)
        let unlocked = "ce=true\nuser=RUNNING_UNLOCKED\n User \"Owner\" (id=0, flags=0xc13) (current): trusted=0, deviceLocked=0\n"
        #expect(!GuestScreenLock.state(unlocked).locked)
        // Without the property, ActivityManager's state counts; without either, nothing is known.
        #expect(GuestScreenLock.state("ce=\nuser=RUNNING_UNLOCKING\n").storageLocked == false)
        #expect(GuestScreenLock.state("ce=\nuser=\n") == .init())
        #expect(!GuestScreenLock.state("").locked)
    }

    @Test func readsWhatTheScreenLockAsksFor() {
        func dump(_ type: String) -> String {
            """
            Current lock settings service state:

            User State:
              User 0
                LSKF-based SP protector ID: 14f08a6752648d4c
                SID: 0000000000000000
                Quality: 0
                CredentialType: \(type)
                IsLockScreenDisabled: true
            """
        }
        #expect(GuestScreenLock.credential(dumpsys: dump("PATTERN")) == .pattern)
        #expect(GuestScreenLock.credential(dumpsys: dump("PIN")) == .pin)
        #expect(GuestScreenLock.credential(dumpsys: dump("PASSWORD")) == .password)
        #expect(GuestScreenLock.credential(dumpsys: dump("PASSWORD_OR_PIN")) == .password)
        #expect(GuestScreenLock.credential(dumpsys: dump("NONE")) == nil)
        #expect(GuestScreenLock.credential(dumpsys: "") == nil)
        // Another user's lock is not user 0's.
        let twoUsers = "User State:\n  User 10\n    CredentialType: PIN\n  User 0\n    CredentialType: PATTERN\n"
        #expect(GuestScreenLock.credential(dumpsys: twoUsers) == .pattern)
        #expect(GuestScreenLock.credential(dumpsys: "User State:\n  User 10\n    CredentialType: PIN\n") == nil)
    }

    @Test func quotesTheCredentialForTheShell() throws {
        let password = try #require(ScreenLockCredential(#"ab'c d%se"f$g"#, kind: .password))
        #expect(GuestScreenLock.verifyCommand(password) == #"cmd lock_settings verify --old 'ab'\''c d%se"f$g'"#)
        let pattern = try #require(ScreenLockCredential("1235789", kind: .pattern))
        #expect(GuestScreenLock.verifyCommand(pattern) == "cmd lock_settings verify --old '1235789'")
    }

    /// `verify` repeats a wrong credential; only the outcome leaves.
    @Test func readsWhatVerifySaid() {
        #expect(GuestScreenLock.outcome(exitCode: 0, output: "Lock credential verified successfully\n") == .verified)
        #expect(GuestScreenLock.outcome(exitCode: 255, output: "Old password '0000' didn't match\n") == .wrong)
        #expect(GuestScreenLock.outcome(exitCode: 255, output: "Request throttled\n") == .throttled)
        #expect(GuestScreenLock.outcome(exitCode: 255, output: "Old password provided but user has no password\n") == .noLock)
        #expect(GuestScreenLock.outcome(exitCode: 255, output: "Error while executing command: verify\n") == .failed)
        #expect(GuestScreenLock.outcome(exitCode: 1, output: "Lock credential verified successfully") == .failed)
    }

    /// `uiautomator dump` of display 0 with the pattern bouncer up (trimmed).
    static let patternBouncer = """
        <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="" resource-id="com.android.systemui:id/keyguard_bouncer_container" class="android.widget.FrameLayout" package="com.android.systemui" content-desc="" bounds="[0,0][720,1280]"><node index="0" text="Draw pattern" resource-id="com.android.systemui:id/bouncer_primary_message_area" class="android.widget.TextView" package="com.android.systemui" bounds="[12,144][708,193]" /><node index="1" text="" resource-id="com.android.systemui:id/lockPatternView" class="android.view.View" package="com.android.systemui" content-desc="" checkable="false" bounds="[12,292][708,988]" /></node></hierarchy>
        """

    @Test func findsTheBouncerOnAndroidsOwnScreen() {
        #expect(GuestScreenLock.bouncer(inDump: Self.patternBouncer) == .pattern(.init(x: 12, y: 292, width: 696, height: 696)))
        let password = #"<hierarchy><node index="0" text="" resource-id="com.android.systemui:id/keyguard_password_view" bounds="[12,104][708,1160]"><node index="0" text="" resource-id="com.android.systemui:id/passwordEntry" class="android.widget.EditText" password="true" focused="true" bounds="[60,600][660,680]" /></node></hierarchy>"#
        #expect(GuestScreenLock.bouncer(inDump: password) == .password)
        let pin = #"<hierarchy><node index="0" text="" resource-id="com.android.systemui:id/pinEntry" bounds="[72,280][648,390]" /></hierarchy>"#
        #expect(GuestScreenLock.bouncer(inDump: pin) == .pin)
        // An app in front of Android's own screen: nothing is typed into it.
        let app = #"<hierarchy><node index="0" text="" resource-id="com.example.notes:id/editor" class="android.widget.EditText" bounds="[0,0][720,1280]" /></hierarchy>"#
        #expect(GuestScreenLock.bouncer(inDump: app) == nil)
        #expect(GuestScreenLock.bouncer(inDump: "ERROR: could not get idle state.") == nil)
        #expect(GuestScreenLock.Bouncer.pin.takes(.pin) && !GuestScreenLock.Bouncer.pin.takes(.password))
    }

    /// The pattern drawn through each dot's centre, as on the test VM.
    @Test func drawsThePatternOnTheBouncer() {
        let frame = GuestScreenLock.Frame(x: 12, y: 292, width: 696, height: 696)
        #expect(GuestScreenLock.patternCommand("1235789", in: frame) == [
            "input -d 0 motionevent DOWN 128 408", "input -d 0 motionevent MOVE 360 408", "input -d 0 motionevent MOVE 592 408",
            "input -d 0 motionevent MOVE 360 640", "input -d 0 motionevent MOVE 128 872", "input -d 0 motionevent MOVE 360 872",
            "input -d 0 motionevent MOVE 592 872", "input -d 0 motionevent UP 592 872",
        ].joined(separator: " && "))
    }

    /// `input text` turns "%s" into a space: the text goes in pieces ending at "%".
    @Test func typesTheCredentialInPieces() {
        #expect(GuestScreenLock.typingCommand("1234", enter: false) == "input -d 0 text '1234'")
        #expect(GuestScreenLock.typingCommand(#"ab'c d%se"f$g"#, enter: true)
                == #"input -d 0 text 'ab'\''c d%' && input -d 0 text 'se"f$g' && input -d 0 keyevent 66"#)
        #expect(GuestScreenLock.typingCommand("%%", enter: false) == "input -d 0 text '%' && input -d 0 text '%'")
    }

    /// Apps resolve while Android is locked too, and Android's Settings is one of the apps.
    @Test func listsEveryLauncherAppAndSettings() {
        #expect(HostAgent.launchableCommand.contains("--query-flags 0xC0000"))
        #expect(HostAgent.featuredSystemPackages.contains("com.android.settings"))
    }
}

/// FakeEngine plus Android's screen lock, as HostAgent reports and unlocks it.
final class ScreenLockFakeEngine: ScreenLockEngine, @unchecked Sendable {
    let inner: FakeEngine
    let screenLockUpdates: AsyncStream<AndroidScreenLock?>
    private let sink: AsyncStream<AndroidScreenLock?>.Continuation
    private let lock = NSLock()
    private var current: AndroidScreenLock?
    private var _received: [String] = []
    /// The credential Android takes.
    let right: String

    var name: String { inner.name }
    var exits: AsyncStream<EngineExit> { inner.exits }
    /// Every credential that reached "Android".
    var received: [String] { lock.withLock { _received } }

    init(inner: FakeEngine, locked: AndroidScreenLock?, right: String) {
        self.inner = inner
        self.right = right
        current = locked
        (screenLockUpdates, sink) = AsyncStream.makeStream(of: AndroidScreenLock?.self)
    }

    func start(_ launch: EngineLaunch) async throws {
        try await inner.start(launch)
        // Every start reports, before Android is ready (HostAgent.prepare).
        sink.yield(lock.withLock { current })
    }

    func stop() async { await inner.stop() }
    func snapshot(to url: URL) async throws { try await inner.snapshot(to: url) }
    func connect(port: UInt32) async throws -> any ByteStream { try await inner.connect(port: port) }
    func screenLock() async -> AndroidScreenLock? { lock.withLock { current } }

    func unlockScreen(_ credential: ScreenLockCredential) async throws {
        lock.withLock { _received.append(credential.value) }
        guard credential.value == right else { throw AvoError.screenLockRejected(throttled: false) }
        set(nil)
    }

    func set(_ new: AndroidScreenLock?) {
        lock.withLock { current = new }
        sink.yield(new)
    }
}

/// A DaemonCore on ScreenLockFakeEngine in a temporary home, optionally with
/// records it had before (apps.json).
private struct ScreenLockHarness {
    let root: URL
    let paths: AvoPaths
    let agent: FakeBridgeAgent
    let engine: ScreenLockFakeEngine
    let core: DaemonCore

    init(apps: [Avo_V1_AppInfo], records: [AppRecord] = [], locked: AndroidScreenLock? = nil, right: String = "1235") throws {
        root = FileManager.default.temporaryDirectory.appending(path: "avo-lock-\(UUID().uuidString.prefix(8))")
        paths = AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp"))
        try FileManager.default.createDirectory(at: paths.desktop, withIntermediateDirectories: true)
        var config = VMConfig()
        config.createDesktopAlias = false
        try config.save(to: paths.config)
        if !records.isEmpty { try AvoXPC.encode(records).write(to: paths.registry) }

        let template = root.appending(path: "AvoShim.app")
        try FileManager.default.createDirectory(at: template.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: template.appending(path: "Contents/MacOS/AvoShim"))
        let info: [String: Any] = ["CFBundleExecutable": "AvoShim", "CFBundlePackageType": "APPL", "CFBundleIdentifier": "com.avodroid.shim"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: template.appending(path: "Contents/Info.plist"))
        var builder = ShimBuilder(template: template, hostApplication: URL(filePath: "/Applications/Avo.app"), directory: paths.shims)
        builder.registersWithLaunchServices = false

        let adbKey = try ADBKey.generate()
        agent = FakeBridgeAgent(apps: apps)
        engine = ScreenLockFakeEngine(inner: FakeEngine(agent: agent, adbPublicKey: adbKey.publicKey), locked: locked, right: right)
        let image = AndroidImage(schema: 1, version: "17.0.0-test", sdk: 37, kernel: "kernel", initrd: nil,
                                 partitions: ["system.img"], overlayStock: "overlay.img", overlayRooted: "overlay-rooted.img", files: [])
        let profiles = DeviceProfileCatalog(profiles: [DeviceProfile(id: DeviceProfile.defaultID, name: "Avo Virtual Device", properties: [:])])
        let host = HostInfo(physicalMemoryBytes: 32 << 30, performanceCores: 8, efficiencyCores: 4, isAppleSilicon: true, macOSVersion: "27.0")
        core = DaemonCore(.init(paths: paths, engine: engine, adbKey: adbKey, profiles: profiles, host: host,
                                shortcuts: ShortcutManager(builder: builder, paths: paths),
                                softwareVersion: "avo-host test", bootTimeout: .seconds(5), loadImage: { image }))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func connect(_ role: ClientHello.Role) async -> (UUID, RecordingClient) {
        let id = UUID()
        let client = RecordingClient()
        _ = await core.register(id, role: role, proxy: ClientProxy(client))
        return (id, client)
    }

    func packages() async -> [String] { await core.apps().map(\.package).sorted() }

    /// Every file under the temporary home (but the sparse data disk), for
    /// what must never be written down.
    func filesContain(_ text: String) -> Bool {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])?.compactMap { $0 as? URL } ?? []
        return files.contains { file in
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 16 << 20 else { return false }
            return (try? Data(contentsOf: file))?.range(of: Data(text.utf8)) != nil
        }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct ScreenLockDaemonTests {
    /// The bug: Android locked by its screen lock resolved only its
    /// direct-boot apps, and the sync after boot took every other app's
    /// record and shim away. Now a record goes only with its package.
    @Test func appsThatDoNotResolveKeepTheirRecords() async throws {
        let game = AppRecord(package: "com.example.game", label: "Game", shortcuts: .init(shimPath: "/nonexistent/Game.app"))
        let gone = AppRecord(package: "com.example.gone", label: "Gone")
        let harness = try ScreenLockHarness(apps: [
            FakeBridgeAgent.app("com.example.game", label: "Game", launchable: false), // installed, does not resolve now
            FakeBridgeAgent.app("com.example.notes", label: "Notes"),
        ], records: [game, gone])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        #expect(await eventually { await harness.packages() == ["com.example.game", "com.example.notes"] })
        // The record is the one Avo had, with its shim.
        let kept = try #require(await harness.core.apps().first { $0.package == "com.example.game" })
        #expect(kept.shortcuts.shimPath == "/nonexistent/Game.app")
        #expect(kept.launchable)
    }

    /// A listing with nothing in it is a listing that failed: nothing goes.
    @Test func anEmptyListingRemovesNothing() async throws {
        let records = [AppRecord(package: "com.example.a", label: "A"), AppRecord(package: "com.example.b", label: "B")]
        let harness = try ScreenLockHarness(apps: [], records: records)
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await harness.packages() == ["com.example.a", "com.example.b"])
    }

    /// Locked after boot: every client hears it, windows are refused (they
    /// show their own lock), a wrong credential is refused, and the right
    /// one unlocks; apps then sync again, and a shim missing comes back.
    @Test func lockedAndroidIsUnlockedFromAnyWindow() async throws {
        let harness = try ScreenLockHarness(apps: [FakeBridgeAgent.app("com.example.notes", label: "Notes")],
                                            locked: AndroidScreenLock(credential: .pattern), right: "1235")
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, panelEvents) = await harness.connect(.controlPanel)
        let (shim, shimEvents) = await harness.connect(.shim(package: "com.example.notes"))
        try await harness.core.startVM(client: panel)
        #expect(await eventually { await harness.core.status().screenLock?.credential == .pattern })
        #expect(await harness.core.status().state == .running)
        #expect(await shimEvents.wait { if case .vmStatus(let s) = $0 { s.screenLock != nil } else { false } } != nil)

        let request = OpenDisplayRequest(package: "com.example.notes", width: 800, height: 1600, dpi: 320)
        await #expect(throws: AvoError.androidLocked) { try await harness.core.openDisplay(request, client: shim) }
        #expect(await harness.agent.requests { if case .launch(let l) = $0 { l } else { nil } }.isEmpty)

        // Wrong, not even a pattern, and a caller that is no client.
        await #expect(throws: AvoError.screenLockRejected(throttled: false)) {
            try await harness.core.unlockAndroid(credential: "1478", client: shim)
        }
        await #expect(throws: AvoError.screenLockRejected(throttled: false)) {
            try await harness.core.unlockAndroid(credential: "12", client: panel)
        }
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.unlockAndroid(credential: "1235", client: UUID()) }
        #expect(harness.engine.received == ["1478"]) // only a well-formed one reaches Android

        // An app that did not resolve while locked does after the unlock: the sync gives it a shim.
        #expect(await eventually { await harness.core.apps().first?.shortcuts.shimPath != nil })
        let notes = try #require(await harness.core.apps().first)
        let shimPath = try #require(notes.shortcuts.shimPath)
        try FileManager.default.removeItem(atPath: shimPath)
        await harness.agent.setApps([FakeBridgeAgent.app("com.example.notes", label: "Notes"),
                                     FakeBridgeAgent.app("com.example.game", label: "Game")])

        try await harness.core.unlockAndroid(credential: "1235", client: shim)
        #expect(await eventually { await harness.core.status().screenLock == nil })
        #expect(await panelEvents.wait { if case .vmStatus(let s) = $0 { s.state == .running && s.screenLock == nil } else { false } } != nil)
        #expect(await eventually {
            let apps = await harness.core.apps()
            return apps.map(\.package).sorted() == ["com.example.game", "com.example.notes"]
                && apps.allSatisfy { $0.shortcuts.shimPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }
        })
        let display = try await harness.core.openDisplay(request, client: shim)
        #expect(await shimEvents.wait { $0 == .displayReady(displayID: display) } != nil)
        // Unlocking an unlocked Android is nothing to do.
        try await harness.core.unlockAndroid(credential: "1235", client: panel)
        #expect(harness.engine.received == ["1478", "1235"])
    }

    /// A password reaches Android as typed and is written down nowhere; the
    /// lock lasts one run (a stop clears it, a report after the stop is ignored).
    @Test func passwordsAreNeverKeptAndTheLockEndsWithTheRun() async throws {
        let harness = try ScreenLockHarness(apps: [FakeBridgeAgent.app("com.example.notes", label: "Notes")],
                                            locked: AndroidScreenLock(credential: .password), right: #"s3cret 'Avo' %s!"#)
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        #expect(await eventually { await harness.core.status().screenLock?.credential == .password })
        await #expect(throws: AvoError.screenLockRejected(throttled: false)) {
            try await harness.core.unlockAndroid(credential: "wr0ng-Avo-pass", client: panel)
        }
        try await harness.core.unlockAndroid(credential: #"s3cret 'Avo' %s!"#, client: panel)
        #expect(harness.engine.received == ["wr0ng-Avo-pass", #"s3cret 'Avo' %s!"#])
        #expect(await eventually { await harness.core.status().screenLock == nil })
        #expect(!harness.filesContain("wr0ng-Avo-pass") && !harness.filesContain("s3cret 'Avo'"))

        harness.engine.set(AndroidScreenLock(credential: .pin)) // the lock screen came back
        #expect(await eventually { await harness.core.status().screenLock?.credential == .pin })
        try await harness.core.stopVM(client: panel)
        #expect(await harness.core.status().screenLock == nil)
        await harness.core.vm.setScreenLock(AndroidScreenLock(credential: .pin))
        #expect(await harness.core.status().screenLock == nil)
    }
}
