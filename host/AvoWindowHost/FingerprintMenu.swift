import AppKit
import AvoHazeUI
import AvoKit
import os

/// Android's fingerprints as the daemon last sent them to this App Shim
/// (`DaemonEvent.fingerprints`), shared by its windows' fingerprint menus.
@MainActor
final class ShimFingerprints {
    static let shared = ShimFingerprints()

    private(set) var status = FingerprintStatus.androidStopped
    private var client: DaemonClient?
    private var observers: [Observer] = []
    private var refreshing = false

    private struct Observer {
        weak var owner: AnyObject?
        let changed: (FingerprintStatus) -> Void
    }

    /// After `hello`: the status now (the daemon asks Android if it has not lately).
    func connect(_ client: DaemonClient) {
        self.client = client
        refresh(fromAndroid: false)
    }

    func update(_ status: FingerprintStatus) {
        guard status != self.status else { return }
        self.status = status
        observers.removeAll { $0.owner == nil }
        for observer in observers { observer.changed(status) }
    }

    /// Calls `changed` now and on every change, for as long as `owner` lives.
    func observe(_ owner: AnyObject, _ changed: @escaping (FingerprintStatus) -> Void) {
        observers.removeAll { $0.owner == nil || $0.owner === owner }
        observers.append(Observer(owner: owner, changed: changed))
        changed(status)
    }

    /// Asks again in the background (a menu opens with what is known);
    /// `fromAndroid`: now, else only when the daemon's answer is stale.
    func refresh(fromAndroid: Bool) {
        guard let client, !refreshing else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            if let status = try? await client.fingerprints(refresh: fromAndroid) { update(status) }
        }
    }

    func touch(_ id: Int?) async throws -> FingerprintTouchResult {
        guard let client else { throw AvoError.daemonUnreachable(String(localized: "not connected", bundle: .windowHost)) }
        return try await client.touchFingerprint(id)
    }

    func cancelRequest() async throws {
        try await client?.cancelFingerprintRequest()
    }

    func lockAndroid() async throws {
        try await client?.lockAndroidForFingerprints()
    }
}

/// The fingerprint menu touches Android's fingerprint sensor with a finger
/// from Settings › Fingerprints, so an app's BiometricPrompt (which shows on
/// Android's own screen, never in a window) or the lock screen takes it, and
/// Android's Settings adds the finger it is touched with. It is the title
/// bar's Device › Fingerprint, and a blue button of its own in the title bar
/// while this app, the lock screen or Settings asks for a finger.
@MainActor
final class FingerprintMenu: NSObject {
    let button = TitlebarButton(symbol: "touchid", label: FingerprintMenu.title, action: nil)
    private let package: String
    private let appName: String
    private let notice: (String) -> Void
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Fingerprints")
    /// The request a notice was shown for (one notice per request).
    private var announced: FingerprintRequest?

    static var title: String { String(localized: "Fingerprint", bundle: .windowHost) }

    init(package: String, appName: String, notice: @escaping (String) -> Void) {
        self.package = package
        self.appName = appName
        self.notice = notice
        super.init()
        button.popUpMenu = { [weak self] in self?.makeMenu() }
        ShimFingerprints.shared.observe(self) { [weak self] status in self?.statusChanged(status) }
    }

    // MARK: The button

    /// Whether a finger now would reach something this window shows: this
    /// app, Android's lock screen, or Settings adding a fingerprint. Only
    /// then does the button show.
    private func concernsThisWindow(_ request: FingerprintRequest) -> Bool {
        request.package == package || request.isLockScreen || request.purpose == .enroll
    }

    private func statusChanged(_ status: FingerprintStatus) {
        let request = status.request.flatMap { concernsThisWindow($0) && status.canTouch ? $0 : nil }
        button.isHidden = request == nil
        button.contentTintColor = request == nil ? nil : .controlAccentColor
        let tip = request.map(headline) ?? Self.title
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        guard let request else {
            announced = nil
            return
        }
        // An app's request is invisible otherwise, and Settings asks for a
        // sensor the Mac does not have: say once where the fingers are.
        guard request != announced, request.package == package else { return }
        announced = request
        if request.purpose == .enroll {
            notice(status.fingers.contains(where: { !$0.enrolled })
                ? String(localized: "Choose the finger to add with the fingerprint button in the title bar.", bundle: .windowHost)
                : String(localized: "Register a finger in Avo first: choose Manage Fingerprints… with the fingerprint button in the title bar.", bundle: .windowHost))
        } else if !status.fingers.isEmpty {
            notice(String(localized: "\(appName) is asking for a fingerprint. Choose a finger with the fingerprint button in the title bar.",
                          bundle: .windowHost))
        }
    }

    // MARK: The menu

