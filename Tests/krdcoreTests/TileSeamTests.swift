import XCTest
import CoreGraphics
@testable import krdcore

/// A tile's image is **that tile's own cell box** - and the seam issue #86 is made of is exactly the
/// case where that and "the tiles cover the frame" disagree.
///
/// WHY both claims in one place: the split this replaced (`i / cols x pixelW`, proportional to the
/// cells) satisfied coverage *by construction* and got the per-tile box wrong by a rounding at full
/// scale. A test that only pinned the sum would have waved that through. A terminal that draws one
/// image pixel per device pixel (Rex) cannot stretch the difference, so a tile image narrower than
/// its cells is a column of pane background at that tile's right edge - the shape of the reported
/// seam. Both claims hold exactly as long as a cell is at least one pixel at the capture scale, which
/// is the case for every real `--cell` and `--scale`; below that (see
/// `testADegenerateFrameIsClampedIntoItAndStillCovered`) the edges are clamped into the frame.
///
/// WHY the cell sizes are fractional too: a pty answers `ws_xpixel / ws_col`, so `cellW` is a fraction
/// unless the terminal happens to be an exact multiple of its own column count - and the two numbers
/// that have to agree (the tile's pixel rect and the cell box its placement covers) are then no longer
/// integers. That is the case where a proportional slice stops being the cell box.
final class TileSeamTests: XCTestCase {
    /// The reporter's display page, a tall pane, the golden dump's 80x24, and two where the pane's
    /// column count is not a multiple of the tile.
    private let panes = [(117, 72), (118, 73), (80, 24), (137, 44), (100, 40), (61, 25)]
    private let cells: [(Double, Double)] = [(17, 33), (16, 32), (8, 16),
                                             (16.75, 33), (17.03, 32.6), (9.5, 18.4)]
    private let scales: [Double] = [1, 0.9, 0.8]
    private let tiles = [(8, 4), (32, 16), (16, 8)]
    /// Integer cells: the tile's box is a whole number of device px, so its width can be stated
    /// without worrying about which side of a pixel a fractional edge falls on.
    private let integerCells: [(Double, Double)] = [(17, 33), (16, 32), (8, 16)]

    private func grid(_ pane: (Int, Int), _ cell: (Double, Double), scale: Double,
                      tile: (Int, Int), fillsCells: Bool = false) -> TileGrid {
        // The aspect that keeps the picture at the whole pane, so `paneCols/paneRows` are the pane
        // and `originCol/originRow` stay (1, 1): the seam is a tiling question, not a centring one.
        TileGrid.make(paneCols: pane.0, paneRows: pane.1,
                      cellW: cell.0, cellH: cell.1,
                      aspect: cell.0 * Double(pane.0) / (cell.1 * Double(pane.1)),
                      tileCols: tile.0, tileRows: tile.1, scale: scale,
                      fillsCells: fillsCells)
    }

    /// The device-pixel edge of a cell boundary, at the capture scale: the one arithmetic both
    /// `make` (for the frame) and `rect` (for the tiles) have to use.
    private func edge(_ cellIndex: Int, _ cell: Double, _ scale: Double) -> Int {
        Int((Double(cellIndex) * cell * scale).rounded())
    }

