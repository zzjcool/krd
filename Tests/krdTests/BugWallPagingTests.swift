import XCTest
@testable import krd
import krdcore

/// The paging and scrolling invariants of the landing wall (`--wall`), asserted on the state
/// machine **and** the layout that feeds it — the pair, because that is where two definitions of
/// "a page" can disagree.
///
/// The one thing that has to be true for any of this: `WallState.clamp`/`apply` take `per` as a
/// *parameter*, and the only correct value is `WallLayout.per` — the **effective** page (below 28
/// columns `WallLayout.make` fits fewer cards than `WallState.per` asks for). Both wall call sites
/// pass it: `main.swift:1276` (`clamp`, after a refresh) and `main.swift:3312` (`apply`, after a
/// click or a wheel). Everything below is therefore built the way `main.swift` builds it: state
/// first, `state.layout(...)` from it, then `clamp`/`apply` with `layout.per`.
///
/// Seven invariants, one test each. The numbers are the design's reference pane, 137x44: three
/// cards of 43 cells in a 10-row band (`cardGap` 3), six fixed rows above them, the footer on row
/// 44, and a bar whose card segment is rows 32–41 — two arrows and **eight** shaft cells for
/// `maxStart = 7 - 3 = 4`. The resize target is 24x20, where the "one card fewer" loop drops `per`
/// from 3 to 2 (22 content cells: 6 per card at 3 slots is under the 8-cell floor, 10 at 2 is not)
/// and the card band keeps exactly 3 rows.
///
///  (a) one click = one page, and both ends are inert (no wrap-around);
///  (b) no window is unreachable: the pages a reader can walk cover `0..<windows`, and the walk
///      stops on exactly the layout's `maxStart` — the number the bar's shaft jumps to;
///  (c) `pageCount < per`: neither the card band nor the bar's lower segment answers a step, i.e.
///      no dead arrow the user can click (design §5);
///  (d) a resize while scrolled keeps the window that was on screen, and the page it lands on is a
///      legal page;
///  (e) re-entry restores the page: `.enterCard`/`.back` — and a resize while a pick is showing —
///      never move the shelf (the `--wall-at` offset handed to the mirror is `state.cardStart`);
///  (f) the shaft is a monotone map onto `0...maxStart` and its last cell is the last page;
///  (g) the wheel moves one card (not one page), one display on the stage, and nothing at all when
///      there is nothing to scroll.
final class BugWallPagingTests: XCTestCase {
    private let displays = 3

    /// The wall's state, built the way `runWall()` builds it (`WallState()`, then the `--wall-at`
    /// offsets on a return). `per` is the *request*; the layout decides what actually fits.
    private func state(cardStart: Int = 0, stageStart: Int = 0, per: Int = 3) -> WallState {
        var state = WallState()
        state.per = per
        state.cardStart = cardStart
        state.stageStart = stageStart
        return state
    }

    /// The layout `main.swift` would build for a state (`WallCanvas.swift:217`), whose `per` every
    /// `clamp`/`apply` below is called with.
    private func layout(_ state: WallState, windows: Int, cols: Int = 137, rows: Int = 44,
                        displays: Int = 3) -> WallLayout {
        state.layout(cols: cols, rows: rows, displays: displays, windows: windows)
    }

    // MARK: (a) one click = one page

