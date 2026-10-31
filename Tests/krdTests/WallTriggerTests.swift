import XCTest
@testable import krd

/// The trigger rule of issue #141: an idle wall must not ask the window server anything.
///
/// The numbers here are the bug and the fix in one place — the enumeration moved off the 1 s timer
/// onto the notifications that can actually move the list (`WallWatch`), so "nothing happened"
/// costs an ioctl instead of a `CGWindowListCopyWindowInfo` round-trip.
final class WallTriggerTests: XCTestCase {
    private let pane = PaneGeometry(cols: 118, rows: 73, cellW: 17, cellH: 33, dpr: 2, source: "pty")

    func testTheTimerNeverAsksTheWindowServer() {
        // The fix, as one assertion: `.tick` is the 1 s timer, and it does not enumerate.
        XCTAssertFalse(WallTrigger.tick.enumerates)
        // The two triggers that do, and must keep doing it: the wall asking itself (the first
        // paint, a resize, a return from a mirror) and the system reporting a change.
        XCTAssertTrue(WallTrigger.explicit.enumerates)
        XCTAssertTrue(WallTrigger.world.enumerates)
    }

    func testAnIdleSecondDoesNothing() {
        // Unchanged grid, unchanged world, no request: no repaint and no enumeration. This is the
        // case that used to cost 1.24 ms median / 1.52 ms p95, once a second, forever.
        XCTAssertEqual(WallRefresh.tick(drawn: pane, pty: pane, pinned: false), .idle)
    }

    func testAGridThePtyMovedWithoutASignalRelayoutsWithoutAskingTheWorld() {
        // An ssh client resizing its own pty sends no SIGWINCH. The grid moves the layout (and the
        // band's capacity), but a grid cannot change the window list, so the answer is a relayout
        // against the cached model — never an enumeration.
        XCTAssertEqual(WallRefresh.tick(drawn: pane, pty: pane.with(cols: 120, rows: 74), pinned: false),
                       .relayout(cols: 120, rows: 74))
        // One axis is enough.
        XCTAssertEqual(WallRefresh.tick(drawn: pane, pty: pane.with(cols: 118, rows: 40), pinned: false),
                       .relayout(cols: 118, rows: 40))
    }

    func testAPinnedGridIgnoresThePty() {
        // `--pane` is the reader's request: the pty may not move it, and a tick that cannot move the
        // pane has nothing to do at all.
        XCTAssertEqual(WallRefresh.tick(drawn: pane, pty: pane.with(cols: 120, rows: 74), pinned: true),
                       .idle)
    }

    func testAnUnchangedWindowSetWithNoRequestRepaintsNothing() {
        let model = WallSource.demoModel()
        XCTAssertFalse(WallRefresh.needsRepaint(current: model, drawn: model, pane: pane,
                                                drawnPane: pane, force: false))
        // Forced is the caller saying "paint anyway" (a resize cleared the terminal).
        XCTAssertTrue(WallRefresh.needsRepaint(current: model, drawn: model, pane: pane,
                                               drawnPane: pane, force: true))
    }

    func testAChangedWindowListOrPaneRepaints() {
        let model = WallSource.demoModel()
        var fewer = model
        fewer.windows.removeLast()
        XCTAssertTrue(WallRefresh.needsRepaint(current: fewer, drawn: model, pane: pane,
                                               drawnPane: pane, force: false))
        // Order alone is a change: the shelf is "most recently used first", so a reordering is a
        // different wall even with the same membership.
        var reordered = model
        reordered.windows.reverse()
        XCTAssertTrue(WallRefresh.needsRepaint(current: reordered, drawn: model, pane: pane,
                                               drawnPane: pane, force: false))
        // A pane the wall has never drawn for has to be drawn, even when the world stands still.
        XCTAssertTrue(WallRefresh.needsRepaint(current: model, drawn: model, pane: pane,
                                               drawnPane: nil, force: false))
        XCTAssertTrue(WallRefresh.needsRepaint(current: model, drawn: model,
                                               pane: pane.with(cols: 100, rows: 73),
                                               drawnPane: pane, force: false))
    }

    // MARK: - the gate that bounds staleness (issue #169)

    /// Three windows on one display, `Terminal` (pid 501) in front. The ids are the sum of the
    /// window numbers (5107 + 5112 + 5119), which is exactly what `WallSource.fingerprint()` reads.
    private let world = WallFingerprint(windows: 3, ids: 15338, frontmost: 501, displays: [1])
    /// The same app, one window fewer: the case no notification announces.
    private let moved = WallFingerprint(windows: 2, ids: 10219, frontmost: 501, displays: [1])
    /// The same windows in a different order, i.e. a pure focus change.
    private let refocused = WallFingerprint(windows: 3, ids: 15338, frontmost: 502, displays: [1])
    /// The same windows, one display more.
    private let replugged = WallFingerprint(windows: 3, ids: 15338, frontmost: 501,
                                           displays: [1, 3])

    func testTheTimerNeverEnumeratesEvenWhenTheFingerprintMoved() {
        // The fix of #141, restated now that something *else* has to notice a closure: the 2 s poll
        // is the thing allowed to look, and it is the only thing. A timer that enumerated would put
        // the 1.24 ms/s back the moment the world moved once.
        XCTAssertFalse(WallTrigger.tick.enumerates)
        XCTAssertFalse(WallRefresh.shouldEnumerate(.tick, now: moved, drawn: world))
        XCTAssertFalse(WallRefresh.shouldEnumerate(.tick, now: replugged, drawn: world))
        XCTAssertFalse(WallRefresh.shouldEnumerate(.tick, now: refocused, drawn: world))
        // Even with nothing drawn yet: the first paint is `.explicit`'s job, not the timer's.
        XCTAssertFalse(WallRefresh.shouldEnumerate(.tick, now: world, drawn: nil))
    }

