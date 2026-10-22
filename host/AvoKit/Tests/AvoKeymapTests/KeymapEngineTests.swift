import AvoProtocol
import Foundation
import Testing
@testable import AvoKeymap

/// 2400 x 1080 landscape display.
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

@Suite struct KeymapEngineTests {
    @Test func tapLiftsAfterFortyMilliseconds() {
        var e = engine([Control(id: "jump", kind: .tap(NormalizedPoint(0.5, 0.5)), triggers: [.key(.space)])])
        let down = e.handle(.keyDown(.space), at: 0)
        #expect(down.consumed)
        #expect(summary(down.events) == ["down[0] 0@1200,540"])
        #expect(e.handle(.keyUp(.space), at: 0.01).events.isEmpty) // released early: tap still completes
        #expect(e.tick(at: 0.03).isEmpty)
        #expect(summary(e.tick(at: 0.041)) == ["up[0] 0@1200,540"])
        #expect(e.activeTouchCount == 0)
    }

    @Test func holdsFollowTheKeyAndShareMultitouch() {
        var e = engine([
            Control(id: "fire", kind: .hold(NormalizedPoint(0.8, 0.6)), triggers: [.mouse(.right)]),
            Control(id: "crouch", kind: .hold(NormalizedPoint(0.9, 0.9)), triggers: [.key(.c)]),
        ])
        #expect(summary(e.handle(.mouseDown(.right), at: 0).events) == ["down[0] 0@1920,648"])
        #expect(summary(e.handle(.keyDown(.c), at: 0.1).events) == ["pointerDown[1] 0@1920,648 1@2160,972"])
        // Lifting the first pointer reports its index while both are still listed.
        #expect(summary(e.handle(.mouseUp(.right), at: 0.2).events) == ["pointerUp[0] 0@1920,648 1@2160,972"])
        #expect(summary(e.handle(.keyUp(.c), at: 0.3).events) == ["up[0] 1@2160,972"])
    }

    @Test func anchorTapFollowsTheMouseFromItsPoint() {
        // An emote wheel: hold B, move towards an item, let go.
        var e = engine([Control(id: "emote", kind: .anchor(NormalizedPoint(0.5, 0.5)), triggers: [.key(.b)])])
        #expect(!e.handle(.pointerMoved(dx: 50, dy: 0), at: 0).consumed) // not held: the cursor is free
        #expect(summary(e.handle(.keyDown(.b), at: 0.1).events) == ["down[0] 0@1200,540"])
        let moved = e.handle(.pointerMoved(dx: 120, dy: -80), at: 0.2)
        #expect(moved.consumed)
        #expect(summary(moved.events) == ["move[0] 0@1320,460"])
        // Kept on the screen.
        #expect(summary(e.handle(.pointerMoved(dx: 5000, dy: 0), at: 0.3).events) == ["move[0] 0@2399,460"])
        #expect(summary(e.handle(.keyUp(.b), at: 0.4).events) == ["up[0] 0@2399,460"])
        #expect(e.activeTouchCount == 0)
    }

    @Test func anchorTapTakesTheLockedMouseFromTheCamera() {
        let camera = Control(id: "camera", kind: .aim(area: NormalizedRect(0.5, 0.1, 1, 0.7), sensitivity: AxisPair(x: 1, y: 1),
                                                      adsSensitivity: AxisPair(x: 1, y: 1), exponent: 1, deadzone: 0,
                                                      invertY: false, stick: nil))
        let emote = Control(id: "emote", kind: .anchor(NormalizedPoint(0.2, 0.5)), triggers: [.key(.b)])
        var e = engine([camera, emote], fps: FPSSettings(aimControl: "camera"))
        _ = e.setPointerLocked(true) // the camera touch goes down
        _ = e.handle(.keyDown(.b), at: 0)
        let scale = H / KeymapEngine.referenceHeight
        let events = summary(e.handle(.mouseMoved(dx: 10, dy: 0), at: 0.1).events)
        // Only the anchor (pointer 1) moves; the camera (pointer 0) stays put.
        #expect(events == ["move[0] 0@1800,432 1@\(Int((480 + 10 * scale).rounded())),540"])
    }

