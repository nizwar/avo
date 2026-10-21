import AvoKit
import Foundation

// GPU rendering for avo-vmm (docs/engine.md, "GPU (gfxstream)"): which
// gfxstream to load, whether to try it, and when a GPU boot has failed so
// Android falls back to software. Everything here except the monitor is
// pure, so VMMEngine's state machine is tested through it.

/// The Android Emulator install whose gfxstream libraries avo-vmm loads at
/// run time. Avo never ships them (Android SDK licence); our own build of
/// gfxstream replaces this later.
public struct AndroidEmulator: Equatable, Sendable {
    /// The directory with `source.properties` and `lib64/`.
    public var directory: URL
    /// `Pkg.Revision`, e.g. 37.1.11.
    public var version: String
    /// `Pkg.BuildId`, when the file has one.
    public var build: String?

    /// The first version whose gfxstream avo-vmm was tested with (37.1.11).
    public static let minimumMajorVersion = 37

    /// What avo-vmm loads, relative to the directory; a missing one means
    /// an incomplete install rather than an old one.
    static let requiredFiles = [
        "lib64/libgfxstream_backend.dylib",
        "lib64/libemugl_common.dylib",
        "lib64/vulkan/libvulkan.dylib",
        "lib64/vulkan/libMoltenVK.dylib",
        "lib64/vulkan/MoltenVK_icd.json",
    ]

    public enum Lookup: Equatable, Sendable {
        case found(AndroidEmulator)
        case missing
        case unsupported(version: String)
    }

    /// The emulator Android Studio's SDK Manager installs, or `override`
    /// (`defaults write dev.avo.daemon AvoAndroidEmulator <dir>`) instead.
    public static func lookup(home: URL,
                              override: String? = UserDefaults.standard.string(forKey: "AvoAndroidEmulator")) -> Lookup {
        if let override, !override.isEmpty { return inspect(URL(filePath: override, directoryHint: .isDirectory)) }
        return inspect(home.appending(path: "Library/Android/sdk/emulator", directoryHint: .isDirectory))
    }

    /// The emulator's netsimd (Root Canal inside), Android's Bluetooth
    /// controller (`--bluetooth`, engine/hvf/vmm/src/bluetooth.rs). Any
    /// version will do: avo-vmm only uses its HCI port.
    public static func netsimd(home: URL,
                               override: String? = UserDefaults.standard.string(forKey: "AvoAndroidEmulator")) -> URL? {
        let directory = override.flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? home.appending(path: "Library/Android/sdk/emulator", directoryHint: .isDirectory)
        let netsimd = directory.appending(path: "netsimd")
        return FileManager.default.isExecutableFile(atPath: netsimd.path) ? netsimd : nil
    }

    public static func inspect(_ directory: URL) -> Lookup {
        guard let text = try? String(contentsOf: directory.appending(path: "source.properties"), encoding: .utf8),
              let (version, build) = revision(sourceProperties: text) else { return .missing }
        let major = version.split(separator: ".").first.flatMap { Int($0) } ?? 0
        guard major >= minimumMajorVersion else { return .unsupported(version: version) }
        let files = FileManager.default
        guard requiredFiles.allSatisfy({ files.fileExists(atPath: directory.appending(path: $0).path) }) else { return .missing }
        return .found(AndroidEmulator(directory: directory, version: version, build: build))
    }