    func testOneClickIsOnePageAndBothEndsAreInert() {
        let windows = 7
        var state = self.state()                     // per 3, cardStart 0: the landing page
        let layout = self.layout(state, windows: windows)
        XCTAssertEqual(layout.per, 3,
                       "windows \(windows), requested per 3 at 137x44: expected the layout's per 3, "
                       + "actual \(layout.per)")
        XCTAssertEqual(layout.cardStart, 0,
                       "windows \(windows), per \(layout.per): the landing page starts at 0, actual "
                       + "\(layout.cardStart)")
        XCTAssertEqual(layout.bar.cards.maxStart, 4,
                       "windows \(windows), per \(layout.per): expected maxStart \(windows) - 3 = 4, "
                       + "actual \(layout.bar.cards.maxStart)")

        // The click itself, not a hand-written payload: the bar's ▼ is one page (`per` cards).
        let down = layout.action(row: layout.bar.cards.rect.maxRow, col: layout.barCol)
        let up = layout.action(row: layout.bar.cards.rect.row, col: layout.barCol)
        XCTAssertEqual(down, .cardStep(3),
                       "windows \(windows), per \(layout.per): the card ▼ at row "
                       + "\(layout.bar.cards.rect.maxRow) must send one page, actual "
                       + "\(String(describing: down))")
        XCTAssertEqual(up, .cardStep(-3),
                       "windows \(windows), per \(layout.per): the card ▲ at row "
                       + "\(layout.bar.cards.rect.row) must send one page back, actual "
                       + "\(String(describing: up))")
        guard let down, let up else {
            return XCTFail("windows \(windows), per \(layout.per): the bar's card segment must "
                           + "answer cardStep(±3), actual \(String(describing: down)) / "
                           + "\(String(describing: up))")
        }

        var trace: [String] = []
        func step(_ action: WallAction, want: Int, _ why: String) {
            let before = state.cardStart
            state.apply(action, displays: displays, windows: windows, per: layout.per)
            trace.append("\(before) -> \(state.cardStart)")
            XCTAssertEqual(state.cardStart, want,
                           "windows \(windows), per \(layout.per): cardStart \(before) after "
                           + "\(action) must be \(want), actual \(state.cardStart) (\(why))")
        }
        step(down, want: 3, "one page forward from the landing page")
        step(down, want: 4, "the last page is windows - per = 7 - 3 = 4")
        step(down, want: 4, "a click past the last page is inert, no wrap-around")
        step(up, want: 1, "one page back from the last page")
        step(up, want: 0, "one page back from 1")
        step(up, want: 0, "a click before the first page is inert, no wrap-around")
        XCTAssertEqual(trace, ["0 -> 3", "3 -> 4", "4 -> 4", "4 -> 1", "1 -> 0", "0 -> 0"],
                       "windows \(windows), per \(layout.per): expected 0,3,4,4,1,0,0 through the "
                       + "bar's own arrows, actual \(trace)")
    }

    // MARK: (b) no window is unreachable

