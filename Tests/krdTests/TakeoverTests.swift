import XCTest
import Darwin
@testable import krd

/// Taking the screen back from a `krd` that is still holding it.
///
/// WHY, in one paragraph: ScreenCaptureKit gives one executable image one client, so while an
/// earlier copy is alive the newcomer's wall paints its text, its cards and its captions and not one
/// picture — and the earlier copy is usually the reader's own, left behind by a terminal that closed
/// on it (`docs/TROUBLESHOOTING.md` §23c). What is pinned here is who to ask, when it is allowed to
/// ask, and that the asking escalates, because a copy wedged in a capture call ignores SIGTERM and
/// an ignored signal is not a released client. The tart-VM measurements behind those two facts are
/// quoted in `Takeover.swift`'s header; the *wiring* (the hook in `Desk.run`) cannot be pinned here
/// at all, because it only fires for a run that really captures, which needs a TCC grant no test can
/// give — it was measured on the VM instead: two panes, both plain `krd`, the first process gone and
/// `krd: took the screen from krd 31281 …` in the second one's log.
final class TakeoverTests: XCTestCase {

    // MARK: - Who

    func testTheOtherCopiesOfThisPathAreTheCopiesToAsk() {
        let me: Int32 = 400
        let candidates = [
            Takeover.Candidate(pid: me, path: "/Users/me/bin/krd"),
            Takeover.Candidate(pid: 403, path: "/Users/me/bin/krd"),
            Takeover.Candidate(pid: 402, path: "/tmp/krd-copy/krd"),
            Takeover.Candidate(pid: 401, path: "/Users/me/bin/krd"),
        ]

        XCTAssertEqual(Takeover.otherCopies(candidates, ownPath: "/Users/me/bin/krd", ownPID: me)
            .map(\.pid), [401, 403], "two other copies of this image, in pid order, never ourselves")
    }

    func testTheNameIsNotTheIdentity() {
        // Measured in `Desk.enterFocus`: the same binary at another path streams fine beside a
        // running wall, so a copy at another path is a second client and not a copy to ask.
        let candidates = [
            Takeover.Candidate(pid: 501, path: "/tmp/other/krd"),
            Takeover.Candidate(pid: 502, path: "/Users/me/bin/krd.old"),
        ]

        XCTAssertEqual(Takeover.otherCopies(candidates, ownPath: "/Users/me/bin/krd", ownPID: 400), [])
    }

    func testTheOnlyCopyIsUs() {
        let me: Int32 = 400
        let candidates = [Takeover.Candidate(pid: me, path: "/Users/me/bin/krd")]
        XCTAssertEqual(Takeover.otherCopies(candidates, ownPath: "/Users/me/bin/krd", ownPID: me), [])
    }

    /// `kill(0, SIGTERM)` is a broadcast to the process group: the guard that keeps pid 0 out of the
    /// list is the only thing between a stray kernel entry and every process this shell owns.
    func testPidZeroIsNeverACopy() {
        let candidates = [Takeover.Candidate(pid: 0, path: "/Users/me/bin/krd")]
        XCTAssertEqual(Takeover.otherCopies(candidates, ownPath: "/Users/me/bin/krd", ownPID: 400), [])
    }

    // MARK: - When

    func testASessionThatCapturesOnATerminalTakesTheScreen() {
        XCTAssertTrue(Takeover.wanted(options: Options(), capturesTheScreen: true, isTerminal: true))
    }

    func testAPipeIsNotAPictureStream() {
        // The guard the repo's recipes ride on: every one of them redirects stdout.
        XCTAssertFalse(Takeover.wanted(options: Options(), capturesTheScreen: true, isTerminal: false))
    }

    func testARunThatNeverCapturesNeverTakesTheScreen() {
        // `--selftest` is the one that matters: `KRD_DUMP=… krd --selftest >/dev/null` is the
        // documented recipe (CONTRIBUTING.md, TESTING.md §), and it must not kill the reader's wall.
        XCTAssertFalse(Takeover.wanted(options: Options(), capturesTheScreen: false, isTerminal: true))
    }

