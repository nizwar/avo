import Foundation
import os

// Where Android's data lives on this Mac (Settings › Storage › Location).
//
//   ~/Library/Application Support/Avo/
//     data-location.json         StorageLocationRecord: Android's data is in another
//                                folder (none: Avo's own storage, vm/)
//     vm/                        Avo's own storage, and this Mac's side of the VM
//                                (engine logs and frames, identity.prop, avo_config.img)
//   <anywhere>/Avo Android Data/ Android's data in a folder of its own (an external drive)
//     avo-data.json              what the folder holds and who used it last
//     userdata.img               Android's data disk
//     cuttlefish/                metadata (the key to the data), misc, frp, super, vbmeta
//     android-data.json …        AvoPaths.portableDataItems
//
// The data folder travels between Macs; everything else stays with the Mac.

/// `data-location.json`: Android's data is in a folder outside Avo's own
/// storage. Written by the daemon only.
public struct StorageLocationRecord: Codable, Equatable, Sendable {
    /// The folder where the daemon last found it.
    public var path: String
    /// Finds the folder again after its volume was renamed or mounted elsewhere.
    public var bookmark: Data?
    /// The volume's name, for "… is on “<volume>”, which isn’t connected".
    public var volumeName: String?
    public var volumeUUID: String?
    /// The folder's path inside its volume (`/Avo Android Data`).
    public var pathInVolume: String?
    /// The data folder's own id (`avo-data.json`), so another folder of the
    /// same name is never taken for it.
    public var dataID: UUID?
    public var chosenAt: Date

    public init(path: String, bookmark: Data? = nil, volumeName: String? = nil, volumeUUID: String? = nil,
                pathInVolume: String? = nil, dataID: UUID? = nil, chosenAt: Date = Date()) {
        self.path = path
        self.bookmark = bookmark
        self.volumeName = volumeName
        self.volumeUUID = volumeUUID
        self.pathInVolume = pathInVolume
        self.dataID = dataID
        self.chosenAt = chosenAt
    }

    public static func load(_ paths: AvoPaths) -> StorageLocationRecord? {
        guard let data = try? Data(contentsOf: paths.dataLocationFile) else { return nil }
        return try? Self.decoder.decode(StorageLocationRecord.self, from: data)
    }

    public func save(_ paths: AvoPaths) throws {
        try FileManager.default.createDirectory(at: paths.applicationSupport, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: paths.dataLocationFile, options: .atomic)
    }

    /// Back to Avo's own storage.
    public static func remove(_ paths: AvoPaths) throws {
        guard FileManager.default.fileExists(atPath: paths.dataLocationFile.path) else { return }
        try FileManager.default.removeItem(at: paths.dataLocationFile)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: The folder AvoPaths.data names

    private struct Stamp: Equatable {
        var inode: UInt64
        var size: Int64
        var modified: Int64
        var modifiedNanoseconds: Int
    }

    /// The record's path per record file, until the file changes (a stat per look).
    private static let cache = OSAllocatedUnfairLock<[String: (stamp: Stamp, path: String?)]>(initialState: [:])

    static func currentPath(_ file: URL) -> String? {
        var info = stat()
        guard stat(file.path, &info) == 0 else { return nil }
        let stamp = Stamp(inode: UInt64(info.st_ino), size: Int64(info.st_size), modified: Int64(info.st_mtimespec.tv_sec),
                          modifiedNanoseconds: info.st_mtimespec.tv_nsec)
        if let cached = cache.withLock({ $0[file.path] }), cached.stamp == stamp { return cached.path }
        let path = (try? Data(contentsOf: file)).flatMap { try? decoder.decode(StorageLocationRecord.self, from: $0) }?.path
        cache.withLock { $0[file.path] = (stamp, path) }
        return path
    }
}

extension AvoPaths {
    /// Names the folder Android's data is in when it is not Avo's own storage.
    public var dataLocationFile: URL { applicationSupport.appending(path: "data-location.json") }

