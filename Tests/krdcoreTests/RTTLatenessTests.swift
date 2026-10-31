import XCTest
@testable import krdcore

/// The lateness question the frame path asks about the link (`RTTProbe.isLate`), on a synthetic
/// timeline (#52, #187).
///
/// What went wrong: on OpenSSH 10 the terminal batches the `CSI 0n` answer behind
/// `ObscureKeystrokeTiming`, so one answer came back at 258 ms on a link whose round trip is 25 ms.
/// `main.swift` read only the **latest** answer, the probe goes out every 2 s while the tick that
/// consumes it runs at 1 Hz, so that one answer was "the link" for ~2 s and every frame written in
/// that time counted as late — 31 of 61 at 20 fps, a majority, which spent a rung of the quality
/// ladder on a link that was never congested.
///
/// These tests are the specification of the rule: one outlier answer is not congestion, two
/// consecutive over-budget answers are, and a probe that is stale or switched off is never late —
/// `rtt —` in the panel is not a measurement of 400 ms.
final class RTTLatenessTests: XCTestCase {
    /// One slow answer among good ones must not make a single frame late, and must not take a rung.
    func testOneOutlierAnswerAmongGoodOnesNeverMakesFramesLate() throws {
        var probe = RTTProbe(interval: 2, timeout: 2)
        var governor = QualityGovernor()
        // The third answer is the one #187 measured; probes every 2 s for 40 s, as `Desk` sends them.
        let outlierSentAt = 4.0
        var everLate = false

        for step in 0...20 {
            let sentAt = Double(step) * 2
            let rtt = sentAt == outlierSentAt ? 0.258 : 0.025
            let answerAt = sentAt + rtt
            probe.sent(at: sentAt)
            XCTAssertEqual(try XCTUnwrap(probe.reply(at: answerAt)), rtt * 1000, accuracy: 0.001)

            // The tick that consumes the answer, and every tick for the next 2 s while it is the
            // freshest sample — exactly the window the bug made late.
            var t = answerAt
            while t < sentAt + 2 {
                if probe.isLate(budgetMs: 250) { everLate = true }
                XCTAssertFalse(probe.isLate(budgetMs: 250),
                               "one \(Int(rtt * 1000)) ms answer at \(answerAt) s must not make the "
                                   + "link late for the next two seconds")
                t += 0.05
            }

            // The frame loop of those two seconds, 20 fps through the rule `main.swift` calls: 61
            // frames is what the panel showed (31 late of 61), enough for the >50 %-of-3 s rule to
            // fire if the outlier is believed. One outlier answer is not congestion, so no rung.
            guard sentAt == outlierSentAt else { continue }
            var firstStep: QualityGovernor.Change?
            for k in 0...60 {
                let sample = QualityGovernor.frameSample(
                    writeMs: 3, targetFps: 20, rttLate: probe.isLate(budgetMs: 250))
                if let change = governor.observe(at: answerAt + Double(k) * 0.05,
                                                late: sample.late, span: sample.span) {
                    firstStep = firstStep ?? change
                }
            }
            XCTAssertNil(firstStep, "one outlier answer must not step the ladder; got "
                + "\(firstStep?.line ?? "no change")")
            XCTAssertEqual(governor.index, 0,
                           "one outlier answer must not step the ladder; got rung \(governor.index)")
        }

        XCTAssertFalse(everLate, "40 s of 25 ms answers with one 258 ms outlier is never late")
        XCTAssertEqual(governor.index, 0)
    }

    /// The rule itself: the last **two** answers have to be over budget, and a good one in between
    /// starts the pair again.
    func testOneOverBudgetAnswerIsNotLateButTwoConsecutiveOnesAre() throws {
        var probe = RTTProbe(interval: 2, timeout: 2)
        probe.sent(at: 0)
        XCTAssertEqual(try XCTUnwrap(probe.reply(at: 0.3)), 300, accuracy: 0.001)
        XCTAssertFalse(probe.isLate(budgetMs: 250), "one outlier is not congestion")
        probe.sent(at: 2)
        XCTAssertEqual(try XCTUnwrap(probe.reply(at: 2.3)), 300, accuracy: 0.001)
        XCTAssertTrue(probe.isLate(budgetMs: 250), "two consecutive over-budget answers are")

        // 300, 25, 300 is one outlier on either side of a good answer, not congestion.
        var reset = RTTProbe(interval: 2, timeout: 2)
        for (i, ms) in [300.0, 25.0, 300.0].enumerated() {
            let sentAt = Double(i) * 2
            reset.sent(at: sentAt)
            XCTAssertEqual(try XCTUnwrap(reset.reply(at: sentAt + ms / 1000)), ms, accuracy: 0.001)
        }
        XCTAssertFalse(reset.isLate(budgetMs: 250), "a good answer in between resets the pair")
    }

