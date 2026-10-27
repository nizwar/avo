import AvoKit
import AvoPackages
import Foundation
import os

/// What Android reports about itself for a Google apps package.
public struct SystemFacts: Sendable, Equatable {
    /// `ro.build.version.sdk`.
    public var sdk: Int
    /// `ro.bionic.arch` (`arm64`), what MindTheGapps' build.prop names.
    public var arch: String
    /// `ro.build.product` (MindTheGapps treats `tangorpro` differently).
    public var product: String

    public init(sdk: Int, arch: String, product: String) {
        self.sdk = sdk
        self.arch = arch
        self.product = product
    }
}

public enum RemountResult: Sendable, Equatable {
    /// /product and /system_ext take writes now.
    case writable
    /// `remount` set up the overlay and asks for a reboot first.
    case needsRestart
}

/// How far the last commit got, from its manifest (`GoogleAppsCommit.manifest`).
public enum CommitState: Sendable, Equatable {
    /// No manifest: nothing was copied in, or it was taken out again.
    case none
    /// Copying started and did not finish.
    case partial
    /// Every file is in.
    case complete
}

/// The guest's side of adding Google apps to the system partitions
/// (`HostAgent` on Cuttlefish userdebug builds, as root through su).
public protocol SystemAppsGuest: Sendable {
    func systemFacts() async throws -> SystemFacts
    /// `avbctl get-verity`.
    func verityEnabled() async throws -> Bool
    /// `avbctl disable-verity`; applies after the VM restarts.
    func disableVerity() async throws
    /// `remount`. `afterRestart`: the reboot it asked for has happened, so
    /// only whether the partitions take writes counts.
    func remount(afterRestart: Bool) async throws -> RemountResult
    /// Free bytes of the file system holding `path` (`df`), when known.
    func freeBytes(_ path: String) async -> UInt64?
    /// Pushes the files to a staging folder; `progress` gets bytes sent.
    func stage(_ files: [GoogleAppsPackage.File], of package: GoogleAppsPackage,
               progress: @escaping @Sendable (UInt64) -> Void) async throws
    /// Copies the staged files (`paths`, as in `GoogleAppsPackage.File.path`)
    /// into /product and /system_ext as root with `GoogleAppsCommit.script`
    /// and removes the staging folder.
    func commitStaged(_ paths: [String]) async throws
    /// How far the last commit got.
    func commitState() async throws -> CommitState
    /// Stops a commit that is still running and removes what it added
    /// (`GoogleAppsCommit.rollbackScript`).
    func rollBackCommit() async throws
    /// Every package Android has (`pm list packages`).
    func packageNames() async throws -> Set<String>
    /// The system apps among them (`pm list packages -s`), updated ones included.
    func systemPackageNames() async throws -> Set<String>
    /// `pm uninstall`: the app and its data, for every user.
    func uninstallPackage(_ package: String) async throws
    func googleAppsStatus() async -> GoogleAppsStatus
}

/// What Google apps are doing to Android (the menu bar says it).
public enum GoogleAppsWork: Sendable, Equatable {
    case installing
    case removing
}

/// An engine whose Android can take Google apps into its system partitions.
public protocol SystemAppsEngine: VMEngine {
    /// The running guest; throws while Android is not ready.
    func systemApps() async throws -> any SystemAppsGuest
}

/// Why an install ended once Android's system partitions had changed.
enum GoogleAppsInstallError: Error, Equatable, LocalizedError {
    /// What the commit added was taken out again after `reason`.
    case restored(reason: String)
    /// Taking it out failed too (`detail`); Avo tries again at the next start.
    case notRestored(reason: String, detail: String)
    /// Android was stopped by force while it was being changed: the next
    /// start finishes the install or takes it out (`GoogleAppsJournal`).
    case interrupted
    /// Android was stopped by force before the commit: nothing to finish
    /// or undo (verified boot may be off already).
    case stoppedBeforeCommit
    /// After an interrupted install: it never got to copy anything.
    case untouched

    var errorDescription: String? {
        switch self {
        case .restored(let reason):
            String(localized: "Google apps were not installed; Android was restored. \(reason)", bundle: .avoKit)
        case let .notRestored(reason, detail):
            String(localized: "Google apps were not installed, and Avo could not restore Android yet (\(detail)). Avo tries again the next time Android starts. \(reason)",
                   bundle: .avoKit)
        case .interrupted:
            String(localized: "Android was stopped while Google apps were being installed. Avo finishes or undoes the install the next time Android starts.",
                   bundle: .avoKit)
        case .stoppedBeforeCommit:
            String(localized: "Google apps were not installed: Android was stopped during the install.", bundle: .avoKit)
        case .untouched:
            String(localized: "Google apps were not installed; Android was not changed.", bundle: .avoKit)
        }
    }
}

/// Why Remove ended before Google apps were gone.
enum GoogleAppsRemovalError: Error, Equatable, LocalizedError {
    /// Android was stopped by force while the files came out: the next
    /// start finishes (`GoogleAppsJournal.systemPackages`).
    case interrupted
    /// Taking the files out failed (`detail`); the next start tries again.
    case notRemoved(detail: String)
    /// Android still lists Google Play: files Avo has no list of (another
    /// installer, or an Avo from before the list).
    case stillListed

    var errorDescription: String? {
        switch self {
        case .interrupted:
            String(localized: "Android was stopped while Google apps were being removed. Avo finishes removing them the next time Android starts.",
                   bundle: .avoKit)
        case .notRemoved(let detail):
            String(localized: "Google apps could not be removed yet (\(detail)). Avo tries again the next time Android starts.", bundle: .avoKit)
        case .stillListed:
            String(localized: "Android still lists Google Play: these Google apps were not installed by this Avo, so it has no list of their files. Reset Android to remove them.",
                   bundle: .avoKit)
        }
    }
}