    /// Android's data: Avo's own storage (`vm`), or the folder chosen in
    /// Settings › Storage › Location. Follows the daemon's changes at once.
    public var data: URL {
        guard let path = StorageLocationRecord.currentPath(dataLocationFile), !path.isEmpty else { return vm }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// Android's data is in Avo's own storage.
    public var isDataInternal: Bool { data.standardizedFileURL.path == vm.standardizedFileURL.path }

    /// avo-vmm's `--instance`: this Mac's side of the VM (frames, logs, bootconfig).
    public var instance: URL { vm.appending(path: "cuttlefish", directoryHint: .isDirectory) }
    /// avo-vmm's `--disks`: the disks that belong with Android's data
    /// (metadata holds the key to it, misc, frp, and the writable super and vbmeta).
    public var dataDisks: URL { data.appending(path: "cuttlefish", directoryHint: .isDirectory) }
    /// `avo-data.json` (AndroidDataManifest).
    public var dataManifest: URL { data.appending(path: Self.dataManifestName) }

    public static let dataManifestName = "avo-data.json"
    /// The folder Avo makes for Android's data in a folder the user chose.
    public static let dataFolderName = "Avo Android Data"

    /// What travels with Android's data, relative to its folder: the data
    /// disk, the disks bound to it (the metadata disk holds its encryption
    /// key; misc and frp; super and vbmeta, which Google apps change) with
    /// the record of the image they came from, the newest Android that used
    /// it, Android's storage figures, Avo's fingers (enrolled in Android),
    /// an unfinished Google apps commit and which Android has Google apps
    /// (GoogleAppsRecord). Everything else is this Mac's.
    public static let portableDataItems = [
        "userdata.img",
        "cuttlefish/metadata.img", "cuttlefish/misc.img", "cuttlefish/frp.img",
        "cuttlefish/super.img", "cuttlefish/vbmeta.img", "cuttlefish/avo-image.json",
        "android-data.json", "data-disk.json", "fingerprints.json", "google-apps-commit.json", "google-apps.json",
        dataManifestName,
    ]

    /// Creates Android's data folder in Avo's own storage; a folder elsewhere
    /// must exist already (a missing drive's path is never made on this Mac).
    public func ensureDataFolder() throws {
        let folder = data
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        guard isDataInternal else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path]) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
}

// MARK: - Status (Settings › Storage, avoctl storage)

/// What a folder of Android's data says about itself.
public struct AndroidDataSummary: Codable, Equatable, Sendable {
    public var id: UUID?
    /// `Android 17`: the newest Android that used the data.
    public var android: String?
    public var sdk: Int?
    public var build: String?
    /// The data disk's size (what Android sees) and what it takes on the drive.
    public var diskBytes: Int64
    public var allocatedBytes: Int64
    /// Android created its storage on the disk (it has apps and data).
    public var created: Bool
    public var createdAt: Date?
    public var lastUsedAt: Date?
    /// The Mac that used it last.
    public var lastMac: String?
    public var googleApps: Bool?
    /// The checkpoints beside it (nil: a daemon from before they were counted).
    public var checkpoints: Int?

    public init(id: UUID? = nil, android: String? = nil, sdk: Int? = nil, build: String? = nil, diskBytes: Int64 = 0,
                allocatedBytes: Int64 = 0, created: Bool = false, createdAt: Date? = nil, lastUsedAt: Date? = nil,
                lastMac: String? = nil, googleApps: Bool? = nil, checkpoints: Int? = nil) {
        self.id = id
        self.android = android
        self.sdk = sdk
        self.build = build
        self.diskBytes = diskBytes
        self.allocatedBytes = allocatedBytes
        self.created = created
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.lastMac = lastMac
        self.googleApps = googleApps
        self.checkpoints = checkpoints
    }
}

/// The volume a folder is on.
public struct VolumeSummary: Codable, Equatable, Sendable {
    public var name: String
    /// Where it is mounted (`/Volumes/SSD`, `/` for the startup disk).
    public var mountPoint: String
    /// The file system: `apfs`, `hfs`, `exfat`, `msdos`, `smbfs` …
    public var format: String
    public var freeBytes: Int64
    public var capacityBytes: Int64
    /// The Mac's own disk.
    public var isInternal: Bool
    /// Can be ejected or unplugged (an external drive, a disk image).
    public var isRemovable: Bool
    public var isReadOnly: Bool
    public var isNetwork: Bool
    public var uuid: String?

