import Foundation

/// A device identity template (spec §8, "Mock nama sistem").
///
/// Templates live as JSON files in `profiles/devices/` so the community can
/// add devices through pull requests. The engine applies `properties` at
/// boot; changing the profile needs a VM restart.
///
/// The default (`avo`) is Avo's honest identity. Every other template makes
/// apps read another device's `Build.*` fields: impersonation, which does not
/// and cannot pass hardware attestation, and the UI says so. Whichever is
/// chosen, Avo still states what it is (`AvoIdentity`).
public struct DeviceProfile: Codable, Identifiable, Equatable, Sendable {
    public struct Display: Codable, Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var dpi: Int
    }

    /// Avo's honest identity, the default for new installs.
    public static let defaultID = "avo-virtual-device"
    /// The user-editable profile.
    public static let customID = "custom"

    /// The honest identity (profiles/devices/avo-virtual-device.json; the
    /// daemon falls back to this copy). Android derives the build
    /// fingerprint from brand, name and device with the image's own release,
    /// build ID, incremental, type and tags (`fingerprint(image:)`), so it
    /// stays true for every image: `Avo/avo_droid/avo_droid:17/…:userdebug/test-keys`.
    public static let avo = DeviceProfile(
        id: defaultID, name: "Avo (AVO-Droid)",
        properties: [
            "ro.product.brand": "Avo",
            "ro.product.manufacturer": "Avo",
            "ro.product.model": "AVO-Droid",
            "ro.product.name": "avo_droid",
            "ro.product.device": "avo_droid",
        ],
        notes: "Default, and Avo's honest identity: apps see a device made by Avo, model AVO-Droid. Brand, name and device say Avo too, and Android derives the build fingerprint from them with the image's own release, build ID, incremental, type and tags, so it is valid and true for every image. Board, hardware and SoC stay the image's (AOSP Cuttlefish), because they describe the virtual hardware Android runs on. Avo also states what it is on every boot whichever profile is chosen (ro.boot.avo.* and the com.avodroid.feature.MAC system feature): see docs/for-game-developers.md.")

    /// Properties every impersonation template must define.
    public static let requiredProperties = [
        "ro.product.brand",
        "ro.product.manufacturer",
        "ro.product.model",
        "ro.product.device",
        "ro.build.fingerprint",
    ]

    /// What the honest identity must say about itself. Its fingerprint is
    /// Android's own derivation, never written down.
    public static let avoRequiredProperties = [
        "ro.product.brand",
        "ro.product.manufacturer",
        "ro.product.model",
        "ro.product.name",
        "ro.product.device",
    ]

    /// The `ro.product.*` fields that name the device (`Build.BRAND`,
    /// `MANUFACTURER`, `MODEL`, `PRODUCT`, `DEVICE`), also per partition
    /// (`ro.product.vendor.model`).
    public static let productFields = ["brand", "manufacturer", "model", "name", "device"]
    static let productPartitions = ["system", "system_ext", "product", "vendor", "odm", "bootimage",
                                    "vendor_dlkm", "odm_dlkm", "system_dlkm"]
    /// What Android builds the fingerprint from: brand/name/device.
    static let fingerprintFields: Set<String> = ["ro.product.brand", "ro.product.name", "ro.product.device"]

    /// The build properties a template may set besides `ro.product.<field>`.
    public static let buildProperties: Set<String> = [
        "ro.build.fingerprint", "ro.build.description", "ro.build.product", "ro.build.display.id",
        "ro.build.version.incremental", "ro.build.id", "ro.build.tags", "ro.build.type", "ro.build.flavor",
        "ro.soc.manufacturer", "ro.soc.model",
    ]

    /// A partition's own build names, as a phone has them: its system image
    /// often comes from another brand (Qualcomm's QSSI, "Transsion/tssi/...")
    /// than its vendor one. Not the vendor partition's: Avo's guest patches
    /// bind only on the image's `ro.vendor.build.fingerprint`.
    public static let partitionBuildProperties: Set<String> = Set(buildPartitions.flatMap { partition in
        ["fingerprint", "id", "version.incremental"].map { "ro.\(partition).build.\($0)" }
    })

    /// Security state, debuggability and verified boot; the hardware
    /// (`ro.hardware*` picks init scripts, graphics and audio drivers) and
    /// everything else that is not identity is rejected too.
    public static let forbiddenProperties: Set<String> = [
        "ro.debuggable", "ro.secure", "ro.adb.secure", "ro.boot.verifiedbootstate",
        "ro.boot.flash.locked", "ro.boot.vbmeta.device_state", "ro.build.selinux", "ro.hardware",
    ]

    /// Whether a template may set `key`: the device's names and build
    /// strings only. ABI lists, API levels, hardware drivers and Avo's own
    /// `ro.boot.avo.*` markers are not identity.
    public static func isIdentityProperty(_ key: String) -> Bool {
        if buildProperties.contains(key) || partitionBuildProperties.contains(key) { return true }
        guard key.hasPrefix("ro.product.") else { return false }
        let parts = key.dropFirst("ro.product.".count).split(separator: ".", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return productFields.contains(String(parts[0]))
        case 2: return productPartitions.contains(String(parts[0])) && productFields.contains(String(parts[1]))
        default: return false
        }
    }

    public var schema: Int
    public var id: String
    public var name: String
    public var properties: [String: String]
    public var display: Display?
    /// The SoC, CPU and GPU this profile reports when "Emulate this phone's
    /// hardware" is on (`DeviceHardware`). Nil, or absent from the JSON, means
    /// the profile changes only the device's name and build strings.
    public var hardware: DeviceHardware?
    public var notes: String?

    public init(schema: Int = 1, id: String, name: String, properties: [String: String],
                display: Display? = nil, hardware: DeviceHardware? = nil, notes: String? = nil) {
        self.schema = schema
        self.id = id
        self.name = name
        self.properties = properties
        self.display = display
        self.hardware = hardware
        self.notes = notes
    }

    /// Whether this profile has hardware to emulate (any of SoC, CPU, GPU, memory).
    public var hasHardware: Bool {
        guard let hardware else { return false }
        return hardware.soc != nil || hardware.cpu != nil || !(hardware.gpu?.isEmpty ?? true) || hardware.memoryGB != nil
    }

    /// The identity properties, plus the hardware ones and the phone's whole
    /// build identity (`buildIdentityProperties`) when `emulateHardware` is
    /// on. The identity always wins, so a profile that sets `ro.soc.model` or
    /// `ro.build.id` itself keeps it. The engine writes this at boot (`AvoIdentity`).
    public func properties(emulateHardware: Bool) -> [String: String] {
        guard emulateHardware, let hardware else { return properties }
        return properties.merging(hardware.bootProperties()) { identity, _ in identity }
            .merging(buildIdentityProperties()) { identity, _ in identity }
    }

    /// Partitions whose build names follow the phone. Not `vendor`: Avo's
    /// guest patches (GuestComposer, GuestVulkanWrapper) bind only on the
    /// image's own `ro.vendor.build.fingerprint`, so it stays the image's.
    static let buildPartitions = productPartitions.filter { $0 != "vendor" }

    /// What a real phone says about its build everywhere, from the profile's
    /// fingerprint (`brand/name/device:release/id/incremental:type/tags`):
    /// `Build.ID`, `Build.VERSION.INCREMENTAL`, `Build.DISPLAY`, the build
    /// description and flavor, each partition's fingerprint, ID and
    /// incremental, and each partition's product names, which otherwise stay
    /// the image's ("aosp_cf_arm64_only_phone", "Cuttlefish arm64 phone").
    /// `ro.build.type` and `ro.build.tags` stay the image's (userdebug, test
    /// keys): that is how Android really runs. Empty for Avo's identity and
    /// a profile without a valid fingerprint.
    public func buildIdentityProperties() -> [String: String] {
        guard !isAvoIdentity, let fingerprint = properties["ro.build.fingerprint"],
              Self.isValidFingerprint(fingerprint) else { return [:] }
        let parts = fingerprint.split(separator: ":").map { $0.split(separator: "/").map(String.init) }
        let (name, release, id, incremental, type, tags) = (parts[0][1], parts[1][0], parts[1][1], parts[1][2], parts[2][0], parts[2][1])
        let description = "\(name)-\(type) \(release) \(id) \(incremental) \(tags)"
        var out = [
            "ro.build.id": id,
            "ro.build.version.incremental": incremental,
            "ro.build.description": description,
            // AOSP's own rule: a release build shows its ID, others the description.
            "ro.build.display.id": type == "user" && tags == "release-keys" ? id : description,
            "ro.build.flavor": "\(name)-\(type)",
        ]
        for partition in Self.buildPartitions {
            out["ro.\(partition).build.fingerprint"] = fingerprint
            out["ro.\(partition).build.id"] = id
            out["ro.\(partition).build.version.incremental"] = incremental
        }
        for partition in Self.productPartitions {
            for field in Self.productFields {
                if let value = properties["ro.product.\(field)"] { out["ro.product.\(partition).\(field)"] = value }
            }
        }
        return out
    }

    public var brand: String? { properties["ro.product.brand"] }
    public var model: String? { properties["ro.product.model"] }

    /// The honest identity; every other template impersonates a device.
    public var isAvoIdentity: Bool { id == Self.defaultID }

    /// Problems that make the template unusable.
    public func validate() -> [String] {
        var problems: [String] = []
        if schema != 1 { problems.append("unsupported schema \(schema)") }
        if id.isEmpty || id.contains(where: { !($0.isLetter || $0.isNumber || $0 == "-") }) {
            problems.append("id must contain only letters, digits and '-'")
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("name is empty") }
        let required = isAvoIdentity ? Self.avoRequiredProperties : Self.requiredProperties
        for key in required where (properties[key] ?? "").isEmpty {
            problems.append("missing \(key)")
        }
        if isAvoIdentity, properties["ro.build.fingerprint"] != nil {
            problems.append("ro.build.fingerprint is Android's own derivation for this profile")
        }
        for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
            if Self.forbiddenProperties.contains(key) {
                problems.append("\(key) may not be overridden")
            } else if !Self.isIdentityProperty(key) {
                problems.append("\(key) is not an identity property")
            }
            // Property values are limited to 91 bytes (PROP_VALUE_MAX - 1) for non-ro props;
            // ro.* may be longer but must stay on one line.
            if value.contains(where: \.isNewline) { problems.append("\(key) contains a newline") }
            if Self.fingerprintFields.contains(key), value.isEmpty || value.contains(where: { $0 == " " || $0 == "/" || $0 == ":" }) {
                problems.append("\(key) is part of the build fingerprint: no spaces, '/' or ':'")
            }
        }
        for (key, fingerprint) in properties.sorted(by: { $0.key < $1.key })
        where key.hasSuffix("build.fingerprint") && !Self.isValidFingerprint(fingerprint) {
            problems.append("\(key) must look like brand/product/device:release/id/incremental:type/tags")
        }
        if let display {
            if display.width < 240 || display.height < 240 { problems.append("display is too small") }
            if !VMConfig.dpiRange.contains(display.dpi) { problems.append("display dpi out of range") }
        }
        if let hardware { problems.append(contentsOf: hardware.validate()) }
        return problems
    }

    /// `brand/product/device:release/id/incremental:type/tags`
    public static func isValidFingerprint(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        let head = parts[0].split(separator: "/", omittingEmptySubsequences: false)
        let middle = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        let tail = parts[2].split(separator: "/", omittingEmptySubsequences: false)
        return head.count == 3 && middle.count == 3 && tail.count == 2
            && (head + middle + tail).allSatisfy { !$0.isEmpty && !$0.contains(" ") }
    }

    /// `Build.FINGERPRINT` with this profile on an image whose own
    /// fingerprint is `image`: the profile's, else what Android's init
    /// derives (`brand/name/device`, the profile's where it sets them, then
    /// the image's `release/id/incremental:type/tags`). Nil for an invalid `image`.
    public func fingerprint(image: String) -> String? {
        if let own = properties["ro.build.fingerprint"] { return own }
        guard Self.isValidFingerprint(image), let colon = image.firstIndex(of: ":") else { return nil }
        let head = image[..<colon].split(separator: "/").map(String.init)
        let names = zip(["brand", "name", "device"], head).map { properties["ro.product.\($0)"] ?? $1 }
        return names.joined(separator: "/") + image[colon...]
    }

    /// Property file applied by the guest at boot (`key=value` lines, sorted).
    /// The engine adds Avo's markers (`AvoIdentity.propertyFile`).
    public func propertyFile() -> String {
        properties.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)\n" }.joined()
    }
}

