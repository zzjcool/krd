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
    /// A string-terminated sequence that is **not** input: an `APC G … ST` (the channel kitty's
    /// graphics protocol answers on), or a `DCS`/`SOS`/`PM` body such as a `tmux` passthrough
    /// (issue #109). `krd` counts it and says why a tile was refused; nothing is injected for it.
    case graphicReply(GraphicsReply)
    /// A parse-level diagnostic for `--debug` (e.g. an OSC that grew past the cap).
    case notice(String)
}

/// One reply from a string-terminated sequence: `APC G i=31;OK ST`, `APC G i=31;EINVAL: … ST`, or
/// whatever body a `DCS`/`SOS`/`PM` carried.
///
/// Numbers and the terminal's own words only. The parser never guesses that a body it does not
/// recognise was a keystroke — `status` is then `unparsed` and `krd` says so instead of typing it.
public struct GraphicsReply: Equatable {
    /// The body between the introducer and `ST`, untouched (`Gi=31;OK` for the example above).
    public var body: String
    /// `i=<id>`: the image the reply is about.
    public var image: Int?
    /// `I=<number>`: an image *number*, the other way kitty names an image.
    public var imageNumber: Int?
    /// `p=<id>`: the placement, on a reply to `a=p`.
    public var placement: Int?
    /// `OK`, the terminal's own error text (`EINVAL: decompression failed`), or `unparsed`.
    public var status: String

    /// Every kitty error code starts with `E` (`EINVAL`, `ENOENT`, `ENOSPC`, …); `OK` does not.
    public var isError: Bool { status.first == "E" }
    public var isOK: Bool { status == "OK" }
    /// The body's selector: `G` for graphics, otherwise whatever the sequence started with.
    public var selector: String { body.first.map(String.init) ?? "" }

