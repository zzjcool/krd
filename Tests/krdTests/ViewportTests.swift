import XCTest
import CoreGraphics
@testable import krd

/// The zoom geometry: which part of the screen a magnified view shows, and where a click inside
/// that view lands on the desktop. Both are pure functions of a CGRect, so they are tested here
/// rather than by pointing a camera at a terminal.
final class ViewportZoomTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

    // MARK: crop

    func testNoZoomIsTheWholeSource() {
        XCTAssertEqual(Viewport.crop(full: display, scale: 1, focus: CGPoint(x: 10, y: 10)), display)
    }

    func testZoomHalvesBothDimensionsAndCentresOnTheFocus() {
        let focus = CGPoint(x: 400, y: 300)
        let crop = Viewport.crop(full: display, scale: 2, focus: focus)
        XCTAssertEqual(crop.width, 756, accuracy: 0.001)
        XCTAssertEqual(crop.height, 491, accuracy: 0.001)
        XCTAssertEqual(crop.midX, focus.x, accuracy: 0.001)
        XCTAssertEqual(crop.midY, focus.y, accuracy: 0.001)
    }

    func testAFocusOutsideTheSourceIsClampedInside() {
        // A pointer on another display must not produce a crop off this one.
        let crop = Viewport.crop(full: display, scale: 2, focus: CGPoint(x: -5000, y: 9999))
        XCTAssertTrue(display.contains(crop), "\(crop) escaped \(display)")
        XCTAssertEqual(crop.minX, display.minX, accuracy: 0.001)
        XCTAssertEqual(crop.maxY, display.maxY, accuracy: 0.001)
    }

    func testCropNeverLeavesTheSourceForAnyFocusOrScale() {
        let scales: [Double] = [1, 1.5, 2, 3, 4, 8, 64]
        for scale in scales {
            for x in stride(from: -2000.0, through: 3500.0, by: 250.0) {
                for y in stride(from: -2000.0, through: 2000.0, by: 250.0) {
                    let crop = Viewport.crop(full: display, scale: scale, focus: CGPoint(x: x, y: y))
                    XCTAssertGreaterThanOrEqual(crop.minX, display.minX - 0.001, "scale \(scale) x \(x)")
                    XCTAssertGreaterThanOrEqual(crop.minY, display.minY - 0.001, "scale \(scale) y \(y)")
                    XCTAssertLessThanOrEqual(crop.maxX, display.maxX + 0.001, "scale \(scale) x \(x)")
                    XCTAssertLessThanOrEqual(crop.maxY, display.maxY + 0.001, "scale \(scale) y \(y)")
                    XCTAssertGreaterThan(crop.width, 0)
                    XCTAssertGreaterThan(crop.height, 0)
                }
            }
        }
    }

    func testHostileInputsFallBackToTheWholeSource() {
        // NaN and infinity arrive from --zoom / --zoom-at parsing and from a pointer query.
        XCTAssertEqual(Viewport.crop(full: display, scale: Double.nan, focus: CGPoint(x: 100, y: 100)), display)
        XCTAssertEqual(Viewport.crop(full: display, scale: Double.infinity, focus: CGPoint(x: CGFloat.nan, y: 100)).width,
                       display.width)
        XCTAssertEqual(Viewport.crop(full: display, scale: 0.25, focus: CGPoint(x: 100, y: 100)), display)
        XCTAssertEqual(Viewport.crop(full: .zero, scale: 2, focus: .zero), .zero)
    }

    func testATinySourceStillProducesAUsableRect() {
        // A 40-point-scaled-down window at 8x would be 5x5 pt; the floor keeps ScreenCaptureKit
        // from being handed a zero-sized sourceRect.
        let small = CGRect(x: 10, y: 10, width: 3, height: 3)
        let crop = Viewport.crop(full: small, scale: 8, focus: CGPoint(x: 11, y: 11))
        XCTAssertGreaterThanOrEqual(crop.width, 1)
        XCTAssertGreaterThanOrEqual(crop.height, 1)
        XCTAssertTrue(small.contains(crop))
    }

    // MARK: mapping a click back through the zoom

    func testClickMappingFollowsTheCrop() {
        let crop = Viewport.crop(full: display, scale: 2, focus: CGPoint(x: 756, y: 491))
        let viewport = Viewport(pixelWidth: 1020, pixelHeight: 612, cols: 60, rows: 17, sourceRect: crop)

        // The centre cell is the focus point, and the picture spans exactly the crop.
        let centre = viewport.point(forCell: 30, 9)
        XCTAssertEqual(centre.x, crop.midX, accuracy: crop.width / 60)
        XCTAssertEqual(centre.y, crop.midY, accuracy: crop.height / 17)

        // A cell maps to a quarter of the points a no-zoom mapping would give.
        let flat = Viewport(pixelWidth: 1020, pixelHeight: 612, cols: 60, rows: 17, sourceRect: display)
        let zoomed = viewport.point(forCell: 45, 9)
        let unzoomed = flat.point(forCell: 45, 9)
        XCTAssertEqual(zoomed.x - centre.x, (unzoomed.x - flat.point(forCell: 30, 9).x) / 2, accuracy: 0.5)
    }

    func testPixelMappingStaysInsideTheCrop() {
        let crop = Viewport.crop(full: display, scale: 4, focus: CGPoint(x: 100, y: 900))
        let viewport = Viewport(pixelWidth: 1020, pixelHeight: 612, cols: 60, rows: 17, sourceRect: crop)
        for px in [0, 1, 509, 1019, 5000] {
            let point = viewport.point(forPixel: px, 0)
            XCTAssertGreaterThanOrEqual(point.x, crop.minX)
            XCTAssertLessThanOrEqual(point.x, crop.maxX)
        }
        // Out-of-range pixel reports are clamped, not extrapolated onto another display.
        XCTAssertEqual(viewport.point(forPixel: 9999, 9999).x, crop.maxX, accuracy: 0.001)
    }

    func testZoomComposesWithAWindowFrame() {
        // --window frames are not anchored at 0,0; the crop has to follow the frame.
        let window = CGRect(x: -1512, y: 120, width: 900, height: 600)
        let crop = Viewport.crop(full: window, scale: 2, focus: CGPoint(x: -1000, y: 400))
        XCTAssertTrue(window.contains(crop))
        XCTAssertEqual(crop.width, 450, accuracy: 0.001)
        XCTAssertEqual(crop.midX, -1000, accuracy: 0.001)
    }
}

