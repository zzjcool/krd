import XCTest
@testable import krd
@testable import krdcore

/// The pointer must not move when the picture is captured smaller (issue #60).
///
/// `--scale` changes how many pixels ScreenCaptureKit delivers, nothing else. SGR-Pixels mouse
/// coordinates come from the terminal's own grid (the pane), so the viewport has to be built from
/// `panePixelW/panePixelH` -- the *pane*, not the image. Built from the image instead, every click
/// would land at half the distance from the top-left corner: the exact bug this test pins down.
final class ScaleViewportTests: XCTestCase {
    private func viewport(for layout: TileGrid, source: CGRect) -> Viewport {
        Viewport(pixelWidth: layout.panePixelW, pixelHeight: layout.panePixelH,
                 cols: layout.paneCols, rows: layout.paneRows, sourceRect: source)
    }

    private func grid(scale: Double) -> TileGrid {
        TileGrid.make(paneCols: 100, paneRows: 40, cellW: 17, cellH: 33,
                      aspect: 1.6, tileCols: 8, tileRows: 4, bpp: 3, scale: scale)
    }

    func testSameTerminalPixelMapsToTheSameScreenPointAtAnyScale() {
        // A 2x zoomed crop, which is where the mapping is most sensitive: 1700x1056 px of pane,
        // 960x600 points of source.
        let source = CGRect(x: 480, y: 300, width: 960, height: 600)
        let full = viewport(for: grid(scale: 1), source: source)
        for scale in [0.5, 0.25] {
            let scaled = viewport(for: grid(scale: scale), source: source)
            for pixel in [(0, 0), (1, 1), (850, 660), (1700, 1320)] {
                XCTAssertEqual(scaled.point(forPixel: pixel.0, pixel.1),
                               full.point(forPixel: pixel.0, pixel.1),
                               "scale \(scale): pixel \(pixel) moved")
            }
            for cell in [(1, 1), (50, 20), (100, 40)] {
                XCTAssertEqual(scaled.point(forCell: cell.0, cell.1),
                               full.point(forCell: cell.0, cell.1),
                               "scale \(scale): cell \(cell) moved")
            }
        }
    }

    /// The failure mode this guards against, spelled out: a viewport built from the *captured*
    /// image size halves the distance from the origin, which is how "click, nothing happens, click
    /// 300 px away, wrong thing happens" looks.
    func testBuildingTheViewportFromCapturePixelsWouldHaveBeenWrong() {
        let source = CGRect(x: 480, y: 300, width: 960, height: 600)
        let half = grid(scale: 0.5)
        let correct = viewport(for: half, source: source)
        let wrong = Viewport(pixelWidth: half.pixelW, pixelHeight: half.pixelH,
                             cols: half.paneCols, rows: half.paneRows, sourceRect: source)
        // The pane is 100x32 cells of 17x33 px (the aspect fit trims the rows), i.e. 1700x1056 px,
        // so this is its centre.
        XCTAssertEqual(half.panePixelW, 1700)
        XCTAssertEqual(half.panePixelH, 1056)
        let pixel = (850, 528)
        let expected = correct.point(forPixel: pixel.0, pixel.1)
        XCTAssertEqual(expected.x, 960, accuracy: 0.5)      // 480 + 0.5 * 960
        XCTAssertEqual(expected.y, 600, accuracy: 0.5)      // 300 + 0.5 * 600
        XCTAssertEqual(wrong.point(forPixel: pixel.0, pixel.1).x, 1440, accuracy: 1,
                       "built from the captured width, the same pixel maps to the right edge")
    }
}
