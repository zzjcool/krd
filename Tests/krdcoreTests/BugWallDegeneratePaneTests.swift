import XCTest
@testable import krdcore

/// A property sweep of `WallLayout.make` at the panes nobody photographs: **5…25 rows by 10…60
/// columns**, both cell shapes (`cellAspect` 1.0 for an 8x8 cell, 2.0 for the 8x16 / 10x20 / 20x40
/// ones), `per` 1…4, 0/1/3/7/14 windows, 0/1/3 displays, a start both inside *and* past the end of
/// both stacks, and a stage picture that is unknown, 16:9 or 1:2.
///
/// `WallLayoutTests` pins the design's numbers at 137x44, 100x36 and 60x24 — panes where the row
/// budget has room and `clip()` never has work to do. This file is the other end of the same
/// contract: a 5-row pane has no budget at all, a 10-column pane shrinks `per` to 1, `cardStart: 99`
/// lands on the last page, and the divider stops being drawn below 20 rows. Every rule below is a
/// *property* of the layout rather than one answer, so a failure prints all nine numbers of the
/// combination that broke it.
///
/// **The sweep is 1,542,240 combinations and every rule held at all of them** — including the two
/// the fixed panes cannot reach (`per` shrunk by a narrow pane, the card band dropped by a short
/// one) and the exact row budget, `stage.rows + cardBandRows + 6 (+divider) == rows`, which the
/// clamped `footerRow` alone would not catch. `testNineColumnsAndBelow…` then walks the model off
/// its floor at 1–9 columns, `testFourRowsAndBelow…` does the same under 5 rows, and
/// `testTheOneColumnPane…` names the exact cell where it stops.
final class BugWallDegeneratePaneTests: XCTestCase {
    // MARK: the axes

    private let paneRows = Array(5...25)
    private let paneCols = Array(10...60)
    private let cellAspects = [1.0, 2.0]
    private let pers = [1, 2, 3, 4]
    private let windowCounts = [0, 1, 3, 7, 14]
    private let displayCounts = [0, 1, 3]
    /// 0 and "past the end": clamping the starts is part of the contract, not a caller's duty.
    private let starts = [0, 99]
    private let stageAspects: [Double?] = [nil, 1.78, 0.5]

    // MARK: the frozen formulas, restated

    /// `WallLayout.cardWidth` and `cardGap` are `private`/`static` in the layout, so the sweep has to
    /// restate them: the point is to check the layout against the *formula*, not against itself.
    /// Both are copied verbatim from `Sources/krdcore/WallLayout.swift`.
    private func cardWidth(_ content: Int, _ n: Int, gap: Int) -> Int {
        guard n > 0 else { return 0 }
        return (content - (n - 1) * gap) / n
    }

    private func cardGap(_ content: Int) -> Int { max(1, content / 45) }

    /// Every rect the layout hands out, with a name, so a failure says *which* pair clashed.
    private func namedRects(_ l: WallLayout) -> [(String, CellRect)] {
        var out: [(String, CellRect)] = [
            ("stage", l.stage), ("stageCaption", l.stageCaption), ("dividerRow", l.dividerRow),
            ("bar.stage.rect", l.bar.stage.rect), ("bar.cards.rect", l.bar.cards.rect),
        ]
        for (i, r) in l.cards.enumerated() { out.append(("cards[\(i)]", r)) }
        for (i, r) in l.cardCaptions.enumerated() { out.append(("cardCaptions[\(i)]", r)) }
        return out
    }

    /// The three rules that cannot hold at a pane smaller than the constants they describe. They are
    /// on for the whole sweep, and switched off one at a time — never more than the pane forces — by
    /// the two boundary tests at the bottom:
    ///
    /// - `disjoint` / `contentKeepsOffTheBar` at 1 and 2 columns, where `contentCols = max(1, cols -
    ///   2)` leaves no gap column to keep free;
    /// - `exactBudget` below 5 rows, where the six fixed rows do not fit at all.
    private struct Rules {
        var disjoint = true
        var contentKeepsOffTheBar = true
        var exactBudget = true
        static let all = Rules()
    }

    // MARK: the rules

