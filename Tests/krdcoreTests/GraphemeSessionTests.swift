import XCTest
@testable import krdcore

/// The one mode a session turns on *because the terminal was asked*, and the two ways out of a session.
///
/// `GraphemeModeTests` covers what the terminal said; this covers what the writer does about it.
/// The rule is asymmetric on purpose: enable only when the terminal reported the mode **reset**, and
/// disable only if this session was the one that set it. The reasons are measured, not stylistic —
/// restoring a mode with nothing saved turns Ghostty's 2027 *off* (`CSI ?2027 s`/`r` round-trip, both
/// terminals), so an unconditional reset at teardown would leave a pane in a state krd never found it
/// in, and an unconditional enable would do the same in the other direction.
final class GraphemeSessionTests: XCTestCase {

    /// Everything the writer put on the wire, in order.
    private func session(_ body: (ScreenWriter) -> Void) -> String {
        let writer = ScreenWriter()
        var bytes: [UInt8] = []
        writer.sink = { bytes.append(contentsOf: $0) }
        body(writer)
        return String(decoding: bytes, as: UTF8.self)
    }

    func testEnablingPutsTheModeOnInTheSameWriteAsTheAlternateScreen() {
        let text = session { writer in
            writer.graphemeClustering = .enableAndReset
            writer.beginSession()
        }
        let alt = try! XCTUnwrap(text.range(of: "\u{1B}[?1049h"))
        let on = try! XCTUnwrap(text.range(of: "\u{1B}[?2027h"))
        XCTAssertLessThan(alt.lowerBound, on.lowerBound, "after the alternate screen, not before")
        // Nothing else may turn it on, and the heal prefix must never touch it: a pane left by a
        // killed predecessor is repaired by the heal, and 2027 is not a mode krd can assume it owns
        // (#134 named the four mouse modes; this one has an owner on each side).
        XCTAssertEqual(text.components(separatedBy: "\u{1B}[?2027h").count - 1, 1)
        XCTAssertFalse(text.contains("\u{1B}[?2027l"), "a session that turns it on does not turn it off")
    }

    func testLeaveEmitsNothingAtAll() {
        // The default, and the reason every recorded byte stream — the wall fixtures, the selftest
        // dump — is still byte-identical: `.leave` is not "send it twice and hope".
        let text = session { writer in
            writer.beginSession()
            writer.endSession()
        }
        XCTAssertFalse(text.contains("2027"), "`.leave` must not mention the mode: \(text.debugDescription)")
    }

    func testTheTeardownGivesTheModeBackBeforeLeavingTheAlternateScreen() {
        let text = session { writer in
            writer.graphemeClustering = .enableAndReset
            writer.beginSession()
            writer.endSession()
        }
        let off = try! XCTUnwrap(text.range(of: "\u{1B}[?2027l"), "the teardown has to reset it")
        let alt = try! XCTUnwrap(text.range(of: "\u{1B}[?1049l"))
        XCTAssertLessThan(off.lowerBound, alt.lowerBound,
                          "before the alternate screen goes: the shell's first frame must not be 2027-on")
        XCTAssertEqual(text.components(separatedBy: "\u{1B}[?2027l").count - 1, 1)
    }

    /// `handOver` `exec`s the mirror into this process image and never calls `endSession`, so the
    /// mode has to be handed back on its own — exactly once, even when a teardown follows anyway.
    func testRestoringIsIdempotentAndWorksWithoutATeardown() {
        let text = session { writer in
            writer.graphemeClustering = .enableAndReset
            writer.beginSession()
            writer.restoreGraphemeMode()      // the `handOver` path
            writer.restoreGraphemeMode()      // a second caller writes nothing
            writer.endSession()               // and the teardown must not write a second reset
        }
        XCTAssertEqual(text.components(separatedBy: "\u{1B}[?2027l").count - 1, 1,
                       "exactly one reset across restore + teardown, got \(text.debugDescription)")
    }

    /// After a failed `exec` the wall comes back with `beginSession()` again, and the mode has to go
    /// on again: the idempotence flag belongs to the session, so `beginSession` re-arms it.
    func testASecondSessionTurnsItOnAgain() {
        let text = session { writer in
            writer.graphemeClustering = .enableAndReset
            writer.beginSession()
            writer.restoreGraphemeMode()      // `exec` failed, `resumeWall()` is about to run
            writer.beginSession()
            writer.endSession()
        }
        XCTAssertEqual(text.components(separatedBy: "\u{1B}[?2027h").count - 1, 2, "once per session")
        XCTAssertEqual(text.components(separatedBy: "\u{1B}[?2027l").count - 1, 2,
                       "one reset per session that turned it on, including the one `restore` gave back")
    }

    func testARestoreWithNothingArmedWritesNothing() {
        let writer = ScreenWriter()
        var bytes: [UInt8] = []
        writer.sink = { bytes.append(contentsOf: $0) }
        writer.graphemeClustering = .enableAndReset
        writer.restoreGraphemeMode()      // before any beginSession: nothing is armed yet
        XCTAssertTrue(bytes.isEmpty, "nothing to give back, so nothing goes out")
    }
}
