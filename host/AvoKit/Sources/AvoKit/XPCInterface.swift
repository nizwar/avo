import Foundation
import IOSurface

// XPC between the Runtime Daemon and its clients (Control Panel, menu bar,
// App Shims and the engine). Structured payloads travel as JSON `Data` so the
// @objc surface stays small and can evolve without breaking older shims;
// input records travel in the Input channel wire format, and frames as
// IOSurface objects.

/// Exported by the daemon on `AvoIdentifiers.daemonMachService`.
@objc public protocol AvoDaemonXPC {
    /// Must be the first call. `request`: JSON `ClientHello`; reply: JSON `DaemonHello`.
    func hello(_ request: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void)

    // MARK: VM lifecycle
    /// Reply: JSON `VMStatus`.
    func status(reply: @escaping @Sendable (Data) -> Void)
    func startVM(reply: @escaping @Sendable (NSError?) -> Void)
    func stopVM(reply: @escaping @Sendable (NSError?) -> Void)
    func restartVM(reply: @escaping @Sendable (NSError?) -> Void)
    /// Forgets a failed GPU boot and restarts Android (Graphics › Try GPU Again).
    func retryGPU(reply: @escaping @Sendable (NSError?) -> Void)
    /// The engine's GPU shader cache (Control Panel only). Reply: JSON `GPUCacheStatus`.
    func gpuCacheStatus(reply: @escaping @Sendable (Data?, NSError?) -> Void)
    /// Empties it (Graphics › Clear GPU cache; Control Panel only). Reply:
    /// JSON `GPUCacheStatus` with `clearedBytes`.
    func clearGPUCache(reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func takeSnapshot(reply: @escaping @Sendable (NSError?) -> Void)
    /// Wipes the user data disk (Sistem → Reset Android).
    func resetAndroid(reply: @escaping @Sendable (NSError?) -> Void)

    // MARK: Where Android's data is (Settings › Storage › Location)
    /// Reply: JSON `StorageLocationStatus`.
    func storageLocation(reply: @escaping @Sendable (Data?, NSError?) -> Void)
    /// Looks at a folder the user chose (empty: Avo's own storage). Control
    /// Panel only. Reply: JSON `StorageCandidate`.
    func inspectStorageLocation(_ path: String, reply: @escaping @Sendable (Data?, NSError?) -> Void)
    /// `request`: JSON `StorageChangeRequest`. Replies when Android's data is
    /// in its new place (or why not); progress arrives as
    /// `DaemonEvent.storageProgress`. Control Panel only.
    func changeStorageLocation(_ request: Data, reply: @escaping @Sendable (NSError?) -> Void)
    /// Stops a move while it still copies (the old place stays in use).
    func cancelStorageChange(reply: @escaping @Sendable (NSError?) -> Void)
    /// Erases the copy of Android's data kept in Avo's own storage while
    /// another folder is used.
    func removeInternalStorageCopy(reply: @escaping @Sendable (NSError?) -> Void)
    /// Looks at a folder the user chose to share with Android (Settings ›
    /// Storage › Shared Folder; the daemon reads it, so macOS asks in Avo's
    /// name). Control Panel only. Reply: JSON `SharedFolderStatus`.
    func inspectSharedFolder(_ path: String, reply: @escaping @Sendable (Data?, NSError?) -> Void)

    // MARK: Configuration
    /// Reply: JSON `ConfigurationSnapshot`.
    func configuration(reply: @escaping @Sendable (Data) -> Void)
    /// `config`: JSON `VMConfig`. Reply: JSON `ConfigUpdateResult`.
    func updateConfiguration(_ config: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void)
    /// Sets (nil removes) one app's graphics override; the only way overrides
    /// change. Allowed for the Control Panel and that app's own shim.
    /// `override`: JSON `AppGraphicsOverride` or nil. Reply: JSON `ConfigUpdateResult`.
    func setAppGraphics(package: String, override: Data?, reply: @escaping @Sendable (Data?, NSError?) -> Void)
    /// Sets Android's frame rate cap (`VMConfig.fpsLimit`, for every app)
    /// and nothing else. Allowed for the Control Panel and App Shims (a
    /// window's settings overlay). Reply: JSON `ConfigUpdateResult`.
    func setFrameRateLimit(_ fps: Int, reply: @escaping @Sendable (Data?, NSError?) -> Void)

    // MARK: Apps
    /// Reply: JSON `[AppRecord]`.
    func apps(reply: @escaping @Sendable (Data) -> Void)
    /// Reply: PNG data of the launcher icon, if known.
    func icon(forPackage package: String, reply: @escaping @Sendable (Data?) -> Void)
    /// `request`: JSON `InstallRequest`; `file` is the package, opened by the
    /// caller (the daemon has no access of its own to Downloads or Documents).
    /// Progress arrives as `DaemonEvent.installProgress`.
    func install(_ request: Data, file: FileHandle, reply: @escaping @Sendable (NSError?) -> Void)
    func uninstall(package: String, reply: @escaping @Sendable (NSError?) -> Void)
    func forceStop(package: String, reply: @escaping @Sendable (NSError?) -> Void)
    func deleteAppData(package: String, reply: @escaping @Sendable (NSError?) -> Void)
    /// Reply: JSON `[AppPermission]`.
    func permissions(package: String, reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func setPermission(package: String, permission: String, granted: Bool, reply: @escaping @Sendable (NSError?) -> Void)
    /// Regenerates App Shims and aliases (all apps when `package` is nil).
    func recreateShortcuts(package: String?, reply: @escaping @Sendable (NSError?) -> Void)
    /// How much each app was used (Control Panel's Library). Reply: JSON
    /// `[AppUsage]`; changes follow as `DaemonEvent.appUsage`.
    func appUsage(reply: @escaping @Sendable (Data?, NSError?) -> Void)

    // MARK: System Status (Control Panel)
    /// What Android and its apps use now (CPU, memory, GPU). `watch`: the
    /// daemon samples every 2 seconds and sends this client
    /// `DaemonEvent.systemActivity` until it calls again with false or goes;
    /// nothing is sampled otherwise. Reply: JSON `SystemActivity`.
    func systemActivity(watch: Bool, reply: @escaping @Sendable (Data?, NSError?) -> Void)

    // MARK: Google apps (Control Panel)
    /// Reply: JSON `GoogleAppsStatus` (asks Android while it runs).
    func googleAppsStatus(reply: @escaping @Sendable (Data?, NSError?) -> Void)
    /// `request`: JSON `GoogleAppsInstallRequest`. Replies when the install
    /// has finished or failed (minutes: Android restarts up to three times);
    /// progress arrives as `DaemonEvent.googleAppsProgress`.
    func installGoogleApps(_ request: Data, reply: @escaping @Sendable (NSError?) -> Void)
    /// Stops an install while it is still preparing or downloading. `id`:
    /// the request's UUID string (empty for whichever runs); one that has
    /// not reached the daemon yet is refused when it does.
    func cancelGoogleApps(_ id: String, reply: @escaping @Sendable (NSError?) -> Void)
    /// Takes Google apps out again, keeping every other app and its data.
    /// `id`: a UUID string naming the run's `DaemonEvent.googleAppsProgress`.
    /// Replies when they are gone or the removal failed.
    func removeGoogleApps(_ id: String, reply: @escaping @Sendable (NSError?) -> Void)

    // MARK: Notifications (Control Panel)
    /// Opens the app a notification came from, as clicking it would.
    func openNotification(key: String, reply: @escaping @Sendable (NSError?) -> Void)
    /// Clear All: dismisses every notification in Avo's list, in
    /// Notification Center and in Android.
    func clearNotifications(reply: @escaping @Sendable (NSError?) -> Void)
    /// Dismisses these notifications (`keys`: JSON `[String]`) in Avo's list,
    /// Notification Center and Android, as a swipe on a phone does.
    func dismissNotifications(_ keys: Data, reply: @escaping @Sendable (NSError?) -> Void)
    /// Whether macOS shows Avo's notifications, asked now (System Settings has
    /// no change notification). Reply: JSON `MacNotificationPermission`.
    func notificationPermission(reply: @escaping @Sendable (Data?, NSError?) -> Void)
    /// Request Permission: the daemon, which posts the notifications, asks
    /// macOS, whose alert appears while it has no answer yet. Replies at once
    /// when macOS answers by itself, else while its alert still waits
    /// (`asking`); the answer follows as `DaemonEvent.macNotifications`.
    /// Reply: JSON `MacNotificationPermission`.
    func requestNotificationPermission(reply: @escaping @Sendable (Data?, NSError?) -> Void)

    // MARK: Screen lock (Control Panel and App Shims)
    /// Passes the screen lock's credential (`VMStatus.screenLock`: a pattern
    /// as its dots "1235", a PIN or a password) to Android and replies once
    /// Android is unlocked; `AvoError.screenLockRejected` when it is not the
    /// right one. The credential is never logged or kept.
    func unlockAndroid(credential: String, reply: @escaping @Sendable (NSError?) -> Void)

    // MARK: Fingerprints (Control Panel; App Shims list, touch and cancel)
    /// Reply: JSON `FingerprintStatus`, asked from Android while it runs
    /// (`refresh`: now, else when not asked for a while).
    func fingerprints(refresh: Bool, reply: @escaping @Sendable (Data?, NSError?) -> Void)
    /// Registers a finger named `name` in Avo; Android's Settings adds it
    /// when touched with it. Reply: JSON `Fingerprint`.
    func addFingerprint(name: String, reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func renameFingerprint(_ id: Int, name: String, reply: @escaping @Sendable (NSError?) -> Void)
    func removeFingerprint(_ id: Int, reply: @escaping @Sendable (NSError?) -> Void)
    /// Touches Android's fingerprint sensor with finger `id` (0: a finger
    /// Avo does not know); while Android's Settings adds a fingerprint, the
    /// touch adds that finger. Reply: JSON `FingerprintTouchResult`.
    func touchFingerprint(_ id: Int, reply: @escaping @Sendable (Data?, NSError?) -> Void)
    /// Cancels an app's fingerprint request (its BiometricPrompt shows on
    /// Android's own screen, which no window shows).
    func cancelFingerprintRequest(reply: @escaping @Sendable (NSError?) -> Void)
    /// Locks Android so its screen lock is entered (in Avo's lock), which
    /// lets fingerprints work again after too many tries.
    func lockAndroidForFingerprints(reply: @escaping @Sendable (NSError?) -> Void)

    // MARK: Widgets (Library › Widgets; Control Panel only)
    /// The widgets Android's apps offer (asks Android). Reply: JSON `[WidgetProvider]`.
    func widgetProviders(reply: @escaping @Sendable (Data?, NSError?) -> Void)
    /// The widgets on the Mac. Reply: JSON `[PlacedWidget]`.
    func placedWidgets(reply: @escaping @Sendable (Data?, NSError?) -> Void)
    /// Puts provider `provider`'s widget on the Mac. Reply: JSON `PlacedWidget`.
    func addWidget(_ provider: String, reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func removeWidget(_ id: String, reply: @escaping @Sendable (NSError?) -> Void)

    // MARK: Location (an app window's Location panel; App Shims and Control Panels)
    /// What Android's GPS reports, with the route's points. `watch`: send
    /// this client `DaemonEvent.location` at every change (once a second
    /// while a route plays) until it calls again with false. Reply: JSON `LocationStatus`.
    func location(watch: Bool, reply: @escaping @Sendable (Data?, NSError?) -> Void)
    /// `request`: JSON `LocationRequest` (this Mac's location, a place, a
    /// route and how it plays). Reply: JSON `LocationStatus`.
    func changeLocation(_ request: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void)

    // MARK: Translate Screen (App Shims)
    /// Gets the text engine ready (Vision's models, the languages translated
    /// last) unless it is already: Translate Screen just turned on in a window.
    func wakeScreenText(reply: @escaping @Sendable (NSError?) -> Void)
    /// The text in a frame. `request`: JSON `ScreenTextRequest`; `pixels`: the
    /// frame's. Reply: JSON `ScreenTextReading`.
    func readScreenText(_ request: Data, pixels: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void)
    /// `request`: JSON `TranslationRequest`. Reply: JSON `[String]`, the
    /// translations in the texts' order.
    func translateTexts(_ request: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void)
    /// The translations the engine has already (any app's), at once.
    /// `request`: JSON `TranslationRequest`. Reply: JSON `[String?]`, nil
    /// for a text not translated yet.
    func knownTranslations(_ request: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void)

    // MARK: Displays (App Shims)
    /// `request`: JSON `OpenDisplayRequest`. Reply: JSON `OpenDisplayReply`.
    func openDisplay(_ request: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void)
    /// Replies once Android has the newest size and density and the app is
    /// back on the display (a size change re-plugs it).
    func resizeDisplay(_ displayID: UInt32, width: UInt32, height: UInt32, dpi: UInt32, reply: @escaping @Sendable (NSError?) -> Void)
    func closeDisplay(_ displayID: UInt32)
    func setDisplayVisible(_ displayID: UInt32, visible: Bool)
    /// The display's window became the Mac's key window: its app takes
    /// Android's input focus (games pause their sound without it).
    func focusDisplay(_ displayID: UInt32)
    /// One Input channel record (docs/protocol.md). Fire and forget.
    func sendInput(_ record: Data)
    /// Copies files (opened by the caller) into /sdcard/Download and shares
    /// them with the app on `displayID`. `names` are the files' names.
    func shareFiles(_ displayID: UInt32, files: [FileHandle], names: [String], reply: @escaping @Sendable (NSError?) -> Void)

    // MARK: Engine
    /// Called by the engine process: the swapchain for a display (IOSurfaces).
    func engineSetSurfaces(_ displayID: UInt32, surfaces: [IOSurface])
    /// Called by the engine process for every presented frame.
    func enginePresent(_ displayID: UInt32, surfaceIndex: Int, sequence: UInt64)
}

/// Exported by every client so the daemon can push events and frames.
@objc public protocol AvoClientXPC {
    /// JSON `DaemonEvent`.
    func handleEvent(_ event: Data)
    /// Swapchain of a display owned by this client (sent on open and resize).
    func setSurfaces(_ displayID: UInt32, surfaces: [IOSurface])
    /// A new frame is in `surfaces[surfaceIndex]`.
    func present(_ displayID: UInt32, surfaceIndex: Int, sequence: UInt64)
}

public enum AvoXPC {
    public static func daemonInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: AvoDaemonXPC.self)
        let surfaces = NSSet(array: [NSArray.self, IOSurface.self]) as! Set<AnyHashable>
        interface.setClasses(surfaces, for: #selector(AvoDaemonXPC.engineSetSurfaces(_:surfaces:)),
                             argumentIndex: 1, ofReply: false)
        let handles = NSSet(array: [NSArray.self, FileHandle.self]) as! Set<AnyHashable>
        interface.setClasses(handles, for: #selector(AvoDaemonXPC.shareFiles(_:files:names:reply:)),
                             argumentIndex: 1, ofReply: false)
        let strings = NSSet(array: [NSArray.self, NSString.self]) as! Set<AnyHashable>
        interface.setClasses(strings, for: #selector(AvoDaemonXPC.shareFiles(_:files:names:reply:)),
                             argumentIndex: 2, ofReply: false)
        return interface
    }

    public static func clientInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: AvoClientXPC.self)
        let surfaces = NSSet(array: [NSArray.self, IOSurface.self]) as! Set<AnyHashable>
        interface.setClasses(surfaces, for: #selector(AvoClientXPC.setSurfaces(_:surfaces:)),
                             argumentIndex: 1, ofReply: false)
        return interface
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func encode<T: Encodable>(_ value: T) -> Data {
        // Encoding our own Codable models cannot fail; crash loudly if it does.
        try! encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    // MARK: Errors

    public static let errorDomain = "\(AvoIdentifiers.prefix).error"

    public static func nsError(_ error: any Error) -> NSError {
        let avoError = (error as? AvoError) ?? .internalError(error.localizedDescription)
        let payload = encode(avoError)
        return NSError(domain: errorDomain, code: 1, userInfo: [
            NSLocalizedDescriptionKey: avoError.localizedDescription,
            "AvoError": payload,
        ])
    }

    public static func avoError(_ error: NSError) -> AvoError {
        if error.domain == errorDomain, let payload = error.userInfo["AvoError"] as? Data,
           let decoded = try? decode(AvoError.self, from: payload) {
            return decoded
        }
        return .internalError(error.localizedDescription)
    }
}

// MARK: - Payloads

public struct ClientHello: Codable, Sendable {
    public enum Role: Codable, Equatable, Sendable {
        case controlPanel
        case shim(package: String)
        case engine
    }

    public var role: Role
    public var version: String

    public init(role: Role, version: String) {
        self.role = role
        self.version = version
    }
}

public struct DaemonHello: Codable, Sendable {
    public var daemonVersion: String
    public var status: VMStatus

    public init(daemonVersion: String, status: VMStatus) {
        self.daemonVersion = daemonVersion
        self.status = status
    }
}

public struct ConfigurationSnapshot: Codable, Sendable {
    public var config: VMConfig
    public var host: HostInfo
    public var profiles: [DeviceProfile]
    /// Settings saved but waiting for the next VM restart.
    public var pendingRestart: Bool
    /// ADB support as it runs (nil while it is off).
    public var adb: ADBStatus?
    /// Android's storage (nil from an older daemon).
    public var dataDisk: DataDiskStatus?
    /// Where Android's data is (nil from an older daemon).
    public var storageLocation: StorageLocationStatus?
    /// The folder shared with Android (nil from an older daemon).
    public var sharedFolder: SharedFolderStatus?

    public init(config: VMConfig, host: HostInfo, profiles: [DeviceProfile], pendingRestart: Bool, adb: ADBStatus? = nil,
                dataDisk: DataDiskStatus? = nil, storageLocation: StorageLocationStatus? = nil, sharedFolder: SharedFolderStatus? = nil) {
        self.config = config
        self.host = host
        self.profiles = profiles
        self.pendingRestart = pendingRestart
        self.adb = adb
        self.dataDisk = dataDisk
        self.storageLocation = storageLocation
        self.sharedFolder = sharedFolder
    }
}

/// The loopback port of "ADB support".
public struct ADBStatus: Codable, Equatable, Sendable {
    public var port: Int
    /// Why the port could not be opened; nil while listening.
    public var problem: String?

    public init(port: Int, problem: String? = nil) {
        self.port = port
        self.problem = problem
    }

    /// What to type: `adb connect 127.0.0.1:5555`.
    public var connectCommand: String { "adb connect 127.0.0.1:\(port)" }
}

public struct ConfigUpdateResult: Codable, Sendable {
    public var effect: ConfigChangeEffect
    public var issues: [ConfigIssue]

    public init(effect: ConfigChangeEffect, issues: [ConfigIssue]) {
        self.effect = effect
        self.issues = issues
    }
}

public struct InstallRequest: Codable, Sendable {
    public var id: UUID
    /// The package file (.apk, .xapk, .apkm, .apks) on the Mac.
    public var path: String

    public init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = path
    }
}

public struct InstallProgress: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case inspecting, startingVM, transferring, installing, copyingOBB, creatingShortcuts, finished, failed
    }

    public var id: UUID
    public var phase: Phase
    /// 0...1 when the phase has measurable progress.
    public var fraction: Double?
    public var package: String?
    public var message: String?

    public init(id: UUID, phase: Phase, fraction: Double? = nil, package: String? = nil, message: String? = nil) {
        self.id = id
        self.phase = phase
        self.fraction = fraction
        self.package = package
        self.message = message
    }
}

