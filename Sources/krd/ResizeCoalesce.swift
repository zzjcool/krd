import Foundation

/// The pane as one `SIGWINCH` can move it — the only numbers a resize can change that the mirror's
/// `TileGrid` is a function of (issue #89).
///
/// The grid is `pane + crop + zoom + panel`, and a `SIGWINCH` can only move the pane: the crop comes
/// from the source's rect, the zoom from the reader's own keys, the panel from the chrome. So "did
/// the pane move?" is the whole question, and answering it before anything is touched is what lets a
/// resize that changes nothing cost nothing.
///
/// A *pinned* cell (`--cell`) is in here too, and deliberately: it makes a `SIGWINCH` that only
/// changes `ws_xpixel` a no-op, which is correct — the pinned cell is what the frame is built from.
struct ResizePane: Equatable {
    var cols: Int
    var rows: Int
    var cellW: Double
    var cellH: Double

    /// The three numbers `TermGeometry.read()` answers with, through the one cell derivation the
    /// program has (`TermGeometry.cellSize`: the operator's pin, else the terminal's answer, else
    /// the fallback). It is a function, so two reads of the same pane are equal.
    init(cols: Int, rows: Int, cellW: Double, cellH: Double) {
        self.cols = cols
        self.rows = rows
        self.cellW = cellW
        self.cellH = cellH
    }
}

/// What one settled resize asks the mirror to do.
enum ResizePlan: Equatable {
    /// The pane is the one the picture was already laid out for: no re-layout, no clear, no restart.
    ///
    /// This is not only the "spurious `SIGWINCH`" case. A drag that goes out and comes back, a
    /// terminal that reports the same grid after a reflow, and the second report some terminals send
    /// for one drag all land here — and every one of them used to delete every placement and
    /// re-transmit the whole picture for nothing.
    case skip
    /// Lay out again, drop the placements, ask the capturer for the new size.
    case relayout

    /// `drawn` is the pane the current picture was fitted to; `nil` means nothing has been laid out
    /// yet (the first paint), or that something other than a resize has re-laid out since (every
    /// `applyLayout` caller clears it), and neither can be "unchanged".
    ///
    /// `force` is a caller whose change is *not* the pane — `applyPanel`, whose rows come out of the
    /// picture while the pane stays put. The comparison above is about the pane and only the pane, so
    /// a caller with its own reason to re-lay out must say so; a skipped `applyLayout` there would
    /// leave the chrome laid out for a panel that is no longer there.
    static func decide(drawn: ResizePane?, now: ResizePane, force: Bool = false) -> ResizePlan {
        if force { return .relayout }
        return drawn == now ? .skip : .relayout
    }
}

/// One settled burst of `SIGWINCH`es, collapsed into one re-layout (issue #89).
///
/// The bug it removes: `installResizeHandler` *delayed* every event by 50 ms and then ran the whole
/// handler — one `writer.clear()` (delete every placement + `2J`), one re-layout and one capture
/// restart **per event**. A 40-event drag therefore deleted the whole picture 40 times and
/// re-transmitted thousands of tiles for one screen: the issue reported 40 clears and 4,564 tile
/// transmissions for a 1.4 s drag, and this branch's re-run of the pre-fix binary put 20 clears on
/// the wire for the 22 events it survived (`bench/loop-resize-storm.py`).
///
/// The rule is a trailing edge: the deadline restarts on every event, and only the work item that
/// still owns the newest token may relayout. Three properties are why it is *trailing* and not
/// "coalesce on the next frame":
///
///  * the frame clock belongs to the capture stream, and a resize is restarting that stream — a
///    rule that waits for a frame to coalesce against would depend on the thing it is coalescing;
///  * the last event of a drag is the one whose size is the size the reader keeps, so the settle
///    has to be measured from the *last* event, not from the first;
///  * nothing needs to happen during a drag. The picture is stale until the pane stops moving, and
///    that is the shape the reader asked for: the picture stops disappearing while dragging.
///
/// `deadline` = 0.08 s: one 20 fps frame of slack over the 0.05 s the old code already paid per
/// event, and comfortably above a drag's event period (30–60 Hz = 33–16 ms), so a whole burst is one
/// deadline and a *single* resize is still answered in 80 ms rather than today's 50.
///
/// The pure half of the handler, in the shape `WallTrigger`/`WallRefresh` gave the wall (#141/#169):
/// the claim "40 events are one re-layout" is a test with a fake clock, not a pty.
struct ResizeCoalescer {
    let deadline: TimeInterval
    /// Bumped by every arrival. A work item carries the token it was scheduled with; a token that is
    /// no longer the current one belongs to an event a later arrival superseded.
    private(set) var generation = 0
    /// When the pending work item fires, or `nil` when no burst is in flight.
    private(set) var dueAt: TimeInterval?
    /// How many events the pending work item would collapse.
    private(set) var pending = 0

    init(deadline: TimeInterval = ResizeCoalescer.defaultDeadline) {
        self.deadline = deadline
    }

    /// 0.08 s — see the type's comment for why it is not the frame and not the old 0.05 s.
    static let defaultDeadline: TimeInterval = 0.08

    /// Monotonic seconds, for the one clock this file's callers use. `Date` is wall time and jumps
    /// with the system clock; a resize that lands across a jump would either never settle or settle
    /// at once.
    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// An event arrived at `now`: it takes ownership of the deadline and gets the token the work
    /// item it schedules must present when it fires.
    mutating func arrive(at now: TimeInterval) -> (token: Int, fireAt: TimeInterval) {
        generation += 1
        pending += 1
        dueAt = now + deadline
        return (generation, dueAt!)
    }

    /// The work item scheduled for `token` ran at `now`.
    ///
    /// Returns how many events it collapsed (the caller logs it), or `nil` when a later arrival
    /// pushed the deadline out and this item must do nothing. `asyncAfter` never fires early, so the
    /// token is the whole rule: a stale item returning `nil` is the burst being *coalesced*, not
    /// lost — the item that owns the newest token is still queued and fires last.
    mutating func fire(token: Int, at now: TimeInterval) -> Int? {
        guard token == generation else { return nil }
        dueAt = nil
        let collapsed = pending
        pending = 0
        return collapsed
    }
}
