import Foundation

// The controller side of a key mapping, for the controller editor (the
// Controller panel of KeymapEditorView in the Window Host): what a control
// can be bound to, how each kind of controller labels its buttons, where the
// panel's diagram draws them, the sticks' dead zones and sensitivity, and the
// controller presets a game keeps in its profile.

// MARK: - Elements

/// A part of a game controller that the editor binds: a button, a stick, or
/// the d-pad's four buttons together (a joystick of their own).
public enum GamepadElement: Hashable, Sendable {
    case button(GamepadButton)
    case stick(GamepadStick)
    case dpad

    /// The d-pad's buttons in a D-pad control's order of directions: up, down, left, right.
    public static let dpadButtons: [GamepadButton] = [.dpadUp, .dpadDown, .dpadLeft, .dpadRight]

    /// The stick whose press is `button` (L3, R3).
    public static func stick(pressedBy button: GamepadButton) -> GamepadStick? {
        switch button {
        case .leftThumbstick: .left
        case .rightThumbstick: .right
        default: nil
        }
    }

    /// The button that presses `stick` down.
    public static func pressButton(of stick: GamepadStick) -> GamepadButton {
        stick == .left ? .leftThumbstick : .rightThumbstick
    }
}

// MARK: - Layouts and labels

/// How a kind of controller is laid out and labelled. GameController names
/// buttons by place (`buttonA` is the bottom face button on every
/// controller), so one binding fits every controller: only the legends and
/// the diagram differ.
public enum GamepadLayout: String, CaseIterable, Sendable {
    case xbox, playStation, nintendo, generic

    /// The layout of a controller with this GCController.productCategory
    /// ("Xbox One", "DualSense", "DualShock 4", "Switch Pro Controller", "MFi", "HID").
    public init(productCategory: String) {
        let category = productCategory.lowercased()
        if ["dualsense", "dualshock", "playstation", "ps4", "ps5"].contains(where: category.contains) {
            self = .playStation
        } else if category.contains("xbox") {
            self = .xbox
        } else if ["switch", "joy-con", "nintendo"].contains(where: category.contains) {
            self = .nintendo
        } else {
            self = .generic
        }
    }

    /// A button's legend as the controller prints it: "A", "✕", "LB", "L2", "ZL", "D↑".
    public func label(_ button: GamepadButton) -> String {
        switch button {
        case .dpadUp: return "D↑"
        case .dpadDown: return "D↓"
        case .dpadLeft: return "D←"
        case .dpadRight: return "D→"
        case .leftThumbstick: return "L3"
        case .rightThumbstick: return "R3"
        default: break
        }
        switch self {
        case .xbox, .generic:
            switch button {
            case .a: return "A"
            case .b: return "B"
            case .x: return "X"
            case .y: return "Y"
            case .leftShoulder: return "LB"
            case .rightShoulder: return "RB"
            case .leftTrigger: return "LT"
            case .rightTrigger: return "RT"
            case .menu: return "Menu"
            default: return "View"
            }
        case .playStation:
            switch button {
            case .a: return "✕"
            case .b: return "○"
            case .x: return "□"
            case .y: return "△"
            case .leftShoulder: return "L1"
            case .rightShoulder: return "R1"
            case .leftTrigger: return "L2"
            case .rightTrigger: return "R2"
            case .menu: return "Options"
            default: return "Create"
            }
        case .nintendo:
            // By place: the bottom button is B on a Nintendo controller.
            switch button {
            case .a: return "B"
            case .b: return "A"
            case .x: return "Y"
            case .y: return "X"
            case .leftShoulder: return "L"
            case .rightShoulder: return "R"
            case .leftTrigger: return "ZL"
            case .rightTrigger: return "ZR"
            case .menu: return "+"
            default: return "−"
            }
        }
    }

    /// A stick's legend: "LS", "RS".
    public func label(_ stick: GamepadStick) -> String {
        stick == .left ? "LS" : "RS"
    }

    /// SF Symbols' game controller glyph for the button on this layout;
    /// `pressed` fills it.
    public func symbol(_ button: GamepadButton, pressed: Bool = false) -> String {
        let fill = pressed ? ".fill" : ""
        switch button {
        case .dpadUp: return "dpad.up.filled"
        case .dpadDown: return "dpad.down.filled"
        case .dpadLeft: return "dpad.left.filled"
        case .dpadRight: return "dpad.right.filled"
        case .leftThumbstick: return "l.joystick.press.down" + fill
        case .rightThumbstick: return "r.joystick.press.down" + fill
        default: break
        }
        let name: String
        switch (self, button) {
        case (.playStation, .a): name = "xmark.circle"
        case (.playStation, .b): name = "circle.circle"
        case (.playStation, .x): name = "square.circle"
        case (.playStation, .y): name = "triangle.circle"
        case (.nintendo, .a): name = "b.circle"
        case (.nintendo, .b): name = "a.circle"
        case (.nintendo, .x): name = "y.circle"
        case (.nintendo, .y): name = "x.circle"
        case (_, .a): name = "a.circle"
        case (_, .b): name = "b.circle"
        case (_, .x): name = "x.circle"
        case (_, .y): name = "y.circle"
        case (.playStation, .leftShoulder): name = "l1.button.roundedbottom.horizontal"
        case (.playStation, .rightShoulder): name = "r1.button.roundedbottom.horizontal"
        case (.playStation, .leftTrigger): name = "l2.button.roundedtop.horizontal"
        case (.playStation, .rightTrigger): name = "r2.button.roundedtop.horizontal"
        case (.nintendo, .leftShoulder): name = "l.button.roundedbottom.horizontal"
        case (.nintendo, .rightShoulder): name = "r.button.roundedbottom.horizontal"
        case (.nintendo, .leftTrigger): name = "zl.button.roundedtop.horizontal"
        case (.nintendo, .rightTrigger): name = "zr.button.roundedtop.horizontal"
        case (_, .leftShoulder): name = "lb.button.roundedbottom.horizontal"
        case (_, .rightShoulder): name = "rb.button.roundedbottom.horizontal"
        case (_, .leftTrigger): name = "lt.button.roundedtop.horizontal"
        case (_, .rightTrigger): name = "rt.button.roundedtop.horizontal"
        case (.nintendo, .menu): name = "plus.circle"
        case (.nintendo, _): name = "minus.circle"
        case (_, .menu): name = "line.3.horizontal.circle"
        default: name = "rectangle.on.rectangle.circle"
        }
        return name + fill
    }