    @Test func tapsLastAsLongAsTheirKey() {
        var e = engine([Control(id: "jump", kind: .tap(NormalizedPoint(0.5, 0.5)), triggers: [.key(.space)])])
        #expect(summary(e.handle(.keyDown(.space), at: 0).events) == ["down[0] 0@1200,540"])
        #expect(e.tick(at: 0.5).isEmpty) // still held: a long press
        #expect(summary(e.handle(.keyUp(.space), at: 0.6).events) == ["up[0] 0@1200,540"])
    }

    @Test func leftClickStaysAClickUntilTheMouseIsLocked() {
        let camera = Control(id: "camera", kind: .aim(area: NormalizedRect(0.5, 0.1, 1, 0.7), sensitivity: AxisPair(x: 1, y: 1),
                                                      adsSensitivity: AxisPair(x: 1, y: 1), exponent: 1, deadzone: 0,
                                                      invertY: false, stick: nil))
        let fire = Control(id: "fire", kind: .tap(NormalizedPoint(0.8, 0.8)), triggers: [.mouse(.left)])
        var e = engine([camera, fire], fps: FPSSettings(aimControl: "camera"))
        // Free mouse: the click reaches the game as a normal touch.
        #expect(!e.handle(.mouseDown(.left), at: 0).consumed)
        _ = e.handle(.mouseUp(.left), at: 0.05)
        _ = e.setPointerLocked(true)
        let locked = e.handle(.mouseDown(.left), at: 0.1)
        #expect(locked.consumed)
        #expect(summary(locked.events) == ["pointerDown[1] 0@1800,432 1@1920,864"])
    }

    @Test func unboundKeysPassThrough() {
        var e = engine([Control(id: "jump", kind: .tap(NormalizedPoint(0.5, 0.5)), triggers: [.key(.space)])])
        let output = e.handle(.keyDown(.t), at: 0)
        #expect(!output.consumed && output.events.isEmpty)
    }

    @Test func dpadNormalizesDiagonals() {
        let dpad = Control(id: "move", kind: .dpad(center: NormalizedPoint(0.15, 0.7), radius: 0.1,
                                                    up: .key(.w), down: .key(.s), left: .key(.a), right: .key(.d), stick: .left))
        var e = engine([dpad])
        // Down at the centre, part of the way out at once, then a glide over
        // the next frames (no jump to the edge).
        #expect(summary(e.handle(.keyDown(.w), at: 0).events) == ["down[0] 0@360,756", "move[0] 0@360,707"])
        let glide = (1...30).flatMap { e.tick(at: Double($0) / 120) }
        #expect(glide.count > 3)
        #expect(summary(Array(glide.suffix(1))) == ["move[0] 0@360,648"])
        // Diagonals are normalized: W+D settles at radius·(1/√2, 1/√2).
        _ = e.handle(.keyDown(.d), at: 0.3)
        let diagonal = (37...80).flatMap { e.tick(at: Double($0) / 120) }
        let r = 0.1 * H / 2.squareRoot()
        #expect(summary(Array(diagonal.suffix(1))) == ["move[0] 0@\(Int((360 + r).rounded())),\(Int((756 - r).rounded()))"])
        _ = e.handle(.keyUp(.w), at: 0.7)
        _ = (85...130).flatMap { e.tick(at: Double($0) / 120) }
        #expect(summary(e.handle(.keyUp(.d), at: 1.2).events) == ["up[0] 0@468,756"])

        // The left stick drives the same joystick proportionally.
        let stick = e.handle(.gamepadStick(.left, x: 0, y: 1), at: 1)
        #expect(stick.consumed)
        #expect(summary(stick.events) == ["down[0] 0@360,756", "move[0] 0@360,648"])
        #expect(summary(e.handle(.gamepadStick(.left, x: 0.05, y: 0), at: 1.1).events) == ["up[0] 0@360,648"])
    }

    @Test func swipeInterpolatesOverItsDuration() {
        var e = engine([Control(id: "slide", kind: .swipe(from: NormalizedPoint(0.5, 0.8), to: NormalizedPoint(0.5, 0.4), milliseconds: 80),
                                triggers: [.key(.q)])])
        #expect(summary(e.handle(.keyDown(.q), at: 0).events) == ["down[0] 0@1200,864"])
        let middle = e.tick(at: 0.04)
        #expect(summary(middle) == ["move[0] 0@1200,648"])
        #expect(summary(e.tick(at: 0.2)) == ["move[0] 0@1200,432", "up[0] 0@1200,432"])
    }

