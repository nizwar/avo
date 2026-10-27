import AvoIO
import AvoKit
import Foundation
import os

/// Everything an engine needs to boot Android.
public struct EngineLaunch: Sendable {
    public var config: VMConfig
    public var paths: AvoPaths
    public var image: AndroidImage
    /// Path of the BootConfig disk written for this boot.
    public var bootConfigDisk: URL
    /// Quick-boot snapshot to restore, when one matches this configuration.
    public var restoreSnapshot: URL?
    /// The device identity to boot with (also inside the BootConfig disk).
    public var profile: DeviceProfile?
    /// The refresh rate of every Android display this boot (FrameRates.androidRate).
    public var displayRate: Int
    /// Android's own screen, display 0 (VMConfig.androidScreen).
    public var androidScreen: DisplayRequest

    public init(config: VMConfig, paths: AvoPaths, image: AndroidImage, bootConfigDisk: URL, restoreSnapshot: URL? = nil,
                profile: DeviceProfile? = nil, displayRate: Int = FrameRates.standardRate,
                androidScreen: DisplayRequest = DisplayRequest(width: 720, height: 1280, dpi: 320)) {
        self.config = config
        self.paths = paths
        self.image = image
        self.bootConfigDisk = bootConfigDisk
        self.restoreSnapshot = restoreSnapshot
        self.profile = profile
        self.displayRate = displayRate
        self.androidScreen = androidScreen
    }
}

/// The VM engine as seen by the daemon. Production uses `CrosvmEngine`
/// (crosvm with the Hypervisor.framework backend); tests use a fake.
public protocol VMEngine: AnyObject, Sendable {
    var name: String { get }
    /// Boots the VM and returns once the engine accepts vsock connections.
    func start(_ launch: EngineLaunch) async throws
    /// Asks Android to shut down cleanly, then ends the engine.
    func stop() async
    /// Writes a quick-boot snapshot of the running VM.
    func snapshot(to url: URL) async throws
    /// Opens a stream to a vsock port inside the guest.
    func connect(port: UInt32) async throws -> any ByteStream
    /// The same as a blocking socket the caller owns (for splicing to a
    /// TCP client, see ADBForwarder).
    func connectSocket(port: UInt32) async throws -> Int32
    /// Yields once when the engine exits; nil for a clean shutdown.
    var exits: AsyncStream<(any Error)?> { get }
}

/// An engine that can pause Android: its vCPUs stop and its clock stands
/// still, and it goes on where it was (avo-vmm's `pause` / `resume`,
/// engine/hvf/vmm/src/pause.rs). VMManager pauses and wakes it.
public protocol PausableEngine: VMEngine {
    /// Returns once no vCPU runs Android's code.
    func pause() async throws
    /// `pausedFor`: how long Android stood still (its wall clock is set right after).
    func resume(pausedFor: Duration) async throws
    /// What the engine is doing now, for Pause When Idle and the menu bar.
    func activity() async -> EngineActivity
    /// What to call when something the engine hands out itself (fingerprints,
    /// Google apps, the unlock) is about to use a paused Android.
    func onUse(_ wake: @escaping @Sendable () async -> Void)
}

/// An engine that tells when Android itself stops answering while the
/// engine runs on (VMStatus.notRespondingSince).
public protocol ResponsivenessEngine: VMEngine {
    /// Nil while Android answers, else since when it has not.
    var responsiveness: AsyncStream<Date?> { get }
}

public struct EngineActivity: Sendable, Equatable {
    /// Android plays sound, or records from the microphone.
    public var playing: Bool
    public var recording: Bool
    /// CPU time the engine process used since it started, and its memory.
    public var cpuTime: Duration?
    public var residentBytes: UInt64?

    public init(playing: Bool = false, recording: Bool = false, cpuTime: Duration? = nil, residentBytes: UInt64? = nil) {
        self.playing = playing
        self.recording = recording
        self.cpuTime = cpuTime
        self.residentBytes = residentBytes
    }
}

/// An engine exit because Android asked for a factory reset (avo-vmm's
/// EXIT_FACTORY_RESET): the daemon erases the data and starts Android again.
public struct AndroidFactoryReset: Error, Equatable {
    public init() {}
}

/// An engine exit because Android rebooted itself (avo-vmm's
/// EXIT_GUEST_REBOOT): the daemon starts it again, as a new boot.
public struct AndroidRebooted: Error, Equatable {
    public init() {}
}

extension VMEngine {
    public func connectSocket(port: UInt32) async throws -> Int32 {
        throw AvoError.internalError("\(name) cannot hand out guest sockets")
    }
}

