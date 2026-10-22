import AvoADB
import AvoKit
import AvoShimKit
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// Android's data, small: a data disk Android wrote to and the files beside it.
private func writeData(_ text: String, in paths: AvoPaths, googleApps: Bool = false) throws {
    try FileManager.default.createDirectory(at: paths.dataDisks, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: paths.dataDisk)
    try Data("key \(text)".utf8).write(to: paths.dataDisks.appending(path: "metadata.img"))
    let google = paths.data.appending(path: "google-apps.json")
    if googleApps {
        try Data("{}".utf8).write(to: google)
    } else {
        try? FileManager.default.removeItem(at: google)
    }
}

private func dataText(_ paths: AvoPaths) throws -> String {
    try String(contentsOf: paths.dataDisk, encoding: .utf8)
}

private let settings = CheckpointSettings(VMConfig())

@Suite struct CheckpointStoreTests {
    private func temporaryPaths() throws -> (root: URL, paths: AvoPaths) {
        let root = FileManager.default.temporaryDirectory.appending(path: "avo-checkpoints-\(UUID().uuidString.prefix(8))")
        let paths = AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp"))
        try paths.createDirectories()
        return (root, paths)
    }

    @Test func aCheckpointKeepsTheDataAsItWas() throws {
        let (root, paths) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CheckpointStore(paths: paths)
        try writeData("before", in: paths)
        let checkpoint = Checkpoint(reason: .manual, detail: "Clean", settings: settings)
        try store.create(checkpoint)
        // Android goes on writing: the checkpoint has its own blocks for what changed.
        try writeData("after", in: paths, googleApps: true)
        #expect(store.list() == [checkpoint])
        let kept = store.folder(of: checkpoint.id)
        #expect(try String(contentsOf: kept.appending(path: "userdata.img"), encoding: .utf8) == "before")
        #expect(try String(contentsOf: kept.appending(path: "cuttlefish/metadata.img"), encoding: .utf8) == "key before")
        #expect(!FileManager.default.fileExists(atPath: kept.appending(path: AvoPaths.dataManifestName).path))
        #expect(store.problem() == nil, "the temporary folder is on APFS")
    }

    @Test func aRestoreBringsTheDataBackAndKeepsTheCheckpoint() throws {
        let (root, paths) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CheckpointStore(paths: paths)
        try writeData("before", in: paths)
        let checkpoint = Checkpoint(reason: .googleApps, settings: settings)
        try store.create(checkpoint)
        try writeData("after", in: paths, googleApps: true)

        #expect(try store.restore(checkpoint.id) == checkpoint)
        #expect(try dataText(paths) == "before")
        #expect(try String(contentsOf: paths.dataDisks.appending(path: "metadata.img"), encoding: .utf8) == "key before")
        // What the checkpoint did not have goes: Google apps came after it.
        #expect(!FileManager.default.fileExists(atPath: paths.data.appending(path: "google-apps.json").path))
        #expect(!FileManager.default.fileExists(atPath: paths.data.appending(path: CheckpointStore.stagingName).path))
        // Restored again later, it is still whole.
        try writeData("later", in: paths)
        _ = try store.restore(checkpoint.id)
        #expect(try dataText(paths) == "before")
    }