    /// SF Symbols' glyph for a stick, `pressed` (pushed off centre) filled.
    public func symbol(_ stick: GamepadStick, pressed: Bool = false) -> String {
        (stick == .left ? "l.joystick" : "r.joystick") + (pressed ? ".fill" : "")
    }

    /// The controller's emblem: the Xbox or PlayStation logo, else a controller.
    public var logoSymbol: String {
        switch self {
        case .xbox: "logo.xbox"
        case .playStation: "logo.playstation"
        case .nintendo, .generic: "gamecontroller.fill"
        }
    }
}

// MARK: - The diagram

/// Where the controller editor's diagram draws each part of a controller of
/// `layout`, in a drawing of `GamepadDiagram.size` with y down. The Window
/// Host draws and hit-tests from this one table.
public struct GamepadDiagram: Sendable {
    public static let size = CGSize(width: 320, height: 200)

    public enum Shape: Sendable, Equatable {
        /// A face button, Menu or View.
        case round
        /// A thumbstick: moving it is the stick, pressing it L3 or R3.
        case stick
        case shoulder
        case trigger
        /// One arm of the d-pad's cross.
        case dpadArm
        /// The middle of the d-pad's cross: the four buttons together.
        case dpadCenter
    }

    public struct Spot: Sendable, Equatable {
        public let element: GamepadElement
        public let frame: CGRect
        public let shape: Shape
    }

    /// Parts that are drawn but bind nothing: macOS keeps the Home button
    /// for itself, and the PlayStation touchpad is no button here.
    public enum Decoration: Sendable, Equatable {
        case home(CGRect)
        case touchpad(CGRect)
    }

    public let layout: GamepadLayout
    public let spots: [Spot]
    public let decorations: [Decoration]

    public init(layout: GamepadLayout) {
        self.layout = layout
        func at(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
            CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
        }
        var spots: [Spot] = [
            Spot(element: .button(.leftTrigger), frame: at(70, 16, 46, 20), shape: .trigger),
            Spot(element: .button(.rightTrigger), frame: at(250, 16, 46, 20), shape: .trigger),
            Spot(element: .button(.leftShoulder), frame: at(74, 40, 58, 14), shape: .shoulder),
            Spot(element: .button(.rightShoulder), frame: at(246, 40, 58, 14), shape: .shoulder),
        ]
        func cross(_ x: Double, _ y: Double) {
            let arm = 14.0, step = 15.0
            spots += [
                Spot(element: .button(.dpadUp), frame: at(x, y - step, arm, arm), shape: .dpadArm),
                Spot(element: .button(.dpadDown), frame: at(x, y + step, arm, arm), shape: .dpadArm),
                Spot(element: .button(.dpadLeft), frame: at(x - step, y, arm, arm), shape: .dpadArm),
                Spot(element: .button(.dpadRight), frame: at(x + step, y, arm, arm), shape: .dpadArm),
                Spot(element: .dpad, frame: at(x, y, arm, arm), shape: .dpadCenter),
            ]
        }
        func face(_ x: Double, _ y: Double) {
            let d = 18.0, step = 18.0
            spots += [
                Spot(element: .button(.y), frame: at(x, y - step, d, d), shape: .round),
                Spot(element: .button(.x), frame: at(x - step, y, d, d), shape: .round),
                Spot(element: .button(.b), frame: at(x + step, y, d, d), shape: .round),
                Spot(element: .button(.a), frame: at(x, y + step, d, d), shape: .round),
            ]
        }
        switch layout {
        case .playStation:
            // The d-pad and face buttons on top, both sticks below them.
            cross(88, 94)
            face(232, 94)
            spots += [
                Spot(element: .stick(.left), frame: at(122, 142, 36, 36), shape: .stick),
                Spot(element: .stick(.right), frame: at(198, 142, 36, 36), shape: .stick),
                Spot(element: .button(.options), frame: at(110, 64, 12, 16), shape: .round),
                Spot(element: .button(.menu), frame: at(210, 64, 12, 16), shape: .round),
            ]
            decorations = [.touchpad(at(160, 80, 62, 36)), .home(at(160, 142, 14, 14))]
        case .xbox, .nintendo, .generic:
            // Offset sticks: the left one above the d-pad, the right one below the face buttons.
            cross(124, 136)
            face(230, 92)
            spots += [
                Spot(element: .stick(.left), frame: at(92, 92, 38, 38), shape: .stick),
                Spot(element: .stick(.right), frame: at(196, 136, 38, 38), shape: .stick),
                Spot(element: .button(.options), frame: at(140, 92, 15, 15), shape: .round),
                Spot(element: .button(.menu), frame: at(180, 92, 15, 15), shape: .round),
            ]
            decorations = [.home(at(160, 68, 17, 17))]
        }
        self.spots = spots
    }

