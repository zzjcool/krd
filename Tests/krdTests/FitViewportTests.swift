import XCTest
@testable import krd
@testable import krdcore

/// The pointer must be mapped against where the picture is, not against the capture (issue #71).
///
/// The picture is placed in `paneCols x paneRows` cells -- which is not the frame's pixel size when
/// the terminal upscales (`fit > 1`) or when `--scale` sends fewer pixels -- and it is not the whole
/// pane either when the source's aspect leaves a band. `Viewport` is built from the placement, so a
/// click inside the picture lands where it looks and a click in the band is outside it.
final class FitViewportTests: XCTestCase {
    private let window = CGRect(x: 381, y: 277, width: 1024, height: 678)   // the reported window

    private func viewport(cols: Int, rows: Int, cellW: Double = 17, cellH: Double = 33,
                          scale: Double = 1) -> (Viewport, TileGrid) {
        let grid = TileGrid.make(paneCols: cols, paneRows: rows, cellW: cellW, cellH: cellH,
                                 aspect: window.width / window.height, tileCols: 8, tileRows: 4,
                                 bpp: 3, scale: scale, source: window.size)
        let viewport = Viewport(pixelWidth: grid.panePixelW, pixelHeight: grid.panePixelH,
                                cols: grid.paneCols, rows: grid.paneRows, sourceRect: window)
        return (viewport, grid)
    }

    func testTheCornersOfThePlacementAreTheCornersOfTheWindow() {
        for scale in [1.0, 0.5, 0.25] {
            let (viewport, grid) = viewport(cols: 70, rows: 24, scale: scale)
            XCTAssertEqual(grid.paneCols, 70, "scale \(scale)")
            XCTAssertEqual(viewport.point(forPixel: viewport.pixelWidth, viewport.pixelHeight),
                           CGPoint(x: window.maxX, y: window.maxY), "scale \(scale)")
            XCTAssertEqual(viewport.point(forPixel: 0, 0), CGPoint(x: window.minX, y: window.minY),
                           "scale \(scale)")
        }
    }

    /// The old failure mode, kept as a test: mapping against the *frame* instead of the placement
    /// moves every click, and the eye reads that as "the click lands to the left of where I
    /// clicked". Only `--scale` makes the two differ now - at full scale the frame *is* the
    /// placement box - so the half-scale case is what keeps the mapping honest.
    func testMappingAgainstTheFrameInsteadOfThePlacementWouldDrift() {
        let (correct, grid) = viewport(cols: 70, rows: 24, scale: 0.5)
        XCTAssertEqual(grid.pixelW, 595, "the frame is half the placement at --scale 0.5")
        let frame = Viewport(pixelWidth: grid.pixelW, pixelHeight: grid.pixelH,
                             cols: grid.paneCols, rows: grid.paneRows, sourceRect: window)
        let px = 1000                                   // most of the way across the placement
        let right = correct.point(forPixel: px, 400).x
        XCTAssertEqual(right, 381 + 1000.0 / 1190 * 1024, accuracy: 1)
        let wrong = frame.point(forPixel: px, 400).x
        XCTAssertGreaterThan(abs(wrong - right), 100,
                             "the frame-sized mapping is off by ~139 pt near the right edge")
    }

    func testClicksInTheAspectBandAreOutsideTheViewport() {
        // A wide, short pane: the picture keeps the window's aspect, so 47 columns are the terminal's.
        let (viewport, grid) = viewport(cols: 88, rows: 14)
        XCTAssertEqual(grid.paneCols, 41)
        XCTAssertTrue(viewport.contains(pixel: viewport.pixelWidth - 1, viewport.pixelHeight - 1))
        XCTAssertFalse(viewport.contains(pixel: viewport.pixelWidth + 1, 100),
                       "one pixel past the picture is not the window")
        XCTAssertFalse(viewport.contains(pixel: 100, viewport.pixelHeight + 1))
        XCTAssertFalse(viewport.contains(cell: 42, 5))
        XCTAssertTrue(viewport.contains(cell: 41, 14))
    }

    /// `--scale` must not move the pointer: fewer pixels, same placement, same mapping.
    func testTheMappingIsTheSameAtEveryScale() {
        let (full, _) = viewport(cols: 70, rows: 24, scale: 1)
        for scale in [0.5, 0.25] {
            let (small, _) = viewport(cols: 70, rows: 24, scale: scale)
            for pixel in [(0, 0), (595, 396), (1189, 791)] {
                XCTAssertEqual(full.point(forPixel: pixel.0, pixel.1),
                               small.point(forPixel: pixel.0, pixel.1), "\(pixel) at \(scale)")
            }
        }
    }

    /// A cell click (no SGR-Pixels mode) also lands inside the picture.
    func testCellClicksStayInsideTheWindow() {
        let (viewport, grid) = viewport(cols: 70, rows: 24)
        for cell in [(1, 1), (grid.paneCols / 2, grid.paneRows / 2), (grid.paneCols, grid.paneRows)] {
            let point = viewport.point(forCell: cell.0, cell.1)
            XCTAssertTrue(window.contains(point), "cell \(cell) mapped outside the window: \(point)")
        }
    }
}