/// Installs a MindTheGapps package (spec: Strategi GMS, "Bring your own
/// GApps"): checks it against Android, turns off dm-verity and restarts when
/// needed, remounts the system partitions through overlayfs, copies the
/// files in, restarts and checks that Google Play is there. A commit that
/// fails, or a boot after it that never gets ready or lacks Google Play, is
/// taken out again (over adbd when Android does not finish booting) and
/// Android restarts as it was.
struct GoogleAppsInstaller: Sendable {
    typealias Report = @Sendable (GoogleAppsProgress) -> Void

    /// How long each step may take, so a guest that stops answering cannot
    /// keep Android's controls locked.
    struct Limits: Sendable {
        /// A guest command: facts, verity, remount, free space, package list.
        var command: Duration = .seconds(120)
        /// Pushing the files: this long without a byte sent.
        var transferStall: Duration = .seconds(120)
        var commit: Duration = .seconds(20 * 60)
        /// Starting, or stopping and starting, Android.
        var restart: Duration = .seconds(10 * 60)
        var rollBack: Duration = .seconds(5 * 60)
        /// Between tries of a check that may fail while Android settles.
        var retry: Duration = .seconds(5)
    }

    let id: UUID
    let ensureRunning: @Sendable () async throws -> Void
    /// Stops and starts the VM, returning once Android is ready again.
    let restart: @Sendable () async throws -> Void
    let guest: @Sendable () async throws -> any SystemAppsGuest
    let report: Report
    /// Runs `GoogleAppsCommit.rollbackScript` over a fresh adbd connection,
    /// for an Android that never finished booting (`vmNotRunning` when the
    /// engine itself is not running).
    var rescue: @Sendable () async throws -> Void = { throw AvoError.guestUnavailable }
    /// Right before the commit (the daemon writes `GoogleAppsJournal`).
    var committing: @Sendable () async -> Void = {}
    /// Android booted with every file in and lists Google Play.
    var committed: @Sendable () async -> Void = {}
    /// Android is as it was before the commit again.
    var restored: @Sendable () async -> Void = {}
    /// Right before Remove takes files out, with Android's system packages
    /// then (the daemon writes `GoogleAppsJournal`).
    var removing: @Sendable (Set<String>) async -> Void = { _ in }
    /// Remove finished: Android lists no Google Play.
    var removed: @Sendable () async -> Void = {}
    /// Android was stopped by force meanwhile: nothing restarts it, and the
    /// next start sees the install through.
    var interrupted: @Sendable () async -> Bool = { false }
    var limits = Limits()

    /// Room left over on each file system, like MindTheGapps' STORAGE_BUFFER.
    static let spareBytes: UInt64 = 10 << 20

    func run(_ package: GoogleAppsPackage) async throws {
        let agent: any SystemAppsGuest
        let files: [GoogleAppsPackage.File]
        do {
            (agent, files) = try await prepare(package)
        } catch {
            // A forced stop shows up as whatever step it cut short (a guest
            // command, the push): say what happened instead. No journal yet.
            guard await interrupted() else { throw error }
            throw GoogleAppsInstallError.stoppedBeforeCommit
        }

        // From here on a failure takes out what went in.
        report(GoogleAppsProgress(id: id, phase: .installing))
        await committing()
        do {
            try await within(limits.commit, String(localized: "Copying into the system partitions", bundle: .avoKit)) { [agent] in
                try await agent.commitStaged(files.map(\.path))
            }
        } catch {
            try await restore(after: .committing, error)
        }
        report(GoogleAppsProgress(id: id, phase: .restarting,
                                  message: String(localized: "Android restarts with Google apps.", bundle: .avoKit)))
        do {
            try await restartAndroid()
        } catch {
            try await restore(after: .booting, error)
        }
        do {
            try await verify()
        } catch {
            try await restore(after: .verifying, error)
        }
        await committed()
    }