    /// Every rule of the sweep on one combination. Returns one line per broken rule — empty means
    /// the layout is right at this pane. The `XCTAssert`s stay in the tests so the sweep is a loop
    /// over values rather than over messages, and so one failure carries its whole combination.
    private func failures(rows: Int, cols: Int, cellAspect: Double, per: Int, windows: Int,
                          displays: Int, stageStart: Int, cardStart: Int, stageAspect: Double?,
                          rules: Rules = .all) -> [String] {
        var out: [String] = []
        let l = WallLayout.make(paneCols: cols, paneRows: rows, displayCount: displays,
                                windowCount: windows, per: per, stageStart: stageStart,
                                cardStart: cardStart, stageAspect: stageAspect,
                                cellAspect: cellAspect)

        /// Only reached on a failure, so describing the combination costs nothing on the green runs.
        func fail(_ rule: String, _ detail: @autoclosure () -> String) {
            out.append("\(rule) — rows=\(rows) cols=\(cols) cellAspect=\(cellAspect) per=\(per) "
                       + "windows=\(windows) displays=\(displays) stageStart=\(stageStart) "
                       + "cardStart=\(cardStart) stageAspect=\(stageAspect.map { "\($0)" } ?? "nil")"
                       + ": \(detail())")
        }

        let rects = namedRects(l)

        // 1. No negative size, nothing outside the pane, and the pending-wrap cell stays free.
        //    (`clip()` may shorten a band; it may never move one out of the pane or grow it.)
        for (name, r) in rects {
            if r.cols < 0 { fail("negative width", "\(name) \(r)") }
            if r.rows < 0 { fail("negative height", "\(name) \(r)") }
            if r.isEmpty { continue }
            if r.col < 1 || r.row < 1 {
                fail("starts outside the pane", "\(name) col=\(r.col) row=\(r.row)")
            }
            if r.maxRow > l.rows { fail("hangs off the bottom", "\(name) maxRow=\(r.maxRow) rows=\(l.rows)") }
            if r.maxCol > l.cols { fail("hangs off the right", "\(name) maxCol=\(r.maxCol) cols=\(l.cols)") }
            // The renderer stops at this cell and `clip()` gives it away: writing it arms the
            // terminal's pending-wrap, and the next byte scrolls the whole wall one row up.
            if r.contains(row: l.rows, col: l.cols) {
                fail("covers the pending-wrap cell", "\(name) \(r)")
            }
            if name.hasPrefix("bar.") {
                if r.cols != 1 { fail("bar segment is not one cell wide", "\(name) cols=\(r.cols)") }
                if r.col != l.cols { fail("bar segment left the bar column", "\(name) col=\(r.col)") }
            } else if rules.contentKeepsOffTheBar, r.maxCol > l.cols - 2 {
                fail("reaches the bar or its gap column", "\(name) maxCol=\(r.maxCol) cols-2=\(l.cols - 2)")
            }
        }

        // 2. The footer is the last pane row. Asserted blanket rather than "unless rows is small":
        //    the row accounting is done with a cursor, so it holds at every size in the window, and
        //    the boundary test shows it still holds at 1 column.
        if l.footerRow != l.rows {
            fail("the footer is not the last row", "footerRow=\(l.footerRow) rows=\(l.rows)")
        }

        // 3. One caption per card, each directly under its picture (§6.6), never under the band.
        if l.cards.count != l.cardCaptions.count {
            fail("cards and captions disagree", "cards=\(l.cards.count) captions=\(l.cardCaptions.count)")
        }
        for i in 0..<min(l.cards.count, l.cardCaptions.count)
        where l.cardCaptions[i].row != l.cards[i].row + l.cards[i].rows {
            fail("a caption is not directly under its card",
                 "cards[\(i)].row=\(l.cards[i].row) rows=\(l.cards[i].rows) "
                 + "cardCaptions[\(i)].row=\(l.cardCaptions[i].row) "
                 + "expected=\(l.cards[i].row + l.cards[i].rows)")
        }

        // 4. The bar column, the content width and the gap between two cards.
        if l.barCol != l.cols { fail("the bar is not the last column", "barCol=\(l.barCol) cols=\(l.cols)") }
        if l.contentCols != max(1, l.cols - 2) {
            fail("content width is not cols - 2", "contentCols=\(l.contentCols) expected=\(max(1, l.cols - 2))")
        }
        if l.cardGap != cardGap(l.contentCols) {
            fail("the card gap is not cardGap(content)", "cardGap=\(l.cardGap) expected=\(cardGap(l.contentCols))")
        }

        // 5. Each bar segment is exactly its band: same rows, same start row, same item count.
        if l.bar.stage.rect.rows != l.stage.rows || l.bar.stage.rect.row != l.stage.row {
            fail("the stage segment does not cover the stage",
                 "segment=\(l.bar.stage.rect) stage=\(l.stage)")
        }
        if l.bar.cards.rect.rows != l.cardBandRows {
            fail("the card segment does not cover the card band",
                 "segment.rows=\(l.bar.cards.rect.rows) cardBandRows=\(l.cardBandRows)")
        }
        if let first = l.cards.first, l.bar.cards.rect.row != first.row {
            fail("the card segment does not start on the first card",
                 "segment.row=\(l.bar.cards.rect.row) cards[0].row=\(first.row)")
        }
        if l.bar.stage.count != l.displayCount || l.bar.cards.count != l.windowCount {
            fail("a segment counts the wrong stack",
                 "stage.count=\(l.bar.stage.count)/\(l.displayCount) cards.count=\(l.bar.cards.count)/\(l.windowCount)")
        }
        if l.bar.stage.visible != 1 || l.bar.cards.visible != l.per {
            fail("a segment shows the wrong number of items",
                 "stage.visible=\(l.bar.stage.visible) cards.visible=\(l.bar.cards.visible) per=\(l.per)")
        }

        // 6. Pairwise disjoint — the stage, its caption, the divider, every card, every caption and
        //    both bar segments (the two segments must not intersect each other either).
        if rules.disjoint {
            for i in rects.indices {
                for j in rects.index(after: i)..<rects.endIndex where rects[i].1.intersects(rects[j].1) {
                    fail("two rects overlap", "\(rects[i].0) \(rects[i].1) / \(rects[j].0) \(rects[j].1)")
                }
            }
        }

        // 7. The card width is the frozen formula, and one page's cards share one shape. `per` may
        //    have been shrunk by a narrow pane, so the formula is applied with the layout's `per` —
        //    and the shrink itself is checked: it may only happen when the requested `per` really
        //    cannot reach `minCardCols`.
        let expectedWidth = cardWidth(l.contentCols, l.per, gap: l.cardGap)
        for (i, c) in l.cards.enumerated() where !c.isEmpty {
            if c.cols != expectedWidth {
                fail("card width is not cardWidth(content, per, gap)",
                     "cards[\(i)].cols=\(c.cols) expected=\(expectedWidth) "
                     + "content=\(l.contentCols) per=\(l.per) gap=\(l.cardGap)")
            }
            if let first = l.cards.first, c.cols != first.cols || c.rows != first.rows || c.row != first.row {
                fail("the page's cards do not share one shape", "cards[\(i)]=\(c) cards[0]=\(first)")
            }
            if l.cardCaptions.indices.contains(i),
               l.cardCaptions[i].col != c.col || l.cardCaptions[i].cols != c.cols {
                fail("a caption is not the width of its card", "cardCaptions[\(i)]=\(l.cardCaptions[i]) card=\(c)")
            }
            if c.rows < WallLayout.minCardRows { fail("a drawn card is under the height floor", "cards[\(i)].rows=\(c.rows)") }
            if c.rows > l.cardBandRows { fail("a card is taller than its band", "cards[\(i)].rows=\(c.rows) band=\(l.cardBandRows)") }
        }
        if l.per < 1 { fail("per below one", "per=\(l.per)") }
        if l.per != max(1, per) {
            let requested = cardWidth(l.contentCols, max(1, per), gap: l.cardGap)
            if requested >= WallLayout.minCardCols {
                fail("per shrank although the requested per still fits",
                     "per=\(l.per) requested=\(max(1, per)) cardWidth=\(requested) floor=\(WallLayout.minCardCols)")
            }
        }

        // 8. The row budget: the stage never takes more than the budget leaves, the divider is
        //    drawn iff the pane is tall enough for it (`wantsDivider = rows >= 20` in the layout,
        //    restated here), and the bands spend the budget exactly — `stage + cardBandRows + 6
        //    (+divider)`, or `stage + 5 (+divider)` in a pane with no band at all.
        let wantsDivider = rows >= 20
        let budget = max(0, rows - (wantsDivider ? 6 : 5))
        let divider = l.dividerRow.isEmpty ? 0 : 1
        if l.stage.rows > budget {
            fail("the stage is taller than the row budget", "stage.rows=\(l.stage.rows) budget=\(budget)")
        }
        if wantsDivider == l.dividerRow.isEmpty {
            fail("the divider is drawn iff rows >= 20", "rows=\(rows) dividerEmpty=\(l.dividerRow.isEmpty)")
        }
        let fixedRows = 6 + divider
        if let first = l.cards.first, l.stage.rows + first.rows + fixedRows > rows {
            fail("the bands do not fit",
                 "stage=\(l.stage.rows) + card=\(first.rows) + fixed=\(fixedRows) = "
                 + "\(l.stage.rows + first.rows + fixedRows) > rows=\(rows)")
        }
        let spent = l.cards.isEmpty ? l.stage.rows + 5 + divider
                                    : l.stage.rows + l.cardBandRows + 6 + divider
        if rules.exactBudget, spent != rows {
            fail("the budget is not spent", "spent=\(spent) rows=\(rows) stage=\(l.stage.rows) "
                 + "band=\(l.cardBandRows) divider=\(divider) cards=\(l.cards.count)")
        }

        // 9. The page: `cardStart` clamped into the window list, at most `per` cards, and a full
        //    page unless the stack ends first.
        let clampedStart = min(max(cardStart, 0), max(0, windows - l.per))
        if l.cardStart != clampedStart {
            fail("cardStart is not clamped the way the page needs",
                 "cardStart=\(l.cardStart) expected=\(clampedStart) windows=\(windows) per=\(l.per)")
        }
        if l.windowCount != max(0, windows) || l.displayCount != max(0, displays) {
            fail("a count was not floored at zero",
                 "windows=\(l.windowCount)/\(windows) displays=\(l.displayCount)/\(displays)")
        }
        if l.stageStart != min(max(stageStart, 0), max(0, l.displayCount - 1)) {
            fail("stageStart is not clamped into the display list",
                 "stageStart=\(l.stageStart) displays=\(l.displayCount)")
        }
        if l.cards.count > l.per {
            fail("a page is wider than per", "cards=\(l.cards.count) per=\(l.per)")
        }
        if l.windowCount > 0 && l.cardBandRows > 0 {
            let page = max(0, min(l.per, l.windowCount - l.cardStart))
            if l.cards.count != page {
                fail("the page is not min(per, windows - cardStart)",
                     "cards=\(l.cards.count) expected=\(page) per=\(l.per) "
                     + "windows=\(l.windowCount) cardStart=\(l.cardStart)")
            }
        } else if !l.cards.isEmpty || !l.cardCaptions.isEmpty {
            fail("a page without a band", "cards=\(l.cards.count) captions=\(l.cardCaptions.count) "
                 + "band=\(l.cardBandRows) windows=\(l.windowCount)")
        }

        return out
    }

