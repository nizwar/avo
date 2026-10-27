import AvoADB
import AvoIO
import AvoKit
import AvoProtocol
import Foundation
import os

/// An AOSP Cuttlefish build Avo can boot with avo-vmm
/// (scripts/fetch-cuttlefish.sh downloads one).
public enum CuttlefishImage {
    static let required = ["boot.img", "vendor_boot.img", "super.img", "vbmeta.img"]

    public static func isImage(_ directory: URL) -> Bool {
        required.allSatisfy { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
    }

    /// `override`, then `images/cuttlefish`, then the newest download in
    /// ~/Library/Caches/Avo/cuttlefish/<build>/img.
    public static func find(paths: AvoPaths, override: String? = nil) -> URL? {
        var candidates: [URL] = []
        if let override, !override.isEmpty { candidates.append(URL(filePath: override)) }
        candidates.append(paths.images.appending(path: "cuttlefish", directoryHint: .isDirectory))
        let cache = paths.home.appending(path: "Library/Caches/Avo/cuttlefish", directoryHint: .isDirectory)
        let builds = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        for build in builds.sorted(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }) {
            candidates.append(build.appending(path: "img", directoryHint: .isDirectory))
        }
        return candidates.first(where: isImage)
    }

    /// What VMManager needs to know about the image (no Avo manifest here).
    public static func androidImage(at directory: URL) -> AndroidImage {
        let build = (try? String(contentsOf: directory.deletingLastPathComponent().appending(path: "BUILD_ID"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AndroidImage(schema: 1, version: "cuttlefish-\(build ?? "local")", sdk: 0, kernel: "boot.img", initrd: nil,
                            partitions: [], overlayStock: "", overlayRooted: "", files: [], directory: directory)
    }
}

/// Avo's own VM engine (engine/hvf/vmm) booting a Cuttlefish image, with the
/// Bridge Agent's role played by `HostAgent`.
public final class VMMEngine: VMEngine, @unchecked Sendable {
    public let name = "avo-vmm"
    public let executable: URL
    public let images: URL
    public let exits: AsyncStream<(any Error)?>
    /// Frames for App Shim windows, in order; the daemon forwards them. A
    /// slow consumer skips presents, never anything else (FrameDeliveryQueue).
    public let frames: AsyncStream<FrameDelivery>
    /// Links Android apps open (Avo Links, see HostAgent's "Links"), already
    /// past `GuestLinkPolicy`: the daemon opens them with the Mac's default apps.
    public let links: AsyncStream<URL>
    /// GPU or software rendering, and why: once per start, and again when
    /// the GPU is up (`gpu active`) or a GPU boot falls back to software.
    public let renderer: AsyncStream<RendererStatus>
    /// Android's screen lock while it keeps Android locked (HostAgent's
    /// "Screen lock"), at every start and as it changes; ScreenLockEngine.
    public let screenLockUpdates: AsyncStream<AndroidScreenLock?>
    private let screenLockSink: AsyncStream<AndroidScreenLock?>.Continuation
    /// Whether Android itself still answers (HostAgent's "Answers"); ResponsivenessEngine.
    public let responsiveness: AsyncStream<Date?>
    private let responsivenessSink: AsyncStream<Date?>.Continuation
    private let exitSink: AsyncStream<(any Error)?>.Continuation
    private let frameQueue: FrameDeliveryQueue
    private let linkSink: AsyncStream<URL>.Continuation
    private let rendererSink: AsyncStream<RendererStatus>.Continuation
    private let adbKey: ADBKey
    private let lock = NSLock()
    private var process: Process?
    private var vsockPath: String?
    private var agent: HostAgent?
    private var control: EngineControl?
    private var tasks: [Task<Void, Never>] = []
    /// The cameras the Mac feeds (CameraFeed), when Android has them.
    private var cameras: CameraFeed?
    /// The running start, and whether it booted Magisk's init_boot (RootEngine).
    private var launched: EngineLaunch?
    private var bootedWithMagisk = false
    /// The Mac's location for Android's GPS (sent again after every start).
    private var location: LocationFix?
    /// System Status' samples of Android's processes (given to every start's agent).
    private var processSink: (@Sendable (GuestActivity.Sample) -> Void)?
    /// The GPU launch being watched, and a software relaunch replacing a
    /// failed one (see "GPU renderer" below).
    private var gpuMonitor: GPUBootMonitor?
    private var relaunch: Task<Void, Never>?
    private var rendererStatus: RendererStatus?
    private var gpuCrashes = GPUCrashHistory()
    /// This GPU launch runs Avo's Vulkan driver wrapper: a failure takes it
    /// out before the GPU is given up (GuestVulkanWrapper.Failure).
    private var vulkanWrapperRuns = false
    /// … and Avo's ANGLE wrapper (GuestGLESWrapper.Failure).
    private var glesWrapperRuns = false
    /// Android is paused (PausableEngine, "Pause" below), and its sound
    /// streams as the engine reports them (`sound playback|capture on|off`).
    private var paused = false
    private var playing = false
    private var recording = false
    private var wakeHandler: (@Sendable () async -> Void)?
    /// Avo's version, for `ro.boot.avo.version` (AvoIdentity).
    private let avoVersion: String
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "avo-vmm")

    public init(executable: URL, images: URL, adbKey: ADBKey, avoVersion: String = "dev") {
        self.executable = executable
        self.images = images
        self.adbKey = adbKey
        self.avoVersion = avoVersion
        (exits, exitSink) = AsyncStream.makeStream(of: (any Error)?.self)
        let frameQueue = FrameDeliveryQueue()
        self.frameQueue = frameQueue
        frames = AsyncStream(unfolding: { await frameQueue.next() }, onCancel: { frameQueue.finish() })
        (links, linkSink) = AsyncStream.makeStream(of: URL.self, bufferingPolicy: .bufferingNewest(16))
        (renderer, rendererSink) = AsyncStream.makeStream(of: RendererStatus.self, bufferingPolicy: .bufferingNewest(4))
        (screenLockUpdates, screenLockSink) = AsyncStream.makeStream(of: AndroidScreenLock?.self, bufferingPolicy: .bufferingNewest(8))
        (responsiveness, responsivenessSink) = AsyncStream.makeStream(of: Date?.self, bufferingPolicy: .bufferingNewest(4))
    }

    /// avo-vmm's exit when Android asked for a factory reset (cuttlefish.rs).
    public static let factoryResetStatus: Int32 = 76
    /// avo-vmm's exit when Android rebooted itself (`--exit-on-reboot`).
    public static let guestRebootStatus: Int32 = 77

    /// Arguments for a launch; pure, so the contract with avo-vmm is testable.
    /// Software adds nothing: avo-vmm then runs exactly as before GPU support.
    /// A reboot from inside Android (Restart, `adb reboot`) ends avo-vmm, and
    /// the daemon starts Android again: its start prepares every boot.
    public static func arguments(images: URL, launch: EngineLaunch, gpu: GPUPlan = .software(.chosen, nil),
                                 bluetooth: URL? = nil, initBoot: URL? = nil, host: HostInfo = .current()) -> [String] {
        let config = launch.config
        let paths = launch.paths
        var gpuFlags: [String] = []
        if case let .gpu(emulator) = gpu { gpuFlags = ["--gpu", "gfxstream", "--gfxstream-dir", emulator.directory.path] }
        // Android's data elsewhere (an external drive): the disks that belong
        // with it are there too; frames and logs stay on this Mac.
        let disks = paths.dataDisks.standardizedFileURL.path == paths.instance.standardizedFileURL.path
            ? [] : ["--disks", paths.dataDisks.path]
        // Display 0 is Android's own screen; app windows get their own displays.
        return ["cuttlefish", images.path,
                "--instance", paths.instance.path,
                "--runtime", paths.runtime.path,
                "--userdata", paths.dataDisk.path] + disks + [
                "--cpus", "\(config.cpuCount)",
                "--mem", "\(config.androidMemoryMiB(profile: launch.profile, host: host))",
                "--display", "\(launch.androidScreen.width)x\(launch.androidScreen.height)",
                "--density", "\(launch.androidScreen.dpi)",
                "--properties", identityFile(paths).path,
                "--exit-on-reboot"] + gpuFlags + sharedFolderFlags(config) + refreshRateFlags(launch.displayRate)
                + (bluetooth.map { ["--bluetooth", $0.path] } ?? [])
                + (initBoot.map { ["--init-boot", $0.path] } ?? [])
                + config.cameraFlags
                + (config.microphoneEnabled ? [] : ["--no-microphone"])
                + cpuFlags(launch) + hardwareFlags(launch)
    }

    /// "Emulate this phone's hardware": the profile's CPU for Android's
    /// cores (`DeviceHardware.CPU.fitted(to:)`), as avo-vmm presents it: each
    /// vCPU's MIDR and a cpufreq policy per cluster. Otherwise the Mac's cores.
    static func cpuFlags(_ launch: EngineLaunch) -> [String] {
        guard launch.config.emulateHardware, let cpu = launch.profile?.hardware?.cpu,
              let clusters = cpu.engineClusters(vcpus: launch.config.cpuCount) else { return [] }
        return ["--cpu-clusters", clusters]
    }

    /// "Emulate this phone's hardware": the phone's `Build.HARDWARE` ("qcom"
    /// on a Snapdragon) in place of the image's `cutf_cvm`. Otherwise none.
    static func hardwareFlags(_ launch: EngineLaunch) -> [String] {
        guard launch.config.emulateHardware, let name = launch.profile?.hardware?.soc?.buildHardware else { return [] }
        return ["--hardware", name]
    }

    /// Display 0's refresh rate, which every app display gets too (HostAgent):
    /// Android paces displays of different rates unevenly. 60 Hz is avo-vmm's own.
    static func refreshRateFlags(_ hz: Int) -> [String] {
        hz == FrameRates.standardRate ? [] : ["--refresh-rate", "\(hz)"]
    }

    /// Settings › Storage › Shared Folder (SharedFolderBridge.swift); a
    /// folder that is not there at the start makes avo-vmm leave it out.
    static func sharedFolderFlags(_ config: VMConfig) -> [String] {
        guard config.shareFolder, let path = config.sharedFolderPath, !path.isEmpty else { return [] }
        return ["--shared-dir", path]
    }

    /// The device profile's properties and Avo's `ro.boot.avo.*` markers,
    /// which avo-vmm hands to Android before anything reads them.
    static func identityFile(_ paths: AvoPaths) -> URL { paths.vm.appending(path: "identity.prop") }

    /// That file for a launch: written again for every avo-vmm process, so
    /// a software relaunch after a failed GPU boot says `software`.
    /// `vulkanWrapper` lets Android run Avo's Vulkan driver wrapper on a GPU
    /// start (GuestVulkanWrapper.switchProperty).
    /// Whether the image's ANGLE knows exposeES32ForTesting, which raises
    /// its cap to OpenGL ES 3.2 (both images Avo offers do: the Android 16's
    /// ANGLE, ab6a82e0ed, and the 17's, 8d8796935e4f). An ANGLE that lacks
    /// the feature merely ignores the name, and Android would promise 3.2
    /// contexts it cannot make, so nothing is written for such an image.
    static func exposesES32(image: AndroidImage?) -> Bool {
        (image?.sdk ?? 0) >= 36
    }

    /// An image this Mac has already seen refuse the promise: the sync layer
    /// read the image's renderer library and found no exposeES32ForTesting,
    /// and said so in the guest's logcat, where avo-vmm was listening and
    /// left this marker (`LogcatWatch` in cuttlefish.rs). The one boot that
    /// told Android 3.2 it could not make is the most it costs: from the
    /// next start of that image on, nothing is promised.
    static func es32Refuted(image: AndroidImage, paths: AvoPaths) -> Bool {
        let name = image.directory.lastPathComponent
        return FileManager.default.fileExists(atPath: paths.instance.appending(path: "es32-refuted-\(name)").path)
    }

    static func identityProperties(profile: DeviceProfile?, plan: GPUPlan, emulateHardware: Bool = false,
                                   vulkanWrapper: Bool = false, glesWrapper: Bool = false, gles: VMConfig.GLESVersion = .v3_2,
                                   es32Capable: Bool = false,
                                   markers: (AvoIdentity.Renderer) -> AvoIdentity.Markers) -> String {
        AvoIdentity.propertyFile(profile: profile, markers: markers(plan.isGPU ? .gpu : .software),
                                 emulateHardware: emulateHardware)
            + (vulkanWrapper ? "\(GuestVulkanWrapper.switchProperty)=1\n" : "")
            // Avo's ANGLE wrapper: only on a GPU start that emulates the
            // profile's GPU (GuestGLESWrapper.switchedOn).
            + (GuestGLESWrapper.switchedOn(allowed: glesWrapper, plan: plan,
                                           emulatesGPU: GuestGPUProfile.emulatesGPU(profile, emulateHardware: emulateHardware))
                ? "\(GuestGLESWrapper.switchProperty)=1\n" : "")
            // Settings › Graphics' "OpenGL ES" below 3.2: the sync layer reads
            // debug.avo.gl.max (guest/gfxsync) and Android reports the same
            // choice (ro.opengles.version). 3.2 needs an ANGLE that has
            // exposeES32ForTesting (`exposesES32`); the bootconfig's floor is
            // 3.1. Software has no layer: its GLES is SwiftShader's, untouched.
            + (plan.isGPU && gles == .v3_2 && es32Capable
                ? "debug.avo.gl.es32=1\nro.opengles.version=196610\n" : "")
            + (plan.isGPU && gles != .v3_2 ? "debug.avo.gl.max=\(gles.rawValue)\nro.opengles.version=\(gles.androidVersion)\n" : "")
    }

    public func start(_ launch: EngineLaunch) async throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw AvoError.engineMissing }
        // A previous VM that lost its Control channel still owns the disks;
        // one that exited by itself (a crash) still has its agent, frames and tasks.
        if lock.withLock({ self.process != nil }) { await stop() }
        try await self.launch(launch, plan: gpuPlan(for: launch))
    }

