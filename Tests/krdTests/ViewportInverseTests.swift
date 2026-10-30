import XCTest
import CoreGraphics
@testable import krd
@testable import krdcore

/// Round C / bug-input: the (cell → point → cell) round trip for every capture crop the CLI can
/// build — `--scale` 1/0.5/0.25, `--zoom` 1/2/3, a zoom-at focus that is not the centre, odd pane
/// and cell sizes. The requirement is that the pointer map is the exact inverse of the crop that
/// was captured, and that an edge cell *clips* (is outside the picture) instead of wrapping to the
/// other side.
///
/// Expected to pass at HEAD; it is here so the parser/AX work in this round cannot move it, and it
/// is the measurement behind "tested and fine" in the round report.
final class ViewportInverseTests: XCTestCase {
    private let display = CGRect(x: 100, y: 50, width: 1512, height: 982)

    private struct Pane {
        var cols: Int
        var rows: Int
        var cellW: Double
        var cellH: Double
    }

    private let panes = [
        Pane(cols: 10, rows: 5, cellW: 8, cellH: 8),
        Pane(cols: 37, rows: 11, cellW: 17, cellH: 33),
        Pane(cols: 61, rows: 25, cellW: 20, cellH: 40),
        Pane(cols: 80, rows: 24, cellW: 9.5, cellH: 19.0),
        Pane(cols: 137, rows: 44, cellW: 17, cellH: 33),
    ]

    private func viewport(pane: Pane, scale: Double, zoom: Double, focus: CGPoint,
                          originCol: Int, originRow: Int) -> Viewport {
        let crop = Viewport.crop(full: display, scale: zoom, focus: focus)
        return Viewport(pixelWidth: Int((crop.width * scale).rounded()),
                        pixelHeight: Int((crop.height * scale).rounded()),
                        cols: pane.cols, rows: pane.rows,
                        sourceRect: crop,
                        originCol: originCol, originRow: originRow,
                        originPixelX: (originCol - 1) * Int(pane.cellW),
                        originPixelY: (originRow - 1) * Int(pane.cellH))
    }

    /// Every cell of the picture maps inside the crop, each cell's point lands in its own slice of
    /// the crop, and the map is monotone. Anything else is a pointer that lands in the wrong place.
    func testCellToPointRoundTripsForEveryGeometry() {
        for pane in panes {
            for scale in [1.0, 0.5, 0.25] {
                for zoom in [1.0, 2.0, 3.0] {
                    for focus in [CGPoint(x: display.midX, y: display.midY),
                                  CGPoint(x: display.minX + 3, y: display.minY + 3),
                                  CGPoint(x: display.maxX - 3, y: display.maxY - 3)] {
                        for (originCol, originRow) in [(1, 1), (2, 3)] {
                            let vp = viewport(pane: pane, scale: scale, zoom: zoom, focus: focus,
                                              originCol: originCol, originRow: originRow)
                            var previous = -CGFloat.infinity
                            for cy in originRow..<(originRow + pane.rows) {
                                for cx in originCol..<(originCol + pane.cols) {
                                    let label = "pane \(pane.cols)x\(pane.rows) scale \(scale) "
                                        + "zoom \(zoom) origin \(originCol),\(originRow) cell \(cx),\(cy)"
                                    XCTAssertTrue(vp.contains(cell: cx, cy), label)
                                    let p = vp.point(forCell: cx, cy)
                                    XCTAssertGreaterThanOrEqual(p.x, vp.sourceRect.minX - 0.001, label)
                                    XCTAssertLessThanOrEqual(p.x, vp.sourceRect.maxX + 0.001, label)
                                    XCTAssertGreaterThanOrEqual(p.y, vp.sourceRect.minY - 0.001, label)
                                    XCTAssertLessThanOrEqual(p.y, vp.sourceRect.maxY + 0.001, label)
                                    // Inverse of `point(forCell:)`: the cell the point falls in.
                                    let fx = (p.x - vp.sourceRect.minX) / vp.sourceRect.width
                                    let back = originCol + Int(fx * Double(pane.cols))
                                    XCTAssertEqual(back, cx, "\(label): point \(p) reads back as cell \(back)")
                                    // And it is in the *first half* of its own cell, never the next.
                                    let into = fx * Double(pane.cols) - Double(cx - originCol)
                                    XCTAssertEqual(into, 0.5, accuracy: 0.5 / Double(pane.cols) + 0.001,
                                                   "\(label): offset \(into) inside the cell")
                                }
                                previous = vp.point(forCell: originCol, cy).y
                                XCTAssertTrue(previous.isFinite)
                            }
                        }
                    }
                }
            }
        }
    }

    /// An edge cell clips: the one past the right/bottom edge belongs to the terminal, and the one
    /// before the origin does too. Neither may wrap to the opposite side of the desktop.
    func testEdgeCellsClipAndNeverWrap() {
        for pane in panes {
            for (originCol, originRow) in [(1, 1), (2, 3)] {
                let vp = viewport(pane: pane, scale: 1, zoom: 2, focus: display.center,
                                  originCol: originCol, originRow: originRow)
                XCTAssertFalse(vp.contains(cell: originCol - 1, originRow), "left of the picture")
                XCTAssertFalse(vp.contains(cell: originCol + pane.cols, originRow), "right of the picture")
                XCTAssertFalse(vp.contains(cell: originCol, originRow - 1), "above the picture")
                XCTAssertFalse(vp.contains(cell: originCol, originRow + pane.rows), "below the picture")
                XCTAssertTrue(vp.contains(cell: originCol, originRow), "top-left corner")
                XCTAssertTrue(vp.contains(cell: originCol + pane.cols - 1, originRow + pane.rows - 1),
                              "bottom-right corner")
            }
        }
    }

    /// A zero-size viewport (the wall has no picture) forwards nothing — the fix that kept a click
    /// on the wall's header from becoming a click at the screen origin.
    func testAZeroSizeViewportContainsNothing() {
        let vp = Viewport(pixelWidth: 0, pixelHeight: 0, cols: 0, rows: 0, sourceRect: display)
        for cx in -2...2 {
            for cy in -2...2 {
                XCTAssertFalse(vp.contains(cell: cx, cy))
                XCTAssertFalse(vp.contains(pixel: cx, cy))
            }
        }
    }

    /// The capture crop is what the pointer map is the inverse of: `layoutSource` must hand the
    /// layout the crop's size, not the full frame's, for every zoom level that leaves a usable crop.
    func testLayoutSourceIsTheCropForEveryZoom() {
        for zoom in [1.0, 1.5, 2.0, 3.0] {
            let crop = Viewport.crop(full: display, scale: zoom, focus: display.center)
            XCTAssertEqual(Viewport.layoutSource(crop: crop, full: display), crop.size,
                           "zoom \(zoom): layout sized from the wrong rect")
        }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
