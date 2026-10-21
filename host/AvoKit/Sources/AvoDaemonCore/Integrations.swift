import AvoKit
import AvoProtocol
import Foundation

/// macOS services the daemon uses but that need AppKit or UserNotifications.
/// The daemon executable provides the real implementations; tests use fakes.

/// Shows Android notifications in Notification Center (spec: "Fitur native tambahan").
public protocol NotificationPresenter: Sendable {
    /// `onOpen` is called with the notification key when the user clicks it.
    func start(onOpen: @escaping @Sendable (_ package: String, _ key: String) -> Void)
    func post(_ notification: Avo_V1_Notification, appName: String, icon: Data?)
    func remove(key: String)
    /// Whether macOS lets Avo show notifications (System Settings ›
    /// Notifications), asked now: the user can change it there at any time.
    func permission() async -> MacNotificationPermission
    /// Asks macOS for permission: its alert while it has no answer yet.
    /// Returns once macOS answers by itself (a decision it already has, or a
    /// refusal to ask), or while its alert still waits for the user
    /// (`asking`); `observePermission` hears the answer.
    func requestPermission() async -> MacNotificationPermission
    /// `onChange` gets the permission each time the user answers macOS's alert.
    func observePermission(_ onChange: @escaping @Sendable (MacNotificationPermission) -> Void)
    /// `onDismiss` gets the key of each notification the user closes in
    /// Notification Center (not the ones Avo removes).
    func observeDismissals(_ onDismiss: @escaping @Sendable (String) -> Void)
}

public extension NotificationPresenter {
    func permission() async -> MacNotificationPermission { .allowed }
    func requestPermission() async -> MacNotificationPermission { await permission() }
    func observePermission(_ onChange: @escaping @Sendable (MacNotificationPermission) -> Void) {}
    func observeDismissals(_ onDismiss: @escaping @Sendable (String) -> Void) {}
}

/// Two-way clipboard sync.
public protocol ClipboardBridge: Sendable {
    /// `onChange` receives text the user copied on the Mac.
    func start(onChange: @escaping @Sendable (String) -> Void)
    /// Puts text copied in Android on the Mac clipboard without echoing it back.
    func set(_ text: String)
    /// Text copied on the Mac that `onChange` has not had yet, now (before a
    /// paste in Android, which must not wait for the next look).
    func takeChange() -> String?
    /// Stops watching the Mac's clipboard (Settings › Devices › Clipboard off).
    func stop()
}

public extension ClipboardBridge {
    func takeChange() -> String? { nil }
    func stop() {}
}

/// Opens App Shims (for notification clicks).
public protocol AppLauncher: Sendable {
    func open(shim: URL, arguments: [String]) async throws
}

/// Default no-op implementations so the core runs headless.
public struct NoNotifications: NotificationPresenter {
    public init() {}
    public func start(onOpen: @escaping @Sendable (String, String) -> Void) {}
    public func post(_ notification: Avo_V1_Notification, appName: String, icon: Data?) {}
    public func remove(key: String) {}
}

public struct NoClipboard: ClipboardBridge {
    public init() {}
    public func start(onChange: @escaping @Sendable (String) -> Void) {}
    public func set(_ text: String) {}
}

public struct NoLauncher: AppLauncher {
    public init() {}
    public func open(shim: URL, arguments: [String]) async throws {}
}