    func testEveryWindowIsReachableByPaging() {
        // Two panes: the reference one, and the one a resize lands in — there 24 columns fit 2
        // cards, so `WallLayout.per` is smaller than the state's request for per 3...5, which is
        // the configuration the `clamp` doc comment is about.
        var complaints: [String] = []
        for pane in [(cols: 137, rows: 44), (cols: 24, rows: 20)] {
            for windows in 1...30 {
                for requested in 1...5 {
                    let start = state(per: requested)
                    let first = layout(start, windows: windows, cols: pane.cols, rows: pane.rows)
                    let per = first.per
                    if pane.cols == 137, per != requested {
                        complaints.append("\(pane.cols)x\(pane.rows), windows \(windows): fits the "
                                          + "requested \(requested), but the layout's per is "
                                          + "\(per)")
                    }
                    // Walk the page forward exactly the way the bar's ▼ does (`.cardStep(per)`)
                    // until the shelf stops moving. The stops are the pages a reader can click.
                    var walker = start
                    var starts: [Int] = []
                    for _ in 0..<256 {                // the guard only stops a broken clamp spinning
                        starts.append(walker.cardStart)
                        let before = walker.cardStart
                        walker.apply(.cardStep(per), displays: displays, windows: windows, per: per)
                        if walker.cardStart == before { break }
                    }
                    // (1) the union of those pages shows every window.
                    var shown = Set<Int>()
                    for from in starts {
                        // A broken clamp can hand back a start past the end; that is a complaint
                        // below ((2) checks the stop), not a trap here.
                        let hi = min(from + per, windows)
                        guard from >= 0, from < hi else { continue }
                        for index in from..<hi { shown.insert(index) }
                    }
                    let never = (0..<windows).filter { !shown.contains($0) }
                    if !never.isEmpty {
                        complaints.append("\(pane.cols)x\(pane.rows), windows \(windows), per "
                                          + "\(per) (requested \(requested)): no page ever shows "
                                          + "window \(never); reachable starts \(starts)")
                    }
                    // (2) the walk stops on exactly the layout's last page, and that is where
                    //     the clamp puts a start that is out of range — the number the bar's
                    //     shaft jumps to (the arithmetic the 27x24 bug got wrong).
                    let stop = walker.cardStart
                    let lastPage = first.bar.cards.maxStart
                    if stop != lastPage {
                        complaints.append("\(pane.cols)x\(pane.rows), windows \(windows), per "
                                          + "\(per): the walk stops at \(stop), the layout's "
                                          + "maxStart is \(lastPage)")
                    }
                    var stale = walker
                    stale.cardStart = windows + 99
                    stale.clamp(displays: displays, windows: windows, per: per)
                    if stale.cardStart != stop {
                        complaints.append("\(pane.cols)x\(pane.rows), windows \(windows), per "
                                          + "\(per): clamp of a stale \(windows + 99) gives "
                                          + "\(stale.cardStart), the largest reachable start is "
                                          + "\(stop)")
                    }
                    // (3) the last window is actually drawn on the page the walk stops on.
                    let last = layout(walker, windows: windows, cols: pane.cols, rows: pane.rows)
                    if last.cards.isEmpty
                        || last.cardStart + last.cards.count - 1 != windows - 1 {
                        complaints.append("\(pane.cols)x\(pane.rows), windows \(windows), per "
                                          + "\(per): the last page starts at \(last.cardStart) "
                                          + "and draws \(last.cards.count) cards, so window "
                                          + "\(windows - 1) is not on it")
                    }
                }
            }
        }
        XCTAssertTrue(complaints.isEmpty, complaints.joined(separator: "; "))
    }

    // MARK: (c) a page smaller than `per` has nothing to scroll

    func testAPartialPageHasNothingToScroll() {
        let windows = 2
        let state = self.state()                     // per 3 requested, cardStart 0
        let layout = self.layout(state, windows: windows)
        XCTAssertEqual(layout.per, 3,
                       "windows \(windows), requested per 3 at 137x44: expected per 3, actual "
                       + "\(layout.per)")
        XCTAssertEqual(layout.cards.count, 2,
                       "windows \(windows), per \(layout.per): pageCount < per means 2 card rects, "
                       + "actual \(layout.cards.count)")
        XCTAssertEqual(layout.bar.cards.count, windows,
                       "windows \(windows): the segment's track is the window list, actual "
                       + "\(layout.bar.cards.count)")
        XCTAssertEqual(layout.bar.cards.visible, 3,
                       "windows \(windows), per \(layout.per): the segment's page is still 3, actual "
                       + "\(layout.bar.cards.visible)")
        XCTAssertFalse(layout.bar.cards.scrollable,
                       "windows \(windows), per \(layout.per): 2 cards on a 3-slot page leave "
                       + "nothing to scroll, actual scrollable \(layout.bar.cards.scrollable) "
                       + "(count \(layout.bar.cards.count), visible \(layout.bar.cards.visible))")

        // Nothing in the card band may step the shelf: the band, its captions and the bar's lower
        // segment are entering cells and dead cells, never arrows.
        let bandTop = layout.bandRow + 1
        XCTAssertEqual(layout.cards.first?.row, bandTop,
                       "windows \(windows): the band starts under the band header "
                       + "\(layout.bandRow), actual \(String(describing: layout.cards.first?.row))")
        var steppers: [String] = []
        for row in bandTop...(bandTop + layout.cardBandRows - 1) {
            for col in 1...layout.cols {
                if case let .cardStep(d)? = layout.action(row: row, col: col) {
                    steppers.append("(\(row),\(col)) -> cardStep(\(d))")
                }
            }
        }
        XCTAssertTrue(steppers.isEmpty,
                      "windows \(windows), per \(layout.per), pageCount \(layout.cards.count): a "
                      + "page smaller than per has nothing to scroll, but \(steppers.count) cells "
                      + "step it: \(steppers.prefix(8))")

        // The bar's lower segment — both arrows and the shaft — answers nothing: that is what
        // makes the grey ▲/▼ honestly grey (design §5, no dead cells the user can click).
        let segment = layout.bar.cards
        XCTAssertFalse(segment.rect.isEmpty,
                       "windows \(windows): the card band exists, so its bar segment must too")
        for row in segment.rect.row...segment.rect.maxRow {
            let got = layout.action(row: row, col: layout.barCol)
            XCTAssertNil(got,
                         "windows \(windows), per \(layout.per): bar row \(row) of a segment with "
                         + "count \(segment.count) <= visible \(segment.visible) must be dead, "
                         + "actual \(String(describing: got))")
        }
        // ...while the two cards themselves still enter their window: inert, not broken.
        XCTAssertEqual(layout.action(row: layout.cards[0].row, col: layout.cards[0].col),
                       .enterCard(0),
                       "windows \(windows), per \(layout.per): the first card must still enter "
                       + "window \(layout.cardStart + 0)")
        XCTAssertEqual(layout.action(row: layout.cards[1].row, col: layout.cards[1].col),
                       .enterCard(1),
                       "windows \(windows), per \(layout.per): the second card must still enter "
                       + "window \(layout.cardStart + 1)")
    }

