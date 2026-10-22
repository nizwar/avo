import AvoKit
import CryptoKit
import Foundation

/// An installed Android image: `images/<version>/manifest.json` plus the files
/// it lists. Images are downloaded at first setup, versioned separately from
/// the macOS app, and verified (SHA-256 per file, Ed25519 signature over the
/// manifest) before use.
public struct AndroidImage: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public var name: String
        public var sha256: String
        public var size: Int64
    }

    public var schema: Int
    public var version: String
    /// API level of the image (36 for Android 16).
    public var sdk: Int
    public var kernel: String
    public var initrd: String?
    /// Read-only partitions in attach order (system, vendor, …).
    public var partitions: [String]
    /// Overlay for /system: stock, and KernelSU-rooted (spec §7).
    public var overlayStock: String
    public var overlayRooted: String
    public var files: [File]

    /// Where the image lives; not part of the manifest.
    public var directory: URL = URL(filePath: "/")

    private enum CodingKeys: String, CodingKey {
        case schema, version, sdk, kernel, initrd, partitions
        case overlayStock = "overlay_stock", overlayRooted = "overlay_rooted", files
    }

    public func url(_ name: String) -> URL { directory.appending(path: name) }

    public static let manifestName = "manifest.json"
    public static let signatureName = "manifest.json.sig"

    /// Loads the newest valid image under `paths.images` (or a custom location).
    public static func installed(in root: URL) throws -> AndroidImage {
        let versions = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let images = versions.compactMap { try? load(from: $0) }
        guard let newest = images.max(by: { $0.version.compare($1.version, options: .numeric) == .orderedAscending }) else {
            throw AvoError.imageMissing
        }
        return newest
    }

    public static func load(from directory: URL) throws -> AndroidImage {
        var image = try JSONDecoder().decode(AndroidImage.self, from: Data(contentsOf: directory.appending(path: manifestName)))
        image.directory = directory
        guard image.schema == 1 else { throw AvoError.internalError("unsupported image schema \(image.schema)") }
        return image
    }

    /// Verifies the manifest signature with Avo's release key, then every file's size and hash.
    public func verify(publicKey: Curve25519.Signing.PublicKey) throws {
        let manifest = try Data(contentsOf: url(Self.manifestName))
        let signature = try Data(contentsOf: url(Self.signatureName))
        guard publicKey.isValidSignature(signature, for: manifest) else {
            throw AvoError.internalError(String(localized: "The Android image signature is invalid.", bundle: .avoKit))
        }
        let referenced = Set([kernel, initrd, overlayStock, overlayRooted].compactMap { $0 } + partitions)
        let listed = Set(files.map(\.name))
        guard referenced.isSubset(of: listed) else {
            throw AvoError.internalError(String(localized: "The image manifest does not cover \(referenced.subtracting(listed).sorted().joined(separator: ", ")).",
                                                       bundle: .avoKit))
        }
        for file in files {
            guard !file.name.contains("/") && !file.name.hasPrefix(".") else {
                throw AvoError.internalError(String(localized: "Invalid file name in image manifest: \(file.name)", bundle: .avoKit))
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url(file.name).path)
            guard (attributes[.size] as? NSNumber)?.int64Value == file.size else {
                throw AvoError.internalError(String(localized: "\(file.name) has the wrong size.", bundle: .avoKit))
            }
            guard try Self.sha256(of: url(file.name)) == file.sha256.lowercased() else {
                throw AvoError.internalError(String(localized: "\(file.name) failed its checksum.", bundle: .avoKit))
            }
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Per-boot settings handed to the guest on a small read-only disk
/// (`avo_config`): the ADB keys it should trust, the device profile, root and
/// GMS choices. Plain JSON padded with zeros to a 4 KiB multiple; read early
/// in boot by `avo_init` (guest/device/avo).
public struct BootConfig: Codable, Sendable, Equatable {
    public var schema = 1
    public var adbKeys: [String]
    public var deviceProfile: [String: String]
    public var deviceProfileID: String
    public var rooted: Bool
    public var gms: VMConfig.GMSMode
    public var locale: String
    public var timeZone: String
    public var defaultDensity: Int?

    private enum CodingKeys: String, CodingKey {
        case schema, adbKeys = "adb_keys", deviceProfile = "device_profile", deviceProfileID = "device_profile_id"
        case rooted, gms, locale, timeZone = "time_zone", defaultDensity = "default_density"
    }

    public init(adbKeys: [String], profile: DeviceProfile?, config: VMConfig, density: Int? = nil,
                locale: Locale = .current, timeZone: TimeZone = .current) {
        self.adbKeys = adbKeys
        // With hardware emulation on, the profile's SoC and GPU properties go
        // with the identity (the engine applies them before anything reads).
        self.deviceProfile = profile?.properties(emulateHardware: config.emulateHardware) ?? [:]
        self.deviceProfileID = profile?.id ?? DeviceProfile.defaultID
        self.rooted = config.rooted
        self.gms = config.gms
        self.locale = locale.identifier(.bcp47)
        self.timeZone = timeZone.identifier
        // Android's own screen's (VMConfig.androidScreen).
        self.defaultDensity = density
    }

    public func diskImage() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        let block = 4096
        data.append(Data(count: (block - data.count % block) % block))
        return data
    }

    public func write(to url: URL) throws {
        try diskImage().write(to: url, options: .atomic)
    }
}