final class ViewportTests: XCTestCase {
    /// The Terminal window measured on this machine in #24: 863x499 at 746,255.
    private let window = CGRect(x: 746, y: 255, width: 863, height: 499)
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 2560)

    private func windowViewport() -> Viewport {
        Viewport(pixelWidth: 863, pixelHeight: 499, cols: 100, rows: 30, sourceRect: window)
    }

    func testWindowModeMapsCellsIntoTheWindowFrame() {
        let viewport = windowViewport()
        // A cell maps to its own centre, so cell 1 sits half a cell in from the frame edge.
        let first = viewport.point(forCell: 1, 1)
        XCTAssertEqual(first.x, window.minX + window.width / (2 * 100), accuracy: 0.001)
        XCTAssertEqual(first.y, window.minY + window.height / (2 * 30), accuracy: 0.001)
        // Every cell, corners included, must stay inside the window: a click outside it is exactly
        // the "went to the wrong place" failure this issue is about.
        for cx in [1, 50, 100] {
            for cy in [1, 15, 30] {
                XCTAssertTrue(window.contains(viewport.point(forCell: cx, cy)),
                              "cell \(cx),\(cy) mapped outside the window")
            }
        }
    }

    func testWindowModeMapsPixelsIntoTheWindowFrame() {
        let viewport = windowViewport()
        for px in [0, 1, 431, 862] {
            for py in [0, 249, 498] {
                XCTAssertTrue(window.contains(viewport.point(forPixel: px, py)),
                              "pixel \(px),\(py) mapped outside the window")
            }
        }
        // A pixel coordinate is clamped to the frame, not extrapolated past it.
        let overshoot = viewport.point(forPixel: 5_000, 5_000)
        XCTAssertEqual(overshoot.x, window.maxX, accuracy: 0.001)
        XCTAssertEqual(overshoot.y, window.maxY, accuracy: 0.001)
    }

    /// The contrast case: display mode maps the same cell to a different point, which is why the
    /// source rect, not the display, is the origin that matters.
    func testDisplayModeMapsAgainstTheDisplayInstead() {
        let displayViewport = Viewport(pixelWidth: 1440, pixelHeight: 2560, cols: 137, rows: 44,
                                       sourceRect: display)
        let point = displayViewport.point(forCell: 137, 44)
        XCTAssertGreaterThan(point.y, window.maxY)
        XCTAssertFalse(window.contains(point))
    }
}
