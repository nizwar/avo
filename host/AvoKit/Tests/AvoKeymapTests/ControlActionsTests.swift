import AvoProtocol
import Foundation
import Testing
@testable import AvoKeymap

/// 2400 x 1080 landscape display.
private let W = 2400.0, H = 1080.0

private func engine(_ profile: KeymapProfile) -> KeymapEngine {
    KeymapEngine(profile: profile, displayID: 7, width: W, height: H)
}

private func summary(_ events: [TouchEvent]) -> [String] {
    events.map { event in
        let pointers = event.pointers.map { "\($0.id)@\(Int($0.x.rounded())),\(Int($0.y.rounded()))" }.joined(separator: " ")
        return "\(event.action)[\(event.actionIndex)] \(pointers)"
    }
}

private func eye(modes: [String]? = nil) -> Control {
    Control(id: "eye", kind: .aim(area: NormalizedRect(0.5, 0.1, 1, 0.7), sensitivity: AxisPair(x: 1, y: 1), adsSensitivity: AxisPair(x: 1, y: 1),
                                  exponent: 1, deadzone: 0, invertY: false, stick: nil), modes: modes)
}

private let combatAndBag = [KeymapMode(id: "combat", name: "Combat"), KeymapMode(id: "bag", name: "Inventory")]

/// A profile as Avo wrote it before actions: Switch Mode and Free/Lock the
/// Mouse controls of their own.
private func legacyJSON(_ controls: String, fps: Bool = true) -> Data {
    Data("""
    {"schema": 1, "package": "x", "name": "x",
     \(fps ? #""fps": {"aim_control": "eye", "cursor_toggle": "key:F8"},"# : "")
     "modes": [{"id": "foot", "name": "On foot"}, {"id": "vehicle", "name": "Vehicle"}],
     "controls": [
       {"type": "aim", "id": "eye", "area": [0.5, 0.1, 1, 0.7]},
       \(controls)
     ]}
    """.utf8)
}

@Suite struct ControlActionsTests {
    // MARK: Old layouts

    @Test func aSwitchOnItsButtonsKeyBecomesItsAction() throws {
        let profile = try KeymapProfile.decode(legacyJSON("""
            {"type": "switch_mode", "id": "to-vehicle", "mode": "vehicle", "position": [0.85, 0.6], "triggers": ["key:F"], "modes": ["foot"]},
            {"type": "tap", "id": "enter", "position": [0.8, 0.6], "triggers": ["key:F"], "modes": ["foot"]},
            {"type": "mouse_look", "id": "free", "lock": false, "position": [0.1, 0.1], "triggers": ["key:F"], "modes": ["foot"]}
            """))
        #expect(profile.validate().isEmpty)
        // The switch came before its button in the file: it still finds it.
        #expect(profile.controls.map(\.id) == ["eye", "enter"])
        #expect(profile.controls[1].actions == [.switchMode("vehicle"), .freeMouse])
        #expect(profile.controls[1].kind == .tap(NormalizedPoint(0.8, 0.6)))
    }

    @Test func aKeyThatOnlySwitchedBecomesAHotkey() throws {
        let profile = try KeymapProfile.decode(legacyJSON("""
            {"type": "tap", "id": "enter", "position": [0.8, 0.6], "triggers": ["key:F"], "modes": ["foot"]},
            {"type": "switch_mode", "id": "drive", "mode": "vehicle", "position": [0.85, 0.6], "triggers": ["key:V"], "modes": ["foot"]},
            {"type": "mouse_look", "id": "free", "lock": false, "position": [0.1, 0.1], "triggers": ["key:V"], "modes": ["foot"]},
            {"type": "switch_mode", "id": "walk", "mode": "foot", "position": [0.85, 0.6], "triggers": ["key:F"], "modes": ["vehicle"]}
            """))
        #expect(profile.validate().isEmpty)
        // V on foot: one hotkey with both actions. F in the vehicle: no
        // button of the game there, so a hotkey of its own (the tap acts on foot).
        #expect(profile.controls.map(\.id) == ["eye", "enter", "drive", "walk"])
        #expect(profile.controls[1].actions.isEmpty)
        #expect(profile.controls[2].kind == .hotkey)
        #expect(profile.controls[2].actions == [.switchMode("vehicle"), .freeMouse])
        #expect(profile.controls[3].kind == .hotkey)
        #expect(profile.controls[3].actions == [.switchMode("foot")])
    }

    @Test func onlyTheSameKeysAndModesMerge() throws {
        let profile = try KeymapProfile.decode(legacyJSON("""
            {"type": "tap", "id": "enter", "position": [0.8, 0.6], "triggers": ["key:F", "pad:y"], "modes": ["foot"]},
            {"type": "switch_mode", "id": "a", "mode": "vehicle", "triggers": ["key:F"], "modes": ["foot"]},
            {"type": "switch_mode", "id": "b", "mode": "vehicle", "triggers": ["pad:y", "key:F"]},
            {"type": "switch_mode", "id": "c", "mode": "vehicle", "triggers": ["pad:y", "key:F"], "modes": ["foot"]}
            """))
        // a misses Y (the button would switch with Y too), b acts in every
        // mode, c is the same in any order.
        #expect(profile.controls.map(\.id) == ["eye", "enter", "a", "b"])
        #expect(profile.controls[1].actions == [.switchMode("vehicle")])
    }

