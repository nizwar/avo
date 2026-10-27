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
        let checkpoints = list()
        var own: [UUID: Int64] = [:]
        for checkpoint in checkpoints { own[checkpoint.id] = ownBytes(of: checkpoint.id) }
        return CheckpointStatus(checkpoints: checkpoints, problem: problem(), ownBytes: own)
    }

    /// What only this checkpoint takes on the drive: the blocks of its
    /// files that no clone shares (the data's, another checkpoint's).
    /// Nil where the file system can't say.
    func ownBytes(of id: UUID) -> Int64? {
        let root = folder(of: id)
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return nil }
        var total: Int64 = 0
        for case let relative as String in enumerator where enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular {
            guard let bytes = Self.privateBytes(of: root.appending(path: relative)) else { return nil }
            total += bytes
        }
        return total
    }

    /// ATTR_CMNEXT_PRIVATESIZE: the bytes of `url` no clone shares.
    static func privateBytes(of url: URL) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        // The reply: its length, the attributes returned (common, volume,
        // directory, file, fork), then the size.
        var reply = [UInt8](repeating: 0, count: 64)
        let result = reply.withUnsafeMutableBytes {
            getattrlist(url.path, &request, $0.baseAddress, $0.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard result == 0 else { return nil }
        return reply.withUnsafeBytes { bytes -> Int64? in
            guard bytes.loadUnaligned(fromByteOffset: 20, as: UInt32.self) & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            return bytes.loadUnaligned(fromByteOffset: 24, as: Int64.self)
        }
    }

    /// The checkpoints beside the data in `data`, as a move takes them
    /// along: their files relative to that folder (`checkpoints/<id>/userdata.img`
    /// …), and what copies of them take on another volume (a copy shares
    /// no blocks, so each clone takes all of its own again). A folder
    /// without its record (a checkpoint cut short) stays out; one this Avo
    /// cannot read (another version's) comes along too.
    static func movable(in data: URL) -> (count: Int, files: [String], bytes: Int64) {
        let root = data.appending(path: folderName, directoryHint: .isDirectory)
        var count = 0
        var files: [String] = []
        var bytes: Int64 = 0
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted() {
            let folder = root.appending(path: name, directoryHint: .isDirectory)
            guard UUID(uuidString: name) != nil, FileManager.default.fileExists(atPath: folder.appending(path: recordName).path),
                  let enumerator = FileManager.default.enumerator(atPath: folder.path) else { continue }
            count += 1
            for case let relative as String in enumerator where enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular {
                files.append("\(folderName)/\(name)/\(relative)")
                var info = stat()
                if stat(folder.appending(path: relative).path, &info) == 0 { bytes += Int64(info.st_blocks) * 512 }
            }
        }
        return (count, files, bytes)
    }

    /// How many checkpoints the data in `data` has (Settings › Storage).
    static func count(in data: URL) -> Int {
        let root = data.appending(path: folderName, directoryHint: .isDirectory)
        return ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter {
            UUID(uuidString: $0) != nil && FileManager.default.fileExists(atPath: root.appending(path: "\($0)/\(recordName)").path)
        }.count
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

    /// What a restore cut short left beside the data (the checkpoint's
    /// clones), once no journal needs it. A restore's own staging folder
    /// never outlives the call that makes it (`restore` waits for nothing).
    func removeLeftoverStaging() {
        for folder in Set([paths.data.standardizedFileURL, paths.vm.standardizedFileURL]) where !RestoreJournal.exists(in: folder) {
            let staging = folder.appending(path: Self.stagingName, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: staging.path) else { continue }
            do {
                try FileManager.default.removeItem(at: staging)
                logger.notice("removed what a restore cut short left in \(folder.path, privacy: .public)")
            } catch {
                logger.error("could not remove \(staging.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Reset Android: its checkpoints go with its data, and a restore cut
    /// short has nothing left to finish.
    func removeAll() throws {
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        RestoreJournal.remove(paths)
        try? FileManager.default.removeItem(at: paths.data.appending(path: Self.stagingName, directoryHint: .isDirectory))
    }

    /// Puts the checkpoint's data in place of Android's (Android stopped).
    /// The checkpoint stays as it was, to restore again. Its clones are made
    /// beside the data first, so a checkpoint that cannot be read changes
    /// nothing; then they replace the data, the data disk last, and what
    /// the checkpoint did not have (Google apps installed after it) goes.
    /// The journal written before the first of them (RestoreJournal) stays
    /// until the daemon has the settings that go with the data: a restore
    /// cut short anywhere is finished, or undone with `before` (the data as
    /// it was), before Android uses the data again.
    func restore(_ id: UUID, before: UUID? = nil) throws -> Checkpoint {
        guard let checkpoint = list().first(where: { $0.id == id }) else { throw Self.missing }
        let source = folder(of: id)
        let staging = paths.data.appending(path: Self.stagingName, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let present = Self.items.filter { FileManager.default.fileExists(atPath: source.appending(path: $0).path) }
        guard present.contains("userdata.img") else { throw Self.missing }
        try Self.clone(present, from: source, to: staging)
        // From here the data changes: a metadata disk from one side and a
        // data disk from the other cannot be opened (its key is on the first).
        try RestoreJournal(checkpoint: id, before: before).save(paths)
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
        // On the drive before the journal can go (a full fsync flushes all of the drive's cache).
        RestoreJournal.flush(paths.dataDisk)
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

/// `<data>/checkpoint-restore.json`: a restore on its way (CheckpointStore.restore).
/// Written once the checkpoint's clones wait beside the data, before the
/// first of them replaces anything; removed once the data and Avo's
/// settings are the checkpoint's. Until then the data may hold disks from
/// both sides, so the daemon finishes the restore first (`finishInterruptedRestore`)
/// and no start, move or checkpoint takes the data as it is.
struct RestoreJournal: Codable, Equatable {
    /// The checkpoint put back: it stays whole, so restoring it again finishes the restore.
    var checkpoint: UUID
    /// The checkpoint of the data as it was before, which undoes it (nil: Android had no data).
    var before: UUID?
    var startedAt: Date

    init(checkpoint: UUID, before: UUID?, startedAt: Date = Date()) {
        self.checkpoint = checkpoint
        self.before = before
        self.startedAt = startedAt
    }

    static let name = "checkpoint-restore.json"

    static func url(in folder: URL) -> URL { folder.appending(path: name) }

    /// One is there, readable or not (a start is refused while it is).
    static func exists(in folder: URL) -> Bool { FileManager.default.fileExists(atPath: url(in: folder).path) }

    static func load(_ paths: AvoPaths) -> RestoreJournal? {
        (try? Data(contentsOf: url(in: paths.data))).flatMap { try? JSONDecoder().decode(RestoreJournal.self, from: $0) }
    }

    /// On the drive before the first item of the data changes.
    func save(_ paths: AvoPaths) throws {
        let url = Self.url(in: paths.data)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        Self.flush(url)
    }

    static func remove(_ paths: AvoPaths) {
        try? FileManager.default.removeItem(at: url(in: paths.data))
    }

    /// F_FULLFSYNC on `url`: its drive writes out everything it holds.
    static func flush(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        if fcntl(fd, F_FULLFSYNC) != 0 { _ = fsync(fd) }
        close(fd)
    }

    static var cutShortMessage: String {
        String(localized: "Restoring a checkpoint was cut short, and Avo could not finish it. Restore a checkpoint again, or reset Android.", bundle: .avoKit)
    }
}
