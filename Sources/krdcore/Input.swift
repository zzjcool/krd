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
    /// never input. Kept across `feed`s because a reply arrives in reads, not in one piece. A
    /// terminator, the byte cap or the fixed deadline ends it (`startDiscard`), so a reply that
    /// never terminates loses its payload rather than the keyboard.
    private var discardingOSC = false
    /// The same for an over-cap `APC`/`DCS`/`SOS`/`PM` body (issue #109). A separate field because
    /// the terminator rule differs: a string sequence ends on `ST` only, so a `BEL` inside one is
    /// payload and must not end the discard.
    private var discardingString = false
    /// The last read ended in `ESC`, the first half of an `ST` (`ESC \`) terminator. Held outside
    /// `buffer` on purpose: a lone `ESC` there is the Esc key to the read loop, and its `reset()`
    /// would drop the discard state in the middle of the sequence.
    private var discardSawESC = false
    /// Bytes swallowed since the current discard began. Every discard is *bounded* (issue #109,
    /// round 3): an input path that can swallow without a limit can swallow the keyboard, and a
    /// reply is at most a few hundred bytes.
    private var discarded = 0
    /// The byte budget this discard may spend (`maxStringSequence`, or `maxEncodedOSC` for a
    /// clipboard reply, whose payload is legitimately megabytes).
    private var discardByteCap = maxStringSequence
    /// When this discard *began* (`benchNowMs`). The deadline is counted from here and **no byte
    /// moves it** (issue #109, round 4): a keystroke is a byte, so an idle window that each `feed`
    /// refreshed made the typist the one input that could keep a discard alive forever.
    private var discardStartedAt: Double = 0
    /// When the current buffer first failed to complete, so a half-arrived *keystroke* can be given
    /// a deadline. Reset by `feed`: that window runs from the last byte, and it only ever decides a
    /// buffer that is neither a reply nor a legal key (`keySequenceGraceMs`).
    private var stalledSince: Double = 0
    /// Which introducer opened the discard that is open now (`nil` = none). Reported with the end
    /// condition, so a discard a *person* started is never logged as a terminal bug (issue #109).
    public private(set) var discardIntroducer: DiscardIntroducer?
    /// `discardStartedAt` expressed in the wall clock, so a bound check driven by a *read* and one
    /// driven by an *idle tick* never compare two different clocks: `now` from a caller uses the
    /// caller's anchor, and a read that brings no clock of its own uses this one.
    private var discardStartedAtWall: Double = 0
    /// A discard ended at one of its bounds while the sequence was still unterminated, so its tail
    /// may still be arriving. Armed there, and spent by **the next read**: if that read completes
    /// the sequence (a terminator inside the cap) it is the reply's own ending and is swallowed
    /// however late it arrived; if it does not, it is input — the keyboard is back, which is what
    /// the bound promised, and every read after it is input too.
    private var tailAttempt = false
    private var tailIntroducer: DiscardIntroducer = .apc
    private var tailByteCap = maxStringSequence
    /// Set by the parser every time a discard ends. The read loop logs the *end* (introducer,
    /// bytes, which condition fired) and never the latch alone.
    public private(set) var lastDiscard: DiscardReport?
    public private(set) var discardEndSerial = 0

    /// True while an unfinished sequence's payload is being swallowed. The read loop logs the idle
    /// ticks it drives; the parser owns the decision.
    public var isDiscarding: Bool { discardingOSC || discardingString }

    /// True while the ending of an already-abandoned sequence may still be swallowed (one read).
    public var isAwaitingTail: Bool { tailAttempt }

    public init() {}

    /// Bytes in. The **deadline is checked here as well as on the idle tick** (issue #109, round
    /// 6): a keystroke is a byte, so a check that only ran on a 100 ms `poll` timeout could be
    /// starved by anything arriving faster than that — a latched discard measured 3440 ms and ate
    /// 60 keystrokes at 50 ms. What this does *not* do: the clock stays anchored at
    /// `discardStartedAt`, and no byte moves it.
    public func feed(_ bytes: [UInt8], now: Double? = nil) {
        stalledSince = 0                            // the keystroke grace runs from the last byte
        checkDiscardDeadline(now: now)
        buffer.append(contentsOf: bytes)             // a discard's deadline does *not* move
        drain()
    }

    public func feed(_ bytes: ArraySlice<UInt8>, now: Double? = nil) {
        stalledSince = 0
        checkDiscardDeadline(now: now)
        buffer.append(contentsOf: bytes)
        drain()
    }

    /// Drop everything buffered (including a half-swallowed sequence), e.g. when the terminal is reset.
    public func reset() {
        buffer.removeAll(keepingCapacity: true)
        discardingOSC = false
        discardingString = false
        discardSawESC = false
        discarded = 0
        discardByteCap = Self.maxStringSequence
        discardStartedAt = 0
        discardStartedAtWall = 0
        stalledSince = 0
        discardIntroducer = nil
        tailAttempt = false
    }

    /// The introducer a discard came from. Logged with the end condition: the two read very
    /// differently to a person, because `ESC ]` plus a body is exactly what Alt-`]` followed by
    /// typing looks like, while `ESC _ G` is a sequence only a graphics reply produces.
    public enum DiscardIntroducer: String, Equatable {
        case osc = "OSC `ESC ]` with a body (a clipboard answer, or Alt+] plus typing — the two are byte-identical)"
        case apc = "APC `ESC _ G` (a kitty graphics reply)"
    }

    /// Which of the three conditions ended a discard.
    public enum DiscardEnd: String, Equatable {
        case terminator = "its terminator"
        case byteCap = "the byte cap"
        case deadline = "the 1500 ms deadline"
    }

    /// One finished discard, as the read loop reports it.
    public struct DiscardReport: Equatable {
        public var introducer: DiscardIntroducer
        public var dropped: Int
        public var end: DiscardEnd
        public var livedMs: Double
    }

    /// What a scan for the late ending of an abandoned sequence found (`scanTail`).
    private enum TailScan {
        /// The read completes the sequence: this many bytes, through its terminator.
        case completes(Int)
        /// Half an `ST` ended the read; wait for the rest.
        case hold
        /// Not the ending: input, all of it.
        case input
    }

    /// What a buffer that stopped growing turned out to be.
    public enum StalledBytes: Equatable {
        /// Nothing was held.
        case none
        /// One lone `ESC` — the Esc key, exactly as before issue #109.
        case escape
        /// Still undecided: nothing typed and nothing dropped. A discard that has not reached its
        /// deadline, or a buffer a *byte* still has to decide (`ESC _`), or half a keystroke inside
        /// `keySequenceGraceMs`.
        case pending
        /// The head of a sequence that was a reply (or half a keystroke). It is gone, and when the
        /// prefix could only have been a reply (`ESC _ G`, `OSC`) every byte up to its terminator is
        /// now swallowed, so the rest of that sequence cannot become input either.
        case sequence
        /// A bare `ESC ]` — the OSC introducer with no body yet — was released as the Alt-`]`
        /// keystroke it is, so the introducer can never swallow the typing that follows it.
        case released
        /// A discard ran out of budget (bytes or silence) and was given up: the keyboard is back and
        /// the parser has already emitted the `.notice` that says so. The sequence it belonged to
        /// may still be arriving, so one tail attempt stays armed (`isAwaitingTail`).
        case abandoned
    }

    /// True for the two prefixes whose tail can only be payload: `OSC` (`ESC ]`, a clipboard
    /// reply) and the graphics `APC` (`ESC _`). Being this prefix is *necessary* for a reply, never
    /// sufficient — see `isReplyCandidate` and `resolveStall`.
    public static func isReplyPrefix(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 2 && bytes[0] == 0x1B && (bytes[1] == 0x5D || bytes[1] == 0x5F)
    }

    /// `ESC _ G`: the only three bytes that begin a reply (issue #109). A bare `ESC _` is **not** a
    /// candidate — it is undecided, and only the *next byte* decides it.
    public static func isReplyCandidate(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 3 && bytes[0] == 0x1B && bytes[1] == 0x5F && bytes[2] == 0x47
    }

    /// A strict prefix of `ESC _ G`: exactly the two bytes `ESC _`, the only undecided state on this
    /// path. Three bytes always decide, and a bare `ESC` is the Esc key.
    public static func isReplyHead(_ bytes: [UInt8]) -> Bool {
        bytes.count == 2 && bytes[0] == 0x1B && bytes[1] == 0x5F
    }

    /// How long half a *keystroke* (`ESC O`, `ESC [ 1 ; 5`) is held before it is dropped. This is
    /// the 500 ms `docs/PROTOCOL.md` §8 quotes. It never applies to `ESC _`: a reply head is decided
    /// by the next byte, not by a clock.
    public static let keySequenceGraceMs: Double = 500

    /// The **total** life of one discard, counted from the byte that started it and never refreshed.
    /// Past it the discard ends and the keyboard comes back, with one exception that is not a
    /// clock: a single later read that *completes* the sequence is still swallowed, because a
    /// sequence that began as a reply head may not type its own terminator however late it arrives
    /// (`abandonDiscard`, `scanTail`).
    public static let replyDiscardBudgetMs: Double = 1500

    /// Resolve a sequence that stopped arriving: `krd`'s read loop calls this on every read that
    /// returned no data (its 100 ms `poll` timeout) and asks the same question each time. This is
    /// the only place that decides a held buffer, so it can be tested against a fake clock.
    ///
    /// The policy, in full (issue #109, round 4 — the round that removed the timers):
    ///
    /// 1. **Only an unambiguous reply may ever be treated as one.** `ESC _ G` is a reply; `ESC _`
    ///    plus anything else is the Alt-`_` keystroke plus what followed it (`parseEscape`). The
    ///    undecided `ESC _` is decided by **the next byte and nothing else**: no clock releases it,
    ///    so a reply whose head and body are written far apart is still heard as a reply instead of
    ///    being typed, and nothing on this path is typed before that byte arrives.
    /// 2. **What that costs is named, not hidden:** a lone `ESC _` with no byte after it is delivered
    ///    when the next byte arrives (on `main` it was typed at once). The alternative — releasing it
    ///    from this idle tick — is a clock, and it types the reply: a read returns no data ~100 ms
    ///    after `ESC _`, so any release here would fire before a body written 1200 ms later.
    /// 3. **`ESC ]` latches nothing new.** A bare `ESC ]` is Alt-`]`, released from this idle tick
    ///    (~100 ms, which is what a human's Alt-`]` looks like); with a body it is a clipboard answer
    ///    and latches the `discardingOSC` state `main` already had, whose only end conditions are the
    ///    ones `startDiscard` gives it.
    /// 4. **Every discard is bounded three ways**: its terminator, a byte budget
    ///    (`maxStringSequence`, or `maxEncodedOSC` for an OSC), and a **fixed total deadline**
    ///    (`replyDiscardBudgetMs`) anchored at the byte that started it. No incoming byte moves that
    ///    deadline — keystrokes are bytes, and a refreshed window made the typist the one input that
    ///    could keep a discard alive forever. Past the terminator and the cap nothing is typed; past
    ///    the **deadline** the keyboard comes back at that moment, and the only thing still
    ///    protected is the sequence's own ending: the next read is swallowed if it completes the
    ///    sequence, and is input if it does not (issue #109, round 6 — the round that stopped a
    ///    reply's late tail from being typed).
    /// 5. **A reply that never terminates still never types its payload** (#127, #109): the bytes up
    ///    to the abandon are dropped, never handed to the byte loop.
    public func resolveStall(now: Double = benchNowMs()) -> StalledBytes {
        // A discard is resolved by its own deadline, not by content: its buffer is empty by
        // construction, and `discardStartedAt` is the anchor `feed` cannot move.
        if isDiscarding {
            let lived = now - discardStartedAt
            guard lived >= Self.replyDiscardBudgetMs else { return .pending }
            checkDiscardDeadline(now: now)
            return .abandoned
        }

        let held = buffer
        guard let first = held.first else {
            stalledSince = 0
            return .none
        }
        if held.count == 1, first == 0x1B {
            buffer.removeAll(keepingCapacity: true)
            stalledSince = 0
            tailAttempt = false
            return .escape
        }

        // `ESC _`: a strict prefix of the only reply krd provokes, and the one buffer here that no
        // clock may decide (policy 1/2). It waits for the byte that decides it.
        if Self.isReplyHead(held) { return .pending }

        // A bare `ESC ]` — the introducer with no body yet — is the Alt-`]` keystroke. `main` left
        // these two bytes buffered until more arrived, so this is the one state that has to be
        // released for typing to continue; it swallows nothing, and a body is handled below.
        if held.count == 2, first == 0x1B, held[1] == 0x5D {
            buffer.removeAll(keepingCapacity: true)
            stalledSince = 0
            tailAttempt = false
            emit(.text("]", [.maskAlternate]))
            return .released
        }

        // A reply, and only a reply, may latch a discard: `ESC ] …` (a clipboard answer with a
        // body) or `ESC _ G …` (the graphics reply). Both carry a payload that must never be typed.
        if held.count >= 2, first == 0x1B, held[1] == 0x5D || Self.isReplyCandidate(held) {
            buffer.removeAll(keepingCapacity: true)
            stalledSince = 0
            startDiscard(osc: held[1] == 0x5D, now: now)
            return .sequence
        }

        // Half a keystroke: neither a reply nor a key, so it gets the grace and is then dropped.
        // It latches no discard, so the next key is unaffected.
        if stalledSince == 0 { stalledSince = now }
        guard now - stalledSince >= Self.keySequenceGraceMs else { return .pending }
        buffer.removeAll(keepingCapacity: true)
        stalledSince = 0
        tailAttempt = false
        return .sequence
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
            if tailAttempt {
                switch scanTail() {
                case let .completes(used):
                    // The sequence's own ending, arriving after its discard was given up. It is
                    // payload, not input, and never becomes a keystroke (issue #109, round 6).
                    buffer.removeFirst(min(used, buffer.count))
                    tailAttempt = false
                    emit(.notice("reply tail after the discard bound: \(used) B swallowed, 0 keys"))
                    continue
                case .hold:
                    // The read ended on the first half of `ST`: wait for the second half. Typing
                    // it now would type half a sequence.
                    return
                case .input:
                    // Not the ending: this is the input the returned keyboard promised.
                    tailAttempt = false
                    emit(.notice("reply sequence released after the discard bound: \(buffer.count) B are input"))
                    continue
                }
            }
            if isDiscarding {
                let before = buffer.count
                guard let used = discardingOSC ? discardOSC() : discardString() else {
                    // No terminator in this read: the discard functions have already emptied the
                    // buffer, so every one of those bytes was payload. Spend it against the budget
                    // (which may abandon the discard and hand the keyboard back), then wait — there
                    // is nothing left here to parse.
                    chargeDiscard(before)
                    return
                }
                // A terminator ended the discard: it is over, whatever it cost.
                buffer.removeFirst(min(used, buffer.count))
                finishDiscard(.terminator, livedMs: max(0, benchNowMs() - discardStartedAtWall))
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
                startDiscard(osc: true, now: benchNowMs())
                return nil
            }
            return nil
        case 0x5F:                                  // APC: `ESC _ … ST`, of which only `ESC _ G` is ours
            // `ESC _ G` is the *only* sequence krd ever asks a terminal to send (issue #109). A
            // `G` on the third byte enters the reply scan; anything else is the Alt-`_` keystroke
            // this parser has always produced for it, released on the spot. A *bare* `ESC _` (no
            // third byte yet) is the one undecided case: it stays buffered — **no clock, no
            // discard** — and the next byte decides it, which is what keeps a reply whose pieces
            // are written far apart from being typed (`resolveStall`, policy 1).
            guard buffer.count >= 3 else { return nil }
            guard buffer[2] == 0x47 else { return altText() }
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

    /// The graphics `APC` (`ESC _ G … ST`). The body is a reply's payload, never input, so it
    /// becomes exactly one `.graphicReply` — an unrecognised body included, as `unparsed`.
    ///
    /// `DCS` (`ESC P`), `SOS` (`ESC X`) and `PM` (`ESC ^`) deliberately do **not** arrive here: the
    /// same prefix is how a legacy terminal encodes Alt+P, Alt+X and Alt+^, so scanning for their
    /// `ST` ate a legal keystroke and every key typed while it waited. Only the reply prefix krd
    /// itself provokes (`ESC _ G`) is worth that trade (issue #109: no legal input may be eaten).
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
            startDiscard(osc: false, now: benchNowMs())
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

    /// Open a discard: the payload from here to the terminator is swallowed, within a budget the
    /// caller cannot forget to set. `OSC` carries a clipboard answer, which is legitimately
    /// megabytes, so its byte budget is the reply cap rather than a few hundred bytes.
    private func startDiscard(osc: Bool, now: Double) {
        discardingOSC = osc
        discardingString = !osc
        discardIntroducer = osc ? .osc : .apc
        tailAttempt = false
        // `discardSawESC` is deliberately untouched: when this is called from the over-cap path the
        // discard functions have just scanned the same read and may have parked half an `ST` there.
        discarded = 0
        discardByteCap = osc ? Self.maxEncodedOSC : Self.maxStringSequence
        // The clock is anchored here and never re-anchored: `feed` does not touch it (policy 4).
        discardStartedAt = now
        discardStartedAtWall = benchNowMs()
        stalledSince = 0
    }

    /// Close a discard and record what actually happened: which introducer, how many bytes it ate,
    /// and which of the three end conditions fired. The read loop logs this, and not the latch
    /// alone, so a user's own Alt-`]` is never reported as a terminal bug (issue #109, round 6).
    private func finishDiscard(_ end: DiscardEnd, livedMs: Double) {
        if let introducer = discardIntroducer {
            lastDiscard = DiscardReport(introducer: introducer, dropped: discarded,
                                        end: end, livedMs: livedMs)
            discardEndSerial += 1
        }
        discardingOSC = false
        discardingString = false
        discardSawESC = false
        discarded = 0
        discardByteCap = Self.maxStringSequence
        discardStartedAt = 0
        discardStartedAtWall = 0
        discardIntroducer = nil
    }

    /// The **fixed total deadline**, checked on every `feed` and on the read loop's idle tick. Past
    /// it the discard ends — the keyboard comes back — but the sequence it belonged to has not
    /// finished, so one tail attempt is armed: a read that *completes* it is still swallowed.
    private func checkDiscardDeadline(now: Double?) {
        guard isDiscarding else { return }
        let lived = now.map { $0 - discardStartedAt } ?? (benchNowMs() - discardStartedAtWall)
        guard lived >= Self.replyDiscardBudgetMs else { return }
        emit(.notice("reply discard abandoned: \(Int(lived)) ms"
                     + (discarded > 0 ? ", \(discarded) B dropped" : "")))
        abandonDiscard(end: .deadline, livedMs: lived)
    }

    /// Scan for the terminator of a sequence whose discard is already over. `completes` = the reply's
    /// late ending (swallow it), `input` = not that (the keyboard is back for real), `hold` = the
    /// read stopped on half an `ST`, so nothing may be decided yet.
    private func scanTail() -> TailScan {
        let scanTo = min(buffer.count, tailByteCap)
        var i = 0
        while i < scanTo {
            let b = buffer[i]
            if b == 0x07, tailIntroducer == .osc { return .completes(i + 1) }
            if b == 0x1B {
                guard i + 1 < buffer.count else { return .hold }
                if buffer[i + 1] == 0x5C { return .completes(i + 2) }
            }
            i += 1
        }
        return .input
    }

    /// Spend `n` payload bytes against the current discard's budget. `false` means the budget is
    /// gone: the discard is abandoned, the keyboard is back, and one `.notice` is the only trace of
    /// the bytes that were thrown away (policy 2 of `resolveStall` — no input path may wedge).
    @discardableResult
    private func chargeDiscard(_ n: Int) -> Bool {
        discarded += n
        guard discarded > discardByteCap else { return true }
        emit(.notice("reply discard abandoned: over \(discardByteCap) B dropped"))
        abandonDiscard(end: .byteCap, livedMs: max(0, benchNowMs() - discardStartedAtWall))
        return false
    }

    /// Give up a discard without a terminator: everything buffered is payload and goes too, and the
    /// next byte is input again — except for the one read that *completes* the sequence, which is
    /// its own ending arriving late and is swallowed (`scanTail`). The caller has already said why
    /// in a `.notice`.
    private func abandonDiscard(end: DiscardEnd, livedMs: Double) {
        buffer.removeAll(keepingCapacity: true)
        tailAttempt = discardIntroducer != nil
        tailIntroducer = discardIntroducer ?? .apc
        tailByteCap = discardByteCap
        finishDiscard(end, livedMs: livedMs)
        stalledSince = 0
    }

    /// Swallow the body of an `APC` up to its `ST`, for the reason `discardOSC` documents — an
    /// over-cap one, or one the read loop found stalled (`resolveStall`). The OSC discard's byte
    /// budget is `maxEncodedOSC` (**2,796,218 B** — the base64 of a 2 MB clipboard plus headroom),
    /// because a legal clipboard answer really is megabytes; this one's is `maxStringSequence`
    /// (65,536 B). Both are also on the fixed total deadline, which is what stops a typist's bytes
    /// from extending a discard (policy 4 of `resolveStall`). Same contract, one difference: `BEL`
    /// is payload in a string sequence, so it does not end the discard — ending there would type the
    /// rest of the reply.
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
