import XCTest
@testable import krdcore

/// The batched capability reply, as a pure function (issue #197).
///
/// This absorbed `Tests/krdTests/GraphemeModeTests` (PR #193): the `DECRQM 2027` question is no longer a
/// probe of its own, so its parse — the part with a wrong answer available — moves with it into the one
/// parser. A terminal that does not implement 2027 does not answer "no", it says nothing at all, so the
/// only thing that ends the read is the `DA1`; a parse that read a `$y` from some other report, or that
/// turned "no answer" into `0`, would send every session down the wrong path silently.
///
/// Seven questions leave in one write and one answer comes back; the parse has to find four kinds of
/// answer in it — a `CSI … t` size, a `DECRQM … $y` verdict, an `OSC … ; rgb:` colour, and the `DA1` —
/// and has to *not* invent the ones that are missing. That last half is the part
/// a terminal cannot be relied on to test: a real terminal answers everything, so "the `DA1`-only reply
/// means nothing is known" only ever runs here — and it is the reply every terminal without `DECRQM`
/// sends, i.e. the common case for a shell in a plain xterm.
final class TermCapsTests: XCTestCase {
    /// The reference pane from `docs/BENCHMARK.md`: a 17x33 cell in a 2329x1452 text area.
    private let reply = "\u{1B}[6;33;17t\u{1B}[4;1452;2329t\u{1B}[?2027;2$y\u{1B}[?62;22c"

    // MARK: the batch, whole

    func testOneReplyCarryingAllFourAnswersParsesIntoOneValue() throws {
        let caps = TermCaps.parse(reply)
        let cell = try XCTUnwrap(caps.cell)
        XCTAssertEqual(cell.w, 17)
        XCTAssertEqual(cell.h, 33)
        let window = try XCTUnwrap(caps.window)
        XCTAssertEqual(window.w, 2329)
        XCTAssertEqual(window.h, 1452)
        XCTAssertEqual(caps.graphemeMode, 2, "Rex: recognised, reset")
        XCTAssertTrue(caps.terminated)
        XCTAssertFalse(caps.isEmpty)
    }

    func testTheOrderTheTerminalAnswersInDoesNotMatter() {
        let shuffled = "\u{1B}[?62;22c\u{1B}[?2027;1$y\u{1B}[4;1452;2329t\u{1B}[6;33;17t"
        XCTAssertEqual(TermCaps.parse(shuffled), TermCaps.parse(reply.replacingOccurrences(
            of: "\u{1B}[?2027;2$y", with: "\u{1B}[?2027;1$y")))
    }

    // MARK: the questions the terminal did not answer

    /// The reply every terminal that knows none of these modes sends: nothing but its `DA1`.
    ///
    /// "Everything unknown" must be `nil`s, not zeros — a caller that read `0x0` as an answer would
    /// draw a picture zero cells wide. This is the test that would catch a parse that defaulted.
    func testADA1OnlyReplyIsEverythingUnknownRatherThanZero() {
        let caps = TermCaps.parse("\u{1B}[?62;22c")
        XCTAssertTrue(caps.isEmpty, "a DA1-only reply must not look like an answer: \(caps)")
        XCTAssertNil(caps.cell, "0 is not a cell size")
        XCTAssertNil(caps.window, "0 is not a window size")
        XCTAssertNil(caps.graphemeMode, "silence about 2027 is not \"reset\"")
        XCTAssertTrue(caps.terminated, "the sentinel did arrive — that is why the read stopped")
    }

    func testNoReplyAtAllIsNone() {
        XCTAssertEqual(TermCaps.parse(nil), .none)
        XCTAssertEqual(TermCaps.parse(""), .none)
        XCTAssertFalse(TermCaps.parse(nil).terminated, "a timeout is not a terminator")
    }