    func makeMenu() -> NSMenu {
        let shared = ShimFingerprints.shared
        // Shown as known; the daemon asks Android again when its answer is
        // a few seconds old, ready for the next time.
        shared.refresh(fromAndroid: false)
        let status = shared.status
        let menu = NSMenu()
        menu.autoenablesItems = false

        func note(_ text: String) {
            let item = menu.addItem(withTitle: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
        }

        switch status.availability {
        case .androidStopped:
            note(String(localized: "Android is not running", bundle: .windowHost))
        case .unsupported:
            note(String(localized: "This Android has no fingerprint sensor Avo can use", bundle: .windowHost))
        case .noScreenLock:
            note(String(localized: "Android needs a screen lock for fingerprints", bundle: .windowHost))
        case .ready where status.fingers.isEmpty:
            note(String(localized: "No fingers registered", bundle: .windowHost))
        case .ready:
            if let state = stateLine(status) { note(state) }
            for finger in status.fingers {
                let item = menu.addItem(withTitle: finger.name, action: #selector(touchFinger(_:)), keyEquivalent: "")
                item.target = self
                item.tag = finger.id
                item.symbol("touchid")
                if status.enrolling {
                    // Settings adds the finger that touches it: the ones Android has are done.
                    item.isEnabled = status.canTouch && !finger.enrolled
                    if finger.enrolled {
                        item.state = .on
                        item.toolTip = String(localized: "Android has this finger already.", bundle: .windowHost)
                    }
                } else {
                    item.isEnabled = status.canTouch
                    if !finger.enrolled { item.subtitle = String(localized: "Not in Android", bundle: .windowHost) }
                }
            }
            if status.enrolling, !status.fingers.contains(where: { !$0.enrolled }) {
                note(String(localized: "Every finger is in Android. Add another with Manage Fingerprints…", bundle: .windowHost))
            }
            if !status.enrolling {
                menu.addItem(.separator())
                let unknown = menu.addItem(withTitle: String(localized: "Unregistered Finger", bundle: .windowHost),
                                           action: #selector(touchUnregistered), keyEquivalent: "")
                unknown.target = self
                unknown.symbol("questionmark.circle")
                unknown.isEnabled = status.canTouch
                unknown.toolTip = String(localized: "A finger Android does not know: the app or lock screen does not recognize it.", bundle: .windowHost)
            }
            if let request = status.request, request.purpose == .authenticate, !request.isLockScreen {
                let cancel = menu.addItem(withTitle: String(localized: "Cancel Fingerprint Request", bundle: .windowHost),
                                          action: #selector(cancelRequest), keyEquivalent: "")
                cancel.target = self
                cancel.symbol("xmark.circle")
            }
            if status.lockout == .permanent {
                let lock = menu.addItem(withTitle: String(localized: "Use Screen Lock Instead…", bundle: .windowHost),
                                        action: #selector(useScreenLock), keyEquivalent: "")
                lock.target = self
                lock.symbol("lock")
                lock.toolTip = String(localized: "Locks Android; entering its PIN, pattern or password lets fingerprints work again.",
                                      bundle: .windowHost)
            }
        }
        menu.addItem(.separator())
        let manage = menu.addItem(withTitle: String(localized: "Manage Fingerprints…", bundle: .windowHost),
                                  action: #selector(manageFingerprints), keyEquivalent: "")
        manage.target = self
        manage.symbol("gearshape")
        return menu
    }

    /// The line above the fingers: what asks, or why Android takes none now.
    private func stateLine(_ status: FingerprintStatus) -> String? {
        switch status.lockout {
        case .timed: return String(localized: "Too many tries. Try again in about 30 seconds.", bundle: .windowHost)
        case .permanent: return String(localized: "Too many tries. Enter Android’s screen lock to use fingerprints again.", bundle: .windowHost)
        case .none: break
        }
        if status.credentialRequired {
            return String(localized: "Unlock Android with its PIN, pattern or password first.", bundle: .windowHost)
        }
        return status.request.map(headline)
    }

    private func headline(_ request: FingerprintRequest) -> String {
        if request.purpose == .enroll {
            return String(localized: "Android’s Settings is adding a fingerprint: choose the finger to add", bundle: .windowHost)
        }
        if request.isLockScreen { return String(localized: "The lock screen is asking for a fingerprint", bundle: .windowHost) }
        if request.package == package { return String(localized: "\(appName) is asking for a fingerprint", bundle: .windowHost) }
        return String(localized: "Another app is asking for a fingerprint", bundle: .windowHost)
    }

    // MARK: Actions

    @objc private func touchFinger(_ sender: NSMenuItem) {
        touch(sender.tag, name: sender.title)
    }

    @objc private func touchUnregistered() {
        touch(nil, name: nil)
    }

    private func touch(_ id: Int?, name: String?) {
        Task {
            do {
                let result = try await ShimFingerprints.shared.touch(id)
                if let message = Self.message(result, finger: name) { notice(message) }
            } catch {
                logger.error("fingerprint touch failed: \(error.localizedDescription, privacy: .public)")
                notice((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// What to say after a touch; the app or the lock screen shows a
    /// recognized finger by itself, but its "Not recognized" is on Android's
    /// own screen.
    static func message(_ result: FingerprintTouchResult, finger: String?) -> String? {
        switch result {
        case .recognized:
            finger.map { String(localized: "Android recognized “\($0)”.", bundle: .windowHost) }
        case .notRecognized:
            String(localized: "Android did not recognize that finger.", bundle: .windowHost)
        case .enrolled:
            finger.map { String(localized: "Android added “\($0)”.", bundle: .windowHost) }
                ?? String(localized: "Android added the fingerprint.", bundle: .windowHost)
        case .lockedOut:
            String(localized: "Too many tries: Android takes no fingerprints for now.", bundle: .windowHost)
        case .credentialRequired:
            String(localized: "Android wants its PIN, pattern or password before a fingerprint.", bundle: .windowHost)
        case .nobodyAsked:
            String(localized: "Nothing in Android is asking for a fingerprint right now.", bundle: .windowHost)
        case .touched:
            String(localized: "Touched the fingerprint sensor.", bundle: .windowHost)
        }
    }

    @objc private func cancelRequest() {
        Task {
            do {
                try await ShimFingerprints.shared.cancelRequest()
            } catch {
                notice((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    @objc private func useScreenLock() {
        Task {
            do {
                try await ShimFingerprints.shared.lockAndroid()
            } catch {
                notice((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Settings › Fingerprints in the Control Panel (Avo.app takes the link).
    @objc private func manageFingerprints() {
        AndroidWindowController.openControlPanel(ControlPanelLink.url(pane: ControlPanelLink.fingerprintsPane))
    }
}