    public init(name: String, mountPoint: String, format: String, freeBytes: Int64, capacityBytes: Int64, isInternal: Bool,
                isRemovable: Bool, isReadOnly: Bool, isNetwork: Bool, uuid: String? = nil) {
        self.name = name
        self.mountPoint = mountPoint
        self.format = format
        self.freeBytes = freeBytes
        self.capacityBytes = capacityBytes
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isReadOnly = isReadOnly
        self.isNetwork = isNetwork
        self.uuid = uuid
    }

    /// Files there take only the space written to them (APFS).
    public var keepsSparseFiles: Bool { format == "apfs" }

    /// Disk Utility's name for the format.
    public var formatName: String {
        switch format {
        case "apfs": "APFS"
        case "hfs": String(localized: "Mac OS Extended", bundle: .avoKit)
        case "exfat": "ExFAT"
        case "msdos": "MS-DOS (FAT)"
        case "ntfs": "NTFS"
        case "smbfs", "nfs", "afpfs", "webdav": String(localized: "a network volume", bundle: .avoKit)
        default: format
        }
    }
}

/// Why Android's data cannot be used where it is (or where the user points).
public enum StorageProblem: Codable, Equatable, Sendable {
    /// Its volume isn't connected.
    case volumeMissing(volume: String, path: String)
    /// The volume is there, the folder is not.
    case folderMissing(path: String)
    /// macOS does not let Avo use files there (Removable Volumes, Files & Folders).
    case notPermitted(path: String)
    /// The folder holds other Android data than the data Avo used there.
    case otherData(path: String)
    /// Made by a newer Avo, in a format this one does not read.
    case unknownFormat(path: String, version: Int)
    /// Android created its data there, but files that belong to it are gone.
    case incomplete(path: String, missing: [String])
    /// The data is from a newer Android than any image on this Mac (or than
    /// the one Android starts with): Android cannot go back without erasing it.
    case newerAndroid(data: String, build: String?, newestHere: String?, installed: Bool)
    /// Avo is moving Android's data right now.
    case changing

    public var message: String {
        switch self {
        case let .volumeMissing(volume, _):
            String(localized: "Android’s storage is on “\(volume)”, which isn’t connected. Connect it, or choose where Android’s data should be.", bundle: .avoKit)
        case let .folderMissing(path):
            String(localized: "Android’s storage folder is missing: \(path). Choose where Android’s data should be.", bundle: .avoKit)
        case let .notPermitted(path):
            String(localized: "macOS doesn’t let Avo use \(path). Allow Avo under Removable Volumes or Network Volumes in System Settings › Privacy & Security › Files & Folders.", bundle: .avoKit)
        case let .otherData(path):
            String(localized: "\(path) holds other Android data than the data Avo used there. Choose it again in Settings › Storage to use it.", bundle: .avoKit)
        case let .unknownFormat(path, _):
            String(localized: "The Android data in \(path) was made by a newer version of Avo. Update Avo to use it.", bundle: .avoKit)
        case let .incomplete(path, missing):
            String(localized: "The Android data in \(path) is incomplete: \(missing.joined(separator: ", ")) is missing.", bundle: .avoKit)
        case let .newerAndroid(data, build, newestHere, installed):
            if installed {
                String(localized: "This Android data was last used by \(Self.named(data, build)), newer than the Android that starts now. Android can’t go back to an older version without erasing its data. Choose \(data) in Settings › Android first.", bundle: .avoKit)
            } else if let newestHere {
                String(localized: "This Android data was last used by \(Self.named(data, build)), newer than any Android on this Mac (the newest is \(newestHere)). Android can’t go back to an older version without erasing its data. Download \(data) in Settings › Android first.", bundle: .avoKit)
            } else {
                String(localized: "This Android data was last used by \(Self.named(data, build)). Download \(data) in Settings › Android first.", bundle: .avoKit)
            }
        case .changing:
            String(localized: "Avo is changing where Android’s data is. Android starts when that is done.", bundle: .avoKit)
        }
    }

