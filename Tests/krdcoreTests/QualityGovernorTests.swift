import XCTest
@testable import krdcore

/// `--quality auto`: spend colour, then frame rate, and leave resolution alone until both are spent.
///
/// The decision table is pure arithmetic (`QualityGovernor`), so it is tested the way
/// `ScaleTests` tests its sibling: feed it a timeline of "was this frame late" and check the rungs.
final class QualityGovernorTests: XCTestCase {
    private func run(_ governor: inout QualityGovernor, from t0: Double, count: Int, step: Double,
                     late: Bool, until done: (QualityGovernor.Change) -> Bool = { _ in true })
        -> (time: Double, change: QualityGovernor.Change?) {
        var t = t0
        for _ in 0..<count {
            if let change = governor.observe(at: t, late: late), done(change) {
                return (t, change)
            }
            governor.settle(at: t)
            t += step
        }
        return (t, nil)
    }

    func testTheLadderSpendsColourBeforeFrameRate() {
        let ladder = QualityGovernor.ladder
        XCTAssertEqual(ladder.first, .init(quality: 80, fps: 20), "the default rung is today's krd")
        XCTAssertEqual(ladder.last, .init(quality: 50, fps: 10))
        // Every colour step happens before the first frame-rate step: losing colour is mild, and
        // losing frames is what the user actually notices.
        let lastColour = ladder.lastIndex { $0.fps == 20 } ?? 0
        let firstRate = ladder.firstIndex { $0.fps < 20 } ?? ladder.count
        XCTAssertLessThan(lastColour, firstRate)
        // And both axes only ever get worse as the index grows.
        XCTAssertEqual(ladder.map(\.quality), ladder.map(\.quality).sorted(by: >))
        XCTAssertEqual(ladder.map(\.fps), ladder.map(\.fps).sorted(by: >))
    }

    func testItStartsAtTheRungTheUserAskedFor() {
        let governor = QualityGovernor(start: .init(quality: 60, fps: 20))
        XCTAssertEqual(governor.step.quality, 50, "60 means 'no better than 60', i.e. the 50 rung")
        XCTAssertFalse(governor.handOver)
        XCTAssertEqual(QualityGovernor(start: .init(quality: 100, fps: 20)).step.quality, 80,
                       "asking for lossless still starts at the top rung the ladder can hold")
    }

    func testAStrugglingLinkStepsDownOneRungAtATime() {
        var governor = QualityGovernor()
        let (t, change) = run(&governor, from: 0, count: 6, step: 1, late: true)
        XCTAssertNotNil(change, "a majority-late window has to do something")
        XCTAssertEqual(change?.from, .init(quality: 80, fps: 20))
        XCTAssertEqual(change?.to, .init(quality: 70, fps: 20), "one rung, not a collapse")
        XCTAssertEqual(governor.index, 1)
        // The next step needs its own window and the dwell time.
        let (t2, second) = run(&governor, from: t, count: 8, step: 1, late: true)
        XCTAssertEqual(second?.to, .init(quality: 50, fps: 20))
        XCTAssertGreaterThan(t2, t)
    }

    func testItTakesAllFiveRungsToHandOver() {
        var governor = QualityGovernor()
        var t = 0.0
        for expected in 1...4 {
            let (next, change) = run(&governor, from: t, count: 8, step: 1, late: true)
            t = next
            XCTAssertNotNil(change, "rung \(expected) should have been taken")
        }
        XCTAssertEqual(governor.step, .init(quality: 50, fps: 10))
        XCTAssertTrue(governor.handOver, "only now may the scale governor take resolution")
    }

    func testAQuietLinkComesBackOneRung() {
        var governor = QualityGovernor()
        _ = run(&governor, from: 0, count: 6, step: 1, late: true)
        XCTAssertEqual(governor.index, 1)
        // Quiet, but not for long enough: the upgrade window is deliberately long (10 s, 8 samples).
        let (_, early) = run(&governor, from: 100, count: 4, step: 1, late: false)
        XCTAssertNil(early, "four quiet frames are not evidence, they are four frames")
        let (_, late5) = run(&governor, from: 200, count: 12, step: 1, late: false)
        XCTAssertEqual(late5?.to, .init(quality: 80, fps: 20), "back up one rung")
    }

    func testNoTwoChangesInsideTheDwellWindow() {
        var governor = QualityGovernor()
        let (changedAt, first) = run(&governor, from: 0, count: 4, step: 1, late: true)
        XCTAssertNotNil(first, "the first window must do something, or this proves nothing")
        // Late again, with a window that is long enough (3 s, 3+ samples) but only 3.5 s after the
        // last change: `minDwell` is 5 s, so nothing may move yet.
        _ = run(&governor, from: changedAt + 0.5, count: 4, step: 1, late: true)
        XCTAssertEqual(governor.index, 1, "the dwell window holds")
        // Past the dwell, the same evidence does move it.
        let (_, later) = run(&governor, from: changedAt + 6, count: 4, step: 1, late: true)
        XCTAssertNotNil(later)
    }

    func testAFailedProbeMakesTheNextUpgradeWaitLonger() {
        var governor = QualityGovernor()
        _ = run(&governor, from: 0, count: 4, step: 1, late: true)          // 80 -> 70
        XCTAssertEqual(governor.index, 1)
        let firstWindow = governor.requiredQuietWindow
        let (upgradedAt, probe) = run(&governor, from: 100, count: 12, step: 1, late: false)
        XCTAssertEqual(probe?.to, .init(quality: 80, fps: 20), "a quiet link gets a rung back")
        // ...and it does not hold: late again well inside `probeSeconds` (20 s).
        let (undoneAt, undone) = run(&governor, from: upgradedAt, count: 8, step: 1, late: true)
        XCTAssertNotNil(undone, "the probe is undone: \(undoneAt - upgradedAt) s later")
        XCTAssertGreaterThan(governor.requiredQuietWindow, firstWindow,
                             "a probe that did not hold buys a longer silence next time")
    }
}