    func testAWindowAnswerAloneStillParses() throws {
        // The `CSI 14t`-only case from issue #56, now inside the batch.
        let caps = TermCaps.parse("\u{1B}[4;1452;2329t\u{1B}[?62;22c")
        XCTAssertNil(caps.cell)
        XCTAssertEqual(try XCTUnwrap(caps.window).w, 2329)
        XCTAssertNil(caps.graphemeMode)
    }

    // MARK: split across reads

    /// A reply that arrives in pieces is the normal case over ssh (and in the pty test): the loop
    /// re-checks the accumulated string, so a half answer must parse as "not yet", and the complete
    /// string must parse the same as if it had arrived in one read.
    func testAReplySplitAcrossReadsParsesTheSame() {
        let halves = [String(reply.prefix(12)), String(reply.dropFirst(12))]
        let first = TermCaps.parse(halves[0])
        XCTAssertFalse(TermCaps.isComplete(halves[0]), "half a reply is not complete")
        XCTAssertNil(first.window, "the `CSI 4t` answer had not arrived yet")
        XCTAssertNil(first.graphemeMode, "the `DECRQM` answer had not arrived yet")

        let joined = TermCaps.parse(halves[0] + halves[1])
        XCTAssertEqual(joined, TermCaps.parse(reply), "two reads and one read are the same reply")
        XCTAssertTrue(joined.terminated)
    }

    func testATruncatedAnswerIsIgnoredNotGuessed() {
        // The numbers may still be growing, so a sequence without its `t` is not an answer.
        XCTAssertNil(TermCaps.parse("\u{1B}[4;600;800").window)
        XCTAssertNil(TermCaps.parse("\u{1B}[4;600;").window)
        XCTAssertNil(TermCaps.parse("\u{1B}[6;33;").cell)
        // A complete answer followed by a truncated one keeps the complete one.
        XCTAssertEqual(TermCaps.parse("\u{1B}[6;33;17t\u{1B}[4;600;").cell?.w, 17)
    }

    // MARK: DECRQM

    func testEveryGraphemeModeVerdictDECRQPCanGive() {
        for (ps, expected) in [(0, 0), (1, 1), (2, 2), (3, 3), (4, 4)] {
            XCTAssertEqual(TermCaps.graphemeModeVerdict("\u{1B}[?2027;\(ps)$y"), expected,
                           "DECRQM Ps \(ps)")
        }
        XCTAssertNil(TermCaps.graphemeModeVerdict(nil))
        XCTAssertNil(TermCaps.graphemeModeVerdict("\u{1B}[?62;22c"), "DA1 alone says nothing about 2027")
        XCTAssertNil(TermCaps.graphemeModeVerdict("\u{1B}[?2027;2$"),
                     "the `y` has not arrived: some other report may still be coming")
        XCTAssertNil(TermCaps.graphemeModeVerdict("\u{1B}[?2027;5$y"), "5 is not a DECRQM value")
        XCTAssertNil(TermCaps.graphemeModeVerdict("\u{1B}[?2027;$y"), "no value at all")
        // The mode number of *another* mode is not this one's.
        XCTAssertNil(TermCaps.graphemeModeVerdict("\u{1B}[?2026;1$y"))
    }

    /// `Ps` is DECRQM's verdict: 0 not recognised, 1 set, 2 reset, 3/4 permanently so. Only `2` is a
    /// reason to enable anything, but all five are real answers and have to parse.
    func testTheModeVerdictSurvivesTheTerminatorAndTheGaps() {
        // Ghostty's answer (set) and Rex's (recognised, reset), each followed by its DA1.
        XCTAssertEqual(TermCaps.graphemeModeVerdict("\u{1B}[?2027;1$y\u{1B}[?62;22;52c"), 1)
        XCTAssertEqual(TermCaps.graphemeModeVerdict("\u{1B}[?2027;2$y\u{1B}[?62;22c"), 2)
        XCTAssertEqual(TermCaps.graphemeModeVerdict("\u{1B}[?2027;0$y\u{1B}[?62c"), 0)
        // A reply that arrives in pieces: `ask` concatenates whatever the pty hands over, and a split
        // can land anywhere — including between `2027;` and its number.
        XCTAssertEqual(TermCaps.graphemeModeVerdict(["\u{1B}[?2027", ";2$y", "\u{1B}[?62;22c"].joined()), 2)
        // A report that merely starts the same way is not 2027's answer.
        XCTAssertNil(TermCaps.graphemeModeVerdict("\u{1B}[?2028;2$y\u{1B}[?62c"))
        XCTAssertNil(TermCaps.graphemeModeVerdict("\u{1B}[?2027;1m\u{1B}[?62c"), "wrong final byte")
    }

