import AvoProtocol
import Foundation
import Testing
@testable import AvoKeymap

/// 2400 x 1080 landscape display.
private let W = 2400.0, H = 1080.0

private func profile(_ controls: [Control], fps: FPSSettings? = nil, gamepad: GamepadSettings? = nil) -> KeymapProfile {
    KeymapProfile(package: "com.example.game", name: "Test", controls: controls, fps: fps, gamepad: gamepad)
}

private func summary(_ events: [TouchEvent]) -> [String] {
    events.map { event in
        let pointers = event.pointers.map { "\($0.id)@\(Int($0.x.rounded())),\(Int($0.y.rounded()))" }.joined(separator: " ")
        return "\(event.action)[\(event.actionIndex)] \(pointers)"
    }
}

private let jump = Control(id: "jump", kind: .tap(NormalizedPoint(0.9, 0.7)), triggers: [.key(.space)])
private let move = Control(id: "move", kind: .dpad(center: NormalizedPoint(0.15, 0.7), radius: 0.1, up: .key(.w), down: .key(.s),
                                                   left: .key(.a), right: .key(.d), stick: nil))
private let eye = Control(id: "eye", kind: .aim(area: NormalizedRect(0.5, 0.1, 1, 0.9), sensitivity: AxisPair(x: 1, y: 1),
                                                adsSensitivity: AxisPair(x: 1, y: 1), exponent: 1, deadzone: 0, invertY: false,
                                                stick: nil))

@Suite struct GamepadProfileCodingTests {
    @Test func oldProfilesLoadUnchangedAndSaveWithoutTheNewFields() throws {
        let json = """
        {"schema": 1, "package": "com.example.game", "name": "Old",
         "controls": [
           {"id": "move", "type": "dpad", "center": [0.15, 0.7], "radius": 0.1, "up": "key:W", "down": "key:S",
            "left": "key:A", "right": "key:D", "stick": "left"},
           {"id": "jump", "type": "tap", "position": [0.9, 0.7], "triggers": ["key:Space", "pad:a"]}
         ]}
        """
        let old = try KeymapProfile.decode(Data(json.utf8))
        #expect(old.gamepad == nil)
        #expect(old.gamepadSettings == .standard)
        #expect(old.controls[0].dpadButtons == false)
        #expect(old.validate().isEmpty)
        let saved = String(decoding: try old.encoded(), as: UTF8.self)
        #expect(!saved.contains("gamepad"))
        #expect(!saved.contains("dpad_buttons"))
        #expect(try KeymapProfile.decode(Data(saved.utf8)) == old)
    }

    @Test func controllerSettingsAndPresetsRoundTrip() throws {
        var move = move
        move.dpadButtons = true
        var p = profile([move, jump], gamepad: GamepadSettings(leftStick: StickSettings(deadzone: 0.25, sensitivity: 1.5),
                                                               rightStick: StickSettings(deadzone: 0.05, sensitivity: 2),
                                                               vibration: true))
        try p.bind(.button(.a), to: "jump")
        p.savePreset(named: "Mine")
        let data = try p.encoded()
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"dpad_buttons\" : true"))
        #expect(json.contains("\"left_stick\""))
        #expect(json.contains("\"vibration\" : true"))
        let decoded = try KeymapProfile.decode(data)
        #expect(decoded == p)
        #expect(decoded.gamepad?.presets.first?.bindings["jump"] == GamepadBinding(buttons: [.a]))
        #expect(decoded.validate().isEmpty)
    }

    @Test func aControllerBlockThisVersionCannotReadLeavesTheControls() throws {
        let json = """
        {"schema": 1, "package": "com.example.game", "name": "Newer", "gamepad": {"left_stick": "very soft"},
         "controls": [{"id": "jump", "type": "tap", "position": [0.9, 0.7], "triggers": ["key:Space"]}]}
        """
        let profile = try KeymapProfile.decode(Data(json.utf8))
        #expect(profile.gamepad == nil)
        #expect(profile.controls.map(\.id) == ["jump"])
        // Parts of a preset from a newer Avo are left out, not the preset.
        let preset = try JSONDecoder().decode(GamepadPreset.self, from: Data("""
            {"name": "P", "bindings": {"jump": {"buttons": ["a", "paddle1"], "stick": "middle"}}}
            """.utf8))
        #expect(preset.bindings["jump"] == GamepadBinding(buttons: [.a]))
        #expect(preset.leftStick == .standard)
    }

    @Test func stickSettingsOutsideTheirRangesAreRejected() {
        let wild = profile([jump], gamepad: GamepadSettings(leftStick: StickSettings(deadzone: 0.9, sensitivity: 1),
                                                            rightStick: StickSettings(deadzone: 0.1, sensitivity: 9)))
        let problems = wild.validate()
        #expect(problems.contains("left stick: dead zone must be between 0% and 60%"))
        #expect(problems.contains("right stick: sensitivity must be between 0.25× and 4×"))
        #expect(problems.count == 2)
    }

    @Test func aDPadThatTheDPadButtonsPushListensToThem() {
        var move = move
        move.dpadButtons = true
        let tapOnUp = Control(id: "up", kind: .tap(NormalizedPoint(0.5, 0.5)), triggers: [.gamepad(.dpadUp)])
        #expect(move.allTriggers.contains(.gamepad(.dpadLeft)))
        // A button may press several things, as a key may.
        #expect(profile([move, tapOnUp]).validate().isEmpty)
        #expect(profile([move]).usesGamepad)
    }
}

