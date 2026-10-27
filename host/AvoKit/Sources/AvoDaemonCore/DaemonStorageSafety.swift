import AvoKit
import AvoPackages
import Foundation
import os

// MARK: - Android's data, whole whatever was cut short (DaemonCore.start)

/// What keeps Android's data whole across work Avo did not see to its end:
/// a checkpoint restore cut short is finished or undone when the daemon
/// starts, before anything can start Android on disks from two sides
/// (every start tries again first, and `prepareForStart` refuses while it
/// is not done). Then what a restore or a move cut short left goes: their
/// staging folders, which on a drive without sparse files take the data
/// disk's whole size.
extension DaemonCore {
    private var safetyLogger: Logger { Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Storage") }

    func startStorageSafety() {
        Task { [weak self] in await self?.recoverInterruptedWork() }
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
}