    /// The sentinel is a `DA1` and nothing else: a mode report, a cursor report and a colour report all
    /// arrive on the same wire, and the read loop must not stop on one of those.
    func testTheSentinelIsADA1AndNotAnyOtherCSI() {
        XCTAssertTrue(TermCaps.containsPrimaryAttributes("\u{1B}[?62;22;52c"))
        XCTAssertTrue(TermCaps.containsPrimaryAttributes("\u{1B}[?2027;2$y\u{1B}[?62;22c"))
        XCTAssertFalse(TermCaps.containsPrimaryAttributes("\u{1B}[?2027;2$y"))
        XCTAssertFalse(TermCaps.containsPrimaryAttributes("\u{1B}[6;33;17t"))
        XCTAssertFalse(TermCaps.containsPrimaryAttributes("\u{1B}]11;rgb:ffff/ffff/ffff\u{1B}\\"))
        XCTAssertFalse(TermCaps.containsPrimaryAttributes(""))
        // `c` with nothing before it is not a DA1 either, and neither is a bare `?c`.
        XCTAssertFalse(TermCaps.containsPrimaryAttributes("\u{1B}[c"))
        XCTAssertFalse(TermCaps.containsPrimaryAttributes("\u{1B}[?c"))
    }

    // MARK: the bytes on the wire

    /// DEC mode 2031's colour-scheme report (issue #212) arrives on the same wire and ends in `n`.
    /// The read loop is still terminated by the `DA1` and by nothing else, and the three answers are
    /// still found around it — one write, one round trip, one terminator (#197).
    func testAColourSchemeReportEndsNothingAndHidesNoAnswer() {
        XCTAssertFalse(TermCaps.isComplete("\u{1B}[?997;1n"), "a colour-scheme report is not the DA1")
        let withScheme = "\u{1B}[?997;2n" + reply
        XCTAssertTrue(TermCaps.isComplete(withScheme), "the DA1 after it still ends the read")
        XCTAssertEqual(TermCaps.parse(withScheme), TermCaps.parse(reply),
                       "the report neither adds a field nor hides one")
        // Between two answers, not only in front of them: the parse must not be position-sensitive.
        let interleaved = reply.replacingOccurrences(of: "\u{1B}[4;",
                                                     with: "\u{1B}[?997;1n\u{1B}[4;")
        XCTAssertEqual(TermCaps.parse(interleaved), TermCaps.parse(reply))
    }

