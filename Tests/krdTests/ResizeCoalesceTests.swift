import XCTest
@testable import krd

/// A burst of `SIGWINCH`es must cost one re-layout, not one per event (issue #89).
///
/// Every number in this file is in the issue's own unit: `handleResize` runs — each of which is a
/// `clear` of every placement, a re-layout and a capture restart on the shipped code. A clock is
/// enough to count them, which is the point of `ResizeCoalescer` being a value: the "40 events are
/// 40 relayouts" half of the bug and the "40 events are one relayout" half of the fix are both
/// reproduced without a terminal, a pty or a capture stream.
final class ResizeCoalesceTests: XCTestCase {

    /// One `DispatchSource` and one `asyncAfter` per arrival, with the deadline arithmetic done by
    /// the real `ResizeCoalescer`. A work item whose deadline passed before the next event runs
    /// *first* — that ordering is the whole difference between the fix and the bug.
    private final class Clock {
        var coalescer: ResizeCoalescer
        var queue: [(at: TimeInterval, token: Int)] = []
        private(set) var relayouts: [(at: TimeInterval, events: Int)] = []

        init(deadline: TimeInterval) { coalescer = ResizeCoalescer(deadline: deadline) }

        /// One `SIGWINCH` at `t`.
        func arrive(at t: TimeInterval) {
            run(upTo: t)
            let arrival = coalescer.arrive(at: t)
            queue.append((arrival.fireAt, arrival.token))
        }

        /// Let the main queue go idle.
        func settle(upTo end: TimeInterval = .infinity) { run(upTo: end) }

        private func run(upTo t: TimeInterval) {
            while let next = queue.min(by: { $0.at < $1.at }), next.at <= t {
                queue.removeAll { $0.token == next.token }
                if let collapsed = coalescer.fire(token: next.token, at: next.at) {
                    relayouts.append((next.at, collapsed))
                }
            }
        }
    }

    /// The drag from the issue: 40 `TIOCSWINSZ` steps at ~30 Hz over 1.33 s.
    private let drag = (0..<40).map { Double($0) / 30.0 }

    // MARK: the bug, and the fix

    /// The same 40 events, once per event (the shipped `handleResize`, which delayed each event and
    /// then ran the whole handler) and once through the coalescer. Measured on the wire by
    /// `bench/loop-resize-storm.py`: 40 clears and 4,564 tile transmissions before, one of each
    /// after.
    func testAFortyEventDragIsOneRelayoutInsteadOfForty() {
        // Before: one run per event. A zero deadline is that shape — every arrival is already due.
        let before = Clock(deadline: 0)
        for t in drag { before.arrive(at: t) }
        before.settle()
        XCTAssertEqual(before.relayouts.count, drag.count, "the old path ran the handler per event")

        // After: one trailing edge for the whole burst.
        let after = Clock(deadline: ResizeCoalescer.defaultDeadline)
        for t in drag { after.arrive(at: t) }
        XCTAssertEqual(after.relayouts.count, 0, "a moving drag relayouts nothing: the picture waits")
        after.settle()
        XCTAssertEqual(after.relayouts.count, 1)
        XCTAssertEqual(after.relayouts[0].events, drag.count, "all 40 events collapsed into it")
    }

    /// The common case must not get slower: `handleResize` used to run 50 ms after an event, and it
    /// now runs one deadline after it. 0.08 s is that number with one 20 fps frame of slack.
    func testASingleResizeIsAnsweredOneDeadlineLater() {
        let clock = Clock(deadline: ResizeCoalescer.defaultDeadline)
        clock.arrive(at: 10)
        XCTAssertEqual(clock.relayouts.count, 0, "not synchronously, and not before the deadline")
        clock.settle(upTo: 10 + 0.079)
        XCTAssertEqual(clock.relayouts.count, 0)
        clock.settle()
        XCTAssertEqual(clock.relayouts.count, 1)
        XCTAssertEqual(clock.relayouts[0].events, 1)
        XCTAssertEqual(clock.relayouts[0].at, 10 + ResizeCoalescer.defaultDeadline, accuracy: 1e-9)
    }

