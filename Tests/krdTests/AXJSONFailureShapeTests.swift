import XCTest
@testable import krd

/// Issue #123: "a machine-readable surface must be able to say *I failed*".
///
/// Both halves are pinned here, and neither needs Accessibility permission: the failure half is
/// `AXCommand.failureOutput(_:json:)` (what the catch in `run` writes and exits with) and the
/// diagnosis half is `AXCommand.doctorOutput(_:)` (what `doctor` prints and exits with). The AX
/// calls that feed them are the only part left to a real machine.
///
/// WHY these are pure functions: the bug was an *exit code*, and an exit code cannot be unit
/// tested by driving the binary -- `exit()` takes the test process with it. Everything up to the
/// `exit` is a value, so the value is what gets asserted.
final class AXJSONFailureShapeTests: XCTestCase {

    /// The four classes the design already distinguished, plus usage. One token and one code each.
    private var failures: [(failure: AXFailure, code: String, exit: AXExit)] {
        [
            (.usage("unknown option \"--nonsense\" (try `krd ax --help`)"), "usage", .usage),
            (.permission(AXCommand.permissionText, ax: nil), "permission", .permission),
            (.environment(AXCommand.environmentText(error: .cannotComplete), ax: "cannotComplete"),
             "environment", .environment),
            (.notFound("Finder has no window in the accessibility tree."), "notFound", .notFound),
            (.notActionable("@e7 button \"Save\" does not answer press (AXPress)"), "notActionable",
             .notActionable),
        ]
    }

    func testAJSONFailureIsExactlyOneObjectOnStdoutAndTheProseOnStderr() {
        for (failure, code, exit) in failures {
            let output = AXCommand.failureOutput(failure, json: true)

            // One object, one line, nothing else: a caller can hand stdout straight to a parser.
            XCTAssertTrue(output.stdout.hasSuffix("\n"), "\(code): stdout should end in a newline")
            XCTAssertEqual(output.stdout.filter { $0 == "\n" }.count, 1,
                           "\(code): stdout must be one object on one line, got \(output.stdout)")
            let object = json(output.stdout, label: code)
            XCTAssertEqual(object["ok"] as? Bool, false, "\(code): ok must be false")
            XCTAssertEqual(object.keys.sorted(), ["error", "ok"], "\(code): no stray top-level keys")

            let error = object["error"] as? [String: Any]
            XCTAssertNotNil(error, "\(code): error must be an object, not a string")
            XCTAssertEqual(error?["code"] as? String, code)
            XCTAssertEqual(error?["exit"] as? Int, Int(exit.rawValue))
            XCTAssertEqual(output.code, exit.rawValue, "\(code): the code is the table's")
            XCTAssertFalse((error?["message"] as? String ?? "").isEmpty, "\(code): message is required")
            XCTAssertFalse((error?["next"] as? String ?? "").isEmpty, "\(code): next is required")

            // The human half is untouched: same prose as before, on stderr where it belongs.
            XCTAssertFalse(output.stderr.isEmpty, "\(code): the prose must still be there")
            XCTAssertNil(try? JSONSerialization.jsonObject(with: Data(output.stderr.utf8)) as? [String: Any],
                         "\(code): stderr is prose, not the machine's channel")
        }
    }

    func testWithoutJSONNothingReachesStdout() {
        // The pre-#123 contract for text mode, which stays exactly as it was.
        for (failure, code, exit) in failures {
            let output = AXCommand.failureOutput(failure, json: false)
            XCTAssertEqual(output.stdout, "", "\(code): text mode writes nothing to stdout")
            XCTAssertFalse(output.stderr.isEmpty)
            XCTAssertEqual(output.code, exit.rawValue)
        }
    }

    func testMessageIsOneSentenceWithoutTheStreamPrefix() {
        // stderr says "krd ax: …" because it is a stream a human reads next to other output;
        // `message` is a field, so the prefix is the stream's job, not the value's.
        let output = AXCommand.failureOutput(
            .notFound("Finder has no window in the accessibility tree."), json: true)
        let error = json(output.stdout)["error"] as? [String: Any]
        XCTAssertEqual(error?["message"] as? String, "Finder has no window in the accessibility tree.")
        XCTAssertTrue(output.stderr.hasPrefix("krd ax: Finder has no window"))

        // A paragraph of advice is a paragraph on stderr; the machine gets its first line.
        let environment = AXCommand.failureOutput(
            .environment(AXCommand.environmentText(error: .cannotComplete), ax: "cannotComplete"),
            json: true)
        let fields = json(environment.stdout)["error"] as? [String: Any]
        XCTAssertEqual(fields?["message"] as? String,
                       "the accessibility API is not answering (cannotComplete)")
        XCTAssertEqual(fields?["ax"] as? String, "cannotComplete")
        XCTAssertGreaterThan(environment.stderr.components(separatedBy: "\n").count, 3,
                             "the advice stays whole on stderr")
    }

