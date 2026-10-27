import AvoADB
import AvoIO
import AvoKit
import AvoPackages
import AvoShimKit
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

@Suite struct MagiskRootTests {
    private func temporaryImage() throws -> (root: URL, paths: AvoPaths, image: AndroidImage) {
        let root = FileManager.default.temporaryDirectory.appending(path: "avo-magisk-\(UUID().uuidString.prefix(8))")
        let directory = root.appending(path: "image", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("ANDROID!stock".utf8).write(to: directory.appending(path: "init_boot.img"))
        let image = AndroidImage(schema: 1, version: "test", sdk: 37, kernel: "boot.img", initrd: nil, partitions: [],
                                 overlayStock: "", overlayRooted: "", files: [], directory: directory)
        return (root, AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp")), image)
    }

    @Test func thePatchedImageBelongsToTheInitBootItCameFrom() throws {
        let (root, paths, image) = try temporaryImage()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(MagiskRoot.patchedImage(for: image, paths: paths) == nil, "nothing patched yet")
        let stock = try MagiskRoot.sha256(of: MagiskRoot.stockImage(of: image))
        try MagiskRoot.store(Data("ANDROID!patched".utf8), stock: stock, paths: paths)
        #expect(MagiskRoot.patchedImage(for: image, paths: paths) == MagiskRoot.patchedImage(paths))
        // Another Android version: patched again.
        try Data("ANDROID!newer".utf8).write(to: MagiskRoot.stockImage(of: image))
        #expect(MagiskRoot.patchedImage(for: image, paths: paths) == nil)
    }

    @Test func theEngineBootsThePatchedInitBoot() {
        let paths = AvoPaths(home: URL(filePath: "/Users/u"), temporaryDirectory: URL(filePath: "/tmp/T"))
        let launch = EngineLaunch(config: VMConfig(), paths: paths, image: CuttlefishImage.androidImage(at: URL(filePath: "/img")),
                                  bootConfigDisk: URL(filePath: "/cfg.img"))
        let patched = MagiskRoot.patchedImage(paths)
        #expect(Array(VMMEngine.arguments(images: URL(filePath: "/img"), launch: launch, initBoot: patched).suffix(2))
            == ["--init-boot", patched.path])
        #expect(!VMMEngine.arguments(images: URL(filePath: "/img"), launch: launch).contains("--init-boot"))
    }

    @Test func theScriptRunsMagisksOwnPatch() throws {
        let lines = MagiskRoot.patchScript.split(separator: "\n").map(String.init)
        #expect(lines.first == "set -e")
        let unzip = try #require(lines.firstIndex { $0.hasPrefix("unzip ") })
        let patch = try #require(lines.firstIndex { $0 == "sh ./boot_patch.sh init_boot.img" })
        for binary in ["magiskboot", "magiskinit", "magisk", "init-ld"] {
            let copy = try #require(lines.firstIndex { $0.hasSuffix(" \(binary)") && $0.hasPrefix("cp lib/arm64-v8a/") })
            #expect(unzip < copy && copy < patch)
        }
        #expect(lines.last == "chmod 644 new-boot.img", "the shell user reads the result")
        #expect(MagiskRoot.release.url.absoluteString.hasPrefix("https://github.com/topjohnwu/Magisk/releases/download/v\(MagiskRoot.release.version)/"))
        #expect(MagiskRoot.release.sha256.count == 64)
        #expect(MagiskRoot.looksPatched(Data("ANDROID!".utf8) + Data(count: 5000)))
        #expect(!MagiskRoot.looksPatched(Data("Error: no such file".utf8)))
    }
}

/// FakeEngine that roots like VMMEngine: a start boots Magisk when root is
/// on and an image was patched. With a `guest`, its Android takes Google
/// apps too (FakeSystemApps).
final class RootFakeEngine: RootEngine, SystemAppsEngine, @unchecked Sendable {
    let inner: FakeEngine
    let guest: FakeSystemApps?
    private let lock = NSLock()
    private var patched = false
    private var rooted = false
    private(set) var prepares = 0
    var failure: (any Error)?
    /// Magisk does not start this Android: a rooted start never gets ready,
    /// and Android reboots soon after (avo-vmm's `AndroidRebooted` exit).
    var rebootsRooted = false
    /// The patch waits for it (Magisk patched inside Android takes a while).
    var patchGate: Gate?
    var name: String { inner.name }
    var exits: AsyncStream<EngineExit> { inner.exits }

