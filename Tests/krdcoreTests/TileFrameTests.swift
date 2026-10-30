import XCTest
import CoreGraphics
@testable import krdcore


/// The frame's pixels are the picture's cells (design §6.9) - the same rule the wall's panels follow.
///
/// WHY this needs a test: a terminal that draws an image one image pixel per device pixel (Rex) cannot
/// stretch a frame into cells that are bigger than it. When the frame was the source's own pixels
/// (1920x1200) on a cell box of 2006x1254, the proportional tile split handed every tile a rect
/// ~6 % smaller than its cells, and the uncovered sliver showed the background: the user counted
/// **nine black lines** across the display page (ten tile rows, nine seams). Nothing else in the
/// suite notices, because the cells were right and only the pixels were short.
final class TileFrameTests: XCTestCase {
    /// The user's display page: 117 columns of 17 px and 38 rows of 33 px in front of a 1920x1200
    /// display, which is *larger* than the source - the case that produced the seams.
    private func displayPage(scale: Double = 1) -> TileGrid {
        TileGrid.make(paneCols: 117, paneRows: 72, cellW: 17, cellH: 33, aspect: 1.6,
                      tileCols: 8, tileRows: 4, scale: scale,
                      source: CGSize(width: 1920, height: 1200), area: nil)
    }

    func testTheFrameIsThePicturesCellBoxNotTheSourcesOwnPixels() {
        let g = displayPage()
        XCTAssertEqual(g.paneCols, 117)
        XCTAssertEqual(g.paneRows, 38, "1.6 aspect in 117x17 px is 1243 px, i.e. 38 rows of 33")
        XCTAssertEqual(g.pixelW, 117 * 17)
        XCTAssertEqual(g.pixelH, 38 * 33)
    }

    func testScaleIsTheOnlyThingThatTakesPixelsAway() {
        let half = displayPage(scale: 0.5)
        XCTAssertEqual(half.pixelW, Int((Double(117 * 17) * 0.5).rounded()))
        XCTAssertEqual(half.pixelH, Int((Double(38 * 33) * 0.5).rounded()))
        XCTAssertEqual(half.paneCols, 117, "--scale buys bandwidth, not less screen")
    }

    func testEveryTileCoversItsCellBox() {
        let g = displayPage()
        for ty in 0..<g.tilesY {
            for tx in 0..<g.tilesX {
                let r = g.rect(tx, ty)
                // A terminal drawing 1:1 leaves a seam wherever these two disagree, so one pixel of
                // rounding is the budget - not the six percent the old frame was short by.
                XCTAssertEqual(Double(r.w), Double(r.cols) * g.cellW, accuracy: 1,
                               "tile \(tx),\(ty): \(r.w) px for \(r.cols) cells")
                XCTAssertEqual(Double(r.h), Double(r.rows) * g.cellH, accuracy: 1,
                               "tile \(tx),\(ty): \(r.h) px for \(r.rows) cells")
                XCTAssertLessThanOrEqual(abs(r.x - (r.col - g.originCol) * Int(g.cellW)), 1)
            }
        }
    }

    func testTheTilesStillTileTheWholePicture() {
        // Proportional splitting exists so no pixel row or column is lost or doubled: the seams are
        // a rounding problem, not a licence to change the coverage arithmetic.
        let g = displayPage()
        let last = g.rect(g.tilesX - 1, g.tilesY - 1)
        XCTAssertEqual(last.x + last.w, g.pixelW)
        XCTAssertEqual(last.y + last.h, g.pixelH)
        XCTAssertEqual(g.rect(0, 0).x, 0)
        XCTAssertEqual(g.rect(0, 0).y, 0)
    }
}
