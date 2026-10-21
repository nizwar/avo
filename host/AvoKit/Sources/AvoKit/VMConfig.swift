import Foundation

/// Everything the Control Panel can change about the VM (spec §6).
public struct VMConfig: Codable, Equatable, Sendable {
    public enum Renderer: String, Codable, CaseIterable, Sendable {
        case vulkan
        case gles
    }

    public enum Orientation: String, Codable, CaseIterable, Sendable {
        case portrait
        case landscape
    }

    /// Google services strategy chosen at first setup (spec: Strategi GMS).
    public enum GMSMode: String, Codable, CaseIterable, Sendable {
        /// Pure AOSP with F-Droid or Aurora Store.
        case none
        /// microG with signature spoofing restricted to microG.
        case microG
        /// User-supplied GApps package installed by the wizard.
        case bringYourOwn
    }

    public struct WindowSize: Codable, Equatable, Sendable {
        /// Content size in points.
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        public var rotated: WindowSize { WindowSize(width: height, height: width) }
    }

    public static let memoryRangeMiB = 2048...16384
    /// Android's frame rate caps. Every Android display runs at the cap
    /// above 60 Hz, else at 60 (FrameRates); 30 is half of 60. Settings
    /// offer these and the own rate of a screen of the Mac between 60 and
    /// 120 (75 Hz, `FrameRates.choices`): any whole rate up to 120 works.
    public static let fpsChoices = [30, 60, 90, 120]
    public static let dpiRange = 120...640
    /// Where adb looks for the first emulator.
    public static let defaultADBPort = 5555
    public static let adbPortRange = 1024...65535
    /// RAM recommended for the "Game berat" preset.
    public static let heavyGameMemoryMiB = 8192
    /// Pause When Idle: off (0) or after this many minutes without a window.
    public static let autoPauseChoices = [0, 5, 15, 30]

    // Performa
    public var memoryMiB: Int
    public var cpuCount: Int
    public var balloonWhenIdle: Bool
    /// Pause When Idle: Android pauses after this many minutes with no app
    /// window open and nothing under way (0: never; `autoPauseChoices`).
    public var autoPauseMinutes: Int

    // Storage
    /// The size of Android's storage in GB as Android's Settings shows it
    /// (10⁹ bytes; the key keeps its old name). It sizes the data disk when
    /// Android creates its storage there (`dataDiskBytes`); after that the
    /// size changes only by erasing Android's data.
    public var dataDiskGiB: Int
    /// Custom directory for the Android image and data disk; nil uses AvoPaths.
    public var imageLocation: String?
    /// Settings › Storage › Shared Folder: a Mac folder Android sees as
    /// /sdcard/Avo Shared (SharedFolder.swift), from its next start.
    public var shareFolder: Bool
    public var sharedFolderPath: String?

    // Grafis
    /// The crosvm contract only (docs/engine.md); still written so an older
    /// Avo reading this file never throws it away. avo-vmm reads `rendererMode`.
    public var renderer: Renderer
    /// Graphics › Renderer for avo-vmm: GPU (gfxstream) or software.
    public var rendererMode: RendererMode
    public var fpsLimit: Int
    /// Resolution, interface size and scaling of app windows: the Apps and
    /// Games profiles (GraphicsSettings.swift).
    public var appGraphics: GraphicsSettings
    public var gameGraphics: GraphicsSettings
    /// What single apps change, by package. The daemon changes these only
    /// through `setAppGraphics`; `updateConfiguration` keeps its own copy.
    public var graphicsOverrides: [String: AppGraphicsOverride]
    public var performanceHUD: PerformanceHUDLevel

    // App windows
    /// The size of an app's first window, turned to its graphics'
    /// orientation (`GraphicsSettings.orientation`, once `defaultOrientation`).
    public var defaultWindowSize: WindowSize

