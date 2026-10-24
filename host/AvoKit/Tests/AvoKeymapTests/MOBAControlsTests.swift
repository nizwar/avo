import AvoProtocol
import Foundation
import Testing
@testable import AvoKeymap

/// 2400 x 1080 landscape display; the hero stands in the middle (1200, 540) unless a test moves it.
private let W = 2400.0, H = 1080.0

private func engine(_ controls: [Control], fps: FPSSettings? = nil, hero: NormalizedPoint? = nil) -> KeymapEngine {
    KeymapEngine(profile: KeymapProfile(package: "com.example.moba", name: "Test", controls: controls, fps: fps, hero: hero),
                 displayID: 7, width: W, height: H)
}

private func summary(_ events: [TouchEvent]) -> [String] {
    events.map { event in
        let pointers = event.pointers.map { "\($0.id)@\(Int($0.x.rounded())),\(Int($0.y.rounded()))" }.joined(separator: " ")
        return "\(event.action)[\(event.actionIndex)] \(pointers)"
    }
}

/// Display frames at 120 Hz from `from` to `to` (inclusive), returning the last event.
private func frames(_ e: inout KeymapEngine, _ from: Int, _ to: Int) -> [String] {
    summary(Array((from...to).flatMap { e.tick(at: Double($0) / 120) }.suffix(1)))
}

/// Joystick at (360, 756) with a 108 px radius.
private let move = Control(id: "move", kind: .mobaMove(center: NormalizedPoint(0.15, 0.7), radius: 0.1), triggers: [.mouse(.right)])
/// Skill at (1920, 810): drags up to 108 px, the full length once the cursor is 432 px from the hero.
private let skill = Control(id: "skill", kind: .smartCast(NormalizedPoint(0.8, 0.75), radius: 0.1, reach: 0.4), triggers: [.key(.q)])

@Suite struct MOBAMoveTests {
    @Test func pushesTheJoystickTowardsTheCursorWhileHeld() {
        var e = engine([move])
        // Reporting the cursor alone does nothing.
        let idle = e.handle(.cursor(x: 1500, y: 540), at: 0)
        #expect(!idle.consumed && idle.events.isEmpty)
        // Cursor 300 px right of the hero: down at the centre, part of the way out at once, then a glide.
        let press = e.handle(.mouseDown(.right), at: 0)
        #expect(press.consumed)
        #expect(summary(press.events) == ["down[0] 0@360,756", "move[0] 0@409,756"])
        #expect(e.isFollowingCursor)
        #expect(frames(&e, 1, 30) == ["move[0] 0@468,756"])
        // The cursor goes above the hero: the joystick turns up over the next frames.
        let turn = e.handle(.cursor(x: 1200, y: 240), at: 0.3)
        #expect(turn.consumed && turn.events.isEmpty)
        #expect(frames(&e, 37, 70) == ["move[0] 0@360,648"])
        // A cursor that stays put sends nothing more.
        #expect(e.handle(.cursor(x: 1200, y: 240), at: 0.6).events.isEmpty)
        #expect(e.tick(at: 0.6).isEmpty)
        let release = e.handle(.mouseUp(.right), at: 1)
        #expect(release.consumed)
        #expect(summary(release.events) == ["up[0] 0@360,648"])
        #expect(e.activeTouchCount == 0)
        #expect(!e.isFollowingCursor)
    }

    @Test func pushesOnlyPartwayWhileTheCursorIsNearTheHero() {
        // Hero moved to (720, 540); the cursor half a radius (54 px) to its right.
        var e = engine([move], hero: NormalizedPoint(0.3, 0.5))
        _ = e.handle(.cursor(x: 774, y: 540), at: 0)
        _ = e.handle(.mouseDown(.right), at: 0)
        #expect(frames(&e, 1, 30) == ["move[0] 0@414,756"])
    }

