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
            // A uniform span keeps these cases "all frames late" / "no frame late", which is what
            // they are about; the stall weighting has its own tests below.
            if let change = governor.observe(at: t, late: late, span: step), done(change) {
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

    // MARK: - issue #93: a stall is one sample worth seconds, not one frame

    /// The frame loop, in the small: one frame every `1000/fps` ms with `writeMs`, except at each
    /// stall, where the write blocks for `stallMs` and **no frame is emitted while it does** — that
    /// deletion of frames is the whole bug.
    private func timeline(seconds: Double, fps: Int, writeMs: Double, stallStarts: [Double],
                          stallMs: Double) -> [(at: Double, writeMs: Double)] {
        let periodMs = 1000.0 / Double(fps)
        var frames: [(at: Double, writeMs: Double)] = []
        var pending = stallStarts.sorted()
        var nowMs = 0.0
        while true {
            nowMs += periodMs
            guard nowMs <= seconds * 1000.0 + 0.5 else { break }
            if let next = pending.first, next * 1000.0 <= nowMs + periodMs / 2 {
                pending.removeFirst()
                nowMs += stallMs                       // the loop is inside write(2) for stallMs
                frames.append((at: nowMs / 1000.0, writeMs: stallMs))
            } else {
                frames.append((at: nowMs / 1000.0, writeMs: writeMs))
            }
        }
        return frames
    }

    /// Feed a timeline through the rule the frame loop uses (`QualityGovernor.frameSample`) and
    /// return the governor plus every rung it took, with the time it took it.
    private func drive(_ frames: [(at: Double, writeMs: Double)], fps: Int)
        -> (governor: QualityGovernor, changes: [(t: Double, change: QualityGovernor.Change)]) {
        var governor = QualityGovernor()
        var changes: [(t: Double, change: QualityGovernor.Change)] = []
        for frame in frames {
            let sample = QualityGovernor.frameSample(writeMs: frame.writeMs, targetFps: fps)
            if let change = governor.observe(at: frame.at, late: sample.late, span: sample.span) {
                changes.append((frame.at, change))
            } else {
                governor.settle(at: frame.at)
            }
        }
        return (governor, changes)
    }

    /// The nine hangs in 34 s that issue #93 measured (`--mock`, 100x40, 20 fps, 5 KB/s drain):
    /// `quality` stayed 80 for the whole run because each hang was **one** late frame out of the ~40
    /// in a 3 s window. It has to take rungs now.
    func testNineStallsInThirtyFourSecondsStepTheLadderDown() {
        let frames = timeline(seconds: 40, fps: 20, writeMs: 3,
                              stallStarts: [7, 11, 14, 17, 21, 24, 27, 31, 34], stallMs: 2500)
        let (governor, changes) = drive(frames, fps: 20)
        // Printed on purpose (FrameGateTests does the same): the table *is* the evidence for #93.
        print("  hang at (s)   rung taken at   ->")
        for (t, change) in changes { print(String(format: "  %10.2f   %10.2f      %@", t - 2.5, t, change.line)) }
        XCTAssertFalse(changes.isEmpty, "a link that hangs nine times must not look calm")
        // The first hang ends at 9.5 s and the ladder may not wait for a second one: the picture is
        // already frozen by then.
        XCTAssertLessThanOrEqual(changes[0].t, 10.0, "the first 2.5 s hang has to move the rung")
        XCTAssertEqual(changes[0].change.to, .init(quality: 70, fps: 20), "one rung, not a collapse")
        // Nine hangs finish the ladder: colour first, then frame rate, `minDwell` 5 s per rung.
        XCTAssertEqual(governor.step, .init(quality: 50, fps: 10),
                       "took \(changes.count) rungs: \(changes.map { $0.change.to.label })")
        XCTAssertTrue(governor.handOver, "only now may the scale governor take resolution")
    }

    /// The control: the same 40 s and the same frame count with a link that is merely fast. Nothing
    /// may move — the fix must not turn a pipe that keeps up into a ladder climb.
    func testACalmSequenceDoesNotMoveTheLadder() {
        let frames = timeline(seconds: 40, fps: 20, writeMs: 3, stallStarts: [], stallMs: 0)
        let (governor, changes) = drive(frames, fps: 20)
        XCTAssertTrue(changes.isEmpty, "a calm link took \(changes.map { $0.change.line })")
        XCTAssertEqual(governor.step, .init(quality: 80, fps: 20))
    }

    /// "The write blocked" and "the link is slow but moving" are the same `late`, and they have to
    /// be: both mean the pipe cannot take what the loop produces. What differs is how much wall
    /// clock each sample speaks for, and that is exactly the number the ladder weighs.
    func testAFrameSampleWeighsTheBlockedTimeOfItsWrite() {
        let period = 1.0 / 20.0
        let stall = QualityGovernor.frameSample(writeMs: 2500, targetFps: 20)
        XCTAssertTrue(stall.late)
        XCTAssertEqual(stall.span, 2.5, accuracy: 1e-9,
                       "a 2.5 s hang is 50 frame intervals of wall clock, not one sample")
        XCTAssertEqual(stall.span / period, 50, accuracy: 1e-6)
        let prompt = QualityGovernor.frameSample(writeMs: 3, targetFps: 20)
        XCTAssertFalse(prompt.late)
        XCTAssertEqual(prompt.span, period, accuracy: 1e-9, "a fast frame still owns its slot")
        // Slow, but moving: late, and worth slightly more than a slot — 80 ms of blocked write.
        let slow = QualityGovernor.frameSample(writeMs: 80, targetFps: 20)
        XCTAssertTrue(slow.late)
        XCTAssertEqual(slow.span, 0.08, accuracy: 1e-9)
        // The round trip's second opinion (#52) is still a late sample on its own.
        XCTAssertTrue(QualityGovernor.frameSample(writeMs: 3, targetFps: 20, rttLate: true).late)
    }

    /// An idle screen is not a stall, and this is the test that stops the obvious wrong fix ("count
    /// the frames that never arrived"): a deduped frame writes nothing and emits nothing (#95), so a
    /// picture that sits still for 30 s produces no samples at all — and when it finally changes,
    /// its span is its own 2 ms write floored at one frame interval, never the 30 s gap.
    func testAnIdleGapIsNotAStall() {
        let frame = QualityGovernor.frameSample(writeMs: 2, targetFps: 20)
        XCTAssertFalse(frame.late)
        XCTAssertEqual(frame.span, 0.05, accuracy: 1e-9)
        var governor = QualityGovernor()
        var t = 0.0
        while t < 60 {
            if let change = governor.observe(at: t, late: frame.late, span: frame.span) {
                XCTFail("an idle screen is not a stall: \(change.line) at \(t) s")
            }
            governor.settle(at: t)
            t += (t == 20.0 ? 30.0 : 0.05)          // one 30 s gap with nothing emitted
        }
        XCTAssertEqual(governor.step, .init(quality: 80, fps: 20))
    }
}