    // Sistem
    public var rooted: Bool
    public var deviceProfileID: String
    /// "Emulate this phone's hardware": apply the profile's SoC, CPU, GPU and
    /// display (`DeviceHardware`) as well as its name, for testing a build's
    /// per-device code paths. Off by default and ignored for Avo's honest
    /// identity, which has no hardware to emulate.
    public var emulateHardware: Bool
    public var gms: GMSMode
    /// "ADB support": adb on this Mac can reach Android at 127.0.0.1:`adbPort`.
    public var adbEnabled: Bool
    public var adbPort: Int
    /// Android's GPS reports where this Mac is (CoreLocation).
    public var shareLocation: Bool
    /// An app's Dock icon shows how many notifications it has in Android.
    public var dockBadges: Bool
    // Devices (Settings › Devices)
    /// Android's Wi-Fi is on (its one network today; off, Android is offline).
    public var wifiEnabled: Bool
    /// How fast Android's network is: the Mac's, or a mobile network type's.
    public var networkSpeed: NetworkSpeed
    /// While Android's Bluetooth is on, it reaches the Bluetooth LE devices
    /// this Mac sees (MacBluetoothBridge).
    public var shareMacBluetooth: Bool
    /// Android has a SIM on a mobile network (avo-vmm's modem): its status
    /// bar shows the network type and signal, and mobile data goes through
    /// this Mac too. Off, Android is a Wi-Fi-only phone.
    public var cellularEnabled: Bool
    public var mobileNetworkType: MobileNetworkType
    /// Signal bars, 0 (none) to 4.
    public var cellularSignal: Int
    /// What Android's back and front cameras show (CameraSource).
    public var backCamera: CameraSource
    public var frontCamera: CameraSource
    // The Mac's devices Android may use, each kept from it when off
    // (Settings › Devices): Android then has no such hardware, and Avo never
    // asks macOS for it.
    /// Android has cameras (the ones above); off, none at all.
    public var camerasEnabled: Bool
    /// Android may use the Mac's microphone; off, it records silence.
    public var microphoneEnabled: Bool
    /// Android has Bluetooth (with the Android Emulator's netsimd); off, none.
    public var bluetoothEnabled: Bool
    /// Text copied on the Mac reaches Android and the other way round.
    public var shareClipboard: Bool
    /// Translate Screen's engine (one for every app, in the daemon) gets
    /// ready as the daemon starts; off, when an app first translates.
    public var translationAtStartup: Bool

    // Shortcuts (spec §4)
    public var createDesktopAlias: Bool
    public var addToDock: Bool

    public init(memoryMiB: Int = 4096, cpuCount: Int = 4, balloonWhenIdle: Bool = true, autoPauseMinutes: Int = 15,
                dataDiskGiB: Int = 32, imageLocation: String? = nil, shareFolder: Bool = false, sharedFolderPath: String? = nil,
                renderer: Renderer = .vulkan, rendererMode: RendererMode = .auto, fpsLimit: Int = 60,
                appGraphics: GraphicsSettings = .appsDefault, gameGraphics: GraphicsSettings = .gamesDefault,
                graphicsOverrides: [String: AppGraphicsOverride] = [:], performanceHUD: PerformanceHUDLevel = .off,
                defaultWindowSize: WindowSize = WindowSize(width: 412, height: 892),
                rooted: Bool = false, deviceProfileID: String = DeviceProfile.defaultID, emulateHardware: Bool = false,
                gms: GMSMode = .none, adbEnabled: Bool = false, adbPort: Int = VMConfig.defaultADBPort, shareLocation: Bool = true, dockBadges: Bool = true,
                wifiEnabled: Bool = true, networkSpeed: NetworkSpeed = .full, shareMacBluetooth: Bool = true,
                cellularEnabled: Bool = false, mobileNetworkType: MobileNetworkType = .lte, cellularSignal: Int = 4,
                backCamera: CameraSource = .emulated, frontCamera: CameraSource = .emulated,
                camerasEnabled: Bool = true, microphoneEnabled: Bool = true, bluetoothEnabled: Bool = true,
                shareClipboard: Bool = true,
                translationAtStartup: Bool = true,
                createDesktopAlias: Bool = true, addToDock: Bool = false) {
        self.memoryMiB = memoryMiB
        self.cpuCount = cpuCount
        self.balloonWhenIdle = balloonWhenIdle
        self.autoPauseMinutes = autoPauseMinutes
        self.dataDiskGiB = dataDiskGiB
        self.imageLocation = imageLocation
        self.shareFolder = shareFolder
        self.sharedFolderPath = sharedFolderPath
        self.renderer = renderer
        self.rendererMode = rendererMode
        self.fpsLimit = fpsLimit
        self.appGraphics = appGraphics
        self.gameGraphics = gameGraphics
        self.graphicsOverrides = graphicsOverrides
        self.performanceHUD = performanceHUD
        self.defaultWindowSize = defaultWindowSize
        self.rooted = rooted
        self.deviceProfileID = deviceProfileID
        self.emulateHardware = emulateHardware
        self.gms = gms
        self.adbEnabled = adbEnabled
        self.adbPort = adbPort
        self.shareLocation = shareLocation
        self.dockBadges = dockBadges
        self.wifiEnabled = wifiEnabled
        self.networkSpeed = networkSpeed
        self.shareMacBluetooth = shareMacBluetooth
        self.cellularEnabled = cellularEnabled
        self.mobileNetworkType = mobileNetworkType
        self.cellularSignal = cellularSignal
        self.backCamera = backCamera
        self.frontCamera = frontCamera
        self.camerasEnabled = camerasEnabled
        self.microphoneEnabled = microphoneEnabled
        self.bluetoothEnabled = bluetoothEnabled
        self.shareClipboard = shareClipboard
        self.translationAtStartup = translationAtStartup
        self.createDesktopAlias = createDesktopAlias
        self.addToDock = addToDock
    }

