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
    /// The bounded-staleness poll (issue #169 review): every `WallSource.pollInterval` seconds the
    /// wall takes a fingerprint and enumerates only when it moved. This is the *upper bound* on
    /// staleness for the one change AppKit does not announce — a window that closes or opens inside
    /// the app that is already frontmost.
    case poll
    /// The wall's own input (a click or a wheel event) reaching for the window it is about to
    /// hit-test. It takes the fingerprint itself for exactly that reason: a card whose window is
    /// gone must not be clicked on, and no notification announces that close.
    case input
    /// A refresh the wall asked of itself: the first paint, a return from a mirror, a resize.
    case explicit

    /// May this trigger ask the window server? A necessary condition, not a sufficient one —
    /// `WallRefresh.shouldEnumerate` has the final say, and for `.poll`/`.input` that answer is
    /// "only when the fingerprint moved". `.tick` must stay `false`: that is the fix of #141.
    var enumerates: Bool { self != .tick }

    /// Does this trigger ask "did the world move?" before it enumerates — the fingerprint gate?
    ///
    /// Only the triggers that run on a rate the reader feels do: the poll (every 2.0 s) and the
    /// wall's own input (every click). Their `drawn == nil || drawn != now` answer is what turns an
    /// idle poll into a comparison instead of an enumeration. `.world` and `.explicit` enumerate by
    /// design, so a fingerprint in front of them buys nothing — and on `.explicit` (the first paint,
    /// a resize, a return from a mirror) it is a window-server round trip in front of the only frame
    /// the wall has, which is the one place a gate must never be.
    var gatesOnFingerprint: Bool { self == .poll || self == .input }
}

/// A cheap summary of the world, compared instead of the model (issue #169 review).
///
/// The poll that bounds the wall's staleness runs for the wall's whole life, so what it costs per
/// interval *is* the design: enumerating every 2.0 s (`CGWindowListCopyWindowInfo` bridged to
/// `[[String: Any]]` plus the `WindowOrder` rules) would give back half of issue #141 (1.24 ms per
/// second becomes 1.24 ms every 2 s). `WallSource.fingerprint()` reads the same window list as CF
/// objects, without bridging it, and keeps only these four values — enough that any change the cards
/// could show moves at least one of them:
///
/// - `windows` and `ids` are deliberately redundant: window numbers are never reused, so "one
///   window closed while another opened" moves `ids`; a bare count would cancel that out.
/// - `frontmost` covers a pure reorder (the same set of windows, a different z order/focus) — and it
///   is what makes a click that changed focus reconcile.
/// - `displays` covers a plug/unplug/rearrange, which changes the stage and every panel's fit.
struct WallFingerprint: Equatable {
    /// On-screen layer-0 windows owned by a regular app. This is `WindowOrder`'s primary membership
    /// rule (`regularPIDs`) without its belt-and-braces name blocklist: a fingerprint does not have
    /// to match the card list, only to move whenever the card list would.
    var windows: Int
    /// The sum of those windows' numbers — see above: a close and an open must not cancel.
    var ids: Int
    /// The frontmost app's pid, `0` when there is none.
    var frontmost: Int32
    /// The active display ids, sorted — so a reordered `CGGetActiveDisplayList` is not a change.
    var displays: [UInt32]
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

/// Did the probes that run behind the wall's first paint move anything (issue #99)?
///
/// The wall now paints before it asks the terminal, so the two questions it asks - the cell
/// (`CSI 16t`/`14t`) and the transport (`U=1`) - arrive *after* a frame is already on screen. Both are
/// allowed to answer "nothing changed", which is the common case and the one that must stay free: an
/// unchanged answer means the frame that is up is right, and a repaint would re-capture every panel to
/// draw exactly the same picture. A value type with the decision in `needsRepaint` (rather than an
/// `if` at the call site) is what makes "a silent terminal moves nothing" a test instead of a claim.
struct WallProbeOutcome: Equatable {
    /// The second measurement found a different cell (or grid).
    var paneMoved: Bool
    /// The `U=1` verdict differs from the transport the first frame was drawn on.
    var transportMoved: Bool

    /// Repaint only when one of them moved: `false` is the silent terminal, whose probe times out to
    /// the fallback cell and the pixel path - the exact two values the first paint already used.
    var needsRepaint: Bool { paneMoved || transportMoved }
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

    /// Does this trigger ask the window server before anything is repainted — the one gate the
    /// bounded-staleness poll and the wall's own input share with the notifications (issue #169
    /// review).
    ///
    /// `drawn` is the fingerprint the model currently on screen was enumerated against; `nil` means
    /// nothing has been enumerated yet, so "the fingerprint did not move" cannot be claimed and any
    /// trigger allowed to ask must ask.
    static func shouldEnumerate(_ trigger: WallTrigger, now: WallFingerprint,
                                drawn: WallFingerprint?) -> Bool {
        switch trigger {
        case .tick:
            // The 1 s timer owns the pty grid and nothing else. An idle second must cost an ioctl,
            // not a window-server round-trip: this is #141 itself.
            return false
        case .world, .explicit:
            // The notification rate is human-scale (a launch, a focus change, a space switch, a
            // resize), so paying the enumeration is cheap in aggregate — and a notification can
            // arrive *before* the window it announces, so comparing fingerprints here could skip
            // the enumeration the event is asking for. `.explicit` is the wall asking itself (first
            // paint, a return from a mirror, a resize): there is nothing trustworthy on screen to
            // compare against, and a repaint after a cleared terminal is free to be right.
            return true
        case .poll, .input:
            // Both exist only to catch what no notification announced (a window closing inside the
            // already-frontmost app), so they may not answer "unchanged" from memory — but they
            // also run at a rate the reader feels (every 2.0 s, every click), so an unchanged world
            // must cost the fingerprint and no enumeration. `drawn == nil` is the first one.
            return drawn == nil || drawn != now
        }
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