@Suite struct StickSettingsTests {
    @Test func theDeadZoneIsTakenOutAndTheRestRisesEvenly() {
        let stick = StickSettings(deadzone: 0.2, sensitivity: 1)
        #expect(stick.deflection(x: 0.19, y: 0) == (0, 0))
        #expect(stick.deflection(x: 0, y: -0.2) == (0, 0))
        let half = stick.deflection(x: 0.6, y: 0)
        #expect(abs(half.x - 0.5) < 1e-12 && half.y == 0)
        #expect(stick.deflection(x: 0, y: 1) == (0, 1))
        // Past the rim on a diagonal (square gates): on the rim, same direction.
        let corner = stick.deflection(x: 1, y: 1)
        #expect(abs(hypot(corner.x, corner.y) - 1) < 1e-12)
        #expect(abs(corner.x - corner.y) < 1e-12)
    }

    @Test func sensitivityScalesTheLean() {
        let quick = StickSettings(deadzone: 0, sensitivity: 2)
        #expect(quick.deflection(x: 0.25, y: 0) == (0.5, 0))
        #expect(quick.deflection(x: -1, y: 0) == (-2, 0))
        let soft = StickSettings(deadzone: 0, sensitivity: 0.5)
        #expect(soft.deflection(x: 0, y: 1) == (0, 0.5))
    }

    @Test func noiseIsRest() {
        #expect(StickSettings.standard.deflection(x: .nan, y: 0.5) == (0, 0))
        #expect(StickSettings.standard.deflection(x: .infinity, y: 0) == (0, 0))
    }
}

@Suite struct GamepadEngineTests {
    private func engine(_ p: KeymapProfile) -> KeymapEngine { KeymapEngine(profile: p, displayID: 7, width: W, height: H) }

    @Test func theJoystickFollowsTheProfilesDeadZoneAndSensitivity() {
        var move = move
        move.kind = move.kind.with(stick: .left)
        var e = engine(profile([move], gamepad: GamepadSettings(leftStick: StickSettings(deadzone: 0.5, sensitivity: 2))))
        #expect(e.handle(.gamepadStick(.left, x: 0.45, y: 0), at: 0).events.isEmpty, "inside the dead zone")
        // Three quarters out: half way past the dead zone, times 2 is the rim.
        #expect(summary(e.handle(.gamepadStick(.left, x: 0.75, y: 0), at: 0.1).events) == ["down[0] 0@360,756", "move[0] 0@468,756"])
        #expect(summary(e.handle(.gamepadStick(.left, x: 0.4, y: 0), at: 0.2).events) == ["up[0] 0@468,756"])
    }

    @Test func theDPadPushesAJoystickThatAlsoHasKeys() {
        var move = move
        move.dpadButtons = true
        var e = engine(profile([move]))
        let up = e.handle(.gamepadButton(.dpadUp, pressed: true), at: 0)
        #expect(up.consumed)
        #expect(summary(up.events) == ["down[0] 0@360,756", "move[0] 0@360,707"])
        _ = (1...30).flatMap { e.tick(at: Double($0) / 120) }
        #expect(summary(e.handle(.gamepadButton(.dpadUp, pressed: false), at: 0.3).events) == ["up[0] 0@360,648"])
        // The keys still work.
        #expect(summary(e.handle(.keyDown(.d), at: 0.4).events) == ["down[0] 0@360,756", "move[0] 0@409,756"])
    }

