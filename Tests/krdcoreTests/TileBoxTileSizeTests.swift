import XCTest
import CoreGraphics
@testable import krdcore

/// The picture's cell box - and therefore `fit`, `boxW`/`boxH` and the frame - must be the same
/// picture at any `--tile` (issue #143). `--tile` decides how the frame is *cut*, nothing else.
///
/// WHY this needs a test: `make` used to clamp the box *up* to at least one whole tile before it
/// computed `fit` (`max(tileCols, min(paneCols, cols))`, where the `max` undid the `min`). Whenever
/// the picture's box was smaller than one tile - a `--tile` bigger than the picture, or a pane
/// shorter/narrower than the tile - the box was then **bigger than the pane** and the fit came out
/// larger than the pane can hold. The `ceil` clamp only trimmed the *cells*, so the picture kept a
/// frame that was not its aspect. Measured with `--selftest`, cell 8x16, source 1440x2560:
///
///     pane 40x15, --tile 8x4    17x15 cells, fit 0.094, frame 136x240 px
///     pane 40x15, --tile 32x16  18x15 cells, fit 0.100, frame 144x240 px   <-- 6.3 % wider
///     pane 40x15, --tile 24x20  23x15 cells, fit 0.125, frame 184x240 px   <-- 36 % wide
///     pane 40x3,  --tile 8x4     5x3  cells, fit 0.025, frame  40x48 px    <-- 48 % wide, no flag
///
/// Nothing in the suite noticed, because every other grid test uses a pane much bigger than its
/// tile, where the floor never binds. What it costs is fidelity (the picture changes size and
/// horizontal scale with a protocol knob) and the invariant `boxCols <= paneCols` / `boxRows <=
/// paneRows` that the mouse mapping and the tile grid take for granted.
final class TileBoxTileSizeTests: XCTestCase {
    /// The issue's pane, panes shorter/narrower than the default 8x4 tile, the golden dump's 80x24,
    /// the reporter's display page, and the two degenerate single-cell panes.
    private let panes = [(40, 15), (40, 3), (40, 4), (7, 10), (5, 2), (40, 1), (1, 30),
                         (80, 24), (117, 72)]
    /// A whole cell, the pty's 17x33, and a fractional one (a pty answers `ws_xpixel / ws_col`).
    private let cells: [(Double, Double)] = [(8, 16), (17, 33), (16.75, 33)]
    private let sources = [
        CGSize(width: 1440, height: 2560),     // the issue's source: taller than any of these panes
        CGSize(width: 100, height: 50),        // smaller than one tile, so the whole picture is one
        CGSize(width: 1920, height: 1200),     // the display page
        CGSize(width: 50, height: 200),        // narrow enough that the columns leave the box alone
    ]
    /// Including tiles larger than the pane, than the picture, and 1x1.
    private let tiles = [(8, 4), (16, 8), (24, 20), (32, 16), (1, 1), (3, 2), (40, 20), (200, 200)]

    private func grid(pane: (Int, Int), cell: (Double, Double), source: CGSize,
                      tile: (Int, Int)) -> TileGrid {
        TileGrid.make(paneCols: pane.0, paneRows: pane.1, cellW: cell.0, cellH: cell.1,
                      aspect: source.width / source.height,
                      tileCols: tile.0, tileRows: tile.1, source: source)
    }

