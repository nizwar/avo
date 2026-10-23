import Foundation

// Mock fingerprints (Settings › Fingerprints, an app window's fingerprint
// menu). The user's fingers live in Avo; Android's own Settings app adds
// them to Android (the virtual sensor of AOSP's userdebug images) when it is
// touched with one, as a phone's sensor is, so apps (BiometricPrompt) and the
// lock screen see enrolled fingerprints. A finger chosen in a window's menu
// touches that sensor. The daemon side is in AvoDaemonCore's
// Fingerprints.swift and GuestFingerprints.swift.

/// A finger registered in Settings › Fingerprints.
public struct Fingerprint: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// The sensor's id for the finger, which Android enrolls it under.
    public var id: Int
    /// Its name in Avo, and in Android's Settings once Android has it
    /// (Security & privacy › Device unlock › Fingerprint).
    public var name: String
    /// Android has the finger (its Settings app added it with a touch of
    /// it): apps and the lock screen recognize it. The others are Avo's
    /// only, and Android does not recognize them.
    public var enrolled: Bool

    public init(id: Int, name: String, enrolled: Bool = true) {
        self.id = id
        self.name = name
        self.enrolled = enrolled
    }

    private enum CodingKeys: String, CodingKey { case id, name, enrolled }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        // Saved before Avo kept fingers of its own: every one was Android's.
        enrolled = try container.decodeIfPresent(Bool.self, forKey: .enrolled) ?? true
    }
}

/// Android's fingerprints and whether it can take a touch now
/// (`DaemonEvent.fingerprints`, `DaemonClient.fingerprints()`).
public struct FingerprintStatus: Codable, Equatable, Sendable {
    public enum Availability: String, Codable, Sendable {
        /// Android runs with a screen lock and a sensor Avo can touch.
        case ready
        /// Android is not running; `fingers` are the ones it had last.
        case androidStopped
        /// Android has no PIN, pattern or password, and takes fingerprints only with one.
        case noScreenLock
        /// This Android has no fingerprint sensor Avo can drive (that takes
        /// AOSP's virtual sensor on a userdebug image, as Cuttlefish has).
        case unsupported
    }

    /// Android takes no fingerprint for now after too many tries.
    public enum Lockout: String, Codable, Sendable {
        case none
        /// For about 30 seconds.
        case timed
        /// Until its PIN, pattern or password is entered.
        case permanent
    }

    public var availability: Availability
    /// Avo's fingers; `enrolled` says which ones Android has.
    public var fingers: [Fingerprint]
    public var lockout: Lockout
    /// Android wants its PIN, pattern or password before it takes a
    /// fingerprint (once after it starts, among other times).
    public var credentialRequired: Bool
    /// What asks for a finger now; nil when nothing does.
    public var request: FingerprintRequest?

    /// The fingers Avo keeps: those of two hands.
    public static let maximumFingers = 10
    /// Android's own limit per user (the sensor's `max_enrollments`): its
    /// Settings app adds no fingerprint past it.
    public static let androidMaximum = 5

    public init(availability: Availability, fingers: [Fingerprint] = [], lockout: Lockout = .none,
                credentialRequired: Bool = false, request: FingerprintRequest? = nil) {
        self.availability = availability
        self.fingers = fingers
        self.lockout = lockout
        self.credentialRequired = credentialRequired
        self.request = request
    }

    public static let androidStopped = FingerprintStatus(availability: .androidStopped)

    /// Fingers can be added, renamed and removed (while Android is stopped too).
    public var canEdit: Bool { availability != .unsupported }

    /// Android's Settings app is adding a fingerprint: a touch adds that finger.
    public var enrolling: Bool { request?.purpose == .enroll }

    /// A touch can reach Android now (it may still find nothing asking).
    public var canTouch: Bool { availability == .ready && lockout == .none && !credentialRequired }

    public func finger(_ id: Int) -> Fingerprint? { fingers.first { $0.id == id } }
}

/// Something in Android waiting for a finger on the sensor.
public struct FingerprintRequest: Codable, Equatable, Sendable {
    public enum Purpose: String, Codable, Sendable {
        /// An app's BiometricPrompt, or the lock screen.
        case authenticate
        /// Android's Settings app adds a fingerprint: the finger that
        /// touches the sensor is the one it adds.
        case enroll
    }

    public var purpose: Purpose
    /// The package that asked (`lockScreenPackage` for the lock screen).
    public var package: String

    public init(purpose: Purpose, package: String) {
        self.purpose = purpose
        self.package = package
    }

    /// SystemUI asks for the lock screen (and the keyguard's bouncer).
    public static let lockScreenPackage = "com.android.systemui"

    public var isLockScreen: Bool { package == Self.lockScreenPackage }
}

/// What touching the sensor did (`DaemonClient.touchFingerprint`).
public enum FingerprintTouchResult: String, Codable, Sendable {
    /// Android recognized the finger: the app or the lock screen takes it.
    case recognized
    /// Android did not recognize it ("Not recognized").
    case notRecognized
    /// The touch added the finger to Android (its Settings app was adding a fingerprint).
    case enrolled
    /// Too many tries: Android takes no fingerprint for now (`FingerprintStatus.lockout`).
    case lockedOut
    /// Android wants its PIN, pattern or password before a fingerprint.
    case credentialRequired
    /// Nothing in Android asked for a fingerprint.
    case nobodyAsked
    /// The sensor was touched, but Android said nothing Avo could read.
    case touched
}