    @Test func aStickCamerasFingerLiftsWhenTheStickRests() {
        var eye = eye
        eye.kind = eye.kind.with(stick: .right)
        var e = engine(profile([eye]))
        _ = e.handle(.gamepadStick(.right, x: 1, y: 0), at: 0)
        _ = e.tick(at: 0)
        #expect(summary(e.tick(at: 0.05)) == ["down[0] 0@1800,540", "move[0] 0@1870,540"])
        _ = e.handle(.gamepadStick(.right, x: 0.05, y: 0), at: 0.06)
        #expect(e.tick(at: 0.1).isEmpty, "a moment's rest keeps the finger down")
        #expect(summary(e.tick(at: 0.21)) == ["up[0] 0@1870,540"])
        #expect(e.activeTouchCount == 0)
        // The next lean touches down at the eye's point again.
        _ = e.handle(.gamepadStick(.right, x: 0, y: 1), at: 0.3)
        // A tenth of a second at most per frame: 140 px up.
        #expect(summary(e.tick(at: 0.35)) == ["down[0] 0@1800,540", "move[0] 0@1800,400"])
    }

    @Test func theLockedMouseKeepsTheCamerasFingerDown() {
        var eye = eye
        eye.kind = eye.kind.with(stick: .right)
        var e = engine(profile([eye], fps: FPSSettings(aimControl: "eye")))
        _ = e.setPointerLocked(true)
        _ = e.handle(.gamepadStick(.right, x: 1, y: 0), at: 0)
        _ = e.tick(at: 0)
        _ = e.tick(at: 0.05)
        _ = e.handle(.gamepadStick(.right, x: 0, y: 0), at: 0.06)
        #expect(e.tick(at: 0.5).isEmpty)
        #expect(e.activeTouchCount == 1)
    }

    @Test func eachChangeOfTheControllerBecomesInput() {
        let before = GamepadReading(pressed: [.a, .leftTrigger], leftX: 0.1)
        let after = GamepadReading(pressed: [.leftTrigger, .y], leftX: 0.1, rightX: 0.5, rightY: -0.25)
        #expect(after.inputs(since: before) == [.gamepadButton(.a, pressed: false), .gamepadButton(.y, pressed: true),
                                                .gamepadStick(.right, x: 0.5, y: -0.25)])
        #expect(after.inputs(since: after).isEmpty)
    }
}

@Suite struct GamepadBindingTests {
    @Test func aButtonBecomesTheControlsControllerButtonAndKeepsItsKey() throws {
        let reload = Control(id: "reload", kind: .tap(NormalizedPoint(0.8, 0.8)), triggers: [.key(.r), .gamepad(.a)])
        var p = profile([jump, reload])
        try p.bind(.button(.a), to: "jump")
        #expect(p.controls[0].triggers == [.key(.space), .gamepad(.a)])
        #expect(p.controls[1].triggers == [.key(.r), .gamepad(.a)], "a button may press several things")
        try p.bind(.button(.b), to: "jump")
        #expect(p.controls[0].triggers == [.key(.space), .gamepad(.b)], "instead of the one it had")
        #expect(p.controls(boundTo: .button(.b)).map(\.id) == ["jump"])
        #expect(p.boundGamepadElements == [.button(.a), .button(.b)])
    }

    @Test func aKeyFromTheKeyboardLeavesTheControllerButton() {
        var control = jump
        control.triggers = [.key(.space), .gamepad(.a)]
        control.setTrigger(.key(.j))
        #expect(control.triggers == [.gamepad(.a), .key(.j)])
        control.setTrigger(.mouse(.right))
        #expect(control.triggers == [.gamepad(.a), .mouse(.right)])
    }

