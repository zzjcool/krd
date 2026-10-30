import XCTest
import krdcore

/// The picture maths: fit, dominant colour, composite.
///
/// These are the parts a reader can see and CI can check. The capture itself needs a screen and a
/// grant, so everything up to and after it is pure on purpose - the pixels are asserted here, and
/// the only thing left untested is "did ScreenCaptureKit hand us a picture", which the VM run and
/// the mask fallback cover.
final class PanelImageTests: XCTestCase {
    private let band = CellRect(col: 1, row: 1, cols: 135, rows: 24)

    // MARK: fit

    func testLandscapeIsHeightBoundInAWideBand() {
        let fit = PanelImage.fit(aspect: 1.6, in: band, cellW: 17, cellH: 33)
        // Height-bound: all 24 rows, and the width is the aspect's - 1275 px, which is exactly the
        // 75 cells the cell rect got. Cells decide pixels, so the two cannot differ (see `fit`).
        XCTAssertEqual(fit.cellRect, CellRect(col: 1 + (135 - 75) / 2, row: 1, cols: 75, rows: 24))
        XCTAssertEqual(fit.contentHeight, 24 * 33)          // the whole cell box, not 792
        XCTAssertEqual(fit.contentWidth, 75 * 17)           // 1275
        // The panel *is* the picture: nothing is placed inside it (design §6.6).
        XCTAssertEqual(fit.originX, 0)
        XCTAssertEqual(fit.originY, 0)
    }

    func testPortraitStaysHeightBoundAndNarrow() {
        let fit = PanelImage.fit(aspect: 1200.0 / 1920.0, in: band, cellW: 17, cellH: 33)
        XCTAssertEqual(fit.cellRect.cols, 29)
        XCTAssertEqual(fit.cellRect.rows, 24)
        XCTAssertEqual(fit.contentHeight, 24 * 33)
        XCTAssertEqual(fit.contentWidth, 29 * 17)
    }

    func testANarrowBandIsWidthBound() {
        let fit = PanelImage.fit(aspect: 1.6, in: CellRect(col: 0, row: 0, cols: 20, rows: 40),
                                 cellW: 17, cellH: 33)
        // Width-bound: all 20 columns, and the height is the aspect's - rounded to whole cells, since
        // a cell is the smallest thing the layout can be wrong by.
        XCTAssertEqual(fit.cellRect.cols, 20)
        XCTAssertEqual(fit.contentWidth, 20 * 17)
        XCTAssertEqual(fit.contentHeight, fit.cellRect.rows * 33)
        XCTAssertEqual(fit.cellRect.rows, 6)                // 340 / 1.6 = 212.5 px -> 6.4 rows, rounded
        XCTAssertEqual(fit.originX, 0)
        XCTAssertEqual(fit.originY, 0)
    }

    /// The invariant every picture geometry bug came from breaking: **the picture's pixels are its
    /// cell rectangle**, and it sits at the panel's origin. A picture a few pixels wider than its box
    /// is a gap on a terminal that draws 1:1 and a 1-2% stretch on one that scales.
    func testThePicturesPixelsAreExactlyItsCells() {
        let cases: [(Double, CellRect, Double, Double)] = [
            (1.6, band, 17, 33),
            (1200.0 / 1920.0, band, 17, 33),
            (1.6, CellRect(col: 0, row: 0, cols: 20, rows: 40), 17, 33),
            (21.0 / 9.0, CellRect(col: 3, row: 5, cols: 137, rows: 42), 8, 16),
            (1.0, CellRect(col: 1, row: 1, cols: 3, rows: 2), 16.7, 32.7)
        ]
        for (aspect, rect, cellW, cellH) in cases {
            let fit = PanelImage.fit(aspect: aspect, in: rect, cellW: cellW, cellH: cellH)
            XCTAssertEqual(Double(fit.contentWidth), Double(fit.cellRect.cols) * cellW,
                           accuracy: 0.5, "aspect \(aspect)")
            XCTAssertEqual(Double(fit.contentHeight), Double(fit.cellRect.rows) * cellH,
                           accuracy: 0.5, "aspect \(aspect)")
            XCTAssertEqual(fit.originX, 0)
            XCTAssertEqual(fit.originY, 0)
            // The cell rect stays inside the band, and the picture inside the cell rect's cells.
            XCTAssertLessThanOrEqual(fit.cellRect.maxCol, rect.maxCol)
            XCTAssertLessThanOrEqual(fit.cellRect.maxRow, rect.maxRow)
        }
    }