    private static func named(_ data: String, _ build: String?) -> String {
        build.map { String(localized: "\(data) (build \($0))", bundle: .avoKit) } ?? data
    }

    /// The volume is gone: "Choose Another…" and "Use Avo’s Own Storage" help.
    public var isMissing: Bool {
        switch self {
        case .volumeMissing, .folderMissing, .otherData: true
        default: false
        }
    }
}

/// Something about a place for Android's data the user should know before choosing it.
public struct StorageIssue: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable { case warning, error }
    /// Which choice it is about.
    public enum Scope: String, Codable, Sendable { case all, move, existing, fresh }

    public var severity: Severity
    public var scope: Scope
    public var message: String

    public init(_ severity: Severity, _ scope: Scope, _ message: String) {
        self.severity = severity
        self.scope = scope
        self.message = message
    }

    public func applies(to scope: Scope) -> Bool { self.scope == .all || self.scope == scope }
}

/// A folder the user pointed at, inspected by the daemon.
public struct StorageCandidate: Codable, Equatable, Sendable {
    /// What the user chose.
    public var chosen: String
    /// The data folder Avo would use: the chosen folder when it is one,
    /// else “Avo Android Data” inside it.
    public var folder: String
    /// Avo's own storage.
    public var isInternal: Bool
    /// Android's data is there now.
    public var isCurrent: Bool
    public var volume: VolumeSummary?
    /// Android data already there.
    public var existing: AndroidDataSummary?
    /// Why that data cannot be used here, or why the folder cannot be read.
    public var problem: StorageProblem?
    public var issues: [StorageIssue]
    /// What moving Android's data there copies (bytes on the destination).
    public var moveBytes: Int64
    /// The current data can be read (to move it).
    public var currentAvailable: Bool
    /// What a move there does with the current data's checkpoints (nil: it has none).
    public var checkpoints: CheckpointsMove?

    public init(chosen: String, folder: String, isInternal: Bool, isCurrent: Bool, volume: VolumeSummary?,
                existing: AndroidDataSummary?, problem: StorageProblem?, issues: [StorageIssue], moveBytes: Int64,
                currentAvailable: Bool, checkpoints: CheckpointsMove? = nil) {
        self.chosen = chosen
        self.folder = folder
        self.isInternal = isInternal
        self.isCurrent = isCurrent
        self.volume = volume
        self.existing = existing
        self.problem = problem
        self.issues = issues
        self.moveBytes = moveBytes
        self.currentAvailable = currentAvailable
        self.checkpoints = checkpoints
    }

    public func issues(for scope: StorageIssue.Scope) -> [StorageIssue] { issues.filter { $0.applies(to: scope) } }

    public func allows(_ scope: StorageIssue.Scope) -> Bool {
        guard !isCurrent, !issues(for: scope).contains(where: { $0.severity == .error }) else { return false }
        switch scope {
        case .existing: return existing != nil && problem == nil
        case .move: return currentAvailable && (existing == nil || isInternal) && !isNotPermitted
        case .fresh: return (existing == nil || isInternal) && !isNotPermitted
        case .all: return true
        }
    }

    private var isNotPermitted: Bool { if case .notPermitted = problem { true } else { false } }

    /// The Android data there is only from a newer Android than this Mac has:
    /// usable once that Android is downloaded (`allowNewerAndroid`).
    public var existingNeedsNewerAndroid: Bool {
        guard existing != nil, case .newerAndroid? = problem, !isCurrent else { return false }
        return !issues(for: .existing).contains { $0.severity == .error }
    }

