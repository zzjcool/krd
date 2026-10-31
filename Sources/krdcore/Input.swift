import Foundation

/// One thing the terminal said, in numbers only (issue #45).
///
/// The parser decides *what the bytes mean*; `krd` decides *what to do about it* — which key code
/// that is, where a cell lands on the screen, whether a click is a double click, whether a paste
/// request can be honoured. That split is why this file has no CoreGraphics in it: the mouse report
/// carries the integers the terminal sent, and `Viewport` (which owns the tty geometry) does the
/// mapping on the other side of the boundary.
public enum Event: Equatable {
    /// A kitty keyboard report. The IME layer decides whether it becomes a key press or an
    /// injected character (`--ime`), so it stays a report until then.
    case key(KeyReport)
    /// An already-resolved key press: the legacy encodings and the single control bytes.
    case press(UInt16, Modifiers, KeyReport.Phase)
    /// Printable text, with whatever modifiers came with it (Alt+letter arrives this way).
    case text(Character, Modifiers)
    /// A byte below 0x20 that is not Enter/Tab/Backspace: `krd` decides (Ctrl-\ quits, Ctrl-V
    /// pastes, Ctrl-A is a keystroke, …).
    case control(UInt8)
    /// An SGR mouse or wheel report, exactly as sent.
    case mouse(MouseReport)
    /// `OSC … BEL|ST`: the body, untouched. Only OSC 52 is interpreted, and `krd` owns the clipboard.
    case osc(String)
    /// The terminal's answer to `CSI ? u` — which keyboard enhancements it accepted.
    case keyboardFlags(Int?)
    /// The terminal's answer to `CSI 5n`: the device status report the round-trip probe measures
    /// (issue #52). Not input — nothing is injected for it.
    case statusReport
    /// A parse-level diagnostic for `--debug` (e.g. an OSC that grew past the cap).
    case notice(String)
}

/// An SGR mouse report: `CSI < b ; x ; y M|m`. Numbers only — `x`/`y` are whatever the terminal
/// sent (cells or, with `?1016h`, pixels) and the decoder on the other side knows which.
public struct MouseReport: Equatable {
    /// Low two bits of the button code. 3 means "no button", which is normal inside a motion report.
    public var button: Int
    public var x: Int
    public var y: Int
    public var isWheel: Bool
    public var isRelease: Bool
    /// Bit 32: the pointer moved (drag, or plain motion when no button is held).
    public var isMotion: Bool
    /// xterm's meta bit becomes Option on the Mac; the mapping is `krd`'s business.
    public var mods: Modifiers

    /// The wheel's direction in the form the chrome takes: `0` for anything that is not a wheel,
    /// `-1` for a notch up (button 64) and `+1` for a notch down (65). One notch is one line or one
    /// card -- how far that is, is the receiver's business; the sign is the terminal's, and it was
    /// dropped on the way in for as long as the callback carried a `Bool`, which is why nothing
    /// could scroll up (issue #118).
    ///
    /// The horizontal codes (66/67) are a downward step, not a left/right one: the wall has always
    /// paged its shelf on them and a panel has nothing sideways to scroll. Deciding that here, next
    /// to the parse, is what keeps the answer the same for both receivers.
    public var wheelStep: Int {
        guard isWheel else { return 0 }
        return button == 0 ? -1 : 1
    }
}

/// The CSI/SS3 state machine: bytes in, `Event`s out.
///
/// Ported from `InputReader.drain`/`parseEscape` in krd, with every side effect turned into an
/// event so the parsing can be tested (and reused) without a terminal. The `--debug` trace is
/// produced on the *other* side of the boundary, from these events, which is what makes the
/// before/after trace comparison meaningful: if a number here changes, the trace changes.
public final class InputParser {
    /// Bytes received but not yet decoded. A partial escape sequence simply stays here until the
    /// rest arrives; `krd` inspects it for the "lone ESC" case (a terminal sends nothing after it).
    public var buffer: [UInt8] = []

    public var onEvent: ((Event) -> Void)?

