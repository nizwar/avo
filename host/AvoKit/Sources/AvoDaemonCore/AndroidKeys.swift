import AvoKit

/// Android key codes (what App Shims send) to Linux evdev codes (what the
/// engine's virtio keyboard reports; Android maps them back through
/// Generic.kl), plus ASCII to key strokes for text input.
enum AndroidKeys {
    static let linux = PhysicalKeyboard.linux

    static let leftShift: UInt16 = 42
    /// KeyEvent.KEYCODE_BACK.
    static let back: UInt32 = 4

    /// The modifier keys a META_* state holds: Android key code
    /// (KEYCODE_CTRL_LEFT …) and evdev code (KEY_LEFTCTRL …).
    static func modifiers(in metaState: UInt32) -> [(android: UInt32, linux: UInt16)] {
        let pairs: [(mask: UInt32, leftFlag: UInt32, rightFlag: UInt32, left: (UInt32, UInt16), right: (UInt32, UInt16))] = [
            (0x1000, 0x2000, 0x4000, (113, 29), (114, 97)),
            (0x01, 0x40, 0x80, (59, 42), (60, 54)),
            (0x02, 0x10, 0x20, (57, 56), (58, 100)),
            (0x10000, 0x20000, 0x40000, (117, 125), (118, 126)),
        ]
        var result: [(UInt32, UInt16)] = []
        for pair in pairs where metaState & (pair.mask | pair.leftFlag | pair.rightFlag) != 0 {
            if metaState & pair.rightFlag == 0 || metaState & pair.leftFlag != 0 { result.append(pair.left) }
            if metaState & pair.rightFlag != 0 { result.append(pair.right) }
        }
        return result
    }

    /// A Mac candidate can contain both Han characters and Latin letters. Committing it
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
