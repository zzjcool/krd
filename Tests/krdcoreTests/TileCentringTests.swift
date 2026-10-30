import XCTest
import CoreGraphics
@testable import krdcore


/// A picture that does not fill its area is centred in it, not pinned to the top-left (design §6.7):
/// a window mirrored into a pane wider than the window's own pixels, or a pane taller than the
/// display's aspect, is the everyday case, and slack on one side only reads as a rendering bug.
final class TileGridCentringTests: XCTestCase {
    private func grid(aspect: Double, area: (top: Int, left: Int, cols: Int, rows: Int)?) -> TileGrid {
        TileGrid.make(paneCols: 20, paneRows: 10, cellW: 10, cellH: 10, aspect: aspect,
                      tileCols: 8, tileRows: 4, source: CGSize(width: 200, height: 100), area: area)
    }

    func testASmallPictureIsCentredInTheWholePane() {
        // No area given means the pane is the area. A 100x50 px source in a 200x100 px pane is the
        // half-size block that used to be pinned to the corner: 5 spare columns left and right, and
        // 2 spare rows above and below (5 rows of picture in 10).
        let g = grid(aspect: 1, area: nil)
        XCTAssertEqual(g.paneCols, 10)
        XCTAssertEqual(g.paneRows, 5)
        XCTAssertEqual(g.originCol, 1 + 5)
        XCTAssertEqual(g.originRow, 1 + 2)
        let first = g.rect(0, 0)
        XCTAssertEqual(first.col, 6)
        XCTAssertEqual(first.row, 3)
    }

    func testTheSlackIsSplitEvenly() {
        // A square picture in a 20x10 area: 10 columns of slack, so 5 on each side.
        let g = grid(aspect: 1, area: (top: 2, left: 3, cols: 20, rows: 10))
        XCTAssertEqual(g.paneCols, 10)
        XCTAssertEqual(g.paneRows, 5)
        XCTAssertEqual(g.originCol, 3 + 5, "centred inside the area, offset by its left edge")
        XCTAssertEqual(g.originRow, 2 + 2, "centred inside the area, offset by its top edge")
        XCTAssertEqual(g.rect(0, 0).col, 8)
        XCTAssertEqual(g.rect(0, 0).row, 4)
    }

    func testAnOddSpareCellGoesRightAndDown() {
        // 21 columns of area and a 10-column picture: 11 spare, 5 to the left, 6 to the right.
        let g = grid(aspect: 1, area: (top: 1, left: 1, cols: 21, rows: 10))
        XCTAssertEqual(g.originCol, 1 + 5)
        let last = g.paneCols + g.originCol - 1
        XCTAssertEqual(last, 15, "the picture never leaves its area")
        XCTAssertLessThanOrEqual(last + 1, 21 + 1)
    }

    func testTheBlockNeverExceedsItsArea() {
        // Height-limited: the block is 20 rows in a 10-row area, so it is clamped and not offset.
        let g = TileGrid.make(paneCols: 20, paneRows: 6, cellW: 10, cellH: 10, aspect: 2,
                              tileCols: 8, tileRows: 4, source: CGSize(width: 200, height: 100),
                              area: (top: 4, left: 1, cols: 20, rows: 6))
        XCTAssertLessThanOrEqual(g.paneRows, 6)
        XCTAssertEqual(g.originRow, 4)
        XCTAssertEqual(g.rect(0, 0).row + g.paneRows - 1, 4 + g.paneRows - 1)
    }
}