    @Test func repeatTapRunsOnlyWhileHeld() {
        var e = engine([Control(id: "collect", kind: .repeatTap(NormalizedPoint(0.5, 0.5), intervalMilliseconds: 100),
                                triggers: [.key(.f)])])
        _ = e.handle(.keyDown(.f), at: 0)
        var downs = 1
        var time = 0.0
        while time < 0.35 {
            time += 0.01
            downs += e.tick(at: time).filter { $0.action == .down }.count
        }
        #expect(downs == 4) // 0, 100, 200, 300 ms
        _ = e.handle(.keyUp(.f), at: 0.35)
        #expect(e.tick(at: 1.0).filter { $0.action == .down }.isEmpty)
    }

    @Test func macroRunsItsTimeline() {
        var e = engine([Control(id: "combo", kind: .macro([.tap(NormalizedPoint(0.1, 0.1)), .wait(milliseconds: 100),
                                                          .hold(NormalizedPoint(0.2, 0.2), milliseconds: 50)]),
                                triggers: [.key(.r)])])
        var log = summary(e.handle(.keyDown(.r), at: 0).events)
        for t in stride(from: 0.01, through: 0.3, by: 0.01) { log += summary(e.tick(at: t)) }
        #expect(log == ["down[0] 0@240,108", "up[0] 0@240,108", "down[0] 0@480,216", "up[0] 0@480,216"])
    }

    @Test func scrollWheelTapsWeaponSlots() {
        var e = engine([
            Control(id: "next", kind: .tap(NormalizedPoint(0.6, 0.9)), triggers: [.scrollDown]),
            Control(id: "prev", kind: .tap(NormalizedPoint(0.4, 0.9)), triggers: [.scrollUp]),
        ])
        #expect(summary(e.handle(.scroll(dy: -1), at: 0).events) == ["down[0] 0@1440,972"])
        #expect(summary(e.handle(.scroll(dy: 1), at: 0.01).events) == ["pointerDown[1] 0@1440,972 1@960,972"])
    }

    @Test func resetLiftsEverything() {
        var e = engine([
            Control(id: "a", kind: .hold(NormalizedPoint(0.1, 0.1)), triggers: [.key(.a)]),
            Control(id: "b", kind: .hold(NormalizedPoint(0.2, 0.2)), triggers: [.key(.b)]),
        ])
        _ = e.handle(.keyDown(.a), at: 0)
        _ = e.handle(.keyDown(.b), at: 0)
        #expect(summary(e.reset()) == ["pointerUp[1] 0@240,108 1@480,216", "up[0] 0@240,108"])
        #expect(e.activeTouchCount == 0)
    }

    @Test func supportsSixteenSimultaneousTouches() {
        let keys: [KeyName] = [.a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p]
        var e = engine(keys.enumerated().map { index, key in
            Control(id: key.rawValue, kind: .hold(NormalizedPoint(Double(index) / 20, 0.5)), triggers: [.key(key)])
        })
        for key in keys { _ = e.handle(.keyDown(key), at: 0) }
        #expect(e.activeTouchCount == 16)
    }
}

@Suite struct FPSModeTests {
    static let aim = Control(id: "camera", kind: .aim(area: NormalizedRect(0.5, 0.0, 1.0, 0.8), sensitivity: AxisPair(x: 1, y: 1),
                                                      adsSensitivity: AxisPair(x: 0.5, y: 0.5), exponent: 1, deadzone: 0,
                                                      invertY: false, stick: .right))
    static let controls = [
        aim,
        Control(id: "fire", kind: .hold(NormalizedPoint(0.85, 0.6)), triggers: [.mouse(.left)], layer: .locked),
        Control(id: "ads", kind: .ads(NormalizedPoint(0.9, 0.4), toggle: false), triggers: [.mouse(.right)], layer: .locked),
        Control(id: "bag", kind: .tap(NormalizedPoint(0.05, 0.05)), triggers: [.key(.tab)], layer: .cursor),
    ]

    private func fpsEngine() -> KeymapEngine {
        engine(Self.controls, fps: FPSSettings(cursorToggle: .key(.option), aimControl: "camera"))
    }

