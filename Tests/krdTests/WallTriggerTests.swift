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
}