    @Test func eachPartFitsItsKindOfControl() throws {
        var p = profile([jump, move, eye])
        #expect(throws: KeymapProfile.GamepadBindingProblem.unsuitable) { try p.bind(.stick(.left), to: "jump") }
        #expect(throws: KeymapProfile.GamepadBindingProblem.unsuitable) { try p.bind(.button(.a), to: "move") }
        #expect(throws: KeymapProfile.GamepadBindingProblem.unsuitable) { try p.bind(.button(.a), to: "eye") }
        #expect(throws: KeymapProfile.GamepadBindingProblem.unsuitable) { try p.bind(.dpad, to: "eye") }
        #expect(throws: KeymapProfile.GamepadBindingProblem.noSuchControl) { try p.bind(.button(.a), to: "gone") }
        try p.bind(.stick(.left), to: "move")
        try p.bind(.stick(.left), to: "eye")
        #expect(p.controls[1].stick == nil, "a stick drives one control")
        #expect(p.controls[2].stick == .left)
        try p.bind(.dpad, to: "move")
        #expect(p.controls[1].dpadButtons)
        // The d-pad's buttons are in use too: they push the joystick.
        #expect(p.boundGamepadElements == Set([.stick(.left), .dpad] + GamepadElement.dpadButtons.map(GamepadElement.button)))
    }

    /// A button may press several things, a direction or the mouse lock
    /// among them, as a key may; the d-pad steers one joystick at a time.
    @Test func buttonsMayBeSharedButNotTheDPad() throws {
        let padMove = Control(id: "pad-move", kind: .dpad(center: NormalizedPoint(0.2, 0.7), radius: 0.1, up: .gamepad(.dpadUp),
                                                          down: .gamepad(.dpadDown), left: .gamepad(.dpadLeft),
                                                          right: .gamepad(.dpadRight), stick: nil))
        var p = profile([jump, padMove, move, eye], fps: FPSSettings(cursorToggle: .gamepad(.options), aimControl: "eye"))
        try p.bind(.button(.dpadUp), to: "jump")
        #expect(p.controls(boundTo: .button(.dpadUp)).map(\.id) == ["jump", "pad-move"])
        #expect(throws: KeymapProfile.GamepadBindingProblem.heldByDirection(controlID: "pad-move")) { try p.bind(.dpad, to: "move") }
        try p.bind(.button(.options), to: "jump")
        #expect(p.controls[0].gamepadButtons == [.options])
        #expect(p.fps?.cursorToggle == .gamepad(.options))
        try p.bind(.dpad, to: "pad-move") // it is the d-pad already
        #expect(p.validate().isEmpty)
    }

    @Test func placingMakesABoundControlWhereTheButtonWasDropped() throws {
        var p = profile([jump])
        let idPlaced = p.place(.button(.x), as: .tap, at: NormalizedPoint(0.4, 0.3))
        let id = try #require(idPlaced)
        #expect(id == "tap-1")
        let tap = try #require(p.controls.last)
        #expect(tap.kind == .tap(NormalizedPoint(0.4, 0.3)))
        #expect(tap.triggers == [.gamepad(.x)])
        #expect(p.place(.stick(.left), as: .tap, at: NormalizedPoint(0.5, 0.5)) == nil)
        #expect(p.place(.button(.a), as: .camera, at: NormalizedPoint(0.5, 0.5)) == nil)
        #expect(p.validate().isEmpty)
    }

    @Test func aJoystickFromAStickGetsFreeKeysAndFromTheDPadItsButtons() throws {
        var p = profile([move])
        let fromStickPlaced = p.place(.stick(.left), as: .joystick, at: NormalizedPoint(0.3, 0.6))
        let fromStick = try #require(fromStickPlaced)
        guard case let .dpad(_, _, up, _, _, right, stick)? = p.controls.first(where: { $0.id == fromStick })?.kind else {
            Issue.record("not a joystick")
            return
        }
        #expect(up == .key(.up) && right == .key(.right), "WASD is taken")
        #expect(stick == .left)

        let upTap = Control(id: "item", kind: .tap(NormalizedPoint(0.5, 0.2)), triggers: [.gamepad(.dpadUp)])
        p.controls.append(upTap)
        let fromDPadPlaced = p.place(.dpad, as: .joystick, at: NormalizedPoint(0.2, 0.5))
        let fromDPad = try #require(fromDPadPlaced)
        #expect(p.controls.first { $0.id == fromDPad }?.isDPadOfButtons == true)
        #expect(p.controls.first { $0.id == "item" }?.triggers.isEmpty == true, "the d-pad's buttons left the tap")
        #expect(p.place(.dpad, as: .joystick, at: NormalizedPoint(0.6, 0.5)) == nil, "one d-pad")
    }