    /// One avo-vmm process. A GPU plan is watched by a `GPUBootMonitor` and
    /// replaced by a software launch when it fails before Android is ready.
    private func launch(_ launch: EngineLaunch, plan: GPUPlan) async throws {
        try launch.paths.validateSocketPaths()
        let version = avoVersion
        // Avo's Vulkan driver wrapper, unless it failed a GPU start; whether
        // Android has it, as of its last ready boot, says if this start may fail by it.
        let wrapper = GuestVulkanWrapper.allowed(paths: launch.paths)
        let wrapperRuns = wrapper && plan.isGPU && GuestVulkanWrapper.installed(paths: launch.paths)
        // Avo's ANGLE wrapper likewise, on a GPU start that emulates a GPU.
        let glesWrapper = GuestGLESWrapper.allowed(paths: launch.paths)
        let glesWrapperRuns = GuestGLESWrapper.switchedOn(
            allowed: glesWrapper, plan: plan,
            emulatesGPU: GuestGPUProfile.emulatesGPU(launch.profile, emulateHardware: launch.config.emulateHardware))
            && GuestGLESWrapper.installed(paths: launch.paths)
        let es32 = Self.exposesES32(image: launch.image) && !Self.es32Refuted(image: launch.image, paths: launch.paths)
        try Self.identityProperties(profile: launch.profile, plan: plan, emulateHardware: launch.config.emulateHardware,
                                    vulkanWrapper: wrapper, glesWrapper: glesWrapper, gles: launch.config.glesVersion,
                                    es32Capable: es32) {
            .current(version: version, renderer: $0)
        }
            .write(to: Self.identityFile(launch.paths), atomically: true, encoding: .utf8)
        lock.withLock {
            vulkanWrapperRuns = wrapperRuns
            self.glesWrapperRuns = glesWrapperRuns
        }
        lock.withLock {
            paused = false
            playing = false
            recording = false
        }
        let runtime = launch.paths.runtime
        let vsock = runtime.appending(path: "vsock.sock").path
        let controlPath = runtime.appending(path: "control.sock").path
        for path in [vsock, controlPath] { try? FileManager.default.removeItem(atPath: path) }

        let process = Process()
        process.executableURL = executable
        // The image of this start (CuttlefishImage.prepareStart): chosen in
        // the Control Panel, so it can differ from the one at daemon launch.
        // Android's Bluetooth controller (Avo's Root Canal), when Settings ›
        // Devices gives Android Bluetooth.
        let bluetooth = launch.config.bluetoothEnabled
            ? AndroidEmulator.bluetoothController(engine: executable, home: launch.paths.home) : nil
        // Root: Magisk's init_boot, once one was made for this image (MagiskRoot).
        let initBoot = launch.config.rooted ? MagiskRoot.patchedImage(for: launch.image, paths: launch.paths) : nil
        process.arguments = Self.arguments(images: launch.image.directory, launch: launch, gpu: plan, bluetooth: bluetooth,
                                           initBoot: initBoot)
        let monitor = plan.isGPU ? GPUBootMonitor() : nil
        lock.withLock { self.gpuMonitor = monitor }
        let log = launch.paths.logs.appending(path: "avo-vmm.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        process.standardOutput = logHandle
        process.standardError = logHandle
        let sink = exitSink
        // The frames and sound it shares, whatever way it ends (SharedMemoryNames).
        let sharedMemory = SharedMemoryNames()
        process.terminationHandler = { [weak self, logger] process in
            try? logHandle.close()
            sharedMemory.removeAll()
            let clean = process.terminationReason == .exit && process.terminationStatus == 0
            logger.notice("avo-vmm exited with status \(process.terminationStatus)")
            if process.terminationReason == .exit, process.terminationStatus == Self.factoryResetStatus {
                sink.yield(AndroidFactoryReset())
                return
            }
            if process.terminationReason == .exit, process.terminationStatus == Self.guestRebootStatus {
                sink.yield(AndroidRebooted())
                return
            }
            // A failed GPU boot is not an exit: a software launch replaces it.
            switch monitor?.exited(status: process.terminationStatus, bySignal: process.terminationReason == .uncaughtSignal) {
            case .ignore?: return
            case let .fallBack(failure)?:
                if let monitor { self?.fallBack(failure, monitor: monitor, launch: launch, plan: plan) }
                return
            case .forward(crashedRunning: true)?: self?.crashedOnGPU(launch: launch, plan: plan)
            case .forward(crashedRunning: false)?, nil: break
            }
            sink.yield(clean ? nil : AvoError.vmStartFailed(String(localized: "The VM engine exited with status \(Int(process.terminationStatus)).", bundle: .avoKit)))
        }
        do {
            try process.run()
        } catch {
            throw AvoError.vmStartFailed(error.localizedDescription)
        }

        // Up when both sockets accept connections (disks are prepared first).
        let deadline = SuspendingClock.now + .seconds(120)
        while SuspendingClock.now < deadline {
            guard process.isRunning else {
                // avo-vmm exits 75 (or crashes) when gfxstream cannot start;
                // its other exits (the instance in use, its disks) are start failures.
                if let monitor, let failure = Self.gpuStartFailure(status: process.terminationStatus,
                                                                   bySignal: process.terminationReason == .uncaughtSignal, log: log),
                   monitor.claimStartFailure() {
                    let next = recordFailure(failure, launch: launch, plan: plan)
                    try Task.checkCancellation()
                    return try await self.launch(launch, plan: next)
                }
                // Android's data on a drive macOS no longer lets Avo use: say so, not "see the log".
                if let refusal = Self.storageRefusal(inLog: log, paths: launch.paths) { throw refusal }
                throw AvoError.vmStartFailed(String(localized: "The VM engine stopped while starting; see \(log.path).", bundle: .avoKit))
            }
            if let a = try? UnixSocket.connect(path: vsock), let b = try? UnixSocket.connect(path: controlPath) {
                Darwin.close(a)
                Darwin.close(b)
                break
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                // Cancelled (stop() during a start or a software relaunch):
                // nobody else knows this process yet.
                process.terminate()
                throw error
            }
        }
        guard SuspendingClock.now < deadline else {
            process.terminate()
            throw AvoError.timedOut("avo-vmm startup")
        }

        monitor?.booted()
        let control = EngineControl(socketPath: controlPath)
        let frameQueue = self.frameQueue
        let bridge = FrameBridge(sharedMemory: sharedMemory) { frameQueue.push($0) }
        let agent = HostAgent(engine: control, frames: bridge, adbKey: adbKey) { port in
            try VsockBridge.connect(socketPath: vsock, port: port)
        }
        let linkSink = self.linkSink
        await agent.forwardLinks { linkSink.yield($0) }
        let screenLockSink = self.screenLockSink
        await agent.forwardScreenLock { screenLockSink.yield($0) }
        let responsivenessSink = self.responsivenessSink
        await agent.forwardResponsiveness { responsivenessSink.yield($0) }
        await agent.shareFolder(Self.sharedFolderFlags(launch.config).last.map { URL(filePath: $0, directoryHint: .isDirectory) })
        await agent.useDisplayRate(launch.displayRate)
        await agent.useBluetooth(bluetooth != nil)
        // Whether Android has Avo's Vulkan driver wrapper, for the next start's failures.
        await agent.noteVulkanWrapper { [paths = launch.paths] in GuestVulkanWrapper.noteInstalled($0, paths: paths) }
        await agent.useGLESWrapper(allowed: GuestGLESWrapper.allowed(paths: launch.paths)) { [paths = launch.paths] in
            GuestGLESWrapper.noteInstalled($0, paths: paths)
        }
        await agent.applyDeviceSettings(wifi: launch.config.wifiEnabled, shareMacBluetooth: launch.config.shareMacBluetooth,
                                        cellular: launch.config.cellularEnabled)
        await agent.sampleProcesses(lock.withLock { processSink })
        // Settings › Devices › Cameras: the Mac's cameras, or scenes, while Android streams them.
        let cameras = launch.config.cameraFlags.isEmpty ? nil : CameraFeed(socketPath: controlPath, sources: launch.config.cameraSources)
        let events = try control.events()
        let pump = Task {
            do {
                for try await line in events {
                    if line.hasPrefix("gpu ") { self.gpuEvent(line, monitor: monitor, launch: launch, plan: plan) }
                    if line.hasPrefix("sound ") { self.soundEvent(line) }
                    if line.hasPrefix("bluetooth hci "), let port = line.split(separator: " ").last.flatMap({ UInt16($0) }) {
                        await agent.useBluetoothPort(port)
                    }
                    if line.hasPrefix("camera ") { cameras?.handle(line) }
                    bridge.handle(line)
                }
            } catch {}
        }
        let preparing = Task { [logger] in
            do {
                // VMManager gives up first (up to 15 minutes for a first boot).
                try await agent.prepare(deadline: ContinuousClock.now + .seconds(960))
            } catch {
                logger.error("Android did not get ready: \(String(describing: error), privacy: .public)")
            }
        }
        var tasks = [pump, preparing]
        if let monitor { tasks.append(watchGPUBoot(monitor, agent: agent, launch: launch, plan: plan)) }
        let (current, location) = lock.withLock { () -> (Bool, LocationFix?) in
            // Since the sockets came up, avo-vmm died on the GPU (the software
            // launch replacing it takes over) or stop() came: not the engine's state.
            if let monitor, monitor.hasFallenBack || monitor.isStopped { return (false, nil) }
            self.process = process
            self.cameras = cameras
            self.vsockPath = vsock
            self.control = control
            self.agent = agent
            self.tasks = tasks
            self.launched = launch
            self.bootedWithMagisk = initBoot != nil
            return (true, self.location)
        }
        guard current else {
            for task in tasks { task.cancel() }
            cameras?.stop()
            await control.close()
            guard monitor?.isStopped == true else { return }
            // stop() did not see this process yet.
            process.terminate()
            throw CancellationError()
        }
        if let location { try? await control.send(location.command) }
        // Settings › Devices › Network speed: the engine starts at full speed.
        if launch.config.networkSpeed != .full { try? await control.send(launch.config.networkSpeed.engineCommand) }
        // Settings › Devices › Mobile network: the modem starts without a SIM.
        if launch.config.cellularEnabled { try? await control.send(launch.config.cellularCommand) }
    }

    public func stop() async {
        // Nothing may relaunch Android after a stop. The monitor stops under
        // the lock fallBack(_:monitor:launch:plan:) hands its relaunch over in.
        let relaunch = lock.withLock { () -> Task<Void, Never>? in
            self.gpuMonitor?.stop()
            defer { self.relaunch = nil }
            return self.relaunch
        }
        relaunch?.cancel()
        await relaunch?.value
        let (process, agent, tasks) = lock.withLock { (self.process, self.agent, self.tasks) }
        guard let process else { return }
        // A paused Android powers off once it runs again.
        if lock.withLock({ paused }) {
            try? await lock.withLock { self.control }?.send("resume")
            await agent?.setPaused(false)
            lock.withLock { paused = false }
        }
        // A clean power off from Android flushes the data disk. A guest that
        // stopped answering would keep `reboot -p` waiting for good: then
        // the process is terminated below.
        if let agent { try? await Deadline.run(.seconds(30), what: "power off") { await agent.shutdown() } }
        for _ in 0..<200 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        await Self.end(process)
        for task in tasks { task.cancel() }
        lock.withLock { self.cameras }?.stop()
        await lock.withLock { self.control }?.close()
        lock.withLock {
            self.process = nil
            self.cameras = nil
            self.vsockPath = nil
            self.agent = nil
            self.control = nil
            self.tasks = []
            self.gpuMonitor = nil
            self.launched = nil
            self.bootedWithMagisk = false
        }
    }

    /// Where Android's GPS says it is; nil for no fix (gnss.rs in the engine).
    public func setLocation(_ fix: LocationFix?) async {
        let control = lock.withLock { () -> EngineControl? in
            self.location = fix
            return self.control
        }
        try? await control?.send(fix?.command ?? "location off")
    }

    /// The Mac's appearance, time zone, clock, languages and battery for
    /// Android to follow (HostAgent's Mac state). Ignored until Android is
    /// ready; the daemon sends it again whenever Android starts running.
    public func setMacState(_ state: MacState) async {
        guard let agent = lock.withLock({ self.agent }) else { return }
        await agent.syncMacState(state)
    }

    public func snapshot(to url: URL) async throws {
        throw AvoError.internalError("Quick-boot snapshots are not supported by avo-vmm yet.")
    }

    public func connect(port: UInt32) async throws -> any ByteStream {
        guard let (vsock, agent) = lock.withLock({ self.vsockPath.flatMap { v in self.agent.map { (v, $0) } } }) else {
            throw AvoError.vmNotRunning
        }
        switch port {
        case AvoProtocol.Port.control, AvoProtocol.Port.input:
            // The "agent" listens once Android has booted and is prepared.
            guard await agent.isReady else { throw IOError.handshake("Android is still starting") }
            let (host, guest) = try UnixSocket.pair()
            let stream = FileDescriptorStream(fileDescriptor: guest, label: "host-agent-\(port)")
            if port == AvoProtocol.Port.control {
                Task { await agent.serveControl(stream) }
            } else {
                Task { await agent.serveInput(stream) }
            }
            return FileDescriptorStream(fileDescriptor: host, label: "avo-vmm-\(port)")
        case AvoProtocol.Port.adb:
            return try VsockBridge.connect(socketPath: vsock, port: HostAgent.adbPort)
        default:
            return try VsockBridge.connect(socketPath: vsock, port: port)
        }
    }

    public func connectSocket(port: UInt32) async throws -> Int32 {
        guard let vsock = lock.withLock({ self.vsockPath }) else { throw AvoError.vmNotRunning }
        // Only ADB is a plain guest port here; Control and Input are HostAgent's.
        guard port == AvoProtocol.Port.adb else { throw AvoError.internalError("port \(port) is served by the host agent") }
        return try VsockBridge.connectSocket(socketPath: vsock, port: HostAgent.adbPort)
    }
}

// MARK: GPU renderer

extension VMMEngine {
    /// Graphics › Renderer against the installed emulator and a recorded
    /// failure; published right away so the Control Panel shows the choice.
    private func gpuPlan(for launch: EngineLaunch) -> GPUPlan {
        let requested = launch.config.rendererMode
        let emulator = requested == .software ? nil
            : AndroidEmulator.lookup(home: launch.paths.home, bundled: AndroidEmulator.bundled(engine: executable))
        let fallback = GPUFallbackRecord.load(paths: launch.paths)
        var key: String?
        if case let .found(found)? = emulator { key = GPUFallbackRecord.key(engine: executable, emulator: found) }
        let plan = GPUPlan.decide(mode: requested, emulator: emulator ?? .missing, fallback: fallback, key: key)
        switch plan {
        case let .gpu(found):
            let source = found.isBundled ? "Avo's renderer" : "the Android Emulator"
            logger.notice("renderer: GPU with \(source, privacy: .public) \(found.version, privacy: .public) at \(found.directory.path, privacy: .public)")
        case let .software(reason, failure):
            logger.notice("renderer: software (\(reason.rawValue, privacy: .public)\(failure.map { ", \($0.rawValue)" } ?? "", privacy: .public))")
        }
        publish(plan.status(requested: requested, emulator: emulator, fallback: fallback))
        return plan
    }