    /// `Pkg.Revision` and `Pkg.BuildId` from a `source.properties` file.
    static func revision(sourceProperties: String) -> (revision: String, build: String?)? {
        var values: [String: String] = [:]
        for line in sourceProperties.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard let revision = values["Pkg.Revision"], !revision.isEmpty else { return nil }
        return (revision, values["Pkg.BuildId"].flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// What one start of avo-vmm uses.
public enum GPUPlan: Equatable, Sendable {
    case gpu(AndroidEmulator)
    case software(RendererStatus.Reason, GPUFailure?)

    /// Software when asked for, without a usable emulator, or after a GPU
    /// failure recorded for this avo-vmm, emulator and macOS (`key`).
    public static func decide(mode: VMConfig.RendererMode, emulator: AndroidEmulator.Lookup,
                              fallback: GPUFallbackRecord?, key: String?) -> GPUPlan {
        if mode == .software { return .software(.chosen, nil) }
        switch emulator {
        case .missing: return .software(.emulatorMissing, nil)
        case .unsupported: return .software(.emulatorUnsupported, nil)
        case let .found(emulator):
            if let fallback, let key, fallback.key == key { return .software(.failed, fallback.failure) }
            return .gpu(emulator)
        }
    }

    public var isGPU: Bool {
        if case .gpu = self { true } else { false }
    }

    /// The status the Control Panel shows for this plan.
    public func status(requested: VMConfig.RendererMode, emulator: AndroidEmulator.Lookup?,
                       fallback: GPUFallbackRecord?) -> RendererStatus {
        let version: String? = switch emulator {
        case let .found(found)?: found.version
        case let .unsupported(version)?: version
        default: nil
        }
        switch self {
        case .gpu:
            return RendererStatus(mode: .gpu, requested: requested, reason: .chosen, emulatorVersion: version)
        case let .software(reason, failure):
            return RendererStatus(mode: .software, requested: requested, reason: reason, failure: failure,
                                  detail: reason == .failed ? fallback?.detail : nil, emulatorVersion: version)
        }
    }
}

/// A failed GPU boot, kept in ~/Library/Application Support/Avo/vm so later
/// starts use software without trying again. A record whose key no longer
/// matches (new avo-vmm, emulator or macOS) is ignored: one new attempt.
public struct GPUFallbackRecord: Codable, Equatable, Sendable {
    public var failure: GPUFailure
    public var detail: String?
    public var date: Date
    public var key: String

    public init(failure: GPUFailure, detail: String?, date: Date, key: String) {
        self.failure = failure
        self.detail = detail
        self.date = date
        self.key = key
    }

    static func url(_ paths: AvoPaths) -> URL { paths.vm.appending(path: "gpu-fallback.json") }

    public static func load(paths: AvoPaths) -> GPUFallbackRecord? {
        guard let data = try? Data(contentsOf: url(paths)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GPUFallbackRecord.self, from: data)
    }

    public func save(paths: AvoPaths) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: paths.vm, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Self.url(paths), options: .atomic)
    }

    public static func remove(paths: AvoPaths) {
        try? FileManager.default.removeItem(at: url(paths))
    }

    /// avo-vmm's size and modification time | the emulator's revision and
    /// build | the macOS version.
    public static func key(engine: URL, emulator: AndroidEmulator,
                           system: String = ProcessInfo.processInfo.operatingSystemVersionString) -> String {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: engine.path)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size):\(Int64(modified))|\(emulator.version):\(emulator.build ?? "")|\(system)"
    }
}

/// Judges one GPU boot from avo-vmm's `gpu` events (control.rs) and its
/// exit, from the moment its sockets accept connections until Android is ready.
/// Its time stands still while the Mac sleeps (SuspendingClock), as Android does.
public struct GPUBootWatch: Sendable {
    public enum Verdict: Equatable, Sendable {
        case started
        case failed(GPUFailure)
    }

    /// The first frame must come within this time of Android starting its
    /// graphics (`gpu context`: its first rendering context)...
    public static let firstFrameTimeout: Duration = .seconds(60)
    /// ...and Android must start them within this time of the sockets
    /// coming up. Until then the GPU has nothing to do: a first boot spends
    /// minutes there (ART's boot classpath, a new data file system).
    public static let graphicsStartTimeout: Duration = .seconds(600)
    /// avo-vmm's exit status when the GPU renderer is unavailable.
    public static let rendererUnavailableStatus: Int32 = 75

    public private(set) var deadline: SuspendingClock.Instant
    public private(set) var sawContext = false
    public private(set) var sawFirstFrame = false

    public init(now: SuspendingClock.Instant = .now) {
        deadline = now + Self.graphicsStartTimeout
    }

    /// nil for lines that say nothing about the boot (`gpu active`, others).
    public mutating func event(_ line: String, now: SuspendingClock.Instant = .now) -> Verdict? {
        if line.hasPrefix("gpu context"), !sawContext {
            sawContext = true
            deadline = now + Self.firstFrameTimeout
            return nil
        }
        if line.hasPrefix("gpu first-frame") {
            sawFirstFrame = true
            return .started
        }
        return line.hasPrefix("gpu stalled") ? .failed(.stalled) : nil
    }

    /// nil for an exit that is not the GPU's doing (see `failure`).
    public func exited(status: Int32, bySignal: Bool) -> Verdict? {
        Self.failure(exitStatus: status, bySignal: bySignal).map { .failed($0) }
    }

    public func check(now: SuspendingClock.Instant) -> Verdict? {
        !sawFirstFrame && now >= deadline ? .failed(.noFrames) : nil
    }

