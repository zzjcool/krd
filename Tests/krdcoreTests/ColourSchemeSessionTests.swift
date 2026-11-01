import XCTest
@testable import krdcore

/// DEC mode 2031 — the one mode a session turns on because the *user* may switch the terminal's theme
/// halfway through it (issue #213), and the two ways out of a session.
///
/// `TermCapsTests` covers what the terminal said about the mode; this covers what the writer does with
/// the answer. The rule is the same shape as `GraphemeSessionTests`' and for the same measured reasons:
/// enable it in `beginSession` only when the desk asked (`followsColourScheme`), and disable it only if
/// this session was the one that set it. There is no `DECRQM` answer that can stand in for "was it
/// ours" — `DECRQM ?2031` says whether the terminal *knows* the mode, not whether it was on before krd
/// started — so the book is the session's own flag, and it is the whole safety property:
///
///  * a terminal that had the mode on for its own reasons must keep it on after krd leaves (an
///    unconditional `?2031l` at teardown would take something that was never ours);
///  * a session that never asked must write **nothing** (the default `false` is what keeps the wall
///    fixtures and `--selftest`'s sha256 byte-identical);
///  * a session can end without `endSession` — `Desk.handOver` `exec`s the mirror into this same
///    process image and leaves the alternate screen entered — so the reset has to live in
///    `restoreSessionModes()`, which is what *both* paths call (#134's bug class).
final class ColourSchemeSessionTests: XCTestCase {

