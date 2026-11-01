import XCTest
@testable import krdcore

/// The DSR probe decides *when* to write 4 bytes and what its answer means. Everything about the
/// timing is arithmetic on a fake clock here, because the failure this replaces was a signal that
/// only fired after seconds of buffering — a probe whose own timing is untested would not help.
final class RTTProbeTests: XCTestCase {
    func testItProbesOnItsIntervalAndNotSooner() throws {
        var probe = RTTProbe(interval: 2, timeout: 2)
        XCTAssertTrue(probe.due(at: 10))
        probe.sent(at: 10)
        XCTAssertFalse(probe.due(at: 10.5), "still outstanding")
        let rtt = probe.reply(at: 10.05)
        XCTAssertEqual(try XCTUnwrap(rtt), 50, accuracy: 0.001)
        XCTAssertFalse(probe.due(at: 11), "not yet an interval since the last write")
        XCTAssertTrue(probe.due(at: 12.01))
        XCTAssertEqual(probe.sent, 1)
    }

    func testAnAnswerWithNothingOutstandingIsIgnored() {
        var probe = RTTProbe()
        XCTAssertNil(probe.reply(at: 5), "a stray CSI 0n must not become a fake round trip")
        XCTAssertEqual(probe.answered, 0)
        XCTAssertTrue(probe.series.isEmpty)
    }

    func testALateAnswerIsGivenUpOnAndThenTheProbeSwitchesOff() {
        var probe = RTTProbe(interval: 2, timeout: 2, missesBeforeOff: 3)
        var now = 0.0
        for expected in 1...3 {
            XCTAssertTrue(probe.due(at: now))
            probe.sent(at: now)
            now += 2.5                       // no answer
            XCTAssertTrue(probe.expire(at: now), "miss \(expected)")
            XCTAssertEqual(probe.misses, expected)
            XCTAssertEqual(probe.isMeasuring, expected < 3, "off after three")
        }
        XCTAssertTrue(probe.unavailable)
        XCTAssertFalse(probe.due(at: now + 100), "a terminal that never answers is not asked again")
        XCTAssertEqual(probe.sent, 3)
    }

    func testAnAnswerClearsTheMisses() throws {
        var probe = RTTProbe(interval: 1, timeout: 1, missesBeforeOff: 2)
        probe.sent(at: 0)
        XCTAssertTrue(probe.expire(at: 5))
        XCTAssertEqual(probe.misses, 1)
        XCTAssertTrue(probe.due(at: 6))
        probe.sent(at: 6)
        let rtt = probe.reply(at: 6.2)
        XCTAssertEqual(try XCTUnwrap(rtt), 200, accuracy: 0.001)
        XCTAssertEqual(probe.misses, 0, "a terminal that answers is not broken")
        XCTAssertFalse(probe.unavailable)
    }

    func testTheIntervalCanBeSlowedDownForCheapRungs() {
        var probe = RTTProbe(interval: 2)
        probe.sent(at: 0)
        _ = probe.reply(at: 0.1)
        probe.setInterval(4)
        XCTAssertFalse(probe.due(at: 3))
        XCTAssertTrue(probe.due(at: 4.1))
        probe.setInterval(0.01)
        XCTAssertEqual(probe.interval, 0.5, "a probe storm is not a thing we allow")
    }

    func testStatisticsComeFromTheSeries() {
        var probe = RTTProbe(interval: 1, timeout: 1)
        for (i, rtt) in [20.0, 30.0, 400.0].enumerated() {
            probe.sent(at: Double(i) * 2)
            _ = probe.reply(at: Double(i) * 2 + rtt / 1000)
        }
        XCTAssertEqual(probe.series.count, 3)
        XCTAssertEqual(probe.lastMs, 400, accuracy: 0.001)
        XCTAssertEqual(probe.p50Ms, 30, accuracy: 0.001)
        XCTAssertTrue(probe.p99Ms >= 400 - 0.001, "the hiccup has to be visible in p99")
    }

    /// The governor asks this question: "is the round trip bad enough to spend a rung on it".
    func testNoAnswerMeansUnknownNotZero() {
        let fresh = RTTProbe()
        XCTAssertTrue(fresh.lastMs.isNaN, "before any answer the number must be unknown")
        XCTAssertFalse(fresh.lastMs > 250, "and unknown must not read as \"fine, 0 ms\"")
    }

    /// The parser and the probe, wired the way `Desk` wires them: an event that *is* the answer feeds
    /// `reply(at:)`, and nothing else does.
    ///
    /// DEC mode 2031 makes the terminal announce its colour scheme with `CSI ? 997 ; 1 n` (dark) /
    /// `CSI ? 997 ; 2 n` (light) — the same final byte as the alive/DES answer this probe measures
    /// (issue #212). Read as an answer, a theme change mid-probe is an *instant* round trip: a sample
    /// that was never a round trip at all, and its shape (`min < 2 ms`) is exactly what the link
    /// verdict reads as a held link. So the report has to land as something else, and the outstanding
    /// probe has to still be waiting for its real answer.
    func testAColourSchemeReportIsNotAnAnswerToTheProbe() {
        var probe = RTTProbe(interval: 2, timeout: 2)
        probe.sent(at: 10)                              // `CSI 5n` is on the wire
        let parser = InputParser()
        var traces: [String] = []
        var statusReports = 0
        parser.onEvent = { event in
            traces.append(event.canonicalTrace)
            switch event {
            case .statusReport:
                // 1 ms later: the phantom shape, and it consumes the probe if it is counted.
                statusReports += 1
                _ = probe.reply(at: 10.001)
            default:
                break
            }
        }

        parser.feed(Array("\u{1B}[?997;1n".utf8))       // the terminal switched to dark
        XCTAssertEqual(probe.answered, 0, "a `?997` report must not be counted as the probe's answer")
        XCTAssertTrue(probe.series.isEmpty, "so the round-trip series did not grow")
        XCTAssertTrue(probe.pendingSince == 10, "the probe is still in flight")
        XCTAssertTrue(probe.isMeasuring)
        XCTAssertEqual(traces, ["colourScheme dark"],
                       "and it arrived as the theme report, not as silence")
        XCTAssertEqual(statusReports, 0, "a colour-scheme report is not a device status report")

        parser.feed(Array("\u{1B}[0n".utf8))            // the real answer still lands, exactly once
        XCTAssertEqual(traces, ["colourScheme dark", "statusReport"])
        XCTAssertEqual(statusReports, 1)
        XCTAssertEqual(probe.answered, 1)
        XCTAssertEqual(probe.series.count, 1)
        XCTAssertTrue(probe.pendingSince == nil)
    }
}