    /// The part under `point` (in the drawing), a few points of slack
    /// around each; the closest one where two reach.
    public func element(at point: CGPoint) -> GamepadElement? {
        spots.filter { $0.frame.insetBy(dx: -3, dy: -3).contains(point) }
            .min { distance($0.frame, point) < distance($1.frame, point) }?.element
    }

    public func spot(for element: GamepadElement) -> Spot? {
        spots.first { $0.element == element }
    }

    private func distance(_ frame: CGRect, _ point: CGPoint) -> Double {
        hypot(frame.midX - point.x, frame.midY - point.y)
    }
}

// MARK: - Sticks

/// How a stick acts: its dead zone and sensitivity.
public struct StickSettings: Hashable, Sendable, Codable {
    /// How far the stick may lean before it does anything, as a fraction of
    /// its travel: a worn stick's drift stays out of the game.
    public var deadzone: Double
    /// How strongly the stick acts: above 1 a joystick reaches its rim (and
    /// the camera turns its fastest) with less of a lean.
    public var sensitivity: Double

    public static let standard = StickSettings(deadzone: 0.15, sensitivity: 1)
    public static let deadzoneRange = 0.0...0.6
    public static let sensitivityRange = 0.25...4.0

    public init(deadzone: Double = StickSettings.standard.deadzone, sensitivity: Double = StickSettings.standard.sensitivity) {
        self.deadzone = deadzone
        self.sensitivity = sensitivity
    }

    private enum CodingKeys: String, CodingKey { case deadzone, sensitivity }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deadzone = try c.decodeIfPresent(Double.self, forKey: .deadzone) ?? Self.standard.deadzone
        sensitivity = try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? Self.standard.sensitivity
    }

    /// Where the stick points once the dead zone is taken out, in the same
    /// direction: nothing inside it, then from 0 at its edge rising evenly
    /// to 1 at the rim (a stick that reports past its rim on a diagonal
    /// counts as on it), times the sensitivity.
    public func deflection(x: Double, y: Double) -> (x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return (0, 0) }
        let magnitude = hypot(x, y)
        let deadzone = min(max(deadzone, 0), 0.95)
        guard magnitude > deadzone else { return (0, 0) }
        let travel = (min(magnitude, 1) - deadzone) / (1 - deadzone)
        let scale = travel * max(sensitivity, 0) / magnitude
        return (x * scale, y * scale)
    }
}

// MARK: - A profile's controller settings

/// A profile's controller settings (`"gamepad"` in its JSON): the sticks,
/// vibration, and the controller presets saved for this game. Every part is
/// optional in the file, and versions of Avo before it ignore the block.
public struct GamepadSettings: Hashable, Sendable, Codable {
    public var leftStick: StickSettings
    public var rightStick: StickSettings
    /// A light pulse on the controller when one of its buttons touches the
    /// screen, on controllers that can vibrate.
    public var vibration: Bool
    /// Controller layouts saved for this game, to switch between.
    public var presets: [GamepadPreset]

    public static let standard = GamepadSettings()

    public init(leftStick: StickSettings = .standard, rightStick: StickSettings = .standard, vibration: Bool = false,
                presets: [GamepadPreset] = []) {
        self.leftStick = leftStick
        self.rightStick = rightStick
        self.vibration = vibration
        self.presets = presets
    }

    public subscript(stick: GamepadStick) -> StickSettings {
        get { stick == .left ? leftStick : rightStick }
        set {
            if stick == .left { leftStick = newValue } else { rightStick = newValue }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case leftStick = "left_stick", rightStick = "right_stick", vibration, presets
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        leftStick = try c.decodeIfPresent(StickSettings.self, forKey: .leftStick) ?? .standard
        rightStick = try c.decodeIfPresent(StickSettings.self, forKey: .rightStick) ?? .standard
        vibration = try c.decodeIfPresent(Bool.self, forKey: .vibration) ?? false
        presets = try c.decodeIfPresent([GamepadPreset].self, forKey: .presets) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(leftStick, forKey: .leftStick)
        try c.encode(rightStick, forKey: .rightStick)
        try c.encode(vibration, forKey: .vibration)
        if !presets.isEmpty { try c.encode(presets, forKey: .presets) }
    }

    /// Problems that stop the profile from loading.
    func validate() -> [String] {
        var problems: [String] = []
        let lowest = Int(StickSettings.deadzoneRange.lowerBound * 100), highest = Int(StickSettings.deadzoneRange.upperBound * 100)
        let sticks = [(leftStick, String(localized: "left stick: dead zone must be between \(lowest)% and \(highest)%", bundle: .avoKit),
                       String(localized: "left stick: sensitivity must be between 0.25× and 4×", bundle: .avoKit)),
                      (rightStick, String(localized: "right stick: dead zone must be between \(lowest)% and \(highest)%", bundle: .avoKit),
                       String(localized: "right stick: sensitivity must be between 0.25× and 4×", bundle: .avoKit))]
        for (stick, deadzone, sensitivity) in sticks {
            if !StickSettings.deadzoneRange.contains(stick.deadzone) { problems.append(deadzone) }
            if !StickSettings.sensitivityRange.contains(stick.sensitivity) { problems.append(sensitivity) }
        }
        return problems
    }
}

/// One saved controller layout of a game: what the controller drives, by
/// control id, and how its sticks and vibration were set.
public struct GamepadPreset: Hashable, Sendable, Codable, Identifiable {
    public var name: String
    public var bindings: [String: GamepadBinding]
    public var leftStick: StickSettings
    public var rightStick: StickSettings
    public var vibration: Bool

