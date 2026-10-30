import XCTest
import krdcore
@testable import krd

/// Issue #113: a card's caption was drawn under *its box* instead of under its *picture*.
///
/// The two rectangles differ on the common wall: a 43x10 card box holding a square picture is 20
/// cells of picture centred in 43 cells of box, so a caption pinned to the box's left edge sits 11
/// cells out in the empty margin, under nothing.
///
/// This test builds the layout and the paints the way `main.swift` does — `WallPanels.plan` gives
/// the panels, `panel.slot` is 0 for the stage and `1 + cardIndex` for the cards — and then measures
/// where each caption row's text actually starts against where its own picture starts. It fails if
/// the painter reads the picture table with a different slot convention than the caller writes it
/// with (0-based caption enumeration vs 1-based panel slot), which is exactly issue #113.
final class BugWallCaptionOffsetTests: XCTestCase {
    private static let cols = 137
    private static let rows = 44
    private static let cellW = 8.0
    private static let cellH = 16.0

    /// Seven windows with distinct app and title strings, so a caption row says which window it
    /// belongs to and a misplacement cannot be excused as "the same text either way".
    private func model() -> WallModel {
        WallModel(
            displays: [
                WallDisplay(name: "Built-in", width: 1512, height: 982, main: true),
                WallDisplay(name: "DELL U2720Q", width: 1728, height: 1117, main: false),
                WallDisplay(name: "BenQ PD2700U", width: 1920, height: 1080, main: false),
            ],
            windows: (0..<7).map { i in
                OrderedWindow(windowID: UInt32(1000 + i), pid: Int32(500 + i),
                              app: "App\(i)", title: "title of window \(i)",
                              bounds: CGRectCompat(x: 0, y: 0, width: 1200, height: 800))
            })
    }

    /// The caption of slot `s` belongs to the panel whose `slot` is `s + 1`; the caption of the
    /// stage is a different row and not this test's business.
    func testEachCardCaptionStartsUnderItsOwnPicture() throws {
        // The production defaults: `per = 3`, both offsets 0. `let`, not `var`: nothing here
        // mutates the state, and an unmutated `var` is a compiler warning in a test that has to
        // build cleanly.
        let state = WallState()
        let layout = state.layout(cols: Self.cols, rows: Self.rows, displays: 3, windows: 7)
        XCTAssertEqual(layout.cardCaptions.count, 3, "137x44 with 3 cards must caption 3 of them")

        // The production sources: a wide stage, square cards. A square picture in a 43x10 box is
        // 20 cells wide, i.e. far narrower than its box - the displacement issue #113 is about.
        let panels = WallPanels.plan(
            layout: layout, cellW: Self.cellW, cellH: Self.cellH,
            stageSource: PanelSource(kind: .display(1), aspect: 1.78),
            cardSources: (0..<layout.cards.count).map { index in
                PanelSource(kind: .window(UInt32(10 + index)), aspect: 1.0)
            })

        // `main.swift`'s `paintWall`, verbatim: mark the slot, then record the picture's cells under
        // the *panel's* slot (1-based, stage excluded).
        var paints = WallSlotPaints()
        for panel in panels {
            paints.mark(slot: panel.slot, .picture)
            if panel.slot > 0 { paints.cardPictureCells[panel.slot] = panel.rect }
        }

        let lines = WallCanvas(symbols: .ascii).lines(
            cols: Self.cols, rows: Self.rows, model: model(), layout: layout, focus: nil,
            cellW: Self.cellW, cellH: Self.cellH, paints: paints)
        XCTAssertEqual(lines.count, Self.rows, "one string per pane row")

        for slot in 0...1 {
            let box = layout.cardCaptions[slot]
            let picture = try XCTUnwrap(panels.first { $0.slot == slot + 1 }?.rect,
                                        "slot \(slot) has no panel to hang its caption under")
            XCTAssertLessThan(picture.cols, box.cols,
                              "slot \(slot): the picture must be narrower than its box, "
                                + "or a caption under the box is under the picture too")
            // Where the text has to start: the picture's left edge, never outside the box.
            let expected = max(box.col, min(picture.col, box.maxCol))

            // Where it does start: the first non-blank cell of the caption row, searched from the
            // slot's own box (one row holds every slot's caption, so searching the whole row would
            // measure card 0's caption for every slot). `drawCards` cleared this box - it is painted
            // `.picture` - and nothing but the captions writes to this row.
            let row = Array(lines[box.row - 1])
            let actual = try XCTUnwrap(row[(box.col - 1)...].firstIndex { $0 != " " }.map { $0 + 1 },
                                       "slot \(slot): nothing was drawn on the caption row "
                                         + "from its box's left edge, column \(box.col)")
            // Which caption was measured: the app names are distinct, so a caption belonging to a
            // neighbouring card cannot pass for this one.
            let index = layout.cardStart + slot
            let tail = String(row[(actual - 1)...])
            XCTAssertTrue(tail.hasPrefix("\(WallSymbols.ascii.window) App\(index)"),
                          "slot \(slot): the text at column \(actual) is not window \(index)'s caption"
                            + " (row: \"\(tail)\")")

            print("issue #113 slot \(slot): box col \(box.col)..\(box.maxCol) (cols \(box.cols)), "
                  + "picture col \(picture.col)..\(picture.maxCol) (cols \(picture.cols)), "
                  + "expected first caption column \(expected), actual \(actual), "
                  + "displacement \(expected - actual)")

            XCTAssertEqual(
                actual, expected,
                "issue #113: slot \(slot)'s caption starts at column \(actual), "
                  + "but its picture starts at column \(expected) "
                  + "(picture rect col \(picture.col) cols \(picture.cols), "
                  + "box rect col \(box.col) cols \(box.cols), caption row \(box.row)); "
                  + "a caption pinned to the box instead of the picture reads as a label for "
                  + "nothing - or for the neighbouring card")
        }
    }
}
