import AvoADB
import AvoIO
import AvoKit
import AvoPackages
import Foundation

/// Installs a package file from the Mac (spec §3): inspect it, boot Android if
/// needed, stream the selected APKs through `pm install-create/-write/-commit`
/// and copy XAPK OBB files to /sdcard/Android/obb/.
///
/// The game data (OBB) goes in after the app, as it always has: since
/// Android 11 an app's OBB folder is made the app's own from its package,
/// so one copied in before Android knows the package might be a folder the
/// game cannot read. A copy that fails undoes the install instead: the
/// files it wrote go, and so does the app when Android did not have it
/// before (an update keeps the app, and its data). When Android stops in
/// the middle, the next install or start does that (InstallJournal).
public struct InstallPipeline: Sendable {
    public typealias Report = @Sendable (InstallProgress) -> Void

    public init() {}

    /// Returns the installed package name. The registry and shortcuts update
    /// when the Bridge Agent reports PACKAGE_ADDED. `journal` keeps what the
    /// install would leave behind if Android stopped in it.
    public func run(_ request: InstallRequest, file: OwnedDescriptor, guestSDK: Int = PackageArchive.guestSDK,
                    journal: InstallJournal? = nil,
                    ensureRunning: @Sendable () async throws -> Void,
                    adb: @Sendable () async throws -> ADBConnection,
                    report: @escaping Report) async throws -> String {
        let id = request.id
        report(InstallProgress(id: id, phase: .inspecting))
        let archive: PackageArchive
        do {
            archive = try PackageArchive(fileDescriptor: file.value, url: URL(filePath: request.path), guestSDK: guestSDK)
        } catch let error as PackageError {
            throw AvoError.unsupportedPackage(error.localizedDescription)
        }
        let summary = archive.summary
        if let issue = summary.compatibility.first(where: \.isBlocking) {
            throw AvoError.unsupportedPackage(issue.message)
        }

        report(InstallProgress(id: id, phase: .startingVM, package: summary.packageName))
        try await ensureRunning()
        let connection = try await adb()
        // What an install Android stopped in left behind goes first.
        if let journal { await Self.tidyUp(journal, adb: connection) }
        journal?.begin(id)
        defer { journal?.end(id) }
        var fresh = false
        if !summary.obbFiles.isEmpty { fresh = await !Self.isInstalled(summary.packageName, adb: connection) }

        let parts = summary.parts.map { part in
            ADBConnection.InstallPart(name: part.installName, size: part.size) {
                ChunkPipe { send in try archive.stream(part) { try send($0) } }.stream()
            }
        }
        report(InstallProgress(id: id, phase: .transferring, fraction: 0, package: summary.packageName))
        do {
            try await connection.install(parts, progress: { done, total in
                let fraction = total == 0 ? 1 : Double(done) / Double(total)
                report(InstallProgress(id: id, phase: done < total ? .transferring : .installing,
                                       fraction: fraction, package: summary.packageName))
            }, session: { session, open in
                if open { journal?.opened(session, by: id) } else { journal?.closed(session, by: id) }
            })
        } catch let error as ADBError {
            throw AvoError.installFailed(Self.friendly(error.localizedDescription))
        }

        if !summary.obbFiles.isEmpty {
            let copy = InstallJournal.Copy(package: summary.packageName, fresh: fresh, files: summary.obbFiles.map {
                InstallJournal.Copy.File(path: "/sdcard/" + $0.destination, size: $0.size)
            })
            journal?.copying(copy, by: id)
            let total = summary.obbBytes
            var copied: UInt64 = 0
            do {
                for obb in summary.obbFiles {
                    let base = copied
                    report(InstallProgress(id: id, phase: .copyingOBB, fraction: total == 0 ? 0 : Double(base) / Double(total),
                                           package: summary.packageName))
                    try await connection.push(ChunkPipe { send in try archive.stream(obb) { try send($0) } },
                                              to: "/sdcard/" + obb.destination, mode: 0o660) { sent in
                        report(InstallProgress(id: id, phase: .copyingOBB, fraction: Double(base + sent) / Double(max(total, 1)),
                                               package: summary.packageName))
                    }
                    copied += obb.size
                }
            } catch {
                let undone = await Self.undo(copy, adb: connection)
                if undone { journal?.copied(by: id) }
                throw AvoError.installFailed(Self.copyFailure(error, fresh: fresh, undone: undone))
            }
            journal?.copied(by: id)
        }
        return summary.packageName
    }

