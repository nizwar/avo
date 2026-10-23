import AvoIO
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore
@testable import AvoKit

@Suite struct GPURendererTests {
    /// A fake emulator directory: `source.properties` plus the files avo-vmm loads.
    private func emulator(revision: String? = "37.1.11", build: String? = "15917651", skipping: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "avo-emulator-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir.appending(path: "lib64/vulkan"), withIntermediateDirectories: true)
        if let revision {
            let properties = "Pkg.Desc = Android Emulator\nPkg.Revision=\(revision)\n" + (build.map { "Pkg.BuildId=\($0)\n" } ?? "")
            try properties.write(to: dir.appending(path: "source.properties"), atomically: true, encoding: .utf8)
        }
        for file in AndroidEmulator.requiredFiles where file != skipping {
            FileManager.default.createFile(atPath: dir.appending(path: file).path, contents: Data())
        }
        return dir
    }

    private func found(_ dir: URL) throws -> AndroidEmulator {
        guard case let .found(emulator) = AndroidEmulator.inspect(dir) else { throw CancellationError() }
        return emulator
    }

    // MARK: Android Emulator

    @Test func findsAnInstalledEmulator() throws {
        let dir = try emulator()
        defer { try? FileManager.default.removeItem(at: dir) }
        let emulator = try found(dir)
        #expect(emulator.version == "37.1.11")
        #expect(emulator.build == "15917651")
        #expect(AndroidEmulator.lookup(home: URL(filePath: "/nonexistent"), override: dir.path) == .found(emulator))
    }

    @Test func missingOldOrIncompleteEmulators() throws {
        #expect(AndroidEmulator.lookup(home: URL(filePath: "/nonexistent"), override: nil) == .missing)
        let old = try emulator(revision: "36.4.2")
        let incomplete = try emulator(skipping: "lib64/vulkan/libMoltenVK.dylib")
        let unversioned = try emulator(revision: nil)
        defer { for dir in [old, incomplete, unversioned] { try? FileManager.default.removeItem(at: dir) } }
        #expect(AndroidEmulator.inspect(old) == .unsupported(version: "36.4.2"))
        #expect(AndroidEmulator.inspect(incomplete) == .missing)
        #expect(AndroidEmulator.inspect(unversioned) == .missing)
    }