    @Test func theCameraIsTheLayoutsOneEye() throws {
        var p = profile([eye])
        #expect(p.place(.stick(.right), as: .camera, at: NormalizedPoint(0.2, 0.2)) == "eye")
        #expect(p.controls.count == 1)
        #expect(p.controls[0].stick == .right)
        var empty = profile([])
        let idPlaced = empty.place(.stick(.right), as: .camera, at: NormalizedPoint(0.9, 0.5))
        let id = try #require(idPlaced)
        let area = try #require(empty.controls.first?.fingerArea)
        #expect(id == "eye-1")
        #expect(abs(area.maxX - 1) < 1e-9 && abs(area.width - Control.defaultEyeArea.width) < 1e-9, "kept on the screen")
    }

    @Test func resetTakesTheControllerOffAndItsOwnControlsWithIt() throws {
        var p = profile([jump, move, eye], gamepad: GamepadSettings(leftStick: StickSettings(deadzone: 0.3, sensitivity: 2), vibration: true))
        try p.bind(.button(.a), to: "jump")
        try p.bind(.stick(.left), to: "move")
        try p.bind(.stick(.right), to: "eye")
        _ = p.place(.button(.rightTrigger), as: .tap, at: NormalizedPoint(0.8, 0.5))
        _ = p.place(.dpad, as: .joystick, at: NormalizedPoint(0.3, 0.8))
        p.savePreset(named: "Mine")
        #expect(Set(p.controllerOnlyControls) == ["eye", "tap-1", "move-1"])
        let removed = p.removeGamepadMapping()
        #expect(Set(removed) == ["eye", "tap-1", "move-1"])
        #expect(p.controls.map(\.id) == ["jump", "move"])
        #expect(p.boundGamepadElements.isEmpty)
        #expect(p.controls[0].triggers == [.key(.space)])
        #expect(p.gamepad?.presets.map(\.name) == ["Mine"], "saved presets stay")
        #expect(p.gamepad?.leftStick == .standard && p.gamepad?.vibration == false)
        var plain = profile([jump])
        plain.removeGamepadMapping()
        #expect(plain.gamepad == nil)
    }

    @Test func aPresetBringsBackItsBindingsAndSettings() throws {
        var p = profile([jump, move, eye])
        try p.bind(.button(.a), to: "jump")
        try p.bind(.stick(.left), to: "move")
        try p.bind(.dpad, to: "move")
        p.gamepad = GamepadSettings(rightStick: StickSettings(deadzone: 0.1, sensitivity: 3), vibration: true)
        p.savePreset(named: "Shooter")
        let saved = p.controls

        try p.bind(.button(.b), to: "jump")
        try p.bind(.stick(.left), to: "eye")
        p.gamepad?.rightStick = .standard
        p.gamepad?.vibration = false
        let preset = p.gamepad!.presets[0]
        #expect(p.apply(preset) == 0)
        #expect(p.controls == saved)
        #expect(p.gamepad?.rightStick == StickSettings(deadzone: 0.1, sensitivity: 3))
        #expect(p.gamepad?.vibration == true)

        // A control that is gone is left out.
        p.controls.removeAll { $0.id == "jump" }
        #expect(p.apply(preset) == 1)
        p.savePreset(named: "Shooter")
        #expect(p.gamepad?.presets.count == 1, "saved again under its name")
        p.deletePreset(named: "Shooter")
        #expect(p.gamepad?.presets.isEmpty == true)
    }

    @Test func theShooterLayoutPutsEachControlWhereShootersDo() {
        var p = KeymapProfile(package: "com.example.game", name: "FPS", controls: KeymapTemplate.fps.layout(aspect: 16 / 9).controls)
        p.controls.append(Control(id: "map", kind: .tap(NormalizedPoint(0.9, 0.1)), triggers: [.key(.m)]))
        p.controls.append(Control(id: "tap-7", kind: .tap(NormalizedPoint(0.5, 0.1)), triggers: [.key(.k)]))
        let preset = KeymapTemplate.fps.gamepadPreset(for: p)
        #expect(preset.bindings["move"] == GamepadBinding(stick: .left))
        #expect(preset.bindings["eye"] == GamepadBinding(stick: .right))
        #expect(preset.bindings["fire"] == GamepadBinding(buttons: [.rightTrigger]))
        #expect(preset.bindings["ads"] == GamepadBinding(buttons: [.leftTrigger]))
        #expect(preset.bindings["jump"] == GamepadBinding(buttons: [.a]))
        #expect(preset.bindings["crouch"] == GamepadBinding(buttons: [.b]))
        #expect(preset.bindings["reload"] == GamepadBinding(buttons: [.x]))
        #expect(preset.bindings["map"] == GamepadBinding(buttons: [.options]))
        #expect(preset.bindings["tap-7"] == GamepadBinding(buttons: [.y]), "the first button left")
        #expect(p.apply(preset) == 0)
        #expect(p.validate().isEmpty)
        #expect(p.usesGamepad)
    }

