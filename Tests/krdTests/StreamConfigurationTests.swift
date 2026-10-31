import XCTest
import CoreMedia
import CoreVideo
import ScreenCaptureKit
@testable import krd

/// The one setting in `Capturer.configuration` that the picture cannot be shipped without: whether a
/// source smaller than the requested frame is *scaled into it* or drawn 1:1 in its corner.
///
/// Off, a window filter draws the window at its native pixels anchored top-left and pads the rest
/// with black; the pane's cell box is routinely larger than the window's pixels, so the padding was
/// cut into tiles and the mirror's picture sat in a corner of it. Measured on macOS 27.0.1 by asking
/// for the box and reading back the picture's share of the frame (a 360x360 px window in an
/// 1800x1800 request): 18 % x 18 % with the flag off, 92 % x 92 % with it on. Nothing else about the
/// request changed, which is why this file pins that flag by name.
///
/// The rest of the fields are here for the opposite reason: they are the ones a refactor into this
/// function could quietly drop (the crop that saves the server pixels, the queue depth that keeps
/// the stream alive on this build), and none of them show up in a test that only checks the picture.
final class StreamConfigurationTests: XCTestCase {
    private let crop = CGRect(x: 100, y: 50, width: 640, height: 480)

    private func make(fps: Int = 20, sourceRect: CGRect? = nil,
                      showsCursor: Bool = false) -> SCStreamConfiguration {
        Capturer.configuration(width: 1440, height: 720, fps: fps,
                               sourceRect: sourceRect, showsCursor: showsCursor)
    }

    // MARK: - The flag that decides the picture's size

    /// A window stream that is not asked to fit pads the source into the top-left corner instead.
    func testTheSourceIsScaledIntoTheFrame() {
        XCTAssertTrue(make().scalesToFit,
                      "a window stream that is not asked to fit pads the source into the "
                      + "top-left corner instead (measured: 18 % of the frame)")
    }

    // MARK: - The requested frame

    func testTheRequestedSizeIsPassedThrough() {
        let config = make()
        XCTAssertEqual(config.width, 1440)
        XCTAssertEqual(config.height, 720)
    }

    /// `queueDepth 1` stalls the stream on this macOS build; the value is small and load-bearing.
    func testTheQueueIsThreeDeep() {
        XCTAssertEqual(make().queueDepth, 3)
    }

    // MARK: - The two fields the frame buffer depends on

    func testTheFormatIsBGRA() {
        XCTAssertEqual(make().pixelFormat, kCVPixelFormatType_32BGRA)
    }

    /// Compared as strings on both sides on purpose: the *default* `colorSpaceName` is an empty
    /// `CFString`, and `CFEqual` against a real colour space segfaults the whole bundle (measured,
    /// 2 of 2) - so a deleted line would report "the test process died" rather than "one assertion
    /// failed", which is the least useful failure a mutation can produce.
    func testTheColourSpaceIsSRGB() {
        XCTAssertEqual(make().colorSpaceName as String, CGColorSpace.sRGB as String)
    }

    // MARK: - Frame rate

    func testTheFrameIntervalIsTheInverseOfTheFps() {
        // 30, not 60: the SDK's own default interval is 1/60, so a 60 fps row cannot fail.
        XCTAssertEqual(make(fps: 20).minimumFrameInterval, CMTime(value: 1, timescale: 20))
        XCTAssertEqual(make(fps: 30).minimumFrameInterval, CMTime(value: 1, timescale: 30))
    }

    /// `fps` comes from a flag; a zero would be a division by zero, so it clamps to 1 fps.
    func testAZeroFpsClampsToOne() {
        XCTAssertEqual(make(fps: 0).minimumFrameInterval, CMTime(value: 1, timescale: 1))
    }

    // MARK: - Cursor

    /// A comparison rather than two literals: the SDK's default is `true`, so `XCTAssertTrue` on
    /// the true half could never fail. Two different answers is the only assertion a dead flag
    /// cannot satisfy.
    func testTheCursorFlagIsPassedThrough() {
        XCTAssertNotEqual(make(showsCursor: true).showsCursor, make(showsCursor: false).showsCursor,
                          "both halves equal means the flag never reached the config")
        XCTAssertFalse(make(showsCursor: false).showsCursor)
    }

    // MARK: - The crop

    func testTheCropIsPassedThrough() {
        XCTAssertEqual(make(sourceRect: crop).sourceRect, crop)
    }

    /// Both arms of `width >= 1 && height >= 1`, and the `>=` itself: `Desk.cropForFilter` rounds a
    /// tiny zoom up to one point, so a 1x1 rect is a real crop and 0.999 is not a crop at all.
    /// Neither the height arm nor the boundary was reachable from the cheap cases alone.
    func testTheCropGuardIsOnBothAxesAndAtOnePoint() {
        XCTAssertEqual(make(sourceRect: CGRect(x: 10, y: 10, width: 640, height: 0.5)).sourceRect,
                       CGRect.zero, "a sub-pixel height is not a crop either")
        let onePoint = CGRect(x: 7, y: 9, width: 1, height: 1)
        XCTAssertEqual(make(sourceRect: onePoint).sourceRect, onePoint,
                       "1 pt is the floor a tiny zoom rounds to; it has to survive the guard")
        XCTAssertEqual(make(sourceRect: CGRect(x: 3, y: 4, width: 2, height: 0.999)).sourceRect,
                       CGRect.zero, "and just under the floor is not")
    }
}
