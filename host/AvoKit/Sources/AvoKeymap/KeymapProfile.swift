import AvoKit
import Foundation
import os

/// A point in display coordinates normalized to 0…1, so profiles survive
/// window resizes and different display sizes. Encoded as `[x, y]`.
public struct NormalizedPoint: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(Double.self)
        y = try container.decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
    }

    var isInside: Bool { (0...1).contains(x) && (0...1).contains(y) }
}

/// Encoded as `[x0, y0, x1, y1]`.
public struct NormalizedRect: Hashable, Sendable, Codable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        minX = try container.decode(Double.self)
        minY = try container.decode(Double.self)
        maxX = try container.decode(Double.self)
        maxY = try container.decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for value in [minX, minY, maxX, maxY] { try container.encode(value) }
    }

    /// The whole screen.
    public static let screen = NormalizedRect(0, 0, 1, 1)

    public var center: NormalizedPoint { NormalizedPoint((minX + maxX) / 2, (minY + maxY) / 2) }
    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }

    public func contains(_ point: NormalizedPoint) -> Bool {
        minX <= point.x && point.x <= maxX && minY <= point.y && point.y <= maxY
    }

    var isValid: Bool { 0 <= minX && minX < maxX && maxX <= 1 && 0 <= minY && minY < maxY && maxY <= 1 }

    /// `point` moved into the rectangle, at least `inset` of its width and
    /// height (0…0.5) away from the edges.
    public func clamp(_ point: NormalizedPoint, inset: Double = 0) -> NormalizedPoint {
        let fraction = min(max(inset, 0), 0.5)
        let dx = width * fraction, dy = height * fraction
        return NormalizedPoint(min(max(point.x, minX + dx), maxX - dx), min(max(point.y, minY + dy), maxY - dy))
    }

    /// The sides a resize moves: `left` and `right` are minX and maxX, `top`
    /// and `bottom` minY and maxY (y grows down the screen).
    public struct Edges: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let left = Edges(rawValue: 1 << 0)
        public static let right = Edges(rawValue: 1 << 1)
        public static let top = Edges(rawValue: 1 << 2)
        public static let bottom = Edges(rawValue: 1 << 3)
    }

    /// The rectangle with `edges` moved by (dx, dy), kept on the screen and,
    /// as far as the screen allows, at least `minWidth` × `minHeight`.
    public func resized(_ edges: Edges, dx: Double, dy: Double, minWidth: Double, minHeight: Double) -> NormalizedRect {
        let w = min(max(minWidth, 0), 1), h = min(max(minHeight, 0), 1)
        var r = self
        if edges.contains(.left) { r.minX = min(max(minX + dx, 0), maxX - w) }
        if edges.contains(.right) { r.maxX = max(min(maxX + dx, 1), minX + w) }
        if edges.contains(.top) { r.minY = min(max(minY + dy, 0), maxY - h) }
        if edges.contains(.bottom) { r.maxY = max(min(maxY + dy, 1), minY + h) }
        // Too small to stay where it is (against an edge of the screen): it grows the other way.
        if r.minX < 0 { r.maxX = min(r.maxX - r.minX, 1); r.minX = 0 }
        if r.maxX > 1 { r.minX = max(r.minX - (r.maxX - 1), 0); r.maxX = 1 }
        if r.minY < 0 { r.maxY = min(r.maxY - r.minY, 1); r.minY = 0 }
        if r.maxY > 1 { r.minY = max(r.minY - (r.maxY - 1), 0); r.maxY = 1 }
        return r
    }

    /// Grown by `dw` × `dh` around its centre (shrunk when negative), kept on
    /// the screen and at least `minWidth` × `minHeight`.
    public func grown(dw: Double, dh: Double, minWidth: Double, minHeight: Double) -> NormalizedRect {
        func axis(_ low: Double, _ high: Double, _ change: Double, _ minimum: Double) -> (Double, Double) {
            let length = min(max(high - low + change, min(max(minimum, 0), 1)), 1)
            var a = (low + high) / 2 - length / 2, b = a + length
            if a < 0 { b -= a; a = 0 }
            if b > 1 { a = max(a - (b - 1), 0); b = 1 }
            return (a, b)
        }
        let (x0, x1) = axis(minX, maxX, dw, minWidth), (y0, y1) = axis(minY, maxY, dh, minHeight)
        return NormalizedRect(x0, y0, x1, y1)
    }

    /// Moved by (dx, dy) as far as the screen allows, the same size.
    public func offsetBy(dx: Double, dy: Double) -> NormalizedRect {
        let x = max(min(dx, 1 - maxX), -minX), y = max(min(dy, 1 - maxY), -minY)
        return NormalizedRect(minX + x, minY + y, maxX + x, maxY + y)
    }
}

public struct AxisPair: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// When a control is active in FPS mode.
public enum ControlLayer: String, Codable, Sendable {
    /// Only while the pointer is locked (combat).
    case locked
    /// Only in cursor mode (inventory, map).
    case cursor
}

public enum MacroStep: Hashable, Sendable, Codable {
    case tap(NormalizedPoint)
    case hold(NormalizedPoint, milliseconds: Int)
    case wait(milliseconds: Int)

    private enum CodingKeys: String, CodingKey { case tap, hold, ms, wait }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let point = try container.decodeIfPresent(NormalizedPoint.self, forKey: .tap) {
            self = .tap(point)
        } else if let point = try container.decodeIfPresent(NormalizedPoint.self, forKey: .hold) {
            self = .hold(point, milliseconds: try container.decode(Int.self, forKey: .ms))
        } else {
            self = .wait(milliseconds: try container.decode(Int.self, forKey: .wait))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tap(let point): try container.encode(point, forKey: .tap)
        case let .hold(point, ms):
            try container.encode(point, forKey: .hold)
            try container.encode(ms, forKey: .ms)
        case .wait(let ms): try container.encode(ms, forKey: .wait)
        }
    }

    var duration: Int {
        switch self {
        case .tap: KeymapEngine.tapDurationMilliseconds
        case .hold(_, let ms), .wait(let ms): ms
        }
    }
}

/// Something a control does besides its touch, when its key is pressed (a
/// click area: when it is clicked), in the order the control lists them:
/// F presses the game's Enter vehicle button and switches the layout to the
/// vehicle mode. Encoded as `{"switch_mode": "vehicle"}`, `{"mouse": "free"}`.
public enum ControlAction: Hashable, Sendable, Codable {
    /// Turns the layout to another of its modes (`KeymapProfile.modes`): its id.
    case switchMode(String)
    /// Locks the mouse to the eye for mouse look.
    case lockMouse
    /// Frees the mouse from the eye, for the cursor (a map, an inventory).
    case freeMouse
    /// Locks the mouse when it is free, frees it when it is locked (the eye's own key does this too).
    case toggleMouse

