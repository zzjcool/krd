import XCTest
@testable import krd
@testable import krdcore
import CoreGraphics

/// The cell is the *terminal's*, the chrome budget only moves the box (issues #121, #146).
///
/// WHY: at 118x73 with the mirror's bar on, the pane can show 73 rows and the picture may use 72.
/// `krd` derived the cell from the *picture's* rows - `ws_ypixel / (73 - 1)` = 2409 / 72 = 33.46 px
/// instead of 2409 / 73 = 33.0 - so the frame came out 2006x1439 while it is drawn on a 2006x1419
/// cell box: 20 px taller than the cells that hold it. That is the "the frame is its cell box" rule of
/// #121 broken by one subtraction, and it is a *shape* bug: the aspect of the picture stops matching
/// the aspect of its cells. The fix has one derivation (`TermGeometry.cellSize`, which divides by the
/// terminal's own grid) and one new parameter for the picture's rows, so this file sweeps the two
/// against each other: whatever the budget, the cell must be the terminal's, and the frame must be
/// exactly `boxRows x cellH` pixels of it.
final class TileCellFromTerminalTests: XCTestCase {
    private let cols = 118
    /// The reporter's pane, its two neighbours, the golden 2409-square, and `(1000, 1001)` - the
    /// fractional case: no row count divides that height evenly, so the cell is 8.47 x 13.7 px and
    /// every `rounded()` in `make` has a fraction to hide in.
    private let panePixels: [(w: Int, h: Int)] = [(2006, 2409), (2006, 2376), (2067, 1452),
                                                 (1700, 990), (2409, 2409), (1000, 1001)]
    /// Whole cells at (2006, 2409)/(2006, 2376), a `--pane` grid, a small pane, and 5 rows.
    private let paneRowsList = [73, 72, 44, 24, 5]
    private let aspects: [Double] = [1.0, 1.414, 1.6, 0.5625, 3.0]

    override func setUp() {
        super.setUp()
        // `pinnedCell` is a static: a test that leaves it set rewrites every other test's cell.
        TermGeometry.pinnedCell = nil
    }

    override func tearDown() {
        TermGeometry.pinnedCell = nil
        super.tearDown()
    }

    /// 0 chrome (the wall at full height), the bar, the bar plus a panel, a tall bar, and one budget
    /// that leaves a single row for the picture - the budget may not reach the cell at any of them.
    private func chromeBudgets(paneRows: Int) -> [Int] { [0, 1, 2, 5, paneRows - 1] }

    private func geometry(_ px: (w: Int, h: Int), rows: Int) -> TermGeometry {
        TermGeometry(cols: cols, rows: rows, pixelWidth: px.w, pixelHeight: px.h)
    }

    private func layout(_ px: (w: Int, h: Int), rows: Int, chrome: Int, aspect: Double) -> TileGrid {
        TileGrid.make(geometry: geometry(px, rows: rows), rows: rows - chrome,
                      aspect: aspect, tileCols: 8, tileRows: 4)
    }

    func testTheCellIsTheTerminalsWhateverTheChromeBudgetIs() {
        for px in panePixels {
            for rows in paneRowsList {
                for chrome in chromeBudgets(paneRows: rows) {
                    for aspect in aspects {
                        let g = layout(px, rows: rows, chrome: chrome, aspect: aspect)
                        let label = "pane \(px.w)x\(px.h) rows \(rows) chrome \(chrome) aspect \(aspect)"
                        // 1. #146: the cell is the terminal's grid, never the picture's rows.
                        XCTAssertEqual(g.cellH, Double(px.h) / Double(rows), label)
                        XCTAssertEqual(g.cellW, Double(px.w) / Double(cols), label)
                        // 2. #121: the frame is exactly the cell box it is drawn on. `make` floors a
                        //    frame at 2 px, the one case where this cannot hold; the smallest cell in
                        //    this sweep is 13.56 px, so nothing here is degenerate and nothing is
                        //    skipped - the floor itself is asserted, so a later shrink is loud.
                        XCTAssertGreaterThanOrEqual((Double(g.boxRows) * g.cellH).rounded(), 2, label)
                        XCTAssertGreaterThanOrEqual((Double(g.boxCols) * g.cellW).rounded(), 2, label)
                        XCTAssertEqual(Double(g.pixelH), (Double(g.boxRows) * g.cellH).rounded(), label)
                        XCTAssertEqual(Double(g.pixelW), (Double(g.boxCols) * g.cellW).rounded(), label)
                    }
                }
            }
        }
    }

