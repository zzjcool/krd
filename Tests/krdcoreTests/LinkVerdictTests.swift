import XCTest
@testable import krdcore

/// The rule behind the pill (issue #199), with no terminal, no clock and no pty in it.
///
/// The numbers are the ones the issue froze, and they come from the plan's measurements
/// (`docs/design-ui-v2` §2.2, `probe/termcaps.py`) with ~2x of slack: on a lossless ssh link the
/// median round trip is **23.5 ms** with OpenSSH's `ObscureKeystrokeTiming` on and **0.59 ms** with
/// it off, while the *minimum* stays **0.71 ms** in both cases. So the minimum is the whole design:
/// a fast minimum with a late median is the client batching the terminal's replies, and a late
/// minimum with a late median is a pipe that is behind.
///
/// Two properties get their own tests because they are the two ways this rule could hurt a reader:
/// it may not fire on a link that is genuinely slow (`slow`, not `held`), and it may not fire at all
/// while the probe has no fresh answer — #187's own guard, which is what keeps a stale sample from
/// being read as a measurement.
final class LinkVerdictTests: XCTestCase {
    // MARK: - the table

    func testTheSignatureIsAFastMinimumUnderALateMedian() {
        // Measured, default OpenSSH 10: p50 21.2-23.5 ms over a 0.71 ms minimum.
        XCTAssertEqual(LinkVerdict.classify(minMs: 0.71, p50Ms: 23.5, count: 20), .held)
        // A congested link: the minimum climbed with the median, so this is *not* the pill.
        XCTAssertEqual(LinkVerdict.classify(minMs: 27.7, p50Ms: 65.9, count: 20), .slow)
        // `ObscureKeystrokeTiming no`, and `interval:5`: the median came back, nothing to say.
        XCTAssertEqual(LinkVerdict.classify(minMs: 0.39, p50Ms: 0.60, count: 20), .fine)
        XCTAssertEqual(LinkVerdict.classify(minMs: 0.70, p50Ms: 5.79, count: 20), .fine)
        // In between — a link with a 10 ms floor and a 40 ms median is behind, not held.
        XCTAssertEqual(LinkVerdict.classify(minMs: 10, p50Ms: 40, count: 20), .slow)
    }

    func testTooFewAnswersIsUnknownRatherThanFine() {
        for count in 0..<LinkVerdict.minAnswers {
            XCTAssertEqual(LinkVerdict.classify(minMs: 0.7, p50Ms: 23.5, count: count), .unknown,
                           "\(count) answers is not enough for the rule to speak")
        }
        XCTAssertEqual(LinkVerdict.classify(minMs: 0.7, p50Ms: 23.5, count: LinkVerdict.minAnswers),
                       .held, "eight answers is exactly enough")
    }

    /// A missing measurement is not a fast one. `Series` answers `nan` for an empty ring, and
    /// `nan < 2` is false — read as a comparison it would have said `slow`, which is the worst of the
    /// wrong answers for the one state that means "I don't know".
    func testNoMeasurementIsNotAMeasurementOfZero() {
        XCTAssertEqual(LinkVerdict.classify(minMs: .nan, p50Ms: .nan, count: 0), .unknown)
        XCTAssertEqual(LinkVerdict.classify(minMs: .nan, p50Ms: 23.5, count: 20), .unknown)
        XCTAssertEqual(LinkVerdict.classify(minMs: 0.7, p50Ms: .nan, count: 20), .unknown)
        XCTAssertEqual(LinkVerdict.classify(minMs: .infinity, p50Ms: 23.5, count: 20), .unknown)
    }

