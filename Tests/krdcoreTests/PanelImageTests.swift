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
        XCTAssertEqual(fit.contentHeight, 792)              // 24 rows
        XCTAssertEqual(fit.contentWidth, 1267)              // 792 * 1.6
        XCTAssertEqual(fit.originX, 514)                    // (2295 - 1267) / 2
        XCTAssertEqual(fit.originY, 0)
        XCTAssertEqual(fit.cellRect, CellRect(col: 1 + (135 - 75) / 2, row: 1, cols: 75, rows: 24))
    }

    func testPortraitStaysHeightBoundAndNarrow() {
        let fit = PanelImage.fit(aspect: 1200.0 / 1920.0, in: band, cellW: 17, cellH: 33)
        XCTAssertEqual(fit.contentHeight, 792)
        XCTAssertEqual(fit.contentWidth, 495)
        XCTAssertEqual(fit.cellRect.cols, 29)
        XCTAssertEqual(fit.cellRect.rows, 24)
    }

    func testANarrowBandIsWidthBound() {
        let fit = PanelImage.fit(aspect: 1.6, in: CellRect(col: 0, row: 0, cols: 20, rows: 40),
                                 cellW: 17, cellH: 33)
        XCTAssertEqual(fit.contentWidth, 340)
        XCTAssertEqual(fit.contentHeight, 213)              // rounded 340 / 1.6
        XCTAssertEqual(fit.originY, (1320 - 213) / 2)
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
        XCTAssertEqual(capped.contentHeight, full.contentHeight - 60)
        XCTAssertEqual(capped.contentWidth, full.contentWidth - 60, "a cap keeps the aspect")
        XCTAssertEqual(capped.originY, (14 * 33 - capped.contentHeight) / 2, "centred, not pinned")
        XCTAssertEqual(capped.originX, (44 * 17 - capped.contentWidth) / 2)
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
        XCTAssertEqual(capped.contentHeight, 100)
        XCTAssertLessThanOrEqual(capped.contentWidth, 44 * 17)
        XCTAssertGreaterThanOrEqual(capped.contentWidth, 1)
    }
}
