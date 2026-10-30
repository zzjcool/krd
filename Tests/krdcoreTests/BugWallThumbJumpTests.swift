import XCTest
@testable import krdcore

/// A drawn thumb that does not answer for its own position.
///
/// `WallLayout.WallBar.Segment` is a proportional scrollbar: `thumbRow()` maps `start` to a cell of
/// the shaft and `jumpTarget(shaftOffset:)` is documented as *the inverse of `thumbRow()`* — a click
/// on the cell the thumb is drawn on makes that page the new start.
///
/// The inverse is only implemented for `shaftCount >= 2`; `jumpTarget` returns `0` for a one-cell
/// shaft, while `thumbRow` still draws a thumb there (it has an explicit `shaftCount == 1` branch).
/// A 3-row segment therefore shows `▲`, one `█` and `▼`, and clicking the `█` jumps to the first
/// page wherever the shelf actually is — a control that says "you are here" and answers "go to the
/// start" (design §5: no cell the user can click that does not do what it looks like).
final class BugWallThumbJumpTests: XCTestCase {
    /// `WallLayout.action` refuses to look at a bar cell that is not in the bar column, so the
    /// click is asked exactly the way a real click asks it.
    private func action(_ l: WallLayout, row: Int) -> WallAction? {
        l.action(row: row, col: l.barCol)
    }

    /// The invariant: if a thumb is drawn, clicking the cell it occupies must not move the segment
    /// away from the position that thumb is showing. Where several starts share one cell (fewer
    /// shaft cells than positions) the nearest one wins, so the assertion is "not a *different*
    /// page that the thumb cannot be showing" only for the one-cell shaft, where `thumbRow` cannot
    /// distinguish any two positions at all: every `start` draws the same cell, so the click owes
    /// the reader `start` (or nothing), never page 0.
    func testOneCellShaftDoesNotLieAboutItsPosition() {
        var failures: [String] = []
        var reached = 0
        var checked = 0
        var firstPane: (cols: Int, rows: Int, start: Int, thumb: Int, got: WallAction?)?

        for cols in 10...60 {
            for rows in 5...25 {
                for windows in [2, 3, 7, 14] {
                    for per in [1, 2, 3, 4] {
                        // The last page, so the thumb is drawn somewhere other than the top.
                        let start = max(0, windows - per)
                        guard start > 0 else { continue }
                        let l = WallLayout.make(paneCols: cols, paneRows: rows, displayCount: 3,
                                                windowCount: windows, per: per,
                                                stageStart: 0, cardStart: start)
                        let seg = l.bar.cards
                        guard seg.scrollable, seg.rect.rows == 3, seg.start > 0 else { continue }
                        // The segment exists. Count it before any thumb decision, so "no thumb
                        // drawn" (fix (a) for #135: `thumbRow` returns nil when the shaft has one
                        // cell - but note `WallLayoutTests.testThumbAndJumpAreInverse` (:617) pins today's
                        // behaviour, so (a) has to revisit that test too) still proves the sweep
                        // reached the case instead of silently asserting nothing.
                        reached += 1
                        // Fix (b) is the other way out: the cell stays inert or keeps the page.
                        // Red only while a thumb IS drawn at a cell whose click goes somewhere the
                        // thumb cannot be showing.
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
        if let f = firstPane {
            print("smallest 3-row card segment: \(f.cols)x\(f.rows) cardStart \(f.start), "
                  + "thumb row \(f.thumb), click -> \(String(describing: f.got))")
        }
        XCTAssertEqual(failures.count, 0,
                       "a thumb is drawn on a segment whose click cannot answer for it: "
                         + "\(failures.count) of \(checked) three-row segments jump to the first "
                         + "page from the last one. First 4: \(failures.prefix(4))")
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
