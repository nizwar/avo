import AvoProtocol
import Foundation
import Testing
@testable import AvoKeymap

/// 2400 x 1080 landscape display.
private let W = 2400.0, H = 1080.0

private func summary(_ events: [TouchEvent]) -> [String] {
    events.map { event in
        let pointers = event.pointers.map { "\($0.id)@\(Int($0.x.rounded())),\(Int($0.y.rounded()))" }.joined(separator: " ")
        return "\(event.action)[\(event.actionIndex)] \(pointers)"
    }
}

/// W A S D at (360, 756), 108 px across; Shift pushes it twice as far.
private func walk(run: JoystickRun? = JoystickRun(trigger: .key(.shift), scale: 2)) -> Control {
    Control(id: "move", kind: .dpad(center: NormalizedPoint(0.15, 0.7), radius: 0.1, up: .key(.w), down: .key(.s), left: .key(.a),
                                    right: .key(.d), stick: .left), run: run)
}

private func engine(_ controls: [Control]) -> KeymapEngine {
    KeymapEngine(profile: KeymapProfile(package: "x", name: "x", controls: controls), displayID: 7, width: W, height: H)
}

/// A joystick that runs: further while its key is held, back when it is let go.
@Suite struct JoystickRunTests {
    @Test func theJoystickGoesFurtherWhileItsKeyIsHeld() {
        var e = engine([walk()])
        _ = e.handle(.keyDown(.w), at: 0)
        #expect(summary(Array((1...30).flatMap { e.tick(at: Double($0) / 120) }.suffix(1))) == ["move[0] 0@360,648"])
        // Shift: twice as far, gliding there.
        #expect(e.handle(.keyDown(.shift), at: 0.3).consumed)
        #expect(summary(Array((37...80).flatMap { e.tick(at: Double($0) / 120) }.suffix(1))) == ["move[0] 0@360,540"])
        // Let go of Shift: walking again, the finger still down.
        _ = e.handle(.keyUp(.shift), at: 0.7)
        #expect(summary(Array((85...130).flatMap { e.tick(at: Double($0) / 120) }.suffix(1))) == ["move[0] 0@360,648"])
        #expect(summary(e.handle(.keyUp(.w), at: 1.2).events) == ["up[0] 0@360,648"])
        // Shift alone touches nothing.
        #expect(e.handle(.keyDown(.shift), at: 1.3).events.isEmpty)
    }

    @Test func runningFromTheStart() {
        var e = engine([walk()])
        _ = e.handle(.keyDown(.shift), at: 0)
        _ = e.handle(.keyDown(.d), at: 0.1)
        #expect(summary(Array((13...60).flatMap { e.tick(at: Double($0) / 120) }.suffix(1))) == ["move[0] 0@576,756"])
    }

    @Test func aControllerButtonRunsAndComesOffWithTheMapping() {
        var profile = KeymapProfile(package: "x", name: "x", controls: [walk(run: JoystickRun(trigger: .gamepad(.leftThumbstick)))])
        #expect(profile.validate().isEmpty)
        #expect(profile.controls(boundTo: .button(.leftThumbstick)).map(\.id) == ["move"])
        _ = profile.removeGamepadMapping()
        #expect(profile.controls[0].run == nil)
    }

    @Test func runIsValidatedAndRoundTrips() throws {
        let profile = KeymapProfile(package: "x", name: "x", controls: [walk()])
        #expect(profile.validate().isEmpty)
        let data = try profile.encoded()
        #expect(String(decoding: data, as: UTF8.self).contains("\"run\" : {"))
        #expect(try KeymapProfile.decode(data) == profile)
        let bad = KeymapProfile(package: "x", name: "x", controls: [
            walk(run: JoystickRun(trigger: .key(.w))),
            Control(id: "far", kind: .dpad(center: NormalizedPoint(0.5, 0.7), radius: 0.1, up: .key(.i), down: .key(.k), left: .key(.j),
                                           right: .key(.l), stick: nil), run: JoystickRun(trigger: .key(.shift), scale: 9)),
        ])
        let problems = bad.validate()
        #expect(problems.contains("move: the key to run is also a direction"))
        #expect(problems.contains("far: running reach must be 1 to 4 times the joystick's"))
        // A joystick from before running has none, and saves none.
        let plain = try KeymapProfile(package: "x", name: "x", controls: [walk(run: nil)]).encoded()
        #expect(!String(decoding: plain, as: UTF8.self).contains("run"))
    }
}