    /// An over-cap OSC is being swallowed up to its terminator: its bytes are a reply's payload,
    /// never input. Kept across `feed`s because a reply arrives in reads, not in one piece. Only a
    /// terminator (or `reset()`) ends it: a reply that never terminates leaves the parser
    /// discarding, which is deliberate — the alternative is typing its payload.
    private var discardingOSC = false
    /// The last read ended in `ESC`, the first half of an `ST` (`ESC \`) terminator. Held outside
    /// `buffer` on purpose: a lone `ESC` there is the Esc key to the read loop, and its `reset()`
    /// would drop the discard state in the middle of the sequence.
    private var discardSawESC = false

    public init() {}

    public func feed(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
        drain()
    }

    public func feed(_ bytes: ArraySlice<UInt8>) {
        buffer.append(contentsOf: bytes)
        drain()
    }

    /// Drop everything buffered (including a half-swallowed sequence), e.g. when the terminal is reset.
    public func reset() {
        buffer.removeAll(keepingCapacity: true)
        discardingOSC = false
        discardSawESC = false
    }

    /// Upper bound for an OSC body, shared with `OSC52` so the parser and the clipboard code
    /// cannot disagree about when a sequence is "too big to be ours" (2 MB of payload, base64'd).
    public static let maxEncodedOSC = ((2 << 20) * 4) / 3 + 16

    /// How long an OSC may grow before it is dropped: a maximal legal reply (`ESC ] 52;c;` +
    /// base64 of 2 MB + `ST`) is `maxEncodedOSC - 5` bytes, so the extra 32 is headroom beyond a
    /// legal reply, not a second payload budget.
    private static let maxOSCSequence = maxEncodedOSC + 32

    private func emit(_ event: Event) { onEvent?(event) }

    private func drain() {
        while true {
            if discardingOSC {
                guard let used = discardOSC() else { return }
                buffer.removeFirst(used)
                discardingOSC = false
                continue
            }
            guard let first = buffer.first else { return }
            if first == 0x1B {
                guard let used = parseEscape() else { return }
                buffer.removeFirst(used)
                continue
            }
            if first == 0x7F || first == 0x08 {
                buffer.removeFirst(); emit(.press(Keys.backspace, [], .press)); continue
            }
            if first == 0x09 {
                buffer.removeFirst(); emit(.press(Keys.tab, [], .press)); continue
            }
            if first == 0x0A || first == 0x0D {
                buffer.removeFirst(); emit(.press(Keys.enter, [], .press)); continue
            }
            if first < 0x20 {
                buffer.removeFirst(); emit(.control(first)); continue
            }
            let length = utf8Length(first)
            if buffer.count < length { return }
            if let text = String(bytes: buffer[0..<length], encoding: .utf8) {
                for ch in text { emit(.text(ch, [])) }
            }
            buffer.removeFirst(length)
        }
    }