    /// The GPU's part in an exit of avo-vmm (main.rs, cuttlefish.rs): 75 when
    /// the renderer cannot start (a panic while it loads ends up there too),
    /// and a signal when gfxstream crashes the process. Every other status is
    /// avo-vmm's own: 0 a power off, 1 an error (the instance in use by
    /// another VM, its disks), 76 a factory reset, 101 a panic of its main
    /// thread. Those are reported as they are and never turn the GPU off.
    static func failure(exitStatus: Int32, bySignal: Bool) -> GPUFailure? {
        if bySignal { return .crashed }
        return exitStatus == rendererUnavailableStatus ? .initFailed : nil
    }
}

/// Crashes after Android was ready on the GPU: the second within 10
/// minutes makes later starts use software.
public struct GPUCrashHistory: Sendable {
    public static let window: TimeInterval = 600
    private var last: Date?

    public init() {}

    public mutating func crashed(at date: Date) -> Bool {
        defer { last = date }
        guard let last else { return false }
        return date.timeIntervalSince(last) <= Self.window
    }
}

/// An engine that remembers GPU crashes (VMMEngine): "Try GPU Again" and a
/// Renderer change forget them along with the fallback record, so the next
/// crash is a first one again.
public protocol GPUFallbackEngine: VMEngine {
    func forgetGPUCrashes()
}

/// One GPU launch of avo-vmm, fed by the event pump, a once-a-second check
/// and the process's termination handler (on their own threads). Exactly
/// one of them gets a failure, so the fallback runs once.
final class GPUBootMonitor: @unchecked Sendable {
    enum Phase {
        /// Launched, sockets not up yet: `start` sees an exit itself.
        case starting
        case booting(GPUBootWatch)
        case running
        /// The engine is replacing this launch with a software one.
        case fallingBack
        /// `stop()`: exits are reported as they are without GPU.
        case stopped
    }

    enum ExitAction: Equatable {
        /// Report the exit through `exits`; `crashedRunning` when avo-vmm
        /// crashed (`GPUBootWatch.failure`) after Android was ready on the GPU.
        case forward(crashedRunning: Bool)
        case fallBack(GPUFailure)
        case ignore
    }

    private let lock = NSLock()
    private var phase = Phase.starting

    /// The sockets accept connections: the boot watch starts.
    func booted(now: SuspendingClock.Instant = .now) {
        lock.withLock {
            if case .starting = phase { phase = .booting(GPUBootWatch(now: now)) }
        }
    }

    /// The process failed the GPU before its sockets came up (`start`
    /// claims only such exits); false when the engine already stopped or
    /// replaced this launch.
    func claimStartFailure() -> Bool {
        lock.withLock {
            guard case .starting = phase else { return false }
            phase = .fallingBack
            return true
        }
    }

    func line(_ line: String, now: SuspendingClock.Instant = .now) -> GPUFailure? {
        lock.withLock {
            guard case var .booting(watch) = phase else { return nil }
            let verdict = watch.event(line, now: now)
            phase = .booting(watch)
            guard case let .failed(failure)? = verdict else { return nil }
            phase = .fallingBack
            return failure
        }
    }

    func check(now: SuspendingClock.Instant = .now) -> GPUFailure? {
        lock.withLock {
            guard case let .booting(watch) = phase, case let .failed(failure)? = watch.check(now: now) else { return nil }
            phase = .fallingBack
            return failure
        }
    }

    /// Between the sockets coming up and Android being ready, with no
    /// failure yet: the once-a-second check runs only then.
    var isBooting: Bool {
        lock.withLock {
            if case .booting = phase { true } else { false }
        }
    }

    /// Android is ready: later problems are crashes, not failed boots.
    func ready() {
        lock.withLock {
            if case .booting = phase { phase = .running }
        }
    }

    func stop() {
        lock.withLock { phase = .stopped }
    }

    /// A failure was claimed: a software launch replaces this one.
    var hasFallenBack: Bool {
        lock.withLock {
            if case .fallingBack = phase { true } else { false }
        }
    }

    var isStopped: Bool {
        lock.withLock {
            if case .stopped = phase { true } else { false }
        }
    }

    func exited(status: Int32, bySignal: Bool) -> ExitAction {
        lock.withLock {
            let failure = GPUBootWatch.failure(exitStatus: status, bySignal: bySignal)
            switch phase {
            case .starting, .fallingBack:
                return .ignore
            case .booting:
                guard let failure else { return .forward(crashedRunning: false) }
                phase = .fallingBack
                return .fallBack(failure)
            case .running:
                return .forward(crashedRunning: failure != nil)
            case .stopped:
                return .forward(crashedRunning: false)
            }
        }
    }
}
