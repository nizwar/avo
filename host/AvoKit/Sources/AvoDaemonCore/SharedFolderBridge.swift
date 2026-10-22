import AvoKit
import CoreServices
import Foundation
import os

// Settings › Storage › Shared Folder in Android (SharedFolder.swift). avo-vmm
// serves the folder over virtio-fs (tag `avo_shared`, `--shared-dir`); every
// start HostAgent mounts it, once Android's storage is unlocked, at
// /mnt/avo_shared and binds that into the media storage as
// /data/media/0/Avo Shared, which apps and file pickers see as
// /sdcard/Avo Shared through MediaProvider. Android's own changes reach its
// media index as usual; the Mac's are told to it, a folder at a time, from
// FSEvents (`content call … scan_file`), so photos and music copied on the
// Mac show up in Android's apps too.

/// The guest's side: shell steps run as root, and what they print.
enum GuestSharedFolder {
    static let tag = "avo_shared"
    static let mountPoint = "/mnt/avo_shared"
    /// In Android's media storage (the lower file system MediaProvider serves).
    static let mediaPath = "/data/media/0/\(SharedFolder.androidName)"
    /// The same folder as apps see it.
    static let storagePath = "/storage/emulated/0/\(SharedFolder.androidName)"

    /// Whether user 0's credential-encrypted storage is unlocked (its media storage is there).
    static let unlockedCommand = "getprop sys.user.0.ce_available"

    /// Mounts the folder (idempotent): prints `mounted`, `unavailable` (no
    /// such virtio-fs device this start) or `failed …`. A folder of that
    /// name Android already had with something in it is kept, renamed.
    static var mountScript: String {
        let media = HostAgent.quote(mediaPath)
        let kept = HostAgent.quote("\(mediaPath) (Android)")
        return [
            "M=\(mountPoint); S=\(media)",
            "mkdir -p $M",
            "if ! grep -qF \" $M virtiofs \" /proc/mounts; then",
            "  mount -t virtiofs -o nosuid,nodev,noexec,noatime,context=u:object_r:media_rw_data_file:s0 \(tag) $M 2>/dev/null || { echo unavailable; exit 0; }",
            "fi",
            "if grep -qF \" \(mountsEscaped(mediaPath)) \" /proc/mounts; then echo mounted; exit 0; fi",
            "if [ -d \"$S\" ] && [ -n \"$(ls -A \"$S\" 2>/dev/null)\" ]; then mv \"$S\" \(kept) 2>/dev/null || mv \"$S\" \"$S.$$\"; fi",
            "mkdir -p \"$S\" && chown 1023:1023 \"$S\" && chmod 2770 \"$S\"",
            "mount --bind $M \"$S\" 2>&1 && echo mounted || echo failed",
        ].joined(separator: "\n")
    }

    /// Sharing is off: the empty folder an earlier start left goes (never
    /// one with something in it), and so do its entries in the media index.
    static var cleanUpScript: String {
        let media = HostAgent.quote(mediaPath)
        return [
            "S=\(media)",
            "grep -qF \" \(mountsEscaped(mediaPath)) \" /proc/mounts && exit 0",
            "[ -d \"$S\" ] && rmdir \"$S\" 2>/dev/null && \(scanCommand(storagePath)) >/dev/null 2>&1",
            "exit 0",
        ].joined(separator: "\n")
    }

    /// /proc/mounts writes a space as \040.
    static func mountsEscaped(_ path: String) -> String {
        path.replacingOccurrences(of: " ", with: "\\\\040")
    }

    /// MediaProvider looks at a file or a folder (and what is in it) again.
    static func scanCommand(_ path: String) -> String {
        "content call --uri content://media/ --method scan_file --arg \(HostAgent.quote(path))"
    }

    static func mount(fromOutput output: String) -> SharedFolderMount {
        let last = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        switch last.trimmingCharacters(in: .whitespaces) {
        case "mounted": return .mounted
        case "unavailable": return .unavailable
        default: return .failed
        }
    }

    /// Android's paths for the Mac folders FSEvents named (under `root`):
    /// each once, none inside another, and the whole folder for more than
    /// `limit` (or for anything outside it).
    static func scanPaths(for changed: [String], root: String, limit: Int = 8) -> [String] {
        let root = root.hasSuffix("/") ? String(root.dropLast()) : root
        var relatives: [String] = []
        for path in changed {
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            guard trimmed == root || trimmed.hasPrefix(root + "/") else { return [storagePath] }
            relatives.append(String(trimmed.dropFirst(root.count)))
        }
        // Shortest first: a folder covers what is inside it.
        var chosen: [String] = []
        for relative in Set(relatives).sorted(by: { $0.count < $1.count || ($0.count == $1.count && $0 < $1) }) {
            if chosen.contains(where: { relative == $0 || $0.isEmpty || relative.hasPrefix($0 + "/") }) { continue }
            chosen.append(relative)
        }
        if chosen.count > limit || chosen.contains("") { return [storagePath] }
        return chosen.map { storagePath + $0 }
    }
}

