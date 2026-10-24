import AppKit
import AvoKeymap
import QuartzCore
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

/// W held walks (a hold, so its touch stays down while the key does).
private let walk = KeymapProfile(package: "com.example.game", name: "Walk",
                                 controls: [Control(id: "walk", kind: .hold(NormalizedPoint(0.25, 0.75)), triggers: [.key(.w)])])

/// The keyboard and the mouse as a test says they are.
@MainActor
private final class FakeHardware {
    var keysDown: Set<UInt16> = []
    var buttons = 0

    var hardware: KeymapController.Hardware {
        KeymapController.Hardware(isKeyDown: { [unowned self] in keysDown.contains($0) }, mouseButtons: { [unowned self] in buttons })
    }
}

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

    @Test("A key the keyboard let go whose keyUp never came is released, and its late keyUp goes nowhere")
    func keyLetGoUnseenIsReleased() async throws {
        let host = Host(gameMode: true, bundled: walk)
        let keymap = host.controller()
        defer { keymap.stop() }
        let fake = FakeHardware()
        keymap.hardware = fake.hardware
        let w = try #require(KeyboardMapping.macKeyCode(for: .w))
        fake.keysDown = [w]
        #expect(keymap.key(.w, down: true, isRepeat: false))
        #expect(host.touches == ["7 down 0@600,810"])
        // Past a tap's 40 ms, the key comes up without its keyUp (a system gesture took it).
        try await Task.sleep(for: .milliseconds(60))
        fake.keysDown = []
        keymap.releaseUnseen(at: CACurrentMediaTime() + 1)
        #expect(host.touches == ["7 down 0@600,810", "7 up 0@600,810"])
        // When the keyUp does come after all, it changes nothing and reaches nothing.
        #expect(keymap.key(.w, down: false, isRepeat: false))
        #expect(host.touches.count == 2)
    }

    @Test("A press the keyboard never showed down is left to its own release")
    func unseenPressIsLeftAlone() async throws {
        let host = Host(gameMode: true, bundled: walk)
        let keymap = host.controller()
        defer { keymap.stop() }
        let fake = FakeHardware()
        keymap.hardware = fake.hardware
        // The keyboard's state reads nothing down (no access to it, a key it doesn't see).
        #expect(keymap.key(.w, down: true, isRepeat: false))
        try await Task.sleep(for: .milliseconds(60))
        keymap.releaseUnseen(at: CACurrentMediaTime() + 1)
        #expect(host.touches == ["7 down 0@600,810"])
        #expect(keymap.key(.w, down: false, isRepeat: false))
        #expect(host.touches == ["7 down 0@600,810", "7 up 0@600,810"])
    }

    @Test("A click's finger whose button came up without a mouseUp is lifted")
    func clickLetGoUnseenIsLifted() async throws {
        let host = Host(gameMode: true, bundled: walk)
        let keymap = host.controller()
        defer { keymap.stop() }
        let fake = FakeHardware()
        keymap.hardware = fake.hardware
        // A click lands where the cursor is in the view's window.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: host.view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host.view
        defer { window.contentView = nil }
        fake.buttons = 1
        #expect(keymap.mouse(.left, down: true))
        #expect(host.touches.count == 1)
        fake.buttons = 0
        keymap.releaseUnseen(at: CACurrentMediaTime() + 1)
        #expect(host.touches.count == 2)
        #expect(host.touches.last?.hasPrefix("7 up") == true)
        #expect(keymap.mouse(.left, down: false))
        #expect(host.touches.count == 2)
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
