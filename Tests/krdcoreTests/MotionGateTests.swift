import XCTest
import Darwin
import Foundation
@testable import krdcore

/// Issue #203, from inside the process: `?1003` (any-motion mouse tracking) is enabled **only** while
/// the mirror's pane has focus, given back while nobody is looking, taken again when the reader comes
/// back -- and reset by the *unfiltered* ownership list, or a session that ends unfocused hands a
/// motion-reporting pane to the shell, which is #134's bug class with a new mode in it.
///
/// The companion is `Tests/krdTests/MotionGateProcessTests`, which owns the bytes a real pty
/// receives (one escape per transition, the wall's exemption). What that instrument cannot see
/// cheaply is the *derivation*: which list the enable set and the reset set each come from. That is
/// what this file pins, and it pins it literally -- a filtered reset list is otherwise a plausible
/// refactor that no end-to-end byte count notices until a pane is left unfocused at teardown.
///
/// `inputEnable` / `inputReset` / `setMotionReporting` are static and write straight to fd 1 by
/// design (they must not queue behind a frame), so the sink seam cannot see them: the bytes are
/// captured by temporarily pointing fd 1 at a temp file, the same instrument `SessionTeardownTests`
/// uses. The strings themselves are also asserted directly, so a "the test capture is broken"
/// failure and a "the list is wrong" failure do not look alike.
final class MotionGateTests: XCTestCase {

    /// Both flags are per-session state a desk sets for a whole run, and a leaked value would make
    /// these cases pass or fail depending on *test order* -- so every case starts and ends on the
    /// shipped defaults, exactly like `SessionTeardownTests` does for `focusReporting`.
    override func setUp() {
        super.setUp()
        ScreenWriter.focusReporting = false
        ScreenWriter.motionReporting = true
        ScreenWriter.sessionClosed = false
    }

    override func tearDown() {
        ScreenWriter.focusReporting = false
        ScreenWriter.motionReporting = true
        ScreenWriter.sessionClosed = false
        super.tearDown()
    }

    // MARK: - (a) nobody is looking: the enable set has no 1003 at all