    @Test func worksWithKeysAndGamepadButtonsAndWaitsForACursor() {
        let control = Control(id: "move", kind: .mobaMove(center: NormalizedPoint(0.15, 0.7), radius: 0.1),
                              triggers: [.key(.space), .gamepad(.a)])
        var e = engine([control])
        // No cursor reported yet: the finger rests on the joystick.
        #expect(summary(e.handle(.keyDown(.space), at: 0).events) == ["down[0] 0@360,756"])
        // A cursor reported later sets where it aims; the frames take it there.
        #expect(e.handle(.cursor(x: 1200, y: 1000), at: 0.05).events.isEmpty)
        // Still held through the gamepad button after the key lets go.
        _ = e.handle(.gamepadButton(.a, pressed: true), at: 0.1)
        #expect(e.handle(.keyUp(.space), at: 0.2).events.isEmpty)
        // Let go where it is aimed, not partway through the glide.
        #expect(summary(e.handle(.gamepadButton(.a, pressed: false), at: 0.3).events) == ["move[0] 0@360,864", "up[0] 0@360,864"])
    }

    @Test func aLeftClickBindingWorksWithTheMouseFree() {
        // Click to walk: a control made for the cursor takes the left button.
        let control = Control(id: "move", kind: .mobaMove(center: NormalizedPoint(0.15, 0.7), radius: 0.1), triggers: [.mouse(.left)])
        var e = engine([control])
        _ = e.handle(.cursor(x: 1500, y: 540), at: 0)
        let press = e.handle(.mouseDown(.left), at: 0)
        #expect(press.consumed)
        #expect(e.activeTouchCount == 1)
    }

    @Test func staysOutOfTheWayWhileTheMouseIsLocked() {
        let camera = Control(id: "camera", kind: .aim(area: NormalizedRect(0.5, 0.1, 1, 0.7), sensitivity: AxisPair(x: 1, y: 1),
                                                      adsSensitivity: AxisPair(x: 1, y: 1), exponent: 1, deadzone: 0,
                                                      invertY: false, stick: nil))
        var e = engine([camera, move], fps: FPSSettings(aimControl: "camera"))
        _ = e.handle(.cursor(x: 1500, y: 540), at: 0)
        // Free mouse: it moves the hero.
        #expect(e.handle(.mouseDown(.right), at: 0).consumed)
        #expect(e.isFollowingCursor)
        // Locking the mouse for the camera lifts it: the cursor is hidden.
        #expect(summary(e.setPointerLocked(true)) == ["up[0] 0@409,756", "down[0] 0@1800,432"])
        #expect(!e.isFollowingCursor)
        _ = e.handle(.mouseUp(.right), at: 0.1)
        // While locked it does not start again.
        let locked = e.handle(.mouseDown(.right), at: 0.2)
        #expect(!locked.consumed && locked.events.isEmpty)
        _ = e.handle(.mouseUp(.right), at: 0.3)
        _ = e.setPointerLocked(false)
        #expect(e.handle(.mouseDown(.right), at: 0.4).consumed)
    }
}

@Suite struct SmartCastTests {
    @Test func dragsTheSkillAsFarAsTheCursorIsFromTheHero() {
        var e = engine([skill])
        // Half the reach (216 px) right of the hero: half the radius (54 px).
        _ = e.handle(.cursor(x: 1416, y: 540), at: 0)
        let press = e.handle(.keyDown(.q), at: 0)
        #expect(press.consumed)
        #expect(summary(press.events) == ["down[0] 0@1920,810", "move[0] 0@1944,810"])
        #expect(frames(&e, 1, 30) == ["move[0] 0@1974,810"])
        // Far above the hero: the full radius and no more, following the cursor.
        #expect(e.handle(.cursor(x: 1200, y: -460), at: 0.25).events.isEmpty)
        #expect(frames(&e, 31, 31) == ["move[0] 0@1961,784"])
        // Letting go casts where it is aimed, even before the glide gets there.
        let cast = e.handle(.keyUp(.q), at: 31.0 / 120)
        #expect(cast.consumed)
        #expect(summary(cast.events) == ["move[0] 0@1920,702", "up[0] 0@1920,702"])
        #expect(e.activeTouchCount == 0)
        // Released: the cursor no longer moves anything.
        #expect(e.handle(.cursor(x: 0, y: 0), at: 0.5).events.isEmpty)
        #expect(e.tick(at: 0.5).isEmpty)
    }

