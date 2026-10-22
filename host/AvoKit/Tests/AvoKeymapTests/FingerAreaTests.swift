import AvoProtocol
import Foundation
import Testing
@testable import AvoKeymap

/// 2400 x 1080 landscape display: one mouse count is one pixel at sensitivity 1.
private let W = 2400.0, H = 1080.0

private func engine(_ controls: [Control], fps: FPSSettings? = nil) -> KeymapEngine {
    KeymapEngine(profile: KeymapProfile(package: "com.example.game", name: "Test", controls: controls, fps: fps),
                 displayID: 7, width: W, height: H)
}

private func summary(_ events: [TouchEvent]) -> [String] {
    events.map { event in
        let pointers = event.pointers.map { "\($0.id)@\(Int($0.x.rounded())),\(Int($0.y.rounded()))" }.joined(separator: " ")
        return "\(event.action)[\(event.actionIndex)] \(pointers)"
    }
}

private func eye(_ area: NormalizedRect, origin: NormalizedPoint? = nil) -> Control {
    Control(id: "eye", kind: .aim(area: area, sensitivity: AxisPair(x: 1, y: 1), adsSensitivity: AxisPair(x: 1, y: 1),
                                  exponent: 1, deadzone: 0, invertY: false, stick: nil, origin: origin))
}

private func close(_ a: NormalizedPoint?, _ b: NormalizedPoint) -> Bool {
    guard let a else { return false }
    return abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9
}

private func close(_ a: NormalizedRect?, _ b: NormalizedRect) -> Bool {
    guard let a else { return false }
    return [a.minX - b.minX, a.minY - b.minY, a.maxX - b.maxX, a.maxY - b.maxY].allSatisfy { abs($0) < 1e-9 }
}

private func locked(_ camera: Control) -> KeymapEngine {
    var e = engine([camera], fps: FPSSettings(aimControl: camera.id))
    _ = e.setPointerLocked(true)
    return e
}

@Suite struct EyeAreaTests {
    /// The right half at full height but for 5% margins: y 54…1026 px, the finger keeps 1 px inside.
    static let tall = NormalizedRect(0.5, 0.05, 1.0, 0.95)

    @Test func aTallAreaLetsTheFingerTravelItsWholeHeightBeforeStartingOver() {
        var e = engine([eye(Self.tall)], fps: FPSSettings(aimControl: "eye"))
        #expect(summary(e.setPointerLocked(true)) == ["down[0] 0@1800,540"])
        // Looking up: the finger goes all the way to the top of the area without lifting...
        #expect(summary(e.handle(.mouseMoved(dx: 0, dy: -485), at: 0).events) == ["move[0] 0@1800,55"])
        // ...and only past it lifts, touches down at the eye's point again and carries on.
        #expect(summary(e.handle(.mouseMoved(dx: 0, dy: -10), at: 0.01).events)
            == ["up[0] 0@1800,55", "down[0] 0@1800,540", "move[0] 0@1800,530"])
        // Looking down goes as far, to the bottom of the area.
        #expect(summary(e.handle(.mouseMoved(dx: 0, dy: 495), at: 0.02).events) == ["move[0] 0@1800,1025"])
        #expect(summary(e.handle(.mouseMoved(dx: 0, dy: 1), at: 0.03).events)
            == ["up[0] 0@1800,1025", "down[0] 0@1800,540", "move[0] 0@1800,541"])
    }

    @Test func aLongLookUsesTheWholeHeightOnEverySwipe() {
        var e = locked(eye(Self.tall))
        // 1000 px up from the middle: two full swipes up to the top (485 px each), then the rest.
        #expect(summary(e.handle(.mouseMoved(dx: 0, dy: -1000), at: 0).events) == [
            "move[0] 0@1800,55", "up[0] 0@1800,55", "down[0] 0@1800,540",
            "move[0] 0@1800,55", "up[0] 0@1800,55", "down[0] 0@1800,540", "move[0] 0@1800,510",
        ])
    }

    @Test func theFingerTouchesDownAndStartsOverAtTheEyesPoint() {
        var e = engine([eye(Self.tall, origin: NormalizedPoint(0.8, 0.8))], fps: FPSSettings(aimControl: "eye"))
        #expect(summary(e.setPointerLocked(true)) == ["down[0] 0@1920,864"])
        #expect(summary(e.handle(.mouseMoved(dx: 500, dy: 0), at: 0).events)
            == ["move[0] 0@2399,864", "up[0] 0@2399,864", "down[0] 0@1920,864", "move[0] 0@1941,864"])
    }

    @Test func aPointOnTheEdgeOfTheAreaDoesNotTapOnTheSpot() {
        // Hand-written: the point sits on the area's left edge, so the finger cannot go left at all.
        var e = locked(eye(NormalizedRect(0.5, 0, 1, 0.8), origin: NormalizedPoint(0.5, 0.4)))
        #expect(e.handle(.mouseMoved(dx: -50, dy: 0), at: 0).events.isEmpty)
        #expect(e.activeTouchCount == 1)
        #expect(summary(e.handle(.mouseMoved(dx: 10, dy: 0), at: 0.01).events) == ["move[0] 0@1211,432"])
    }

    @Test func aDegenerateAreaIsIgnoredInsteadOfTrapping() {
        // Narrower than the pixel the finger keeps from each edge.
        var e = engine([eye(NormalizedRect(0.5, 0.2, 0.5004, 0.6))], fps: FPSSettings(aimControl: "eye"))
        _ = e.setPointerLocked(true)
        _ = e.handle(.mouseMoved(dx: 30, dy: 30), at: 0)
        #expect(e.activeTouchCount == 1)
    }

    @Test func theDefaultAreaCoversTheRightSideAtFullHeight() throws {
        let area = Control.defaultEyeArea
        #expect(area.isValid)
        #expect(area.height > 0.89)
        #expect(area.minX < 0.5 && area.maxX > 0.95)
        // A new FPS layout's eye uses it, touching down where none of its buttons sits.
        let layout = KeymapTemplate.fps.layout(aspect: 16.0 / 9.0)
        let camera = try #require(layout.controls.first { $0.id == layout.fps?.aimControl })
        #expect(camera.fingerArea == area)
        let point = try #require(camera.touchPoint)
        for control in layout.controls where control.id != camera.id {
            guard case .tap(let p) = control.kind else { continue }
            #expect(hypot((p.x - point.x) * 16 / 9, p.y - point.y) > 0.1, "\(control.id) sits on the eye's point")
        }
    }
}

