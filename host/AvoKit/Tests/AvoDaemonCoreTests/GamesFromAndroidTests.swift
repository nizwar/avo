import AvoKit
import AvoProtocol
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// Android says which apps are games (their manifest's category): their
/// windows use the Games profile without a key mapping.
@Suite(.serialized, .timeLimit(.minutes(1))) struct GamesFromAndroidTests {
    /// The helper's `appinfo` (guest/clipboard AppInfo.java), as Android 17 printed it.
    @Test func theHelperSaysWhichAppsAreGames() throws {
        let reports = HostAgent.parseAppInfo("""
            {"package":"com.nekki.shadowfight3","label":"Shadow Fight 3","system":false,"game":true,"orientation":"landscape"}
            {"package":"com.king.candycrushsaga","label":"Candy Crush Saga","system":false,"game":true,"orientation":"portrait"}
            {"package":"com.android.chrome","label":"Chrome","system":false,"game":false}
            {"package":"com.example.old","label":"Old Helper"}
            """)
        func info(_ package: String) throws -> Avo_V1_AppInfo {
            var info = Avo_V1_AppInfo()
            info.package = package
            HostAgent.fill(&info, from: try #require(reports[package]))
            return info
        }
        #expect(try info("com.nekki.shadowfight3").hasGame)
        #expect(try info("com.nekki.shadowfight3").game)
        #expect(try info("com.nekki.shadowfight3").orientation == .landscape)
        #expect(try info("com.king.candycrushsaga").orientation == .portrait)
        #expect(try info("com.android.chrome").orientation == .unspecified)
        #expect(try info("com.android.chrome").hasGame)
        #expect(try !info("com.android.chrome").game)
        // An older helper does not say: nothing is known.
        #expect(try !info("com.example.old").hasGame)
    }

    /// Only Android's answer changes what is known: an APK read on the Mac or
    /// a bare listing (no `game`) keeps it.
    @Test func theRegistryKeepsWhatAndroidSaid() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "avo-games-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AppRegistry(paths: AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp")))
        var info = Avo_V1_AppInfo()
        info.package = "com.nekki.shadowfight3"
        info.label = "Shadow Fight 3"
        #expect(await registry.apply(info).record.isGame == nil)
        info.game = true
        info.orientation = .landscape
        #expect(await registry.apply(info).record.isGame == true)
        #expect(await registry.apply(info).record.orientation == .landscape)
        info.clearGame()
        info.orientation = .unspecified
        #expect(await registry.apply(info).record.isGame == true)
        #expect(await registry.apply(info).record.orientation == .landscape)
        info.game = false
        #expect(await registry.apply(info).record.isGame == false)
        #expect(await registry.apply(info).record.orientation == nil)
    }

    /// App Shims learn which apps are games from the configuration snapshot.
    @Test func appShimsHearWhichAppsAreGames() async throws {
        var game = FakeBridgeAgent.app("com.nekki.shadowfight3", label: "Shadow Fight 3")
        game.game = true
        game.orientation = .landscape
        var portrait = FakeBridgeAgent.app("com.king.candycrushsaga", label: "Candy Crush Saga")
        portrait.game = true
        portrait.orientation = .portrait
        let app = FakeBridgeAgent.app("com.android.chrome", label: "Chrome")
        let harness = try Harness(apps: [game, portrait, app])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        #expect(await harness.waitForShims(3))
        let snapshot = await harness.core.configurationSnapshot()
        #expect(snapshot.games == ["com.nekki.shadowfight3", "com.king.candycrushsaga"])
        #expect(snapshot.gameOrientations == ["com.nekki.shadowfight3": .landscape, "com.king.candycrushsaga": .portrait])
        #expect(await harness.core.apps().first { $0.package == "com.nekki.shadowfight3" }?.isGame == true)
    }
}
