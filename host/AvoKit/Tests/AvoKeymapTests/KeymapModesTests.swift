import AvoProtocol
import Foundation
import Testing
@testable import AvoKeymap

/// 2400 x 1080 landscape display: one mouse count is one pixel at sensitivity 1.
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

private func eye(_ id: String = "eye", modes: [String]? = nil) -> Control {
    Control(id: id, kind: .aim(area: NormalizedRect(0.5, 0.1, 1, 0.7), sensitivity: AxisPair(x: 1, y: 1), adsSensitivity: AxisPair(x: 1, y: 1),
                               exponent: 1, deadzone: 0, invertY: false, stick: nil), modes: modes)
}

private let modes = [KeymapMode(id: "foot", name: "On foot"), KeymapMode(id: "vehicle", name: "Vehicle")]

/// A PUBG-like layout: F enters a vehicle on foot and leaves it in one, and
/// the mode follows; WASD walk or drive.
private func vehicleLayout() -> KeymapProfile {
    KeymapProfile(package: "com.example.pubg", name: "Modes", controls: [
        Control(id: "enter", kind: .tap(NormalizedPoint(0.8, 0.6)), triggers: [.key(.f)], modes: ["foot"]),
        Control(id: "to-vehicle", kind: .switchMode("vehicle", position: NormalizedPoint(0.85, 0.6)), triggers: [.key(.f)], modes: ["foot"]),
        Control(id: "exit", kind: .tap(NormalizedPoint(0.8, 0.7)), triggers: [.key(.f)], modes: ["vehicle"]),
        Control(id: "to-foot", kind: .switchMode("foot", position: NormalizedPoint(0.85, 0.7)), triggers: [.key(.f)], modes: ["vehicle"]),
        Control(id: "jump", kind: .tap(NormalizedPoint(0.9, 0.8)), triggers: [.key(.space)], modes: ["foot"]),
        Control(id: "walk", kind: .dpad(center: NormalizedPoint(0.2, 0.7), radius: 0.1, up: .key(.w), down: .key(.s), left: .key(.a),
                                        right: .key(.d), stick: .left), modes: ["foot"]),
        Control(id: "drive", kind: .dpad(center: NormalizedPoint(0.3, 0.6), radius: 0.1, up: .key(.w), down: .key(.s), left: .key(.a),
                                         right: .key(.d), stick: .left), modes: ["vehicle"]),
    ], modes: modes)
}

@Suite struct KeymapModesTests {
    @Test func aKeyMayDoSeveralThings() {
        let profile = KeymapProfile(package: "x", name: "x", controls: [
            Control(id: "a", kind: .tap(NormalizedPoint(0.25, 0.5)), triggers: [.key(.f)]),
            Control(id: "b", kind: .tap(NormalizedPoint(0.75, 0.5)), triggers: [.key(.f)]),
        ])
        #expect(profile.validate().isEmpty)
        var e = engine(profile)
        let down = e.handle(.keyDown(.f), at: 0)
        #expect(down.consumed)
        #expect(summary(down.events) == ["down[0] 0@600,540", "pointerDown[1] 0@600,540 1@1800,540"])
    }

    @Test func theCursorToggleSharesItsKey() {
        // Tab: the game's inventory, and the mouse free to use it.
        let profile = KeymapProfile(package: "x", name: "x", controls: [
            eye(), Control(id: "bag", kind: .tap(NormalizedPoint(0.1, 0.1)), triggers: [.key(.tab)]),
        ], fps: FPSSettings(cursorToggle: .key(.tab), aimControl: "eye"))
        #expect(profile.validate().isEmpty)
        var e = engine(profile)
        _ = e.setPointerLocked(true)
        let press = e.handle(.keyDown(.tab), at: 0)
        #expect(press.pointerLock == false)
        #expect(!e.pointerLocked)
        // The eye's finger lifts with the lock, then the bag's goes down.
        #expect(summary(press.events) == ["up[0] 0@1800,432", "down[0] 0@240,108"])
        #expect(e.handle(.keyUp(.tab), at: 0.1).consumed)
    }

    @Test func enteringAndLeavingAVehicle() {
        var e = engine(vehicleLayout())
        #expect(e.mode == "foot")
        let enter = e.handle(.keyDown(.f), at: 0)
        #expect(enter.mode == "vehicle")
        #expect(e.mode == "vehicle")
        // The game's Enter button was pressed in the mode it belongs to, and lifts with its key.
        #expect(summary(enter.events) == ["down[0] 0@1920,648"])
        #expect(summary(e.handle(.keyUp(.f), at: 0.1).events) == ["up[0] 0@1920,648"])
        // On foot's controls rest in the vehicle.
        #expect(!e.handle(.keyDown(.space), at: 0.2).consumed)
        _ = e.handle(.keyUp(.space), at: 0.25)
        // F again: the vehicle's Exit button, and on foot again.
        let exit = e.handle(.keyDown(.f), at: 0.3)
        #expect(exit.mode == "foot")
        #expect(summary(exit.events) == ["down[0] 0@1920,756"])
    }

