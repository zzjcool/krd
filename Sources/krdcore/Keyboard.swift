import Foundation

/// Modifier bits, numerically identical to `CGEventFlags.rawValue` so a trace recorded before the
/// core extraction (`flags=1048576`) still reads the same after it. `krd` converts with
/// `CGEventFlags(rawValue:)`, which is a plain reinterpretation of the same bits (issue #45).
public struct Modifiers: OptionSet, Equatable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let maskShift = Modifiers(rawValue: 0x0002_0000)
    public static let maskControl = Modifiers(rawValue: 0x0004_0000)
    public static let maskAlternate = Modifiers(rawValue: 0x0008_0000)
    public static let maskCommand = Modifiers(rawValue: 0x0010_0000)
}

/// The kitty keyboard protocol, as data.
///
/// Two encodings arrive on stdin and both mean the same thing once decoded here:
///
///   kitty:  `CSI code[:shifted[:base]] ; modifiers[:event] [; text] u`
///   legacy: `CSI 1 ; modifiers[:event] A`   ·   `CSI number ; modifiers[:event] ~`
///
/// The modifier field is xterm's `1 + bits` in both (bit 1 shift, 2 alt, 4 ctrl, 8 super — Cmd
/// on the Mac), which is the same encoding `Keys.modifierFlags` already decodes. The `event`
/// sub-field only appears when the terminal accepted the "report event types" enhancement: 1
/// press, 2 repeat, 3 release.
///
/// Everything in this file is pure. `InputReader` owns the tty, the byte buffer and the
/// `CGEvent`s, so the protocol itself can be tested without a terminal — the same split #14
/// ended up with, for the same reason: the interesting decisions are data, not side effects.
public struct KeyReport: Equatable {
    public enum Phase: Int {
        case press = 1, repeated = 2, release = 3
    }

    /// The unicode codepoint of the key — always the *un-shifted* one, per the spec (`ctrl+shift+a`
    /// is `97`, never `65`) — or one of kitty's functional-key numbers from the Private Use Area.
    public var code: Int
    /// Shifted and PC-101 base-layout codepoints: present only for terminals that accepted
    /// "report alternate keys", and the reason a Ctrl+C on a Cyrillic layout still presses the
    /// physical `c` key.
    public var shifted: Int?
    public var base: Int?
    /// Decoded modifier bits, i.e. the wire form minus its `1 +`.
    public var mods: Int = 0
    public var phase: Phase = .press

    /// `Modifiers` for the modifier bits macOS has. Hyper, meta and the lock bits are decoded
    /// into `mods` but deliberately not mapped: macOS has no key for them, and inventing one
    /// (Fn, Caps Lock) would change what the user typed.
    public var flags: Modifiers {
        var flags: Modifiers = []
        if mods & 0b0001 != 0 { flags.insert(.maskShift) }
        if mods & 0b0010 != 0 { flags.insert(.maskAlternate) }
        if mods & 0b0100 != 0 { flags.insert(.maskControl) }
        if mods & 0b1000 != 0 { flags.insert(.maskCommand) }
        return flags
    }

    /// Quit chord: Ctrl-\ , press or repeat. The release has to be ignored or a session with
    /// event reporting enabled would terminate twice — once on the press that `onQuit` already
    /// handles, once on the release that follows it.
    /// Ctrl-\ in any phase. The release is included so it can be swallowed: forwarding it would
    /// send the mirrored app a Ctrl-\ whose press it never received.
    public var isQuitChord: Bool { code == 0x5C && mods == 0b0100 }

    /// The quit itself, on press and repeat only. The phase is part of the predicate on purpose:
    /// with event reporting on the release follows the press, and a quit that checked only the key
    /// would end the session twice.
    public var isQuit: Bool { isQuitChord && phase != .release }
}

extension KeyReport {
    /// `CSI … u` parameters. Missing sub-fields are empty, and an empty field is "absent" (0 is
    /// not a valid codepoint or modifier field), so `97:65::99` parses as code 97, shifted 65,
    /// no base, base-layout 99.
    public init?(kitty params: String) {
        let fields = params.split(separator: ";", omittingEmptySubsequences: false)
        let key = Self.subfields(fields[0])
        guard let code = key.first, code > 0 else { return nil }
        self.code = code
        if key.count > 1, key[1] > 0 { shifted = key[1] }
        if key.count > 2, key[2] > 0 { base = key[2] }
        guard fields.count > 1 else { return }
        let modsField = Self.subfields(fields[1])
        let wire = modsField.first ?? 1
        mods = wire > 1 ? wire - 1 : 0
        if modsField.count > 1, let phase = Phase(rawValue: modsField[1]) { self.phase = phase }
    }

    /// `97:65::99` → `[97, 65, 0, 99]`; an empty sub-field is 0, i.e. absent.
    public static func subfields(_ field: Substring) -> [Int] {
        field.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
    }

    /// Parameters of a legacy report, with the kitty `:event` sub-field split off. With no
    /// sub-field present this is exactly `params.split(";").map { Int($0) ?? 0 }` — the
    /// pre-kitty parse — so a terminal that ignores the handshake keeps today's behaviour.
    public static func legacyFields(_ params: String) -> (numbers: [Int], phase: Phase) {
        var numbers: [Int] = []
        var phase = Phase.press
        for field in params.split(separator: ";") {
            let parts = field.split(separator: ":")
            numbers.append(parts.first.flatMap { Int($0) } ?? 0)
            if parts.count > 1, let raw = Int(parts[1]), let parsed = Phase(rawValue: raw) {
                phase = parsed
            }
        }
        return (numbers, phase)
    }
}

