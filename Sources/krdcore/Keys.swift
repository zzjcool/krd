import Foundation

/// Key codes, layouts and the modifier arithmetic (issue #45): plain numbers, no CoreGraphics.
/// The values are the macOS virtual key codes, but nothing here requires a Mac to compile.

public enum Keys {
    public static let enter: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let backspace: UInt16 = 51
    public static let esc: UInt16 = 53
    public static let forwardDelete: UInt16 = 117
    public static let home: UInt16 = 115
    public static let end: UInt16 = 119
    public static let pageUp: UInt16 = 116
    public static let pageDown: UInt16 = 121
    public static let left: UInt16 = 123
    public static let right: UInt16 = 124
    public static let down: UInt16 = 125
    public static let up: UInt16 = 126

    /// Function keys, by the macOS virtual key code that posts them. Named on purpose: the
    /// terminal numbers them differently (`ESC [ 23 ~` is F11), and relating the two numberings
    /// by subtraction is what indexed off the end of an array in #14.
    public static let f1: UInt16 = 122
    public static let f2: UInt16 = 120
    public static let f3: UInt16 = 99
    public static let f4: UInt16 = 118
    public static let f5: UInt16 = 96
    public static let f6: UInt16 = 97
    public static let f7: UInt16 = 98
    public static let f8: UInt16 = 100
    public static let f9: UInt16 = 101
    public static let f10: UInt16 = 109
    public static let f11: UInt16 = 103
    public static let f12: UInt16 = 111
    public static let f13: UInt16 = 105
    public static let f14: UInt16 = 107

    /// US/ANSI virtual key codes for unshifted characters.
    public static let map: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, "`": 50, " ": space
    ]

    /// Shifted symbol -> the key you actually press.
    public static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
        "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`"
    ]

    /// `ESC [ <code> ~` → the key it presses, keyed by the terminal's number (the numbered-key
    /// table in PROTOCOL.md §7.2). A number that is absent is simply ignored, so nothing can be
    /// subtracted or clamped into a neighbour's key. 16 and 22 are gaps in that numbering.
    public static let numbered: [Int: UInt16] = [
        1: home, 2: home, 3: forwardDelete, 4: end, 5: pageUp, 6: pageDown, 7: home, 8: end,
        11: f1, 12: f2, 13: f3, 14: f4, 15: f5,
        17: f6, 18: f7, 19: f8, 20: f9, 21: f10,
        23: f11, 24: f12, 25: f13, 26: f14
    ]

    /// `ESC O P` … `ESC O S`: the SS3 spelling of F1–F4, resolved through `numbered` rather than
    /// repeated, so the two spellings cannot drift apart. `compactMapValues` means a renamed row
    /// would take the SS3 spelling *dead* rather than *wrong*, so the four entries are pinned by
    /// `Tests/krdTests/InputTests.swift`.
    public static let ss3Function: [Character: UInt16] =
        ["P": 11, "Q": 12, "R": 13, "S": 14].compactMapValues { numbered[$0] }

    /// The modifier parameter of a CSI report, decoded: `mods - 1`, then bits 1/2/4/8. xterm encodes
    /// it the same way but calls bit 8 Meta; krd reads it as cmd (PROTOCOL.md §7.2). Shared by the
    /// whole family, because `ESC [ 1;…A` and `ESC [ <n>;…~` use the same encoding.
    public static func modifierFlags(_ numbers: [Int]) -> Modifiers {
        guard numbers.count >= 2 else { return [] }
        let mods = numbers[1] - 1
        var flags: Modifiers = []
        if mods & 1 != 0 { flags.insert(.maskShift) }
        if mods & 2 != 0 { flags.insert(.maskAlternate) }
        if mods & 4 != 0 { flags.insert(.maskControl) }
        if mods & 8 != 0 { flags.insert(.maskCommand) }
        return flags
    }

    /// `ESC [ <n> ; <mods> ~` as data: the key it presses and the modifiers that ride with it.
    /// Pure — no `CGEvent`, no tty, no buffer — so the tests can drive the parser's decision
    /// instead of only the table under it. Returns nil for a number we do not map.
    public static func numberedPress(_ numbers: [Int]) -> (key: UInt16, flags: Modifiers)? {
        guard let key = numbered[numbers.first ?? 0] else { return nil }
        return (key, modifierFlags(numbers))
    }
}