    func testEveryTileIsItsOwnCellBoxAndTheyStillCoverTheFrame() {
        for pane in panes {
            for cell in cells {
                for scale in scales {
                    for tile in tiles {
                        let g = grid(pane, cell, scale: scale, tile: tile)
                        let label = "pane \(pane.0)x\(pane.1) cell \(cell.0)x\(cell.1) "
                            + "scale \(scale) tile \(tile.0)x\(tile.1)"
                        var sumW = 0, sumH = 0
                        for ty in 0..<g.tilesY {
                            for tx in 0..<g.tilesX {
                                let r = g.rect(tx, ty)
                                let xEnd = tx * g.tileCols + r.cols
                                let yEnd = ty * g.tileRows + r.rows
                                // 1. The tile's image starts and ends where its cells do, in device
                                //    px. This is the half the seam lives in.
                                XCTAssertEqual(r.x, edge(tx * g.tileCols, cell.0, scale), label)
                                XCTAssertEqual(r.y, edge(ty * g.tileRows, cell.1, scale), label)
                                XCTAssertEqual(r.x + r.w,
                                               xEnd == g.paneCols ? g.pixelW : edge(xEnd, cell.0, scale),
                                               "tile \(tx),\(ty) right edge: \(label)")
                                XCTAssertEqual(r.y + r.h,
                                               yEnd == g.paneRows ? g.pixelH : edge(yEnd, cell.1, scale),
                                               "tile \(tx),\(ty) bottom edge: \(label)")
                                // ...and therefore never short of the box it is drawn in, which is
                                // what a 1:1 terminal shows as a gap.
                                XCTAssertEqual(Double(r.w), Double(r.cols) * cell.0 * scale,
                                               accuracy: 1, "tile \(tx),\(ty) width: \(label)")
                                XCTAssertEqual(Double(r.h), Double(r.rows) * cell.1 * scale,
                                               accuracy: 1, "tile \(tx),\(ty) height: \(label)")
                                if tx == 0 { sumH += r.h }
                                if ty == 0 { sumW += r.w }
                            }
                        }
                        // 2. The tiles are the frame: nothing dropped by `extract`, nothing read
                        //    twice by `dirty` - the other half of the same invariant.
                        XCTAssertEqual(sumW, g.pixelW, "columns do not add up to the frame: \(label)")
                        XCTAssertEqual(sumH, g.pixelH, "rows do not add up to the frame: \(label)")
                        XCTAssertEqual(g.rect(0, 0).x, 0, label)
                        XCTAssertEqual(g.rect(0, 0).y, 0, label)
                        let last = g.rect(g.tilesX - 1, g.tilesY - 1)
                        XCTAssertEqual(last.x + last.w, g.pixelW, label)
                        XCTAssertEqual(last.y + last.h, g.pixelH, label)
                    }
                }
            }
        }
    }

    /// At full scale and a whole-pixel cell the box *is* `cols x cellW`, so the equality is exact and
    /// not "within a pixel": that is the geometry every measured page has used.
    func testAtFullScaleAndAWholePixelCellTheBoxIsExact() {
        for pane in panes {
            for cell in integerCells {
                for tile in tiles {
                    let g = grid(pane, cell, scale: 1, tile: tile)
                    XCTAssertEqual(g.pixelW, Int((Double(g.paneCols) * cell.0).rounded()))
                    XCTAssertEqual(g.pixelH, Int((Double(g.paneRows) * cell.1).rounded()))
                    for ty in 0..<g.tilesY {
                        for tx in 0..<g.tilesX {
                            let r = g.rect(tx, ty)
                            XCTAssertEqual(Double(r.w), Double(r.cols) * cell.0)
                            XCTAssertEqual(Double(r.h), Double(r.rows) * cell.1)
                            XCTAssertEqual(Double(r.x), Double(tx * g.tileCols) * cell.0)
                            XCTAssertEqual(Double(r.y), Double(ty * g.tileRows) * cell.1)
                        }
                    }
                }
            }
        }
    }

