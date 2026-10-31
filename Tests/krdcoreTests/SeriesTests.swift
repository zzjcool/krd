import XCTest
@testable import krdcore

/// `Series` and `Rates` are the two things every diagnostic number goes through, so they are tested
/// directly rather than through a panel: a percentile that averages, or a rate that divides by zero,
/// is a wrong number that looks like a right one.
final class SeriesTests: XCTestCase {
    func testAnEmptySeriesSaysUnknownRatherThanZero() {
        let series = Series(capacity: 8)
        XCTAssertTrue(series.isEmpty)
        XCTAssertTrue(series.last.isNaN)
        XCTAssertTrue(series.percentile(0.99).isNaN)
        XCTAssertTrue(series.max.isNaN)
        XCTAssertTrue(series.mean.isNaN)
        XCTAssertEqual(Series.show(series.last), "—", "a missing sample must not read as 0 ms")
        XCTAssertEqual(Series.show(12.34), "12.3")
    }

    func testTheRingKeepsTheNewestSamples() {
        var series = Series(capacity: 3)
        for v in [1.0, 2.0, 3.0, 4.0, 5.0] { series.add(v) }
        XCTAssertEqual(series.count, 3)
        XCTAssertEqual(series.last, 5)
        XCTAssertEqual(series.all, [3, 4, 5], "oldest first, and the two oldest are gone")
        XCTAssertEqual(series.max, 5)
        XCTAssertEqual(series.mean, 4)
    }

    func testPercentilesAreNearestRankNotAverages() {
        // 98 frames at 20 ms and two hiccups: the average hides them, p99 does not. (p99 of 100
        // samples is the 99th value, so *one* outlier in a hundred would sit just outside it —
        // which is why the panel's "worst" is `max` and its "typical bad" is p99.)
        var series = Series(capacity: 300)
        for _ in 0..<98 { series.add(20) }
        series.add(300)
        series.add(300)
        XCTAssertEqual(series.percentile(0.5), 20)
        XCTAssertEqual(series.percentile(0.99), 300, "the hiccups have to be visible somewhere")
        XCTAssertEqual(series.max, 300)
        XCTAssertEqual(series.percentile(1.0), 300)
        XCTAssertEqual(series.percentile(0.0), 20)
        XCTAssertLessThan(series.mean, 26, "and the average is exactly what hides them")

        var single = Series(capacity: 300)
        for _ in 0..<99 { single.add(20) }
        single.add(400)
        XCTAssertEqual(single.max, 400, "a single outlier still shows in max")
        XCTAssertEqual(single.percentile(0.99), 20, "and is just outside p99 by construction")
    }

    /// Issue #91: `pipe p99` was the p99 of *one frame per second*, so a frame that blocked for
    /// 1,368 ms was reported as 0.36 ms. The series is fed per frame now; this pins the arithmetic
    /// the panel's two numbers rest on — the ring's `max` reports that frame, and its p99 (the
    /// 4th-worst of 300 by construction) cannot, which is exactly why `pipe max` exists.
    func testOneHugeFrameAmongSmallOnesIsReported() {
        var pipe = Series(capacity: 300)
        for _ in 0..<299 { pipe.add(0.3) }
        pipe.add(1368.0)
        XCTAssertEqual(pipe.count, 300)
        XCTAssertEqual(pipe.last, 1368.0, "the huge frame is the newest sample")
        XCTAssertEqual(pipe.max, 1368.0, "one 1,368 ms frame has to read as 1,368 ms")
        XCTAssertEqual(pipe.percentile(0.99), 0.3, accuracy: 1e-9,
                       "nearest-rank p99 of 300 samples is the 4th worst: a single outlier is outside"
                       + " it, so p99 alone would still call this run 0.3 ms")
    }

    func testRemoveAllKeepsTheCapacity() {
        var series = Series(capacity: 4)
        series.add(1)
        series.removeAll()
        XCTAssertTrue(series.isEmpty)
        for v in [1.0, 2.0, 3.0, 4.0, 5.0] { series.add(v) }
        XCTAssertEqual(series.all, [2, 3, 4, 5], "the ring still wraps correctly after a reset")
    }

    // MARK: rates

    private func counters(frames: Int, delivered: Int, tiles: Int, bytes: Int,
                          skipped: Int = 0, idle: Int = 0) -> Rates.Counters {
        Rates.Counters(frames: frames, delivered: delivered, tiles: tiles, bytes: bytes,
                       skipped: skipped, idle: idle)
    }

    func testRatesAreDeltasOverTheInterval() {
        let before = counters(frames: 100, delivered: 120, tiles: 4_000, bytes: 10_000_000)
        let after = counters(frames: 120, delivered: 145, tiles: 4_400, bytes: 12_097_152)
        let rates = Rates(previous: before, current: after, seconds: 2)
        XCTAssertEqual(rates.fps, 10, "20 drawn frames in 2 s")
        XCTAssertEqual(rates.captureFps, 12.5, "25 delivered in 2 s")
        XCTAssertEqual(rates.tilesPerSec, 200)
        XCTAssertEqual(rates.mbps, 1.0, "2 MiB in 2 s")
    }

    func testSkippedAndIdleAreRatesToo() {
        let rates = Rates(previous: counters(frames: 0, delivered: 0, tiles: 0, bytes: 0),
                          current: counters(frames: 0, delivered: 0, tiles: 0, bytes: 0,
                                            skipped: 30, idle: 12), seconds: 3)
        XCTAssertEqual(rates.skippedPerSec, 10)
        XCTAssertEqual(rates.idlePerSec, 4)
    }

    func testACounterResetDoesNotPrintANegativeRate() {
        let rates = Rates(previous: counters(frames: 500, delivered: 500, tiles: 9_000, bytes: 9_000),
                          current: counters(frames: 3, delivered: 3, tiles: 10, bytes: 100), seconds: 1)
        XCTAssertEqual(rates.fps, 0, "a reconnect resets the counters; a negative rate is a lie")
        XCTAssertEqual(rates.mbps, 0)
    }

    func testAZeroIntervalDoesNotDivideByZero() {
        let rates = Rates(previous: counters(frames: 1, delivered: 1, tiles: 1, bytes: 1),
                          current: counters(frames: 99, delivered: 99, tiles: 99, bytes: 99), seconds: 0)
        XCTAssertEqual(rates.fps, 0)
        XCTAssertEqual(rates.mbps, 0)
        XCTAssertFalse(rates.fps.isNaN)
    }
}
