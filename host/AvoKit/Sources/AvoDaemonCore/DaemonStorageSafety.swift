import AvoKit
import AvoPackages
import Foundation
import os

// MARK: - Android's data, kept whole (DaemonCore.start, eraseAndroid)

/// What keeps Android's data whole whatever happens around it. A checkpoint
/// restore cut short is finished or undone when the daemon starts, before
/// anything can start Android on disks from two sides (every start tries
/// again first, and `prepareForStart` refuses while it is not done); then
/// what a restore or a move cut short left goes: their staging folders,
/// which on a drive without sparse files take the data disk's whole size.
/// Reset Android erases only data it can reach. And while Android runs, the
/// room its writes have is watched (StorageSpace).
extension DaemonCore {
    private var safetyLogger: Logger { Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Storage") }

    func startStorageSafety() {
        Task { [weak self] in await self?.recoverInterruptedWork() }
        watchStorageSpace()
    }

    func recoverInterruptedWork() async {
        await finishInterruptedRestore()
        // Only what nothing owns: a restore never waits between making its
        // staging folder and removing it, so none runs across this actor's
        // turns, and the storage actor leaves a move's alone while it runs.
        CheckpointStore(paths: deps.paths).removeLeftoverStaging()
        await storage.cleanInterruptedMoves()
    }

    // MARK: Reset Android (eraseAndroid)

    /// Reset Android erases the data where it is, then Avo's side of it
    /// (the apps and their shims, Google apps, the fingers in Android).
    /// Never Avo's side alone: not while the data can't be reached (its
    /// drive unplugged: Avo would forget every app while the data stays on
    /// the drive), nor while its place changes (the data disk a move copies
    /// would come back at the new place).
    func refuseEraseWithoutData() async throws {
        let problem = await storage.status().problem
        // Looked at last, with nothing to wait for before the erase.
        if storageChanging {
            throw AvoError.internalError(String(localized: "Avo is changing where Android’s data is. Reset Android once that is done.", bundle: .avoKit))
        }
        if let problem {
            throw AvoError.internalError(String(localized: "Avo can’t reset Android while its data can’t be reached. \(problem.message)", bundle: .avoKit))
        }
    }

    /// Reset Android and a checkpoint restore erase or swap Android's
    /// files. From before their stop until they are done with the data
    /// (`dataChange`), no start begins (VMManager holds them: one would run
    /// on those files, its status said to be stopped), and neither a move, a
    /// checkpoint nor another such change.
    enum DataChange: Sendable {
        case reset, restore
    }

    static func refusal(during change: DataChange) -> AvoError {
        switch change {
        case .reset: .internalError(String(localized: "Android’s data is being erased. Try again once that is done.", bundle: .avoKit))
        case .restore: .internalError(String(localized: "A checkpoint is being restored. Try again once that is done.", bundle: .avoKit))
        }
    }

    func refuseWhileDataChanges() throws {
        if let dataChange { throw Self.refusal(during: dataChange.kind) }
    }

    /// Marks the change before anything is awaited: two that ask at once
    /// cannot both begin.
    func beginDataChange(_ kind: DataChange) async throws -> UUID {
        try refuseWhileDataChanges()
        let hold = UUID()
        dataChange = (kind, hold)
        await vm.holdStarts(hold, reason: Self.refusal(during: kind))
        return hold
    }

    func endDataChange(_ hold: UUID) async {
        guard dataChange?.hold == hold else { return }
        dataChange = nil
        await vm.releaseStarts(hold)
    }

    /// The data's part of Reset Android. The data disk goes first: when it
    /// can't, the reset fails before anything else changes. Then the
    /// snapshots, the checkpoints of the data that went and the records
    /// that describe it; the names of those that stay (the reset goes on
    /// without them, and says so once Avo's side is reset too).
    func eraseAndroidData() throws -> [String] {
        let paths = deps.paths
        do {
            if FileManager.default.fileExists(atPath: paths.dataDisk.path) { try FileManager.default.removeItem(at: paths.dataDisk) }
        } catch {
            safetyLogger.error("Reset Android: the data disk stays: \(error.localizedDescription, privacy: .public)")
            throw AvoError.internalError(String(localized: "Avo couldn’t erase Android’s data: \(error.localizedDescription)", bundle: .avoKit))
        }
        var left: [String] = []
        do {
            if FileManager.default.fileExists(atPath: paths.snapshots.path) { try FileManager.default.removeItem(at: paths.snapshots) }
        } catch {
            safetyLogger.error("Reset Android: the snapshots stay: \(error.localizedDescription, privacy: .public)")
            left.append(paths.snapshots.lastPathComponent)
        }
        do {
            // Its checkpoints are of the data that went (Reset Android says so).
            try CheckpointStore(paths: paths).removeAll()
        } catch {
            safetyLogger.error("Reset Android: the checkpoints stay: \(error.localizedDescription, privacy: .public)")
            left.append(CheckpointStore.folderName)
        }
        DataDiskStore(paths: paths).forget()
        GoogleAppsJournal.remove(paths)
        GoogleAppsRecord.remove(paths)
        for url in [DataDiskStore(paths: paths).record, GoogleAppsJournal.url(paths)] where FileManager.default.fileExists(atPath: url.path) {
            safetyLogger.error("Reset Android: \(url.lastPathComponent, privacy: .public) stays")
            left.append(url.lastPathComponent)
        }
        return left
    }

    /// What of the data's records Reset Android could not remove.
    static func resetLeftovers(_ names: [String]) -> AvoError? {
        guard !names.isEmpty else { return nil }
        return AvoError.internalError(String(localized: "Android was reset, but Avo couldn’t remove \(names.joined(separator: ", ")) beside its data.", bundle: .avoKit))
    }

    // MARK: Room for Android's writes (StorageSpace)

    /// How often the room on the data's volume is looked at while Android runs.
    static let spaceCheckInterval: Duration = .seconds(60)

    /// While Android runs: what the engine says when Android's writes wait
    /// for room (a full Mac disk no longer fails them, it holds them), and
    /// a look at the data's volume once a minute, for the Library's banner
    /// before it is full. Stopped, Android writes nothing: no banner.
    private func watchStorageSpace() {
        if let engine = deps.engine as? any DiskSpaceEngine {
            let updates = engine.diskFullUpdates
            Task { [weak self] in
                for await full in updates { await self?.androidWritesWait(full) }
            }
        }
        Task { [weak self] in
            guard let statuses = await self?.statusChanges() else { return }
            var running = false
            var looking: Task<Void, Never>?
            for await status in statuses {
                let runs = status.state == .running
                guard runs != running else { continue }
                running = runs
                looking?.cancel()
                looking = nil
                // Stopped, nothing of Android waits any more.
                await self?.storageSpaceChanged(androidRuns: runs, writesWait: runs ? nil : false)
                guard runs else { continue }
                looking = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: Self.spaceCheckInterval)
                        if Task.isCancelled { break }
                        await self?.storageSpaceChanged()
                    }
                }
            }
        }
    }

    /// What the engine says, while it runs Android (a stopped engine's last
    /// word may come after the stop).
    private func androidWritesWait(_ full: Bool) async {
        let state = await vm.status.state
        guard !full || (state != .stopped && state != .failed && state != .notInstalled) else { return }
        safetyLogger.notice("\(full ? "Android's writes wait for room on its data's volume" : "Android's writes go through again", privacy: .public)")
        await storageSpaceChanged(writesWait: full)
    }

    func storageSpaceChanged(androidRuns: Bool? = nil, writesWait: Bool? = nil) async {
        if await storage.noteSpace(androidRuns: androidRuns, writesWait: writesWait) { await publishStorage() }
    }
}

/// An engine that says when Android's writes wait for room on the volume
/// its data is on, and when they go through again (avo-vmm's sticky
/// `disk full on|off`, engine/hvf/vmm/src/virtio/block.rs).
public protocol DiskSpaceEngine: VMEngine {
    var diskFullUpdates: AsyncStream<Bool> { get }
}

/// avo-vmm's `disk full` events, as DiskSpaceEngine's updates.
final class DiskFullReports: Sendable {
    let updates: AsyncStream<Bool>
    private let sink: AsyncStream<Bool>.Continuation

    init() {
        (updates, sink) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(4))
    }

    /// One of the engine's event lines; others are not this one's.
    func handle(_ line: String) {
        switch line {
        case "disk full on": sink.yield(true)
        case "disk full off": sink.yield(false)
        default: break
        }
    }
}

extension VMMEngine: DiskSpaceEngine {
    public var diskFullUpdates: AsyncStream<Bool> { diskFull.updates }
}