    // MARK: (d) a resize keeps what was on screen

    func testAResizeKeepsTheWindowThatWasOnScreen() {
        let windows = 7
        var state = self.state(cardStart: 4)         // page 3 at 137x44: windows 4, 5, 6
        let wide = layout(state, windows: windows)
        XCTAssertEqual(wide.per, 3,
                       "windows \(windows), requested per 3 at 137x44: expected per 3, actual "
                       + "\(wide.per)")
        XCTAssertEqual(wide.cardStart, 4,
                       "windows \(windows), per \(wide.per): expected the page to start at 4, "
                       + "actual \(wide.cardStart)")
        XCTAssertEqual(wide.cards.count, 3,
                       "windows \(windows), per \(wide.per), cardStart \(wide.cardStart): expected "
                       + "windows 4, 5, 6 on screen, actual \(wide.cards.count) cards")

        // The reader drags the pane smaller. 24 columns is under the 3-card floor, so the layout
        // fits 2 and `maxStart` grows from 4 to 5 while the state still says 4.
        let shrunk = self.layout(state, windows: windows, cols: 24, rows: 20)
        XCTAssertEqual(shrunk.per, 2,
                       "windows \(windows) on 24x20: 22 content cells fit 2 cards (6 is under the "
                       + "8-cell floor), expected per 2, actual \(shrunk.per)")
        XCTAssertEqual(shrunk.bar.cards.maxStart, 5,
                       "windows \(windows), per \(shrunk.per): expected maxStart 7 - 2 = 5, actual "
                       + "\(shrunk.bar.cards.maxStart)")

        // What `refreshWall` does on the resize (`main.swift:1276`), then the layout again.
        state.clamp(displays: displays, windows: windows, per: shrunk.per)
        let after = self.layout(state, windows: windows, cols: 24, rows: 20)
        XCTAssertEqual(after.cardStart, state.cardStart,
                       "windows \(windows), per \(after.per): the clamp and the layout must agree "
                       + "on the page, state \(state.cardStart) vs layout \(after.cardStart)")
        XCTAssertFalse(after.cards.isEmpty,
                       "windows \(windows), per \(after.per), cardStart \(after.cardStart): the "
                       + "shelf must still draw cards, actual \(after.cards.count)")
        XCTAssertTrue(after.cardStart >= 0 && after.cardStart <= after.bar.cards.maxStart,
                      "windows \(windows): the page after the resize \(after.cardStart) must be a "
                      + "reachable start, 0...\(after.bar.cards.maxStart)")
        XCTAssertTrue(after.cardStart <= 4 && 4 <= after.cardStart + after.per - 1,
                      "windows \(windows): window 4 was the first one on screen before the resize; "
                      + "after it the page starts at \(after.cardStart) with per \(after.per) "
                      + "(\(after.cards.count) cards, so up to window "
                      + "\(after.cardStart + after.cards.count - 1)), and window 4 is not on it")
    }

