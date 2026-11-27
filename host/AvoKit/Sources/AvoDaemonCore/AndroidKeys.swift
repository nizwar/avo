/// Android key codes (what App Shims send) to Linux evdev codes (what the
/// engine's virtio keyboard reports; Android maps them back through
/// Generic.kl), plus ASCII to key strokes for text input.
enum AndroidKeys {
    /// KeyEvent.KEYCODE_* → linux/input-event-codes.h KEY_*.
    static let linux: [UInt32: UInt16] = {
        var map: [UInt32: UInt16] = [
            3: 172, 4: 158, 19: 103, 20: 108, 21: 105, 22: 106, 23: 353, 24: 115, 25: 114, 26: 116,
            55: 51, 56: 52, 57: 56, 58: 100, 59: 42, 60: 54, 61: 15, 62: 57, 66: 28, 67: 14, 68: 41,
            69: 12, 70: 13, 71: 26, 72: 27, 73: 43, 74: 39, 75: 40, 76: 53, 82: 139, 92: 104, 93: 109,
            111: 1, 112: 111, 113: 29, 114: 97, 115: 58, 117: 125, 118: 126, 122: 102, 123: 107, 124: 110,
        ]
        // KEYCODE_0..9 = 7..16; KEY_1..KEY_9 = 2..10, KEY_0 = 11.
        map[7] = 11
        for digit in 1...9 { map[UInt32(7 + digit)] = UInt16(1 + digit) }
        // KEYCODE_A..Z = 29..54 in alphabetical order; evdev follows the QWERTY rows.
        let letters: [UInt16] = [30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44]
        for (i, code) in letters.enumerated() { map[UInt32(29 + i)] = code }
        // KEYCODE_F1..F12 = 131..142.
        let functions: [UInt16] = [59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 87, 88]
        for (i, code) in functions.enumerated() { map[UInt32(131 + i)] = code }
        return map
    }()

    static let leftShift: UInt16 = 42
    /// KeyEvent.KEYCODE_V and META_CTRL_ON: Ctrl+V, Android's paste.
    static let v: UInt32 = 50
    static let metaCtrlOn: UInt32 = 0x1000
    /// KeyEvent.KEYCODE_BACK.
    static let back: UInt32 = 4

    /// The left-hand modifier keys a META_* state holds: Android key code
    /// (KEYCODE_CTRL_LEFT …) and evdev code (KEY_LEFTCTRL …).
    static func modifiers(in metaState: UInt32) -> [(android: UInt32, linux: UInt16)] {
        let table: [(meta: UInt32, android: UInt32, linux: UInt16)] = [
            (0x1000, 113, 29),   // META_CTRL_ON
            (0x01, 59, 42),      // META_SHIFT_ON
            (0x02, 57, 56),      // META_ALT_ON
            (0x10000, 117, 125), // META_META_ON
        ]
        return table.filter { metaState & $0.meta != 0 }.map { ($0.android, $0.linux) }
    }

    /// A Mac candidate can contain both Han characters and Latin letters. Pasting it
    /// whole keeps Android's active input method from composing the letters again.
    static func canTypeAsKeys(_ text: String) -> Bool {
        text.allSatisfy { strokes(for: $0) != nil }
    }

    /// Key strokes that type `character` on a US layout: (evdev code, shift).
    static func strokes(for character: Character) -> (UInt16, Bool)? {
        let lower = "abcdefghijklmnopqrstuvwxyz"
        let letters: [UInt16] = [30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44]
        if let index = lower.firstIndex(of: character) {
            return (letters[lower.distance(from: lower.startIndex, to: index)], false)
        }
        if let index = lower.uppercased().firstIndex(of: character) {
            let upper = lower.uppercased()
            return (letters[upper.distance(from: upper.startIndex, to: index)], true)
        }
        let plain: [Character: UInt16] = [
            "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8, "8": 9, "9": 10, "0": 11,
            "-": 12, "=": 13, "[": 26, "]": 27, ";": 39, "'": 40, "`": 41, "\\": 43, ",": 51, ".": 52, "/": 53,
            " ": 57, "\n": 28, "\t": 15,
        ]
        if let code = plain[character] { return (code, false) }
        let shifted: [Character: UInt16] = [
            "!": 2, "@": 3, "#": 4, "$": 5, "%": 6, "^": 7, "&": 8, "*": 9, "(": 10, ")": 11,
            "_": 12, "+": 13, "{": 26, "}": 27, ":": 39, "\"": 40, "~": 41, "|": 43, "<": 51, ">": 52, "?": 53,
        ]
        if let code = shifted[character] { return (code, true) }
        return nil
    }
}