/// crosvm with Avo's Hypervisor.framework backend, run as a child process.
///
/// The command line below is the contract between the daemon and the
/// crosvm-hvf port (docs/engine.md). Until that port exists in a release,
/// `Avo.app/Contents/MacOS/crosvm` is absent and `start` reports
/// `AvoError.engineMissing`.
public final class CrosvmEngine: VMEngine, @unchecked Sendable {
    public let name = "crosvm-hvf"
    public let executable: URL
    public let exits: AsyncStream<(any Error)?>
    private let exitSink: AsyncStream<(any Error)?>.Continuation
    private let lock = NSLock()
    private var process: Process?
    private var launch: EngineLaunch?
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "crosvm")

    public init(executable: URL) {
        self.executable = executable
        (exits, exitSink) = AsyncStream.makeStream(of: (any Error)?.self)
    }

    /// `crosvm run` arguments for a launch. Pure, so the contract is testable.
    public static func arguments(for launch: EngineLaunch) -> [String] {
        let config = launch.config
        let image = launch.image
        let paths = launch.paths
        var args = ["run", "--name", "avo"]
        args += ["--cpus", "num-cores=\(config.cpuCount)"]
        args += ["--mem", "size=\(config.memoryMiB)"]
        if config.balloonWhenIdle {
            // Free page reporting returns guest memory to macOS while idle.
            args += ["--balloon-page-reporting"]
        } else {
            args += ["--no-balloon"]
        }
        for partition in image.partitions {
            args += ["--block", "path=\(image.url(partition).path),ro=true,id=\(Self.blockID(partition))"]
        }
        let overlay = config.rooted ? image.overlayRooted : image.overlayStock
        args += ["--block", "path=\(image.url(overlay).path),ro=true,id=avo_overlay"]
        args += ["--block", "path=\(paths.dataDisk.path),id=userdata"]
        args += ["--block", "path=\(launch.bootConfigDisk.path),ro=true,id=avo_config"]
        let vulkan = config.renderer == .vulkan
        args += ["--gpu", "backend=gfxstream,gles=true,vulkan=\(vulkan),context-types=gfxstream-gles:gfxstream-vulkan:gfxstream-composer"]
        // macOS has no AF_VSOCK: the hvf port bridges guest ports to this Unix socket.
        args += ["--vsock", "cid=3,uds-path=\(paths.vsockSocket.path)"]
        args += ["--virtio-snd", "backend=coreaudio,num_input_devices=1,num_output_devices=1"]
        args += ["--socket", paths.engineControlSocket.path]
        args += ["--serial", "type=file,path=\(paths.logs.appending(path: "android-console.log").path),hardware=virtio-console,console=true"]
        if let initrd = image.initrd { args += ["--initrd", image.url(initrd).path] }
        if let snapshot = launch.restoreSnapshot { args += ["--restore", snapshot.path] }
        args += ["--params", "androidboot.hardware=avo androidboot.avo.config=/dev/block/by-name/avo_config"]
        args.append(image.url(image.kernel).path)
        return args
    }

    static func blockID(_ file: String) -> String {
        String(file.split(separator: ".").first ?? Substring(file))
    }

    public func start(_ launch: EngineLaunch) async throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw AvoError.engineMissing }
        try launch.paths.validateSocketPaths()
        try? FileManager.default.removeItem(at: launch.paths.vsockSocket)
        try? FileManager.default.removeItem(at: launch.paths.engineControlSocket)

        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(for: launch)
        let log = launch.paths.logs.appending(path: "crosvm.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        process.standardOutput = logHandle
        process.standardError = logHandle
        let sink = exitSink
        process.terminationHandler = { [logger] process in
            try? logHandle.close()
            let clean = process.terminationReason == .exit && process.terminationStatus == 0
            logger.notice("crosvm exited with status \(process.terminationStatus)")
            sink.yield(clean ? nil : AvoError.vmStartFailed(String(localized: "The VM engine exited with status \(Int(process.terminationStatus)).", bundle: .avoKit)))
        }
        do {
            try process.run()
        } catch {
            throw AvoError.vmStartFailed(error.localizedDescription)
        }
        lock.withLock {
            self.process = process
            self.launch = launch
        }

        // Ready when the vsock bridge socket accepts connections.
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            guard process.isRunning else { throw AvoError.vmStartFailed(String(localized: "The VM engine stopped while starting; see \(log.path).", bundle: .avoKit)) }
            if let fd = try? UnixSocket.connect(path: launch.paths.vsockSocket.path) {
                close(fd)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        process.terminate()
        throw AvoError.timedOut("crosvm startup")
    }

    public func stop() async {
        guard let (process, launch) = lock.withLock({ self.process.flatMap { p in self.launch.map { (p, $0) } } }) else { return }
        // Power button first so Android shuts down and flushes the data disk.
        _ = try? await runControl(["powerbtn", launch.paths.engineControlSocket.path])
        for _ in 0..<200 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning { _ = try? await runControl(["stop", launch.paths.engineControlSocket.path]) }
        for _ in 0..<50 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning { process.terminate() }
        lock.withLock { self.process = nil }
    }

    public func snapshot(to url: URL) async throws {
        guard let launch = lock.withLock({ self.launch }) else { throw AvoError.vmNotRunning }
        try await runControl(["snapshot", "take", "--compress", url.path, launch.paths.engineControlSocket.path])
    }

    public func connect(port: UInt32) async throws -> any ByteStream {
        guard let launch = lock.withLock({ self.launch }) else { throw AvoError.vmNotRunning }
        return try VsockBridge.connect(socketPath: launch.paths.vsockSocket.path, port: port)
    }

    public func connectSocket(port: UInt32) async throws -> Int32 {
        guard let launch = lock.withLock({ self.launch }) else { throw AvoError.vmNotRunning }
        return try VsockBridge.connectSocket(socketPath: launch.paths.vsockSocket.path, port: port)
    }

    @discardableResult
    private func runControl(_ arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
