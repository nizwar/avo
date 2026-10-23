import Foundation

/// Bundle identifiers, launchd labels and Mach service names.
///
/// The prefix is tied to the open question about the project domain
/// (docs/spec.md). Change it here and in host/Config/Base.xcconfig
/// (`AVO_BUNDLE_ID_PREFIX`); a unit test keeps the two in sync.
public enum AvoIdentifiers {
    public static let prefix = "dev.avo"

    /// Avo.app: Control Panel and menu bar item. Its own identifier, apart
    /// from the prefix its helpers share (Base.xcconfig `AVO_APP_BUNDLE_ID`).
    public static let app = "com.avodroid.emulator"
    /// Avo.app's identifiers in earlier builds (`dev.avo.Avo`, then
    /// `emu.avo.droid` in one preview build): their preferences move to the
    /// new one at the first launch (ControlPanelDefaults).
    public static let formerApps = ["\(prefix).Avo", "emu.avo.droid"]
    /// AvoWindowHost.framework, loaded by every App Shim.
    public static let windowHost = "\(prefix).WindowHost"
    /// launchd label of the Runtime Daemon LaunchAgent.
    public static let daemonLabel = "\(prefix).daemon"
    /// Mach service the daemon vends over XPC.
    public static let daemonMachService = "\(prefix).daemon"
    /// AvoDaemon.app's bundle identifier (it posts the macOS notifications).
    public static let daemonBundleID = "\(prefix).daemon"
    /// Bundle identifier prefix of generated App Shims.
    public static let shimPrefix = "\(prefix).shim."
    /// os_log subsystem.
    public static let logSubsystem = prefix
    /// Info.plist key holding the Android package of an App Shim.
    public static let shimPackageInfoKey = "AvoAndroidPackage"
    /// Info.plist key holding the path of the Avo.app that created a shim.
    public static let shimHostAppInfoKey = "AvoHostApplication"

    /// Bundle identifier for the App Shim of an Android package.
    ///
    /// Android package names may contain `_`, which bundle identifiers do not
    /// allow, so every character outside `[A-Za-z0-9.-]` becomes `-`.
    public static func shimBundleIdentifier(for package: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        let sanitized = String(package.map { allowed.contains($0) ? $0 : "-" })
        return shimPrefix + sanitized
    }

    /// The Android package for a shim bundle identifier, when it can be
    /// recovered unambiguously (the Info.plist key is authoritative).
    public static func package(fromShimBundleIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(shimPrefix) else { return nil }
        let rest = identifier.dropFirst(shimPrefix.count)
        return rest.isEmpty ? nil : String(rest)
    }
}

/// What the Control Panel asks an App Shim: distributed notifications to a
/// running one (their object: the app's package), or an argument as it
/// launches.
public enum ShimRequest {
    /// The key mapping editor over the game (the app page's Create Key Mapping…).
    public static let editKeyMapping = Notification.Name("\(AvoIdentifiers.prefix).shim.editKeyMapping")
    /// The same, for a shim that is not running yet.
    public static let editKeyMappingArgument = "--edit-key-mapping"
    /// The app's settings in its shim's defaults changed (Show keys on game on
    /// its page): its windows show them at once.
    public static let preferencesChanged = Notification.Name("\(AvoIdentifiers.prefix).shim.preferencesChanged")
}