    func testTheAXErrorNameRidesAlongOnlyWhenACallProducedIt() {
        let call = AXErrorReport(.environment("the app did not answer", ax: "cannotComplete"))
        XCTAssertEqual(call.dictionary["ax"] as? String, "cannotComplete")
        XCTAssertNil(AXErrorReport(.notFound("no window")).dictionary["ax"])
        XCTAssertNil(AXErrorReport(.usage("unknown option")).dictionary["ax"])
    }

    func testTheErrorObjectCarriesExactlyTheDocumentedKeys() {
        // The key set is the contract: `.error.code` to branch on, `.error.exit` to cross-check
        // the process code, `.error.message` to log, `.error.next` for the operator, and `.ax`
        // only when an accessibility call produced the failure.
        let cases: [(AXFailure, Set<String>)] = [
            (.usage("unknown option"), ["code", "exit", "message", "next"]),
            (.permission(AXCommand.permissionText, ax: nil), ["code", "exit", "message", "next"]),
            (.permission("accessibility was disabled", ax: "apiDisabled"),
             ["ax", "code", "exit", "message", "next"]),
            (.environment("it did not answer", ax: "cannotComplete"),
             ["ax", "code", "exit", "message", "next"]),
            (.notFound("no window"), ["code", "exit", "message", "next"]),
            (.notActionable("refused"), ["code", "exit", "message", "next"]),
        ]
        for (failure, keys) in cases {
            XCTAssertEqual(Set(AXErrorReport(failure).dictionary.keys), keys, "\(failure)")
        }
    }

    func testTheMessageOfEveryClassIsItsOwnSentence() {
        // `message` is derived from the prose (first line, prefix stripped), so a heading added to
        // one of those paragraphs would silently change the machine's sentence. Pin one per class.
        XCTAssertEqual(AXErrorReport(.usage("find needs a query or --role <role>")).message,
                       "find needs a query or --role <role>")
        XCTAssertTrue(AXErrorReport(.permission(AXCommand.permissionText, ax: nil))
            .message.hasPrefix("no Accessibility permission for "),
                      "the grant sentence, without the `krd ax: ` prefix and without the walkthrough")
        XCTAssertEqual(AXErrorReport(.environment(AXCommand.environmentText(error: .cannotComplete),
                                                  ax: "cannotComplete")).message,
                       "the accessibility API is not answering (cannotComplete)")
        XCTAssertEqual(AXErrorReport(.notFound("Finder has no window in the accessibility tree.")).message,
                       "Finder has no window in the accessibility tree.")
        XCTAssertEqual(AXErrorReport(.notActionable("@e7 button \"Save\" does not answer press (AXPress)"))
            .message, "@e7 button \"Save\" does not answer press (AXPress)")
    }

    func testTheAdviceNeverPointsBackAtDoctor() {
        // `doctor` is one of the verbs that ends up in this object, so telling the reader to run
        // it would be a loop. (The prose on stderr still does; that is #125's to reconcile.)
        for (failure, _, _) in failures {
            XCTAssertFalse(AXErrorReport(failure).next.contains("krd ax doctor"), "\(failure)")
        }
    }

    func testJSONIsReadFromTheRawArgvSoAUsageFailureStillAnswersInJSON() {
        // `krd ax --json --nonsense` fails while parsing, i.e. before `options.json` exists.
        XCTAssertTrue(AXCommand.wantsJSON(["--json", "--nonsense"]))
        XCTAssertTrue(AXCommand.wantsJSON(["--nonsense", "--json"]))
        XCTAssertTrue(AXCommand.wantsJSON(["doctor", "--json"]))
        XCTAssertFalse(AXCommand.wantsJSON(["doctor"]))
        XCTAssertFalse(AXCommand.wantsJSON([]))
    }

    private func json(_ text: String, label: String = "",
                      file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            XCTFail("\(label): stdout is not one JSON object: \(text)", file: file, line: line)
            return [:]
        }
        return parsed
    }
}

/// The other half of #123: `ax doctor --json` reported a broken Mac and exited **0**, so a health
/// check built on the machine-readable format was permanently green.
final class AXDoctorExitCodeTests: XCTestCase {