    /// Mirror, unfocused: the live mode set is `1002 1006 1016`. Not "contains" -- the *exact*
    /// bytes, because a `?1003h` that is turned off one escape later would still be one upstream
    /// report per motion for as long as it was on, and the whole point of #203 is that the terminal
    /// never starts sending.
    func testAnUnfocusedSessionEnablesEverythingButMotionTracking() {
        ScreenWriter.motionReporting = false

        XCTAssertEqual(ScreenWriter.inputModes, [1002, 1006, 1016],
                       "with `?1003` gated off, the enable list is the other three mouse modes")
        XCTAssertEqual(ScreenWriter.inputEnable, "\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?1016h",
                       "the unfocused enable bytes are exactly those three escapes")
        XCTAssertFalse(ScreenWriter.inputEnable.contains("?1003"),
                       "not a single `?1003` byte in the enable set of an unfocused session; got "
                       + ScreenWriter.inputEnable.debugDescription)

        // The wire, not just the string: `writeInputModes(true)` is what `InputReader.start()` sends.
        let bytes = captureFd1 { ScreenWriter.writeInputModes(true) }
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self),
                       "\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?1016h",
                       "the unfocused session put a `?1003` byte on the tty")
    }

    /// The other half, and the shipped default: focused, the list is whole and 1003 is first, so the
    /// session starts exactly where it started before #203.
    func testAFocusedSessionEnablesTheWholeList() {
        XCTAssertTrue(ScreenWriter.motionReporting)
        XCTAssertEqual(ScreenWriter.inputModes, [1003, 1002, 1006, 1016])
        XCTAssertEqual(ScreenWriter.inputEnable,
                       "\u{1B}[?1003h\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?1016h")
        XCTAssertEqual(ScreenWriter.inputModes, ScreenWriter.mouseModes,
                       "a session that wants motion reports is the unmodified mouse list")
    }

    // MARK: - (b) the reset is the ownership list, never the filtered enable list

    /// The anti-#134 assertion, spelled out: with the pane unfocused (`motionReporting == false`) and
    /// a session that reads input (`focusReporting == true`), the reset is still **all five** modes,
    /// `?1003l` last. Deriving `inputReset` from the state-filtered `inputModes` would drop `?1003l`
    /// from the heal and the teardown of a session that ends while nobody is looking -- which is the
    /// normal way a session ends in a tiling WM -- and the shell behind krd would inherit a pane that
    /// reports every motion.
    func testTheResetCoversMotionTrackingEvenWhileUnfocused() {
        ScreenWriter.motionReporting = false
        ScreenWriter.focusReporting = true

        XCTAssertEqual(ScreenWriter.resetModes, [1003, 1002, 1006, 1016, 1004],
                       "the ownership list keeps 1003 and adds 1004; the focus state is not applied")
        XCTAssertEqual(ScreenWriter.inputReset,
                       "\u{1B}[?1004l\u{1B}[?1016l\u{1B}[?1006l\u{1B}[?1002l\u{1B}[?1003l",
                       "the reset is `resetModes` reversed -- unfiltered. A list filtered by the "
                       + "current focus state would be missing the last escape, and the pane would "
                       + "keep reporting motion for the next program (#134).")
        // … while what it *enabled* under the same flags is the filtered list, so the two are not
        // the same set on purpose (the whole reason `inputReset` may not read `motionReporting`).
        XCTAssertEqual(ScreenWriter.inputModes, [1002, 1006, 1016, 1004])

        // The session-level consequence: a teardown that runs while the pane is unfocused still
        // hands `?1003` back, exactly once.
        let writer = ScreenWriter()
        var bytes: [UInt8] = []
        writer.sink = { bytes.append(contentsOf: $0) }
        writer.beginSession()
        // A session starts focused and `beginSession` puts the want back to `true` (#203), so the
        // focus-out has to be replayed here: this case is about the teardown, and a want that is on
        // would make it pass even with a reset list filtered by the focus state -- the exact bug it
        // exists to catch.
        ScreenWriter.motionReporting = false
        let teardownStart = bytes.count
        writer.endSession()
        let teardown = String(decoding: bytes[teardownStart...], as: UTF8.self)
        XCTAssertEqual(teardown.components(separatedBy: "\u{1B}[?1003l").count - 1, 1, """
            endSession() did not reset `?1003` exactly once while `motionReporting` was false. \
            The mode was on a moment ago: the teardown owns it whatever the focus state says. \
            teardown = \(teardown.debugDescription)
            """)
    }

    // MARK: - (c) one escape per real change, none for a repeat

    /// `noteFocus` only calls this after its own real-transition early return, but the rule is pinned
    /// here as well: one `?1003h`/`?1003l` per change of want, zero bytes when the want is what the
    /// terminal already holds. Two escapes per transition would be a redundant write on every focus
    /// change; an escape on every *report* would be a write per keystroke, since the reader reports
    /// every human input event as focus-in too (I5, issue #110).
    func testAMotionToggleWritesOneEscapeAndARepeatWritesNone() {
        var wrote: Bool?

        // 1. The want did not change (focused, and the wire already holds `?1003`): nothing at all.
        wrote = nil
        var bytes = captureFd1 { wrote = ScreenWriter.setMotionReporting(true) }
        XCTAssertEqual(wrote, false, "a want that did not change must report no write")
        XCTAssertEqual(bytes.count, 0, """
            a repeated focus-in wrote \(bytes.count) B. The state did not change, so there is \
            nothing to say: got \(String(decoding: bytes, as: UTF8.self).debugDescription).
            """)

        // 2. Focus-out: exactly one `?1003l`.
        wrote = nil
        bytes = captureFd1 { wrote = ScreenWriter.setMotionReporting(false) }
        XCTAssertEqual(wrote, true, "a real transition must report its write")
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "\u{1B}[?1003l",
                       "a focus-out costs one escape and nothing else")
        XCTAssertFalse(ScreenWriter.motionReporting, "the want follows the write")

        // 3. A second focus-out: nothing.
        wrote = nil
        bytes = captureFd1 { wrote = ScreenWriter.setMotionReporting(false) }
        XCTAssertEqual(wrote, false)
        XCTAssertEqual(bytes.count, 0, """
            a repeated focus-out wrote a second `?1003l`: \
            \(String(decoding: bytes, as: UTF8.self).debugDescription)
            """)

        // 4. Focus-in: exactly one `?1003h`.
        wrote = nil
        bytes = captureFd1 { wrote = ScreenWriter.setMotionReporting(true) }
        XCTAssertEqual(wrote, true)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "\u{1B}[?1003h",
                       "a focus-in costs one escape and nothing else")
        XCTAssertTrue(ScreenWriter.motionReporting)

        // 5. A second focus-in: nothing.
        wrote = nil
        bytes = captureFd1 { wrote = ScreenWriter.setMotionReporting(true) }
        XCTAssertEqual(wrote, false)
        XCTAssertEqual(bytes.count, 0, """
            a repeated focus-in wrote a second `?1003h`: \
            \(String(decoding: bytes, as: UTF8.self).debugDescription)
            """)
    }

    // MARK: - (d) a session that has ended may not enable anything again

    /// The teardown is not the last word the reader has. `Desk.shutdown()` only calls
    /// `input?.restore()`, so the reader thread keeps parsing stdin while -- and after --
    /// `endSession()` gives the pane back to the shell: a `CSI I`, or any keystroke (the reader
    /// counts one as focus-in, I5), would otherwise reach `noteFocus` and put `?1003h` on a pane
    /// that is not ours any more. Every writer in this file was a *reset* before #203, and a reset
    /// after the teardown is harmless; the enable is not.
    ///
    /// The latch is per session, not permanent: `beginSession()` opens the window again, which is
    /// what a second session in one process needs. (`handOver()` never sets the latch at all: it
    /// restores the modes itself and `exec`s, so `endSession()` never runs there.)
    func testAnEndedSessionCannotEnableMotionTrackingAgain() {
        let writer = ScreenWriter()
        writer.sink = { _ in }        // the session's own bytes are not what this case measures
        writer.beginSession()
        writer.endSession()

        // 1. Closed: the want cannot reach the wire, whatever it asks for.
        var wrote: Bool?
        var bytes = captureFd1 { wrote = ScreenWriter.setMotionReporting(false) }
        XCTAssertEqual(wrote, false, "a closed session must report no write")
        XCTAssertEqual(bytes.count, 0, """
            a session that already ended wrote \(bytes.count) B of mouse mode: \
            \(String(decoding: bytes, as: UTF8.self).debugDescription). The pane belongs to the \
            shell by now, and `?1003h` after the teardown is a sticky mode nobody takes back. \
            `?1003l` is just as wrong: the teardown already sent it once.
            """)
        XCTAssertTrue(ScreenWriter.motionReporting,
                      "the latch recorded a want it never put on the wire; the next session would "
                      + "start from a half-applied state instead of the shipped default")

        // 2. … and resets are *not* gated: giving the pane back is always allowed, which is how
        //    the teardown and `writeInputModes(false)` work at all.
        ScreenWriter.focusReporting = true
        XCTAssertEqual(ScreenWriter.inputReset,
                       "\u{1B}[?1004l\u{1B}[?1016l\u{1B}[?1006l\u{1B}[?1002l\u{1B}[?1003l",
                       "the latch must not change the ownership list a reset is derived from")
        bytes = captureFd1 { ScreenWriter.writeInputModes(false) }
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self),
                       "\u{1B}[?1004l\u{1B}[?1016l\u{1B}[?1006l\u{1B}[?1002l\u{1B}[?1003l",
                       "a closed session still gives the modes back; only enables are gated")
        ScreenWriter.focusReporting = false

        // 3. A new session owns the pane again: the same call now writes exactly one escape.
        writer.beginSession()
        wrote = nil
        bytes = captureFd1 { wrote = ScreenWriter.setMotionReporting(false) }
        XCTAssertEqual(wrote, true, "a session that began again may enable, so it may also reset")
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "\u{1B}[?1003l",
                       "the latch is per session, not permanent")
        XCTAssertFalse(ScreenWriter.motionReporting, "the want follows the write again")
        writer.endSession()
    }

    // MARK: - plumbing

    /// Runs `body` with fd 1 redirected into a temp file and returns the bytes krd wrote there.
    ///
    /// Same instrument as `SessionTeardownTests.captureFd1`: the sequences under test are `static`
    /// and go straight to the tty by design (they must not queue behind a frame), so the sink seam
    /// cannot see them. The window is one `write(2)` per call and XCTest runs the cases of a class on
    /// one thread, so nothing of the runner's own output can slip in between.
    private func captureFd1(_ body: () -> Void) -> [UInt8] {
        let path = NSTemporaryDirectory() + "krd-motion-gate-\(UUID().uuidString)"
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { XCTFail("could not open \(path) for the fd-1 capture"); return [] }
        defer { unlink(path) }
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else { close(fd); XCTFail("could not dup fd 1"); return [] }
        // Restore in a `defer`: if anything inside `body()` traps, fd 1 must not stay pointed at a
        // deleted temp file and swallow the rest of the test run's output.
        defer {
            fflush(stdout)
            dup2(saved, STDOUT_FILENO)
            close(saved)
            close(fd)
        }
        dup2(fd, STDOUT_FILENO)
        body()
        return (FileManager.default.contents(atPath: path) ?? Data()).map { $0 }
    }
}
