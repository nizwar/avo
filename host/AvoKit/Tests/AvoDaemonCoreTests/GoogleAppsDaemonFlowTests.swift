import AvoADB
import AvoIO
import AvoKit
import AvoPackages
import AvoShimKit
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// FakeEngine plus root access to its "Android" (FakeSystemApps), which
/// boots with whatever its partitions hold at every engine start.
final class SystemAppsFakeEngine: SystemAppsEngine, @unchecked Sendable {
    let inner: FakeEngine
    let guest: FakeSystemApps
    var name: String { inner.name }
    var exits: AsyncStream<(any Error)?> { inner.exits }

    init(inner: FakeEngine, guest: FakeSystemApps) {
        self.inner = inner
        self.guest = guest
    }

    func start(_ launch: EngineLaunch) async throws {
        await guest.boot()
        try await inner.start(launch)
    }

    func stop() async {
        // A power off drops the guest's connection: a held commit fails.
        await guest.releaseCommit(failing: true)
        await inner.stop()
    }

    func snapshot(to url: URL) async throws { try await inner.snapshot(to: url) }
    func connect(port: UInt32) async throws -> any ByteStream { try await inner.connect(port: port) }
    func systemApps() async throws -> any SystemAppsGuest { try await guest.whenReady() }
}

/// A DaemonCore on SystemAppsFakeEngine in a temporary home.
private struct GoogleAppsHarness {
    let root: URL
    let paths: AvoPaths
    let guest: FakeSystemApps
    let core: DaemonCore

