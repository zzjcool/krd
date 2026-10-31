import XCTest
@testable import krdcore

/// The row budget, the bar and the hit table of the landing screen (`--wall`), pinned.
///
/// The geometry is checked two ways on purpose. The `testPinned…` cases are the numbers from
/// `docs/design-overview.zh-CN.md` §6.5 (137x44 / per 3 -> 44 wide, 14 tall, 24 rows of stage), so a
/// changed formula fails on a value a human can compare with the design. The nested loop is the
/// other half: it asserts *invariants* over every pane / per / window-count / start combination,
/// because a formula change that keeps one size right usually breaks a different one — that is how
/// a bar ends up on the final cell of the final row, or a caption ends up two rows tall.
final class WallLayoutTests: XCTestCase {
    /// The three pane widths the design and the mockup are read at: 137 columns is a full-screen
    /// terminal, 60 is a laptop window, 100 is in between.
    private let panes: [(cols: Int, rows: Int)] = [(137, 44), (100, 36), (60, 24)]
    private let pers = [2, 3, 4]
    private let windowCounts = [0, 1, 7, 14]
    /// Includes an out-of-range start: clamping is part of the contract, not a caller duty.
    private let starts: [(stage: Int, card: Int)] = [(0, 0), (2, 5), (99, 99)]
    /// Three displays: the stage scrolls, which is what makes the bar testable at all.
    private let displays = 3

    private func layout(_ cols: Int, _ rows: Int, windows: Int = 14, per: Int = 3,
                        displays: Int? = nil, stageStart: Int = 0, cardStart: Int = 0,
                        stageAspect: Double? = nil,
                        cellAspect: Double = WallLayout.cellAspect) -> WallLayout {
        WallLayout.make(paneCols: cols, paneRows: rows, displayCount: displays ?? self.displays,
                        windowCount: windows, per: per, stageStart: stageStart, cardStart: cardStart,
                        stageAspect: stageAspect, cellAspect: cellAspect)
    }

    /// Every rect the layout hands out, with a name, so a failure says *which* pair clashed.
    private func namedRects(_ l: WallLayout) -> [(String, CellRect)] {
        var out: [(String, CellRect)] = [
            ("stage", l.stage), ("stageCaption", l.stageCaption),
            ("bar.stage", l.bar.stage.rect), ("bar.cards", l.bar.cards.rect),
        ]
        for (i, r) in l.cards.enumerated() { out.append(("cards[\(i)]", r)) }
        for (i, r) in l.cardCaptions.enumerated() { out.append(("cardCaptions[\(i)]", r)) }
        return out
    }

    /// The invariants that must hold at *every* pane size. Kept in one place so the nested loop and
    /// the focused tests cannot drift apart; every message names its rule.
    private func assertStructural(_ l: WallLayout, _ label: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(l.barCol, l.cols, "\(label): the bar is the last column", file: file, line: line)
        XCTAssertEqual(l.contentCols, max(1, l.cols - 2), "\(label): content is cols - 2", file: file, line: line)
        XCTAssertEqual(l.headerRow, 1, "\(label): the header is row 1", file: file, line: line)
        XCTAssertEqual(l.footerRow, l.rows, "\(label): the footer is the last row", file: file, line: line)
        XCTAssertEqual(l.cardCaptions.count, l.cards.count,
                       "\(label): every card has exactly one caption", file: file, line: line)

        for (name, r) in namedRects(l) {
            XCTAssertGreaterThanOrEqual(r.cols, 0, "\(label): \(name) has a negative width", file: file, line: line)
            XCTAssertGreaterThanOrEqual(r.rows, 0, "\(label): \(name) has a negative height", file: file, line: line)
            guard !r.isEmpty else { continue }
            XCTAssertGreaterThanOrEqual(r.col, 1, "\(label): \(name) starts left of the pane", file: file, line: line)
            XCTAssertGreaterThanOrEqual(r.row, 1, "\(label): \(name) starts above the pane", file: file, line: line)
            XCTAssertLessThanOrEqual(r.maxRow, l.rows, "\(label): \(name) hangs off the bottom", file: file, line: line)
            XCTAssertLessThanOrEqual(r.maxCol, l.cols, "\(label): \(name) hangs off the right", file: file, line: line)
            XCTAssertFalse(r.contains(row: l.rows, col: l.cols),
                           "\(label): \(name) covers the pending-wrap cell", file: file, line: line)
            if name.hasPrefix("bar") {
                XCTAssertEqual(r.col, l.barCol, "\(label): \(name) is not on the bar column", file: file, line: line)
                XCTAssertEqual(r.cols, 1, "\(label): \(name) is not one cell wide", file: file, line: line)
            } else {
                XCTAssertLessThanOrEqual(r.maxCol, l.cols - 2,
                                         "\(label): \(name) reaches the bar or its gap column", file: file, line: line)
            }
        }

        let rects = namedRects(l)
        for i in rects.indices {
            for j in rects.index(after: i)..<rects.endIndex {
                XCTAssertFalse(rects[i].1.intersects(rects[j].1),
                               "\(label): \(rects[i].0) overlaps \(rects[j].0)", file: file, line: line)
            }
        }

        // A page is `per` cards per row times the rows of them the band fits, and the cards of one
        // page share a width and a height: a caption sits directly under its own picture (§6.5 one
        // height per row, §6.6 the caption under the picture, #83 the rows).
        XCTAssertEqual(l.capacity, l.per * max(1, l.cardRowCount),
                       "\(label): a page is per x cardRowCount", file: file, line: line)
        if l.cardRowCount > 0 {
            XCTAssertEqual(l.cards.count, min(l.capacity, max(0, l.windowCount - l.cardStart)),
                           "\(label): a page holds capacity cards (or the rest of the shelf)", file: file, line: line)
        } else {
            XCTAssertEqual(l.cards.count, 0, "\(label): no band, no cards", file: file, line: line)
        }
        XCTAssertLessThanOrEqual((l.cards.count + l.per - 1) / l.per, max(1, l.cardRowCount),
                                 "\(label): the page needs more rows than the band has", file: file, line: line)
        for (i, card) in l.cards.enumerated() {
            XCTAssertEqual(card.cols, l.cards[0].cols, "\(label): cards[\(i)] has its own width", file: file, line: line)
            XCTAssertEqual(card.rows, l.cards[0].rows, "\(label): cards[\(i)] has its own height", file: file, line: line)
            // Row-major: card `i` sits on row `i / per` of the page, one caption row apart.
            XCTAssertEqual(card.row, l.cards[0].row + (i / l.per) * (l.cards[0].rows + 1),
                           "\(label): cards[\(i)] is not on row \(i / l.per) of the page", file: file, line: line)
            XCTAssertEqual(l.cardCaptions[i].row, card.maxRow + 1,
                           "\(label): cardCaptions[\(i)] is not directly under its card", file: file, line: line)
            XCTAssertEqual(l.cardCaptions[i].col, card.col, "\(label): cardCaptions[\(i)] is not under its card", file: file, line: line)
            // The whole stack lives in the card section: no card above the band header, no caption
            // below the section's own last row (that row is the bar segment's `maxRow + 1`).
            if !l.bar.cards.rect.isEmpty {
                XCTAssertGreaterThanOrEqual(card.row, l.bar.cards.rect.row,
                                            "\(label): cards[\(i)] starts above the card section", file: file, line: line)
                XCTAssertLessThanOrEqual(l.cardCaptions[i].maxRow, l.bar.cards.rect.maxRow + 1,
                                         "\(label): cardCaptions[\(i)] ends below the card section", file: file, line: line)
            }
        }
    }

    // MARK: the design's numbers