    private func diagnosis(trusted: Bool, answers: Bool, final: AXError = .cannotComplete,
                           first: AXError? = nil, retried: Bool = true) -> AXDiagnosis {
        AXDiagnosis(trusted: trusted, onScreenWindows: 24, answers: answers,
                    first: first ?? final, final: final, retried: retried,
                    sample: answers ? "Finder, 1 window(s)" : "-")
    }

    func testARedDiagnosisExitsNonZeroInBothFormats() {
        // The exact machine from the issue: trusted, window server up (24 windows), every
        // accessibility read returning cannotComplete. Text mode said 4; JSON mode said 0.
        let red = diagnosis(trusted: true, answers: false, final: .cannotComplete)
        let report = AXCommand.doctorOutput(red)

        XCTAssertEqual(report.exit, .environment, "a diagnosis that cannot read must not be `ok`")
        XCTAssertEqual(report.exit.rawValue, 4)
        XCTAssertEqual(report.json["ok"] as? Bool, false)

        let error = report.json["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "environment")
        XCTAssertEqual(error?["exit"] as? Int, 4)
        XCTAssertEqual(error?["ax"] as? String, "cannotComplete")
        XCTAssertTrue(report.text.contains("accessibility answers     no (cannotComplete)"))
    }

    func testAMissingGrantIsThePermissionCode() {
        let red = diagnosis(trusted: false, answers: false, final: .cannotComplete)
        let report = AXCommand.doctorOutput(red)
        XCTAssertEqual(report.exit, .permission)
        XCTAssertEqual(report.exit.rawValue, 3)
        XCTAssertEqual((report.json["error"] as? [String: Any])?["code"] as? String, "permission")
    }

    func testAGreenDiagnosisKeepsTheJSONItAlwaysHad() {
        let green = diagnosis(trusted: true, answers: true, final: .success, retried: false)
        let report = AXCommand.doctorOutput(green)

        XCTAssertEqual(report.exit, .ok)
        XCTAssertEqual(report.exit.rawValue, 0)
        XCTAssertEqual(report.json["ok"] as? Bool, true)
        // Every key a consumer could already be reading is still there, with its old meaning.
        XCTAssertEqual(report.json["trusted"] as? Bool, true)
        XCTAssertEqual(report.json["answers"] as? Bool, true)
        XCTAssertEqual(report.json["onScreenWindows"] as? Int, 24)
        XCTAssertEqual(report.json["firstCall"] as? String, "success")
        XCTAssertEqual(report.json["error"] as? String, "success",
                       "on a green Mac `error` is still the AXError name, not an object")
        XCTAssertEqual(report.json["sample"] as? String, "Finder, 1 window(s)")
    }

    func testARedDiagnosisKeepsTheReportItMeasured() {
        let red = diagnosis(trusted: true, answers: false, final: .cannotComplete)
        let report = AXCommand.doctorOutput(red)
        let json = report.json
        XCTAssertEqual(json["onScreenWindows"] as? Int, 24)
        XCTAssertEqual(json["firstCall"] as? String, "cannotComplete")
        XCTAssertEqual(json["sample"] as? String, "-")
        XCTAssertEqual(json["trusted"] as? Bool, true)
        XCTAssertEqual(json["answers"] as? Bool, false)
        // ...and the AXError name the old `error` field held is still reachable, at error.ax.
        XCTAssertEqual((json["error"] as? [String: Any])?["ax"] as? String, "cannotComplete")
        // stdout is one object; the paragraph a human needs is on stderr, where the other verbs
        // put theirs.
        XCTAssertTrue(report.stderr.hasPrefix("krd ax: the accessibility API is not answering"))
    }

    func testTheReportSeparatesTheFirstCallFromTheOneThatDecidedIt() {
        // `firstCall` is measured first, `error.ax` is what the retry ended on: swapping them
        // would send a reader after the wrong accessibility error.
        let red = diagnosis(trusted: true, answers: false, final: .apiDisabled,
                            first: .cannotComplete, retried: true)
        let report = AXCommand.doctorOutput(red)
        XCTAssertEqual(report.json["firstCall"] as? String, "cannotComplete")
        XCTAssertEqual((report.json["error"] as? [String: Any])?["ax"] as? String, "apiDisabled")
        XCTAssertTrue(report.text.contains("→ retry apiDisabled"))
    }

    func testTheUntrustedProseIsTheWalkthroughAHumanNeeds() {
        let red = diagnosis(trusted: false, answers: false)
        let report = AXCommand.doctorOutput(red)
        // Literal, not AXCommand.permissionText: this asserts what a reader is told, not that a
        // constant equals itself.
        XCTAssertTrue(report.text.contains("System Settings > Privacy & Security > Accessibility"))
        XCTAssertTrue(report.stderr.hasPrefix("krd ax: no Accessibility permission"),
                      "a red doctor in --json mode keeps its prose, on stderr")
    }

    func testAGreenDiagnosisSaysNothingOnStderr() {
        let green = diagnosis(trusted: true, answers: true, final: .success, retried: false)
        XCTAssertEqual(AXCommand.doctorOutput(green).stderr, "")
    }

    func testTheProseIsTheSameProseAsBefore() {
        // A red diagnosis prints the five measured lines and then the advice, exactly as text
        // mode did before #123: the human output is a fixed asset, not a casualty of this fix.
        let red = diagnosis(trusted: true, answers: false, final: .cannotComplete)
        let text = AXCommand.doctorOutput(red).text
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "accessibility permission  granted")
        XCTAssertEqual(lines[1], "accessibility answers     no (cannotComplete)")
        XCTAssertEqual(lines[2], "window server             24 windows on screen")
        XCTAssertEqual(lines[3], "first call in this process cannotComplete → retry cannotComplete")
        XCTAssertEqual(lines[4], "frontmost app             -")
        XCTAssertEqual(lines[5], "")
        XCTAssertTrue(text.hasSuffix(AXCommand.environmentText(error: .cannotComplete)))
    }
}