    public var id: String { name }

    public init(name: String, bindings: [String: GamepadBinding], leftStick: StickSettings = .standard,
                rightStick: StickSettings = .standard, vibration: Bool = false) {
        self.name = name
        self.bindings = bindings
        self.leftStick = leftStick
        self.rightStick = rightStick
        self.vibration = vibration
    }

    private enum CodingKeys: String, CodingKey {
        case name, bindings, leftStick = "left_stick", rightStick = "right_stick", vibration
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        bindings = try c.decodeIfPresent([String: GamepadBinding].self, forKey: .bindings) ?? [:]
        leftStick = try c.decodeIfPresent(StickSettings.self, forKey: .leftStick) ?? .standard
        rightStick = try c.decodeIfPresent(StickSettings.self, forKey: .rightStick) ?? .standard
        vibration = try c.decodeIfPresent(Bool.self, forKey: .vibration) ?? false
    }
}

/// What the controller drives on one control: its controller buttons, the
/// stick on a joystick or the camera, and whether the d-pad pushes a joystick.
public struct GamepadBinding: Hashable, Sendable, Codable {
    public var buttons: [GamepadButton]
    public var stick: GamepadStick?
    public var dpad: Bool

    public init(buttons: [GamepadButton] = [], stick: GamepadStick? = nil, dpad: Bool = false) {
        self.buttons = buttons
        self.stick = stick
        self.dpad = dpad
    }

    public var isEmpty: Bool { buttons.isEmpty && stick == nil && !dpad }

    private enum CodingKeys: String, CodingKey { case buttons, stick, dpad }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A button from a newer Avo is left out, not the whole preset.
        let names = try c.decodeIfPresent([String].self, forKey: .buttons) ?? []
        buttons = names.compactMap(GamepadButton.init(rawValue:))
        stick = try? c.decodeIfPresent(GamepadStick.self, forKey: .stick)
        dpad = try c.decodeIfPresent(Bool.self, forKey: .dpad) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !buttons.isEmpty { try c.encode(buttons, forKey: .buttons) }
        try c.encodeIfPresent(stick, forKey: .stick)
        if dpad { try c.encode(true, forKey: .dpad) }
    }
}

extension KeymapProfile {
    /// The controller settings in use: the profile's, else the standard ones.
    public var gamepadSettings: GamepadSettings { gamepad ?? .standard }
}

// MARK: - Binding

extension Control {
    /// The controller buttons among the control's triggers.
    public var gamepadButtons: [GamepadButton] {
        triggers.compactMap { if case .gamepad(let button) = $0 { button } else { nil } }
    }

    /// A D-pad control whose four directions are the controller's d-pad.
    public var isDPadOfButtons: Bool {
        guard case let .dpad(_, _, up, down, left, right, _) = kind else { return false }
        return [up, down, left, right] == GamepadElement.dpadButtons.map(Trigger.gamepad)
    }

    /// Whether `element` can drive this kind of control: a stick a joystick
    /// or the camera, the d-pad a joystick, a button anything it presses.
    public func accepts(_ element: GamepadElement) -> Bool {
        switch (element, kind) {
        case (.stick, .dpad), (.stick, .aim), (.dpad, .dpad): true
        case (.button, .dpad), (.button, .aim), (.button, .clickArea), (.stick, _), (.dpad, _): false
        case (.button, _): true
        }
    }

    /// Whether `element` drives this control now.
    public func uses(_ element: GamepadElement) -> Bool {
        switch element {
        case .button(let button): allTriggers.contains(.gamepad(button))
        case .stick(let stick): self.stick == stick
        case .dpad: dpadButtons || isDPadOfButtons
        }
    }

    /// Sets the control's keyboard or mouse trigger (`trigger` from the
    /// keyboard or mouse) or its controller button, keeping the other kind:
    /// a control may answer one key and one controller button.
    public mutating func setTrigger(_ trigger: Trigger) {
        triggers.removeAll { $0.isGamepad == trigger.isGamepad }
        triggers.append(trigger)
    }
}

extension KeymapProfile {
    /// Why `bind(_:to:)` did not bind.
    public enum GamepadBindingProblem: Error, Equatable, Sendable {
        case noSuchControl
        /// A stick on a button, or a button on a joystick or the camera.
        case unsuitable
        /// A D-pad control's direction, which cannot be left empty, uses it.
        case heldByDirection(controlID: String)
    }