public struct AppPermission: Codable, Hashable, Sendable {
    public var name: String
    public var label: String
    public var granted: Bool
    public var runtime: Bool

    public init(name: String, label: String, granted: Bool, runtime: Bool) {
        self.name = name
        self.label = label
        self.granted = granted
        self.runtime = runtime
    }
}

public struct OpenDisplayRequest: Codable, Sendable {
    public var package: String
    /// Display size in pixels and density.
    public var width: UInt32
    public var height: UInt32
    public var dpi: UInt32
    public var notificationKey: String?
    public var dataURI: String?
    public var mimeType: String?
    /// A widget panel's `PlacedWidget.id` (package `AndroidWidgets.package`).
    public var widget: String?

    public init(package: String, width: UInt32, height: UInt32, dpi: UInt32,
                notificationKey: String? = nil, dataURI: String? = nil, mimeType: String? = nil, widget: String? = nil) {
        self.package = package
        self.width = width
        self.height = height
        self.dpi = dpi
        self.notificationKey = notificationKey
        self.dataURI = dataURI
        self.mimeType = mimeType
        self.widget = widget
    }
}

public struct OpenDisplayReply: Codable, Sendable {
    public var displayID: UInt32

    public init(displayID: UInt32) {
        self.displayID = displayID
    }
}

