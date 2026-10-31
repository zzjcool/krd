import XCTest
@testable import krdcore

/// `--quality auto`'s frame-rate rungs deliver the rate they name, whatever the capture cadence is.
///
/// The gate is pure arithmetic (`FrameGate`), so this is a table: feed it a source that ticks every
/// `1000/source` ms for ten seconds and count the frames it let through. The tolerance is the
/// counting tolerance, not a fudge factor: a ten-second window holds a whole number of frames, so
/// the rate lands within one frame of the rung (1/10 s = 0.1 fps), and 0.5 fps leaves room for the
/// window's endpoints.
///
/// The bug this pins (issue #140) was that the gate kept a *last-draw mark* instead of an owed
/// deadline, so the delivered period was `ceil(due / sourcePeriod)` capture periods and could never
/// be `due`: the 15 fps rung out of the default 20 fps capture (50 ms) drew every second frame,
/// 100 ms, 10 fps — the rung below it, which is why the rest of the ladder got spent for nothing.
final class FrameGateTests: XCTestCase {
    /// One frame every `1000 / fps` ms, starting at t=0, for `seconds`.
    private func arrivals(fps: Int, seconds: Double) -> [Double] {
        let period = 1000.0 / Double(fps)
        var t = 0.0
        var out: [Double] = []
        while t <= seconds * 1000.0 {
            out.append(t)
            t += period
        }
        return out
    }

    /// The frames the gate draws on that source, and the rate over the counted window.
    ///
    /// Exactly what `main.swift` does per frame: `owesFrame` before the frame is encoded, and
    /// `tookFrame` once it is known to change the picture (a frame that draws nothing must not
    /// spend the rung's slot, #95). Here every frame changes something, so the two are adjacent.
    ///
    /// `rate` is what a stats window would print (count over elapsed, which is what `--stats` and the
    /// `--dev` bar show); `meanGap` is the delivered period, i.e. the arithmetic without the window's
    /// ends in it.
    private func delivered(source fps: Int, rung: Double, seconds: Double = 12,
                           skip: Double = 2)
        -> (rate: Double, meanGap: Double, drawn: Int) {
        var gate = FrameGate(fps: Int(rung.rounded()))
        var drawn: [Double] = []
        for t in arrivals(fps: fps, seconds: seconds) {
            if gate.owesFrame(at: t) {
                gate.tookFrame(at: t)
                drawn.append(t)
            }
        }
        let counted = drawn.filter { $0 >= skip * 1000.0 && $0 < seconds * 1000.0 }
        let meanGap = counted.count > 1 ? (counted[counted.count - 1] - counted[0]) / Double(counted.count - 1) : 0
        return (Double(counted.count) / (seconds - skip), meanGap, counted.count)
    }

    private let rungs = QualityGovernor.ladder.map(\.fps)
    private let sources = [60, 30, 20]
    private let tolerance = 0.5

    /// The table this bug is about, and the check that every cell delivers its rung.
    func testEveryRungDeliversItsRateFromEveryCaptureCadence() {
        var table = "\n  source  rung  interval  delivered  mean gap  verdict\n"
        for source in sources.reversed() {
            for rung in Set(rungs).sorted(by: >) where Double(rung) < Double(source) {
                let got = delivered(source: source, rung: Double(rung))
                let period = 1000.0 / Double(rung)
                let ok = abs(got.rate - Double(rung)) <= tolerance
                table += String(format: "  %5d  %4d  %7.2f  %9.2f  %7.2f  %@\n",
                                source, rung, period, got.rate, got.meanGap, ok ? "ok" : "WRONG")
                // The rate a stats window prints: count over elapsed, one frame's worth of slack.
                XCTAssertEqual(got.rate, Double(rung), accuracy: tolerance,
                               "the \(rung) fps rung delivered \(got.rate) fps from a \(source) fps "
                               + "capture (\(got.drawn) frames in 10 s)")
                // The delivered *period* -- the arithmetic without the window's ends in it, which
                // can cut a gap in half: 0.3 fps is still far below the 5 fps the bug cost.
                XCTAssertEqual(1000.0 / got.meanGap, Double(rung), accuracy: 0.3,
                               "the delivered period of the \(rung) fps rung from a \(source) fps capture")
            }
        }
        print("krd: --quality auto rungs, 10 s of a fixed-cadence source (after a 2 s warm-up)" + table)
    }

