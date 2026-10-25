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

private func eye() -> Control {
    Control(id: "eye", kind: .aim(area: NormalizedRect(0.5, 0.1, 1, 0.7), sensitivity: AxisPair(x: 1, y: 1), adsSensitivity: AxisPair(x: 1, y: 1),
                                  exponent: 1, deadzone: 0, invertY: false, stick: nil))
}

/// A map's zoom slider at the right: from the bottom (y 0.8) up to the top
/// (y 0.2), wheel up towards the top, resting halfway, a tenth a notch.
private func zoom(reset: Trigger? = nil, modes: [String]? = nil) -> Control {
    Control(id: "zoom", kind: .scrollBar(from: NormalizedPoint(0.9, 0.8), to: NormalizedPoint(0.9, 0.2), rest: 0.5, step: 0.1),
            modes: modes, reset: reset)
}

@Suite struct ScrollBarTests {
    @Test func aNotchDragsTheThumbAStepAndLetsGoAfterTheWheelStops() {
        let profile = KeymapProfile(package: "x", name: "x", controls: [zoom()])
        #expect(profile.validate().isEmpty)
        var e = engine(profile)
        // Down on the thumb at its rest point (y 0.5 = 540), then part of the way up (a step is 0.06 of the height: 64.8 px).
        let up = e.handle(.scroll(dy: 1), at: 0)
        #expect(up.consumed)
        #expect(summary(up.events) == ["down[0] 0@2160,540", "move[0] 0@2160,511"])
        // The glide carries it to the step's end (475), a few frames on.
        let settled = summary(e.tick(at: 0.01) + e.tick(at: 0.05) + e.tick(at: 0.1)).last ?? ""
        #expect(settled.hasPrefix("move[0] 0@2160,47"), "\(settled)")
        // A second notch soon after: the same finger, further up.
        _ = e.handle(.scroll(dy: 1), at: 0.12)
        _ = e.tick(at: 0.2)
        #expect(e.activeTouchCount == 1)
        // The first notch's release has passed and is ignored; the last one's lets go.
        _ = e.tick(at: 0.25)
        #expect(e.activeTouchCount == 1)
        let lift = summary(e.tick(at: 0.33))
        #expect(lift == ["up[0] 0@2160,410"])
        // The next notch starts from where the thumb was left.
        let down = e.handle(.scroll(dy: -1), at: 1)
        #expect(summary(down.events).first == "down[0] 0@2160,410")
    }

    @Test func theThumbStopsAtTheEndsOfItsTrack() {
        var e = engine(KeymapProfile(package: "x", name: "x", controls: [zoom()]))
        var time = 0.0
        for _ in 0..<5 {
            _ = e.handle(.scroll(dy: 1), at: time)
            time += 0.3
            _ = e.tick(at: time)
        }
        // At the top end (y 0.2 = 216): another notch up touches nothing.
        #expect(e.activeTouchCount == 0)
        #expect(e.handle(.scroll(dy: 1), at: time).events.isEmpty)
        #expect(e.activeTouchCount == 0)
    }

    @Test func itsResetKeyDragsTheThumbBackToItsRestPoint() {
        let profile = KeymapProfile(package: "x", name: "x", controls: [zoom(reset: .key(.z))])
        #expect(profile.validate().isEmpty)
        var e = engine(profile)
        _ = e.handle(.scroll(dy: 1), at: 0)
        _ = e.tick(at: 0.5)
        // Down where the thumb is (one step up), glided back down to rest.
        let reset = e.handle(.keyDown(.z), at: 1)
        #expect(summary(reset.events).first == "down[0] 0@2160,475")
        _ = e.handle(.keyUp(.z), at: 1.05)
        let after = summary(e.tick(at: 1.1) + e.tick(at: 1.3))
        #expect(after.last == "up[0] 0@2160,540")
        // At rest already: nothing to do.
        #expect(e.handle(.keyDown(.z), at: 2).events.isEmpty)
    }

    @Test func aNewModeStartsItsScrollBarsFromRest() {
        let profile = KeymapProfile(package: "x", name: "x", controls: [
            zoom(modes: ["map", "car"]),
            Control(id: "drive", kind: .hotkey, triggers: [.key(.v)], modes: ["map"], actions: [.switchMode("car")]),
        ], modes: [KeymapMode(id: "map", name: "Map"), KeymapMode(id: "car", name: "Car")])
        #expect(profile.validate().isEmpty)
        var e = engine(profile)
        _ = e.handle(.scroll(dy: 1), at: 0)
        _ = e.tick(at: 0.5)
        _ = e.handle(.keyDown(.v), at: 1)
        #expect(e.mode == "car")
        #expect(summary(e.handle(.scroll(dy: 1), at: 2).events).first == "down[0] 0@2160,540")
    }

    @Test func scrollBarsAreValidatedAndRoundTrip() throws {
        let bad = KeymapProfile(package: "x", name: "x", controls: [
            Control(id: "a", kind: .scrollBar(from: NormalizedPoint(0.5, 0.5), to: NormalizedPoint(0.5, 0.51), rest: 0.5, step: 0.1)),
            Control(id: "b", kind: .scrollBar(from: NormalizedPoint(0.5, 0.2), to: NormalizedPoint(0.5, 0.8), rest: 1.5, step: 0.9),
                    reset: .scrollUp),
        ])
        let problems = bad.validate()
        #expect(problems.contains("a: the scroll bar's track is too short"))
        #expect(problems.contains("b: the rest point must be on the track"))
        #expect(problems.contains("b: a step must be 1 to 50% of the track"))
        #expect(problems.contains("b: the wheel cannot reset a scroll bar"))
        let good = KeymapProfile(package: "x", name: "x", controls: [zoom(reset: .key(.z))])
        let data = try good.encoded()
        #expect(String(decoding: data, as: UTF8.self).contains("\"type\" : \"scroll_bar\""))
        #expect(try KeymapProfile.decode(data) == good)
        #expect(zoom().allTriggers == [.scrollUp, .scrollDown])
        #expect(zoom().isVerticalScrollBar)
        #expect(!zoom().canCarryActions && !zoom().canHaveClickZone)
    }
}