    func testUnusableInputsGiveAnEmptyFit() {
        XCTAssertTrue(PanelImage.fit(aspect: 0, in: band, cellW: 17, cellH: 33).isEmpty)
        XCTAssertTrue(PanelImage.fit(aspect: .nan, in: band, cellW: 17, cellH: 33).isEmpty)
        XCTAssertTrue(PanelImage.fit(aspect: 1.6, in: CellRect(col: 0, row: 0, cols: 0, rows: 4),
                                     cellW: 17, cellH: 33).isEmpty)
        XCTAssertTrue(PanelImage.fit(aspect: 1.6, in: band, cellW: 0, cellH: 0).isEmpty)
    }

    // MARK: composite

    /// The bars are transparent: an RGBA canvas, alpha 0 outside the picture and 255 inside it.
    func testTheBarsAreTransparentAndThePictureIsCentred() {
        let content = [UInt8](repeating: 7, count: 2 * 2 * 3)          // a 2x2 picture
        let canvas = PanelImage.compose(content: content, width: 2, height: 2,
                                        panelWidth: 6, panelHeight: 4, originX: 2, originY: 1)
        XCTAssertEqual(canvas.count, 6 * 4 * 4)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let o = (y * 6 + x) * 4
            return Array(canvas[o..<o + 4])
        }
        XCTAssertEqual(pixel(0, 0), [0, 0, 0, 0])        // bar: transparent, not black
        XCTAssertEqual(pixel(1, 1), [0, 0, 0, 0])        // bar row above the picture
        XCTAssertEqual(pixel(2, 1), [7, 7, 7, 255])      // first picture pixel, opaque
        XCTAssertEqual(pixel(3, 2), [7, 7, 7, 255])      // last picture pixel
        XCTAssertEqual(pixel(4, 2), [0, 0, 0, 0])        // bar on the right
        XCTAssertEqual(pixel(5, 3), [0, 0, 0, 0])
    }

    func testAContentBiggerThanThePanelIsClippedNotScaled() {
        // 4x4 of 5s into a 2x2 panel at (0,0): the top-left corner survives, nothing is resampled.
        let content = [UInt8](repeating: 5, count: 4 * 4 * 3)
        let canvas = PanelImage.compose(content: content, width: 4, height: 4,
                                        panelWidth: 2, panelHeight: 2, originX: 0, originY: 0)
        XCTAssertEqual(canvas.count, 2 * 2 * 4)
        for i in stride(from: 0, to: canvas.count, by: 4) {
            XCTAssertEqual(Array(canvas[i..<i + 3]), [5, 5, 5])
            XCTAssertEqual(canvas[i + 3], 255)
        }
        // Pushed off the panel entirely: everything stays transparent, nothing is written out of
        // bounds and the alpha never becomes garbage.
        let offscreen = PanelImage.compose(content: content, width: 4, height: 4,
                                           panelWidth: 2, panelHeight: 2,
                                           originX: 99, originY: -99)
        XCTAssertEqual(offscreen, [UInt8](repeating: 0, count: 2 * 2 * 4))
    }

    func testAnEmptyContentLeavesTheWholePanelClear() {
        let canvas = PanelImage.compose(content: [], width: 0, height: 0,
                                        panelWidth: 3, panelHeight: 2, originX: 0, originY: 0)
        XCTAssertEqual(canvas, [UInt8](repeating: 0, count: 3 * 2 * 4))
    }
}

/// `maxHeight` is how a row of cards agrees on one height (design §6.6): it lowers a picture without
/// changing its aspect or its centre.
final class PanelImageHeightCapTests: XCTestCase {
    private let rect = CellRect(col: 1, row: 1, cols: 44, rows: 14)

    func testACapLowersThePictureAndKeepsItsShape() {
        let full = PanelImage.fit(aspect: 1.0, in: rect, cellW: 17, cellH: 33)
        let capped = PanelImage.fit(aspect: 1.0, in: rect, cellW: 17, cellH: 33,
                                     maxHeight: full.contentHeight - 60)
        // A cap lowers the picture: fewer rows, a square stays square to within the cell the layout is
        // quantised in, and the panel is still exactly the picture (no offset inside it).
        XCTAssertLessThan(capped.cellRect.rows, full.cellRect.rows)
        // Square stays square to within one cell per axis: a cell is 17x33, so a 24x12-cell picture
        // is 408x396 px. That is the layout's quantisation, not a crop or a stretch.
        let aspect = Double(capped.contentWidth) / Double(capped.contentHeight)
        XCTAssertEqual(aspect, 1.0, accuracy: 0.04, "a square cap stays square")
        XCTAssertEqual(capped.contentHeight, capped.cellRect.rows * 33)
        XCTAssertEqual(capped.contentWidth, capped.cellRect.cols * 17)
        XCTAssertEqual(capped.originX, 0)
        XCTAssertEqual(capped.originY, 0)
    }