    // MARK: the sweep

    /// The sweep itself: nine nested loops, ~1.5 million panes, all nine rule groups above. The
    /// nested loop *is* the "no trap" assertion — a `max(0, …)` that lost its `max` would crash
    /// this test rather than fail it.
    func testEveryCombinationOfTheSweepKeepsEveryInvariant() {
        var sample: [String] = []
        var broken = 0
        var combinations = 0

        for rows in paneRows {
            for cols in paneCols {
                for cellAspect in cellAspects {
                    for per in pers {
                        for windows in windowCounts {
                            for displays in displayCounts {
                                for stageStart in starts {
                                    for cardStart in starts {
                                        for stageAspect in stageAspects {
                                            combinations += 1
                                            let found = failures(
                                                rows: rows, cols: cols, cellAspect: cellAspect,
                                                per: per, windows: windows, displays: displays,
                                                stageStart: stageStart, cardStart: cardStart,
                                                stageAspect: stageAspect)
                                            broken += found.count
                                            if sample.count < 20 { sample += found.prefix(20 - sample.count) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        let expected = paneRows.count * paneCols.count * cellAspects.count * pers.count
            * windowCounts.count * displayCounts.count * starts.count * starts.count
            * stageAspects.count
        XCTAssertEqual(combinations, expected, "every combination of the axes ran exactly once")
        XCTAssertTrue(sample.isEmpty,
                      "\(broken) broken rules over \(combinations) combinations; first "
                      + "\(sample.count):\n" + sample.joined(separator: "\n"))
    }

    /// A green sweep is only evidence if the rules can go red. Here that is pinned with the sweep's
    /// own `failures` call: at one column it returns the overlap and the barred-column rules (the
    /// stage and the bar share a cell, the content is on the bar column), and ten columns further
    /// right — the sweep's floor — the same call returns none.
    func testTheRulesFireWhereTheModelBreaksAndOnlyThere() {
        let broken = failures(rows: 17, cols: 1, cellAspect: 2.0, per: 3, windows: 14,
                              displays: 3, stageStart: 0, cardStart: 0, stageAspect: nil)
        XCTAssertFalse(broken.isEmpty, "the rules never fire — the sweep below would be vacuous")
        XCTAssertTrue(broken.contains { $0.hasPrefix("two rects overlap") },
                      "a 1-column pane puts the stage on the bar column, and the rules must say "
                      + "so:\n" + broken.joined(separator: "\n"))
        XCTAssertTrue(broken.contains { $0.hasPrefix("reaches the bar or its gap column") },
                      "content is floored at one column, so it cannot miss the bar there:\n"
                      + broken.joined(separator: "\n"))
        XCTAssertEqual(failures(rows: 17, cols: 10, cellAspect: 2.0, per: 3, windows: 14,
                                displays: 3, stageStart: 0, cardStart: 0, stageAspect: nil),
                       [], "the same call is silent at the sweep's floor")
    }

    /// The sweep is 1.5 million panes, so it has to be shown that they are not 1.5 million *easy*
    /// panes: every branch of the row budget, the `per` shrink and the page has to be visited, and
    /// the numbers below are the count of panes that took each one (a coarser product than the sweep
    /// — the count is what matters, not a second run of the rules).
    func testTheSweepVisitsEveryDegenerateBranch() {
        var shrunkPer = 0, perDownToOne = 0, bandDropped = 0, noStageAtAll = 0
        var dividerDrawn = 0, dividerDropped = 0, aspectShrankTheStage = 0
        var cardShorterThanBand = 0, cardFillsBand = 0, emptyBarSegment = 0
        var partialPage = 0, clampedCardStart = 0, stageClampedStart = 0

        for rows in paneRows {
            for cols in paneCols {
                for cellAspect in cellAspects {
                    for per in pers {
                        for windows in windowCounts {
                            for stageAspect in stageAspects {
                                for cardStart in starts {
                                    let l = WallLayout.make(
                                        paneCols: cols, paneRows: rows, displayCount: 3,
                                        windowCount: windows, per: per, stageStart: 99,
                                        cardStart: cardStart, stageAspect: stageAspect,
                                        cellAspect: cellAspect)
                                    if l.per < per { shrunkPer += 1 }
                                    if l.per == 1 && per > 1 { perDownToOne += 1 }
                                    if windows > 0 && l.cardBandRows == 0 { bandDropped += 1 }
                                    if l.stage.rows == 0 { noStageAtAll += 1 }
                                    if l.dividerRow.isEmpty { dividerDropped += 1 } else { dividerDrawn += 1 }
                                    if l.bar.cards.rect.isEmpty || l.bar.stage.rect.isEmpty { emptyBarSegment += 1 }
                                    if l.cards.count < l.per { partialPage += 1 }
                                    if cardStart > 0 && l.cardStart != cardStart { clampedCardStart += 1 }
                                    if l.stageStart != 99 { stageClampedStart += 1 }
                                    if let first = l.cards.first {
                                        if first.rows < l.cardBandRows { cardShorterThanBand += 1 }
                                        if first.rows == l.cardBandRows { cardFillsBand += 1 }
                                    }
                                    if stageAspect != nil, l.cardBandRows > 0 {
                                        let base = WallLayout.make(
                                            paneCols: cols, paneRows: rows, displayCount: 3,
                                            windowCount: windows, per: per, stageStart: 99,
                                            cardStart: cardStart, stageAspect: nil,
                                            cellAspect: cellAspect)
                                        if l.stage.rows < base.stage.rows { aspectShrankTheStage += 1 }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // A pane where the requested `per` does not fit, and one where it does not even fit two.
        XCTAssertGreaterThan(shrunkPer, 0, "no pane in the sweep shrinks per")
        XCTAssertGreaterThan(perDownToOne, 0, "no pane in the sweep shrinks per to 1")
        // No budget at all (5 rows), and a card band that is dropped although there are windows.
        XCTAssertGreaterThan(bandDropped, 0, "no pane in the sweep drops the card band")
        XCTAssertGreaterThan(noStageAtAll, 0, "no pane in the sweep has no stage rows")
        // Both sides of the `rows >= 20` divider rule, both sides of the picture-fits-the-band rule.
        XCTAssertGreaterThan(dividerDrawn, 0, "no pane in the sweep is tall enough for the divider")
        XCTAssertGreaterThan(dividerDropped, 0, "every pane in the sweep draws the divider")
        XCTAssertGreaterThan(aspectShrankTheStage, 0, "a stage aspect never shrank a stage")
        XCTAssertGreaterThan(cardShorterThanBand, 0, "no card is shorter than its band")
        XCTAssertGreaterThan(cardFillsBand, 0, "no card fills its band")
        // Bands that vanish entirely, pages that end early, starts that clamp.
        XCTAssertGreaterThan(emptyBarSegment, 0, "no pane in the sweep has an empty bar segment")
        XCTAssertGreaterThan(partialPage, 0, "every page in the sweep is full")
        XCTAssertGreaterThan(clampedCardStart, 0, "cardStart 99 is never clamped")
        XCTAssertGreaterThan(stageClampedStart, 0, "stageStart 99 is never clamped")
    }

    /// The floor of the model, stepped off one pane width at a time.
    ///
    /// `contentCols` is `max(1, cols - 2)`, so a **3-column** pane still has one content column, one
    /// gap column and the bar; a **2-column** pane spends the gap column (content is column 1, the
    /// bar column 2 — no overlap, but `cols - 2` is no longer where the content stops); and a
    /// **1-column** pane has nothing left: the content column *is* the bar column. Those two are the
    /// only rules below that get switched off, and only for `cols <= 2`; everything else — no trap,
    /// no negative size, nothing outside the pane, the pending-wrap cell free, the footer on the
    /// last row, the budget spent exactly, the page the size of `per` — must survive all the way
    /// down to one column, which is what this test says.
    func testNineColumnsAndBelowKeepEveryRuleButTheBarColumn() {
        var sample: [String] = []
        var broken = 0
        for rows in paneRows {
            for cols in 1...9 {
                for cellAspect in cellAspects {
                    for per in pers {
                        for windows in windowCounts {
                            for stageAspect in stageAspects {
                                let found = failures(
                                    rows: rows, cols: cols, cellAspect: cellAspect, per: per,
                                    windows: windows, displays: 3, stageStart: 0, cardStart: 0,
                                    stageAspect: stageAspect,
                                    rules: Rules(disjoint: cols > 1,
                                                 contentKeepsOffTheBar: cols > 2))
                                broken += found.count
                                if sample.count < 20 { sample += found.prefix(20 - sample.count) }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertTrue(sample.isEmpty,
                      "\(broken) broken rules at 1…9 columns; first \(sample.count):\n"
                      + sample.joined(separator: "\n"))
    }

    /// Where the model stops, with the numbers spelled out instead of swept.
    ///
    /// At one column `contentCols` is floored to 1 and `barCol` is 1 as well, so `stage` and
    /// `bar.stage.rect` are the *same cell*, and every card shares its column with
    /// `bar.cards.rect`. That overlap is reported, not pinned: `WallLayout` states its contract for
    /// hostile sizes as "merely useless, never fatal", and this pane is outside the sweep's window
    /// (10 columns). What keeps it survivable — and what this test does assert — is that nothing
    /// traps or leaves the pane, the pending-wrap cell stays free, the card band and the page are
    /// still the page of `per`, and `action` gives the contested column to the bar (it checks
    /// `barCol` first), so the wall still scrolls. At two columns the content and the bar already
    /// miss each other again.
    func testTheOneColumnPaneIsWhereTheContentMeetsTheBarColumn() {
        let one = WallLayout.make(paneCols: 1, paneRows: 17, displayCount: 3, windowCount: 14,
                                  per: 3, stageStart: 0, cardStart: 0)
        XCTAssertEqual(one.cols, 1)
        XCTAssertEqual(one.contentCols, 1, "content is floored at one column")
        XCTAssertEqual(one.barCol, 1, "…and at one column that column is also the bar column")
        XCTAssertEqual(one.per, 1, "a 1-cell card is still a card: per shrinks to 1, never to 0")
        XCTAssertEqual(one.cards.count, 1, "the page still holds min(per, windows) cards")
        XCTAssertEqual(one.cards[0].cols, 1)
        XCTAssertEqual(one.cardBandRows, 3, "the card band still gets its rows")
        XCTAssertEqual(one.footerRow, 17, "the footer is still the last row")
        XCTAssertEqual(one.bar.stage.rect.cols, 1, "the stage segment is still one cell wide")
        XCTAssertEqual(one.action(row: one.stage.row, col: 1), .stageStep(-1),
                       "the contested column scrolls the stage instead of entering it")
        for (name, r) in namedRects(one) {
            XCTAssertGreaterThanOrEqual(r.cols, 0, "\(name) width")
            XCTAssertGreaterThanOrEqual(r.rows, 0, "\(name) height")
            guard !r.isEmpty else { continue }
            XCTAssertLessThanOrEqual(r.maxRow, one.rows, "\(name) hangs off the bottom")
            XCTAssertLessThanOrEqual(r.maxCol, one.cols, "\(name) hangs off the right")
            XCTAssertFalse(r.contains(row: one.rows, col: one.cols),
                           "\(name) writes the pending-wrap cell")
        }

        let two = WallLayout.make(paneCols: 2, paneRows: 17, displayCount: 3, windowCount: 14,
                                  per: 3, stageStart: 0, cardStart: 0)
        XCTAssertEqual(two.contentCols, 1)
        XCTAssertEqual(two.barCol, 2)
        XCTAssertEqual(two.stage.maxCol, 1, "two columns are already enough for content and bar")
        XCTAssertLessThan(two.stage.maxCol, two.barCol, "…to miss each other")
        XCTAssertFalse(two.stage.intersects(two.bar.stage.rect))
        XCTAssertFalse(two.cards.isEmpty)
        XCTAssertFalse(two.cards[0].intersects(two.bar.cards.rect), "and the cards miss the bar too")
    }

    /// The other end of the row budget: **1…4 rows**, where the six fixed rows (header, stage
    /// caption, band header, card caption, blank, footer) do not fit at all. That is the case the
    /// footer rule is phrased with an escape clause for — "unless rows is so small the constants
    /// cannot fit" — and the clause never fires: the cursor runs one row past the pane and
    /// `footerRow = min(rows, row)` puts the footer back on the last row, so a 1-row pane is still a
    /// wall whose footer is row 1. Only the *spend* changes (there is nowhere to spend a budget of
    /// zero), which is the one rule switched off here. Everything else is asked exactly as the
    /// sweep asks it: no trap, no negative size, nothing outside the pane, the pending-wrap cell
    /// free, the bar one cell wide or absent, the segments counting their stacks, the columns and
    /// the page.
    func testFourRowsAndBelowClampTheFooterInsteadOfOverflowing() {
        var sample: [String] = []
        var broken = 0
        var panes = 0
        for rows in 1...4 {
            for cols in paneCols {
                for cellAspect in cellAspects {
                    for per in pers {
                        for windows in windowCounts {
                            for stageAspect in stageAspects {
                                panes += 1
                                let l = WallLayout.make(
                                    paneCols: cols, paneRows: rows, displayCount: 3,
                                    windowCount: windows, per: per, stageStart: 99,
                                    cardStart: 99, stageAspect: stageAspect, cellAspect: cellAspect)
                                XCTAssertEqual(l.footerRow, rows,
                                               "the footer is the last row even at rows=\(rows) "
                                               + "cols=\(cols) windows=\(windows)")
                                XCTAssertEqual(l.stage.rows, 0,
                                               "rows=\(rows): there is no budget for a stage")
                                XCTAssertEqual(l.cardBandRows, 0,
                                               "rows=\(rows): there is no budget for a band")
                                let found = failures(
                                    rows: rows, cols: cols, cellAspect: cellAspect, per: per,
                                    windows: windows, displays: 3, stageStart: 99, cardStart: 99,
                                    stageAspect: stageAspect,
                                    rules: Rules(exactBudget: false))
                                broken += found.count
                                if sample.count < 20 { sample += found.prefix(20 - sample.count) }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(panes, 0)
        XCTAssertTrue(sample.isEmpty,
                      "\(broken) broken rules at 1…4 rows over \(panes) panes; first "
                      + "\(sample.count):\n" + sample.joined(separator: "\n"))
    }
}
