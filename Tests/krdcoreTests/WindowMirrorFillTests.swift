import XCTest
import CoreGraphics
@testable import krdcore

/// Issue #84: clicking a window card on the wall opened the window mirror with the picture pinned to
/// the top-left at *80 % of the picture area*, the rest of the box plain background. That is the
/// self-same defect #86/#121 fixed for the display page, in the one page whose source is usually
/// **smaller than its cell box** - and it is the combination nothing pinned: `TileSeamTests` sweeps
/// `fillsCells` with no `source:` at all, `FitTests` sweeps sources with `fillsCells` off, so
/// "a placeholder grid, a `--scale` below 1 *and* a window for a source" was the untested corner.
///
/// The numbers are the report's: a 950x677 window in a 118x73 pane of 17x33 cells (Rex), `--scale
/// 0.8`, one row taken by the mirror's bar (design §6.8). Measured headlessly with the mock as the
/// frame source, on the commit before #121 that frame was **80 % of the cell box** (1605x1151 px in a
/// 2006x1439 px box, drawn at its top-left corner - exactly what the reporter photographed), and on
/// this tree it is the box itself. The tests below use a whole 17x33 cell, so the box is 2006x1419
/// here and the short frame 1605x1135; the 33.46 in the measurement is the pty's pixel height
/// divided by the 72 rows the bar leaves.
///
/// WHY the assertion is on *both* the frame and the cell box rather than a ratio: a terminal that
/// draws one image pixel per device pixel (Rex) cannot stretch a frame into cells it is not the size
/// of (measured: 14 vertical and 9 horizontal seams at `--scale 0.8`, issue #86), so the only two
/// numbers that matter are `pixelW/pixelH` and `paneCols x cellW` / `paneRows x cellH`, and they have
/// to be equal exactly - not "within a pixel".
final class WindowMirrorFillTests: XCTestCase {
    /// The reporter's window: 950x677 points of Safari. Its own size is what makes this case special -
    /// it is smaller than the box the pane offers, so the picture is *drawn* larger than the source.
    private let window = CGSize(width: 950, height: 677)
    /// 118x73 cells of 17x33 px, minus the one row the mirror's bar owns.
    private let pane = (cols: 118, rows: 72, cellW: 17.0, cellH: 33.0)

    /// The window mirror's layout, built the way `Desk.applyLayout` builds it: the aspect is the
    /// source's, the area is the pane below the bar, and the transport decides `fillsCells`.
    private func grid(scale: Double = 1, fillsCells: Bool, source: CGSize? = nil,
                      area: (top: Int, left: Int, cols: Int, rows: Int)? = nil) -> TileGrid {
        let source = source ?? window
        return TileGrid.make(paneCols: pane.cols, paneRows: pane.rows,
                             cellW: pane.cellW, cellH: pane.cellH,
                             aspect: source.width / source.height,
                             tileCols: 8, tileRows: 4, scale: scale, fillsCells: fillsCells,
                             source: source,
                             area: area ?? (top: 2, left: 1, cols: pane.cols, rows: pane.rows))
    }

    /// The bug itself. A placeholder grid cannot stretch, so the frame has to *be* the cell box even
    /// when `--scale` is below 1 and even though the source is smaller than the box.
    func testAWindowMirrorFillsItsPictureAreaOnATerminalThatCannotStretch() {
        let filled = grid(scale: 0.8, fillsCells: true)
        // The block: 43 rows of 33 px under a 118-column-wide picture (the window's 1.40 aspect is
        // wider than the pane's 1.41 cell grid, so the width is what binds).
        XCTAssertEqual(filled.paneCols, 118)
        XCTAssertEqual(filled.paneRows, 43)
        XCTAssertEqual(Double(filled.pixelW), Double(filled.paneCols) * pane.cellW,
                       "the frame is the picture's cell box, not 80 % of it")
        XCTAssertEqual(Double(filled.pixelH), Double(filled.paneRows) * pane.cellH)
        XCTAssertEqual(filled.pixelW, 2006)
        XCTAssertEqual(filled.pixelH, 1419)
        XCTAssertEqual(filled.scale, 1, "the scale in force is 1: a short frame is a gap in the box")
        XCTAssertGreaterThan(filled.fit, 2,
                             "and the picture is drawn larger than the source (950 -> 1991 px)")
    }

    /// The contrast that names the defect, and the reason `fillsCells` exists: on a transport that
    /// *does* stretch (a pixel placement, `a=p` with `c`/`r`), `--scale` is honoured and the terminal
    /// enlarges the short frame back into the cells. Both answers are deliberate; the bug was a
    /// placeholder grid getting the second one.
    func testTheSameWindowIsEightyPercentOfItsAreaWhereTheTransportCanStretchIt() {
        let scaled = grid(scale: 0.8, fillsCells: false)
        let box = grid(scale: 1, fillsCells: true)
        XCTAssertEqual(scaled.paneCols, box.paneCols, "where the picture is does not depend on --scale")
        XCTAssertEqual(scaled.paneRows, box.paneRows)
        XCTAssertEqual(scaled.originCol, box.originCol)
        XCTAssertEqual(scaled.originRow, box.originRow)
        // 0.8 x 2006 = 1604.8 and 0.8 x 1419 = 1135.2: the frame the reporter saw in the corner.
        XCTAssertEqual(scaled.pixelW, 1605)
        XCTAssertEqual(scaled.pixelH, 1135)
        XCTAssertEqual(Double(scaled.pixelW) / Double(box.pixelW), 0.8, accuracy: 0.001)
        XCTAssertEqual(Double(scaled.pixelH) / Double(box.pixelH), 0.8, accuracy: 0.001)
    }

