import XCTest
@testable import krdcore

/// `MouseReport.wheelStep` is the wheel's *direction*, and until #118 it did not exist: the parse
/// kept `isWheel` and threw the sign away by the time anything acted on it, so nothing could scroll
/// up. One notch is one row of a panel or one card of the wall; which way the notch points is the
/// terminal's answer (button 64 is up, 65 is down), and it is decided here, next to the parse, so a
/// second receiver cannot decide it differently.
final class MouseWheelTests: XCTestCase {
    private func report(_ button: Int, wheel: Bool) -> MouseReport {
        MouseReport(button: button, x: 10, y: 4, isWheel: wheel, isRelease: false,
                    isMotion: false, mods: [])
    }

    /// xterm's button code keeps its low two bits in `button`: 64 & 3 == 0 is a notch up, 65 & 3 == 1
    /// is a notch down. A sign, not a distance — how far one notch scrolls is the receiver's rule.
    func testTheVerticalNotchesPointBothWays() {
        XCTAssertEqual(report(0, wheel: true).wheelStep, -1, "64: a notch up")
        XCTAssertEqual(report(1, wheel: true).wheelStep, 1, "65: a notch down")
    }

    /// The horizontal codes are a downward step, not a sideways one. That is what the wall has always
    /// done with them (its shelf only scrolls one way per notch), and a panel has nothing sideways to
    /// scroll, so the decision is recorded rather than left to each receiver.
    func testTheHorizontalNotchesStepDown() {
        XCTAssertEqual(report(2, wheel: true).wheelStep, 1, "66: tilt left")
        XCTAssertEqual(report(3, wheel: true).wheelStep, 1, "67: tilt right")
    }

    /// A click is not a notch. Both receivers branch on `0`, so a plain press must never look like one.
    func testAClickIsNotANotch() {
        XCTAssertEqual(report(0, wheel: false).wheelStep, 0)
        XCTAssertEqual(report(1, wheel: false).wheelStep, 0)
        XCTAssertEqual(report(2, wheel: false).wheelStep, 0)
    }
}