    /// Starting fresh with a `gb` disk there: refused where the disk takes
    /// its full size at once and does not fit; a warning where it may outgrow the drive.
    public func freshIssue(gb: Int) -> StorageIssue? {
        guard let volume, volume.format != "msdos" else { return nil }
        let disk = VMConfig.dataDiskBytes(gb: gb)
        let free = ByteCountFormatter.string(fromByteCount: volume.freeBytes, countStyle: .decimal)
        if !volume.keepsSparseFiles, volume.freeBytes < disk + 1_000_000_000 {
            return StorageIssue(.error, .fresh, String(localized: "A \(gb) GB disk takes its full size on “\(volume.name)”, which has \(free) free.", bundle: .avoKit))
        }
        if volume.keepsSparseFiles, volume.freeBytes < disk {
            return StorageIssue(.warning, .fresh, String(localized: "Android’s storage can grow to \(gb) GB; “\(volume.name)” has \(free) free. Android runs out of space when the drive is full.", bundle: .avoKit))
        }
        return nil
    }
}

/// What moving Android's data somewhere does with its checkpoints: they
/// come along (APFS clones on the same volume, copies on another APFS
/// volume with room for them beside the data), or they stay with the old
/// copy, which a move that keeps no old copy deletes only when asked to
/// (`StorageChangeRequest.leavesCheckpoints`).
public struct CheckpointsMove: Codable, Equatable, Sendable {
    public enum Obstacle: Codable, Equatable, Sendable {
        /// Checkpoints need APFS; the destination has another format (its name).
        case format(String)
        /// They don't fit on the destination beside the data.
        case room
    }

    public var count: Int
    /// What they take on the destination (nothing as clones on the same volume).
    public var bytes: Int64
    /// Why they can't come along (nil: they do).
    public var obstacle: Obstacle?

    public init(count: Int, bytes: Int64, obstacle: Obstacle? = nil) {
        self.count = count
        self.bytes = bytes
        self.obstacle = obstacle
    }

    public var comeAlong: Bool { obstacle == nil }
}

/// What to do at the new place.
public enum StorageChangeAction: Codable, Equatable, Sendable {
    /// Copy Android's data there (keeping it sparse) with the checkpoints
    /// that can come along (CheckpointsMove), check the copy, use it, and
    /// remove the old copy unless `keepOldCopy`.
    case move(keepOldCopy: Bool)
    /// Use the Android data already there (a folder Avo made, carried from another Mac).
    case useExisting
    /// An empty place: Android creates its storage at `gb` when it next starts.
    case startFresh(gb: Int)
}

public struct StorageChangeRequest: Codable, Equatable, Sendable {
    public var id: UUID
    /// The folder the user chose (StorageCandidate.chosen); nil for Avo's own storage.
    public var destination: String?
    public var action: StorageChangeAction
    /// Stop Android first when it runs (else the change is refused).
    public var stopAndroid: Bool
    /// Erase Android data already in Avo's own storage (a kept copy) to move
    /// there or start fresh there.
    public var replaceExisting: Bool
    /// Use data from a newer Android than any image on this Mac (the Setup
    /// Assistant downloads that Android next): every start is still refused
    /// until an image that can use the data is chosen.
    public var allowNewerAndroid: Bool
    /// A move that keeps no old copy may delete the checkpoints it can't
    /// take along (CheckpointsMove: the sheet said how many). Without it
    /// such a move is refused before anything changes.
    public var leavesCheckpoints: Bool

    public init(id: UUID = UUID(), destination: String?, action: StorageChangeAction, stopAndroid: Bool = false,
                replaceExisting: Bool = false, allowNewerAndroid: Bool = false, leavesCheckpoints: Bool = false) {
        self.id = id
        self.destination = destination
        self.action = action
        self.stopAndroid = stopAndroid
        self.replaceExisting = replaceExisting
        self.allowNewerAndroid = allowNewerAndroid
        self.leavesCheckpoints = leavesCheckpoints
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        destination = try container.decodeIfPresent(String.self, forKey: .destination)
        action = try container.decode(StorageChangeAction.self, forKey: .action)
        stopAndroid = try container.decodeIfPresent(Bool.self, forKey: .stopAndroid) ?? false
        replaceExisting = try container.decodeIfPresent(Bool.self, forKey: .replaceExisting) ?? false
        allowNewerAndroid = try container.decodeIfPresent(Bool.self, forKey: .allowNewerAndroid) ?? false
        leavesCheckpoints = try container.decodeIfPresent(Bool.self, forKey: .leavesCheckpoints) ?? false
    }
}