    /// Yields under the lock, so the stream's last status is the current one
    /// even when the event pump and a fallback publish at the same time.
    private func publish(_ status: RendererStatus) {
        lock.withLock {
            rendererStatus = status
            rendererSink.yield(status)
        }
    }

    /// `gpu active <device>` names the GPU; the others judge the boot.
    private func gpuEvent(_ line: String, monitor: GPUBootMonitor?, launch: EngineLaunch, plan: GPUPlan) {
        if line.hasPrefix("gpu active ") {
            let device = String(line.dropFirst("gpu active ".count)).trimmingCharacters(in: .whitespaces)
            // Only onto the GPU status: never over a fallback published meanwhile.
            let named = lock.withLock { () -> Bool in
                guard var status = rendererStatus, status.mode == .gpu else { return false }
                status.detail = device
                rendererStatus = status
                rendererSink.yield(status)
                return true
            }
            if named { logger.notice("renderer: \(line, privacy: .public)") }
        } else if line.hasPrefix("gpu stalled") {
            logger.error("renderer: \(line, privacy: .public)")
        }
        if let monitor, let failure = monitor.line(line) { fallBack(failure, monitor: monitor, launch: launch, plan: plan) }
    }

    /// Once a second until Android is ready: no first frame within a minute
    /// fails the GPU boot.
    private func watchGPUBoot(_ monitor: GPUBootMonitor, agent: HostAgent, launch: EngineLaunch, plan: GPUPlan) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled, monitor.isBooting {
                try? await Task.sleep(for: .seconds(1))
                if await agent.isReady {
                    monitor.ready()
                    return
                }
                if let failure = monitor.check() {
                    self?.fallBack(failure, monitor: monitor, launch: launch, plan: plan)
                    return
                }
            }
        }
    }

    /// Writes the fallback record and publishes software; the plan for the
    /// launch that replaces the failed one. A GPU launch that ran Avo's
    /// Vulkan driver wrapper or ANGLE wrapper loses the wrappers it ran
    /// instead, and the GPU gets one more launch without them.
    private func recordFailure(_ failure: GPUFailure, launch: EngineLaunch, plan: GPUPlan) -> GPUPlan {
        let log = launch.paths.logs.appending(path: "avo-vmm.log")
        let detail = Self.gpuError(inLog: log)
        // The failed log stays for bug reports: the next launch writes a new one.
        let failedLog = launch.paths.logs.appending(path: "avo-vmm-gpu-failed.log")
        let (vulkan, gles) = lock.withLock { (vulkanWrapperRuns, glesWrapperRuns) }
        if case .gpu = plan, vulkan || gles {
            logger.error("renderer: GPU failed (\(failure.rawValue, privacy: .public)) with Avo's \(vulkan && gles ? "Vulkan driver and ANGLE wrappers" : vulkan ? "Vulkan driver wrapper" : "ANGLE wrapper", privacy: .public): \(detail ?? "-", privacy: .public); trying the GPU without")
            do {
                if vulkan, let sha256 = GuestVulkanWrapper.wrapper?.sha256 {
                    try GuestVulkanWrapper.Failure(sha256: sha256, failure: failure, date: Date()).save(paths: launch.paths)
                }
                if gles, let sha256 = GuestGLESWrapper.wrapper?.sha256 {
                    try GuestGLESWrapper.Failure(sha256: sha256, failure: failure, date: Date()).save(paths: launch.paths)
                }
                try? FileManager.default.removeItem(at: failedLog)
                try? FileManager.default.copyItem(at: log, to: failedLog)
                return plan
            } catch {
                logger.error("renderer: cannot turn Avo's wrappers off: \(error.localizedDescription, privacy: .public)")
            }
        }
        logger.error("renderer: GPU failed (\(failure.rawValue, privacy: .public)): \(detail ?? "-", privacy: .public); using software")
        if case let .gpu(emulator) = plan {
            let record = GPUFallbackRecord(failure: failure, detail: detail, date: Date(),
                                           key: GPUFallbackRecord.key(engine: executable, emulator: emulator))
            do { try record.save(paths: launch.paths) } catch {
                logger.error("renderer: cannot save the GPU fallback: \(error.localizedDescription, privacy: .public)")
            }
            publish(GPUPlan.software(.failed, failure).status(requested: launch.config.rendererMode, emulator: .found(emulator),
                                                              fallback: record))
        }
        try? FileManager.default.removeItem(at: failedLog)
        try? FileManager.default.copyItem(at: log, to: failedLog)
        return .software(.failed, failure)
    }

    /// A GPU boot failed after the sockets came up: power that Android off
    /// (10 s), then terminate it (SIGKILL after 5 s), and start it again in
    /// software (on the GPU without Avo's Vulkan driver wrapper, when the
    /// failed one ran it). VMManager keeps waiting for Android meanwhile.
    private func fallBack(_ failure: GPUFailure, monitor: GPUBootMonitor, launch: EngineLaunch, plan: GPUPlan) {
        let next = recordFailure(failure, launch: launch, plan: plan)
        lock.withLock {
            // stop() since the failure: nothing may start Android again.
            guard !monitor.isStopped else { return }
            relaunch = Task { [weak self] in
                guard let self else { return }
                let (process, agent, tasks, control) = lock.withLock { (self.process, self.agent, self.tasks, self.control) }
                if let process, process.isRunning {
                    if let agent { try? await Deadline.run(.seconds(10), what: "power off") { await agent.shutdown() } }
                    await Self.end(process)
                }
                for task in tasks { task.cancel() }
                await control?.close()
                guard !Task.isCancelled else { return }
                do {
                    try await self.launch(launch, plan: next)
                } catch is CancellationError {
                } catch {
                    exitSink.yield(error)
                }
            }
        }
    }

    /// Android crashed after it was ready on the GPU; the second time
    /// within 10 minutes, later starts use software.
    private func crashedOnGPU(launch: EngineLaunch, plan: GPUPlan) {
        guard lock.withLock({ gpuCrashes.crashed(at: Date()) }) else { return }
        _ = recordFailure(.crashedTwice, launch: launch, plan: plan)
    }

    /// Terminates `process` (SIGKILL after 5 s) and returns once it is gone,
    /// or a second after that: the next avo-vmm then finds the instance
    /// unlocked instead of exiting because it is in use.
    private static func end(_ process: Process) async {
        if process.isRunning { process.terminate() }
        for _ in 0..<50 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        for _ in 0..<10 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Whether a GPU launch that exited before its sockets came up failed
    /// the GPU (`GPUBootWatch.failure`), or an avo-vmm too old for `--gpu`
    /// refused the flag.
    static func gpuStartFailure(status: Int32, bySignal: Bool, log: URL) -> GPUFailure? {
        if let failure = GPUBootWatch.failure(exitStatus: status, bySignal: bySignal) { return failure }
        return status == 1 && gpuError(inLog: log) == "unknown argument --gpu" ? .initFailed : nil
    }

    /// avo-vmm could not open Android's data in a folder elsewhere than Avo's
    /// own storage (macOS's Removable Volumes permission was turned off).
    static func storageRefusal(inLog log: URL, paths: AvoPaths) -> AvoError? {
        guard !paths.isDataInternal, let text = try? String(contentsOf: log, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("error: ") }),
              line.contains("Operation not permitted") || line.contains("Permission denied") else { return nil }
        return .storage(.notPermitted(path: paths.data.path))
    }

    /// avo-vmm's `error: gpu: <reason>` line, when it wrote one, else its last
    /// `error: …` (an avo-vmm too old for `--gpu` says "unknown argument --gpu").
    static func gpuError(inLog log: URL) -> String? {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline)
        if let line = lines.last(where: { $0.hasPrefix("error: gpu: ") }) { return String(line.dropFirst("error: gpu: ".count)) }
        return lines.last { $0.hasPrefix("error: ") }.map { String($0.dropFirst("error: ".count)) }
    }
}