    private enum CodingKeys: String, CodingKey { case switchMode = "switch_mode", mouse }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let mode = try c.decodeIfPresent(String.self, forKey: .switchMode) {
            self = .switchMode(mode)
            return
        }
        switch try c.decode(String.self, forKey: .mouse) {
        case "lock": self = .lockMouse
        case "free": self = .freeMouse
        case "toggle": self = .toggleMouse
        case let other: throw DecodingError.dataCorruptedError(forKey: .mouse, in: c, debugDescription: "unknown mouse action \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .switchMode(let mode): try c.encode(mode, forKey: .switchMode)
        case .lockMouse: try c.encode("lock", forKey: .mouse)
        case .freeMouse: try c.encode("free", forKey: .mouse)
        case .toggleMouse: try c.encode("toggle", forKey: .mouse)
        }
    }

    /// Locking or freeing the mouse, which needs the eye.
    public var isMouse: Bool {
        if case .switchMode = self { false } else { true }
    }
}

/// One entry of a control's `actions`: an action, or nil for one this
/// version does not know (a newer Avo wrote it), left out so the rest loads.
private struct ActionEntry: Decodable {
    var action: ControlAction?

    init(from decoder: any Decoder) throws {
        action = try? ControlAction(from: decoder)
    }
}

/// One on-screen control of a keymap profile (spec §5: tap, hold, D-pad,
/// mouse aim, swipe, repeated tap and simple macros, plus the MOBA controls
/// that aim at the cursor).
public struct Control: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// A short touch when the trigger is pressed.
        case tap(NormalizedPoint)
        /// Touch held while the trigger is held.
        case hold(NormalizedPoint)
        /// Virtual joystick driven by four triggers (WASD) or a gamepad stick.
        case dpad(center: NormalizedPoint, radius: Double, up: Trigger, down: Trigger, left: Trigger, right: Trigger, stick: GamepadStick?)
        /// Camera area for mouse-look (FPS mode) or a gamepad stick: a
        /// finger touches down at `origin` (the centre of `area` when nil),
        /// swipes inside `area` as the mouse moves and, at its edge, lifts
        /// and touches down at `origin` again, so the camera turns without
        /// limit. The taller the area, the further a look up or down goes in
        /// one swipe.
        case aim(area: NormalizedRect, sensitivity: AxisPair, adsSensitivity: AxisPair, exponent: Double,
                 deadzone: Double, invertY: Bool, stick: GamepadStick?, origin: NormalizedPoint? = nil)
        /// Aim-down-sights button: also switches the aim control to ADS sensitivity.
        case ads(NormalizedPoint, toggle: Bool)
        case swipe(from: NormalizedPoint, to: NormalizedPoint, milliseconds: Int)
        case repeatTap(NormalizedPoint, intervalMilliseconds: Int)
        case macro([MacroStep])
        /// Anchor tap: a touch held at the point while the trigger is held,
        /// moved from there by the mouse (radial menus such as emote wheels:
        /// hold the key, move the mouse towards an item, let go), never
        /// further than `radius` from it, a fraction of the display height
        /// (anywhere on the screen when nil).
        case anchor(NormalizedPoint, radius: Double? = nil)
        /// MOBA movement (move by mouse): while the trigger is held, a
        /// joystick touch at `center` is pushed the way the cursor lies from
        /// the hero (`KeymapProfile.hero`), all the way out to `radius` once
        /// the cursor is that far from the hero.
        case mobaMove(center: NormalizedPoint, radius: Double)
        /// MOBA skill with smart cast: the trigger puts a finger on the skill
        /// button and drags it the way the cursor lies from the hero,
        /// following the cursor; letting go casts. The drag grows with the
        /// cursor's distance from the hero and is a full `radius` at `reach`
        /// (the skill's range on screen), never longer.
        case smartCast(NormalizedPoint, radius: Double, reach: Double)
        /// A key that touches nothing: it only does its `actions` (switch
        /// the mode, free the mouse). It has no place on the game.
        case hotkey
        /// A part of the screen that does its `actions` when it is clicked
        /// while the mouse is free (the game's Close button of an
        /// inventory: back to combat, the mouse locked to the eye). With
        /// `passThrough` the click also touches the game there.
        case clickArea(NormalizedRect, passThrough: Bool)
        /// A slider of the game (a map's zoom): each notch of the wheel drags
        /// its thumb a `step` (a fraction of the track) along the track from
        /// `from` to `to`, wheel up towards `to`, never past either end. The
        /// thumb starts at `rest` (0 is `from`, 1 is `to`), goes back there
        /// in a new mode, and is dragged back there by the control's `reset`
        /// key. The finger stays down while the wheel turns and lets go a
        /// moment after it stops.
        case scrollBar(from: NormalizedPoint, to: NormalizedPoint, rest: Double, step: Double)
    }

    public var id: String
    public var kind: Kind
    /// What activates the control (not used by `dpad`, which has four, or
    /// by `aim`, which follows the mouse). A trigger may activate several
    /// controls: they act together.
    public var triggers: [Trigger]
    public var layer: ControlLayer?
    /// The modes it acts in (`KeymapProfile.modes`); nil: all of them.
    public var modes: [String]?
    /// How big a button (tap, hold, ads, repeat_tap, macro) was drawn by
    /// Avo before b64; read and kept, no longer used: a button's size never
    /// changed what it touches.
    public var size: Double?
    /// A D-pad control (keys or a stick) that the controller's d-pad also
    /// pushes, its four buttons as the directions. Older versions of Avo
    /// leave it out and the keys still work.
    public var dpadButtons: Bool
    /// A D-pad control pushed further while a key is held (running).
    /// Older versions of Avo leave it out and the joystick still walks.
    public var run: JoystickRun?
    /// What it does besides its touch, in order (`canCarryActions`).
    /// Older versions of Avo leave them out, and the touch still works.
    public var actions: [ControlAction]
    /// A part of the game that, clicked while the mouse is free, presses the
    /// control as its key would (`canHaveClickZone`): the press while the
    /// button is down, its actions once, and the click itself never reaches
    /// the game, so the game's button is touched once. Nil: none.
    public var clickZone: ClickZone?
    /// A scroll bar's key that drags its thumb back to its rest point.
    public var reset: Trigger?

    public static let defaultSize = 0.035
    public static let sizeRange = 0.012...0.3
    /// A MOBA joystick's radius, as a fraction of the display height.
    public static let defaultJoystickRadius = 0.12
    /// How far a smart cast drags the skill button at most, and how far the
    /// cursor must be from the hero for that (a typical skill range on a
    /// landscape screen), as fractions of the display height.
    public static let defaultCastRadius = 0.1
    public static let defaultCastReach = 0.35
    public static let castReachRange = 0.05...2.0

    /// A new anchor tap's reach (a fraction of the display height), and its limits.
    public static let defaultAnchorRadius = 0.18
    public static let anchorRadiusRange = 0.03...1.0

    /// A new eye's swipe area: most of the right part of the screen, at
    /// full height but for a margin. The finger goes all the way to its
    /// edge before it lifts and touches down at its point again (a thumb
    /// swiping again and again), so a look up or down travels far.
    public static let defaultEyeArea = NormalizedRect(0.45, 0.05, 0.97, 0.95)
    /// The shortest side the editor gives an area, as a fraction of the
    /// display height (on screen, a square of that side at the least).
    public static let minimumAreaSide = 0.1
    /// How far inside its area the editor keeps the eye's touch-down point,
    /// as a fraction of the area's width and height: from there the finger
    /// always has some way to go before it starts over.
    public static let eyeOriginInset = 0.1
    /// A new click area's side, a square about a button's size, as a fraction of the display height.
    public static let defaultClickAreaSide = 0.12
    /// The shortest side the editor gives a click area, as a fraction of
    /// the display height: the game's smallest buttons (a close ×).
    public static let minimumClickAreaSide = 0.04
    /// A new scroll bar: a step a notch (a tenth of the track), resting halfway.
    public static let defaultScrollStep = 0.1
    public static let scrollStepRange = 0.01...0.5
    public static let defaultScrollRest = 0.5
    /// The shortest track the editor makes, as a fraction of the display height.
    public static let minimumScrollTrack = 0.05

    public init(id: String, kind: Kind, triggers: [Trigger] = [], layer: ControlLayer? = nil, modes: [String]? = nil,
                size: Double? = nil, dpadButtons: Bool = false, run: JoystickRun? = nil, actions: [ControlAction] = [],
                clickZone: ClickZone? = nil, reset: Trigger? = nil) {
        self.id = id
        self.kind = kind
        self.triggers = triggers
        self.layer = layer
        self.modes = modes
        self.size = size
        self.dpadButtons = dpadButtons
        self.run = run
        self.actions = actions
        self.clickZone = clickZone
        self.reset = reset
    }

    // Flat JSON: {"type": "tap", "id": "jump", "triggers": ["key:Space"], "position": [0.9, 0.7]}
    private enum CodingKeys: String, CodingKey {
        case type, id, triggers, layer, modes, size, position, center, radius, up, down, left, right, stick, dpadButtons = "dpad_buttons"
        case area, sensitivity, adsSensitivity = "ads_sensitivity", exponent, deadzone, invertY = "invert_y", origin
        case toggle, from, to, ms, interval, steps, reach, mode, lock, run, actions, passThrough = "pass_through"
        case rest, step, reset, clickZone = "click_zone"
    }

    /// The `type` values this version reads; KeymapProfile skips the others.
    /// `switch_mode` and `mouse_look` are Avo's controls before actions: a
    /// key that only switched the mode or locked or freed the mouse, read
    /// as a hotkey with that action (`legacyTypes`).
    static let knownTypes = Set<String>([
        "tap", "hold", "dpad", "aim", "ads", "swipe", "repeat_tap", "macro", "anchor", "moba_move", "smart_cast",
        "hotkey", "click_area", "scroll_bar",
    ]).union(legacyTypes)
    static let legacyTypes: Set<String> = ["switch_mode", "mouse_look"]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        triggers = try c.decodeIfPresent([Trigger].self, forKey: .triggers) ?? []
        layer = try c.decodeIfPresent(ControlLayer.self, forKey: .layer)
        modes = try c.decodeIfPresent([String].self, forKey: .modes)
        size = try c.decodeIfPresent(Double.self, forKey: .size)
        dpadButtons = false
        run = nil
        // Newer than the controls: a list this version cannot read leaves them out.
        actions = ((try? c.decodeIfPresent([ActionEntry].self, forKey: .actions)) ?? nil)?.compactMap(\.action) ?? []
        // Newer than the controls as well: one this version cannot read is no zone.
        clickZone = (try? c.decodeIfPresent(ClickZone.self, forKey: .clickZone)) ?? nil
        reset = nil
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "tap": kind = .tap(try c.decode(NormalizedPoint.self, forKey: .position))
        case "hold": kind = .hold(try c.decode(NormalizedPoint.self, forKey: .position))
        case "dpad":
            kind = .dpad(center: try c.decode(NormalizedPoint.self, forKey: .center),
                         radius: try c.decode(Double.self, forKey: .radius),
                         up: try c.decodeIfPresent(Trigger.self, forKey: .up) ?? .key(.w),
                         down: try c.decodeIfPresent(Trigger.self, forKey: .down) ?? .key(.s),
                         left: try c.decodeIfPresent(Trigger.self, forKey: .left) ?? .key(.a),
                         right: try c.decodeIfPresent(Trigger.self, forKey: .right) ?? .key(.d),
                         stick: try c.decodeIfPresent(GamepadStick.self, forKey: .stick))
            dpadButtons = try c.decodeIfPresent(Bool.self, forKey: .dpadButtons) ?? false
            // Newer than the joystick: one this version cannot read walks.
            run = (try? c.decodeIfPresent(JoystickRun.self, forKey: .run)) ?? nil
        case "aim":
            let sensitivity = try c.decodeIfPresent(AxisPair.self, forKey: .sensitivity) ?? AxisPair(x: 1, y: 1)
            kind = .aim(area: try c.decode(NormalizedRect.self, forKey: .area),
                        sensitivity: sensitivity,
                        adsSensitivity: try c.decodeIfPresent(AxisPair.self, forKey: .adsSensitivity) ?? sensitivity,
                        exponent: try c.decodeIfPresent(Double.self, forKey: .exponent) ?? 1,
                        deadzone: try c.decodeIfPresent(Double.self, forKey: .deadzone) ?? 0,
                        invertY: try c.decodeIfPresent(Bool.self, forKey: .invertY) ?? false,
                        stick: try c.decodeIfPresent(GamepadStick.self, forKey: .stick),
                        // Newer than the rest: a file without it (or with one
                        // this version cannot read) touches down at the centre.
                        origin: try? c.decodeIfPresent(NormalizedPoint.self, forKey: .origin))
        case "ads":
            kind = .ads(try c.decode(NormalizedPoint.self, forKey: .position),
                        toggle: try c.decodeIfPresent(Bool.self, forKey: .toggle) ?? false)
        case "swipe":
            kind = .swipe(from: try c.decode(NormalizedPoint.self, forKey: .from),
                          to: try c.decode(NormalizedPoint.self, forKey: .to),
                          milliseconds: try c.decodeIfPresent(Int.self, forKey: .ms) ?? 150)
        case "repeat_tap":
            kind = .repeatTap(try c.decode(NormalizedPoint.self, forKey: .position),
                              intervalMilliseconds: try c.decodeIfPresent(Int.self, forKey: .interval) ?? 150)
        case "macro":
            kind = .macro(try c.decode([MacroStep].self, forKey: .steps))
        case "anchor":
            // Newer than the position: without a reach (or with one this
            // version cannot read) the finger may go anywhere on the screen.
            // Avo before b64 kept it in a rectangle: the circle as tall.
            var radius = (try? c.decodeIfPresent(Double.self, forKey: .radius)) ?? nil
            if radius == nil, let area = (try? c.decodeIfPresent(NormalizedRect.self, forKey: .area)) ?? nil, area.isValid {
                radius = min(max(area.height / 2, Self.anchorRadiusRange.lowerBound), Self.anchorRadiusRange.upperBound)
            }
            kind = .anchor(try c.decode(NormalizedPoint.self, forKey: .position), radius: radius)
        case "moba_move":
            kind = .mobaMove(center: try c.decode(NormalizedPoint.self, forKey: .center),
                             radius: try c.decodeIfPresent(Double.self, forKey: .radius) ?? Self.defaultJoystickRadius)
        case "smart_cast":
            kind = .smartCast(try c.decode(NormalizedPoint.self, forKey: .position),
                              radius: try c.decodeIfPresent(Double.self, forKey: .radius) ?? Self.defaultCastRadius,
                              reach: try c.decodeIfPresent(Double.self, forKey: .reach) ?? Self.defaultCastReach)
        case "hotkey":
            kind = .hotkey
        case "scroll_bar":
            kind = .scrollBar(from: try c.decode(NormalizedPoint.self, forKey: .from), to: try c.decode(NormalizedPoint.self, forKey: .to),
                              rest: try c.decodeIfPresent(Double.self, forKey: .rest) ?? Self.defaultScrollRest,
                              step: try c.decodeIfPresent(Double.self, forKey: .step) ?? Self.defaultScrollStep)
            reset = (try? c.decodeIfPresent(Trigger.self, forKey: .reset)) ?? nil
        case "click_area":
            kind = .clickArea(try c.decode(NormalizedRect.self, forKey: .area),
                              passThrough: try c.decodeIfPresent(Bool.self, forKey: .passThrough) ?? true)
        case "switch_mode":
            kind = .hotkey
            actions = [.switchMode(try c.decode(String.self, forKey: .mode))]
        case "mouse_look":
            kind = .hotkey
            actions = [try c.decodeIfPresent(Bool.self, forKey: .lock) ?? false ? .lockMouse : .freeMouse]
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown control type \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if !triggers.isEmpty { try c.encode(triggers, forKey: .triggers) }
        try c.encodeIfPresent(layer, forKey: .layer)
        try c.encodeIfPresent(modes, forKey: .modes)
        try c.encodeIfPresent(size, forKey: .size)
        if !actions.isEmpty { try c.encode(actions, forKey: .actions) }
        try c.encodeIfPresent(clickZone, forKey: .clickZone)
        switch kind {
        case .tap(let point):
            try c.encode("tap", forKey: .type)
            try c.encode(point, forKey: .position)
        case .hold(let point):
            try c.encode("hold", forKey: .type)
            try c.encode(point, forKey: .position)
        case let .dpad(center, radius, up, down, left, right, stick):
            try c.encode("dpad", forKey: .type)
            try c.encode(center, forKey: .center)
            try c.encode(radius, forKey: .radius)
            try c.encode(up, forKey: .up)
            try c.encode(down, forKey: .down)
            try c.encode(left, forKey: .left)
            try c.encode(right, forKey: .right)
            try c.encodeIfPresent(stick, forKey: .stick)
            if dpadButtons { try c.encode(true, forKey: .dpadButtons) }
            try c.encodeIfPresent(run, forKey: .run)
        case let .aim(area, sensitivity, ads, exponent, deadzone, invertY, stick, origin):
            try c.encode("aim", forKey: .type)
            try c.encode(area, forKey: .area)
            try c.encode(sensitivity, forKey: .sensitivity)
            try c.encode(ads, forKey: .adsSensitivity)
            try c.encode(exponent, forKey: .exponent)
            try c.encode(deadzone, forKey: .deadzone)
            try c.encode(invertY, forKey: .invertY)
            try c.encodeIfPresent(stick, forKey: .stick)
            try c.encodeIfPresent(origin, forKey: .origin)
        case let .ads(point, toggle):
            try c.encode("ads", forKey: .type)
            try c.encode(point, forKey: .position)
            try c.encode(toggle, forKey: .toggle)
        case let .swipe(from, to, ms):
            try c.encode("swipe", forKey: .type)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
            try c.encode(ms, forKey: .ms)
        case let .repeatTap(point, interval):
            try c.encode("repeat_tap", forKey: .type)
            try c.encode(point, forKey: .position)
            try c.encode(interval, forKey: .interval)
        case .macro(let steps):
            try c.encode("macro", forKey: .type)
            try c.encode(steps, forKey: .steps)
        case let .anchor(point, radius):
            try c.encode("anchor", forKey: .type)
            try c.encode(point, forKey: .position)
            try c.encodeIfPresent(radius, forKey: .radius)
        case let .mobaMove(center, radius):
            try c.encode("moba_move", forKey: .type)
            try c.encode(center, forKey: .center)
            try c.encode(radius, forKey: .radius)
        case let .smartCast(point, radius, reach):
            try c.encode("smart_cast", forKey: .type)
            try c.encode(point, forKey: .position)
            try c.encode(radius, forKey: .radius)
            try c.encode(reach, forKey: .reach)
        case .hotkey:
            try c.encode("hotkey", forKey: .type)
        case let .clickArea(area, passThrough):
            try c.encode("click_area", forKey: .type)
            try c.encode(area, forKey: .area)
            try c.encode(passThrough, forKey: .passThrough)
        case let .scrollBar(from, to, rest, step):
            try c.encode("scroll_bar", forKey: .type)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
            try c.encode(rest, forKey: .rest)
            try c.encode(step, forKey: .step)
            try c.encodeIfPresent(reset, forKey: .reset)
        }
    }

    /// Triggers this control listens to (including a D-pad's four keys, and
    /// the controller's d-pad buttons when they push it too).
    public var allTriggers: [Trigger] {
        if case let .dpad(_, _, up, down, left, right, _) = kind {
            let directions = [up, down, left, right]
            let buttons = dpadButtons ? GamepadElement.dpadButtons.map(Trigger.gamepad).filter { !directions.contains($0) } : []
            return directions + buttons + (run.map { [$0.trigger] } ?? [])
        }
        // Clicked, not pressed.
        if case .clickArea = kind { return [] }
        // The wheel, both ways, and its reset key.
        if case .scrollBar = kind { return [.scrollUp, .scrollDown] + (reset.map { [$0] } ?? []) }
        return triggers
    }

    /// Aimed from the hero at the free cursor (MOBA move and smart cast).
    public var followsCursor: Bool {
        switch kind {
        case .mobaMove, .smartCast: true
        default: false
        }
    }

    /// Acts in `mode` (nil: a layout without modes, where every control does).
    public func belongs(to mode: String?) -> Bool {
        guard let mode, let modes else { return true }
        return modes.contains(mode)
    }

    /// Something the player may put on the game's buttons (a hotkey only
    /// does its actions; a click area is clicked, and touches nothing itself).
    public var touchesTheScreen: Bool {
        switch kind {
        case .hotkey, .clickArea: false
        default: true
        }
    }

    /// Does `actions` on its press: everything but a joystick, which has a
    /// key for each way, and the eye, which follows the mouse.
    public var canCarryActions: Bool {
        switch kind {
        case .dpad, .aim, .scrollBar: false
        default: true
        }
    }

    /// May be pressed by a click on the game as well (`clickZone`): a control
    /// with a key of its own. Not a joystick (four keys), the eye, a click
    /// area (it is one) or a scroll bar (the wheel's).
    public var canHaveClickZone: Bool {
        switch kind {
        case .dpad, .aim, .clickArea, .scrollBar: false
        default: true
        }
    }

    /// Shown and placed on the game (a hotkey has no place there).
    public var isOnGame: Bool {
        if case .hotkey = kind { false } else { true }
    }
}

