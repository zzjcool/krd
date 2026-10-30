import XCTest
@testable import krdcore

/// The capture size comes from the source, not from the pane (issue #69).
///
/// The bug: `pixelW` was the pane box in pixels, so a 1024x678 window in a 1190x792 box was
/// requested as 1190x792. ScreenCaptureKit does not upscale a window into a bigger box — it draws
/// the window 1:1 in the top-left and pads with black (31.8 % of the frame in the reported case) —
/// while the pointer kept being mapped across the padding, which is why the window felt unoperable.
///
/// The rule these tests pin down: `fit = min(boxW/srcW, boxH/srcH, 1)`, the frame is the source at
/// that fit, the placement box is `ceil` of it in cells (anchored top-left, the rest of the pane left
/// alone), and the pointer rect is that same box.
final class FitTests: XCTestCase {
    private let safari = CGSize(width: 1024, height: 678)      // the window in the issue
    private let cell = (w: 17.0, h: 33.0)

    private func grid(_ cols: Int, _ rows: Int, source: CGSize, scale: Double = 1,
                      cellW: Double = 17, cellH: Double = 33) -> TileGrid {
        TileGrid.make(paneCols: cols, paneRows: rows, cellW: cellW, cellH: cellH,
                      aspect: source.width / source.height, tileCols: 8, tileRows: 4,
                      bpp: 3, scale: scale, source: source)
    }

    /// The four rows of the issue's table, all of which padded before this fix.
    func testWindowIsNeverAskedForMorePixelsThanItHas() {
        // 70x24 (the reported pane), 88x30 (much larger than the window), and 60x40 clipped.
        for (cols, rows) in [(70, 24), (88, 30), (60, 40)] {
            let grid = grid(cols, rows, source: safari)
            XCTAssertLessThanOrEqual(Double(grid.pixelW), safari.width + 1,
                                     "pane \(cols)x\(rows) asked for \(grid.pixelW) px of a 1024 px window")
            XCTAssertLessThanOrEqual(Double(grid.pixelH), safari.height + 1,
                                     "pane \(cols)x\(rows) asked for \(grid.pixelH) px of a 678 px window")
            // and it keeps the source's aspect, so there is nothing to letterbox either
            XCTAssertEqual(Double(grid.pixelW) / Double(grid.pixelH),
                           safari.width / safari.height, accuracy: 0.02)
        }
    }

    func testSmallWindowInABigPaneGetsAPlacementBoxJustAboveItsSize() {
        let grid = grid(88, 30, source: safari)
        XCTAssertEqual(grid.fit, 1)
        XCTAssertEqual(grid.pixelW, 1024)
        XCTAssertEqual(grid.pixelH, 678)
        XCTAssertEqual(grid.paneCols, 61, "ceil(1024 / 17)")
        XCTAssertEqual(grid.paneRows, 21, "ceil(678 / 33)")
        XCTAssertEqual(grid.boxCols, 88, "the box it was fitted into is still reported")
        XCTAssertEqual(grid.boxRows, 30)
        XCTAssertEqual(grid.paneCols * grid.paneRows < 88 * 30, true, "the rest of the pane is left over")
    }

    func testPlacementBoxIsTheCeilOfTheFittedImage() {
        for scale in [1.0, 0.5, 0.25] {
            let grid = grid(70, 24, source: safari, scale: scale)
            XCTAssertEqual(grid.paneCols, 61, "scale \(scale): the cell box must not move")
            XCTAssertEqual(grid.paneRows, 21)
            XCTAssertEqual(grid.pixelW, Int((1024 * scale).rounded()))
            XCTAssertEqual(grid.pixelH, Int((678 * scale).rounded()))
            XCTAssertEqual(grid.panePixelW, 61 * 17, "the terminal's pixel space is the cell box")
            XCTAssertEqual(grid.panePixelH, 21 * 33)
        }
    }

    /// A source bigger than the pane is downscaled into the box, as it always was.
    func testLargeSourceIsFittedIntoTheBox() {
        let display = CGSize(width: 1920, height: 1200)
        let grid = grid(70, 24, source: display)
        XCTAssertLessThan(grid.fit, 0.7)
        XCTAssertLessThanOrEqual(grid.pixelW, grid.boxW + 1)
        XCTAssertLessThanOrEqual(grid.pixelH, grid.boxH + 1)
        XCTAssertEqual(Double(grid.pixelW) / Double(grid.pixelH), 1.6, accuracy: 0.02)
        XCTAssertEqual(grid.paneCols, 70, "the box is still filled across")
    }