    /// The regression itself: same pane, same cell, same source, only `--tile` changes.
    func testTheCellBoxAndTheFitDoNotDependOnTheTileSize() {
        for pane in panes {
            for cell in cells {
                for source in sources {
                    let base = grid(pane: pane, cell: cell, source: source, tile: tiles[0])
                    for tile in tiles.dropFirst() {
                        let g = grid(pane: pane, cell: cell, source: source, tile: tile)
                        let label = "pane \(pane.0)x\(pane.1) cell \(cell.0)x\(cell.1) "
                            + "src \(Int(source.width))x\(Int(source.height)) "
                            + "tile \(tile.0)x\(tile.1) vs \(tiles[0].0)x\(tiles[0].1)"
                        XCTAssertEqual(g.paneCols, base.paneCols, "--tile moved the picture: \(label)")
                        XCTAssertEqual(g.paneRows, base.paneRows, "--tile moved the picture: \(label)")
                        XCTAssertEqual(g.boxCols, base.boxCols, label)
                        XCTAssertEqual(g.boxRows, base.boxRows, label)
                        XCTAssertEqual(g.boxW, base.boxW, label)
                        XCTAssertEqual(g.boxH, base.boxH, label)
                        XCTAssertEqual(g.fit, base.fit, accuracy: 0, "--tile changed the fit: \(label)")
                        XCTAssertEqual(g.fittedW, base.fittedW, label)
                        XCTAssertEqual(g.fittedH, base.fittedH, label)
                        XCTAssertEqual(g.pixelW, base.pixelW, "--tile resized the frame: \(label)")
                        XCTAssertEqual(g.pixelH, base.pixelH, "--tile resized the frame: \(label)")
                        XCTAssertEqual(g.originCol, base.originCol, label)
                        XCTAssertEqual(g.originRow, base.originRow, label)
                    }
                }
            }
        }
    }

    /// What the box *is*: the source's aspect in whole cells, fitted into the pane - never bigger
    /// than the pane, at any tile size. The tolerance is half a cell in the direction the aspect
    /// leaves slack in, which is exactly the rounding `make` does; anything larger is the tile floor
    /// coming back.
    func testTheBoxKeepsTheSourceAspectWithinACellAndStaysInsideThePane() {
        for pane in panes {
            for cell in cells {
                for source in sources {
                    for tile in tiles {
                        let g = grid(pane: pane, cell: cell, source: source, tile: tile)
                        let label = "pane \(pane.0)x\(pane.1) cell \(cell.0)x\(cell.1) "
                            + "src \(Int(source.width))x\(Int(source.height)) "
                            + "tile \(tile.0)x\(tile.1)"
                        // Never larger than the area it is fitted into: the mouse mapping and the
                        // tile grid both assume this.
                        XCTAssertLessThanOrEqual(g.boxCols, pane.0, "box wider than the pane: \(label)")
                        XCTAssertLessThanOrEqual(g.boxRows, pane.1, "box taller than the pane: \(label)")
                        XCTAssertLessThanOrEqual(g.paneCols, pane.0, label)
                        XCTAssertLessThanOrEqual(g.paneRows, pane.1, label)
                        // The frame is the picture's cells, so it cannot exceed the pane's pixels.
                        XCTAssertLessThanOrEqual(g.pixelW, Int((Double(pane.0) * cell.0).rounded()),
                                                 "frame wider than the pane: \(label)")
                        XCTAssertLessThanOrEqual(g.pixelH, Int((Double(pane.1) * cell.1).rounded()),
                                                 "frame taller than the pane: \(label)")
                        // ...and the box is the source's aspect fitted into the pane, to within the
                        // one rounding that makes it whole cells: one of its two pixel dimensions is
                        // the pane's (or the aspect's), the other is that value rounded to a cell. So
                        // each dimension is within one cell of the un-rounded fit - stated in pixels,
                        // because "within half a cell" in *cells* is 0.5 x cellH*aspect/cellW columns
                        // once the cell is not square, which is why an aspect ratio tolerance would
                        // either be too tight for a tall cell or too loose for the tile floor.
                        let fx = Double(pane.0) * cell.0, fy = Double(pane.1) * cell.1
                        let s = min(fx / source.width, fy / source.height)
                        XCTAssertLessThanOrEqual(
                            abs(Double(g.boxCols) * cell.0 - source.width * s), cell.0,
                            "box \(g.boxCols)x\(g.boxRows) cells is not the source's aspect: \(label)")
                        XCTAssertLessThanOrEqual(
                            abs(Double(g.boxRows) * cell.1 - source.height * s), cell.1,
                            "box \(g.boxCols)x\(g.boxRows) cells is not the source's aspect: \(label)")
                        XCTAssertEqual(g.boxW, max(1, Int((Double(g.boxCols) * cell.0).rounded())),
                                       "boxW is the box, not the tile: \(label)")
                        XCTAssertEqual(g.boxH, max(1, Int((Double(g.boxRows) * cell.1).rounded())),
                                       "boxH is the box, not the tile: \(label)")
                    }
                }
            }
        }
    }