// MARK: - The eye's swipe area

extension Control {
    /// Where an eye's finger may go: its swipe area; nil for the other kinds
    /// (an anchor tap's reach is a circle around its point).
    public var fingerArea: NormalizedRect? {
        if case let .aim(area, _, _, _, _, _, _, _) = kind { area } else { nil }
    }

    /// Where an eye's finger touches down: its origin (the centre of its
    /// area unless the player moved it); nil for the other kinds.
    public var touchPoint: NormalizedPoint? {
        if case let .aim(area, _, _, _, _, _, _, origin) = kind { origin ?? area.center } else { nil }
    }

    /// Gives an eye `area`, its touch-down point kept inside (one at the
    /// centre stays at the centre).
    public mutating func setFingerArea(_ area: NormalizedRect) {
        guard case let .aim(_, sensitivity, ads, exponent, deadzone, invertY, stick, origin) = kind else { return }
        kind = .aim(area: area, sensitivity: sensitivity, adsSensitivity: ads, exponent: exponent, deadzone: deadzone,
                    invertY: invertY, stick: stick, origin: origin.map { area.clamp($0, inset: Self.eyeOriginInset) })
    }

    /// Moves an eye's touch-down point (nil: the centre of its area), kept inside the area.
    public mutating func setTouchPoint(_ point: NormalizedPoint?) {
        guard case let .aim(area, sensitivity, ads, exponent, deadzone, invertY, stick, _) = kind else { return }
        kind = .aim(area: area, sensitivity: sensitivity, adsSensitivity: ads, exponent: exponent, deadzone: deadzone,
                    invertY: invertY, stick: stick, origin: point.map { area.clamp($0, inset: Self.eyeOriginInset) })
    }