    @Test func aQuickPressStillDragsAndCasts() {
        var e = engine([skill])
        _ = e.handle(.cursor(x: 1416, y: 540), at: 0)
        _ = e.handle(.keyDown(.q), at: 0)
        // Released after 10 ms: the cast waits for a whole touch.
        #expect(e.handle(.keyUp(.q), at: 0.01).events.isEmpty)
        #expect(e.tick(at: 0.03).isEmpty)
        #expect(summary(e.tick(at: 0.041)) == ["move[0] 0@1974,810", "up[0] 0@1974,810"])
        #expect(e.activeTouchCount == 0)
    }

    @Test func aCursorOnTheHeroIsAQuickCast() {
        var e = engine([skill])
        _ = e.handle(.cursor(x: 1200, y: 540), at: 0)
        #expect(summary(e.handle(.keyDown(.q), at: 0).events) == ["down[0] 0@1920,810"])
        #expect(summary(e.handle(.keyUp(.q), at: 0.1).events) == ["up[0] 0@1920,810"])
    }

    @Test func staysOnTheScreenWithoutTurning() {
        // A big drag from a button near the bottom right corner, towards that corner.
        let corner = Control(id: "ult", kind: .smartCast(NormalizedPoint(0.95, 0.9), radius: 0.2, reach: 0.2), triggers: [.key(.r)])
        var e = engine([corner])
        _ = e.handle(.cursor(x: 2200, y: 1540), at: 0)
        _ = e.handle(.keyDown(.r), at: 0)
        // Shortened along the same diagonal until it meets the bottom edge.
        #expect(frames(&e, 1, 30) == ["move[0] 0@2387,1079"])
    }

    @Test func skillsAndMovementShareTheCursor() {
        var e = engine([move, skill])
        _ = e.handle(.cursor(x: 1632, y: 540), at: 0) // a full reach to the right
        _ = e.handle(.mouseDown(.right), at: 0)
        _ = e.handle(.keyDown(.q), at: 0.05)
        _ = frames(&e, 7, 40)
        let both = e.tick(at: 41.0 / 120)
        #expect(both.isEmpty) // settled
        #expect(e.handle(.cursor(x: 1200, y: 108), at: 41.0 / 120).events.isEmpty)
        // One move event carries both fingers turning up together.
        #expect(summary(e.tick(at: 42.0 / 120)) == ["move[0] 0@442,730 1@2002,784"])
    }

    @Test func aCursorReportedEveryFrameGlidesAtOnePaceAtAnyFrameRate() {
        // As KeymapController does while a MOBA control is held: report the cursor, then tick.
        func play(framesPerSecond: Double, frames: Int) -> [TouchEvent] {
            var e = engine([move])
            _ = e.tick(at: 0)
            _ = e.handle(.cursor(x: 1500, y: 540), at: 0)
            _ = e.handle(.mouseDown(.right), at: 0)
            return (1...frames).flatMap { frame in
                let now = Double(frame) / framesPerSecond
                return e.handle(.cursor(x: 1500, y: 540), at: now).events + e.tick(at: now)
            }
        }
        // 50 ms at 60 and at 120 Hz: one move per frame, and the joystick is as far out either way.
        let slow = play(framesPerSecond: 60, frames: 3), fast = play(framesPerSecond: 120, frames: 6)
        #expect(slow.count == 3 && fast.count == 6)
        #expect(summary(Array(slow.suffix(1))) == ["move[0] 0@457,756"])
        #expect(summary(Array(fast.suffix(1))) == ["move[0] 0@457,756"])
    }

