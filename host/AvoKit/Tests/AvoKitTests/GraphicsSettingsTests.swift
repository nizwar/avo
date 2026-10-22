import Foundation
import Testing
@testable import AvoKit

private func decode(_ json: String) throws -> VMConfig {
    try JSONDecoder().decode(VMConfig.self, from: Data(json.utf8))
}

@Suite struct GraphicsSettingsTests {
    @Test func defaults() {
        let config = VMConfig()
        #expect(config.appGraphics == .appsDefault)
        #expect(config.gameGraphics == .gamesDefault)
        #expect(config.graphicsOverrides.isEmpty)
        #expect(config.performanceHUD == .off)
        #expect(GraphicsSettings.appsDefault.mode == .followWindow && GraphicsSettings.appsDefault.renderScale == 100)
        #expect(GraphicsSettings.gamesDefault.mode == .fixed)
        #expect(GraphicsSettings.gamesDefault.shortSide == 720 && GraphicsSettings.gamesDefault.aspectRatio == .ratio16x9)
        #expect((GraphicsSettings.appsDefault.orientation, GraphicsSettings.gamesDefault.orientation) == (.portrait, .landscape))
        #expect(GraphicsSettings.appsDefault.followAspectRatio == .matchWindow && GraphicsSettings.gamesDefault.followAspectRatio == .matchWindow)
        #expect(GraphicsSettings.appsDefault.validate(field: "x").isEmpty && GraphicsSettings.gamesDefault.validate(field: "x").isEmpty)
    }