    /// Everything before the commit: checks, verified boot, remount and the
    /// push. Android's system partitions are not changed yet.
    private func prepare(_ package: GoogleAppsPackage) async throws -> (any SystemAppsGuest, [GoogleAppsPackage.File]) {
        report(GoogleAppsProgress(id: id, phase: .startingVM))
        try await within(limits.restart, String(localized: "Starting Android", bundle: .avoKit)) { try await ensureRunning() }
        var agent = try await guest()
        // A second commit over a finished one could not be undone: it
        // overwrites files in place, and a rollback of it would take out the
        // first install too.
        if try await command({ [agent] in try await agent.commitState() }) == .complete {
            throw AvoError.internalError(Self.alreadyInstalled)
        }
        let facts = try await command { [agent] in try await agent.systemFacts() }
        let files: [GoogleAppsPackage.File]
        do {
            files = try package.plan(sdk: facts.sdk, arch: facts.arch, product: facts.product)
        } catch let error as GoogleAppsError {
            throw AvoError.unsupportedPackage(error.localizedDescription)
        }
        if let unsafe = files.first(where: { !GoogleAppsCommit.isSafe($0.path) }) {
            throw AvoError.unsupportedPackage(GoogleAppsError.unsafePath(unsafe.path).localizedDescription)
        }
        let total = files.reduce(UInt64(0)) { $0 + $1.size }

        if try await command({ [agent] in try await agent.verityEnabled() }) {
            try await checkpoint()
            report(GoogleAppsProgress(id: id, phase: .disablingVerity))
            try await command { [agent] in try await agent.disableVerity() }
            report(GoogleAppsProgress(id: id, phase: .restarting,
                                      message: String(localized: "Android restarts with verified boot off.", bundle: .avoKit)))
            try await restartAndroid()
            agent = try await guest()
        }

        try await checkpoint()
        report(GoogleAppsProgress(id: id, phase: .remounting))
        if try await command({ [agent] in try await agent.remount(afterRestart: false) }) == .needsRestart {
            report(GoogleAppsProgress(id: id, phase: .restarting,
                                      message: String(localized: "Android restarts to make its system partitions writable.", bundle: .avoKit)))
            try await restartAndroid()
            agent = try await guest()
            report(GoogleAppsProgress(id: id, phase: .remounting))
            guard try await command({ [agent] in try await agent.remount(afterRestart: true) }) == .writable else {
                throw AvoError.installFailed(String(localized: "Android’s system partitions stayed read-only", bundle: .avoKit))
            }
        }
        for path in ["/product", "/data"] {
            if let free = (try? await command({ [agent] in await agent.freeBytes(path) })) ?? nil, free < total + Self.spareBytes {
                throw AvoError.installFailed(String(localized: "Android needs \(Self.format(total + Self.spareBytes)) free in \(path) but has \(Self.format(free)).",
                                                    bundle: .avoKit))
            }
        }

        try await checkpoint()
        report(GoogleAppsProgress(id: id, phase: .transferring, fraction: 0))
        let heartbeat = Heartbeat()
        try await within(limits.transferStall, String(localized: "Copying Google apps to Android", bundle: .avoKit), heartbeat: heartbeat) { [agent] in
            try await agent.stage(files, of: package) { sent in
                heartbeat.beat()
                report(GoogleAppsProgress(id: id, phase: .transferring, fraction: total == 0 ? 1 : Double(sent) / Double(total)))
            }
        }
        try await checkpoint()
        return (agent, files)
    }

    static var alreadyInstalled: String {
        String(localized: "Google apps are already installed. To install another package, reset Android first.", bundle: .avoKit)
    }

    /// Google apps of another Android version are on Android's storage (`GoogleAppsRecord`).
    static func leftOver(_ android: AndroidRelease?) -> String {
        if let android {
            return String(localized: "Google apps for \(android.name) are still on Android’s storage. Reset Android first, then install Google apps for the Android that runs now.",
                          bundle: .avoKit)
        }
        return String(localized: "Google apps from an earlier install are still on Android’s storage. Reset Android first, then install them again.",
                      bundle: .avoKit)
    }

    /// An install the daemon did not see to its end (it quit, or Android was
    /// stopped by force, during the commit or the boot after it): starts
    /// Android and keeps a complete commit Android lists Google Play for, or
    /// takes out what went in. Throws `untouched` when nothing was copied.
    func recover() async throws {
        report(GoogleAppsProgress(id: id, phase: .startingVM))
        do {
            try await within(limits.restart, String(localized: "Starting Android", bundle: .avoKit)) { try await ensureRunning() }
        } catch {
            try await restore(after: .booting, error)
        }
        let decision: GoogleAppsRecovery.Decision
        do {
            let agent = try await guest()
            report(GoogleAppsProgress(id: id, phase: .checking))
            let state = try await command { try await agent.commitState() }
            let listed = state == .none ? false : Self.listsGooglePlay(try await command { try await agent.packageNames() })
            decision = GoogleAppsRecovery.decide(commit: state, listed: listed)
        } catch {
            try await restore(after: .verifying, error)
        }
        switch decision {
        case .keep:
            await committed()
        case .nothingToUndo:
            await restored()
            throw GoogleAppsInstallError.untouched
        case .rollBack:
            try await restore(after: .verifying, AvoError.installFailed(String(localized: "the install did not finish", bundle: .avoKit)))
        }
    }

    // MARK: Remove

    /// Remove (Settings › Google Apps): takes out every file the install
    /// added, as a failed install's are, and restarts Android, which drops
    /// those system apps with their data. Google Play's updates of them
    /// outlive them as ordinary apps that keep the old data and can't sign
    /// in, so those are uninstalled too (`uninstallLeftovers`). Other apps
    /// and their data stay. When the files are gone already (only the
    /// updates are left), only the updates go.
    func remove() async throws {
        do {
            report(removal(.startingVM))
            try await within(limits.restart, String(localized: "Starting Android", bundle: .avoKit)) { try await ensureRunning() }
            let agent = try await guest()
            report(removal(.removing, fraction: 0))
            let state = try await command { try await agent.commitState() }
            let system = try await command { try await agent.systemPackageNames() }
            if state != .none {
                try await checkpoint()
                await removing(system)
                try await takeOutFiles()
            }
            try await uninstallLeftovers(system)
        } catch {
            throw await removalError(error)
        }
    }

    /// A Remove the daemon did not see to its end (`GoogleAppsJournal`):
    /// finishes it before Android is used. `systemBefore`: Android's system
    /// packages when it began.
    func finishRemoval(_ systemBefore: Set<String>) async throws {
        do {
            report(removal(.startingVM))
            do {
                try await within(limits.restart, String(localized: "Starting Android", bundle: .avoKit)) { try await ensureRunning() }
            } catch where !(error is GoogleAppsInstallError) {
                // Android never got ready: out over adbd, then a fresh start.
                try await takeOutFiles()
            }
            let agent = try await guest()
            report(removal(.removing, fraction: 0))
            if try await command({ try await agent.commitState() }) != .none { try await takeOutFiles() }
            try await uninstallLeftovers(systemBefore)
        } catch {
            throw await removalError(error)
        }
    }