    func testNoTakeoverRefusesTheTerminalToo() {
        var options = Options()
        options.noTakeover = true
        XCTAssertFalse(Takeover.wanted(options: options, capturesTheScreen: true, isTerminal: true))
    }

    /// The predicate the gate actually asks, over the flag combinations that decide it. A mirror of
    /// the `paintsThePane` test in `DiagnosticsTests`, and it exists because the two questions have
    /// different answers for the same argv — that difference is the whole of this file's gate.
    func testOnlyACapturingSessionAsksForTheScreen() throws {
        for argv in [["krd"], ["krd", "--wall"], ["krd", "--mirror"], ["krd", "--window", "1"],
                     ["krd", "--wall-at", "0:0"], ["krd", "--dev"]] {
            XCTAssertTrue(Desk.capturesTheScreen(try parseArguments(argv)),
                          argv.joined(separator: " ") + " asks ScreenCaptureKit for pixels")
        }
        for argv in [["krd", "--list"], ["krd", "--list", "--json"], ["krd", "--selftest"],
                     ["krd", "--bench"], ["krd", "--bench-wire", "/tmp/wire"],
                     ["krd", "--replay", "/tmp/krd-replay"], ["krd", "--mock"],
                     ["krd", "--wall", "--demo"]] {
            XCTAssertFalse(Desk.capturesTheScreen(try parseArguments(argv)),
                           argv.joined(separator: " ") + " never asks for a ScreenCaptureKit client")
        }
    }

    // MARK: - What happens to the copy

    /// A real child, because the question is what the kernel does with the signal — no seam here can
    /// answer it. The assertion is the child's *termination status*, not "it is gone": that is what
    /// proves the escalation and the polite half are told apart.
    func testAskingAHealthyCopyMakesItLeave() throws {
        let child = try spawn(["/bin/sleep", "30"])
        defer { reap(child.process) }

        let outcome = Takeover.take([copy(child)])

        XCTAssertEqual(outcome.asked, [child.pid])
        XCTAssertEqual(outcome.killed, [], "it left on SIGTERM, so nothing had to be killed")
        child.process.waitUntilExit()
        XCTAssertEqual(child.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.process.terminationStatus, SIGTERM, "SIGTERM is what took it down")
    }

    /// The case measured on the VM: `pkill` could not take a session wedged in a capture call down.
    /// The escalation has to, or the fancier wall still draws no pictures.
    func testACopyThatIgnoresSIGTERMIsKilled() throws {
        // `trap '' TERM` is the reproducible form of "wedged inside ScreenCaptureKit". Readiness is
        // the child's own line on a pipe, not a sleep: a loaded machine that has not reached `trap`
        // yet would otherwise turn this into a test of the default disposition.
        let child = try spawn(["/bin/sh", "-c", "trap '' TERM; echo ready; sleep 30"], readyLine: true)
        defer { reap(child.process) }
        XCTAssertEqual(try readLine(child.ready), "ready", "the trap is installed before the signal")

        let pid = child.pid
        let outcome = Takeover.take([copy(child)], generousMilliseconds: 300, stepMilliseconds: 50)

        XCTAssertEqual(outcome.asked, [pid])
        XCTAssertEqual(outcome.killed, [pid], "SIGTERM was ignored, so it had to be killed")
        // The line reports what the wait cost, so the number has to come from a real measurement:
        // the budget was spent before the escalation.
        XCTAssertGreaterThanOrEqual(outcome.milliseconds, 300)
        child.process.waitUntilExit()
        XCTAssertEqual(child.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.process.terminationStatus, SIGKILL, "only SIGKILL could end it")
    }