    @Test func migratesRetinaAndDensity() throws {
        #expect(try decode(#"{"retinaScaling": false}"#).appGraphics.renderScale == 50)
        #expect(try decode(#"{"retinaScaling": true}"#).appGraphics == .appsDefault)
        #expect(try decode(#"{"defaultDPI": 280}"#).appGraphics.interfaceScale == 88)
        // 320 dpi at 1x was twice the default layout; clamped to the largest size.
        let clamped = try decode(#"{"retinaScaling": false, "defaultDPI": 320}"#).appGraphics
        #expect((clamped.renderScale, clamped.interfaceScale) == (50, 150))
        #expect(try decode("{}") == VMConfig())
        // Saved graphics win over legacy keys.
        #expect(try decode(#"{"retinaScaling": false, "appGraphics": {"renderScale": 77}}"#).appGraphics.renderScale == 77)
    }

    @Test func partialProfilesKeepTheirOwnDefaults() throws {
        let config = try decode(#"{"gameGraphics": {"shortSide": 1080}, "appGraphics": {"sharpness": 20}}"#)
        var games = GraphicsSettings.gamesDefault
        games.shortSide = 1080
        #expect(config.gameGraphics == games)
        var apps = GraphicsSettings.appsDefault
        apps.sharpness = 20
        #expect(config.appGraphics == apps)
    }

    @Test func unknownValuesAreDropped() throws {
        let config = try decode(#"""
        {"appGraphics": {"filter": "temporal", "aspectRatio": "21:9", "renderScale": "lots", "sharpness": 10},
         "performanceHUD": "graph",
         "graphicsOverrides": {
            "com.good": {"profile": "games", "changes": {"shortSide": 900}},
            "com.newer": {"profile": "consoles", "changes": {"filter": "nearest"}},
            "com.empty": {"profile": "consoles"},
            "com.broken": 7
         }}
        """#)
        var apps = GraphicsSettings.appsDefault
        apps.sharpness = 10
        #expect(config.appGraphics == apps)
        #expect(config.performanceHUD == .off)
        #expect(config.graphicsOverrides.keys.sorted() == ["com.good", "com.newer"])
        #expect(config.graphicsOverrides["com.good"]?.profile == .games)
        #expect(config.graphicsOverrides["com.good"]?.changes.shortSide == 900)
        #expect(config.graphicsOverrides["com.newer"]?.profile == nil)
        #expect(config.graphicsOverrides["com.newer"]?.changes.filter == .nearest)
    }

    @Test func patchesRoundTrip() {
        var custom = GraphicsSettings.gamesDefault
        custom.shortSide = 1080
        custom.filter = .nearest
        let patch = GraphicsSettingsPatch.difference(custom, from: .gamesDefault)
        #expect(patch.count == 2)
        #expect(!patch.isEmpty)
        #expect(patch.applied(to: .gamesDefault) == custom)
        #expect(GraphicsSettingsPatch.difference(.appsDefault, from: .appsDefault).isEmpty)
        #expect(AppGraphicsOverride().isEmpty)
        #expect(!AppGraphicsOverride(profile: .apps).isEmpty)
    }

    @Test func antiAliasingIsSavedAndRead() throws {
        #expect(GraphicsSettings.appsDefault.antiAliasing == .off)
        var custom = GraphicsSettings.gamesDefault
        custom.antiAliasing = .ssaa2x
        let patch = GraphicsSettingsPatch.difference(custom, from: .gamesDefault)
        #expect(patch.count == 1)
        let data = try JSONEncoder().encode(patch)
        #expect(String(decoding: data, as: UTF8.self) == #"{"antiAliasing":"ssaa2x"}"#)
        #expect(try JSONDecoder().decode(GraphicsSettingsPatch.self, from: data).applied(to: .gamesDefault) == custom)
        // A value from a newer Avo is dropped, the rest kept.
        let newer = try JSONDecoder().decode(GraphicsSettingsPatch.self, from: Data(#"{"antiAliasing":"taa","sharpness":20}"#.utf8))
        #expect(newer.antiAliasing == nil && newer.sharpness == 20)
    }

    @Test func overridesFollowLaterProfileEdits() {
        var config = VMConfig()
        var patch = GraphicsSettingsPatch()
        patch.shortSide = 1080
        config.graphicsOverrides["com.x"] = AppGraphicsOverride(changes: patch)
        config.gameGraphics.aspectRatio = .ratio16x10
        let resolved = config.graphics(for: "com.x", hasKeyMapping: true).settings
        #expect(resolved.shortSide == 1080)
        #expect(resolved.aspectRatio == .ratio16x10)
    }

    @Test func encodesWithoutLegacyKeys() throws {
        var config = VMConfig()
        config.appGraphics.interfaceScale = 115
        config.gameGraphics.sharpness = 20
        config.performanceHUD = .detailed
        var patch = GraphicsSettingsPatch()
        patch.aspectRatio = .ratio4x3
        config.graphicsOverrides["com.x"] = AppGraphicsOverride(profile: .games, changes: patch)
        let data = try JSONEncoder().encode(config)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("defaultDPI"))
        #expect(!text.contains("retinaScaling"))
        #expect(try JSONDecoder().decode(VMConfig.self, from: data) == config)
    }

    /// Files from before the phone's screen and the follow mode's ratio
    /// decode to exactly what they did.
    @Test func olderGraphicsDecodeAsBefore() throws {
        let config = try decode(#"""
        {"appGraphics": {"followsWindow": false, "renderScale": 100, "shortSide": 900, "aspectRatio": "matchWindow",
                         "interfaceScale": 100, "filter": "bilinear", "sharpness": 0},
         "gameGraphics": {"followsWindow": true, "renderScale": 67, "shortSide": 720, "aspectRatio": "16:10",
                          "interfaceScale": 115, "filter": "metalFXSpatial", "sharpness": 10},
         "graphicsOverrides": {"com.x": {"changes": {"followsWindow": true}}, "com.y": {"changes": {"followsWindow": false}}}}
        """#)
        #expect(config.appGraphics == GraphicsSettings(mode: .fixed, renderScale: 100, shortSide: 900, aspectRatio: .matchWindow,
                                                       orientation: .portrait, interfaceScale: 100, filter: .bilinear, sharpness: 0))
        // Following the window with 16:10 kept for fixed mode: the window stays free.
        #expect(config.gameGraphics == GraphicsSettings(mode: .followWindow, renderScale: 67, shortSide: 720, aspectRatio: .ratio16x10,
                                                        followAspectRatio: .matchWindow, orientation: .landscape,
                                                        interfaceScale: 115, filter: .metalFXSpatial, sharpness: 10))
        #expect(config.gameGraphics.lockedRatio(device: nil) == nil)
        #expect(config.graphicsOverrides["com.x"]?.changes.mode == .followWindow)
        #expect(config.graphicsOverrides["com.y"]?.changes.mode == .fixed)
        #expect(config.graphicsOverrides["com.x"]?.changes.count == 1)
    }

    @Test func modeWinsOverTheOldFlag() throws {
        let config = try decode(#"""
        {"appGraphics": {"mode": "deviceProfile", "followsWindow": true},
         "gameGraphics": {"mode": "hologram", "followsWindow": true},
         "graphicsOverrides": {"com.x": {"changes": {"mode": "hologram", "sharpness": 5}}}}
        """#)
        #expect(config.appGraphics.mode == .deviceProfile)
        // A newer Avo's mode: the old flag if there is one, else the profile's.
        #expect(config.gameGraphics.mode == .followWindow)
        #expect(config.graphicsOverrides["com.x"]?.changes.mode == nil)
        #expect(config.graphicsOverrides["com.x"]?.changes.sharpness == 5)
    }

    @Test func orientationMigratesFromDisplay() throws {
        let landscape = try decode(#"{"defaultOrientation": "landscape"}"#)
        #expect(landscape.appGraphics.orientation == .landscape)
        #expect(landscape.gameGraphics.orientation == .landscape)
        #expect(try decode(#"{"defaultOrientation": "landscape", "appGraphics": {"renderScale": 77}}"#).appGraphics.orientation == .landscape)
        #expect(try decode(#"{"defaultOrientation": "landscape", "appGraphics": {"orientation": "portrait"}}"#).appGraphics.orientation == .portrait)
        #expect(try decode(#"{"defaultOrientation": "sideways"}"#).appGraphics.orientation == .portrait)
        // Games were always previewed and started in landscape.
        #expect(try decode(#"{"defaultOrientation": "portrait", "gameGraphics": {"shortSide": 900}}"#).gameGraphics.orientation == .landscape)
        // Saved again, the orientation is the profile's alone.
        let text = try #require(String(data: JSONEncoder().encode(landscape), encoding: .utf8))
        #expect(!text.contains("defaultOrientation"))
        #expect(try decode(text) == landscape)
    }

    @Test func encodesTheModeNotTheOldFlag() throws {
        var config = VMConfig()
        config.appGraphics.mode = .deviceProfile
        config.gameGraphics.followAspectRatio = .ratio20x9
        var patch = GraphicsSettingsPatch()
        patch.mode = .followWindow
        patch.orientation = .portrait
        config.graphicsOverrides["com.x"] = AppGraphicsOverride(changes: patch)
        let data = try JSONEncoder().encode(config)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let apps = try #require(object["appGraphics"] as? [String: Any])
        #expect(apps["mode"] as? String == "deviceProfile")
        #expect(apps["orientation"] as? String == "portrait")
        #expect(apps["followsWindow"] == nil)
        #expect((object["gameGraphics"] as? [String: Any])?["followAspectRatio"] as? String == "20:9")
        let changes = (object["graphicsOverrides"] as? [String: Any]).flatMap { ($0["com.x"] as? [String: Any])?["changes"] as? [String: Any] }
        #expect(changes?.keys.sorted() == ["mode", "orientation"])
        #expect(try JSONDecoder().decode(VMConfig.self, from: data) == config)
    }

    @Test func patchesCarryTheNewFields() {
        var custom = GraphicsSettings.appsDefault
        custom.mode = .deviceProfile
        custom.followAspectRatio = .ratio16x10
        custom.orientation = .landscape
        let patch = GraphicsSettingsPatch.difference(custom, from: .appsDefault)
        #expect(patch.count == 3)
        #expect((patch.mode, patch.followAspectRatio, patch.orientation) == (.deviceProfile, .ratio16x10, .landscape))
        #expect(patch.applied(to: .appsDefault) == custom)
        // Applied to Games, the rest follows the Games profile.
        let games = patch.applied(to: .gamesDefault)
        #expect((games.shortSide, games.aspectRatio, games.mode) == (720, .ratio16x9, .deviceProfile))
    }

    @Test func deviceDisplayComesFromTheChosenProfile() {
        let phone = DeviceProfile(id: "phone", name: "Phone", properties: [:], display: .init(width: 1080, height: 2400, dpi: 420))
        var config = VMConfig()
        #expect(config.deviceDisplay(in: [.avo, phone]) == nil)
        config.deviceProfileID = "phone"
        #expect(config.deviceDisplay(in: [.avo, phone]) == phone.display)
        #expect(config.deviceDisplay(in: []) == nil)
        #expect(abs(phone.display!.longOverShort - 2400.0 / 1080) < 1e-12)
    }

    @Test func fourKResolutions() {
        #expect(GraphicsSettings.shortSideRange == 360...2160)
        #expect(GraphicsSettings.resolutionPresets == [540, 720, 900, 1080, 1440, 2160])
        #expect(GraphicsSettings.resolutionName(2160) == "4K" && GraphicsSettings.resolutionName(1440) == "1440p")
        var settings = GraphicsSettings.gamesDefault
        settings.shortSide = 2160
        #expect(settings.validate(field: "x").isEmpty)
        settings.shortSide = 2162
        let issue = settings.validate(field: "x").first
        #expect(issue?.field == "x.shortSide")
        #expect(issue?.message.contains("2160") == true)
    }

    @Test func androidsOwnScreenIsWhatANewAppWindowGets() {
        var config = VMConfig()
        // The default window (412 × 892 points) on a Retina display, upright.
        #expect(config.androidScreen(device: nil, backingScale: 2) == DisplayRequest(width: 824, height: 1784, dpi: 320,
                                                                                     effectiveRenderScale: 100))
        config.appGraphics.interfaceScale = 115
        #expect(config.androidScreen(device: nil, backingScale: 2).dpi == 368)
        config.appGraphics.interfaceScale = 100
        // Upright even when the default window is wide; supersampling is for what is seen.
        config.defaultWindowSize = VMConfig.WindowSize(width: 892, height: 412)
        config.appGraphics.antiAliasing = .ssaa4x
        let screen = config.androidScreen(device: nil, backingScale: 2)
        #expect((screen.width, screen.height, screen.dpi) == (824, 1784, 320))
        // A fixed resolution: its short side.
        config.appGraphics.mode = .fixed
        config.appGraphics.shortSide = 1080
        #expect(config.androidScreen(device: nil, backingScale: 2).width == 1080)
    }

    @Test func androidsOwnScreenIsThePhonesWithItsHardware() {
        var config = VMConfig()
        let phone = DeviceProfile.Display(width: 2400, height: 1080, dpi: 395)
        // Without the hardware, the apps' resolution decides.
        #expect(config.androidScreen(device: phone, backingScale: 2).width == 824)
        config.emulateHardware = true
        #expect(config.androidScreen(device: phone, backingScale: 2) == DisplayRequest(width: 1080, height: 2400, dpi: 395))
        // The apps' "Phone's screen" resolution gives it too.
        config.emulateHardware = false
        config.appGraphics.mode = .deviceProfile
        let screen = config.androidScreen(device: phone, backingScale: 2)
        #expect((screen.width, screen.height, screen.dpi) == (1080, 2400, 395))
    }

    @Test func resolvesTheProfile() {
        var config = VMConfig()
        let plain = config.graphics(for: "com.x", hasKeyMapping: false)
        #expect((plain.profile, plain.reason, plain.settings) == (.apps, ResolvedGraphics.Reason.none, .appsDefault))
        let mapped = config.graphics(for: "com.x", hasKeyMapping: true)
        #expect((mapped.profile, mapped.reason, mapped.settings) == (.games, .keyMapping, .gamesDefault))
        config.graphicsOverrides["com.x"] = AppGraphicsOverride(profile: .apps)
        let chosen = config.graphics(for: "com.x", hasKeyMapping: true)
        #expect((chosen.profile, chosen.reason, chosen.settings) == (.apps, .chosen, .appsDefault))
        #expect(chosen.changes.isEmpty)
    }

    /// An app Android lists as a game gets the Games profile, after the
    /// user's choice and a key mapping.
    @Test func androidsGamesUseTheGamesProfile() {
        var config = VMConfig()
        let game = config.graphics(for: "com.x", hasKeyMapping: false, isGame: true)
        #expect((game.profile, game.reason, game.settings) == (.games, .androidGame, .gamesDefault))
        #expect(config.graphics(for: "com.x", hasKeyMapping: true, isGame: true).reason == .keyMapping)
        config.graphicsOverrides["com.x"] = AppGraphicsOverride(profile: .apps)
        let chosen = config.graphics(for: "com.x", hasKeyMapping: false, isGame: true)
        #expect((chosen.profile, chosen.reason) == (.apps, .chosen))
    }

    /// Such a game keeps the Games profile's performance settings but opens
    /// in the orientation it asks for; one that lets the screen turn takes
    /// the profile's, and the app's own changes still come last.
    @Test func androidsGamesKeepTheirOrientation() {
        var config = VMConfig()
        let portrait = config.graphics(for: "com.x", hasKeyMapping: false, isGame: true, orientation: .portrait)
        var expected = GraphicsSettings.gamesDefault
        expected.orientation = .portrait
        #expect((portrait.profile, portrait.reason, portrait.settings, portrait.base) == (.games, .androidGame, expected, expected))
        #expect(config.graphics(for: "com.x", hasKeyMapping: false, isGame: true).settings.orientation == .landscape)
        // A key mapping or the user's choice is not Android's word.
        #expect(config.graphics(for: "com.x", hasKeyMapping: true, isGame: true, orientation: .portrait).settings.orientation == .landscape)
        #expect(config.graphics(for: "com.x", hasKeyMapping: false, isGame: false, orientation: .landscape).settings.orientation == .portrait)
        config.graphicsOverrides["com.x"] = AppGraphicsOverride(changes: .difference(.gamesDefault, from: expected))
        #expect(config.graphics(for: "com.x", hasKeyMapping: false, isGame: true, orientation: .portrait).settings.orientation == .landscape)
    }
}