    /// The seven rows of the task's table. Every one of them comes out of the frozen algorithm;
    /// if any of these disagree, the formula is wrong, not the design.
    func testPinnedGeometryMatchesTheDesignTable() {
        // The row split is 7 parts display to 3 parts shelf (his rule: "上面桌面 7, 下面窗口 3"),
        // so the stage height is round(0.7 * budget) and the cards get what is left, minus their
        // caption row. The card width still follows the pane (`cardWidth`) and no longer decides the
        // card *height*: a short pane keeps three readable cards instead of a tall one.
        let pinned: [(cols: Int, rows: Int, per: Int, winW: Int, cardH: Int, stageH: Int)] = [
            (137, 44, 3, 43, 10, 27),
            (137, 44, 2, 66, 10, 27),
            (137, 44, 4, 31, 10, 27),
            (100, 36, 3, 31, 8, 21),
            (60, 24, 2, 28, 4, 13),
            (60, 24, 3, 18, 4, 13),
            (60, 24, 4, 13, 4, 13),
        ]
        for p in pinned {
            let l = layout(p.cols, p.rows, windows: 14, per: p.per)
            let label = "\(p.cols)x\(p.rows) per=\(p.per)"
            XCTAssertEqual(l.per, p.per, "\(label): per was shrunk although the card still fits")
            XCTAssertEqual(l.cards.first?.cols ?? -1, p.winW, "\(label): card width")
            XCTAssertEqual(l.cards.first?.rows ?? -1, p.cardH, "\(label): card height")
            XCTAssertEqual(l.stage.rows, p.stageH, "\(label): stage height")
            // The budget is fully spent: header + stage + caption + divider + band + cards +
            // captions + footer. The divider only exists in panes tall enough for it (rows >= 20).
            let divider = l.dividerRow.isEmpty ? 0 : 1
            XCTAssertEqual(l.stage.rows + p.cardH + 6 + divider, p.rows,
                           "\(label): the row budget is not spent")
        }
    }

    /// The width -> height table from contract §2B: 44 -> 14, 67 -> 21, 33 -> 10, 28 -> 9, 18 -> 6,
    /// 13 -> 4. 44 / (1.62 * 2 cells) = 13.58 -> 14 is the design's "44 cells wide, 14 rows tall".
    func testCardHeightFollowsTheAspectRatio() {
        for (winW, cardH) in [(44, 14), (67, 21), (33, 10), (28, 9), (18, 6), (13, 4)] {
            let rows = max(WallLayout.minCardRows,
                           Int((Double(winW) / (WallLayout.cardAspect * WallLayout.cellAspect)).rounded()))
            XCTAssertEqual(rows, cardH, "\(winW) cells is \(cardH) rows")
        }
        // The table above is the card's *ideal* height, which is what a tall pane uses: there the
        // card band takes the rows the stage does not need and the cards widen to fill them. In a
        // 44-row pane the band is the 3 of the 7:3 split instead, so the cards are 43 cells wide and
        // 10 rows tall - the picture inside keeps its own aspect and is width-limited.
        let card = layout(137, 44, windows: 14, per: 3).cards[0]
        XCTAssertEqual(card.cols, 43)
        XCTAssertEqual(card.rows, 10)
    }

    /// The row budget, band by band, against the table in contract §2B. A cursor that skips the
    /// card band still has to land the caption and the footer on their own rows.
    func testRowBudgetFollowsTheDesignTable() {
        for pane in panes {
            for per in pers {
                let l = layout(pane.cols, pane.rows, windows: 14, per: per)
                let label = "\(pane.cols)x\(pane.rows) per=\(per)"
                let stageH = l.stage.rows
                let cardH = l.cardBandRows
                XCTAssertEqual(l.headerRow, 1, "\(label): header")
                XCTAssertEqual(l.stage.row, 2, "\(label): stage top")
                let divider = l.dividerRow.isEmpty ? 0 : 1
                XCTAssertEqual(l.stageCaption.row, 2 + stageH, "\(label): stage caption")
                XCTAssertEqual(l.dividerRow.row, 3 + stageH, "\(label): divider")
                XCTAssertEqual(l.bandRow, 3 + stageH + divider, "\(label): band header")
                // The stack of card rows is centred in the section: the leftover of `cardH + 1`
                // rows is split above and below it, the odd row going to the bottom (§6.7).
                let section = l.cardBandRows + 1
                let used = l.cardRowCount * (l.cards[0].rows + 1)
                let top = 4 + stageH + divider + max(0, (section - used) / 2)
                XCTAssertEqual(l.cards[0].row, top, "\(label): cards")
                XCTAssertEqual(l.cardCaptions[0].row, top + l.cards[0].rows,
                               "\(label): a caption sits under its picture, not under the band")
                XCTAssertEqual(l.footerRow, 6 + stageH + cardH + divider, "\(label): footer")
                XCTAssertEqual(l.footerRow, pane.rows, "\(label): footer == last row")
                XCTAssertEqual(l.bar.stage.rect, CellRect(col: pane.cols, row: 2, cols: 1, rows: stageH),
                               "\(label): the stage segment covers the stage")
                XCTAssertEqual(l.bar.cards.rect,
                               CellRect(col: pane.cols, row: 4 + stageH + divider, cols: 1, rows: cardH),
                               "\(label): the card segment covers the cards")
                XCTAssertEqual(l.bar.cards.visible, l.capacity,
                               "\(label): the segment's track counts whole pages")
                // Each row of the page is centred on its own, so a partial last row keeps its slots
                // and does not depend on how full the rows above it are.
                for rowIndex in 0..<max(1, l.cardRowCount) {
                    let inRow = min(l.per, l.cards.count - rowIndex * l.per)
                    guard inRow >= 1 else { continue }
                    let rowW = inRow * l.cards[0].cols + max(0, inRow - 1) * l.cardGap
                    let startCol = 1 + max(0, (l.contentCols - rowW) / 2)
                    XCTAssertEqual(Array(l.cards[(rowIndex * l.per)..<(rowIndex * l.per + inRow)].map(\.col)),
                                   (0..<inRow).map { startCol + $0 * (l.cards[0].cols + l.cardGap) },
                                   "\(label): row \(rowIndex): one gap between cards, the row centred in the band")
                }
            }
        }
        // No card band: the two card rows vanish and the footer moves up by two.
        let noCards = layout(137, 8, windows: 14, per: 3)
        XCTAssertEqual(noCards.cards.count, 0)
        XCTAssertEqual(noCards.stage.rows + 5, 8, "no band: 5 fixed rows + the stage")
        XCTAssertEqual(noCards.footerRow, 5 + noCards.stage.rows)
        XCTAssertEqual(noCards.footerRow, 8)
        XCTAssertEqual(noCards.bar.cards.rect.rows, 0, "no band: the card segment does not exist")
    }

    // MARK: the loop

    /// Contract §3B: pane x per x windowCount x start, asserting invariants rather than 48 answers.
    func testEveryGeometryKeepsTheStructuralInvariants() {
        for pane in panes {
            for per in pers {
                for windows in windowCounts {
                    for start in starts {
                        let l = layout(pane.cols, pane.rows, windows: windows, per: per,
                                       stageStart: start.stage, cardStart: start.card)
                        let label = "\(pane.cols)x\(pane.rows) per=\(per) windows=\(windows) start=\(start)"
                        assertStructural(l, label)

                        XCTAssertLessThanOrEqual(l.cards.count, l.capacity, "\(label): a page is at most capacity cards")
                        if let cardH = l.cards.first?.rows, cardH > 0 {
                            XCTAssertEqual(l.cards.count,
                                           max(0, min(l.capacity, l.windowCount - l.cardStart)),
                                           "\(label): a full page (or a partial last one)")
                        } else {
                            XCTAssertEqual(l.cards.count, 0, "\(label): no band, no cards")
                            XCTAssertEqual(l.cardCaptions.count, 0, "\(label): no band, no captions")
                        }
                        XCTAssertEqual(l.windowCount, windows)
                        XCTAssertEqual(l.displayCount, displays)
                        // +1 when the divider row exists: it is one of the fixed rows too, and a
                        // pane that leaves a row unused is a layout bug, not breathing room.
                        let divider = l.dividerRow.isEmpty ? 0 : 1
                        // `cardBandRows`, not `cards[0].rows`: the section keeps its rows even when
                        // its previews are shorter than the band.
                        XCTAssertEqual(l.stage.rows + (l.cards.isEmpty ? 5 : (l.cardBandRows + 6)) + divider,
                                       pane.rows, "\(label): the budget is spent exactly")
                    }
                }
            }
        }
    }

