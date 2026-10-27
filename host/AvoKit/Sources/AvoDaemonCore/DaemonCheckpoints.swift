import AvoADB
import AvoKit
import AvoPackages
import Foundation
import os

// MARK: - Checkpoints (Settings › Android › Checkpoints, CheckpointStore.swift)

/// Restore points of Android's apps and data. The user makes them (Create
/// Checkpoint, also while Android runs) and Avo makes one before each change
/// Android cannot take back: root turned on, Google apps installed or
/// removed, another device profile, and the first start of a newer Android.
/// A restore puts one back, with the settings that belong to its data.
extension DaemonCore {
    private var checkpointLogger: Logger { Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Checkpoints") }

    public func checkpoints(client: ClientID) throws -> CheckpointStatus {
        try requireControlPanel(client)
        return CheckpointStore(paths: deps.paths).status()
    }

    /// Create Checkpoint: Android's apps and data as they are now.
    public func createCheckpoint(named name: String?, client: ClientID) async throws -> Checkpoint {
        try requireControlPanel(client)
        if storageChanging { throw AvoError.storage(.changing) }
        // Not while Google apps change Android (its partitions are half written).
        try await clearForVMChange(.snapshot)
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await makeCheckpoint(.manual, detail: name?.isEmpty == false ? name : nil)
    }

    public func deleteCheckpoint(_ id: UUID, client: ClientID) throws {
        try requireControlPanel(client)
        try CheckpointStore(paths: deps.paths).delete(id)
        publishCheckpoints()
    }

    /// Android stops; its data now becomes a checkpoint of its own (so the
    /// restore can be undone); the checkpoint's data takes its place, with
    /// the settings that go with it (root, Google apps, device profile); and
    /// Android starts again when it ran. Its apps follow at that start
    /// (`syncApps`: Android's list is the truth).
    public func restoreCheckpoint(_ id: UUID, client: ClientID) async throws {
        try requireControlPanel(client)
        restartWork += 1
        defer { restartWork -= 1 }
        if storageChanging { throw AvoError.storage(.changing) }
        let store = CheckpointStore(paths: deps.paths)
        guard store.list().contains(where: { $0.id == id }) else { throw CheckpointStore.missing }
        // Never data newer than the Android that would start with it (it could not use it).
        if let data = AndroidDataFolder(store.folder(of: id)).dataRecord()?.release,
           let next = AndroidImageStore(paths: deps.paths).imageForBoot(override: deps.imageOverride)?.release,
           next.isOlder(than: data) {
            throw AvoError.internalError(String(localized: "This checkpoint’s data is from \(data.name), newer than the Android that starts now (\(next.name)). Choose \(data.name) under Android version first.", bundle: .avoKit))
        }
        try await clearForVMChange(.reset)
        let state = await vm.status.state
        let wasRunning = state != .stopped && state != .notInstalled && state != .failed
        if state != .stopped && state != .notInstalled { await vm.stop() }
        if store.hasData { try await makeCheckpoint(.restore, keeping: id) }
        let restored = try store.restore(id)
        // Avo's side follows the data, as when another folder of data is used (`adopt`).
        storageCheckedAt = nil
        bootedConfig = nil
        var new = restored.settings.applied(to: config)
        if deps.profiles.profile(id: new.deviceProfileID) == nil { new.deviceProfileID = config.deviceProfileID }
        if let seen = DataDiskStore(paths: deps.paths).status().android, VMConfig.dataDiskRangeGB.contains(seen.settingsTotalGB) {
            new.dataDiskGiB = seen.settingsTotalGB
        }
        if new != config { apply(new) }
        await fingerprints.reload()
        publishCheckpoints()
        await publishStorage()
        if wasRunning { try await ensureRunning() }
    }

    /// Before a change Android cannot take back. Nothing when there is no
    /// data yet or the drive cannot clone; a failure is logged and the
    /// change goes ahead (the user asked for it, not for the checkpoint).
    func autoCheckpoint(_ reason: Checkpoint.Reason, detail: String? = nil) async {
        let store = CheckpointStore(paths: deps.paths)
        guard !storageChanging, store.hasData, store.problem() == nil else { return }
        do {
            try await makeCheckpoint(reason, detail: detail)
        } catch {
            checkpointLogger.error("no checkpoint before \(reason.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Which change of the settings gets a checkpoint first.
    static func checkpointReason(from old: VMConfig, to new: VMConfig) -> Checkpoint.Reason? {
        if new.rooted, !old.rooted { return .root }
        if new.deviceProfileID != old.deviceProfileID || new.emulateHardware != old.emulateHardware { return .deviceProfile }
        return nil
    }

    /// A start with a newer Android than the data was last used with
    /// upgrades the data for good: a checkpoint of the older data first.
    func checkpointBeforeNewerAndroid() async {
        guard await vm.status.state == .stopped else { return }
        let images = AndroidImageStore(paths: deps.paths)
        guard let data = images.dataRecord()?.release, let next = images.imageForBoot(override: deps.imageOverride)?.release,
              data.isOlder(than: next) else { return }
        await autoCheckpoint(.androidVersion, detail: next.name)
    }

    /// Clones Android's data as a checkpoint now. A running Android first
    /// writes out what it holds in memory (`sync`), then stands still for
    /// the clone (VMManager.holdingStill), so the checkpoint is as if
    /// Android had been shut down at that moment. `keeping`: a checkpoint
    /// that must stay however many automatic ones there are.
    @discardableResult
    func makeCheckpoint(_ reason: Checkpoint.Reason, detail: String? = nil, keeping: UUID? = nil) async throws -> Checkpoint {
        let store = CheckpointStore(paths: deps.paths)
        let checkpoint = Checkpoint(reason: reason, detail: detail,
                                    android: AndroidImageStore(paths: deps.paths).dataRecord()?.release.name,
                                    settings: CheckpointSettings(config))
        if let problem = store.problem() { throw AvoError.internalError(problem) }
        let state = await vm.status.state
        if state == .running || state == .suspended { await flushAndroid() }
        try await vm.holdingStill { try store.create(checkpoint) }
        store.prune(keeping: keeping)
        publishCheckpoints()
        return checkpoint
    }

    /// Android writes its file systems' dirty pages to its disks; a checkpoint
    /// without it is still whole, as after a power loss, only older.
    private func flushAndroid() async {
        let vm = vm
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = try await vm.adbConnection().shell("sync") }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    throw AvoError.timedOut("sync")
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            checkpointLogger.notice("checkpoint without Android's sync: \(error.localizedDescription, privacy: .public)")
        }
    }

    func publishCheckpoints() {
        broadcast(.checkpoints(CheckpointStore(paths: deps.paths).status()), to: isControlPanel)
    }
}
