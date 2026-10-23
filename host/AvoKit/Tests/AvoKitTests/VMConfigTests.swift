import Foundation
import Testing
@testable import AvoKit

let macBook16 = HostInfo(physicalMemoryBytes: 16 << 30, performanceCores: 4, efficiencyCores: 4,
                         isAppleSilicon: true, macOSVersion: "27.0")
let macStudio64 = HostInfo(physicalMemoryBytes: 64 << 30, performanceCores: 12, efficiencyCores: 4,
                           isAppleSilicon: true, macOSVersion: "27.0")
let macMini8 = HostInfo(physicalMemoryBytes: 8 << 30, performanceCores: 4, efficiencyCores: 4,
                        isAppleSilicon: true, macOSVersion: "27.0")

@Suite struct VMConfigTests {
    @Test func defaultsAreValid() {
        #expect(VMConfig().validate(previous: nil, host: macBook16).filter { $0.severity == .error }.isEmpty)
    }

    @Test func recommendedFitsTheHost() {
        let small = VMConfig.recommended(for: macMini8)
        #expect(small.memoryMiB == 4096)
        #expect(small.cpuCount == 4)
        let big = VMConfig.recommended(for: macStudio64)
        #expect(big.memoryMiB == 8192)
        #expect(big.cpuCount == 8)
        #expect(big.validate(previous: nil, host: macStudio64).isEmpty)
    }

    @Test func maxGuestMemoryLeavesRoomForMacOS() {
        #expect(macMini8.maxGuestMemoryMiB == 4096)
        #expect(macBook16.maxGuestMemoryMiB == 12288)
        #expect(macStudio64.maxGuestMemoryMiB == 16384) // capped by the spec
    }

    @Test(arguments: [1024, 2000, 20480]) func rejectsMemoryOutsideSpec(memory: Int) {
        var config = VMConfig()
        config.memoryMiB = memory
        #expect(config.validate(previous: nil, host: macStudio64).contains { $0.field == "memoryMiB" && $0.severity == .error })
    }

    /// "Emulate this phone's hardware": Android gets the phone's RAM, as far
    /// as the Mac and Avo's range allow; otherwise the configured amount.
    @Test func emulatedPhoneBringsItsMemory() {
        func phone(_ gb: Int?) -> DeviceProfile {
            DeviceProfile(id: "p", name: "P", properties: [:], hardware: DeviceHardware(memoryGB: gb))
        }
        var config = VMConfig()
        config.memoryMiB = 8192
        #expect(config.androidMemoryMiB(profile: phone(12), host: macStudio64) == 8192, "off: the setting")
        config.emulateHardware = true
        #expect(config.androidMemoryMiB(profile: phone(12), host: macStudio64) == 12288)
        #expect(config.androidMemoryMiB(profile: phone(3), host: macStudio64) == 3072, "a small phone stays small")
        #expect(config.androidMemoryMiB(profile: phone(12), host: macMini8) == 4096, "the Mac's limit")
        #expect(config.androidMemoryMiB(profile: phone(24), host: macStudio64) == 16384, "Avo's limit")
        #expect(config.androidMemoryMiB(profile: phone(1), host: macStudio64) == 2048, "Avo's floor")
        #expect(config.androidMemoryMiB(profile: phone(nil), host: macStudio64) == 8192, "no memory in the profile")
        #expect(config.androidMemoryMiB(profile: nil, host: macStudio64) == 8192)
    }

    @Test func rejectsMoreMemoryThanTheMacCanSpare() {
        var config = VMConfig()
        config.memoryMiB = 8192
        let issues = config.validate(previous: nil, host: macMini8)
        #expect(issues.contains { $0.field == "memoryMiB" && $0.severity == .error })
    }

    /// Any size in range is valid here; once Android created its storage the
    /// daemon refuses every change (DataDiskStore), smaller or bigger.
    @Test func dataDiskSizeStaysInRange() {
        let current = VMConfig(dataDiskGiB: 64)
        for gb in [8, 16, 32, 128, 1024] {
            var changed = current
            changed.dataDiskGiB = gb
            #expect(!changed.validate(previous: current, host: macBook16).contains { $0.field == "dataDiskGiB" })
        }
        for gb in [4, 7, 1025] {
            var changed = current
            changed.dataDiskGiB = gb
            #expect(changed.validate(previous: current, host: macBook16).contains { $0.field == "dataDiskGiB" && $0.severity == .error })
        }
    }