    @Test func leavingAModeHandsTheHeldKeysOn() {
        var e = engine(vehicleLayout())
        // Walking forward.
        _ = e.handle(.keyDown(.w), at: 0)
        _ = e.tick(at: 0.5)
        // F mid-walk: the Enter button goes down, the walk joystick (partway
        // up) lets go, and the drive joystick takes W at once on the free finger.
        let enter = e.handle(.keyDown(.f), at: 0.6)
        #expect(summary(enter.events) == [
            "pointerDown[1] 0@480,707 1@1920,648", "pointerUp[0] 0@480,707 1@1920,648",
            "pointerDown[1] 1@1920,648 0@720,648", "move[0] 1@1920,648 0@720,540",
        ])
    }

    @Test func aModeLocksOrFreesTheMouse() {
        let profile = KeymapProfile(package: "x", name: "x", controls: [
            eye(modes: ["combat"]),
            Control(id: "open", kind: .switchMode("bag", position: NormalizedPoint(0.1, 0.2)), triggers: [.key(.tab)], modes: ["combat"]),
            Control(id: "close", kind: .switchMode("combat", position: NormalizedPoint(0.1, 0.2)), triggers: [.key(.tab)], modes: ["bag"]),
        ], fps: FPSSettings(aimControl: "eye"),
        modes: [KeymapMode(id: "combat", name: "Combat", mouseLook: true), KeymapMode(id: "bag", name: "Inventory", mouseLook: false)])
        #expect(profile.validate().isEmpty)
        var e = engine(profile)
        _ = e.setPointerLocked(true)
        let open = e.handle(.keyDown(.tab), at: 0)
        #expect(open.mode == "bag")
        #expect(open.pointerLock == false)
        _ = e.handle(.keyUp(.tab), at: 0.1)
        let close = e.handle(.keyDown(.tab), at: 0.2)
        #expect(close.mode == "combat")
        #expect(close.pointerLock == true)
        #expect(e.pointerLocked)
    }

    @Test func keysThatFreeOrLockTheMouse() {
        let profile = KeymapProfile(package: "x", name: "x", controls: [
            eye(),
            Control(id: "map", kind: .tap(NormalizedPoint(0.9, 0.1)), triggers: [.key(.m)]),
            Control(id: "free", kind: .mouseLook(lock: false, position: NormalizedPoint(0.95, 0.1)), triggers: [.key(.m)]),
            Control(id: "lock", kind: .mouseLook(lock: true, position: NormalizedPoint(0.5, 0.5)), triggers: [.mouse(.right)]),
        ], fps: FPSSettings(aimControl: "eye"))
        #expect(profile.validate().isEmpty)
        var e = engine(profile)
        _ = e.setPointerLocked(true)
        let map = e.handle(.keyDown(.m), at: 0)
        #expect(map.pointerLock == false)
        #expect(!e.pointerLocked)
        _ = e.handle(.keyUp(.m), at: 0.1)
        // Again: already free, nothing to do.
        #expect(e.handle(.keyDown(.m), at: 0.2).pointerLock == nil)
        #expect(e.handle(.mouseDown(.right), at: 0.3).pointerLock == true)
    }

    @Test func modesAreValidated() {
        let profile = KeymapProfile(package: "x", name: "x", controls: [
            Control(id: "a", kind: .tap(NormalizedPoint(0.5, 0.5)), triggers: [.key(.f)], modes: ["swim"]),
            Control(id: "b", kind: .switchMode("fly", position: NormalizedPoint(0.5, 0.5)), triggers: [.key(.g)]),
            Control(id: "c", kind: .switchMode("foot", position: NormalizedPoint(0.85, 0.7))),
            Control(id: "d", kind: .mouseLook(lock: false, position: NormalizedPoint(0.95, 0.1)), triggers: [.key(.h)]),
        ], modes: modes + [KeymapMode(id: "foot", name: " ")])
        let problems = profile.validate()
        #expect(problems.contains("duplicate or empty mode id foot"))
        #expect(problems.contains("mode foot has no name"))
        #expect(problems.contains("a: no mode swim"))
        #expect(problems.contains("b: no mode fly to switch to"))
        #expect(problems.contains("c: needs a trigger"))
        #expect(problems.contains("d: locking or freeing the mouse needs the eye (mouse look)"))
    }

    @Test func modesRoundTrip() throws {
        let profile = vehicleLayout()
        #expect(profile.validate().isEmpty)
        let data = try profile.encoded()
        #expect(try KeymapProfile.decode(data) == profile)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"type\" : \"switch_mode\""))
        #expect(json.contains("\"modes\" : ["))
        // A layout without modes writes none.
        let plain = try KeymapProfile(package: "x", name: "x", controls: []).encoded()
        #expect(!String(decoding: plain, as: UTF8.self).contains("modes"))
    }

    /// The controller follows the modes: a button may press several controls,
    /// and one stick steers the walk joystick on foot and the drive joystick in a vehicle.
    @Test func theControllerFollowsTheModes() throws {
        var profile = vehicleLayout()
        try profile.bind(.button(.y), to: "enter")
        try profile.bind(.button(.y), to: "to-vehicle")
        #expect(profile.controls(boundTo: .button(.y)).map(\.id) == ["enter", "to-vehicle"])
        try profile.bind(.stick(.right), to: "drive")
        try profile.bind(.stick(.right), to: "walk")
        // Different modes: both keep it.
        #expect(Set(profile.controls(boundTo: .stick(.right)).map(\.id)) == ["walk", "drive"])
        // A joystick that acts in every mode takes it from both.
        profile.controls.append(Control(id: "look", kind: .dpad(center: NormalizedPoint(0.7, 0.7), radius: 0.1, up: .key(.i), down: .key(.k),
                                                                   left: .key(.j), right: .key(.l), stick: nil)))
        try profile.bind(.stick(.right), to: "look")
        #expect(profile.controls(boundTo: .stick(.right)).map(\.id) == ["look"])
    }
}
