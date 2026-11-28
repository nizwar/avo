/// Physical keyboard positions shared by the Mac event source and the virtio keyboard.
public enum PhysicalKeyboard {
    /// KeyEvent.KEYCODE_* → linux/input-event-codes.h KEY_*.
    public static let linux: [UInt32: UInt16] = {
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

    /// Carbon kVK positions outside the keymap editor’s ANSI keyboard.
    public static let extra: [UInt16: (code: UInt32, scan: UInt16)] = [
        0x0a: (73, 86), 0x5d: (216, 124), 0x5e: (217, 89), 0x5f: (159, 121),
        0x66: (212, 123), 0x68: (218, 122), 0x41: (158, 83), 0x43: (155, 55),
        0x45: (157, 78), 0x47: (143, 69), 0x4b: (154, 98), 0x4c: (160, 96),
        0x4e: (156, 74), 0x51: (161, 117), 0x52: (144, 82), 0x53: (145, 79),
        0x54: (146, 80), 0x55: (147, 81), 0x56: (148, 75), 0x57: (149, 76),
        0x58: (150, 77), 0x59: (151, 71), 0x5b: (152, 72), 0x5c: (153, 73),
    ]
}
