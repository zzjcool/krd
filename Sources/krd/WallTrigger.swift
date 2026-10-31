import Foundation

/// What asked the wall to look at the world again — and the one thing that must *not* (issue #141).
///
/// The wall used to decide "did anything change?" by enumerating: `refreshWall` was the 1 s tick's
/// handler, it called `WallSource.model()` (`CGWindowListCopyWindowInfo` + `NSWorkspace.runningApplications`)
/// and then compared the answer against the previous one. The comparison is what costs 1.24 ms
/// median / 1.52 ms p95 per idle second (`bench/wall-tick/tick_cost.swift`), and finding out that
/// nothing changed is exactly the case where it buys nothing.
///
/// So the enumeration moved off the timer and onto the triggers that can actually move the list.
/// The rule is a pure function here for the same reason `WallSource.ordered` is one: which of these
/// asks the window server is a decision, not a translation, and it decides whether an idle wall
/// sleeps or burns.
enum WallTrigger: Equatable {
    /// The 1 s timer. It owns the pty grid (an ioctl, no query) and nothing else: a wall whose
    /// world did not move has no reason to ask the window server.
    case tick
    /// Something the system said moved the window list: an app launched, quit, activated, hidden or
    /// unhidden, the active space changed, or the display configuration changed.
    case world
    /// A refresh the wall asked of itself: the first paint, a return from a mirror, a resize.
    case explicit

    /// Does this trigger ask the window server? `.tick` must stay `false` — that is the fix.
    var enumerates: Bool { self != .tick }
}

/// The tick's decision, before anything is touched.
enum WallTick: Equatable {
    /// No repaint and no enumeration — an idle second, which is what the wall spends most of its
    /// life in.
    case idle
    /// The pty reported a grid no `SIGWINCH` did (an ssh client resizing its own pty): re-lay out
    /// against the **cached** model. The window list cannot have changed because of a grid, so this
    /// repaints without enumerating.
    case relayout(cols: Int, rows: Int)
}

/// The pure half of `refreshWall`'s bookkeeping: what a trigger does, and when a fresh model is
/// worth painting.
enum WallRefresh {
    /// What the 1 s tick does, given the pane the wall last drew for and the grid the pty reports
    /// now. Pure so the answer is testable without a terminal: a tick whose grid is unchanged is
    /// `.idle`, i.e. zero window server calls per idle second.
    ///
    /// `pinned` is `--pane`: a pinned grid is the reader's request, so the pty cannot move it.
    static func tick(drawn: PaneGeometry, pty: PaneGeometry, pinned: Bool) -> WallTick {
        guard !pinned, pty.cols != drawn.cols || pty.rows != drawn.rows else { return .idle }
        return .relayout(cols: max(1, pty.cols), rows: max(1, pty.rows))
    }

    /// Does a trigger that already holds its model repaint?
    ///
    /// The enumeration is only half of the cost: a repaint re-captures every panel, so a
    /// notification that fired without moving the list must not paint either. `force` is the
    /// caller saying "paint anyway" (a resize cleared the terminal, a paint had to be redone).
    static func needsRepaint(current: WallModel, drawn: WallModel,
                             pane: PaneGeometry, drawnPane: PaneGeometry?,
                             force: Bool) -> Bool {
        force || current != drawn || drawnPane == nil || pane != drawnPane
    }
}