    /// Moves an eye's area together with its touch-down point, as far as the screen allows.
    public mutating func moveFinger(dx: Double, dy: Double) {
        guard case let .aim(area, sensitivity, ads, exponent, deadzone, invertY, stick, origin) = kind else { return }
        let moved = area.offsetBy(dx: dx, dy: dy)
        let ox = moved.minX - area.minX, oy = moved.minY - area.minY
        kind = .aim(area: moved, sensitivity: sensitivity, adsSensitivity: ads, exponent: exponent, deadzone: deadzone,
                    invertY: invertY, stick: stick, origin: origin.map { moved.clamp(NormalizedPoint($0.x + ox, $0.y + oy)) })
    }

    /// The rectangle the editor sizes on the game: an eye's swipe area, a
    /// click area, or another control's click zone; nil for none.
    public var area: NormalizedRect? {
        switch kind {
        case let .aim(area, _, _, _, _, _, _, _), let .clickArea(area, _): area
        default: clickZone?.area
        }
    }

    /// Gives an eye, a click area or a click zone `area` (an eye keeps its point inside).
    public mutating func setArea(_ area: NormalizedRect) {
        switch kind {
        case .aim: setFingerArea(area)
        case .clickArea(_, let passThrough): kind = .clickArea(area, passThrough: passThrough)
        default: clickZone?.area = area
        }
    }