    /// The install's files out (through the running guest, else over adbd),
    /// then a restart so Android drops them.
    private func takeOutFiles() async throws {
        do {
            if !(await rollBackInGuest()) {
                do {
                    try await within(limits.rollBack, String(localized: "Removing Google apps", bundle: .avoKit)) { try await rescue() }
                } catch AvoError.vmNotRunning {
                    try await checkpoint()
                    try? await restartAndroid()
                    try await within(limits.rollBack, String(localized: "Removing Google apps", bundle: .avoKit)) { try await rescue() }
                }
            }
        } catch GoogleAppsInstallError.interrupted {
            throw GoogleAppsInstallError.interrupted
        } catch {
            throw GoogleAppsRemovalError.notRemoved(detail: Self.describe(error))
        }
        report(removal(.restarting, message: String(localized: "Android restarts without Google apps.", bundle: .avoKit)))
        try await restartAndroid()
    }

    /// Uninstalls what Google Play's updates left of the removed system apps
    /// (system apps before, ordinary ones now; the core ones in any case),
    /// then checks that Android lists no Google Play.
    private func uninstallLeftovers(_ systemBefore: Set<String>) async throws {
        let agent = try await guest()
        report(removal(.removing, fraction: 1))
        let all = try await settledPackages { try await agent.packageNames() }
        let system = try await command { try await agent.systemPackageNames() }
        for package in all.subtracting(system).intersection(systemBefore.union(GoogleApps.corePackages)).sorted() {
            try await checkpoint()
            try await command { try await agent.uninstallPackage(package) }
        }
        let left = try await command { try await agent.packageNames() }
        guard !left.contains(GoogleApps.playServices), !left.contains(GoogleApps.playStore) else {
            throw GoogleAppsRemovalError.stillListed
        }
        await removed()
    }

    private func removal(_ phase: GoogleAppsProgress.Phase, fraction: Double? = nil, message: String? = nil) -> GoogleAppsProgress {
        GoogleAppsProgress(id: id, phase: phase, fraction: fraction, message: message, removal: true)
    }

    /// A forced stop shows up as whatever step it cut short: say that instead.
    private func removalError(_ error: any Error) async -> any Error {
        if error as? GoogleAppsInstallError == .interrupted { return GoogleAppsRemovalError.interrupted }
        if !(error is GoogleAppsRemovalError), await interrupted() { return GoogleAppsRemovalError.interrupted }
        return error
    }

    // MARK: Checks

    /// `pm` can fail right after boot: three tries.
    private func settledPackages(_ read: @escaping @Sendable () async throws -> Set<String>) async throws -> Set<String> {
        var attempt = 1
        while true {
            do {
                return try await command(read)
            } catch where attempt < 3 && !(error is CancellationError) {
                attempt += 1
                try await Task.sleep(for: limits.retry)
            }
        }
    }

    private func verify() async throws {
        let agent = try await guest()
        report(GoogleAppsProgress(id: id, phase: .checking))
        // Only a list without Google Play (or pm failing for good) takes the
        // install out again.
        let packages = try await settledPackages { try await agent.packageNames() }
        guard Self.listsGooglePlay(packages) else {
            throw AvoError.installFailed(String(localized: "the files were copied, but Android does not list Google Play services and the Play Store.",
                                                bundle: .avoKit))
        }
    }

    static func listsGooglePlay(_ packages: Set<String>) -> Bool {
        packages.contains(GoogleApps.playServices) && packages.contains(GoogleApps.playStore)
    }

    /// Takes out what the commit added: through the running guest, else
    /// over adbd (Android loops before it is ready), starting the engine
    /// first when it is not running; then Android restarts when it has
    /// loaded the files (`GoogleAppsRecovery.restartsAndroid`).
    private func restore(after stage: GoogleAppsRecovery.Stage, _ error: any Error) async throws -> Never {
        let reason = Self.sentence(Self.describe(error))
        guard !(await interrupted()) else { throw GoogleAppsInstallError.interrupted }
        report(GoogleAppsProgress(id: id, phase: .restoring))
        do {
            let rescued = !(await rollBackInGuest())
            if rescued {
                do {
                    try await within(limits.rollBack, String(localized: "Restoring Android", bundle: .avoKit)) { try await rescue() }
                } catch AvoError.vmNotRunning {
                    // The engine is gone: start it (Android may never get
                    // ready, but adbd comes up), then try again.
                    try await checkpoint()
                    try? await restartAndroid()
                    try await within(limits.rollBack, String(localized: "Restoring Android", bundle: .avoKit)) { try await rescue() }
                }
            }
            if GoogleAppsRecovery.restartsAndroid(after: stage, rescued: rescued) {
                try await checkpoint()
                try await restartAndroid()
            }
        } catch GoogleAppsInstallError.interrupted {
            throw GoogleAppsInstallError.interrupted
        } catch {
            throw GoogleAppsInstallError.notRestored(reason: reason, detail: Self.describe(error))
        }
        await restored()
        throw GoogleAppsInstallError.restored(reason: reason)
    }

    /// Through the running guest; false when it is not ready or that failed.
    private func rollBackInGuest() async -> Bool {
        guard let agent = try? await guest() else { return false }
        do {
            try await within(limits.rollBack, String(localized: "Restoring Android", bundle: .avoKit)) { try await agent.rollBackCommit() }
            return true
        } catch {
            return false
        }
    }

    private func restartAndroid() async throws {
        try await checkpoint()
        try await within(limits.restart, String(localized: "Restarting Android", bundle: .avoKit)) { try await restart() }
    }

    private func checkpoint() async throws {
        if await interrupted() { throw GoogleAppsInstallError.interrupted }
    }

