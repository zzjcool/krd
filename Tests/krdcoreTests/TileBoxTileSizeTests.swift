import XCTest
import CoreGraphics
@testable import krdcore

/// The picture's cell box and its `fit` must depend on the pane, the cell and the source's
/// aspect -- never on `--tile`. `TileGrid.make` clamps the *box* to at least one whole tile
/// before it computes `fit`, so a pane shorter than `tileRows` (or narrower than `tileCols`)
/// is fitted against a box that is larger than the pane: the frame comes out bigger than its
/// pane allows, and its cell rect no longer has the source's aspect.
///
/// Measured against `.build/release/krd --selftest --pane 40x15` (default `--source
/// 1440x2560`, cell 8x16):
///
///     --tile 8x4    fit 0.094  frame 136x240 px  grid 17x15 cells   (240 px of 15 rows)
///     --tile 16x8   fit 0.094  frame 136x240 px  grid 17x15 cells
///     --tile 32x16  fit 0.100  frame 144x240 px  grid 18x15 cells   <-- 6.3 % wider
///
/// 15 rows of 16 px is 240 px, so 240/2560 = 0.09375 is the only fit the pane can hold; the
/// 0.100 above comes from `boxH = max(tileRows, 15) x cellH = 16 x 16 = 256 px`.
final class TileBoxIndependentOfTileSizeTests: XCTestCase {
    private func grid(tileCols: Int, tileRows: Int, paneCols: Int = 40, paneRows: Int = 15) -> TileGrid {
        TileGrid.make(paneCols: paneCols, paneRows: paneRows, cellW: 8, cellH: 16,
                      aspect: 1440.0 / 2560.0, tileCols: tileCols, tileRows: tileRows,
                      source: CGSize(width: 1440, height: 2560))
    }

    /// The regression: the default tiling and a bigger tile must describe the same picture.
    func testTheCellBoxDoesNotChangeWithTheTileSize() {
        let eight = grid(tileCols: 8, tileRows: 4)
        let big = grid(tileCols: 32, tileRows: 16)
        XCTAssertEqual(eight.paneCols, 17)
        XCTAssertEqual(eight.paneRows, 15)
        XCTAssertEqual(big.paneCols, eight.paneCols,
                       "--tile 32x16 drew the picture \(big.paneCols) cells wide, --tile 8x4 \(eight.paneCols)")
        XCTAssertEqual(big.paneRows, eight.paneRows)
        XCTAssertEqual(big.pixelW, eight.pixelW, "frame width followed --tile")
        XCTAssertEqual(big.pixelH, eight.pixelH, "frame height followed --tile")
        XCTAssertEqual(big.fit, eight.fit, accuracy: 1e-9)
        XCTAssertEqual(big.originCol, eight.originCol)
    }

    /// Whatever the tile size, the picture must keep the source's aspect to within one cell in
    /// each direction -- and it must never claim a box taller or wider than the pane.
    func testTheBoxKeepsTheAspectAndFitsThePane() {
        for tileCols in [1, 3, 4, 8, 16, 24, 32, 40] {
            for tileRows in [1, 2, 4, 8, 15, 16, 20] {
                let g = grid(tileCols: tileCols, tileRows: tileRows)
                XCTAssertLessThanOrEqual(g.paneCols, 40, "tile \(tileCols)x\(tileRows): box wider than the pane")
                XCTAssertLessThanOrEqual(g.paneRows, 15, "tile \(tileCols)x\(tileRows): box taller than the pane")
                XCTAssertLessThanOrEqual(g.boxCols, 40, "tile \(tileCols)x\(tileRows): boxCols \(g.boxCols) > pane")
                XCTAssertLessThanOrEqual(g.boxRows, 15, "tile \(tileCols)x\(tileRows): boxRows \(g.boxRows) > pane")
                // aspect: the placement box in device px vs the source's own
                let boxAspect = Double(g.paneCols) * 8 / (Double(g.paneRows) * 16)
                XCTAssertEqual(boxAspect, 1440.0 / 2560.0, accuracy: 0.07,
                               "tile \(tileCols)x\(tileRows): box \(g.paneCols)x\(g.paneRows) cells is not the source's aspect")
            }
        }
    }
}