    /// Defaults sized for the Mac the VM runs on: half the RAM (2–8 GB) and
    /// the performance cores, leaving the efficiency cores to macOS.
    public static func recommended(for host: HostInfo) -> VMConfig {
        var config = VMConfig()
        let halfMiB = Int(host.physicalMemoryBytes / 1_048_576 / 2)
        config.memoryMiB = min(max(roundDown(halfMiB, to: 512), memoryRangeMiB.lowerBound), 8192)
        config.cpuCount = max(2, min(host.performanceCores, 8))
        return config
    }

    /// Preset "Game berat": GPU rendering, no frame rate cap below 60 (a
    /// higher one stays), at least 8 GB when the Mac allows it, and games at a fixed 720p
    /// 16:9 enlarged with MetalFX (the user's interface size and sharpness stay).
    public mutating func applyHeavyGamePreset(host: HostInfo) {
        renderer = .vulkan
        rendererMode = .gpu
        fpsLimit = max(fpsLimit, FrameRates.standardRate)
        if host.maxGuestMemoryMiB >= Self.heavyGameMemoryMiB {
            memoryMiB = max(memoryMiB, Self.heavyGameMemoryMiB)
        }
        gameGraphics.mode = .fixed
        gameGraphics.shortSide = 720
        gameGraphics.aspectRatio = .ratio16x9
        gameGraphics.filter = .metalFXSpatial
    }

    private static func roundDown(_ value: Int, to step: Int) -> Int { value / step * step }

    /// A cap Android can run at: 30, or a display rate from 60 to 120 Hz.
    public static func isSupportedFPS(_ fps: Int) -> Bool {
        fps == fpsChoices[0] || (FrameRates.standardRate...FrameRates.maximumRate).contains(fps)
    }

    /// `fps` when Android can run at it, else 120 above that and the
    /// highest cap in `fpsChoices` under it (the lowest for less).
    public static func supportedFPS(_ fps: Int) -> Int {
        if isSupportedFPS(fps) { return fps }
        return fps > FrameRates.maximumRate ? FrameRates.maximumRate : fpsChoices.last { $0 <= fps } ?? fpsChoices[0]
    }

    // MARK: Storage sizes

    /// Storage sizes like a phone's: the sizes Android's Settings can show.
    public static let dataDiskChoices = [16, 32, 64, 128, 256, 512]
    public static let dataDiskRangeGB = 8...1024
    /// Room left under the chosen size for Android's system partition, which
    /// Settings › Storage counts with the data (about 1 GB on Cuttlefish).
    static let systemHeadroomBytes: Int64 = 2_000_000_000

