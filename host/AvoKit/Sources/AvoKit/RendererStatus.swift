import Foundation

extension VMConfig {
    /// Graphics › Renderer: how avo-vmm draws Android (docs/engine.md, "GPU").
    public enum RendererMode: String, Codable, CaseIterable, Sendable {
        /// The GPU through gfxstream (Avo's own build, or an Android
        /// Emulator's), software rendering when there is none.
        case auto
        /// The same as `auto`, but a missing renderer is shown prominently.
        case gpu
        /// Software rendering in Android on the CPU, always (today's engine).
        case software
    }

    /// Settings › Graphics: the highest OpenGL ES version apps get, to test
    /// an app against a weaker phone's GPU. 3.2 (the default) is everything
    /// the Mac's GPU has, short of geometry shaders, which Metal lacks
    /// (docs/engine.md, "GPU"); the lower ones are what the gfxstream sync
    /// layer holds ANGLE to (debug.avo.gl.max, from the next GPU start).
    public enum GLESVersion: String, Codable, CaseIterable, Sendable {
        case v2_0 = "2.0"
        case v3_0 = "3.0"
        case v3_1 = "3.1"
        case v3_2 = "3.2"

        /// What `ro.opengles.version` says: major and minor in one number
        /// (`0x30002` is 3.2).
        public var androidVersion: Int {
            switch self {
            case .v2_0: return 0x2_0000
            case .v3_0: return 0x3_0000
            case .v3_1: return 0x3_0001
            case .v3_2: return 0x3_0002
            }
        }
    }
}

/// Why a GPU boot was given up; the fallback to software is kept until
/// "Try GPU Again", a Renderer change, or a new avo-vmm, emulator or macOS.
public enum GPUFailure: String, Codable, Sendable, CustomStringConvertible {
    /// avo-vmm exited with status 75: the library, a symbol, or the
    /// renderer's init failed before Android started.
    case initFailed
    /// avo-vmm stopped while Android was starting on the GPU.
    case crashed
    /// No frame came from the GPU within a minute of boot.
    case noFrames
    /// A GPU fence stayed pending while Android was starting (`gpu stalled`).
    case stalled
    /// Android crashed twice within 10 minutes after it had started on the GPU.
    case crashedTwice

    public var description: String {
        switch self {
        case .initFailed: String(localized: "The GPU renderer could not start.", bundle: .avoKit)
        case .crashed: String(localized: "Android stopped while starting on the GPU.", bundle: .avoKit)
        case .noFrames: String(localized: "Android showed nothing on the GPU within a minute.", bundle: .avoKit)
        case .stalled: String(localized: "The GPU stopped responding while Android started.", bundle: .avoKit)
        case .crashedTwice: String(localized: "Android stopped twice within 10 minutes while using the GPU.", bundle: .avoKit)
        }
    }
}

/// How Android renders right now (`VMStatus.renderer`), from the daemon.
public struct RendererStatus: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case gpu
        case software
    }

    /// Why the mode was picked.
    public enum Reason: String, Codable, Sendable {
        /// The Renderer setting asked for it (and the emulator was found for GPU).
        case chosen
        /// No GPU renderer (neither Avo's nor an Android Emulator's): software rendering.
        case emulatorMissing
        /// The Android Emulator is older than GPU rendering needs.
        case emulatorUnsupported
        /// GPU rendering failed (`failure` says how): software rendering.
        case failed
    }

    public var mode: Mode
    public var requested: VMConfig.RendererMode
    public var reason: Reason?
    public var failure: GPUFailure?
    /// The GPU's name once the renderer is up (`gpu active`), or what went wrong.
    public var detail: String?
    /// The Android Emulator's `Pkg.Revision`, when one was found.
    public var emulatorVersion: String?

    public init(mode: Mode, requested: VMConfig.RendererMode, reason: Reason? = nil, failure: GPUFailure? = nil,
                detail: String? = nil, emulatorVersion: String? = nil) {
        self.mode = mode
        self.requested = requested
        self.reason = reason
        self.failure = failure
        self.detail = detail
        self.emulatorVersion = emulatorVersion
    }

    private enum CodingKeys: String, CodingKey {
        case mode, requested, reason, failure, detail, emulatorVersion
    }

    /// Values a newer daemon may send decode to something this version
    /// shows (software, no reason), so `VMStatus` never fails to decode.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func raw(_ key: CodingKeys) -> String? { (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil }
        mode = raw(.mode).flatMap(Mode.init(rawValue:)) ?? .software
        requested = raw(.requested).flatMap(VMConfig.RendererMode.init(rawValue:)) ?? .auto
        reason = raw(.reason).flatMap(Reason.init(rawValue:))
        failure = raw(.failure).flatMap(GPUFailure.init(rawValue:))
        detail = raw(.detail)
        emulatorVersion = raw(.emulatorVersion)
    }
}
