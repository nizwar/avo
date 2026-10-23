import Foundation

// Checkpoints (Settings › Android › Checkpoints): restore points of Android's
// data, kept beside it (`<data>/checkpoints/<id>/`, CheckpointStore in the
// daemon). Each is an APFS clone of AvoPaths.portableDataItems: made in a
// moment, and taking space only as Android's data changes after it.

/// One restore point of Android's apps and data.
public struct Checkpoint: Codable, Equatable, Sendable, Identifiable {
    /// Why it was made: by the user, or by Avo before a change to Android
    /// that cannot be taken back otherwise.
    public enum Reason: String, Codable, Sendable {
        case manual
        /// Root access turned on (Magisk changes Android's boot and data).
        case root
        case googleApps
        case googleAppsRemoval
        /// Another device profile, or its hardware emulated or no longer.
        case deviceProfile
        /// The first start of another Android version (`detail`: which), which
        /// upgrades the data for good.
        case androidVersion
        /// Another checkpoint restored over this data.
        case restore
    }

    public var id: UUID
    public var createdAt: Date
    public var reason: Reason
    /// The user's name for a manual checkpoint; the Android version for `androidVersion`.
    public var detail: String?
    /// The newest Android that used the data then (`Android 17`).
    public var android: String?
    /// The settings that belong with the data then; a restore sets them again.
    public var settings: CheckpointSettings

    public init(id: UUID = UUID(), createdAt: Date = Date(), reason: Reason, detail: String? = nil, android: String? = nil,
                settings: CheckpointSettings) {
        self.id = id
        self.createdAt = createdAt
        self.reason = reason
        self.detail = detail
        self.android = android
        self.settings = settings
    }

    /// Made by Avo (kept up to `CheckpointStatus.automaticLimit`); a manual
    /// one stays until the user deletes it.
    public var isAutomatic: Bool { reason != .manual }

    /// What the list shows.
    public var title: String {
        switch reason {
        case .manual:
            if let detail, !detail.isEmpty { return detail }
            return String(localized: "Checkpoint", bundle: .avoKit)
        case .root: return String(localized: "Before turning on root", bundle: .avoKit)
        case .googleApps: return String(localized: "Before installing Google apps", bundle: .avoKit)
        case .googleAppsRemoval: return String(localized: "Before removing Google apps", bundle: .avoKit)
        case .deviceProfile: return String(localized: "Before changing the device profile", bundle: .avoKit)
        case .androidVersion:
            if let detail { return String(localized: "Before starting \(detail)", bundle: .avoKit) }
            return String(localized: "Before starting another Android version", bundle: .avoKit)
        case .restore: return String(localized: "Before restoring a checkpoint", bundle: .avoKit)
        }
    }
}

/// The settings that describe Android's data rather than this Mac: a data
/// disk from before root, Google apps or another phone's identity starts
/// again as it was then.
public struct CheckpointSettings: Codable, Equatable, Sendable {
    public var rooted: Bool
    public var gms: VMConfig.GMSMode
    public var deviceProfileID: String
    public var emulateHardware: Bool

    public init(rooted: Bool, gms: VMConfig.GMSMode, deviceProfileID: String, emulateHardware: Bool) {
        self.rooted = rooted
        self.gms = gms
        self.deviceProfileID = deviceProfileID
        self.emulateHardware = emulateHardware
    }

    public init(_ config: VMConfig) {
        self.init(rooted: config.rooted, gms: config.gms, deviceProfileID: config.deviceProfileID,
                  emulateHardware: config.emulateHardware)
    }

    /// `config` with these settings.
    public func applied(to config: VMConfig) -> VMConfig {
        var config = config
        config.rooted = rooted
        config.gms = gms
        config.deviceProfileID = deviceProfileID
        config.emulateHardware = emulateHardware
        return config
    }
}

/// Settings › Android › Checkpoints.
public struct CheckpointStatus: Codable, Equatable, Sendable {
    /// Newest first.
    public var checkpoints: [Checkpoint]
    /// Why none can be made where Android's data is now (a drive that is
    /// not APFS), or nil.
    public var problem: String?

    /// Automatic checkpoints kept; the oldest goes when a new one is made.
    public static let automaticLimit = 5

    public init(checkpoints: [Checkpoint] = [], problem: String? = nil) {
        self.checkpoints = checkpoints
        self.problem = problem
    }
}