    /// **The failure mode of coalescing**: the drag ends on a size, and that size has to be the one
    /// that gets painted. It is, structurally — the handler reads `TermGeometry` when it *runs*, and
    /// the accepted run is strictly after the last event — and this pins the argument rather than
    /// trusting it: for every intermediate size the drag passed through, the relayout that paints it
    /// would have to happen at a time when that size was still current.
    func testADragThatEndsSettlesOnTheFinalSize() {
        let clock = Clock(deadline: ResizeCoalescer.defaultDeadline)
        // The pane at time t: the last event at or before t, i.e. exactly what `TermGeometry.read()`
        // answers when the handler runs.
        let sizes = drag.indices.map { 100 + $0 }
        func pane(at t: TimeInterval) -> Int {
            let fired = drag.indices.filter { drag[$0] <= t }
            return fired.isEmpty ? sizes[0] : sizes[fired.last!]
        }
        for t in drag { clock.arrive(at: t) }
        clock.settle()
        XCTAssertEqual(clock.relayouts.count, 1)
        XCTAssertEqual(pane(at: clock.relayouts[0].at), sizes.last!,
                       "the one relayout happened on the size the drag ended on, not an earlier one")
    }

    /// A drag with a pause in it is not starved: the deadline is measured from the last event, so
    /// each quiet stretch settles on its own size. 40 events with one pause are two relayouts, not
    /// zero (waiting for the drag to end) and not 40.
    func testAPauseInADragSettlesInsteadOfWaitingForTheEnd() {
        let clock = Clock(deadline: ResizeCoalescer.defaultDeadline)
        clock.arrive(at: 0)
        clock.arrive(at: 0.03)
        clock.arrive(at: 1.0)
        clock.settle()
        XCTAssertEqual(clock.relayouts.map(\.events), [2, 1])
        XCTAssertEqual(clock.relayouts[0].at, 0.03 + ResizeCoalescer.defaultDeadline, accuracy: 1e-9)
        XCTAssertEqual(clock.relayouts[1].at, 1.0 + ResizeCoalescer.defaultDeadline, accuracy: 1e-9)
    }

    /// Coalescing must not become dropping: a superseded work item is a no-op *because* its
    /// successor is still queued, and its count carries over to it.
    func testASupersededWorkItemDoesNothingAndLosesNoEvent() {
        var coalescer = ResizeCoalescer(deadline: ResizeCoalescer.defaultDeadline)
        let first = coalescer.arrive(at: 0)
        let second = coalescer.arrive(at: 0.01)
        XCTAssertNotEqual(first.token, second.token)
        XCTAssertNil(coalescer.fire(token: first.token, at: first.fireAt), "stale: must not relayout")
        XCTAssertEqual(coalescer.pending, 2, "the event is still owed a relayout")
        XCTAssertEqual(coalescer.fire(token: second.token, at: second.fireAt), 2)
        XCTAssertEqual(coalescer.pending, 0)
        XCTAssertNil(coalescer.dueAt, "idle again, so the next resize starts a fresh burst")
    }

    // MARK: did the pane move?

    private let pane40x100 = ResizePane(cols: 100, rows: 40, cellW: 10, cellH: 20)

    /// The second half of the issue: a resize that changes nothing must not clear the screen and
    /// re-transmit every tile to draw exactly the picture that is already there.
    func testAnUnchangedPaneIsNothingToDo() {
        XCTAssertEqual(ResizePlan.decide(drawn: pane40x100, now: pane40x100), .skip)
    }

    func testEveryNumberTheGridDependsOnMovesThePlan() {
        let moved = [
            ResizePane(cols: 101, rows: 40, cellW: 10, cellH: 20),   // one column
            ResizePane(cols: 100, rows: 41, cellW: 10, cellH: 20),   // one row
            ResizePane(cols: 100, rows: 40, cellW: 11, cellH: 20),   // a font change
            ResizePane(cols: 100, rows: 40, cellW: 10, cellH: 21),
        ]
        for now in moved {
            XCTAssertEqual(ResizePlan.decide(drawn: pane40x100, now: now), .relayout, "\(now)")
        }
    }

    /// The first resize of a session has nothing to be "unchanged" against: `drawn == nil` relayouts,
    /// or a mirror that started at the wrong size would never correct itself.
    func testTheFirstResizeAlwaysRelayouts() {
        XCTAssertEqual(ResizePlan.decide(drawn: nil, now: pane40x100), .relayout)
    }
}