    @Test func resetLiftsEveryMOBATouch() {
        // Game Mode off and focus loss reset the engine.
        var e = engine([move, skill])
        _ = e.handle(.cursor(x: 1500, y: 300), at: 0)
        _ = e.handle(.mouseDown(.right), at: 0)
        _ = e.handle(.keyDown(.q), at: 0)
        #expect(e.activeTouchCount == 2)
        let events = e.reset()
        #expect(events.filter { $0.action == .up || $0.action == .pointerUp }.count == 2)
        #expect(e.activeTouchCount == 0)
        #expect(!e.isFollowingCursor)
        // Nothing comes back when the keys are released afterwards.
        #expect(e.handle(.mouseUp(.right), at: 0.1).events.isEmpty)
        #expect(e.handle(.keyUp(.q), at: 0.1).events.isEmpty)
        #expect(e.tick(at: 0.2).isEmpty)
    }
}

/// A left click no control takes (KeymapController sends it as fingerDown and fingerUp).
@Suite struct ClickFingerTests {
    private let attack = Control(id: "attack", kind: .tap(NormalizedPoint(0.9, 0.8)), triggers: [.key(.space)])

    @Test func aClickIsAFingerThatFollowsTheCursor() {
        var e = engine([attack])
        _ = e.tick(at: 0)
        let press = e.handle(.fingerDown(x: 600, y: 300), at: 0)
        #expect(press.consumed)
        #expect(summary(press.events) == ["down[0] 0@600,300"])
        #expect(e.isFollowingCursor)
        // A drag goes out with the frame.
        #expect(e.handle(.cursor(x: 650, y: 320), at: 0.01).events.isEmpty)
        #expect(summary(e.tick(at: 0.01)) == ["move[0] 0@650,320"])
        // Kept on the display, and lifted where the button comes up.
        let release = e.handle(.fingerUp(x: 2500, y: 330), at: 0.02)
        #expect(release.consumed)
        #expect(summary(release.events) == ["move[0] 0@2399,330", "up[0] 0@2399,330"])
        #expect(e.activeTouchCount == 0 && !e.isFollowingCursor)
        // Nothing left to lift.
        #expect(!e.handle(.fingerUp(x: 0, y: 0), at: 0.03).consumed)
    }

    @Test func aClickWhileWalkingIsASecondFingerOfTheSameGesture() {
        // The right button walks; a click on a game button (a skill upgrade, the shop) must not stop the hero.
        var e = engine([move])
        _ = e.handle(.cursor(x: 1500, y: 540), at: 0)
        _ = e.handle(.mouseDown(.right), at: 0)
        #expect(summary(e.handle(.fingerDown(x: 1700, y: 200), at: 0.1).events) == ["pointerDown[1] 0@409,756 1@1700,200"])
        #expect(summary(e.handle(.fingerUp(x: 1700, y: 200), at: 0.15).events) == ["pointerUp[1] 0@409,756 1@1700,200"])
        // The joystick never let go.
        #expect(e.activeTouchCount == 1)
        #expect(summary(e.handle(.mouseUp(.right), at: 0.2).events) == ["move[0] 0@468,756", "up[0] 0@468,756"])
    }

    @Test func keysPressedDuringAClickJoinIt() {
        var e = engine([attack])
        _ = e.handle(.fingerDown(x: 600, y: 300), at: 0)
        #expect(summary(e.handle(.keyDown(.space), at: 0.01).events) == ["pointerDown[1] 0@600,300 1@2160,864"])
        // Game Mode off or focus lost: both lift.
        #expect(e.reset().count == 2)
        #expect(!e.isFollowingCursor)
        #expect(e.handle(.fingerUp(x: 600, y: 300), at: 0.1).events.isEmpty)
    }

    @Test func lockingTheMouseLiftsTheClick() {
        let camera = Control(id: "camera", kind: .aim(area: NormalizedRect(0.5, 0.1, 1, 0.7), sensitivity: AxisPair(x: 1, y: 1),
                                                      adsSensitivity: AxisPair(x: 1, y: 1), exponent: 1, deadzone: 0,
                                                      invertY: false, stick: nil))
        var e = engine([camera], fps: FPSSettings(aimControl: "camera"))
        _ = e.handle(.fingerDown(x: 600, y: 300), at: 0)
        #expect(summary(e.setPointerLocked(true)) == ["up[0] 0@600,300", "down[0] 0@1800,432"])
        #expect(e.handle(.fingerUp(x: 600, y: 300), at: 0.1).events.isEmpty)
    }
}

