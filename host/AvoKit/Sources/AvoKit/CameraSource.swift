import Foundation

/// What one of Android's cameras shows (Settings › Devices › Cameras).
///
/// While both cameras are emulated, Android has the image's own emulated
/// back and front cameras. Any other choice gives it cameras the daemon feeds
/// (avo-vmm `--cameras`, camera.rs; CameraFeed): one of this Mac's cameras,
/// or, for an emulated one, a scene the daemon draws. Which cameras Android
/// has is set when it starts; what each one shows changes at once.
public enum CameraSource: Hashable, Sendable {
    /// A scene drawn for it.
    case emulated
    /// One of this Mac's cameras (`AVCaptureDevice.uniqueID`).
    case mac(String)
    /// None: Android does not have this camera.
    case none

    public var macCameraID: String? {
        if case .mac(let id) = self { return id }
        return nil
    }
}

extension CameraSource: Codable {
    /// `emulated`, `none`, or `mac:<unique ID>`.
    public var rawValue: String {
        switch self {
        case .emulated: "emulated"
        case .none: "none"
        case .mac(let id): "mac:" + id
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "emulated": self = .emulated
        case "none": self = .none
        case let value where value.hasPrefix("mac:") && value.count > 4: self = .mac(String(value.dropFirst(4)))
        default: return nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let source = CameraSource(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown camera source \(raw)"))
        }
        self = source
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension VMConfig {
    /// The back camera first, as avo-vmm numbers them (0 back, 1 front);
    /// none while cameras are off.
    public var cameraSources: [CameraSource] { camerasEnabled ? [backCamera, frontCamera] : [.none, .none] }

    /// avo-vmm's `--cameras`: none while both cameras are the image's
    /// emulated ones, else the cameras Android has.
    public var cameraFlags: [String] {
        let sources = cameraSources
        if sources == [.emulated, .emulated] { return [] }
        let present = zip(["back", "front"], sources).filter { $0.1 != .none }.map(\.0)
        return ["--cameras", present.isEmpty ? "none" : present.joined(separator: ",")]
    }
}
