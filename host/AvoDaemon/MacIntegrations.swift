import AppKit
import AvoDaemonCore
import AvoKit
import AvoProtocol
import os
import UserNotifications

/// Android notifications in Notification Center; clicking one opens the app's
/// window (spec: "meng-klik notifikasi akan membuka jendela aplikasinya").
///
/// macOS checks who posts by looking the bundle identifier up in Launch
/// Services, which leaves out apps in temporary folders (`TemporaryFolder`):
/// while the only Avo.app it knows is in /tmp, Avo is refused without being
/// asked or listed in System Settings, however it was launched or signed.
/// Any copy outside one (/Applications/Avo.app) is enough.
final class UserNotificationPresenter: NSObject, NotificationPresenter, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()
    private let lock = NSLock()
    private var onOpen: (@Sendable (String, String) -> Void)?
    private var onPermission: (@Sendable (MacNotificationPermission) -> Void)?
    private var onDismiss: (@Sendable (String) -> Void)?
    private var onAction: (@Sendable (String, UInt32, String?) -> Void)?
    /// Android notifications ask to hear when the user closes them, which
    /// dismisses them in Android too.
    private static let category = "android"
    /// A category per set of buttons Android notifications came with
    /// (`category(for:)`), each with the plain one's dismiss action.
    private var categories: [String: UNNotificationCategory] = [:]
    private static let categoryLimit = 64
    /// Button identifiers: this prefix and the button's NotificationAction.index.
    private static let actionPrefix = "android.action."
    /// Requests whose alert still waits for the user's answer.
    private var pendingRequests = 0
    /// What macOS said when it refused to ask, until the next request.
    private var refusal: MacNotificationPermission?
    private var notShownLogged = false
    /// Avo.app, whose folder decides whether macOS lets it ask.
    private let avoApp: URL
    private let iconDirectory = FileManager.default.temporaryDirectory.appending(path: "avo-notification-icons")
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Notifications")

    /// `avoApp`: Avo.app/Contents/Library/Helpers/AvoDaemon.app → Avo.app.
    init(avoApp: URL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()) {
        self.avoApp = avoApp
        super.init()
    }

    func start(onOpen: @escaping @Sendable (String, String) -> Void) {
        lock.withLock { self.onOpen = onOpen }
        center.delegate = self
        center.setNotificationCategories([Self.plainCategory])
        // Asks right away rather than at the first Android notification:
        // until Avo has asked once, macOS does not list it in System
        // Settings › Notifications, so there would be nothing to turn on.
        // Request Permission in the Control Panel asks again.
        Task { _ = await requestPermission() }
    }

    func observePermission(_ onChange: @escaping @Sendable (MacNotificationPermission) -> Void) {
        lock.withLock { onPermission = onChange }
    }

    func observeDismissals(_ onDismiss: @escaping @Sendable (String) -> Void) {
        lock.withLock { self.onDismiss = onDismiss }
    }

    func observeActions(_ onAction: @escaping @Sendable (String, UInt32, String?) -> Void) {
        lock.withLock { self.onAction = onAction }
    }

    private static var plainCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: category, actions: [], intentIdentifiers: [], options: [.customDismissAction])
    }

    /// The category that shows these buttons (Reply as a text field), known
    /// to Notification Center before the notification that needs it.
    private func category(for actions: [Avo_V1_NotificationAction]) async -> String {
        guard !actions.isEmpty else { return Self.category }
        let identifier = Self.category + ":" + actions.map { "\($0.index)\($0.reply ? "r" : "")=\($0.title)" }.joined(separator: "|")
        let added = lock.withLock { () -> Set<UNNotificationCategory>? in
            guard categories[identifier] == nil else { return nil }
            // Old button sets go once there are many: today's notifications bring theirs again.
            if categories.count >= Self.categoryLimit { categories.removeAll() }
            categories[identifier] = UNNotificationCategory(identifier: identifier, actions: actions.map(Self.action),
                                                            intentIdentifiers: [], options: [.customDismissAction])
            return Set(categories.values).union([Self.plainCategory])
        }
        if let added {
            center.setNotificationCategories(added)
            // Asked after the change, which Notification Center then has.
            _ = await center.notificationCategories()
        }
        return identifier
    }

    private static func action(_ action: Avo_V1_NotificationAction) -> UNNotificationAction {
        let identifier = actionPrefix + String(action.index)
        guard action.reply else { return UNNotificationAction(identifier: identifier, title: action.title) }
        return UNTextInputNotificationAction(identifier: identifier, title: action.title, options: [],
                                             textInputButtonTitle: String(localized: "Send"),
                                             textInputPlaceholder: action.replyHint)
    }

    func post(_ notification: Avo_V1_Notification, appName: String, icon: Data?) {
        guard !notification.ongoing else { return } // progress bars and media sessions stay in Android
        Task {
            // Asking here would bring macOS's alert back with every Android
            // notification; the start and Request Permission ask.
            guard await shown() else { return }
            let content = UNMutableNotificationContent()
            content.title = notification.title.isEmpty ? appName : notification.title
            content.subtitle = notification.title.isEmpty ? "" : appName
            content.body = notification.body
            content.threadIdentifier = notification.package
            content.categoryIdentifier = await category(for: notification.actions)
            content.userInfo = ["package": notification.package, "key": notification.key]
            if !notification.silent { content.sound = .default }
            if let attachment = attachment(icon: notification.largeIconPng.isEmpty ? icon : notification.largeIconPng,
                                           package: notification.package) {
                content.attachments = [attachment]
            }
            let request = UNNotificationRequest(identifier: notification.key, content: content, trigger: nil)
            do {
                try await center.add(request)
                logger.notice("notification from \(notification.package, privacy: .public) shown")
            } catch {
                logger.error("notification from \(notification.package, privacy: .public) not shown: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func remove(key: String) {
        center.removeDeliveredNotifications(withIdentifiers: [key])
    }

    /// Asked every time: the user can allow Avo in System Settings at any point.
    func permission() async -> MacNotificationPermission {
        let status = await center.notificationSettings().authorizationStatus
        return lock.withLock { () -> MacNotificationPermission in
            switch status {
            case .authorized, .provisional, .ephemeral:
                return .allowed
            case .denied:
                return MacNotificationPermission(state: .denied)
            default:
                return refusal ?? MacNotificationPermission(state: .notDetermined, asking: pendingRequests > 0)
            }
        }
    }

    func requestPermission() async -> MacNotificationPermission {
        let before = await permission()
        // macOS asks only while it has no answer; after Don't Allow only
        // System Settings changes it.
        guard before.state == .notDetermined || before.state == .unavailable else { return before }
        let answered = Flag()
        Task {
            await authorize()
            answered.set()
        }
        // macOS answers at once when it refuses to ask; otherwise its alert
        // waits for the user, and the answer goes to `onPermission`.
        await answered.wait(upTo: .seconds(1))
        return await permission()
    }

    private func authorize() async {
        lock.withLock {
            pendingRequests += 1
            refusal = nil
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            lock.withLock { pendingRequests -= 1 }
            logger.notice("notification permission \(granted ? "allowed" : "not allowed (System Settings › Notifications)", privacy: .public)")
        } catch {
            let undecided = await center.notificationSettings().authorizationStatus == .notDetermined
            let reason = refused(error)
            lock.withLock {
                pendingRequests -= 1
                if undecided { refusal = reason }
            }
        }
        let now = await permission()
        lock.withLock { onPermission }?(now)
    }

    /// macOS refused to ask (UNError.notificationsNotAllowed): it does not
    /// know this copy of Avo, which an app in a temporary folder never is.
    private func refused(_ error: any Error) -> MacNotificationPermission {
        let me = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let known = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? AvoIdentifiers.daemonBundleID)
            .contains { $0.resolvingSymlinksInPath() == me }
        let temporary = TemporaryFolder.contains(avoApp)
        logger.error("""
            macOS did not ask for notification permission: \(error.localizedDescription, privacy: .public) \
            (Launch Services \(known ? "lists" : "does not list", privacy: .public) \(me.path, privacy: .public)\
            \(temporary ? "; Avo runs from a temporary folder, which macOS ignores" : "", privacy: .public))
            """)
        return MacNotificationPermission(state: .unavailable, temporaryFolder: temporary ? avoApp.path : nil,
                                         refusal: error.localizedDescription)
    }

    /// Whether macOS shows Avo's notifications now.
    private func shown() async -> Bool {
        if await permission().isAllowed { return true }
        if lock.withLock({ () -> Bool in defer { notShownLogged = true }; return !notShownLogged }) {
            logger.notice("Android notifications stay in Avo's list: macOS does not show Avo's notifications (Control Panel › Notifications)")
        }
        return false
    }

    private func attachment(icon: Data?, package: String) -> UNNotificationAttachment? {
        guard let icon else { return nil }
        try? FileManager.default.createDirectory(at: iconDirectory, withIntermediateDirectories: true)
        let url = iconDirectory.appending(path: "\(package)-\(UUID().uuidString).png")
        guard (try? icon.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "icon", url: url)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let package = info["package"] as? String, let key = info["key"] as? String else { return }
        if response.actionIdentifier == UNNotificationDismissActionIdentifier {
            lock.withLock { onDismiss }?(key)
        } else if response.actionIdentifier.hasPrefix(Self.actionPrefix),
                  let index = UInt32(response.actionIdentifier.dropFirst(Self.actionPrefix.count)) {
            let reply = (response as? UNTextInputNotificationResponse)?.userText
            lock.withLock { onAction }?(key, index, reply)
        } else {
            lock.withLock { onOpen }?(package, key)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

/// Set once; `wait` returns when it is, or after a while.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    func set() { lock.withLock { isSet = true } }

    func wait(upTo timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !lock.withLock({ isSet }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Two-way clipboard sync. macOS has no pasteboard change notification, so
/// the change count is polled (cheap, and the contents are only read on
/// change), while the daemon watches (Android runs, not paused). An item a
/// password manager marks private never goes to Android (ClipboardPrivacy).
final class PasteboardBridge: ClipboardBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    func start(onChange: @escaping @Sendable (String) -> Void) {
        DispatchQueue.main.async { [self] in
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                let pasteboard = NSPasteboard.general
                let count = pasteboard.changeCount
                let changed = self.lock.withLock { () -> Bool in
                    defer { self.lastChangeCount = count }
                    return count != self.lastChangeCount
                }
                guard changed, let text = Self.sharedText(pasteboard) else { return }
                onChange(text)
            }
        }
    }

    func stop() {
        DispatchQueue.main.async { [self] in
            timer?.invalidate()
            timer = nil
        }
    }

    func set(_ text: String) {
        DispatchQueue.main.async { [self] in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            lock.withLock { lastChangeCount = pasteboard.changeCount }
        }
    }

    func takeChange() -> String? {
        let look = { [self] () -> String? in
            let pasteboard = NSPasteboard.general
            let count = pasteboard.changeCount
            let changed = lock.withLock { () -> Bool in
                defer { lastChangeCount = count }
                return count != lastChangeCount
            }
            return changed ? Self.sharedText(pasteboard) : nil
        }
        return Thread.isMainThread ? look() : DispatchQueue.main.sync(execute: look)
    }

    /// The text Android may have of what was copied: none for a private item.
    private static func sharedText(_ pasteboard: NSPasteboard) -> String? {
        guard !ClipboardPrivacy.isPrivate((pasteboard.types ?? []).map(\.rawValue)),
              let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        return text
    }
}

struct WorkspaceLauncher: AppLauncher {
    func open(shim: URL, arguments: [String]) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: shim, configuration: configuration)
    }
}