    /// The two rungs that were *already* right, because their interval happened to be a whole number
    /// of capture periods (or the capture period itself): they must not move.
    ///
    /// - The 20 fps rung out of a 60 fps capture: 50 ms is exactly 3 x 16.67 ms.
    /// - The 15 fps rung out of 30 fps and 60 fps captures: 66.67 ms is exactly 2 x 33.33 / 4 x 16.67.
    /// - The 10 fps rung out of 20/30/60: 100 ms is exactly 2/3/6 capture periods.
    /// - Any rung equal to the capture rate: the gate is not engaged at all (`effectiveFps ==
    ///   `--fps`), so the loop draws every frame — covered here as the pass-through case.
    func testTheRungsThatWereAlreadyRightDoNotMove() {
        let alreadyRight: [(source: Int, rung: Int)] = [
            (60, 20), (60, 15), (60, 10), (30, 15), (30, 10), (20, 10),
        ]
        for (source, rung) in alreadyRight {
            let got = delivered(source: source, rung: Double(rung))
            XCTAssertEqual(got.rate, Double(rung), accuracy: tolerance,
                           "\(rung) fps from a \(source) fps capture was already exact")
        }
        // And the rung that is the capture rate itself never passes through the gate: 20 fps out of
        // a 20 fps capture is every frame, not `ceil(50/50)` of them.
        var gate = FrameGate(fps: 20)
        var drawn = 0
        for t in arrivals(fps: 20, seconds: 10) {
            if gate.owesFrame(at: t) { gate.tookFrame(at: t); drawn += 1 }
        }
        XCTAssertEqual(drawn, arrivals(fps: 20, seconds: 10).count)
    }

    /// The specific regression from the issue: at 15 fps out of a 20 fps capture the delivered
    /// period is *not* two capture periods (100 ms, 10 fps), and the 15 and 10 rungs no longer
    /// deliver the same rate.
    func testThe15FpsRungIsNotThe10FpsRungFromAFasterSource() {
        let fifteen = delivered(source: 20, rung: 15)
        let ten = delivered(source: 20, rung: 10)
        XCTAssertGreaterThan(fifteen.rate, ten.rate + 4,
                             "15 fps (\(fifteen.rate)) and 10 fps (\(ten.rate)) delivered the same "
                             + "rate from a 20 fps source, which is the bug in issue #140")
        XCTAssertEqual(fifteen.rate, 15, accuracy: tolerance)
    }

    /// A rung is a target, not a floor and not a claim on frames that do not exist: a source slower
    /// than the rung delivers the source, never invented frames.
    func testASlowSourceIsNotRoundedUpToTheRung() {
        let got = delivered(source: 10, rung: 15)
        XCTAssertEqual(got.rate, 10, accuracy: tolerance,
                       "a 10 fps capture cannot be made to deliver 15 fps")
        XCTAssertEqual(got.drawn,
                       arrivals(fps: 10, seconds: 12).filter { $0 >= 2000 && $0 < 12000 }.count,
                       "every frame of a slower-than-the-rung source draws")
    }

    /// The deadline is carried, so a frame that arrives a hair early (timer jitter) still draws and
    /// the next one is a full period later — the tolerance cannot accumulate into a faster stream.
    func testJitterDoesNotDriftTheRate() {
        // 20 fps capture with +/- 3 ms of jitter, a deterministic triangle so the test is stable.
        var gate = FrameGate(fps: 15)
        var drawn: [Double] = []
        for (i, t) in arrivals(fps: 20, seconds: 12).enumerated() {
            let jitter = Double([0, 1, -1, 2, -2, 3, -3][i % 7])
            if gate.owesFrame(at: t + jitter) {
                gate.tookFrame(at: t + jitter)
                drawn.append(t + jitter)
            }
        }
        let counted = drawn.filter { $0 >= 2000 && $0 < 12000 }
        XCTAssertEqual(Double(counted.count) / 10.0, 15, accuracy: 1.0,
                       "jitter moved the 15 fps rung to \(Double(counted.count) / 10.0) fps")
    }

    /// A stall does not come back as a burst: once the gate is more than a period behind, the
    /// deadline is pulled back to now instead of paying the deficit back frame by frame.
    func testAStallIsNotRepaidAsABurst() {
        var gate = FrameGate(fps: 15)
        gate.tookFrame(at: 0)                      // due at 66.67
        XCTAssertFalse(gate.owesFrame(at: 10))
        // …nothing arrives for a second, then two frames back to back at 1000 and 1005.
        XCTAssertTrue(gate.owesFrame(at: 1000))
        gate.tookFrame(at: 1000)                   // 1000 - 66.67 > 66.67: deadline resyncs to 1066.67
        XCTAssertFalse(gate.owesFrame(at: 1005), "the frame right after a stall drew too: it is a burst")
        XCTAssertTrue(gate.owesFrame(at: 1066.67))
    }

    /// A rung change owes a frame at once and carries its deadline from there.
    func testARungChangeOwesAFrameImmediately() {
        var gate = FrameGate(fps: 20)
        gate.tookFrame(at: 0)
        XCTAssertFalse(gate.owesFrame(at: 10))
        gate = FrameGate(fps: 15)
        XCTAssertTrue(gate.owesFrame(at: 10))
        gate.tookFrame(at: 10)
        XCTAssertEqual(gate.dueAt, 10 + 1000.0 / 15, accuracy: 1e-9, "the new rung carries its own period")
    }
}