    private func command<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await within(limits.command, String(localized: "Android’s answer", bundle: .avoKit), operation)
    }

    private func within<T: Sendable>(_ limit: Duration, _ what: String, heartbeat: Heartbeat? = nil,
                                     _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Deadline.run(limit, what: what, heartbeat: heartbeat, operation)
    }

    /// Why a step failed. Without "Installation failed:", which the restore
    /// messages already say in their own words.
    static func describe(_ error: any Error) -> String {
        if error is CancellationError { return String(localized: "Android was stopped.", bundle: .avoKit) }
        if case AvoError.installFailed(let detail) = error { return detail }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// `the install did not finish` → `The install did not finish.`, to
    /// follow the restore message's own sentence.
    static func sentence(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first else { return text }
        let capitalized = first.uppercased() + text.dropFirst()
        return capitalized.last.map { ".!?…)".contains($0) } == true ? capitalized : capitalized + "."
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

/// What to do about a commit that did not end well.
enum GoogleAppsRecovery {
    /// Where the install was when it failed, once the commit had begun.
    enum Stage: Sendable, Equatable {
        /// Copying in (Android runs without having loaded anything new).
        case committing
        /// The restart with Google apps.
        case booting
        /// Android booted with them, but does not list Google Play.
        case verifying
    }

    enum Decision: Sendable, Equatable {
        /// Every file is in and Android lists Google Play: the install stands.
        case keep
        /// Copying never began.
        case nothingToUndo
        case rollBack
    }

    /// After taking the files out: Android restarts unless only a commit
    /// failed while the same boot keeps running (it loaded none of them).
    /// Over adbd, Android was not ready, so it always restarts.
    static func restartsAndroid(after stage: Stage, rescued: Bool) -> Bool {
        rescued || stage != .committing
    }

    /// An install the daemon did not see to its end, at the next start.
    static func decide(commit: CommitState, listed: Bool) -> Decision {
        switch commit {
        case .none: .nothingToUndo
        case .partial: .rollBack
        case .complete: listed ? .keep : .rollBack
        }
    }
}

/// Stopping, restarting, resetting or snapshotting Android while Google
/// apps install: while the install only downloads or reads the package it
/// goes on (a reset stops it first); once it changes Android these wait,
/// unless the user insisted (`force`, the menu bar's "Stop Anyway").
enum GoogleAppsGuard {
    enum Action: Sendable, Equatable { case stop, restart, reset, snapshot }

    enum Decision: Sendable, Equatable {
        case allow
        /// Stop the install, then go ahead.
        case cancelInstall
        case refuse
    }

    static func decide(_ action: Action, installing: Bool, cancellable: Bool, force: Bool) -> Decision {
        guard installing else { return .allow }
        if cancellable { return action == .reset ? .cancelInstall : .allow }
        return force ? .allow : .refuse
    }

    static var refusal: String {
        String(localized: "Avo is changing Google apps and restarts Android by itself meanwhile. Wait until it finishes.", bundle: .avoKit)
    }
}

/// A commit the daemon started and has not seen to its end
/// (`google-apps-commit.json`, next to Android's data disk): the next start
/// finishes or undoes it, also on another Mac. A Remove is noted the same
/// way, and the next start finishes it.
struct GoogleAppsJournal: Codable, Equatable, Sendable {
    var id: UUID
    var started: Date
    /// A Remove: Android's system packages when it began (nil for an install).
    var systemPackages: [String]?

    static func url(_ paths: AvoPaths) -> URL { paths.data.appending(path: "google-apps-commit.json") }

    static func load(_ paths: AvoPaths) -> GoogleAppsJournal? {
        guard let data = try? Data(contentsOf: url(paths)) else { return nil }
        return try? JSONDecoder().decode(GoogleAppsJournal.self, from: data)
    }

    func save(_ paths: AvoPaths) throws {
        try paths.ensureDataFolder()
        try JSONEncoder().encode(self).write(to: Self.url(paths), options: .atomic)
    }

    static func remove(_ paths: AvoPaths) {
        try? FileManager.default.removeItem(at: url(paths))
    }
}

/// The shell side of a commit, run as root in Android (and, in tests,
/// against a folder standing in for its partitions).
///
/// The commit first lists every path it may add (`manifest`, relative to
/// the partitions' root) and syncs, so whatever happens next can be taken
/// out. Then, safest first: permission allowlists, sysconfig and other
/// `etc` files (extra allowlist entries are harmless, missing ones stop
/// system_server while `ro.control_privapp_permissions=enforce`), then
/// libraries, frameworks and other files, then the app folders. Each file
/// and each new app folder is copied under `<partition>/.avo-new` and
/// renamed into place (new upper-only folders rename fine with
/// `redirect_dir=nofollow`), so nothing is ever half there. `#complete`
/// ends the manifest once everything is in.
enum GoogleAppsCommit {
    /// Where HostAgent pushes the package's files.
    static let staging = "/data/local/tmp/avo-gapps"
    /// Every path the commit added, then `completeMarker`.
    static let manifest = "product/etc/avo-gapps.files"
    static let completeMarker = "#complete"
    /// A rollback began: whatever the list says, it is not complete.
    static let rollbackMarker = "#rollback"
    static let partitions = ["product", "system_ext"]

    struct Layout: Sendable {
        /// Prefix of `/product` and `/system_ext` ("" in Android).
        var root = ""
        var staging = GoogleAppsCommit.staging
        /// Android: `remount`, and the overlay's upper folders when the
        /// partitions stay read-only (rollback).
        var android = true
        /// Where the overlays' upper folders are read from (a stand-in in tests).
        var mounts = "/proc/mounts"

        var script: String { staging + "-commit.sh" }
    }

    /// What is copied as one piece.
    enum Unit: Sendable, Equatable {
        case file(String)
        /// `product/priv-app/Phonesky`: copied whole when new.
        case folder(String)

        var path: String {
            switch self {
            case .file(let path), .folder(let path): path
            }
        }
    }

    /// The package's files as units, in commit order.
    static func units(_ paths: [String]) -> [Unit] {
        var seen = Set<String>()
        var units: [(rank: Int, unit: Unit)] = []
        for path in paths.sorted() {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { continue }
            let unit: Unit = parts[1] != "etc" && parts.count >= 4 ? .folder(parts[0..<3].joined(separator: "/")) : .file(path)
            guard seen.insert(unit.path).inserted else { continue }
            let rank = parts[1] == "etc" ? 0 : ["app", "priv-app"].contains(parts[1]) ? 2 : 1
            units.append((rank, unit))
        }
        return units.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element.unit)
    }

    /// The commit (HostAgent pushes it to `Layout.script` and runs it with sh).
    static func script(_ paths: [String], layout: Layout = Layout()) -> String {
        let files = paths.sorted()
        let units = units(files)
        var lines = [
            "S=\(quote(layout.staging))",
            "R=\(quote(layout.root))",
            "M=\"$R/\(manifest)\"",
            // Lists a path that is not there yet (the rollback removes it).
            #"n() { if [ ! -e "$R/$1" ]; then echo "$1" >> "$M"; fi; }"#,
            #"d() { if [ ! -d "$R/$1" ]; then mkdir -m 0755 "$R/$1"; restorecon "$R/$1"; fi; }"#,
            #"f() { w="$R/${1%%/*}/.avo-new"; mkdir -p "$w"; cp -p "$S/$1" "$w/f"; mv -f "$w/f" "$R/$1"; restorecon "$R/$1"; }"#,
            #"t() { w="$R/${1%%/*}/.avo-new"; mkdir -p "$w"; rm -rf "$w/t"; cp -R -p "$S/$1" "$w/t"; mv "$w/t" "$R/$1"; restorecon -R "$R/$1"; }"#,
            "( set -e",
            // What MindTheGapps' installer makes of each file.
            #"find "$S" -type d -exec chmod 0755 {} +"#,
            #"find "$S" -type f -exec chmod 0644 {} +"#,
            #"chown -R root:root "$S""#,
            // A finished install's list starts over; an unfinished one's
            // paths stay (without its markers), so a rollback still takes
            // its files out.
            #"if [ ! -f "$M" ] || { grep -qx '\#(completeMarker)' "$M" && ! grep -qx '\#(rollbackMarker)' "$M"; }; then : > "$M"; "#
                + #"else { grep -v '^#' "$M" || true; } > "$M.t"; mv -f "$M.t" "$M"; fi"#,
        ]
        var listed = Set<String>()
        func list(_ path: String) {
            if listed.insert(path).inserted { lines.append("n " + quote(path)) }
        }
        for unit in units {
            for folder in ancestors(of: unit.path) { list(folder) }
            list(unit.path)
            if case .folder(let folder) = unit {
                for file in files where file.hasPrefix(folder + "/") {
                    for inner in ancestors(of: file) where inner.count > folder.count { list(inner) }
                    list(file)
                }
            }
        }
        lines.append("sync")
        var made = Set<String>()
        for unit in units {
            for folder in ancestors(of: unit.path) where made.insert(folder).inserted { lines.append("d " + quote(folder)) }
            switch unit {
            case .file(let path):
                lines.append("f " + quote(path))
            case .folder(let folder):
                // Already there (an earlier install, or a folder Android has): file by file.
                var inner: [String] = []
                var innerFolders = Set<String>()
                for file in files where file.hasPrefix(folder + "/") {
                    for sub in ancestors(of: file) where sub.count > folder.count && innerFolders.insert(sub).inserted {
                        inner.append("d " + quote(sub))
                    }
                    inner.append("f " + quote(file))
                }
                lines.append("if [ -e \"$R/\"\(quote(folder)) ]; then \(inner.joined(separator: "; ")); else t \(quote(folder)); fi")
            }
        }
        lines += partitions.map { "rm -rf \"$R/\($0)/.avo-new\"" }
        lines += ["sync", "echo '\(completeMarker)' >> \"$M\"", "sync )", "s=$?", #"rm -rf "$S" "$S-commit.sh""#, "exit $s"]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Takes out what the last commit added: stops a commit still running,
    /// makes the partitions writable (or, when they stay read-only, works in
    /// the overlay's upper folders, which apply at the next boot), removes
    /// every listed path and the manifest. Exits 1 when something stayed,
    /// saying on stderr where it looked and what `remount` answered.
    ///
    /// The upper folders are read before `remount` as well as after it: with
    /// verified boot back on, `remount` turned it off and left the overlays
    /// out of /proc/mounts, so a Remove found nowhere to remove from (b79).
    static func rollbackScript(layout: Layout = Layout()) -> String {
        var lines = [
            "S=\(quote(layout.staging))",
            "R=\(quote(layout.root))",
            "M=\"$R/\(manifest)\"",
            // The commit's sh and its cp (their command lines name the
            // staging folder); the brackets keep this script's own off the list.
            "pkill -9 -f \(quote(killPattern(layout.staging + "-commit"))) && sleep 1",
            "pkill -9 -f \(quote(killPattern(layout.staging) + "/")) && sleep 1",
            #"rm -rf "$S" "$S-commit.sh""#,
            #"if [ ! -f "$M" ]; then exit 0; fi"#,
        ]
        func upperdir(_ partition: String) -> String {
            "$(sed -n 's|^overlay /\(partition) overlay .*upperdir=\\([^,]*\\).*|\\1|p' \(quote(layout.mounts)) | tail -n 1)"
        }
        if layout.android {
            for (partition, upper) in zip(partitions, ["UP", "US"]) { lines.append("\(upper)=\(upperdir(partition))") }
            lines.append("RO=$(remount 2>&1); RS=$?")
        }
        for (index, partition) in partitions.enumerated() {
            let base = ["BP", "BS"][index], upper = ["UP", "US"][index]
            lines.append("\(base)=")
            lines.append("if touch \"$R/\(partition)/.avo-probe\" 2>/dev/null; then rm -f \"$R/\(partition)/.avo-probe\"; \(base)=\"$R/\(partition)\"; fi")
            if layout.android {
                lines.append("if [ -z \"$\(base)\" ]; then \(base)=\(upperdir(partition)); fi")
                lines.append("if [ -z \"$\(base)\" ] && [ -d \"$\(upper)\" ]; then \(base)=$\(upper); fi")
            }
        }
        lines += [
            // Last in first out: app folders, then libraries, then the
            // allowlists, so a rollback cut short never leaves a priv-app
            // without its permissions. And `rollbackMarker` first, so that
            // list no longer reads as complete (the next start takes out
            // the rest).
            #"L="$S-rollback.list""#,
            #"sed '1!G;h;$!d' "$M" > "$L" || exit 1"#,
            #"if [ -n "$BP" ]; then echo '\#(rollbackMarker)' >> "$BP/etc/avo-gapps.files"; sync; fi"#,
            "status=0",
            #"while IFS= read -r p; do"#,
            #"  case "$p" in ''|'#'*|*..*) continue;; esac"#,
            #"  case "$p" in product/*) base=$BP; rest=${p#product/};; system_ext/*) base=$BS; rest=${p#system_ext/};; *) continue;; esac"#,
            #"  if [ -z "$base" ] || [ -z "$rest" ]; then status=1; continue; fi"#,
            #"  rm -rf "$base/$rest""#,
            #"  if [ -e "$base/$rest" ]; then status=1; fi"#,
            #"done < "$L""#,
            #"rm -f "$L""#,
            #"for base in "$BP" "$BS"; do if [ -n "$base" ]; then rm -rf "$base/.avo-new"; fi; done"#,
            #"if [ $status = 0 ] && [ -n "$BP" ]; then rm -f "$BP/etc/avo-gapps.files"; fi"#,
            layout.android
                ? #"if [ $status != 0 ]; then echo "files stayed in product (${BP:-not writable}) or system_ext (${BS:-not writable}); remount ($RS): $(printf '%s' "$RO" | tr '\n' ' ' | tail -c 300)" >&2; fi"#
                : #"if [ $status != 0 ]; then echo "files stayed in product (${BP:-not writable}) or system_ext (${BS:-not writable})" >&2; fi"#,
            "sync",
            "exit $status",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Prints `manifest` and the list when there is one (`state(fromOutput:)`).
    static func stateCommand(layout: Layout = Layout()) -> String {
        "M=\(quote(layout.root + "/" + manifest)); if [ -f \"$M\" ]; then echo manifest; cat \"$M\"; fi"
    }

    static func state(fromOutput output: String) -> CommitState {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "manifest" else { return .none }
        return lines.contains(completeMarker) && !lines.contains(rollbackMarker) ? .complete : .partial
    }

    /// `su 0 sh -c '<script>'`, for adbd's shell.
    static func rootCommand(_ script: String) -> String { "su 0 sh -c " + quote(script) }

    /// The folders between a partition and `path` (`product/etc`,
    /// `product/etc/permissions` for a file in it), outermost first.
    static func ancestors(of path: String) -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 2 else { return [] }
        return (2..<parts.count).map { parts[0..<$0].joined(separator: "/") }
    }

    /// File names MindTheGapps uses; anything else (quotes, newlines, `$`)
    /// would not survive the scripts or the line-per-path manifest.
    static func isSafe(_ path: String) -> Bool {
        !path.isEmpty && path.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-+@/".unicodeScalars.contains(scalar))
        }
    }

    /// `…/avo-gapps` → `…/avo-gapp[s]`: matches the path, not this text.
    static func killPattern(_ path: String) -> String {
        guard let last = path.last else { return path }
        return String(path.dropLast()) + "[\(last)]"
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// When a step last made progress (the push of the package's files).
final class Heartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var last = SuspendingClock.now

    func beat() { lock.withLock { last = .now } }
    var lastBeat: SuspendingClock.Instant { lock.withLock { last } }
}

/// Gives up on a step after a time limit (counted from the last heartbeat
/// when there is one). A step that ignores cancellation, such as a guest
/// command that never answers, is left behind instead of waited for. The
/// Mac asleep is no time the step had: Android stood still with it.
enum Deadline {
    static func run<T: Sendable>(_ limit: Duration, what: String, heartbeat: Heartbeat? = nil,
                                 _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                race.start(continuation)
                race.add(Task {
                    do {
                        race.finish(.success(try await operation()))
                    } catch {
                        race.finish(.failure(error))
                    }
                })
                race.add(Task {
                    let start = SuspendingClock.now
                    while !Task.isCancelled {
                        let from = heartbeat?.lastBeat ?? start
                        if SuspendingClock.now - from >= limit {
                            race.finish(.failure(AvoError.timedOut(what)))
                            return
                        }
                        try? await Task.sleep(for: min(limit, .seconds(1)), clock: .suspending)
                    }
                })
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    /// The first outcome wins; the other task is cancelled.
    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        private var tasks: [Task<Void, Never>] = []
        private var result: Result<T, any Error>?

        func start(_ continuation: CheckedContinuation<T, any Error>) {
            let early = lock.withLock { () -> Result<T, any Error>? in
                if result == nil { self.continuation = continuation }
                return result
            }
            if let early { continuation.resume(with: early) }
        }

        func add(_ task: Task<Void, Never>) {
            let done = lock.withLock { () -> Bool in
                if result == nil { tasks.append(task) }
                return result != nil
            }
            if done { task.cancel() }
        }

        func finish(_ outcome: Result<T, any Error>) {
            let (continuation, tasks) = lock.withLock { () -> (CheckedContinuation<T, any Error>?, [Task<Void, Never>]) in
                guard result == nil else { return (nil, []) }
                result = outcome
                defer {
                    self.continuation = nil
                    self.tasks = []
                }
                return (self.continuation, self.tasks)
            }
            for task in tasks { task.cancel() }
            continuation?.resume(with: outcome)
        }
    }
}

/// Google apps from GitHub (the build Settings › Google Apps lists, or a
/// link of the user's own): finds the release's .zip through the GitHub
/// API, downloads it into the cache and checks it against the SHA-256
/// GitHub computed for the asset (or the release's `.sha256sum` file).
struct GoogleAppsDownloader: Sendable {
    let directory: URL
    let session: URLSession
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "GoogleApps")

    init(directory: URL, session: URLSession = GoogleAppsDownloader.makeSession()) {
        self.directory = directory
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 2
        configuration.httpAdditionalHeaders = ["User-Agent": "Avo"]
        return URLSession(configuration: configuration)
    }

    /// Returns the verified .zip. `progress` gets bytes received and expected.
    func download(_ link: String, verifying: @Sendable () -> Void,
                  progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws -> URL {
        let (api, preferred) = try GitHubRelease.apiURL(for: link)
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await fetch(request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw GoogleAppsError.download(Self.describe(status: http.statusCode, url: link))
        }
        let release: GitHubRelease
        do {
            release = try GitHubRelease.parse(data)
        } catch {
            throw GoogleAppsError.download(String(localized: "GitHub’s answer was not a release.", bundle: .avoKit))
        }
        guard let asset = release.packageAsset(preferring: preferred) else {
            throw GoogleAppsError.noPackageInRelease(release.tagName)
        }
        let expected = try await expectedSHA256(asset, in: release)
        let name = asset.name.replacingOccurrences(of: "/", with: "-")
        let file = directory.appending(path: name.hasPrefix(".") ? "_" + name : name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // A previous attempt that downloaded it already (the install failed later).
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? UInt64, size == asset.size {
            verifying()
            if (try? Checksum.sha256(of: file)) == expected {
                logger.notice("reusing \(name, privacy: .public)")
                return file
            }
        }
        try? FileManager.default.removeItem(at: file)
        logger.notice("downloading \(asset.browserDownloadURL.absoluteString, privacy: .public)")
        try await transfer(asset.browserDownloadURL, to: file, expected: asset.size, progress: progress)
        verifying()
        let actual = try Checksum.sha256(of: file)
        guard actual == expected else {
            try? FileManager.default.removeItem(at: file)
            throw GoogleAppsError.checksumMismatch(asset.name)
        }
        return file
    }

    private func expectedSHA256(_ asset: GitHubRelease.Asset, in release: GitHubRelease) async throws -> String {
        if let sha = asset.sha256 { return sha }
        guard let sums = release.checksumAsset(for: asset) else { throw GoogleAppsError.noChecksum(asset.name) }
        let (data, response) = try await fetch(URLRequest(url: sums.browserDownloadURL))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let sha = Checksum.sha256(fromSumFile: String(decoding: data.prefix(64 << 10), as: UTF8.self), name: asset.name) else {
            throw GoogleAppsError.noChecksum(asset.name)
        }
        return sha
    }

    private func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw GoogleAppsError.download(error.localizedDescription)
        }
    }

    static func describe(status: Int, url: String) -> String {
        switch status {
        case 404: String(localized: "GitHub has no release at \(url).", bundle: .avoKit)
        case 403, 429: String(localized: "GitHub refused the request (too many requests from this network). Try again later.", bundle: .avoKit)
        default: String(localized: "GitHub answered with HTTP status \(status).", bundle: .avoKit)
        }
    }

    /// A download task, polled for progress; cancelled with the calling task.
    private func transfer(_ url: URL, to destination: URL, expected: UInt64,
                          progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws {
        let holder = TaskHolder()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let task = session.downloadTask(with: url) { location, response, error in
                    if let error {
                        let cancelled = (error as? URLError)?.code == .cancelled
                        continuation.resume(throwing: cancelled ? CancellationError() : GoogleAppsError.download(error.localizedDescription))
                        return
                    }
                    guard let http = response as? HTTPURLResponse, let location else {
                        continuation.resume(throwing: GoogleAppsError.download(String(localized: "no answer", bundle: .avoKit)))
                        return
                    }
                    guard http.statusCode == 200 else {
                        continuation.resume(throwing: GoogleAppsError.download(Self.describe(status: http.statusCode, url: url.absoluteString)))
                        return
                    }
                    // The file is gone once this handler returns: move it now.
                    do {
                        try FileManager.default.moveItem(at: location, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                holder.start(task)
                Task {
                    while task.state == .running || task.state == .suspended {
                        let total = task.countOfBytesExpectedToReceive > 0 ? UInt64(task.countOfBytesExpectedToReceive) : expected
                        progress(UInt64(max(task.countOfBytesReceived, 0)), total)
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
        } onCancel: {
            holder.cancel()
        }
    }

    /// The download task, cancellable before and after it starts.
    private final class TaskHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false

        func start(_ task: URLSessionTask) {
            let cancelled = lock.withLock {
                self.task = task
                return self.cancelled
            }
            task.resume()
            if cancelled { task.cancel() }
        }

        func cancel() {
            let task = lock.withLock {
                cancelled = true
                return self.task
            }
            task?.cancel()
        }
    }
}