    // MARK: (e) re-entry restores the page

    func testReEntryRestoresThePage() {
        let windows = 7
        var state = self.state(cardStart: 4)         // the page the reader leaves from
        let wide = layout(state, windows: windows)
        let first = wide.cards[0]
        XCTAssertEqual(wide.action(row: first.row, col: first.col), .enterCard(4),
                       "windows \(windows), per \(wide.per), cardStart \(wide.cardStart): the first "
                       + "card of the page must enter window 4")

        state.apply(.enterCard(4), displays: displays, windows: windows, per: wide.per)
        XCTAssertEqual(state.focus, WallState.Focus.window(4),
                       "windows \(windows): expected the pick to be window 4, actual "
                       + "\(String(describing: state.focus))")
        XCTAssertEqual(state.cardStart, 4,
                       "windows \(windows), per \(wide.per): entering window 4 must not move the "
                       + "shelf, expected 4, actual \(state.cardStart)")
        state.apply(.back, displays: displays, windows: windows, per: wide.per)
        XCTAssertNil(state.focus, "windows \(windows): back leaves the wall's own view")
        XCTAssertEqual(state.cardStart, 4,
                       "windows \(windows), per \(wide.per): back from window 4 must return to "
                       + "page 4, actual \(state.cardStart)")

        // The wall that comes back (`exec` → `--wall-at 0:4` → `runWall`) draws that same page.
        let restored = layout(state, windows: windows)
        XCTAssertEqual(restored.cardStart, 4,
                       "windows \(windows), per \(restored.per): expected the restored page 4, "
                       + "actual \(restored.cardStart)")
        XCTAssertEqual(restored.cards.count, 3,
                       "windows \(windows), per \(restored.per), cardStart \(restored.cardStart): "
                       + "expected windows 4, 5, 6, actual \(restored.cards.count) cards")

        // A resize while the pick is showing must not page the shelf either: the offset handed to
        // the mirror is the state's, and it has to still be the page the reader was looking at.
        state.apply(.enterCard(4), displays: displays, windows: windows, per: wide.per)
        let shrunk = self.layout(state, windows: windows, cols: 24, rows: 20)
        state.clamp(displays: displays, windows: windows, per: shrunk.per)
        XCTAssertEqual(state.focus, WallState.Focus.window(4),
                       "windows \(windows): a resize must not clear the pick, actual "
                       + "\(String(describing: state.focus))")
        XCTAssertEqual(state.cardStart, 4,
                       "windows \(windows), per \(shrunk.per): a resize while window 4 is picked "
                       + "must not move the shelf, expected 4, actual \(state.cardStart)")
        state.apply(.back, displays: displays, windows: windows, per: shrunk.per)
        let after = self.layout(state, windows: windows, cols: 24, rows: 20)
        XCTAssertEqual(after.cardStart, 4,
                       "windows \(windows), per \(after.per): back after the resize must still be "
                       + "page 4, actual \(after.cardStart)")
        XCTAssertTrue(after.cardStart <= 4 && 4 <= after.cardStart + after.per - 1,
                      "windows \(windows), per \(after.per), cardStart \(after.cardStart): the page "
                      + "the reader returns to must still show window 4, actual cards "
                      + "\(after.cardStart)...\(after.cardStart + after.cards.count - 1)")
    }

    // MARK: (f) the shaft is a monotone map onto 0...maxStart