    @Test func everyControlGetsAButtonWhileThereAreButtonsLeft() {
        // No limit on controls: past the controller's buttons the rest keep their keys.
        let many = (1...30).map { Control(id: "tap-\($0)", kind: .tap(NormalizedPoint(0.5, 0.5))) }
        var p = KeymapProfile(package: "x", name: "x", controls: many)
        let preset = KeymapTemplate.platformer.gamepadPreset(for: p)
        #expect(preset.bindings.count == GamepadButton.allCases.count)
        #expect(p.apply(preset) == 0)
        #expect(p.controls.count == 30)
    }
}

@Suite struct GamepadLayoutTests {
    @Test func theProductCategoryNamesTheLayout() {
        #expect(GamepadLayout(productCategory: "DualSense") == .playStation)
        #expect(GamepadLayout(productCategory: "DualShock 4") == .playStation)
        #expect(GamepadLayout(productCategory: "Xbox One") == .xbox)
        #expect(GamepadLayout(productCategory: "Switch Pro Controller") == .nintendo)
        #expect(GamepadLayout(productCategory: "Nintendo Switch Joy-Con (L/R)") == .nintendo)
        #expect(GamepadLayout(productCategory: "MFi") == .generic)
        #expect(GamepadLayout(productCategory: "HID") == .generic)
    }

    @Test func legendsFollowTheController() {
        #expect(GamepadLayout.xbox.label(.a) == "A")
        #expect(GamepadLayout.playStation.label(.a) == "✕")
        #expect(GamepadLayout.playStation.label(.rightTrigger) == "R2")
        #expect(GamepadLayout.nintendo.label(.a) == "B", "by place: the bottom button")
        #expect(GamepadLayout.nintendo.symbol(.b) == "a.circle")
        #expect(GamepadLayout.xbox.symbol(.leftShoulder, pressed: true) == "lb.button.roundedbottom.horizontal.fill")
        for layout in GamepadLayout.allCases {
            let labels = GamepadButton.allCases.map(layout.label)
            #expect(Set(labels).count == labels.count, "\(layout): every button reads differently")
        }
    }

    @Test func theDiagramHasEveryPartOnceInsideTheDrawing() {
        let bindable = GamepadButton.allCases.filter { $0 != .leftThumbstick && $0 != .rightThumbstick }.map(GamepadElement.button)
            + GamepadStick.allCases.map(GamepadElement.stick) + [.dpad]
        let bounds = CGRect(origin: .zero, size: GamepadDiagram.size)
        for layout in GamepadLayout.allCases {
            let diagram = GamepadDiagram(layout: layout)
            #expect(Set(diagram.spots.map(\.element)) == Set(bindable), "\(layout)")
            #expect(diagram.spots.count == bindable.count)
            for spot in diagram.spots {
                #expect(bounds.contains(spot.frame), "\(layout) \(spot.element)")
                #expect(diagram.element(at: CGPoint(x: spot.frame.midX, y: spot.frame.midY)) == spot.element)
                for other in diagram.spots where other.element != spot.element {
                    #expect(!spot.frame.intersects(other.frame), "\(layout): \(spot.element) and \(other.element) overlap")
                }
            }
            #expect(diagram.element(at: CGPoint(x: 1, y: 199)) == nil)
        }
    }

    @Test func placementsFitTheirParts() {
        for element in [GamepadElement.button(.a), .button(.leftTrigger), .stick(.left), .stick(.right), .dpad] {
            let choices = GamepadPlacement.choices(for: element)
            #expect(!choices.isEmpty)
            #expect(choices.allSatisfy { $0.fits(element) }, "\(element)")
        }
        #expect(GamepadPlacement.choices(for: .stick(.right)).first == .camera)
        #expect(GamepadPlacement.choices(for: .button(.leftTrigger)).first == .ads)
    }
}
