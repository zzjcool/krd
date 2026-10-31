import XCTest
@testable import krdcore

/// The terminal *answers* graphics requests on the same stdin that carries keystrokes (issue #109),
/// and `KRD_Q=0`/`1` is the documented way to see those answers. Nothing here needs a terminal —
/// `InputParser` is the pure half, and a reply is just bytes — so these tests state both halves of
/// the contract: the answer becomes a typed `Event.graphicReply` (so `krd` can say *why* a tile was
/// refused), and no byte of it ever becomes input (the #149 rule, applied to the whole
/// string-terminated family).
final class GraphicsReplyTests: XCTestCase {
    /// Everything a parsed stream would turn into a key press, an injected character or a control
    /// byte — i.e. the events that reach the mirrored desktop.
    private func injected(_ events: [Event]) -> [Event] {
        events.filter {
            switch $0 {
            case .key, .press, .text, .control: return true
            case .mouse, .osc, .keyboardFlags, .statusReport, .graphicReply, .notice: return false
            }
        }
    }

    private func replies(_ events: [Event]) -> [GraphicsReply] {
        events.compactMap { if case let .graphicReply(reply) = $0 { return reply } else { return nil } }
    }

    private func notices(_ events: [Event]) -> [String] {
        events.compactMap { if case let .notice(text) = $0 { return text } else { return nil } }
    }

    private func trace(_ events: [Event]) -> String {
        events.map(\.canonicalTrace).joined(separator: " | ")
    }