@Suite struct AnchorReachTests {
    @Test func anAnchorTapStaysWithinItsReach() {
        // Reach 0.2 of the display height: 216 px around 1200,540.
        let wheel = Control(id: "emote", kind: .anchor(NormalizedPoint(0.5, 0.5), radius: 0.2), triggers: [.key(.b)])
        var e = engine([wheel])
        #expect(summary(e.handle(.keyDown(.b), at: 0).events) == ["down[0] 0@1200,540"])
        // Up and right as far as the circle allows, the way the mouse went.
        #expect(summary(e.handle(.pointerMoved(dx: 500, dy: -500), at: 0.1).events) == ["move[0] 0@1353,387"])
        // Clamped, not wound up: moving back moves at once.
        #expect(summary(e.handle(.pointerMoved(dx: -100, dy: 0), at: 0.2).events) == ["move[0] 0@1253,387"])
        #expect(summary(e.handle(.keyUp(.b), at: 0.3).events) == ["up[0] 0@1253,387"])
    }

    @Test func theLockedMouseIsClampedToo() {
        let camera = eye(NormalizedRect(0.5, 0.1, 1, 0.7))
        let wheel = Control(id: "emote", kind: .anchor(NormalizedPoint(0.2, 0.5), radius: 0.1), triggers: [.key(.b)])
        var e = engine([camera, wheel], fps: FPSSettings(aimControl: "eye"))
        _ = e.setPointerLocked(true)
        _ = e.handle(.keyDown(.b), at: 0)
        // Only the anchor (pointer 1) moves, 108 px from 480,540 at most.
        #expect(summary(e.handle(.mouseMoved(dx: 900, dy: 900), at: 0.1).events) == ["move[0] 0@1800,432 1@556,616"])
    }

    @Test func withoutAnAreaTheWholeScreenIsTheLimit() {
        var e = engine([Control(id: "emote", kind: .anchor(NormalizedPoint(0.5, 0.5)), triggers: [.key(.b)])])
        _ = e.handle(.keyDown(.b), at: 0)
        #expect(summary(e.handle(.pointerMoved(dx: -5000, dy: 5000), at: 0.1).events) == ["move[0] 0@0,1079"])
    }
}