    /// First page: exactly `min(capacity, windowCount)` cards, and every one of them clickable.
    func testFullPageHasCapacityOrWindowCountCards() {
        for pane in panes {
            for per in pers {
                for windows in windowCounts {
                    let l = layout(pane.cols, pane.rows, windows: windows, per: per, cardStart: 0)
                    let label = "\(pane.cols)x\(pane.rows) per=\(per) windows=\(windows)"
                    guard l.cardStart == 0, let cardH = l.cards.first?.rows, cardH > 0 else {
                        XCTAssertEqual(l.cards.count, 0, "\(label): no room, so no cards")
                        continue
                    }
                    XCTAssertEqual(l.cards.count, min(l.capacity, windows), "\(label): first page size")
                    for i in 0..<l.cards.count {
                        XCTAssertEqual(l.action(row: l.cards[i].row, col: l.cards[i].col), .enterCard(i),
                                       "\(label): cards[\(i)] enters window \(i)")
                    }
                }
            }
        }
    }

    func testNoTwoRectsOverlap() {
        let l = layout(137, 44, windows: 14, per: 3)
        assertStructural(l, "137x44 per=3 windows=14")
        // Spelled out once, so a regression points at the pair, not only at the helper.
        XCTAssertFalse(l.stage.intersects(l.stageCaption))
        XCTAssertFalse(l.stage.intersects(l.bar.stage.rect))
        XCTAssertFalse(l.cards[0].intersects(l.cards[1]))
        XCTAssertFalse(l.cards[0].intersects(l.cardCaptions[0]))
        XCTAssertFalse(l.cardCaptions[2].intersects(l.bar.cards.rect))
        XCTAssertFalse(l.stageCaption.intersects(l.cardCaptions[0]))
    }

    func testBarColumnIsReserved() {
        for pane in panes {
            for per in pers {
                let l = layout(pane.cols, pane.rows, windows: 14, per: per)
                let label = "\(pane.cols)x\(pane.rows) per=\(per)"
                XCTAssertEqual(l.barCol, pane.cols, "\(label): the bar is the last column")
                XCTAssertEqual(l.bar.stage.rect.col, l.barCol, "\(label): the stage segment is on it")
                XCTAssertEqual(l.bar.cards.rect.col, l.barCol, "\(label): the card segment is on it")
                for (name, r) in namedRects(l) where !name.hasPrefix("bar") && !r.isEmpty {
                    XCTAssertLessThan(r.maxCol, l.barCol, "\(label): \(name) touches the bar column")
                    XCTAssertLessThanOrEqual(r.maxCol, l.cols - 2, "\(label): \(name) crosses the gap column")
                }
            }
        }
    }

    func testCaptionsAreExactlyOneRow() {
        for pane in panes {
            for per in pers {
                for windows in windowCounts {
                    let l = layout(pane.cols, pane.rows, windows: windows, per: per)
                    let label = "\(pane.cols)x\(pane.rows) per=\(per) windows=\(windows)"
                    XCTAssertEqual(l.stageCaption.rows, 1, "\(label): the stage caption is one row")
                    for (i, c) in l.cardCaptions.enumerated() {
                        XCTAssertEqual(c.rows, 1, "\(label): cardCaptions[\(i)] is one row")
                        XCTAssertEqual(c.cols, l.cards[i].cols, "\(label): cardCaptions[\(i)] is the card's width")
                    }
                }
            }
        }
    }

    /// The bar and every band stop short of the final cell of the final row: writing it arms the
    /// terminal's pending-wrap and the next byte scrolls the whole wall one row up.
    func testFooterIsTheLastRowAndTheFinalCellStaysFree() {
        for pane in panes {
            for per in pers {
                for windows in windowCounts {
                    let l = layout(pane.cols, pane.rows, windows: windows, per: per)
                    let label = "\(pane.cols)x\(pane.rows) per=\(per) windows=\(windows)"
                    XCTAssertEqual(l.footerRow, pane.rows, "\(label): footer == rows")
                    for (name, r) in namedRects(l) {
                        XCTAssertFalse(r.contains(row: pane.rows, col: pane.cols),
                                       "\(label): \(name) writes the pending-wrap cell")
                    }
                    // The bar ends on the row above the blank row, never on the footer.
                    XCTAssertLessThanOrEqual(l.bar.cards.rect.maxRow, pane.rows - 2, "\(label): bar bottom")
                    XCTAssertLessThanOrEqual(l.bar.stage.rect.maxRow, pane.rows - 2, "\(label): bar bottom")
                }
            }
        }
    }

    /// The overlap test above is only evidence if `intersects` itself is right: a pair that merely
    /// touches must not count (a card caption sits directly under its card, sharing an edge), and an
    /// empty rect must collide with nothing — that is how a dropped band is spelled.
    func testCellRectPrimitives() {
        let a = CellRect(col: 1, row: 1, cols: 3, rows: 2)
        XCTAssertEqual(a.maxRow, 2)
        XCTAssertEqual(a.maxCol, 3)
        XCTAssertFalse(a.isEmpty)
        XCTAssertTrue(a.contains(row: 1, col: 1))
        XCTAssertTrue(a.contains(row: 2, col: 3))
        XCTAssertFalse(a.contains(row: 3, col: 1), "the row below is not inside")
        XCTAssertFalse(a.contains(row: 1, col: 4), "the column to the right is not inside")
        XCTAssertFalse(a.intersects(CellRect(col: 1, row: 3, cols: 3, rows: 2)),
                       "rows 2 and 3 touch but do not overlap")
        XCTAssertTrue(a.intersects(CellRect(col: 3, row: 2, cols: 1, rows: 1)), "one shared cell")
        let empty = CellRect(col: 1, row: 1, cols: 0, rows: 5)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(empty.contains(row: 1, col: 1), "an empty band covers nothing")
        XCTAssertFalse(empty.intersects(a), "an empty band overlaps nothing")
        XCTAssertFalse(a.intersects(empty))
        XCTAssertTrue(CellRect(col: 1, row: 1, cols: 4, rows: 0).isEmpty)
    }

    // MARK: hit table

    func testTheStageAndItsCaptionEnterTheStage() {
        let l = layout(137, 44, windows: 14, per: 3, stageStart: 1)
        XCTAssertEqual(l.stageStart, 1)
        XCTAssertEqual(l.action(row: l.stage.row, col: 1), .enterStage(1))
        XCTAssertEqual(l.action(row: l.stage.row, col: l.stage.maxCol), .enterStage(1))
        XCTAssertEqual(l.action(row: l.stage.maxRow, col: 40), .enterStage(1))
        XCTAssertEqual(l.action(row: l.stageCaption.row, col: 1), .enterStage(1))
        XCTAssertEqual(l.action(row: l.stageCaption.row, col: 20), .enterStage(1))
        XCTAssertEqual(l.slot(row: l.stage.row, col: 3), .stage(0))
        XCTAssertEqual(l.slot(row: l.stageCaption.row, col: 3), .stage(0))
    }

    func testCardsAndTheirCaptionsEnterTheWindow() {
        let l = layout(137, 44, windows: 14, per: 3, cardStart: 3)
        XCTAssertEqual(l.cardStart, 3)
        XCTAssertEqual(l.cards.count, 3)
        for i in 0..<l.cards.count {
            XCTAssertEqual(l.action(row: l.cards[i].row, col: l.cards[i].col), .enterCard(3 + i))
            XCTAssertEqual(l.action(row: l.cards[i].maxRow, col: l.cards[i].maxCol), .enterCard(3 + i))
            XCTAssertEqual(l.action(row: l.cardCaptions[i].row, col: l.cardCaptions[i].col), .enterCard(3 + i))
            XCTAssertEqual(l.slot(row: l.cardCaptions[i].row, col: l.cardCaptions[i].col), .card(i))
        }
    }