    /// Classify `G i=<id>[,p=<id>][,I=<n>];<OK | E…>` and nothing else.
    ///
    /// Both the transmit (`a=t`) and the placement (`a=p`) replies carry the status the same way,
    /// and kitty sends the error text without a leading identifier: `ESC _ G EINVAL: … ST` is a
    /// legal reply about no particular image, so the `;` is optional in this grammar.
    public init(body: String) {
        self.body = body
        var rest = Substring(body)
        guard rest.first == "G" else {
            status = "unparsed"
            return
        }
        rest = rest.dropFirst()
        let meta: Substring
        let result: Substring
        // A `;` separates metadata from the status only when there *is* metadata (`i=`/`I=`/`p=`).
        // An error text may carry its own `;` (`EINVAL: bad; param`), and splitting on it used to
        // turn a refusal into `unparsed` — i.e. lose the reason the issue is about.
        if let semicolon = rest.firstIndex(of: ";"), rest[..<semicolon].contains("=") {
            meta = rest[..<semicolon]
            result = rest[rest.index(after: semicolon)...]
        } else {
            meta = ""
            result = rest
        }
        for field in meta.split(separator: ",") {
            let pair = field.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let value = Int(pair[1]) else { continue }
            switch pair[0] {
            case "i": image = value
            case "I": imageNumber = value
            case "p": placement = value
            default: break
            }
        }
        // `OK` or an error code; the wildcard case is `unparsed`, never a guess.
        guard let first = result.first, first == "O" || first == "E" else {
            status = "unparsed"
            return
        }
        status = String(result)
    }
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
    /// The same for an over-cap `APC`/`DCS`/`SOS`/`PM` body (issue #109). A separate field because
    /// the terminator rule differs: a string sequence ends on `ST` only, so a `BEL` inside one is
    /// payload and must not end the discard.
    private var discardingString = false
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
        discardingString = false
        discardSawESC = false
    }

    /// Upper bound for an OSC body, shared with `OSC52` so the parser and the clipboard code
    /// cannot disagree about when a sequence is "too big to be ours" (2 MB of payload, base64'd).
    public static let maxEncodedOSC = ((2 << 20) * 4) / 3 + 16

    /// How long an OSC may grow before it is dropped: a maximal legal reply (`ESC ] 52;c;` +
    /// base64 of 2 MB + `ST`) is `maxEncodedOSC - 5` bytes, so the extra 32 is headroom beyond a
    /// legal reply, not a second payload budget.
    private static let maxOSCSequence = maxEncodedOSC + 32

    /// Upper bound for an `APC`/`DCS`/`SOS`/`PM` body. A kitty graphics reply is ~40 bytes and a
    /// `tmux` passthrough carries the payload it relays, so this is generous headroom rather than a
    /// budget; past it the sequence is swallowed whole, never typed (see `discardingString`).
    public static let maxStringSequence = 64 << 10

    private func emit(_ event: Event) { onEvent?(event) }

    private func drain() {
        while true {
            if discardingOSC {
                guard let used = discardOSC() else { return }
                buffer.removeFirst(used)
                discardingOSC = false
                continue
            }
            if discardingString {
                guard let used = discardString() else { return }
                buffer.removeFirst(used)
                discardingString = false
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
            while i < buffer.count {
                let b = buffer[i]
                if b >= 0x40 && b <= 0x7E {
                    let params = String(bytes: buffer[2..<i], encoding: .utf8) ?? ""
                    handleCSI(params: params, final: b)
                    return i + 1
                }
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
        case 0x5F, 0x50, 0x58, 0x5E:            // APC: ESC _ … ST; DCS ESC P; SOS ESC X; PM ESC ^
            // A graphics reply is `ESC _ G … ST` (issue #109) and the other three are the same
            // class of sequence: a reply or a passthrough, never a key. Alt-`_` is a legal
            // keystroke though, so any `ESC _` that is not the reply prefix keeps today's meaning
            // exactly — one byte of lookahead, then the Alt-text path below.
            if buffer[1] == 0x5F {
                guard buffer.count >= 3 else { return nil }
                guard buffer[2] == 0x47 else { return altText() }
            }
            return parseStringSequence()
        default:
            return altText()
        }
    }

    /// `ESC` + one printable byte: how a legacy terminal encodes Alt, and this parser's fallback for
    /// every escape it does not recognise. One keystroke, unchanged by any of the above.
    private func altText() -> Int? {
        if buffer[1] < 0x20 {
            emit(.press(Keys.esc, [], .press))
            return 1
        }
        if let ch = String(bytes: [buffer[1]], encoding: .utf8)?.first {
            emit(.text(ch, [.maskAlternate]))
        }
        return 2
    }

    /// `APC`/`DCS`/`SOS`/`PM`: `ESC x … ST`. The body is a reply's payload, never input, so it
    /// becomes exactly one `.graphicReply` — an unrecognised body included, as `unparsed`.
    ///
    /// `ST` is the only terminator here (`BEL` ends an `OSC` and nothing else), and the scan stops at
    /// the cap: past it the sequence is dropped whole rather than buffered or typed.
    private func parseStringSequence() -> Int? {
        let scanTo = min(buffer.count, Self.maxStringSequence)
        var i = 2
        while i < scanTo {
            if buffer[i] == 0x1B, i + 1 < buffer.count, buffer[i + 1] == 0x5C {
                handleStringSequence(String(bytes: buffer[2..<i], encoding: .utf8) ?? "")
                return i + 2
            }
            i += 1
        }
        if buffer.count > Self.maxStringSequence {
            emit(.notice("string sequence dropped: over cap"))
            if let used = discardString() { return used }
            discardingString = true
            return nil
        }
        // Still arriving: the body stays in `buffer` and nothing is emitted, so a reply split
        // across reads cannot be typed while it is incomplete.
        return nil
    }

    /// One string-sequence body, classified. The distinction from a keystroke is made *here*, by the
    /// fact that the sequence arrived: `krd` must never guess these bytes were input.
    private func handleStringSequence(_ body: String) {
        emit(.graphicReply(GraphicsReply(body: body)))
    }

    /// Swallow the body of an over-cap `APC`/`DCS`/`SOS`/`PM` up to its `ST`, for the reason
    /// `discardOSC` documents. Same contract, one difference: `BEL` is payload in a string sequence,
    /// so it does not end the discard — ending there would type the rest of the reply.
    private func discardString() -> Int? {
        if discardSawESC {
            guard let first = buffer.first else { return nil }
            discardSawESC = false
            if first == 0x5C { return 1 }         // `ESC \` split across two reads
        }
        var i = 0
        while i < buffer.count {
            if buffer[i] == 0x1B {
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
        case let .graphicReply(r):
            // The status text is the terminal's words about a payload, so the trace reports the
            // selector, the ids and the length — never the body (the `osc` rule).
            return "graphicReply \(r.selector) i=\(r.image.map(String.init) ?? "-")"
                + " p=\(r.placement.map(String.init) ?? "-")"
                + " \(r.isOK ? "ok" : r.isError ? "error" : "unparsed") \(r.body.utf8.count) B"
        case let .notice(text):
            return "notice \(text)"
        }
    }
}