    init(inner: FakeEngine, guest: FakeSystemApps? = nil) {
        self.inner = inner
        self.guest = guest
    }

    var launches: [EngineLaunch] { inner.launches }

    func systemApps() async throws -> any SystemAppsGuest {
        guard let guest else { throw AvoError.vmNotRunning }
        return try await guest.whenReady()
    }

    func start(_ launch: EngineLaunch) async throws {
        await guest?.boot()
        let failing = lock.withLock {
            rooted = launch.config.rooted && patched
            return rooted && rebootsRooted
        }
        inner.refuseControlConnections = failing ? Int.max : 0
        try await inner.start(launch)
        guard failing else { return }
        // What the engine logs of a start that reboots.
        let log = launch.paths.instance.appending(path: "kernel.log")
        try? FileManager.default.createDirectory(at: launch.paths.instance, withIntermediateDirectories: true)
        try? Data("magiskinit: First Stage Init\ninit: Reboot start, reason: test\n".utf8).write(to: log)
        let inner = self.inner
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            inner.exit(AndroidRebooted())
        }
    }

    func stop() async {
        // A power off drops the guest's connection: a held commit fails.
        await guest?.releaseCommit(failing: true)
        await inner.stop()
    }

    func snapshot(to url: URL) async throws { try await inner.snapshot(to: url) }
    func connect(port: UInt32) async throws -> any ByteStream { try await inner.connect(port: port) }
    func bootedRooted() async -> Bool { lock.withLock { rooted } }
    func hasPatchedImage() async -> Bool { lock.withLock { patched } }

    func prepareRoot() async throws {
        let gate = lock.withLock { () -> Gate? in
            prepares += 1
            return patchGate
        }
        await gate?.wait()
        try lock.withLock {
            if let failure { throw failure }
            patched = true
        }
    }
}