    func testBarArrowsStepAndTheShaftJumps() {
        let l = layout(137, 44, windows: 14, per: 3)
        XCTAssertEqual(l.action(row: l.bar.stage.rect.row, col: l.barCol), WallAction.stageStep(-1))
        XCTAssertEqual(l.action(row: l.bar.stage.rect.maxRow, col: l.barCol), WallAction.stageStep(1))
        XCTAssertEqual(l.action(row: l.bar.cards.rect.row, col: l.barCol), WallAction.cardStep(-l.capacity))
        XCTAssertEqual(l.action(row: l.bar.cards.rect.maxRow, col: l.barCol), WallAction.cardStep(l.capacity))

        // Pinned: at 27 rows of stage the shaft is rows 3…27, so row 10 is offset 7 of 25
        // -> 7/25 * 2 displays = 0.56 -> 1.
        XCTAssertEqual(l.action(row: 10, col: l.barCol), WallAction.stageJump(1))
        // Card shaft: rows 33…41, row 35 is offset 2 of 9 -> 2/9 * 11 = 2.4 -> 3 with the layout's
        // rounding (it rounds the ratio, not the offset).
        XCTAssertEqual(l.action(row: 35, col: l.barCol), WallAction.cardJump(3))

        // Every inner row of both segments answers, and it answers with a jump.
        for row in (l.bar.stage.rect.row + 1)..<l.bar.stage.rect.maxRow {
            guard case .stageJump(let target)? = l.action(row: row, col: l.barCol) else {
                return XCTFail("stage shaft row \(row) is not a jump")
            }
            XCTAssertTrue((0...l.bar.stage.maxStart).contains(target), "stage jump \(target) is out of range")
        }
        for row in (l.bar.cards.rect.row + 1)..<l.bar.cards.rect.maxRow {
            guard case .cardJump(let target)? = l.action(row: row, col: l.barCol) else {
                return XCTFail("card shaft row \(row) is not a jump")
            }
            XCTAssertTrue((0...l.bar.cards.maxStart).contains(target), "card jump \(target) is out of range")
        }
    }

    /// A segment with nothing to scroll is dim and dead (design §5). That includes a segment whose
    /// band was dropped, and the caps of the bar, which are the rows between the two segments.
    func testDeadSegmentsAnswerNothing() {
        let one = layout(137, 44, windows: 1, per: 3, displays: 1)
        XCTAssertFalse(one.bar.stage.scrollable)
        XCTAssertFalse(one.bar.cards.scrollable)
        for row in 1...one.rows {
            XCTAssertNil(one.action(row: row, col: one.barCol), "dead bar row \(row) answered")
        }
        // …but the card itself still enters its window.
        XCTAssertEqual(one.action(row: one.cards[0].row, col: one.cards[0].col), .enterCard(0))

        // 7 rows: no card band at all, so the lower segment has no rows and no clicks.
        let tiny = layout(137, 7, windows: 14, per: 3)
        XCTAssertEqual(tiny.cards.count, 0)
        XCTAssertEqual(tiny.bar.cards.rect.rows, 0)
        XCTAssertNil(tiny.action(row: tiny.bar.cards.rect.row, col: tiny.barCol))
        XCTAssertTrue(tiny.bar.stage.scrollable, "the stage still scrolls with 3 displays")
        XCTAssertEqual(tiny.action(row: tiny.bar.stage.rect.row, col: tiny.barCol), .stageStep(-1))
        XCTAssertEqual(tiny.action(row: tiny.bar.stage.rect.maxRow, col: tiny.barCol), .stageStep(1))
        XCTAssertNil(tiny.bar.stage.thumbRow(), "two rows have no shaft")
    }

    /// Header, band header, blank row, the gap column, the bar caps, anything outside: nil. Those
    /// clicks are swallowed by the wall — they must never reach the remote desktop.
    func testEverythingElseAnswersNothing() {
        let l = layout(137, 44, windows: 14, per: 3)
        let blankRow = l.cardCaptions[0].row + 1
        XCTAssertEqual(blankRow + 1, l.footerRow, "exactly one blank row above the footer")
        XCTAssertNil(l.action(row: l.headerRow, col: 1), "header")
        XCTAssertNil(l.action(row: l.bandRow, col: 1), "band header")
        XCTAssertNil(l.action(row: blankRow, col: 1), "blank row")
        // The bar's caps: one above the stage, one at the stage caption, one at the card caption.
        XCTAssertNil(l.action(row: l.headerRow, col: l.barCol), "top cap")
        XCTAssertNil(l.action(row: l.stageCaption.row, col: l.barCol), "stage bottom cap")
        XCTAssertNil(l.action(row: l.cardCaptions[0].row, col: l.barCol), "card top cap")
        // The gap column between the content and the bar — except on the footer row, which is a
        // back button across its whole width (the bar column itself stays dead there).
        for row in 2..<l.footerRow {
            XCTAssertNil(l.action(row: row, col: l.cols - 1), "gap column row \(row)")
        }
        XCTAssertEqual(l.action(row: l.footerRow, col: l.cols - 1), .back, "the footer reaches the gap column")
        XCTAssertNil(l.action(row: l.cards[0].row, col: l.cols + 5), "outside right")
        XCTAssertNil(l.action(row: l.rows + 1, col: 1), "below the pane")
        XCTAssertNil(l.action(row: 0, col: 0), "the 0-based corner does not exist")
        XCTAssertNil(l.slot(row: l.headerRow, col: 1))
        XCTAssertNil(l.slot(row: l.stage.row, col: l.barCol), "the bar is not a slot")
    }

    /// The hit table as a whole, cell by cell: the cells that answer must be exactly the stage,
    /// its caption, the cards, their captions, the footer row and the live cells of the bar — no
    /// more (a dead cell must not swallow a click meant for the desktop) and no less (a card the
    /// user can see must be clickable). Built from the rectangles, not from `action`, so an extra
    /// cell that answers by accident shows up.
    func testEveryCellOfThePaneIsHitTested() {
        var cases: [(label: String, l: WallLayout)] = []
        for pane in panes {
            for per in pers {
                for windows in [1, 7, 14] {
                    cases.append(("\(pane.cols)x\(pane.rows) per=\(per) windows=\(windows)",
                                  layout(pane.cols, pane.rows, windows: windows, per: per)))
                }
            }
        }
        // …and panes tall enough for the band to hold several rows of cards (issue #83). There a
        // page's rects are not one row any more, so the live cells have to follow the rows.
        cases.append(("118x73 per=3 (two rows)",
                      layout(118, 73, windows: 14, per: 3, displays: 1,
                             stageAspect: 1.6, cellAspect: 33.0 / 17.0)))
        cases.append(("137x100 per=3 (three rows)",
                      layout(137, 100, windows: 14, per: 3, displays: 1, stageAspect: 1.6)))
        for (label, l) in cases {
            var live = Set<[Int]>()
            func mark(_ r: CellRect) {
                guard !r.isEmpty else { return }
                for row in r.row...r.maxRow {
                    for col in r.col...r.maxCol { live.insert([row, col]) }
                }
            }
            mark(l.stage)
            mark(l.stageCaption)
            l.cards.forEach(mark)
            l.cardCaptions.forEach(mark)
            // The footer is a back button across the content, but not across the bar.
            for col in 1..<l.barCol { live.insert([l.footerRow, col]) }
            for segment in [l.bar.stage, l.bar.cards]
            where segment.scrollable && segment.rect.rows >= 2 {
                live.insert([segment.rect.row, l.barCol])
                live.insert([segment.rect.maxRow, l.barCol])
                if segment.rect.rows >= 3 {
                    for row in (segment.rect.row + 1)..<segment.rect.maxRow {
                        live.insert([row, l.barCol])
                    }
                }
            }
            for row in 1...l.rows {
                for col in 1...l.cols {
                    let answers = l.action(row: row, col: col) != nil
                    XCTAssertEqual(answers, live.contains([row, col]),
                                   "\(label): (\(row),\(col)) answers \(String(describing: l.action(row: row, col: col)))")
                }
            }
        }
    }

