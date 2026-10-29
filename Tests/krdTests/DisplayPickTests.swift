import XCTest
@testable import krd
@testable import krdcore

/// Which display a session follows, and when a burst of screen-parameter notifications collapses
/// into one restart. Both are pure so they can be tested without a screen or a monitor to unplug.
final class DisplayPickTests: XCTestCase {
    private let primary = DisplayBox(id: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1200))
    private let external = DisplayBox(id: 2, bounds: CGRect(x: 1920, y: 0, width: 2560, height: 1440))
    private let laptop = DisplayBox(id: 3, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))

    func testTheTrackedDisplayIsKeptEvenWhenThePointerMovesAway() {
        // "Mirror my screen", not "follow my mouse": the pointer wandering onto the external
        // display must not move the capture.
        let choice = DisplayPick.choose(requested: nil, tracked: 2,
                                        displays: [primary, external],
                                        pointer: CGPoint(x: 10, y: 10), main: 1)
        XCTAssertEqual(choice?.display, external)
        XCTAssertEqual(choice?.fellBack, false)
    }

    func testALostDisplayFallsBackToThePointerAndSaysSo() {
        let choice = DisplayPick.choose(requested: nil, tracked: 2,
                                        displays: [primary, laptop],
                                        pointer: CGPoint(x: 200, y: 200), main: 1)
        XCTAssertEqual(choice?.display, primary)
        XCTAssertEqual(choice?.fellBack, true)
        XCTAssertTrue(choice?.reason.contains("is gone") == true, choice?.reason ?? "")
        XCTAssertTrue(choice?.reason.contains("pointer") == true, choice?.reason ?? "")
    }

    func testAnExplicitDisplayIndexWins() {
        let choice = DisplayPick.choose(requested: 1, tracked: 1,
                                        displays: [primary, external], pointer: .zero, main: 1)
        XCTAssertEqual(choice?.display, external)
        XCTAssertEqual(choice?.fellBack, false)
    }

    func testAnIndexThatNoLongerExistsFallsBackAndExplains() {
        // Unplugged one of two displays while running `--display 1`: the index is out of range.
        let choice = DisplayPick.choose(requested: 1, tracked: 2,
                                        displays: [primary], pointer: CGPoint(x: 5, y: 5), main: 1)
        XCTAssertEqual(choice?.display, primary)
        XCTAssertEqual(choice?.fellBack, true)
        XCTAssertTrue(choice?.reason.contains("out of range") == true, choice?.reason ?? "")
    }

    func testThePointerPicksTheDisplayItIsOnWhenNothingIsTracked() {
        let choice = DisplayPick.choose(requested: nil, tracked: nil,
                                        displays: [primary, external],
                                        pointer: CGPoint(x: 2500, y: 100), main: 1)
        XCTAssertEqual(choice?.display, external)
        XCTAssertEqual(choice?.fellBack, false)
    }

    func testTheMainDisplayIsTheLastResort() {
        // The tracked display is gone *and* the pointer is parked at coordinates no remaining
        // display covers (it was left on the one that vanished).
        let choice = DisplayPick.choose(requested: nil, tracked: 2,
                                        displays: [primary, laptop],
                                        pointer: CGPoint(x: -900, y: -900), main: 1)
        XCTAssertEqual(choice?.display, primary)
        XCTAssertEqual(choice?.fellBack, true)
        XCTAssertTrue(choice?.reason.contains("main display") == true, choice?.reason ?? "")
    }

    func testNoDisplaysMeansNoChoice() {
        XCTAssertNil(DisplayPick.choose(requested: nil, tracked: 1, displays: [],
                                        pointer: .zero, main: 1))
    }

    func testReorderingDisplaysStillHonoursTheIndex() {
        // macOS reorders `SCShareableContent.displays` when the pointer's display changes; the
        // index is what `--list` printed, so it is what the flag means.
        let choice = DisplayPick.choose(requested: 0, tracked: 2,
                                        displays: [external, primary], pointer: .zero, main: 1)
        XCTAssertEqual(choice?.display, external)
        XCTAssertEqual(choice?.fellBack, false)  // same physical display, new index in the list
    }

    // MARK: debounce

    func testABurstOfNotificationsFiresOnceAfterTheLastOne() {
        var debounce = Debounce(window: 0.5)
        let base = Date(timeIntervalSince1970: 1000)
        debounce.note(base)
        debounce.note(base.addingTimeInterval(0.2))
        debounce.note(base.addingTimeInterval(0.4))
        // Only a timer firing at or after the newest event's deadline runs the work: a lid close
        // that fires three notifications is one restart, 0.5 s after the third.
        XCTAssertFalse(debounce.isCurrent(at: base.addingTimeInterval(0.5)))
        XCTAssertFalse(debounce.isCurrent(at: base.addingTimeInterval(0.89)))
        XCTAssertTrue(debounce.isCurrent(at: base.addingTimeInterval(0.9)))
        XCTAssertEqual(debounce.deadline, base.addingTimeInterval(0.9))
    }

    func testAfterFiringTheDebounceIsIdle() {
        var debounce = Debounce(window: 0.5)
        let now = Date(timeIntervalSince1970: 10)
        debounce.note(now)
        XCTAssertTrue(debounce.isCurrent(at: now.addingTimeInterval(0.5)))
        debounce.reset()
        XCTAssertNil(debounce.deadline)
        XCTAssertFalse(debounce.isCurrent(at: now.addingTimeInterval(1)))
    }
}