    /// Moves an eye's, a click area's or a click zone's rectangle, as far as the screen allows.
    public mutating func moveArea(dx: Double, dy: Double) {
        switch kind {
        case .aim: moveFinger(dx: dx, dy: dy)
        case let .clickArea(area, passThrough): kind = .clickArea(area.offsetBy(dx: dx, dy: dy), passThrough: passThrough)
        default: if let zone = clickZone { clickZone?.area = zone.area.offsetBy(dx: dx, dy: dy) }
        }
    }

    /// A scroll bar's thumb at `fraction` of its track (0 at `from`), clamped to the track.
    public func scrollPoint(at fraction: Double) -> NormalizedPoint? {
        guard case let .scrollBar(from, to, _, _) = kind else { return nil }
        let t = min(max(fraction, 0), 1)
        return NormalizedPoint(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t)
    }

    /// Whether a scroll bar's track runs up and down the screen (else across it).
    public var isVerticalScrollBar: Bool {
        guard case let .scrollBar(from, to, _, _) = kind else { return false }
        return abs(to.y - from.y) >= abs(to.x - from.x)
    }
}

/// Where a click presses a control (`Control.clickZone`): a part of the
/// screen, as a rectangle, a rectangle with round corners, or the ellipse in
/// it. Encoded as `{"area": [x0, y0, x1, y1], "shape": "rounded"}`.
public struct ClickZone: Hashable, Sendable, Codable {
    public enum Shape: String, Codable, Sendable, CaseIterable {
        case rectangle, rounded, ellipse
    }

    public var area: NormalizedRect
    public var shape: Shape

    public init(area: NormalizedRect, shape: Shape = .rounded) {
        self.area = area
        self.shape = shape
    }