/// A change of place on its way (sent to Control Panels as it goes).
public struct StorageChangeProgress: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case stopping, checking, copying, verifying, switching, removingOld, finished, failed, cancelled
    }

    public var id: UUID
    public var phase: Phase
    public var doneBytes: Int64
    public var totalBytes: Int64
    public var message: String?

    public init(id: UUID, phase: Phase, doneBytes: Int64 = 0, totalBytes: Int64 = 0, message: String? = nil) {
        self.id = id
        self.phase = phase
        self.doneBytes = doneBytes
        self.totalBytes = totalBytes
        self.message = message
    }

    public var fraction: Double? { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : nil }
    public var isDone: Bool { phase == .finished || phase == .failed || phase == .cancelled }
}

/// The room Android's writes have on the volume its data is on, while it
/// runs (Settings › Storage and the Library's banner).
public enum StorageSpace: Codable, Equatable, Sendable {
    /// The volume is full: avo-vmm holds Android's writes until there is
    /// room again (engine/hvf/vmm/src/virtio/block.rs). `onMac`: the Mac's own disk.
    case full(volume: String, onMac: Bool)
    /// Less than `StorageSpace.lowBytes` is left.
    case low(volume: String, onMac: Bool, freeBytes: Int64)

    /// Below this much free space while Android runs, Avo says so.
    public static let lowBytes: Int64 = 2_000_000_000

    public var isFull: Bool { if case .full = self { true } else { false } }

    /// On the Mac's own disk (System Settings › General › Storage frees room there).
    public var isOnMac: Bool {
        switch self {
        case let .full(_, onMac), let .low(_, onMac, _): onMac
        }
    }

    public var message: String {
        switch self {
        case .full(_, true):
            String(localized: "Android is waiting because the Mac’s disk is full. Free some space, and Android goes on.", bundle: .avoKit)
        case let .full(volume, false):
            String(localized: "Android is waiting because “\(volume)” is full. Free some space on it, and Android goes on.", bundle: .avoKit)
        case let .low(_, true, free):
            String(localized: "The Mac’s disk has only \(Self.bytes(free)) free. When it is full, Android waits until you free some space.", bundle: .avoKit)
        case let .low(volume, false, free):
            String(localized: "“\(volume)” has only \(Self.bytes(free)) free. When it is full, Android waits until you free some space on it.", bundle: .avoKit)
        }
    }

    private static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .decimal) }
}

/// Where Android's data is now (Settings › Storage › Location).
public struct StorageLocationStatus: Codable, Equatable, Sendable {
    /// The data folder.
    public var path: String
    public var isInternal: Bool
    /// Its volume, while it is there.
    public var volume: VolumeSummary?
    /// The volume's name (also while it is missing).
    public var volumeName: String?
    /// Nil while Android's data can be used.
    public var problem: StorageProblem?
    public var data: AndroidDataSummary?
    /// Android data still in Avo's own storage while another folder is used
    /// (kept when it moved, or from before).
    public var internalCopy: AndroidDataSummary?
    /// A change on its way.
    public var change: StorageChangeProgress?
    /// Android's writes wait for room, or little is left (nil: enough, or Android is stopped).
    public var space: StorageSpace?

    public init(path: String, isInternal: Bool, volume: VolumeSummary? = nil, volumeName: String? = nil,
                problem: StorageProblem? = nil, data: AndroidDataSummary? = nil, internalCopy: AndroidDataSummary? = nil,
                change: StorageChangeProgress? = nil, space: StorageSpace? = nil) {
        self.path = path
        self.isInternal = isInternal
        self.volume = volume
        self.volumeName = volumeName
        self.problem = problem
        self.data = data
        self.internalCopy = internalCopy
        self.change = change
        self.space = space
    }
}