/// The success side of the same wire: `press`/`set` used to print human lines into stdout, which
/// is the stream a `--json` caller parses, and `set` printed them before it knew whether the write
/// had landed. Both now answer one object, built by these pure functions.
final class AXWriteResultShapeTests: XCTestCase {
    func testAPressSaysItLandedAndWhatChanged() {
        let landed = AXCommand.pressResult(ref: "@e7", label: "@e7 button \"Save\"", dryRun: false,
                                           elapsedMs: 12, before: "role=button value=\"\"",
                                           after: "role=button value=\"\"", note: "no observable change")
        XCTAssertEqual(landed["ok"] as? Bool, true)
        XCTAssertEqual(landed["command"] as? String, "press")
        XCTAssertEqual(landed["ref"] as? String, "@e7")
        XCTAssertEqual(landed["elapsedMs"] as? Int, 12)
        XCTAssertEqual(landed["before"] as? String, "role=button value=\"\"")
        XCTAssertEqual(landed["after"] as? String, "role=button value=\"\"")
        XCTAssertEqual(landed["note"] as? String, "no observable change")
        XCTAssertNil(landed["dryRun"])
    }

    func testADryRunSaysItSentNothing() {
        // `ok:true` on a dry run means "the command succeeded", so the object has to say that
        // nothing was written: no `after`, no `elapsedMs`, an explicit `dryRun`.
        for result in [AXCommand.pressResult(ref: "@e7", label: "l", dryRun: true, elapsedMs: 0,
                                             before: "b", after: nil, note: nil),
                       AXCommand.setResult(ref: "@e7", label: "l", value: "hi", dryRun: true,
                                           elapsedMs: 0, before: "b", after: nil)] {
            XCTAssertEqual(result["ok"] as? Bool, true)
            XCTAssertEqual(result["dryRun"] as? Bool, true)
            XCTAssertNil(result["after"])
            XCTAssertNil(result["elapsedMs"])
        }
    }

    func testAnElementThatWentAwayIsNullNotAFakeString() {
        let landed = AXCommand.pressResult(ref: "@e7", label: "l", dryRun: false, elapsedMs: 3,
                                           before: "b", after: nil, note: "element is gone")
        XCTAssertTrue(landed["after"] is NSNull, "absent state is null, not the word \"nil\"")
        let written = AXCommand.setResult(ref: "@e7", label: "l", value: "hi", dryRun: false,
                                          elapsedMs: 3, before: "b", after: nil)
        XCTAssertTrue(written["after"] is NSNull)
        XCTAssertEqual(written["value"] as? String, "hi")
    }

    func testEverythingASuccessPayloadGainsIsOneKey() {
        // The read verbs keep their fields exactly and gain `ok`. This is the whole diff a
        // consumer of `windows`/`screen`/`tree`/`find` sees.
        let payload = AXCommand.success(["windows": [[String: Any]](), "focus": [String: Any]()])
        XCTAssertEqual(Set(payload.keys), ["focus", "ok", "windows"])
        XCTAssertEqual(payload["ok"] as? Bool, true)
    }
}