    func testACapAboveTheFitChangesNothing() {
        let full = PanelImage.fit(aspect: 1.62, in: rect, cellW: 17, cellH: 33)
        let capped = PanelImage.fit(aspect: 1.62, in: rect, cellW: 17, cellH: 33,
                                     maxHeight: full.contentHeight + 100)
        XCTAssertEqual(capped, full)
        XCTAssertEqual(PanelImage.fit(aspect: 1.62, in: rect, cellW: 17, cellH: 33, maxHeight: nil),
                       full)
    }

    func testACapNeverLeavesThePanel() {
        let capped = PanelImage.fit(aspect: 3.0, in: rect, cellW: 17, cellH: 33, maxHeight: 100)
        // The cap is honoured to the nearest cell: 100 px is three rows of 33 px.
        XCTAssertEqual(capped.cellRect.rows, 3)
        XCTAssertEqual(capped.contentHeight, 3 * 33)
        XCTAssertLessThanOrEqual(capped.contentWidth, 44 * 17)
        XCTAssertGreaterThanOrEqual(capped.contentWidth, 1)
    }
}

/// Rounded corners on the picture itself (design §6.6): the alpha outside the arc stays 0, so the
/// wall's background shows through and a display reads as an object on the wall.
final class PanelImageCornerTests: XCTestCase {
    /// A solid white 40x40 picture on a 40x40 panel, so every pixel is content.
    private func white(_ w: Int = 40, _ h: Int = 40) -> [UInt8] {
        [UInt8](repeating: 255, count: w * h * 3)
    }

    private func alpha(_ canvas: [UInt8], _ x: Int, _ y: Int, width: Int) -> UInt8 {
        canvas[(y * width + x) * 4 + 3]
    }

    func testTheCornersAreCutAndTheRestIsOpaque() {
        let canvas = PanelImage.compose(content: white(), width: 40, height: 40,
                                       panelWidth: 40, panelHeight: 40,
                                       originX: 0, originY: 0, cornerRadius: 8)
        XCTAssertEqual(alpha(canvas, 0, 0, width: 40), 0, "top-left corner")
        XCTAssertEqual(alpha(canvas, 39, 0, width: 40), 0, "top-right corner")
        XCTAssertEqual(alpha(canvas, 0, 39, width: 40), 0, "bottom-left corner")
        XCTAssertEqual(alpha(canvas, 39, 39, width: 40), 0, "bottom-right corner")
        // Inside the arc and everywhere else: untouched.
        XCTAssertEqual(alpha(canvas, 8, 8, width: 40), 255)
        XCTAssertEqual(alpha(canvas, 20, 0, width: 40), 255, "the top edge stays")
        XCTAssertEqual(alpha(canvas, 20, 20, width: 40), 255)
        XCTAssertEqual(alpha(canvas, 20, 39, width: 40), 255, "the bottom edge stays")
    }

    func testTheArcIsMonotoneSoTheCornerLooksRound() {
        let canvas = PanelImage.compose(content: white(), width: 40, height: 40,
                                       panelWidth: 40, panelHeight: 40,
                                       originX: 0, originY: 0, cornerRadius: 8)
        // Row 0 is cut by the full radius, row r-1 by almost nothing.
        var widths: [Int] = []
        for y in 0..<8 {
            let firstOpaque = (0..<40).first { alpha(canvas, $0, y, width: 40) != 0 } ?? -1
            widths.append(firstOpaque)
        }
        XCTAssertEqual(widths.first, 8, "the top row starts at the radius")
        XCTAssertEqual(widths.last, 1, "the last row of the arc keeps only the tangent pixel")
        XCTAssertEqual(widths, widths.sorted(by: >), "the cut shrinks row by row: \(widths)")
    }

    func testRadiusZeroIsTheOldRectangle() {
        let square = PanelImage.compose(content: white(), width: 40, height: 40,
                                       panelWidth: 40, panelHeight: 40,
                                       originX: 0, originY: 0)
        XCTAssertEqual(alpha(square, 0, 0, width: 40), 255)
        XCTAssertEqual(alpha(square, 39, 39, width: 40), 255)
    }

    func testARadiusLargerThanHalfThePictureCannotEraseIt() {
        let canvas = PanelImage.compose(content: white(), width: 20, height: 20,
                                       panelWidth: 20, panelHeight: 20,
                                       originX: 0, originY: 0, cornerRadius: 999)
        XCTAssertEqual(alpha(canvas, 10, 10, width: 20), 255, "the middle always survives")
    }

    func testTheRadiusIsA24thOfTheShortSide() {
        XCTAssertEqual(PanelImage.cornerRadius(width: 731, height: 416), 17)
        XCTAssertEqual(PanelImage.cornerRadius(width: 1267, height: 792), 33)
        XCTAssertEqual(PanelImage.cornerRadius(width: 10, height: 200), 0, "nothing to round")
    }
}