    /// The half of the expected behaviour the issue states in words - "aspect preserved, centred when
    /// the box is wider" (design §6.6/§6.7) - for this page's own source. A display's block is the
    /// whole pane area; a window's is the largest cell rect with the window's aspect, and the rows the
    /// aspect leaves over are split above and below it.
    func testTheWindowAspectDecidesTheBlockAndTheSlackIsSplitEvenly() {
        let filled = grid(scale: 0.8, fillsCells: true)
        XCTAssertEqual(filled.originCol, 1, "the width binds, so there is no slack to centre")
        XCTAssertEqual(filled.originRow, 16, "2 (bar + first row) + (72 - 43) / 2")
        // 29 spare rows do not halve: integer halves floor, so the odd one goes below the picture -
        // the same rule every layout in this repo uses, and never all of it on one side.
        let above = filled.originRow - 2, below = pane.rows - filled.paneRows - above
        XCTAssertEqual(above, 14)
        XCTAssertEqual(below, 15)
        XCTAssertEqual(above + filled.paneRows + below, pane.rows)
        XCTAssertEqual(filled.boxCols, 118)
        XCTAssertEqual(filled.boxRows, 43)
    }

    /// A source whose aspect leaves *columns* over as well: a portrait window in the same pane. The
    /// block is centred horizontally and nothing is stretched to fill the rest - the cells outside the
    /// block belong to the terminal, and `Viewport` treats a click there as outside the picture.
    func testAPortraitWindowIsCentredInBothDirections() {
        let portrait = CGSize(width: 677, height: 950)
        let filled = grid(scale: 0.8, fillsCells: true, source: portrait)
        XCTAssertLessThan(filled.paneCols, pane.cols)
        XCTAssertEqual(filled.paneRows, 72)
        XCTAssertEqual(filled.originCol, 1 + (pane.cols - filled.paneCols) / 2)
        XCTAssertEqual(filled.originRow, 2, "the height binds")
        XCTAssertEqual(Double(filled.pixelW), Double(filled.paneCols) * pane.cellW)
        XCTAssertEqual(Double(filled.pixelH), Double(filled.paneRows) * pane.cellH)
    }

    /// ...and the filled frame is still tiled exactly, which is the other half of #86: the tile grid
    /// for this page is 15x11 (not 1x1), so a frame short of its cells shows as a gap at every tile
    /// - 165 of them - not as one band.
    func testTheFilledFrameIsPartitionedByItsTiles() {
        let filled = grid(scale: 0.8, fillsCells: true)
        XCTAssertEqual(filled.tilesX, 15)
        XCTAssertEqual(filled.tilesY, 11)
        XCTAssertEqual(filled.count, 165)
        var covered = Set<Int>()
        for ty in 0..<filled.tilesY {
            for tx in 0..<filled.tilesX {
                let r = filled.rect(tx, ty)
                XCTAssertEqual(Double(r.w), Double(r.cols) * pane.cellW, "tile \(tx),\(ty)")
                XCTAssertEqual(Double(r.h), Double(r.rows) * pane.cellH, "tile \(tx),\(ty)")
                for y in r.y..<(r.y + r.h) {
                    for x in r.x..<(r.x + r.w) { covered.insert(y * filled.pixelW + x) }
                }
            }
        }
        XCTAssertEqual(covered.count, filled.pixelW * filled.pixelH, "a pixel belongs to no tile")
    }

    /// The invariant over the panes a real window mirror lands in, not just the reporter's: from a
    /// narrow pane (where the window's aspect binds the height) to a wide one (where the pane's own
    /// cells bind the width), `fillsCells` never leaves a pixel of the cell box uncovered at any
    /// `--scale`. Before #121 every one of these sent `scale x cells` and left the difference as
    /// background.
    func testNoWindowSizeAndScalePairLeavesTheCellBoxShort() {
        let panes = [(118, 72), (61, 24), (70, 23), (137, 43), (40, 60)]
        let sources = [window, CGSize(width: 677, height: 950), CGSize(width: 1600, height: 900),
                       CGSize(width: 300, height: 300)]
        for (cols, rows) in panes {
            for source in sources {
                for scale in [1.0, 0.9, 0.8, 0.5] {
                    let g = TileGrid.make(paneCols: cols, paneRows: rows,
                                          cellW: pane.cellW, cellH: pane.cellH,
                                          aspect: source.width / source.height,
                                          tileCols: 8, tileRows: 4, scale: scale,
                                          fillsCells: true, source: source)
                    let label = "pane \(cols)x\(rows) source \(source) scale \(scale)"
                    XCTAssertEqual(Double(g.pixelW), Double(g.paneCols) * pane.cellW, label)
                    XCTAssertEqual(Double(g.pixelH), Double(g.paneRows) * pane.cellH, label)
                    XCTAssertLessThanOrEqual(g.paneCols, cols, label)
                    XCTAssertLessThanOrEqual(g.paneRows, rows, label)
                }
            }
        }
    }
}