    func testTheShaftMapsMonotonicallyOntoEveryPageStart() {
        let windows = 7
        let state = self.state()                     // the landing page: the shaft can move
        let layout = self.layout(state, windows: windows)
        let segment = layout.bar.cards
        XCTAssertTrue(segment.scrollable,
                      "windows \(windows), per \(segment.visible): 7 windows on a 3-slot page must "
                      + "scroll, actual count \(segment.count) visible \(segment.visible)")
        let shaft = segment.rect.rows - 2
        XCTAssertEqual(shaft, 8,
                       "windows \(windows), per \(segment.visible): a \(segment.rect.rows)-row "
                       + "segment (the card band) has expected 8 shaft cells between its arrows, "
                       + "actual \(shaft)")
        var targets: [Int] = []
        for row in (segment.rect.row + 1)..<segment.rect.maxRow {
            let got = layout.action(row: row, col: layout.barCol)
            guard case let .cardJump(target)? = got else {
                XCTFail("windows \(windows), per \(segment.visible): shaft row \(row) must jump to "
                        + "a page, actual \(String(describing: got))")
                continue
            }
            XCTAssertTrue(target >= 0 && target <= segment.maxStart,
                          "windows \(windows), per \(segment.visible): shaft row \(row) jumps to "
                          + "\(target), outside 0...\(segment.maxStart)")
            targets.append(target)
        }
        for (a, b) in zip(targets, targets.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b,
                                     "windows \(windows), per \(segment.visible): the shaft must not "
                                     + "go backwards down the track, targets \(targets)")
        }
        XCTAssertEqual(targets.first, 0,
                       "windows \(windows), per \(segment.visible): the top shaft cell is the first "
                       + "page, actual \(String(describing: targets.first)) (targets \(targets))")
        XCTAssertEqual(targets.last, segment.maxStart,
                       "windows \(windows), per \(segment.visible): the last shaft cell must reach "
                       + "the last page \(segment.maxStart), actual "
                       + "\(String(describing: targets.last)) (targets \(targets))")
        XCTAssertEqual(segment.jumpTarget(shaftOffset: shaft - 1), segment.maxStart,
                       "windows \(windows), per \(segment.visible): jumpTarget of the last shaft "
                       + "offset \(shaft - 1) must be \(segment.maxStart), actual "
                       + "\(segment.jumpTarget(shaftOffset: shaft - 1))")
        // The click route and the state agree about where that is (the old bug was the state
        // dragging a jump back, which made the last window unreachable).
        var clicked = state
        clicked.apply(.cardJump(segment.maxStart), displays: displays, windows: windows,
                      per: layout.per)
        XCTAssertEqual(clicked.cardStart, segment.maxStart,
                       "windows \(windows), per \(layout.per): a jump to the last page must land "
                       + "on \(segment.maxStart), actual \(clicked.cardStart)")
    }

    // MARK: (g) the wheel moves one card, not one page

    func testTheWheelMovesOneCardNotOnePage() {
        let windows = 7
        let state = self.state()
        let layout = self.layout(state, windows: windows)
        let cards = layout.cards
        XCTAssertEqual(cards.count, 3,
                       "windows \(windows), per \(layout.per): expected a full page of 3, actual "
                       + "\(cards.count)")
        XCTAssertEqual(cards[0].rows, layout.cardBandRows,
                       "windows \(windows): at 137x44 the page fills the band, cards "
                       + "\(cards[0].rows) rows against a band of \(layout.cardBandRows)")
        let col = cards[1].col                      // a column that is inside a card, not the bar
        for row in cards[0].row...cards[0].maxRow {
            let down = layout.wheelAction(row: row, col: col, direction: 1)
            let up = layout.wheelAction(row: row, col: col, direction: -1)
            XCTAssertEqual(down, .cardStep(1),
                           "windows \(windows), per \(layout.per): a notch down on card row \(row) "
                           + "must move one card (cardStep(1)), actual \(String(describing: down))")
            XCTAssertEqual(up, .cardStep(-1),
                           "windows \(windows), per \(layout.per): a notch up on card row \(row) "
                           + "must move one card (cardStep(-1)), actual "
                           + "\(String(describing: up))")
        }
        // The band header — the row above the page — scrolls the same shelf, one card at a time.
        XCTAssertEqual(layout.wheelAction(row: layout.bandRow, col: col, direction: 1), .cardStep(1),
                       "windows \(windows), per \(layout.per): a notch down on the band header "
                       + "\(layout.bandRow) must move one card, actual "
                       + "\(String(describing: layout.wheelAction(row: layout.bandRow, col: col, direction: 1)))")
        XCTAssertEqual(layout.wheelAction(row: layout.bandRow, col: col, direction: -1),
                       .cardStep(-1),
                       "windows \(windows), per \(layout.per): a notch up on the band header "
                       + "\(layout.bandRow) must move one card, actual "
                       + "\(String(describing: layout.wheelAction(row: layout.bandRow, col: col, direction: -1)))")
        // The stage is a different shelf: one display, not one card.
        XCTAssertEqual(layout.wheelAction(row: layout.stage.row, col: 5, direction: 1),
                       .stageStep(1),
                       "displays \(displays): a notch down on stage row \(layout.stage.row) must "
                       + "move one display, actual "
                       + "\(String(describing: layout.wheelAction(row: layout.stage.row, col: 5, direction: 1)))")
        XCTAssertEqual(layout.wheelAction(row: layout.stage.maxRow, col: 5, direction: -1),
                       .stageStep(-1),
                       "displays \(displays): a notch up on stage row \(layout.stage.maxRow) must "
                       + "move one display, actual "
                       + "\(String(describing: layout.wheelAction(row: layout.stage.maxRow, col: 5, direction: -1)))")
        XCTAssertEqual(layout.wheelAction(row: layout.stageCaption.row, col: 5, direction: 1),
                       .stageStep(1),
                       "displays \(displays): a notch on the stage caption row "
                       + "\(layout.stageCaption.row) belongs to the stage, actual "
                       + "\(String(describing: layout.wheelAction(row: layout.stageCaption.row, col: 5, direction: 1)))")

        // Nothing to scroll, nothing to move: a 2-window shelf on a 3-slot page...
        let short = self.layout(self.state(), windows: 2)
        XCTAssertEqual(short.cards.count, 2,
                       "windows 2, per \(short.per): expected 2 cards, actual \(short.cards.count)")
        XCTAssertNil(short.wheelAction(row: short.bandRow, col: col, direction: 1),
                     "windows 2, per \(short.per), cardStart \(short.cardStart): the band header of "
                     + "a shelf with nothing to scroll must swallow the notch, actual "
                     + "\(String(describing: short.wheelAction(row: short.bandRow, col: col, direction: 1)))")
        for row in short.cards[0].row...short.cards[0].maxRow {
            XCTAssertNil(short.wheelAction(row: row, col: col, direction: 1),
                         "windows 2, per \(short.per): card row \(row) of a shelf with nothing to "
                         + "scroll must swallow the notch, actual "
                         + "\(String(describing: short.wheelAction(row: row, col: col, direction: 1)))")
        }
        // ...and a single display.
        let single = self.layout(self.state(), windows: windows, displays: 1)
        XCTAssertNil(single.wheelAction(row: single.stage.row, col: 5, direction: 1),
                     "displays 1: stage row \(single.stage.row) has nothing to scroll, actual "
                     + "\(String(describing: single.wheelAction(row: single.stage.row, col: 5, direction: 1)))")
        // A wheel report with no direction is not a notch.
        XCTAssertNil(layout.wheelAction(row: cards[0].row, col: col, direction: 0),
                     "windows \(windows), per \(layout.per): direction 0 is not a notch, actual "
                     + "\(String(describing: layout.wheelAction(row: cards[0].row, col: col, direction: 0)))")
    }
}