    @Test func parsesSourceProperties() {
        let parsed = AndroidEmulator.revision(sourceProperties: "Pkg.UserSrc=false\nPkg.Revision=37.1.11\nPkg.BuildId=15917651\n")
        #expect(parsed?.revision == "37.1.11")
        #expect(parsed?.build == "15917651")
        #expect(AndroidEmulator.revision(sourceProperties: "Pkg.Revision = 38.0.1\r\n")?.build == nil)
        #expect(AndroidEmulator.revision(sourceProperties: "Pkg.Desc=x") == nil)
        #expect(AndroidEmulator.revision(sourceProperties: "Pkg.Desc=Avo GPU renderer: x\nPkg.Revision=avo.1\n")?.description
            == "Avo GPU renderer: x")
    }

    // MARK: Avo's own renderer

    /// A fake build of scripts/build-gfxstream.sh.
    private func avoRenderer(skipping: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "avo-gfxstream-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir.appending(path: "lib64/vulkan"), withIntermediateDirectories: true)
        let properties = "Pkg.Desc=Avo GPU renderer: gfxstream, the Vulkan loader and MoltenVK, built from source\n"
            + "Pkg.Revision=avo.1\nPkg.BuildId=gfxstream-ec3143b4ac34\n"
        try properties.write(to: dir.appending(path: "source.properties"), atomically: true, encoding: .utf8)
        for file in AndroidEmulator.bundledFiles where file != skipping {
            FileManager.default.createFile(atPath: dir.appending(path: file).path, contents: Data())
        }
        return dir
    }

    /// Avo's own build in Avo.app comes before the Android Emulator, which
    /// a user then needs for nothing but Bluetooth.
    @Test func prefersAvosOwnRenderer() throws {
        let bundled = try avoRenderer()
        let incomplete = try avoRenderer(skipping: "lib64/vulkan/libMoltenVK.dylib")
        let home = FileManager.default.temporaryDirectory.appending(path: "avo-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        let installed = home.appending(path: "Library/Android/sdk/emulator", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: try emulator(), to: installed)
        defer { for dir in [bundled, incomplete, home] { try? FileManager.default.removeItem(at: dir) } }

        // Avo's own build has no emulator version to check.
        let own = try found(bundled)
        #expect(own.isBundled)
        #expect(own.version == "avo.1")
        let emulator = try found(installed)
        #expect(!emulator.isBundled)
        #expect(AndroidEmulator.lookup(home: home, bundled: bundled, override: nil) == .found(own))
        // A developer's override still wins; without Avo's build (or with a
        // broken one), the installed emulator.
        #expect(AndroidEmulator.lookup(home: home, bundled: bundled, override: installed.path) == .found(emulator))
        #expect(AndroidEmulator.lookup(home: home, bundled: nil, override: nil) == .found(emulator))
        #expect(AndroidEmulator.inspect(incomplete) == .missing)
        #expect(AndroidEmulator.lookup(home: home, bundled: incomplete, override: nil) == .found(emulator))
    }

    @Test func findsTheRendererNextToTheEngine() {
        let engine = URL(filePath: "/Applications/Avo.app/Contents/MacOS/avo-vmm")
        #expect(AndroidEmulator.bundled(engine: engine).path == "/Applications/Avo.app/Contents/Resources/gfxstream")
    }

    // MARK: Plan

    @Test func planMatrix() {
        let emu = AndroidEmulator(directory: URL(filePath: "/emu"), version: "37.1.11", build: "1")
        let record = GPUFallbackRecord(failure: .noFrames, detail: nil, date: Date(), key: "k1")
        #expect(GPUPlan.decide(mode: .software, emulator: .found(emu), fallback: nil, key: "k1") == .software(.chosen, nil))
        #expect(GPUPlan.decide(mode: .auto, emulator: .missing, fallback: nil, key: nil) == .software(.emulatorMissing, nil))
        #expect(GPUPlan.decide(mode: .gpu, emulator: .unsupported(version: "36.1"), fallback: nil, key: nil)
            == .software(.emulatorUnsupported, nil))
        #expect(GPUPlan.decide(mode: .auto, emulator: .found(emu), fallback: nil, key: "k1") == .gpu(emu))
        #expect(GPUPlan.decide(mode: .gpu, emulator: .found(emu), fallback: record, key: "k1") == .software(.failed, .noFrames))
        // A new avo-vmm, emulator or macOS: one more GPU try.
        #expect(GPUPlan.decide(mode: .auto, emulator: .found(emu), fallback: record, key: "k2") == .gpu(emu))
    }

    @Test func planStatus() {
        let emu = AndroidEmulator(directory: URL(filePath: "/emu"), version: "37.1.11", build: nil)
        let record = GPUFallbackRecord(failure: .initFailed, detail: "missing libvulkan", date: Date(), key: "k")
        let gpu = GPUPlan.gpu(emu).status(requested: .auto, emulator: .found(emu), fallback: nil)
        #expect(gpu == RendererStatus(mode: .gpu, requested: .auto, reason: .chosen, emulatorVersion: "37.1.11"))
        let failed = GPUPlan.software(.failed, .initFailed).status(requested: .gpu, emulator: .found(emu), fallback: record)
        #expect(failed.mode == .software && failed.failure == .initFailed && failed.detail == "missing libvulkan")
        let old = GPUPlan.software(.emulatorUnsupported, nil).status(requested: .auto, emulator: .unsupported(version: "36.1"), fallback: nil)
        #expect(old.emulatorVersion == "36.1")
    }

    @Test func fallbackRecordRoundTripAndKey() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "avo-gpu-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AvoPaths(home: root, temporaryDirectory: root)
        #expect(GPUFallbackRecord.load(paths: paths) == nil)
        let record = GPUFallbackRecord(failure: .stalled, detail: "d", date: Date(timeIntervalSince1970: 1_800_000_000), key: "k")
        try record.save(paths: paths)
        #expect(GPUFallbackRecord.load(paths: paths) == record)
        GPUFallbackRecord.remove(paths: paths)
        #expect(GPUFallbackRecord.load(paths: paths) == nil)

        let engine = root.appending(path: "avo-vmm")
        try Data(count: 10).write(to: engine)
        let emu = AndroidEmulator(directory: root, version: "37.1.11", build: "15917651")
        let key = GPUFallbackRecord.key(engine: engine, emulator: emu, system: "Version 27.0")
        #expect(key.hasPrefix("10:") && key.hasSuffix("|37.1.11:15917651|Version 27.0"))
        var newer = emu
        newer.build = "15917652"
        #expect(GPUFallbackRecord.key(engine: engine, emulator: newer, system: "Version 27.0") != key)
    }

    // MARK: Boot watch

    @Test func bootWatch() {
        let start = SuspendingClock.now
        var watch = GPUBootWatch(now: start)
        let active = watch.event("gpu active Apple M4 Pro", now: start)
        #expect(active == nil)
        // A first boot: minutes before Android starts its graphics are not a GPU failure.
        #expect(watch.check(now: start + .seconds(300)) == nil)
        let context = watch.event("gpu context", now: start + .seconds(200))
        #expect(context == nil)
        #expect(watch.check(now: start + .seconds(259)) == nil)
        #expect(watch.check(now: start + .seconds(260)) == .failed(.noFrames))
        let first = watch.event("gpu first-frame 0")
        #expect(first == .started)
        #expect(watch.check(now: start + .seconds(120)) == nil)
        let stalled = watch.event("gpu stalled 10012")
        #expect(stalled == .failed(.stalled))
        #expect(watch.exited(status: 75, bySignal: false) == .failed(.initFailed))
        #expect(watch.exited(status: 11, bySignal: true) == .failed(.crashed))
        #expect(watch.exited(status: 0, bySignal: false) == nil)
        // avo-vmm's own errors, a factory reset and a panic of its main thread are not the GPU's.
        for status: Int32 in [1, 76, 101] {
            #expect(watch.exited(status: status, bySignal: false) == nil)
        }
    }

    /// An exit before the sockets: only the GPU's turns the GPU off; the
    /// others (the instance in use by another VM) are start failures.
    @Test func gpuStartFailures() throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "avo-vmm-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        try "error: gpu: libvulkan.dylib: not a Mach-O file\n".write(to: log, atomically: true, encoding: .utf8)
        #expect(VMMEngine.gpuStartFailure(status: 75, bySignal: false, log: log) == .initFailed)
        #expect(VMMEngine.gpuStartFailure(status: 6, bySignal: true, log: log) == .crashed)
        try "error: /Users/u/Library/Application Support/Avo/vm/cuttlefish is in use by another VM\n"
            .write(to: log, atomically: true, encoding: .utf8)
        #expect(VMMEngine.gpuStartFailure(status: 1, bySignal: false, log: log) == nil)
        #expect(VMMEngine.gpuStartFailure(status: 0, bySignal: false, log: log) == nil)
        // An avo-vmm from before GPU support.
        try "error: unknown argument --gpu\n".write(to: log, atomically: true, encoding: .utf8)
        #expect(VMMEngine.gpuStartFailure(status: 1, bySignal: false, log: log) == .initFailed)
    }

    /// A boot whose graphics never start fails only after `graphicsStartTimeout`.
    @Test func bootWatchWithoutGraphics() {
        let start = SuspendingClock.now
        var watch = GPUBootWatch(now: start)
        #expect(watch.check(now: start + .seconds(599)) == nil)
        #expect(watch.check(now: start + .seconds(600)) == .failed(.noFrames))
        // A second context later does not move the deadline.
        _ = watch.event("gpu context", now: start + .seconds(10))
        _ = watch.event("gpu context", now: start + .seconds(50))
        #expect(watch.check(now: start + .seconds(70)) == .failed(.noFrames))
    }

    @Test func crashHistory() {
        var history = GPUCrashHistory()
        let t0 = Date()
        let first = history.crashed(at: t0)
        let second = history.crashed(at: t0 + 9 * 60)
        #expect(!first && second)
        var apart = GPUCrashHistory()
        let early = apart.crashed(at: t0)
        let late = apart.crashed(at: t0 + 11 * 60)
        #expect(!early && !late)
    }

    @Test func monitorFailsOnce() {
        let start = SuspendingClock.now
        let monitor = GPUBootMonitor()
        // Before the sockets, start() handles an exit itself.
        #expect(monitor.exited(status: 75, bySignal: false) == .ignore)
        monitor.booted(now: start)
        #expect(monitor.line("gpu first-frame 0") == nil)
        #expect(!monitor.hasFallenBack)
        #expect(monitor.line("gpu stalled 10000") == .stalled)
        // The fallback owns this launch now: nothing else fails it again.
        #expect(monitor.hasFallenBack && !monitor.isStopped)
        #expect(monitor.check(now: start + .seconds(90)) == nil)
        #expect(monitor.exited(status: 0, bySignal: true) == .ignore)
        // A stop() during the fallback: its relaunch must not start.
        monitor.stop()
        #expect(monitor.isStopped && !monitor.hasFallenBack)

        let running = GPUBootMonitor()
        running.booted(now: start)
        running.ready()
        #expect(running.check(now: start + .seconds(90)) == nil)
        #expect(running.exited(status: 1, bySignal: false) == .forward(crashedRunning: false))
        #expect(running.exited(status: 6, bySignal: true) == .forward(crashedRunning: true))

        let booting = GPUBootMonitor()
        booting.booted(now: start)
        #expect(booting.exited(status: 0, bySignal: false) == .forward(crashedRunning: false))
        #expect(booting.exited(status: 1, bySignal: false) == .forward(crashedRunning: false))
        #expect(!booting.hasFallenBack)
        let crashed = GPUBootMonitor()
        crashed.booted(now: start)
        #expect(crashed.exited(status: 11, bySignal: true) == .fallBack(.crashed))

        let stopped = GPUBootMonitor()
        #expect(stopped.claimStartFailure())
        #expect(!stopped.claimStartFailure())
        stopped.stop()
        #expect(stopped.exited(status: 15, bySignal: true) == .forward(crashedRunning: false))
    }

    // MARK: Status and engine contract

    @Test func rendererStatusDecodesTolerantly() throws {
        let newer = #"{"mode": "vulkan-direct", "requested": "turbo", "reason": "magic", "failure": "melted", "detail": "x"}"#
        let status = try JSONDecoder().decode(RendererStatus.self, from: Data(newer.utf8))
        #expect(status == RendererStatus(mode: .software, requested: .auto, detail: "x"))
        let vm = try JSONDecoder().decode(VMStatus.self, from: Data(#"{"state": "running", "openDisplays": 0}"#.utf8))
        #expect(vm.renderer == nil)
        let full = RendererStatus(mode: .gpu, requested: .gpu, reason: .chosen, detail: "Apple M4 Pro", emulatorVersion: "37.1.11")
        #expect(try JSONDecoder().decode(RendererStatus.self, from: JSONEncoder().encode(full)) == full)
    }

    @Test func vmmArgumentsAddGPUFlagsOnlyForTheGPU() {
        let paths = AvoPaths(home: URL(filePath: "/Users/u"), temporaryDirectory: URL(filePath: "/tmp/T"))
        let image = CuttlefishImage.androidImage(at: URL(filePath: "/img"))
        let launch = EngineLaunch(config: VMConfig(memoryMiB: 6144, cpuCount: 6), paths: paths, image: image,
                                  bootConfigDisk: URL(filePath: "/cfg.img"))
        let images = URL(filePath: "/img")
        let software = ["cuttlefish", "/img",
                        "--instance", paths.vm.appending(path: "cuttlefish").path,
                        "--runtime", paths.runtime.path,
                        "--userdata", paths.dataDisk.path,
                        "--cpus", "6",
                        "--mem", "6144",
                        "--display", "720x1280",
                        "--density", "\(launch.config.bootDensity ?? 320)",
                        "--properties", paths.vm.appending(path: "identity.prop").path,
                        "--exit-on-reboot"]
        #expect(VMMEngine.arguments(images: images, launch: launch) == software)
        #expect(VMMEngine.arguments(images: images, launch: launch, gpu: .software(.failed, .crashed)) == software)
        let emu = AndroidEmulator(directory: URL(filePath: "/Users/u/Library/Android/sdk/emulator"), version: "37.1.11", build: nil)
        #expect(VMMEngine.arguments(images: images, launch: launch, gpu: .gpu(emu))
            == software + ["--gpu", "gfxstream", "--gfxstream-dir", "/Users/u/Library/Android/sdk/emulator"])
        // Bluetooth comes with its controller, in software mode too.
        let rootcanal = URL(filePath: "/Applications/Avo.app/Contents/Resources/bluetooth/rootcanal")
        #expect(VMMEngine.arguments(images: images, launch: launch, bluetooth: rootcanal)
            == software + ["--bluetooth", "/Applications/Avo.app/Contents/Resources/bluetooth/rootcanal"])
    }

    @Test func findsTheEmulatorsNetsimd() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "avo-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let emulator = home.appending(path: "Library/Android/sdk/emulator")
        try FileManager.default.createDirectory(at: emulator, withIntermediateDirectories: true)
        #expect(AndroidEmulator.netsimd(home: home, override: nil) == nil, "no emulator, no Bluetooth")
        let netsimd = emulator.appending(path: "netsimd")
        FileManager.default.createFile(atPath: netsimd.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o644])
        #expect(AndroidEmulator.netsimd(home: home, override: nil) == nil, "not executable")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: netsimd.path)
        #expect(AndroidEmulator.netsimd(home: home, override: nil)?.path == netsimd.path)
        // `AvoAndroidEmulator` names another emulator.
        #expect(AndroidEmulator.netsimd(home: URL(filePath: "/nowhere"), override: emulator.path)?.path == netsimd.path)
    }

    /// Avo's own Root Canal, next to avo-vmm in Avo.app, comes first; the
    /// emulator's netsimd only for a build without it.
    @Test func bluetoothIsAvosOwnControllerFirst() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "avo-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let emulator = home.appending(path: "Library/Android/sdk/emulator")
        try FileManager.default.createDirectory(at: emulator, withIntermediateDirectories: true)
        let netsimd = emulator.appending(path: "netsimd")
        FileManager.default.createFile(atPath: netsimd.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let app = home.appending(path: "Avo.app/Contents")
        let engine = app.appending(path: "MacOS/avo-vmm")
        #expect(AndroidEmulator.bluetoothController(engine: engine, home: home, override: nil)?.path == netsimd.path, "no Root Canal yet")
        let rootcanal = app.appending(path: "Resources/bluetooth/rootcanal")
        try FileManager.default.createDirectory(at: rootcanal.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: rootcanal.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        #expect(AndroidEmulator.bluetoothController(engine: engine, home: home, override: nil)?.path == rootcanal.path)
        try FileManager.default.removeItem(at: emulator)
        #expect(AndroidEmulator.bluetoothController(engine: engine, home: home, override: nil)?.path == rootcanal.path, "no emulator needed")
    }

    @Test func readsTheEnginesGPUError() throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "avo-vmm-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        try "[gpu] loading\nerror: gpu: libvulkan.dylib: not a Mach-O file\n".write(to: log, atomically: true, encoding: .utf8)
        #expect(VMMEngine.gpuError(inLog: log) == "libvulkan.dylib: not a Mach-O file")
        // An avo-vmm from before GPU support: its own error is the detail.
        try "error: unknown argument --gpu\n".write(to: log, atomically: true, encoding: .utf8)
        #expect(VMMEngine.gpuError(inLog: log) == "unknown argument --gpu")
        try "booted\n".write(to: log, atomically: true, encoding: .utf8)
        #expect(VMMEngine.gpuError(inLog: log) == nil)
    }
}

