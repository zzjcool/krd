import XCTest
@testable import krdcore

/// #83 — the card band keeps its agreed 7:3 rows, but only half of them are used.
///
/// The row budget (`WallLayout`'s doc comment, design §6.5) hands the card section `cardH` rows:
///
///     row 4+stageH   … +cardH     the cards
///     row 4+stageH+cardH          the card captions
///
/// So the contract is that the *cards* own those `cardH` rows — the box each card is drawn in is
/// the band's rows, and its caption sits on the band's floor. `a438e9c` gave a card the height its
/// picture needs (`slotW / (cardAspect x cellAspect)`, capped by the band) and kept `cardH` for the
/// row accounting so the footer stays the pane's last row. At 137 columns a `per`-3 slot is 43 cells
/// wide, i.e. 13 rows, while a tall pane's band is 24: the band is declared 7:3 and then **11 of its
/// 24 rows draw nothing** — the shelf ends mid-wall and the caption floats in the middle of it,
/// which is the report ("agreed rows, only half used").
///
/// This file is the red test for that: no product source is changed here, the assertions state the
/// doc comment's contract and fail on `a438e9c`.
///
/// **Read this before "fixing" it by making the file green.** `a438e9c` also added
/// `WallLayoutTests.testACardIsAsTallAsItsPicture` (`Tests/krdcoreTests/WallLayoutTests.swift:549-563`),
/// which pins the *opposite* number (13 rows in a 15-row band). The two cannot both hold: measured,
/// the only shape that satisfies this file is `cardRows = cardH`, which turns that existing test red.
/// So #83 is a decision to revisit `a438e9c`, not a one-line fix: measured, "hand the spare band rows
/// back to the stage" does not satisfy this file either (the stage would grow past the row the second
/// method pins — `testStageToBandSplitIsSevenToThree` goes red at 137x73), so the realistic outcomes
/// are "put more cards on the page" or "revert the card height and rewrite
/// `testACardIsAsTallAsItsPicture` in the same change". What this file establishes is only that the
/// documented budget and the drawn card disagree, with the numbers.
final class BugWallBandSplitTests: XCTestCase {
    /// One pane + whether the stage gets the rows its picture needs. `stageAspect` is what the real
    /// wall passes (`WallState.layout(stageAspect:)`, a 16:10 display); `nil` is the plain row
    /// budget. The first three are the panes the design table is read at (§6.5, 137 / 200 / 240
    /// columns); the last two are the tall panes the same section measures the band on — at the
    /// short panes the band is thinner than a `per`-3 slot, so the band caps the card and the two
    /// heights coincide. The bug needs band > slot height, i.e. a tall pane.
    private struct Pane {
        let cols: Int, rows: Int
        let stageAspect: Double?
        var label: String {
            "\(cols)x\(rows) stageAspect=\(stageAspect.map { String(format: "%.2f", $0) } ?? "nil")"
        }
    }

    private let panes: [Pane] = [
        Pane(cols: 137, rows: 44, stageAspect: nil),
        Pane(cols: 137, rows: 44, stageAspect: 1.6),
        Pane(cols: 200, rows: 60, stageAspect: nil),
        Pane(cols: 240, rows: 44, stageAspect: nil),
        Pane(cols: 137, rows: 60, stageAspect: 1.6),
        Pane(cols: 137, rows: 73, stageAspect: nil),
        Pane(cols: 137, rows: 73, stageAspect: 1.6),
    ]

    /// Seven windows is the number the review counts ("一排可以显示三个窗口"), so `per: 3` gives a
    /// full page with four left over and the band is always drawn.
    private let windows = 7
    private let displays = 3
    private let per = 3

    private func layout(_ pane: Pane) -> WallLayout {
        WallLayout.make(paneCols: pane.cols, paneRows: pane.rows,
                        displayCount: displays, windowCount: windows,
                        per: per, stageStart: 0, cardStart: 0,
                        stageAspect: pane.stageAspect)
    }

