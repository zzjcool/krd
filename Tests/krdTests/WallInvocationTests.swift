import XCTest
@testable import krd

/// `wall` is how the screen is meant to be called, so the binary answers to that name.
///
/// WHY argv[0] and not a wrapper script: a wrapper would have to forward every flag by hand and
/// would drift from the real parser the first time a flag is added. `install.sh` drops a
/// `wall -> krd` symlink; only argv[0] differs, so only argv[0] is read.
final class WallInvocationTests: XCTestCase {
    func testTheBasenameIsTheWholeRule() {
        XCTAssertTrue(invokedAsWall("wall"))
        XCTAssertTrue(invokedAsWall("/Users/me/bin/wall"))
        XCTAssertTrue(invokedAsWall("/usr/local/bin/wall"))
        XCTAssertFalse(invokedAsWall("krd"))
        XCTAssertFalse(invokedAsWall("/usr/local/bin/krd"))
        XCTAssertFalse(invokedAsWall("/tmp/wall/krd"))    // a directory named wall is not the name
        XCTAssertFalse(invokedAsWall("wall.sh"))          // a different binary, not our alias
        XCTAssertFalse(invokedAsWall(""))
    }
}

/// Phase 4 flipped the default: plain `krd` opens the wall, and two flags take it back. Those three
/// facts are what a reader of the README relies on, so they are pinned here rather than in the help
/// text - the help text is a string, the parser is behaviour.
final class WallModeDefaultTests: XCTestCase {
    func testPlainKrdStartsOnTheWall() {
        XCTAssertTrue(parseArguments(["/usr/local/bin/krd"]).wall)
        XCTAssertTrue(parseArguments(["/Users/me/bin/krd", "--fps", "30"]).wall,
                      "a mirror-only knob does not change which screen krd opens")
        XCTAssertTrue(parseArguments(["krd", "--wall"]).wall, "--wall still means the wall")
        XCTAssertTrue(parseArguments(["wall"]).wall)
        XCTAssertTrue(parseArguments(["/usr/local/bin/wall", "--symbols", "ascii"]).wall)
    }

    func testMirrorIsOneFlagAway() {
        XCTAssertFalse(parseArguments(["krd", "--mirror"]).wall)
        // The alias cannot out-vote an explicit flag: the flags are read after argv[0].
        XCTAssertFalse(parseArguments(["wall", "--mirror"]).wall)
        // ...and order is ordinary: the last one wins.
        XCTAssertTrue(parseArguments(["krd", "--mirror", "--wall"]).wall)
    }

    func testNamingOneWindowImpliesTheMirror() {
        let options = parseArguments(["krd", "--window", "Safari"])
        XCTAssertFalse(options.wall, "--window asks for that window, i.e. for the mirror")
        XCTAssertEqual(options.windowQuery, "Safari")
        // Unless the wall is asked for after it.
        XCTAssertTrue(parseArguments(["krd", "--window", "Safari", "--wall"]).wall)
    }
}

/// Clicking a picture hands the pane to a child `krd`: one `posix_spawn` of this same binary, and the
/// wall returns when that child exits. The command line is the part that can go wrong silently - a
/// flag the child reads as something else is a wrong picture, not an error - so it is a pure
/// function with a test.
final class WallMirrorChildTests: XCTestCase {
    func testAWindowGetsItsOwnId() {
        XCTAssertEqual(Desk.mirrorArguments(windowID: 30, cell: nil), ["--window", "30"])
        // `--window` implies the mirror, so no `--mirror` is added: one spelling of one request.
        XCTAssertFalse(Desk.mirrorArguments(windowID: 30, cell: nil).contains("--mirror"))
    }

    func testAStageClickMirrorsTheDisplay() {
        // Plain `krd` is the wall now, so the child has to say it wants the mirror.
        XCTAssertEqual(Desk.mirrorArguments(windowID: nil, cell: nil), ["--mirror"])
    }

    func testTheCellSizeIsForwarded() {
        // A pty that reports no pixel size is exactly the case where the child must be told what
        // the wall already worked out, or it draws a picture at the built-in 8x20 cell.
        XCTAssertEqual(Desk.mirrorArguments(windowID: 7, cell: (17, 33)),
                       ["--window", "7", "--cell", "17x33"])
        XCTAssertEqual(Desk.mirrorArguments(windowID: nil, cell: (17, 33)),
                       ["--mirror", "--cell", "17x33"])
    }
}

/// When the child mirror stops, the wall a reader comes back to says why. The message is the child's
/// own sentence - it is the one that knows whether the window is gone or the grant is missing.
final class WallMirrorFailureTests: XCTestCase {
    func testTheLastLineIsWhatTheChildSaid() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("krd-test-mirror-\(UUID().uuidString).log").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try """
        krd: logging to /tmp/krd-1.log
        krd: no window matched "30" (try --list)

        """.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(Desk.lastLine(of: path), "no window matched \"30\" (try --list)",
                       "the krd: prefix is noise in a footer that is already krd's")
        XCTAssertNil(Desk.lastLine(of: path + ".missing"), "a file that is not there says nothing")
    }

    func testTheExitCodeIsTheNumberAShellWouldPrint() {
        XCTAssertEqual(Desk.exitCode(of: 1 << 8), 1)
        XCTAssertEqual(Desk.exitCode(of: 0), 0)
        // `exit(2)`, which is what a usage error produces.
        XCTAssertEqual(Desk.exitCode(of: 2 << 8), 2)
        // Killed by SIGSEGV (11): shells say 139, and so does this.
        XCTAssertEqual(Desk.exitCode(of: 11), 128 + 11)
    }

    func testAFrameworkErrorKeepsOnlyItsDescription() {
        let raw = "krd: Error Domain=com.apple.ScreenCaptureKit.SCStreamErrorDomain Code=-3801 "
            + "\"The user declined TCCs for application, window, display capture\" "
            + "UserInfo={NSLocalizedDescription=The user declined TCCs for application, window, "
            + "display capture}"
        XCTAssertEqual(Desk.tidy(raw), "The user declined TCCs for application, window, display capture")
        // krd's own one-liners lose their prefix and nothing else.
        XCTAssertEqual(Desk.tidy("krd: no window matched \"30\" (try --list)"),
                       "no window matched \"30\" (try --list)")
        XCTAssertEqual(Desk.tidy("plain sentence"), "plain sentence")
    }

    func testALongLineIsCutToFitOneFooterRow() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("krd-test-mirror-\(UUID().uuidString).log").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try String(repeating: "x", count: 400).write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(Desk.lastLine(of: path)?.count, 120)
    }

    func testTheFooterSentenceNamesTheExitAndTheReason() {
        XCTAssertEqual(
            WallNotice.mirrorStopped(exit: 1, message: "no window matched \"30\"").text(bullet: "-", dash: " - "),
            "- the mirror stopped (exit 1) - no window matched \"30\"")
        XCTAssertEqual(WallNotice.mirrorStopped(exit: 9, message: nil).text(bullet: "-", dash: " - "),
                       "- the mirror stopped (exit 9)")
        XCTAssertEqual(WallNotice.mirrorStopped(exit: 1, message: "").text(bullet: "-", dash: " - "),
                       "- the mirror stopped (exit 1)", "an empty message is no message")
    }
}
