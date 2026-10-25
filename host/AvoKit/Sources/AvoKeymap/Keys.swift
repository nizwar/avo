import Foundation

/// A physical key, named independently of the keyboard layout (positions of a
/// US ANSI keyboard), so profiles work on every Mac keyboard.
public enum KeyName: String, Codable, CaseIterable, Sendable {
    case a = "A", b = "B", c = "C", d = "D", e = "E", f = "F", g = "G", h = "H", i = "I", j = "J"
    case k = "K", l = "L", m = "M", n = "N", o = "O", p = "P", q = "Q", r = "R", s = "S", t = "T"
    case u = "U", v = "V", w = "W", x = "X", y = "Y", z = "Z"
    case digit0 = "0", digit1 = "1", digit2 = "2", digit3 = "3", digit4 = "4"
    case digit5 = "5", digit6 = "6", digit7 = "7", digit8 = "8", digit9 = "9"
    case space = "Space", tab = "Tab", returnKey = "Return", escape = "Escape", delete = "Delete"
    case forwardDelete = "ForwardDelete", capsLock = "CapsLock"
    case shift = "Shift", rightShift = "RightShift", control = "Control", rightControl = "RightControl"
    case option = "Option", rightOption = "RightOption", command = "Command", rightCommand = "RightCommand"
    case up = "Up", down = "Down", left = "Left", right = "Right"
    case minus = "Minus", equal = "Equal", leftBracket = "LeftBracket", rightBracket = "RightBracket"
    case backslash = "Backslash", semicolon = "Semicolon", quote = "Quote", comma = "Comma"
    case period = "Period", slash = "Slash", grave = "Grave"
    case home = "Home", end = "End", pageUp = "PageUp", pageDown = "PageDown"
    case f1 = "F1", f2 = "F2", f3 = "F3", f4 = "F4", f5 = "F5", f6 = "F6"
    case f7 = "F7", f8 = "F8", f9 = "F9", f10 = "F10", f11 = "F11", f12 = "F12"

    public var isModifier: Bool {
        switch self {
        case .shift, .rightShift, .control, .rightControl, .option, .rightOption, .command, .rightCommand, .capsLock: true
        default: false
        }
    }
}

/// Mac virtual key codes (Carbon kVK_*) and their Android KeyEvent codes.
public enum KeyboardMapping {
    private static let table: [(mac: UInt16, key: KeyName, android: UInt32)] = [
        (0x00, .a, 29), (0x0B, .b, 30), (0x08, .c, 31), (0x02, .d, 32), (0x0E, .e, 33), (0x03, .f, 34),
        (0x05, .g, 35), (0x04, .h, 36), (0x22, .i, 37), (0x26, .j, 38), (0x28, .k, 39), (0x25, .l, 40),
        (0x2E, .m, 41), (0x2D, .n, 42), (0x1F, .o, 43), (0x23, .p, 44), (0x0C, .q, 45), (0x0F, .r, 46),
        (0x01, .s, 47), (0x11, .t, 48), (0x20, .u, 49), (0x09, .v, 50), (0x0D, .w, 51), (0x07, .x, 52),
        (0x10, .y, 53), (0x06, .z, 54),
        (0x1D, .digit0, 7), (0x12, .digit1, 8), (0x13, .digit2, 9), (0x14, .digit3, 10), (0x15, .digit4, 11),
        (0x17, .digit5, 12), (0x16, .digit6, 13), (0x1A, .digit7, 14), (0x1C, .digit8, 15), (0x19, .digit9, 16),
        (0x31, .space, 62), (0x30, .tab, 61), (0x24, .returnKey, 66), (0x35, .escape, 111),
        (0x33, .delete, 67), (0x75, .forwardDelete, 112), (0x39, .capsLock, 115),
        (0x38, .shift, 59), (0x3C, .rightShift, 60), (0x3B, .control, 113), (0x3E, .rightControl, 114),
        (0x3A, .option, 57), (0x3D, .rightOption, 58), (0x37, .command, 117), (0x36, .rightCommand, 118),
        (0x7E, .up, 19), (0x7D, .down, 20), (0x7B, .left, 21), (0x7C, .right, 22),
        (0x1B, .minus, 69), (0x18, .equal, 70), (0x21, .leftBracket, 71), (0x1E, .rightBracket, 72),
        (0x2A, .backslash, 73), (0x29, .semicolon, 74), (0x27, .quote, 75), (0x2B, .comma, 55),
        (0x2F, .period, 56), (0x2C, .slash, 76), (0x32, .grave, 68),
        (0x73, .home, 122), (0x77, .end, 123), (0x74, .pageUp, 92), (0x79, .pageDown, 93),
        (0x7A, .f1, 131), (0x78, .f2, 132), (0x63, .f3, 133), (0x76, .f4, 134), (0x60, .f5, 135),
        (0x61, .f6, 136), (0x62, .f7, 137), (0x64, .f8, 138), (0x65, .f9, 139), (0x6D, .f10, 140),
        (0x67, .f11, 141), (0x6F, .f12, 142),
    ]

