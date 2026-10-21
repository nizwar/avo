import AvoKit
@preconcurrency import DiskArbitration
import Foundation
import os

/// What happens to volumes while Android's data may be on one.
public enum VolumeEvent: Sendable, Equatable {
    /// Someone asked to unmount or eject the volume at `mountPoint`, and it
    /// was refused while Android uses it (the daemon stops Android).
    case unmountRefused(mountPoint: String)
    /// The volume went without asking (unplugged, forced unmount).
    case disappeared(mountPoint: String)
    /// A volume appeared, was mounted or unmounted.
    case changed
}

/// Watches unmounts and ejects (DiskArbitration in the daemon, nothing in tests).
public protocol VolumeWatching: Sendable {
    /// `refusal` is asked synchronously when an unmount of `mountPoint` is
    /// requested: a message refuses it (macOS shows it to whoever asked).
    func start(refusal: @escaping @Sendable (_ mountPoint: String) -> String?,
               events: @escaping @Sendable (VolumeEvent) -> Void)
}

/// Which volumes must not go now, and why: read on DiskArbitration's queue
/// while an unmount waits for an answer, so it is plain locked state.
public final class VolumeGuard: Sendable {
    public enum Reason: Sendable, Equatable {
        /// Android has its disks open there.
        case android
        /// Avo copies Android's data to or from it.
        case moving
    }

    private struct State {
        var dataVolume: (mountPoint: String, name: String)?
        var androidActive = false
        var moving: Set<String> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    func setDataVolume(mountPoint: String?, name: String?) {
        state.withLock { $0.dataVolume = mountPoint.map { ($0, name ?? $0) } }
    }

    func setAndroidActive(_ active: Bool) {
        state.withLock { $0.androidActive = active }
    }

    func setMoving(_ mountPoints: Set<String>) {
        state.withLock { $0.moving = mountPoints }
    }

    /// The volume Android's data is on (not the Mac's own disk), and its name.
    var dataVolume: (mountPoint: String, name: String)? { state.withLock { $0.dataVolume } }

    public func reason(for mountPoint: String) -> Reason? {
        let path = Self.normalized(mountPoint)
        return state.withLock { state in
            if state.moving.contains(path) { return .moving }
            if state.androidActive, let volume = state.dataVolume, Self.normalized(volume.mountPoint) == path { return .android }
            return nil
        }
    }

    /// What macOS shows to whoever asked for the unmount.
    public func refusal(for mountPoint: String) -> String? {
        switch reason(for: mountPoint) {
        case .android?:
            String(localized: "Android keeps its storage on this disk. Avo is stopping Android; eject the disk again in a moment.", bundle: .avoKit)
        case .moving?:
            String(localized: "Avo is copying Android’s data on this disk. Eject it when the copy is done.", bundle: .avoKit)
        case nil:
            nil
        }
    }

    static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// DiskArbitration: refuses an unmount of a guarded volume until Android
/// stopped (the user ejects again), and says when volumes come and go.
public final class DiskArbitrationWatcher: VolumeWatching, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.avo.daemon.volumes")
    private var session: DASession?
    private var refusal: (@Sendable (String) -> String?)?
    private var events: (@Sendable (VolumeEvent) -> Void)?
    /// Mount points by BSD name (a disk that disappeared no longer says).
    private var mounts: [String: String] = [:]
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Volumes")

    public init() {}

    public func start(refusal: @escaping @Sendable (String) -> String?, events: @escaping @Sendable (VolumeEvent) -> Void) {
        queue.async { [self] in
            guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
            self.refusal = refusal
            self.events = events
            self.session = session
            // The watcher lives as long as the daemon.
            let context = Unmanaged.passUnretained(self).toOpaque()
            DARegisterDiskAppearedCallback(session, nil, { disk, context in
                DiskArbitrationWatcher.from(context).appeared(disk)
            }, context)
            DARegisterDiskDisappearedCallback(session, nil, { disk, context in
                DiskArbitrationWatcher.from(context).disappeared(disk)
            }, context)
            DARegisterDiskDescriptionChangedCallback(session, nil, kDADiskDescriptionWatchVolumePath.takeUnretainedValue(), { disk, _, context in
                DiskArbitrationWatcher.from(context).changed(disk)
            }, context)
            DARegisterDiskUnmountApprovalCallback(session, nil, { disk, context in
                DiskArbitrationWatcher.from(context).approveUnmount(disk)
            }, context)
            DASessionSetDispatchQueue(session, queue)
        }
    }

    private static func from(_ context: UnsafeMutableRawPointer?) -> DiskArbitrationWatcher {
        Unmanaged<DiskArbitrationWatcher>.fromOpaque(context!).takeUnretainedValue()
    }

    private static func info(_ disk: DADisk) -> (bsd: String?, mountPoint: String?) {
        let bsd = DADiskGetBSDName(disk).map { String(cString: $0) }
        let description = DADiskCopyDescription(disk) as? [String: Any]
        let url = description?[kDADiskDescriptionVolumePathKey as String] as? URL
        return (bsd, url.map { DataCopierPath.mountPoint($0) })
    }

    private func appeared(_ disk: DADisk) {
        let (bsd, mountPoint) = Self.info(disk)
        // A BSD name comes back for another disk (a disk image) once its own
        // is gone: it never keeps the old disk's mount point.
        if let bsd { mounts[bsd] = mountPoint }
        events?(.changed)
    }

    private func changed(_ disk: DADisk) {
        let (bsd, mountPoint) = Self.info(disk)
        if let bsd {
            if let mountPoint {
                mounts[bsd] = mountPoint
            } else if let old = mounts.removeValue(forKey: bsd) {
                // Unmounted (a forced unmount asks nobody).
                if refusal?(old) != nil { confirmGone(old) }
            }
        }
        events?(.changed)
    }

    private func disappeared(_ disk: DADisk) {
        let (bsd, mountPoint) = Self.info(disk)
        let known = bsd.flatMap { mounts.removeValue(forKey: $0) }
        if let point = mountPoint ?? known, refusal?(point) != nil { confirmGone(point) }
        events?(.changed)
    }

    /// Stops Android only once its volume is really gone: a disk that
    /// disappears under a name or path Avo last saw for it is not proof
    /// (building a disk image once stopped Android while its drive stayed
    /// mounted). Still mounted, it is checked once more a second later, when
    /// a forced unmount has had its time.
    private func confirmGone(_ point: String, again: Bool = true) {
        if Self.isMounted(point) {
            guard again else { return }
            queue.asyncAfter(deadline: .now() + 1) { [self] in confirmGone(point, again: false) }
            return
        }
        logger.error("the volume at \(point, privacy: .public) went away while Android used it")
        events?(.disappeared(mountPoint: point))
    }

    /// A volume is mounted at `path` (not a folder of another volume).
    static func isMounted(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: &info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return VolumeGuard.normalized(mountedOn) == VolumeGuard.normalized(path)
    }

    private func approveUnmount(_ disk: DADisk) -> Unmanaged<DADissenter>? {
        guard let point = Self.info(disk).mountPoint, let message = refusal?(point) else { return nil }
        logger.notice("refused unmounting \(point, privacy: .public) while Android uses it")
        events?(.unmountRefused(mountPoint: point))
        return Unmanaged.passRetained(DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnBusy), message as CFString))
    }
}

enum DataCopierPath {
    /// A volume URL's path as `statfs` names mount points (no trailing slash).
    static func mountPoint(_ url: URL) -> String {
        VolumeGuard.normalized(url.standardizedFileURL.path)
    }
}