/// One start's shared folder in Android: mounts it, then passes the Mac's
/// changes to Android's media index. Owned by HostAgent.
actor SharedFolderBridge {
    /// How long the Mac's changes gather before Android hears of them.
    static let quiet: Duration = .seconds(1)

    let folder: URL?
    private let run: @Sendable (String) async -> String?
    private let paused: @Sendable () async -> Bool
    private(set) var mount: SharedFolderMount?
    private var watcher: FolderWatcher?
    private var pending: [String] = []
    private var flushing: Task<Void, Never>?
    private var stopped = false
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "SharedFolder")

    /// `folder`: this start's (nil: sharing is off); `run`: a root shell
    /// command's output (nil when it failed); `paused`: Android is paused.
    init(folder: URL?, run: @escaping @Sendable (String) async -> String?, paused: @escaping @Sendable () async -> Bool) {
        self.folder = folder
        self.run = run
        self.paused = paused
    }

    /// After Android is ready: waits for its storage to be unlocked, mounts,
    /// and starts following the Mac's changes.
    func start() async {
        guard let folder else {
            _ = await run(GuestSharedFolder.cleanUpScript)
            return
        }
        mount = .waiting
        while !stopped {
            let isPaused = await paused()
            if !isPaused, await run(GuestSharedFolder.unlockedCommand)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
                break
            }
            try? await Task.sleep(for: .seconds(2))
        }
        guard !stopped else { return }
        let output = await run(GuestSharedFolder.mountScript) ?? ""
        mount = GuestSharedFolder.mount(fromOutput: output)
        logger.notice("shared folder \(folder.path, privacy: .public): \(self.mount?.rawValue ?? "?", privacy: .public)")
        guard mount == .mounted else {
            if mount == .failed { logger.error("mounting the shared folder: \(output, privacy: .public)") }
            return
        }
        // What changed on the Mac while Android was off.
        let root = Self.realPath(folder)
        pending.append(root)
        scheduleFlush()
        watcher = FolderWatcher(path: root, latency: 1) { [weak self] paths in
            Task { await self?.changed(paths) }
        }
    }

    func stop() {
        stopped = true
        watcher = nil
        flushing?.cancel()
    }

    private func changed(_ paths: [String]) {
        guard !stopped else { return }
        pending += paths
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushing == nil else { return }
        flushing = Task { [weak self] in
            try? await Task.sleep(for: Self.quiet)
            await self?.flush()
        }
    }

    /// Tells Android's media index (a paused Android hears once it goes on).
    private func flush() async {
        while await paused(), !stopped { try? await Task.sleep(for: .seconds(2)) }
        flushing = nil
        guard !stopped, let folder, !pending.isEmpty else { return }
        let paths = GuestSharedFolder.scanPaths(for: pending, root: Self.realPath(folder))
        pending = []
        for path in paths {
            _ = await run(GuestSharedFolder.scanCommand(path))
        }
    }

    /// The folder as FSEvents names it (/tmp is /private/tmp).
    static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// FSEvents for one folder: the folders in it where something changed.
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let root: String
    private let queue = DispatchQueue(label: "com.avodroid.shared-folder")
    private let changed: @Sendable ([String]) -> Void

    init?(path: String, latency: CFTimeInterval, changed: @escaping @Sendable ([String]) -> Void) {
        root = path
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let names = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            var folders: [String] = []
            for index in 0..<min(count, names.count) {
                let flag = flags[index]
                // Events were dropped, or the folder itself moved: look at all of it.
                if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0 {
                    folders.append(watcher.root)
                }
                folders.append(names[index])
            }
            watcher.changed(folders)
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            // No callback still runs with this object.
            queue.sync {}
        }
    }
}

// MARK: - The daemon's side (Settings › Storage › Shared Folder)

/// Engines that can say whether this start's Android has the shared folder.
public protocol SharedFolderEngine: AnyObject, Sendable {
    func sharedFolderMount() async -> SharedFolderMount?
}

enum SharedFolderInspector {
    /// What Settings shows for `path` (nil: none chosen), as the daemon finds
    /// it: reading it is what makes macOS ask about a protected folder or a
    /// removable volume, in Avo's name.
    static func status(path: String?, enabled: Bool, paths: AvoPaths, dataFolder: URL?) -> SharedFolderStatus {
        guard let path, !path.isEmpty else { return SharedFolderStatus(path: nil, enabled: enabled) }
        let url = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        var status = SharedFolderStatus(path: url.path, enabled: enabled)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if !exists {
            if url.path.hasPrefix("/Volumes/"), StorageLocations.volumeSummary(for: url)?.mountPoint == "/" {
                status.problem = .volumeMissing(volume: StorageLocations.volumeName(fromPath: url.path), path: url.path)
            } else {
                status.problem = .folderMissing(path: url.path)
            }
            return status
        }
        guard isDirectory.boolValue else {
            status.problem = .notAFolder(path: url.path)
            return status
        }
        if let error = StorageLocations.accessError(url), error == EPERM || error == EACCES {
            status.problem = .notPermitted(path: url.path)
            return status
        }
        // Never Avo's own files or Android's data (the engine has them open as disks).
        let protected = [paths.applicationSupport, dataFolder].compactMap { $0?.standardizedFileURL.path }
        if protected.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") || $0.hasPrefix(url.path + "/") }) {
            status.problem = .avoData(path: url.path)
        }
        status.volume = StorageLocations.volumeSummary(for: url)
        return status
    }
}

extension DaemonCore {
    /// Settings › Storage › Shared Folder: the chosen folder and what Android does with it.
    func sharedFolderStatus() async -> SharedFolderStatus {
        let location = await storage.status()
        var status = SharedFolderInspector.status(path: config.sharedFolderPath, enabled: config.shareFolder, paths: dependencies.paths,
                                                  dataFolder: location.problem == nil ? URL(filePath: location.path) : nil)
        if await vm.status.state == .running {
            status.mount = await (dependencies.engine as? any SharedFolderEngine)?.sharedFolderMount()
        }
        return status
    }

    /// A folder the user chose to share (Control Panel only): what Avo finds there.
    public func inspectSharedFolder(_ path: String, client: ClientID) async throws -> SharedFolderStatus {
        guard role(of: client) == .controlPanel else { throw AvoError.unauthorizedCaller }
        let location = await storage.status()
        return SharedFolderInspector.status(path: path, enabled: true, paths: dependencies.paths,
                                            dataFolder: location.problem == nil ? URL(filePath: location.path) : nil)
    }
}