    /// The thresholds are the issue's, not a tuning knob: the pair is what makes the pill mean "the
    /// link is not slow". Asserted on the boundary itself, because a later "small tweak" to either
    /// number is exactly the change this test is here to refuse.
    func testTheThresholdsAreTheIssuesNumbers() {
        XCTAssertEqual(LinkVerdict.heldMinMs, 2)
        XCTAssertEqual(LinkVerdict.heldP50Ms, 15)
        XCTAssertEqual(LinkVerdict.minAnswers, 8)
        // The boundary in each direction.
        XCTAssertEqual(LinkVerdict.classify(minMs: 1.99, p50Ms: 15, count: 8), .held)
        XCTAssertEqual(LinkVerdict.classify(minMs: 2.0, p50Ms: 15, count: 8), .slow)
        XCTAssertEqual(LinkVerdict.classify(minMs: 1.99, p50Ms: 14.99, count: 8), .fine)
    }

    // MARK: - only held draws the pill

    func testOnlyHeldHasAPillAndOnlyTheSymptomsHaveAdvice() {
        XCTAssertEqual(LinkVerdict.held.pill, "[ keys held ]")
        for quiet in [LinkVerdict.fine, .unknown, .slow] {
            XCTAssertNil(quiet.pill, "\(quiet) must not draw the pill")
        }
        XCTAssertFalse(LinkVerdict.fine.isSymptom)
        XCTAssertFalse(LinkVerdict.unknown.isSymptom)
        XCTAssertTrue(LinkVerdict.held.isSymptom)
        XCTAssertTrue(LinkVerdict.slow.isSymptom)
        // The pill opens a panel; the line in it has to be the setting, spelled as ssh spells it.
        XCTAssertEqual(LinkVerdict.held.advice?.contains("ObscureKeystrokeTiming no"), true)
        XCTAssertNotNil(LinkVerdict.slow.advice, "a slow link gets a sentence too, just not a pill")
        XCTAssertNil(LinkVerdict.fine.advice)
        XCTAssertNil(LinkVerdict.unknown.advice, "a terminal without DSR has nothing to fix")
    }

    // MARK: - the probe's own guard

    /// The rule needs a *series*, and a series can be stale: `expire()` leaves it alone on purpose
    /// (the report still wants the history), so the last number that happened to land can sit in it
    /// for good. This is #187's guard, reused rather than re-invented — no verdict may be derived
    /// from an answer that is no longer a measurement.
    func testTheProbeGivesNoVerdictWithoutAFreshAnswer() {
        var probe = RTTProbe(interval: 0.5, timeout: 2, missesBeforeOff: 3)
        // Eight answers, one fast and the rest on the 20 ms grid — the held signature, built the way
        // the terminal would build it.
        var now = 0.0
        for i in 1...8 {
            XCTAssertTrue(probe.due(at: now))
            probe.sent(at: now)
            _ = probe.reply(at: now + (i == 1 ? 0.0008 : 0.020))
            now += 1
        }
        XCTAssertEqual(probe.linkVerdict(), .held, "the measured signature is the pill")
        XCTAssertEqual(probe.minMs, 0.8, accuracy: 0.001)

        // The next probe goes unanswered: the freshest sample is now stale, whatever the ring says.
        XCTAssertTrue(probe.due(at: now))
        probe.sent(at: now)
        XCTAssertTrue(probe.expire(at: now + 3))
        XCTAssertEqual(probe.series.count, 8, "the history is kept on purpose")
        XCTAssertEqual(probe.linkVerdict(), .unknown, "a stale answer is not a verdict")

        // …and a terminal that never answers is `unknown` for good, not `held` from the ring.
        probe.sent(at: now + 4)
        _ = probe.expire(at: now + 7)
        probe.sent(at: now + 8)
        _ = probe.expire(at: now + 11)
        XCTAssertTrue(probe.unavailable)
        XCTAssertEqual(probe.linkVerdict(), .unknown)
    }

    /// A probe that has answered nothing says `unknown`, not `fine`: the two are different claims and
    /// only one of them is true.
    func testAnUnansweredProbeIsUnknownAndNotFine() {
        let probe = RTTProbe()
        XCTAssertEqual(probe.linkVerdict(), .unknown)
        XCTAssertTrue(probe.minMs.isNaN)
    }
}