    /// The batch is one string *and* seven questions in it: a shorter `query` would silently stop asking
    /// a question krd still needs, and the compiler would not say so.
    ///
    /// `#213` widened the batch from four questions to seven — `DECRQM ?2031` and the two `OSC` colour
    /// questions joined it — so this assertion is updated to the frozen wire format rather than
    /// dropped: the point is still an exact string, with the `DA1` still last.
    func testTheBatchIsSevenQuestionsInOneString() {
        XCTAssertEqual(TermCaps.query,
                       "\u{1B}[16t\u{1B}[14t\u{1B}[?2027$p\u{1B}[?2031$p"
                       + "\u{1B}]10;?\u{1B}\\\u{1B}]11;?\u{1B}\\" + "\u{1B}[c")
        XCTAssertTrue(TermCaps.query.hasSuffix("\u{1B}[c"), "the DA1 has to be the last question")
        // Seven questions = five `CSI` introductions plus the two `OSC` colour questions. Counted
        // both ways so that a question quietly dropped from one half is a failure, not a shorter
        // string nobody looks at.
        XCTAssertEqual(TermCaps.query.components(separatedBy: "\u{1B}[").count - 1, 5,
                       "five CSI introductions")
        XCTAssertEqual(TermCaps.query.components(separatedBy: "\u{1B}]").count - 1, 2,
                       "plus the two OSC colour questions")
        // The terminator is the `DA1`, so a `DA1`-only reply completes the batch: that is what keeps a
        // terminal that knows none of the other six from waiting out the timeout.
        XCTAssertTrue(TermCaps.isComplete("\u{1B}[?62;22c"))
        XCTAssertFalse(TermCaps.isComplete("\u{1B}[?2027;2$y"), "one answer is not the terminator")
        XCTAssertFalse(TermCaps.isComplete(""), "an empty read is not complete")
    }

    // MARK: the colour questions (issue #213)

    /// The seven answers of one batch, in one reply: both sizes, both `DECRQM` verdicts, both colours
    /// and the `DA1`. Nothing here may be inferred from a neighbour — every field is read out of the
    /// raw reply by its own introducer.
    private let colourReply = "\u{1B}[6;33;17t\u{1B}[4;1452;2329t\u{1B}[?2027;2$y\u{1B}[?2031;1$y"
        + "\u{1B}]10;rgb:1e1e/1e1e/1e1e\u{1B}\\\u{1B}]11;rgb:0d0d/1111/1717\u{1B}\\" + "\u{1B}[?62;22c"

    /// Property: a reply that answers everything fills every field, and the palette it makes is the
    /// one `Palette(foreground:background:)` makes out of the very two colours the terminal sent —
    /// not a second derivation living in the probe.
    func testASevenAnswerReplyFillsEveryFieldOfTheBatch() throws {
        let caps = TermCaps.parse(colourReply)
        XCTAssertEqual(try XCTUnwrap(caps.cell).w, 17)
        XCTAssertEqual(try XCTUnwrap(caps.window).w, 2329)
        XCTAssertEqual(caps.graphemeMode, 2, "Rex: recognised, reset")
        XCTAssertEqual(caps.colourSchemeMode, 1, "recognised, set")
        XCTAssertEqual(caps.foreground, RGB(0x1E_1E_1E), "OSC 10, 16-bit form")
        XCTAssertEqual(caps.background, RGB(0x0D_11_17), "OSC 11, 16-bit form")
        XCTAssertEqual(caps.palette, Palette(foreground: RGB(0x1E_1E_1E), background: RGB(0x0D_11_17)))
        XCTAssertTrue(caps.supportsColourSchemeFollow)
        XCTAssertTrue(caps.terminated)
        XCTAssertFalse(caps.isEmpty)
    }

    /// A terminal answers in whatever order its parser reaches the questions, and the answers can be
    /// interleaved with anything else on the wire. `parse` is a scan of the accumulated string, so two
    /// replies with the same contents in a different order are the same `TermCaps`.
    func testTheOrderTheColourAnswersArriveInDoesNotMatter() {
        let shuffled = "\u{1B}]11;rgb:0d0d/1111/1717\u{1B}\\" + "\u{1B}[?2031;1$y"
            + "\u{1B}[?62;22c" + "\u{1B}]10;rgb:1e1e/1e1e/1e1e\u{1B}\\" + "\u{1B}[4;1452;2329t"
            + "\u{1B}[?2027;2$y" + "\u{1B}[6;33;17t"
        XCTAssertEqual(TermCaps.parse(shuffled), TermCaps.parse(colourReply),
                       "the `DA1` in the middle changes nothing: only the parse order could")
    }