    private func parseEscape() -> Int? {
        if buffer.count == 1 { return nil }
        switch buffer[1] {
        case 0x5B:                                  // CSI: ESC [ ... final
            var i = 2
            // An SGR mouse report is read straight out of `buffer` (issue #105): the parameter
            // body is digits and ';', so building a `String` for it only to `split` it back into
            // numbers is 76 % of the cost of one report on a terminal with motion reporting on.
            // `ascii` keeps the one case where the bytes and the text disagree: a body that is
            // not valid UTF-8 is "" on the string side and so never a mouse report at all.
            var ascii = true
            while i < buffer.count {
                let b = buffer[i]
                if b >= 0x40 && b <= 0x7E {
                    // `M`/`m` only: `n` and `u` are read before the mouse branch in `handleCSI`,
                    // and any other final still goes through it unchanged.
                    if ascii, (b == 0x4D || b == 0x6D), buffer[2] == 0x3C,
                       let report = buffer.withUnsafeBufferPointer({ bytes in
                           Self.scanMouseSGR(bytes: bytes, start: 3, end: i,
                                             isRelease: b == 0x6D)
                       }) {
                        emit(.mouse(report))
                        return i + 1
                    }
                    let params = String(bytes: buffer[2..<i], encoding: .utf8) ?? ""
                    handleCSI(params: params, final: b)
                    return i + 1
                }
                if b >= 0x80 { ascii = false }
                i += 1
            }
            return nil
        case 0x4F:                                  // SS3: ESC O x
            guard buffer.count >= 3 else { return nil }
            handleSS3(buffer[2])
            return 3
        case 0x5D:                                  // OSC: ESC ] ... BEL | ST
            // The body is the payload (a clipboard reply is megabytes), so a terminator is only
            // accepted inside the cap: an over-cap sequence is dropped whole and no part of it may
            // reach an `Event` as input.
            let scanTo = min(buffer.count, Self.maxOSCSequence)
            var i = 2
            while i < scanTo {
                if buffer[i] == 0x07 {
                    emit(.osc(String(bytes: buffer[2..<i], encoding: .utf8) ?? ""))
                    return i + 1
                }
                if buffer[i] == 0x1B, i + 1 < buffer.count, buffer[i + 1] == 0x5C {
                    emit(.osc(String(bytes: buffer[2..<i], encoding: .utf8) ?? ""))
                    return i + 2
                }
                i += 1
            }
            // A clipboard reply is megabytes of base64; anything longer than the cap without a
            // terminator inside it is not ours. Dropping only `ESC ]` (what this used to do) fed
            // the body to the ordinary loop, and the body is base64: it was typed into the
            // mirrored desktop. Swallow it instead, up to its terminator.
            if buffer.count > Self.maxOSCSequence {
                emit(.notice("osc dropped: over cap"))
                if let used = discardOSC() { return used }
                discardingOSC = true
                return nil
            }
            return nil
        default:
            if buffer[1] < 0x20 {
                emit(.press(Keys.esc, [], .press))
                return 1
            }
            if let ch = String(bytes: [buffer[1]], encoding: .utf8)?.first {
                emit(.text(ch, [.maskAlternate]))
            }
            return 2
        }
    }

    /// Swallow the body of an over-cap OSC. Returns how many buffered bytes to drop (through the
    /// terminator); nil means this read held no terminator, and the buffer has been emptied so the
    /// caller only has to keep `discardingOSC`. A trailing `ESC` (the first half of a split `ST`)
    /// survives in `discardSawESC`. The buffer never grows with the reply, which is what keeps a
    /// 100 MB answer from being held.
    private func discardOSC() -> Int? {
        if discardSawESC {
            guard let first = buffer.first else { return nil }
            discardSawESC = false
            if first == 0x5C { return 1 }         // `ESC \` split across two reads
        }
        var i = 0
        while i < buffer.count {
            let b = buffer[i]
            if b == 0x07 { return i + 1 }
            if b == 0x1B {
                guard i + 1 < buffer.count else {
                    // The read ended on the first half of `ST`: hold it for the next read.
                    discardSawESC = true
                    buffer.removeAll(keepingCapacity: true)
                    return nil
                }
                if buffer[i + 1] == 0x5C { return i + 2 }
            }
            i += 1
        }
        buffer.removeAll(keepingCapacity: true)
        return nil
    }

    /// `CSI … u`: either the terminal's answer to the capability query, or a key report.
    ///
    /// `CSI ? <flags> u` is the answer (`?` = query), `CSI > … u` / `CSI < … u` / `CSI = … u` are
    /// pushes, pops and sets, which are ours to send and never in the input stream; anything else
    /// is a key.
    private func handleKeyProtocol(_ params: String) {
        if params.hasPrefix("?") {
            emit(.keyboardFlags(Int(params.dropFirst())))
            return
        }
        guard !params.hasPrefix(">"), !params.hasPrefix("<"), !params.hasPrefix("=") else { return }
        guard let report = KeyReport(kitty: params) else { return }
        emit(.key(report))
    }