/// The fake engine, remembering GPU crashes as VMMEngine does.
final class GPUCrashTestEngine: GPUFallbackEngine, @unchecked Sendable {
    let base: FakeEngine
    private let lock = NSLock()
    private var _forgotten = 0

    init(_ base: FakeEngine) {
        self.base = base
    }

    var forgotten: Int { lock.withLock { _forgotten } }

    var name: String { base.name }
    var exits: AsyncStream<(any Error)?> { base.exits }
    func start(_ launch: EngineLaunch) async throws { try await base.start(launch) }
    func stop() async { await base.stop() }
    func snapshot(to url: URL) async throws { try await base.snapshot(to: url) }
    func connect(port: UInt32) async throws -> any ByteStream { try await base.connect(port: port) }
    func forgetGPUCrashes() { lock.withLock { _forgotten += 1 } }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct GPUFallbackDaemonTests {
    /// "Try GPU Again" and a Renderer change give the GPU a fresh start: no
    /// fallback record, and no earlier crash that would make the next one a second.
    @Test func tryGPUAgainAndRendererChangesForgetCrashes() async throws {
        var wrapped: GPUCrashTestEngine?
        let harness = try Harness(apps: [], wrap: { base in
            let engine = GPUCrashTestEngine(base)
            wrapped = engine
            return engine
        })
        defer { harness.cleanUp() }
        let engine = try #require(wrapped)
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        try GPUFallbackRecord(failure: .crashedTwice, detail: nil, date: Date(), key: "k").save(paths: harness.paths)
        try await harness.core.retryGPU(client: panel)
        #expect(GPUFallbackRecord.load(paths: harness.paths) == nil)
        #expect(engine.forgotten == 1)

        var config = await harness.core.configurationSnapshot().config
        config.fpsLimit = 30
        _ = try await harness.core.updateConfiguration(config, client: panel)
        #expect(engine.forgotten == 1, "only a Renderer change")
        config.rendererMode = .software
        _ = try await harness.core.updateConfiguration(config, client: panel)
        #expect(engine.forgotten == 2)
    }
}
