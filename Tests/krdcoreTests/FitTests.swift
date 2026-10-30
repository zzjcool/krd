import XCTest
@testable import krdcore

/// `fit` is where the picture goes on screen; `--scale` is how many pixels we spend on it (issue #71).
///
/// Two rules that used to be one knot:
///  * the picture is placed as large as the pane allows (`fit = min(pane/src)`, which **may be > 1**
///    when the source is smaller than the pane — the terminal upscales it for free);
///  * the capture is the source at `min(fit, 1) x scale` — never more pixels than the source has
///    (ScreenCaptureKit pads instead of upscaling, #69) and never more because the pane grew.
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

    func testSmallWindowIsUpscaledToFillThePaneWithoutMorePixels() {
        for (cols, rows, fit) in [(70, 24, 1.162), (88, 30, 1.460), (120, 41, 1.992)] {
            let grid = grid(cols, rows, source: window)
            XCTAssertEqual(grid.fit, fit, accuracy: 0.002, "pane \(cols)x\(rows)")
            XCTAssertEqual(grid.pixelW, 1024, "the capture stays at the window's own pixels")
            XCTAssertEqual(grid.pixelH, 678)
            XCTAssertEqual(grid.paneCols, cols, "and the picture fills the pane")
            XCTAssertEqual(grid.paneRows, rows, "pane \(cols)x\(rows): the aspect binds the other way")
            XCTAssertGreaterThan(grid.panePixelW, 1024, "so the terminal draws it larger than it is")
        }
    }

    func testPanePixelBoxIsThePlacementNotTheCapture() {
        let grid = grid(70, 24, source: window)
        XCTAssertEqual(grid.panePixelW, 70 * 17)
        XCTAssertEqual(grid.panePixelH, 24 * 33)
        XCTAssertEqual(grid.pixelW, 1024)
        XCTAssertNotEqual(grid.pixelW, grid.panePixelW, "SGR pixels are the placement's, not the frame's")
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
            XCTAssertEqual(grid.pixelW, Int((1024 * scale).rounded()))
            XCTAssertEqual(grid.pixelH, Int((678 * scale).rounded()))
        }
    }

    /// The half of the invariant the user asked for: the picture is as big as the pane whether we
    /// send 1024 px or 256 px, because the terminal does the enlarging.
    func testAFullSizePictureNeverAsksForMoreThanTheSource() {
        for source in [window, display] {
            for scale in [1.0, 0.5, 0.25] {
                let grid = self.grid(70, 24, source: source, scale: scale)
                XCTAssertLessThanOrEqual(Double(grid.pixelW), source.width + 1,
                                         "\(source) at \(scale) asked for \(grid.pixelW) px")
                XCTAssertLessThanOrEqual(Double(grid.pixelH), source.height + 1)
            }
        }
    }

    // MARK: unchanged cases

    /// A source bigger than the pane is downscaled into it, exactly as before.
    func testLargeSourceIsFittedIntoThePane() {
        let grid = grid(70, 24, source: display)
        XCTAssertLessThan(grid.fit, 1)
        XCTAssertEqual(grid.pixelW, 1190)
        XCTAssertEqual(grid.pixelH, 744)
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

    /// The display mirror must not start capturing more than the screen because the pane grew.
    func testPaneBiggerThanTheDisplayStopsAtTheDisplay() {
        let grid = grid(120, 45, source: display)
        XCTAssertEqual(grid.pixelW, 1920)
        XCTAssertEqual(grid.pixelH, 1200)
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

    func testFitNoteSaysWhichCaseYouAreIn() {
        let upscaled = grid(70, 24, source: window)
        XCTAssertTrue(upscaled.fitNote.contains("stretches x1."), upscaled.fitNote)
        XCTAssertTrue(upscaled.fitNote.contains("1024x678 px in 70x24 cells"), upscaled.fitNote)
        let downscaled = grid(70, 24, source: display)
        XCTAssertTrue(downscaled.fitNote.contains("fitted to 0.620"), downscaled.fitNote)
        // At --scale 0.5 the screen size is the same and the stretch doubles: that is the number
        // that explains the softness, and it is why --scale is a bandwidth knob.
        let half = self.grid(70, 24, source: window, scale: 0.5)
        XCTAssertTrue(half.fitNote.contains("stretches x2."), half.fitNote)
        XCTAssertTrue(half.fitNote.contains("512x339 px in 70x24 cells"), half.fitNote)
    }
}