    /// The reply every terminal without `DECRQM` and without `OSC 10`/`OSC 11` sends. "No palette" is
    /// the documented degrade — today's hard-coded SGR table, byte for byte — so this is the reply
    /// that must *not* invent one, and the one that must not read `OSC 12` or a size answer as a
    /// colour.
    func testADA1OnlyReplyHasNoColoursAndNoPalette() {
        let caps = TermCaps.parse("\u{1B}[?62;22c")
        XCTAssertNil(caps.foreground)
        XCTAssertNil(caps.background)
        XCTAssertNil(caps.colourSchemeMode, "silence about 2031 is not a verdict")
        XCTAssertNil(caps.palette, "no answer must stay on the hard-coded table")
        XCTAssertFalse(caps.supportsColourSchemeFollow, "silence is not permission")
        XCTAssertTrue(caps.terminated)
        XCTAssertTrue(caps.isEmpty, "a DA1-only reply is still nothing known: \(caps)")
    }

    /// Answers arrive in pieces over ssh — `ask` concatenates whatever the pty hands over, and a split
    /// can land anywhere, including inside an `OSC` body. A body whose terminator has not arrived is
    /// `nil` (it may still be growing), and the joined string parses exactly like one read.
    func testOSCAnswersSplitAcrossReadsParseTheSame() throws {
        let cut = try XCTUnwrap(colourReply.range(of: "\u{1B}\\")?.lowerBound,
                                "the fixture has an `ST` in it")
        let head = String(colourReply[..<cut]), tail = String(colourReply[cut...])
        XCTAssertNil(TermCaps.parse(head).foreground,
                     "half an `OSC 10` body is not a colour: the rest is still coming")
        XCTAssertNil(TermCaps.parse(head).palette, "and half a colour is not a palette")
        XCTAssertEqual(TermCaps.parse(head + tail), TermCaps.parse(colourReply),
                       "two reads and one read are the same reply")
        // Split in the middle of the digits, not only before the terminator: the head is a
        // colour-shaped prefix and nothing may be read out of it — the joined pair is still the whole
        // answer.
        let body = try XCTUnwrap(colourReply.range(of: "1e1e/1e1e"))
        let half = colourReply.index(body.lowerBound, offsetBy: 6)
        XCTAssertNil(TermCaps.parse(String(colourReply[..<half])).foreground)
        XCTAssertEqual(TermCaps.parse(String(colourReply[..<half]) + colourReply[half...]),
                       TermCaps.parse(colourReply))
    }

    /// A colour that was misparsed is a wrong colour on every cell of the pane, so every malformed
    /// body is `nil` — and, just as important, it leaves the *other* six answers alone: a terminal
    /// that answers one badly is still a terminal that knows its cell size and its modes.
    func testAMalformedColourAnswerLeavesNoPaletteAndDisturbsNothing() {
        for body in ["rgb:1e/1e", "rgb:gg/00/00", "rgb:12345/1/1", "", "rgba:1e/1e/1e/1"] {
            let reply = colourReply.replacingOccurrences(of: "rgb:1e1e/1e1e/1e1e", with: body)
            let caps = TermCaps.parse(reply)
            XCTAssertNil(caps.foreground, "\(body.debugDescription) is not a foreground")
            XCTAssertNil(caps.palette, "one colour is not a palette")
            XCTAssertEqual(caps.cell?.w, 17, "the size answer is still there: \(body.debugDescription)")
            XCTAssertEqual(caps.graphemeMode, 2)
            XCTAssertEqual(caps.colourSchemeMode, 1)
            XCTAssertEqual(caps.background, RGB(0x0D_11_17), "the other colour is still an answer")
        }
        // `OSC 12` is the cursor's colour. It is one number away from `OSC 11` and the same shape,
        // which is exactly why it has to be refused by *code* and not by shape.
        let cursorColour = colourReply.replacingOccurrences(of: "\u{1B}]10;", with: "\u{1B}]12;")
        let caps = TermCaps.parse(cursorColour)
        XCTAssertNil(caps.foreground, "OSC 12 is the cursor colour, not the foreground")
        XCTAssertEqual(caps.background, RGB(0x0D_11_17))
        XCTAssertNil(caps.palette)
        XCTAssertTrue(caps.terminated, "an unknown `OSC` still hides nothing and ends nothing")
    }

