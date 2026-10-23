import AvoKit
import AvoProtocol
import CryptoKit
import Foundation

/// The daemon's list of installed apps (spec: the daemon is the single source
/// of truth on the Mac). Contents follow the guest's AppInstalled/AppRemoved
/// events and ListApps; host-side state (shims, aliases) is kept alongside.
public actor AppRegistry {
    private let paths: AvoPaths
    private var apps: [String: AppRecord] = [:]

    public init(paths: AvoPaths) {
        self.paths = paths
        if let data = try? Data(contentsOf: paths.registry),
           let records = try? AvoXPC.decode([AppRecord].self, from: data) {
            apps = Dictionary(records.map { ($0.package, $0) }, uniquingKeysWith: { _, last in last })
        }
    }

    public func all() -> [AppRecord] {
        apps.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func record(_ package: String) -> AppRecord? { apps[package] }

    /// Updates a record from the guest's description, keeping host-side state.
    @discardableResult
    public func apply(_ info: Avo_V1_AppInfo) -> (record: AppRecord, iconChanged: Bool, labelChanged: Bool) {
        let previous = apps[info.package]
        var record = previous ?? AppRecord(package: info.package, label: info.label)
        let labelChanged = previous == nil || previous?.label != info.label
        record.label = info.label
        record.versionName = info.versionName
        record.versionCode = info.versionCode
        record.sizeBytes = info.sizeBytes > 0 ? info.sizeBytes : record.sizeBytes
        record.installedAt = info.firstInstallTimeMs > 0 ? Date(timeIntervalSince1970: Double(info.firstInstallTimeMs) / 1000) : record.installedAt
        record.updatedAt = info.lastUpdateTimeMs > 0 ? Date(timeIntervalSince1970: Double(info.lastUpdateTimeMs) / 1000) : record.updatedAt
        record.systemApp = info.systemApp
        record.launchable = info.launchable
        record.installer = info.installerPackage.isEmpty ? nil : info.installerPackage
        // Only Android's answer says; an APK read on the Mac or a bare listing keeps what it said.
        if info.hasGame {
            record.isGame = info.game
            record.orientation = switch info.orientation {
            case .portrait, .reversePortrait: .portrait
            case .landscape, .reverseLandscape: .landscape
            default: nil
            }
        }

        var iconChanged = false
        if let png = Self.iconPNG(info) {
            let digest = Self.digest(info)
            if digest != record.iconDigest || !FileManager.default.fileExists(atPath: paths.icon(for: info.package).path) {
                try? FileManager.default.createDirectory(at: paths.icons, withIntermediateDirectories: true)
                try? png.write(to: paths.icon(for: info.package), options: .atomic)
                record.iconDigest = digest
                iconChanged = true
            }
        }
        apps[info.package] = record
        save()
        return (record, iconChanged, labelChanged)
    }

    public func update(_ record: AppRecord) {
        apps[record.package] = record
        save()
    }

    @discardableResult
    public func remove(_ package: String) -> AppRecord? {
        let removed = apps.removeValue(forKey: package)
        try? FileManager.default.removeItem(at: paths.icon(for: package))
        save()
        return removed
    }

    /// Drops records for apps the guest no longer has (after ListApps at boot).
    public func retain(only packages: Set<String>) -> [AppRecord] {
        let gone = apps.values.filter { !packages.contains($0.package) }
        for record in gone { remove(record.package) }
        return gone
    }

    public func icon(for package: String) -> Data? {
        try? Data(contentsOf: paths.icon(for: package))
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all()) else { return }
        try? FileManager.default.createDirectory(at: paths.applicationSupport, withIntermediateDirectories: true)
        try? data.write(to: paths.registry, options: .atomic)
    }

    /// The icon shown in the Control Panel grid: the flattened launcher icon.
    static func iconPNG(_ info: Avo_V1_AppInfo) -> Data? {
        if !info.iconPng.isEmpty { return info.iconPng }
        if info.hasAdaptiveIcon, !info.adaptiveIcon.foregroundPng.isEmpty { return info.adaptiveIcon.foregroundPng }
        return nil
    }

    static func digest(_ info: Avo_V1_AppInfo) -> String {
        var hasher = SHA256()
        hasher.update(data: info.iconPng)
        hasher.update(data: info.adaptiveIcon.backgroundPng)
        hasher.update(data: info.adaptiveIcon.foregroundPng)
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