    /// The data disk Avo creates for `gb`. Android's Settings adds its data
    /// and system partitions and rounds the sum up to a phone size (16, 32,
    /// 64 … GB of 10⁹ bytes, `androidStorageSize`), so the disk leaves room
    /// for the system partition under `gb`: Settings then shows `gb` exactly
    /// for every size in `dataDiskChoices`, and a fresh Android little used.
    public static func dataDiskBytes(gb: Int) -> Int64 {
        let bytes = max(Int64(gb) * 1_000_000_000 - systemHeadroomBytes, 4 << 30)
        return bytes / (1 << 20) * (1 << 20)
    }

    /// Android's `FileUtils.roundStorageSize`: the total Settings › Storage
    /// shows for `bytes` (1, 2, 4 … 512 of 10⁹ⁿ bytes).
    public static func androidStorageSize(_ bytes: Int64) -> Int64 {
        var value: Int64 = 1
        var unit: Int64 = 1
        while value * unit < bytes {
            value <<= 1
            if value > 512 {
                value = 1
                unit *= 1000
            }
        }
        return value * unit
    }

    private enum CodingKeys: String, CodingKey {
        case memoryMiB, cpuCount, balloonWhenIdle, autoPauseMinutes, dataDiskGiB, imageLocation, shareFolder, sharedFolderPath
        case renderer, rendererMode, fpsLimit
        case appGraphics, gameGraphics, graphicsOverrides, performanceHUD
        case defaultWindowSize, rooted, deviceProfileID, emulateHardware, gms, adbEnabled, adbPort, shareLocation, dockBadges
        case wifiEnabled, networkSpeed, shareMacBluetooth, cellularEnabled, mobileNetworkType, cellularSignal
        case backCamera, frontCamera, camerasEnabled, microphoneEnabled, bluetoothEnabled, shareClipboard
        case translationAtStartup
        case createDesktopAlias, addToDock
    }

    /// Read once, from files saved before graphics profiles (or before each
    /// had its own orientation), and never written.
    private enum LegacyKeys: String, CodingKey {
        case defaultDPI, retinaScaling, defaultOrientation
    }

