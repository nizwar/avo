import AvoKit
import AvoPackages
import Foundation
import os
import SystemConfiguration

/// Where Android's data is (Settings › Storage › Location): finding it again
/// (a bookmark, its path, its volume under another name), checking a folder
/// before it is used, and moving, adopting or starting the data somewhere else.
///
/// Only Android's data moves (AvoPaths.portableDataItems: the data disk with
/// the metadata disk that holds its key, misc, frp, super and vbmeta, and the
/// records that describe it), with its checkpoints where they can come along
/// (CheckpointsMove). Images, settings, the apps list, key mappings and
/// avo-vmm's frames and logs stay with this Mac.
actor StorageLocations {
    let paths: AvoPaths
    /// The Android images on this Mac, newest first (data from a newer Android is refused).
    private let images: @Sendable () -> [AndroidImageSummary]
    /// What DiskArbitration must not let go now.
    nonisolated let volumeGuard = VolumeGuard()
    private(set) var change: StorageChangeProgress?
    private var cancelRequested = false
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Storage")

    /// APFS clones on the same volume (tests turn them off to copy bytes).
    private let cloning: Bool
    /// The volume of a folder the user chose (tests stand in other drives).
    private let destinationVolume: @Sendable (URL) -> VolumeSummary?

    init(paths: AvoPaths, cloning: Bool = true, destinationVolume: @escaping @Sendable (URL) -> VolumeSummary? = { volumeSummary(for: $0) },
         images: @escaping @Sendable () -> [AndroidImageSummary]) {
        self.paths = paths
        self.cloning = cloning
        self.destinationVolume = destinationVolume
        self.images = images
    }

    /// Room kept free on the destination beyond what a move copies.
    static let spareBytes: Int64 = 1_000_000_000

    var isChanging: Bool { change.map { !$0.isDone } ?? false }

    // MARK: Finding Android's data

    struct Resolution {
        var folder: URL
        var problem: StorageProblem?
        var record: StorageLocationRecord?
    }

    /// Finds the data folder, and notes where it is now when its volume was
    /// renamed or mounted elsewhere. Avo's own storage needs no finding.
    func resolve() -> Resolution {
        guard var record = StorageLocationRecord.load(paths) else { return Resolution(folder: paths.vm, problem: nil, record: nil) }
        var found: URL?
        var stale = false
        if let bookmark = record.bookmark,
           let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                              bookmarkDataIsStale: &stale),
           Self.matches(url, record) {
            found = url
        }
        if found == nil, Self.matches(URL(filePath: record.path, directoryHint: .isDirectory), record) {
            found = URL(filePath: record.path, directoryHint: .isDirectory)
        }
        if found == nil, let inVolume = record.pathInVolume {
            // Its volume under another name (no bookmark could say).
            for volume in Self.mountedVolumes() where record.volumeUUID == nil || volume.uuid == record.volumeUUID {
                let candidate = URL(filePath: volume.mountPoint, directoryHint: .isDirectory).appending(path: inVolume, directoryHint: .isDirectory)
                if Self.matches(candidate, record) {
                    found = candidate
                    break
                }
            }
        }
        guard var found else { return Resolution(folder: URL(filePath: record.path, directoryHint: .isDirectory), problem: diagnose(record), record: record) }
        let path = found.standardizedFileURL.path
        let moved = found.resolvingSymlinksInPath().path != URL(filePath: record.path).resolvingSymlinksInPath().path
        if !moved { found = URL(filePath: record.path, directoryHint: .isDirectory) }
        if moved || stale || record.bookmark == nil {
            logger.notice("Android's data is at \(path, privacy: .public) now (was \(record.path, privacy: .public))")
            record = Self.record(for: found, id: record.dataID, chosenAt: record.chosenAt)
            do { try record.save(paths) } catch {
                logger.error("could not note where Android's data is: \(error.localizedDescription, privacy: .public)")
            }
        }
        return Resolution(folder: found, problem: nil, record: record)
    }

    /// `url` is the data folder the record names (its manifest has its id).
    static func matches(_ url: URL, _ record: StorageLocationRecord) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        guard let id = record.dataID else { return true }
        return (try? AndroidDataManifest.load(from: url))?.id == id
    }

    /// Why the record's folder was not found.
    private func diagnose(_ record: StorageLocationRecord) -> StorageProblem {
        let url = URL(filePath: record.path, directoryHint: .isDirectory)
        if let error = Self.accessError(url) {
            if error == EPERM || error == EACCES { return .notPermitted(path: record.path) }
            // The volume of the nearest folder that is there: the record's own,
            // or (its drive gone) the one its mount point folder is on.
            let nearest = Self.volumeSummary(for: url)
            let volumeThere: Bool
            if let uuid = record.volumeUUID {
                volumeThere = nearest?.uuid == uuid || Self.mountedVolumes().contains { $0.uuid == uuid }
            } else if record.path.hasPrefix("/Volumes/") {
                let mount = "/Volumes/" + Self.volumeName(fromPath: record.path)
                volumeThere = nearest?.mountPoint == mount
            } else {
                volumeThere = true
            }
            if !volumeThere {
                return .volumeMissing(volume: record.volumeName ?? Self.volumeName(fromPath: record.path), path: record.path)
            }
            return .folderMissing(path: record.path)
        }
        do {
            _ = try AndroidDataManifest.load(from: url)
        } catch .notPermitted {
            return .notPermitted(path: record.path)
        } catch .unknownFormat(let version) {
            return .unknownFormat(path: record.path, version: version)
        } catch {}
        return .otherData(path: record.path)
    }

    static func volumeName(fromPath path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count >= 2 && parts[0] == "Volumes" ? String(parts[1]) : path
    }

    /// errno of opening `url` as a folder (nil: it opens).
    static func accessError(_ url: URL) -> Int32? {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY)
        guard fd < 0 else {
            close(fd)
            return nil
        }
        return errno
    }

    /// A record for the folder: its path, a bookmark and its volume.
    static func record(for folder: URL, id: UUID?, chosenAt: Date = Date()) -> StorageLocationRecord {
        let volume = volumeSummary(for: folder)
        let path = folder.standardizedFileURL.path
        var inVolume: String?
        if let mount = volume?.mountPoint, mount != "/", path.hasPrefix(mount + "/") { inVolume = String(path.dropFirst(mount.count)) }
        let bookmark = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: [.volumeNameKey, .volumeUUIDStringKey],
                                                relativeTo: nil)
        return StorageLocationRecord(path: path, bookmark: bookmark, volumeName: volume?.name, volumeUUID: volume?.uuid,
                                     pathInVolume: inVolume, dataID: id, chosenAt: chosenAt)
    }

    // MARK: Volumes

    static func mountedVolumes() -> [VolumeSummary] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { volumeSummary(for: $0) }
    }

    /// The volume `url` is on (the nearest folder that exists decides).
    static func volumeSummary(for url: URL) -> VolumeSummary? {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe = probe.deletingLastPathComponent() }
        var info = statfs()
        guard statfs(probe.path, &info) == 0 else { return nil }
        func text<T>(_ value: T) -> String {
            withUnsafeBytes(of: value) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
        let mountPoint = text(info.f_mntonname)
        let format = text(info.f_fstypename)
        let startupDisk = mountPoint == "/" || mountPoint.hasPrefix("/System/Volumes/")
        var keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                         .volumeUUIDStringKey, .volumeIsLocalKey]
        // Purgeable space counts on the startup disk (other volumes only log that they have none).
        if startupDisk { keys.insert(.volumeAvailableCapacityForImportantUsageKey) }
        let values = try? URL(filePath: mountPoint, directoryHint: .isDirectory).resourceValues(forKeys: keys)
        var free = Int64(info.f_bavail) * Int64(info.f_bsize)
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > free { free = important }
        let network = ["smbfs", "nfs", "afpfs", "webdav", "ftp", "cifs"].contains(format) || values?.volumeIsLocal == false
        let isInternal = values?.volumeIsInternal ?? (mountPoint == "/" || mountPoint.hasPrefix("/System/Volumes/"))
        let name = values?.volumeName ?? (mountPoint == "/" ? "Macintosh HD" : URL(filePath: mountPoint).lastPathComponent)
        return VolumeSummary(name: name, mountPoint: mountPoint, format: format, freeBytes: free,
                             capacityBytes: Int64(info.f_blocks) * Int64(info.f_bsize), isInternal: isInternal && !network,
                             isRemovable: (values?.volumeIsRemovable ?? false) || (values?.volumeIsEjectable ?? false) || !isInternal,
                             isReadOnly: info.f_flags & UInt32(MNT_RDONLY) != 0, isNetwork: network, uuid: values?.volumeUUIDString)
    }

    // MARK: Status

    func status() -> StorageLocationStatus {
        let resolution = resolve()
        let isInternal = resolution.record == nil
        var status = StorageLocationStatus(path: resolution.folder.standardizedFileURL.path, isInternal: isInternal,
                                           volumeName: resolution.record?.volumeName, problem: resolution.problem, change: change)
        if resolution.problem == nil {
            status.volume = Self.volumeSummary(for: resolution.folder)
            status.volumeName = status.volume?.name ?? status.volumeName
            let folder = AndroidDataFolder(resolution.folder)
            status.data = folder.summary(manifest: try? AndroidDataManifest.load(from: resolution.folder))
            status.data?.checkpoints = CheckpointStore.count(in: resolution.folder)
        }
        if !isInternal {
            let own = AndroidDataFolder(paths.vm)
            if FileManager.default.fileExists(atPath: own.dataDisk.path) {
                status.internalCopy = own.summary(manifest: try? AndroidDataManifest.load(from: paths.vm))
                // Removing the copy removes them too (Settings › Storage says so).
                status.internalCopy?.checkpoints = CheckpointStore.count(in: paths.vm)
            }
        }
        guardVolume(resolution, volume: status.volume)
        return status
    }

    /// The volume an eject must wait for while Android runs: the data's,
    /// when it is not the Mac's own disk.
    private func guardVolume(_ resolution: Resolution, volume: VolumeSummary?) {
        let guarded = resolution.record != nil && resolution.problem == nil ? volume.flatMap { $0.mountPoint == "/" ? nil : $0 } : nil
        volumeGuard.setDataVolume(mountPoint: guarded?.mountPoint, name: guarded?.name ?? resolution.record?.volumeName)
    }

    /// Before every start: the data must be where the record says, whole, and
    /// in a format this Avo reads (a newer Android is refused with the image).
    func prepareForStart() throws {
        if isChanging { throw AvoError.storage(.changing) }
        let resolution = resolve()
        guardVolume(resolution, volume: resolution.record == nil ? nil : Self.volumeSummary(for: resolution.folder))
        if let problem = resolution.problem {
            logger.error("Android's data is not available: \(problem.message, privacy: .public)")
            throw AvoError.storage(problem)
        }
        // A restore the daemon could not finish (bootVM tries first) left
        // disks from two sides: Android would ask to erase its data.
        if RestoreJournal.exists(in: resolution.folder) {
            logger.error("a checkpoint restore was cut short and is not finished")
            throw AvoError.internalError(RestoreJournal.cutShortMessage)
        }
        guard resolution.record != nil else { return }
        if let problem = AndroidDataFolder(resolution.folder).problem(images: []) { throw AvoError.storage(problem) }
    }

    /// Notes in the folder's manifest who used it and with which Android, and
    /// whether it has Google apps (at every start, once Android answers).
    func stamp(avoVersion: String) {
        guard !isChanging else { return }
        let googleApps = (try? VMConfig.load(from: paths.config))?.gms == .bringYourOwn
        let folder = paths.data
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        var manifest: AndroidDataManifest
        do {
            manifest = try AndroidDataManifest.load(from: folder)
        } catch .missing {
            manifest = AndroidDataManifest()
        } catch {
            return
        }
        let data = AndroidDataFolder(folder)
        manifest.lastUsedAt = AndroidDataManifest.wholeSeconds(Date())
        manifest.lastMac = Self.macName
        if let record = data.dataRecord() {
            manifest.android = record.release
            manifest.build = record.build
        }
        manifest.diskBytes = DataDiskStore.size(data.dataDisk)
        manifest.storageCreated = DataDiskStore.isWritten(data.dataDisk)
        manifest.googleApps = googleApps
        manifest.avoVersion = avoVersion
        do { try manifest.write(to: folder) } catch {
            logger.error("could not update \(AvoPaths.dataManifestName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    static var macName: String? {
        SCDynamicStoreCopyComputerName(nil, nil) as String?
    }

    // MARK: Looking at a folder the user chose

    /// The data folder for a folder the user chose: the chosen folder when it
    /// holds Android's data, else `Avo Android Data` inside it.
    static func dataFolder(for chosen: URL) -> URL {
        if AndroidDataFolder(chosen).holdsData || chosen.lastPathComponent == AvoPaths.dataFolderName { return chosen }
        return chosen.appending(path: AvoPaths.dataFolderName, directoryHint: .isDirectory)
    }

    func inspect(_ path: String?) -> StorageCandidate {
        let current = resolve()
        let currentFolder = AndroidDataFolder(current.folder)
        let currentAvailable = current.problem == nil
        let ownPath = paths.vm.standardizedFileURL.path
        var issues: [StorageIssue] = []
        let chosen: URL
        var folder: URL
        if let path, !path.isEmpty {
            chosen = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
            folder = chosen.path == ownPath ? paths.vm : Self.dataFolder(for: chosen)
        } else {
            chosen = paths.vm
            folder = paths.vm
        }
        folder = folder.standardizedFileURL
        let isInternal = folder.path == ownPath
        let isCurrent = folder.path == current.folder.standardizedFileURL.path
        let support = paths.applicationSupport.standardizedFileURL.path
        if !isInternal, folder.path == support || folder.path.hasPrefix(support + "/") {
            issues.append(StorageIssue(.error, .all, String(localized: "Choose a folder outside Avo’s own folder.", bundle: .avoKit)))
        }
        if !isCurrent, !current.folder.path.isEmpty, folder.path.hasPrefix(current.folder.standardizedFileURL.path + "/") {
            issues.append(StorageIssue(.error, .all, String(localized: "Choose a folder outside Android’s data folder.", bundle: .avoKit)))
        }
        if !isInternal, !FileManager.default.fileExists(atPath: chosen.path) {
            issues.append(StorageIssue(.error, .all, String(localized: "\(chosen.path) does not exist.", bundle: .avoKit)))
        }
        // A disk image there would be uploaded again and again while Android runs.
        let home = paths.home.standardizedFileURL.path
        if ["/Library/Mobile Documents", "/Library/CloudStorage"].contains(where: { folder.path.hasPrefix(home + $0 + "/") }) {
            issues.append(StorageIssue(.error, .all, String(localized: "Android’s data can’t be in a folder that syncs to the cloud (iCloud Drive, Dropbox, Google Drive …): it changes all the time while Android runs. Choose a folder on this Mac or a drive.", bundle: .avoKit)))
        }
        let volume = destinationVolume(folder)
        var problem: StorageProblem?
        if let error = Self.accessError(FileManager.default.fileExists(atPath: folder.path) ? folder : chosen),
           error == EPERM || error == EACCES {
            problem = .notPermitted(path: chosen.path)
        }
        let target = AndroidDataFolder(folder)
        var existing: AndroidDataSummary?
        if problem == nil, target.holdsData {
            let manifest = try? AndroidDataManifest.load(from: folder)
            existing = target.summary(manifest: manifest)
            // Replacing Avo's own copy erases them with it (the sheet says so).
            existing?.checkpoints = CheckpointStore.count(in: folder)
            problem = target.problem(images: images())
        }
        let usage = currentAvailable ? currentFolder.usage() : (allocated: Int64(0), logical: Int64(0))
        var moveBytes = usage.allocated
        if let volume, !volume.keepsSparseFiles { moveBytes = usage.logical }
        // The checkpoints beside the data now: whether a move takes them along.
        var checkpoints: CheckpointsMove?
        if !isCurrent, currentAvailable, existing == nil || isInternal {
            let movable = CheckpointStore.movable(in: current.folder)
            let sameVolume = cloning && volume != nil && Self.volumeSummary(for: current.folder)?.mountPoint == volume?.mountPoint
            checkpoints = Self.checkpointsMove(count: movable.count, bytes: movable.bytes, to: volume, sameVolume: sameVolume,
                                               dataBytes: moveBytes)
        }
        if let volume {
            let name = volume.name
            if volume.isNetwork {
                issues.append(StorageIssue(.error, .all, String(localized: "Android’s data can’t be on a network volume. Choose a drive connected to this Mac.", bundle: .avoKit)))
            } else if volume.isReadOnly {
                issues.append(StorageIssue(.error, .all, String(localized: "“\(name)” is read-only.", bundle: .avoKit)))
            }
            switch volume.format {
            case "apfs":
                break
            case "msdos":
                issues.append(StorageIssue(.error, .all, String(localized: "“\(name)” is formatted as MS-DOS (FAT), which can’t hold files over 4 GB, and Android’s data disk is bigger. Format the drive as APFS in Disk Utility.", bundle: .avoKit)))
            case "exfat":
                issues.append(StorageIssue(.warning, .all, String(localized: "“\(name)” is formatted as ExFAT. It has no sparse files, so Android’s data disk takes its full size on the drive, and no journal, so unplugging the drive while Android runs can damage it. APFS is better: format the drive as APFS in Disk Utility.", bundle: .avoKit)))
            case "hfs":
                issues.append(StorageIssue(.warning, .all, String(localized: "“\(name)” is formatted as Mac OS Extended, which has no sparse files: Android’s data disk takes its full size on the drive. APFS keeps it as small as what Android stores.", bundle: .avoKit)))
            default:
                if !volume.isNetwork {
                    issues.append(StorageIssue(.warning, .all, String(localized: "“\(name)” is formatted as \(volume.formatName). Avo is made for APFS drives; format it as APFS in Disk Utility if Android has trouble with it.", bundle: .avoKit)))
                }
            }
            if !isCurrent, currentAvailable, existing == nil || isInternal {
                let needed = moveBytes + Self.spareBytes
                if volume.freeBytes < needed {
                    issues.append(StorageIssue(.error, .move, String(localized: "Moving Android’s data needs \(Self.bytes(needed)) on “\(name)”, which has \(Self.bytes(volume.freeBytes)) free.", bundle: .avoKit)))
                } else if volume.keepsSparseFiles, usage.logical > 0, volume.freeBytes < usage.logical {
                    let disk = DataDiskStore.size(currentFolder.dataDisk)
                    issues.append(StorageIssue(.warning, .move, String(localized: "Android’s storage can grow to \(Self.bytes(disk)); “\(name)” has \(Self.bytes(volume.freeBytes)) free. Android runs out of space when the drive is full.", bundle: .avoKit)))
                }
            }
            if volume.isRemovable, !volume.isInternal {
                issues.append(StorageIssue(.warning, .all, String(localized: "Eject “\(name)” only while Android is stopped. If you eject it while Android runs, Avo stops Android first and asks you to eject again.", bundle: .avoKit)))
            }
        }
        if !currentAvailable {
            issues.append(StorageIssue(.error, .move, current.problem?.message ?? String(localized: "Android’s data is not available.", bundle: .avoKit)))
        }
        if existing != nil, !isInternal {
            issues.append(StorageIssue(.error, .move, String(localized: "This folder already holds Android data. Use it, or choose another folder.", bundle: .avoKit)))
            issues.append(StorageIssue(.error, .fresh, String(localized: "This folder already holds Android data. Use it, or choose another folder.", bundle: .avoKit)))
        }
        return StorageCandidate(chosen: chosen.path, folder: folder.path, isInternal: isInternal, isCurrent: isCurrent, volume: volume,
                                existing: existing, problem: problem, issues: issues, moveBytes: moveBytes, currentAvailable: currentAvailable,
                                checkpoints: checkpoints)
    }

    /// What a move to `volume` does with `count` checkpoints whose copies
    /// take `bytes`: APFS clones where the data stays on its volume, copies
    /// on another APFS volume where they fit beside the data (`dataBytes`),
    /// else they stay with the old copy. Off APFS no checkpoint can be
    /// restored, so none goes there.
    static func checkpointsMove(count: Int, bytes: Int64, to volume: VolumeSummary?, sameVolume: Bool,
                                dataBytes: Int64) -> CheckpointsMove? {
        guard count > 0 else { return nil }
        // A volume statfs cannot describe: the copy finds out (one that
        // runs out of room fails the move, and nothing changes).
        guard let volume else { return CheckpointsMove(count: count, bytes: bytes) }
        guard volume.keepsSparseFiles else { return CheckpointsMove(count: count, bytes: bytes, obstacle: .format(volume.formatName)) }
        if sameVolume { return CheckpointsMove(count: count, bytes: 0) }
        guard volume.freeBytes >= dataBytes + bytes + spareBytes else { return CheckpointsMove(count: count, bytes: bytes, obstacle: .room) }
        return CheckpointsMove(count: count, bytes: bytes)
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .decimal) }

    // MARK: Changing where it is

    enum Outcome: Sendable, Equatable {
        /// The same data, somewhere else.
        case moved
        /// Other data (carried from another Mac, or the copy kept in Avo's own storage).
        case adopted(AndroidDataManifest?)
        /// No data yet: Android creates its storage at `gb` at its next start.
        case fresh(gb: Int)
    }

    func cancel() {
        guard isChanging else { return }
        cancelRequested = true
    }

    /// Changes where Android's data is (Android is stopped: the caller sees to it).
    func perform(_ request: StorageChangeRequest, report: @escaping @Sendable (StorageChangeProgress) -> Void) async throws -> Outcome {
        guard !isChanging else {
            throw AvoError.internalError(String(localized: "Avo is already changing where Android’s data is.", bundle: .avoKit))
        }
        cancelRequested = false
        let id = request.id
        func publish(_ progress: StorageChangeProgress) {
            change = progress
            report(progress)
        }
        publish(StorageChangeProgress(id: id, phase: .checking))
        do {
            let outcome = try await apply(request, publish: publish)
            publish(StorageChangeProgress(id: id, phase: .finished, doneBytes: change?.totalBytes ?? 0, totalBytes: change?.totalBytes ?? 0))
            volumeGuard.setMoving([])
            _ = status()
            return outcome
        } catch {
            volumeGuard.setMoving([])
            let cancelled = error is CancellationError
            let message = cancelled ? Self.stoppedMessage : (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            publish(StorageChangeProgress(id: id, phase: cancelled ? .cancelled : .failed, message: message))
            _ = status()
            throw cancelled ? AvoError.internalError(message) : error
        }
    }

    static var stoppedMessage: String {
        String(localized: "Moving stopped. Android’s data stays where it was.", bundle: .avoKit)
    }

    private func refusal(_ candidate: StorageCandidate, _ scope: StorageIssue.Scope) -> any Error {
        if let issue = candidate.issues(for: scope).first(where: { $0.severity == .error }) { return AvoError.internalError(issue.message) }
        if candidate.isCurrent { return AvoError.internalError(String(localized: "Android’s data is there already.", bundle: .avoKit)) }
        if let problem = candidate.problem { return AvoError.storage(problem) }
        if scope == .existing { return AvoError.internalError(String(localized: "There is no Android data in this folder.", bundle: .avoKit)) }
        return AvoError.internalError(String(localized: "This folder already holds Android data. Use it, or choose another folder.", bundle: .avoKit))
    }

    private func apply(_ request: StorageChangeRequest, publish: (StorageChangeProgress) -> Void) async throws -> Outcome {
        let candidate = inspect(request.destination)
        let destination = URL(filePath: candidate.folder, directoryHint: .isDirectory)
        let replacing = candidate.isInternal && candidate.existing != nil
        switch request.action {
        case .move(let keepOldCopy):
            guard candidate.allows(.move) else { throw refusal(candidate, .move) }
            guard !replacing || request.replaceExisting else {
                throw AvoError.internalError(String(localized: "Avo’s own storage holds a copy of Android’s data already. Use it, or replace it.", bundle: .avoKit))
            }
            // Checkpoints the move can't take along stay with the old copy;
            // without one they go only when the user was told how many.
            let checkpoints = candidate.checkpoints
            if let checkpoints, !checkpoints.comeAlong, !keepOldCopy, !request.leavesCheckpoints {
                let name = candidate.volume?.name ?? destination.lastPathComponent
                throw AvoError.internalError(String(localized: "Android’s checkpoints can’t come along to “\(name)”. Keep the old copy to keep them.", bundle: .avoKit))
            }
            let source = resolve().folder
            // Half of a checkpoint's disks would travel as Android's data.
            if RestoreJournal.exists(in: source) { throw AvoError.internalError(RestoreJournal.cutShortMessage) }
            if replacing { try removeData(in: paths.vm) }
            let carried = checkpoints?.comeAlong == true ? CheckpointStore.movable(in: source).files : []
            try await copyData(from: source, to: destination, checkpoints: carried, id: request.id, publish: publish)
            var manifest = (try? AndroidDataManifest.load(from: source)) ?? AndroidDataManifest()
            if manifest.diskBytes == nil { manifest.diskBytes = DataDiskStore.size(AndroidDataFolder(source).dataDisk) }
            try manifest.write(to: destination)
            publish(StorageChangeProgress(id: request.id, phase: .switching))
            try use(destination, isInternal: candidate.isInternal, id: manifest.id)
            if !keepOldCopy {
                publish(StorageChangeProgress(id: request.id, phase: .removingOld))
                try removeData(in: source)
                if source.standardizedFileURL.path != paths.vm.standardizedFileURL.path { Self.removeIfEmpty(source) }
            }
            let left = checkpoints.map { $0.comeAlong ? "came along" : keepOldCopy ? "stayed with the old copy" : "went with the old copy" }
            logger.notice("moved Android's data to \(destination.path, privacy: .public) (old copy \(keepOldCopy ? "kept" : "removed", privacy: .public); its \(checkpoints?.count ?? 0) checkpoints \(left ?? "-", privacy: .public))")
            return .moved
        case .useExisting:
            guard candidate.allows(.existing) || (request.allowNewerAndroid && candidate.existingNeedsNewerAndroid) else {
                throw refusal(candidate, .existing)
            }
            publish(StorageChangeProgress(id: request.id, phase: .switching))
            var manifest = try? AndroidDataManifest.load(from: destination)
            if manifest == nil, !candidate.isInternal {
                // A folder from before manifests (copied by hand): it gets one.
                let made = AndroidDataManifest(diskBytes: DataDiskStore.size(AndroidDataFolder(destination).dataDisk),
                                               storageCreated: DataDiskStore.isWritten(AndroidDataFolder(destination).dataDisk))
                try made.write(to: destination)
                manifest = made
            }
            try use(destination, isInternal: candidate.isInternal, id: manifest?.id)
            logger.notice("using the Android data at \(destination.path, privacy: .public)")
            return .adopted(manifest)
        case .startFresh(let gb):
            guard candidate.allows(.fresh) else { throw refusal(candidate, .fresh) }
            if let issue = candidate.freshIssue(gb: gb), issue.severity == .error { throw AvoError.internalError(issue.message) }
            guard !replacing || request.replaceExisting else {
                throw AvoError.internalError(String(localized: "Avo’s own storage holds a copy of Android’s data already. Use it, or replace it.", bundle: .avoKit))
            }
            publish(StorageChangeProgress(id: request.id, phase: .switching))
            if replacing { try removeData(in: paths.vm) }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let manifest = AndroidDataManifest(diskBytes: VMConfig.dataDiskBytes(gb: gb))
            try manifest.write(to: destination)
            try use(destination, isInternal: candidate.isInternal, id: manifest.id)
            logger.notice("Android's data starts fresh at \(destination.path, privacy: .public)")
            return .fresh(gb: gb)
        }
    }

    /// Android's data is in `folder` from now on.
    private func use(_ folder: URL, isInternal: Bool, id: UUID?) throws {
        if isInternal {
            try StorageLocationRecord.remove(paths)
        } else {
            try Self.record(for: folder, id: id).save(paths)
        }
    }

    /// Folder a move copies into, beside the data's place: nothing in it
    /// counts as Android's data until the copy is checked and moved in.
    static let stagingName = ".avo-moving"

    /// Copies and checks every portable item and the `checkpoints` files
    /// (CheckpointStore.movable) in a staging folder, then moves them into
    /// place, each checkpoint whole, the data disk last (with no data disk, a
    /// folder an interrupted move left holds no Android data). On any
    /// failure the staging folder goes again.
    private func copyData(from source: URL, to destination: URL, checkpoints: [String], id: UUID,
                          publish: (StorageChangeProgress) -> Void) async throws {
        let createdFolder = !FileManager.default.fileExists(atPath: destination.path)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // Noted until the copy is in place or gone (`cleanInterruptedMoves`).
        noteMove(to: destination, createdFolder: createdFolder)
        defer { forgetMove(to: destination) }
        let staging = destination.appending(path: Self.stagingName, directoryHint: .isDirectory)
        // What a move the daemon did not see to its end left.
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let items = AvoPaths.portableDataItems.filter { $0 != AvoPaths.dataManifestName } + checkpoints
        var mounts: Set<String> = []
        for folder in [source, destination] {
            if let volume = Self.volumeSummary(for: folder), volume.mountPoint != "/" { mounts.insert(volume.mountPoint) }
        }
        volumeGuard.setMoving(mounts)
        do {
            let (stream, sink) = AsyncStream.makeStream(of: StorageChangeProgress.self, bufferingPolicy: .bufferingNewest(1))
            var copier = try DataCopier(source: source, destination: staging, relative: items)
            let total = copier.totalBytes
            let cancelled = CancelFlag()
            copier.isCancelled = { cancelled.isSet }
            copier.cloning = cloning
            copier.progress = { phase, done, total in
                sink.yield(StorageChangeProgress(id: id, phase: phase == .copying ? .copying : .verifying, doneBytes: done, totalBytes: total))
            }
            publish(StorageChangeProgress(id: id, phase: .copying, totalBytes: total))
            let work = Task.detached { [copier] in
                defer { sink.finish() }
                try copier.run()
            }
            var last = ContinuousClock.now - .seconds(1)
            for await progress in stream {
                if cancelRequested { cancelled.set() }
                // At most a few times a second.
                if ContinuousClock.now - last > .milliseconds(250) || progress.doneBytes == progress.totalBytes {
                    last = .now
                    publish(progress)
                }
            }
            try await work.value
            // Into place (renames on one volume): the disks bound to the data,
            // the checkpoints, each folder whole with its record, then the
            // data disk last.
            let names = copier.items.map(\.relative).filter { !$0.hasPrefix(CheckpointStore.folderName + "/") }
            try FileManager.default.createDirectory(at: destination.appending(path: "cuttlefish", directoryHint: .isDirectory),
                                                    withIntermediateDirectories: true)
            for item in names where item != "userdata.img" {
                try Self.replace(destination.appending(path: item), with: staging.appending(path: item))
            }
            let stagedCheckpoints = staging.appending(path: CheckpointStore.folderName, directoryHint: .isDirectory)
            let checkpointIDs = (try? FileManager.default.contentsOfDirectory(atPath: stagedCheckpoints.path)) ?? []
            if !checkpointIDs.isEmpty {
                let folder = destination.appending(path: CheckpointStore.folderName, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for name in checkpointIDs {
                    try Self.replace(folder.appending(path: name, directoryHint: .isDirectory),
                                     with: stagedCheckpoints.appending(path: name, directoryHint: .isDirectory))
                }
            }
            if names.contains("userdata.img") {
                try Self.replace(destination.appending(path: "userdata.img"), with: staging.appending(path: "userdata.img"))
            }
            try? FileManager.default.removeItem(at: staging)
        } catch {
            logger.error("moving Android's data failed: \(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: staging)
            if createdFolder { Self.removeIfEmpty(destination) }
            throw error
        }
    }

    // MARK: Moves the daemon did not see to their end

    /// A folder a move copies into (`data-moves.json` in Application
    /// Support), so a move cut short (Avo quit, the Mac stopped) leaves no
    /// hidden copy as big as the data behind: on a drive without sparse
    /// files its staging folder takes the data disk's whole size.
    struct MoveInProgress: Codable, Equatable {
        var destination: String
        /// The move made the folder: it goes again once nothing is in it.
        var createdFolder: Bool
        var startedAt: Date
    }

    private var movesFile: URL { paths.applicationSupport.appending(path: "data-moves.json") }

    private func moves() -> [MoveInProgress] {
        (try? Data(contentsOf: movesFile)).flatMap { try? JSONDecoder().decode([MoveInProgress].self, from: $0) } ?? []
    }

    private func saveMoves(_ moves: [MoveInProgress]) {
        do {
            if moves.isEmpty {
                if FileManager.default.fileExists(atPath: movesFile.path) { try FileManager.default.removeItem(at: movesFile) }
            } else {
                try JSONEncoder().encode(moves).write(to: movesFile, options: .atomic)
            }
        } catch {
            logger.error("could not note the moves under way: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func noteMove(to destination: URL, createdFolder: Bool) {
        let path = destination.standardizedFileURL.path
        saveMoves(moves().filter { $0.destination != path } + [MoveInProgress(destination: path, createdFolder: createdFolder, startedAt: Date())])
    }

    private func forgetMove(to destination: URL) {
        let path = destination.standardizedFileURL.path
        saveMoves(moves().filter { $0.destination != path })
    }

    /// At the daemon's start, while nothing moves: the staging folder of
    /// every move that did not end goes (its copy never became Android's
    /// data: that happens only after it was moved out of it), with the
    /// folder the move made when nothing else is in it, and those of moves
    /// into Avo's own storage or the data's folder from before moves were
    /// noted. A drive that isn't connected is looked at again at the next
    /// start, for a month.
    func cleanInterruptedMoves() {
        guard !isChanging else { return }
        var kept: [MoveInProgress] = []
        for move in moves() {
            let folder = URL(filePath: move.destination, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: folder.path) else {
                if !FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path),
                   Date().timeIntervalSince(move.startedAt) < 30 * 24 * 3600 { kept.append(move) }
                continue
            }
            guard Self.removeStaging(in: folder, logger: logger) else {
                kept.append(move)
                continue
            }
            if move.createdFolder { Self.removeIfEmpty(folder) }
        }
        saveMoves(kept)
        for folder in Set([paths.vm.standardizedFileURL, paths.data.standardizedFileURL]) {
            _ = Self.removeStaging(in: folder, logger: logger)
        }
    }

    /// Removes `folder`'s `.avo-moving`; false when it is still there.
    private static func removeStaging(in folder: URL, logger: Logger) -> Bool {
        let staging = folder.appending(path: stagingName, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: staging.path) else { return true }
        do {
            try FileManager.default.removeItem(at: staging)
            logger.notice("removed what a move cut short left in \(folder.path, privacy: .public)")
            return true
        } catch {
            logger.error("could not remove \(staging.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// `target` becomes what `staged` is (a rename on one volume).
    private static func replace(_ target: URL, with staged: URL) throws {
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: staged, to: target)
    }

    /// Removes Android's data from `folder` (every portable item), and the
    /// checkpoints of that data (CheckpointStore): a move took them along or
    /// said they can't come (CheckpointsMove), and replacing or removing the
    /// copy in Avo's own storage says how many go with it.
    private func removeData(in folder: URL) throws {
        for item in AvoPaths.portableDataItems + [CheckpointStore.folderName] {
            let url = folder.appending(path: item)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    /// The copy kept in Avo's own storage, while another folder is used.
    func removeInternalCopy() throws {
        guard !isChanging, StorageLocationRecord.load(paths) != nil else { return }
        try removeData(in: paths.vm)
        logger.notice("removed the copy of Android's data in Avo's own storage")
    }

    /// A data folder Avo emptied (only its lock files and Finder's left).
    static func removeIfEmpty(_ folder: URL) {
        let leftovers: Set<String> = [".DS_Store", "vm.lock"]
        let disks = folder.appending(path: "cuttlefish", directoryHint: .isDirectory)
        for dir in [disks, folder] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            guard names.allSatisfy({ leftovers.contains($0) || ($0 == "cuttlefish" && !FileManager.default.fileExists(atPath: disks.path)) })
            else { continue }
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

/// Set once from the actor, read from the copy's thread.
final class CancelFlag: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}
