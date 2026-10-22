import AvoKit
import Foundation
import os
import Security

/// The Runtime Daemon as a LaunchAgent in ~/Library/LaunchAgents, which Avo
/// installs and updates itself.
///
/// Login Items (SMAppService) suit only a Developer ID–signed Avo: launchd
/// pins a Login Item to the code it saw when it was registered (a launch
/// constraint), and for any other signature it pins the daemon's cdhash. Once
/// an ad hoc or development-signed Avo is replaced, its new daemon is killed at
/// launch ("Launch Constraint Violation") and never starts again. A plain
/// LaunchAgent has no such pin, and every Avo update points it at the new
/// daemon. macOS lists it under Login Items › Allow in the Background, named
/// after Avo.
///
/// A daemon that runs is never stopped here: after an update it may hold
/// Android, which only the Control Panel can tell once connected
/// (ControlPanelModel.checkDaemonBuild). `install` says whether the loaded
/// agent is out of date; `reload` restarts it on this Avo's daemon.
enum DaemonAgent {
    static let label = "\(AvoIdentifiers.prefix).daemon.agent"
    /// The agent of the builds before 0.3.0 Preview 2 (AvoIdentifiers.formerPrefix).
    /// It may hold Android when this Avo first opens, so it stays until
    /// Android stops: the Control Panel talks to its daemon under the former
    /// Mach service, and `reload` puts this build's agent in its place. Two
    /// agents never run at once (two daemons would share Android's data).
    static let legacyLabel = "\(AvoIdentifiers.formerPrefix).daemon.agent"
    /// Agents of hand setups from before Avo did this itself.
    static let formerLabels = ["\(AvoIdentifiers.prefix).daemon.release", "\(AvoIdentifiers.formerPrefix).daemon.release"]

    private static let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "DaemonAgent")

    static var plistURL: URL { launchAgents.appending(path: "\(label).plist") }
    private static var launchAgents: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
    }
    private static var domain: String { "gui/\(getuid())" }

    /// A Developer ID–signed Avo keeps using Login Items, which survive its updates.
    static var usesLoginItems: Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let developerID = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        guard SecRequirementCreateWithString(developerID as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static var daemonExecutable: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Library/Helpers/AvoDaemon.app/Contents/MacOS/AvoDaemon")
    }

    static func plist(daemon: URL) -> [String: Any] {
        [
            "Label": label,
            "Program": daemon.path,
            "MachServices": [AvoIdentifiers.daemonMachService: true],
            "RunAtLoad": true,
            // Back after a crash, not after Quit Avo from its menu bar item.
            "KeepAlive": ["SuccessfulExit": false],
            // Without it the daemon and the engine are held to utility QoS, and timers coalesce.
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? AvoIdentifiers.app],
        ]
    }

    /// Installs the agent, or points its plist at this Avo's daemon, and
    /// makes sure it runs. True when launchd still holds an older plist (an
    /// update changed it), or the legacy agent's daemon still runs Android:
    /// `reload(plistChanged: true)` loads this build's.
    static func install() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            if legacyHoldsAndroid() { return true }
            // Holding nothing, the legacy agent goes now, and so does a legacy
            // plist launchd has not loaded (it would load at the next login,
            // beside this build's agent).
            _ = retireLegacy()
            IdentifierMigration.finish()
            return installNow()
        }.value
    }

    /// The legacy agent (`legacyLabel`) is loaded and its daemon runs
    /// Android: it serves `AvoIdentifiers.formerDaemonMachService` until
    /// Android stops.
    static func legacyAgentHoldsAndroid() async -> Bool {
        await Task.detached(priority: .userInitiated) { legacyHoldsAndroid() }.value
    }

    /// Starts the daemon again on this Avo's build: the agent loaded again
    /// from its plist (`plistChanged`), else its process restarted. Only
    /// while Android holds nothing: the old daemon takes Android with it.
    static func reload(plistChanged: Bool) async {
        await Task.detached(priority: .userInitiated) {
            if retireLegacy() {
                IdentifierMigration.finish()
                _ = installNow()
            } else if plistChanged {
                _ = launchctl(["bootout", "\(domain)/\(label)"])
                bootstrap()
            } else if launchctl(["kickstart", "-k", "\(domain)/\(label)"]) != 0 {
                bootstrap()
            }
            logger.notice("daemon agent restarted on this Avo")
        }.value
    }

    private static func legacyLoaded() -> Bool {
        launchctl(["print", "\(domain)/\(legacyLabel)"]) == 0
    }

    /// Only a legacy daemon that runs Android's engine has anything to keep.
    /// A loaded legacy agent may not even start: launchd holds a background
    /// item to the signature it first saw ("Unable to get updated LWCR"), so
    /// an ad hoc Avo's job cannot start a Developer ID daemon, and that job
    /// must go at once, not wait for an Android that is not there.
    private static func legacyHoldsAndroid() -> Bool {
        guard legacyLoaded() else { return false }
        let pgrep = Process()
        pgrep.executableURL = URL(filePath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "avo-vmm"]
        pgrep.standardOutput = FileHandle.nullDevice
        pgrep.standardError = FileHandle.nullDevice
        do {
            try pgrep.run()
        } catch {
            return true
        }
        pgrep.waitUntilExit()
        return pgrep.terminationStatus == 0
    }

    /// Unloads the legacy agent and removes its plist (false when there is
    /// none), waiting until launchd has let go of it, its daemon with it.
    private static func retireLegacy() -> Bool {
        let plist = launchAgents.appending(path: "\(legacyLabel).plist")
        let loaded = legacyLoaded()
        guard loaded || FileManager.default.fileExists(atPath: plist.path) else { return false }
        if loaded {
            _ = launchctl(["bootout", "\(domain)/\(legacyLabel)"])
            for _ in 0..<40 where legacyLoaded() { Thread.sleep(forTimeInterval: 0.25) }
        }
        try? FileManager.default.removeItem(at: plist)
        logger.notice("the agent of an Avo from before com.avodroid gave way to this build's")
        return true
    }

    private static func installNow() -> Bool {
        for former in formerLabels {
            _ = launchctl(["bootout", "\(domain)/\(former)"])
            try? FileManager.default.removeItem(at: launchAgents.appending(path: "\(former).plist"))
        }
        let wanted = plist(daemon: daemonExecutable.resolvingSymlinksInPath())
        let current = (try? Data(contentsOf: plistURL)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? NSDictionary
        }
        let changed = current != (wanted as NSDictionary)
        if changed {
            do {
                try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: wanted, format: .xml, options: 0)
                try data.write(to: plistURL, options: .atomic)
            } catch {
                logger.error("cannot write \(plistURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        guard launchctl(["print", "\(domain)/\(label)"]) == 0 else {
            bootstrap()
            return false
        }
        // Loaded: start it if it is not running (Quit Avo from the menu bar stops it).
        _ = launchctl(["kickstart", "\(domain)/\(label)"])
        return changed
    }

    private static func bootstrap() {
        // launchd finishes a bootout in the background: the bootstrap waits for it.
        var status: Int32 = -1
        for attempt in 0..<20 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            status = launchctl(["bootstrap", domain, plistURL.path])
            if status == 0 { break }
        }
        if status == 0 {
            logger.notice("daemon agent loaded")
        } else {
            logger.error("launchctl bootstrap \(label, privacy: .public) failed: \(status)")
        }
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
