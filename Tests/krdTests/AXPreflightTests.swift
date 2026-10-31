import XCTest
@testable import krd

/// Issue #103: the preflight cost ~50 ms of every `krd ax` invocation — the grant (8 ms), a
/// window list only `doctor` read (22–28 ms) and a systemwide round trip (17.5–20.5 ms) — and
/// every verb but `doctor` threw the result away (`_ = try preflight(options)`). It now runs
/// only for a verb that has something to report, and these tests pin three things:
///
/// 1. **the verdict**, through `AXReadiness` / `AXDiagnosis.readiness`: (no grant) → 3,
///    (granted, does not answer) → 4, (granted, answers) → the verb's own answer. That mapping is
///    the whole contract the preflight carried, and it is a value, so a machine that cannot
///    grant Accessibility can still pin it (this one answers `err=-25208`).
/// 2. **the wiring**, through `AXCommand.plan(for:)` — verb → (staged, retrying) as a pure value.
///    The previous round put those six decisions in `main()` as literals, so a test that looped
///    over verb names proved nothing and a row (`windows` not retrying) could stay wrong.
/// 3. **when it is paid for**, through `AXCommand.dispatch(_:_:diagnose:_:)`, whose `diagnose` is
///    injectable: a successful verb makes **zero** diagnosis calls, a failed one exactly one, and
///    a verb that asked for the diagnosis itself and then failed makes **one, not two** — the
///    second call is the regression that made the deferred preflight slower than the eager one.
///
/// What this cannot prove: the millisecond cost of the three calls. No grant here means no honest
/// wall clock (the AX calls answer nothing), so what is asserted is the *number of times* the
/// measurement runs, which is what the ~50 ms was attached to.
final class AXPreflightTests: XCTestCase {

    /// Every verb with a plan, and the one string that is not a verb.
    private let verbs = ["windows", "screen", "tree", "find", "press", "set", "doctor"]

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

    // MARK: - the wiring, as a value

    /// The table `main()` reads. Nothing here is a comment: flip a row and this fails.
    func testTheVerbTableIsWhatMainRuns() {
        // Reads: staged, and retried once -- `measure()` has just warmed the window server, and a
        // read that answered `cannotComplete` before that is startup noise.
        for verb in ["windows", "screen", "tree", "find"] {
            XCTAssertEqual(AXCommand.plan(for: verb), .init(staged: true, retrying: true), verb)
        }
        // Writes: staged, never retried. An `AXPress` that returned `cannotComplete` may have
        // landed, and a second one is a second click.
        for verb in ["press", "set"] {
            XCTAssertEqual(AXCommand.plan(for: verb), .init(staged: true, retrying: false), verb)
        }
        // `doctor` reports the diagnosis; it is not run under the decision that produces one.
        XCTAssertEqual(AXCommand.plan(for: "doctor"), .init(staged: false, retrying: false))
        // Anything else is a usage failure, not a verb with a default plan.
        XCTAssertNil(AXCommand.plan(for: "nonsense"))
        XCTAssertNil(AXCommand.plan(for: ""))
    }

    /// Both shapes of the same read: `windows` and `screen` read one window list and print it,
    /// so neither may differ from the other in how it is run. (They did: `windows` was
    /// `retrying: false` while `screen` retried, which nobody noticed because the decision was
    /// spelled inline in `main()`.)
    func testTheSameReadShapeIsRunTheSameWay() {
        XCTAssertEqual(AXCommand.plan(for: "windows"), AXCommand.plan(for: "screen"))
    }