/// Holds whoever waits until it opens.
actor Gate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        open = true
        for waiter in waiting { waiter.resume() }
        waiting.removeAll()
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct RootDaemonFlowTests {
    private struct Harness {
        let root: URL
        let paths: AvoPaths
        let engine: RootFakeEngine
        let notifications = RecordingNotifications()
        let core: DaemonCore

        init(bootTimeout: Duration = .seconds(5), guest: FakeSystemApps? = nil) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "avo-root-daemon-\(UUID().uuidString.prefix(8))")
            let paths = AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp"))
            self.paths = paths
            try FileManager.default.createDirectory(at: paths.desktop, withIntermediateDirectories: true)
            var config = VMConfig()
            config.createDesktopAlias = false
            try config.save(to: paths.config)
            let template = root.appending(path: "AvoShim.app")
            try FileManager.default.createDirectory(at: template.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: template.appending(path: "Contents/MacOS/AvoShim"))
            let info: [String: Any] = ["CFBundleExecutable": "AvoShim", "CFBundlePackageType": "APPL", "CFBundleIdentifier": "com.avodroid.shim"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: template.appending(path: "Contents/Info.plist"))
            var builder = ShimBuilder(template: template, hostApplication: URL(filePath: "/Applications/Avo.app"), directory: paths.shims)
            builder.registersWithLaunchServices = false
            let adbKey = try ADBKey.generate()
            engine = RootFakeEngine(inner: FakeEngine(agent: FakeBridgeAgent(apps: [])), guest: guest)
            let image = AndroidImage(schema: 1, version: "17.0.0-test", sdk: 37, kernel: "kernel", initrd: nil,
                                     partitions: ["system.img"], overlayStock: "overlay.img", overlayRooted: "overlay-rooted.img", files: [])
            let profiles = DeviceProfileCatalog(profiles: [DeviceProfile(id: DeviceProfile.defaultID, name: "Avo Virtual Device", properties: [:])])
            let host = HostInfo(physicalMemoryBytes: 32 << 30, performanceCores: 8, efficiencyCores: 4, isAppleSilicon: true, macOSVersion: "27.0")
            core = DaemonCore(.init(paths: paths, engine: engine, adbKey: adbKey, profiles: profiles, host: host,
                                    shortcuts: ShortcutManager(builder: builder, paths: paths), notifications: notifications,
                                    softwareVersion: "avo-host test", bootTimeout: bootTimeout, loadImage: { image }))
        }

        func controlPanel() async -> UUID {
            let id = UUID()
            _ = await core.register(id, role: .controlPanel, proxy: ClientProxy(RecordingClient()))
            return id
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        /// The Control Panel's copy of a Google apps package, inside the cache.
        func cachedPackage() throws -> URL {
            let folder = paths.googleAppsCache.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try googleAppsPackageFolder(in: folder)
        }
    }

    private func rootedAndRunning(_ harness: Harness) async -> Bool {
        guard await harness.engine.bootedRooted() else { return false }
        return await harness.core.vm.status.state == .running
    }

    /// Root turned on while Android runs: Magisk is prepared once and
    /// Android starts again, rooted.
    @Test func turningRootOnRestartsAndroidWithMagisk() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let panel = await harness.controlPanel()
        try await harness.core.startVM(client: panel)
        var config = await harness.core.configurationSnapshot().config
        config.rooted = true
        _ = try await harness.core.updateConfiguration(config, client: panel)
        // Started again, rooted, and up (the restart's boot finishes after the engine starts).
        #expect(await eventually { await rootedAndRunning(harness) })
        #expect(harness.engine.prepares == 1)
        #expect(harness.engine.launches.count == 2)
        // The next start needs no new patch.
        try await harness.core.restartVM(client: panel)
        #expect(await eventually { await rootedAndRunning(harness) })
        #expect(harness.engine.prepares == 1)
    }

    /// Magisk could not be prepared (no network): root turns off again, the Mac says why.
    @Test func aFailedPatchTurnsRootOffAgain() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.engine.failure = AvoError.installFailed("Magisk could not be downloaded from GitHub")
        let panel = await harness.controlPanel()
        try await harness.core.startVM(client: panel)
        var config = await harness.core.configurationSnapshot().config
        config.rooted = true
        _ = try await harness.core.updateConfiguration(config, client: panel)
        #expect(await eventually { await !harness.core.configurationSnapshot().config.rooted })
        #expect(harness.notifications.posted.map(\.title) == ["Root could not be turned on"])
        #expect(harness.engine.launches.count == 1, "Android was not restarted")
        #expect(await !harness.engine.bootedRooted())
    }

    /// Magisk does not start this Android: it reboots before it is ready.
    /// Root goes off again with a notification, the kernel's log of that
    /// start is kept, and Android starts without root at once, not after the
    /// boot's timeout (a minute here, longer than the test may take).
    @Test func aRootedStartThatRebootsTurnsRootOffAgain() async throws {
        let harness = try Harness(bootTimeout: .seconds(60))
        defer { harness.cleanUp() }
        harness.engine.rebootsRooted = true
        let panel = await harness.controlPanel()
        try await harness.core.startVM(client: panel)
        var config = await harness.core.configurationSnapshot().config
        config.rooted = true
        _ = try await harness.core.updateConfiguration(config, client: panel)
        #expect(await eventually(timeout: .seconds(10)) { await !harness.core.configurationSnapshot().config.rooted })
        #expect(await eventually(timeout: .seconds(10)) {
            await harness.core.vm.status.state == .running && harness.engine.launches.count == 3
        })
        #expect(await !harness.engine.bootedRooted())
        #expect(harness.engine.launches.map(\.config.rooted) == [false, true, false])
        #expect(harness.notifications.posted.map(\.title) == ["Root could not be turned on"])
        let kept = try String(contentsOf: MagiskRoot.failedBootLog(harness.paths), encoding: .utf8)
        #expect(kept.contains("init: Reboot start, reason: test"))
    }

    /// Google apps begin changing Android while Magisk is patched: the patch
    /// cuts nothing off, and the start they end with is Magisk's.
    @Test func googleAppsDuringThePatchGoOnUndisturbed() async throws {
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        await guest.set(holdCommit: true)
        let harness = try Harness(guest: guest)
        defer { harness.cleanUp() }
        let gate = Gate()
        harness.engine.patchGate = gate
        let panel = await harness.controlPanel()
        try await harness.core.startVM(client: panel)
        var config = await harness.core.configurationSnapshot().config
        config.rooted = true
        _ = try await harness.core.updateConfiguration(config, client: panel)
        #expect(await eventually { harness.engine.prepares == 1 })

        let request = GoogleAppsInstallRequest(source: .local(path: try harness.cachedPackage().path))
        let core = harness.core
        let install = Task { try await core.installGoogleApps(request, client: panel) }
        #expect(await eventually { await guest.commitIsHeld })
        await gate.release()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await guest.commitIsHeld, "no restart cut the commit off")
        #expect(harness.engine.launches.count == 1)
        await guest.releaseCommit()
        try await install.value
        #expect(await eventually { await rootedAndRunning(harness) })
        #expect(harness.engine.launches.map(\.config.rooted) == [false, true], "Google apps' restart is Magisk's start")
        let after = await harness.core.configurationSnapshot().config
        #expect(after.rooted && after.gms == .bringYourOwn)
        #expect(harness.notifications.posted.isEmpty)
    }

    /// The patch cut short as Google apps restart Android under it: root
    /// stays on, and the next start patches again.
    @Test func aPatchCutShortByGoogleAppsIsTriedAgain() async throws {
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        await guest.set(holdCommit: true)
        let harness = try Harness(guest: guest)
        defer { harness.cleanUp() }
        await harness.core.start()
        let gate = Gate()
        harness.engine.patchGate = gate
        harness.engine.failure = AvoError.guestUnavailable
        let panel = await harness.controlPanel()
        try await harness.core.startVM(client: panel)
        var config = await harness.core.configurationSnapshot().config
        config.rooted = true
        _ = try await harness.core.updateConfiguration(config, client: panel)
        #expect(await eventually { harness.engine.prepares == 1 })

        let request = GoogleAppsInstallRequest(source: .local(path: try harness.cachedPackage().path))
        let core = harness.core
        let install = Task { try await core.installGoogleApps(request, client: panel) }
        #expect(await eventually { await guest.commitIsHeld })
        await gate.release()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await harness.core.configurationSnapshot().config.rooted)
        #expect(harness.notifications.posted.isEmpty)

        harness.engine.failure = nil
        await guest.releaseCommit()
        try await install.value
        #expect(await eventually { await rootedAndRunning(harness) })
        #expect(harness.engine.prepares == 2)
        #expect(await harness.core.configurationSnapshot().config.rooted)
        #expect(harness.notifications.posted.isEmpty)
    }

    /// A start with Magisk that never began (Android's data moving), or that
    /// a stop cut short, did not fail its trial; Android's own reboot did.
    @Test func onlyAStartThatRanFailsTheRootTrial() {
        #expect(DaemonCore.failsRootTrial(AvoError.timedOut("Android boot"), rebooted: false))
        #expect(DaemonCore.failsRootTrial(AvoError.vmStartFailed("engine crashed"), rebooted: false))
        #expect(!DaemonCore.failsRootTrial(AvoError.storage(.changing), rebooted: false))
        #expect(!DaemonCore.failsRootTrial(CancellationError(), rebooted: false), "a stop")
        #expect(DaemonCore.failsRootTrial(CancellationError(), rebooted: true), "Android's own reboot")
    }
}