    /// Whether `a` and `b` act at the same time: in a mode they both
    /// belong to (always, without modes).
    public func sharesMode(_ a: Control, _ b: Control) -> Bool {
        guard !modes.isEmpty, let first = a.modes, let second = b.modes else { return true }
        return !Set(first).isDisjoint(with: second)
    }

    /// The controls `element` drives.
    public func controls(boundTo element: GamepadElement) -> [Control] {
        controls.filter { $0.uses(element) }
    }

    /// Every part of the controller that drives something.
    public var boundGamepadElements: Set<GamepadElement> {
        var elements = Set<GamepadElement>()
        for control in controls {
            for button in GamepadButton.allCases where control.allTriggers.contains(.gamepad(button)) { elements.insert(.button(button)) }
            if let stick = control.stick { elements.insert(.stick(stick)) }
            if control.dpadButtons || control.isDPadOfButtons { elements.insert(.dpad) }
        }
        if case .gamepad(let button)? = fps?.cursorToggle { elements.insert(.button(button)) }
        return elements
    }

    /// Binds `element` to the control `id`: a button becomes its controller
    /// button (instead of the one it had), a stick drives its joystick or
    /// camera, the d-pad pushes its joystick too. A button may press several
    /// controls, as a key may (the game's Enter vehicle button and a switch
    /// to the vehicle mode); a stick or the d-pad steers one joystick or
    /// camera at a time, so it leaves the others of the control's modes
    /// (on foot and in a vehicle, one stick may steer both).
    public mutating func bind(_ element: GamepadElement, to id: String) throws(GamepadBindingProblem) {
        guard let index = controls.firstIndex(where: { $0.id == id }) else { throw .noSuchControl }
        guard controls[index].accepts(element) else { throw .unsuitable }
        let target = controls[index]
        switch element {
        case .button(let button):
            controls[index].setTrigger(.gamepad(button))
        case .stick(let stick):
            for i in controls.indices where i != index && controls[i].stick == stick && sharesMode(controls[i], target) {
                controls[i].kind = controls[i].kind.with(stick: nil)
            }
            controls[index].kind = target.kind.with(stick: stick)
        case .dpad:
            if target.isDPadOfButtons { return }
            if let holder = directionHolder(of: GamepadElement.dpadButtons, except: id, beside: target) {
                throw .heldByDirection(controlID: holder)
            }
            for i in controls.indices where i != index && sharesMode(controls[i], target) {
                controls[i].dpadButtons = false
                for button in GamepadElement.dpadButtons { controls[i].triggers.removeAll { $0 == .gamepad(button) } }
            }
            controls[index].dpadButtons = true
        }
    }

    /// Takes `element` off every control that it can leave (a D-pad
    /// control's directions stay: they cannot be empty).
    public mutating func unbind(_ element: GamepadElement) {
        for i in controls.indices {
            switch element {
            case .button(let button):
                controls[i].triggers.removeAll { $0 == .gamepad(button) }
                if GamepadElement.dpadButtons.contains(button) { controls[i].dpadButtons = false }
                if controls[i].run?.trigger == .gamepad(button) { controls[i].run = nil }
            case .stick(let stick):
                if controls[i].stick == stick { controls[i].kind = controls[i].kind.with(stick: nil) }
            case .dpad:
                controls[i].dpadButtons = false
                for button in GamepadElement.dpadButtons { controls[i].triggers.removeAll { $0 == .gamepad(button) } }
            }
        }
    }

    /// The D-pad control (other than `id`, and acting beside `control` when
    /// given) whose directions use one of `buttons`.
    private func directionHolder(of buttons: [GamepadButton], except id: String, beside control: Control? = nil) -> String? {
        controls.first { other in
            guard other.id != id, case let .dpad(_, _, up, down, left, right, _) = other.kind else { return false }
            if let control, !sharesMode(other, control) { return false }
            return [up, down, left, right].contains { trigger in buttons.contains { trigger == .gamepad($0) } }
        }?.id
    }

    /// The controls that only the controller works: nothing on the keyboard
    /// or mouse presses them, or an eye that a stick drives and the mouse
    /// does not (no FPS mode for it).
    public var controllerOnlyControls: [String] {
        controls.filter { control in
            switch control.kind {
            case .dpad: control.isDPadOfButtons
            case .aim: control.stick != nil && fps?.aimControl != control.id
            default: !control.triggers.isEmpty && control.triggers.allSatisfy(\.isGamepad)
            }
        }.map(\.id)
    }

    /// Takes the controller off the layout: every control's controller
    /// buttons, sticks and d-pad, and the controls that only the controller
    /// worked (their ids are returned). The stick settings go back to the
    /// standard ones; the saved presets stay.
    @discardableResult
    public mutating func removeGamepadMapping() -> [String] {
        let removed = controllerOnlyControls
        controls.removeAll { removed.contains($0.id) }
        for element in [GamepadElement.dpad] + GamepadStick.allCases.map(GamepadElement.stick)
            + GamepadButton.allCases.map(GamepadElement.button) {
            unbind(element)
        }
        let presets = gamepad?.presets ?? []
        gamepad = presets.isEmpty ? nil : GamepadSettings(presets: presets)
        return removed
    }

