import XCTest
@testable import krdcore

/// The one terminal mode krd asks for and can never ask *about*: the pointer shape (OSC 22, #202).
///
/// `ESC ] 22 ; <name> ST` is how a program names the shape the outer terminal draws for its mouse.
/// It is not a DEC private mode, so there is no `DECRQM` for it — the arming here is krd's own book
/// ("did *we* put a hand on that pane?"), never a probe, and the reset costs nothing for every
/// session that never asked (the golden dump and `--selftest`'s sha256 are byte contracts).
///
/// Three properties live in this file, all measured rather than stylistic:
///
/// 1. **The reset is conditional on our own book.** A session that painted no pointer shape writes
///    nothing at teardown; a session that did writes `default` exactly once, before `?1049l` — the
///    shell's first frame must not be drawn with a hand pointer, the same "leave it as we found it"
///    rule as `?2027` (`GraphemeSessionTests`), except this one has no way to ask what was there
///    before.
/// 2. **The shape rides the frame's write.** krd went to some trouble to make a hover one `write(2)`
///    (#197): the sequence is prepended to the text the wall was already sending, not written as a
///    second chunk.
/// 3. **A mouse-mode toggle forgets it.** Measured in the recon: that is one of the things both
///    terminals reset the shape with, so anything remembering "the pane is holding a hand" has to
///    forget or the next hover inside the same item emits nothing and the hand never comes back.
final class PointerShapeTests: XCTestCase {

    private func session(_ body: (ScreenWriter) -> Void) -> (chunks: [[UInt8]], text: String) {
        let writer = ScreenWriter()
        var chunks: [[UInt8]] = []
        writer.sink = { chunks.append($0) }
        body(writer)
        return (chunks, String(decoding: chunks.flatMap { $0 }, as: UTF8.self))
    }

    private func shapes(in text: String) -> [String] {
        var out: [String] = []
        let open = "\u{1B}]22;"
        var rest = Substring(text)
        while let r = rest.range(of: open) {
            rest = rest[r.upperBound...]
            guard let st = rest.range(of: "\u{1B}\\") else { break }
            out.append(String(rest[..<st.lowerBound]))
            rest = rest[st.upperBound...]
        }
        return out
    }

    // MARK: - 1. the wire format

    /// The two shapes the wall uses, and the exact bytes each one is: ST, not BEL — both terminals
    /// krd is tested against take `ESC \` and it is what §6.6's neighbours use.
    func testTheSequenceIsTheDocumentedOne() {
        XCTAssertEqual(PointerShape.pointer.sequence, "\u{1B}]22;pointer\u{1B}\\")
        XCTAssertEqual(PointerShape.default.sequence, "\u{1B}]22;default\u{1B}\\")
        XCTAssertEqual(PointerShape.pointer.sequence.utf8.count, 14)
        XCTAssertEqual(PointerShape.default.sequence.utf8.count, 14)
    }

    /// The shape is an OSC, not a graphics APC, so tmux's passthrough envelope has nothing to carry:
    /// it travels bare and the envelope guard must not read it as a bypass (#107's `isFullyEnveloped`
    /// counts a chunk that is not a run of complete envelopes). It also must not be *wrapped*: a
    /// wrapped OSC would be a different escape for tmux, and under a multiplexer the shape simply does
    /// not change — that is the documented, supported outcome.
    func testTheShapeIsNotWrappedAndDoesNotTripTheEnvelopeGuard() {
        let bare = PointerShape.pointer.sequence + "\u{1B}[1;1Hframe"
        XCTAssertTrue(GraphicsAPC.isFullyEnveloped(Array(bare.utf8)),
                      "an OSC 22 outside any envelope is not a graphics bypass")
        XCTAssertFalse(PointerShape.default.sequence.contains("tmux;"),
                       "the shape is never enveloped: under tmux it is dropped, by design")
    }

    // MARK: - 2. it rides the frame's write

    func testTheShapeRidesTheFrameWrite() {
        let (chunks, text) = session { writer in
            writer.pointerShape = .pointer
            writer.writeChrome(Array("frame".utf8))
        }
        XCTAssertEqual(chunks.count, 1, "one write for the shape and the frame together")
        XCTAssertEqual(String(decoding: chunks[0], as: UTF8.self),
                       PointerShape.pointer.sequence + "frame",
                       "the shape is a prefix of the frame's own bytes, not a chunk of its own")
        XCTAssertEqual(shapes(in: text), ["pointer"])
    }

    func testAnUnchangedShapeAsksForNothing() {
        let (_, text) = session { writer in
            writer.pointerShape = .pointer
            writer.writeChrome(Array("one".utf8))
            writer.writeChrome(Array("two".utf8))
        }
        XCTAssertEqual(shapes(in: text), ["pointer"], "the second paint must not repeat the shape")
    }

    func testAClassChangeIsAskedForInTheNextWrite() {
        let (chunks, text) = session { writer in
            writer.pointerShape = .pointer
            writer.writeChrome(Array("card".utf8))
            writer.pointerShape = .default
            writer.writeChrome(Array("bar".utf8))
        }
        XCTAssertEqual(shapes(in: text), ["pointer", "default"])
        XCTAssertEqual(chunks.count, 2)
    }

