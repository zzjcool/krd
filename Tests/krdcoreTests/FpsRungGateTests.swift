import XCTest
@testable import krdcore

/// The adaptive frame-rate gate cannot deliver the 15 fps rung from a 20 fps source.
///
/// `Sources/krd/main.swift:2570-2573` (HEAD a438e9c), inside `handleFrame`:
///
/// ```swift
/// if options.qualityAuto, effectiveFps < options.fps {
///     let due = 1000.0 / Double(max(effectiveFps, 1))
///     if started - lastDrawAt < due - 1 { return }   // drop this frame
///     lastDrawAt = started                          // this frame drew
/// }
/// ```
///
/// `lastDrawAt` is the last frame that *drew*, so the gate asks "has a whole period passed since I
/// last drew?" instead of "am I owed a frame?". A source delivering at a fixed period `c` can
/// therefore only ever draw every `ceil(due / c)`-th frame: the delivered period is
/// `c * ceil(due / c)`, never `due`. For the governor's ladder
/// (`QualityGovernor.swift:48-53`: 20, 20, 20, 15, 10 fps) against the default 20 fps capture
/// (`--fps 20`, c = 50 ms) the 15 fps rung (due = 66.67 ms) rounds up to 100 ms — so the rung
/// delivers **10.0 fps, identical to the next rung down**, and the ladder loses a step.
///
/// The predicate has no seam in product source (it is inline in `handleFrame`), so `RungGate` below
/// is a verbatim transcription — the arithmetic is what is under test. The end-to-end number is in
/// `bench/fps-rung/`, and reproducing the rung on a real link is blocked by issue #93 (the ladder
/// never steps under a stalled link).
///
/// Armed with `KRD_RED=1`; the default suite skips it so `swift test` stays green.
final class FpsRungGateTests: XCTestCase {

    /// `main.swift:2570-2573`, transcribed. `due - 1` and the comparison both kept.
    struct ProductGate {
        let sourcePeriod: Double        // ms between arrivals: 1000 / options.fps
        let due: Double                 // ms the rung asks for: 1000 / effectiveFps
        private var lastDrawAt = -Double.greatestFiniteMagnitude
        private(set) var draws = 0

        init(sourcePeriod: Double, due: Double) {
            self.sourcePeriod = sourcePeriod
            self.due = due
        }

        mutating func arrive(at started: Double) -> Bool {
            if started - lastDrawAt < due - 1 { return false }
            lastDrawAt = started
            draws += 1
            return true
        }
    }

    /// The shape the gate would need: a deadline that advances one period per *accepted* frame and
    /// is pulled back to now when the source itself is slower than the rung (otherwise the deadline
    /// runs away and the gate never blocks).
    struct DeadlineGate {
        let sourcePeriod: Double
        let due: Double
        private var nextDue = -Double.greatestFiniteMagnitude
        private(set) var draws = 0

        init(sourcePeriod: Double, due: Double) {
            self.sourcePeriod = sourcePeriod
            self.due = due
        }

        mutating func arrive(at started: Double) -> Bool {
            if started < nextDue { return false }
            if started - nextDue > due { nextDue = started }   // catch up when starved
            nextDue += due
            draws += 1
            return true
        }
    }

    /// 10 s of arrivals every 50 ms (20 fps) against the governor's 15 fps rung.
    private func productDraws(period c: Double, due: Double, seconds: Double = 10) -> Double {
        var gate = ProductGate(sourcePeriod: c, due: due)
        let n = Int(seconds * 1000 / c)
        for i in 0...n { _ = gate.arrive(at: Double(i) * c) }
        return Double(gate.draws) / seconds
    }

    private func deadlineDraws(period c: Double, due: Double, seconds: Double = 10) -> Double {
        var gate = DeadlineGate(sourcePeriod: c, due: due)
        let n = Int(seconds * 1000 / c)
        for i in 0...n { _ = gate.arrive(at: Double(i) * c) }
        return Double(gate.draws) / seconds
    }

    // MARK: the bug

    func testTwentyFpsSourceReachesThe15FpsRung() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KRD_RED"] == "1",
                          "armed with KRD_RED=1")
        let c = 1000.0 / 20          // --fps 20: a frame every 50 ms
        let due = 1000.0 / 15        // the governor's q50/15 rung
        let delivered = productDraws(period: c, due: due)
        XCTAssertEqual(delivered, 15.0, accuracy: 0.5,
                       "the 15 fps rung delivered \(delivered) fps from a 20 fps source")
    }

    /// Red with 10.0: every second frame is dropped, so the rung is the 10 fps rung wearing
    /// another name. `- 1` (a millisecond of slack against timer jitter) does not help: 50 ms
    /// against 65.67 ms is a *whole frame* short, not a rounding error.
    func testThe15FpsRungDeliversTen() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KRD_RED"] == "1",
                          "armed with KRD_RED=1")
        let delivered = productDraws(period: 50, due: 1000.0 / 15)
        XCTAssertEqual(delivered, 10.0, accuracy: 0.1,
                       "diagnosis: the gate quantises the rung down to a multiple of the source period")
    }

    // MARK: what the ladder therefore does (characterisation, green today)

    /// The delivered rate of `rung` fps from a `source` fps capture, with the product's gate.
    func testLadderQuantisationTable() throws {
        let ladder = [20, 20, 20, 15, 10]     // QualityGovernor.ladder: fps of each rung
        for source in [60.0, 30.0, 20.0] {
            let c = 1000.0 / source
            for rung in Set(ladder) {
                let delivered = productDraws(period: c, due: 1000.0 / Double(rung))
                // Never more than asked, and never more than the source can carry.
                XCTAssertLessThanOrEqual(delivered, Double(rung) + 0.6,
                                         "source \(source) rung \(rung) delivered \(delivered)")
                XCTAssertLessThanOrEqual(delivered, source + 0.6)
            }
        }
        // 20 -> 15 is the one that collides with another rung on this ladder.
        XCTAssertEqual(productDraws(period: 50, due: 1000.0 / 15),
                       productDraws(period: 50, due: 1000.0 / 10),
                       "the 15 fps and 10 fps rungs are the same rate from a 20 fps source")
    }

    /// The rung is reachable as soon as the source is fast enough for `due` to be less than two
    /// source periods: a 30 fps capture (33.3 ms) hits 66.67 ms in two frames and delivers 15 fps.
    func testThirtyFpsSourceDoesReach15() throws {
        let delivered = productDraws(period: 1000.0 / 30, due: 1000.0 / 15)
        XCTAssertEqual(delivered, 15.0, accuracy: 0.4,
                       "a 30 fps source should reach the 15 fps rung")
    }

    // MARK: the fix shape

    func testDeadlineGateReaches15() throws {
        let delivered = deadlineDraws(period: 50, due: 1000.0 / 15)
        XCTAssertEqual(delivered, 15.0, accuracy: 0.5,
                       "an owed-frame deadline delivers the rung instead of half of it")
    }

    func testDeadlineGateStillRespectsASlowSource() throws {
        // A source slower than the rung must not be gated at all: 10 fps source, 15 fps rung.
        let delivered = deadlineDraws(period: 100, due: 1000.0 / 15)
        XCTAssertEqual(delivered, 10.0, accuracy: 0.2,
                       "the gate must never invent frames")
    }
}