extension VMMEngine: GPUFallbackEngine {
    public func forgetGPUCrashes() {
        lock.withLock { gpuCrashes = GPUCrashHistory() }
    }
}

/// Settings › Graphics and "Try GPU Again": the GPU layers the next start
/// names go in while this one runs (GuestGPUProfile, GuestGfxstreamSync).
extension VMMEngine: GPULayerEngine {
    public func stageGPULayers(profile: Bool, gfxstreamSync: Bool) async {
        await wakeIfPaused()
        await lock.withLock({ self.agent })?.stageGPULayers(profile: profile, gfxstreamSync: gfxstreamSync)
    }
}

/// Settings › Fingerprints: HostAgent enrolls and touches fingerprints in
/// the virtual sensor of userdebug Cuttlefish (GuestFingerprints).
extension VMMEngine: FingerprintEngine {
    func fingerprintGuest() async throws -> any FingerprintGuest {
        await wakeIfPaused()
        guard let agent = lock.withLock({ self.agent }), await agent.isReady else { throw AvoError.vmNotRunning }
        return agent
    }
}

/// An app window's Device › Shake.
extension VMMEngine: ShakeEngine {
    func shake() async throws {
        await wakeIfPaused()
        guard let control = lock.withLock({ self.control }) else { throw AvoError.vmNotRunning }
        try await control.send("shake")
    }
}