    /// `DECRQM ?2031` decides whether a session may turn the mode on. Only "recognised, and not
    /// permanently reset" is permission: `0` is "never heard of it", `4` is a terminal saying
    /// "never", and silence is neither permission nor a verdict — it is `nil`, which reading it as
    /// `0` would have thrown away.
    func testEveryColourSchemeVerdictAndWhatItPermits() {
        for (ps, permitted) in [(1, true), (2, true), (3, true), (0, false), (4, false)] {
            let caps = TermCaps.parse("\u{1B}[?2031;\(ps)$y\u{1B}[?62c")
            XCTAssertEqual(caps.colourSchemeMode, ps, "DECRQM Ps \(ps)")
            XCTAssertEqual(caps.supportsColourSchemeFollow, permitted, "DECRQM Ps \(ps)")
        }
        XCTAssertNil(TermCaps.decrqmVerdict("\u{1B}[?62;22c", mode: 2031), "the DA1 is not an answer")
        XCTAssertNil(TermCaps.decrqmVerdict("\u{1B}[?2031;1$y", mode: 2027),
                     "one mode's report is not the other's")
        XCTAssertNil(TermCaps.decrqmVerdict("\u{1B}[?2031;5$y", mode: 2031), "5 is not a DECRQM value")
    }

    /// Both reports in one buffer, each still its own verdict. This is the reply a terminal that
    /// understands both modes sends, i.e. the common one after #213 — and the one where a shared
    /// reader could most easily read 2031's number as 2027's.
    func testTheTwoDECRQMReportsDoNotReadEachOthersNumbers() {
        let caps = TermCaps.parse("\u{1B}[?2031;1$y\u{1B}[?2027;2$y\u{1B}[?62;22c")
        XCTAssertEqual(caps.graphemeMode, 2)
        XCTAssertEqual(caps.colourSchemeMode, 1)
        // The same pair in the other order, and a truncated neighbour in between.
        let mixed = TermCaps.parse("\u{1B}[?2027;2$\u{1B}[?2031;1$y\u{1B}[?62;22c")
        XCTAssertNil(mixed.graphemeMode, "a `$` without its `y` is not a verdict")
        XCTAssertEqual(mixed.colourSchemeMode, 1, "…and it must not swallow 2031's")
    }

    /// The batch on the wire, as seven questions in one string with the `DA1` still last and still
    /// the terminator. Presence *and* order: `OSC 10;?` must be asked, and a terminal that ignores it
    /// must not cost a second round trip.
    func testTheBatchCarriesSevenQuestionsAndEndsOnTheDA1() {
        let questions = ["\u{1B}[16t", "\u{1B}[14t", "\u{1B}[?2027$p", "\u{1B}[?2031$p",
                         "\u{1B}]10;?\u{1B}\\", "\u{1B}]11;?\u{1B}\\", "\u{1B}[c"]
        for question in questions {
            XCTAssertTrue(TermCaps.query.contains(question),
                          "the batch does not ask \(question.debugDescription): \(TermCaps.query.debugDescription)")
        }
        XCTAssertEqual(TermCaps.query, questions.joined(), "one write, in this order")
        XCTAssertTrue(TermCaps.query.hasSuffix("\u{1B}[c"), "and the DA1 is the last of them")
        // A terminal that answers nothing but the `DA1` still ends the read: the colour questions
        // cost it no timeout, which is the whole reason they share this one write.
        XCTAssertTrue(TermCaps.isComplete("\u{1B}[?62;22c"))
        XCTAssertNil(TermCaps.parse("\u{1B}[?62;22c").palette,
                     "a terminal that never answered the colours stays on the hard-coded table")
    }
}
