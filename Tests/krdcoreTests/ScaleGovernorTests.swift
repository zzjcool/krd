import XCTest
@testable import krdcore

/// The decision table for `--scale auto` (issue #64).
///
/// Every test drives the governor with a synthetic frame stream at 20 fps, which is the configured
/// rate, so "late" here means "this frame took longer than 50 ms to get out". The interesting
/// properties are not the numbers but the shapes: it must not react to one slow frame, it must not
/// ping-pong on a link that sits exactly at the boundary, and it must stop probing a link it has
/// already found wanting.
final class ScaleGovernorTests: XCTestCase {
    private let fps = 20.0

    /// Feed `seconds` of frames with the given late fraction; returns what changed.
    private func drive(_ governor: inout ScaleGovernor, from start: Double, seconds: Double,
                       lateEvery: Int) -> [ScaleGovernor.Change] {
        var changes: [ScaleGovernor.Change] = []
        var t = start
        var frame = 0
        while t < start + seconds {
            let late = lateEvery > 0 && frame % lateEvery == 0
            if let change = governor.observe(at: t, late: late) { changes.append(change) }
            governor.settle(at: t)
            frame += 1
            t += 1.0 / fps
        }
        return changes
    }

    func testStaysAtOneWhenNothingIsLate() {
        var governor = ScaleGovernor()
        let changes = drive(&governor, from: 0, seconds: 60, lateEvery: 0)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(governor.level, 1)
    }

    func testOneSlowFrameIsNotBackpressure() {
        var governor = ScaleGovernor()
        XCTAssertNil(governor.observe(at: 0, late: true))
        XCTAssertEqual(governor.level, 1, "a single late frame must not change the picture quality")
    }

    func testSustainedBackpressureStepsDownOneLevelAtATime() {
        var governor = ScaleGovernor()
        // Every frame late: the first step comes after the 3 s window, the rest are held back by the
        // dwell time, so a slow link walks down the ladder instead of jumping to the bottom.
        let changes = drive(&governor, from: 0, seconds: 12, lateEvery: 1)
        XCTAssertEqual(changes.map(\.to), [0.5, 0.25], "\(changes)")
        XCTAssertEqual(changes.first?.reason, "pipe is behind")
        XCTAssertEqual(governor.level, 0.25)
        XCTAssertEqual(changes.first?.line, "pipe is behind; scale 1 -> 0.5")
    }

    /// A pipe that has already collapsed produces almost no frames. The governor still has to act,
    /// but "3 s of frames" is two frames at 0.7 fps, so the window has to be *spanned*, not counted.
    func testCollapsedStreamStillGetsADecision() {
        var governor = ScaleGovernor()
        var changes: [(t: Double, change: ScaleGovernor.Change)] = []
        var t = 0.0
        while t < 20 {
            if let change = governor.observe(at: t, late: true) { changes.append((t, change)) }
            governor.settle(at: t)
            t += 1 / 0.7                              // 0.7 fps: the pipe has already given up
        }
        XCTAssertEqual(changes.first?.change.to, 0.5, "it has to react to a collapsed stream")
        XCTAssertLessThan(changes.first?.t ?? .infinity, 12, "within a few seconds, not half a minute")
    }

    func testWindowMustSpanBeforeItCounts() {
        var governor = ScaleGovernor()
        // Two late frames 0.2 s apart are not 3 s of backpressure.
        XCTAssertNil(governor.observe(at: 0, late: true))
        XCTAssertNil(governor.observe(at: 0.2, late: true))
        XCTAssertNil(governor.observe(at: 0.4, late: true))
        XCTAssertEqual(governor.level, 1)
    }

    func testNeverGoesBelowTheLastStep() {
        var governor = ScaleGovernor()
        let changes = drive(&governor, from: 0, seconds: 120, lateEvery: 1)
        XCTAssertEqual(governor.level, 0.25)
        XCTAssertEqual(changes.map(\.to), [0.5, 0.25])
    }

    func testUpgradeNeedsTheWholeQuietWindow() {
        var governor = ScaleGovernor(start: 0.5)
        // 9 s of quiet is not 10.
        XCTAssertTrue(drive(&governor, from: 0, seconds: 9, lateEvery: 0).isEmpty)
        XCTAssertEqual(governor.level, 0.5)
        let changes = drive(&governor, from: 9, seconds: 2, lateEvery: 0)
        XCTAssertEqual(changes.map(\.to), [1])
        XCTAssertEqual(changes.first?.line, "pipe has headroom; scale 0.5 -> 1")
    }