    /// Everything the writer put on the wire, in order.
    private func session(_ body: (ScreenWriter) -> Void) -> String {
        let writer = ScreenWriter()
        var bytes: [UInt8] = []
        writer.sink = { bytes.append(contentsOf: $0) }
        body(writer)
        return String(decoding: bytes, as: UTF8.self)
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testTheModeGoesOnInTheSameWriteAsTheAlternateScreen() {
        let text = session { writer in
            writer.followsColourScheme = true
            writer.beginSession()
        }
        let alt = try! XCTUnwrap(text.range(of: "\u{1B}[?1049h"))
        let on = try! XCTUnwrap(text.range(of: "\u{1B}[?2031h"), "the session never turned it on")
        XCTAssertLessThan(alt.lowerBound, on.lowerBound, "after the alternate screen, not before")
        // One write means one `write(2)` — so the enable is inside the same string as the screen it
        // is drawn on, and the terminal is already in the mode when the first cell arrives. Nothing
        // else may turn it on: the heal prefix is the *killed-predecessor* repair list, and 2031 is
        // not a mode krd can assume it owns.
        XCTAssertEqual(occurrences(of: "\u{1B}[?2031h", in: text), 1)
        XCTAssertEqual(occurrences(of: "\u{1B}[?2031l", in: text), 0,
                       "a session that turns it on does not turn it off")
    }

    /// The default, and the reason every recorded byte stream — the wall fixtures, the selftest dump
    /// and its sha256 — is still byte-identical: `followsColourScheme` starts `false`, which is not
    /// "send it twice and hope".
    func testTheDefaultEmitsNothingAboutTheMode() {
        let text = session { writer in
            writer.beginSession()
            writer.endSession()
        }
        XCTAssertFalse(text.contains("2031"),
                       "the default must not mention the mode: \(text.debugDescription)")
    }

    /// The teardown gives it back *before* the alternate screen goes: the shell behind us must not
    /// inherit a pane that is following a scheme it never asked about, and its first frame must not be
    /// drawn in a mode krd left on.
    func testTheTeardownGivesTheModeBackBeforeLeavingTheAlternateScreen() {
        let text = session { writer in
            writer.followsColourScheme = true
            writer.beginSession()
            writer.endSession()
        }
        let off = try! XCTUnwrap(text.range(of: "\u{1B}[?2031l"), "the teardown has to reset it")
        let alt = try! XCTUnwrap(text.range(of: "\u{1B}[?1049l"))
        XCTAssertLessThan(off.lowerBound, alt.lowerBound, "reset first, then the alternate screen")
        XCTAssertEqual(occurrences(of: "\u{1B}[?2031l", in: text), 1)
    }

    /// `handOver` `exec`s the mirror into this process image and never calls `endSession`, so the mode
    /// has to be handed back on its own — exactly once, even when a teardown follows the failed
    /// `exec` anyway. That is the #134 class: a sticky mode with only one of the two exits covered.
    func testRestoringSessionModesIsIdempotentAndWorksWithoutATeardown() {
        let text = session { writer in
            writer.followsColourScheme = true
            writer.beginSession()
            writer.restoreSessionModes()      // the `handOver` path
            writer.restoreSessionModes()      // a second caller writes nothing
            writer.endSession()               // and the teardown must not write a second reset
        }
        XCTAssertEqual(occurrences(of: "\u{1B}[?2031l", in: text), 1,
                       "exactly one reset across restore + teardown, got \(text.debugDescription)")
    }

    /// A restore with nothing armed writes nothing — the same rule the default session above relies
    /// on, checked on the function itself rather than through `beginSession`.
    func testARestoreWithNothingArmedWritesNothing() {
        let writer = ScreenWriter()
        var bytes: [UInt8] = []
        writer.sink = { bytes.append(contentsOf: $0) }
        writer.followsColourScheme = true
        writer.restoreColourSchemeMode()      // before any beginSession: nothing is armed yet
        XCTAssertTrue(bytes.isEmpty, "nothing to give back, so nothing goes out")
    }

    /// After a failed `exec` the wall comes back with `beginSession()` again, and the mode has to go on
    /// again: the flag belongs to the session, so `beginSession` re-arms it.
    func testASecondSessionTurnsItOnAgain() {
        let text = session { writer in
            writer.followsColourScheme = true
            writer.beginSession()
            writer.restoreColourSchemeMode()  // `exec` failed, `resumeWall()` is about to run
            writer.beginSession()
            writer.endSession()
        }
        XCTAssertEqual(occurrences(of: "\u{1B}[?2031h", in: text), 2, "once per session")
        XCTAssertEqual(occurrences(of: "\u{1B}[?2031l", in: text), 2,
                       "one reset per session that turned it on, including the one `restore` gave back")
    }

    /// Both layout modes at once — the desk's real shape — each enabled exactly once, in the one write
    /// that enters the alternate screen, and each given back exactly once. 2027 stays first: it is the
    /// mode the *cells* are laid out by, so it has to be settled before 2031, which only decides what
    /// colours those cells are drawn in.
    func testBothLayoutModesGoOnAndOffOnceEach() {
        let text = session { writer in
            writer.graphemeClustering = .enableAndReset
            writer.followsColourScheme = true
            writer.beginSession()
            writer.endSession()
        }
        for (mode, enable, reset) in [(2027, "\u{1B}[?2027h", "\u{1B}[?2027l"),
                                      (2031, "\u{1B}[?2031h", "\u{1B}[?2031l")] {
            XCTAssertEqual(occurrences(of: enable, in: text), 1, "`\(mode)` enabled once")
            XCTAssertEqual(occurrences(of: reset, in: text), 1, "`\(mode)` reset once")
            // Both resets are in the teardown's one write, before the alternate screen is left.
            let resetAt = try! XCTUnwrap(text.range(of: reset))
            let alt = try! XCTUnwrap(text.range(of: "\u{1B}[?1049l"))
            XCTAssertLessThan(resetAt.lowerBound, alt.lowerBound, "`\(mode)` gave back before ?1049l")
        }
        let grapheme = try! XCTUnwrap(text.range(of: "\u{1B}[?2027h"))
        let scheme = try! XCTUnwrap(text.range(of: "\u{1B}[?2031h"))
        XCTAssertLessThan(grapheme.lowerBound, scheme.lowerBound,
                          "clustering first, then the colours it is drawn in")
    }
}