extension VMMEngine: VolumeEngine {
    func mediaVolume() async throws -> AndroidVolume {
        try await readyAgent().mediaVolume()
    }

    func setMediaVolume(_ level: Int) async throws -> AndroidVolume {
        try await readyAgent().setMediaVolume(level)
    }

    /// The host agent, once Android has started (woken from a pause first).
    private func readyAgent() async throws -> HostAgent {
        await wakeIfPaused()
        guard let agent = lock.withLock({ self.agent }), await agent.isReady else { throw AvoError.vmNotRunning }
        return agent
    }
}

/// Library › Widgets: Avo Widgets, which HostAgent installs.
extension VMMEngine: WidgetsEngine {
    func widgetsGuest() async throws -> any WidgetsGuest {
        await wakeIfPaused()
        guard let agent = lock.withLock({ self.agent }), await agent.isReady else { throw AvoError.vmNotRunning }
        return agent
    }
}

/// Google apps (Settings › System): userdebug Cuttlefish lets root turn off
/// dm-verity and remount the system partitions, which HostAgent does.
extension VMMEngine: DeviceSettingsEngine {
    public func applyDeviceSettings(_ config: VMConfig) async {
        let (control, agent, cameras) = lock.withLock { (self.control, self.agent, self.cameras) }
        cameras?.use(config.cameraSources)
        try? await control?.send(config.microphoneEnabled ? "microphone on" : "microphone off")
        try? await control?.send(config.networkSpeed.engineCommand)
        try? await control?.send(config.cellularCommand)
        await agent?.applyDeviceSettings(wifi: config.wifiEnabled, shareMacBluetooth: config.shareMacBluetooth,
                                         cellular: config.cellularEnabled)
    }
}