    init(guest: FakeSystemApps) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "avo-gapps-daemon-\(UUID().uuidString.prefix(8))")
        paths = AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp"))
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
        self.guest = guest
        let engine = SystemAppsFakeEngine(inner: FakeEngine(agent: FakeBridgeAgent(apps: []), adbPublicKey: adbKey.publicKey), guest: guest)
        let image = AndroidImage(schema: 1, version: "17.0.0-test", sdk: 37, kernel: "kernel", initrd: nil,
                                 partitions: ["system.img"], overlayStock: "overlay.img", overlayRooted: "overlay-rooted.img", files: [])
        let profiles = DeviceProfileCatalog(profiles: [DeviceProfile(id: DeviceProfile.defaultID, name: "Avo Virtual Device", properties: [:])])
        let host = HostInfo(physicalMemoryBytes: 32 << 30, performanceCores: 8, efficiencyCores: 4, isAppleSilicon: true, macOSVersion: "27.0")
        core = DaemonCore(.init(paths: paths, engine: engine, adbKey: adbKey, profiles: profiles, host: host,
                                shortcuts: ShortcutManager(builder: builder, paths: paths),
                                softwareVersion: "avo-host test", bootTimeout: .seconds(5), loadImage: { image }))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func controlPanel() async -> (UUID, RecordingClient) {
        let id = UUID()
        let client = RecordingClient()
        _ = await core.register(id, role: .controlPanel, proxy: ClientProxy(client))
        return (id, client)
    }

    /// The Control Panel's copy of a package, inside the cache.
    func cachedPackage() throws -> URL {
        let folder = paths.googleAppsCache.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try googleAppsPackageFolder(in: folder)
    }

    func progress(_ client: RecordingClient, _ id: UUID) -> [GoogleAppsProgress] {
        client.events.compactMap { event in
            if case .googleAppsProgress(let progress) = event, progress.id == id { return progress }
            return nil
        }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct GoogleAppsDaemonFlowTests {
    /// While the commit runs, Stop, Restart, Reset and Save Snapshot are
    /// refused (also the menu bar's Stop); afterwards they work again.
    @Test func androidControlsWaitForTheCommit() async throws {
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        await guest.set(holdCommit: true)
        let harness = try GoogleAppsHarness(guest: guest)
        defer { harness.cleanUp() }
        let (panel, client) = await harness.controlPanel()
        let request = GoogleAppsInstallRequest(source: .local(path: try harness.cachedPackage().path))
        let core = harness.core
        let install = Task { try await core.installGoogleApps(request, client: panel) }
        #expect(await eventually { await guest.commitIsHeld })
        #expect(GoogleAppsJournal.load(harness.paths)?.id == request.id)

        let refusal = AvoError.internalError(GoogleAppsGuard.refusal)
        await #expect(throws: refusal) { try await core.stopVM(client: panel) }
        await #expect(throws: refusal) { try await core.restartVM(client: panel) }
        await #expect(throws: refusal) { try await core.resetAndroid(client: panel) }
        await #expect(throws: refusal) { try await core.takeSnapshot(client: panel) }
        await #expect(throws: refusal) { try await core.stopVMFromMenuBar() }
        await #expect(throws: AvoError.self) { try await core.cancelGoogleApps(request.id, client: panel) }
        #expect(await core.vm.status.state == .running)

        await guest.releaseCommit()
        try await install.value
        #expect(harness.progress(client, request.id).last?.phase == .finished)
        // Settings › Google services follows, with no restart "pending".
        let snapshot = await core.configurationSnapshot()
        #expect(snapshot.config.gms == .bringYourOwn)
        #expect(!snapshot.pendingRestart)
        #expect(GoogleAppsJournal.load(harness.paths) == nil)

        try await core.stopVM(client: panel)
        #expect(await core.vm.status.state == .stopped)
    }

    /// The menu bar's Stop Anyway mid-commit: the install ends without
    /// restarting Android, and the next start takes the half-done commit
    /// out before Android is used.
    @Test func aForcedStopIsRepairedAtTheNextStart() async throws {
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        await guest.set(holdCommit: true)
        let harness = try GoogleAppsHarness(guest: guest)
        defer { harness.cleanUp() }
        let (panel, client) = await harness.controlPanel()
        let request = GoogleAppsInstallRequest(source: .local(path: try harness.cachedPackage().path))
        let core = harness.core
        let install = Task { try await core.installGoogleApps(request, client: panel) }
        #expect(await eventually { await guest.commitIsHeld })

        try await core.stopVMFromMenuBar(force: true)
        await #expect(throws: (any Error).self) { try await install.value }
        #expect(await core.vm.status.state == .stopped)
        #expect(harness.progress(client, request.id).last?.message == GoogleAppsInstallError.interrupted.errorDescription)
        #expect(GoogleAppsJournal.load(harness.paths) != nil)
        #expect(await guest.manifest == .partial)
        #expect(await !guest.system.isEmpty)

        try await core.startVM(client: panel)
        #expect(await core.vm.status.state == .running)
        #expect(await guest.system.isEmpty)
        #expect(await guest.steps.contains("rollback"))
        #expect(GoogleAppsJournal.load(harness.paths) == nil)
        let last = try #require(harness.progress(client, request.id).last)
        #expect(last.phase == .failed)
        #expect(last.message?.hasPrefix("Google apps were not installed; Android was restored.") == true)
        #expect(await core.configurationSnapshot().config.gms == .none)
    }

    /// A new install after a forced stop mid-commit: the half-done commit
    /// comes out first, then the new one goes in.
    @Test func anInstallSeesAnInterruptedOneThroughFirst() async throws {
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        await guest.set(holdCommit: true)
        let harness = try GoogleAppsHarness(guest: guest)
        defer { harness.cleanUp() }
        let (panel, _) = await harness.controlPanel()
        let core = harness.core
        let first = GoogleAppsInstallRequest(source: .local(path: try harness.cachedPackage().path))
        let install = Task { try await core.installGoogleApps(first, client: panel) }
        #expect(await eventually { await guest.commitIsHeld })
        try await core.stopVMFromMenuBar(force: true)
        _ = try? await install.value
        #expect(GoogleAppsJournal.load(harness.paths) != nil)

        await guest.set(holdCommit: false)
        let second = GoogleAppsInstallRequest(source: .local(path: try harness.cachedPackage().path))
        try await core.installGoogleApps(second, client: panel)
        let steps = await guest.steps
        let rollback = try #require(steps.firstIndex(of: "rollback"))
        #expect(steps[rollback...].contains("commit"))
        #expect(GoogleAppsJournal.load(harness.paths) == nil)
        #expect(await core.configurationSnapshot().config.gms == .bringYourOwn)
    }

    /// Stop pressed while the Control Panel was still handing the request
    /// over: the request is refused when it arrives, and it is not an error.
    @Test func aStopBeforeTheRequestArrivesHolds() async throws {
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        let harness = try GoogleAppsHarness(guest: guest)
        defer { harness.cleanUp() }
        let (panel, client) = await harness.controlPanel()
        let copy = try harness.cachedPackage()
        let request = GoogleAppsInstallRequest(source: .local(path: copy.path))
        try await harness.core.cancelGoogleApps(request.id, client: panel)
        await #expect(throws: AvoError.self) { try await harness.core.installGoogleApps(request, client: panel) }
        #expect(harness.progress(client, request.id).map(\.phase) == [.cancelled])
        #expect(await guest.steps.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path))
    }

    /// Reset Android takes Google apps with the data disk: the mode goes
    /// back to None and nothing is left to repair.
    @Test func resetForgetsGoogleApps() async throws {
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        let harness = try GoogleAppsHarness(guest: guest)
        defer { harness.cleanUp() }
        let (panel, _) = await harness.controlPanel()
        let request = GoogleAppsInstallRequest(source: .local(path: try harness.cachedPackage().path))
        try await harness.core.installGoogleApps(request, client: panel)
        #expect(await harness.core.configurationSnapshot().config.gms == .bringYourOwn)
        // Not a second package over the first (it could not be undone).
        let again = GoogleAppsInstallRequest(source: .local(path: try harness.cachedPackage().path))
        await #expect(throws: AvoError.internalError(GoogleAppsInstaller.alreadyInstalled)) {
            try await harness.core.installGoogleApps(again, client: panel)
        }
        try GoogleAppsJournal(id: UUID(), started: Date()).save(harness.paths)

        try await harness.core.resetAndroid(client: panel)
        #expect(await harness.core.configurationSnapshot().config.gms == .none)
        #expect(GoogleAppsJournal.load(harness.paths) == nil)
    }

    /// Google apps another Android version left on Android's storage
    /// (Settings › Google services went back to None as that version was
    /// chosen) take no package over them until Reset Android.
    @Test func leftOverGoogleAppsWaitForReset() async throws {
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        let harness = try GoogleAppsHarness(guest: guest)
        defer { harness.cleanUp() }
        let (panel, _) = await harness.controlPanel()
        try await harness.core.installGoogleApps(GoogleAppsInstallRequest(source: .local(path: try harness.cachedPackage().path)), client: panel)
        // Noted beside the data disk once Android lists Google Play.
        let record = harness.paths.data.appending(path: "google-apps.json")
        #expect(FileManager.default.fileExists(atPath: record.path))
        if !FileManager.default.fileExists(atPath: harness.paths.dataDisk.path) { try Data().write(to: harness.paths.dataDisk) }
        #expect(GoogleAppsRecord.load(harness.paths) != nil)

        var config = await harness.core.configurationSnapshot().config
        config.gms = .none
        _ = try await harness.core.updateConfiguration(config, client: panel)
        await #expect(throws: AvoError.internalError(GoogleAppsInstaller.leftOver(nil))) {
            try await harness.core.installGoogleApps(GoogleAppsInstallRequest(source: .local(path: try harness.cachedPackage().path)), client: panel)
        }

        try await harness.core.resetAndroid(client: panel)
        #expect(!FileManager.default.fileExists(atPath: record.path))
    }

    /// Remove takes Google apps out, Settings › Google services goes back
    /// to None and the record goes, so a new install is accepted.
    @Test func removeLetsGoogleAppsBeInstalledAgain() async throws {
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        let harness = try GoogleAppsHarness(guest: guest)
        defer { harness.cleanUp() }
        let (panel, client) = await harness.controlPanel()
        try await harness.core.installGoogleApps(GoogleAppsInstallRequest(source: .local(path: try harness.cachedPackage().path)), client: panel)
        await guest.set(updated: [GoogleApps.playServices])
        if !FileManager.default.fileExists(atPath: harness.paths.dataDisk.path) { try Data().write(to: harness.paths.dataDisk) }
        #expect(GoogleAppsRecord.load(harness.paths) != nil)

        let id = UUID()
        try await harness.core.removeGoogleApps(id, client: panel)
        let progress = harness.progress(client, id)
        #expect(progress.last?.phase == .finished)
        #expect(progress.allSatisfy { $0.removal })
        #expect(await harness.core.configurationSnapshot().config.gms == .none)
        #expect(GoogleAppsRecord.load(harness.paths) == nil)
        #expect(GoogleAppsJournal.load(harness.paths) == nil)
        #expect(await !guest.packages.contains(GoogleApps.playServices))
        #expect(await guest.system.isEmpty)

        try await harness.core.installGoogleApps(GoogleAppsInstallRequest(source: .local(path: try harness.cachedPackage().path)), client: panel)
        #expect(await harness.core.configurationSnapshot().config.gms == .bringYourOwn)
    }

    /// Android stopped by force mid-Remove (Stop Anyway): the next start
    /// finishes the removal before Android is used.
    @Test func aForcedStopMidRemoveIsFinishedAtTheNextStart() async throws {
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        let harness = try GoogleAppsHarness(guest: guest)
        defer { harness.cleanUp() }
        let (panel, _) = await harness.controlPanel()
        try await harness.core.installGoogleApps(GoogleAppsInstallRequest(source: .local(path: try harness.cachedPackage().path)), client: panel)
        // As if Remove had been stopped right after it noted itself.
        let system = await guest.systemPackages
        try GoogleAppsJournal(id: UUID(), started: Date(), systemPackages: system.sorted()).save(harness.paths)
        try await harness.core.stopVM(client: panel)

        try await harness.core.startVM(client: panel)
        #expect(await guest.steps.contains("rollback"))
        #expect(await guest.system.isEmpty)
        #expect(await !guest.packages.contains(GoogleApps.playStore))
        #expect(GoogleAppsJournal.load(harness.paths) == nil)
        #expect(await harness.core.configurationSnapshot().config.gms == .none)
        #expect(await harness.core.vm.status.state == .running)
    }
}