    /// Every planned verb has work to do, and every verb with work has a plan: a verb added to
    /// one table and not the other is a usage failure at runtime, so it fails here instead.
    func testEveryVerbHasBothAPlanAndABody() {
        for verb in verbs {
            XCTAssertNotNil(AXCommand.plan(for: verb), "\(verb): planned")
            XCTAssertNotNil(AXCommand.body(for: verb), "\(verb): has a body")
        }
        XCTAssertNil(AXCommand.body(for: "nonsense"))
        XCTAssertEqual(verbs.count, Set(verbs).count)
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

    private func plan(_ verb: String) -> AXCommand.AXPlan {
        guard let plan = AXCommand.plan(for: verb) else {
            XCTFail("no plan for \(verb)")
            return .direct
        }
        return plan
    }

    func testASuccessfulVerbPaysNothingForThePreflight() throws {
        for verb in verbs {
            let counter = Counter(diagnosis(trusted: false, answers: false))
            var bodies = 0
            let code = try AXCommand.dispatch(plan(verb), options(verb), diagnose: counter.diagnose) {
                _, _ in
                bodies += 1
                return 0
            }
            XCTAssertEqual(code, 0, verb)
            XCTAssertEqual(bodies, 1, "\(verb): the body runs once")
            // This is the issue: before #103 every one of these made three accessibility calls
            // before the first node was read. Now a success makes none.
            XCTAssertEqual(counter.calls, 0, "\(verb): a successful run must not diagnose the Mac")
        }
    }

    func testAFailureThatCouldBeTheGrantIsDiagnosedExactlyOnce() {
        let untrusted = Counter(diagnosis(trusted: false, answers: false, error: .apiDisabled))
        let failure = AXFailure.notFound("no window in the accessibility tree")
        XCTAssertThrowsError(try AXCommand.dispatch(plan("tree"), options("tree"),
                                                   diagnose: untrusted.diagnose) { _, _ in
            throw failure
        }) { thrown in
            // 5 was really a 3: the answer the preflight used to give before the verb ran.
            XCTAssertEqual((thrown as? AXFailure)?.code, .permission)
        }
        XCTAssertEqual(untrusted.calls, 1, "one diagnosis per invocation, not one per read")
    }

    func testAGreenDiagnosisKeepsTheVerbSOwnFailure() {
        let green = Counter(diagnosis(trusted: true, answers: true, error: .success))
        XCTAssertThrowsError(try AXCommand.dispatch(plan("find"), options("find"),
                                                   diagnose: green.diagnose) { _, _ in
            throw AXFailure.notFound("nothing matched \"zzz\"")
        }) { thrown in
            // The Mac is fine, so "nothing matched" is the truth and keeps exit 5.
            XCTAssertEqual((thrown as? AXFailure)?.code, .notFound)
        }
        XCTAssertEqual(green.calls, 1)
    }

    /// The regression this round exists for. `windows`/`screen` ask the question themselves when
    /// they read nothing, and then throw the answer: asking again in `dispatch`'s catch made an
    /// ungranted `ax windows` pay the ~50 ms diagnosis twice (451 ms where `origin/main` was
    /// 286 ms). One throw, one measurement — and the code the caller sees is unchanged.
    func testAVerbThatAsksAndThenThrowsIsMeasuredOnce() {
        let untrusted = Counter(diagnosis(trusted: false, answers: false, error: .apiDisabled))
        var bodies = 0
        XCTAssertThrowsError(try AXCommand.dispatch(plan("windows"), options("windows"),
                                                   diagnose: untrusted.diagnose) { _, ready in
            bodies += 1
            // What `windows` does with an empty list: ask, and let the answer out.
            try ready()
            return 0
        }) { thrown in
            XCTAssertEqual((thrown as? AXFailure)?.code, .permission)
        }
        XCTAssertEqual(bodies, 1, "a red answer ends it: no second body run")
        XCTAssertEqual(untrusted.calls, 1, "asked by the verb, not asked again by the decision")
    }

    /// The other half of the same coin: a *green* answer the verb already paid for is not paid for
    /// again by the catch, and the verb's own failure keeps its code.
    func testAGreenAnswerTheVerbAlreadyHasIsNotAskedTwice() {
        let green = Counter(diagnosis(trusted: true, answers: true, error: .success))
        var probes = 0
        XCTAssertThrowsError(try AXCommand.dispatch(plan("screen"), options("screen"),
                                                   diagnose: green.diagnose) { _, ready in
            probes += 1
            try ready()
            throw AXFailure.notFound("no apps")
        }) { thrown in
            XCTAssertEqual((thrown as? AXFailure)?.code, .notFound)
        }
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(green.calls, 1, "one measure per process, however many ask")
    }

    /// `usage` is decided before any accessibility call, so it is the one code that never pays.
    func testUsageNeverPaysForADiagnosis() {
        let counter = Counter(diagnosis(trusted: false, answers: false))
        var bodies = 0
        XCTAssertThrowsError(try AXCommand.dispatch(plan("press"), options("press"),
                                                   diagnose: counter.diagnose) { _, _ in
            bodies += 1
            throw AXFailure.usage("unknown option \"--nonsense\"")
        }) { thrown in
            XCTAssertEqual((thrown as? AXFailure)?.code, .usage)
        }
        XCTAssertEqual(counter.calls, 0)
        XCTAssertEqual(bodies, 1)
    }

    /// A dead element answers *nothing*, so "this node refuses" and "this Mac refuses" look the
    /// same: a revoked grant plus a ref from a persisted snapshot reached `press` as an element
    /// with no actions and exited 6 where the preflight said 3. It is diagnosed now — and on a Mac
    /// that answers, the refusal still exits 6.
    func testANodeThatRefusesIsDiagnosedAndKeepsItsCode() {
        let untrusted = Counter(diagnosis(trusted: false, answers: false, error: .apiDisabled))
        var bodies = 0
        XCTAssertThrowsError(try AXCommand.dispatch(plan("press"), options("press"),
                                                   diagnose: untrusted.diagnose) { _, _ in
            bodies += 1
            throw AXFailure.notActionable("@e7 does not answer press (AXPress)")
        }) { thrown in
            // The grant is the reason, and it is the reason the gate can see: 3, not 6.
            XCTAssertEqual((thrown as? AXFailure)?.code, .permission)
        }
        XCTAssertEqual(untrusted.calls, 1)
        XCTAssertEqual(bodies, 1, "a write is never run twice, diagnosed or not")

        let green = Counter(diagnosis(trusted: true, answers: true, error: .success))
        var writes = 0
        XCTAssertThrowsError(try AXCommand.dispatch(plan("set"), options("set"),
                                                   diagnose: green.diagnose) { _, _ in
            writes += 1
            throw AXFailure.notActionable("@e7 has no settable value")
        }) { thrown in
            XCTAssertEqual((thrown as? AXFailure)?.code, .notActionable)
        }
        XCTAssertEqual(green.calls, 1)
        XCTAssertEqual(writes, 1, "set must not be retried")
    }

    /// The retry the preflight used to make *up front* (a Background/ssh process answers
    /// `cannotComplete` on its first accessibility call) is made *after* a green diagnosis, which
    /// is what touched the window server. One extra body run, not a second diagnosis.
    func testAStartupNoiseEnvironmentFailureIsRetriedOnceForARead() throws {
        let green = Counter(diagnosis(trusted: true, answers: true, error: .success))
        var bodies = 0
        let code = try AXCommand.dispatch(plan("tree"), options("tree"),
                                          diagnose: green.diagnose) { _, _ in
            bodies += 1
            if bodies == 1 { throw AXFailure.environment("first call", ax: "cannotComplete") }
            return 0
        }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(bodies, 2, "one retry")
        XCTAssertEqual(green.calls, 1, "one diagnosis")
    }

    /// `windows` reads what `screen` reads, so it is retried the same way. (It was the one row of
    /// the old inline table that disagreed with its twin.)
    func testBothWindowListReadsRetry() throws {
        for verb in ["windows", "screen"] {
            let green = Counter(diagnosis(trusted: true, answers: true, error: .success))
            var bodies = 0
            let code = try AXCommand.dispatch(plan(verb), options(verb),
                                              diagnose: green.diagnose) { _, _ in
                bodies += 1
                if bodies == 1 { throw AXFailure.environment("first call", ax: "cannotComplete") }
                return 0
            }
            XCTAssertEqual(code, 0, verb)
            XCTAssertEqual(bodies, 2, "\(verb): one retry")
            XCTAssertEqual(green.calls, 1, "\(verb): one diagnosis")
        }
    }

    func testAWriteIsNeverRunTwice() {
        let green = Counter(diagnosis(trusted: true, answers: true, error: .success))
        var bodies = 0
        XCTAssertThrowsError(try AXCommand.dispatch(plan("press"), options("press"),
                                                    diagnose: green.diagnose) { _, _ in
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
        XCTAssertThrowsError(try AXCommand.dispatch(plan("tree"), options("tree"),
                                                    diagnose: untrusted.diagnose) { _, _ in
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

    /// `doctor` is the one verb that is not staged: it reports the diagnosis, so it is not run
    /// under the decision that produces one.
    func testDoctorIsNotStaged() throws {
        let counter = Counter(diagnosis(trusted: false, answers: false, error: .apiDisabled))
        var bodies = 0
        XCTAssertThrowsError(try AXCommand.dispatch(plan("doctor"), options("doctor"),
                                                    diagnose: counter.diagnose) { _, _ in
            bodies += 1
            throw AXFailure.permission("accessibility was disabled", ax: "apiDisabled")
        }) { thrown in
            // Unwrapped by `main()`'s catch, unchanged: `doctor`'s own code is its report's exit.
            XCTAssertEqual((thrown as? AXFailure)?.code, .permission)
        }
        XCTAssertEqual(bodies, 1)
        XCTAssertEqual(counter.calls, 0, "doctor printed the diagnosis; it is not diagnosed again")
    }
}
