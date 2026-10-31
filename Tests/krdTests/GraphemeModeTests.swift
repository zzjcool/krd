import XCTest
@testable import krd
@testable import krdcore

/// `DECRQM 2027` — who decides where a grapheme cluster ends.
///
/// The two terminals krd is tested against disagree, permanently: Ghostty 1.4.0 starts with 2027
/// **set** and Rex starts with it **reset**. With it reset every code point is laid out on its own,
/// so a flag is two letters and `☰` can land in a different cell than the one `TextWidth` predicted.
/// A session therefore asks once (`TermGeometry.query2027`) and, if the answer is `2`, turns the
/// mode on for its own duration and gives it back on the way out.
///
/// What is pinned here is the part that has a wrong answer available: the parse. A terminal that
/// does not implement 2027 does not answer "no" — it says nothing at all, so the only thing that
/// ends the probe is the `DA1` sentinel sent in the same write. A parse that read a `$y` from some
/// other report, or that turned "no answer" into `0`, would send every session down the wrong path
/// silently.
final class GraphemeModeTests: XCTestCase {

    // MARK: - what the terminal said

    func testASetModeIsOne() {
        // Ghostty's answer: `CSI ? 2027 ; 1 $ y` then DA1.
        XCTAssertEqual(TermGeometry.graphemeModeVerdict("\u{1B}[?2027;1$y\u{1B}[?62;22;52c"), 1)
    }

    func testAResetModeIsTwo() {
        // Rex's answer: recognised, not set. This is the one that makes the session turn it on.
        XCTAssertEqual(TermGeometry.graphemeModeVerdict("\u{1B}[?2027;2$y\u{1B}[?62;22c"), 2)
    }

    func testNotRecognisedIsZero() {
        XCTAssertEqual(TermGeometry.graphemeModeVerdict("\u{1B}[?2027;0$y\u{1B}[?62c"), 0)
        // 3 and 4 are DECRQM's "permanently set"/"permanently reset"; neither is 2, so neither is a
        // reason to enable anything, but both are real answers and have to parse.
        XCTAssertEqual(TermGeometry.graphemeModeVerdict("\u{1B}[?2027;3$y\u{1B}[?62c"), 3)
        XCTAssertEqual(TermGeometry.graphemeModeVerdict("\u{1B}[?2027;4$y\u{1B}[?62c"), 4)
    }

    func testDA1AloneMeansTheTerminalSaidNothing() {
        // The whole point of the sentinel: a terminal with no 2027 answers only this, and "nothing"
        // must not read as `0` — a `0` is a terminal *telling* us it has no such mode, which is a
        // different fact and would also mean `.leave`, but only one of them is a measurement.
        XCTAssertNil(TermGeometry.graphemeModeVerdict("\u{1B}[?62;22;52c"))
        XCTAssertNil(TermGeometry.graphemeModeVerdict(""))
        XCTAssertNil(TermGeometry.graphemeModeVerdict(nil))
    }

    func testGarbageIsNotAnAnswer() {
        // A `$y` without DECRQM's shape, an out-of-range number, and a reply that never terminates.
        XCTAssertNil(TermGeometry.graphemeModeVerdict("\u{1B}[?2027;1$"), "no terminator")
        XCTAssertNil(TermGeometry.graphemeModeVerdict("\u{1B}[?2027;$y\u{1B}[?62c"), "no number")
        XCTAssertNil(TermGeometry.graphemeModeVerdict("\u{1B}[?2027;9$y\u{1B}[?62c"), "not a DECRQM Ps")
        XCTAssertNil(TermGeometry.graphemeModeVerdict("\u{1B}[?2027;1m\u{1B}[?62c"), "wrong final byte")
        // Some other private report that happens to start the same way must not be read as 2027.
        XCTAssertNil(TermGeometry.graphemeModeVerdict("\u{1B}[?2028;2$y\u{1B}[?62c"))
    }

    func testTheAnswerMayArriveInPieces() {
        // `ask` concatenates whatever the pty hands over, and a split can land anywhere — including
        // between `2027;` and its number. The parse only ever sees the joined string.
        let pieces = ["\u{1B}[?2027", ";2$y", "\u{1B}[?62;22c"]
        XCTAssertEqual(TermGeometry.graphemeModeVerdict(pieces.joined()), 2)
    }

    // MARK: - the sentinel

    func testTheSentinelIsADA1AndNotAnyOtherCSI() {
        XCTAssertTrue(TermGeometry.containsPrimaryAttributes("\u{1B}[?62;22;52c"))
        XCTAssertTrue(TermGeometry.containsPrimaryAttributes("\u{1B}[?2027;2$y\u{1B}[?62;22c"))
        // A mode report, a cursor position report and a colour report are not DA1.
        XCTAssertFalse(TermGeometry.containsPrimaryAttributes("\u{1B}[?2027;2$y"))
        XCTAssertFalse(TermGeometry.containsPrimaryAttributes("\u{1B}[6;33;17t"))
        XCTAssertFalse(TermGeometry.containsPrimaryAttributes("\u{1B}]11;rgb:ffff/ffff/ffff\u{1B}\\"))
        XCTAssertFalse(TermGeometry.containsPrimaryAttributes(""))
        // `c` with nothing before it is not a DA1 either, and neither is a bare `?c`.
        XCTAssertFalse(TermGeometry.containsPrimaryAttributes("\u{1B}[c"))
        XCTAssertFalse(TermGeometry.containsPrimaryAttributes("\u{1B}[?c"))
    }
}