    /// Settings missing from a file saved by an older Avo, or holding a value
    /// this Avo does not know (a newer Avo's), take their defaults instead of
    /// the whole file being ignored.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VMConfig()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        memoryMiB = try value(.memoryMiB, defaults.memoryMiB)
        cpuCount = try value(.cpuCount, defaults.cpuCount)
        balloonWhenIdle = try value(.balloonWhenIdle, defaults.balloonWhenIdle)
        // A time this Avo does not offer becomes the nearest one it does (never stays never).
        let pauseMinutes = try value(.autoPauseMinutes, defaults.autoPauseMinutes)
        autoPauseMinutes = pauseMinutes <= 0 ? 0
            : Self.autoPauseChoices.filter { $0 > 0 }.min { abs($0 - pauseMinutes) < abs($1 - pauseMinutes) } ?? defaults.autoPauseMinutes
        dataDiskGiB = try value(.dataDiskGiB, defaults.dataDiskGiB)
        imageLocation = try container.decodeIfPresent(String.self, forKey: .imageLocation)
        shareFolder = try value(.shareFolder, defaults.shareFolder)
        sharedFolderPath = try? container.decodeIfPresent(String.self, forKey: .sharedFolderPath)
        renderer = try value(.renderer, defaults.renderer)
        // A new key: files from before it (with only `renderer`) use Automatic.
        rendererMode = (try? container.decodeIfPresent(String.self, forKey: .rendererMode)).flatMap(RendererMode.init(rawValue:))
            ?? defaults.rendererMode
        // A cap Android cannot run at (45, or 144 from a hand edit) becomes
        // the highest one it can under it (120 above that).
        fpsLimit = Self.supportedFPS(try value(.fpsLimit, defaults.fpsLimit))
        // Graphics are read field by field: a value this Avo does not know
        // drops that field (or one app's override), never the whole file.
        func patch(_ key: CodingKeys) -> GraphicsSettingsPatch {
            (try? container.decodeIfPresent(GraphicsSettingsPatch.self, forKey: key)) ?? GraphicsSettingsPatch()
        }
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let apps = patch(.appGraphics)
        appGraphics = container.contains(.appGraphics) ? apps.applied(to: .appsDefault) : Self.migratedAppGraphics(legacy)
        // Display › Orientation was the apps' before each profile had one.
        if apps.orientation == nil,
           let orientation = (try? legacy.decodeIfPresent(String.self, forKey: .defaultOrientation)).flatMap(Orientation.init(rawValue:)) {
            appGraphics.orientation = orientation
        }
        gameGraphics = patch(.gameGraphics).applied(to: .gamesDefault)
        let overrides = (try? container.decodeIfPresent([String: Failable<AppGraphicsOverride>].self, forKey: .graphicsOverrides)) ?? [:]
        graphicsOverrides = overrides.compactMapValues { $0.value.flatMap { $0.isEmpty ? nil : $0 } }
        performanceHUD = (try? container.decodeIfPresent(String.self, forKey: .performanceHUD)).flatMap(PerformanceHUDLevel.init(rawValue:))
            ?? defaults.performanceHUD
        defaultWindowSize = try value(.defaultWindowSize, defaults.defaultWindowSize)
        rooted = try value(.rooted, defaults.rooted)
        deviceProfileID = try value(.deviceProfileID, defaults.deviceProfileID)
        emulateHardware = try value(.emulateHardware, defaults.emulateHardware)
        gms = try value(.gms, defaults.gms)
        adbEnabled = try value(.adbEnabled, defaults.adbEnabled)
        adbPort = try value(.adbPort, defaults.adbPort)
        shareLocation = try value(.shareLocation, defaults.shareLocation)
        dockBadges = try value(.dockBadges, defaults.dockBadges)
        wifiEnabled = try value(.wifiEnabled, defaults.wifiEnabled)
        networkSpeed = try value(.networkSpeed, defaults.networkSpeed)
        shareMacBluetooth = try value(.shareMacBluetooth, defaults.shareMacBluetooth)
        cellularEnabled = try value(.cellularEnabled, defaults.cellularEnabled)
        mobileNetworkType = try value(.mobileNetworkType, defaults.mobileNetworkType)
        cellularSignal = min(max(try value(.cellularSignal, defaults.cellularSignal), 0), 4)
        backCamera = try value(.backCamera, defaults.backCamera)
        frontCamera = try value(.frontCamera, defaults.frontCamera)
        camerasEnabled = try value(.camerasEnabled, defaults.camerasEnabled)
        microphoneEnabled = try value(.microphoneEnabled, defaults.microphoneEnabled)
        bluetoothEnabled = try value(.bluetoothEnabled, defaults.bluetoothEnabled)
        shareClipboard = try value(.shareClipboard, defaults.shareClipboard)
        translationAtStartup = try value(.translationAtStartup, defaults.translationAtStartup)
        createDesktopAlias = try value(.createDesktopAlias, defaults.createDesktopAlias)
        addToDock = try value(.addToDock, defaults.addToDock)
    }

    /// Apps settings for a file saved before graphics profiles. "Render at
    /// Retina resolution" off rendered at 1x, half of Retina's pixels; a
    /// custom density counted dpi at that pixel size (160 per point at 1x,
    /// 320 on Retina screens), so it becomes the interface size that gives
    /// the same layout.
    private static func migratedAppGraphics(_ legacy: KeyedDecodingContainer<LegacyKeys>) -> GraphicsSettings {
        let retina = (try? legacy.decodeIfPresent(Bool.self, forKey: .retinaScaling)) ?? true
        let dpi = try? legacy.decodeIfPresent(Int.self, forKey: .defaultDPI)
        var settings = GraphicsSettings.appsDefault
        settings.renderScale = retina ? 100 : 50
        if let dpi {
            let percent = Int((Double(dpi) / (retina ? 320 : 160) * 100).rounded())
            let range = GraphicsSettings.interfaceScaleRange
            settings.interfaceScale = min(max(percent, range.lowerBound), range.upperBound)
        }
        return settings
    }
}

/// Decodes what it can: one unreadable entry of a collection is dropped
/// instead of failing the whole collection.
private struct Failable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - Validation

