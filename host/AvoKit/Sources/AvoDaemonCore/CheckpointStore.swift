import AvoKit
import Foundation
import os

/// Checkpoints on disk, beside Android's data (wherever it is):
///
/// ```
/// <data>/checkpoints/<id>/checkpoint.json   Checkpoint, written last
/// <data>/checkpoints/<id>/userdata.img …    AvoPaths.portableDataItems as they were
/// ```
///
/// Every item is an APFS clone (clonefile), so a checkpoint is made in a
/// moment and its blocks are shared with the data until Android changes
/// them. There is no copy fallback: a full copy of Android's data disk takes
/// minutes and as much space again, so a drive that cannot clone (not APFS)
/// has no checkpoints (`problem`). The caller holds Android still while one
/// is made (DaemonCheckpoints.swift); a restore needs Android stopped.
struct CheckpointStore {
    let paths: AvoPaths
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Checkpoints")

    init(paths: AvoPaths) {
        self.paths = paths
    }

    static let folderName = "checkpoints"
    static let recordName = "checkpoint.json"
    /// Where a restore gathers the checkpoint's clones before they replace the data.
    static let stagingName = ".avo-restoring"

    var folder: URL { paths.data.appending(path: Self.folderName, directoryHint: .isDirectory) }

    func folder(of id: UUID) -> URL { folder.appending(path: id.uuidString, directoryHint: .isDirectory) }

    /// What a checkpoint holds: Android's data without the folder's own
    /// manifest (which says where the folder is used, not what Android has).
    static let items = AvoPaths.portableDataItems.filter { $0 != AvoPaths.dataManifestName }

    // MARK: Listing

    /// Newest first. A folder without its record (a checkpoint cut short) is not one.
    func list() -> [Checkpoint] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let decoder = JSONDecoder()
        return names.compactMap { name -> Checkpoint? in
            guard let id = UUID(uuidString: name),
                  let data = try? Data(contentsOf: folder(of: id).appending(path: Self.recordName)),
                  let checkpoint = try? decoder.decode(Checkpoint.self, from: data), checkpoint.id == id else { return nil }
            return checkpoint
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func status() -> CheckpointStatus {
        CheckpointStatus(checkpoints: list(), problem: problem())
    }

    /// Why no checkpoint can be made where Android's data is, or nil.
    func problem() -> String? {
        let data = paths.data
        guard FileManager.default.fileExists(atPath: data.path) else { return nil }
        let values = try? data.resourceValues(forKeys: [.volumeSupportsFileCloningKey, .volumeLocalizedFormatDescriptionKey])
        guard values?.volumeSupportsFileCloning == false else { return nil }
        let format = values?.volumeLocalizedFormatDescription ?? "?"
        return String(localized: "Checkpoints need Android’s data on an APFS drive; it is on a drive formatted as \(format). Move it in Settings › Storage › Location to use checkpoints.",
                      bundle: .avoKit)
    }

    /// Android created its storage: there is something to keep.
    var hasData: Bool { DataDiskStore.isWritten(paths.dataDisk) }

    // MARK: Changes

    /// Clones Android's data into a new checkpoint. Android must not write
    /// meanwhile (stopped, or held still).
    func create(_ checkpoint: Checkpoint) throws {
        if let problem = problem() { throw AvoError.internalError(problem) }
        guard hasData else {
            throw AvoError.internalError(String(localized: "Android has no apps or data yet, so there is nothing to keep.", bundle: .avoKit))
        }
        let destination = folder(of: checkpoint.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try Self.clone(Self.items, from: paths.data, to: destination)
            let encoder = JSONEncoder()
            // Dates as they are (not ISO 8601, whole seconds): checkpoints made
            // one after another keep their order.
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(checkpoint).write(to: destination.appending(path: Self.recordName), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        logger.notice("checkpoint \(checkpoint.id.uuidString, privacy: .public) (\(checkpoint.reason.rawValue, privacy: .public))")
    }

    func delete(_ id: UUID) throws {
        let url = folder(of: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Self.missing }
        try FileManager.default.removeItem(at: url)
    }

    /// Automatic checkpoints past `CheckpointStatus.automaticLimit`, oldest
    /// first, go; and what an interrupted checkpoint left (no record: it is
    /// written last). Manual ones stay, and so does `keeping` (the one a
    /// restore is about to put back). A record this Avo cannot read (another
    /// version's) keeps its checkpoint: unlisted, but not erased.
    func prune(keeping: UUID? = nil) {
        let checkpoints = list()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            guard let id = UUID(uuidString: name),
                  !FileManager.default.fileExists(atPath: folder(of: id).appending(path: Self.recordName).path) else { continue }
            try? FileManager.default.removeItem(at: folder(of: id))
        }
        for old in checkpoints.filter({ $0.isAutomatic && $0.id != keeping }).dropFirst(CheckpointStatus.automaticLimit) {
            try? FileManager.default.removeItem(at: folder(of: old.id))
            logger.notice("checkpoint \(old.id.uuidString, privacy: .public) removed (only the newest \(CheckpointStatus.automaticLimit) automatic ones stay)")
        }
    }

    /// Reset Android: its checkpoints go with its data.
    func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Puts the checkpoint's data in place of Android's (Android stopped).
    /// The checkpoint stays as it was, to restore again. Its clones are made
    /// beside the data first, so a checkpoint that cannot be read changes
    /// nothing; then they replace the data, the data disk last, and what
    /// the checkpoint did not have (Google apps installed after it) goes.
    func restore(_ id: UUID) throws -> Checkpoint {
        guard let checkpoint = list().first(where: { $0.id == id }) else { throw Self.missing }
        let source = folder(of: id)
        let staging = paths.data.appending(path: Self.stagingName, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let present = Self.items.filter { FileManager.default.fileExists(atPath: source.appending(path: $0).path) }
        guard present.contains("userdata.img") else { throw Self.missing }
        try Self.clone(present, from: source, to: staging)
        let order = present.filter { $0 != "userdata.img" } + ["userdata.img"]
        for item in Self.items where !present.contains(item) {
            let url = paths.data.appending(path: item)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        for item in order {
            let target = paths.data.appending(path: item)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: staging.appending(path: item), to: target)
        }
        logger.notice("restored checkpoint \(id.uuidString, privacy: .public) from \(checkpoint.createdAt, privacy: .public)")
        return checkpoint
    }

    // MARK: Cloning

    /// Clones each of `items` that exists in `source` to the same place in
    /// `destination`. Each is flushed first: Android's last writes may still
    /// be in the Mac's cache, and the clone must have them.
    static func clone(_ items: [String], from source: URL, to destination: URL) throws {
        for item in items {
            let from = source.appending(path: item)
            let fd = open(from.path, O_RDONLY)
            guard fd >= 0 else {
                if errno == ENOENT { continue }
                throw DataCopier.Failure.io(DataCopier.describe(errno, from))
            }
            _ = fsync(fd)
            close(fd)
            let to = destination.appending(path: item)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard clonefile(from.path, to.path, UInt32(CLONE_NOOWNERCOPY)) == 0 else {
                throw DataCopier.Failure.io(DataCopier.describe(errno, to))
            }
        }
    }

    static var missing: AvoError {
        AvoError.internalError(String(localized: "That checkpoint is no longer there.", bundle: .avoKit))
    }
}