    @Test func pointerLockStartsTheCameraTouchAtTheCentre() {
        var e = fpsEngine()
        #expect(summary(e.setPointerLocked(true)) == ["down[0] 0@1800,432"])
        let moved = e.handle(.mouseMoved(dx: 30, dy: -10), at: 0)
        #expect(moved.consumed)
        #expect(summary(moved.events) == ["move[0] 0@1830,422"])
    }

    @Test func recentersAtTheEdgeAndKeepsTheRemainder() {
        var e = fpsEngine()
        _ = e.setPointerLocked(true)
        // Area x: 1200…2400 (inset 1 px). From 1800, +700 px crosses the edge at 2399.
        let events = summary(e.handle(.mouseMoved(dx: 700, dy: 0), at: 0).events)
        #expect(events == ["move[0] 0@2399,432", "up[0] 0@2399,432", "down[0] 0@1800,432", "move[0] 0@1901,432"])
    }

    @Test func adsSwitchesSensitivity() {
        var e = fpsEngine()
        _ = e.setPointerLocked(true)
        _ = e.handle(.mouseDown(.right), at: 0)
        #expect(e.adsActive)
        let events = e.handle(.mouseMoved(dx: 40, dy: 0), at: 0.1).events
        #expect(events.last?.pointers.first?.x == 1820) // half sensitivity
        _ = e.handle(.mouseUp(.right), at: 0.2)
        #expect(!e.adsActive)
    }

    @Test func fireAndCameraAreSimultaneous() {
        var e = fpsEngine()
        _ = e.setPointerLocked(true)
        let fire = e.handle(.mouseDown(.left), at: 0)
        #expect(summary(fire.events) == ["pointerDown[1] 0@1800,432 1@2040,648"])
        let look = e.handle(.mouseMoved(dx: 10, dy: 10), at: 0.01)
        #expect(summary(look.events) == ["move[0] 0@1810,442 1@2040,648"])
    }

    @Test func cursorToggleSwitchesLayersAndReleasesTheCamera() {
        var e = fpsEngine()
        _ = e.setPointerLocked(true)
        _ = e.handle(.mouseDown(.left), at: 0)
        let toggle = e.handle(.keyDown(.option), at: 0.1)
        #expect(toggle.pointerLock == false)
        #expect(toggle.consumed)
        #expect(!e.pointerLocked)
        #expect(e.activeTouchCount == 0) // camera and fire lifted
        // Releasing the button that fired produces nothing: its touch is already up.
        let release = e.handle(.mouseUp(.left), at: 0.15)
        #expect(release.consumed && release.events.isEmpty)
        // Cursor layer: Tab opens the bag; left click is no longer bound (the host turns it into a direct touch).
        #expect(e.handle(.keyDown(.tab), at: 0.2).consumed)
        #expect(!e.handle(.mouseDown(.left), at: 0.3).consumed)
        #expect(!e.handle(.mouseMoved(dx: 5, dy: 5), at: 0.3).consumed)
        let back = e.handle(.keyDown(.option), at: 0.4)
        #expect(back.pointerLock == true)
        #expect(e.pointerLocked)
    }

    @Test func rightStickAimsWithVelocity() {
        var e = fpsEngine()
        _ = e.setPointerLocked(true)
        _ = e.handle(.gamepadStick(.right, x: 1, y: 0), at: 0)
        _ = e.tick(at: 0)
        let events = e.tick(at: 0.05)
        // Full deflection: 1400 counts/s * 0.05 s = 70 px at 1080p scale.
        #expect(events.last?.pointers.first?.x == 1870)
    }
}

@Suite struct KeymapProfileTests {
    @Test func jsonRoundTrip() throws {
        let profile = KeymapProfile(
            package: "com.example.game", name: "Default", author: "avo",
            controls: FPSModeTests.controls + [
                Control(id: "move", kind: .dpad(center: NormalizedPoint(0.15, 0.7), radius: 0.1, up: .key(.w), down: .key(.s),
                                                left: .key(.a), right: .key(.d), stick: .left)),
                Control(id: "jump", kind: .tap(NormalizedPoint(0.9, 0.7)), triggers: [.key(.space), .gamepad(.a)]),
                Control(id: "slide", kind: .swipe(from: NormalizedPoint(0.3, 0.9), to: NormalizedPoint(0.3, 0.95), milliseconds: 120),
                        triggers: [.key(.z)]),
            ],
            fps: FPSSettings(aimControl: "camera"))
        let data = try profile.encoded()
        #expect(try KeymapProfile.decode(data) == profile)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"type\" : \"dpad\""))
        #expect(json.contains("\"key:Space\""))
        #expect(profile.validate().isEmpty)
    }