    @Test func aMergedLayoutSavesAndReadsTheSame() throws {
        let old = try KeymapProfile.decode(legacyJSON("""
            {"type": "tap", "id": "enter", "position": [0.8, 0.6], "triggers": ["key:F"], "modes": ["foot"]},
            {"type": "switch_mode", "id": "to-vehicle", "mode": "vehicle", "triggers": ["key:F"], "modes": ["foot"]},
            {"type": "mouse_look", "id": "lock", "lock": true, "triggers": ["key:L"]}
            """))
        let data = try old.encoded()
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("\"type\" : \"switch_mode\""))
        #expect(!json.contains("\"type\" : \"mouse_look\""))
        #expect(json.contains("\"type\" : \"hotkey\""))
        #expect(try KeymapProfile.decode(data) == old)
    }

    @Test func anActionFromANewerAvoIsLeftOut() throws {
        let profile = try KeymapProfile.decode(legacyJSON("""
            {"type": "tap", "id": "enter", "position": [0.8, 0.6], "triggers": ["key:F"],
             "actions": [{"teleport": true}, {"switch_mode": "vehicle"}, {"mouse": "sideways"}]}
            """))
        #expect(profile.controls[1].actions == [.switchMode("vehicle")])
    }

    // MARK: Pressing

    @Test func aTapThatSwitchesAndFreesTheMouse() {
        let profile = KeymapProfile(package: "x", name: "x", controls: [
            eye(),
            Control(id: "bag", kind: .tap(NormalizedPoint(0.1, 0.1)), triggers: [.key(.tab)], modes: ["combat"],
                    actions: [.switchMode("bag"), .freeMouse]),
            Control(id: "close", kind: .tap(NormalizedPoint(0.1, 0.1)), triggers: [.key(.tab)], modes: ["bag"],
                    actions: [.switchMode("combat"), .lockMouse]),
        ], fps: FPSSettings(aimControl: "eye"), modes: combatAndBag)
        #expect(profile.validate().isEmpty)
        var e = engine(profile)
        _ = e.setPointerLocked(true)
        // The game's button goes down first, in the mode it belongs to, then
        // the mode switches and the eye's finger lifts with the lock.
        let open = e.handle(.keyDown(.tab), at: 0)
        #expect(open.mode == "bag")
        #expect(open.pointerLock == false)
        #expect(summary(open.events) == ["pointerDown[1] 0@1800,432 1@240,108", "pointerUp[0] 0@1800,432 1@240,108"], "\(summary(open.events))")
        _ = e.handle(.keyUp(.tab), at: 0.1)
        let close = e.handle(.keyDown(.tab), at: 0.2)
        #expect(close.mode == "combat")
        #expect(close.pointerLock == true)
    }

    @Test func aHotkeyTouchesNothing() {
        let profile = KeymapProfile(package: "x", name: "x", controls: [
            eye(), Control(id: "toggle", kind: .hotkey, triggers: [.key(.q)], actions: [.toggleMouse]),
        ], fps: FPSSettings(aimControl: "eye"))
        #expect(profile.validate().isEmpty)
        var e = engine(profile)
        let lock = e.handle(.keyDown(.q), at: 0)
        #expect(lock.consumed)
        #expect(lock.pointerLock == true)
        _ = e.handle(.keyUp(.q), at: 0.1)
        let free = e.handle(.keyDown(.q), at: 0.2)
        #expect(free.pointerLock == false)
        #expect(e.activeTouchCount == 0)
    }

    // MARK: Click areas

    private func clickLayout(passThrough: Bool) -> KeymapProfile {
        KeymapProfile(package: "x", name: "x", controls: [
            eye(),
            Control(id: "close", kind: .clickArea(NormalizedRect(0.9, 0, 1, 0.1), passThrough: passThrough), modes: ["bag"],
                    actions: [.switchMode("combat"), .lockMouse]),
        ], fps: FPSSettings(aimControl: "eye"), modes: [KeymapMode(id: "bag", name: "Inventory"), KeymapMode(id: "combat", name: "Combat")])
    }

    @Test func clickingAnAreaDoesItsActionsAndTouchesTheGame() {
        let profile = clickLayout(passThrough: true)
        #expect(profile.validate().isEmpty)
        var e = engine(profile)
        #expect(e.mode == "bag")
        // Outside it: only the game's touch.
        let miss = e.handle(.fingerDown(x: 1000, y: 500), at: 0)
        #expect(miss.mode == nil)
        _ = e.handle(.fingerUp(x: 1000, y: 500), at: 0.05)
        // On the game's Close button: back to combat, the mouse locked, and the click touches Close.
        let hit = e.handle(.fingerDown(x: 2300, y: 50), at: 0.2)
        #expect(hit.consumed)
        #expect(hit.mode == "combat")
        #expect(hit.pointerLock == true)
        #expect(summary(hit.events).last == "pointerDown[1] 0@1800,432 1@2300,50")
        #expect(summary(e.handle(.fingerUp(x: 2300, y: 50), at: 0.25).events) == ["pointerUp[1] 0@1800,432 1@2300,50"])
    }

    @Test func anAreaMayKeepTheClickFromTheGame() {
        var e = engine(clickLayout(passThrough: false))
        let hit = e.handle(.fingerDown(x: 2300, y: 50), at: 0)
        #expect(hit.consumed)
        #expect(hit.mode == "combat")
        // Only the eye's finger, for the lock.
        #expect(summary(hit.events) == ["down[0] 0@1800,432"])
        let up = e.handle(.fingerUp(x: 2300, y: 50), at: 0.05)
        #expect(up.consumed)
        #expect(up.events.isEmpty)
    }

    @Test func anAreaRestsWhileTheMouseIsLockedOrInAnotherMode() {
        let profile = KeymapProfile(package: "x", name: "x", controls: [
            eye(), Control(id: "map", kind: .clickArea(NormalizedRect(0, 0, 0.2, 0.2), passThrough: true), actions: [.lockMouse]),
        ], fps: FPSSettings(aimControl: "eye"))
        var e = engine(profile)
        _ = e.setPointerLocked(true)
        #expect(e.handle(.fingerDown(x: 100, y: 100), at: 0).pointerLock == nil)
        _ = e.handle(.fingerUp(x: 100, y: 100), at: 0.05)
        // In combat the inventory's Close area rests: the click is the game's.
        var bag = engine(clickLayout(passThrough: true))
        _ = bag.handle(.fingerDown(x: 2300, y: 50), at: 0)
        _ = bag.handle(.fingerUp(x: 2300, y: 50), at: 0.05)
        _ = bag.setPointerLocked(false)
        #expect(bag.mode == "combat")
        let again = bag.handle(.fingerDown(x: 2300, y: 50), at: 0.2)
        #expect(again.mode == nil)
        #expect(again.pointerLock == nil)
    }

    // MARK: Validation

    @Test func actionsAreValidated() {
        let profile = KeymapProfile(package: "x", name: "x", controls: [
            Control(id: "a", kind: .hotkey, triggers: [.key(.q)]),
            Control(id: "b", kind: .clickArea(NormalizedRect(0, 0, 0.1, 0.1), passThrough: true)),
            Control(id: "c", kind: .dpad(center: NormalizedPoint(0.2, 0.7), radius: 0.1, up: .key(.w), down: .key(.s), left: .key(.a),
                                         right: .key(.d), stick: nil), actions: [.switchMode("foot")]),
            Control(id: "d", kind: .tap(NormalizedPoint(0.5, 0.5)), triggers: [.key(.e)], actions: [.lockMouse]),
            Control(id: "e", kind: .hotkey, triggers: [.scrollUp], actions: [.switchMode("foot")]),
            Control(id: "f", kind: .clickArea(NormalizedRect(0.5, 0.5, 0.4, 0.6), passThrough: false), actions: [.switchMode("foot")]),
        ], modes: [KeymapMode(id: "foot", name: "On foot")])
        let problems = profile.validate()
        #expect(problems.contains("a: does nothing yet: add an action"))
        #expect(problems.contains("b: does nothing yet: add an action"))
        #expect(problems.contains("c: a joystick or the eye cannot do actions"))
        #expect(problems.contains("d: locking or freeing the mouse needs the eye (mouse look)"))
        #expect(problems.contains("f: click area is invalid"))
        // The wheel may switch the mode.
        #expect(!problems.contains { $0.hasPrefix("e:") })
    }

    @Test func clickAreasTakeNoKeysOrButtons() {
        let area = Control(id: "x", kind: .clickArea(NormalizedRect(0, 0, 0.1, 0.1), passThrough: true), triggers: [.key(.q)])
        #expect(area.allTriggers.isEmpty)
        #expect(!area.accepts(.button(.a)))
        #expect(!area.touchesTheScreen)
        #expect(area.isOnGame)
        #expect(!Control(id: "h", kind: .hotkey).isOnGame)
    }

    @Test func aClickAreaMovesAndResizesOnTheScreen() throws {
        var area = Control(id: "x", kind: .clickArea(NormalizedRect(0.8, 0.1, 0.95, 0.2), passThrough: true))
        area.moveArea(dx: 0.2, dy: -0.5)
        let moved = try #require(area.area)
        #expect(abs(moved.minX - 0.85) < 1e-9 && moved.minY == 0 && moved.maxX == 1 && abs(moved.maxY - 0.1) < 1e-9)
        area.setArea(NormalizedRect(0.1, 0.1, 0.3, 0.3))
        #expect(area.kind == .clickArea(NormalizedRect(0.1, 0.1, 0.3, 0.3), passThrough: true))
    }
}
