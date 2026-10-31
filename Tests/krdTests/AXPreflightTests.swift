import XCTest
@testable import krd

/// Issue #103: the preflight cost ~50 ms of every `krd ax` invocation — the grant (8 ms), a
/// window list only `doctor` read (22–28 ms) and a systemwide round trip (17.5–20.5 ms) — and
/// every verb but `doctor` threw the result away (`_ = try preflight(options)`). It now runs
/// only for a verb that has something to report, and these tests pin the two halves of that:
///
/// 1. **the verdict**, through `AXReadiness` / `AXDiagnosis.readiness`: (no grant) → 3,
///    (granted, does not answer) → 4, (granted, answers) → the verb's own answer. That mapping is
///    the whole contract the preflight carried, and it is a value, so a machine that cannot
///    grant Accessibility can still pin it (this one answers `err=-25208`).
/// 2. **when it is paid for**, through `AXCommand.staged(_:retrying:diagnose:_:)`, whose
///    `diagnose` is injectable: a successful verb must make **zero** diagnosis calls, a failure
///    exactly one, and a write must never be run twice.
///
/// What this cannot prove: the millisecond cost of the three calls. No grant here means no honest
/// wall clock (the AX calls answer nothing), so what is asserted is the *number of times the
/// measurement runs*, which is what the ~50 ms was attached to: 1 per failed invocation, 0 per
/// successful one, where before it was 1 per invocation of any kind.
final class AXPreflightTests: XCTestCase {

    // MARK: - the verdict

    private func diagnosis(trusted: Bool, answers: Bool,
                           error: AXError = .cannotComplete) -> AXDiagnosis {
        AXDiagnosis(trusted: trusted, onScreenWindows: trusted ? 24 : -1, answers: answers,
                    first: error, final: error, retried: true, sample: "-")
    }

    func testTheThreeAnswersAreTheThreeOutcomes() {
        XCTAssertEqual(AXReadiness.of(trusted: true, answers: true), .ready)
        XCTAssertEqual(AXReadiness.of(trusted: true, answers: false), .notAnswering)
        XCTAssertEqual(AXReadiness.of(trusted: false, answers: false), .untrusted)
        // An ungranted Mac cannot answer, but if it somehow did, "answers" wins: the API being
        // alive is the only thing that makes a failure the verb's own.
        XCTAssertEqual(AXReadiness.of(trusted: false, answers: true), .ready)
    }

    func testNoGrantIsExitThreeAndGrantedButSilentIsExitFour() {
        let untrusted = diagnosis(trusted: false, answers: false, error: .apiDisabled)
        XCTAssertEqual(untrusted.readiness, .untrusted)
        XCTAssertEqual(untrusted.exit, .permission)
        let untrustedFailure = try? XCTUnwrap(untrusted.failure)
        XCTAssertEqual(untrustedFailure?.code, .permission)

        let silent = diagnosis(trusted: true, answers: false, error: .cannotComplete)
        XCTAssertEqual(silent.readiness, .notAnswering)
        XCTAssertEqual(silent.exit, .environment)
        XCTAssertEqual(silent.failure?.code, .environment)

        let green = diagnosis(trusted: true, answers: true, error: .success)
        XCTAssertEqual(green.readiness, .ready)
        XCTAssertEqual(green.exit, .ok)
        XCTAssertNil(green.failure)
    }

    /// The sentences are the preflight's own, not a second copy: an ungranted Mac still prints the
    /// grant walkthrough, and a silent one still says the Mac may be asleep.
    func testTheFailuresAreTheSameProseWithTheSameAXErrorAsBefore() {
        let untrusted = diagnosis(trusted: false, answers: false, error: .apiDisabled)
        if case .permission(let prose, let ax)? = untrusted.failure {
            XCTAssertEqual(prose, AXCommand.permissionText)
            XCTAssertEqual(ax, "apiDisabled")
        } else {
            XCTFail("no grant must be a permission failure, got \(String(describing: untrusted.failure))")
        }

        let silent = diagnosis(trusted: true, answers: false, error: .cannotComplete)
        if case .environment(let prose, let ax)? = silent.failure {
            XCTAssertEqual(prose, AXCommand.environmentText(error: .cannotComplete))
            XCTAssertEqual(ax, "cannotComplete")
        } else {
            XCTFail("a silent Mac must be an environment failure")
        }
    }

    /// `doctor` reads the same verdict: its exit code is 3 / 4 / 0 for the same three answers, so
    /// the deferred preflight cannot make `doctor` disagree with the verb that follows it.
    func testDoctorExitsWhatTheVerdictSays() {
        XCTAssertEqual(AXCommand.doctorOutput(diagnosis(trusted: false, answers: false)).exit, .permission)
        XCTAssertEqual(AXCommand.doctorOutput(diagnosis(trusted: true, answers: false)).exit, .environment)
        XCTAssertEqual(AXCommand.doctorOutput(diagnosis(trusted: true, answers: true)).exit, .ok)
    }

    // MARK: - when it is paid for

    /// A counter standing in for `AXCommand.measure()`: one entry = one preflight's worth of
    /// `AXIsProcessTrusted` + window list + systemwide round trip.
    private final class Counter {
        var calls = 0
        var answer: AXDiagnosis
        init(_ answer: AXDiagnosis) { self.answer = answer }
        func diagnose() -> AXDiagnosis { calls += 1; return answer }
    }

    private func options(_ verb: String) -> AXOptions {
        var options = AXOptions()
        options.verb = verb
        return options
    }