    @Test func fpsMustBeARateAndroidRuns() {
        var config = VMConfig()
        for fps in [45, 59, 121, 144, 0] {
            config.fpsLimit = fps
            #expect(config.validate(previous: nil, host: macBook16).contains { $0.field == "fpsLimit" }, "\(fps)")
        }
        // A screen's own rate (75 or 100 Hz) as well as the fixed choices.
        for fps in VMConfig.fpsChoices + [75, 100, 61, 119] {
            config.fpsLimit = fps
            #expect(!config.validate(previous: nil, host: macBook16).contains { $0.field == "fpsLimit" }, "\(fps)")
        }
    }

    @Test func coresBeyondPerformanceCoresWarn() {
        var config = VMConfig()
        config.cpuCount = 6
        let issues = config.validate(previous: nil, host: macBook16)
        #expect(issues.contains { $0.field == "cpuCount" && $0.severity == .warning })
        config.cpuCount = 9
        #expect(config.validate(previous: nil, host: macBook16).contains { $0.field == "cpuCount" && $0.severity == .error })
    }

    @Test func heavyGamePreset() {
        var config = VMConfig(memoryMiB: 4096)
        config.applyHeavyGamePreset(host: macStudio64)
        #expect(config.renderer == .vulkan)
        #expect(config.rendererMode == .gpu)
        #expect(config.fpsLimit == 60)
        #expect(config.memoryMiB == 8192)
        #expect(config.gameGraphics == .gamesDefault)
        // The preset sets the shape and filter, and keeps what the user chose
        // for interface size and sharpness.
        var tuned = VMConfig()
        tuned.gameGraphics = GraphicsSettings(mode: .deviceProfile, renderScale: 50, shortSide: 1080, aspectRatio: .ratio4x3,
                                              followAspectRatio: .ratio16x10, orientation: .portrait,
                                              interfaceScale: 115, filter: .nearest, sharpness: 20)
        tuned.applyHeavyGamePreset(host: macStudio64)
        #expect(tuned.gameGraphics == GraphicsSettings(mode: .fixed, renderScale: 50, shortSide: 720, aspectRatio: .ratio16x9,
                                                       followAspectRatio: .ratio16x10, orientation: .portrait,
                                                       interfaceScale: 115, filter: .metalFXSpatial, sharpness: 20))

        // A cap above 60 stays; one below goes up to 60.
        var fast = VMConfig()
        fast.fpsLimit = 120
        fast.applyHeavyGamePreset(host: macStudio64)
        #expect(fast.fpsLimit == 120)
        fast.fpsLimit = 30
        fast.applyHeavyGamePreset(host: macStudio64)
        #expect(fast.fpsLimit == 60)

        // A Mac that cannot spare 8 GB keeps its memory and gets a warning instead.
        var small = VMConfig(memoryMiB: 4096)
        small.applyHeavyGamePreset(host: macMini8)
        #expect(small.memoryMiB == 4096)
        #expect(small.validate(previous: nil, host: macMini8).contains { $0.severity == .warning && $0.field == "memoryMiB" })
    }

    // Spec §6: which tabs need a restart.
    @Test func restartRulesFollowTheSpecTable() {
        let base = VMConfig()
        func effect(_ change: (inout VMConfig) -> Void) -> ConfigChangeEffect {
            var updated = base
            change(&updated)
            return updated.effect(of: base)
        }
        #expect(effect { $0.memoryMiB = 6144 } == .restartRequired)          // Performa
        #expect(effect { $0.cpuCount = 2 } == .restartRequired)
        #expect(effect { $0.balloonWhenIdle.toggle() } == .restartRequired)
        #expect(effect { $0.dataDiskGiB = 64 } == .restartRequired)          // Storage (resize)
        #expect(effect { $0.renderer = .gles } == .restartRequired)          // Grafis: partly
        #expect(effect { $0.rendererMode = .software } == .restartRequired)
        #expect(effect { $0.fpsLimit = 30 } == .immediate)
        // Graphics: open windows re-plug their displays, no restart.
        #expect(effect { $0.appGraphics.interfaceScale = 115 } == .immediate)
        #expect(effect { $0.appGraphics.renderScale = 50 } == .immediate)
        #expect(effect { $0.gameGraphics.shortSide = 1080 } == .immediate)
        #expect(effect { $0.graphicsOverrides["com.x"] = AppGraphicsOverride(profile: .games) } == .immediate)
        #expect(effect { $0.performanceHUD = .fps } == .immediate)
        #expect(effect { $0.appGraphics.orientation = .landscape } == .immediate)
        #expect(effect { $0.defaultWindowSize = .init(width: 500, height: 900) } == .newWindows) // App windows: no restart
        #expect(effect { $0.appBarStyle = .phone } == .immediate) // open windows change their looks
        #expect(effect { $0.rooted = true } == .restartRequired)             // Sistem
        #expect(effect { $0.deviceProfileID = "xiaomi-14" } == .restartRequired)
        #expect(effect { $0.createDesktopAlias.toggle() } == .immediate)
        #expect(base.effect(of: base) == .immediate)
        #expect(effect { $0.fpsLimit = 30; $0.cpuCount = 2 } == .restartRequired)
    }

    @Test func persistsAsJSON() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "avo-config-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var config = VMConfig()
        config.gms = .microG
        config.appGraphics.interfaceScale = 115
        config.graphicsOverrides["com.x"] = AppGraphicsOverride(changes: GraphicsSettingsPatch.difference(.gamesDefault, from: .appsDefault))
        try config.save(to: url)
        #expect(try VMConfig.load(from: url) == config)
    }
}