extension VMMEngine: RootEngine {
    public func bootedRooted() async -> Bool {
        lock.withLock { bootedWithMagisk }
    }

    public func hasPatchedImage() async -> Bool {
        guard let launch = lock.withLock({ launched }) else { return false }
        return MagiskRoot.patchedImage(for: launch.image, paths: launch.paths) != nil
    }

    public func prepareRoot() async throws {
        await wakeIfPaused()
        guard let (agent, launch) = lock.withLock({ agent.flatMap { a in launched.map { (a, $0) } } }), await agent.isReady else {
            throw AvoError.vmNotRunning
        }
        let apk = try await MagiskRoot.apk(paths: launch.paths)
        let stock = MagiskRoot.stockImage(of: launch.image)
        let hash = try MagiskRoot.sha256(of: stock)
        let patched = try await agent.patchInitBoot(stock: stock, apk: apk)
        try MagiskRoot.store(patched, stock: hash, paths: launch.paths)
        logger.notice("root: Magisk \(MagiskRoot.release.version, privacy: .public) patched init_boot; Android starts rooted next time")
    }
}

extension VMMEngine: SystemAppsEngine {
    public func systemApps() async throws -> any SystemAppsGuest {
        await wakeIfPaused()
        guard let agent = lock.withLock({ self.agent }), await agent.isReady else { throw AvoError.vmNotRunning }
        return agent
    }
}

