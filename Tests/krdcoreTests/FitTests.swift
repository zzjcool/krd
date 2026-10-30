import XCTest
@testable import krdcore

/// `fit` is where the picture goes on screen; `--scale` is how many pixels we spend on it (issue #71).
///
///  * the picture is placed as large as the pane allows (`fit = min(pane/src)`, which **may be > 1**
///    when the source is smaller than the pane);
///  * the **frame is that placement's cell box** (`cols x cellW` by `rows x cellH`), at `--scale`
///    times that. The stream upscales to the request, so a display smaller than the pane is
///    delivered at the pane's pixels: measured 1920x1200 -> 2006x1254 with no dropped frames.
///    (The *screenshot* path cannot upscale - ScreenCaptureKit pads with black instead - which is
///    why the wall caps its request and scales the pixels itself. Two transports, two rules.)
///
/// The frame used to stop at the source's own pixels. That left a terminal which draws one image
/// pixel per device pixel (Rex) unable to fill its cells, and the shortfall showed up as a seam at
/// every tile row: nine black lines across the display page (§TROUBLESHOOTING 23g).
///
/// Everything the pointer depends on is the *placement*: its pixel rect is what the terminal draws
/// into, so it is what SGR-Pixels coordinates are mapped against.
final class FitTests: XCTestCase {
    private let window = CGSize(width: 1024, height: 678)      // the window in the issue
    private let display = CGSize(width: 1920, height: 1200)

    private func grid(_ cols: Int, _ rows: Int, source: CGSize, scale: Double = 1,
                      cellW: Double = 17, cellH: Double = 33) -> TileGrid {
        TileGrid.make(paneCols: cols, paneRows: rows, cellW: cellW, cellH: cellH,
                      aspect: source.width / source.height, tileCols: 8, tileRows: 4,
                      bpp: 3, scale: scale, source: source)
    }

    // MARK: the user's case: a window smaller than the pane fills the pane, for free

    func testSmallWindowFillsThePaneAndTheStreamIsAskedForThatManyPixels() {
        for (cols, rows, fit) in [(70, 24, 1.162), (88, 30, 1.460), (120, 41, 1.992)] {
            let grid = grid(cols, rows, source: window)
            XCTAssertEqual(grid.fit, fit, accuracy: 0.002, "pane \(cols)x\(rows)")
            XCTAssertEqual(grid.pixelW, grid.panePixelW, "the frame is the placement box")
            XCTAssertEqual(grid.pixelH, grid.panePixelH)
            XCTAssertGreaterThan(grid.pixelW, 1024, "so the stream upscales, it does not letterbox")
            XCTAssertEqual(grid.paneCols, cols, "and the picture fills the pane")
            XCTAssertEqual(grid.paneRows, rows, "pane \(cols)x\(rows): the aspect binds the other way")
        }
    }

    func testTheFrameIsThePlacementBoxUnlessScaleTakesPixelsAway() {
        let full = grid(70, 24, source: window)
        XCTAssertEqual(full.panePixelW, 70 * 17)
        XCTAssertEqual(full.panePixelH, 24 * 33)
        XCTAssertEqual(full.pixelW, full.panePixelW)
        // SGR-Pixels are the placement's: at --scale 0.5 the frame is half of it, and the pointer
        // must still address the whole box.
        let half = self.grid(70, 24, source: window, scale: 0.5)
        XCTAssertEqual(half.panePixelW, 70 * 17)
        XCTAssertEqual(half.pixelW, half.panePixelW / 2)
    }

    // MARK: --scale is bandwidth, not screen size

    func testScaleChangesThePixelsButNotWhereThePictureIs() {
        let base = grid(70, 24, source: window, scale: 1)
        for scale in [0.5, 0.25] {
            let grid = self.grid(70, 24, source: window, scale: scale)
            XCTAssertEqual(grid.paneCols, base.paneCols, "scale \(scale)")
            XCTAssertEqual(grid.paneRows, base.paneRows, "scale \(scale)")
            XCTAssertEqual(grid.panePixelW, base.panePixelW)
            XCTAssertEqual(grid.panePixelH, base.panePixelH)
            XCTAssertEqual(grid.pixelW, Int((Double(base.panePixelW) * scale).rounded()))
            XCTAssertEqual(grid.pixelH, Int((Double(base.panePixelH) * scale).rounded()))
        }
    }

    /// The half of the invariant the user asked for: the picture is as big as the pane whether we
    /// send 1190 px or 298 px, because the terminal does the enlarging.
    ///
    /// Note the *opposite* rule for the wall's screenshots (PanelCaptureTests): a screenshot request
    /// above the source's pixels comes back padded with black, so it must be capped; a stream
    /// request above them comes back upscaled, which is what the cells need.
    func testTheStreamIsAskedForTheBoxEvenWhenTheSourceIsSmaller() {
        for source in [window, display] {
            for scale in [1.0, 0.5, 0.25] {
                let grid = self.grid(70, 24, source: source, scale: scale)
                // The source's own pixel count does not enter: the cells do.
                XCTAssertEqual(Double(grid.pixelW), Double(grid.panePixelW) * scale, accuracy: 1,
                               "\(source) at \(scale) asked for \(grid.pixelW) px")
                XCTAssertEqual(Double(grid.pixelH), Double(grid.panePixelH) * scale, accuracy: 1)
            }
        }
    }

