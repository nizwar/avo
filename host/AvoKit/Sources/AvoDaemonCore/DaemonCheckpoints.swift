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
        // A restore cut short needs both to be finished or undone.
        if let journal = RestoreJournal.load(deps.paths), journal.checkpoint == id || journal.before == id {
            throw AvoError.internalError(RestoreJournal.cutShortMessage)
        }
        try CheckpointStore(paths: deps.paths).delete(id)
        publishCheckpoints()
    }

    /// Android stops; its data now becomes a checkpoint of its own (so the
    /// restore can be undone); the checkpoint's data takes its place, with
    /// the settings that go with it (root, Google apps, device profile); and
    /// Android starts again when it ran. Its apps follow at that start
    /// (`syncApps`: Android's list is the truth). A restore that fails
    /// before it changed anything starts a running Android again; one cut
    /// short while it replaced the data is finished or undone at once, or
    /// else before the next start (RestoreJournal).
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
        let restored: Checkpoint
        do {
            // Data a restore cut short left half replaced is not worth a checkpoint.
            let before = store.hasData && !RestoreJournal.exists(in: deps.paths.data) ? try await makeCheckpoint(.restore, keeping: id) : nil
            restored = try store.restore(id, before: before?.id)
        } catch {
            guard RestoreJournal.exists(in: deps.paths.data) else {
                // Nothing changed: Android goes on as it was.
                checkpointLogger.error("no restore of \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if wasRunning { try? await ensureRunning() }
                throw error
            }
            checkpointLogger.error("restoring \(id.uuidString, privacy: .public) was cut short: \(error.localizedDescription, privacy: .public)")
            switch await finishInterruptedRestore() {
            case .finished?:
                if wasRunning { try await ensureRunning() }
                return
            case .undone?:
                if wasRunning { try? await ensureRunning() }
                throw error
            case nil:
                // Android stays stopped: the next start finishes it first, or refuses.
                throw error
            }
        }
        followRestoredData(restored)
        RestoreJournal.remove(deps.paths)
        await fingerprints.reload()
        publishCheckpoints()
        await publishStorage()
        if wasRunning { try await ensureRunning() }
    }

    /// Avo's side follows the data a restore put back, as when another
    /// folder of data is used (`adopt`): the settings that go with it, and
    /// the size Android created its storage with.
    private func followRestoredData(_ restored: Checkpoint) {
        storageCheckedAt = nil
        bootedConfig = nil
        var new = restored.settings.applied(to: config)
        if deps.profiles.profile(id: new.deviceProfileID) == nil { new.deviceProfileID = config.deviceProfileID }
        if let seen = DataDiskStore(paths: deps.paths).status().android, VMConfig.dataDiskRangeGB.contains(seen.settingsTotalGB) {
            new.dataDiskGiB = seen.settingsTotalGB
        }
        if new != config { apply(new) }
    }

    enum RestoreRecovery: Equatable {
        /// The checkpoint is back, as asked.
        case finished
        /// The data is as it was before the restore.
        case undone
    }

    /// A restore Avo did not see to its end (it quit, the Mac stopped, the
    /// drive went): the data may hold some disks of the checkpoint and some
    /// of its own, a key that does not open the data disk beside it. It is
    /// finished from the checkpoint, which is whole, or else undone with the
    /// checkpoint of the data before; with neither, the journal stays and
    /// `prepareForStart` refuses every start. Only while Android is stopped;
    /// nil when there was nothing to do or nothing worked.
    @discardableResult
    func finishInterruptedRestore() async -> RestoreRecovery? {
        let state = await vm.status.state
        guard state == .stopped || state == .notInstalled || state == .failed,
              RestoreJournal.exists(in: deps.paths.data) else { return nil }
        // From here to the journal's removal nothing waits: no other call sees the data half done.
        guard let journal = RestoreJournal.load(deps.paths) else {
            checkpointLogger.error("a checkpoint restore was cut short, and its journal can't be read")
            return nil
        }
        let store = CheckpointStore(paths: deps.paths)
        var outcome: (Checkpoint, RestoreRecovery)?
        do {
            outcome = (try store.restore(journal.checkpoint, before: journal.before), .finished)
            checkpointLogger.notice("finished restoring checkpoint \(journal.checkpoint.uuidString, privacy: .public), cut short at \(journal.startedAt, privacy: .public)")
        } catch {
            checkpointLogger.error("could not finish restoring \(journal.checkpoint.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if let before = journal.before {
                do {
                    outcome = (try store.restore(before), .undone)
                    checkpointLogger.notice("undid the restore with checkpoint \(before.uuidString, privacy: .public)")
                } catch {
                    checkpointLogger.error("could not undo the restore either: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        guard let outcome else { return nil }
        followRestoredData(outcome.0)
        RestoreJournal.remove(deps.paths)
        await fingerprints.reload()
        publishCheckpoints()
        await publishStorage()
        return outcome.1
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

    /// The checkpoints' part of every start (bootVM, before the settings it
    /// boots with are read): a restore Avo did not see to its end is
    /// finished or undone first, with the settings that go with its data.
    /// Then a start with a newer Android than the data was last used with,
    /// which upgrades the data for good, gets a checkpoint of the older data.
    func checkpointBeforeNewerAndroid() async {
        await finishInterruptedRestore()
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
        // Half of one checkpoint's disks and half of the data's would be no restore point.
        if RestoreJournal.exists(in: deps.paths.data) { throw AvoError.internalError(RestoreJournal.cutShortMessage) }
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