    /// The decision issue #86 asks for: **while the tiles travel as placeholders, krd never sends a
    /// tile smaller than its cell box.** `fillsCells` is where that is enforced, so a `--scale` below
    /// 1 cannot leave a placeholder grid short of its cells no matter which caller forgets.
    func testAPlaceholderFrameIsNeverSmallerThanItsCells() {
        for pane in panes {
            for cell in cells {
                for scale in [1.0, 0.9, 0.8, 0.5, 0.25] {
                    for tile in tiles {
                        let full = grid(pane, cell, scale: 1, tile: tile)
                        let filled = grid(pane, cell, scale: scale, tile: tile, fillsCells: true)
                        let label = "pane \(pane.0)x\(pane.1) cell \(cell.0)x\(cell.1) "
                            + "scale \(scale) tile \(tile.0)x\(tile.1)"
                        XCTAssertEqual(filled.scale, 1, "a filled frame is not scaled: \(label)")
                        XCTAssertEqual(filled.pixelW, full.pixelW, label)
                        XCTAssertEqual(filled.pixelH, full.pixelH, label)
                        XCTAssertEqual(filled.paneCols, full.paneCols, label)
                        XCTAssertEqual(filled.paneRows, full.paneRows, label)
                        for ty in 0..<full.tilesY {
                            for tx in 0..<full.tilesX {
                                let a = full.rect(tx, ty)
                                let b = filled.rect(tx, ty)
                                XCTAssertGreaterThanOrEqual(b.w, a.w,
                                                            "tile \(tx),\(ty) is smaller than its cells: \(label)")
                                XCTAssertGreaterThanOrEqual(b.h, a.h,
                                                            "tile \(tx),\(ty) is smaller than its cells: \(label)")
                                XCTAssertEqual(b.w, a.w, "the cell box is the same at any scale: \(label)")
                                XCTAssertEqual(b.h, a.h, "the cell box is the same at any scale: \(label)")
                                XCTAssertEqual(b.x, a.x, label)
                                XCTAssertEqual(b.y, a.y, label)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A frame floored at 2 px, and a `--scale` small enough that several cells fit in one pixel:
    /// the edges are clamped into the frame. Nothing may be read past it (`extract` and `dirty`
    /// stride by `pixelW`), and every pixel still has to belong to a tile - the corner costs a
    /// one-pixel overlap, never an out-of-bounds `memcpy`.
    func testADegenerateFrameIsClampedIntoItAndStillCovered() {
        for g in [
            // 8 columns of 0.3 px: the frame is floored at 2 px and the pitch is a third of that.
            TileGrid.make(paneCols: 8, paneRows: 4, cellW: 0.3, cellH: 0.3,
                          aspect: 2, tileCols: 2, tileRows: 2),
            // The reviewer case: a real cell at `--scale 0.1`, so a cell is 0.8 px wide.
            TileGrid.make(paneCols: 13, paneRows: 38, cellW: 8, cellH: 16,
                          aspect: 8 * 13 / (16 * 38), tileCols: 2, tileRows: 4, scale: 0.1),
        ] {
            let label = "pane \(g.paneCols)x\(g.paneRows) cell \(g.cellW)x\(g.cellH) scale \(g.scale)"
            XCTAssertGreaterThan(g.tilesX, 1, "this test is about several tiles: \(label)")
            var covered = Set<Int>()
            for ty in 0..<g.tilesY {
                for tx in 0..<g.tilesX {
                    let r = g.rect(tx, ty)
                    XCTAssertGreaterThanOrEqual(r.x, 0, label)
                    XCTAssertGreaterThanOrEqual(r.y, 0, label)
                    XCTAssertGreaterThanOrEqual(r.w, 1, "tile \(tx),\(ty): \(label)")
                    XCTAssertGreaterThanOrEqual(r.h, 1, "tile \(tx),\(ty): \(label)")
                    XCTAssertLessThanOrEqual(r.x + r.w, g.pixelW, "tile \(tx),\(ty) reads past the frame: \(label)")
                    XCTAssertLessThanOrEqual(r.y + r.h, g.pixelH, "tile \(tx),\(ty) reads past the frame: \(label)")
                    for y in r.y..<(r.y + r.h) {
                        for x in r.x..<(r.x + r.w) {
                            covered.insert(y * g.pixelW + x)
                        }
                    }
                }
            }
            XCTAssertEqual(covered.count, g.pixelW * g.pixelH, "a pixel belongs to no tile: \(label)")
        }
    }
}