    func testFooterIsBack() {
        let l = layout(60, 24, windows: 7, per: 2)
        XCTAssertEqual(l.footerRow, 24)
        XCTAssertEqual(l.action(row: 24, col: 1), .back)
        XCTAssertEqual(l.action(row: 24, col: l.cols - 1), .back)
        XCTAssertNil(l.action(row: 24, col: l.barCol), "the footer row is not a bar row")
        XCTAssertNil(l.action(row: 23, col: 1), "the blank row is not the footer")
        XCTAssertNil(l.action(row: 25, col: 1), "there is nothing below the footer")
    }

    // MARK: pages and starts

    func testPartialLastPageKeepsItsCards() {
        let l = layout(137, 44, windows: 7, per: 3, cardStart: 4)
        XCTAssertEqual(l.cardStart, 4)
        XCTAssertEqual(l.cards.count, 3, "windows 4,5,6")
        XCTAssertEqual(l.cards.last?.maxCol, l.cards[0].maxCol + 2 * (l.cards[0].cols + l.cardGap))

        // Asking for a start past the end clamps to the last full page: 7 - 3 = 4.
        let clamped = layout(137, 44, windows: 7, per: 3, cardStart: 6)
        XCTAssertEqual(clamped.cardStart, 4)
        XCTAssertEqual(clamped.cards.count, 3)
        XCTAssertEqual(clamped.action(row: clamped.cards[2].row, col: clamped.cards[2].col), .enterCard(6))
    }

    /// **A lone card takes the band, not one `per`-th of it.**
    ///
    /// This used to pin the opposite ("left-aligned, one card wide"), and that is what a reader sees
    /// as "the picture is off to the left with a wall of black beside it" (§6.7: reach the width, and
    /// when the picture cannot, centre it). `per` is a maximum, so a page with fewer cards spreads
    /// over the same band: the card box is full width and the picture keeps its aspect inside it.
    /// A card is one slot of `per` whatever the page holds, and the row of cards is centred: a page
    /// of one used to stretch its card across the whole band (a 115x29 box around an 11-row
    /// picture). The review asked for the opposite - small previews, three to a row.
    func testSingleCardIsOneSlotCentred() {
        let l = layout(137, 44, windows: 1, per: 3)
        XCTAssertEqual(l.cards.count, 1)
        XCTAssertEqual(l.cardCaptions.count, 1)
        XCTAssertEqual(l.cards[0].cols, (l.contentCols - 2 * l.cardGap) / 3, "one slot of three")
        XCTAssertEqual(l.cardCaptions[0].cols, l.cards[0].cols)
        XCTAssertEqual(l.cards[0].col - 1, l.contentCols - l.cards[0].maxCol,
                       "centred in the band, not hugging the left edge")
        XCTAssertEqual(l.action(row: l.cards[0].row, col: l.cards[0].col), .enterCard(0))
        XCTAssertEqual(l.action(row: l.cards[0].row, col: l.cards[0].maxCol), .enterCard(0),
                       "the whole card is the target, not only its first cells")
        XCTAssertNil(l.slot(row: l.cards[0].row, col: l.barCol), "the bar is never a card")
        XCTAssertFalse(l.bar.cards.scrollable, "one window does not scroll")
    }

    /// A partial page keeps its slots and centres the row: two cards occupy two of three slots, one
    /// gap apart, with the spare slot split evenly between the two margins.
    func testAPartialPageKeepsItsSlotsAndCentresTheRow() {
        let two = layout(137, 44, windows: 2, per: 3)
        XCTAssertEqual(two.cards.count, 2)
        XCTAssertEqual(two.cards[0].cols, (two.contentCols - 2 * two.cardGap) / 3,
                       "the slot width does not depend on how many cards the page holds")
        XCTAssertEqual(two.cards[0].cols, two.cards[1].cols)
        XCTAssertEqual(two.cards[1].col - two.cards[0].col, two.cards[0].cols + two.cardGap,
                       "one gap between them")
        XCTAssertEqual(two.cards[0].col - 1, two.contentCols - two.cards[1].maxCol,
                       "and one equal margin either side")

        let full = layout(137, 44, windows: 7, per: 3)
        XCTAssertEqual(full.cards.count, 3)
        XCTAssertEqual(full.cards[0].col, 1, "a full page fills the band")
        XCTAssertEqual(full.cards[2].maxCol, full.contentCols)
        XCTAssertEqual(full.cards[0].cols, (full.contentCols - 2 * full.cardGap) / 3)
    }

    /// The cards are as tall as their pictures need, not as tall as the band: `cardAspect` turns the
    /// slot's width into rows, so a row of small previews does not carry 18 rows of empty band, and
    /// the caption sits directly under the picture (§6.6).
    func testACardIsAsTallAsItsPicture() {
        let tall = layout(137, 60, windows: 3, per: 3)
        let slotW = tall.cards[0].cols
        let expected = Int((Double(slotW) / (WallLayout.cardAspect * WallLayout.cellAspect)).rounded())
        XCTAssertEqual(tall.cards[0].rows, expected, "the slot's width decides the height")
        XCTAssertLessThanOrEqual(tall.cards[0].rows, tall.cardBandRows, "the band caps it")
        XCTAssertEqual(tall.cardCaptions[0].row, tall.cards[0].row + tall.cards[0].rows,
                       "the caption belongs directly under the picture")
        XCTAssertEqual(tall.footerRow, tall.rows, "the footer stays the pane's last row")

        let short = layout(137, 22, windows: 3, per: 3)
        XCTAssertLessThanOrEqual(short.cards[0].rows, short.cardBandRows)
        XCTAssertGreaterThanOrEqual(short.cards[0].rows, WallLayout.minCardRows)
    }

    // MARK: a band that holds more than one row of cards (issue #83)

    /// The reporter's pane: 118x73 with an 17x33 cell and a 16:10 display. The 7:3 split hands the
    /// card section 29 picture rows and a 37-cell slot is a 12-row preview, so the page holds
    /// **two** rows of three - "3 x 2 = 6 windows", not one row of previews inside 18 rows of empty
    /// wall, and nothing about the split changes.
    ///
    /// (The issue's table says a preview is 37x11; that is the same slot measured with a 2.0 cell
    /// aspect. With the cell the reporter actually has - 17x33 - it is 12 rows. Both are the same
    /// rule, `slotW / (cardAspect x cellAspect)`.)
    func testABandThatFitsTwoRowsPagesBySix() {
        let l = layout(118, 73, windows: 14, per: 3, displays: 1,
                       stageAspect: 1.6, cellAspect: 33.0 / 17.0)
        let label = "118x73 per=3"
        assertStructural(l, label)
        XCTAssertEqual(l.stage.rows, 37, "the stage keeps the rows its 16:10 picture needs")
        XCTAssertEqual(l.cardBandRows, 29, "and the card section keeps the rest of the 7:3 split")
        XCTAssertEqual(l.per, 3, "three to a row - the reader's number does not move")
        XCTAssertEqual(l.cardRowCount, 2, "two rows of previews fit the band")
        XCTAssertEqual(l.capacity, 6, "a page is 3 x 2 windows")
        XCTAssertEqual(l.cards.count, 6)
        XCTAssertEqual(l.cardCaptions.count, 6)

        // Geometry, spelled out: 37 cells wide, 12 rows tall, caption under each, and the second
        // row directly under the first row's caption. The section is 30 rows and the stack 26, so
        // it is centred with two rows above and two below (§6.7: an odd leftover goes bottom).
        XCTAssertEqual(l.bandRow, 41)
        XCTAssertEqual(l.cards[0], CellRect(col: 1, row: 44, cols: 37, rows: 12))
        XCTAssertEqual(l.cardCaptions[0].row, 56, "directly under its picture")
        XCTAssertEqual(l.cards[3].row, 57, "row two starts under row one's caption")
        XCTAssertEqual(l.cards[3].col, 1, "and it is centred on its own")
        XCTAssertEqual(l.cardCaptions[5].row, 69)
        XCTAssertEqual(l.bar.cards.rect, CellRect(col: 118, row: 42, cols: 1, rows: 29),
                       "the bar's lower segment still spans the whole section")
        XCTAssertEqual(l.footerRow, 73, "the footer is still the pane's last row")
        // The section's own rows: 42 (band start) … 71 (its last row), blank row 72, footer 73.
        XCTAssertEqual(l.cardBandRows + 1, l.cardCaptions[5].maxRow - l.bar.cards.rect.row + 3,
                       "two spare section rows under the stack, then the blank row")

        // Hit testing follows the rows: every card and every caption enters its own window.
        for i in 0..<6 {
            XCTAssertEqual(l.action(row: l.cards[i].row, col: l.cards[i].col), .enterCard(i),
                           "card \(i) of the page enters window \(i)")
            XCTAssertEqual(l.action(row: l.cards[i].maxRow, col: l.cards[i].maxCol), .enterCard(i))
            XCTAssertEqual(l.action(row: l.cardCaptions[i].row, col: l.cardCaptions[i].col),
                           .enterCard(i))
        }
        // The band rows the stack does not cover are empty wall, not click targets - and a wheel
        // over them still scrolls the shelf, because they belong to the section.
        for row in [42, 43, 70, 71] {
            XCTAssertNil(l.action(row: row, col: 5), "band row \(row) is empty wall")
            XCTAssertEqual(l.wheelAction(row: row, col: 5, direction: 1), .cardStep(1),
                           "band row \(row) is still the shelf for the wheel")
        }
    }