/// Loads templates from a directory of JSON files.
public struct DeviceProfileCatalog: Sendable {
    public private(set) var profiles: [DeviceProfile]
    public private(set) var rejected: [(file: String, problems: [String])]

    public init(profiles: [DeviceProfile]) {
        self.profiles = profiles
        self.rejected = []
    }

    public init(directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var profiles: [DeviceProfile] = []
        var rejected: [(String, [String])] = []
        let decoder = JSONDecoder()
        for file in files {
            do {
                let profile = try decoder.decode(DeviceProfile.self, from: Data(contentsOf: file))
                let problems = profile.validate()
                if problems.isEmpty, file.deletingPathExtension().lastPathComponent == profile.id {
                    profiles.append(profile)
                } else {
                    rejected.append((file.lastPathComponent, problems.isEmpty ? ["file name must match id"] : problems))
                }
            } catch {
                rejected.append((file.lastPathComponent, ["invalid JSON: \(error.localizedDescription)"]))
            }
        }
        // The honest identity is always there, the default for new installs.
        if !profiles.contains(where: \.isAvoIdentity) { profiles.append(.avo) }
        // The honest default first, then alphabetical by name.
        self.profiles = profiles.sorted {
            if $0.id == DeviceProfile.defaultID { return true }
            if $1.id == DeviceProfile.defaultID { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        self.rejected = rejected
    }

    public func profile(id: String) -> DeviceProfile? {
        profiles.first { $0.id == id }
    }
}
