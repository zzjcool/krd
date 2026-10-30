import Foundation

/// Display width in terminal cells: ASCII is 1, CJK and emoji are 2, combining marks are 0.
///
/// `String.count` is the number of extended grapheme clusters, which is not what a terminal
/// draws: "访达" is two characters and four cells, and a window title with a Chinese app name
/// would push everything after it right, break every column in a panel, and truncate in the
/// middle of a glyph. This is the table the chrome needs, vendored rather than depended on
/// (issue #8): the ranges below are EastAsianWidth plus the emoji-presentation case.
enum DisplayWidth {
    /// Cells this scalar occupies, ignoring context. 0 = combining/joiner, 2 = wide.
    static func of(_ scalar: UnicodeScalar) -> Int {
        let v = scalar.value
        if v == 0xFE0F { return 2 }                       // variation selector 16: emoji presentation
        if isZeroWidth(v) { return 0 }
        return isWide(v) ? 2 : 1
    }

    /// Cells this character occupies. A cluster is as wide as its widest scalar, so a ZWJ
    /// sequence ("👨‍👩‍👧") counts once and "é" written as e + U+0301 still counts as 1.
    static func of(_ ch: Character) -> Int {
        var width = 0
        for scalar in ch.unicodeScalars {
            width = max(width, of(scalar))
            if width == 2 { break }
        }
        return width
    }

    static func of(_ s: String) -> Int {
        s.reduce(0) { $0 + of($1) }
    }

    /// Cut to at most `cells` columns without splitting a wide glyph, ending in an ellipsis when
    /// anything was dropped.
    static func truncate(_ s: String, to cells: Int) -> String {
        guard cells > 0 else { return "" }
        var out = ""
        var used = 0
        var truncated = false
        for ch in s {
            let width = of(ch)
            if used + width > cells { truncated = true; break }
            out.append(ch)
            used += width
        }
        guard truncated else { return out }
        while used + 1 > cells, !out.isEmpty {
            if let last = out.popLast() { used -= of(last) }
        }
        return out + "…"
    }

    /// Exactly `cells` columns: truncated if too wide, space-padded if too narrow.
    static func pad(_ s: String, to cells: Int, alignRight: Bool = false) -> String {
        let body = truncate(s, to: cells)
        let used = of(body)
        guard used < cells else { return body }
        let fill = String(repeating: " ", count: cells - used)
        return alignRight ? fill + body : body + fill
    }

    /// Start column (0-based) that keeps an `width`-cell string right-aligned inside `cells`.
    static func rightAlignedStart(_ s: String, cells: Int) -> Int {
        max(0, cells - of(s))
    }

    // MARK: tables

    private static func isZeroWidth(_ v: UInt32) -> Bool {
        switch v {
        case 0x0300...0x036F, 0x0483...0x0489, 0x0591...0x05BD, 0x0610...0x061A,
             0x064B...0x065F, 0x0670...0x0670, 0x06D6...0x06DC, 0x0711...0x0711,
             0x0900...0x0902, 0x093C...0x093C, 0x0941...0x0948, 0x0E31...0x0E31,
             0x0E34...0x0E3A, 0x0E47...0x0E4E, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF,
             0x200B...0x200F, 0x2028...0x202E, 0x2060...0x2064, 0x20D0...0x20F0,
             0xFE00...0xFE0E, 0xFE20...0xFE2F, 0xFEFF...0xFEFF,
             0xE0100...0xE01EF:
            return true
        default:
            return false
        }
    }

    private static func isWide(_ v: UInt32) -> Bool {
        switch v {
        case 0x1100...0x115F,                             // Hangul Jamo
             0x231A...0x231B, 0x23E9...0x23EC, 0x23F0...0x23F0, 0x23F3...0x23F3,
             0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653, 0x267F...0x267F,
             0x2693...0x2693, 0x26A1...0x26A1, 0x26AA...0x26AB, 0x26BD...0x26BE,
             0x26C4...0x26C5, 0x26CE...0x26CE, 0x26D4...0x26D4, 0x26EA...0x26EA,
             0x26F2...0x26F3, 0x26F5...0x26F5, 0x26FA...0x26FA, 0x26FD...0x26FD,
             0x2705...0x2705, 0x270A...0x270B, 0x2728...0x2728, 0x274C...0x274C,
             0x274E...0x274E, 0x2753...0x2755, 0x2757...0x2757, 0x2795...0x2797,
             0x27B0...0x27B0, 0x27BF...0x27BF, 0x2B1B...0x2B1C, 0x2B50...0x2B50,
             0x2B55...0x2B55,
             0x2E80...0x303E,                             // CJK radicals, Kangxi, CJK punctuation
             0x3041...0x33FF,                             // kana … CJK compatibility
             0x3400...0x4DBF, 0x4E00...0x9FFF,            // CJK unified + ext A
             0xA000...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6,            // fullwidth forms
             0x16FE0...0x16FE4, 0x17000...0x187F7, 0x18800...0x18CD5,
             0x1B000...0x1B152, 0x1B164...0x1B167, 0x1B170...0x1B2FB,
             0x1F004...0x1F004, 0x1F0CF...0x1F0CF, 0x1F18E...0x1F18E,
             0x1F191...0x1F19A, 0x1F200...0x1F320, 0x1F32D...0x1F335,
             0x1F337...0x1F37C, 0x1F37E...0x1F393, 0x1F3A0...0x1F3CA,
             0x1F3CF...0x1F3D3, 0x1F3E0...0x1F3F0, 0x1F3F4...0x1F3F4,
             0x1F3F8...0x1F43E, 0x1F440...0x1F440, 0x1F442...0x1F4FC,
             0x1F4FF...0x1F53D, 0x1F54B...0x1F54E, 0x1F550...0x1F567,
             0x1F57A...0x1F57A, 0x1F595...0x1F596, 0x1F5A4...0x1F5A4,
             0x1F5FB...0x1F64F, 0x1F680...0x1F6C5, 0x1F6CC...0x1F6CC,
             0x1F6D0...0x1F6D2, 0x1F6D5...0x1F6D7, 0x1F6EB...0x1F6EC,
             0x1F6F4...0x1F6FC, 0x1F7E0...0x1F7EB, 0x1F90C...0x1F93A,
             0x1F93C...0x1F945, 0x1F947...0x1F9FF, 0x1FA70...0x1FAFF,
             0x20000...0x2FFFD, 0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