public struct ConfigIssue: Codable, Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Codable, Sendable { case error, warning }

    public var field: String
    public var severity: Severity
    public var message: String

    public init(field: String, severity: Severity, message: String) {
        self.field = field
        self.severity = severity
        self.message = message
    }

    public var description: String { "\(field): \(message)" }
}

extension VMConfig {
    /// Checks the configuration against the spec's limits and the host.
    /// `previous` is the configuration currently in effect, used for rules
    /// such as "the data disk can grow but never shrink".
    public func validate(previous: VMConfig?, host: HostInfo) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        func error(_ field: String, _ message: String) { issues.append(.init(field: field, severity: .error, message: message)) }
        func warning(_ field: String, _ message: String) { issues.append(.init(field: field, severity: .warning, message: message)) }

        if !Self.memoryRangeMiB.contains(memoryMiB) {
            error("memoryMiB", String(localized: "RAM must be between 2 and 16 GB.", bundle: .avoKit))
        } else if memoryMiB % 256 != 0 {
            error("memoryMiB", String(localized: "RAM must be a multiple of 256 MB.", bundle: .avoKit))
        } else if memoryMiB > host.maxGuestMemoryMiB {
            error("memoryMiB", String(localized: "This Mac can give Android at most \(host.maxGuestMemoryMiB / 1024) GB.", bundle: .avoKit))
        }

        if cpuCount < 1 || cpuCount > host.totalCores {
            error("cpuCount", String(localized: "CPU cores must be between 1 and \(host.totalCores).", bundle: .avoKit))
        } else if cpuCount > host.performanceCores {
            warning("cpuCount", String(localized: "More cores than this Mac’s \(host.performanceCores) performance cores can slow macOS down.",
                                       bundle: .avoKit))
        }

        // Whether the size can change at all (not once Android created its
        // storage) is the daemon's to say: it knows the disk.
        if !Self.dataDiskRangeGB.contains(dataDiskGiB) {
            error("dataDiskGiB", String(localized: "Android’s storage must be between \(Self.dataDiskRangeGB.lowerBound) and \(Self.dataDiskRangeGB.upperBound) GB.",
                                         bundle: .avoKit))
        }

        if !Self.autoPauseChoices.contains(autoPauseMinutes) {
            error("autoPauseMinutes", String(localized: "“Pause when idle” must be Never or 5, 15 or 30 minutes.", bundle: .avoKit))
        }
        if !Self.isSupportedFPS(fpsLimit) {
            error("fpsLimit", String(localized: "FPS limit must be 30, or between 60 and 120.",
                                      bundle: .avoKit))
        }
        issues += appGraphics.validate(field: "appGraphics")
        issues += gameGraphics.validate(field: "gameGraphics")
        for (package, override) in graphicsOverrides.sorted(by: { $0.key < $1.key }) {
            issues += override.changes.validate(field: "graphicsOverrides.\(package)")
        }
        if defaultWindowSize.width < 240 || defaultWindowSize.height < 240 {
            error("defaultWindowSize", String(localized: "Windows must be at least 240 × 240 points.", bundle: .avoKit))
        }
        if rendererMode == .gpu && memoryMiB < Self.heavyGameMemoryMiB {
            warning("memoryMiB", String(localized: "Heavy games run best with at least 8 GB of RAM.", bundle: .avoKit))
        }
        if deviceProfileID.isEmpty {
            error("deviceProfileID", String(localized: "Choose a device profile.", bundle: .avoKit))
        }
        if !Self.adbPortRange.contains(adbPort) {
            error("adbPort", String(localized: "The ADB port must be between \(Self.adbPortRange.lowerBound) and \(Self.adbPortRange.upperBound).",
                                     bundle: .avoKit))
        }
        return issues
    }
}

// MARK: - Restart rules (spec §6 table)

/// When a configuration change takes effect.
public enum ConfigChangeEffect: String, Codable, Comparable, Sendable {
    /// Applied right away to the running VM and open windows.
    case immediate
    /// Applies to windows opened after the change.
    case newWindows
    /// Needs the VM to restart.
    case restartRequired

