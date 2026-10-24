import AppKit
import AvoKeymap
import AvoProtocol
import Foundation
import Testing
@testable import AvoKeymapUI

/// A game view whose picture fills it, Android's display 2400 x 1080.
@MainActor
private final class GameView: NSView, KeymapDisplay {
    var displayRect: CGRect { bounds }
    var displaySize = CGSize(width: 2400, height: 1080)
}

/// A window's store (KeymapStore) in a folder of its own, and what the
/// controller sent.
@MainActor
private final class Host {
    let directory = FileManager.default.temporaryDirectory.appending(path: "KeymapControllerTests-\(UUID().uuidString)")
    var gameMode: Bool
    var bundled: KeymapProfile?
    var sent: [InputRecord] = []
    let view = GameView(frame: NSRect(x: 0, y: 0, width: 600, height: 270))

    init(gameMode: Bool = false, bundled: KeymapProfile? = nil) {
        self.gameMode = gameMode
        self.bundled = bundled
    }

    var profileURL: URL { directory.appending(path: "com.example.game.json") }

    var store: KeymapStore {
        KeymapStore(profileURL: profileURL, bundledDirectory: nil,
                    usable: { [bundled, profileURL] in bundled.map { ($0, profileURL) } },
                    gameMode: { [unowned self] in gameMode },
                    setGameMode: { [unowned self] in gameMode = $0 })
    }

    func controller() -> KeymapController {
        KeymapController(package: "com.example.game", displayID: 7, view: view, store: store) { [unowned self] in sent.append($0) }
    }

    var touches: [String] {
        sent.compactMap { record in
            guard case .touch(let event) = record else { return nil }
            let pointers = event.pointers.map { "\($0.id)@\(Int($0.x.rounded())),\(Int($0.y.rounded()))" }.joined(separator: " ")
            return "\(event.displayID) \(event.action) \(pointers)"
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private let jump = KeymapProfile(package: "com.example.game", name: "Test",
                                 controls: [Control(id: "jump", kind: .tap(NormalizedPoint(0.5, 0.5)), triggers: [.key(.space)])])

@MainActor
@Suite("Key mapping over a window's own view and store")
struct KeymapControllerTests {
    @Test("The store gives the profile and Game Mode, and the keys become touches on the window's display")
    func storeGivesProfileAndGameMode() {
        let host = Host(gameMode: true, bundled: jump)
        let keymap = host.controller()
        defer { keymap.stop() }
        #expect(keymap.profile?.name == "Test")
        #expect(keymap.gameMode)
        #expect(keymap.key(.space, down: true, isRepeat: false))
        #expect(host.touches == ["7 down 0@1200,540"])
    }

    @Test("Game Mode is remembered by the store, and off the keys reach the app")
    func gameModeGoesToTheStore() {
        let host = Host(gameMode: true, bundled: jump)
        let keymap = host.controller()
        defer { keymap.stop() }
        var told: [Bool] = []
        keymap.onGameMode = { told.append($0) }
        keymap.setGameMode(false)
        #expect(!host.gameMode)
        #expect(told == [false])
        #expect(!keymap.key(.space, down: true, isRepeat: false))
        #expect(host.touches.isEmpty)
    }

    @Test("Saving writes the store's profile and turns Game Mode on")
    func savingWritesTheStoresProfile() throws {
        let host = Host()
        let keymap = host.controller()
        defer { keymap.stop() }
        #expect(keymap.profile == nil)
        try keymap.save(jump)
        let saved = try KeymapProfile.decode(Data(contentsOf: host.profileURL))
        #expect(saved.controls.map(\.id) == ["jump"])
        #expect(keymap.profile?.controls.map(\.id) == ["jump"])
        #expect(keymap.gameMode && host.gameMode)
    }

    @Test("Without a profile, Game Mode says how to set one up and maps nothing")
    func noProfileMapsNothing() {
        let host = Host()
        let keymap = host.controller()
        defer { keymap.stop() }
        var notices: [String] = []
        keymap.onNotice = { notices.append($0) }
        keymap.setGameMode(true)
        #expect(notices.count == 1)
        #expect(!keymap.key(.space, down: true, isRepeat: false))
        #expect(!keymap.takesGamepad)
    }
}