public enum DisplayOrientation: String, Codable, Sendable {
    case unspecified, portrait, landscape, reversePortrait, reverseLandscape
}

/// Events the daemon pushes to clients.
/// What an app is doing, for the Control Panel's list (apps not listed are
/// not running).
public enum AppActivity: String, Codable, Sendable, Equatable {
    /// A window shows it.
    case open
    /// All its windows are minimized or hidden.
    case minimized
    /// Running without a window: closed to the background, or started by
    /// something else.
    case background
}

/// A notification an Android app posted, as the Control Panel lists it.
public struct AndroidNotification: Codable, Sendable, Equatable, Identifiable {
    public var key: String
    public var package: String
    public var appName: String
    public var title: String
    public var body: String
    public var postedAt: Date

    public var id: String { key }

    public init(key: String, package: String, appName: String, title: String, body: String, postedAt: Date) {
        self.key = key
        self.package = package
        self.appName = appName
        self.title = title
        self.body = body
        self.postedAt = postedAt
    }
}

public enum DaemonEvent: Codable, Sendable, Equatable {
    case vmStatus(VMStatus)
    /// The activity of every running app (sent to the Control Panel).
    case appActivity([String: AppActivity])
    case appInstalled(AppRecord)
    case appRemoved(package: String)
    case installProgress(InstallProgress)
    case displayReady(displayID: UInt32)
    case displayClosed(displayID: UInt32)
    /// The app was force stopped (Control Panel): its shim quits.
    case appStopped(package: String)
    case displayTitle(displayID: UInt32, title: String)
    case orientationRequest(displayID: UInt32, orientation: DisplayOrientation)
    case configurationChanged(VMConfig)
    /// Android's recent notifications, newest first (sent to the Control Panel).
    case notifications([AndroidNotification])
    /// The widgets on the Mac, when they change (sent to Control Panels).
    case widgets([PlacedWidget])
    /// How many of an app's notifications Android shows, for its Dock badge:
    /// when that changes and when its App Shim connects (sent to that app's
    /// App Shims).
    case notificationCount(package: String, count: Int)
    /// Whether macOS shows Avo's notifications: when a Control Panel connects
    /// and when the user answers macOS's alert (sent to the Control Panel).
    case macNotifications(MacNotificationPermission)
    /// Settings › System › Google apps (sent to every Control Panel).
    case googleAppsProgress(GoogleAppsProgress)
    /// Settings › Fingerprints and what asks for a finger (sent to Control
    /// Panels and App Shims).
    case fingerprints(FingerprintStatus)
    /// Every app's usage, when a window opens, closes or goes on or off
    /// screen, and once a minute while one is on screen (sent to Control Panels).
    case appUsage([AppUsage])
    /// Where Android's data is, when that or its volume changes (sent to Control Panels).
    case storageLocation(StorageLocationStatus)
    /// A change of where Android's data is, as it goes (sent to Control Panels).
    case storageProgress(StorageChangeProgress)
    /// Where the engine keeps what Android plays, for screen recordings
    /// (CaptureAudio.swift): when it starts and when an App Shim connects
    /// (sent to App Shims).
    case audioTap(AudioTapLocation)
    /// What Android's GPS reports, without the route's points (sent to the
    /// clients whose Location panel watches, see `location(watch:)`).
    case location(LocationStatus)
    /// System Status, every 2 seconds (sent to the Control Panels that
    /// watch, see `systemActivity(watch:)`).
    case systemActivity(SystemActivity)
}