// MARK: Screen lock

/// Android started with a screen lock (HostAgent's "Screen lock").
extension VMMEngine: GuestStorageEngine {
    public func androidStorage() async -> AndroidStorage? {
        guard let agent = lock.withLock({ self.agent }) else { return nil }
        return await agent.storage()
    }
}

extension VMMEngine: ResponsivenessEngine {}

extension VMMEngine: ScreenLockEngine {
    public func screenLock() async -> AndroidScreenLock? {
        await lock.withLock({ self.agent })?.currentScreenLock
    }

    public func unlockScreen(_ credential: ScreenLockCredential) async throws {
        await wakeIfPaused()
        guard let agent = lock.withLock({ self.agent }), await agent.isReady else { throw AvoError.vmNotRunning }
        try await agent.unlockScreen(credential)
    }
}

// MARK: Pause (PausableEngine)

extension VMMEngine: PausableEngine {
    /// HostAgent's watches wait first (they would only queue up commands for
    /// a stopped Android), then avo-vmm stops the vCPUs.
    public func pause() async throws {
        guard let (control, agent) = lock.withLock({ self.control.flatMap { c in self.agent.map { (c, $0) } } }) else {
            throw AvoError.vmNotRunning
        }
        // From here on, whatever uses Android through the engine wakes it.
        lock.withLock { paused = true }
        await agent.setPaused(true)
        do {
            try await control.send("pause")
        } catch {
            lock.withLock { paused = false }
            await agent.setPaused(false)
            throw error
        }
    }