    private func handleCSI(params: String, final: UInt8) {
        if final == 0x6E {                                  // 'n': device status report
            // `CSI 0n` is the terminal telling us it is alive; the probe in `Desk` measures the
            // round trip. Emitted rather than swallowed so the timing lives in one place.
            emit(.statusReport)
            return
        }
        if final == 0x75 {                                  // 'u': kitty keyboard protocol
            handleKeyProtocol(params)
            return
        }
        if params.hasPrefix("<") {
            handleMouse(params, isRelease: final == 0x6D)   // 'm' = release
            return
        }
        let (numbers, phase) = KeyReport.legacyFields(params)
        let flags = Keys.modifierFlags(numbers)
        let letter = Character(UnicodeScalar(final))
        switch letter {
        case "A": emit(.press(Keys.up, flags, phase))
        case "B": emit(.press(Keys.down, flags, phase))
        case "C": emit(.press(Keys.right, flags, phase))
        case "D": emit(.press(Keys.left, flags, phase))
        case "H": emit(.press(Keys.home, flags, phase))
        case "F": emit(.press(Keys.end, flags, phase))
        case "Z": emit(.press(Keys.tab, flags.union(.maskShift), phase))
        case "~":
            // A table lookup, not arithmetic: an unknown number is dropped instead of indexing
            // past the end of a shorter table (TROUBLESHOOTING §22) — and a Swift subscript trap
            // is not catchable, so the process used to die with raw mode still on.
            if let press = Keys.numberedPress(numbers) {
                emit(.press(press.key, press.flags, phase))
            }
        default: break
        }
    }

    private func handleSS3(_ b: UInt8) {
        switch Character(UnicodeScalar(b)) {
        case "A": emit(.press(Keys.up, [], .press))
        case "B": emit(.press(Keys.down, [], .press))
        case "C": emit(.press(Keys.right, [], .press))
        case "D": emit(.press(Keys.left, [], .press))
        case "H": emit(.press(Keys.home, [], .press))
        case "F": emit(.press(Keys.end, [], .press))
        case "P", "Q", "R", "S":
            // Same values as `ESC [ 11 ~` … `ESC [ 14 ~`; `ss3Function` is built from that table.
            if let key = Keys.ss3Function[Character(UnicodeScalar(b))] {
                emit(.press(key, [], .press))
            }
        default: break
        }
    }

    // MARK: mouse

    /// Modifier bits the terminal puts in the button code (xterm's "meta" is Option on the Mac).
    static func mouseModifiers(_ b: Int) -> Modifiers {
        var mods: Modifiers = []
        if b & 4 != 0 { mods.insert(.maskShift) }
        if b & 8 != 0 { mods.insert(.maskAlternate) }
        if b & 16 != 0 { mods.insert(.maskControl) }
        return mods
    }

    /// One SGR mouse report, `CSI < b ; x ; y M|m`, scanned in place (issue #105).
    ///
    /// `bytes[start..<end]` is the parameter body just past the `<`; `end` is the index of the
    /// final byte, so no terminator is needed. Nothing here allocates: no `String`, no `Substring`,
    /// no array — the fields are accumulated as they are walked.
    ///
    /// It reads the body the way `handleMouse(_:isRelease:)` below reads it, field for field: the
    /// integer rule is Swift's `Int(_:)` rule (a leading `+`/`-` is a sign, a value outside `Int`
    /// is not a number), an empty field is skipped, and a field that is not a number is *dropped*
    /// rather than failing the report — so `b;x;y` are the first three surviving fields, and fewer
    /// than three means the sequence was never a report.
    static func scanMouseSGR(bytes: UnsafeBufferPointer<UInt8>, start: Int, end: Int,
                             isRelease: Bool) -> MouseReport? {
        var b = 0, x = 0, y = 0
        var fields = 0
        var i = start
        while i < end, fields < 3 {                             // the first three are the report
            let fieldStart = i
            while i < end, bytes[i] != 0x3B { i += 1 }           // ';'
            if i > fieldStart, let value = integer(bytes, fieldStart, i) {
                switch fields {
                case 0: b = value
                case 1: x = value
                default: y = value
                }
                fields += 1
            }
            i += 1                                              // step over the ';'
        }
        guard fields >= 3 else { return nil }
        return MouseReport(button: b & 3, x: x, y: y, isWheel: (b & 64) != 0,
                           isRelease: isRelease, isMotion: (b & 32) != 0,
                           mods: mouseModifiers(b))
    }

