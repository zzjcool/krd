import XCTest
@testable import krdcore

/// A drawn thumb that does not answer for its own position (issue #135).
///
/// `WallLayout.WallBar.Segment` is a proportional scrollbar: `thumbRow()` maps `start` to a cell of
/// the shaft and `jumpTarget(shaftOffset:)` is documented as *the inverse of `thumbRow()`* — a click
/// on the cell the thumb is drawn on makes that position the new start.
///
/// The inverse used to be implemented only for `shaftCount >= 2`; `jumpTarget` answered `0` for a
/// one-cell shaft, while `thumbRow` still draws a thumb there (it has an explicit `shaftCount == 1`
/// branch). A 3-row segment therefore showed `▲`, one `█` and `▼`, and clicking the `█` jumped to
/// the first page wherever the shelf actually was — a control that says "you are here" and answers
/// "go to the start" (design §5: no cell the user can click that does not do what it looks like).
///
/// The rule now in force: with one shaft cell no two starts can be told apart — every one of them
/// draws the thumb in that cell — so the only position the click can name is the one the thumb is
/// drawn for, i.e. the reader's own. The cell is a no-op; it is never page 0. The alternative (draw
/// no thumb on a one-cell shaft and let `drawSegment` keep the plain `│`) was rejected: a `│` in a
/// live segment means "click to jump proportionally" everywhere else in the bar, so a dead one
/// would put a cell that swallows a click inside a live segment (design §5: "no dead cells that
/// swallow clicks").
final class BugWallThumbJumpTests: XCTestCase {
    /// `WallLayout.action` refuses to look at a bar cell that is not in the bar column, so the
    /// click is asked exactly the way a real click asks it.
    private func action(_ l: WallLayout, row: Int) -> WallAction? {
        l.action(row: row, col: l.barCol)
    }

    /// The invariant: a thumb drawn at a cell means "this segment's position is here", so a click on
    /// that cell must not send the segment to a page the thumb cannot be showing. A shaft with fewer
    /// cells than positions is coarse — several starts share one cell and the nearest one wins, which
    /// is what `testThumbAndJumpAreInverse` pins for a >= 2-cell shaft. A **one-cell** shaft cannot
    /// distinguish any two positions at all (every `start` draws the thumb in the same cell), so the
    /// click owes the reader `start` — or nothing — and never page 0.
    func testOneCellShaftDoesNotLieAboutItsPosition() {
        var failures: [String] = []
        var reached = 0
        var checked = 0
        var firstPane: (cols: Int, rows: Int, start: Int, thumb: Int, got: WallAction?)?

        for cols in 10...60 {
            for rows in 5...25 {
                for windows in [2, 3, 7, 14] {
                    for per in [1, 2, 3, 4] {
                        // A page that is not the first, so a click that answers 0 is visibly wrong.
                        // Narrow panes lower `per`, so this is the last page only where the layout
                        // kept the requested row width — on the rest it is an interior page, which
                        // is all the assertion needs.
                        let start = max(0, windows - per)
                        guard start > 0 else { continue }
                        let l = WallLayout.make(paneCols: cols, paneRows: rows, displayCount: 3,
                                                windowCount: windows, per: per,
                                                stageStart: 0, cardStart: start)
                        let seg = l.bar.cards
                        guard seg.scrollable, seg.rect.rows == 3, seg.start > 0 else { continue }
                        // The segment exists. Count it before any thumb decision, so "no thumb is
                        // drawn on a one-cell shaft" still proves the sweep reached the case
                        // instead of silently asserting nothing; `checked` below then insists that
                        // some thumbs were actually clicked.
                        reached += 1
                        guard let thumb = seg.thumbRow() else { continue }
                        // rect.rows == 3 -> exactly one shaft cell, the one the thumb is on.
                        XCTAssertEqual(thumb, seg.rect.row + 1,
                                       "\(cols)x\(rows) w\(windows) per\(per): a 3-row segment "
                                         + "has one shaft cell")
                        let got = action(l, row: thumb)
                        checked += 1
                        if firstPane == nil {
                            firstPane = (cols, rows, seg.start, thumb, got)
                        }
                        if got != .cardJump(seg.start) {
                            failures.append("\(cols)x\(rows) w\(windows) per\(per): thumb drawn at "
                                + "row \(thumb) for cardStart \(seg.start), "
                                + "maxStart \(seg.maxStart), click -> \(String(describing: got))")
                        }
                    }
                }
            }
        }

        XCTAssertGreaterThan(reached, 0,
                             "the sweep must reach a 3-row card segment at all")
        XCTAssertGreaterThan(checked, 0,
                             "the sweep must actually click a thumb, or it proves nothing")
        if let f = firstPane {
            print("smallest 3-row card segment: \(f.cols)x\(f.rows) cardStart \(f.start), "
                  + "thumb row \(f.thumb), click -> \(String(describing: f.got))")
        }
        XCTAssertEqual(failures.count, 0,
                       "a thumb is drawn on a segment whose click cannot answer for it: "
                         + "\(failures.count) of \(checked) three-row segments jump away from the "
                         + "page their thumb is showing. First 4: \(failures.prefix(4))")
    }