    func testASuccessfulVerbPaysNothingForThePreflight() throws {
        for verb in ["windows", "screen", "tree", "find", "press", "set"] {
            let counter = Counter(diagnosis(trusted: false, answers: false))
            var bodies = 0
            let code = try AXCommand.staged(options(verb), diagnose: counter.diagnose) {
                bodies += 1
                return 0
            }
            XCTAssertEqual(code, 0)
            XCTAssertEqual(bodies, 1, "\(verb): the body runs once")
            // This is the issue: before #103 every one of these made three accessibility calls
            // before the first node was read. Now a success makes none.
            XCTAssertEqual(counter.calls, 0, "\(verb): a successful run must not diagnose the Mac")
        }
    }

    func testAFailureThatCouldBeTheGrantIsDiagnosedExactlyOnce() {
        let untrusted = Counter(diagnosis(trusted: false, answers: false, error: .apiDisabled))
        let failure = AXFailure.notFound("no window in the accessibility tree")
        XCTAssertThrowsError(try AXCommand.staged(options("tree"), diagnose: untrusted.diagnose) {
            throw failure
        }) { thrown in
            // 5 was really a 3: the answer the preflight used to give before the verb ran.
            XCTAssertEqual((thrown as? AXFailure)?.code, .permission)
        }
        XCTAssertEqual(untrusted.calls, 1, "one diagnosis per invocation, not one per read")
    }

    func testAGreenDiagnosisKeepsTheVerbSOwnFailure() {
        let green = Counter(diagnosis(trusted: true, answers: true, error: .success))
        XCTAssertThrowsError(try AXCommand.staged(options("find"), diagnose: green.diagnose) {
            throw AXFailure.notFound("nothing matched \"zzz\"")
        }) { thrown in
            // The Mac is fine, so "nothing matched" is the truth and keeps exit 5.
            XCTAssertEqual((thrown as? AXFailure)?.code, .notFound)
        }
        XCTAssertEqual(green.calls, 1)
    }

    func testUsageAndNotActionableNeverPayForADiagnosis() {
        for failure: AXFailure in [.usage("unknown option \"--nonsense\""),
                                   .notActionable("@e7 does not answer press")] {
            let counter = Counter(diagnosis(trusted: false, answers: false))
            var bodies = 0
            XCTAssertThrowsError(try AXCommand.staged(options("press"), diagnose: counter.diagnose) {
                bodies += 1
                throw failure
            }) { thrown in
                XCTAssertEqual((thrown as? AXFailure)?.code, failure.code)
            }
            // `usage` is decided before any accessibility call, and `notActionable` means the API
            // answered -- neither is a question for the Mac.
            XCTAssertEqual(counter.calls, 0, "\(failure.code): no diagnosis")
            XCTAssertEqual(bodies, 1, "\(failure.code): no retry")
        }
    }

    /// The retry the preflight used to make *up front* (a Background/ssh process answers
    /// `cannotComplete` on its first accessibility call) is made *after* a green diagnosis, which
    /// is what touched the window server. One extra body run, not a second diagnosis.
    func testAStartupNoiseEnvironmentFailureIsRetriedOnceForARead() throws {
        let green = Counter(diagnosis(trusted: true, answers: true, error: .success))
        var bodies = 0
        let code = try AXCommand.staged(options("tree"), diagnose: green.diagnose) {
            bodies += 1
            if bodies == 1 { throw AXFailure.environment("first call", ax: "cannotComplete") }
            return 0
        }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(bodies, 2, "one retry")
        XCTAssertEqual(green.calls, 1, "one diagnosis")
    }

    func testAWriteIsNeverRunTwice() {
        let green = Counter(diagnosis(trusted: true, answers: true, error: .success))
        var bodies = 0
        XCTAssertThrowsError(try AXCommand.staged(options("press"), retrying: false,
                                                  diagnose: green.diagnose) {
            bodies += 1
            throw AXFailure.environment("AXPress failed: cannotComplete", ax: "cannotComplete")
        }) { thrown in
            XCTAssertEqual((thrown as? AXFailure)?.code, .environment)
        }
        // An `AXPress` that returned cannotComplete may have landed; a retry is a second click.
        XCTAssertEqual(bodies, 1, "press must not be retried")
        XCTAssertEqual(green.calls, 1)
    }

    func testARedDiagnosisEndsItWithoutRetryingTheBody() {
        let untrusted = Counter(diagnosis(trusted: false, answers: false, error: .apiDisabled))
        var bodies = 0
        XCTAssertThrowsError(try AXCommand.staged(options("tree"), diagnose: untrusted.diagnose) {
            bodies += 1
            throw AXFailure.environment("cannotComplete", ax: "cannotComplete")
        }) { thrown in
            // The grant is the answer, and it is the answer on the first try: no second body run
            // against a Mac that cannot answer.
            XCTAssertEqual((thrown as? AXFailure)?.code, .permission)
        }
        XCTAssertEqual(bodies, 1)
        XCTAssertEqual(untrusted.calls, 1)
    }

    /// No cache, and none needed: the measurement can run at most once per process (a verb body
    /// runs once, and only a failed or empty one asks), so there is nothing for an answer to be
    /// reused by -- and nothing that could go stale when the grant is revoked or the Mac wakes.
    func testOneInvocationAsksAtMostOnce() throws {
        let counter = Counter(diagnosis(trusted: true, answers: false, error: .cannotComplete))
        XCTAssertThrowsError(try AXCommand.staged(options("windows"), retrying: false,
                                                 diagnose: counter.diagnose) {
            throw AXFailure.notFound("no windows")
        })
        XCTAssertEqual(counter.calls, 1)
    }
}