    /// Whether Android has `package` already. Unsure (it did not answer):
    /// yes, so a copy that fails never takes out an app that was there.
    static func isInstalled(_ package: String, adb: ADBConnection) async -> Bool {
        guard let result = try? await adb.shell("pm path " + ADBConnection.shellQuote(package)) else { return true }
        return result.output.contains("package:")
    }

    /// Takes out the game data `copy` wrote, and the app when Android did
    /// not have it before; false when Android did not answer.
    static func undo(_ copy: InstallJournal.Copy, adb: ADBConnection) async -> Bool {
        do {
            if !copy.files.isEmpty { _ = try await adb.shell("rm -f " + copy.files.map { ADBConnection.shellQuote($0.path) }.joined(separator: " ")) }
            if copy.fresh { _ = try await adb.shell("pm uninstall " + ADBConnection.shellQuote(copy.package)) }
            return true
        } catch {
            return false
        }
    }

    /// Abandons the `pm` sessions installs before this one left open, and
    /// undoes their copies of game data that did not finish.
    public static func tidyUp(_ journal: InstallJournal, adb: ADBConnection) async {
        for entry in journal.leftovers() {
            var abandoned: [Int] = []
            for session in entry.sessions {
                // Android answered: the session is gone (or was already).
                if (try? await adb.shell("pm install-abandon \(session)")) != nil { abandoned.append(session) }
            }
            var undone = false
            if let copy = entry.copy {
                // One that got to its end before it could be noted stands.
                if (try? await isComplete(copy, adb: adb)) == true {
                    undone = true
                } else {
                    undone = await undo(copy, adb: adb)
                }
            }
            journal.tidied(entry.install, sessions: abandoned, copy: undone)
        }
    }

    /// Whether every file of `copy` is in Android at its full size.
    static func isComplete(_ copy: InstallJournal.Copy, adb: ADBConnection) async throws -> Bool {
        for file in copy.files {
            let result = try await adb.shell("stat -c %s " + ADBConnection.shellQuote(file.path))
            guard result.succeeded, UInt64(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) == file.size else { return false }
        }
        return true
    }

    /// Why the install failed when its game data could not be copied.
    static func copyFailure(_ error: any Error, fresh: Bool, undone: Bool) -> String {
        var reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        if reason.contains("No space left on device") { reason = outOfStorage }
        if !fresh {
            return String(localized: "the app was updated, but its game data (OBB) could not be copied to Android: \(reason). Install it again to copy it",
                          bundle: .avoKit)
        }
        return undone
            ? String(localized: "its game data (OBB) could not be copied to Android, so Avo uninstalled the app again: \(reason)", bundle: .avoKit)
            : String(localized: "its game data (OBB) could not be copied to Android: \(reason). Avo uninstalls the app the next time Android starts",
                     bundle: .avoKit)
    }

    /// Android's storage keeps the size it was created with: only erasing
    /// Android's data changes it (Settings › Storage › Change Size).
    static var outOfStorage: String {
        String(localized: "Android is out of storage; uninstall apps or clear their data to make room, or use Change Size in Settings › Storage, which erases Android’s data",
               bundle: .avoKit)
    }