    func testWorldAndExplicitEnumerateEvenWhenTheFingerprintIsIdentical() {
        // `.world` must not be gated on the fingerprint: a notification can precede the window it
        // announces (a launch posts before the window exists), so "this looks unchanged" is a
        // legitimate answer that has to be reachable — the notification is the reason to re-read,
        // not the conclusion. `.explicit` is the wall asking itself (first paint, resize, a return
        // from a mirror), and it has no fingerprint to compare against by definition.
        for trigger in [WallTrigger.world, .explicit] {
            XCTAssertTrue(WallRefresh.shouldEnumerate(trigger, now: world, drawn: world))
            XCTAssertTrue(WallRefresh.shouldEnumerate(trigger, now: world, drawn: nil))
            XCTAssertTrue(WallRefresh.shouldEnumerate(trigger, now: moved, drawn: world))
            XCTAssertTrue(trigger.enumerates)
        }
        XCTAssertTrue(WallTrigger.world.enumerates)
        XCTAssertTrue(WallTrigger.explicit.enumerates)
    }

    func testPollEnumeratesOnlyWhenTheFingerprintMoved() {
        // The bound of #169: the poll is the backstop for the change AppKit does not announce (a
        // window closing inside the already-frontmost app). It earns its 2 s read only when the
        // read differs — an idle wall spends one fingerprint per poll and never enumerates.
        XCTAssertTrue(WallTrigger.poll.enumerates)
        XCTAssertFalse(WallRefresh.shouldEnumerate(.poll, now: world, drawn: world))
        XCTAssertTrue(WallRefresh.shouldEnumerate(.poll, now: moved, drawn: world))
        // Nothing drawn yet is the other half of the rule: there is nothing to compare against, so
        // the poll is a first paint rather than a no-op.
        XCTAssertTrue(WallRefresh.shouldEnumerate(.poll, now: world, drawn: nil))
        // Every field counts, not just the window set: a pure reorder and a plug/unplug are changes
        // the enumeration would have shown, so the gate has to see them too.
        XCTAssertTrue(WallRefresh.shouldEnumerate(.poll, now: refocused, drawn: world))
        XCTAssertTrue(WallRefresh.shouldEnumerate(.poll, now: replugged, drawn: world))
    }

    func testAWallClickResyncsOnlyWhenTheWorldMoved() {
        // The click path drew from the cached `wallModel` (`main.swift` `wallClick`), so a click
        // after a close hit-tested a window number that no longer existed. A click now pays a
        // fingerprint first — but only an enumeration when the fingerprint moved: "a click
        // happened" is not evidence that the world did.
        XCTAssertTrue(WallTrigger.input.enumerates)
        XCTAssertFalse(WallRefresh.shouldEnumerate(.input, now: world, drawn: world))
        XCTAssertTrue(WallRefresh.shouldEnumerate(.input, now: moved, drawn: world))
        XCTAssertTrue(WallRefresh.shouldEnumerate(.input, now: world, drawn: nil))
        // One rule for both triggers: a click and a poll that disagreed would be two costs and two
        // answers for the same question, and the click is the one that decides what a hit-test
        // means.
        for now in [world, moved, refocused, replugged] {
            XCTAssertEqual(WallRefresh.shouldEnumerate(.input, now: now, drawn: world),
                           WallRefresh.shouldEnumerate(.poll, now: now, drawn: world),
                           "input and poll must agree on \(now)")
        }
    }

    // MARK: - the probes behind the first paint (issue #99)

    /// The four answers a late probe can give, and the one thing that follows from each.
    ///
    /// The wall paints before it asks (`CSI 16t` for the cell, `U=1` for the transport), so both
    /// answers arrive with a frame already on screen. A repaint is a whole frame - every panel
    /// re-captured - so "nothing moved" has to be free, and it is the case that matters: a terminal
    /// that answers neither question is every terminal krd was written for before #99.
    func testOnlyAProbeThatMovedSomethingRepaints() {
        XCTAssertFalse(WallProbeOutcome(paneMoved: false, transportMoved: false).needsRepaint,
                       "a silent terminal moves nothing (issue #99)")
        XCTAssertTrue(WallProbeOutcome(paneMoved: true, transportMoved: false).needsRepaint,
                      "the cell arrived late: the frame is at the assumed one")
        XCTAssertTrue(WallProbeOutcome(paneMoved: false, transportMoved: true).needsRepaint,
                      "`U=1` was accepted: the first frame is on the pixel path")
        XCTAssertTrue(WallProbeOutcome(paneMoved: true, transportMoved: true).needsRepaint,
                      "both arrived late, which is one repaint and not two")
    }

    func testTheStalenessBoundIsTwoSeconds() {
        // The number IS the bound: a window that closes inside the already-frontmost app posts no
        // `NSWorkspace` notification, so nothing announces it and its card stays on the wall until
        // the next poll notices the fingerprint moved. 2.0 s is therefore the worst-case staleness
        // the design promises — not a polling rate chosen for feel.
        XCTAssertEqual(WallSource.pollInterval, 2.0)
        // And the promise is a ceiling, not a target: a future edit that "just polls a bit more"
        // would quietly turn the bound into something the design never claimed.
        XCTAssertLessThanOrEqual(WallSource.pollInterval, 5.0)
        XCTAssertGreaterThan(WallSource.pollInterval, 0)
    }
}