    @Test func onlyTheNewestAutomaticCheckpointsStay() throws {
        let (root, paths) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CheckpointStore(paths: paths)
        try writeData("data", in: paths)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let manual = Checkpoint(createdAt: start, reason: .manual, settings: settings)
        try store.create(manual)
        let automatic = (1...CheckpointStatus.automaticLimit + 2).map {
            Checkpoint(createdAt: start + Double($0), reason: .root, settings: settings)
        }
        for checkpoint in automatic { try store.create(checkpoint) }
        // A checkpoint cut short (no record): not listed, and tidied away.
        let partial = store.folder(of: UUID())
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        // One whose record this Avo cannot read (another version's): not
        // listed, but kept.
        let foreign = store.folder(of: UUID())
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data(#"{"from": "a later Avo"}"#.utf8).write(to: foreign.appending(path: CheckpointStore.recordName))

        store.prune()
        let kept = store.list()
        #expect(kept.filter(\.isAutomatic).map(\.id) == automatic.suffix(CheckpointStatus.automaticLimit).reversed().map(\.id))
        #expect(kept.last == manual, "a manual checkpoint stays")
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        // The oldest automatic one, about to be restored, stays.
        let oldest = try #require(kept.filter(\.isAutomatic).last)
        try store.create(Checkpoint(createdAt: start + 100, reason: .restore, settings: settings))
        store.prune(keeping: oldest.id)
        #expect(store.list().contains(oldest))
    }

    @Test func nothingToKeepWithoutData() throws {
        let (root, paths) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CheckpointStore(paths: paths)
        // A data disk Android never wrote to (a fresh sparse file).
        FileManager.default.createFile(atPath: paths.dataDisk.path, contents: nil)
        try FileHandle(forWritingTo: paths.dataDisk).truncate(atOffset: 1 << 30)
        #expect(throws: AvoError.self) { try store.create(Checkpoint(reason: .manual, settings: settings)) }
        #expect(store.list().isEmpty)
        #expect(throws: AvoError.self) { try store.delete(UUID()) }
        #expect(throws: AvoError.self) { _ = try store.restore(UUID()) }
    }

    @Test func theSettingsThatChangeTheDataGetACheckpoint() {
        let old = VMConfig()
        var root = old
        root.rooted = true
        #expect(DaemonCore.checkpointReason(from: old, to: root) == .root)
        #expect(DaemonCore.checkpointReason(from: root, to: old) == nil, "root off changes nothing in the data")
        var phone = old
        phone.deviceProfileID = "pixel"
        #expect(DaemonCore.checkpointReason(from: old, to: phone) == .deviceProfile)
        var hardware = old
        hardware.emulateHardware.toggle()
        #expect(DaemonCore.checkpointReason(from: old, to: hardware) == .deviceProfile)
        var memory = old
        memory.memoryMiB += 1024
        #expect(DaemonCore.checkpointReason(from: old, to: memory) == nil)
    }

    @Test func settingsComeBackWithTheirData() {
        var config = VMConfig()
        config.rooted = true
        config.gms = .bringYourOwn
        config.memoryMiB = 8192
        let restored = CheckpointSettings(VMConfig()).applied(to: config)
        #expect(!restored.rooted)
        #expect(restored.gms == .none)
        #expect(restored.memoryMiB == 8192, "this Mac's settings stay")
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct CheckpointDaemonFlowTests {
    private struct Harness {
        let root: URL
        let paths: AvoPaths
        let engine: PausingEngine
        let core: DaemonCore

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "avo-checkpoint-daemon-\(UUID().uuidString.prefix(8))")
            let paths = AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp"))
            self.paths = paths
            try paths.createDirectories()
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
            let fake = FakeEngine(agent: FakeBridgeAgent(apps: []), adbPublicKey: adbKey.publicKey)
            engine = PausingEngine(fake)
            let image = AndroidImage(schema: 1, version: "17.0.0-test", sdk: 37, kernel: "kernel", initrd: nil,
                                     partitions: ["system.img"], overlayStock: "overlay.img", overlayRooted: "overlay-rooted.img", files: [])
            let profiles = DeviceProfileCatalog(profiles: [DeviceProfile(id: DeviceProfile.defaultID, name: "Avo Virtual Device", properties: [:]),
                                                           DeviceProfile(id: "pixel", name: "Pixel", properties: [:])])
            let host = HostInfo(physicalMemoryBytes: 32 << 30, performanceCores: 8, efficiencyCores: 4, isAppleSilicon: true, macOSVersion: "27.0")
            core = DaemonCore(.init(paths: paths, engine: engine, adbKey: adbKey, profiles: profiles, host: host,
                                    shortcuts: ShortcutManager(builder: builder, paths: paths),
                                    softwareVersion: "avo-host test", bootTimeout: .seconds(5), loadImage: { image }))
            try writeData("v1", in: paths)
        }

        func controlPanel() async -> UUID {
            let id = UUID()
            _ = await core.register(id, role: .controlPanel, proxy: ClientProxy(RecordingClient()))
            return id
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// While Android runs, it writes out what it holds (`sync`), then stands
    /// still for the clone and goes on: no restart, no pause the user sees.
    @Test func aCheckpointWhileAndroidRunsHoldsItStillForAMoment() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let panel = await harness.controlPanel()
        try await harness.core.startVM(client: panel)
        let checkpoint = try await harness.core.createCheckpoint(named: "  Before the update ", client: panel)
        #expect(checkpoint.detail == "Before the update")
        #expect(checkpoint.title == "Before the update")
        #expect(harness.engine.pauses == 1)
        #expect(harness.engine.resumes.count == 1)
        #expect(!harness.engine.isPaused)
        #expect(await harness.core.vm.status.state == .running)
        #expect(await harness.engine.base.adbd?.shellCommands.contains("sync") == true)
        #expect(try await harness.core.checkpoints(client: panel).checkpoints.map(\.id) == [checkpoint.id])
        #expect(harness.engine.base.launches.count == 1)
    }

    /// Root turned on: the data as it was without it is kept first, with root off.
    @Test func turningRootOnKeepsACheckpointFirst() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let panel = await harness.controlPanel()
        var config = await harness.core.configurationSnapshot().config
        config.rooted = true
        _ = try await harness.core.updateConfiguration(config, client: panel)
        let checkpoints = try await harness.core.checkpoints(client: panel).checkpoints
        #expect(checkpoints.map(\.reason) == [.root])
        #expect(checkpoints.first?.settings.rooted == false)
        #expect(harness.engine.pauses == 0, "Android was stopped: nothing to hold")
    }

    /// A restore over a stopped Android: the data and the settings that go
    /// with it come back, the data it replaced is kept as a checkpoint, and
    /// Android stays stopped.
    @Test func aRestoreBringsTheDataAndItsSettingsBack() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let panel = await harness.controlPanel()
        let clean = try await harness.core.createCheckpoint(named: nil, client: panel)
        var config = await harness.core.configurationSnapshot().config
        config.deviceProfileID = "pixel"
        _ = try await harness.core.updateConfiguration(config, client: panel)
        try writeData("v2", in: harness.paths, googleApps: true)

        try await harness.core.restoreCheckpoint(clean.id, client: panel)
        #expect(try dataText(harness.paths) == "v1")
        #expect(await harness.core.configurationSnapshot().config.deviceProfileID == DeviceProfile.defaultID)
        let reasons = try await harness.core.checkpoints(client: panel).checkpoints.map(\.reason)
        #expect(reasons == [.restore, .deviceProfile, .manual])
        let undo = try #require(try await harness.core.checkpoints(client: panel).checkpoints.first)
        #expect(undo.settings.deviceProfileID == "pixel")
        #expect(harness.engine.base.launches.isEmpty)
        // And back: the restore itself can be undone.
        try await harness.core.restoreCheckpoint(undo.id, client: panel)
        #expect(try dataText(harness.paths) == "v2")
        #expect(await harness.core.configurationSnapshot().config.deviceProfileID == "pixel")
    }

