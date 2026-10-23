import Foundation

/// One installed Android app as the daemon tracks it.
///
/// The guest is the source of truth (AppInstalled / AppRemoved events and
/// ListApps); the registry adds host-side state such as the App Shim.
public struct AppRecord: Codable, Identifiable, Hashable, Sendable {
    public var package: String
    public var label: String
    public var versionName: String
    public var versionCode: Int64
    public var sizeBytes: Int64?
    public var installedAt: Date?
    public var updatedAt: Date?
    public var systemApp: Bool
    public var launchable: Bool
    public var installer: String?
    /// The app says it is a game (AppInfo.game): its windows use the Games
    /// profile unless the user chose otherwise. Nil until Android said.
    public var isGame: Bool?
    /// The orientation its activities ask for (AppInfo.orientation), which
    /// the Games profile takes when Android's word made it a game; nil when
    /// they let the screen turn, or until Android said.
    public var orientation: VMConfig.Orientation?
    /// SHA-256 of the icon PNG, used to skip regenerating unchanged shim icons.
    public var iconDigest: String?
    /// Host-side shortcuts created for this app.
    public var shortcuts: Shortcuts

    public struct Shortcuts: Codable, Hashable, Sendable {
        public var shimPath: String?
        /// Code directory hash of the ad-hoc signed shim, pinned for XPC caller checks.
        public var shimCDHash: String?
        public var desktopAliasPath: String?
        public var inDock: Bool

        public init(shimPath: String? = nil, shimCDHash: String? = nil, desktopAliasPath: String? = nil, inDock: Bool = false) {
            self.shimPath = shimPath
            self.shimCDHash = shimCDHash
            self.desktopAliasPath = desktopAliasPath
            self.inDock = inDock
        }
    }

    public var id: String { package }

    public init(package: String, label: String, versionName: String = "", versionCode: Int64 = 0,
                sizeBytes: Int64? = nil, installedAt: Date? = nil, updatedAt: Date? = nil,
                systemApp: Bool = false, launchable: Bool = true, installer: String? = nil, isGame: Bool? = nil,
                orientation: VMConfig.Orientation? = nil,
                iconDigest: String? = nil, shortcuts: Shortcuts = Shortcuts()) {
        self.package = package
        self.label = label
        self.versionName = versionName
        self.versionCode = versionCode
        self.sizeBytes = sizeBytes
        self.installedAt = installedAt
        self.updatedAt = updatedAt
        self.systemApp = systemApp
        self.launchable = launchable
        self.installer = installer
        self.isGame = isGame
        self.orientation = orientation
        self.iconDigest = iconDigest
        self.shortcuts = shortcuts
    }

    /// Display name with a fallback for apps without a label.
    public var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? package : trimmed
    }
}

/// VM lifecycle as shown in the menu bar and Control Panel.
public enum VMState: String, Codable, Sendable {
    case notInstalled
    case stopped
    case starting
    case running
    /// Android is being paused (its vCPUs stop; `VMStatus.pause` says why).
    case suspending
    /// Android is paused: it holds its place, uses no CPU, and goes on when
    /// anything uses it.
    case suspended
    case stopping
    case failed
}

public struct VMStatus: Codable, Equatable, Sendable {
    public var state: VMState
    public var detail: String?
    public var androidVersion: String?
    public var protocolVersion: UInt32?
    public var bootedAt: Date?
    public var openDisplays: Int
    /// GPU or software rendering, and why (nil from a daemon before GPU
    /// support, or the crosvm engine).
    public var renderer: RendererStatus?
    /// Android started with a screen lock and waits for its credential: apps
    /// open once it is unlocked (`unlockAndroid`). Nil otherwise, and from
    /// engines that cannot tell.
    public var screenLock: AndroidScreenLock?
    /// While Android is paused or being paused (nil otherwise, and from an
    /// older daemon).
    public var pause: VMPause?

    public init(state: VMState, detail: String? = nil, androidVersion: String? = nil,
                protocolVersion: UInt32? = nil, bootedAt: Date? = nil, openDisplays: Int = 0, renderer: RendererStatus? = nil,
                screenLock: AndroidScreenLock? = nil, pause: VMPause? = nil) {
        self.state = state
        self.detail = detail
        self.androidVersion = androidVersion
        self.protocolVersion = protocolVersion
        self.bootedAt = bootedAt
        self.openDisplays = openDisplays
        self.renderer = renderer
        self.screenLock = screenLock
        self.pause = pause
    }

    public static let stopped = VMStatus(state: .stopped)

    /// Paused, or being paused: Android goes on by itself when used.
    public var isPaused: Bool { state == .suspended || state == .suspending }
}

/// Why and since when Android is paused.
public struct VMPause: Codable, Equatable, Sendable {
    public var since: Date
    /// Avo paused it on its own (Settings › Performance › Pause When Idle),
    /// not the user from the menu bar.
    public var automatic: Bool

    public init(since: Date, automatic: Bool) {
        self.since = since
        self.automatic = automatic
    }
}
