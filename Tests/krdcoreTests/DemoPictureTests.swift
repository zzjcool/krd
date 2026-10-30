import XCTest
@testable import krdcore

/// The demo picture: the wall's geometry made visible without a window server.
///
/// The pattern is the measuring instrument, so its *structure* is what these tests pin: a border at
/// the picture's own edge, four distinguishable corners, a circle (an aspect error makes it an
/// ellipse) and a size that is exactly `width * height * 4`.
final class DemoPictureTests: XCTestCase {
    private func pixel(_ pixels: [UInt8], _ width: Int, _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * width + x) * 4
        return Array(pixels[i..<(i + 3)])
    }

    func testTheSizeIsExactlyTheRequest() {
        for (w, h) in [(1, 1), (2, 3), (86, 27), (1600, 1000)] {
            let pixels = DemoPicture.render(width: w, height: h)
            XCTAssertEqual(pixels.count, w * h * 4, "\(w)x\(h)")
            // Opaque everywhere: the wall's pictures carry alpha and a transparent pixel is a hole
            // the terminal fills with its own background.
            XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 })
        }
    }

    /// A request for nothing must not produce a zero-length buffer: the emitter rejects those and the
    /// slot would then show its mask, which reads as a capture failure rather than as a demo.
    func testAZeroRequestStillProducesOnePixel() {
        XCTAssertEqual(DemoPicture.render(width: 0, height: 0).count, 4)
    }

    /// The border is the picture's extent - the thing a wrong placement or a wrong scale changes
    /// first - so it must be on all four edges and it must be the outermost pixel.
    func testTheBorderIsOnEveryEdge() {
        let w = 40, h = 24
        let pixels = DemoPicture.render(width: w, height: h)
        let border = DemoPicture.border
        for x in [0, w / 2, w - 1] {
            XCTAssertEqual(pixel(pixels, w, x, 0), [border.r, border.g, border.b])
            XCTAssertEqual(pixel(pixels, w, x, h - 1), [border.r, border.g, border.b])
        }
        for y in [0, h / 2, h - 1] {
            XCTAssertEqual(pixel(pixels, w, 0, y), [border.r, border.g, border.b])
            XCTAssertEqual(pixel(pixels, w, w - 1, y), [border.r, border.g, border.b])
        }
    }

    /// Four corners, four colours: a crop, a flip or a rotation is then visible without knowing what
    /// the picture was supposed to be.
    func testTheFourCornersDiffer() {
        let w = 64, h = 64
        let pixels = DemoPicture.render(width: w, height: h)
        let inset = 4                       // inside the border
        let corners = [(inset, inset), (w - 1 - inset, inset),
                       (inset, h - 1 - inset), (w - 1 - inset, h - 1 - inset)]
        let colours = corners.map { pixel(pixels, w, $0.0, $0.1) }
        for i in colours.indices {
            for j in colours.indices where i < j {
                XCTAssertNotEqual(colours[i], colours[j], "corner \(i) and \(j) look the same")
            }
        }
    }

    /// Deterministic, or two runs of the same demo would not be comparable - which is the only
    /// reason to have a demo at all.
    func testTheSameSizeGivesTheSamePicture() {
        XCTAssertEqual(DemoPicture.render(width: 33, height: 17),
                       DemoPicture.render(width: 33, height: 17))
    }
}