    /// Android ran: it stops for the restore and starts again with the checkpoint's data.
    @Test func aRestoreStartsAndroidAgainWhenItRan() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let panel = await harness.controlPanel()
        try await harness.core.startVM(client: panel)
        let clean = try await harness.core.createCheckpoint(named: nil, client: panel)
        try writeData("v2", in: harness.paths)
        try await harness.core.restoreCheckpoint(clean.id, client: panel)
        #expect(try dataText(harness.paths) == "v1")
        #expect(await harness.core.vm.status.state == .running)
        #expect(harness.engine.base.launches.count == 2)
    }

    @Test func resetAndroidErasesItsCheckpoints() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let panel = await harness.controlPanel()
        let checkpoint = try await harness.core.createCheckpoint(named: nil, client: panel)
        try await harness.core.resetAndroid(client: panel)
        #expect(try await harness.core.checkpoints(client: panel).checkpoints.isEmpty)
        await #expect(throws: AvoError.self) { try await harness.core.restoreCheckpoint(checkpoint.id, client: panel) }
    }

    @Test func onlyTheControlPanelHandlesCheckpoints() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let shim = UUID()
        _ = await harness.core.register(shim, role: .shim(package: "com.example"), proxy: ClientProxy(RecordingClient()))
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.createCheckpoint(named: nil, client: shim) }
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.checkpoints(client: shim) }
    }
}