/// FakeEngine that records Settings › Devices as VMMEngine applies them.
final class DeviceSettingsFakeEngine: DeviceSettingsEngine, @unchecked Sendable {
    let inner = FakeEngine(agent: FakeBridgeAgent(apps: []))
    private let lock = NSLock()
    private var _applied: [VMConfig] = []
    var applied: [VMConfig] { lock.withLock { _applied } }
    var name: String { inner.name }
    var exits: AsyncStream<EngineExit> { inner.exits }

    func start(_ launch: EngineLaunch) async throws { try await inner.start(launch) }
    func stop() async { await inner.stop() }
    func snapshot(to url: URL) async throws { try await inner.snapshot(to: url) }
    func connect(port: UInt32) async throws -> any ByteStream { try await inner.connect(port: port) }
    func applyDeviceSettings(_ config: VMConfig) async { lock.withLock { _applied.append(config) } }
}

final class RecordingClipboard: ClipboardBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    func start(onChange: @escaping @Sendable (String) -> Void) { lock.withLock { _calls.append("start") } }
    func set(_ text: String) { lock.withLock { _calls.append("set \(text)") } }
    func stop() { lock.withLock { _calls.append("stop") } }
}

@Suite struct DeviceSettingsTests {
    @Test func networkSpeedsAreEngineCommands() {
        #expect(NetworkSpeed.full.engineCommand == "network off")
        #expect(NetworkSpeed.edge.engineCommand == "network 237 118 300")
        #expect(NetworkSpeed.nr.badge == "5G" && NetworkSpeed.lte.badge == "4G")
        // Slower types are slower, and wait longer.
        let limited = NetworkSpeed.allCases.filter { $0 != .full }
        #expect(zip(limited, limited.dropFirst()).allSatisfy { $0.limits.downKbps > $1.limits.downKbps && $0.limits.latencyMs < $1.limits.latencyMs })
    }