    private enum CodingKeys: String, CodingKey { case area, shape }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        area = try c.decode(NormalizedRect.self, forKey: .area)
        // A shape from a newer Avo is the plain one.
        shape = ((try? c.decodeIfPresent(Shape.self, forKey: .shape)) ?? nil) ?? .rounded
    }

    /// A rounded zone's corner radius: a quarter of its shorter side on the screen.
    public static let cornerFraction = 0.25

    /// Whether `point` is in the zone on a `width` × `height` display (its
    /// corners and ellipse are round on the screen, not in fractions).
    public func contains(_ point: NormalizedPoint, width: Double, height: Double) -> Bool {
        guard area.contains(point) else { return false }
        let w = area.width * width, h = area.height * height
        let x = (point.x - area.minX) * width, y = (point.y - area.minY) * height
        switch shape {
        case .rectangle:
            return true
        case .ellipse:
            guard w > 0, h > 0 else { return false }
            let dx = (x - w / 2) / (w / 2), dy = (y - h / 2) / (h / 2)
            return dx * dx + dy * dy <= 1
        case .rounded:
            let r = min(w, h) * Self.cornerFraction
            let cx = min(max(x, r), w - r), cy = min(max(y, r), h - r)
            return hypot(x - cx, y - cy) <= r
        }
    }
}

/// One entry of a profile's `controls`: a control, or the type of a control
/// this version does not know.
private struct ControlEntry: Decodable {
    var control: Control?
    var unsupportedType: String?
    /// A Switch Mode or Free/Lock the Mouse control of Avo before actions, read as a hotkey.
    var legacy = false

    private enum CodingKeys: String, CodingKey { case type }

    init(from decoder: any Decoder) throws {
        let type = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .type)
        if Control.knownTypes.contains(type) {
            control = try Control(from: decoder)
            legacy = Control.legacyTypes.contains(type)
        } else {
            unsupportedType = type
        }
    }
}

extension KeymapProfile {
    /// Avo's controls before actions, made actions: a Switch Mode or a
    /// Free/Lock the Mouse control on exactly the keys of a control of the
    /// game in exactly its modes (F: the game's Enter vehicle button, and
    /// the switch to the vehicle) becomes that control's action; others on
    /// the same keys in the same modes join one hotkey, in their order. A
    /// press does what it did: the touches first, then the actions.
    static func mergingLegacyControls(_ controls: [Control], legacy: Set<Int>) -> [Control] {
        func same(_ a: Control, _ b: Control) -> Bool {
            !a.triggers.isEmpty && Set(a.triggers) == Set(b.triggers) && a.modes.map(Set.init) == b.modes.map(Set.init)
        }
        // The game's button for each (anywhere in the layout: a switch may come before its button).
        var carried: [Int: [ControlAction]] = [:]
        var absorbed = Set<Int>()
        for index in controls.indices where legacy.contains(index) {
            let control = controls[index]
            guard let host = controls.indices.first(where: { !legacy.contains($0) && controls[$0].touchesTheScreen
                && controls[$0].canCarryActions && same(controls[$0], control) }) else { continue }
            carried[host, default: []] += control.actions
            absorbed.insert(index)
        }
        var merged: [Control] = []
        var hotkeys: [Int] = []
        for (index, control) in controls.enumerated() where !absorbed.contains(index) {
            if !legacy.contains(index) {
                var control = control
                control.actions += carried[index] ?? []
                merged.append(control)
            } else if let at = hotkeys.first(where: { same(merged[$0], control) }) {
                merged[at].actions += control.actions
            } else {
                hotkeys.append(merged.count)
                merged.append(control)
            }
        }
        return merged
    }
}

/// FPS mode (spec §5a).
public struct FPSSettings: Hashable, Sendable, Codable {
    /// Toggles between pointer lock (combat) and cursor mode (inventory, map).
    public var cursorToggle: Trigger
    /// The aim control that the mouse drives while the pointer is locked.
    public var aimControl: String

    /// F8 by default: a key games rarely use (fn+F8 on keyboards whose top
    /// row controls media).
    public static let defaultCursorToggle = Trigger.key(.f8)

    public init(cursorToggle: Trigger = FPSSettings.defaultCursorToggle, aimControl: String) {
        self.cursorToggle = cursorToggle
        self.aimControl = aimControl
    }

    private enum CodingKeys: String, CodingKey {
        case cursorToggle = "cursor_toggle", aimControl = "aim_control"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursorToggle = try c.decodeIfPresent(Trigger.self, forKey: .cursorToggle) ?? Self.defaultCursorToggle
        aimControl = try c.decode(String.self, forKey: .aimControl)
    }
}

/// A joystick (D-pad control) pushed further while a key is held: running,
/// in games that walk with the joystick partway and run with it all the way,
/// or lock a sprint past its edge.
public struct JoystickRun: Hashable, Sendable, Codable {
    /// Held to run: a key, a mouse button or a controller button.
    public var trigger: Trigger
    /// How far the finger goes meanwhile, in the joystick's radii.
    public var scale: Double

    public static let defaultScale = 1.6
    public static let scaleRange = 1.0...4.0

    public init(trigger: Trigger, scale: Double = JoystickRun.defaultScale) {
        self.trigger = trigger
        self.scale = scale
    }
}

/// One of a layout's modes, such as on foot and in a vehicle: controls act
/// in some modes or all of them (`Control.modes`), keys and controller
/// alike, and a control's Switch Mode action turns the layout to another. A game
/// starts in the first.
public struct KeymapMode: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// The mouse on entering the mode, with an eye: locked to it for mouse
    /// look (true), free for the cursor (false), or as it was (nil).
    public var mouseLook: Bool?

    public init(id: String, name: String, mouseLook: Bool? = nil) {
        self.id = id
        self.name = name
        self.mouseLook = mouseLook
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, mouseLook = "mouse_look"
    }
}

/// A keymapping profile for one Android package, stored as JSON so the
/// community can share them (spec §5).
public struct KeymapProfile: Hashable, Sendable, Codable {
    public static let currentSchema = 1

    public var schema: Int
    public var package: String
    public var name: String
    public var author: String?
    public var notes: String?
    public var controls: [Control]
    public var fps: FPSSettings?
    /// Where the player's character stands on the screen in a MOBA (the
    /// camera keeps it there): move-by-mouse and smart-cast controls aim
    /// from here to the cursor. Nil is the centre.
    public var hero: NormalizedPoint?
    /// The controller's sticks, vibration and saved controller presets
    /// (GamepadMapping.swift); nil uses the standard sticks.
    public var gamepad: GamepadSettings?
    /// Its modes (on foot, in a vehicle), the first where a game starts;
    /// none: one, with every control.
    public var modes: [KeymapMode] = []
    /// Types of controls in the file that this version of Avo does not know
    /// (a newer one wrote them). They are left out so the rest of the profile
    /// still loads; saving the profile again drops them.
    public private(set) var unsupportedControls: [String] = []

    public static let defaultHero = NormalizedPoint(0.5, 0.5)

    public init(schema: Int = KeymapProfile.currentSchema, package: String, name: String, author: String? = nil,
                notes: String? = nil, controls: [Control], fps: FPSSettings? = nil, hero: NormalizedPoint? = nil,
                gamepad: GamepadSettings? = nil, modes: [KeymapMode] = []) {
        self.schema = schema
        self.package = package
        self.name = name
        self.author = author
        self.notes = notes
        self.controls = controls
        self.fps = fps
        self.hero = hero
        self.gamepad = gamepad
        self.modes = modes
    }