    func testFivePercentLateIsStillQuietEnough() {
        var governor = ScaleGovernor(start: 0.5)
        // Exactly at the threshold (< 5 %), 20 fps → one late frame every 25.
        let changes = drive(&governor, from: 0, seconds: 12, lateEvery: 25)
        XCTAssertEqual(changes.map(\.to), [1])
    }

    /// The whole point of the asymmetric thresholds: a link that is *just* too slow for scale 1 must
    /// not make the governor climb back up every few seconds. It may probe, but each probe has to
    /// wait longer than the last one.
    func testNoFlappingOnALinkThatCannotCarryTheFullPicture() {
        var governor = ScaleGovernor()
        var changes: [(t: Double, change: ScaleGovernor.Change)] = []
        var t = 0.0
        var frame = 0
        // A link that carries 0.5 easily and 1 only at ~2 fps, i.e. every frame at full scale is late.
        while t < 180 {
            let late = governor.level > 0.75 ? true : (frame % 30 == 0)
            if let change = governor.observe(at: t, late: late) { changes.append((t, change)) }
            governor.settle(at: t)
            frame += 1
            t += 1.0 / fps
        }
        XCTAssertEqual(changes.first?.change.to, 0.5, "it has to come down first")
        let probes = changes.filter { $0.change.to == 1 }.map(\.t)
        XCTAssertGreaterThan(probes.count, 0, "it must still try to come back up")
        XCTAssertLessThanOrEqual(probes.count, 3, "at most three probes in three minutes")
        let gaps = zip(probes, probes.dropFirst()).map { $1 - $0 }
        for (a, b) in zip(gaps, gaps.dropFirst()) {
            XCTAssertGreaterThan(b, a, "probe gaps must grow (backoff): \(gaps)")
        }
        // Nothing may sit at the "changes twice a second" level that flapping looks like.
        XCTAssertLessThanOrEqual(changes.count, 7, "\(changes.map { "\($0.change.from)->\($0.change.to)" })")
    }

    func testFailedProbeBacksOffAndSuccessResetsIt() {
        var governor = ScaleGovernor(start: 0.5)
        XCTAssertEqual(governor.requiredQuietWindow, 10)
        // Quiet long enough for a probe, then backpressure as soon as it comes up: the probe failed.
        _ = drive(&governor, from: 0, seconds: 11, lateEvery: 0)
        XCTAssertEqual(governor.level, 1, "the probe happened")
        XCTAssertEqual(governor.requiredQuietWindow, 10, "nothing to back off from yet")
        var t = 11.0
        while governor.level > 0.75, t < 40 {
            if let _ = governor.observe(at: t, late: true) { break }
            governor.settle(at: t)
            t += 1.0 / fps
        }
        XCTAssertEqual(governor.level, 0.5, "and it was undone")
        XCTAssertEqual(governor.requiredQuietWindow, 30, accuracy: 0.001,
                       "3x the window, capped at 300")

        // A long quiet stretch: the next probe survives `probeSeconds`, so the penalty resets.
        t += 5
        let start = t
        while governor.level < 1, t < start + 60 {
            if let _ = governor.observe(at: t, late: false) { break }
            governor.settle(at: t)
            t += 1.0 / fps
        }
        XCTAssertEqual(governor.level, 1, "the backed-off window elapsed, so it came back up")
        _ = drive(&governor, from: t, seconds: 25, lateEvery: 0)
        XCTAssertEqual(governor.requiredQuietWindow, 10, "a probe that held resets the penalty")
    }

    func testMinimumDwellHoldsBothDirections() {
        var governor = ScaleGovernor()
        _ = drive(&governor, from: 0, seconds: 4, lateEvery: 1)      // one step down, at ~3 s
        XCTAssertEqual(governor.level, 0.5)
        // Quiet from here, but the dwell (5 s) has not passed yet at t = 5.
        let early = drive(&governor, from: 4, seconds: 1, lateEvery: 0)
        XCTAssertTrue(early.isEmpty, "a change within the dwell time must be refused")
    }

    func testSamplesDoNotAccumulateForever() {
        var governor = ScaleGovernor()
        _ = drive(&governor, from: 0, seconds: 600, lateEvery: 0)
        // Not exposed directly; the property that matters is that the window did not make the
        // governor stop sampling and it still reacts after 10 minutes of quiet.
        XCTAssertEqual(governor.level, 1)
        let changes = drive(&governor, from: 600, seconds: 6, lateEvery: 1)
        XCTAssertEqual(changes.map(\.to), [0.5])
    }
}