    /// A band that fits three rows: 137x100 with a 16:10 display gives the section 51 picture rows,
    /// a 43-cell preview is 13 rows, and 3 x 14 = 42 of the 52 rows are used - nine windows a page.
    func testABandThatFitsThreeRowsPagesByNine() {
        let l = layout(137, 100, windows: 14, per: 3, displays: 1, stageAspect: 1.6)
        assertStructural(l, "137x100 per=3")
        XCTAssertEqual(l.stage.rows, 42, "the picture's own rows")
        XCTAssertEqual(l.cardBandRows, 51)
        XCTAssertEqual(l.cardRowCount, 3)
        XCTAssertEqual(l.capacity, 9)
        XCTAssertEqual(l.cards.count, 9)
        XCTAssertEqual(l.cards[0], CellRect(col: 1, row: 52, cols: 43, rows: 13))
        XCTAssertEqual(l.cards[8], CellRect(col: 93, row: 80, cols: 43, rows: 13),
                       "the third row of three, one gap apart")
        XCTAssertEqual(l.cardCaptions[8].row, 93)
        XCTAssertEqual(l.bar.cards.rect, CellRect(col: 137, row: 47, cols: 1, rows: 51))
        XCTAssertLessThanOrEqual(l.cardCaptions[8].maxRow, l.bar.cards.rect.maxRow + 1,
                                 "the last caption is inside the section")
        XCTAssertEqual(l.footerRow, 100)
        XCTAssertEqual(l.action(row: l.cards[7].row, col: l.cards[7].col), .enterCard(7))
        XCTAssertEqual(l.action(row: l.cardCaptions[7].row, col: l.cardCaptions[7].col),
                       .enterCard(7))
    }

    /// The same pane split two ways: without the display's aspect the band is the 3 of the 7:3
    /// split (27 picture rows) and holds two rows of cards; with it the stage keeps 42 rows and the
    /// band holds three. `per` is the same number both times - only the page grows.
    func testThePageGrowsWithTheBandNotWithTheWindows() {
        let split = layout(137, 100, windows: 14, per: 3, displays: 1)
        let fitted = layout(137, 100, windows: 14, per: 3, displays: 1, stageAspect: 1.6)
        XCTAssertEqual(split.stage.rows, 66)
        XCTAssertEqual(split.cardBandRows, 27)
        XCTAssertEqual(split.cardRowCount, 2)
        XCTAssertEqual(split.capacity, 6)
        XCTAssertEqual(fitted.cardRowCount, 3)
        XCTAssertEqual(fitted.capacity, 9)
        XCTAssertEqual(split.per, fitted.per, "the row width is not what changes")
        for l in [split, fitted] {
            assertStructural(l, "137x100 per=3")
            XCTAssertEqual(l.footerRow, l.rows)
            XCTAssertEqual(l.cards.count, l.capacity, "14 windows fill more than a page")
        }
        // …and the paging step follows the page, not the row width: `.cardStep(6)` / `.cardStep(9)`.
        XCTAssertEqual(split.action(row: split.bar.cards.rect.maxRow, col: split.barCol),
                       .cardStep(6))
        XCTAssertEqual(fitted.action(row: fitted.bar.cards.rect.maxRow, col: fitted.barCol),
                       .cardStep(9))
        XCTAssertEqual(split.bar.cards.maxStart, 14 - 6)
        XCTAssertEqual(fitted.bar.cards.maxStart, 14 - 9)
    }

    /// The last page has to be reachable: the thumb's track covers `windowCount - capacity`
    /// positions, every one of them round-trips through a click, and a page step never skips a
    /// window - the three cards of the page the reader was on stay on screen when it turns.
    func testTheThumbAndThePageStepFollowThePageCapacity() {
        let windows = 14
        let l = layout(118, 73, windows: windows, per: 3, displays: 1,
                       stageAspect: 1.6, cellAspect: 33.0 / 17.0)
        let seg = l.bar.cards
        XCTAssertEqual(seg.visible, 6)
        XCTAssertEqual(seg.maxStart, windows - 6)
        for start in 0...seg.maxStart {
            let at = layout(118, 73, windows: windows, per: 3, displays: 1, cardStart: start,
                            stageAspect: 1.6, cellAspect: 33.0 / 17.0)
            XCTAssertEqual(at.cardStart, start)
            XCTAssertEqual(at.cards.count, min(6, windows - start))
            guard let thumb = at.bar.cards.thumbRow() else { return XCTFail("start \(start): no thumb") }
            XCTAssertTrue((seg.rect.row + 1...seg.rect.maxRow - 1).contains(thumb),
                          "start \(start): the thumb is outside the shaft")
            XCTAssertEqual(at.bar.cards.jumpTarget(shaftOffset: thumb - seg.rect.row - 1), start,
                           "start \(start): thumb -> jump -> start")
        }
        // A page of six never leaves a window behind: paging from the landing page steps
        // 0 -> 6 -> 8 (clamped), so 0…5, 6…11 and 8…13 cover 0…13 and no page starts past the last
        // window.
        let lastPage = layout(118, 73, windows: windows, per: 3, displays: 1,
                              cardStart: seg.maxStart, stageAspect: 1.6, cellAspect: 33.0 / 17.0)
        XCTAssertEqual(lastPage.cards.count, 6)
        XCTAssertEqual(lastPage.cardStart + lastPage.cards.count, windows,
                       "the last page ends on the last window")
        var starts: [Int] = []
        var start = 0
        while true {
            starts.append(start)
            let next = min(start + seg.visible, seg.maxStart)
            if next == start { break }
            start = next
        }
        XCTAssertEqual(starts, [0, 6, 8], "a page step walks the shelf without skipping a window")
    }

    func testStartsAreClamped() {
        let l = layout(137, 44, windows: 7, per: 3, stageStart: 9, cardStart: -4)
        XCTAssertEqual(l.stageStart, 2, "clamped to the last display")
        XCTAssertEqual(l.cardStart, 0, "negative start clamps to zero")
        XCTAssertEqual(l.action(row: l.stage.row, col: 1), .enterStage(2))

        let empty = layout(137, 44, windows: 0, per: 3, displays: 0, stageStart: 3, cardStart: 3)
        XCTAssertEqual(empty.stageStart, 0)
        XCTAssertEqual(empty.cardStart, 0)
        XCTAssertEqual(empty.cards.count, 0)
        XCTAssertEqual(empty.stage.rows, 38, "no windows: the stage takes the whole budget")
        XCTAssertEqual(empty.bar.cards.rect.rows, 0)
    }

