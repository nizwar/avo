import Foundation

/// Errors that cross process boundaries (XPC) and reach the UI.
public enum AvoError: Error, Codable, Equatable, Sendable, LocalizedError {
    case vmNotRunning
    case vmStartFailed(String)
    case engineMissing
    case imageMissing
    case guestUnavailable
    case guestIncompatible(String)
    case installFailed(String)
    case unsupportedPackage(String)
    case packageNotFound(String)
    case displayUnavailable(String)
    case invalidConfiguration([String])
    case unauthorizedCaller
    case daemonUnreachable(String)
    case socketPathTooLong(String)
    case timedOut(String)
    case internalError(String)
    /// Android's screen lock keeps it locked: apps open once it is unlocked
    /// (`VMStatus.screenLock`).
    case androidLocked
    /// Android did not take the screen lock's credential. `throttled`: after
    /// too many wrong ones it takes none for a while.
    case screenLockRejected(throttled: Bool)
    /// A fingerprint change Avo or Android refused (Fingerprints.swift).
    case fingerprint(FingerprintProblem)
    /// Android's data cannot be used where it is (StorageLocation.swift).
    case storage(StorageProblem)
    /// Translate Screen's engine did not translate (ScreenTextRequests.swift).
    case translation(TranslationProblem)

    public var errorDescription: String? {
        switch self {
        case .vmNotRunning: String(localized: "Android is not running.", bundle: .avoKit)
        case .vmStartFailed(let detail): String(localized: "Android could not start: \(detail)", bundle: .avoKit)
        case .engineMissing: String(localized: "The VM engine is not installed in this build of Avo.", bundle: .avoKit)
        case .imageMissing: String(localized: "The Android image has not been downloaded yet.", bundle: .avoKit)
        case .guestUnavailable: String(localized: "Android did not respond.", bundle: .avoKit)
        case .guestIncompatible(let detail): detail
        case .installFailed(let detail): String(localized: "Installation failed: \(detail)", bundle: .avoKit)
        case .unsupportedPackage(let detail): String(localized: "This file cannot be installed: \(detail)", bundle: .avoKit)
        case .packageNotFound(let package): String(localized: "\(package) is not installed.", bundle: .avoKit)
        case .displayUnavailable(let detail): String(localized: "The app window could not be opened: \(detail)", bundle: .avoKit)
        case .invalidConfiguration(let issues): issues.joined(separator: "\n")
        case .unauthorizedCaller: String(localized: "The caller is not allowed to talk to the Avo daemon.", bundle: .avoKit)
        case .daemonUnreachable(let detail): String(localized: "Avo’s background service is not reachable (\(detail)).", bundle: .avoKit)
        case .socketPathTooLong(let path): String(localized: "Socket path is too long: \(path)", bundle: .avoKit)
        case .timedOut(let operation): String(localized: "\(operation) timed out.", bundle: .avoKit)
        case .internalError(let detail): detail
        case .androidLocked: String(localized: "Android is locked by its screen lock. Unlock it in Avo to open your apps.", bundle: .avoKit)
        case .screenLockRejected(throttled: false): String(localized: "That’s not Android’s screen lock. Try again.", bundle: .avoKit)
        case .screenLockRejected(throttled: true):
            String(localized: "Too many wrong tries. Android accepts the next one in about a minute.", bundle: .avoKit)
        case .fingerprint(let problem): problem.message
        case .storage(let problem): problem.message
        case .translation(let problem): problem.message
        }
    }
}