/// Why a fingerprint change was refused (`AvoError.fingerprint`).
public enum FingerprintProblem: Error, Codable, Equatable, Sendable, LocalizedError {
    case emptyName
    case nameTooLong(maximum: Int)
    case invalidName
    case duplicateName(String)
    case tooManyFingers(maximum: Int)
    case unsupported
    case unknownFinger
    /// Android's Settings adds the finger that touches the sensor, which has
    /// to be one of Avo's.
    case unregisteredFinger
    /// Android's Settings was asked to add a finger it has already.
    case alreadyInAndroid(String)
    case androidRefused(String)

    public var message: String {
        switch self {
        case .emptyName:
            String(localized: "Give the finger a name.", bundle: .avoKit)
        case .nameTooLong(let maximum):
            String(localized: "Use a shorter name (up to \(maximum) characters).", bundle: .avoKit)
        case .invalidName:
            String(localized: "A finger’s name can’t contain line breaks or other control characters.", bundle: .avoKit)
        case .duplicateName(let name):
            String(localized: "A finger named “\(name)” is already registered.", bundle: .avoKit)
        case .tooManyFingers(let maximum):
            String(localized: "Avo keeps up to \(maximum) fingers. Remove one first.", bundle: .avoKit)
        case .unsupported:
            String(localized: "This Android has no fingerprint sensor Avo can use.", bundle: .avoKit)
        case .unknownFinger:
            String(localized: "That finger is no longer registered.", bundle: .avoKit)
        case .unregisteredFinger:
            String(localized: "Android’s Settings adds the finger that touches the sensor. Choose one of your fingers.", bundle: .avoKit)
        case .alreadyInAndroid(let name):
            String(localized: "Android already has “\(name)”. Choose another finger to add.", bundle: .avoKit)
        case .androidRefused(let detail):
            String(localized: "Android did not take the change: \(detail)", bundle: .avoKit)
        }
    }

    public var errorDescription: String? { message }
}

/// Finger names as Avo takes them.
public enum FingerprintName {
    /// Long enough for "Left ring finger (work gloves)", short enough for a menu.
    public static let maximumLength = 40

    /// `name` without surrounding spaces, or why it cannot be used. `fingers`
    /// are the ones registered now; `renaming` is the finger being renamed,
    /// whose own name does not count as taken.
    public static func validated(_ name: String, among fingers: [Fingerprint], renaming id: Int? = nil)
        -> Result<String, FingerprintProblem> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyName) }
        guard trimmed.count <= maximumLength else { return .failure(.nameTooLong(maximum: maximumLength)) }
        // Android's Settings and the menus show one line.
        guard !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            return .failure(.invalidName)
        }
        if let taken = finger(named: trimmed, among: fingers, except: id) {
            return .failure(.duplicateName(taken.name))
        }
        if id == nil, fingers.count >= FingerprintStatus.maximumFingers {
            return .failure(.tooManyFingers(maximum: FingerprintStatus.maximumFingers))
        }
        return .success(trimmed)
    }

    /// The finger (other than `id`) whose name is `name`, ignoring case,
    /// accents and surrounding spaces.
    public static func finger(named name: String, among fingers: [Fingerprint], except id: Int? = nil) -> Fingerprint? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return fingers.first { finger in
            finger.id != id && finger.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(wanted, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
        }
    }

    /// Ready-made names for Settings › Fingerprints, thumbs and index
    /// fingers first.
    public static var suggestions: [String] {
        [
            String(localized: "Right thumb", bundle: .avoKit),
            String(localized: "Right index finger", bundle: .avoKit),
            String(localized: "Left thumb", bundle: .avoKit),
            String(localized: "Left index finger", bundle: .avoKit),
            String(localized: "Right middle finger", bundle: .avoKit),
            String(localized: "Left middle finger", bundle: .avoKit),
            String(localized: "Right ring finger", bundle: .avoKit),
            String(localized: "Left ring finger", bundle: .avoKit),
            String(localized: "Right little finger", bundle: .avoKit),
            String(localized: "Left little finger", bundle: .avoKit),
        ]
    }

    /// The suggestions no registered finger is named yet.
    public static func unusedSuggestions(among fingers: [Fingerprint]) -> [String] {
        suggestions.filter { finger(named: $0, among: fingers) == nil }
    }
}

/// Opens the Control Panel at one of its panes from another Avo process (an
/// app window's Manage Fingerprints…): `avo-control-panel://fingerprints`,
/// opened with Avo.app itself, which registers the scheme. An app's page in
/// the Library (an app window's All Settings…) is `avo-control-panel://app/<package>`.
public enum ControlPanelLink {
    public static let scheme = "avo-control-panel"
    /// Settings › Fingerprints.
    public static let fingerprintsPane = "fingerprints"
    /// Not a pane: Check for Updates… from the menu bar item.
    public static let checkForUpdates = "check-for-updates"
    /// Not a pane: an app's page, its package the path.
    public static let appPageHost = "app"

    public static func url(pane: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = pane
        return components.url!
    }

    /// The pane a link names; nil for any other URL.
    public static func pane(in url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, let host = url.host(), !host.isEmpty else { return nil }
        return host.lowercased()
    }

    public static func url(appPage package: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = appPageHost
        components.path = "/" + package
        return components.url!
    }

    /// The package whose page a link names; nil for any other URL. Package
    /// names keep their case.
    public static func appPage(in url: URL) -> String? {
        guard pane(in: url) == appPageHost else { return nil }
        let package = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return package.isEmpty || package.contains("/") ? nil : package
    }
}