@Suite struct FingerAreaProfileTests {
    /// The eye and anchor tap of a profile saved before areas existed (a Delta Force layout).
    static let oldJSON = """
    {"schema": 1, "package": "com.garena.game.df", "name": "My layout",
     "controls": [
       {"id": "eye-1", "type": "aim", "area": [0.5761263643839712, 0.28167649696468, 0.7711981347188995, 0.64167649696468],
        "sensitivity": {"x": 1, "y": 1}, "ads_sensitivity": {"x": 0.6, "y": 0.6}, "exponent": 1, "deadzone": 0,
        "invert_y": false, "stick": "right"},
       {"id": "anchor-1", "type": "anchor", "position": [0.3125, 0.1218716613247863], "size": 0.024157489026492597,
        "triggers": ["key:F"]}
     ],
     "fps": {"aim_control": "eye-1", "cursor_toggle": "key:Grave"}}
    """

    @Test func oldProfilesLoadAndSaveUnchanged() throws {
        let profile = try KeymapProfile.decode(Data(Self.oldJSON.utf8))
        #expect(profile.validate().isEmpty)
        let area = NormalizedRect(0.5761263643839712, 0.28167649696468, 0.7711981347188995, 0.64167649696468)
        #expect(profile.controls[0].kind == .aim(area: area, sensitivity: AxisPair(x: 1, y: 1), adsSensitivity: AxisPair(x: 0.6, y: 0.6),
                                                 exponent: 1, deadzone: 0, invertY: false, stick: .right, origin: nil))
        #expect(profile.controls[0].touchPoint == area.center)
        #expect(profile.controls[1].kind == .anchor(NormalizedPoint(0.3125, 0.1218716613247863), radius: nil))
        #expect(profile.controls[1].fingerArea == nil)
        // Saving writes the same fields back, nothing added.
        let saved = try JSONSerialization.jsonObject(with: profile.encoded()) as? NSDictionary
        let original = try JSONSerialization.jsonObject(with: Data(Self.oldJSON.utf8)) as? NSDictionary
        #expect(saved == original)
    }

    @Test func pointsAndAreasRoundTrip() throws {
        let profile = KeymapProfile(package: "com.example.fps", name: "Areas", controls: [
            eye(EyeAreaTests.tall, origin: NormalizedPoint(0.7, 0.6)),
            Control(id: "emote", kind: .anchor(NormalizedPoint(0.3, 0.2), radius: 0.15), triggers: [.key(.f)]),
        ], fps: FPSSettings(aimControl: "eye"))
        #expect(profile.validate().isEmpty)
        let data = try profile.encoded()
        #expect(try KeymapProfile.decode(data) == profile)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"origin\" : ["))
        #expect(json.contains("\"area\" : ["))
        #expect(json.contains("\"radius\" : 0.15"))
    }

    /// Avo before b64 kept an anchor tap's finger in a rectangle: it becomes the circle as tall.
    @Test func anOldAnchorAreaBecomesACircle() throws {
        let json = """
        {"schema": 1, "package": "x", "name": "x",
         "controls": [{"id": "emote", "type": "anchor", "position": [0.3, 0.2], "area": [0.2, 0.05, 0.45, 0.4], "triggers": ["key:F"]}]}
        """
        let profile = try KeymapProfile.decode(Data(json.utf8))
        guard case let .anchor(point, radius?) = profile.controls[0].kind else {
            Issue.record("no reach")
            return
        }
        #expect(point == NormalizedPoint(0.3, 0.2))
        #expect(abs(radius - 0.175) < 1e-9)
        #expect(profile.validate().isEmpty)
    }

    @Test func unreadableAreasAndPointsFallBackToTheOldBehaviour() throws {
        let json = """
        {"schema": 1, "package": "x", "name": "x",
         "controls": [
           {"id": "eye", "type": "aim", "area": [0.5, 0.1, 1, 0.9], "origin": [0.7]},
           {"id": "emote", "type": "anchor", "position": [0.3, 0.2], "area": "everywhere", "triggers": ["key:F"]}
         ]}
        """
        let profile = try KeymapProfile.decode(Data(json.utf8))
        #expect(profile.controls[0].touchPoint == NormalizedPoint(0.75, 0.5))
        #expect(profile.controls[1].kind == .anchor(NormalizedPoint(0.3, 0.2)))
        #expect(profile.validate().isEmpty)
    }

    @Test func validatesPointsAgainstTheirAreas() {
        let profile = KeymapProfile(package: "x", name: "x", controls: [
            eye(NormalizedRect(0.5, 0.1, 1, 0.9), origin: NormalizedPoint(0.3, 0.5)),
            Control(id: "a", kind: .anchor(NormalizedPoint(0.1, 0.1), radius: 2), triggers: [.key(.f)]),
            Control(id: "b", kind: .anchor(NormalizedPoint(0.3, 0.3), radius: 0.01), triggers: [.key(.g)]),
        ], fps: FPSSettings(aimControl: "eye"))
        let problems = profile.validate()
        #expect(problems.contains("eye: touch-down point must be inside the aim area"))
        #expect(problems.contains("a: anchor reach must be between 0.03 and 1"))
        #expect(problems.contains("b: anchor reach must be between 0.03 and 1"))
        #expect(problems.count == 3)
    }
}