    /// No regression for the case that always worked: when the pane box *is* the screen's aspect, the
    /// frame must be exactly the pane box.
    func testMatchingAspectKeepsTheFrameEqualToThePaneBox() {
        let display = CGSize(width: 1920, height: 1200)          // 1.6
        let grid = grid(64, 20, source: display, cellW: 16, cellH: 32)   // 1024x640 = 1.6
        XCTAssertEqual(grid.boxW, 1024)
        XCTAssertEqual(grid.boxH, 640)
        XCTAssertEqual(grid.pixelW, 1024, "exactly the pane box, no rounding drift")
        XCTAssertEqual(grid.pixelH, 640)
        XCTAssertEqual(grid.paneCols, 64)
        XCTAssertEqual(grid.paneRows, 20)
    }

    /// A pane wider than the display no longer asks for pixels the display does not have.
    func testPaneBiggerThanTheDisplayIsClampedToTheDisplay() {
        let display = CGSize(width: 1920, height: 1200)
        let grid = grid(120, 45, source: display)
        XCTAssertEqual(grid.fit, 1)
        XCTAssertEqual(grid.pixelW, 1920)
        XCTAssertEqual(grid.pixelH, 1200)
        XCTAssertLessThan(grid.paneCols, 120, "and the picture stops there")
    }

    /// The tiles must partition the fitted frame exactly: a 1024-px image in a 1037-px box means the
    /// pixel rects cannot be `cells x cellW` any more.
    func testTilesStillPartitionTheFrameExactly() {
        for source in [safari, CGSize(width: 1920, height: 1200), CGSize(width: 640, height: 480)] {
            let grid = grid(70, 24, source: source)
            var seen = Set<Int>()
            for ty in 0..<grid.tilesY {
                for tx in 0..<grid.tilesX {
                    let r = grid.rect(tx, ty)
                    XCTAssertGreaterThan(r.w, 0)
                    XCTAssertGreaterThan(r.h, 0)
                    XCTAssertLessThanOrEqual(r.x + r.w, grid.pixelW, "tile (\(tx),\(ty)) runs off")
                    XCTAssertLessThanOrEqual(r.y + r.h, grid.pixelH, "tile (\(tx),\(ty)) runs off")
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

    /// A tile must not be squeezed: its image has to be within a pixel or two of the cell box it is
    /// placed in, or the terminal stretches some columns and not others.
    func testEveryTileImageMatchesItsCellBox() {
        let grid = grid(70, 24, source: safari)
        for ty in 0..<grid.tilesY {
            for tx in 0..<grid.tilesX {
                let r = grid.rect(tx, ty)
                let boxW = Double(r.cols) * grid.cellW
                let boxH = Double(r.rows) * grid.cellH
                XCTAssertEqual(Double(r.w), boxW, accuracy: max(2, boxW * 0.03),
                               "tile (\(tx),\(ty)) is squeezed: \(r.w) px into \(boxW) px of cells")
                XCTAssertEqual(Double(r.h), boxH, accuracy: max(2, boxH * 0.03),
                               "tile (\(tx),\(ty)) is squeezed: \(r.h) px into \(boxH) px of cells")
            }
        }
    }

    func testFitNoteIsSilentWhenTheFrameIsThePaneBox() {
        let display = CGSize(width: 1920, height: 1200)
        let grid = grid(64, 20, source: display, cellW: 16, cellH: 32)
        XCTAssertEqual(grid.fitNote, "", "nothing to explain: the frame is exactly the pane box")
    }

    func testFitNoteExplainsBothCases() {
        let small = grid(88, 30, source: safari)
        XCTAssertTrue(small.fitNote.contains("smaller than the pane box"), small.fitNote)
        XCTAssertTrue(small.fitNote.contains("27x9"), "88-61 and 30-21: \(small.fitNote)")
        let large = grid(70, 24, source: CGSize(width: 1920, height: 1200))
        XCTAssertTrue(large.fitNote.contains("fitted to"), large.fitNote)
    }
}