    private static let byMac: [UInt16: (KeyName, UInt32)] = Dictionary(uniqueKeysWithValues: table.map { ($0.mac, ($0.key, $0.android)) })
    private static let byName: [KeyName: (UInt16, UInt32)] = Dictionary(uniqueKeysWithValues: table.map { ($0.key, ($0.mac, $0.android)) })

    public static func key(forMacKeyCode code: UInt16) -> KeyName? { byMac[code]?.0 }
    public static func androidKeyCode(forMacKeyCode code: UInt16) -> UInt32? { byMac[code]?.1 }
    public static func androidKeyCode(for key: KeyName) -> UInt32? { byName[key]?.1 }
    public static func macKeyCode(for key: KeyName) -> UInt16? { byName[key]?.0 }

    /// Android KEYCODE_BACK, sent for Esc and the two-finger swipe left (spec §1).
    public static let androidBack: UInt32 = 4

    /// Android META_* bits for the modifiers currently held.
    public static func androidMetaState(shift: Bool, control: Bool, option: Bool, command: Bool, capsLock: Bool) -> UInt32 {
        var meta: UInt32 = 0
        if shift { meta |= 0x01 | 0x40 }        // META_SHIFT_ON | META_SHIFT_LEFT_ON
        if option { meta |= 0x02 | 0x10 }       // META_ALT_ON | META_ALT_LEFT_ON
        if control { meta |= 0x1000 | 0x2000 }  // META_CTRL_ON | META_CTRL_LEFT_ON
        if command { meta |= 0x10000 | 0x20000 } // META_META_ON | META_META_LEFT_ON
        if capsLock { meta |= 0x100000 }        // META_CAPS_LOCK_ON
        return meta
    }
}

public enum MouseButton: String, Codable, CaseIterable, Sendable {
    case left, right, middle, button4, button5

    public init?(buttonNumber: Int) {
        switch buttonNumber {
        case 0: self = .left
        case 1: self = .right
        case 2: self = .middle
        case 3: self = .button4
        case 4: self = .button5
        default: return nil
        }
    }

    /// Its number in NSEvent (`buttonNumber`, the bits of `pressedMouseButtons`).
    public var buttonNumber: Int {
        switch self {
        case .left: 0
        case .right: 1
        case .middle: 2
        case .button4: 3
        case .button5: 4
        }
    }
}

/// Buttons of an extended gamepad (GameController.framework names).
public enum GamepadButton: String, Codable, CaseIterable, Sendable {
    case a, b, x, y
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case leftThumbstick, rightThumbstick, menu, options

    /// Bit in GamepadState.buttons (Input channel).
    public var bit: UInt32 { 1 << UInt32(Self.allCases.firstIndex(of: self)!) }
}

public enum GamepadStick: String, Codable, CaseIterable, Sendable {
    case left, right
}

/// Anything a control can be bound to. Encoded as "key:W", "mouse:left",
/// "scroll:up", "pad:a".
public enum Trigger: Hashable, Sendable, Codable, CustomStringConvertible {
    case key(KeyName)
    case mouse(MouseButton)
    case scrollUp
    case scrollDown
    case gamepad(GamepadButton)

    public var description: String {
        switch self {
        case .key(let key): "key:\(key.rawValue)"
        case .mouse(let button): "mouse:\(button.rawValue)"
        case .scrollUp: "scroll:up"
        case .scrollDown: "scroll:down"
        case .gamepad(let button): "pad:\(button.rawValue)"
        }
    }

    public init?(string: String) {
        let parts = string.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "key": guard let key = KeyName(rawValue: parts[1]) else { return nil }; self = .key(key)
        case "mouse": guard let button = MouseButton(rawValue: parts[1]) else { return nil }; self = .mouse(button)
        case "scroll":
            switch parts[1] {
            case "up": self = .scrollUp
            case "down": self = .scrollDown
            default: return nil
            }
        case "pad": guard let button = GamepadButton(rawValue: parts[1]) else { return nil }; self = .gamepad(button)
        default: return nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let trigger = Trigger(string: string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown trigger \(string)"))
        }
        self = trigger
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// Scroll ticks are instantaneous, so they can only drive tap-like controls.
    public var isMomentary: Bool { self == .scrollUp || self == .scrollDown }

    /// A game controller button, as opposed to the keyboard and mouse.
    public var isGamepad: Bool {
        if case .gamepad = self { true } else { false }
    }
}
