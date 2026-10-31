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

    // MARK: - the rest of the string-terminated family

    /// DCS (`ESC P`), SOS (`ESC X`) and PM (`ESC ^`) are the same class of sequence: replies, not
    /// keys. A terminal that answers `CSI 6n` inside a DCS, or a `tmux` passthrough, lands here.
    func testOtherStringSequencesAreNotTypedEither() {
        let dcs = parse(Array("\u{1B}P1;2|hello\u{1B}\\".utf8))
        XCTAssertEqual(injected(dcs).count, 0, "DCS became input: \(trace(dcs))")
        XCTAssertEqual(replies(dcs).first?.status, "unparsed", "a DCS body is reported, not guessed")
        XCTAssertEqual(notices(dcs).count, 0)

        let sos = parse(Array("\u{1B}Xjunk\u{1B}\\".utf8))
        XCTAssertEqual(injected(sos).count, 0, "SOS became input: \(trace(sos))")
        XCTAssertEqual(replies(sos).count, 1)

        let pm = parse(Array("\u{1B}^junk\u{1B}\\".utf8))
        XCTAssertEqual(injected(pm).count, 0, "PM became input: \(trace(pm))")
        XCTAssertEqual(replies(pm).count, 1)
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

    /// A `DCS`/`SOS`/`PM` that never terminates still emits nothing — the read loop's idle tick
    /// drops the stalled bytes, so the keyboard comes back without a payload byte being typed.
    func testUnterminatedStringSequenceEmitsNothing() {
        let dcs = parse(Array("\u{1B}P1;2|hello".utf8))
        XCTAssertEqual(dcs.count, 0, "an unfinished DCS leaked: \(trace(dcs))")
        let sos = parse(Array("\u{1B}Xjunk".utf8))
        XCTAssertEqual(sos.count, 0, "an unfinished SOS leaked: \(trace(sos))")
        let pm = parse(Array("\u{1B}^junk".utf8))
        XCTAssertEqual(pm.count, 0, "an unfinished PM leaked: \(trace(pm))")
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
