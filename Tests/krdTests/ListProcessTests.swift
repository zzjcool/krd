import XCTest
import Foundation

/// The other half of #124 — the one an in-process test cannot see: **what `--list` actually writes
/// to a pipe.**
///
/// WHY this spawns the binary: the defect was a raw APC escape (`ESC _ G a=d,d=i,i=31 ESC \`) that
/// the placeholder probe's cleanup wrote to `STDOUT_FILENO` before the listing, and no test of the
/// renderers can catch it — deleting the guard in `Desk.listsOnly` keeps every `ListOutputTests`
/// green. The invariant is about bytes on a stream, so it has to be read off a stream. Same harness
/// as `ArgumentTests.testAUsageErrorLeavesTheProcessWithStatusTwoAndAQuietStdout`.
///
/// The listing itself needs no grant (`SCShareableContent` answers with empty titles without one),
/// but it *can* throw on a Mac with no window server or no Screen Recording at all — so the tests
/// assert the byte discipline on **both** outcomes and never assume the machine is green:
///
/// * escape-free is unconditional (the text listing is plain ASCII, and the `--json` objects escape
///   control characters),
/// * on a green machine the listing is non-empty and the JSON `ok` is true,
/// * on a red one the documented failure is what comes out (`permission` 3 / `environment` 4), and
///   it is still one object.
final class ListProcessTests: XCTestCase {
    private func binary() -> URL {
        Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("krd")
    }

    private struct Run {
        var stdout: String
        var stderr: String
        var status: Int32
    }

    /// One spawn with a bound: a listing must never hang a suite (the probe this change removes used
    /// to stall `--list` for up to 600 ms on a tty; a capture path would stall it forever).
    private func run(_ arguments: [String], timeout: TimeInterval = 30) throws -> Run {
        let binary = self.binary()
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("no krd binary at \(binary.path) — run `swift build` before `swift test`")
            return Run(stdout: "", stderr: "", status: -1)
        }
        let child = Process()
        child.executableURL = binary
        child.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = out
        child.standardError = err
        try child.run()
        let deadline = Date().addingTimeInterval(timeout)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if child.isRunning {
            child.terminate()
            child.waitUntilExit()
            XCTFail("krd \(arguments) did not exit within \(Int(timeout)) s")
        }
        return Run(stdout: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                   stderr: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                   status: child.terminationStatus)
    }

    /// #124 itself: the first bytes are the listing, not an escape.
    func testThePlainListingWritesItsListingAndNoControlSequence() throws {
        let result = try run(["--list"])

        XCTAssertFalse(result.stdout.contains("\u{1b}"),
                       "stdout must carry the listing and nothing else, got "
                       + "\(result.stdout.prefix(80).unicodeScalars.map { String(format: "U+%04X", $0.value) })")

        if result.status == 0 {
            XCTAssertFalse(result.stdout.isEmpty, "a green listing answers something")
            for line in result.stdout.split(separator: "\n") {
                // The two row grammars, and nothing else: `[0] display 2  1440x2560 pt` /
                // `    window 83  @0,0 1440x2560  app=…  title=…`.
                XCTAssertTrue(line.hasPrefix("[") || line.hasPrefix("    window "),
                              "unexpected listing row: \(line)")
            }
            XCTAssertEqual(result.stderr, "", "the listing is not a place for prose")
        } else {
            // No grant / no window server: the text path says so on stderr and leaves stdout empty
            // (the object is the `--json` half's job), with the documented class.
            XCTAssertEqual(result.stdout, "", "a failed text listing writes nothing to stdout")
            XCTAssertFalse(result.stderr.isEmpty, "a failure owes the reader a sentence")
            XCTAssertTrue([3, 4].contains(Int(result.status)),
                          "a listing failure is permission (3) or environment (4), got \(result.status)")
        }
    }

    /// `--list --json`: exactly one object, `ok` either way, `error.exit` equal to the status.
    func testTheJSONListingIsOneObjectWhicheverWayTheMachineAnswers() throws {
        let result = try run(["--list", "--json"])

        XCTAssertFalse(result.stdout.contains("\u{1b}"), "--json must not paste a terminal sequence into a pipe")
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1, "one object on one line, got: \(result.stdout.prefix(200))")

        let data = Data(result.stdout.utf8)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        XCTAssertNotNil(object, "stdout must be one JSON object: \(result.stdout.prefix(200))")
        guard let object else { return }

        if result.status == 0 {
            XCTAssertEqual(object["ok"] as? Bool, true)
            XCTAssertNotNil(object["displays"] as? [Any], "displays is present even when empty")
            XCTAssertNotNil(object["windows"] as? [Any], "windows is present even when empty")
            XCTAssertEqual(result.stderr, "", "the object is the whole answer")
        } else {
            XCTAssertEqual(object["ok"] as? Bool, false)
            let error = object["error"] as? [String: Any] ?? [:]
            XCTAssertEqual(error["exit"] as? Int, Int(result.status), "error.exit is the exit code")
            XCTAssertEqual(error.keys.sorted(), ["code", "exit", "message", "next"])
            XCTAssertFalse(result.stderr.isEmpty, "the prose stays on stderr")
        }
    }

    /// The usage refusal is deterministic on every machine, so it is the one that can pin the
    /// envelope end to end: one object on stdout, the historical sentence on stderr, status 2.
    func testARefusedCommandLineWithJSONIsOneUsageObject() throws {
        let result = try run(["--list", "--json", "--nonsense"], timeout: 5)

        XCTAssertEqual(result.status, 2)
        let data = Data(result.stdout.utf8)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        XCTAssertEqual(object?["ok"] as? Bool, false)
        let error = object?["error"] as? [String: Any] ?? [:]
        XCTAssertEqual(error["code"] as? String, "usage")
        XCTAssertEqual(error["exit"] as? Int, 2)
        XCTAssertEqual(error["message"] as? String,
                       "unknown option \"--nonsense\" (try `krd --help`)")
        XCTAssertEqual(result.stderr, "krd: unknown option \"--nonsense\" (try `krd --help`)\n",
                       "the sentence a human reads is unchanged")
        XCTAssertEqual(result.stdout.split(separator: "\n").filter { !$0.isEmpty }.count, 1,
                       "one object, not one per key")
    }
}