    /// Every number a reader of a failure needs, on one line: the band's agreed rows, the rows the
    /// card actually takes, the caption row, the footer, and **how many band rows draw nothing**.
    private func numbers(_ pane: Pane, _ l: WallLayout) -> String {
        let cardRows = l.cards.first?.rows ?? 0
        let cardRow = l.cards.first?.row ?? 0
        let captionRow = l.cardCaptions.first?.row ?? 0
        let unused = l.cardBandRows - cardRows
        return "\(pane.label): paneRows=\(pane.rows) cardBandRows=\(l.cardBandRows) "
            + "cards[0].rows=\(cardRows) cards[0].row=\(cardRow) cardCaptions[0].row=\(captionRow) "
            + "footerRow=\(l.footerRow) unusedBandRows=\(unused) "
            + "per=\(l.per) slotW=\(l.cards.first?.cols ?? 0)"
    }

    /// The band's rows are the cards' rows: `row 4+stageH … +cardH: the cards`, and the caption sits
    /// on the band's floor (`row 4+stageH+cardH`). Both halves of the doc comment, one failure per
    /// pane, with the "only half used" number spelled out.
    func testTheCardBoxOccupiesTheBandRows() {
        for pane in panes {
            let l = layout(pane)
            let numbers = numbers(pane, l)
            guard let card = l.cards.first, let caption = l.cardCaptions.first else {
                XCTFail("\(numbers): no card in a pane with \(windows) windows")
                continue
            }
            XCTAssertEqual(card.rows, l.cardBandRows,
                           "\(numbers): the band is \(l.cardBandRows) rows and the card draws "
                           + "\(card.rows) of them, so \(l.cardBandRows - card.rows) band rows are "
                           + "empty wall")
            XCTAssertEqual(caption.row, card.row + l.cardBandRows,
                           "\(numbers): the caption is on row \(caption.row), under the picture "
                           + "(\(card.row) + \(card.rows) = \(card.row + card.rows)), not on the "
                           + "band's floor (\(card.row) + \(l.cardBandRows) = "
                           + "\(card.row + l.cardBandRows))")
        }
    }

    /// The same numbers, printed, plus the split itself: `stageH = round(0.7 x budget)` and the band
    /// takes `budget - stageH - 1` (the -1 is the band's own caption row, §6.5), where
    /// `budget = rows - 6` with the divider. This half may be green on HEAD — it documents the split
    /// the first test says is being kept but not used.
    func testStageToBandSplitIsSevenToThree() {
        var table: [String] = []
        for pane in panes {
            let l = layout(pane)
            table.append(numbers(pane, l))
            let divider = l.dividerRow.isEmpty ? 0 : 1
            let budget = pane.rows - (5 + divider)
            XCTAssertEqual(l.stage.rows + l.cardBandRows + 1 + 5 + divider, pane.rows,
                           "\(numbers(pane, l)): the budget (stage + band + its caption + the five "
                           + "fixed rows + divider) is not spent exactly")
            XCTAssertEqual(l.footerRow, pane.rows,
                           "\(numbers(pane, l)): the footer is the pane's last row (§6.5)")
            if pane.stageAspect == nil {
                // The pure 7:3 split: no picture can shrink the stage, so it is exactly the round.
                XCTAssertEqual(l.stage.rows, Int((0.7 * Double(budget)).rounded()),
                               "\(numbers(pane, l)): stage \(l.stage.rows) of a \(budget)-row "
                               + "budget is not 7:3 (round(0.7 x \(budget)) = "
                               + "\(Int((0.7 * Double(budget)).rounded())))")
                XCTAssertEqual(l.cardBandRows, budget - l.stage.rows - 1,
                               "\(numbers(pane, l)): the band does not take the other 3 of the 7:3 "
                               + "split (\(budget) - \(l.stage.rows) - 1)")
            } else {
                // With a picture on stage the split is only ever corrected downwards: the rows a
                // 16:10 picture cannot use go to the band, never to the wall.
                let split = Int((0.7 * Double(budget)).rounded())
                XCTAssertLessThanOrEqual(l.stage.rows, split,
                                         "\(numbers(pane, l)): the picture handed the stage *more* "
                                         + "than its 7:3 share (\(split))")
                XCTAssertEqual(l.stage.rows + l.cardBandRows + 1, budget,
                               "\(numbers(pane, l)): the rows the stage does not need did not reach "
                               + "the band")
            }
        }
        print("--- the band's rows, per pane (#83) ---\n" + table.joined(separator: "\n"))
    }
}
