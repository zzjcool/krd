import XCTest
@testable import krdcore

/// `--scale`: capture at a fraction of the pane's pixels (issue #60).
///
/// The whole feature is one arithmetic change, so the tests are about the invariants that make it
/// safe: the **placement** box and the **pane** pixel size must not move (the terminal upscales into
/// the same cells, and SGR-Pixels mouse coordinates are the pane's own grid, which is how the pointer
/// stays accurate), while the tile pixel rects must follow the scale exactly -- no gap, no overlap,
/// and a stride that `extract` can actually walk.
final class ScaleTests: XCTestCase {
    private let cellW = 17.0
    private let cellH = 33.0

    private func grid(scale: Double, cols: Int = 100, rows: Int = 40) -> TileGrid {
        TileGrid.make(paneCols: cols, paneRows: rows, cellW: cellW, cellH: cellH,
                      aspect: 1.6, tileCols: 8, tileRows: 4, bpp: 3, scale: scale)
    }

    func testHalfScaleAsksForHalfThePixels() {
        let full = grid(scale: 1)
        let half = grid(scale: 0.5)
        XCTAssertEqual(half.pixelW, Int((Double(full.paneCols) * cellW * 0.5).rounded()))
        XCTAssertEqual(half.pixelH, Int((Double(full.paneRows) * cellH * 0.5).rounded()))
        XCTAssertEqual(half.pixelW * 2, full.pixelW, accuracy: 2)
        // A quarter of the pixels, which is the 4x on the wire -- minus the framing that does not scale.
        XCTAssertLessThan(Double(half.pixelW * half.pixelH) / Double(full.pixelW * full.pixelH), 0.26)
    }

    func testPlacementCellsAndPanePixelsNeverMove() {
        let full = grid(scale: 1)
        for scale in [1.0, 0.5, 0.25] {
            let scaled = grid(scale: scale)
            XCTAssertEqual(scaled.paneCols, full.paneCols, "the picture must still fill the pane")
            XCTAssertEqual(scaled.paneRows, full.paneRows)
            XCTAssertEqual(scaled.panePixelW, full.panePixelW,
                           "SGR-Pixels coordinates are the pane's grid, not the captured image's")
            XCTAssertEqual(scaled.panePixelH, full.panePixelH)
            XCTAssertEqual(scaled.tilesX, full.tilesX)
            XCTAssertEqual(scaled.tilesY, full.tilesY)
        }
    }

    /// Every tile keeps the cell box it has at scale 1, and the pixel rects shrink inside it.
    func testTileCellBoxesAreUnchangedAndPixelsAreScaled() {
        let full = grid(scale: 1)
        let half = grid(scale: 0.5)
        for ty in 0..<full.tilesY {
            for tx in 0..<full.tilesX {
                let a = full.rect(tx, ty)
                let b = half.rect(tx, ty)
                XCTAssertEqual(b.col, a.col)
                XCTAssertEqual(b.row, a.row)
                XCTAssertEqual(b.cols, a.cols)
                XCTAssertEqual(b.rows, a.rows)
                XCTAssertEqual(b.x, Int((Double(a.x) * 0.5).rounded()), "tile (\(tx),\(ty)) x")
                XCTAssertEqual(b.y, Int((Double(a.y) * 0.5).rounded()), "tile (\(tx),\(ty)) y")
            }
        }
    }

    /// The tiles must partition the frame: no gap and no overlap, at every scale, otherwise the
    /// encoder either drops a column of pixels or reads the same byte twice.
    func testTilesCoverTheFrameExactly() {
        for scale in [1.0, 0.5, 0.25] {
            let grid = grid(scale: scale)
            var seen = Set<Int>()
            for ty in 0..<grid.tilesY {
                for tx in 0..<grid.tilesX {
                    let r = grid.rect(tx, ty)
                    XCTAssertGreaterThan(r.w, 0)
                    XCTAssertGreaterThan(r.h, 0)
                    XCTAssertLessThanOrEqual(r.x + r.w, grid.pixelW, "tile (\(tx),\(ty)) runs off the right")
                    XCTAssertLessThanOrEqual(r.y + r.h, grid.pixelH, "tile (\(tx),\(ty)) runs off the bottom")
                    for y in r.y..<(r.y + r.h) {
                        for x in r.x..<(r.x + r.w) {
                            XCTAssertTrue(seen.insert(y * grid.pixelW + x).inserted,
                                          "tile (\(tx),\(ty)) overlaps at \(x),\(y) (scale \(scale))")
                        }
                    }
                }
            }
            XCTAssertEqual(seen.count, grid.pixelW * grid.pixelH, "scale \(scale) leaves pixels out")
        }
    }

    /// `extract` walks the frame with `pixelW * bpp` as its stride, so a scaled grid has to slice the
    /// scaled frame -- this is what a wrong stride would break (and it looks like scrambled tiles,
    /// not like a crash).
    func testExtractReadsTheScaledFrameWithTheScaledStride() {
        let grid = grid(scale: 0.5)
        var frame = [UInt8](repeating: 0, count: grid.pixelW * grid.pixelH * grid.bpp)
        for y in 0..<grid.pixelH {
            for x in 0..<grid.pixelW {
                let i = (y * grid.pixelW + x) * grid.bpp
                frame[i] = UInt8(truncatingIfNeeded: x)
                frame[i + 1] = UInt8(truncatingIfNeeded: y)
                frame[i + 2] = UInt8(truncatingIfNeeded: x ^ y)
            }
        }
        for ty in 0..<grid.tilesY {
            for tx in 0..<grid.tilesX {
                let r = grid.rect(tx, ty)
                let tile = grid.extract(frame, rect: r)
                XCTAssertEqual(tile.count, r.w * r.h * grid.bpp)
                for row in 0..<r.h {
                    for col in 0..<r.w {
                        let i = (row * r.w + col) * grid.bpp
                        XCTAssertEqual(tile[i], UInt8(truncatingIfNeeded: r.x + col))
                        XCTAssertEqual(tile[i + 1], UInt8(truncatingIfNeeded: r.y + row))
                    }
                }
            }
        }
    }

    func testSillyScalesFallBackToNoScaling() {
        for scale in [0.0, -0.5, 2.0, Double.nan, Double.infinity] {
            XCTAssertEqual(grid(scale: scale).scale, 1, "scale \(scale) must not reach ScreenCaptureKit")
            XCTAssertEqual(grid(scale: scale).pixelW, grid(scale: 1).pixelW)
        }
    }
}