    /// The layout's controller part as a preset named `name`.
    public func gamepadPreset(named name: String) -> GamepadPreset {
        var bindings: [String: GamepadBinding] = [:]
        for control in controls {
            let binding = GamepadBinding(buttons: control.gamepadButtons, stick: control.stick, dpad: control.dpadButtons)
            if !binding.isEmpty { bindings[control.id] = binding }
        }
        let settings = gamepadSettings
        return GamepadPreset(name: name, bindings: bindings, leftStick: settings.leftStick, rightStick: settings.rightStick,
                             vibration: settings.vibration)
    }

    /// Puts a preset's controller part on the layout instead of the one it
    /// has: the controls it names get their controller buttons and sticks
    /// back, the others none (a D-pad of the d-pad's buttons stays, and its
    /// directions with it). Bindings that no longer fit (a control that is
    /// gone or changed kind, a button a direction holds) are left out; their
    /// number is returned.
    @discardableResult
    public mutating func apply(_ preset: GamepadPreset) -> Int {
        for element in [GamepadElement.dpad] + GamepadStick.allCases.map(GamepadElement.stick)
            + GamepadButton.allCases.map(GamepadElement.button) {
            unbind(element)
        }
        var skipped = 0
        for id in preset.bindings.keys.sorted() {
            guard let binding = preset.bindings[id] else { continue }
            var elements = binding.buttons.map(GamepadElement.button)
            if let stick = binding.stick { elements.append(.stick(stick)) }
            if binding.dpad { elements.append(.dpad) }
            for element in elements where !bindKeepingOthers(element, to: id) { skipped += 1 }
        }
        var settings = gamepad ?? GamepadSettings()
        settings.leftStick = preset.leftStick
        settings.rightStick = preset.rightStick
        settings.vibration = preset.vibration
        gamepad = settings
        return skipped
    }

    /// `bind`, except that a control keeps the controller buttons it got
    /// before: a preset may give one control several. False when it did not bind.
    private mutating func bindKeepingOthers(_ element: GamepadElement, to id: String) -> Bool {
        let kept = controls.first { $0.id == id }?.gamepadButtons ?? []
        do {
            try bind(element, to: id)
        } catch {
            return false
        }
        if case .button(let button) = element, let index = controls.firstIndex(where: { $0.id == id }) {
            controls[index].triggers.removeAll { $0.isGamepad }
            controls[index].triggers += (kept.filter { $0 != button } + [button]).map(Trigger.gamepad)
        }
        return true
    }

    /// Saves the layout's controller part as the preset `name`, replacing one of that name.
    public mutating func savePreset(named name: String) {
        var settings = gamepad ?? GamepadSettings()
        let preset = gamepadPreset(named: name)
        if let index = settings.presets.firstIndex(where: { $0.name == name }) {
            settings.presets[index] = preset
        } else {
            settings.presets.append(preset)
        }
        gamepad = settings
    }

    public mutating func deletePreset(named name: String) {
        gamepad?.presets.removeAll { $0.name == name }
    }
}

extension Control.Kind {
    /// The same joystick or camera, driven by `stick` (nil: none); other kinds unchanged.
    func with(stick: GamepadStick?) -> Control.Kind {
        switch self {
        case let .dpad(center, radius, up, down, left, right, _):
            .dpad(center: center, radius: radius, up: up, down: down, left: left, right: right, stick: stick)
        case let .aim(area, sensitivity, ads, exponent, deadzone, invertY, _, origin):
            .aim(area: area, sensitivity: sensitivity, adsSensitivity: ads, exponent: exponent, deadzone: deadzone,
                 invertY: invertY, stick: stick, origin: origin)
        default:
            self
        }
    }
}

// MARK: - Placing controls from the controller

/// What the editor places on the game for a part of the controller dragged
/// onto it (its drop menu), the usual choice first.
public enum GamepadPlacement: String, CaseIterable, Sendable {
    case tap, repeatTap, swipe, anchor, ads, joystick, camera

    /// The choices for `element`. A stick's own press (L3, R3) is offered
    /// with the stick, as `choices(for: .button(.leftThumbstick))`.
    public static func choices(for element: GamepadElement) -> [GamepadPlacement] {
        switch element {
        case .stick(.left): [.joystick, .camera]
        case .stick(.right): [.camera, .joystick]
        case .dpad: [.joystick]
        case .button(.leftTrigger): [.ads, .tap, .repeatTap, .swipe, .anchor]
        case .button: [.tap, .repeatTap, .swipe, .anchor, .ads]
        }
    }

    /// Whether this placement makes a control for `element`, which a stick or
    /// the d-pad drive (joystick, camera) and a button presses (the rest).
    public func fits(_ element: GamepadElement) -> Bool {
        switch (self, element) {
        case (.joystick, .stick), (.joystick, .dpad), (.camera, .stick): true
        case (.joystick, _), (.camera, _): false
        case (_, .button): true
        case (_, _): false
        }
    }

    var idPrefix: String {
        switch self {
        case .tap: "tap"
        case .repeatTap: "repeat"
        case .swipe: "swipe"
        case .anchor: "anchor"
        case .ads: "ads"
        case .joystick: "move"
        case .camera: "eye"
        }
    }
}