    /// A probe that stopped answering must not keep the link late forever: `expire()` leaves
    /// `series` alone, so the last real measurement is still 400 ms, and it is stale.
    func testAnUnavailableOrExpiredProbeIsNeverLate() throws {
        var probe = RTTProbe(interval: 2, timeout: 2, missesBeforeOff: 2)
        probe.sent(at: 0)
        _ = try XCTUnwrap(probe.reply(at: 0.4))
        probe.sent(at: 2)
        _ = try XCTUnwrap(probe.reply(at: 2.4))
        XCTAssertEqual(probe.series.last, 400, accuracy: 0.001)
        XCTAssertTrue(probe.isLate(budgetMs: 250), "two 400 ms answers are congestion")

        // One miss: the newest probe expired unanswered.
        probe.sent(at: 4)
        XCTAssertTrue(probe.expire(at: 6.5))
        XCTAssertEqual(probe.series.last, 400, accuracy: 0.001,
                       "the panel still shows the last real measurement")
        XCTAssertFalse(probe.isLate(budgetMs: 250), "the freshest sample is stale")

        // Misses enough to switch the probe off: `rtt —`, not `rtt 400`.
        probe.sent(at: 8)
        XCTAssertTrue(probe.expire(at: 10.5))
        XCTAssertTrue(probe.unavailable)
        XCTAssertEqual(probe.series.last, 400, accuracy: 0.001)
        XCTAssertFalse(probe.isLate(budgetMs: 250),
                       "a probe that stopped answering is not late — that is the `rtt —` case")

        // And before the first answer there is no measurement at all.
        let fresh = RTTProbe(interval: 2, timeout: 2)
        XCTAssertFalse(fresh.isLate(budgetMs: 250), "no answer yet is not late")
    }

    /// The opposite mistake would be to swallow real congestion: when every answer is 400 ms the
    /// link is late from the second answer on — one probe later than a `lastMs` read, and the
    /// ladder still steps down.
    func testSustainedCongestionStillTripsTheLadderOneProbeLater() throws {
        var probe = RTTProbe(interval: 2, timeout: 2)
        var governor = QualityGovernor()
        // The tick model `main.swift` runs: 1 Hz, the answer fed with the input thread's timestamp,
        // the verdict recomputed here and held between ticks.
        var answerAt: Double?
        var answerTicks: [Int] = []
        var lateByTick: [Bool] = []
        for (tick, second) in (0...40).enumerated() {
            let now = Double(second)
            if let at = answerAt, at <= now {
                answerAt = nil
                XCTAssertNotNil(probe.reply(at: at), "the answer is fed on the tick after it lands")
                answerTicks.append(tick)
            }
            if probe.due(at: now) {
                probe.sent(at: now)
                answerAt = now + 0.4
            }
            XCTAssertFalse(probe.expire(at: now), "every probe here is answered inside its timeout")
            lateByTick.append(probe.isLate(budgetMs: 250))
        }
        XCTAssertEqual(probe.misses, 0)

        let first = try XCTUnwrap(answerTicks.first)
        let second = try XCTUnwrap(answerTicks.dropFirst().first)
        XCTAssertFalse(lateByTick[first], "the first 400 ms answer is not congestion yet")
        for tick in second..<lateByTick.count {
            XCTAssertTrue(lateByTick[tick],
                          "from the second answer on (\(answerTicks[1]) s) the link is late")
        }

        // The held verdict is what the frame loop sees, so the ladder must step down through it.
        let congestionAt = Double(second)
        var firstStep: QualityGovernor.Change?
        for k in 0...60 {
            let frameAt = congestionAt + Double(k) * 0.05
            let tick = Swift.min(Swift.max(Int(frameAt.rounded(.down)), 0), lateByTick.count - 1)
            let sample = QualityGovernor.frameSample(
                writeMs: 3, targetFps: 20, rttLate: lateByTick[tick])
            if let change = governor.observe(at: frameAt, late: sample.late, span: sample.span) {
                firstStep = firstStep ?? change
            }
        }
        XCTAssertNotNil(firstStep, "sustained congestion must still step the ladder down")
        XCTAssertEqual(firstStep?.reason, "pipe is behind")
        XCTAssertEqual(governor.index, 1, "one rung, not a plunge")
    }
}