@Suite struct ClickZoneTests {
    /// The game's settings button at the top right, on Esc, which also frees
    /// the mouse; clicking the button presses the same Esc, once.
    private func settings(shape: ClickZone.Shape = .rounded) -> Control {
        Control(id: "esc", kind: .tap(NormalizedPoint(0.95, 0.05)), triggers: [.key(.escape)], actions: [.freeMouse],
                clickZone: ClickZone(area: NormalizedRect(0.92, 0, 0.98, 0.1), shape: shape))
    }

    @Test func aClickInTheZonePressesTheControlOnce() {
        let profile = KeymapProfile(package: "x", name: "x", controls: [eye(), settings()],
                                    fps: FPSSettings(aimControl: "eye"))
        #expect(profile.validate().isEmpty)
        var e = engine(profile)
        // The mouse is free: a click on the button is Esc's tap, held as long as the click.
        let down = e.handle(.fingerDown(x: 2280, y: 54), at: 0)
        #expect(down.consumed)
        #expect(summary(down.events) == ["down[0] 0@2280,54"])
        #expect(e.handle(.fingerUp(x: 2280, y: 54), at: 0.1).consumed)
        #expect(e.activeTouchCount == 0)
        // Outside it the click is the game's own finger.
        let other = e.handle(.fingerDown(x: 1000, y: 500), at: 1)
        #expect(summary(other.events) == ["down[0] 0@1000,500"])
        _ = e.handle(.fingerUp(x: 1000, y: 500), at: 1.1)
    }

    @Test func theZoneDoesTheControlsActionsAndHoldsAHoldWhileTheButtonIsDown() {
        let hold = Control(id: "map", kind: .hold(NormalizedPoint(0.1, 0.1)), triggers: [.key(.m)], actions: [.switchMode("map")],
                           clickZone: ClickZone(area: NormalizedRect(0.05, 0.05, 0.15, 0.15)))
        let profile = KeymapProfile(package: "x", name: "x", controls: [hold],
                                    modes: [KeymapMode(id: "foot", name: "Foot"), KeymapMode(id: "map", name: "Map")])
        var e = engine(profile)
        let click = e.handle(.fingerDown(x: 240, y: 108), at: 0)
        #expect(click.mode == "map")
        #expect(summary(click.events) == ["down[0] 0@240,108"])
        _ = e.tick(at: 1)
        #expect(e.activeTouchCount == 1, "held while the button is")
        _ = e.handle(.fingerUp(x: 240, y: 108), at: 1.2)
        #expect(e.activeTouchCount == 0)
    }

    @Test func theZoneRestsWhileTheMouseIsLocked() {
        var e = engine(KeymapProfile(package: "x", name: "x", controls: [eye(), settings()], fps: FPSSettings(aimControl: "eye")))
        _ = e.setPointerLocked(true)
        let click = e.handle(.fingerDown(x: 2280, y: 54), at: 0)
        // Esc's action did not run: the click is the locked mouse's own.
        #expect(click.pointerLock == nil)
        #expect(e.pointerLocked)
    }

    @Test func aZonesShapeIsRoundOnTheScreen() {
        let area = NormalizedRect(0.4, 0.4, 0.6, 0.6)
        let corner = NormalizedPoint(0.401, 0.401), middle = NormalizedPoint(0.5, 0.5), edge = NormalizedPoint(0.5, 0.401)
        #expect(ClickZone(area: area, shape: .rectangle).contains(corner, width: W, height: H))
        #expect(!ClickZone(area: area, shape: .rounded).contains(corner, width: W, height: H))
        #expect(!ClickZone(area: area, shape: .ellipse).contains(corner, width: W, height: H))
        for shape in ClickZone.Shape.allCases {
            #expect(ClickZone(area: area, shape: shape).contains(middle, width: W, height: H))
            #expect(ClickZone(area: area, shape: shape).contains(edge, width: W, height: H))
        }
    }

    @Test func zonesAreValidatedAndRoundTrip() throws {
        let profile = KeymapProfile(package: "x", name: "x", controls: [settings(shape: .ellipse)])
        let data = try profile.encoded()
        #expect(String(decoding: data, as: UTF8.self).contains("\"click_zone\""))
        #expect(try KeymapProfile.decode(data) == profile)
        let bad = KeymapProfile(package: "x", name: "x", controls: [
            Control(id: "j", kind: .dpad(center: NormalizedPoint(0.2, 0.7), radius: 0.1, up: .key(.w), down: .key(.s), left: .key(.a),
                                         right: .key(.d), stick: nil), clickZone: ClickZone(area: NormalizedRect(0.1, 0.6, 0.3, 0.8))),
        ])
        #expect(bad.validate().contains("j: this kind of control cannot be clicked"))
        // A shape from a newer Avo reads as the rounded one.
        let json = Data(#"{"area": [0.1, 0.1, 0.2, 0.2], "shape": "star"}"#.utf8)
        #expect(try JSONDecoder().decode(ClickZone.self, from: json).shape == .rounded)
    }
}
