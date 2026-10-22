import Foundation

/// How Avo identifies itself to Android apps (docs/for-game-developers.md):
/// read-only properties under one namespace on every boot, and a system
/// feature where Avo can add it to Android. Both are there whichever device
/// profile the user picked, so a phone profile changes `Build.*` but never
/// hides Avo from an app that checks.
///
/// Versioned by `schema`. A later schema only adds properties or input
/// kinds; the meaning of what is here does not change.
public enum AvoIdentity {
    /// The version of this scheme: `ro.boot.avo.schema` and the feature's version.
    public static let schema = 1

    /// `PackageManager.hasSystemFeature(feature)`, like Google Play Games on
    /// PC's `com.google.android.play.feature.HPE_EXPERIENCE`.
    public static let feature = "\(AvoIdentifiers.prefix).feature.MAC"

    /// `ro.boot.*` is what the boot loader, here Avo's VM engine, tells
    /// Android about the platform. The same names work whether the engine
    /// passes them as boot parameters (`androidboot.avo.*`, like the crosvm
    /// contract's `androidboot.avo.config`) or in its properties file, and
    /// they have a context of their own (`bootloader_prop`) that SELinux
    /// lets every process read. An unlisted `ro.avo.*` would fall into the
    /// catch-all `default_prop`, which vendor processes may not read.
    public static let propertyPrefix = "ro.boot.avo."

    /// Where the feature is declared (`permissionsFile`): a file Android's
    /// SystemConfig reads when the framework starts.
    public static let permissionsPath = "/product/etc/permissions/\(AvoIdentifiers.prefix).feature.mac.xml"
    /// The file of the builds before 0.3.0 Preview 2 (`dev.avo.feature.MAC`),
    /// taken out where the new one goes in (IdentityFeature).
    public static let formerPermissionsPath = "/product/etc/permissions/\(AvoIdentifiers.formerPrefix).feature.mac.xml"

    /// What renders Android this boot (Graphics › Renderer, after any fallback).
    public enum Renderer: String, Sendable, Equatable, CaseIterable {
        /// The Mac's GPU through gfxstream (Vulkan and GLES on Metal).
        case gpu
        /// SwiftShader on the Mac's CPU.
        case software
    }

    /// How the player controls apps, in `ro.boot.avo.input` order.
    public enum Input: String, Sendable, Equatable, CaseIterable {
        /// A hardware keyboard: Android gets key events from Avo's virtual keyboard.
        case keyboard
        /// The Mac's mouse or trackpad. Android has no mouse device: clicks,
        /// drags and the wheel arrive as touches, and in Game Mode with FPS
        /// controls Avo captures the pointer and turns its motion into
        /// camera drags.
        case mouse
        /// Touches Avo synthesizes, from the mouse and from key mappings.
        case touch
        /// An Xbox-compatible controller (045e:02ea), plugged into Android
        /// while a game controller connected to the Mac drives it.
        case gamepad
    }

    /// The facts Avo states at boot.
    public struct Markers: Sendable, Equatable {
        /// Avo's version (`CFBundleShortVersionString`).
        public var version: String
        /// `macOS 27.0.1`.
        public var hostOS: String
        /// `Apple M4 Pro`.
        public var hostChip: String
        public var renderer: Renderer
        public var input: [Input]

        public init(version: String, hostOS: String, hostChip: String, renderer: Renderer,
                    input: [Input] = Input.allCases) {
            self.version = version
            self.hostOS = hostOS
            self.hostChip = hostChip
            self.renderer = renderer
            self.input = input
        }

        /// This Mac, now.
        public static func current(version: String, renderer: Renderer) -> Markers {
            Markers(version: version, hostOS: AvoIdentity.hostOS(ProcessInfo.processInfo.operatingSystemVersion),
                    hostChip: AvoIdentity.hostChip(), renderer: renderer)
        }

        /// The `ro.boot.avo.*` properties.
        public var properties: [String: String] {
            [
                propertyPrefix + "schema": "\(AvoIdentity.schema)",
                propertyPrefix + "version": AvoIdentity.value(version),
                propertyPrefix + "host.os": AvoIdentity.value(hostOS),
                propertyPrefix + "host.chip": AvoIdentity.value(hostChip),
                propertyPrefix + "renderer": renderer.rawValue,
                propertyPrefix + "input": input.map(\.rawValue).joined(separator: ","),
            ]
        }
    }

    /// `macOS 27.0.1`: the name, then major, minor and patch.
    public static func hostOS(_ version: OperatingSystemVersion) -> String {
        "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// The chip's marketing name (`machdep.cpu.brand_string`, "Apple M4 Pro").
    public static func hostChip() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return value(String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    /// Longest value `__system_property_get` returns whole (PROP_VALUE_MAX - 1).
    public static let maxValueBytes = 91

    /// A property value every reader takes as is: printable ASCII on one
    /// line (anything else becomes `?`), single spaces, at most
    /// `maxValueBytes`; `unknown` when nothing is left.
    public static func value(_ text: String) -> String {
        var out = ""
        var space = false
        for scalar in text.unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                space = !out.isEmpty
                continue
            }
            if space { out.append(" ") }
            space = false
            out.unicodeScalars.append(scalar.isASCII && scalar.value >= 0x21 && scalar.value < 0x7f ? scalar : "?")
        }
        if out.utf8.count > maxValueBytes { out = String(out.prefix(maxValueBytes)).trimmingCharacters(in: .whitespaces) }
        return out.isEmpty ? "unknown" : out
    }

    /// The properties file the engine applies at boot (`key=value` lines,
    /// sorted): the profile's identity, the profile's hardware when
    /// `emulateHardware` is on (SoC and GPU; `DeviceHardware`), then Avo's
    /// markers. Profiles cannot set `ro.boot.*` (`DeviceProfile.validate()`),
    /// so the markers always win.
    public static func propertyFile(profile: DeviceProfile?, markers: Markers, emulateHardware: Bool = false) -> String {
        var properties = profile?.properties(emulateHardware: emulateHardware) ?? [:]
        properties.merge(markers.properties) { _, marker in marker }
        return properties.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)\n" }.joined()
    }

    /// The permissions file that declares `feature` (SystemConfig's format).
    public static var permissionsFile: String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <!-- Avo runs Android apps on a Mac. See docs/for-game-developers.md in the Avo repository. -->
        <permissions>
            <feature name="\(feature)" version="\(schema)" />
        </permissions>

        """
    }
}