    /// `Int(_:)` over a byte range, accepting and rejecting exactly what the string initialiser
    /// accepts and rejects: optional sign, then at least one digit, and `nil` when the value does
    /// not fit in `Int` (no trap — the old path got `nil` from `Int` and dropped the field).
    private static func integer(_ bytes: UnsafeBufferPointer<UInt8>,
                                _ start: Int, _ end: Int) -> Int? {
        guard start < end else { return nil }
        var i = start
        var negative = false
        if bytes[i] == 0x2D { negative = true; i += 1 }         // '-'
        else if bytes[i] == 0x2B { i += 1 }                     // '+'
        guard i < end else { return nil }                       // "", "-", "+"
        var magnitude: UInt64 = 0
        while i < end {
            let digit = Int(bytes[i] &- 0x30)
            guard digit >= 0, digit <= 9 else { return nil }
            let (scaled, overflowed) = magnitude.multipliedReportingOverflow(by: 10)
            guard !overflowed else { return nil }
            let (sum, carried) = scaled.addingReportingOverflow(UInt64(digit))
            guard !carried else { return nil }
            magnitude = sum
            i += 1
        }
        // `Int.min` has one more magnitude than `Int.max`; anything past that is not an `Int`.
        let limit = UInt64(Int.max) &+ 1
        if negative, magnitude == limit { return Int.min }
        guard magnitude < limit else { return nil }
        return negative ? -Int(magnitude) : Int(magnitude)
    }

    /// The string form of the report, kept as the exactness fallback: it is what runs for a
    /// parameter body that is not ASCII (a valid-UTF-8 body whose fields can still be numbers
    /// must keep parsing, and one that is not valid UTF-8 must keep emitting nothing) and for a
    /// `<`-prefixed CSI whose final byte is neither `M` nor `m`.
    private func handleMouse(_ params: String, isRelease: Bool) {
        let body = params.dropFirst()                       // strip '<'
        let parts = body.split(separator: ";").compactMap { Int($0) }
        guard parts.count >= 3 else { return }
        let b = parts[0]
        emit(.mouse(MouseReport(button: b & 3, x: parts[1], y: parts[2],
                                isWheel: (b & 64) != 0, isRelease: isRelease,
                                isMotion: (b & 32) != 0,
                                mods: Self.mouseModifiers(b))))
    }

    /// How many bytes the UTF-8 scalar that starts with `first` occupies.
    private func utf8Length(_ first: UInt8) -> Int {
        switch first {
        case 0x00...0x7F: return 1
        case 0xC0...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF7: return 4
        default: return 1
        }
    }
}

extension Event {
    /// Deterministic one-line form, for the golden input fixture (issue #45).
    ///
    /// Numbers only, and no payload content: an OSC body can be a clipboard, so it is reported by
    /// its selector and size. This is the input analogue of the encoder's dump — the same fed
    /// sequence must produce the same lines, before and after any refactor of the state machine.
    public var canonicalTrace: String {
        switch self {
        case let .key(r):
            return "key \(r.code) mods=\(r.mods) \(r.phase)"
                + (r.shifted.map { " shifted=\($0)" } ?? "")
                + (r.base.map { " base=\($0)" } ?? "")
        case let .press(code, mods, phase):
            return "press \(code) mods=\(mods.rawValue) \(phase)"
        case let .text(ch, mods):
            return "text U+\(String(ch.unicodeScalars.first!.value, radix: 16, uppercase: true))"
                + " mods=\(mods.rawValue)"
        case let .control(byte):
            return "control \(byte)"
        case let .mouse(r):
            return "mouse button=\(r.button) x=\(r.x) y=\(r.y)"
                + " wheel=\(r.isWheel ? 1 : 0) release=\(r.isRelease ? 1 : 0)"
                + " motion=\(r.isMotion ? 1 : 0) mods=\(r.mods.rawValue)"
        case let .osc(body):
            return "osc \(body.prefix(3)) \(body.utf8.count) B"
        case let .keyboardFlags(flags):
            return "keyboardFlags \(flags.map(String.init) ?? "?")"
        case .statusReport:
            return "statusReport"
        case let .notice(text):
            return "notice \(text)"
        }
    }
}