    private enum CodingKeys: String, CodingKey {
        case schema, package, name, author, notes, controls, fps, hero, gamepad, modes
    }

    /// The mode a game starts in; nil without modes.
    public var firstMode: String? { modes.first?.id }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        package = try c.decode(String.self, forKey: .package)
        name = try c.decode(String.self, forKey: .name)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        // A control kind from a newer Avo is skipped instead of failing the
        // whole profile; a broken control of a known kind still fails it.
        let entries = try c.decode([ControlEntry].self, forKey: .controls)
        let known = entries.filter { $0.control != nil }
        controls = Self.mergingLegacyControls(known.compactMap(\.control),
                                              legacy: Set(known.indices.filter { known[$0].legacy }))
        unsupportedControls = entries.compactMap(\.unsupportedType)
        fps = try c.decodeIfPresent(FPSSettings.self, forKey: .fps)
        hero = try c.decodeIfPresent(NormalizedPoint.self, forKey: .hero)
        // Newer than the rest: a block this version cannot read leaves the
        // standard sticks, and the controls still load.
        gamepad = try? c.decodeIfPresent(GamepadSettings.self, forKey: .gamepad)
        modes = try c.decodeIfPresent([KeymapMode].self, forKey: .modes) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(package, forKey: .package)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(author, forKey: .author)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encode(controls, forKey: .controls)
        try c.encodeIfPresent(fps, forKey: .fps)
        try c.encodeIfPresent(hero, forKey: .hero)
        try c.encodeIfPresent(gamepad, forKey: .gamepad)
        if !modes.isEmpty { try c.encode(modes, forKey: .modes) }
    }

    public static func decode(_ data: Data) throws -> KeymapProfile {
        try JSONDecoder().decode(KeymapProfile.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

// MARK: - Validation

extension KeymapProfile {
    /// Fingers on Android's touch screen at the same time (its multitouch
    /// slots). A profile may have any number of controls; past this many
    /// fingers down, another control waits for one to lift.
    public static let maxPointers = 16
    public static let minimumMacroWait = 16
    public static let maximumMacroDuration = 10_000

    /// Problems that stop the profile from loading. Enforces the spec's hard
    /// limits: no recoil macros, auto-aim or automatic rapid fire.
    public func validate() -> [String] {
        var problems: [String] = []
        if schema != Self.currentSchema { problems.append(String(localized: "unsupported schema \(schema)", bundle: .avoKit)) }
        if package.isEmpty { problems.append(String(localized: "package is empty", bundle: .avoKit)) }
        if let hero, !hero.isInside {
            problems.append(String(localized: "the hero point \(String(describing: hero.x)), \(String(describing: hero.y)) is outside the screen", bundle: .avoKit))
        }
        if let gamepad { problems += gamepad.validate() }

        var modeIDs = Set<String>()
        for mode in modes {
            if mode.id.isEmpty || !modeIDs.insert(mode.id).inserted {
                problems.append(String(localized: "duplicate or empty mode id \(mode.id)", bundle: .avoKit))
            }
            if mode.name.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append(String(localized: "mode \(mode.id) has no name", bundle: .avoKit))
            }
        }
        // A trigger may activate several controls (they act together, such as
        // the game's Enter vehicle button and a switch to the vehicle mode).
        var ids = Set<String>()
        for control in controls {
            if !ids.insert(control.id).inserted { problems.append(String(localized: "duplicate control id \(control.id)", bundle: .avoKit)) }
            problems += validate(control)
            for mode in control.modes ?? [] where !modeIDs.contains(mode) {
                problems.append(String(localized: "\(control.id): no mode \(mode)", bundle: .avoKit))
            }
            for case .switchMode(let mode) in control.actions where !modeIDs.contains(mode) {
                problems.append(String(localized: "\(control.id): no mode \(mode) to switch to", bundle: .avoKit))
            }
            if control.actions.contains(where: \.isMouse), fps == nil {
                problems.append(String(localized: "\(control.id): locking or freeing the mouse needs the eye (mouse look)", bundle: .avoKit))
            }
        }
        if let fps {
            let aims = controls.filter { if case .aim = $0.kind { return true } else { return false } }
            guard let aim = controls.first(where: { $0.id == fps.aimControl }), case .aim(let area, _, _, _, _, _, _, _) = aim.kind else {
                problems.append(String(localized: "fps.aim_control must name an aim control", bundle: .avoKit))
                return problems
            }
            if aims.count > 1 { problems.append(String(localized: "FPS mode supports one aim control", bundle: .avoKit)) }
            for control in controls {
                switch control.kind {
                case .repeatTap:
                    problems.append(String(localized: "\(control.id): repeated taps are not allowed in FPS mode (no automatic rapid fire)", bundle: .avoKit))
                case .macro:
                    problems.append(String(localized: "\(control.id): macros are not allowed in FPS mode (no recoil or fire macros)", bundle: .avoKit))
                case let .swipe(from, to, _) where area.contains(from) || area.contains(to):
                    problems.append(String(localized: "\(control.id): swipes may not touch the aim area (no recoil compensation)", bundle: .avoKit))
                default:
                    break
                }
            }
        }
        return problems
    }

    private func validate(_ control: Control) -> [String] {
        var problems: [String] = []
        let name = control.id
        func point(_ p: NormalizedPoint) {
            if !p.isInside { problems.append(String(localized: "\(name): position \(String(describing: p.x)), \(String(describing: p.y)) is outside the screen", bundle: .avoKit)) }
        }
        if let size = control.size, !Control.sizeRange.contains(size) {
            problems.append(String(localized: "\(name): size must be between \(Control.sizeRange.lowerBound) and \(Control.sizeRange.upperBound)", bundle: .avoKit))
        }
        switch control.kind {
        case .tap(let p), .hold(let p), .ads(let p, _), .anchor(let p, _):
            point(p)
            if control.triggers.isEmpty { problems.append(String(localized: "\(name): needs a trigger", bundle: .avoKit)) }
            if case .anchor(_, let radius?) = control.kind, !Control.anchorRadiusRange.contains(radius) {
                problems.append(String(localized: "\(name): anchor reach must be between 0.03 and 1", bundle: .avoKit))
            }
        case .hotkey:
            if control.triggers.isEmpty { problems.append(String(localized: "\(name): needs a trigger", bundle: .avoKit)) }
            if control.actions.isEmpty { problems.append(String(localized: "\(name): does nothing yet: add an action", bundle: .avoKit)) }
        case let .clickArea(area, _):
            if !area.isValid { problems.append(String(localized: "\(name): click area is invalid", bundle: .avoKit)) }
            if control.actions.isEmpty { problems.append(String(localized: "\(name): does nothing yet: add an action", bundle: .avoKit)) }
        case let .scrollBar(from, to, rest, step):
            point(from)
            point(to)
            if hypot(to.x - from.x, to.y - from.y) < Control.minimumScrollTrack / 2 {
                problems.append(String(localized: "\(name): the scroll bar's track is too short", bundle: .avoKit))
            }
            if !(0...1).contains(rest) { problems.append(String(localized: "\(name): the rest point must be on the track", bundle: .avoKit)) }
            if !Control.scrollStepRange.contains(step) {
                problems.append(String(localized: "\(name): a step must be 1 to 50% of the track", bundle: .avoKit))
            }
            if control.reset?.isMomentary == true { problems.append(String(localized: "\(name): the wheel cannot reset a scroll bar", bundle: .avoKit)) }
        case let .repeatTap(p, interval):
            point(p)
            if control.triggers.isEmpty { problems.append(String(localized: "\(name): needs a trigger", bundle: .avoKit)) }
            if interval < 50 { problems.append(String(localized: "\(name): repeat interval must be at least 50 ms", bundle: .avoKit)) }
        case let .dpad(center, radius, up, down, left, right, _):
            point(center)
            if !(0.01...0.5).contains(radius) { problems.append(String(localized: "\(name): radius must be between 0.01 and 0.5", bundle: .avoKit)) }
            if let run = control.run {
                if !JoystickRun.scaleRange.contains(run.scale) {
                    problems.append(String(localized: "\(name): running reach must be 1 to 4 times the joystick's", bundle: .avoKit))
                }
                if [up, down, left, right].contains(run.trigger) {
                    problems.append(String(localized: "\(name): the key to run is also a direction", bundle: .avoKit))
                }
                if run.trigger.isMomentary { problems.append(String(localized: "\(name): the wheel cannot be held to run", bundle: .avoKit)) }
            }
        case let .mobaMove(center, radius):
            point(center)
            if control.triggers.isEmpty { problems.append(String(localized: "\(name): needs a trigger", bundle: .avoKit)) }
            if !(0.01...0.5).contains(radius) { problems.append(String(localized: "\(name): radius must be between 0.01 and 0.5", bundle: .avoKit)) }
        case let .smartCast(p, radius, reach):
            point(p)
            if control.triggers.isEmpty { problems.append(String(localized: "\(name): needs a trigger", bundle: .avoKit)) }
            if !(0.01...0.5).contains(radius) { problems.append(String(localized: "\(name): radius must be between 0.01 and 0.5", bundle: .avoKit)) }
            if !Control.castReachRange.contains(reach) { problems.append(String(localized: "\(name): reach must be between 0.05 and 2", bundle: .avoKit)) }
        case let .aim(area, sensitivity, ads, exponent, deadzone, _, _, origin):
            if !area.isValid { problems.append(String(localized: "\(name): aim area is invalid", bundle: .avoKit)) }
            if let origin, !area.contains(origin) {
                problems.append(String(localized: "\(name): touch-down point must be inside the aim area", bundle: .avoKit))
            }
            for s in [sensitivity.x, sensitivity.y, ads.x, ads.y] where !(0.01...20).contains(s) {
                problems.append(String(localized: "\(name): sensitivity must be between 0.01 and 20", bundle: .avoKit))
                break
            }
            if !(0.5...3).contains(exponent) { problems.append(String(localized: "\(name): curve exponent must be between 0.5 and 3", bundle: .avoKit)) }
            if !(0...50).contains(deadzone) { problems.append(String(localized: "\(name): deadzone must be between 0 and 50", bundle: .avoKit)) }
        case let .swipe(from, to, ms):
            point(from)
            point(to)
            if control.triggers.isEmpty { problems.append(String(localized: "\(name): needs a trigger", bundle: .avoKit)) }
            if !(30...2000).contains(ms) { problems.append(String(localized: "\(name): swipe duration must be 30–2000 ms", bundle: .avoKit)) }
        case .macro(let steps):
            if control.triggers.isEmpty { problems.append(String(localized: "\(name): needs a trigger", bundle: .avoKit)) }
            if steps.isEmpty || steps.count > 32 { problems.append(String(localized: "\(name): macros need 1–32 steps", bundle: .avoKit)) }
            var total = 0
            for step in steps {
                switch step {
                case .tap(let p): point(p)
                case let .hold(p, ms):
                    point(p)
                    if ms < Self.minimumMacroWait { problems.append(String(localized: "\(name): holds must last at least \(Self.minimumMacroWait) ms", bundle: .avoKit)) }
                case .wait(let ms):
                    if ms < Self.minimumMacroWait { problems.append(String(localized: "\(name): waits must be at least \(Self.minimumMacroWait) ms", bundle: .avoKit)) }
                }
                total += step.duration
            }
            if total > Self.maximumMacroDuration { problems.append(String(localized: "\(name): macros may run at most 10 s", bundle: .avoKit)) }
        }
        if control.allTriggers.contains(where: \.isMomentary) {
            switch control.kind {
            case .tap, .swipe, .macro, .hotkey, .scrollBar: break
            default: problems.append(String(localized: "\(name): scroll triggers only work with tap, swipe, macro and hotkey controls", bundle: .avoKit))
            }
        }
        if let zone = control.clickZone {
            if !zone.area.isValid { problems.append(String(localized: "\(name): click area is invalid", bundle: .avoKit)) }
            if !control.canHaveClickZone { problems.append(String(localized: "\(name): this kind of control cannot be clicked", bundle: .avoKit)) }
        }
        if !control.actions.isEmpty, !control.canCarryActions {
            problems.append(String(localized: "\(name): a joystick or the eye cannot do actions", bundle: .avoKit))
        }
        return problems
    }
}

// MARK: - Lookup

extension KeymapProfile {
    /// The profile a window uses: the user's (`paths.keymap(for:)`) when it
    /// decodes and validates, else the one shipped with Avo,
    /// `<bundledDirectory>/<package>.json`, under the same rule. It is also
    /// the one definition of "this app has a key mapping", which gives the
    /// app the Games graphics defaults, so the profile and the graphics
    /// always agree.
    public static func usable(for package: String, bundledDirectory: URL?,
                              paths: AvoPaths = AvoPaths()) -> (profile: KeymapProfile, url: URL)? {
        let candidates = [paths.keymap(for: package), bundledDirectory?.appending(path: "\(package).json")]
        for case let url? in candidates {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let profile = try decode(data)
                let problems = profile.validate()
                guard problems.isEmpty else {
                    lookupLogger.error("ignoring \(url.lastPathComponent, privacy: .public): \(problems.joined(separator: "; "), privacy: .public)")
                    continue
                }
                return (profile, url)
            } catch {
                lookupLogger.error("cannot read \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }
}

private let lookupLogger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Keymap")
