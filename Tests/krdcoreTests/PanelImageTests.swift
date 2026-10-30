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

    // MARK: backdrop colour

    /// The case that made this the rule: a desk with a big bright window in the middle and a blue
    /// wallpaper at the edges must give a blue backdrop, not white.
    func testTheEdgesWinOverABrightMiddle() {
        let w = 64, h = 40
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 3
                let edge = x < 6 || x >= w - 6 || y < 6 || y >= h - 6
                let colour: [UInt8] = edge ? [30, 90, 200] : [250, 250, 250]
                rgb[o] = colour[0]; rgb[o + 1] = colour[1]; rgb[o + 2] = colour[2]
            }
        }
        XCTAssertEqual(PanelImage.backdropColor(rgb: rgb, width: w, height: h),
                       PanelColor(r: 30, g: 90, b: 200))
    }

    func testAUniformEdgeGivesThatColour() {
        let w = 40, h = 30
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in stride(from: 0, to: rgb.count, by: 3) { rgb[i] = 12; rgb[i + 1] = 200; rgb[i + 2] = 40 }
        XCTAssertEqual(PanelImage.backdropColor(rgb: rgb, width: w, height: h),
                       PanelColor(r: 12, g: 200, b: 40))
    }

    /// Two colours split down the middle of the ring: the fuller one wins, and the same picture
    /// always gives the same answer.
    func testTheFullerEdgeColourWinsAndTheAnswerIsStable() {
        let w = 40, h = 40
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 3
                let left = x < w / 2
                let colour: [UInt8] = left ? [0, 0, 0] : [255, 255, 255]
                rgb[o] = colour[0]; rgb[o + 1] = colour[1]; rgb[o + 2] = colour[2]
            }
        }
        let first = PanelImage.backdropColor(rgb: rgb, width: w, height: h)
        XCTAssertEqual(first, PanelImage.backdropColor(rgb: rgb, width: w, height: h))
        XCTAssertEqual(first, PanelColor(r: 0, g: 0, b: 0))
    }

    func testATinyPictureDoesNotTrap() {
        // 1x1 and 2x2 have no "band" to speak of: the clamp is what keeps the indices in range.
        XCTAssertEqual(PanelImage.backdropColor(rgb: [9, 8, 7], width: 1, height: 1),
                       PanelColor(r: 9, g: 8, b: 7))
        XCTAssertEqual(PanelImage.backdropColor(rgb: [UInt8](repeating: 4, count: 2 * 2 * 3),
                                                width: 2, height: 2),
                       PanelColor(r: 4, g: 4, b: 4))
    }

    func testAnEmptyPictureIsBlackAndNeverTraps() {
        XCTAssertEqual(PanelImage.backdropColor(rgb: [], width: 0, height: 0), .black)
        XCTAssertEqual(PanelImage.backdropColor(rgb: [1, 2, 3], width: 100, height: 100), .black)
    }

    // MARK: composite

    func testTheBarsAreTheBackdropAndThePictureIsCentred() {
        let content = [UInt8](repeating: 7, count: 2 * 2 * 3)          // a 2x2 picture
        let canvas = PanelImage.compose(content: content, width: 2, height: 2,
                                        panelWidth: 6, panelHeight: 4, originX: 2, originY: 1,
                                        backdrop: PanelColor(r: 9, g: 9, b: 9))
        XCTAssertEqual(canvas.count, 6 * 4 * 3)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let o = (y * 6 + x) * 3
            return Array(canvas[o..<o + 3])
        }
        XCTAssertEqual(pixel(0, 0), [9, 9, 9])           // bar
        XCTAssertEqual(pixel(1, 1), [9, 9, 9])           // bar row above the picture
        XCTAssertEqual(pixel(2, 1), [7, 7, 7])           // first picture pixel
        XCTAssertEqual(pixel(3, 2), [7, 7, 7])           // last picture pixel
        XCTAssertEqual(pixel(4, 2), [9, 9, 9])           // bar on the right
        XCTAssertEqual(pixel(5, 3), [9, 9, 9])
    }

    func testAContentBiggerThanThePanelIsClippedNotScaled() {
        // 4x4 of 5s into a 2x2 panel at (0,0): the top-left corner survives, nothing is resampled.
        let content = [UInt8](repeating: 5, count: 4 * 4 * 3)
        let canvas = PanelImage.compose(content: content, width: 4, height: 4,
                                        panelWidth: 2, panelHeight: 2, originX: 0, originY: 0,
                                        backdrop: .black)
        XCTAssertEqual(canvas, [UInt8](repeating: 5, count: 2 * 2 * 3))
        // Pushed off the panel entirely: the bars stay, and nothing is written out of bounds.
        let offscreen = PanelImage.compose(content: content, width: 4, height: 4,
                                           panelWidth: 2, panelHeight: 2, originX: 99, originY: -99,
                                           backdrop: PanelColor(r: 1, g: 2, b: 3))
        XCTAssertEqual(offscreen, [UInt8](repeating: 0, count: 0)
                       + [1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 3])
    }
}