extension KeymapProfile {
    /// Places a new control for `element` at `point` and binds it, or, for
    /// the camera when the layout has its one eye already, binds the eye.
    /// Returns the control's id; nil when the placement does not fit the
    /// element. A joystick gets keys too (WASD, else the arrow keys) while
    /// they are free, so it also works from the keyboard; from the d-pad, its
    /// directions are the d-pad's buttons.
    public mutating func place(_ element: GamepadElement, as placement: GamepadPlacement, at point: NormalizedPoint,
                               modes: [String]? = nil) -> String? {
        guard placement.fits(element) else { return nil }
        let p = NormalizedPoint(min(max(point.x, 0), 1), min(max(point.y, 0), 1))
        if placement == .camera, let eye = controls.first(where: { if case .aim = $0.kind { true } else { false } }) {
            do {
                try bind(element, to: eye.id)
                return eye.id
            } catch {
                return nil
            }
        }
        let kind: Control.Kind
        switch placement {
        case .tap: kind = .tap(p)
        case .repeatTap: kind = .repeatTap(p, intervalMilliseconds: 150)
        case .swipe: kind = .swipe(from: p, to: NormalizedPoint(p.x, max(p.y - 0.2, 0)), milliseconds: 150)
        case .anchor: kind = .anchor(p, radius: Control.defaultAnchorRadius)
        case .ads: kind = .ads(p, toggle: false)
        case .joystick:
            let directions = element == .dpad ? GamepadElement.dpadButtons.map(Trigger.gamepad) : freeDirections()
            kind = .dpad(center: p, radius: Control.defaultJoystickRadius, up: directions[0], down: directions[1],
                         left: directions[2], right: directions[3], stick: nil)
        case .camera:
            // The default area, as near to centred on the point as the screen allows.
            let area = Control.defaultEyeArea
            kind = .aim(area: area.offsetBy(dx: p.x - area.center.x, dy: p.y - area.center.y), sensitivity: AxisPair(x: 1, y: 1),
                        adsSensitivity: AxisPair(x: 0.6, y: 0.6), exponent: 1, deadzone: 0, invertY: false, stick: nil)
        }
        var n = 1
        while controls.contains(where: { $0.id == "\(placement.idPrefix)-\(n)" }) { n += 1 }
        let id = "\(placement.idPrefix)-\(n)"
        if element == .dpad {
            // Its directions are the d-pad's buttons: they leave the other controls.
            let placed = Control(id: id, kind: kind, modes: modes)
            guard directionHolder(of: GamepadElement.dpadButtons, except: id, beside: placed) == nil else { return nil }
            for i in controls.indices where sharesMode(controls[i], placed) {
                controls[i].dpadButtons = false
                for button in GamepadElement.dpadButtons { controls[i].triggers.removeAll { $0 == .gamepad(button) } }
            }
            controls.append(placed)
            return id
        }
        controls.append(Control(id: id, kind: kind, modes: modes))
        do {
            try bind(element, to: id)
        } catch {
            controls.removeAll { $0.id == id }
            return nil
        }
        return id
    }

    /// Four keys for a new joystick that nothing uses yet: WASD, else the
    /// arrow keys, else the controller's d-pad.
    private func freeDirections() -> [Trigger] {
        var used = Set(controls.flatMap(\.allTriggers))
        if let toggle = fps?.cursorToggle { used.insert(toggle) }
        let choices: [[Trigger]] = [[.key(.w), .key(.s), .key(.a), .key(.d)], [.key(.up), .key(.down), .key(.left), .key(.right)],
                                    GamepadElement.dpadButtons.map(Trigger.gamepad)]
        return choices.first { !$0.contains(where: used.contains) } ?? choices[0]
    }
}

// MARK: - Ready-made controller layouts

extension KeymapTemplate {
    /// This kind of game's usual controller layout for `profile`'s controls:
    /// each control gets the button such games put it on, found from its id
    /// (the templates' "fire", "jump"…) or its key (Space jumps, R
    /// reloads…); the rest get the buttons left over, and joysticks and the
    /// eye the sticks. The stick settings and vibration stay as they are.
    public func gamepadPreset(for profile: KeymapProfile) -> GamepadPreset {
        var bindings: [String: GamepadBinding] = [:]
        var usedButtons = Set<GamepadButton>()
        var usedSticks = Set<GamepadStick>()
        var held = Set<GamepadButton>()
        // D-pad directions that are controller buttons stay as they are.
        for control in profile.controls where control.isDPadOfButtons { held.formUnion(GamepadElement.dpadButtons) }
        if case .gamepad(let button)? = profile.fps?.cursorToggle { held.insert(button) }

        // Sticks: the first joystick moves, the eye looks.
        for control in profile.controls {
            switch control.kind {
            case .dpad where !usedSticks.contains(.left):
                bindings[control.id] = GamepadBinding(stick: .left)
                usedSticks.insert(.left)
            case .aim where !usedSticks.contains(.right):
                bindings[control.id] = GamepadBinding(stick: .right)
                usedSticks.insert(.right)
            default:
                break
            }
        }

        let pressable = profile.controls.filter { $0.accepts(.button(.a)) }
        // First the controls this kind of game puts on a known button, in the plan's order.
        var placed = Set<String>()
        for (role, button) in buttonPlan {
            guard !usedButtons.contains(button), !held.contains(button),
                  let control = pressable.first(where: { !placed.contains($0.id) && GamepadRole(of: $0) == role }) else { continue }
            bindings[control.id] = GamepadBinding(buttons: [button])
            usedButtons.insert(button)
            placed.insert(control.id)
        }
        let rest = pressable.filter { !placed.contains($0.id) }
        // Then the others, on the buttons left, the easiest to reach first.
        var spare = Self.spareOrder.filter { !usedButtons.contains($0) && !held.contains($0) }.makeIterator()
        for control in rest {
            guard let button = spare.next() else { break }
            bindings[control.id] = GamepadBinding(buttons: [button])
        }
        let settings = profile.gamepadSettings
        return GamepadPreset(name: rawValue, bindings: bindings, leftStick: settings.leftStick, rightStick: settings.rightStick,
                             vibration: settings.vibration)
    }

