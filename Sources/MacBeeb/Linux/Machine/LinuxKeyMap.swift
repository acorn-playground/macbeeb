import CGtk

/// PC keys as the Mac's key codes, by position, so the rest of the
/// keyboard handling (KeyboardTranslator, the BBC layout, custom mappings
/// and their saved settings) is the Mac's, shared.
///
/// GDK gives a key's hardware code: Linux's evdev code plus 8, on X11 and
/// Wayland alike. The Mac's codes are ANSI/ISO positions, as evdev's are.
enum LinuxKeyMap {
    /// The Mac key code for a GDK hardware keycode.
    static func macKeyCode(_ hardware: UInt32) -> UInt16? {
        guard hardware >= 8 else { return nil }
        return evdev[UInt16(hardware - 8)]
    }

    /// evdev code -> Mac virtual key code.
    static let evdev: [UInt16: UInt16] = [
        // Number row. The key left of 1 is the Mac ANSI grave key's place.
        41: 0x32, 2: 0x12, 3: 0x13, 4: 0x14, 5: 0x15, 6: 0x17, 7: 0x16, 8: 0x1A, 9: 0x1C, 10: 0x19, 11: 0x1D,
        12: 0x1B, 13: 0x18, 14: 0x33,
        // Top letter row.
        15: 0x30, 16: 0x0C, 17: 0x0D, 18: 0x0E, 19: 0x0F, 20: 0x11, 21: 0x10, 22: 0x20, 23: 0x22, 24: 0x1F, 25: 0x23,
        26: 0x21, 27: 0x1E, 28: 0x24,
        // Home row (43 is above Return on ANSI, left of it on ISO: the
        // Mac's backslash both ways).
        58: 0x39, 30: 0x00, 31: 0x01, 32: 0x02, 33: 0x03, 34: 0x05, 35: 0x04, 36: 0x26, 37: 0x28, 38: 0x25,
        39: 0x29, 40: 0x27, 43: 0x2A,
        // Bottom row; 86 is ISO's extra key by left Shift (the Mac's ISO
        // section key).
        42: 0x38, 86: 0x0A, 44: 0x06, 45: 0x07, 46: 0x08, 47: 0x09, 48: 0x0B, 49: 0x2D, 50: 0x2E, 51: 0x2B,
        52: 0x2F, 53: 0x2C, 54: 0x3C,
        // Space and modifiers: Alt is the Mac's Option (Left Alt is
        // MacBeeb's own shortcut key; see `reservedForShortcuts`), Super its
        // Command.
        57: 0x31, 29: 0x3B, 97: 0x3E, 56: 0x3A, 100: 0x3D, 125: 0x37, 126: 0x36,
        // Escape and function keys.
        1: 0x35, 59: 0x7A, 60: 0x78, 61: 0x63, 62: 0x76, 63: 0x60, 64: 0x61, 65: 0x62, 66: 0x64, 67: 0x65,
        68: 0x6D, 87: 0x67, 88: 0x6F, 183: 0x69, 184: 0x6B, 185: 0x71, 186: 0x6A, 187: 0x40, 188: 0x4F,
        189: 0x50, 190: 0x5A,
        // Print Screen, Scroll Lock and Pause, as a Mac extended keyboard
        // has them: F13, F14, F15.
        99: 0x69, 70: 0x6B, 119: 0x71,
        // Editing keys: Insert is the Mac's Help.
        110: 0x72, 102: 0x73, 104: 0x74, 111: 0x75, 107: 0x77, 109: 0x79,
        // Arrows.
        105: 0x7B, 106: 0x7C, 108: 0x7D, 103: 0x7E,
        // Keypad: Num Lock is the Mac's Clear.
        69: 0x47, 98: 0x4B, 55: 0x43, 74: 0x4E, 71: 0x59, 72: 0x5B, 73: 0x5C, 78: 0x45, 75: 0x56, 76: 0x57,
        77: 0x58, 79: 0x53, 80: 0x54, 81: 0x55, 96: 0x4C, 82: 0x52, 83: 0x41, 117: 0x51,
    ]

    /// Left Alt: the key the app's own shortcuts use in a machine window
    /// (the BBC has no Alt, as it has no Command), so it never reaches the
    /// BBC. (Right Alt is the BBC's Shift Lock, as Option is on the Mac.)
    static let reservedForShortcuts: UInt16 = 0x3A

    /// Modifier keys by Mac code, which the translator hears as changes
    /// of modifiers, as the Mac reports them.
    static let modifierKeys: Set<UInt16> = [0x38, 0x3C, 0x3B, 0x3E, 0x3A, 0x3D, 0x37, 0x36, 0x39]
}