    // MARK: unchanged cases

    /// A source bigger than the pane is downscaled into it, exactly as before.
    func testLargeSourceIsFittedIntoThePane() {
        let grid = grid(70, 24, source: display)
        XCTAssertLessThan(grid.fit, 1)
        XCTAssertEqual(grid.pixelW, 1190)
        XCTAssertEqual(grid.pixelH, 759, "23 rows of 33 px, not the display's 1200 x 0.62")
        XCTAssertEqual(grid.paneCols, 70)
        XCTAssertEqual(grid.paneRows, 23)
    }

    /// No regression for the case that always worked: a pane box with the screen's aspect keeps the
    /// frame exactly the size of the box.
    func testMatchingAspectKeepsTheFrameEqualToThePaneBox() {
        let grid = grid(64, 20, source: display, cellW: 16, cellH: 32)   // 1024x640 = 1.6
        XCTAssertEqual(grid.boxW, 1024)
        XCTAssertEqual(grid.boxH, 640)
        XCTAssertEqual(grid.pixelW, 1024)
        XCTAssertEqual(grid.pixelH, 640)
        XCTAssertEqual(grid.paneCols, 64)
        XCTAssertEqual(grid.paneRows, 20)
        XCTAssertEqual(grid.fitNote, "", "nothing to explain: the frame is exactly the pane box")
    }

    /// A pane bigger than the display is captured at the pane's pixels: the cells need them, and the
    /// stream upscales. This is the case that used to leave nine seams.
    func testPaneBiggerThanTheDisplayIsCapturedAtThePaneBox() {
        let grid = grid(120, 45, source: display)
        XCTAssertEqual(grid.pixelW, 120 * 17)
        XCTAssertEqual(grid.pixelH, 39 * 33)
        XCTAssertGreaterThan(grid.fit, 1, "but it is drawn larger")
        XCTAssertEqual(grid.paneCols, 120)
        XCTAssertEqual(grid.paneRows, 39)
    }

    /// When the aspects differ the picture cannot fill both directions: the rest is the terminal's.
    func testAspectMismatchLeavesCellsToTheTerminal() {
        let grid = grid(88, 14, source: window)          // a wide, short pane
        XCTAssertEqual(grid.paneRows, 14)
        XCTAssertEqual(grid.paneCols, 41, "the width is what binds")
        XCTAssertLessThan(grid.paneCols, 88, "47 columns stay the terminal's")
        XCTAssertLessThan(grid.fit, 1)
    }

    // MARK: tiles

    /// The tiles must partition the frame exactly, and every tile must be stretched by the same
    /// factor: one that is squeezed differently is a visible seam.
    func testTilesPartitionTheFrameAndShareOneStretchFactor() {
        for source in [window, display, CGSize(width: 640, height: 480)] {
            for scale in [1.0, 0.5] {
                let grid = self.grid(70, 24, source: source, scale: scale)
                let stretchX = Double(grid.paneCols) * grid.cellW / Double(grid.pixelW)
                let stretchY = Double(grid.paneRows) * grid.cellH / Double(grid.pixelH)
                var seen = Set<Int>()
                for ty in 0..<grid.tilesY {
                    for tx in 0..<grid.tilesX {
                        let r = grid.rect(tx, ty)
                        XCTAssertGreaterThan(r.w, 0, "\(source) \(scale)")
                        XCTAssertGreaterThan(r.h, 0)
                        XCTAssertLessThanOrEqual(r.x + r.w, grid.pixelW, "tile \(tx),\(ty) runs off")
                        XCTAssertLessThanOrEqual(r.y + r.h, grid.pixelH)
                        XCTAssertEqual(Double(r.cols) * grid.cellW / Double(r.w), stretchX,
                                       accuracy: stretchX * 0.05,
                                       "tile \(tx),\(ty) is stretched differently: \(r.w) px into "
                                       + "\(Double(r.cols) * grid.cellW) px of cells")
                        XCTAssertEqual(Double(r.rows) * grid.cellH / Double(r.h), stretchY,
                                       accuracy: stretchY * 0.05)
                        for y in r.y..<(r.y + r.h) {
                            for x in r.x..<(r.x + r.w) {
                                XCTAssertTrue(seen.insert(y * grid.pixelW + x).inserted,
                                              "overlap at \(x),\(y) for \(source)")
                            }
                        }
                    }
                }
                XCTAssertEqual(seen.count, grid.pixelW * grid.pixelH, "pixels left out for \(source)")
            }
        }
    }

    // MARK: --debug

    func testFitNoteIsSilentUnlessScaleLeavesAStretch() {
        // The frame is the placement box, so a picture bigger or smaller than the source has
        // nothing for the terminal to stretch: neither case says anything.
        XCTAssertEqual(grid(70, 24, source: window).fitNote, "")
        XCTAssertEqual(grid(70, 24, source: display).fitNote, "")
        // At --scale 0.5 the screen size is the same and the stretch doubles: that is the number
        // that explains the softness, and it is why --scale is a bandwidth knob.
        let half = self.grid(70, 24, source: window, scale: 0.5)
        XCTAssertTrue(half.fitNote.contains("stretches x2."), half.fitNote)
        XCTAssertTrue(half.fitNote.contains("595x396 px in 70x24 cells"), half.fitNote)
    }
}