    public func resume(pausedFor: Duration) async throws {
        guard let (control, agent) = lock.withLock({ self.control.flatMap { c in self.agent.map { (c, $0) } } }) else {
            throw AvoError.vmNotRunning
        }
        try await control.send("resume")
        lock.withLock { paused = false }
        await agent.setPaused(false)
        // Android's clock stood still with it (pause.rs).
        Task { await agent.clockResumed(after: pausedFor) }
    }

    public func activity() async -> EngineActivity {
        let (process, playing, recording) = lock.withLock { (self.process, self.playing, self.recording) }
        var activity = EngineActivity(playing: playing, recording: recording)
        if let process, process.isRunning, let usage = Self.usage(of: process.processIdentifier) {
            activity.cpuTime = usage.cpu
            activity.residentBytes = usage.resident
        }
        return activity
    }

    public func onUse(_ wake: @escaping @Sendable () async -> Void) {
        lock.withLock { wakeHandler = wake }
    }

    /// Before handing Android out to a caller that uses it directly.
    private func wakeIfPaused() async {
        guard let wake = lock.withLock({ paused ? wakeHandler : nil }) else { return }
        await wake()
    }

    /// `sound playback on`, `sound capture off` (engine/hvf/vmm/src/virtio/sound.rs).
    private func soundEvent(_ line: String) {
        let words = line.split(separator: " ")
        guard words.count == 3 else { return }
        let on = words[2] == "on"
        lock.withLock {
            if words[1] == "playback" { playing = on } else if words[1] == "capture" { recording = on }
        }
    }

    /// The CPU time and resident memory of a process (proc_pidinfo).
    static func usage(of pid: pid_t) -> (cpu: Duration, resident: UInt64)? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        // Mach absolute time units on Apple silicon.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = info.pti_total_user + info.pti_total_system
        let nanoseconds = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer)).partialValue / UInt64(max(timebase.denom, 1))
        return (.nanoseconds(Int64(clamping: nanoseconds)), info.pti_resident_size)
    }
}

/// A position from the Mac (CoreLocation) for Android's GPS.
public struct LocationFix: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var accuracy: Double
    public var speed: Double
    public var bearing: Double

    public init(latitude: Double, longitude: Double, altitude: Double, accuracy: Double, speed: Double, bearing: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.accuracy = accuracy
        self.speed = speed
        self.bearing = bearing
    }

    /// `location <lat> <lng> <alt> <accuracy> <speed> <bearing>` (engine control socket).
    var command: String {
        String(format: "location %.7f %.7f %.1f %.1f %.2f %.1f", locale: Locale(identifier: "en_US_POSIX"),
               latitude, longitude, altitude, max(accuracy, 1), max(speed, 0), max(bearing, 0))
    }
}

// MARK: - Shared folder (SharedFolderBridge.swift)

extension VMMEngine: SharedFolderEngine {
    public func sharedFolderMount() async -> SharedFolderMount? {
        guard let agent = lock.withLock({ self.agent }) else { return nil }
        return await agent.sharedFolderMount()
    }
}

// MARK: - System Status (SystemMonitor.swift)

extension VMMEngine: ActivityEngine {
    func sampleProcesses(_ sink: (@Sendable (GuestActivity.Sample) -> Void)?) async {
        let agent = lock.withLock { () -> HostAgent? in
            processSink = sink
            return self.agent
        }
        await agent?.sampleProcesses(sink)
    }

    func windowFrames() async -> [String: UInt64] {
        await lock.withLock({ self.agent })?.windowFrames() ?? [:]
    }

    var engineProcessID: pid_t? {
        lock.withLock { process.flatMap { $0.isRunning ? $0.processIdentifier : nil } }
    }
}