    /// Turns PackageManager failure codes into sentences.
    static func friendly(_ message: String) -> String {
        let known: [(String, String)] = [
            ("INSTALL_FAILED_NO_MATCHING_ABIS", String(localized: "the app has no 64-bit ARM code", bundle: .avoKit)),
            ("INSTALL_FAILED_INSUFFICIENT_STORAGE", outOfStorage),
            ("INSTALL_FAILED_UPDATE_INCOMPATIBLE",
             String(localized: "an installed version is signed with a different key; uninstall it first", bundle: .avoKit)),
            ("INSTALL_FAILED_VERSION_DOWNGRADE", String(localized: "a newer version is already installed", bundle: .avoKit)),
            ("INSTALL_FAILED_OLDER_SDK", String(localized: "the app needs a newer Android version", bundle: .avoKit)),
            ("INSTALL_PARSE_FAILED_NO_CERTIFICATES", String(localized: "the package is not signed", bundle: .avoKit)),
            ("INSTALL_FAILED_MISSING_SPLIT", String(localized: "a required split APK is missing from the bundle", bundle: .avoKit)),
        ]
        for (code, sentence) in known where message.contains(code) { return "\(sentence) (\(code))" }
        return message
    }
}

/// What installs left in Android that the next install or start tidies up
/// (`InstallPipeline.tidyUp`), kept beside Android's data, whose Android
/// it is about: `pm` sessions Avo created and neither committed nor
/// abandoned (Android keeps each, and the APKs written to it, for days,
/// and an abandon over a connection that went does nothing), and copies of
/// game data that did not finish (Android stopped in them).
public final class InstallJournal: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var install: UUID
        var sessions: [Int] = []
        var copy: Copy?

        var isEmpty: Bool { sessions.isEmpty && copy == nil }
    }

    /// The game data an install copies, and whether its app is new to Android.
    struct Copy: Codable, Equatable, Sendable {
        struct File: Codable, Equatable, Sendable {
            /// Where in Android (/sdcard/Android/obb/<package>/…).
            var path: String
            var size: UInt64
        }

        var package: String
        var fresh: Bool
        var files: [File]
    }

    private let paths: AvoPaths
    private let lock = NSLock()
    /// Installs running in this daemon: what they hold is not left over.
    private var running: Set<UUID> = []

    public init(paths: AvoPaths) {
        self.paths = paths
    }

    static func url(_ paths: AvoPaths) -> URL { paths.data.appending(path: "installs.json") }

    /// Anything an install that is not running left behind.
    var hasLeftovers: Bool { !leftovers().isEmpty }

    func leftovers() -> [Entry] {
        lock.withLock { load().filter { !running.contains($0.install) } }
    }

    func begin(_ install: UUID) {
        lock.withLock { _ = running.insert(install) }
    }

    /// The install ended: what it still holds is left over.
    func end(_ install: UUID) {
        lock.withLock {
            running.remove(install)
            change(install) { _ in }
        }
    }

    func opened(_ session: Int, by install: UUID) {
        lock.withLock { change(install) { $0.sessions.append(session) } }
    }

    func closed(_ session: Int, by install: UUID) {
        lock.withLock { change(install) { $0.sessions.removeAll { $0 == session } } }
    }

    func copying(_ copy: Copy, by install: UUID) {
        lock.withLock { change(install) { $0.copy = copy } }
    }

    func copied(by install: UUID) {
        lock.withLock { change(install) { $0.copy = nil } }
    }

    /// What `tidyUp` saw to: the sessions Android abandoned, and the copy when it was undone.
    func tidied(_ install: UUID, sessions: [Int], copy: Bool) {
        lock.withLock {
            change(install) { entry in
                entry.sessions.removeAll { sessions.contains($0) }
                if copy { entry.copy = nil }
            }
        }
    }

    /// Read and written each time: where Android's data is can change.
    private func load() -> [Entry] {
        guard let data = try? Data(contentsOf: Self.url(paths)) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func change(_ install: UUID, _ body: (inout Entry) -> Void) {
        var entries = load()
        var entry = entries.first { $0.install == install } ?? Entry(install: install)
        body(&entry)
        entries.removeAll { $0.install == install }
        if !entry.isEmpty { entries.append(entry) }
        let url = Self.url(paths)
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? paths.ensureDataFolder()
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}
