import AppKit
import AvoDaemonCore
import AvoKit
import os

/// Notices Avo.app being replaced under the running daemon. Sparkle installs
/// an update by swapping the bundle at the same path: this daemon's code
/// stays as it was, but whatever it reads from the bundle from then on (the
/// engine it launches, the shim template, the profiles) is the new build's.
/// So once Android holds nothing, at once or when it next stops, the daemon
/// exits with `AppUpdate.daemonRestartExitStatus` and launchd starts the new
/// build's daemon at the same path (KeepAlive). While Android runs it waits:
/// an update never takes Android away from the player. The menu bar item
/// offers to restart Android, and the new daemon starts it again.
@MainActor
final class AppUpdateWatcher {
    private let avoApp: URL
    private let core: DaemonCore
    private let logger: Logger
    /// The build this daemon started from (CFBundleVersion).
    private let launchBuild: String?
    private var source: (any DispatchSourceFileSystemObject)?
    private var timer: Timer?
    private var state = VMState.stopped
    /// Avo.app on disk is another build; this daemon restarts once Android stops.
    private(set) var updatePending = false
    /// Runs just before the daemon exits to restart on the new build (the menu bar item leaves first).
    var beforeExit: @MainActor () -> Void = {}
    /// The new daemon starts Android: the old one stopped it for the update.
    private static let startAfterRestartKey = "AvoStartAndroidAfterUpdate"

    init(avoApp: URL, core: DaemonCore, logger: Logger) {
        self.avoApp = avoApp
        self.core = core
        self.logger = logger
        launchBuild = Self.build(of: avoApp)
    }

    func start() {
        watch()
        // Anything the file system source misses is found within minutes.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        Task { @MainActor [weak self] in
            guard let core = self?.core else { return }
            for await status in await core.statusChanges() {
                guard let self else { return }
                self.state = status.state
                self.check()
            }
        }
    }

    /// The menu bar's Restart Android to Finish Updating: Android stops as
    /// with Stop Android, this daemon restarts on the new build, and that
    /// one starts Android again.
    func restartAndroid(force: Bool = false) async throws {
        UserDefaults.standard.set(true, forKey: Self.startAfterRestartKey)
        do {
            try await core.stopVMFromMenuBar(force: force)
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.startAfterRestartKey)
            throw error
        }
    }

    /// At the new daemon's start: whether the old one stopped Android for the update (asked once).
    static func takeStartRequest() -> Bool {
        defer { UserDefaults.standard.removeObject(forKey: startAfterRestartKey) }
        return UserDefaults.standard.bool(forKey: startAfterRestartKey)
    }

    private func watch() {
        let descriptor = open(avoApp.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.rename, .delete, .revoke, .write],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.bundleChanged() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    /// The bundle the descriptor was opened on moved or changed: look at
    /// the path again once the swap is done, and watch what is there now.
    private func bundleChanged() {
        source?.cancel()
        source = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                self?.watch()
                self?.check()
            }
        }
    }

    private func check() {
        let disk = Self.build(of: avoApp)
        let pending = disk != nil && disk != launchBuild
        if pending, !updatePending {
            logger.notice("Avo.app on disk is build \(disk ?? "?", privacy: .public); this daemon is \(self.launchBuild ?? "?", privacy: .public)")
        }
        updatePending = pending
        guard AppUpdate.daemonShouldRestart(launchBuild: launchBuild, diskBuild: disk, state: state) else { return }
        logger.notice("restarting on the updated Avo (build \(disk ?? "?", privacy: .public))")
        beforeExit()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(MenuBarController.removalGraceMilliseconds)) {
            exit(AppUpdate.daemonRestartExitStatus)
        }
    }

    nonisolated static func build(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))?["CFBundleVersion"] as? String
    }
}