@Suite struct IdentifierTests {
    @Test func shimBundleIdentifiersAreValid() {
        #expect(AvoIdentifiers.shimBundleIdentifier(for: "com.example.app") == "com.avodroid.shim.com.example.app")
        #expect(AvoIdentifiers.shimBundleIdentifier(for: "org.my_app.free") == "com.avodroid.shim.org.my-app.free")
        #expect(AvoIdentifiers.package(fromShimBundleIdentifier: "com.avodroid.shim.com.example") == "com.example")
        // A shim made before com.avodroid still names its package.
        #expect(AvoIdentifiers.package(fromShimBundleIdentifier: "dev.avo.shim.com.example") == "com.example")
        #expect(AvoIdentifiers.package(fromShimBundleIdentifier: "com.other") == nil)
    }

    @Test func everyHelperIsUnderAvosDomain() {
        for identifier in [AvoIdentifiers.windowHost, AvoIdentifiers.daemonLabel, AvoIdentifiers.daemonMachService,
                           AvoIdentifiers.daemonBundleID, AvoIdentifiers.shimPrefix, AvoIdentifiers.logSubsystem] {
            #expect(identifier.hasPrefix("com.avodroid"), "\(identifier)")
        }
        #expect(AvoIdentifiers.app == "com.avodroid.emulator")
        #expect(AvoIdentifiers.formerDaemonMachService == "dev.avo.daemon")
    }