    private var rank: Int {
        switch self {
        case .immediate: 0
        case .newWindows: 1
        case .restartRequired: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

extension VMConfig {
    /// Fields that changed between `old` and `self`, each with its effect.
    public func changes(from old: VMConfig) -> [(field: String, effect: ConfigChangeEffect)] {
        var result: [(String, ConfigChangeEffect)] = []
        func check<T: Equatable>(_ keyPath: KeyPath<VMConfig, T>, _ name: String, _ effect: ConfigChangeEffect) {
            if self[keyPath: keyPath] != old[keyPath: keyPath] { result.append((name, effect)) }
        }
        // Performa: all need a restart.
        check(\.memoryMiB, "memoryMiB", .restartRequired)
        check(\.cpuCount, "cpuCount", .restartRequired)
        check(\.balloonWhenIdle, "balloonWhenIdle", .restartRequired)
        // The daemon's own timer: from now on.
        check(\.autoPauseMinutes, "autoPauseMinutes", .immediate)
        // Storage: resizing or moving the disk needs a restart.
        check(\.dataDiskGiB, "dataDiskGiB", .restartRequired)
        check(\.imageLocation, "imageLocation", .restartRequired)
        // The engine serves the shared folder from its start.
        check(\.shareFolder, "shareFolder", .restartRequired)
        check(\.sharedFolderPath, "sharedFolderPath", .restartRequired)
        // Grafis ("sebagian"): the renderer needs a restart, the FPS cap does
        // not, and open windows re-plug their displays for graphics changes.
        check(\.renderer, "renderer", .restartRequired)
        check(\.rendererMode, "rendererMode", .restartRequired)
        check(\.fpsLimit, "fpsLimit", .immediate)
        check(\.appGraphics, "appGraphics", .immediate)
        check(\.gameGraphics, "gameGraphics", .immediate)
        check(\.graphicsOverrides, "graphicsOverrides", .immediate)
        check(\.performanceHUD, "performanceHUD", .immediate)
        // App windows: never needs a restart.
        check(\.defaultWindowSize, "defaultWindowSize", .newWindows)
        // Sistem: root, device profile and GMS are applied at boot.
        check(\.rooted, "rooted", .restartRequired)
        check(\.deviceProfileID, "deviceProfileID", .restartRequired)
        check(\.emulateHardware, "emulateHardware", .restartRequired)
        check(\.gms, "gms", .restartRequired)
        // ADB support opens or closes its port right away.
        check(\.adbEnabled, "adbEnabled", .immediate)
        check(\.adbPort, "adbPort", .immediate)
        check(\.shareLocation, "shareLocation", .immediate)
        check(\.dockBadges, "dockBadges", .immediate)
        // Devices: Android follows at once.
        check(\.wifiEnabled, "wifiEnabled", .immediate)
        check(\.networkSpeed, "networkSpeed", .immediate)
        check(\.shareMacBluetooth, "shareMacBluetooth", .immediate)
        check(\.cellularEnabled, "cellularEnabled", .immediate)
        check(\.mobileNetworkType, "mobileNetworkType", .immediate)
        check(\.cellularSignal, "cellularSignal", .immediate)
        // Cameras: which ones Android has (and whose HAL) is set at its
        // start; what a camera it has shows changes at once.
        if cameraSources != old.cameraSources || camerasEnabled != old.camerasEnabled {
            result.append(("cameras", cameraFlags == old.cameraFlags ? .immediate : .restartRequired))
        }
        // The engine plugs Bluetooth's controller in at its start; the
        // microphone and the clipboard follow at once.
        check(\.bluetoothEnabled, "bluetoothEnabled", .restartRequired)
        check(\.microphoneEnabled, "microphoneEnabled", .immediate)
        check(\.shareClipboard, "shareClipboard", .immediate)
        check(\.translationAtStartup, "translationAtStartup", .immediate)
        // Shortcuts.
        check(\.createDesktopAlias, "createDesktopAlias", .immediate)
        check(\.addToDock, "addToDock", .immediate)
        return result
    }

    public func effect(of old: VMConfig) -> ConfigChangeEffect {
        changes(from: old).map(\.effect).max() ?? .immediate
    }
}

// MARK: - Persistence

extension VMConfig {
    public static func load(from url: URL) throws -> VMConfig {
        try JSONDecoder().decode(VMConfig.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