@Suite struct MOBAProfileTests {
    @Test func jsonRoundTrip() throws {
        let profile = KeymapProfile(package: "com.example.moba", name: "MOBA", controls: [move, skill],
                                    hero: NormalizedPoint(0.5, 0.45))
        let data = try profile.encoded()
        #expect(try KeymapProfile.decode(data) == profile)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"type\" : \"moba_move\""))
        #expect(json.contains("\"type\" : \"smart_cast\""))
        #expect(json.contains("\"reach\" : 0.4"))
        #expect(json.contains("\"hero\" : ["))
        #expect(profile.validate().isEmpty)
    }

    @Test func profilesWithoutMOBAFieldsStillDecode() throws {
        // An older file: no hero; MOBA controls written without their optional fields.
        let json = """
        {"schema": 1, "package": "com.example.moba", "name": "Old",
         "controls": [
           {"id": "jump", "type": "tap", "position": [0.9, 0.7], "triggers": ["key:Space"]},
           {"id": "move", "type": "moba_move", "center": [0.15, 0.7], "triggers": ["mouse:right"]},
           {"id": "skill", "type": "smart_cast", "position": [0.8, 0.75], "triggers": ["key:Q"]}
         ]}
        """
        let profile = try KeymapProfile.decode(Data(json.utf8))
        #expect(profile.hero == nil)
        #expect(profile.controls.map(\.kind) == [
            .tap(NormalizedPoint(0.9, 0.7)),
            .mobaMove(center: NormalizedPoint(0.15, 0.7), radius: Control.defaultJoystickRadius),
            .smartCast(NormalizedPoint(0.8, 0.75), radius: Control.defaultCastRadius, reach: Control.defaultCastReach),
        ])
        #expect(profile.unsupportedControls.isEmpty)
        #expect(profile.validate().isEmpty)
    }

    @Test func unknownControlKindsAreSkippedNotFatal() throws {
        // Written by a newer Avo: the rest of the profile still loads.
        let json = """
        {"schema": 1, "package": "com.example.moba", "name": "Newer",
         "controls": [
           {"id": "jump", "type": "tap", "position": [0.9, 0.7], "triggers": ["key:Space"]},
           {"id": "blink", "type": "teleport", "somewhere": [1, 2, 3], "triggers": ["key:T"]}
         ]}
        """
        let profile = try KeymapProfile.decode(Data(json.utf8))
        #expect(profile.controls.map(\.id) == ["jump"])
        #expect(profile.unsupportedControls == ["teleport"])
        #expect(profile.validate().isEmpty)
        // Saving leaves the unknown control out.
        #expect(!String(decoding: try profile.encoded(), as: UTF8.self).contains("teleport"))
        // A broken control of a known kind still fails the profile.
        let broken = #"{"schema": 1, "package": "x", "name": "x", "controls": [{"id": "a", "type": "tap"}]}"#
        #expect(throws: DecodingError.self) { try KeymapProfile.decode(Data(broken.utf8)) }
    }

    @Test func validatesMOBAValues() {
        let profile = KeymapProfile(package: "x", name: "x", controls: [
            Control(id: "a", kind: .mobaMove(center: NormalizedPoint(0.15, 0.7), radius: 0.9)),
            Control(id: "b", kind: .smartCast(NormalizedPoint(0.8, 0.75), radius: 0.1, reach: 5), triggers: [.key(.q)]),
            Control(id: "c", kind: .smartCast(NormalizedPoint(0.8, 0.5), radius: 0.1, reach: 0.4), triggers: [.scrollUp]),
        ], hero: NormalizedPoint(1.2, 0.5))
        let problems = profile.validate()
        #expect(problems.contains("a: needs a trigger"))
        #expect(problems.contains("a: radius must be between 0.01 and 0.5"))
        #expect(problems.contains("b: reach must be between 0.05 and 2"))
        #expect(problems.contains("c: scroll triggers only work with tap, swipe, macro and hotkey controls"))
        #expect(problems.contains("the hero point 1.2, 0.5 is outside the screen"))
    }
}
