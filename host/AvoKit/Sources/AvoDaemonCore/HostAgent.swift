import AvoADB
import AvoIO
import AvoKit
import AvoPackages
import AvoProtocol
import AvoShimKit
import CoreGraphics
import Foundation
import os

/// The Bridge Agent's side of the Control and Input channels, played on the
/// host for images that do not ship the agent (AOSP Cuttlefish builds, see
/// docs/engine.md). It does the agent's work from outside Android:
///
/// - a window's display is a virtio-gpu scanout the engine hot-plugs; the
///   app is started on it with `am start --display` over ADB;
/// - touches go to the engine's per-scanout touchscreen, tied to its
///   display by an input device configuration file (`touch.displayId`);
/// - packages come from `pm` and are read from their APKs on the host.
///
/// Privileged steps use `su` (userdebug images).
actor HostAgent: DisplayResizing {
    private struct Display {
        let id: UInt32
        let scanout: Int
        let package: String
        /// Nil while Android is still adding the display.
        var androidID: Int?
        var width: UInt32
        var height: UInt32
        var dpi: UInt32
        /// The size the window measures input in (before 8-pixel alignment).
        var inputWidth: UInt32
        var inputHeight: UInt32
        /// The size Android has for the display (`width`/`height` are wanted).
        var appliedWidth: UInt32 = 0
        var appliedHeight: UInt32 = 0
        /// The density last given to Android (0: Android's own).
        var appliedDPI: UInt32 = 0
        /// Android's unique id for the display (`local:…`), once it has it.
        var uniqueID: String?
        /// The launch's data: a widget panel's widget (`AndroidWidgets.launchURI`).
        var dataURI = ""
    }

    static let adbPort: UInt32 = 6520
    private static let scanouts = 1..<16
    /// Touchscreen units per display edge (engine/hvf/vmm/src/control.rs).
    private static let touchRange: Float = 32767

    private let engine: EngineControl
    private let frames: FrameBridge
    private let adbKey: ADBKey
    private let connectGuest: @Sendable (UInt32) async throws -> any ByteStream
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "HostAgent")

    private var adb: ADBConnection?
    private(set) var isReady = false
    /// Android has Avo's Vulkan driver wrapper (GuestVulkanWrapper): it runs
    /// this boot, or is installed for the next GPU start.
    private(set) var hasVulkanWrapper = false
    /// It runs this boot (`checkVulkanWrapper`'s `.running`): the gfxstream
    /// sync layer and the GPU profile layer ride inside it, so the Vulkan
    /// profile layer stays out of /data/local/debug (`installGPUProfileLayers`).
    private var vulkanWrapperRuns = false
    /// It runs at the next GPU start (this start's engine lets it), so that
    /// start needs no gfxstream sync layer in /data/local/debug.
    private var vulkanWrapperNextStart = false
    /// What the boot's start found (`checkVulkanWrapper`), whether the engine
    /// lets the wrapper run, and who keeps `hasVulkanWrapper` (VMMEngine).
    private var vulkanWrapperState: GuestVulkanWrapper.State?
    private var vulkanWrapperAllowed = false
    private var vulkanWrapperNoted: (@Sendable (Bool) -> Void)?
    /// Avo's ANGLE wrapper (GuestGLESWrapper): it runs this boot, so the GLES
    /// profile layer stays out of /data/local/debug (`installGPUProfileLayers`);
    /// the daemon lets it run (it has not failed a GPU start); it runs at the
    /// next GPU start that emulates a GPU; and who keeps whether Android has it (VMMEngine).
    private var glesWrapperRuns = false
    private var glesWrapperAllowed = false
    private var glesWrapperNextStart = false
    private var glesWrapperState: GuestGLESWrapper.State?
    private var glesWrapperNoted: (@Sendable (Bool) -> Void)?
    /// Android is paused (VMMEngine's pause): the watches wait, as their turns
    /// would only queue up commands for it ("Pause"), and so does whatever
    /// else would wake the Mac every few seconds for nothing (`whilePaused`).
    private(set) var paused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    /// Android's clock being put right after a pause or the Mac's sleep (`clockResumed`).
    private var clockCorrection: Task<Void, Never>?
    private var displays: [UInt32: Display] = [:]
    /// Scanouts of closed windows that Android may not have let go of yet
    /// (`release`): a new window takes another one meanwhile.
    private var releasing: Set<Int> = []
    private var displayRate = FrameRates.standardRate
    private var hasBluetooth = false
    /// Settings › Devices: Android's Wi-Fi, the Mac's Bluetooth devices for
    /// it, and whether the modem has a SIM.
    private var wifiWanted = true
    private var shareMacBluetooth = true
    private var cellularWanted = false
    /// The Mac's Bluetooth LE devices in Android's air (MacBluetoothBridge),
    /// and the watch that follows Android's Bluetooth switch for it.
    private var bluetoothBridge: MacBluetoothBridge?
    private var bluetoothWatch: Task<Void, Never>?
    private var touchTargets: [Int: String] = [:]
    private var control: FileDescriptorStream?
    private var sdk: UInt32 = 0
    private var build = ""
    private var known: [String: Int64] = [:]
    private var infoCache: [String: (version: Int64, info: Avo_V1_AppInfo)] = [:]
    /// Asks again for apps whose info came out incomplete (`repairAppInfoLater`).
    private var appInfoRepair: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    /// Pointer ids down per host display.
    private var touches: [UInt32: [UInt32: (Float, Float)]] = [:]
    /// Where the engine's keyboard types: Android's focused display, which
    /// is the one last tapped or launched on.
    private var focusedDisplay: UInt32?
    /// The display whose window last became the Mac's key window, while one
    /// before it is still taking the focus (`focusDisplay`).
    private var focusWanted: UInt32?
    private var focusing = false
    /// Displays being re-plugged at a new size, and the resize requests
    /// waiting for that to end (`DisplayResizing`).
    var resizing: Set<UInt32> = []
    var resizeWaiters: [UInt32: [CheckedContinuation<Void, Never>]] = [:]
    /// Avo's composer runs (GuestComposer): a display takes a new size in
    /// place, keeping its Android display id, instead of a re-plug.
    private var resizesInPlace = false
    /// When each display's app was started, and how many checks in a row
    /// found nothing on it (see `watchTasks`).
    private var startedAt: [UInt32: ContinuousClock.Instant] = [:]
    private var emptyChecks: [UInt32: Int] = [:]
    /// What each widget panel's display shows on top (`reportWidgetTops`).
    private var widgetTops: [UInt32: String] = [:]
    private var watching: Task<Void, Never>?
    /// Tasks seen in front on display 0 (Android's own screen, never shown).
    private var frontOnDefault: Set<Int> = []
    private var defaultWatch: Task<Void, Never>?
    /// The clipboard bridge (guest/clipboard, run with app_process).
    static let clipboardJar = "/data/local/tmp/avo-clipboard.jar"
    private var clipboardWatch: Task<Void, Never>?
    /// The last text the Mac put on Android's clipboard (not echoed back).
    private var clipboardFromHost: String?
    /// Notifications passed to the Mac: key → when it was posted.
    private var shownNotifications: [String: Int64] = [:]
    /// When each notification Android lists was last read in full, and
    /// whether it was ongoing then (`notificationsDue`).
    private var readNotifications: [String: NotificationRead] = [:]
    /// Those that go away when opened (FLAG_AUTO_CANCEL), as in Android's shade.
    private var autoCancelNotifications: Set<String> = []
    /// Notifications to dismiss in Android, gathered for one helper run.
    private var pendingDismissals: Set<String> = []
    /// Notifications answered from the Mac (Reply): the app's update with the
    /// answer in it comes back quietly, as it does in Android's shade.
    private var repliedNotifications: Set<String> = []
    /// What Android plays, for the Mac's Now Playing (the helper's `media
    /// watch`), and the stream that takes its commands.
    private var mediaWatch: Task<Void, Never>?
    private var mediaStream: ADBStream?
    private var dismissing: Task<Void, Never>?
    /// Avo Links (guest/links, see "Links"): where the links Android apps
    /// open go, what was read of its log, and the task following it.
    private var linkSink: (@Sendable (URL) -> Void)?
    private var linkReader = GuestLinkReader()
    private var linkWatch: Task<Void, Never>?
    /// Installing Avo Widgets this start (true once Android has this build's copy).
    private var widgetsInstall: Task<Bool, Never>?
    /// Android's screen lock while it keeps Android locked, where its changes
    /// go, the kind of credential this start found (none: nothing to watch),
    /// and the checks and the unlock running now (see "Screen lock").
    private var screenLock: AndroidScreenLock?
    private var screenLockSink: (@Sendable (AndroidScreenLock?) -> Void)?
    private var lockCredential: AndroidScreenLock.Credential?
    private var checkingScreenLock = false
    private var unlocking = false
    /// This start's shared folder (Settings › Storage › Shared Folder;
    /// SharedFolderBridge.swift), or its leftovers to clean up when it is off.
    private var sharedFolder: SharedFolderBridge?
    /// While System Status watches: where the look's samples of Android's
    /// processes go (SystemMonitor.swift, GuestActivity.swift).
    private var processSink: (@Sendable (GuestActivity.Sample) -> Void)?
    /// Whether Android itself still answers ("Answers"): the questions so
    /// far, the task asking them, and where a change goes.
    private var answers = GuestAnswers()
    private var answerWatch: Task<Void, Never>?
    private var responsivenessSink: (@Sendable (Date?) -> Void)?

    init(engine: EngineControl, frames: FrameBridge, adbKey: ADBKey,
         connectGuest: @escaping @Sendable (UInt32) async throws -> any ByteStream) {
        self.engine = engine
        self.frames = frames
        self.adbKey = adbKey
        self.connectGuest = connectGuest
    }

    // MARK: Readiness

    /// Waits for Android, then prepares it for windows. The Control port
    /// "listens" only after this, like the real agent late in boot. The Mac
    /// asleep is no time Android had to boot.
    func prepare(deadline: SuspendingClock.Instant) async throws {
        let adb = try await connectADB(deadline: deadline)
        while try await shell("getprop sys.boot_completed").trimmed != "1" {
            guard SuspendingClock.now < deadline else { throw AvoError.timedOut("Android boot") }
            try await Task.sleep(for: .seconds(1))
        }
        _ = adb
        sdk = UInt32(try await shell("getprop ro.build.version.sdk").trimmed) ?? 0
        build = try await shell("getprop ro.build.fingerprint").trimmed
        try await provision()
        // Before the Mac hears of Android: a screen lock keeps the windows locked.
        await checkScreenLock(initial: true)
        // A listing that fails leaves `known` empty: the first poll then
        // announces every app, which is harmless (none is ever removed for it).
        known = ((try? await installedPackages()) ?? []).reduce(into: [:]) { $0[$1.package] = $1.versionCode }
        isReady = true
        Task { [weak self] in
            await self?.raiseMediaVolume()
            await self?.turnOffMissingRadios()
            await self?.declareAvoFeature()
            await self?.grantPlayServicesLocation()
            await self?.installGPUProfileLayers()
            await self?.noticeGPUDebugLayers()
            await self?.applyWiFi()
            await self?.showFourGForLTE()
            await self?.installVulkanWrapper()
        }
        Task { [weak self] in await self?.sharedFolder?.start() }
        // Each watch ends with the agent too: one an engine crash left behind
        // (no shutdown) would otherwise wake up for nothing as long as the daemon runs.
        defaultWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if await paused {
                    await whilePaused()
                    continue
                }
                // While windows are open, the task watch takes the look in its own ticks.
                if await watching == nil { await lookAround() }
                await watchScreenLock()
            }
        }
        if (try? await installClipboardHelper()) != nil {
            clipboardWatch = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await whilePaused()
                    await watchClipboard()
                    try? await Task.sleep(for: .seconds(2)) // it ended (Android restarted it): again
                }
            }
            mediaWatch = Task { [weak self] in
                var wait = Duration.seconds(2)
                while !Task.isCancelled {
                    guard let self else { return }
                    await whilePaused()
                    if await !paused {
                        let started = ContinuousClock.now
                        await watchMedia()
                        // One that ends at once (it cannot run in this Android) is tried less and less often.
                        wait = ContinuousClock.now - started < .seconds(10) ? min(wait * 2, .seconds(60)) : .seconds(2)
                    }
                    try? await Task.sleep(for: wait)
                }
            }
        }
        linkWatch = Task { [weak self] in await self?.runLinks() }
        widgetsInstall = Task { [weak self] in await self?.installWidgets() ?? false }
        answerWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: GuestAnswers.interval)
                guard let self else { return }
                if await paused {
                    await whilePaused()
                    await answersStartOver()
                    continue
                }
                await askAndroid()
            }
        }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                if await paused {
                    await whilePaused()
                    continue
                }
                await pollPackages()
            }
        }
        logger.notice("Android ready (SDK \(self.sdk), \(self.build, privacy: .public))")
    }

    /// Android's display rate this boot (`--refresh-rate`, FrameRates.androidRate):
    /// every display is plugged in at it.
    /// avo-vmm runs a Bluetooth controller this boot (netsimd): Android's
    /// Bluetooth may be on.
    func useBluetooth(_ on: Bool) {
        hasBluetooth = on
    }

    /// netsimd's HCI port (avo-vmm's `bluetooth hci` event): the Mac's
    /// devices join Android's air there while Android's Bluetooth is on.
    func useBluetoothPort(_ port: UInt16) {
        guard bluetoothBridge == nil else { return }
        let bridge = MacBluetoothBridge(port: port, sharing: shareMacBluetooth)
        bluetoothBridge = bridge
        bluetoothWatch = Task { [weak self] in
            var last: Bool?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                await whilePaused()
                guard await isReady, await !paused,
                      let output = try? await shell("settings get global bluetooth_on") else { continue }
                let on = output.trimmed == "1"
                guard on != last else { continue }
                last = on
                await bridge.setAndroidBluetooth(on)
            }
        }
    }

    func useDisplayRate(_ hz: Int) {
        displayRate = hz
    }

    /// The frame rate cap as Android's own settings, for displays at
    /// `displayRate` Hz. A lower cap is a render rate for every display
    /// (Settings.System `peak_refresh_rate`, which Android rounds down to a
    /// divisor of the display rate); without one Android runs at the
    /// displays' rate. Above 60 Hz Android's game default frame rate is off
    /// (`ro.surface_flinger.game_default_frame_rate_override`, 60): it holds
    /// games that ask for no rate of their own at 60, and stalled them to a
    /// frame a second on a 120 Hz display next to a 60 Hz one.
    static func refreshRateCommand(fps: Int, displayRate: Int) -> String {
        let peak = fps < displayRate ? "settings put system peak_refresh_rate \(VMConfig.supportedFPS(fps))"
                                     : "settings delete system peak_refresh_rate"
        return peak + " && setprop debug.graphics.game_default_frame_rate.disabled \(displayRate > FrameRates.standardRate)"
    }

    /// Android's storage (`statfs` of /data and /system), once Android is ready.
    func storage() async -> AndroidStorage? {
        // A quick statfs that Settings and every new window wait for.
        guard isReady, let output = try? await shell(AndroidStorage.statCommand, timeout: .seconds(5)) else { return nil }
        return AndroidStorage.parse(output)
    }

    /// Asks Android to power off; whether it could be asked (adbd is up:
    /// Android had booted far enough).
    @discardableResult
    func shutdown() async -> Bool {
        polling?.cancel()
        watching?.cancel()
        defaultWatch?.cancel()
        clipboardWatch?.cancel()
        mediaWatch?.cancel()
        await mediaStream?.close()
        linkWatch?.cancel()
        widgetsInstall?.cancel()
        answerWatch?.cancel()
        bluetoothWatch?.cancel()
        await bluetoothBridge?.stop()
        await sharedFolder?.stop()
        let asked = await adb?.isOpen == true
        _ = try? await root("reboot -p")
        await adb?.close()
        adb = nil
        isReady = false
        endPauseWaits()
        return asked
    }

    private func connectADB(deadline: SuspendingClock.Instant) async throws -> ADBConnection {
        var lastError: (any Error)?
        while SuspendingClock.now < deadline {
            do {
                let stream = try await connectGuest(Self.adbPort)
                let connection = ADBConnection(transport: stream, key: adbKey, keyComment: "avo-daemon")
                _ = try await connection.connect(timeout: .seconds(10))
                adb = connection
                return connection
            } catch {
                lastError = error
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw AvoError.timedOut("ADB (\(lastError.map { "\($0)" } ?? "no answer"))")
    }

    /// `timeout`: how long Android has to finish (nil: the caller's own limit applies).
    private func shell(_ command: String, timeout: Duration? = ADBConnection.shellTimeout) async throws -> String {
        guard let adb else { throw AvoError.guestUnavailable }
        let result = try await adb.shell(command, timeout: timeout)
        return result.output
    }

    /// Runs `command` as root through su (userdebug images).
    @discardableResult
    private func root(_ command: String, timeout: Duration? = ADBConnection.shellTimeout) async throws -> ShellResult {
        guard let adb else { throw AvoError.guestUnavailable }
        return try await adb.shell("su 0 sh -c " + Self.quote(command), timeout: timeout)
    }

    /// Before `prepare`: the folder avo-vmm serves this start (nil: none).
    func shareFolder(_ folder: URL?) {
        sharedFolder = SharedFolderBridge(folder: folder, run: { [weak self] command in
            try? await self?.root(command).output
        }, paused: { [weak self] in await self?.paused ?? true })
    }

    /// Whether Android has the shared folder now (nil: this start has none).
    func sharedFolderMount() async -> SharedFolderMount? {
        guard let sharedFolder, sharedFolder.folder != nil else { return nil }
        return await sharedFolder.mount
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// One-time setup per boot.
    private func provision() async throws {
        // Extra displays host their own task instead of mirroring display 0
        // (LocalDisplayAdapter: config_localDisplaysMirrorContent). Fabricated
        // overlays do not survive a reboot, so this runs every boot.
        try await root("cmd overlay fabricate --target android --name avodisplays "
                       + "android:bool/config_localDisplaysMirrorContent 0x12 0x0")
        try await root("cmd overlay enable com.android.shell:avodisplays")
        // Windows are the UI: no lock screen, no screen timeout.
        _ = try? await shell("cmd lock_settings set-disabled true")
        _ = try? await shell("settings put global stay_on_while_plugged_in 7")
        _ = try? await shell("svc power stayon true")
        _ = try? await shell("wm dismiss-keyguard")
        try await root("mkdir -p /data/system/devices/idc && chown -R system:system /data/system/devices "
                       + "&& chmod 755 /data/system/devices /data/system/devices/idc")
        // There is no UWB radio: Android's UWB service fails to turn it on and
        // files a full bug report for it (minutes of dumpstate) every boot.
        // Off stays off across boots.
        _ = try? await root("cmd uwb disable-uwb")
        // Thread's HAL simulates its radio on a second network card (eth1)
        // the engine does not have: it exits within a second, ot-daemon falls
        // with it, and init starts both again every few seconds, each time
        // leaving an unreaped ot-rcp behind. Stopped for this boot (Thread is
        // off anyway, `turnOffMissingRadios`); ot-daemon then waits quietly.
        _ = try? await root(Self.stopThreadHALCommand)
        // The kernel binds the engine's gamepad at boot; it waits unplugged
        // for a Mac controller (`drive(gamepad:)`).
        _ = try? await root(EngineGamepad.detachScript)
        // Before any app plays: no audio stream the HAL only pretends to play ("Audio").
        await dropStubAudioPorts()
        // Before any app asks for audio focus: apps in other windows keep theirs.
        await shareAudioFocus()
        // Before any app draws: Vulkan apps must not deadlock gfxstream (GuestGfxstreamSync).
        await enableGfxstreamSync()
        // Before any window resizes: in place, or by re-plugs (GuestComposer).
        await checkComposer()
        // Before any app opens a camera: the Mac's face back and front (GuestCamera).
        await setUpCameras()
    }

    /// GPU mode: installs Avo's gfxstream sync layer and names it for the
    /// apps started from now on (GuestGfxstreamSync). The property waits for
    /// the next boot when this one had no layer at its start: processes that
    /// began without the file would fail to create a Vulkan instance.
    /// Software mode removes the layer: unnamed, libvulkan still opens it in
    /// every app. So does a boot that runs Avo's Vulkan driver wrapper, which
    /// runs the layer inside the driver (GuestVulkanWrapper).
    private func enableGfxstreamSync() async {
        guard let driver = try? await shell("getprop ro.hardware.vulkan").trimmed else { return }
        let wrapped = await checkVulkanWrapper()
        guard driver == GuestGfxstreamSync.gpuModeDriver, !wrapped else {
            await removeGfxstreamSync(because: wrapped ? "Avo's Vulkan driver runs it this start" : "this Android start has no GPU")
            return
        }
        guard let installed = await installGfxstreamSync() else { return }
        guard installed != .missing else {
            logger.notice("gfxstream sync layer installed; Vulkan apps use it from the next Android start")
            return
        }
        do {
            try await root(GuestGfxstreamSync.enableCommand)
            logger.notice("gfxstream sync layer active for Vulkan apps started from now on")
        } catch {
            logger.error("gfxstream sync layer did not turn on: \(String(describing: error), privacy: .public)")
        }
    }

    /// Puts this build's gfxstream sync layer in place, unnamed. What the
    /// guest had before it (nil: the layer did not install).
    private func installGfxstreamSync() async -> GuestGfxstreamSync.Installed? {
        guard let layer = GuestGfxstreamSync.layer, let adb else { return nil }
        let sums = (try? await shell("sha256sum \(GuestGfxstreamSync.path) 2>/dev/null")) ?? ""
        let installed = GuestGfxstreamSync.installed(sumOutput: sums)
        guard installed != .current else { return installed }
        do {
            try await adb.push(AsyncStream { $0.yield(layer.data); $0.finish() }, to: GuestGfxstreamSync.staging)
            let result = try await root(GuestGfxstreamSync.installScript())
            guard result.succeeded else {
                logger.error("gfxstream sync layer did not install: \(result.errorOutput + result.output, privacy: .public)")
                return nil
            }
            return installed
        } catch {
            logger.error("gfxstream sync layer did not install: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// A start without the GPU, or with the layer inside the driver, names no
    /// gfxstream sync layer, but libvulkan would still open it in every app
    /// (GuestGfxstreamSync), so it goes.
    private func removeGfxstreamSync(because reason: String) async {
        guard let sums = try? await shell("sha256sum \(GuestGfxstreamSync.path) 2>/dev/null"),
              GuestGfxstreamSync.installed(sumOutput: sums) != .missing else { return }
        if let result = try? await root(GuestGfxstreamSync.removeScript()), result.succeeded {
            logger.notice("gfxstream sync layer removed from /data/local/debug: \(reason, privacy: .public)")
        } else {
            logger.error("gfxstream sync layer could not be removed")
        }
    }

    /// Before `prepare`: told whether Android has Avo's Vulkan driver
    /// wrapper whenever the agent learns it (VMMEngine keeps it for the next start).
    func noteVulkanWrapper(_ note: @escaping @Sendable (Bool) -> Void) {
        vulkanWrapperNoted = note
    }

    /// Before `prepare`: whether the daemon lets Avo's ANGLE wrapper run
    /// (GuestGLESWrapper.allowed), and who to tell whether Android has it.
    func useGLESWrapper(allowed: Bool, note: @escaping @Sendable (Bool) -> Void) {
        glesWrapperAllowed = allowed
        glesWrapperNoted = note
    }

    /// Avo's Vulkan driver wrapper (GuestVulkanWrapper): whether it runs the
    /// gfxstream sync layer this boot. Putting it in, or this build of it,
    /// waits until Android is ready (`installVulkanWrapper`): it applies from
    /// the next GPU start anyway.
    private func checkVulkanWrapper() async -> Bool {
        guard GuestVulkanWrapper.wrapper != nil, let output = try? await root(GuestVulkanWrapper.stateCommand).output else {
            return false
        }
        vulkanWrapperAllowed = (try? await shell("getprop \(GuestVulkanWrapper.switchProperty)"))?.trimmed == "1"
        let state = GuestVulkanWrapper.state(output: output)
        vulkanWrapperState = state
        vulkanWrapperRuns = false
        switch state {
        case .running:
            setVulkanWrapper(true)
            vulkanWrapperRuns = true
            logger.notice("Vulkan driver: Avo's wrapper runs the gfxstream sync layer this start")
            return true
        case .pending:
            setVulkanWrapper(true)
            noteVulkanWrapperNextStart()
        case .unknown:
            setVulkanWrapper(false)
            logger.notice("Vulkan driver: unknown vendor build; the gfxstream sync layer stays in /data/local/debug")
        case .stock:
            setVulkanWrapper(false)
        }
        return false
    }

    /// Once Android is ready: puts the wrapper in for the next GPU start, or
    /// this build of it over an older one that runs, unless the wrapper
    /// failed a GPU start (the engine then leaves it off).
    private func installVulkanWrapper() async {
        switch vulkanWrapperState {
        case let .running(current: false, build?)?:
            if await pushVulkanWrapper(), (try? await root(GuestVulkanWrapper.updateScript(build)))?.succeeded == true {
                logger.notice("Vulkan driver: Avo's wrapper updated for the apps started from now on")
            }
        case let .stock(build)? where vulkanWrapperAllowed:
            guard await pushVulkanWrapper(), (try? await root(GuestVulkanWrapper.installScript(build)))?.succeeded == true else {
                logger.notice("Vulkan driver: Avo's wrapper not installed (no remount overlays?); the gfxstream sync layer stays in /data/local/debug")
                return
            }
            setVulkanWrapper(true)
            noteVulkanWrapperNextStart()
        default:
            break
        }
    }

    private func setVulkanWrapper(_ installed: Bool) {
        hasVulkanWrapper = installed
        vulkanWrapperNextStart = installed && vulkanWrapperAllowed
        vulkanWrapperNoted?(installed)
    }

    private func noteVulkanWrapperNextStart() {
        if vulkanWrapperAllowed {
            logger.notice("Vulkan driver: Avo's wrapper runs the gfxstream sync layer from the next GPU start")
        } else {
            logger.notice("Vulkan driver: Avo's wrapper stays off (it failed a GPU start); the gfxstream sync layer stays in /data/local/debug")
        }
    }

    /// This build's wrapper to `GuestVulkanWrapper.staged`.
    private func pushVulkanWrapper() async -> Bool {
        guard let wrapper = GuestVulkanWrapper.wrapper, let adb else { return false }
        do {
            try await adb.push(AsyncStream { $0.yield(wrapper.data); $0.finish() }, to: GuestVulkanWrapper.staged)
            return true
        } catch {
            logger.error("Vulkan driver: Avo's wrapper did not copy: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Cuttlefish binds a full bug report to the A+B key chord
    /// (init.cutf_cvm.rc, "keycodes 30 48"), which typing or a game can
    /// press on the Mac's keyboard: stop it before it takes minutes of CPU.
    /// `state`: `getprop init.svc.bugreport` (`lookAround`).
    private func stopChordBugreport(_ state: String) async {
        guard isReady, state.trimmed == "running" else { return }
        _ = try? await root("setprop ctl.stop bugreport")
        logger.notice("stopped the bug report Android starts for the A+B key chord")
    }

    /// Android's media volume starts at a third, which plays 33 dB under the
    /// Mac's other apps: like any Mac app, Android plays at full scale and the
    /// Mac's volume sets how loud (Quick Settings and Settings › Devices turn
    /// Android's own down). Once per data disk, and once more on disks from
    /// before those sliders (marker 2), where something in Android had left
    /// it low; after that the user's setting stands.
    private func raiseMediaVolume() async {
        let marker = "2"
        guard (try? await shell("settings get global avo_media_volume_set"))?.trimmed != marker,
              let volume = try? await mediaVolume() else { return }
        _ = try? await setMediaVolume(volume.maximum)
        _ = try? await shell("settings put global avo_media_volume_set \(marker)")
    }

    // MARK: Media volume

    /// AudioManager.STREAM_MUSIC: what apps and games play on.
    static let musicStream = 3

    /// Android's media volume, for the volume sliders.
    func mediaVolume() async throws -> AndroidVolume {
        let output = try await shell("cmd media_session volume --stream \(Self.musicStream) --get")
        guard let volume = Self.mediaVolume(from: output) else {
            throw AvoError.internalError(String(localized: "Android did not say its volume.", bundle: .avoKit))
        }
        return volume
    }

    /// Sets the media volume, within its steps; Android shows no volume panel.
    func setMediaVolume(_ level: Int) async throws -> AndroidVolume {
        let maximum = try await mediaVolume().maximum
        let level = min(max(level, 0), maximum)
        // As root: Android's audio hardening ignores volume changes from the shell user.
        try await root("cmd media_session volume --stream \(Self.musicStream) --set \(level)")
        return AndroidVolume(level: level, maximum: maximum)
    }

    /// "volume is 3 in range [0..15]" (`cmd media_session volume --get`).
    static func mediaVolume(from output: String) -> AndroidVolume? {
        guard let range = output.range(of: #"volume is \d+ in range \[0\.\.\d+\]"#, options: .regularExpression) else { return nil }
        // The level, 0, the maximum.
        let numbers = output[range].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count == 3, numbers[2] > 0 else { return nil }
        return AndroidVolume(level: numbers[0], maximum: numbers[2])
    }

    /// Stops Cuttlefish's Thread HAL when the image has one (init keeps a
    /// stopped service down until the next boot).
    static let stopThreadHALCommand =
        "[ -n \"$(getprop init.svc.vendor.threadnetwork_hal)\" ] && setprop ctl.stop vendor.threadnetwork_hal"

    /// Cuttlefish runs Android's Bluetooth and Thread radios against host
    /// simulators: left on without one, Bluetooth crashes and starts again
    /// every minute. Thread never has one, Bluetooth has netsimd when the
    /// Android Emulator is there and Settings › Devices gives Android
    /// Bluetooth (`useBluetooth`). Thread goes off once per data disk, like a
    /// phone with it off; Bluetooth without a controller at every start.
    private func turnOffMissingRadios() async {
        // Bluetooth at every start: it may have been on with a controller
        // before (Settings › Devices turns Bluetooth off, or the Android
        // Emulator went), and left on without one it crashes over and over.
        if !hasBluetooth { _ = try? await root("cmd bluetooth_manager disable") }
        guard (try? await shell("settings get global avo_radios_off"))?.trimmed != "1" else { return }
        _ = try? await root("cmd thread_network disable")
        _ = try? await shell("settings put global avo_radios_off 1")
    }

    /// Avo's system feature (`IdentityFeature`), where /product keeps
    /// changes: written once, counted from the next boot. The `ro.boot.avo.*`
    /// properties need nothing here; the engine sets them at every boot.
    private func declareAvoFeature() async {
        guard let check = try? await root(IdentityFeature.checkCommand()), check.succeeded,
              IdentityFeature.needsWrite(checkOutput: check.output) else { return }
        let result = try? await root(IdentityFeature.writeScript())
        if let result, result.succeeded {
            logger.notice("declared \(AvoIdentity.feature, privacy: .public) in \(IdentityFeature.path, privacy: .public); apps see it from the next Android start")
        } else {
            logger.error("could not declare \(AvoIdentity.feature, privacy: .public): \(result.map { $0.errorOutput + $0.output } ?? "no answer", privacy: .public)")
        }
    }

    /// Google Play services answers apps' location requests (its fused and
    /// network providers), so Android grants it location by default, but
    /// only when it first sets up or after a system update: Google apps
    /// added later never get it, and then no app that asks Play services for
    /// a location gets one, the Mac's or a chosen place alike. Granted every
    /// boot while it lacks them, unless the user decided (Settings › Apps).
    private func grantPlayServicesLocation() async {
        let names = Self.playServicesLocation.joined(separator: "|")
        guard let dump = try? await shell("dumpsys package \(GoogleApps.playServices) | grep -E '(\(names)): granted='") else { return }
        let missing = Self.permissionsToGrant(Self.playServicesLocation, dump: dump)
        guard !missing.isEmpty else { return }
        for permission in missing {
            _ = try? await shell("pm grant \(GoogleApps.playServices) \(permission)")
        }
        logger.notice("granted Google Play services \(missing.joined(separator: ", "), privacy: .public)")
    }

    /// Foreground location before background, which needs it.
    static let playServicesLocation = [
        "android.permission.ACCESS_FINE_LOCATION", "android.permission.ACCESS_COARSE_LOCATION",
        "android.permission.ACCESS_BACKGROUND_LOCATION",
    ]

    /// Of `permissions`, those `dumpsys package` lists as not granted and not
    /// set by the user or a policy (its first line for each: user 0's runtime
    /// permissions), in order. None when the package is not there.
    static func permissionsToGrant(_ permissions: [String], dump: String) -> [String] {
        let lines = dump.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let decided: Set<Substring> = ["USER_SET", "USER_FIXED", "POLICY_FIXED", "SYSTEM_FIXED"]
        return permissions.filter { permission in
            guard let line = lines.first(where: { $0.hasPrefix(permission + ": granted=") }),
                  line.hasPrefix(permission + ": granted=false") else { return false }
            // `flags=[ USER_SENSITIVE_WHEN_GRANTED|USER_SET]`
            let flags = line.range(of: "flags=[").map { line[$0.upperBound...].prefix { $0 != "]" } } ?? ""
            return decided.isDisjoint(with: flags.split(whereSeparator: { $0 == "|" || $0 == " " }))
        }
    }

    /// Installs Avo's GPU layers, and turns them on when this boot emulates a
    /// phone's GPU: the engine set `debug.avo.gl.*` / `debug.avo.vk.*` at
    /// first boot (`DeviceHardware.gpuProperties`), and `debug.gles.layers` /
    /// `debug.vulkan.layers` load the layers — naming a missing Vulkan layer
    /// system-wide at boot stops graphics services from starting, which is
    /// why the engine does not. The files go under `/data/local/debug`
    /// (GuestGPUProfile) only on a boot that emulates a GPU, and a boot that
    /// emulates none removes them: unnamed, libvulkan still opens the Vulkan
    /// one in every app. A layer is named only on a boot that began with its
    /// file there, so a process started before the install cannot fail to
    /// create a Vulkan instance for it (`stageGPULayers` puts the files in
    /// before the restart a setting needs). The properties are set every boot
    /// (they reset). An app started after this reads the profile's GPU from
    /// its own `glGetString` and Vulkan.
    ///
    /// A boot the Vulkan driver wrapper runs carries the Vulkan layer inside
    /// the HAL driver (guest/vkwrap): that boot installs and names the GLES
    /// layer alone, takes the Vulkan layer out of `/data/local/debug` — that
    /// path needs `ro.debuggable=1` — and leaves `debug.vulkan.layers` unset.
    private func installGPUProfileLayers() async {
        guard !GuestGPUProfile.layers.isEmpty, let check = try? await shell(GuestGPUProfile.checkCommand) else { return }
        await checkGLESWrapper()
        let vulkan = !vulkanWrapperRuns, gles = !glesWrapperRuns
        let sums = await gpuProfileSums()
        var present = GuestGPUProfile.present(sumOutput: sums)
        if !vulkan, present.contains(GuestGPUProfile.vulkanFile) {
            await removeVulkanProfileLayer()
            present.remove(GuestGPUProfile.vulkanFile)
        }
        if !gles, present.contains(DeviceHardware.glesLayer) {
            await removeGLESProfileLayer()
            present.remove(DeviceHardware.glesLayer)
        }
        // A boot that emulates a GPU puts the ANGLE wrapper in for the next
        // GPU start, when Android can take it.
        if GuestGPUProfile.wantsGLES(checkOutput: check) { await installGLESWrapper() }
        let enable = GuestGPUProfile.enableCommands(checkOutput: check, present: present, vulkan: vulkan, gles: gles)
        let wanted = GuestGPUProfile.enableCommands(checkOutput: check, present: GuestGPUProfile.names, vulkan: vulkan, gles: gles)
        guard !wanted.isEmpty else {
            // Nothing to name: the profile asks for nothing, or the wrappers carry it.
            await removeGPUProfileLayers(present: present)
            return
        }
        guard await installGPUProfileFiles(sumOutput: sums, vulkan: vulkan, gles: gles) else { return }
        if enable.count < wanted.count {
            logger.notice("Avo GPU layers installed; apps read the profile's GPU from the next Android start")
        }
        guard !enable.isEmpty else { return }
        do {
            _ = try await root(enable.joined(separator: "; "))
            logger.notice("Avo GPU layers active; apps read the profile's GPU this boot")
        } catch {
            logger.error("Avo GPU layers did not turn on: \(String(describing: error), privacy: .public)")
        }
    }

    /// The Vulkan profile layer a boot without the wrapper left in
    /// `/data/local/debug`, which the wrapper makes needless — and which
    /// libvulkan, on a userdebug image, would still open in every app:
    /// it goes (`installGPUProfileLayers`).
    private func removeVulkanProfileLayer() async {
        if let result = try? await root(GuestGPUProfile.removeVulkanScript()), result.succeeded {
            logger.notice("Avo Vulkan GPU layer removed from /data/local/debug: the driver wrapper runs it this start")
        } else {
            logger.error("Avo Vulkan GPU layer could not be removed")
        }
    }

    /// The GLES profile layer a boot without the ANGLE wrapper left in
    /// `/data/local/debug`, which the wrapper makes needless: it goes
    /// (`installGPUProfileLayers`).
    private func removeGLESProfileLayer() async {
        if let result = try? await root(GuestGPUProfile.removeGLESScript()), result.succeeded {
            logger.notice("Avo GLES GPU layer removed from /data/local/debug: Avo's ANGLE wrapper answers this start")
        } else {
            logger.error("Avo GLES GPU layer could not be removed")
        }
    }

    /// Avo's ANGLE wrapper (GuestGLESWrapper): whether it runs this boot.
    private func checkGLESWrapper() async {
        guard GuestGLESWrapper.wrapper != nil, let output = try? await root(GuestGLESWrapper.stateCommand).output else { return }
        let state = GuestGLESWrapper.state(output: output)
        glesWrapperState = state
        glesWrapperRuns = false
        switch state {
        case .running:
            glesWrapperRuns = true
            setGLESWrapper(true)
            logger.notice("GLES: Avo's ANGLE wrapper reports the profile's GPU this start")
        case .pending:
            setGLESWrapper(true)
        case .stock, .unknown:
            setGLESWrapper(false)
        }
    }

    /// Puts the ANGLE wrapper in for the next GPU start that emulates a GPU,
    /// or this build of it over an older one that runs, unless it failed a
    /// GPU start (the engine then leaves it off).
    private func installGLESWrapper() async {
        if glesWrapperState == nil { await checkGLESWrapper() }
        switch glesWrapperState {
        case let .running(current: false, build?)?:
            if await pushGLESWrapper(), (try? await root(GuestGLESWrapper.updateScript(build)))?.succeeded == true {
                logger.notice("GLES: Avo's ANGLE wrapper updated for the next Android start")
            }
        case let .stock(build)? where glesWrapperAllowed:
            guard await pushGLESWrapper(), (try? await root(GuestGLESWrapper.installScript(build)))?.succeeded == true else {
                logger.notice("GLES: Avo's ANGLE wrapper not installed (no remount overlays?); the GLES layer stays in /data/local/debug")
                return
            }
            glesWrapperState = .pending
            setGLESWrapper(true)
            logger.notice("GLES: Avo's ANGLE wrapper reports the profile's GPU from the next GPU start")
        default:
            break
        }
    }

    private func setGLESWrapper(_ installed: Bool) {
        glesWrapperNextStart = installed && glesWrapperAllowed
        glesWrapperNoted?(installed)
    }

    /// This build's ANGLE wrapper to `GuestGLESWrapper.staged`.
    private func pushGLESWrapper() async -> Bool {
        guard let wrapper = GuestGLESWrapper.wrapper, let adb else { return false }
        do {
            try await adb.push(AsyncStream { $0.yield(wrapper.data); $0.finish() }, to: GuestGLESWrapper.staged)
            return true
        } catch {
            logger.error("GLES: Avo's ANGLE wrapper did not copy: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// `sha256sum` of the guest's GPU layers (GuestGPUProfile), empty when it has none.
    private func gpuProfileSums() async -> String {
        let installed = GuestGPUProfile.layers.map { "\($0.dir)/\($0.name)" }.joined(separator: " ")
        return (try? await shell("sha256sum \(installed) 2>/dev/null")) ?? ""
    }

    /// Puts this build's GPU layers in place, unnamed, unless `sums` shows
    /// the guest has them. With `vulkan: false`, the GLES layer alone: the
    /// Vulkan driver wrapper runs the Vulkan one. False when they did not
    /// install.
    private func installGPUProfileFiles(sumOutput sums: String, vulkan: Bool = true, gles: Bool = true) async -> Bool {
        guard !GuestGPUProfile.upToDate(sumOutput: sums, vulkan: vulkan, gles: gles) else { return true }
        guard let adb else { return false }
        do {
            _ = try await shell("mkdir -p \(GuestGPUProfile.staging)")
            for layer in GuestGPUProfile.layersToInstall(vulkan: vulkan, gles: gles) {
                try await adb.push(AsyncStream { $0.yield(layer.data); $0.finish() },
                                   to: "\(GuestGPUProfile.staging)/\(layer.name)")
            }
            let result = try await root(GuestGPUProfile.installScript(vulkan: vulkan, gles: gles))
            guard result.succeeded else {
                logger.error("Avo GPU layers did not install: \(result.errorOutput + result.output, privacy: .public)")
                return false
            }
            return true
        } catch {
            logger.error("Avo GPU layers did not install: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// A boot that emulates no GPU names neither layer, but libvulkan would
    /// still open the Vulkan one in every app (GuestGPUProfile), so they go.
    private func removeGPUProfileLayers(present: Set<String>) async {
        guard !present.isEmpty else { return }
        if let result = try? await root(GuestGPUProfile.removeScript()), result.succeeded {
            logger.notice("Avo GPU layers removed: this Android start emulates no GPU")
        } else {
            logger.error("Avo GPU layers could not be removed")
        }
    }

    /// Settings ask the next start for the profile's GPU (`profile`) or for
    /// the GPU itself (`gfxstreamSync`): their layers go in now, unnamed, so
    /// that start begins with them and names them at once. What a setting
    /// turns off goes at that start (`installGPUProfileLayers`,
    /// `enableGfxstreamSync`): a layer this boot named stays while its
    /// processes run. A GPU start that runs Avo's Vulkan driver wrapper needs
    /// no gfxstream sync layer there, and carries the Vulkan profile layer
    /// itself: the next start stages the GLES layer alone.
    func stageGPULayers(profile: Bool, gfxstreamSync: Bool) async {
        guard isReady else { return }
        if profile, !GuestGPUProfile.layers.isEmpty {
            // A GPU start the wrapper runs carries the Vulkan profile layer;
            // a software start, or one without the wrapper, still needs its
            // file in /data/local/debug.
            // Likewise the ANGLE wrapper for the GLES one: a GPU start only.
            await installGLESWrapper()
            let vulkan = !gfxstreamSync || !vulkanWrapperNextStart
            let gles = !gfxstreamSync || !glesWrapperNextStart
            let sums = await gpuProfileSums()
            if !GuestGPUProfile.upToDate(sumOutput: sums, vulkan: vulkan, gles: gles),
               await installGPUProfileFiles(sumOutput: sums, vulkan: vulkan, gles: gles) {
                logger.notice("Avo GPU layers installed for the next Android start")
            }
        }
        if gfxstreamSync, !vulkanWrapperNextStart, let before = await installGfxstreamSync(), before != .current {
            logger.notice("gfxstream sync layer installed for the next Android start")
        }
    }

    /// Android's GPU debug layer settings replace Avo's layers in the app
    /// they name (GuestGPUDebugLayers): said once at boot, and again when
    /// that app is launched. The settings stay as they are.
    private func noticeGPUDebugLayers(launching package: String? = nil) async {
        guard let output = try? await shell(GuestGPUDebugLayers.checkCommand),
              let override = GuestGPUDebugLayers.override(checkOutput: output),
              package == nil || package == override.app else { return }
        logger.notice("\(override.notice, privacy: .public)")
    }

    /// The engine's network is Android's Wi-Fi: the "VirtWifi" access point
    /// (virt_wifi over eth2, engine/hvf/vmm/src/net.rs). Android joins it
    /// once per data disk; after that Wi-Fi is whatever the user makes it in
    /// Android's settings.
    /// Settings › Devices: on (joined to VirtWifi once per data disk) or off
    /// (Android is offline), at every start (Android keeps its own switch
    /// too) and when the setting changes.
    private func applyWiFi() async {
        guard wifiWanted else {
            _ = try? await shell("cmd wifi set-wifi-enabled disabled")
            return
        }
        _ = try? await shell("cmd wifi set-wifi-enabled enabled")
        await joinWiFi()
    }

    /// Settings › Devices changed (or a start begins): applied at once when Android is up.
    func applyDeviceSettings(wifi: Bool, shareMacBluetooth: Bool, cellular: Bool = false) async {
        let wifiChanged = wifi != wifiWanted
        let simInserted = cellular && !cellularWanted
        wifiWanted = wifi
        cellularWanted = cellular
        self.shareMacBluetooth = shareMacBluetooth
        await bluetoothBridge?.setSharing(shareMacBluetooth)
        if wifiChanged, isReady { await applyWiFi() }
        if simInserted, isReady { Task { await showFourGForLTE() } }
    }

    /// Android's status bar says LTE for 4G unless the carrier's
    /// configuration asks for "4G", as most carriers' do; the modem's test
    /// SIM (PLMN 001/01, engine/hvf/vmm/src/modem.rs) does not. Once its
    /// subscription is up, Avo asks for 4G, persistently (`-p`): Android keeps
    /// it for that SIM across starts. Telephony takes that from the shell
    /// only on a build that is not `user`: a device profile that names a
    /// phone's own build (`ro.build.type=user`) keeps "LTE".
    private func showFourGForLTE() async {
        guard cellularWanted else { return }
        if (try? await shell("getprop ro.build.type"))?.trimmed == "user" {
            logger.notice("mobile network: the device profile's user build keeps the status bar's \"LTE\"")
            return
        }
        for _ in 0..<60 {
            if (try? await shell("getprop gsm.sim.state"))?.contains("LOADED") == true {
                let result = try? await root("cmd phone cc set-value -p show_4g_for_lte_data_icon_bool true")
                if result?.succeeded != true {
                    logger.error("mobile network: LTE stays \"LTE\" in the status bar: \((result?.output ?? "") + (result?.errorOutput ?? ""), privacy: .public)")
                }
                return
            }
            try? await Task.sleep(for: .seconds(1))
            guard cellularWanted else { return }
        }
        logger.notice("mobile network: the SIM was not loaded after a minute; LTE stays \"LTE\" in the status bar")
    }

    private func joinWiFi() async {
        guard (try? await shell("settings get global avo_wifi_joined"))?.trimmed != "1" else { return }
        _ = try? await shell("cmd wifi set-wifi-enabled enabled")
        var asked = false
        for _ in 0..<30 {
            if (try? await shell("cmd wifi status"))?.contains("Wifi is connected") == true {
                _ = try? await shell("settings put global avo_wifi_joined 1")
                logger.notice("Android is on Wi-Fi")
                return
            }
            if !asked, (try? await shell("cmd wifi list-scan-results"))?.contains("VirtWifi") == true {
                _ = try? await shell("cmd wifi connect-network VirtWifi open")
                asked = true
            }
            try? await Task.sleep(for: .seconds(1))
        }
        logger.error("Android did not join Wi-Fi; it tries again next boot")
    }

    // MARK: Control channel

    func serveControl(_ stream: FileDescriptorStream) async {
        control = stream
        var decoder = ControlFrameDecoder()
        do {
            for try await chunk in stream.incoming {
                decoder.append(chunk)
                while let envelope = try decoder.next() {
                    if case .ping(let ping)? = envelope.payload {
                        // Keepalive answers never wait behind a slow request.
                        var pong = Avo_V1_Pong()
                        pong.nonce = ping.nonce
                        await send(Avo_V1_Envelope(.pong(pong), requestID: envelope.requestID))
                    } else {
                        // Requests run concurrently (launching an app takes seconds).
                        Task { await self.handle(envelope) }
                    }
                }
            }
        } catch {
            logger.debug("control channel closed: \(String(describing: error), privacy: .public)")
        }
        if control === stream { control = nil }
    }

    private func send(_ envelope: Avo_V1_Envelope) async {
        guard let control else { return }
        try? await control.write(ControlFraming.encode(envelope))
    }

    private func reply(_ request: Avo_V1_Envelope, _ status: Avo_V1_Reply.Status = .ok, message: String = "") async {
        var reply = Avo_V1_Reply()
        reply.status = status
        reply.message = message
        await send(Avo_V1_Envelope(.reply(reply), requestID: request.requestID))
    }

    private func handle(_ envelope: Avo_V1_Envelope) async {
        do {
            switch envelope.payload {
            case .hello?:
                var hello = Avo_V1_Hello()
                hello.protocolVersion = AvoProtocol.version
                hello.minProtocolVersion = AvoProtocol.minimumVersion
                hello.softwareVersion = "avo-host-agent " + build
                hello.androidSdk = sdk
                hello.deviceProfileID = DeviceProfile.defaultID
                await send(Avo_V1_Envelope(.hello(hello)))
            case .listApps(let request)?:
                var list = Avo_V1_AppList()
                list.apps = try await appInfos(includeSystem: request.includeSystem)
                await send(Avo_V1_Envelope(.appList(list), requestID: envelope.requestID))
            case .launch(let launch)?:
                try await self.launch(launch)
                await reply(envelope)
            case .resize(let resize)?:
                try await self.resize(resize)
                await reply(envelope)
            case .close(let close)?:
                await self.close(close.displayID)
                await reply(envelope)
            case .uninstall(let request)?:
                let output = try await shell("pm uninstall " + Self.quote(request.package))
                await reply(envelope, output.contains("Success") ? .ok : .failed, message: output.trimmed)
            case .forceStop(let request)?:
                _ = try await shell("am force-stop " + Self.quote(request.package))
                await reply(envelope)
            case .deleteAppData(let request)?:
                let output = try await shell("pm clear " + Self.quote(request.package))
                await reply(envelope, output.contains("Success") ? .ok : .failed, message: output.trimmed)
            case .getPermissions(let request)?:
                var list = Avo_V1_PermissionList()
                list.package = request.package
                list.permissions = try await permissions(of: request.package)
                await send(Avo_V1_Envelope(.permissionList(list), requestID: envelope.requestID))
            case .setPermission(let request)?:
                let verb = request.granted ? "grant" : "revoke"
                let result = try await adbShell("pm \(verb) \(Self.quote(request.package)) \(Self.quote(request.permission))")
                await reply(envelope, result.succeeded ? .ok : .failed, message: result.errorOutput.trimmed)
            case .install(let request)?:
                let output = try await shell("pm install -r " + Self.quote(request.path))
                await reply(envelope, output.contains("Success") ? .ok : .failed, message: output.trimmed)
            case .setClipboard(let request)?:
                // Remembered so the watcher does not hand it back to the Mac.
                clipboardFromHost = request.text
                let encoded = Data(request.text.utf8).base64EncodedString()
                if encoded.count <= 96 * 1024 {
                    _ = try await shell(Self.clipboardCommand("set " + encoded))
                } else {
                    // One shell command carries it, and has a length limit.
                    logger.notice("the Mac's clipboard is too long for Android's (\(request.text.utf8.count) bytes): Android keeps what it had")
                }
                await reply(envelope)
            case .openNotification(let request)?:
                // Opening one (its app's window comes to the front) dismisses it when its app says so.
                if autoCancelNotifications.contains(request.key) { dismissNotification(request.key) }
                await reply(envelope)
            case .dismissNotification(let request)?:
                dismissNotification(request.key)
                await reply(envelope)
            case .performNotificationAction(let request)?:
                var command = "act \(Self.quote(request.key)) \(request.index)"
                if !request.replyText.isEmpty { command += " " + Data(request.replyText.utf8).base64EncodedString() }
                let result = try await adbShell(Self.clipboardCommand(command))
                if result.succeeded, !request.replyText.isEmpty { repliedNotifications.insert(request.key) }
                await reply(envelope, result.succeeded ? .ok : .failed, message: result.errorOutput.trimmed)
            case .mediaCommand(let request)?:
                guard let line = Self.mediaCommandLine(request), let mediaStream else {
                    await reply(envelope, .failed, message: "nothing plays")
                    break
                }
                try await mediaStream.write(Data((line + "\n").utf8))
                await reply(envelope)
            case .setRefreshRate(let request)?:
                // A cap under the displays' rate is a render rate for every
                // display, which Android applies at once.
                let result = try await adbShell(Self.refreshRateCommand(fps: Int(request.fps), displayRate: displayRate))
                await reply(envelope, result.succeeded ? .ok : .failed, message: result.errorOutput.trimmed)
            case .setDisplayVisibility(let request)?:
                // Android goes on drawing; the frames nobody sees are not copied.
                frames.setVisible(request.displayID, visible: request.visible)
                await reply(envelope)
            case .focusDisplay(let request)?:
                await focusDisplay(request.displayID)
                await reply(envelope)
            case .shareFiles(let request)?:
                try await share(request)
                await reply(envelope)
            default:
                if envelope.requestID != 0 { await reply(envelope, .unsupported) }
            }
        } catch {
            logger.error("request failed: \(String(describing: error), privacy: .public)")
            if envelope.requestID != 0 {
                await reply(envelope, .failed, message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    private func adbShell(_ command: String, timeout: Duration? = ADBConnection.shellTimeout) async throws -> ShellResult {
        guard let adb else { throw AvoError.guestUnavailable }
        return try await adb.shell(command, timeout: timeout)
    }

    // MARK: Displays

    private func launch(_ launch: Avo_V1_Launch) async throws {
        // The lock screen covers every display until Android is unlocked
        // (the window shows its own lock meanwhile).
        if screenLock != nil { throw AvoError.androidLocked }
        // Claimed right after the last look, with no await between: requests
        // run concurrently. A closed window's scanout waits until Android has
        // let it go (`release`), so when only those are left, so does this.
        var free = Self.freeScanout(in: Self.scanouts, taken: takenScanouts)
        let deadline = ContinuousClock.now + .seconds(6)
        while free == nil, !releasing.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            free = Self.freeScanout(in: Self.scanouts, taken: takenScanouts)
        }
        guard let scanout = free else { throw AvoError.displayUnavailable("too many windows") }
        // virtio-gpu modes are 8-pixel aligned.
        let width = max(64, launch.width / 8 * 8)
        let height = max(64, launch.height)
        displays[launch.displayID] = Display(id: launch.displayID, scanout: scanout, package: launch.package,
                                             androidID: nil, width: width, height: height, dpi: launch.dpi,
                                             inputWidth: launch.width, inputHeight: launch.height, dataURI: launch.dataUri)
        frames.assign(scanout: scanout, to: launch.displayID)
        do {
            try await engine.send("display \(scanout) \(width) \(height) \(displayRate)")
            let (androidID, uniqueID) = try await waitForDisplay(scanout: scanout)
            // The window may have resized or closed meanwhile.
            guard var display = displays[launch.displayID] else { throw AvoError.displayUnavailable("closed") }
            display.androidID = androidID
            display.uniqueID = uniqueID
            display.appliedWidth = width
            display.appliedHeight = height
            display.appliedDPI = display.dpi
            displays[launch.displayID] = display
            if display.dpi > 0 { _ = try? await shell("wm density \(display.dpi) -d \(androidID)") }
            try await associateTouchscreen(scanout: scanout, uniqueID: uniqueID)

            // A task the app already has on Android's own screen (started by
            // adb or another app, or sent to the background) moves here as it
            // is; otherwise the app starts here.
            if launch.package == AndroidWidgets.package {
                // A widget panel: Avo Widgets shows the panel's widget.
                guard await widgetsInstall?.value == true else { throw AvoError.displayUnavailable("Avo Widgets is not installed") }
                let output = try await shell(GuestWidgets.startCommand(data: launch.dataUri, display: androidID))
                if output.contains("Error") || output.contains("Exception") {
                    throw AvoError.displayUnavailable(output.trimmed)
                }
            } else if launch.component.isEmpty,
               let task = Self.rootTask(of: launch.package, onDisplay: 0, in: try await shell("am stack list")) {
                _ = try await shell("am display move-stack \(task) \(androidID)")
            } else {
                let component = launch.component.isEmpty ? try await launcherComponent(launch.package) : launch.component
                let output = try await shell(Self.startCommand(component, display: androidID))
                if output.contains("Error") || output.contains("Exception") {
                    throw AvoError.displayUnavailable(output.trimmed)
                }
            }
            focusedDisplay = launch.displayID
            // A notification click that opened this window.
            if autoCancelNotifications.contains(launch.notificationKey) { dismissNotification(launch.notificationKey) }
        } catch {
            await close(launch.displayID)
            throw error
        }
        var ready = Avo_V1_DisplayReady()
        ready.displayID = launch.displayID
        ready.package = launch.package
        await send(Avo_V1_Envelope(.displayReady(ready)))
        startedAt[launch.displayID] = .now
        watchTasks()
        Task { [weak self] in await self?.noticeGPUDebugLayers(launching: launch.package) }
        // A resize that came in while launching.
        try await applySize(launch.displayID)
    }

    private func resize(_ resize: Avo_V1_Resize) async throws {
        guard var display = displays[resize.displayID] else { throw AvoError.displayUnavailable("unknown display") }
        display.width = max(64, resize.width / 8 * 8)
        display.height = max(64, resize.height)
        display.inputWidth = resize.width
        display.inputHeight = resize.height
        if resize.dpi > 0 { display.dpi = resize.dpi }
        displays[resize.displayID] = display
        // Before Android knows the display, launch applies size and density
        // and then runs the loop; the reply waits for that.
        guard display.androidID != nil else { return await waitForResize(resize.displayID) }
        // The loop sets the density once: live when the size stays, after
        // the plug when it changes.
        try await applySize(resize.displayID)
    }

    // MARK: Resize loop (DisplayResizing, run by `applySize`)

    func modes(of id: UInt32) -> (wanted: DisplayMode, applied: DisplayMode)? {
        guard let display = displays[id], display.androidID != nil else { return nil }
        return (DisplayMode(width: display.width, height: display.height, dpi: display.dpi),
                DisplayMode(width: display.appliedWidth, height: display.appliedHeight, dpi: display.appliedDPI))
    }

    /// Avo's composer (GuestComposer) gives the display its new size in
    /// place. The image's composer ignores new modes of a connected display,
    /// so the display is unplugged and plugged in again at the new size:
    /// Android moves the display's tasks to display 0 and back when it
    /// returns (under a new display id), and the app lays out for the new size.
    func replug(_ id: UInt32, to mode: DisplayMode) async throws {
        if resizesInPlace, try await resize(id, inPlaceTo: mode) { return }
        guard let display = displays[id] else { return }
        try await engine.send("display \(display.scanout) off")
        // Plugged back before Android let go of it, the display would keep
        // its old mode, or SurfaceFlinger would crash (`waitForDisplayRemoved`).
        try await waitForDisplayRemoved(scanout: display.scanout, uniqueID: display.uniqueID)
        guard displays[id] != nil else { return } // closed meanwhile
        try await engine.send("display \(display.scanout) \(mode.width) \(mode.height) \(displayRate)")
        let (androidID, uniqueID) = try await waitForDisplay(scanout: display.scanout)
        guard var current = displays[id] else { return }
        current.androidID = androidID
        current.uniqueID = uniqueID
        current.appliedWidth = mode.width
        current.appliedHeight = mode.height
        // The newest density, which may have changed during the plug.
        current.appliedDPI = current.dpi
        displays[id] = current
        if current.dpi > 0 { _ = try? await shell("wm density \(current.dpi) -d \(androidID)") }
        try await bringBack(current, to: androidID)
    }

    /// The scanout takes the new mode while plugged: the composer reports it
    /// and DisplayManager gives the same display its new size, with the app
    /// on it. False when Android did not take it in time (then it re-plugs).
    private func resize(_ id: UInt32, inPlaceTo mode: DisplayMode) async throws -> Bool {
        guard let display = displays[id], let androidID = display.androidID else { return false }
        try await engine.send("display \(display.scanout) \(mode.width) \(mode.height) \(displayRate)")
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
            guard var current = displays[id] else { return true } // closed meanwhile
            let size = Self.modeSize(androidID: androidID, in: try await shell("cmd display get-displays"))
            guard let size, size.width == mode.width, size.height == mode.height else { continue }
            current.appliedWidth = mode.width
            current.appliedHeight = mode.height
            // A density that changed meanwhile is the loop's next step.
            displays[id] = current
            return true
        }
        logger.error("display \(androidID) did not take \(mode.width)x\(mode.height) in place; re-plugging it")
        return false
    }

    /// The size of display `androidID`'s mode in `cmd display get-displays`
    /// (`… supportedModes [{id=38, …, width=432, height=892, …`), which does
    /// not turn with the display as `real` does.
    static func modeSize(androidID: Int, in output: String) -> (width: UInt32, height: UInt32)? {
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("Display id \(androidID): ") }),
              let modes = line.range(of: "supportedModes [{") else { return nil }
        func value(_ name: String) -> UInt32? {
            guard let start = line.range(of: name + "=", range: modes.upperBound..<line.endIndex) else { return nil }
            return UInt32(line[start.upperBound...].prefix { $0.isNumber })
        }
        guard let width = value("width"), let height = value("height") else { return nil }
        return (width, height)
    }

    func applyDensity(_ id: UInt32, _ dpi: UInt32) async {
        guard var display = displays[id], let androidID = display.androidID else { return }
        display.appliedDPI = dpi
        displays[id] = display
        _ = try? await shell("wm density \(dpi) -d \(androidID)")
    }

    /// Android 17 restores a re-plugged display's tasks; older versions
    /// leave them on display 0.
    private func bringBack(_ display: Display, to androidID: Int) async throws {
        let tasks = try await shell("am stack list")
        if Self.hasTask(of: display.package, onDisplay: androidID, in: tasks) { return }
        // A widget panel's activity ended with its display (WidgetActivity):
        // it starts again, or the task watch would close the panel.
        if display.package == AndroidWidgets.package {
            _ = try await shell(GuestWidgets.startCommand(data: display.dataURI, display: androidID))
            return
        }
        let component = try await launcherComponent(display.package)
        _ = try await shell(Self.startCommand(component, display: androidID))
    }

    /// Files dropped on a window, already in Downloads, offered to its app as
    /// the Bridge Agent offers them: Android's media index gives each one a
    /// content URI, and ACTION_SEND starts on the window's display, letting
    /// the app read it. `am` cannot pass a list of streams (ACTION_SEND_MULTIPLE):
    /// of several files, the app gets the first; all are in Downloads. An app
    /// that takes no shared files leaves them there.
    private func share(_ request: Avo_V1_ShareFiles) async throws {
        guard let display = displays[request.displayID], let androidID = display.androidID else {
            throw AvoError.displayUnavailable("unknown display")
        }
        var shared: (uri: String, type: String)?
        for (index, path) in request.paths.enumerated() where shared == nil {
            let output = (try? await shell(GuestSharedFolder.scanCommand(path), timeout: .seconds(15))) ?? ""
            guard let uri = Self.contentURI(inScanOutput: output) else { continue }
            shared = (uri, index < request.mimeTypes.count ? request.mimeTypes[index] : "*/*")
        }
        guard let shared else { throw AvoError.internalError("Android could not index the shared files") }
        if request.paths.count > 1 {
            logger.notice("shared the first of \(request.paths.count) files with \(display.package, privacy: .public); all are in Downloads")
        }
        // As the shell, which may grant what it reads (the system itself may not).
        let output = try await shell(Self.shareCommand(uri: shared.uri, type: shared.type, package: display.package, display: androidID))
        if output.contains("Error") || output.contains("Exception") {
            logger.notice("\(display.package, privacy: .public) takes no shared files: \(output.trimmed, privacy: .public)")
        }
    }

    /// The URI `content call … scan_file` answers with (its Bundle's EXTRA_STREAM).
    static func contentURI(inScanOutput output: String) -> String? {
        guard let start = output.range(of: "content://") else { return nil }
        let uri = output[start.lowerBound...].prefix { !$0.isWhitespace && !",}]".contains($0) }
        return uri.count > "content://".count ? String(uri) : nil
    }

    /// ACTION_SEND of one stream to `package` on `display`. The URI is the
    /// intent's data too: `am` grants a read of the data, not of an extra.
    static func shareCommand(uri: String, type: String, package: String, display: Int) -> String {
        "am start --user 0 --display \(display) -a android.intent.action.SEND -t \(quote(type)) -d \(quote(uri)) "
            + "--eu android.intent.extra.STREAM \(quote(uri)) --grant-read-uri-permission \(quote(package))"
    }

    /// Starts the app the way a launcher does (NEW_TASK | RESET_TASK_IF_NEEDED):
    /// a task that already runs, in the background or on Android's own
    /// screen, moves to the display as it is instead of starting over.
    static func startCommand(_ component: String, display: Int) -> String {
        "am start --display \(display) -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -f 0x10200000 -n "
            + quote(component)
    }

    /// A widget panel's display shows its widget, or the widget's settings
    /// while it is being set up (the panel is larger then): each change goes
    /// to the panel as the display's content (`title`: the top activity).
    private func reportWidgetTops(_ output: String) async {
        for display in displays.values where display.package == AndroidWidgets.package {
            guard let androidID = display.androidID,
                  let top = Self.topActivity(of: AndroidWidgets.package, onDisplay: androidID, in: output),
                  widgetTops[display.id] != top else { continue }
            widgetTops[display.id] = top
            var changed = Avo_V1_DisplayContentChanged()
            changed.displayID = display.id
            changed.package = display.package
            changed.title = top
            await send(Avo_V1_Envelope(.displayContentChanged(changed)))
        }
    }

    /// `taskId=66: com.avodroid.widgets/… visible=true topActivity=ComponentInfo{com.example/com.example.Setup}`:
    /// the top activity of `package`'s task on a display.
    static func topActivity(of package: String, onDisplay androidID: Int, in output: String) -> String? {
        var onDisplay = false
        for line in output.split(separator: "\n") {
            if line.hasPrefix("RootTask ") {
                onDisplay = line.contains(" displayId=\(androidID) ")
            } else if onDisplay, line.contains(": \(package)/"), let range = line.range(of: "topActivity=ComponentInfo{") {
                return String(line[range.upperBound...].prefix { $0 != "}" })
            }
        }
        return nil
    }

    /// `RootTask id=20 bounds=[…] displayId=3 …` followed by its
    /// `  taskId=20: dev.example/.Main …` lines.
    static func hasTask(of package: String, onDisplay androidID: Int, in output: String) -> Bool {
        var onDisplay = false
        for line in output.split(separator: "\n") {
            if line.hasPrefix("RootTask ") {
                onDisplay = line.contains(" displayId=\(androidID) ")
            } else if onDisplay, line.contains(": \(package)/") {
                return true
            }
        }
        return false
    }

    /// The real agent reports a task that ends (Back on the app's first
    /// screen, finish(), a crash) so its window closes; from outside
    /// Android, displays are checked for a visible task every 2 seconds.
    private func watchTasks() {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if await self?.paused == true { continue }
                guard let self else { return }
                // The default display's look meanwhile, with the same listing of the tasks.
                let stacks = await lookAround()
                guard await checkTasks(stacks: stacks) else { return }
            }
        }
    }

    /// Two checks a moment apart (a display counts as empty after two).
    private func checkTasksSoon() {
        Task { [weak self] in
            for _ in 0..<2 {
                try? await Task.sleep(for: .milliseconds(500))
                _ = await self?.checkTasks()
            }
        }
    }

    /// False once no display is left to watch. `stacks`: the look's `am stack list`.
    private func checkTasks(stacks: String? = nil) async -> Bool {
        guard !displays.isEmpty else {
            watching = nil
            return false
        }
        // New displays get a moment for their app to appear.
        let settled = displays.keys.filter { id in startedAt[id].map { ContinuousClock.now - $0 > .seconds(3) } ?? false }
        guard !settled.isEmpty else { return true }
        var output = stacks
        if output == nil { output = try? await shell("am stack list") }
        guard let output else { return true }
        await reportWidgetTops(output)
        for id in settled {
            guard let androidID = displays[id]?.androidID, !resizing.contains(id) else { continue }
            if Self.hasVisibleTask(onDisplay: androidID, in: output) {
                emptyChecks[id] = 0
                continue
            }
            let count = emptyChecks[id, default: 0] + 1
            emptyChecks[id] = count
            guard count >= 2, let package = displays[id]?.package else { continue }
            var closed = Avo_V1_TaskClosed()
            closed.displayID = id
            closed.package = package
            await send(Avo_V1_Envelope(.taskClosed(closed)))
            await close(id)
        }
        return true
    }

    /// The look every 2 s: the tasks (`checkDefaultDisplay`), the
    /// notifications and the A+B bug report, read in one shell call; each
    /// command alone would be a shell process more in Android. `cmd activity`
    /// is what `am` runs. While System Status watches, Android's processes
    /// come along in the same call. Returns the tasks' listing for the task watch.
    @discardableResult
    private func lookAround() async -> String? {
        let marker = Self.shellMarker()
        let sink = processSink
        var command = "cmd activity stack list; echo \(marker); cmd notification list; echo \(marker); getprop init.svc.bugreport"
        if sink != nil { command += "; echo \(marker); " + GuestActivity.command(marker: marker) }
        guard isReady, let output = try? await shell(command) else { return nil }
        let parts = Self.sections(of: output, marker: marker)
        guard parts.count == 3 + (sink != nil ? GuestActivity.sections : 0) else { return nil }
        if let sink { sink(GuestActivity.sample(ps: parts[3], files: parts[4], at: .now)) }
        await checkDefaultDisplay(parts[0])
        await checkNotifications(list: parts[1])
        await stopChordBugreport(parts[2])
        return parts[0]
    }

    /// System Status: Android's processes with every look while `sink` is set.
    func sampleProcesses(_ sink: (@Sendable (GuestActivity.Sample) -> Void)?) {
        processSink = sink
    }

    /// Frames published so far for each package with a window, its windows together.
    func windowFrames() -> [String: UInt64] {
        let published = frames.publishedFrames()
        var counts: [String: UInt64] = [:]
        for display in displays.values {
            if let count = published[display.scanout] { counts[display.package, default: 0] += count }
        }
        return counts
    }

    /// A line no command prints, between the outputs of one shell call.
    static func shellMarker() -> String {
        "avo-\(UInt64.random(in: 1...UInt64.max))"
    }

    /// The outputs of commands run in one shell call, split at the `echo <marker>` lines between them.
    static func sections(of output: String, marker: String) -> [String] {
        var sections: [String] = []
        var lines: [Substring] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmed == marker {
                sections.append(lines.joined(separator: "\n"))
                lines = []
            } else {
                lines.append(line)
            }
        }
        sections.append(lines.joined(separator: "\n"))
        return sections
    }

    // MARK: Clipboard and notifications (the agent's NotificationListener and clipboard)

    static func clipboardCommand(_ arguments: String) -> String {
        "CLASSPATH=\(clipboardJar) app_process / com.avodroid.clipboard.Main " + arguments
    }

    private func installClipboardHelper() async throws {
        guard let adb, let jar = Data(base64Encoded: ClipboardHelper.jar) else { throw AvoError.guestUnavailable }
        try await adb.push(AsyncStream { $0.yield(jar); $0.finish() }, to: Self.clipboardJar)
    }

    /// Android's clipboard as it changes ("clip BASE64" lines), to the Mac.
    private func watchClipboard() async {
        guard let adb, let stream = try? await adb.open("shell:" + Self.clipboardCommand("watch")) else { return }
        var buffer = Data()
        do {
            for try await chunk in stream.incoming {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self).trimmed
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard line.hasPrefix("clip "), let data = Data(base64Encoded: String(line.dropFirst(5))) else { continue }
                    let text = String(decoding: data, as: UTF8.self)
                    guard text != clipboardFromHost else { continue }
                    var changed = Avo_V1_ClipboardChanged()
                    changed.text = text
                    await send(Avo_V1_Envelope(.clipboardChanged(changed)))
                }
            }
        } catch {}
        await stream.close()
    }

    /// The apps' notifications as macOS notifications: new and updated ones
    /// are posted, gone ones removed. Ongoing ones (music, downloads) stay in
    /// Android.
    /// `list`: the look's `cmd notification list` (nil: asked for here).
    private func checkNotifications(list: String? = nil) async {
        guard isReady else { return }
        var list = list
        if list == nil { list = try? await shell("cmd notification list") }
        guard let list else { return }
        let keys = Self.notificationKeys(in: list).filter { key in known[Self.package(ofNotification: key)] != nil }
        // Only new ones, and the others now and then: each look reading every
        // one again was a shell call every 2 s for as long as one lingered.
        let now = ContinuousClock.now
        let due = Self.notificationsDue(keys, read: readNotifications, now: now)
        readNotifications = readNotifications.filter { keys.contains($0.key) }
        // Every one in one shell call, not a shell process more for each.
        let marker = Self.shellMarker()
        var dumps: [String] = []
        if !due.isEmpty,
           let output = try? await shell(due.map { "cmd notification get \(Self.quote($0)); echo \(marker)" }.joined(separator: "; ")) {
            dumps = Self.sections(of: output, marker: marker)
        }
        var posting: [Avo_V1_Notification] = []
        var withButtons: [String] = []
        for (index, key) in due.enumerated() {
            guard index < dumps.count, let info = Self.parseNotification(dumps[index]) else { continue }
            readNotifications[key] = NotificationRead(at: now, ongoing: info.ongoing)
            guard !info.ongoing, shownNotifications[key] != info.postedAt else { continue }
            shownNotifications[key] = info.postedAt
            if info.autoCancel { autoCancelNotifications.insert(key) } else { autoCancelNotifications.remove(key) }
            var notification = Avo_V1_Notification()
            notification.package = info.package
            notification.key = key
            notification.title = info.title
            notification.body = info.text
            notification.postedAtMs = info.postedAt
            notification.silent = info.importance < 3 || repliedNotifications.remove(key) != nil
            if info.actions > 0 { withButtons.append(key) }
            posting.append(notification)
        }
        // Their buttons, from the helper: the dump names them, not what they take.
        if !withButtons.isEmpty,
           let output = try? await shell(Self.clipboardCommand("actions " + withButtons.map(Self.quote).joined(separator: " "))) {
            let buttons = Self.parseNotificationActions(output)
            for index in posting.indices { posting[index].actions = buttons[posting[index].key] ?? [] }
        }
        for notification in posting { await send(Avo_V1_Envelope(.notification(notification))) }
        for key in shownNotifications.keys where !keys.contains(key) {
            shownNotifications[key] = nil
            autoCancelNotifications.remove(key)
            repliedNotifications.remove(key)
            var removed = Avo_V1_NotificationRemoved()
            removed.key = key
            await send(Avo_V1_Envelope(.notificationRemoved(removed)))
        }
    }

    /// Dismisses a notification in Android as a swipe in its shade does (the
    /// helper's `dismiss`); ones asked for together go in one run. The next
    /// look reports it gone, which takes it off the Mac.
    private func dismissNotification(_ key: String) {
        guard !key.isEmpty else { return }
        pendingDismissals.insert(key)
        guard dismissing == nil else { return }
        dismissing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            await self?.runDismissals()
        }
    }

    private func runDismissals() async {
        let keys = pendingDismissals.sorted()
        pendingDismissals = []
        dismissing = nil
        guard !keys.isEmpty else { return }
        let command = Self.clipboardCommand("dismiss " + keys.map(Self.quote).joined(separator: " "))
        if let result = try? await adbShell(command), result.succeeded, result.output.contains("dismissed") {
            await checkNotifications()
        } else {
            logger.error("could not dismiss \(keys.count) notifications in Android")
        }
    }

    /// A notification read in full (`cmd notification get`).
    struct NotificationRead: Equatable {
        var at: ContinuousClock.Instant
        var ongoing: Bool
    }

    /// How long a notification that was read stays unread: an app that
    /// updates it under the same key (a chat's next message) reaches the Mac
    /// within this. Ongoing ones, which stay in Android, are read less often,
    /// only to see one stop being ongoing.
    static let notificationReread = Duration.seconds(10)
    static let ongoingNotificationReread = Duration.seconds(60)

    /// Which of `keys` a look reads in full: the new ones, and the others
    /// once their time since the last read passed.
    static func notificationsDue(_ keys: [String], read: [String: NotificationRead], now: ContinuousClock.Instant) -> [String] {
        keys.filter { key in
            guard let last = read[key] else { return true }
            return now - last.at >= (last.ongoing ? ongoingNotificationReread : notificationReread)
        }
    }

    /// `cmd notification list`: `0|com.example|12|tag|10123` per line (user 0 only).
    static func notificationKeys(in list: String) -> [String] {
        list.split(separator: "\n").map(\.trimmed).filter { $0.hasPrefix("0|") && $0.split(separator: "|").count >= 5 }
    }

    static func package(ofNotification key: String) -> String {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        return parts.count > 1 ? String(parts[1]) : ""
    }

    struct NotificationInfo: Equatable {
        var package = ""
        var title = ""
        var text = ""
        var postedAt: Int64 = 0
        var ongoing = false
        var importance = 3
        /// FLAG_AUTO_CANCEL: opening it dismisses it.
        var autoCancel = false
        /// How many buttons it has (`actions=` of the record line).
        var actions = 0
    }

    /// `cmd notification get <key>`: the record line, `flags=`, `when=`,
    /// `android.title=String (…)` and `android.text=String (…)`.
    static func parseNotification(_ dump: String) -> NotificationInfo? {
        var info = NotificationInfo()
        func value(_ line: Substring, after marker: String) -> Substring? {
            guard let range = line.range(of: marker) else { return nil }
            return line[range.upperBound...].prefix { !$0.isWhitespace && $0 != ")" && $0 != ":" }
        }
        func text(_ line: Substring) -> String {
            // `android.title=String (Hello (again))`: everything inside the outer parentheses.
            guard let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { return "" }
            return String(line[line.index(after: open)..<close])
        }
        var flags = 0
        var flagNames = ""
        var flagsRead = false
        for line in dump.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("NotificationRecord(") {
                info.package = value(trimmed, after: "pkg=").map(String.init) ?? ""
                info.importance = value(trimmed, after: "importance=").flatMap { Int($0) } ?? 3
                info.actions = value(trimmed, after: " actions=").flatMap { Int($0) } ?? 0
            } else if trimmed.hasPrefix("flags="), let raw = value(trimmed, after: "flags=") {
                // Hex, a number, or names (`AUTO_CANCEL|GROUP_SUMMARY|…`) depending on the release.
                flags = raw.hasPrefix("0x") ? Int(raw.dropFirst(2), radix: 16) ?? 0 : Int(raw) ?? 0
                flagNames = String(raw)
                flagsRead = true
            } else if trimmed.hasPrefix("when="), let raw = value(trimmed, after: "when=") {
                info.postedAt = Int64(raw.prefix { $0.isNumber }) ?? 0
            } else if trimmed.hasPrefix("android.title=") {
                info.title = text(trimmed)
            } else if trimmed.hasPrefix("android.text=") {
                info.text = text(trimmed)
            }
        }
        guard !info.package.isEmpty else { return nil }
        // FLAG_ONGOING_EVENT, FLAG_FOREGROUND_SERVICE, FLAG_GROUP_SUMMARY.
        let names = flagNames.split(separator: "|")
        info.ongoing = flags & (0x2 | 0x40 | 0x200) != 0
            || names.contains { ["ONGOING_EVENT", "FOREGROUND_SERVICE", "GROUP_SUMMARY", "AUTOGROUP_SUMMARY"].contains(String($0)) }
        // FLAG_AUTO_CANCEL; without flags it goes, as most notifications do.
        info.autoCancel = !flagsRead || flags & 0x10 != 0 || names.contains("AUTO_CANCEL")
        return info
    }

    /// The helper's `actions`: one `{"key", "actions": [{"index", "title", "reply", "hint"?}]}` per line.
    static func parseNotificationActions(_ output: String) -> [String: [Avo_V1_NotificationAction]] {
        struct Line: Decodable {
            struct Button: Decodable {
                var index: UInt32
                var title: String
                var reply: Bool
                var hint: String?
            }
            var key: String
            var actions: [Button]
        }
        var buttons: [String: [Avo_V1_NotificationAction]] = [:]
        for line in output.split(separator: "\n") {
            guard let decoded = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)) else { continue }
            buttons[decoded.key] = decoded.actions.map { button in
                var action = Avo_V1_NotificationAction()
                action.index = button.index
                action.title = button.title
                action.reply = button.reply
                action.replyHint = button.hint ?? ""
                return action
            }
        }
        return buttons
    }

    // MARK: Now Playing (the helper's `media watch`)

    /// What Android plays as it changes, to the Mac; the commands from there
    /// go to the same helper (`mediaCommand`). Ends with the helper, which
    /// leaves nothing playing on the Mac until it runs again.
    private func watchMedia() async {
        guard let adb, let stream = try? await adb.open("exec:" + Self.clipboardCommand("media watch")) else { return }
        mediaStream = stream
        var buffer = Data()
        var showing = false
        do {
            for try await chunk in stream.incoming {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self).trimmed
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let playing = Self.nowPlaying(fromLine: line) else { continue }
                    showing = !playing.package.isEmpty
                    await send(Avo_V1_Envelope(.nowPlaying(playing)))
                }
            }
        } catch {}
        if mediaStream === stream { mediaStream = nil }
        await stream.close()
        if showing { await send(Avo_V1_Envelope(.nowPlaying(Avo_V1_NowPlaying()))) }
    }

    /// `media none` (nothing plays: no package) or `media {JSON}` (see guest/clipboard Media.java).
    static func nowPlaying(fromLine line: String) -> Avo_V1_NowPlaying? {
        guard line.hasPrefix("media ") else { return nil }
        let rest = line.dropFirst(6)
        if rest == "none" { return Avo_V1_NowPlaying() }
        struct Line: Decodable {
            var package: String
            var title: String
            var artist: String
            var album: String
            var durationMs: Int64
            var positionMs: Int64
            var speed: Double
            var state: String
            var next: Bool
            var previous: Bool
            var seek: Bool
            var artworkJpeg: String?
        }
        guard let decoded = try? JSONDecoder().decode(Line.self, from: Data(rest.utf8)), !decoded.package.isEmpty else { return nil }
        var playing = Avo_V1_NowPlaying()
        playing.package = decoded.package
        playing.title = decoded.title
        playing.artist = decoded.artist
        playing.album = decoded.album
        playing.durationMs = decoded.durationMs
        playing.positionMs = decoded.positionMs
        playing.speed = Float(decoded.speed)
        playing.state = switch decoded.state {
        case "playing": .playing
        case "paused": .paused
        case "buffering": .buffering
        default: .stopped
        }
        playing.canNext = decoded.next
        playing.canPrevious = decoded.previous
        playing.canSeek = decoded.seek
        if let artwork = decoded.artworkJpeg {
            playing.artworkChanged = true
            playing.artworkJpeg = Data(base64Encoded: artwork) ?? Data()
        }
        return playing
    }

    /// The helper's line for a command (nil: none to send).
    static func mediaCommandLine(_ command: Avo_V1_MediaCommand) -> String? {
        switch command.command {
        case .play: "play"
        case .pause: "pause"
        case .toggle: "toggle"
        case .next: "next"
        case .previous: "previous"
        case .stop: "stop"
        case .seek: "seek \(max(command.positionMs, 0))"
        case .unspecified, .UNRECOGNIZED: nil
        }
    }

    /// An installed app in front on Android's own screen was started by
    /// adb, another app or the system: ask the host for a window (once per
    /// time it comes to the front), or move it into the app's window whose
    /// task just ended (`moveIntoEndedWindow`).
    /// `output`: `am stack list` (`lookAround`).
    private func checkDefaultDisplay(_ output: String) async {
        guard isReady else { return }
        // Android starts a new task on the display it last used: an app opened
        // by adb or by another app can land in some app's window. It goes back
        // to Android's own screen and gets a window of its own. System
        // activities (permission dialogs, share sheets) are not installed apps
        // and stay where they are.
        var moved: Set<Int> = []
        var taken: Set<UInt32> = []
        for display in displays.values where !resizing.contains(display.id) {
            guard let androidID = display.androidID else { continue }
            for task in Self.visibleRootTasks(onDisplay: androidID, in: output) where task.package != display.package {
                guard known[task.package] != nil else {
                    // A widget's tap opened an app Avo has no window for: it
                    // leaves the widget's display, which shows the widget only.
                    if display.package == AndroidWidgets.package { _ = try? await shell("am display move-stack \(task.root) 0") }
                    continue
                }
                if await moveIntoEndedWindow(task.root, of: task.package, in: output, taken: &taken) { continue }
                _ = try? await shell("am display move-stack \(task.root) 0")
                moved.insert(task.root)
                var started = Avo_V1_TaskStarted()
                started.package = task.package
                started.taskID = Int32(task.root)
                await send(Avo_V1_Envelope(.taskStarted(started)))
            }
        }
        frontOnDefault.formUnion(moved)
        let front = Self.visibleTasks(onDisplay: 0, in: output)
        let frontRoots = Self.visibleRootTasks(onDisplay: 0, in: output)
        var movedIn: Set<Int> = []
        for task in front where !frontOnDefault.contains(task.id) && known[task.package] != nil {
            if let root = frontRoots.first(where: { $0.package == task.package })?.root,
               await moveIntoEndedWindow(root, of: task.package, in: output, taken: &taken) {
                movedIn.insert(task.id)
                continue
            }
            var started = Avo_V1_TaskStarted()
            started.package = task.package
            started.taskID = Int32(task.id)
            await send(Avo_V1_Envelope(.taskStarted(started)))
        }
        // An app adb installed a moment ago is not known until the next
        // package poll: its task gets a window at the look after that. A task
        // moved into a window that closed meanwhile is back here by the next
        // look and gets a window of its own then.
        frontOnDefault = Set(front.filter { known[$0.package] != nil && !movedIn.contains($0.id) }.map(\.id))
    }

    /// `flutter run` and Android Studio force-stop the app, install it and
    /// start it again over adb, often before the task watch has closed the
    /// app's window, which is empty since the stop (`checkTasks`). That
    /// window takes the new task: asked for a window instead, the app's shim
    /// would quit with the old one right after, and the app would stay on
    /// Android's own screen. True when the task was moved to such a window.
    private func moveIntoEndedWindow(_ root: Int, of package: String, in output: String,
                                     taken: inout Set<UInt32>) async -> Bool {
        let window = displays.values.first { display in
            // Windows still starting their app are not empty, only early.
            guard display.package == package, !taken.contains(display.id), !resizing.contains(display.id),
                  let androidID = display.androidID,
                  let started = startedAt[display.id], ContinuousClock.now - started > .seconds(3) else { return false }
            return !Self.hasVisibleTask(onDisplay: androidID, in: output)
        }
        guard let window, let androidID = window.androidID,
              let result = try? await shell("am display move-stack \(root) \(androidID)"),
              !result.contains("Exception"), !result.contains("Error") else { return false }
        taken.insert(window.id)
        // Closed meanwhile: Android sent the task back to its own screen.
        guard displays[window.id] != nil else { return true }
        // As after a launch, the task gets a moment to show before the window is checked again.
        startedAt[window.id] = .now
        emptyChecks[window.id] = 0
        focusedDisplay = window.id
        return true
    }

    /// The root task holding one of the package's tasks on a display.
    static func rootTask(of package: String, onDisplay androidID: Int, in output: String) -> Int? {
        var root: Int?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("RootTask ") {
                root = line.contains(" displayId=\(androidID) ")
                    ? Int(line.dropFirst("RootTask id=".count).prefix { $0.isNumber }) : nil
            } else if let root, line.contains(": \(package)/") {
                return root
            }
        }
        return nil
    }

    /// Visible tasks on a display with the root task holding each.
    static func visibleRootTasks(onDisplay androidID: Int, in output: String) -> [(root: Int, package: String)] {
        var root: Int?
        var tasks: [(root: Int, package: String)] = []
        for line in output.split(separator: "\n") {
            if line.hasPrefix("RootTask ") {
                root = line.contains(" displayId=\(androidID) ")
                    ? Int(line.dropFirst("RootTask id=".count).prefix { $0.isNumber }) : nil
                continue
            }
            if isSystemRootTask(line) { root = nil }
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let root, text.hasPrefix("taskId="), text.contains(" visible=true"),
                  let colon = text.firstIndex(of: ":"), let slash = text.firstIndex(of: "/"), colon < slash else { continue }
            tasks.append((root, text[text.index(after: colon)..<slash].trimmingCharacters(in: .whitespaces)))
        }
        return tasks
    }

    /// A root task's configuration line (right under `RootTask …`) naming the
    /// home screen, recents or a dream: never an app to give a window. While
    /// Android is locked after it starts, its home is Settings' FallbackHome,
    /// which must not open Android Settings' window.
    static func isSystemRootTask(_ line: Substring) -> Bool {
        guard line.hasPrefix(" configuration=") || line.hasPrefix("  configuration=") else { return false }
        return ["mActivityType=home", "mActivityType=recents", "mActivityType=dream", "mActivityType=assistant"]
            .contains { line.contains($0) }
    }

    /// Visible tasks on a display: `  taskId=37: dev.example/.Main … visible=true …`.
    static func visibleTasks(onDisplay androidID: Int, in output: String) -> [(id: Int, package: String)] {
        var onDisplay = false
        var tasks: [(id: Int, package: String)] = []
        for line in output.split(separator: "\n") {
            if line.hasPrefix("RootTask ") {
                onDisplay = line.contains(" displayId=\(androidID) ")
                continue
            }
            if isSystemRootTask(line) { onDisplay = false }
            let text = line.trimmingCharacters(in: .whitespaces)
            guard onDisplay, text.hasPrefix("taskId="), text.contains(" visible=true"),
                  let colon = text.firstIndex(of: ":"), let slash = text.firstIndex(of: "/"),
                  let id = Int(text[text.index(text.startIndex, offsetBy: 7)..<colon]) else { continue }
            let package = text[text.index(after: colon)..<slash].trimmingCharacters(in: .whitespaces)
            tasks.append((id, package))
        }
        return tasks
    }

    /// Whether `am stack list` shows a visible task on the display.
    static func hasVisibleTask(onDisplay androidID: Int, in output: String) -> Bool {
        var onDisplay = false
        for line in output.split(separator: "\n") {
            if line.hasPrefix("RootTask ") {
                onDisplay = line.contains(" displayId=\(androidID) ")
            } else if onDisplay, line.contains("taskId="), line.contains(" visible=true") {
                return true
            }
        }
        return false
    }

    /// Waits until Android has let go of an unplugged scanout's display
    /// (`displayReleased`): only then may the scanout be plugged again.
    ///
    /// The composer forgets the display as soon as it reports the unplug,
    /// so SurfaceFlinger's list loses the display's EDID (`port=`) at once,
    /// but SurfaceFlinger drops the display itself only at its next commit,
    /// a frame or more later. A plug in that gap reaches SurfaceFlinger
    /// before the commit: it then takes the new display for the old one,
    /// the commit deletes the new one's HWComposer state, and the next frame
    /// composites a display HWComposer no longer has (a null pointer in
    /// `HWComposer::executeCommands`). SurfaceFlinger restarts, and every
    /// app with it. A plug before Android noticed at all would also keep the
    /// old mode.
    private func waitForDisplayRemoved(scanout: Int, uniqueID: String?) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        let marker = Self.shellMarker()
        while ContinuousClock.now < deadline {
            let output = try await shell("dumpsys SurfaceFlinger --display-id; echo \(marker); cmd display get-displays")
            let parts = Self.sections(of: output, marker: marker)
            if parts.count == 2,
               Self.displayReleased(scanout: scanout, uniqueID: uniqueID, surfaceFlinger: parts[0], displays: parts[1]) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AvoError.displayUnavailable("Android did not remove display \(scanout)")
    }

    /// Whether Android has let go of the display behind `scanout`: no line of
    /// SurfaceFlinger's `--display-id` names its HWC display or port, not even
    /// one without identification data (`Display 4619827124781842690 (HWC
    /// display 2): no display identification data`, the display SurfaceFlinger
    /// still composites after the composer forgot it), and DisplayManager's
    /// `cmd display get-displays` no longer has its unique id (when known).
    /// The composer's HWC display ids and ports are the scanout indexes.
    static func displayReleased(scanout: Int, uniqueID: String?, surfaceFlinger: String, displays: String) -> Bool {
        for line in surfaceFlinger.split(separator: "\n") where line.hasPrefix("Display ") {
            if line.contains("(HWC display \(scanout))") || line.contains("port=\(scanout) ") || line.hasSuffix("port=\(scanout)") {
                return false
            }
        }
        guard let uniqueID else { return true }
        return logicalDisplayID(uniqueID: uniqueID, in: displays) == nil
    }

    /// Scanouts no new window may take: those with a window and those
    /// Android may still hold (`releasing`).
    private var takenScanouts: Set<Int> {
        Set(displays.values.map(\.scanout)).union(releasing)
    }

    /// The lowest scanout of `range` not in `taken`.
    static func freeScanout(in range: Range<Int>, taken: Set<Int>) -> Int? {
        range.first { !taken.contains($0) }
    }

    /// Gives a closed window's scanout back to new windows once Android has
    /// let go of it, or after `waitForDisplayRemoved`'s time limit (or at
    /// once without ADB, when Android is going away anyway).
    private func release(scanout: Int, uniqueID: String?) async {
        defer { releasing.remove(scanout) }
        try? await waitForDisplayRemoved(scanout: scanout, uniqueID: uniqueID)
    }

    private func close(_ id: UInt32) async {
        // A resize waiting for the launch or the loop has nothing left to wait for.
        defer { finishResize(id) }
        guard let display = displays.removeValue(forKey: id) else { return }
        widgetTops[id] = nil
        // Before the first await, so no launch takes the scanout meanwhile.
        releasing.insert(display.scanout)
        touches[id] = nil
        startedAt[id] = nil
        emptyChecks[id] = nil
        if focusedDisplay == id { focusedDisplay = nil }
        frames.assign(scanout: display.scanout, to: nil)
        // Unplugging the display moves its task to display 0: the app keeps
        // running in the background, as on a phone.
        try? await engine.send("display \(display.scanout) off")
        Task { [weak self] in await self?.release(scanout: display.scanout, uniqueID: display.uniqueID) }
        // The window that drove the gamepad is gone (it closed, or its shim
        // quit or crashed): so is the controller.
        if gamepadDisplay == id || displays.isEmpty { await drive(gamepad: GamepadState(pad: 0, connected: false)) }
    }

    /// The Android display behind `scanout` (its HWC port), once it appears.
    private func waitForDisplay(scanout: Int) async throws -> (Int, String) {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            let physical = try await shell("dumpsys SurfaceFlinger --display-id")
            if let id = Self.physicalDisplayID(port: scanout, in: physical) {
                let uniqueID = "local:\(id)"
                let displays = try await shell("cmd display get-displays")
                if let androidID = Self.logicalDisplayID(uniqueID: uniqueID, in: displays) {
                    return (androidID, uniqueID)
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw AvoError.displayUnavailable("Android did not add display \(scanout)")
    }

    /// `Display 4619827551948147201 (HWC display 1): port=1 …`
    static func physicalDisplayID(port: Int, in output: String) -> String? {
        for line in output.split(separator: "\n") where line.contains("port=\(port) ") || line.hasSuffix("port=\(port)") {
            let words = line.split(separator: " ")
            if words.count > 1, words[0] == "Display" { return String(words[1]) }
        }
        return nil
    }

    /// `Display id 2: DisplayInfo{"Built-in Screen", displayId 2, … uniqueId "local:…", …}`
    static func logicalDisplayID(uniqueID: String, in output: String) -> Int? {
        for line in output.split(separator: "\n") where line.hasPrefix("Display id ") && line.contains("uniqueId \"\(uniqueID)\"") {
            let number = line.dropFirst("Display id ".count).prefix { $0.isNumber }
            return Int(number)
        }
        return nil
    }

    /// Ties the engine's touchscreen for `scanout` to the Android display:
    /// an .idc file (read when the input device opens), then a rebind of the
    /// virtio device so Android opens it again.
    private func associateTouchscreen(scanout: Int, uniqueID: String) async throws {
        guard touchTargets[scanout] != uniqueID else { return }
        let file = String(format: "/data/system/devices/idc/Vendor_1af4_Product_%04x.idc", 0x0100 + scanout)
        let current = try await root("cat \(file) 2>/dev/null").output
        let wanted = "touch.deviceType = touchScreen\ntouch.displayId = \(uniqueID)\n"
        if current != wanted {
            let name = "Avo Touch Screen \(scanout)"
            try await root("""
                printf '%s' \(Self.quote(wanted)) > \(file) && chown system:system \(file) && chmod 644 \(file); \
                for d in /sys/class/input/input*; do \
                  if [ "$(cat $d/name)" = \(Self.quote(name)) ]; then \
                    v=$(basename $(readlink -f $d/device)); \
                    echo $v > /sys/bus/virtio/drivers/virtio_input/unbind; \
                    echo $v > /sys/bus/virtio/drivers/virtio_input/bind; \
                  fi; \
                done
                """)
        }
        touchTargets[scanout] = uniqueID
    }

    private func launcherComponent(_ package: String) async throws -> String {
        let output = try await shell("cmd package resolve-activity --brief -a android.intent.action.MAIN "
                                     + "-c android.intent.category.LAUNCHER " + Self.quote(package))
        guard let component = output.split(separator: "\n").last.map(String.init)?.trimmed, component.contains("/") else {
            throw AvoError.packageNotFound(package)
        }
        return component
    }

    // MARK: Packages

    struct InstalledPackage {
        let package: String
        let path: String
        let versionCode: Int64
        let system: Bool
    }

    /// `package:/data/app/…/base.apk=com.example versionCode:12`
    static func parsePackages(_ output: String, system: Bool) -> [InstalledPackage] {
        output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("package:") else { return nil }
            var rest = line.dropFirst("package:".count)
            var versionCode: Int64 = 0
            if let range = rest.range(of: " versionCode:") {
                versionCode = Int64(rest[range.upperBound...].split(separator: " ").first ?? "") ?? 0
                rest = rest[..<range.lowerBound]
            }
            guard let equals = rest.lastIndex(of: "=") else { return nil }
            return InstalledPackage(package: String(rest[rest.index(after: equals)...]), path: String(rest[..<equals]),
                                    versionCode: versionCode, system: system)
        }
    }

    /// System apps people use like their own: Android's Settings (where the
    /// screen lock is changed or removed, among others), and Google Play and
    /// the Google app once the user has added Google apps (Settings › System ›
    /// Google apps, installed as privileged system apps by `GoogleAppsInstaller`).
    static let featuredSystemPackages: Set<String> = [
        "com.android.settings", "com.android.vending", "com.google.android.googlequicksearchbox",
    ]

    private func installedPackages(includeSystem: Bool = false) async throws -> [InstalledPackage] {
        // Both lists in one shell call (`cmd package` is what `pm` runs). With
        // `&&` the marker follows only a first list that succeeded, and the
        // call's status is the second's.
        let marker = Self.shellMarker()
        let result = try await adbShell("cmd package list packages -3 -f --show-versioncode && echo \(marker) && "
                                        + "cmd package list packages -s -f --show-versioncode")
        let lists = Self.sections(of: result.output, marker: marker)
        let system = lists.count == 2 ? Self.parsePackages(lists[1], system: true) : []
        // A pm that failed (Android's package service restarting) lists
        // nothing, which must never read as "every app was uninstalled":
        // Android always has system packages.
        guard result.succeeded, lists.count == 2, !system.isEmpty else {
            throw AvoError.internalError("Android did not list its packages")
        }
        var packages = Self.parsePackages(lists[0], system: false)
        packages += includeSystem ? system : system.filter { Self.featuredSystemPackages.contains($0.package) }
        return packages
    }

    /// Match flags for both kinds of activity (MATCH_DIRECT_BOOT_AWARE |
    /// MATCH_DIRECT_BOOT_UNAWARE): while a screen lock keeps the user's
    /// storage closed, Android otherwise resolves only the few apps that can
    /// run then (Phone, Settings), and every other app would look gone.
    static let allActivityFlags = "0xC0000"

    static let launchableCommand = "cmd package query-activities --brief --query-flags \(allActivityFlags) "
        + "-a android.intent.action.MAIN -c android.intent.category.LAUNCHER"

    private func launchablePackages() async throws -> Set<String> {
        var result = try await adbShell(Self.launchableCommand)
        if !result.succeeded {
            // An Android without --query-flags: what resolves now.
            result = try await adbShell(Self.launchableCommand.replacingOccurrences(of: "--query-flags \(Self.allActivityFlags) ", with: ""))
        }
        let output = result.output
        return Set(output.split(separator: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let slash = text.firstIndex(of: "/"), !text.contains(" ") else { return nil }
            return String(text[..<slash])
        })
    }

    private func appInfos(includeSystem: Bool) async throws -> [Avo_V1_AppInfo] {
        let launchable = try await launchablePackages()
        let installed = try await installedPackages(includeSystem: includeSystem)
        var apps = await appInfos(installed.filter { launchable.contains($0.package) }, launchable: launchable)
        // Installed apps without a launcher activity now are listed too, by
        // name only: the Mac keeps an app's record and shim while it is
        // installed, also when it does not resolve for a moment.
        apps += installed.filter { !launchable.contains($0.package) }.map { Self.packageOnlyInfo($0, launchable: false) }
        let trimmed = Self.fitAppList(&apps, bytes: Self.appListBytes)
        if !trimmed.isEmpty {
            logger.notice("AppList: icons left out for \(trimmed.count) apps to fit one Control frame")
        }
        return apps
    }

    /// One app's info (an install or an update).
    private func appInfo(_ package: InstalledPackage, launchable: Bool) async -> Avo_V1_AppInfo {
        await appInfos([package], launchable: launchable ? [package.package] : []).first
            ?? Self.packageOnlyInfo(package, launchable: launchable)
    }

    /// Label (the app's, as the Bridge Agent gives it), version, size and
    /// launcher icon, asked of Android itself (the helper's `appinfo`, one
    /// run for all apps not cached yet), cached per version. Without the
    /// helper, small APKs are read on the host instead (AvoPackages).
    private func appInfos(_ packages: [InstalledPackage], launchable: Set<String>) async -> [Avo_V1_AppInfo] {
        let missing = packages.filter { infoCache[$0.package]?.version != $0.versionCode }
        let reports = await helperAppInfo(missing.map(\.package))
        var incomplete = false
        for package in missing {
            let info = await appInfo(package, report: reports[package.package], launchable: launchable.contains(package.package))
            infoCache[package.package] = (package.versionCode, info)
            incomplete = incomplete || !Self.isComplete(info)
        }
        if incomplete { repairAppInfoLater() }
        return packages.map { package in
            var info = infoCache[package.package]?.info ?? Self.packageOnlyInfo(package, launchable: false)
            info.launchable = launchable.contains(package.package)
            return info
        }
    }

    private func appInfo(_ package: InstalledPackage, report: HelperAppInfo?, launchable: Bool) async -> Avo_V1_AppInfo {
        var info = Self.packageOnlyInfo(package, launchable: launchable)
        if let report, report.error == nil {
            Self.fill(&info, from: report)
            // Android could not draw the icon (`iconError`): the base APK's, when it is small enough to read.
            if info.iconPng.isEmpty, Self.appInfoSource(nil, baseAPKBytes: await fileBytes(package.path)) == .apk {
                var apk = info
                await fillFromAPK(&apk, path: package.path)
                info.iconPng = apk.iconPng
            }
        } else if Self.appInfoSource(report, baseAPKBytes: await fileBytes(package.path)) == .apk {
            await fillFromAPK(&info, path: package.path)
        }
        return info
    }

    static func packageOnlyInfo(_ package: InstalledPackage, launchable: Bool) -> Avo_V1_AppInfo {
        var info = Avo_V1_AppInfo()
        info.package = package.package
        info.label = package.package
        info.versionCode = package.versionCode
        info.launchable = launchable
        info.systemApp = package.system
        return info
    }

    /// Label, version and icon read from the base APK on the host (AvoPackages).
    private func fillFromAPK(_ info: inout Avo_V1_AppInfo, path: String) async {
        guard let adb, let apk = try? await adb.exec("cat " + Self.quote(path)) else { return }
        info.sizeBytes = Int64(apk.count)
        let file = FileManager.default.temporaryDirectory.appending(path: "avo-apk-\(UUID().uuidString).apk")
        if (try? apk.write(to: file)) != nil, let summary = try? PackageArchive(url: file).summary {
            if !summary.label.trimmed.isEmpty { info.label = summary.label }
            info.versionName = summary.versionName ?? ""
            if let icon = summary.icon { Self.fill(&info, icon: icon) }
        }
        try? FileManager.default.removeItem(at: file)
    }

    private func fileBytes(_ path: String) async -> Int64? {
        guard let output = try? await shell("stat -c %s " + Self.quote(path)) else { return nil }
        return Int64(output.trimmed)
    }

    private static func fill(_ info: inout Avo_V1_AppInfo, icon: PackageIcon) {
        switch icon {
        case .bitmap(let data):
            if let image = MacIconRenderer.image(from: data), let png = MacIconRenderer.png(image) { info.iconPng = png }
        case let .adaptive(background, foreground, _):
            let layer = { (layer: IconLayer?) -> MacIconRenderer.Layer? in
                switch layer {
                case .color(let argb)?: .color(MacIconRenderer.color(argb: argb))
                case .bitmap(let data)?: MacIconRenderer.image(from: data).map { .image($0) }
                default: nil
                }
            }
            if let png = adaptiveIconPNG(background: layer(background), foreground: layer(foreground)) { info.iconPng = png }
        }
    }

    /// An adaptive icon as the Control Panel shows it: its layers on the Mac's squircle.
    static func adaptiveIconPNG(background: MacIconRenderer.Layer?, foreground: MacIconRenderer.Layer?) -> Data? {
        let source = MacIconRenderer.Source.adaptive(background: background, foreground: foreground)
        guard let image = MacIconRenderer.render(source, pixels: 256) else { return nil }
        return MacIconRenderer.png(image)
    }

    // MARK: App info from Android (the helper's `appinfo`)

    /// One line of `appinfo` (guest/clipboard AppInfo.java). An adaptive
    /// icon comes as its full-bleed 108 dp layers (the background may be a
    /// colour, unsigned ARGB); any other icon as `iconPng`. PNGs are Base64.
    struct HelperAppInfo: Decodable, Equatable {
        var package: String
        var label: String?
        var versionName: String?
        var versionCode: Int64?
        var sizeBytes: Int64?
        var firstInstallTime: Int64?
        var lastUpdateTime: Int64?
        var iconPng: Data?
        var backgroundPng: Data?
        var backgroundColor: UInt32?
        var foregroundPng: Data?
        /// The app says it is a game (absent from an older helper).
        var game: Bool?
        /// "portrait" or "landscape": what its activities ask for (absent when they let the screen turn).
        var orientation: String?
        /// Android could not describe the package (not installed, not visible).
        var error: String?
    }

    /// Where an app's info comes from.
    enum AppInfoSource: Equatable {
        /// Android's own answer (the helper).
        case android
        /// The base APK, copied to the Mac and read (the helper did not answer).
        case apk
        /// Only what `pm` lists: the base APK is too large to copy (or unreadable).
        case packageOnly
    }

    /// A base APK larger than this is not copied to the Mac to be read (the
    /// Google app's is 250 MB); besides, a split install keeps its icons in
    /// its density splits, not in the base APK.
    static let largestAPKReadOnHost: Int64 = 64 << 20

    static func appInfoSource(_ report: HelperAppInfo?, baseAPKBytes: Int64?) -> AppInfoSource {
        if let report, report.error == nil { return .android }
        // Time ran out asking Android: copying APKs would take longer still.
        if report?.error == appInfoOutOfTime { return .packageOnly }
        guard let bytes = baseAPKBytes, bytes > 0, bytes <= largestAPKReadOnHost else { return .packageOnly }
        return .apk
    }

    /// Apps per helper run: each run starts a runtime, and its output carries
    /// two icon layers per app.
    static let appInfoBatch = 40

    /// How long one helper run may take (`timeout`), and all the runs of one
    /// ask: ListApps answers within the Mac's 60 seconds (ControlSession).
    static let appInfoRunSeconds = 20
    static let appInfoSeconds = 30

    /// The report of a package left unasked when `appInfoSeconds` ran out.
    static let appInfoOutOfTime = "not asked: out of time"

    static func appInfoCommand(_ packages: [String], seconds: Int = appInfoRunSeconds) -> String {
        // `timeout` (toybox): a hung runtime must not hold the app list up.
        "CLASSPATH=\(clipboardJar) timeout \(seconds) app_process / com.avodroid.clipboard.Main appinfo "
            + packages.map(quote).joined(separator: " ")
    }

    /// How a helper run ended. It answers in the order asked, a line each.
    enum AppInfoRun: Equatable {
        /// Every package answered, or the helper ended normally.
        case done
        /// The helper stopped at this package (hung or crashed on it): the
        /// ones after it are asked again, without it.
        case stopped(at: String, rest: [String])
        /// Nothing answered: an older helper (it exits 2 for `appinfo`), none
        /// pushed yet, a runtime that would not start.
        case notStarted
    }

    static func appInfoRun(_ batch: [String], reports: [String: HelperAppInfo], exitCode: Int32) -> AppInfoRun {
        guard exitCode != 0, let index = batch.firstIndex(where: { reports[$0] == nil }) else { return .done }
        // 124 is `timeout`'s: it hung on the first package rather than not starting.
        if index == 0, exitCode != 124 { return .notStarted }
        return .stopped(at: batch[index], rest: Array(batch[(index + 1)...]))
    }

    /// `appinfo`'s JSON lines by package; any other line (runtime warnings) is skipped.
    static func parseAppInfo(_ output: String) -> [String: HelperAppInfo] {
        let decoder = JSONDecoder()
        var reports: [String: HelperAppInfo] = [:]
        // Lines end at "\n" only: a label may hold U+0085 or U+2028, which
        // Android's org.json leaves as they are and Swift counts as newlines.
        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let text = line.trimmed
            guard text.hasPrefix("{"), let report = try? decoder.decode(HelperAppInfo.self, from: Data(text.utf8)),
                  !report.package.isEmpty else { continue }
            reports[report.package] = report
        }
        return reports
    }

    static func fill(_ info: inout Avo_V1_AppInfo, from report: HelperAppInfo) {
        if let label = report.label?.trimmed, !label.isEmpty { info.label = label }
        if let versionName = report.versionName { info.versionName = versionName }
        if let bytes = report.sizeBytes, bytes > 0 { info.sizeBytes = bytes }
        if let time = report.firstInstallTime, time > 0 { info.firstInstallTimeMs = time }
        if let time = report.lastUpdateTime, time > 0 { info.lastUpdateTimeMs = time }
        if let game = report.game {
            info.game = game
            info.orientation = switch report.orientation {
            case "portrait": .portrait
            case "landscape": .landscape
            default: .unspecified
            }
        }
        let backgroundImage = report.backgroundPng.flatMap(MacIconRenderer.image(from:))
        let foregroundImage = report.foregroundPng.flatMap(MacIconRenderer.image(from:))
        let background = report.backgroundColor.map { MacIconRenderer.Layer.color(MacIconRenderer.color(argb: $0)) }
            ?? backgroundImage.map(MacIconRenderer.Layer.image)
        let foreground = foregroundImage.map(MacIconRenderer.Layer.image)
        if background != nil || foreground != nil {
            if let png = adaptiveIconPNG(background: background, foreground: foreground) { info.iconPng = png }
            // The layers as well, as the Bridge Agent sends them: the App Shim's
            // icon is drawn from them at every size (ShortcutManager.iconSource).
            var layers = Avo_V1_AdaptiveIcon()
            if let argb = report.backgroundColor {
                layers.backgroundPng = layerPNG(argb: argb) ?? Data()
            } else if backgroundImage != nil, let png = report.backgroundPng {
                layers.backgroundPng = png
            }
            if foregroundImage != nil, let png = report.foregroundPng { layers.foregroundPng = png }
            if !layers.backgroundPng.isEmpty || !layers.foregroundPng.isEmpty { info.adaptiveIcon = layers }
        } else if let png = report.iconPng, MacIconRenderer.image(from: png) != nil {
            info.iconPng = png
        }
    }

    /// A one-colour adaptive icon layer, 108 dp at xxxhdpi (AdaptiveIcon carries PNGs).
    static func layerPNG(argb: UInt32) -> Data? {
        let pixels = 432
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(MacIconRenderer.color(argb: argb))
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return context.makeImage().flatMap(MacIconRenderer.png)
    }

    /// How much of what the Control Panel shows the info has: a name (not
    /// the package's) and an icon.
    static func completeness(_ info: Avo_V1_AppInfo) -> Int {
        (!info.label.trimmed.isEmpty && info.label != info.package ? 1 : 0) + (info.iconPng.isEmpty ? 0 : 1)
    }

    /// Whether the info has a name and an icon.
    static func isComplete(_ info: Avo_V1_AppInfo) -> Bool {
        completeness(info) == 2
    }

    /// The AppList travels as one Control frame (`AvoProtocol.maxFrameSize`),
    /// the envelope around it included.
    static let appListBytes = AvoProtocol.maxFrameSize - (256 << 10)

    /// Keeps an AppList within `bytes`, largest apps first: icon layers go
    /// first (the App Shim's icon then comes from the flattened one), then
    /// flattened icons (the Mac keeps the one it has). The apps trimmed.
    static func fitAppList(_ apps: inout [Avo_V1_AppInfo], bytes: Int) -> Set<String> {
        // An entry's tag and length take a few bytes more.
        func size(_ app: Avo_V1_AppInfo) -> Int { ((try? app.serializedData())?.count ?? 0) + 5 }
        var sizes = apps.map(size)
        var total = sizes.reduce(0, +)
        var trimmed: Set<String> = []
        let steps: [(inout Avo_V1_AppInfo) -> Void] = [{ $0.clearAdaptiveIcon() }, { $0.iconPng = Data() }]
        for step in steps where total > bytes {
            for index in apps.indices.sorted(by: { sizes[$0] > sizes[$1] }) where total > bytes {
                step(&apps[index])
                let after = size(apps[index])
                guard after < sizes[index] else { continue }
                total -= sizes[index] - after
                sizes[index] = after
                trimmed.insert(apps[index].package)
            }
        }
        return trimmed
    }

    /// The helper's reports by package, in batches; none for apps it could
    /// not describe or when it does not run, `appInfoOutOfTime` for those
    /// left when `appInfoSeconds` ran out.
    private func helperAppInfo(_ packages: [String]) async -> [String: HelperAppInfo] {
        var reports: [String: HelperAppInfo] = [:]
        var pending = packages
        var failures = 0
        let deadline = ContinuousClock.now + .seconds(Self.appInfoSeconds)
        while !pending.isEmpty {
            let left = Int((deadline - .now).components.seconds)
            guard left >= 2 else {
                for package in pending { reports[package] = HelperAppInfo(package: package, error: Self.appInfoOutOfTime) }
                break
            }
            let batch = Array(pending.prefix(Self.appInfoBatch))
            let command = Self.appInfoCommand(batch, seconds: min(Self.appInfoRunSeconds, left))
            guard let result = try? await adbShell(command) else { break }
            let parsed = Self.parseAppInfo(result.output)
            reports.merge(parsed) { _, new in new }
            switch Self.appInfoRun(batch, reports: parsed, exitCode: result.exitCode) {
            case .done:
                pending.removeFirst(batch.count)
                failures = 0
            case let .stopped(culprit, rest):
                // One app must not cost the others theirs.
                logger.error("appinfo stopped at \(culprit, privacy: .public) (exit \(result.exitCode))")
                pending = rest + pending.dropFirst(batch.count)
                failures = 0
            case .notStarted:
                // Right after boot the helper may still be the previous one
                // or not pushed yet: again shortly, then not at all.
                failures += 1
                guard failures < 3 else { return reports }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return reports
    }

    /// Apps whose info came out incomplete (the helper did not answer, the
    /// APK was too large to read) are asked again a few times, and the Mac
    /// hears of each one that gets its name and icon (an AppInstalled that
    /// replaces it), so a wrong entry repairs itself.
    private func repairAppInfoLater() {
        guard appInfoRepair == nil else { return }
        appInfoRepair = Task { [weak self] in
            for attempt in 1...3 {
                try? await Task.sleep(for: .seconds(10 * attempt))
                guard let self, await self.repairAppInfo() else { break }
            }
            await self?.endAppInfoRepair()
        }
    }

    private func endAppInfoRepair() {
        appInfoRepair = nil
    }

    /// False once no cached info is incomplete.
    private func repairAppInfo() async -> Bool {
        let incomplete = infoCache.filter { !Self.isComplete($0.value.info) }
        guard !incomplete.isEmpty else { return false }
        guard isReady, let installed = try? await installedPackages(includeSystem: true) else { return true }
        let packages = installed.filter { incomplete[$0.package]?.version == $0.versionCode }
        let reports = await helperAppInfo(packages.map(\.package))
        for package in packages {
            guard let report = reports[package.package], report.error == nil,
                  let cached = infoCache[package.package], cached.version == package.versionCode else { continue }
            let info = await appInfo(package, report: report, launchable: cached.info.launchable)
            // Only a better answer replaces the one the Mac has.
            guard let current = infoCache[package.package], current.version == package.versionCode,
                  Self.completeness(info) > Self.completeness(current.info) else { continue }
            infoCache[package.package] = (package.versionCode, info)
            // Apps the Mac does not list (other system apps) stay as they are.
            guard known[package.package] == package.versionCode else { continue }
            var installed = Avo_V1_AppInstalled()
            installed.app = info
            installed.replacing = true
            await send(Avo_V1_Envelope(.appInstalled(installed)))
        }
        return infoCache.values.contains { !Self.isComplete($0.info) }
    }

    /// PACKAGE_ADDED / PACKAGE_REMOVED by polling (no receiver outside Android).
    private func pollPackages() async {
        guard isReady, let packages = try? await installedPackages() else { return }
        let now = packages.reduce(into: [String: Int64]()) { $0[$1.package] = $1.versionCode }
        // Only for an install or an update: it is one more process in Android every poll.
        let changed = packages.contains { known[$0.package] != $0.versionCode }
        let launchable = changed ? (try? await launchablePackages()) ?? [] : []
        for package in packages where known[package.package] != package.versionCode {
            let replacing = known[package.package] != nil
            var installed = Avo_V1_AppInstalled()
            installed.app = await appInfo(package, launchable: launchable.contains(package.package))
            installed.replacing = replacing
            await send(Avo_V1_Envelope(.appInstalled(installed)))
        }
        for package in known.keys where now[package] == nil {
            var removed = Avo_V1_AppRemoved()
            removed.package = package
            await send(Avo_V1_Envelope(.appRemoved(removed)))
            infoCache[package] = nil
        }
        known = now
    }

    /// Runtime permissions from `dumpsys package`.
    private func permissions(of package: String) async throws -> [Avo_V1_Permission] {
        let output = try await shell("dumpsys package " + Self.quote(package))
        var result: [Avo_V1_Permission] = []
        var inRuntime = false
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("runtime permissions:") {
                inRuntime = true
                continue
            }
            guard inRuntime else { continue }
            guard text.hasPrefix("android.permission.") || text.contains(".permission."),
                  let colon = text.firstIndex(of: ":") else {
                if !text.isEmpty && !text.contains("granted=") { inRuntime = false }
                continue
            }
            var permission = Avo_V1_Permission()
            permission.name = String(text[..<colon])
            permission.granted = text.contains("granted=true")
            permission.runtime = true
            result.append(permission)
        }
        return result
    }

    // MARK: Input channel

    func serveInput(_ stream: FileDescriptorStream) async {
        var buffer: [UInt8] = []
        var negotiated = false
        var decoder = InputRecordDecoder()
        do {
            for try await chunk in stream.incoming {
                if negotiated {
                    decoder.append(chunk)
                } else {
                    buffer += chunk
                    guard buffer.count >= 8 else { continue }
                    try await stream.write(Data(InputWire.preamble()))
                    negotiated = true
                    decoder.append(buffer.dropFirst(8))
                }
                while let record = try decoder.next() {
                    await inject(record)
                }
            }
        } catch {
            logger.debug("input channel closed: \(String(describing: error), privacy: .public)")
        }
        // No stuck fingers or modifier keys after the shim goes away.
        for id in touches.keys {
            if let display = displays[id] { try? await engine.send("touch \(display.scanout)") }
        }
        touches.removeAll()
        await holdModifiers(0)
        // The daemon's one channel carries every shim's records: none drives it now.
        await drive(gamepad: GamepadState(pad: 0, connected: false))
    }

    private func inject(_ record: InputRecord) async {
        switch record {
        case .touch(let event):
            guard let display = displays[event.displayID] else { return }
            var down = touches[event.displayID] ?? [:]
            switch event.action {
            case .up, .cancel:
                down.removeAll()
            case .pointerUp:
                let index = Int(event.actionIndex)
                if index < event.pointers.count { down[event.pointers[index].id] = nil }
                for (i, pointer) in event.pointers.enumerated() where i != index { down[pointer.id] = (pointer.x, pointer.y) }
            default:
                for pointer in event.pointers { down[pointer.id] = (pointer.x, pointer.y) }
            }
            touches[event.displayID] = down
            await sendTouches(down, to: display)
        case .mouse(let event):
            guard let display = displays[event.displayID] else { return }
            var down = touches[event.displayID] ?? [:]
            switch event.action {
            case .down, .move: down = [0: (event.x, event.y)]
            case .up: down.removeAll()
            default: return
            }
            touches[event.displayID] = down
            await sendTouches(down, to: display)
        case .key(let event):
            // Back on an app's first screen closes it: notice that quickly.
            if event.keyCode == AndroidKeys.back, event.action == .up { checkTasksSoon() }
            if let androidID = unfocusedTarget(event.displayID) {
                // `input` sends the press and release itself, modifiers first.
                guard event.action == .down else { return }
                let modifiers = AndroidKeys.modifiers(in: event.metaState).map(\.android)
                let command = modifiers.isEmpty ? "keyevent \(event.keyCode)"
                    : "keycombination " + (modifiers + [event.keyCode]).map(String.init).joined(separator: " ")
                _ = try? await shell("input -d \(androidID) " + command)
                return
            }
            guard let code = AndroidKeys.linux[event.keyCode] else { return }
            // The keyboard holds the event's modifiers around the key (Ctrl+C,
            // Shift+arrow) and lets go of them when it is released.
            if event.action == .down { await holdModifiers(event.metaState) }
            try? await engine.send("key \(code) \(event.action == .down ? 1 : 0)")
            if event.action == .up { await holdModifiers(0) }
        case .text(let displayID, let text):
            if let androidID = unfocusedTarget(displayID) {
                _ = try? await shell("input -d \(androidID) text " + Self.quote(text))
                return
            }
            await holdModifiers(0)
            for character in text {
                if let (code, shift) = AndroidKeys.strokes(for: character) {
                    if shift { try? await engine.send("key \(AndroidKeys.leftShift) 1") }
                    try? await engine.send("key \(code) 1")
                    try? await engine.send("key \(code) 0")
                    if shift { try? await engine.send("key \(AndroidKeys.leftShift) 0") }
                } else {
                    _ = try? await shell("input text " + Self.quote(String(character)))
                }
            }
        case .gamepad(let state):
            await drive(gamepad: state)
        case .scroll(let event):
            // The mouse wheel as Android's own mouse scroll on the window's display.
            guard let androidID = displays[event.displayID]?.androidID else { return }
            queueScroll(event, androidID: androidID)
        default:
            break
        }
    }

    /// Wheel notches waiting to go to Android, per display: a burst goes out
    /// as one `input` command (each one is a process in Android).
    private var pendingScroll: [UInt32: (androidID: Int, x: Float, y: Float, horizontal: Float, vertical: Float)] = [:]
    private var scrollFlush: Task<Void, Never>?

    private func queueScroll(_ event: ScrollEvent, androidID: Int) {
        var entry = pendingScroll[event.displayID] ?? (androidID, event.x, event.y, 0, 0)
        entry.x = event.x
        entry.y = event.y
        entry.horizontal += event.horizontal
        entry.vertical += event.vertical
        pendingScroll[event.displayID] = entry
        guard scrollFlush == nil else { return }
        scrollFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(12))
            await self?.flushScroll()
        }
    }

    private func flushScroll() async {
        let batch = pendingScroll
        pendingScroll = [:]
        scrollFlush = nil
        for scroll in batch.values where scroll.vertical != 0 || scroll.horizontal != 0 {
            _ = try? await shell(Self.scrollCommand(display: scroll.androidID, x: scroll.x, y: scroll.y,
                                                     horizontal: scroll.horizontal, vertical: scroll.vertical))
        }
    }

    /// `input mouse scroll` (a mouse's AXIS_VSCROLL/HSCROLL, in lines) at a point of a display.
    /// The source goes before `-d`: `input -d 3 mouse …` is "Unknown command: mouse".
    static func scrollCommand(display: Int, x: Float, y: Float, horizontal: Float, vertical: Float) -> String {
        var command = "input mouse -d \(display) scroll \(Int(x.rounded())) \(Int(y.rounded()))"
        if vertical != 0 { command += " --axis VSCROLL,\(String(format: "%.3f", vertical))" }
        if horizontal != 0 { command += " --axis HSCROLL,\(String(format: "%.3f", horizontal))" }
        return command
    }

    /// Modifier keys the engine's keyboard holds down now (evdev codes).
    private var heldModifiers: Set<UInt16> = []

    /// Presses and releases modifier keys until exactly those in `metaState` are down.
    private func holdModifiers(_ metaState: UInt32) async {
        let wanted = Set(AndroidKeys.modifiers(in: metaState).map(\.linux))
        for code in heldModifiers.subtracting(wanted) { try? await engine.send("key \(code) 0") }
        for code in wanted.subtracting(heldModifiers) { try? await engine.send("key \(code) 1") }
        heldModifiers = wanted
    }

    /// The Android display for keys meant for a window whose display is not
    /// the focused one (the engine's keyboard would type into another app).
    private func unfocusedTarget(_ displayID: UInt32) -> Int? {
        guard displayID != focusedDisplay, let display = displays[displayID] else { return nil }
        return display.androidID
    }

    /// The display's window became the Mac's key window: its app takes
    /// Android's input focus (MacState.focusDisplayCommand), as a tap there
    /// gives it. Android focuses one display at a time and games pause their
    /// sound without it. A quick run of windows (Cmd-`) ends on the last one.
    func focusDisplay(_ id: UInt32) async {
        focusWanted = id
        guard !focusing, isReady else { return }
        focusing = true
        defer { focusing = false }
        while let wanted = focusWanted {
            focusWanted = nil
            guard wanted != focusedDisplay, let androidID = displays[wanted]?.androidID,
                  await pushMacHelper() else { continue }
            let output = (try? await shell(MacState.focusDisplayCommand(androidID))) ?? ""
            // A window may close meanwhile.
            if output.contains("focused task"), displays[wanted] != nil {
                focusedDisplay = wanted
            } else {
                logger.debug("display \(wanted) did not take Android's focus: \(output.trimmed, privacy: .public)")
            }
        }
    }

    private func sendTouches(_ down: [UInt32: (Float, Float)], to display: Display) async {
        // Tapping a display gives it Android's input focus.
        if !down.isEmpty { focusedDisplay = display.id }
        // The touchscreen spans the whole display; the window measures in its own size.
        let width = Float(max(display.inputWidth, 2) - 1)
        let height = Float(max(display.inputHeight, 2) - 1)
        let pointers = down.sorted { $0.key < $1.key }.map { id, position in
            let x = Int((min(max(position.0, 0), width) / width * Self.touchRange).rounded())
            let y = Int((min(max(position.1, 0), height) / height * Self.touchRange).rounded())
            return "\(id):\(x):\(y)"
        }
        try? await engine.send((["touch", "\(display.scanout)"] + pointers).joined(separator: " "))
    }

    // MARK: Gamepad (EngineGamepad)

    /// Android has the engine's gamepad only while a Mac controller drives
    /// it: a game that sees a gamepad may switch to controller prompts and
    /// hide its touch controls, so the rest of the time it is unplugged.
    private var gamepadAttached = false
    /// The display of the window that sent the last GAMEPAD record: closing
    /// it unplugs the gamepad, closing another app's window does not.
    private var gamepadDisplay: UInt32?

    /// Records follow the key window of the app in front (GamepadForwarder
    /// in the Window Host); Android gives them to its focused window.
    private func drive(gamepad state: GamepadState) async {
        gamepadDisplay = state.connected ? state.displayID : nil
        guard state.connected else {
            guard gamepadAttached else { return }
            // Unbinding releases what is held: the kernel lets go of every key.
            gamepadAttached = false
            _ = try? await root(EngineGamepad.detachScript)
            return
        }
        if !gamepadAttached {
            gamepadAttached = true
            _ = try? await root(EngineGamepad.attachScript)
        }
        try? await engine.send(EngineGamepad.command(for: state))
    }

    // MARK: Mac state (the Mac's appearance, time zone, clock, languages and battery; MacState.swift)

    /// The Mac's latest state, and what this boot of Android has of it.
    private var macWanted: MacState?
    private var macApplied: MacState?
    private var macSync: Task<Void, Never>?
    private var macHelperPushed = false

    /// Brings Android in step with the Mac: what differs from what this boot
    /// has is applied, one change at a time and the latest last, so a quick
    /// run of Mac changes never leaves an older one in place.
    func syncMacState(_ state: MacState) {
        macWanted = state
        guard isReady, !paused, macSync == nil else { return }
        macSync = Task { [weak self] in await self?.runMacSync() }
    }

    private func runMacSync() async {
        while isReady, !paused, let wanted = macWanted, wanted != macApplied {
            let previous = macApplied
            // A step that fails is tried again when the Mac next changes it, not in a loop.
            macApplied = wanted
            await applyMac(wanted, over: previous)
        }
        macSync = nil
    }

    private func applyMac(_ state: MacState, over previous: MacState?) async {
        if state.dark != previous?.dark { await applyAppearance(dark: state.dark) }
        if state.timeZone != previous?.timeZone { await applyTimeZone(state.timeZone) }
        if state.uses24HourClock != previous?.uses24HourClock { await applyClock(uses24HourClock: state.uses24HourClock) }
        if previous == nil || state.battery != previous?.battery,
           let command = MacState.batteryCommand(state.battery, over: previous?.battery) {
            await macStep("battery", command)
        }
        // Last: Android relaunches the apps' activities for new languages.
        if state.languages != previous?.languages, let tags = MacState.androidLanguages(state.languages) {
            await applyLanguages(tags)
        }
    }

    /// As root, so it does not matter which of these Android lets the shell
    /// user do (it hardens some, like the media volume).
    @discardableResult
    private func macStep(_ what: String, _ command: String) async -> Bool {
        do {
            let result = try await root(command)
            if result.succeeded { return true }
            logger.error("Mac \(what, privacy: .public) in Android failed (exit \(result.exitCode)): \((result.output + result.errorOutput).trimmed, privacy: .public)")
        } catch {
            logger.error("Mac \(what, privacy: .public) in Android failed: \(String(describing: error), privacy: .public)")
        }
        return false
    }

    private func applyAppearance(dark: Bool) async {
        if let output = try? await shell("cmd uimode night"), MacState.isDark(uimode: output) == dark { return }
        if await macStep("appearance", MacState.appearanceCommand(dark: dark)) {
            logger.notice("Android is \(dark ? "dark" : "light", privacy: .public) like the Mac")
        }
    }

    private func applyTimeZone(_ id: String) async {
        guard MacState.isValidTimeZoneID(id) else {
            logger.error("the Mac's time zone \(id, privacy: .public) is not an IANA identifier; Android keeps its own")
            return
        }
        guard (try? await shell("getprop persist.sys.timezone"))?.trimmed != id else { return }
        if (try? await root(MacState.autoTimeZoneQuery))?.output.trimmed == "true" {
            await macStep("time zone", MacState.autoTimeZoneOffCommand)
        }
        await macStep("time zone", MacState.timeZoneCommand(id))
        // The detector says "injected" whether or not it took the zone.
        if (try? await shell("getprop persist.sys.timezone"))?.trimmed == id {
            logger.notice("Android's time zone is \(id, privacy: .public) like the Mac's")
        } else {
            logger.error("Android did not take the Mac's time zone \(id, privacy: .public)")
        }
    }

    private func applyClock(uses24HourClock: Bool) async {
        guard (try? await shell(MacState.clockQuery))?.trimmed != (uses24HourClock ? "24" : "12") else { return }
        if await macStep("clock", MacState.clockCommand(uses24HourClock: uses24HourClock)) {
            logger.notice("Android's clock is \(uses24HourClock ? 24 : 12)-hour like the Mac's")
        }
    }

    /// `mac`: the Mac's languages as Android tags. Followed only while
    /// Android's are still Avo's doing (`MacState.languagePlan`).
    private func applyLanguages(_ mac: String) async {
        guard let android = await helperLanguages(nil) else { return }
        let last = MacState.LanguageSync(setting: (try? await shell("settings get global " + MacState.LanguageSync.setting)) ?? "null")
        let persisted = (try? await shell("getprop persist.sys.locale")) ?? ""
        let productDefault = (try? await shell("getprop ro.product.locale")) ?? ""
        let chosen = MacState.languagesChosen(android: android, persisted: persisted, productDefault: productDefault)
        let plan = MacState.languagePlan(mac: mac, android: android, chosenInAndroid: chosen, last: last)
        var remember = plan.remember
        if plan.apply {
            guard let now = await helperLanguages(mac) else { return }
            remember = MacState.LanguageSync(mac: mac, android: now)
            logger.notice("Android's languages are \(now, privacy: .public) like the Mac's")
        } else if remember != nil, remember?.mac != android {
            logger.notice("Android's languages (\(android, privacy: .public)) were chosen in Android; they stay")
        }
        if let remember {
            _ = try? await shell("settings put global \(MacState.LanguageSync.setting) " + Self.quote(remember.settingValue))
        }
    }

    /// Android's languages from the helper, after making them `tags` if
    /// given: as the shell user, whose permissions the change is checked
    /// against, else as root.
    private func helperLanguages(_ tags: String?) async -> String? {
        guard await pushMacHelper() else { return nil }
        let command = MacState.languagesCommand(tags)
        var result = try? await adbShell(command)
        if result?.succeeded != true { result = try? await root(command) }
        guard let result, result.succeeded, let languages = MacState.parseLanguages(result.output) else {
            logger.error("the languages helper failed: \(((result?.output ?? "") + (result?.errorOutput ?? "")).trimmed, privacy: .public)")
            return nil
        }
        return languages
    }

    /// avo-macstate.jar on Android, once per agent (it may be an older one).
    private func pushMacHelper() async -> Bool {
        if macHelperPushed { return true }
        guard let adb, let jar = Data(base64Encoded: MacStateHelper.jar),
              (try? await adb.push(AsyncStream { $0.yield(jar); $0.finish() }, to: MacState.helperJar)) != nil else {
            logger.error("could not put the Mac state helper on Android")
            return false
        }
        macHelperPushed = true
        return true
    }

    /// Every app keeps audio focus (MacState.audioFocusCommand). On a phone
    /// an app another one takes focus from pauses or mutes itself, so two
    /// games side by side silenced each other. Once on, Android keeps it.
    func shareAudioFocus() async {
        guard (try? await shell(MacState.audioFocusQuery))?.trimmed != "1", await pushMacHelper() else { return }
        let result = try? await adbShell(MacState.audioFocusCommand)
        // The call is one-way: AudioService may finish it a moment later.
        for _ in 0..<10 {
            if (try? await shell(MacState.audioFocusQuery))?.trimmed == "1" {
                logger.notice("audio: every app keeps audio focus, as on a Mac")
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        logger.error("audio: apps still take audio focus from each other: \(((result?.output ?? "") + (result?.errorOutput ?? "")).trimmed, privacy: .public)")
    }
}

// MARK: - Pause (VMMEngine's PausableEngine)

extension HostAgent {
    func setPaused(_ paused: Bool) {
        self.paused = paused
        if !paused { endPauseWaits() }
        // What the Mac changed meanwhile (appearance, time zone, battery).
        if !paused, isReady, macSync == nil, macWanted != macApplied {
            macSync = Task { [weak self] in await self?.runMacSync() }
        }
    }

    /// Returns once Android goes on, or the agent shuts down.
    func whilePaused() async {
        guard paused, isReady else { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    private func endPauseWaits() {
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// After a pause Android's clock is behind by the pause: it stood still
    /// with Android (engine/hvf/vmm/src/pause.rs), as it does while the Mac
    /// sleeps. With network time on (the default) it takes the Mac's time; a
    /// time set by hand moves on by the pause. Network time is then asked
    /// again: its last fix, timed by the elapsed-time clock that stood still
    /// too, would set it back later. One correction at a time: a pause's and
    /// a sleep's, at the same moment, each move a time set by hand on.
    func clockResumed(after pause: Duration) async {
        let previous = clockCorrection
        let correction = Task { [weak self] in
            await previous?.value
            await self?.moveClock(by: pause)
        }
        clockCorrection = correction
        await correction.value
    }

    private func moveClock(by pause: Duration) async {
        guard isReady, !paused, pause >= .seconds(1) else { return }
        let networkTime = (try? await shell("settings get global auto_time"))?.trimmed != "0"
        let target: Int64
        if networkTime {
            target = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        } else {
            guard let now = Int64((try? await shell("date +%s%3N"))?.trimmed ?? "") else { return }
            target = now + Int64(pause / .milliseconds(1))
        }
        guard let result = try? await root(Self.setTimeCommand(milliseconds: target)), result.succeeded else {
            logger.error("could not set Android's clock after a pause")
            return
        }
        if networkTime { _ = try? await shell("cmd network_time_update_service force_refresh") }
        logger.notice("Android's clock moved on by the pause (\(pause, privacy: .public))")
    }

    /// AlarmManager sets the clock and tells apps (ACTION_TIME_CHANGED).
    static func setTimeCommand(milliseconds: Int64) -> String {
        "cmd alarm set-time \(milliseconds)"
    }
}

// MARK: - Root (MagiskRoot: Magisk in init_boot)

extension HostAgent {
    /// Patches `stock` (the image's init_boot) with Magisk from `apk` inside
    /// Android, as Magisk's app would, and returns the patched image.
    /// Magisk's app is installed too, so apps' root requests have someone to ask.
    func patchInitBoot(stock: URL, apk: URL) async throws -> Data {
        guard let adb else { throw AvoError.guestUnavailable }
        let staging = MagiskRoot.staging
        _ = try await root("rm -rf \(staging) && mkdir -p \(staging) && chown shell:shell \(staging)")
        defer { Task { _ = try? await self.root("rm -rf \(staging)") } }
        for (file, name) in [(stock, "init_boot.img"), (apk, "magisk.apk")] {
            let data = try Data(contentsOf: file)
            try await adb.push(AsyncStream { $0.yield(data); $0.finish() }, to: "\(staging)/\(name)")
        }
        let result = try await root(MagiskRoot.patchScript, timeout: .seconds(300))
        guard result.succeeded else {
            let detail = (result.output + "\n" + result.errorOutput).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AvoError.installFailed(String(localized: "Magisk could not patch Android’s boot ramdisk", bundle: .avoKit)
                                         + (detail.isEmpty ? "" : ": " + String(detail.suffix(600))))
        }
        let patched = try await adb.exec("cat \(staging)/new-boot.img")
        guard MagiskRoot.looksPatched(patched) else {
            throw AvoError.installFailed(String(localized: "Magisk’s patched boot ramdisk is not a boot image", bundle: .avoKit))
        }
        let install = (try? await shell("pm install -r \(staging)/magisk.apk", timeout: .seconds(300))) ?? ""
        if !install.contains("Success") { logger.error("root: Magisk's app did not install: \(install.trimmed, privacy: .public)") }
        return patched
    }
}

// MARK: - Composer (GuestComposer: resizes keep the display)

extension HostAgent {
    /// Resizes go in place when Avo's composer runs. On the known build with
    /// the overlays of a `remount`, it is put in place for the next boot;
    /// until then, and everywhere else, resizes re-plug.
    func checkComposer() async {
        guard let sums = try? await shell("sha256sum " + GuestComposer.binary) else { return }
        switch GuestComposer.state(sumOutput: sums) {
        case .patched:
            resizesInPlace = true
            logger.notice("composer: Avo's; windows resize in place")
        case .unknown:
            logger.notice("composer: unknown build; windows re-plug to resize")
        case .stock(let build):
            if (try? await root(GuestComposer.pendingCheck(build)))?.succeeded == true {
                logger.notice("composer: Avo's runs from the next Android start; windows re-plug to resize until then")
            } else if (try? await root(GuestComposer.installScript(build)))?.succeeded == true {
                logger.notice("composer: Avo's installed; it runs from the next Android start")
            } else {
                logger.notice("composer: not installed (no remount overlays?); windows re-plug to resize")
            }
        }
    }
}

// MARK: - Cameras (GuestCamera: the cameras the Mac feeds face back and front)

extension HostAgent {
    /// With cameras from the Mac, the camera HAL that reads them gets their
    /// facing and its configuration (GuestCamera) for this boot; on a VM
    /// with overlays, Android lists camera features from its next start on
    /// either way.
    func setUpCameras() async {
        if (try? await root(GuestCamera.featuresCheck))?.succeeded != true {
            if (try? await root(GuestCamera.featuresScript))?.succeeded == true {
                logger.notice("cameras: features listed from the next Android start")
            }
        }
        guard (try? await shell("getprop " + GuestCamera.apexProperty))?.trimmed == GuestCamera.fedAPEX,
              let sums = try? await shell("sha256sum " + GuestCamera.library) else { return }
        switch GuestCamera.state(sumOutput: sums) {
        case .patched:
            logger.notice("cameras: Avo's camera HAL runs; back and front from the Mac")
        case .unknown:
            logger.notice("cameras: unknown camera HAL build; Android's cameras face \"external\"")
        case .stock(let build):
            guard let result = try? await root(GuestCamera.installScript(build)), result.succeeded else {
                logger.error("cameras: the camera HAL keeps facing \"external\": patching it failed")
                return
            }
            logger.notice("cameras: camera HAL patched and restarted; back and front from the Mac")
        }
    }
}

// MARK: - Audio (GuestAudioPolicy: every stream through the mixer and virtio-snd)

extension HostAgent {
    /// Cuttlefish's audio HAL offers MMAP and compressed-offload streams that
    /// it only simulates (GuestAudioPolicy): games' low-latency AAudio and
    /// offloaded music would play to nothing while everything else plays.
    /// Every boot, before an app plays, the HAL gets its configuration without
    /// those ports: an edited copy is bind-mounted over each file that declares
    /// them (the image stays as it is), as is the HAL with a 20 ms mixer period
    /// (GuestAudioHal), and audioserver starts again, which restarts the HAL
    /// (audioserver.rc's `onrestart`).
    func dropStubAudioPorts() async {
        guard let adb, let listing = try? await shell(GuestAudioPolicy.findCommand) else { return }
        let files = listing.split(separator: "\n").map(\.trimmed).filter { $0.hasPrefix("/") }
        guard !files.isEmpty else { return }
        _ = try? await root("rm -rf " + GuestAudioPolicy.staging)
        var replaced: [String] = []
        for file in files {
            // A file replaced already reads as its edited copy: nothing to change.
            guard let text = try? await shell("cat " + Self.quote(file)),
                  let edited = GuestAudioPolicy.adjusted(text) else { continue }
            let staged = GuestAudioPolicy.stagedPath(for: file)
            do {
                try await adb.push(AsyncStream { $0.yield(Data(edited.utf8)); $0.finish() }, to: staged, mode: 0o644)
            } catch {
                logger.error("audio: staging \(file, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                continue
            }
            // Root's and read-only (adbd pushes files as 0666), labelled like
            // the file it covers: the HAL reads vendor configuration only.
            let result = try? await root("chown root:root \(Self.quote(staged)) && chmod 644 \(Self.quote(staged)) "
                                         + "&& chcon u:object_r:vendor_configs_file:s0 \(Self.quote(staged)) "
                                         + "&& mount -o bind \(Self.quote(staged)) \(Self.quote(file))")
            guard let result, result.succeeded else {
                logger.error("audio: replacing \(file, privacy: .public) failed: \(((result?.output ?? "") + (result?.errorOutput ?? "")).trimmed, privacy: .public)")
                continue
            }
            replaced.append(file)
        }
        // The 20 ms HAL periods (GuestAudioHal) wait until they are proven
        // with the engine's playback clock; the stock 85 ms ones stay.
        if GuestAudioHal.enabled, await shortenAudioPeriods() {
            replaced.append(GuestAudioHal.binary)
        }
        guard !replaced.isEmpty else { return }
        await restartAudioServer(for: replaced)
    }

    /// The HAL's 85 ms mixer period becomes 20 ms and its input pipes twice
    /// as large (GuestAudioHal) on the build that is known; the restart that
    /// follows loads it. True when it was put in place now.
    private func shortenAudioPeriods() async -> Bool {
        guard let sums = try? await shell("sha256sum " + GuestAudioHal.binary) else { return false }
        switch GuestAudioHal.installed(sumOutput: sums) {
        case .patched:
            return false
        case .unknown:
            logger.notice("audio: unknown audio HAL build; it keeps its 85 ms mixer period")
            return false
        case .stock(let build):
            guard let result = try? await root(GuestAudioHal.installScript(build)), result.succeeded else {
                logger.error("audio: the HAL keeps its 85 ms mixer period: patching it failed")
                return false
            }
            return true
        }
    }

    /// Starts audioserver again (init restarts the audio HALs with it) and
    /// waits until the new one has the HAL's modules.
    private func restartAudioServer(for files: [String]) async {
        let started = ContinuousClock.now
        let before = (try? await shell("pidof audioserver"))?.trimmed ?? ""
        guard (try? await root("setprop ctl.restart audioserver"))?.succeeded == true else {
            logger.error("audio: audioserver did not restart; MMAP and offload stay on until it does")
            return
        }
        while ContinuousClock.now < started + .seconds(20) {
            try? await Task.sleep(for: .milliseconds(250))
            let pid = (try? await shell("pidof audioserver"))?.trimmed ?? ""
            guard !pid.isEmpty, pid != before, let dump = try? await shell("dumpsys media.audio_policy"),
                  GuestAudioPolicy.hasModules(dump: dump) else { continue }
            let milliseconds = Int((ContinuousClock.now - started) / .milliseconds(1))
            if GuestAudioPolicy.offersStubPorts(dump: dump) {
                logger.error("audio: audioserver still offers MMAP or offload streams (\(files.joined(separator: ", "), privacy: .public))")
            } else {
                logger.notice("audio: no MMAP or offload streams, all audio through the mixer (\(files.joined(separator: ", "), privacy: .public); audioserver back after \(milliseconds) ms)")
            }
            return
        }
        logger.error("audio: audioserver did not come back within 20 s")
    }
}

// MARK: - Links (Avo Links, guest/links: the links Android apps open, on the Mac)

extension HostAgent {
    static let linksPackage = "\(AvoIdentifiers.prefix).links"
    /// Avo Links of the builds before 0.3.0 Preview 2, uninstalled once this
    /// one is in; the browser role it held goes to this one.
    static let formerLinksPackage = "\(AvoIdentifiers.formerPrefix).links"
    static let browserRole = "android.app.role.BROWSER"
    /// Set once Avo Links became Android's browser on this data disk: a
    /// browser the user picks in Android's settings later on stays.
    static let linksBrowserSetting = "avo_links_browser"

    /// Where the links Android apps open go (VMMEngine.links); set before `prepare`.
    func forwardLinks(to sink: @escaping @Sendable (URL) -> Void) {
        linkSink = sink
    }

    /// Installs Avo Links when Android's copy is not this build's, makes it
    /// the browser once per data disk, then follows its log while Android runs.
    private func runLinks() async {
        guard let uid = await installLinks() else { return }
        await makeLinksTheBrowser()
        // From now on by Android's clock: what Avo Links logged before is not opened again.
        guard let now = try? await shell("date +%s"), let seconds = Int64(now.trimmed) else { return }
        linkReader.assembler.start(at: seconds * 1000)
        // When logcat ends it starts again from the last line read; when ADB
        // will not open it any more (Android has stopped), or logcat keeps
        // ending as soon as it starts (it refuses the command), it stops.
        var failures = 0
        while !Task.isCancelled, failures < 5 {
            failures = await watchLinks(uid: uid) ? 0 : failures + 1
            try? await Task.sleep(for: .seconds(2))
        }
        if !Task.isCancelled { logger.error("stopped following Avo Links: links stay in Android until the next start") }
    }

    /// Avo Links' uid, once this build's copy is installed.
    private func installLinks() async -> Int? {
        guard let adb, let apk = Self.linksAPK else { return nil }
        var installed: String?
        if let path = Self.baseAPKPath(in: (try? await shell("pm path " + Self.linksPackage)) ?? "") {
            installed = Self.sha256(sumOutput: (try? await shell("sha256sum " + Self.quote(path))) ?? "")
        }
        if installed != apk.sha256 {
            do {
                try await Self.install(apk.data, adb: adb)
            } catch let error where "\(error)".contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
                // Signed with another key (built elsewhere): it only goes on
                // as a new install, and keeps the browser role it had.
                let wasBrowser = await linksIsTheBrowser()
                _ = try? await shell("pm uninstall " + Self.linksPackage)
                do {
                    try await Self.install(apk.data, adb: adb)
                } catch {
                    logger.error("Avo Links did not install: \(String(describing: error), privacy: .public)")
                    return nil
                }
                if wasBrowser { _ = try? await root("cmd role add-role-holder \(Self.browserRole) \(Self.linksPackage)") }
            } catch {
                logger.error("Avo Links did not install: \(String(describing: error), privacy: .public)")
                return nil
            }
            logger.notice("installed Avo Links")
        }
        await retireFormerLinks()
        return Self.uid(of: Self.linksPackage, in: (try? await shell("pm list packages -U " + Self.linksPackage)) ?? "")
    }

    /// Uninstalls `formerLinksPackage` when it is there, passing its browser
    /// role on (a browser the user picked instead stays theirs).
    private func retireFormerLinks() async {
        guard Self.baseAPKPath(in: (try? await shell("pm path " + Self.formerLinksPackage)) ?? "") != nil else { return }
        let holders = (try? await root("cmd role get-role-holders \(Self.browserRole)").output) ?? ""
        let wasBrowser = Self.roleHolders(in: holders).contains(Self.formerLinksPackage)
        _ = try? await shell("pm uninstall " + Self.formerLinksPackage)
        if wasBrowser { _ = try? await root("cmd role add-role-holder \(Self.browserRole) \(Self.linksPackage)") }
        logger.notice("Avo Links moved to \(Self.linksPackage, privacy: .public)\(wasBrowser ? ", Android's browser still" : "", privacy: .public)")
    }

    /// Installs Avo Widgets when Android's copy is not this build's, and
    /// lets it bind widgets (each start: a reinstall forgets it).
    private func installWidgets() async -> Bool {
        guard let adb, let apk = Self.widgetsAPK else { return false }
        var installed: String?
        if let path = Self.baseAPKPath(in: (try? await shell("pm path " + AndroidWidgets.package)) ?? "") {
            installed = Self.sha256(sumOutput: (try? await shell("sha256sum " + Self.quote(path))) ?? "")
        }
        if installed != apk.sha256 {
            do {
                try await Self.install(apk.data, adb: adb)
            } catch let error where "\(error)".contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
                // Signed with another key (built elsewhere): only a new install goes on.
                _ = try? await shell("pm uninstall " + AndroidWidgets.package)
                guard (try? await Self.install(apk.data, adb: adb)) != nil else {
                    logger.error("Avo Widgets did not install")
                    return false
                }
            } catch {
                logger.error("Avo Widgets did not install: \(String(describing: error), privacy: .public)")
                return false
            }
            logger.notice("installed Avo Widgets")
        }
        // The builds before 0.3.0 Preview 2 hosted widgets under another name:
        // each panel gets its widget again from this one when it opens.
        if Self.baseAPKPath(in: (try? await shell("pm path " + AndroidWidgets.formerPackage)) ?? "") != nil {
            _ = try? await shell("pm uninstall " + AndroidWidgets.formerPackage)
            logger.notice("Avo Widgets moved to \(AndroidWidgets.package, privacy: .public)")
        }
        if let result = try? await root(GuestWidgets.grantCommand), !result.succeeded {
            logger.error("Avo Widgets may not bind widgets: \(result.output.trimmed, privacy: .public)")
        }
        return true
    }

    private static func install(_ apk: Data, adb: ADBConnection) async throws {
        let part = ADBConnection.InstallPart(name: "base.apk", size: UInt64(apk.count)) {
            AsyncThrowingStream { $0.yield(apk); $0.finish() }
        }
        // -d: an older Avo's copy replaces a newer one too (userdebug allows it).
        try await adb.install([part], options: ["-r", "-d"])
    }

    private func linksIsTheBrowser() async -> Bool {
        guard let output = try? await root("cmd role get-role-holders \(Self.browserRole)").output else { return false }
        return Self.roleHolders(in: output).contains(Self.linksPackage)
    }

    /// Avo Links becomes Android's browser once per data disk, so the links
    /// apps open go to the Mac; after that the browser is whichever the user
    /// picks in Android (Settings › Apps › Default apps).
    private func makeLinksTheBrowser() async {
        guard (try? await shell("settings get global \(Self.linksBrowserSetting)"))?.trimmed != "1" else { return }
        // As root: the role service wants MANAGE_ROLE_HOLDERS.
        _ = try? await root("cmd role add-role-holder \(Self.browserRole) \(Self.linksPackage)")
        guard await linksIsTheBrowser() else {
            logger.error("Avo Links did not become Android's browser; it tries again next boot")
            return
        }
        _ = try? await shell("settings put global \(Self.linksBrowserSetting) 1")
        logger.notice("Avo Links is Android's browser: links open on the Mac")
    }

    /// Follows Avo Links' log until logcat ends; false if it did not start
    /// or ended within a second (an error, not Android restarting logd).
    private func watchLinks(uid: Int) async -> Bool {
        let command = Self.linksLogcatCommand(uid: uid, since: linkReader.assembler.since)
        let started = ContinuousClock.now
        guard let adb, let stream = try? await adb.open("shell:" + command) else { return false }
        var buffer = Data()
        do {
            for try await chunk in stream.incoming {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    switch linkReader.read(line, at: .now) {
                    case .open(let url)?:
                        logger.notice("opening a link from Android: \(url.absoluteString, privacy: .private)")
                        linkSink?(url)
                    case .refused(let scheme)?:
                        logger.notice("a \(scheme, privacy: .public): link from Android stays in Android")
                    case .throttled?:
                        logger.notice("too many links from Android at once: one left out")
                    case nil:
                        break
                    }
                }
                // Avo Links' lines are a few kilobytes: anything longer is not one.
                if buffer.count > 64 << 10 { buffer.removeAll() }
            }
        } catch {}
        await stream.close()
        return ContinuousClock.now - started >= .seconds(1)
    }
}

// MARK: - Google apps (GoogleAppsInstaller's guest steps)

extension HostAgent: SystemAppsGuest {
    /// Where the package's files wait before root copies them in.
    static let googleAppsStaging = "/data/local/tmp/avo-gapps"

    func systemFacts() async throws -> SystemFacts {
        SystemFacts(sdk: Int(sdk), arch: try await shell("getprop ro.bionic.arch").trimmed,
                    product: try await shell("getprop ro.build.product").trimmed)
    }

    func verityEnabled() async throws -> Bool {
        let result = try await root("avbctl get-verity")
        guard let enabled = Self.verityEnabled(in: result.output + result.errorOutput) else {
            throw AvoError.installFailed(Self.failure(result, String(localized: "avbctl could not read verified boot’s state", bundle: .avoKit)))
        }
        return enabled
    }

    /// `verity is enabled on slot with suffix _a.` / `verity is disabled …`.
    static func verityEnabled(in output: String) -> Bool? {
        let text = output.lowercased()
        if text.contains("verity is disabled") { return false }
        if text.contains("verity is enabled") { return true }
        return nil
    }

    func disableVerity() async throws {
        // The engine keeps a writable vbmeta per VM (engine/hvf/vmm/src/cuttlefish.rs)
        // and reads its flags at the next start.
        let result = try await root("avbctl disable-verity")
        guard result.succeeded else {
            throw AvoError.installFailed(Self.failure(result, String(localized: "avbctl could not turn off verified boot", bundle: .avoKit)))
        }
    }

    func remount(afterRestart: Bool) async throws -> RemountResult {
        // The first time, remount creates the overlayfs scratch partition and
        // wants a reboot before /product and /system_ext take writes.
        // The installer gives each step its own time (GoogleAppsInstaller.Limits).
        let result = try await root("remount 2>&1", timeout: nil)
        if !afterRestart, Self.remountWantsReboot(result.output) { return .needsRestart }
        let probe = try await root("touch /product/.avo-probe /system_ext/.avo-probe && rm -f /product/.avo-probe /system_ext/.avo-probe")
        guard probe.succeeded else {
            throw AvoError.installFailed(Self.failure(result, String(localized: "Android’s system partitions stayed read-only", bundle: .avoKit)))
        }
        // The scratch partition is mounted `sync`: copying 700 MB through it
        // would take 20 minutes instead of seconds.
        _ = try? await root("grep -q ' /mnt/scratch ' /proc/mounts && mount -o remount,async /mnt/scratch")
        return .writable
    }

    /// `remount`: "… Now reboot your device for settings to take effect".
    static func remountWantsReboot(_ output: String) -> Bool {
        output.lowercased().contains("reboot your device")
    }

    func freeBytes(_ path: String) async -> UInt64? {
        guard let output = try? await root("df -k " + Self.quote(path)).output else { return nil }
        return Self.availableBytes(df: output)
    }

    /// `df -k`: `Filesystem 1K-blocks Used Available Use% Mounted on`, then one line.
    static func availableBytes(df output: String) -> UInt64? {
        let lines = output.split(separator: "\n").filter { !$0.hasPrefix("Filesystem") }
        guard let words = lines.last?.split(separator: " "), words.count >= 4, let kib = UInt64(words[3]) else { return nil }
        return kib * 1024
    }

    func stage(_ files: [GoogleAppsPackage.File], of package: GoogleAppsPackage,
               progress: @escaping @Sendable (UInt64) -> Void) async throws {
        guard let adb else { throw AvoError.guestUnavailable }
        // A previous attempt's files are root's by now.
        try await root("rm -rf \(Self.googleAppsStaging)")
        var done: UInt64 = 0
        for file in files {
            let base = done
            do {
                try await adb.push(ChunkPipe { send in try package.stream(file) { try send($0) } },
                                   to: Self.googleAppsStaging + "/" + file.path, mode: 0o644) { sent in progress(base + sent) }
            } catch let error as ADBError {
                throw AvoError.installFailed("\(file.path): \(error.description)")
            }
            done += file.size
        }
    }

    func commitStaged(_ paths: [String]) async throws {
        guard let adb else { throw AvoError.guestUnavailable }
        // Listed first, allowlists before apps, each piece renamed into
        // place (GoogleAppsCommit). Pushed: a few hundred files make a
        // script too long for one command line.
        let layout = GoogleAppsCommit.Layout(staging: Self.googleAppsStaging)
        let script = Data(GoogleAppsCommit.script(paths, layout: layout).utf8)
        do {
            try await adb.push(ChunkPipe { send in try send(script) }, to: layout.script, mode: 0o644)
        } catch let error as ADBError {
            throw AvoError.installFailed("\(layout.script): \(error.description)")
        }
        let result = try await root("sh " + layout.script, timeout: nil)
        guard result.succeeded else {
            throw AvoError.installFailed(Self.failure(result, String(localized: "copying into the system partitions failed", bundle: .avoKit)))
        }
    }

    func commitState() async throws -> CommitState {
        // Empty output means "no list" only when the shell got to run.
        let result = try await root(GoogleAppsCommit.stateCommand())
        guard result.succeeded else {
            throw AvoError.installFailed(Self.failure(result, String(localized: "reading the install’s file list failed", bundle: .avoKit)))
        }
        return GoogleAppsCommit.state(fromOutput: result.output)
    }

    func rollBackCommit() async throws {
        let result = try await root(GoogleAppsCommit.rollbackScript(layout: GoogleAppsCommit.Layout(staging: Self.googleAppsStaging)),
                                    timeout: nil)
        guard result.succeeded else {
            throw AvoError.installFailed(Self.failure(result, String(localized: "removing the copied files failed", bundle: .avoKit)))
        }
    }

    func packageNames() async throws -> Set<String> {
        try await listPackages("")
    }

    func systemPackageNames() async throws -> Set<String> {
        try await listPackages(" -s")
    }

    private func listPackages(_ options: String) async throws -> Set<String> {
        guard let adb else { throw AvoError.guestUnavailable }
        // A pm that failed lists nothing, which must not read as "Google
        // Play is missing" (that would take out a good install).
        let result = try await adb.shell("pm list packages" + options)
        guard result.succeeded else {
            throw AvoError.installFailed(Self.failure(result, String(localized: "Android did not list its apps", bundle: .avoKit)))
        }
        return Set(result.output.split(separator: "\n").compactMap { line in
            line.hasPrefix("package:") ? String(line.dropFirst("package:".count)).trimmed : nil
        })
    }

    func uninstallPackage(_ package: String) async throws {
        guard let adb else { throw AvoError.guestUnavailable }
        let result = try await adb.shell("pm uninstall " + Self.quote(package))
        guard result.succeeded, result.output.contains("Success") else {
            throw AvoError.installFailed(Self.failure(result, String(localized: "Android did not uninstall \(package)", bundle: .avoKit)))
        }
    }

    func googleAppsStatus() async -> GoogleAppsStatus {
        var status = GoogleAppsStatus(supported: true)
        guard isReady, let packages = try? await packageNames() else { return status }
        status.installed = packages.contains(GoogleApps.playServices) && packages.contains(GoogleApps.playStore)
        if packages.contains(GoogleApps.playServices), let system = try? await systemPackageNames() {
            status.systemApps = system.contains(GoogleApps.playServices)
        }
        if packages.contains(GoogleApps.playStore) { status.playStoreVersion = await versionName(of: GoogleApps.playStore) }
        if packages.contains(GoogleApps.playServices) { status.playServicesVersion = await versionName(of: GoogleApps.playServices) }
        if let output = try? await root("avbctl get-verity") {
            status.verityDisabled = Self.verityEnabled(in: output.output + output.errorOutput).map { !$0 }
        }
        if status.installed == true { status.androidID = await gsfAndroidID() }
        return status
    }

    /// `versionName=53.5.48-34 [0] [PR] 995634172` → `53.5.48-34`.
    private func versionName(of package: String) async -> String? {
        guard let output = try? await shell("dumpsys package \(Self.quote(package)) | grep -m 1 versionName=") else { return nil }
        return Self.versionName(dumpsys: output)
    }

    static func versionName(dumpsys output: String) -> String? {
        guard let range = output.range(of: "versionName=") else { return nil }
        let value = output[range.upperBound...].prefix { !$0.isWhitespace }
        return value.isEmpty ? nil : String(value)
    }

    /// The Android ID Google's registration page asks for: GSF's gservices
    /// provider, else the gservices database Play services keeps it in.
    private func gsfAndroidID() async -> String? {
        let query = "content query --uri content://com.google.android.gsf.gservices --where \"name='android_id'\""
        if let output = try? await root(query).output, let id = Self.androidID(contentQuery: output) { return id }
        for database in ["/data/data/com.google.android.gms/databases/gservices.db",
                         "/data/data/com.google.android.gsf/databases/gservices.db"] {
            let select = "[ -f \(database) ] && sqlite3 -readonly \(database) \"select value from main where name='android_id';\""
            if let output = try? await root(select).output, let id = Self.androidID(value: output) { return id }
        }
        return nil
    }

    /// `Row: 0 name=android_id, value=3641621413558569340`.
    static func androidID(contentQuery output: String) -> String? {
        guard let range = output.range(of: "value=") else { return nil }
        return androidID(value: String(output[range.upperBound...].prefix { !$0.isWhitespace && $0 != "," }))
    }

    static func androidID(value: String) -> String? {
        let text = value.trimmed
        return !text.isEmpty && text != "0" && text.allSatisfy(\.isNumber) ? text : nil
    }

    private static func failure(_ result: ShellResult, _ fallback: String) -> String {
        let text = (result.errorOutput + "\n" + result.output).trimmed
        return text.isEmpty ? fallback : "\(fallback): \(text.suffix(600))"
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Substring {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Fingerprints (Settings › Fingerprints: FingerprintCenter's guest steps, GuestFingerprints)

extension HostAgent: FingerprintGuest {
    func fingerprintShell(_ command: String, asRoot: Bool) async throws -> ShellResult {
        asRoot ? try await root(command) : try await adbShell(command)
    }

    func fingerprintPush(_ data: Data, to path: String) async throws {
        guard let adb else { throw AvoError.guestUnavailable }
        try await adb.push(AsyncStream { $0.yield(data); $0.finish() }, to: path)
    }
}

// MARK: - Widgets (Library › Widgets: Avo Widgets, GuestWidgets)

extension HostAgent: WidgetsGuest {
    func widgetProviders() async throws -> [WidgetProvider] {
        guard await widgetsInstall?.value == true else { throw AvoError.guestUnavailable }
        return try GuestWidgets.providers(try await shell(GuestWidgets.listCommand))
    }

    func deleteWidget(slot: String) async {
        guard await widgetsInstall?.value == true else { return }
        _ = try? await shell(GuestWidgets.deleteCommand(slot: slot))
    }
}

// MARK: - Answers (whether Android itself still answers: VMStatus.notRespondingSince)

extension HostAgent {
    /// Where it goes (VMMEngine.responsiveness): nil while Android answers,
    /// else since when it has not. Set before `prepare`.
    func forwardResponsiveness(to sink: @escaping @Sendable (Date?) -> Void) {
        responsivenessSink = sink
    }

    /// After a pause the questions start over.
    private func answersStartOver() {
        answers.reset()
    }

    /// The Control channel's keepalive is answered here, on the Mac, so it
    /// never notices Android itself hanging: this asks Android, through its
    /// adbd, what any shell answers at once. A paused Android answers
    /// nothing; it is not asked, and its count starts over.
    private func askAndroid() async {
        guard isReady else { return }
        guard !paused else {
            answers.reset()
            return
        }
        let asked = Date()
        let answered = (try? await shell("echo avo", timeout: GuestAnswers.timeout))?.trimmed == "avo"
        // Paused or stopped meanwhile: the question tells nothing.
        guard isReady, !paused else { return }
        switch answers.record(answered: answered, askedAt: asked) {
        case .notResponding(let since)?:
            logger.error("Android has not answered since \(since, privacy: .public)")
            responsivenessSink?(since)
        case .responding?:
            logger.notice("Android answers again")
            responsivenessSink?(nil)
        case nil:
            break
        }
    }
}

/// HostAgent's questions to Android: two in a row left unanswered (about
/// half a minute) make it not responding, the next answer responding again.
struct GuestAnswers: Sendable, Equatable {
    static let interval: Duration = .seconds(15)
    /// Android does more than this under the heaviest load.
    static let timeout: Duration = .seconds(10)
    static let unansweredLimit = 2

    enum Change: Equatable {
        case notResponding(since: Date)
        case responding
    }

    private(set) var unanswered = 0
    /// When the first of the questions in a row left unanswered was asked.
    private(set) var firstUnanswered: Date?
    private(set) var notResponding = false

    mutating func record(answered: Bool, askedAt asked: Date) -> Change? {
        guard !answered else {
            defer { reset() }
            return notResponding ? .responding : nil
        }
        unanswered += 1
        if firstUnanswered == nil { firstUnanswered = asked }
        guard unanswered >= Self.unansweredLimit, !notResponding, let since = firstUnanswered else { return nil }
        notResponding = true
        return .notResponding(since: since)
    }

    /// Paused: the questions start over once Android goes on.
    mutating func reset() {
        unanswered = 0
        firstUnanswered = nil
        notResponding = false
    }
}

// MARK: - Screen lock (Android started with a screen lock; GuestScreenLock)

extension HostAgent {
    /// Where the screen lock's state goes (VMMEngine.screenLockUpdates); set before `prepare`.
    func forwardScreenLock(to sink: @escaping @Sendable (AndroidScreenLock?) -> Void) {
        screenLockSink = sink
    }

    /// Android's screen lock while it keeps Android locked.
    var currentScreenLock: AndroidScreenLock? { screenLock }

    /// Every 2 s once this start found a screen lock: locked still, or again
    /// (the lock screen can come back while Android runs).
    private func watchScreenLock() async {
        guard isReady, lockCredential != nil else { return }
        await checkScreenLock()
    }

    /// Whether a screen lock keeps Android locked: user 0's storage closed,
    /// or the lock screen up over every display. Each lock also reads what
    /// it asks for; a start without a screen lock (storage opening by itself)
    /// leaves nothing to watch. Changes go to the daemon; becoming unlocked
    /// first catches up on what needed the user's storage.
    func checkScreenLock(initial: Bool = false) async {
        guard !checkingScreenLock else { return }
        checkingScreenLock = true
        defer { checkingScreenLock = false }
        guard let output = try? await shell(GuestScreenLock.stateCommand) else { return }
        let state = GuestScreenLock.state(output)
        if state.locked, initial || screenLock == nil, let dump = try? await shell(GuestScreenLock.credentialCommand) {
            lockCredential = GuestScreenLock.credential(dumpsys: dump)
        }
        let lock = state.locked ? lockCredential.map(AndroidScreenLock.init(credential:)) : nil
        if lock == nil, screenLock != nil { await screenUnlocked() }
        guard lock != screenLock || initial else { return }
        screenLock = lock
        if let lock { logger.notice("Android is locked by its screen lock (\(lock.credential.rawValue, privacy: .public))") }
        screenLockSink?(lock)
    }

    /// Unlocked: app infos described while the storage was closed are asked
    /// again (the daemon syncs the apps as it hears of the unlock), `known`
    /// catches up, and Avo Links becomes the browser if that failed meanwhile.
    private func screenUnlocked() async {
        logger.notice("Android is unlocked")
        infoCache.removeAll()
        await pollPackages()
        await makeLinksTheBrowser()
    }

    /// Passes the credential to Android: `lock_settings verify` checks it and
    /// opens the user's storage, then the lock screen's bouncer takes it.
    /// Returns once Android is unlocked. Neither the credential nor what
    /// Android answers (it repeats a wrong one) is ever logged.
    func unlockScreen(_ credential: ScreenLockCredential) async throws {
        guard isReady else { throw AvoError.vmNotRunning }
        guard let lock = screenLock else { return }
        guard credential.kind == lock.credential else { throw AvoError.screenLockRejected(throttled: false) }
        guard !unlocking else {
            throw AvoError.internalError(String(localized: "Android is already being unlocked.", bundle: .avoKit))
        }
        unlocking = true
        defer { unlocking = false }
        let result: ShellResult
        do {
            result = try await adbShell(GuestScreenLock.verifyCommand(credential))
        } catch {
            // The command holds the credential: not even the error goes to the log.
            logger.error("the screen lock could not be checked: ADB failed")
            throw AvoError.guestUnavailable
        }
        switch GuestScreenLock.outcome(exitCode: result.exitCode, output: result.output) {
        case .verified:
            logger.notice("Android took the screen lock's credential")
            await enterOnBouncer(credential)
        case .noLock:
            logger.notice("Android has no screen lock any more")
            _ = try? await shell(GuestScreenLock.dismissCommand)
        case .wrong:
            logger.notice("Android did not take the screen lock's credential")
            throw AvoError.screenLockRejected(throttled: false)
        case .throttled:
            logger.notice("Android takes no screen lock attempts for now")
            throw AvoError.screenLockRejected(throttled: true)
        case .failed:
            logger.error("checking the screen lock failed (exit \(result.exitCode))")
            throw AvoError.internalError(String(localized: "Android could not check the screen lock.", bundle: .avoKit))
        }
        // The storage opens within a moment; the lock screen goes as its bouncer takes the credential.
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            await checkScreenLock()
            if screenLock == nil { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        throw AvoError.internalError(String(localized: "Android took the screen lock, but its lock screen stayed up. Try again.", bundle: .avoKit))
    }

    /// `verify` opens the user's storage but leaves the lock screen up over
    /// every display: the bouncer on Android's own screen (display 0) takes
    /// the credential as a person would enter it. Only into the bouncer, which
    /// the window hierarchy must show first, and at most twice (a wrong entry
    /// counts against the attempts Android allows).
    private func enterOnBouncer(_ credential: ScreenLockCredential) async {
        for _ in 0..<2 {
            guard await lockScreenHolds() else { return }
            _ = try? await shell(GuestScreenLock.dismissCommand)
            guard let bouncer = await showingBouncer(), bouncer.takes(credential.kind) else {
                logger.error("Android's lock screen did not show its bouncer")
                return
            }
            // The commands hold the credential: their results are not looked at or logged.
            switch bouncer {
            case .pattern(let frame):
                _ = try? await adbShell(GuestScreenLock.patternCommand(credential.value, in: frame))
            case .pin:
                // A PIN can confirm itself as its last digit goes in: Enter only
                // while the PIN bouncer is still there.
                _ = try? await adbShell(GuestScreenLock.typingCommand(credential.value, enter: false))
                try? await Task.sleep(for: .milliseconds(500))
                if await showingBouncer(attempts: 1) == .pin { _ = try? await adbShell(GuestScreenLock.enterCommand) }
            case .password:
                _ = try? await adbShell(GuestScreenLock.typingCommand(credential.value, enter: true))
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// The bouncer on display 0, once it shows (the window hierarchy can be
    /// busy with an animation for a moment).
    private func showingBouncer(attempts: Int = 4) async -> GuestScreenLock.Bouncer? {
        for attempt in 0..<attempts {
            if attempt > 0 || attempts > 1 { try? await Task.sleep(for: .milliseconds(500)) }
            if let bouncer = GuestScreenLock.bouncer(inDump: (try? await shell(GuestScreenLock.dumpCommand)) ?? "") { return bouncer }
        }
        return nil
    }

    /// The lock screen holds the device, or nothing says it does not.
    private func lockScreenHolds() async -> Bool {
        guard let output = try? await shell(GuestScreenLock.stateCommand) else { return true }
        return GuestScreenLock.state(output).keyguardLocked ?? true
    }
}