    /// A class change that happens to paint no cells still has to reach the terminal: the frame's
    /// text is empty, so the shape is the whole write.
    func testAnEmptyFrameStillCarriesTheShape() {
        let (chunks, text) = session { writer in
            writer.pointerShape = .pointer
            writer.writeChrome([])
        }
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(String(decoding: chunks[0], as: UTF8.self), PointerShape.pointer.sequence)
        XCTAssertEqual(shapes(in: text), ["pointer"])
    }

    // MARK: - 3. the ways out

    func testTheTeardownGivesTheShapeBack() {
        let (_, text) = session { writer in
            writer.beginSession()
            writer.pointerShape = .pointer
            writer.writeChrome(Array("wall".utf8))
            writer.endSession()
        }
        XCTAssertEqual(shapes(in: text), ["pointer", "default"],
                       "endSession must reset the shape: \(text.debugDescription)")
        let off = try! XCTUnwrap(text.range(of: "\u{1B}]22;default"))
        let alt = try! XCTUnwrap(text.range(of: "\u{1B}[?1049l"))
        XCTAssertLessThan(off.lowerBound, alt.lowerBound,
                          "before the alternate screen goes: the shell behind us must not inherit a hand")
    }

    /// The byte contract every recorded stream depends on: a session that never asked for a shape
    /// says nothing about it — no probe, no reset, no 14 bytes.
    func testASessionThatNeverAskedForAShapeWritesNothing() {
        let (_, text) = session { writer in
            writer.beginSession()
            writer.writeChrome(Array("mirror".utf8))
            writer.endSession()
        }
        XCTAssertFalse(text.contains("]22;"), "no shape, no bytes: \(text.debugDescription)")
    }

    /// `handOver` `exec`s the mirror and never calls `endSession`, so the shape is handed back on its
    /// own — exactly once, even when a teardown follows anyway (`GraphemeSessionTests`' rule).
    ///
    /// `restoreSessionModes()` is what both paths call (the teardown and the hand-over), and that is
    /// the point: a mode given back by one and forgotten by the other is a mode the `exec`ed mirror
    /// inherits. The two lists had already drifted once for 2027 (#193).
    func testRestoringIsIdempotentAndWorksWithoutATeardown() {
        let (_, text) = session { writer in
            writer.beginSession()
            writer.pointerShape = .pointer
            writer.writeChrome(Array("clicked card".utf8))
            writer.restoreSessionModes()        // the `handOver` path
            writer.restoreSessionModes()        // a second caller writes nothing
            writer.endSession()                 // and the teardown must not write a second reset
        }
        XCTAssertEqual(shapes(in: text), ["pointer", "default"],
                       "exactly one reset across restore + teardown: \(shapes(in: text))")
    }

    func testARestoreWithNothingArmedWritesNothing() {
        let (chunks, _) = session { writer in
            writer.beginSession()
            writer.restorePointerShape()        // the pane never held a shape of ours
        }
        XCTAssertTrue(chunks.allSatisfy { !$0.contains(0x5D) }, "nothing to give back, so nothing goes out")
    }

    // MARK: - 4. the toggles that reset it

    /// `beginSession` forgets, because its heal resets the mouse modes unconditionally — and the
    /// toggles are what reset the shape. Without this line the book would survive into a pane that no
    /// longer holds what it says, and the first hover of the new session would sit inside the same
    /// class and emit nothing.
    func testTheHealAtSessionStartForgetsTheShape() {
        let (_, text) = session { writer in
            writer.pointerShape = .pointer
            writer.writeChrome(Array("first session".utf8))   // the hand goes out
            writer.beginSession()                             // its heal resets the mouse modes
            writer.writeChrome(Array("second session".utf8))  // the wish survives the session
            writer.endSession()
        }
        XCTAssertEqual(shapes(in: text), ["pointer", "pointer", "default"],
                       "one ask per session, and one reset at the end: \(shapes(in: text))")
    }

    /// The recon's measured fact: enabling or disabling the mouse modes resets the shape. The next
    /// session of the same writer therefore has to ask again rather than believe its own book.
    func testASecondSessionAsksForTheShapeAgain() {
        let (_, text) = session { writer in
            writer.beginSession()
            writer.pointerShape = .pointer
            writer.writeChrome(Array("wall".utf8))
            writer.endSession()
            writer.beginSession()               // `resumeWall()` after a failed `exec`
            writer.pointerShape = .pointer
            writer.writeChrome(Array("wall".utf8))
            writer.endSession()
        }
        XCTAssertEqual(shapes(in: text), ["pointer", "default", "pointer", "default"],
                       "one ask and one reset per session: \(shapes(in: text))")
    }

    /// `Desk.startInput()` enables the mouse modes *after* the wall's first paint, so the shape the
    /// paint may have just asked for is gone. Forgetting keeps the book honest; the wish stays, so
    /// the very next paint re-asks.
    func testForgettingKeepsTheWishAndReAsks() {
        let (_, text) = session { writer in
            writer.pointerShape = .pointer
            writer.writeChrome(Array("wall".utf8))
            writer.forgetPointerShape()
            writer.writeChrome([])              // the next paint, of the same frame
        }
        XCTAssertEqual(shapes(in: text), ["pointer", "pointer"],
                       "the terminal forgot, so the wish has to be said again: \(shapes(in: text))")
    }
}