    @Test func devicesApplyAtOnceAndOldFilesKeepDefaults() throws {
        let old = VMConfig()
        var new = old
        new.wifiEnabled = false
        #expect(new.effect(of: old) == .immediate)
        new.networkSpeed = .edge
        new.shareMacBluetooth = false
        #expect(new.effect(of: old) == .immediate)
        let saved = try JSONDecoder().decode(VMConfig.self, from: try JSONEncoder().encode(new))
        #expect(saved.wifiEnabled == false && saved.networkSpeed == .edge && saved.shareMacBluetooth == false)
        let before = try JSONDecoder().decode(VMConfig.self, from: Data(#"{"memoryMiB": 4096}"#.utf8))
        #expect(before.wifiEnabled && before.networkSpeed == .full && before.shareMacBluetooth)
    }

    @Test func theModemFollowsTheMobileNetworkSettings() throws {
        var config = VMConfig()
        #expect(config.cellularCommand == "cellular off", "a Wi-Fi-only phone by default")
        config.cellularEnabled = true
        #expect(config.cellularCommand == "cellular lte 4")
        config.mobileNetworkType = .edge
        config.cellularSignal = 9
        #expect(config.cellularCommand == "cellular edge 4", "at most 4 bars")
        #expect(MobileNetworkType.edge.typicalSpeed == .edge && MobileNetworkType.nr.badge == "5G")
        let hand = try JSONDecoder().decode(VMConfig.self, from: Data(#"{"cellularEnabled": true, "cellularSignal": -3}"#.utf8))
        #expect(hand.cellularSignal == 0)
    }

    @Test func aChangeReachesTheRunningEngine() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "avo-devices-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp"))
        try FileManager.default.createDirectory(at: paths.desktop, withIntermediateDirectories: true)
        var config = VMConfig()
        config.createDesktopAlias = false
        try config.save(to: paths.config)
        let template = root.appending(path: "AvoShim.app")
        try FileManager.default.createDirectory(at: template.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let builder = ShimBuilder(template: template, hostApplication: URL(filePath: "/Applications/Avo.app"), directory: paths.shims)
        let engine = DeviceSettingsFakeEngine()
        let image = AndroidImage(schema: 1, version: "17", sdk: 37, kernel: "kernel", initrd: nil, partitions: [],
                                 overlayStock: "", overlayRooted: "", files: [])
        let core = DaemonCore(.init(paths: paths, engine: engine, adbKey: try ADBKey.generate(),
                                    profiles: DeviceProfileCatalog(profiles: [DeviceProfile(id: DeviceProfile.defaultID, name: "Avo", properties: [:])]),
                                    host: HostInfo(physicalMemoryBytes: 32 << 30, performanceCores: 8, efficiencyCores: 4, isAppleSilicon: true, macOSVersion: "27.0"),
                                    shortcuts: ShortcutManager(builder: builder, paths: paths),
                                    softwareVersion: "test", bootTimeout: .seconds(5), loadImage: { image }))
        let panel = UUID()
        _ = await core.register(panel, role: .controlPanel, proxy: ClientProxy(RecordingClient()))
        var new = await core.configurationSnapshot().config
        new.networkSpeed = .lte
        _ = try await core.updateConfiguration(new, client: panel)
        #expect(engine.applied.map(\.networkSpeed) == [.lte])
        // Anything else leaves the engine alone.
        new.addToDock = true
        _ = try await core.updateConfiguration(new, client: panel)
        #expect(engine.applied.count == 1)
        // The microphone too, at once.
        new.microphoneEnabled = false
        _ = try await core.updateConfiguration(new, client: panel)
        #expect(engine.applied.last?.microphoneEnabled == false)
    }

    /// Clipboard off: the Mac's clipboard is no longer watched, and nothing
    /// copied on either side crosses over. On, it is watched only while
    /// Android runs.
    @Test func theClipboardIsLeftAloneWhenNotShared() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "avo-clip-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp"))
        try FileManager.default.createDirectory(at: paths.desktop, withIntermediateDirectories: true)
        var config = VMConfig()
        config.createDesktopAlias = false
        try config.save(to: paths.config)
        let template = root.appending(path: "AvoShim.app")
        try FileManager.default.createDirectory(at: template.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let builder = ShimBuilder(template: template, hostApplication: URL(filePath: "/Applications/Avo.app"), directory: paths.shims)
        let clipboard = RecordingClipboard()
        let image = AndroidImage(schema: 1, version: "17", sdk: 37, kernel: "kernel", initrd: nil, partitions: [],
                                 overlayStock: "", overlayRooted: "", files: [])
        let core = DaemonCore(.init(paths: paths, engine: DeviceSettingsFakeEngine(), adbKey: try ADBKey.generate(),
                                    profiles: DeviceProfileCatalog(profiles: [DeviceProfile(id: DeviceProfile.defaultID, name: "Avo", properties: [:])]),
                                    host: HostInfo(physicalMemoryBytes: 32 << 30, performanceCores: 8, efficiencyCores: 4, isAppleSilicon: true, macOSVersion: "27.0"),
                                    shortcuts: ShortcutManager(builder: builder, paths: paths), clipboard: clipboard,
                                    softwareVersion: "test", bootTimeout: .seconds(5), loadImage: { image }))
        await core.start()
        #expect(clipboard.calls == [], "Android does not run yet")
        let panel = UUID()
        _ = await core.register(panel, role: .controlPanel, proxy: ClientProxy(RecordingClient()))
        try await core.startVM(client: panel)
        #expect(await eventually { clipboard.calls == ["start"] })
        var new = await core.configurationSnapshot().config
        new.shareClipboard = false
        _ = try await core.updateConfiguration(new, client: panel)
        #expect(clipboard.calls == ["start", "stop"])
        await core.hostClipboardChanged("copied on the Mac")
        new.shareClipboard = true
        _ = try await core.updateConfiguration(new, client: panel)
        #expect(clipboard.calls == ["start", "stop", "start"])
        try await core.stopVM(client: panel)
        #expect(await eventually { clipboard.calls == ["start", "stop", "start", "stop"] })
    }
}