    /// The list was taken a moment ago: between then and the signal, a copy can exit and its pid be
    /// handed to something else. The path is the check that the pid is still the thing we meant.
    func testACopyWhosePathNoLongerMatchesIsNotSignalled() throws {
        let child = try spawn(["/bin/sleep", "30"])
        defer { reap(child.process) }

        let outcome = Takeover.take([Takeover.Candidate(pid: child.pid, path: "/not/this/binary")])

        XCTAssertTrue(outcome.isEmpty)
        XCTAssertTrue(child.process.isRunning, "a process that is not the copy we listed is left alone")
    }

    func testNothingToDoSaysSoInOneQuietLine() {
        let outcome = Takeover.Outcome()
        XCTAssertTrue(outcome.isEmpty)
        XCTAssertEqual(outcome.sentence, "no earlier krd held the screen")
    }

    func testTheLineCarriesNumbersAndOnlyClaimsWhatHappened() {
        var polite = Takeover.Outcome(asked: [12, 13])
        polite.milliseconds = 42
        XCTAssertEqual(polite.sentence, "took the screen from krd 12 13 in 42 ms")

        var forced = Takeover.Outcome(asked: [12])
        forced.killed = [12]
        forced.milliseconds = 650
        XCTAssertEqual(forced.sentence,
                       "took the screen from krd 12 in 650 ms; 12 did not leave on SIGTERM and was killed")

        // A copy this process may not signal is never described as killed: the line is what a
        // pictureless session is read against.
        var refused = Takeover.Outcome(asked: [12])
        refused.milliseconds = 651
        XCTAssertFalse(refused.sentence.contains("killed"))
    }

    func testTheElectionSaysWhoWonWhenItIsNotUs() {
        var outraced = Takeover.Outcome(outracedBy: 999)
        outraced.milliseconds = 0
        XCTAssertEqual(outraced.sentence, "krd 999 is taking the screen; leaving it to that one")
        XCTAssertFalse(outraced.isEmpty, "a refusal is still worth one line in the log")
    }

    // MARK: - The real thing

    /// `ownPath` and `running` have to agree, or nothing is ever a copy of anything on a live machine.
    func testThisProcessIsInItsOwnListingUnderItsOwnPath() {
        let me = getpid()
        let path = Takeover.ownPath()
        XCTAssertFalse(path.isEmpty, "libproc answers for the process it is asked from")
        XCTAssertTrue(Takeover.running().contains(Takeover.Candidate(pid: me, path: path)))
    }

    /// A zombie has left; only its exit status is waiting. Counting it as alive would put the full
    /// polling budget and a false "was killed" on every start after a test run.
    func testAReapedChildIsNotAliveAndAZombieIsNotEither() throws {
        let child = try spawn(["/usr/bin/true"])
        child.process.waitUntilExit()
        XCTAssertFalse(Takeover.isAlive(child.pid))
    }

    // MARK: - Helpers

    private struct Child {
        let process: Process
        let ready: Pipe?
        var pid: Int32 { process.processIdentifier }
    }

    private func spawn(_ arguments: [String], readyLine: Bool = false) throws -> Child {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardInput = FileHandle.nullDevice
        let pipe = readyLine ? Pipe() : nil
        process.standardOutput = pipe ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return Child(process: process, ready: pipe)
    }

    /// The candidate a real process presents: the *kernel's* path, which is what `take` re-checks
    /// against before it signals (`/bin/sh` is `/bin/bash` once the kernel says what it is running).
    private func copy(_ child: Child) -> Takeover.Candidate {
        Takeover.Candidate(pid: child.pid, path: Takeover.path(of: child.pid) ?? "")
    }

    private func readLine(_ pipe: Pipe?) throws -> String {
        guard let pipe else { return "" }
        var bytes: [UInt8] = []
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            bytes += chunk
            if bytes.contains(UInt8(ascii: "\n")) { break }
        }
        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Never leave a child behind, and never signal a pid that may have been reused: the child is
    /// only killed while it is still running, and its exit is always collected.
    private func reap(_ process: Process) {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}