    /// The bar is a scrollbar, not a slider: clicking the shaft puts the thumb where the click was.
    /// A one-cell shaft is the degenerate end of that: its thumb can only put the segment back
    /// where it already is (issue #135).
    func testThumbAndJumpAreInverse() {
        // 137x44, per 3: a 10-row card segment is an 8-cell shaft, and 9 windows are 7 positions,
        // so every start is representable. (The shaft used to be one cell longer; the gap between
        // the cards took that row, which is why this case asks for 9 windows and not 14.)
        for start in 0...6 {
            let l = layout(137, 44, windows: 9, per: 3, cardStart: start)
            let seg = l.bar.cards
            XCTAssertEqual(seg.start, start)
            guard let thumb = seg.thumbRow() else { return XCTFail("start \(start): no thumb") }
            XCTAssertTrue((seg.rect.row + 1...seg.rect.maxRow - 1).contains(thumb),
                          "start \(start): the thumb is outside the shaft")
            XCTAssertEqual(seg.jumpTarget(shaftOffset: thumb - seg.rect.row - 1), start,
                           "start \(start): thumb -> jump -> start")
        }
        // Stage: 25 shaft cells for 3 displays.
        for start in 0...2 {
            let seg = layout(137, 44, stageStart: start).bar.stage
            XCTAssertEqual(seg.start, start)
            guard let thumb = seg.thumbRow() else { return XCTFail("stage start \(start): no thumb") }
            XCTAssertEqual(seg.jumpTarget(shaftOffset: thumb - seg.rect.row - 1), start)
        }

        // A shaft with fewer cells than positions cannot be exact — the nearest start wins.
        let coarse = layout(60, 24, windows: 14, per: 3, cardStart: 7).bar.cards
        let shaft = coarse.rect.rows - 2
        guard let thumb = coarse.thumbRow() else { return XCTFail("no thumb") }
        let back = coarse.jumpTarget(shaftOffset: thumb - coarse.rect.row - 1)
        let bound = Int((0.5 * Double(coarse.maxStart) / Double(shaft - 1) + 0.5).rounded(.up))
        XCTAssertLessThanOrEqual(abs(back - coarse.start), bound,
                                 "a coarse thumb has to land near the start it shows")

        // Nothing to show: no thumb at all.
        XCTAssertNil(layout(137, 44, windows: 3, per: 3, displays: 1).bar.stage.thumbRow())
        XCTAssertNil(layout(137, 44, windows: 3, per: 3).bar.cards.thumbRow())
        // A shaft of exactly one cell cannot tell two positions apart — the thumb is drawn in that
        // one cell for *every* `start` — so the click on it keeps the position the thumb shows
        // instead of going anywhere. Pinned as `== 0` before issue #135, which was the defect
        // written down as intent: on both segments the thumb was a "go to the first page" button.
        // Both segments, on the smallest bands the layout draws and *not* on their first page, so a
        // `0` cannot pass by being the start: a 3-row stage (137x8 leaves a budget of 3 rows) with
        // the last display up, and a 3-row card band (24x17 with 7 windows, one to a page) on the
        // last page.
        let oneCellStage = layout(137, 8, windows: 14, per: 3, stageStart: 2)
        XCTAssertEqual(oneCellStage.stageStart, 2)
        let stageShaft = oneCellStage.bar.stage
        XCTAssertEqual(stageShaft.rect.rows, 3)
        XCTAssertEqual(stageShaft.thumbRow(), stageShaft.rect.row + 1)
        XCTAssertEqual(stageShaft.jumpTarget(shaftOffset: 0), stageShaft.start,
                       "a one-cell shaft keeps the display it is showing")
        XCTAssertEqual(oneCellStage.action(row: stageShaft.rect.row + 1, col: oneCellStage.barCol),
                       .stageJump(2), "…and the click route answers what the thumb shows")

        let oneCellCards = layout(24, 17, windows: 7, per: 1, cardStart: 6)
        XCTAssertEqual(oneCellCards.cardStart, 6)
        let cardShaft = oneCellCards.bar.cards
        XCTAssertEqual(cardShaft.rect.rows, 3)
        XCTAssertEqual(cardShaft.thumbRow(), cardShaft.rect.row + 1)
        XCTAssertEqual(cardShaft.jumpTarget(shaftOffset: 0), cardShaft.start,
                       "a one-cell shaft keeps the page it is showing")
        XCTAssertEqual(oneCellCards.action(row: cardShaft.rect.row + 1, col: oneCellCards.barCol),
                       .cardJump(6), "…and the click route answers what the thumb shows")

        XCTAssertNil(layout(137, 7, windows: 14, per: 3).bar.stage.thumbRow(), "two rows are arrows only")
    }

    // MARK: narrow and tiny panes

    func testNarrowPanesDropCardsInsteadOfSqueezingThem() {
        // content 28: four cards would be 6 cells wide (< 8), three are 8.
        let narrow = layout(30, 24, windows: 7, per: 4)
        XCTAssertEqual(narrow.per, 3, "a 6-cell card is not drawn, 8 is")
        XCTAssertEqual(narrow.cards[0].cols, 8)
        XCTAssertEqual(narrow.cards.count, 3)
        // content 32: four cards would be 7, three are 10.
        XCTAssertEqual(layout(34, 24, windows: 7, per: 4).per, 3)
        // content 18: four -> 3, three -> 5, two -> 8.
        XCTAssertEqual(layout(20, 24, windows: 7, per: 4).per, 2)
        XCTAssertEqual(layout(20, 24, windows: 7, per: 4).cards[0].cols, 8)
        // A 1-column-wide card is still a card: the loop never reaches 0.
        XCTAssertGreaterThanOrEqual(layout(4, 24, windows: 7, per: 4).per, 1)
    }

    /// Contract §3B: rows 6…14, cols 20…60. No negative size, no card band shorter than the floor,
    /// no overlap, and the footer is still the last row.
    func testTinyPanesStayInsideThePane() {
        for rows in 6...14 {
            for cols in [20, 27, 33, 41, 52, 60] {
                for per in pers {
                    for windows in [0, 1, 7] {
                        let l = layout(cols, rows, windows: windows, per: per)
                        let label = "\(cols)x\(rows) per=\(per) windows=\(windows)"
                        assertStructural(l, label)
                        XCTAssertGreaterThanOrEqual(l.stage.rows, 0, "\(label): stage height")
                        XCTAssertGreaterThanOrEqual(l.contentCols, 1, "\(label): content width")
                        XCTAssertEqual(l.footerRow, rows, "\(label): footer")
                        XCTAssertGreaterThanOrEqual(l.stage.row, 1)
                        for card in l.cards {
                            XCTAssertGreaterThanOrEqual(card.rows, WallLayout.minCardRows,
                                                        "\(label): a drawn card band is at least \(WallLayout.minCardRows) rows")
                            XCTAssertGreaterThanOrEqual(card.cols, 1, "\(label): card width")
                        }
                        if l.cards.isEmpty {
                            XCTAssertEqual(l.stage.rows + 5, rows, "\(label): no band, the stage takes the rest")
                        } else {
                            XCTAssertLessThanOrEqual(l.stage.rows + l.cards[0].rows + 6, rows,
                                                     "\(label): the bands fit")
                        }
                    }
                }
            }
        }
    }

    /// Panes a terminal should never report: the caller is a resize handler, so this has to be
    /// useless, not fatal.
    func testDegeneratePanesDoNotTrap() {
        for cols in [1, 2, 3, 5, 8, 12] {
            for rows in [1, 2, 3, 4, 5, 8] {
                let l = layout(cols, rows, windows: 14, per: 4)
                let label = "\(cols)x\(rows)"
                XCTAssertEqual(l.footerRow, rows, "\(label): footer is clamped to the last row")
                XCTAssertEqual(l.barCol, cols)
                XCTAssertGreaterThanOrEqual(l.contentCols, 1)
                for (name, r) in namedRects(l) {
                    XCTAssertGreaterThanOrEqual(r.cols, 0, "\(label): \(name) width")
                    XCTAssertGreaterThanOrEqual(r.rows, 0, "\(label): \(name) height")
                    guard !r.isEmpty else { continue }
                    XCTAssertLessThanOrEqual(r.maxRow, rows, "\(label): \(name) hangs off the bottom")
                    XCTAssertLessThanOrEqual(r.maxCol, cols, "\(label): \(name) hangs off the right")
                    XCTAssertFalse(r.contains(row: rows, col: cols),
                                   "\(label): \(name) writes the pending-wrap cell")
                }
                XCTAssertGreaterThanOrEqual(l.per, 1)
            }
        }
        // per 0 and a negative window count are caller mistakes, not geometry.
        let zero = layout(80, 24, windows: -3, per: 0)
        XCTAssertEqual(zero.per, 1)
        XCTAssertEqual(zero.windowCount, 0)
        XCTAssertEqual(zero.cards.count, 0)
        XCTAssertEqual(zero.stage.rows, 18)      // one row of the budget is the divider
        XCTAssertEqual(zero.footerRow, 24)
    }
}