    @Test func formerPreferencesMoveToTheirNewDomains() {
        let files = ["dev.avo.daemon.plist", "dev.avo.WindowHost.plist", "dev.avo.shim.com.dts.freefiremax.plist",
                     "dev.avo.shim.org.my-app.free.plist", "dev.avo.hub.plist", "dev.avo.hub.agent.plist",
                     "dev.avo.shim..plist", "com.avodroid.emulator.plist", "dev.avo.shim.com.example.app.plist.lockfile"]
        let pairs = AvoIdentifiers.formerPreferenceDomains(preferenceFiles: files).map { "\($0.from) > \($0.to)" }
        #expect(pairs == [
            "dev.avo.daemon > com.avodroid.daemon",
            "dev.avo.WindowHost > com.avodroid.WindowHost",
            "dev.avo.avoctl > com.avodroid.avoctl",
            "dev.avo.shim.com.dts.freefiremax > com.avodroid.shim.com.dts.freefiremax",
            "dev.avo.shim.org.my-app.free > com.avodroid.shim.org.my-app.free",
        ], "Avo Hub's dev.avo.hub domains are not Avo's to move")
    }

    @Test func prefixMatchesXcodeConfiguration() throws {
        // host/Config/Base.xcconfig must agree with AvoIdentifiers.prefix.
        let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../")
        let xcconfig = root.appending(path: "Config/Base.xcconfig").standardizedFileURL
        guard let text = try? String(contentsOf: xcconfig, encoding: .utf8) else {
            Issue.record("missing \(xcconfig.path)")
            return
        }
        #expect(text.contains("AVO_BUNDLE_ID_PREFIX = \(AvoIdentifiers.prefix)\n"))
        #expect(text.contains("AVO_APP_BUNDLE_ID = \(AvoIdentifiers.app)\n"))
    }

    @Test func pathsUseShortRuntimeDirectory() throws {
        let paths = AvoPaths(home: URL(filePath: "/Users/someone-with-a-long-name"),
                             temporaryDirectory: URL(filePath: "/var/folders/ab/cdefghijklmnopqrstuvwxyz0000gn/T"))
        #expect(paths.shims.path == "/Users/someone-with-a-long-name/Applications/Android Apps")
        #expect(paths.vsockSocket.path.hasSuffix("/T/com.avodroid/vsock.sock"))
        try paths.validateSocketPaths()
    }

    @Test func olderFilesKeepTheirSettings() throws {
        // Saved before ADB support existed: the new keys take their defaults.
        let old = #"{"memoryMiB": 6144, "cpuCount": 6, "balloonWhenIdle": false, "dataDiskGiB": 64, "renderer": "gles", "fpsLimit": 120, "defaultWindowSize": {"width": 500, "height": 900}, "defaultOrientation": "portrait", "retinaScaling": true, "rooted": true, "deviceProfileID": "pixel-8", "gms": "microG", "createDesktopAlias": false, "addToDock": true}"#
        let config = try JSONDecoder().decode(VMConfig.self, from: Data(old.utf8))
        #expect(config.memoryMiB == 6144)
        // 120 FPS from an older Avo stays (Android runs at it where a screen shows it).
        #expect(config.fpsLimit == 120)
        #expect(config.gms == .microG)
        #expect(config.rooted)
        #expect(!config.createDesktopAlias)
        #expect(!config.adbEnabled)
        #expect(config.adbPort == VMConfig.defaultADBPort)
    }

    @Test func graphicsErrorsNameTheirField() {
        func errors(_ change: (inout VMConfig) -> Void) -> [String] {
            var config = VMConfig()
            change(&config)
            return config.validate(previous: nil, host: macBook16).filter { $0.severity == .error }.map(\.field)
        }
        #expect(errors { $0.appGraphics.renderScale = 49 } == ["appGraphics.renderScale"])
        #expect(errors { $0.appGraphics.renderScale = 101 } == ["appGraphics.renderScale"])
        #expect(errors { $0.gameGraphics.shortSide = 359 } == ["gameGraphics.shortSide"])
        #expect(errors { $0.gameGraphics.shortSide = 2161 } == ["gameGraphics.shortSide"])
        #expect(errors { $0.gameGraphics.shortSide = 2160 }.isEmpty)
        #expect(errors { $0.gameGraphics.shortSide = 721 } == ["gameGraphics.shortSide"])
        #expect(errors { $0.appGraphics.interfaceScale = 74 } == ["appGraphics.interfaceScale"])
        #expect(errors { $0.appGraphics.sharpness = 101 } == ["appGraphics.sharpness"])
        var patch = GraphicsSettingsPatch()
        patch.shortSide = 721
        #expect(errors { $0.graphicsOverrides["com.x"] = AppGraphicsOverride(changes: patch) } == ["graphicsOverrides.com.x.shortSide"])
        // An override checks only the fields it changes.
        #expect(errors { $0.graphicsOverrides["com.x"] = AppGraphicsOverride(profile: .games) }.isEmpty)
    }

    @Test func adbPortIsChecked() {
        var config = VMConfig()
        config.adbEnabled = true
        config.adbPort = 80
        #expect(config.validate(previous: nil, host: macBook16).contains { $0.field == "adbPort" && $0.severity == .error })
        config.adbPort = 5557
        #expect(!config.validate(previous: nil, host: macBook16).contains { $0.field == "adbPort" })
        #expect(config.effect(of: VMConfig()) == .immediate)
    }

    // MARK: Renderer

    /// The standard title bar unless the user chose another, also in a file
    /// from before the setting or with a style a newer Avo added.
    @Test func appBarStyleDefaultsToStandard() throws {
        #expect(VMConfig().appBarStyle == .standard)
        let old = try JSONDecoder().decode(VMConfig.self, from: Data(#"{"memoryMiB": 6144}"#.utf8))
        #expect(old.appBarStyle == .standard)
        let newer = try JSONDecoder().decode(VMConfig.self, from: Data(#"{"appBarStyle": "floating"}"#.utf8))
        #expect(newer.appBarStyle == .standard)
        var phone = VMConfig()
        phone.appBarStyle = .phone
        #expect(try JSONDecoder().decode(VMConfig.self, from: JSONEncoder().encode(phone)).appBarStyle == .phone)
    }

    @Test func rendererModeDefaultsToAutomatic() throws {
        #expect(VMConfig().rendererMode == .auto)
        // A file from before the setting, with only the crosvm key.
        let old = try JSONDecoder().decode(VMConfig.self, from: Data(#"{"renderer": "vulkan", "memoryMiB": 6144}"#.utf8))
        #expect(old.rendererMode == .auto)
        #expect(old.memoryMiB == 6144)
        // A newer Avo's value drops only this setting, never the file.
        let newer = try JSONDecoder().decode(VMConfig.self, from: Data(#"{"rendererMode": "bogus", "renderer": "metal", "cpuCount": 3}"#.utf8))
        #expect(newer.rendererMode == .auto)
        #expect(newer.renderer == .vulkan)
        #expect(newer.cpuCount == 3)
    }

    @Test func rendererModeRoundTripsAndKeepsTheLegacyKey() throws {
        var config = VMConfig()
        config.rendererMode = .software
        let data = try JSONEncoder().encode(config)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["rendererMode"] as? String == "software")
        #expect(object["renderer"] as? String == "vulkan")
        #expect(try JSONDecoder().decode(VMConfig.self, from: data).rendererMode == .software)
    }

    @Test func heavyGameWarningFollowsTheRendererMode() {
        var config = VMConfig(memoryMiB: 4096, rendererMode: .gpu)
        #expect(config.validate(previous: nil, host: macBook16).contains { $0.field == "memoryMiB" && $0.severity == .warning })
        config.rendererMode = .software
        #expect(!config.validate(previous: nil, host: macBook16).contains { $0.field == "memoryMiB" })
        config.rendererMode = .auto
        #expect(!config.validate(previous: nil, host: macBook16).contains { $0.field == "memoryMiB" })
        config.rendererMode = .gpu
        config.memoryMiB = 8192
        #expect(!config.validate(previous: nil, host: macBook16).contains { $0.field == "memoryMiB" })
    }

    // MARK: Frame rate cap

    /// Android's displays run at any whole rate from 60 to 120 Hz (the
    /// fixed choices, or a screen's own 75 Hz); 30 is half of 60. A cap
    /// under 60 loads as 30, one above 120 as 120.
    @Test func frameRateCapsAndroidCanRun() throws {
        #expect(VMConfig.fpsChoices == [30, 60, 90, 120])
        #expect(VMConfig().fpsLimit == 60, "60 Hz stays the default")
        #expect(VMConfig.supportedFPS(144) == 120)
        #expect(VMConfig.supportedFPS(119) == 119)
        #expect(VMConfig.supportedFPS(75) == 75)
        #expect(VMConfig.supportedFPS(59) == 30)
        #expect(VMConfig.supportedFPS(20) == 30)
        for (saved, loaded) in [(120, 120), (90, 90), (75, 75), (100, 100), (144, 120), (45, 30), (30, 30), (60, 60)] {
            let config = try JSONDecoder().decode(VMConfig.self, from: Data(#"{"fpsLimit": \#(saved)}"#.utf8))
            #expect(config.fpsLimit == loaded)
            #expect(!config.validate(previous: nil, host: macBook16).contains { $0.field == "fpsLimit" })
        }
    }

    /// Pause When Idle: 15 minutes for files from before it; a time this Avo
    /// does not offer becomes the nearest one; it applies at once.
    @Test func pauseWhenIdleChoices() throws {
        #expect(VMConfig().autoPauseMinutes == 15)
        let old = try JSONDecoder().decode(VMConfig.self, from: Data(#"{"memoryMiB": 6144}"#.utf8))
        #expect(old.autoPauseMinutes == 15)
        for (saved, loaded) in [(0, 0), (-3, 0), (1, 5), (10, 5), (12, 15), (60, 30), (30, 30)] {
            let config = try JSONDecoder().decode(VMConfig.self, from: Data(#"{"autoPauseMinutes": \#(saved)}"#.utf8))
            #expect(config.autoPauseMinutes == loaded, "\(saved)")
        }
        var config = VMConfig()
        config.autoPauseMinutes = 7
        #expect(config.validate(previous: nil, host: macBook16).contains { $0.field == "autoPauseMinutes" && $0.severity == .error })
        config.autoPauseMinutes = 0
        #expect(config.validate(previous: nil, host: macBook16).isEmpty)
        #expect(config.effect(of: VMConfig()) == .immediate)
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(VMConfig.self, from: data).autoPauseMinutes == 0)
    }
}