    /// Where this kind of game puts each role, most important first.
    private var buttonPlan: [(GamepadRole, GamepadButton)] {
        switch self {
        case .fps:
            [(.fire, .rightTrigger), (.aimDownSights, .leftTrigger), (.jump, .a), (.crouch, .b), (.reload, .x), (.interact, .y),
             (.sprint, .leftThumbstick), (.melee, .rightThumbstick), (.grenade, .rightShoulder), (.weapon(1), .dpadLeft),
             (.weapon(2), .dpadRight), (.weapon(3), .dpadUp), (.weapon(4), .dpadDown), (.map, .options), (.inventory, .menu)]
        case .moba:
            [(.attack, .rightTrigger), (.skill(1), .a), (.skill(2), .x), (.skill(3), .y), (.skill(4), .b),
             (.spell, .rightShoulder), (.recall, .leftShoulder), (.fire, .rightTrigger), (.map, .options)]
        case .racing:
            [(.accelerate, .rightTrigger), (.brake, .leftTrigger), (.steerLeft, .dpadLeft), (.steerRight, .dpadRight),
             (.nitro, .a), (.jump, .a), (.map, .options)]
        case .platformer:
            [(.jump, .a), (.action(1), .x), (.action(2), .b), (.attack, .x), (.interact, .y), (.sprint, .rightShoulder),
             (.map, .options)]
        }
    }

    /// The buttons for controls without a role, the easiest to reach first.
    static let spareOrder: [GamepadButton] = [
        .a, .b, .x, .y, .rightShoulder, .leftShoulder, .rightTrigger, .leftTrigger,
        .dpadUp, .dpadRight, .dpadDown, .dpadLeft, .leftThumbstick, .rightThumbstick, .options, .menu,
    ]
}

/// What a control does in its game, guessed from its id and its keys, for
/// putting it on the button controller games use for it.
enum GamepadRole: Hashable {
    case fire, aimDownSights, jump, crouch, reload, interact, sprint, melee, grenade, weapon(Int), map, inventory
    case attack, skill(Int), spell, recall
    case accelerate, brake, steerLeft, steerRight, nitro
    case action(Int)
    case other

    init(of control: Control) {
        if case .ads = control.kind {
            self = .aimDownSights
            return
        }
        let id = control.id.lowercased()
        let keys = Set(control.triggers.compactMap { if case .key(let key) = $0 { key } else { nil } })
        // Whole words of the id ("steer-left"), so "pause" is no "use".
        let words = id.split { !$0.isLetter }.map(String.init)
        func named(_ names: String...) -> Bool { words.contains { word in names.contains { word.hasPrefix($0) } } }
        func numbered(_ prefix: String) -> Int? {
            guard id.hasPrefix(prefix) else { return nil }
            return Int(id.dropFirst(prefix.count).filter(\.isNumber))
        }
        if let n = numbered("skill") { self = .skill(n) }
        else if let n = numbered("weapon") { self = .weapon(n) }
        else if let n = numbered("action") { self = .action(n) }
        else if named("fire", "shoot") || control.triggers.contains(.mouse(.left)) { self = .fire }
        else if named("scope", "ads", "aim") || control.triggers.contains(.mouse(.right)) { self = .aimDownSights }
        else if named("jump") || keys.contains(.space) { self = .jump }
        else if named("crouch", "prone", "slide") || keys.contains(.c) || keys.contains(.control) { self = .crouch }
        else if named("reload") || keys.contains(.r) { self = .reload }
        else if named("interact", "use", "pick", "open") || keys.contains(.f) || keys.contains(.e) { self = .interact }
        else if named("sprint", "run", "dash") || keys.contains(.shift) { self = .sprint }
        else if named("melee", "punch") || keys.contains(.v) { self = .melee }
        else if named("grenade", "throw") || keys.contains(.g) { self = .grenade }
        else if named("inventory", "bag") || keys.contains(.tab) || keys.contains(.i) { self = .inventory }
        else if named("map") || keys.contains(.m) { self = .map }
        else if named("attack") { self = .attack }
        else if named("spell") { self = .spell }
        else if named("recall", "back") || keys.contains(.b) { self = .recall }
        else if named("accelerate", "gas", "throttle") || keys.contains(.w) || keys.contains(.up) { self = .accelerate }
        else if named("brake", "reverse") || keys.contains(.s) || keys.contains(.down) { self = .brake }
        else if named("left") || keys.contains(.a) || keys.contains(.left) { self = .steerLeft }
        else if named("right") || keys.contains(.d) || keys.contains(.right) { self = .steerRight }
        else if named("nitro", "boost") { self = .nitro }
        else if let digit = keys.compactMap({ Self.digits[$0] }).first { self = .weapon(digit) }
        else { self = .other }
    }

    private static let digits: [KeyName: Int] = [.digit1: 1, .digit2: 2, .digit3: 3, .digit4: 4]
}