    @Test func fpsModeForbidsRapidFireAndRecoilMacros() {
        var profile = KeymapProfile(package: "x", name: "x", controls: FPSModeTests.controls, fps: FPSSettings(aimControl: "camera"))
        profile.controls.append(Control(id: "rapid", kind: .repeatTap(NormalizedPoint(0.85, 0.6), intervalMilliseconds: 60),
                                        triggers: [.mouse(.button4)]))
        profile.controls.append(Control(id: "recoil", kind: .macro([.hold(NormalizedPoint(0.7, 0.5), milliseconds: 100)]),
                                        triggers: [.mouse(.button5)]))
        profile.controls.append(Control(id: "pull", kind: .swipe(from: NormalizedPoint(0.7, 0.3), to: NormalizedPoint(0.7, 0.5), milliseconds: 200),
                                        triggers: [.key(.v)]))
        let problems = profile.validate()
        #expect(problems.contains { $0.hasPrefix("rapid: repeated taps are not allowed in FPS mode") })
        #expect(problems.contains { $0.hasPrefix("recoil: macros are not allowed in FPS mode") })
        #expect(problems.contains { $0.hasPrefix("pull: swipes may not touch the aim area") })
    }

    @Test func detectsConflictsAndBadValues() {
        let profile = KeymapProfile(package: "x", name: "x", controls: [
            Control(id: "a", kind: .tap(NormalizedPoint(0.5, 1.5)), triggers: [.key(.space)]),
            Control(id: "b", kind: .hold(NormalizedPoint(0.5, 0.5)), triggers: [.key(.space)]),
            Control(id: "b", kind: .repeatTap(NormalizedPoint(0.5, 0.5), intervalMilliseconds: 10), triggers: [.key(.f)]),
            Control(id: "c", kind: .hold(NormalizedPoint(0.5, 0.5)), triggers: [.scrollUp]),
        ])
        let problems = profile.validate()
        #expect(problems.contains("a: position 0.5, 1.5 is outside the screen"))
        // A key may press several controls (KeymapModesTests).
        #expect(!problems.contains { $0.contains("bound more than once") })
        #expect(problems.contains("duplicate control id b"))
        #expect(problems.contains("b: repeat interval must be at least 50 ms"))
        #expect(problems.contains("c: scroll triggers only work with tap, swipe, macro, mode switch and mouse lock controls"))
    }

    @Test func layersMayReuseTriggers() {
        let profile = KeymapProfile(package: "x", name: "x", controls: FPSModeTests.controls + [
            Control(id: "map-close", kind: .tap(NormalizedPoint(0.95, 0.05)), triggers: [.mouse(.right)], layer: .cursor),
        ], fps: FPSSettings(aimControl: "camera"))
        #expect(profile.validate().isEmpty)
    }

    @Test func communityProfilesAreValid() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardizedFileURL
        let directory = root.appending(path: "profiles/keymaps")
        // Plus the sample app's profile (guest/samples/hello), which uses every kind of control.
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" } + [root.appending(path: "guest/samples/hello/keymap/com.avodroid.hello.json")]
        #expect(files.count > 1)
        for file in files {
            let profile = try KeymapProfile.decode(Data(contentsOf: file))
            #expect(profile.validate().isEmpty, "\(file.lastPathComponent): \(profile.validate())")
            #expect(file.deletingPathExtension().lastPathComponent == profile.package)
        }
    }

    @Test func keyboardMappingCoversEveryKey() {
        for key in KeyName.allCases {
            let mac = KeyboardMapping.macKeyCode(for: key)
            #expect(mac != nil, "missing mac key code for \(key)")
            #expect(KeyboardMapping.key(forMacKeyCode: mac!) == key)
            #expect(KeyboardMapping.androidKeyCode(for: key) != nil)
        }
        #expect(KeyboardMapping.androidKeyCode(forMacKeyCode: 0x35) == 111) // Esc -> KEYCODE_ESCAPE
    }
}
