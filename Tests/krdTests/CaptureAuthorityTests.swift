import XCTest
import Foundation
import ScreenCaptureKit
@testable import krd

/// Who macOS asks for the Screen Recording grant, and what krd says about it (issue #219).
///
/// The reporter's premise was "the grant never attaches to krd, so SSH always fails". The first half
/// is right and the second is not: TCC asks the **responsible process** — the terminal app for a
/// shell in a window, `sshd`'s session wrapper for an SSH login — so SSH works exactly when that
/// wrapper has been granted. See `CaptureAuthority`'s doc comment for the two measurements.
///
/// What the sentences must do is name the process a reader has to grant. `-3801` alone
/// ("The user declined TCCs for application, window, display capture") names nobody, and the advice
/// krd used to print — "grant Screen Recording to this binary" — named the one process TCC never
/// asks.
final class CaptureAuthorityTests: XCTestCase {
    private func streamError(_ code: Int) -> NSError {
        NSError(domain: SCStreamErrorDomain, code: code, userInfo: [
            NSLocalizedDescriptionKey: "The user declined TCCs for application, window, display capture",
        ])
    }

    // MARK: - which session

    /// An SSH login session's environment, as `sshd` writes it.
    private let overSSH = ["SSH_CONNECTION": "10.0.0.2 50231 10.0.0.1 22", "SSH_TTY": "/dev/ttys003"]
    /// A GUI terminal app's environment, as Terminal/iTerm/WezTerm/Rex write it.
    private let inWezTerm = ["TERM_PROGRAM": "WezTerm", "TERM": "xterm-256color"]

    func testAnSSHSessionIsItsLoginProcess() {
        XCTAssertEqual(CaptureAuthority.current(overSSH), .sshLoginSession)
        XCTAssertEqual(CaptureAuthority.current(["SSH_CONNECTION": "1 2 3 4"]), .sshLoginSession,
                       "SSH_CONNECTION alone is enough; SSH_TTY is not always there")
        XCTAssertEqual(CaptureAuthority.current(["SSH_TTY": "/dev/ttys003"]), .sshLoginSession)
        XCTAssertEqual(CaptureAuthority.current(overSSH).grantTarget,
                       "/usr/libexec/sshd-keygen-wrapper",
                       "the path System Settings lists, not a bundle identifier")
    }

    func testATerminalSessionsGrantBelongsToTheTerminalApp() {
        XCTAssertEqual(CaptureAuthority.current(inWezTerm), .terminalApp("WezTerm"))
        XCTAssertEqual(CaptureAuthority.current(inWezTerm).grantTarget, "WezTerm")
    }

    /// `ssh` forwards the *client's* `TERM_PROGRAM` when the client asks it to, and some
    /// configurations always do. That name belongs to a terminal on the reader's desk, which is not
    /// the process that answers for the session — so SSH has to win.
    func testAForwardedTermProgramDoesNotOutvoteTheSSHSession() {
        var environment = inWezTerm
        environment.merge(overSSH) { _, ssh in ssh }
        XCTAssertEqual(CaptureAuthority.current(environment), .sshLoginSession)
    }

    func testNeitherFactIsUnknown() {
        XCTAssertEqual(CaptureAuthority.current([:]), .unknown)
        XCTAssertEqual(CaptureAuthority.current(["TERM_PROGRAM": ""]), .unknown,
                       "an empty TERM_PROGRAM names nothing")
        XCTAssertNil(CaptureAuthority.current([:]).grantTarget)
    }

    // MARK: - the sentences

    /// THE RED ONE. On `70d098e` every refusal said "Screen Recording is off for this terminal" —
    /// which, over SSH, points the reader at a terminal app that is not in the chain and cannot be
    /// granted for it. The sentence has to name the login wrapper instead.
    func testARefusedGrantOverSSHNamesTheLoginProcess() throws {
        for code in [-3801, -3803] {
            let sentence = Desk.setupFailure(streamError(code), authority: .sshLoginSession)
            XCTAssertTrue(sentence.contains("/usr/libexec/sshd-keygen-wrapper"), sentence)
            XCTAssertFalse(sentence.contains("this terminal"),
                           "\(code): there is no terminal app in an SSH session's chain: \(sentence)")
        }
    }

    /// The GUI case is unchanged on purpose: the reader is looking at that terminal, and a footer has
    /// one row. `WallNotice` is where its name is spelled out.
    func testARefusedGrantInATerminalKeepsTheSentenceItAlwaysHad() {
        XCTAssertEqual(Desk.setupFailure(streamError(-3801), authority: .terminalApp("WezTerm")),
                       "Screen Recording is off for this terminal")
        XCTAssertEqual(Desk.setupFailure(streamError(-3801), authority: .unknown),
                       "Screen Recording is off for this terminal")
    }

    /// `-3805` is not a TCC answer ("failed during stream": a window that cannot be streamed, or a
    /// second process of the same binary), so the denial sentence must not swallow it.
    func testATransientStreamFaultIsNotTurnedIntoAGrantProblem() {
        XCTAssertEqual(Desk.setupFailure(streamError(-3805), authority: .sshLoginSession),
                       "The user declined TCCs for application, window, display capture",
                       "-3805 keeps the framework's own words, as it always has")
    }

    /// The `--list` advice: every context names a process the reader can grant, and where.
    func testTheListAdviceNamesAProcessAndThePlaceInEveryContext() {
        for (authority, name) in [(CaptureAuthority.terminalApp("WezTerm"), "WezTerm"),
                                  (.sshLoginSession, "/usr/libexec/sshd-keygen-wrapper")] {
            let advice = authority.grantAdvice
            XCTAssertTrue(advice.contains("grant Screen Recording to \(name)"), advice)
            XCTAssertTrue(advice.contains("System Settings > Privacy & Security > Screen Recording"),
                          advice)
        }
        // Nothing to name: the sentence still has to avoid the old lie ("this binary").
        let unknown = CaptureAuthority.unknown.grantAdvice
        XCTAssertFalse(unknown.contains("this binary"), unknown)
        XCTAssertTrue(unknown.contains("the app krd was started from"), unknown)
    }
}