@Suite struct FingerAreaEditingTests {
    @Test func resizingKeepsTheAreaOnTheScreenAndNoSmallerThanTheMinimum() {
        let area = NormalizedRect(0.5, 0.3, 0.8, 0.7)
        // The bottom edge dragged down past the screen stops at its edge.
        #expect(area.resized(.bottom, dx: 0, dy: 0.6, minWidth: 0.1, minHeight: 0.1) == NormalizedRect(0.5, 0.3, 0.8, 1))
        // The top left corner dragged past the opposite corner stops at the minimum size.
        #expect(area.resized([.top, .left], dx: 0.5, dy: 0.5, minWidth: 0.1, minHeight: 0.2)
            == NormalizedRect(0.8 - 0.1, 0.7 - 0.2, 0.8, 0.7))
        // A tiny area against the edge grows away from it to the minimum.
        let tiny = NormalizedRect(0.95, 0, 0.99, 0.02)
        let grown = tiny.resized(.right, dx: 0, dy: 0, minWidth: 0.1, minHeight: 0)
        #expect(close(grown, NormalizedRect(0.9, 0, 1, 0.02)))
    }

    @Test func keyboardResizingGrowsAroundTheCentre() {
        let area = NormalizedRect(0.5, 0.3, 0.8, 0.7)
        let taller = area.grown(dw: 0, dh: 0.2, minWidth: 0.1, minHeight: 0.1)
        #expect(close(taller, NormalizedRect(0.5, 0.2, 0.8, 0.8)))
        // Against the top of the screen it grows downwards only.
        let top = NormalizedRect(0.5, 0, 0.8, 0.4).grown(dw: 0, dh: 0.2, minWidth: 0.1, minHeight: 0.1)
        #expect(close(top, NormalizedRect(0.5, 0, 0.8, 0.6)))
        // Never smaller than the minimum.
        let small = area.grown(dw: -1, dh: -1, minWidth: 0.1, minHeight: 0.2)
        #expect(close(small, NormalizedRect(0.6, 0.4, 0.7, 0.6)))
    }

    @Test func movingAnAreaKeepsItsSizeAndTakesItsPointAlong() {
        var camera = eye(NormalizedRect(0.5, 0.1, 0.9, 0.9), origin: NormalizedPoint(0.7, 0.3))
        camera.moveFinger(dx: 0.3, dy: -0.3)
        // Only as far as the screen allows: 0.1 right, 0.1 up.
        #expect(close(camera.fingerArea, NormalizedRect(0.6, 0, 1, 0.8)))
        #expect(close(camera.touchPoint, NormalizedPoint(0.8, 0.2)))
    }

    @Test func theEyesPointStaysInsideItsArea() {
        var camera = eye(NormalizedRect(0.5, 0.1, 0.9, 0.9))
        camera.setTouchPoint(NormalizedPoint(0.1, 0.95))
        // Inside by a tenth of the area's width and height.
        #expect(close(camera.touchPoint, NormalizedPoint(0.54, 0.82)))
        // A smaller area takes the point along; one at the centre stays at the centre.
        camera.setFingerArea(NormalizedRect(0.6, 0.2, 0.8, 0.6))
        #expect(camera.fingerArea!.contains(camera.touchPoint!))
        camera.setTouchPoint(nil)
        camera.setFingerArea(NormalizedRect(0.5, 0.05, 0.95, 0.95))
        #expect(close(camera.touchPoint, NormalizedPoint(0.725, 0.5)))
    }

    /// The swipe area is the eye's: an anchor tap's reach is a circle (AnchorReachTests).
    @Test func onlyTheEyeHasAFingerArea() {
        var wheel = Control(id: "emote", kind: .anchor(NormalizedPoint(0.3, 0.2), radius: 0.2), triggers: [.key(.f)])
        wheel.setFingerArea(NormalizedRect(0.4, 0.3, 0.8, 0.9))
        wheel.moveFinger(dx: -0.5, dy: 0.1)
        wheel.setTouchPoint(NormalizedPoint(0.9, 0.9))
        #expect(wheel.kind == .anchor(NormalizedPoint(0.3, 0.2), radius: 0.2))
        #expect(wheel.fingerArea == nil)
        #expect(wheel.touchPoint == nil)
    }
}