    /// Parse `bytes` as one read, in fixed-size chunks, or one split in two — and return every event.
    private func parse(_ bytes: [UInt8], chunk: Int? = nil, split: Int? = nil) -> [Event] {
        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }
        if let split {
            parser.feed(Array(bytes[0..<split]))
            parser.feed(Array(bytes[split...]))
        } else if let chunk {
            var i = 0
            while i < bytes.count {
                let end = min(i + chunk, bytes.count)
                parser.feed(Array(bytes[i..<end]))
                i = end
            }
        } else {
            parser.feed(bytes)
        }
        return events
    }

    // MARK: - APC (`ESC _ … ST`): where every graphics reply comes back

    /// A successful tile placement, `KRD_Q=0` (`docs/PROTOCOL.md` §8). 13 bytes, and the reason the
    /// old parser typed Alt-`_` `G` `i` `=` `3` `1` `;` `O` `K` `\` into the desktop.
    func testAPCSuccessReplyIsReportedAndNotTyped() {
        let events = parse(Array("\u{1B}_Gi=31;OK\u{1B}\\".utf8))
        XCTAssertEqual(injected(events).count, 0, "APC reply became input: \(trace(events))")
        let reply = replies(events)
        XCTAssertEqual(reply.count, 1, "the reply must be reported, or nothing can explain a tile")
        XCTAssertEqual(reply.first?.image, 31)
        XCTAssertEqual(reply.first?.status, "OK")
        XCTAssertEqual(reply.first?.isOK, true)
        XCTAssertEqual(reply.first?.isError, false)
    }

    /// A kitty *error* reply — the whole point of issue #109: a refused tile must say why.
    func testAPCErrorReplyCarriesTheReason() {
        let events = parse(Array("\u{1B}_Gi=137,p=7;EINVAL: decompression failed\u{1B}\\".utf8))
        XCTAssertEqual(injected(events).count, 0, "APC error became input: \(trace(events))")
        let reply = replies(events).first
        XCTAssertEqual(reply?.image, 137)
        XCTAssertEqual(reply?.placement, 7)
        XCTAssertEqual(reply?.status, "EINVAL: decompression failed")
        XCTAssertEqual(reply?.isError, true)
    }

    /// kitty also sends errors about no particular image (`ESC _ G EINVAL: … ST`, no `;`): the
    /// `issue`'s own repro uses that form. It must still be one typed event, not a guess.
    func testAPCErrorWithoutAnImageID() {
        let events = parse(Array("\u{1B}_GEINVAL: decompression failed\u{1B}\\".utf8))
        XCTAssertEqual(injected(events).count, 0, "APC error became input: \(trace(events))")
        XCTAssertEqual(replies(events).first?.image, nil)
        XCTAssertEqual(replies(events).first?.status, "EINVAL: decompression failed")
        XCTAssertEqual(replies(events).first?.isError, true)
    }

    /// `I=` names an image *number*, the other way kitty addresses one.
    func testAPCImageNumberForm() {
        let events = parse(Array("\u{1B}_GI=7;OK\u{1B}\\".utf8))
        XCTAssertEqual(injected(events).count, 0)
        XCTAssertEqual(replies(events).first?.imageNumber, 7)
        XCTAssertEqual(replies(events).first?.status, "OK")
    }

    /// The same reply split across two reads (a terminal writes it in one go, an ssh pty does not).
    /// Every split point — and one byte at a time — must give the same single event and no input.
    func testAPCReplySplitAcrossReadsIsNotTyped() {
        let reply = Array("\u{1B}_Gi=31,p=1;OK\u{1B}\\".utf8)
        for split in 1..<reply.count {
            let events = parse(reply, split: split)
            XCTAssertEqual(injected(events).count, 0, "split at \(split): \(trace(events))")
            XCTAssertEqual(replies(events).count, 1, "split at \(split): \(trace(events))")
        }
        let events = parse(reply, chunk: 1)
        XCTAssertEqual(injected(events).count, 0, "byte-at-a-time: \(trace(events))")
        XCTAssertEqual(replies(events).first?.image, 31)
        XCTAssertEqual(replies(events).first?.placement, 1)
    }

    /// A reply that is still arriving must not be typed *while* it is incomplete either.
    func testAPCPrefixAloneEmitsNothing() {
        let events = parse(Array("\u{1B}_Gi=31,p=1".utf8))
        XCTAssertEqual(events.count, 0, "an unfinished APC leaked: \(trace(events))")
    }

    /// APC is terminated by `ST` only, never `BEL` (the asymmetry tmux documents): a `BEL` inside a
    /// reply is payload, so it must neither end the sequence nor release the bytes after it.
    func testBELDoesNotTerminateAnAPC() {
        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }
        parser.feed(Array("\u{1B}_Gi=31;OK\u{07}".utf8))
        XCTAssertEqual(events.count, 0, "BEL ended an APC: \(trace(events))")
        parser.feed(Array("\u{1B}\\".utf8))
        XCTAssertEqual(injected(events).count, 0, "APC became input: \(trace(events))")
        XCTAssertEqual(replies(events).first?.image, 31)
    }

    // MARK: - what is *not* a reply: the rest of the string family

    /// `DCS` (`ESC P`), `SOS` (`ESC X`) and `PM` (`ESC ^`) are **not** replies as far as krd is
    /// concerned. Those three prefixes are exactly how a legacy terminal encodes Alt+P, Alt+X and
    /// Alt+^, so scanning them for an `ST` ate a legal keystroke and every key typed while it
    /// waited (the gate's stages D/E). Only the prefix krd itself provokes — `ESC _ G` — enters the
    /// reply scan; these keep the pre-#109 meaning byte for byte, which is what this pins.
    func testOtherStringSequencesStayKeystrokes() {
        let dcs = parse(Array("\u{1B}P1;2|hello\u{1B}\\".utf8))
        XCTAssertEqual(replies(dcs).count, 0, "a DCS is not a graphics reply: \(trace(dcs))")
        XCTAssertEqual(dcs.first, .text("P", [.maskAlternate]), trace(dcs))
        XCTAssertEqual(injected(dcs).count, 11, "DCS changed what reaches the desktop: \(trace(dcs))")

        let sos = parse(Array("\u{1B}Xjunk".utf8))
        XCTAssertEqual(sos.first, .text("X", [.maskAlternate]), trace(sos))
        XCTAssertEqual(injected(sos).count, 5, trace(sos))

        let pm = parse(Array("\u{1B}^junk".utf8))
        XCTAssertEqual(pm.first, .text("^", [.maskAlternate]), trace(pm))
        XCTAssertEqual(injected(pm).count, 5, trace(pm))
    }

    /// `KRD_Q=0` also makes the terminal answer the *transmit* (`ESC _ G a=t …`), with the same
    /// `i=<id>;OK`/`;E…` body. Same requirement, no `p=`.
    func testTransmitReplyIsNotTyped() {
        let events = parse(Array("\u{1B}_Gi=100;OK\u{1B}\\".utf8))
        XCTAssertEqual(injected(events).count, 0, "transmit reply became input: \(trace(events))")
        XCTAssertEqual(replies(events).first?.image, 100)
    }

    /// An unrecognised body is `unparsed` — typed as nothing, but reported, because "krd guessed
    /// these bytes were a keystroke" is exactly the bug.
    func testUnrecognisedAPCBodyIsReportedAsUnparsed() {
        let events = parse(Array("\u{1B}_Ghello\u{1B}\\".utf8))
        XCTAssertEqual(injected(events).count, 0)
        XCTAssertEqual(replies(events).first?.status, "unparsed")
        XCTAssertEqual(replies(events).first?.isError, false)
    }

    /// An error text may contain a `;` of its own (`EINVAL: bad; param`): only a `;` that follows
    /// real metadata (`i=`/`I=`/`p=`) separates it from the status, or the reason is lost.
    func testErrorTextWithASemicolonKeepsItsReason() {
        let events = parse(Array("\u{1B}_GEINVAL: bad; param\u{1B}\\".utf8))
        XCTAssertEqual(replies(events).first?.status, "EINVAL: bad; param")
        XCTAssertEqual(replies(events).first?.isError, true)
        XCTAssertEqual(injected(events).count, 0)
        // ... while metadata is still split off when it is there.
        let withID = parse(Array("\u{1B}_Gi=9;EINVAL: bad; param\u{1B}\\".utf8))
        XCTAssertEqual(withID.count == 1 ? replies(withID).first?.image : nil, 9)
        XCTAssertEqual(replies(withID).first?.status, "EINVAL: bad; param")
    }

    // MARK: - a sequence that stops arriving (the read loop's idle tick)

    /// An `APC` that never terminates emits nothing while it is incomplete: the body is buffered
    /// (or, past the cap, discarded) and no byte of it is typed.
    func testUnterminatedAPCEmitsNothing() {
        let events = parse(Array("\u{1B}_Gi=31;OK".utf8))
        XCTAssertEqual(events.count, 0, "an unfinished APC leaked: \(trace(events))")
    }

    /// Stage F of the gate's transcript (round 4): **a lone `ESC _` is the Alt-`_` keystroke**, and
    /// *no clock* decides that — the byte that arrives after it does. The idle tick holds it
    /// (`.pending`, however long the silence lasts), and `hello` then arrives as Alt+`_` and the five
    /// letters, with nothing lost and nothing typed early.
    func testALoneAPCHeadIsReleasedAsAltUnderscore() {
        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }

        parser.feed(Array("\u{1B}_".utf8))
        XCTAssertEqual(events.count, 0, "half a reply emitted early: \(trace(events))")
        XCTAssertEqual(parser.resolveStall(now: 100), .pending, "the head was decided on the first tick")
        XCTAssertEqual(parser.resolveStall(now: 400), .pending, "300 ms is inside the window")
        XCTAssertEqual(parser.resolveStall(now: 5_000), .pending,
                       "a clock released the reply head — the round-4 regression")

        parser.feed(Array("hello".utf8))                  // ... and now the keys arrive
        XCTAssertEqual(events, [.text("_", [.maskAlternate]), .text("h", []), .text("e", []),
                                .text("l", []), .text("l", []), .text("o", [])],
                       "the keyboard did not come back: \(trace(events))")
    }

    /// The deciding third byte is honoured while the head is still held: the same stalled `ESC _`,
    /// followed by the rest of the reply, is *heard* as one reply — not typed, and not discarded as
    /// if the head had been a keystroke either. The hold is not a window (round 4): the gate's gap 2
    /// was `ESC _` + 1200 ms + `Gi=31;OK ST`, and the reply must still be the answer at 1200 ms.
    func testAHeldAPCHeadStillBecomesTheReply() {
        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }
        parser.feed(Array("\u{1B}_".utf8))
        for tick in stride(from: 100.0, through: 1_200.0, by: 100) {
            XCTAssertEqual(parser.resolveStall(now: tick), .pending, "released at \(tick) ms")
        }
        parser.feed(Array("Gi=31;OK\u{1B}\\".utf8))
        XCTAssertEqual(replies(events).count, 1, trace(events))
        XCTAssertEqual(injected(events).count, 0, "a reply was typed: \(trace(events))")
    }

    /// Policy 4: a discard dies on a **fixed total deadline** counted from the byte that started it,
    /// not on an idle window. Past `replyDiscardBudgetMs`, the keyboard comes back and one `.notice`
    /// says so.
    func testAReplyThatNeverTerminatesLosesItsKeyboardForNoMoreThanTheDeadline() {
        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }

        parser.feed(Array("\u{1B}_Gi=31;OK".utf8))        // a reply whose `ST` never came
        // The idle tick that latched it is the anchor: whatever `now` the loop sees next, the 1500 ms
        // run from *here*.
        XCTAssertEqual(parser.resolveStall(now: 1_000), .sequence)
        XCTAssertEqual(injected(events).count, 0, "the payload was typed: \(trace(events))")
        XCTAssertEqual(parser.resolveStall(now: 2_000), .pending, "abandoned too early")
        XCTAssertEqual(parser.resolveStall(now: 2_600), .abandoned)
        XCTAssertEqual(notices(events).count, 1, "the abandon was not logged: \(trace(events))")

        parser.feed(Array("hi".utf8))                     // ... and the keyboard is back
        XCTAssertEqual(injected(events), [.text("h", []), .text("i", [])], trace(events))
    }

    /// **The round-4 regression, gap 3.** A keystroke is a byte, so an idle clock that every `feed`
    /// refreshed made the *typist* the one input that could keep a discard alive forever: a stray
    /// `ESC ]` swallowed every key typed afterwards, up to a 2.7 MB budget. The deadline is anchored
    /// at the discard's first byte and no byte moves it.
    func testADiscardsDeadlineIsNotRefreshedByIncomingBytes() {
        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }

        parser.feed(Array("\u{1B}_Gi=31;OK".utf8))
        XCTAssertEqual(parser.resolveStall(now: 0), .sequence)
        // 1400 ms of typing at 200 ms intervals: the same bytes that used to reset the clock.
        for tick in stride(from: 200.0, through: 1_400.0, by: 200) {
            parser.feed(Array("x".utf8))
            XCTAssertEqual(parser.resolveStall(now: tick), .pending,
                           "abandoned before its deadline at \(tick) ms")
        }
        XCTAssertEqual(parser.resolveStall(now: 1_500), .abandoned,
                       "the deadline slid with the incoming bytes")

        events.removeAll()
        parser.feed(Array("hi".utf8))
        XCTAssertEqual(injected(events), [.text("h", []), .text("i", [])], trace(events))
    }

    /// The other half of the same budget: a discard that keeps receiving bytes is still capped, so a
    /// terminal stuck mid-sequence cannot swallow input without end.
    func testAReplyDiscardIsAlsoBoundedInBytes() {
        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }
        parser.feed(Array("\u{1B}_Gi=31".utf8))
        XCTAssertEqual(parser.resolveStall(now: 100), .sequence)

        var block = [UInt8](repeating: 0x41, count: 16 << 10)   // 16 KiB a read, no `ST` anywhere
        for _ in 0..<6 { parser.feed(block) }
        XCTAssertEqual(notices(events).count, 1, "the byte cap never tripped: \(trace(events))")

        events.removeAll()
        parser.feed(Array("hi".utf8))
        XCTAssertEqual(injected(events), [.text("h", []), .text("i", [])], trace(events))
    }

    /// Once the `G` has arrived the payload is a reply and the discard is the right answer: dropping
    /// it would hand the rest of the body to the byte loop.
    func testAStalledAPCBodyAlsoLosesItsTail() {
        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }
        parser.feed(Array("\u{1B}_Gi=31".utf8))
        XCTAssertEqual(parser.resolveStall(now: 100), .sequence)
        parser.feed(Array(";OK\u{1B}\\".utf8))
        XCTAssertEqual(events.count, 0, "the tail of a stalled reply was typed: \(trace(events))")
    }

    /// Stage G: an `OSC` reply that stops mid-body. This is the regression the gate found — the read
    /// loop used to `reset()`, discard the head, and parse `SECRET` (the rest of the payload) as the
    /// keys S, E, C, R, E, T into the mirrored desktop.
    func testAStalledOSCLosesItsTailToTheDiscard() {
        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }

        parser.feed(Array("\u{1B}]52;c;".utf8))            // a clipboard read reply, truncated
        XCTAssertEqual(events.count, 0, trace(events))
        XCTAssertEqual(parser.resolveStall(now: 100), .sequence)

        parser.feed(Array("SECRET\u{1B}\\".utf8))
        XCTAssertEqual(injected(events).count, 0, "the tail of a stalled OSC was typed: \(trace(events))")
        parser.feed(Array("hi".utf8))
        XCTAssertEqual(events, [.text("h", []), .text("i", [])], trace(events))
    }

    /// The two discards keep the asymmetry the terminator scan uses: `BEL` ends an `OSC` and never
    /// an `APC` (a `BEL` inside a reply is payload, so ending there would type the rest of it).
    func testTheDiscardsEndWhereTheSequencesEnd() {
        let osc = InputParser()
        var oscEvents: [Event] = []
        osc.onEvent = { oscEvents.append($0) }
        osc.feed(Array("\u{1B}]52;c;".utf8))
        _ = osc.resolveStall(now: 100)
        osc.feed(Array("ab\u{07}hi".utf8))
        XCTAssertEqual(oscEvents, [.text("h", []), .text("i", [])], trace(oscEvents))

        let apc = InputParser()
        var apcEvents: [Event] = []
        apc.onEvent = { apcEvents.append($0) }
        apc.feed(Array("\u{1B}_G".utf8))
        _ = apc.resolveStall(now: 100)
        apc.feed(Array("ab\u{07}cd\u{1B}\\hi".utf8))
        XCTAssertEqual(apcEvents, [.text("h", []), .text("i", [])],
                       "a BEL ended an APC discard: \(trace(apcEvents))")
    }

    /// **The round-4 regression, gap 1.** `ESC ]` is how a legacy terminal encodes Alt+`]`, so a
    /// stray one must cost exactly one keystroke and nothing else. Round 3 latched an OSC discard on
    /// it — budget `maxEncodedOSC`, 2,796,218 B — and the idle clock was refreshed by every key, so a
    /// typist could lose 27 of 27 keystrokes. It is Alt-`]` on the next read that returns no data,
    /// and the typing after it is untouched.
    func testABareOSCIntroducerIsTheAltBracketKey() {
        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }

        parser.feed(Array("\u{1B}]".utf8))
        XCTAssertEqual(events.count, 0, "half a sequence emitted early: \(trace(events))")
        XCTAssertEqual(parser.resolveStall(now: 100), .released,
                       "a bare `ESC ]` latched a discard instead of being a key")
        XCTAssertEqual(events, [.text("]", [.maskAlternate])], trace(events))
        XCTAssertFalse(parser.isDiscarding, "a legal Alt+] started a discard")

        // ... and a whole second of typing, one key every 200 ms, arrives as keys.
        for ch in "hello" {
            parser.feed(Array(String(ch).utf8))
            XCTAssertEqual(parser.resolveStall(now: 300), .none)
        }
        XCTAssertEqual(events, [.text("]", [.maskAlternate]), .text("h", []), .text("e", []),
                                .text("l", []), .text("l", []), .text("o", [])], trace(events))
    }

    /// Only a lone `ESC` has no tail, so it is the only stalled buffer still released as a key with
    /// nothing after it. (`ESC ]` is released too — as Alt-`]`, above — because an introducer with
    /// no body is a keystroke; `ESC _` is *held*, because two of its three possible bytes are a
    /// reply.)
    func testAStalledLoneEscapeIsStillTheEscKey() {
        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }
        parser.feed([0x1B])
        XCTAssertEqual(parser.resolveStall(now: 100), .escape)
        XCTAssertEqual(parser.buffer.count, 0)
        XCTAssertEqual(events.count, 0, "the read loop decides what the Esc key is")
    }

    /// Half a keystroke (`ESC O` is half of F1, `ESC [ 1 ; 5` half a modified arrow) is neither a
    /// reply nor a key: dropped, and — unlike a reply — it latches no discard, so the next key is
    /// unaffected. This is the pair the gate's stages D/E were about.
    func testAStalledKeySequenceIsDroppedWithoutADiscard() {
        for half in ["\u{1B}O", "\u{1B}[1;5"] {
            let parser = InputParser()
            var events: [Event] = []
            parser.onEvent = { events.append($0) }
            parser.feed(Array(half.utf8))
            XCTAssertEqual(events.count, 0, "half a key emitted: \(trace(events))")
            XCTAssertEqual(parser.resolveStall(now: 100), .pending, "\(half) was dropped at once")
            XCTAssertEqual(parser.resolveStall(now: 700), .sequence, "\(half) survived the grace")
            parser.feed(Array("ab".utf8))
            XCTAssertEqual(events, [.text("a", []), .text("b", [])],
                           "\(half): the discard ate the next key: \(trace(events))")
        }
    }

    /// Which prefixes may latch a discard. `OSC` and `APC` carry a reply's payload; the rest are
    /// keys in progress and must not swallow anything. Being one of these two is *necessary* for a
    /// reply and never sufficient — `isReplyCandidate` is the sufficient test.
    func testOnlyTheReplyPrefixesLatchADiscard() {
        XCTAssertTrue(InputParser.isReplyPrefix([0x1B, 0x5F]))
        XCTAssertTrue(InputParser.isReplyPrefix([0x1B, 0x5D, 0x35]))
        XCTAssertFalse(InputParser.isReplyPrefix([0x1B]))
        XCTAssertFalse(InputParser.isReplyPrefix([]))
        XCTAssertFalse(InputParser.isReplyPrefix([0x1B, 0x4F]))
        XCTAssertFalse(InputParser.isReplyPrefix([0x1B, 0x5B, 0x31]))

        XCTAssertTrue(InputParser.isReplyCandidate(Array("\u{1B}_G".utf8)))
        XCTAssertTrue(InputParser.isReplyCandidate(Array("\u{1B}_Gi=31;OK".utf8)))
        XCTAssertFalse(InputParser.isReplyCandidate(Array("\u{1B}_".utf8)),
                       "a lone `ESC _` is the Alt-`_` key, not a reply")
        XCTAssertFalse(InputParser.isReplyCandidate(Array("\u{1B}_hello".utf8)))
        XCTAssertFalse(InputParser.isReplyCandidate([0x1B]))
    }

    // MARK: - the keystroke this must not break

    /// Alt-`_` is a legal thing to type. Only `ESC _ G` starts a reply, so any other `ESC _` keeps
    /// today's meaning exactly: Alt+`_`, then whatever came next.
    func testAltUnderscoreIsStillAKeystroke() {
        let events = parse(Array("\u{1B}_x".utf8))
        XCTAssertEqual(replies(events).count, 0, "Alt+_ was taken for a reply: \(trace(events))")
        XCTAssertEqual(events, [.text("_", [.maskAlternate]), .text("x", [])])
    }

    /// The two-byte prefix is held (it may be the start of a reply), and released as Alt+`_` when the
    /// next byte says it is not one — no byte is lost, none is typed early.
    func testAltUnderscoreAcrossTwoReads() {
        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }
        parser.feed(Array("\u{1B}_".utf8))
        XCTAssertEqual(events.count, 0, "half a sequence emitted early: \(trace(events))")
        parser.feed(Array("x".utf8))
        XCTAssertEqual(events, [.text("_", [.maskAlternate]), .text("x", [])])
    }

    /// Alt-`P`/`X`/`^` arrive as `ESC P`/`X`/`^` — the same bytes a `DCS`/`SOS`/`PM` starts with.
    /// They resolve on the spot, so the key is not even *slow*, let alone eaten.
    func testAltLettersSharingASequencePrefixAreImmediate() {
        for (letter, bytes) in [("P", "\u{1B}P"), ("X", "\u{1B}X"), ("^", "\u{1B}^")] {
            let parser = InputParser()
            var events: [Event] = []
            parser.onEvent = { events.append($0) }
            parser.feed(Array(bytes.utf8))
            XCTAssertEqual(events, [.text(Character(letter), [.maskAlternate])], bytes)
            XCTAssertEqual(parser.buffer.count, 0, "\(bytes) was held instead of resolved")
        }
    }

    // MARK: - the cap (the #149 rule, for the string family)

    /// An over-cap body is a reply, not input: it is swallowed whole to its `ST`, with one notice,
    /// and the buffer never grows with it. The bytes after the terminator still parse.
    func testOverCapStringSequenceIsSwallowedWhole() {
        let body = [UInt8](repeating: 0x41, count: InputParser.maxStringSequence + 4096)
        var bytes = Array("\u{1B}_G".utf8)
        bytes += body
        bytes += Array("\u{1B}\\".utf8)
        bytes += Array("ab".utf8)

        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }
        for i in stride(from: 0, to: bytes.count, by: 4096) {
            parser.feed(Array(bytes[i..<min(i + 4096, bytes.count)]))
            XCTAssertLessThan(parser.buffer.count, InputParser.maxStringSequence + 4096 + 32,
                              "the reply was buffered, not swallowed")
        }
        XCTAssertEqual(injected(events), [.text("a", []), .text("b", [])],
                       "an over-cap reply leaked into input: \(trace(events))")
        XCTAssertEqual(notices(events), ["string sequence dropped: over cap"])
        XCTAssertEqual(replies(events).count, 0, "a dropped reply is not a parsed one")
    }
}