    /// A box smaller than one tile is one tile, and it still has to tile the frame exactly - the
    /// half of #121 the tile floor was hiding, because a picture that fits in a single tile is the
    /// case where `rect` has the fewest cells to work with (`min(tileCols, paneCols - tx*tileCols)`
    /// is the whole box).
    func testAPictureSmallerThanOneTileStillTilesItsFrameExactly() {
        for source in sources {
            for pane in [(40, 15), (7, 3)] {
                for tile in tiles {
                    let g = grid(pane: pane, cell: (8, 16), source: source, tile: tile)
                    let label = "pane \(pane.0)x\(pane.1) src \(Int(source.width))x"
                        + "\(Int(source.height)) tile \(tile.0)x\(tile.1)"
                    if g.boxCols <= tile.0 && g.boxRows <= tile.1 {
                        XCTAssertEqual(g.count, 1, "a picture smaller than one tile is one tile: \(label)")
                    }
                    XCTAssertGreaterThanOrEqual(g.count, 1, label)
                    var sumW = 0, sumH = 0
                    for ty in 0..<g.tilesY {
                        for tx in 0..<g.tilesX {
                            let r = g.rect(tx, ty)
                            XCTAssertGreaterThanOrEqual(r.w, 1, "tile \(tx),\(ty): \(label)")
                            XCTAssertGreaterThanOrEqual(r.h, 1, "tile \(tx),\(ty): \(label)")
                            XCTAssertLessThanOrEqual(r.x + r.w, g.pixelW,
                                                     "tile \(tx),\(ty) reads past the frame: \(label)")
                            XCTAssertLessThanOrEqual(r.y + r.h, g.pixelH,
                                                     "tile \(tx),\(ty) reads past the frame: \(label)")
                            XCTAssertEqual(Double(r.w), Double(r.cols) * g.cellW,
                                           "tile \(tx),\(ty) is not its own cell box: \(label)")
                            XCTAssertEqual(Double(r.h), Double(r.rows) * g.cellH,
                                           "tile \(tx),\(ty) is not its own cell box: \(label)")
                            if ty == 0 { sumW += r.w }
                            if tx == 0 { sumH += r.h }
                        }
                    }
                    XCTAssertEqual(sumW, g.pixelW, "the columns do not add up to the frame: \(label)")
                    XCTAssertEqual(sumH, g.pixelH, "the rows do not add up to the frame: \(label)")
                }
            }
        }
    }

    /// The issue's own table, as numbers: the four `--tile` sizes on the 40x15 pane of `--selftest`,
    /// cell 8x16 and source 1440x2560 (`--debug` prints exactly these).
    func testTheIssueTableIsOneRowNow() {
        for tile in [(8, 4), (16, 8), (24, 20), (32, 16)] {
            let g = TileGrid.make(paneCols: 40, paneRows: 15, cellW: 8, cellH: 16,
                                  aspect: 1440.0 / 2560.0, tileCols: tile.0, tileRows: tile.1,
                                  source: CGSize(width: 1440, height: 2560))
            XCTAssertEqual(g.paneCols, 17, "tile \(tile.0)x\(tile.1)")
            XCTAssertEqual(g.paneRows, 15, "tile \(tile.0)x\(tile.1)")
            XCTAssertEqual(g.pixelW, 136, "tile \(tile.0)x\(tile.1)")
            XCTAssertEqual(g.pixelH, 240, "tile \(tile.0)x\(tile.1)")
            XCTAssertEqual(g.fit, 0.09375, accuracy: 1e-9, "tile \(tile.0)x\(tile.1)")
        }
    }
}
