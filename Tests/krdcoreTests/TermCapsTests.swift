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
/// Four questions leave in one write and one answer comes back; the parse has to find three different
/// kinds of answer in it and has to *not* invent the ones that are missing. That last half is the part
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

    /// The batch is one string *and* four questions in it: a shorter `query` would silently stop asking
    /// a question krd still needs, and the compiler would not say so.
    func testTheBatchIsFourQuestionsInOneString() {
        XCTAssertEqual(TermCaps.query, "\u{1B}[16t\u{1B}[14t\u{1B}[?2027$p\u{1B}[c")
        XCTAssertTrue(TermCaps.query.hasSuffix("\u{1B}[c"), "the DA1 has to be the last question")
        XCTAssertEqual(TermCaps.query.components(separatedBy: "\u{1B}[").count - 1, 4,
                       "four introductions, i.e. four questions")
        // The terminator is the `DA1`, so a `DA1`-only reply completes the batch: that is what keeps a
        // terminal that knows none of the other three from waiting out the timeout.
        XCTAssertTrue(TermCaps.isComplete("\u{1B}[?62;22c"))
        XCTAssertFalse(TermCaps.isComplete("\u{1B}[?2027;2$y"), "three answers are not the terminator")
        XCTAssertFalse(TermCaps.isComplete(""), "an empty read is not complete")
    }
}
