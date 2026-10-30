import XCTest
@testable import krd

/// `PaneGeometry` is the wall's only source of terminal geometry (design §6.9): the layout, the
/// capture size and the mouse mapping all come from one snapshot, so the properties worth pinning
/// are the ones a second source would have disagreed about.
final class PaneGeometryTests: XCTestCase {
    private let pane = PaneGeometry(cols: 137, rows: 44, cellW: 8, cellH: 16, dpr: 2,
                                    source: "test")

    /// `cellAspect` is a cell's **height over its width** - the shape `WallLayout.make` takes. The
    /// opposite convention compiles just as happily and silently fits every picture against a
    /// 1/4-as-tall cell, so it is worth a test.
    func testCellAspectIsHeightOverWidth() {
        XCTAssertEqual(pane.cellAspect, 2.0)                                  // 16 / 8
        var square = pane
        square.cellW = 10
        square.cellH = 10
        XCTAssertEqual(square.cellAspect, 1.0)
    }

    /// The quality factor multiplies *both* axes: a picture scaled on one axis only would be
    /// stretched, and `PanelImage.fit` would then fit a stretched aspect into the same box.
    func testThePictureCellScalesBothAxesByTheSameFactor() {
        let scaleTwo = pane.pictureCell(scale: 2)
        XCTAssertEqual(scaleTwo.w, 16)
        XCTAssertEqual(scaleTwo.h, 32)
        let half = pane.pictureCell(scale: 0.5)
        XCTAssertEqual(half.w, 4)
        XCTAssertEqual(half.h, 8)
        XCTAssertEqual(scaleTwo.w / scaleTwo.h, pane.cellW / pane.cellH, accuracy: 1e-12)
    }

    /// A resize report carries no new cell size: the snapshot keeps the cell it measured and takes
    /// the new grid. Re-measuring per tick is what made the wall ask `CSI 16t` once a second.
    func testAResizeKeepsTheCellAndTakesTheGrid() {
        let resized = pane.with(cols: 200, rows: 50)
        XCTAssertEqual(resized.cols, 200)
        XCTAssertEqual(resized.rows, 50)
        XCTAssertEqual(resized.cellW, pane.cellW)
        XCTAssertEqual(resized.cellH, pane.cellH)
        XCTAssertEqual(resized.source, pane.source)
    }

    /// A terminal that answers 0x0 for its grid (or a resize to nothing) must not divide by zero
    /// later: both axes are at least one cell.
    func testAGridIsNeverEmpty() {
        let empty = pane.with(cols: 0, rows: 0)
        XCTAssertEqual(empty.cols, 1)
        XCTAssertEqual(empty.rows, 1)
    }
}