    /// A fixed aspect is a fixed box, so any change left over here is the budget leaking into the cell
    /// - which is exactly what #146 measured: 2409 / 72 = 33.46 against a real 33 px cell.
    func testTheChromeBudgetMovesNeitherTheCellNorTheFrame() {
        let px = (w: 2006, h: 2409)
        // aspect 1.6 wants 118x38 cells of 17x33 px, so 35 rows of chrome still leave it standing.
        let budgets = [0, 1, 2, 5, 30]
        let noChrome = layout(px, rows: 73, chrome: budgets[0], aspect: 1.6)
        XCTAssertEqual(noChrome.cellH, 33, "2409 / 73")
        XCTAssertEqual(noChrome.boxRows, 38, "the box is the picture's aspect, not the pane's rows")
        for chrome in budgets {
            let g = layout(px, rows: 73, chrome: chrome, aspect: 1.6)
            let label = "chrome \(chrome)"
            XCTAssertEqual(g.cellH, noChrome.cellH, label)
            XCTAssertEqual(g.cellW, noChrome.cellW, label)
            XCTAssertEqual(g.pixelH, noChrome.pixelH, label)
            XCTAssertEqual(g.pixelW, noChrome.pixelW, label)
            XCTAssertEqual(g.boxRows, noChrome.boxRows, label)
        }
        // The one budget that does eat into the picture: the box legitimately shrinks to a row, but
        // the cell must not follow it - divided by the picture's rows that cell would be 2409 px.
        let squeezed = layout(px, rows: 73, chrome: 72, aspect: 1.6)
        XCTAssertEqual(squeezed.boxRows, 1)
        XCTAssertEqual(squeezed.cellH, noChrome.cellH, "a one-row picture still has a 33 px cell")
        XCTAssertEqual(squeezed.pixelH, 33, "one row of 33 px, not a whole-pane frame on one row")
    }

    /// `--cell` is a pin, not a fallback: an operator who says 17x33 knows the cell their terminal
    /// will not answer for (#146). It has to answer (17, 33) and not what the pty measured.
    func testThePinnedCellBeatsTheMeasuredOne() {
        TermGeometry.pinnedCell = (w: 17, h: 33)
        let measured = geometry((w: 2006, h: 2409), rows: 73)
        XCTAssertEqual(measured.cellSize.w, 17)
        XCTAssertEqual(measured.cellSize.h, 33)
        // 2409/73 happens to *be* 33, so the pin is invisible on the reporter's own pane; on a
        // 72-row height (2376 px) the measurement is 32.55 and the pin is the only source of 33.
        let disagreeing = TermGeometry(cols: cols, rows: 73, pixelWidth: 2006, pixelHeight: 2376)
        XCTAssertEqual(disagreeing.cellSize.h, 33, "the pin wins over the measurement, not the reverse")
        XCTAssertNotEqual(disagreeing.cellSize.h, Double(2376) / 73, "the measurement it had to beat")
        let g = TileGrid.make(geometry: measured, rows: 73, aspect: 1.6, tileCols: 8, tileRows: 4)
        XCTAssertEqual(g.cellW, 17)
        XCTAssertEqual(g.cellH, 33)
    }

    /// No row budget yet means "the picture may use the whole pane", and then `paneRows` is the pane.
    /// This is the case #146's arithmetic is invisible in - which is why the bug survived until a bar
    /// took a row: the subtraction needs somewhere to happen.
    func testNoRowBudgetLaysOutTheWholePane() {
        let measured = geometry((w: 2006, h: 2409), rows: 73)
        let paneAspect = 17.0 * 118 / (33.0 * 73)
        let whole = TileGrid.make(geometry: measured, aspect: paneAspect, tileCols: 8, tileRows: 4)
        XCTAssertEqual(whole.paneRows, measured.rows)
        XCTAssertEqual(whole.paneCols, measured.cols)
        XCTAssertEqual(whole.cellH, 33, "2409 / 73 rows, exact")
        XCTAssertEqual(whole.pixelH, 2409)
        // One row of chrome and the whole-pane aspect no longer fits: the box shrinks, the cell does
        // not - and 2409 / 72 = 33.46 would have made this a 2409 px frame on 72 rows (#146).
        let narrowed = TileGrid.make(geometry: measured, rows: 72, aspect: paneAspect, tileCols: 8, tileRows: 4)
        XCTAssertEqual(narrowed.paneRows, 72)
        XCTAssertEqual(narrowed.cellH, whole.cellH, "the cell does not follow the budget")
        XCTAssertEqual(narrowed.pixelH, 2376, "72 rows of the same 33 px cell")
    }
}