    /// The same sweep for the *stage* segment, which has the same shape whenever the stage band is
    /// 3 rows — the card band is not the only source of a one-cell shaft: a pane too short for a card
    /// band hands the whole budget to the stage, and at 8 rows that budget is exactly 3. Both
    /// segments share `WallBar.Segment`, so a fix that only held for the cards would be a fix in the
    /// wrong place.
    func testOneCellStageShaftDoesNotLieAboutItsPosition() {
        var failures: [String] = []
        var reached = 0
        var checked = 0

        for cols in 10...160 {
            for rows in 5...30 {
                for displays in [2, 3, 7] {
                    // The last display, so a click that answers 0 is visibly not a no-op.
                    let start = displays - 1
                    let l = WallLayout.make(paneCols: cols, paneRows: rows, displayCount: displays,
                                            windowCount: 7, per: 3,
                                            stageStart: start, cardStart: 0)
                    let seg = l.bar.stage
                    guard seg.scrollable, seg.rect.rows == 3, seg.start > 0 else { continue }
                    reached += 1
                    guard let thumb = seg.thumbRow() else { continue }
                    XCTAssertEqual(thumb, seg.rect.row + 1,
                                   "\(cols)x\(rows) d\(displays): a 3-row segment has one shaft cell")
                    let got = action(l, row: thumb)
                    checked += 1
                    if got != .stageJump(seg.start) {
                        failures.append("\(cols)x\(rows) d\(displays): thumb drawn at row \(thumb) "
                            + "for stageStart \(seg.start), maxStart \(seg.maxStart), click -> "
                            + "\(String(describing: got))")
                    }
                }
            }
        }

        XCTAssertGreaterThan(reached, 0, "the sweep must reach a 3-row stage segment at all")
        XCTAssertGreaterThan(checked, 0,
                             "the sweep must actually click a thumb, or it proves nothing")
        XCTAssertEqual(failures.count, 0,
                       "the stage's one-cell shaft jumps away from the display it shows: "
                         + "\(failures.count) of \(checked). First 4: \(failures.prefix(4))")
    }

    /// The baseline this bug is a hole in: on the design pane (137x44, 7 windows, per 3) the shaft
    /// has 8 cells, and the thumb answers for itself — the round trip holds.
    func testThumbRoundTripOnTheDesignPane() {
        let l = WallLayout.make(paneCols: 137, paneRows: 44, displayCount: 3, windowCount: 7,
                                per: 3, stageStart: 0, cardStart: 0)
        let seg = l.bar.cards
        XCTAssertTrue(seg.scrollable)
        XCTAssertEqual(seg.rect.rows, 10, "the card band is 10 rows at 137x44")
        for start in 0...seg.maxStart {
            let shifted = WallLayout.make(paneCols: 137, paneRows: 44, displayCount: 3,
                                          windowCount: 7, per: 3, stageStart: 0, cardStart: start)
            let s = shifted.bar.cards
            guard let thumb = s.thumbRow() else {
                return XCTFail("cardStart \(start) of \(seg.maxStart): no thumb")
            }
            let target = s.jumpTarget(shaftOffset: thumb - s.rect.row - 1)
            XCTAssertEqual(target, start, "cardStart \(start): the thumb is at row \(thumb) and "
                             + "the click goes to \(target)")
        }
    }
}