/// The wheel is the second way into the shelves, so it gets its own rule: one notch is one item,
/// the band decides which shelf, and an empty shelf swallows nothing.
final class WallWheelTests: XCTestCase {
    private func layout(displays: Int = 3, windows: Int = 9, cardStart: Int = 0) -> WallLayout {
        WallLayout.make(paneCols: 137, paneRows: 44, displayCount: displays, windowCount: windows,
                        per: 3, stageStart: 0, cardStart: cardStart)
    }

    func testAWheelOverTheStageMovesTheDisplayByOne() {
        let layout = self.layout()
        XCTAssertEqual(layout.wheelAction(row: layout.stage.row + 1, col: 5, direction: 1), .stageStep(1))
        XCTAssertEqual(layout.wheelAction(row: layout.stage.maxRow, col: 5, direction: -1), .stageStep(-1))
        // The caption belongs to the stage: aiming at the label and scrolling is natural.
        XCTAssertEqual(layout.wheelAction(row: layout.stageCaption.row, col: 5, direction: 1), .stageStep(1))
    }

    func testAWheelOverTheCardsMovesTheShelfByOneNotByAPage() {
        let layout = self.layout()
        let first = layout.cards[0]
        XCTAssertEqual(layout.wheelAction(row: first.row, col: 5, direction: 1), .cardStep(1))
        XCTAssertEqual(layout.wheelAction(row: first.row + first.rows - 1, col: 5, direction: -1),
                       .cardStep(-1))
        XCTAssertEqual(layout.wheelAction(row: layout.cardCaptions[0].row, col: 5, direction: 1),
                       .cardStep(1))
        XCTAssertEqual(layout.wheelAction(row: layout.bandRow, col: 5, direction: 1), .cardStep(1))
    }

    func testAWheelOnTheBarFollowsTheSegmentUnderTheCursor() {
        let layout = self.layout()
        XCTAssertEqual(layout.wheelAction(row: layout.bar.stage.rect.row + 2, col: layout.barCol, direction: 1),
                       .stageStep(1))
        XCTAssertEqual(layout.wheelAction(row: layout.bar.cards.rect.row + 2, col: layout.barCol, direction: 1),
                       .cardStep(1))
    }

    func testAShelfWithNothingToScrollDoesNotEatTheWheel() {
        // One display, one page of windows: neither segment is scrollable, so no band is claimed.
        let layout = WallLayout.make(paneCols: 137, paneRows: 44, displayCount: 1, windowCount: 2,
                                     per: 3, stageStart: 0, cardStart: 0)
        XCTAssertNil(layout.wheelAction(row: layout.bar.stage.rect.row + 1, col: layout.barCol, direction: 1))
        XCTAssertNil(layout.wheelAction(row: layout.bar.cards.rect.row + 1, col: layout.barCol, direction: 1))
        // ...and the cards themselves agree: two windows fit in three slots, so a notch is a
        // no-op rather than a step that `apply` would have to clamp.
        XCTAssertNil(layout.wheelAction(row: layout.cards[0].row, col: 5, direction: 1))
    }

    func testTheHeaderAndFooterAreNotScrollable() {
        let layout = self.layout()
        XCTAssertNil(layout.wheelAction(row: 0, col: 5, direction: 1))
        XCTAssertNil(layout.wheelAction(row: layout.footerRow, col: 5, direction: 1))
        XCTAssertNil(layout.wheelAction(row: layout.stage.row, col: 5, direction: 0))
    }

    /// The divider is one dim rule and nothing else: it must not become a hit target, or a click on
    /// what looks like a separator would enter whatever happened to be behind it.
    func testTheDividerIsNotAHitTarget() {
        let layout = self.layout()
        XCTAssertFalse(layout.dividerRow.isEmpty)
        XCTAssertEqual(layout.dividerRow.rows, 1)
        XCTAssertNil(layout.action(row: layout.dividerRow.row, col: 1))
        XCTAssertNil(layout.wheelAction(row: layout.dividerRow.row, col: 5, direction: 1))
    }
}

/// The stage band follows the picture it has to hold (design §6.6, the "picture smaller than its
/// frame" report): a 16:10 display in a 137x73 pane needs 42 rows, not the 53 the row budget leaves
/// over, and the rows it gives back make the cards bigger instead of showing as wall.
final class WallStageAspectTests: XCTestCase {
    private let cols = 137, rows = 73

    private func layout(stageAspect: Double?, per: Int = 3) -> WallLayout {
        WallLayout.make(paneCols: cols, paneRows: rows, displayCount: 1, windowCount: 3,
                        per: per, stageStart: 0, cardStart: 0,
                        stageAspect: stageAspect, cellAspect: 2.0)
    }

    func testTheStageBandIsWhatThePictureNeedsAndTheCardsStayPreviews() {
        let budget = layout(stageAspect: nil)
        let fitted = layout(stageAspect: 1.6)
        // 135 content columns / (2.0 cell aspect * 1.6 picture aspect) = 42.2 -> 42 rows.
        XCTAssertEqual(fitted.stage.rows, 42)
        // 7:3 of the 67-row budget gives the stage 47, and the picture keeps only the 42 it needs.
        XCTAssertEqual(budget.stage.rows, 47)
        // The 5 rows the stage does not need stay with the card *section* - a card is one slot of
        // `per` wide and as tall as its picture, so the freed rows are not spent making previews
        // bigger ("很小的一个图片就可以了，一排可以显示三个窗口").
        XCTAssertEqual(fitted.cardBandRows, budget.cardBandRows + 5)
        XCTAssertEqual(fitted.cards[0].cols, budget.cards[0].cols, "the slot does not widen")
        XCTAssertEqual(fitted.cards[0].rows, budget.cards[0].rows, "and the preview does not grow")
        XCTAssertEqual(fitted.per, budget.per)
        XCTAssertEqual(fitted.cards.count, fitted.capacity)
        XCTAssertEqual(fitted.capacity, fitted.per * fitted.cardRowCount)
        // Nothing moved down: the footer is still the last row of the pane.
        XCTAssertEqual(fitted.footerRow, rows)
        XCTAssertEqual(budget.footerRow, rows)
        // Both captions still sit directly under their picture.
        XCTAssertEqual(fitted.stageCaption.row, fitted.stage.row + fitted.stage.rows)
        XCTAssertEqual(fitted.cardCaptions[0].row, fitted.cards[0].row + fitted.cards[0].rows)
    }

    func testAShorterPaneKeepsTheRowsItHasWhenThePictureDoesNotNeedMore() {
        // 36 rows: the budget gives the stage 24 and a 16:10 picture needs 42 -> the aspect must
        // never ask for more than the budget has; the layout shrinks, it does not overflow.
        let tall = WallLayout.make(paneCols: cols, paneRows: 36, displayCount: 1, windowCount: 3,
                                   per: 3, stageStart: 0, cardStart: 0,
                                   stageAspect: 1.6, cellAspect: 2.0)
        XCTAssertTrue(tall.stage.rows <= 24)
        XCTAssertEqual(tall.stage.row + tall.stage.rows - 1, tall.stageCaption.row - 1)
        XCTAssertEqual(tall.footerRow, 36)
    }

    func testAMockWithoutADisplaySizeKeepsTheBudgetsSplit() {
        let noAspect = layout(stageAspect: nil)
        // 7:3 of the 67-row budget, with no aspect to shrink it: 47 rows of stage, 19 of cards.
        XCTAssertEqual(noAspect.stage.rows, 47)
        XCTAssertEqual(noAspect.per, 3)
    }
}
