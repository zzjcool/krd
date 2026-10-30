import XCTest
@testable import krd
@testable import krdcore

/// The pointer has to use the same rect as the placement (issue #69).
///
/// This is the half of the bug that fails silently: the picture shrank to fit the window, but the
/// mapping kept spreading the pointer across the whole pane, so a click near the right edge of the
/// picture landed ~143 pt to its left. Building the viewport from the grid's *placement* box (not the
/// pane) is what keeps the two in step, and it is one line that nothing else would catch.
final class FitViewportTests: XCTestCase {
    private let window = CGRect(x: 358, y: 229, width: 1024, height: 678)   // the reported Safari window

    private func viewport(cols: Int, rows: Int, cellW: Double = 17, cellH: Double = 33,
                          scale: Double = 1) -> (Viewport, TileGrid) {
        let grid = TileGrid.make(paneCols: cols, paneRows: rows, cellW: cellW, cellH: cellH,
                                 aspect: window.width / window.height, tileCols: 8, tileRows: 4,
                                 bpp: 3, scale: scale, source: window.size)
        let viewport = Viewport(pixelWidth: grid.panePixelW, pixelHeight: grid.panePixelH,
                                cols: grid.paneCols, rows: grid.paneRows, sourceRect: window)
        return (viewport, grid)
    }

    func testTheRightEdgeOfThePictureMapsToTheRightEdgeOfTheWindow() {
        let (viewport, grid) = viewport(cols: 70, rows: 24)
        XCTAssertEqual(grid.paneCols, 61)
        // The far corner of the *picture* is the far corner of the window, not 143 pt short of it.
        let corner = viewport.point(forPixel: viewport.pixelWidth, viewport.pixelHeight)
        XCTAssertEqual(corner.x, window.maxX, accuracy: 0.5)
        XCTAssertEqual(corner.y, window.maxY, accuracy: 0.5)
        let centre = viewport.point(forPixel: viewport.pixelWidth / 2, viewport.pixelHeight / 2)
        XCTAssertEqual(centre.x, window.midX, accuracy: 1)
        XCTAssertEqual(centre.y, window.midY, accuracy: 1)
    }

    /// The old mapping was built from the pane box: same picture, pointer spread over 1190 px instead
    /// of 1037. This is that mistake, spelled out, so the test would fail if it came back.
    func testMappingAcrossThePaneBoxWouldMissByThePadding() {
        let (correct, _) = viewport(cols: 70, rows: 24)
        let paneBox = Viewport(pixelWidth: 70 * 17, pixelHeight: 24 * 33,
                               cols: 70, rows: 24, sourceRect: window)
        // The picture is 1024 px wide but the box is 1190, so the padded mapping sends the right
        // edge of the picture to 1024/1190 of the way across: 143 pt short, which is the number the
        // user reported as "clicking does not land where you click".
        let px = 1024
        XCTAssertEqual(correct.point(forPixel: 1037, 300).x, window.maxX, accuracy: 0.5,
                       "the picture's own box edge is the window's right edge")
        let wrong = paneBox.point(forPixel: px, 300).x
        XCTAssertEqual(window.maxX - wrong, 143, accuracy: 1, "the ~143 pt the user measured")
    }

    func testClicksLeftOfThePictureAreOutsideTheViewport() {
        let (viewport, _) = viewport(cols: 88, rows: 30)
        XCTAssertTrue(viewport.contains(pixel: 0, 0))
        XCTAssertTrue(viewport.contains(pixel: viewport.pixelWidth - 1, viewport.pixelHeight - 1))
        // The leftover cells are the terminal's, not the window's: a click there must be ignored
        // rather than posted to a guessed point.
        XCTAssertFalse(viewport.contains(pixel: viewport.pixelWidth + 1, 100))
        XCTAssertFalse(viewport.contains(pixel: 100, viewport.pixelHeight + 1))
        XCTAssertFalse(viewport.contains(cell: viewport.cols + 1, 10))
        XCTAssertFalse(viewport.contains(cell: 10, viewport.rows + 1))
    }

    /// `--scale` must not move the pointer, and the fit must not either: the two are independent
    /// (the cell box is the same at 1 and 0.5, the image is not).
    func testMappingIsTheSameAtEveryScaleAndFollowsTheFit() {
        let (full, fullGrid) = viewport(cols: 70, rows: 24, scale: 1)
        let (half, halfGrid) = viewport(cols: 70, rows: 24, scale: 0.5)
        XCTAssertEqual(fullGrid.paneCols, halfGrid.paneCols)
        XCTAssertNotEqual(fullGrid.pixelW, halfGrid.pixelW)
        for pixel in [(0, 0), (300, 200), (1036, 692)] {
            XCTAssertEqual(full.point(forPixel: pixel.0, pixel.1),
                           half.point(forPixel: pixel.0, pixel.1), "pixel \(pixel)")
        }
    }

    /// A cell click (no SGR-Pixels mode) also lands inside the picture, not in the padding.
    func testCellClicksStayInsideTheWindow() {
        let (viewport, grid) = viewport(cols: 70, rows: 24)
        for cell in [(1, 1), (grid.paneCols / 2, grid.paneRows / 2), (grid.paneCols, grid.paneRows)] {
            let point = viewport.point(forCell: cell.0, cell.1)
            XCTAssertTrue(window.contains(point), "cell \(cell) mapped outside the window: \(point)")
        }
    }
}