/// Terminal key code → the macOS key code that posts it.
public enum Keyboard {
    /// Functional keys that kitty reports from the Private Use Area, for the ones with no legacy
    /// escape form. The rest — arrows, Home/End, page up/down, insert/delete, F1–F12 — keep their
    /// legacy `CSI 1;mods A` / `CSI n;mods ~` shape even with all enhancements on, which is why
    /// `Keys.numbered` is still the table for them.
    public static let functional: [Int: UInt16] = [
        27: Keys.esc,
        13: Keys.enter,
        9: Keys.tab,
        127: Keys.backspace,
        57376: Keys.f13,
        57377: Keys.f14
    ]

    /// Reports for the modifier keys themselves. Every other report repeats the modifier state in
    /// its own field, so forwarding these would apply it twice — and, because presses are posted
    /// as a down+up tap, leave nothing held either way. Ignoring them is what keeps a released Cmd
    /// from ever becoming a stuck one.
    public static let modifierKeys: Set<Int> = [
        57441, 57442, 57443, 57444, 57445, 57446,      // left  shift ctrl alt super hyper meta
        57447, 57448, 57449, 57450, 57451, 57452,      // right shift ctrl alt super hyper meta
        57453, 57454,                                  // ISO level 3 / 5 shift
        57358, 57359, 57360                            // caps lock, scroll lock, num lock
    ]

    /// The character a report types, if it types one. Private Use Area codes are functional keys
    /// by construction and must never be turned into a character: posting `U+E02x` would type a
    /// replacement glyph into the mirrored app.
    public static func text(_ report: KeyReport) -> Character? {
        let codepoint = report.base ?? report.code
        guard codepoint < 0xE000, let scalar = UnicodeScalar(UInt32(codepoint)) else { return nil }
        return Character(scalar)
    }

    /// The macOS key code for a report, or nil when it is a key only the text path can carry.
    public static func keyCode(_ report: KeyReport) -> UInt16? {
        if let code = functional[report.code] { return code }
        guard let ch = text(report) else { return nil }
        if let code = Keys.map[ch] { return code }
        // Terminals that send the shifted codepoint in `code` (the spec says not to) still land
        // on the base key this way, with `shift` already in the flags.
        if let base = Keys.shifted[ch], let code = Keys.map[base] { return code }
        return nil
    }
}

/// How a character gets to the mirrored Mac (issue #16).
///
/// The distinction is not cosmetic: `postUnicode` is `virtualKey 0` plus a string, so the target's
/// input method never sees a keystroke — no composition, no candidate window, and an app that reads
/// keycodes (Electron, Terminal.app, most custom text views) sees nothing at all. Pressing the
/// physical key instead lets the *target's* IME do the composing, which is what a real machine does.
public enum IMEMode: String, CaseIterable {
    /// Physical key when the terminal reports one, injected text otherwise. The default: never
    /// worse than the old behaviour, and the log says when it had to inject.
    case auto
    /// Physical keys only. Text the terminal sent with no recoverable key is dropped, so a
    /// composition never gets half-injected text in the middle of it (Korean jamo → syllable).
    case raw
    /// Injected text for anything that is not plain ASCII: what krd always did, and the right
    /// answer when the user already composed the character locally.
    case unicode

    public init?(spec: String) { self.init(rawValue: spec.lowercased()) }
}

/// What one key report should become. Pure so the table is tested instead of the tty.
public enum KeyPlan: Equatable {
    /// Press this key; the target's layout and input method decide the character.
    case key(UInt16, Modifiers)
    /// Inject the character directly (bypasses any input method).
    case text(Character)
    /// Nothing this mode can do with it.
    case drop
}

extension Keyboard {
    /// The character the user actually typed. `code` is the unshifted codepoint *on the terminal's
    /// layout*, which is what "typed" means here; `base` is the physical key, i.e. what the target's
    /// layout may or may not make of it, so it is deliberately not used for this.
    public static func character(for report: KeyReport) -> Character? {
        guard report.code < 0xE000, let scalar = UnicodeScalar(UInt32(report.code)) else { return nil }
        return Character(scalar)
    }

    /// Modifiers to press with: the report's own, plus shift when the character lives on a shifted
    /// key and the terminal did not say so. `!` arrives as `code 33` from terminals that never send
    /// the `shifted` field, and pressing `1` bare would type `1`.
    public static func pressFlags(for report: KeyReport) -> Modifiers {
        var flags = report.flags
        if let physical = text(report), Keys.shifted[physical] != nil { flags.insert(.maskShift) }
        return flags
    }

    /// The decision for one report under `--ime`.
    ///
    /// ASCII always presses a key, in every mode: injecting `a` as text would blind every
    /// keycode-reading app for no benefit, and it is the fast path that must not regress.
    /// Functional keys (F13, Esc, …) press their key too — they are not characters at all.
    public static func plan(for report: KeyReport, mode: IMEMode) -> KeyPlan {
        let key = keyCode(report)
        let typed = character(for: report)
        let flags = pressFlags(for: report)
        switch mode {
        case .auto:
            if let key { return .key(key, flags) }
            if let typed { return .text(typed) }
            return .drop
        case .raw:
            if let key { return .key(key, flags) }
            return .drop
        case .unicode:
            // A functional key has no character (`typed == nil`) and must still be pressed.
            if let key, typed == nil || typed?.isASCII == true { return .key(key, flags) }
            if let typed { return .text(typed) }
            return .drop
        }
    }
}