/// #123's bug lived in `run`'s exit path -- `doctor` returning `AXExit.ok` for `--json`, and a
/// catch that wrote nothing to stdout. `run` ends in `exit()`, so it cannot be reached in-process;
/// a subprocess can. The arguments used here need no Accessibility grant, so this runs on a Mac
/// with and without the TCC permission (the assertions adapt to which branch the machine is on,
/// and the equality assertion is the one that matters).
final class AXCommandProcessTests: XCTestCase {

    func testAFailedJSONCommandIsOneObjectOnStdoutWithItsCode() throws {
        let run = try krd(["ax", "--json", "--nonsense"])
        XCTAssertEqual(run.code, 2, "usage is 2, in JSON mode too")
        XCTAssertEqual(run.stdout.filter { $0 == "\n" }.count, 1,
                       "stdout is one line, nothing else: \(run.stdout)")
        let object = try json(run.stdout)
        XCTAssertEqual(object["ok"] as? Bool, false)
        let error = object["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "usage")
        XCTAssertEqual(error?["exit"] as? Int, 2)
        XCTAssertTrue(run.stderr.contains("unknown option"), "the prose is still on stderr")
    }

    func testWithoutJSONTheSameFailureWritesNothingToStdout() throws {
        let run = try krd(["ax", "--nonsense"])
        XCTAssertEqual(run.code, 2)
        XCTAssertEqual(run.stdout, "", "text mode's stdout is prose the command chose to print")
        XCTAssertTrue(run.stderr.contains("unknown option"))
    }

    func testDoctorExitsTheSameCodeInBothFormats() throws {
        // The exact bug: `krd ax doctor` said 3 (or 4) and `krd ax doctor --json` said 0. Whatever
        // this machine's diagnosis is, the two formats must agree -- and a non-zero code must come
        // with `"ok": false` and an error object, not with a report that only *mentions* it.
        let text = try krd(["ax", "doctor"])
        let json = try krd(["ax", "doctor", "--json"])
        XCTAssertEqual(json.code, text.code,
                       "`--json` is a format switch: it must not change the exit code")

        let object = try self.json(json.stdout)
        XCTAssertEqual(object["ok"] as? Bool, json.code == 0)
        if json.code != 0 {
            let error = object["error"] as? [String: Any]
            XCTAssertNotNil(error, "a red diagnosis answers with the failure object, not just a report")
            XCTAssertEqual(error?["exit"] as? Int, Int(json.code))
        } else {
            // A green Mac is `success`, `noValue` or `attributeUnsupported` depending on whether
            // anything is frontmost (see `doctor`'s `answers`): all three are green, so what this
            // asserts is the *type* -- a green doctor's `error` is still the AXError name it always
            // was, not the failure object.
            XCTAssertNotNil(object["error"] as? String,
                            "a green diagnosis keeps the string it always had: \(json.stdout)")
        }
    }

    func testAReadVerbMatchesItsOwnReportInEitherFormat() throws {
        // Environment-adaptive on purpose: with a grant `windows` answers the payload (+ok), with
        // no grant it answers the failure object. Both are the documented contract, and neither
        // may print anything else.
        for verb in [["ax", "windows", "--json"], ["ax", "find", "zzzznomatch", "--json"]] {
            let run = try krd(verb)
            let object = try json(run.stdout)
            XCTAssertEqual(object["ok"] as? Bool, run.code == 0, "\(verb): ok must agree with rc")
            if run.code != 0 {
                XCTAssertEqual((object["error"] as? [String: Any])?["exit"] as? Int, Int(run.code),
                               "\(verb): .error.exit must be the code the process exited with")
            }
        }
    }

    // MARK: - plumbing

    /// The test bundle sits next to the executable it tests (same trick as WallProcessTests). A
    /// missing binary fails loudly: a silently skipped test here would hide the exit path.
    private var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("krd")
    }

    private func krd(_ arguments: [String]) throws -> (code: Int32, stdout: String, stderr: String) {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("no krd binary at \(binary.path) — run `swift build` before `swift test`")
            return (-1, "", "")
        }
        let child = Process()
        child.executableURL = binary
        child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        child.standardOutput = out
        child.standardError = err
        // A watchdog rather than a bare `waitUntilExit`: `doctor` bounds its own AX call (1.5 s),
        // but a hung CLI must fail the test instead of hanging the suite.
        let watchdog = DispatchWorkItem { if child.isRunning { child.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        defer { watchdog.cancel() }
        try child.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        return (child.terminationStatus,
                String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self))
    }

    private func json(_ text: String,
                      file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let data = Data(text.utf8)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            XCTFail("stdout is not one JSON object: \(text)", file: file, line: line)
            return [:]
        }
        return object
    }
}
