import XCTest
import ScreenCaptureKit
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

/// Clicking a picture replaces this process with a mirror of it (`execv`, not spawn: two live
/// processes of one executable cannot both be ScreenCaptureKit clients - see `Desk.handOver`). The
/// command line is the part that can go wrong silently - a flag the mirror reads as something else
/// is a wrong picture, not an error - so it is a pure function with a test.
final class WallMirrorChildTests: XCTestCase {
    func testAWindowGetsItsOwnId() {
        XCTAssertEqual(Desk.mirrorArguments(windowID: 30, cell: nil, at: nil), ["--window", "30"])
        // `--window` implies the mirror, so no `--mirror` is added: one spelling of one request.
        XCTAssertFalse(Desk.mirrorArguments(windowID: 30, cell: nil, at: nil).contains("--mirror"))
    }

    func testAStageClickMirrorsTheDisplay() {
        // Plain `krd` is the wall now, so the mirror has to say it wants the mirror.
        XCTAssertEqual(Desk.mirrorArguments(windowID: nil, cell: nil, at: nil), ["--mirror"])
    }

    func testTheCellSizeIsForwarded() {
        // A pty that reports no pixel size is exactly the case where the mirror must be told what
        // the wall already worked out, or it draws a picture at the built-in 8x20 cell.
        XCTAssertEqual(Desk.mirrorArguments(windowID: 7, cell: (17, 33), at: nil),
                       ["--window", "7", "--cell", "17x33"])
        XCTAssertEqual(Desk.mirrorArguments(windowID: nil, cell: (17, 33), at: nil),
                       ["--mirror", "--cell", "17x33"])
    }

    func testTheShelfTheReaderWasOnTravelsWithTheMirror() {
        // Nothing is left behind to remember it: the process image is replaced, so the only place the
        // shelf can survive is argv.
        XCTAssertEqual(Desk.mirrorArguments(windowID: nil, cell: nil, at: (2, 1)),
                       ["--mirror", "--wall-at", "2:1"])
        XCTAssertEqual(Desk.mirrorArguments(windowID: 9, cell: (17, 33), at: (0, 11)),
                       ["--window", "9", "--cell", "17x33", "--wall-at", "0:11"])
    }
}

/// The way back. A mirror that leaves - cleanly with `Ctrl-\`, or because its capture never started -
/// `exec`s the wall again, so the command line it comes back with has to mean exactly what the wall
/// reads: the same page, and (when it failed) the sentence it failed with.
final class WallReturnTests: XCTestCase {
    func testTheCleanWayBackHasNothingToExplain() {
        let arguments = Desk.wallArguments(at: (1, 4))
        XCTAssertEqual(arguments, ["--wall", "--wall-at", "1:4"])
        let options = parseArguments(["krd"] + arguments)
        XCTAssertTrue(options.wall)
        XCTAssertEqual(options.wallAt?.stage, 1)
        XCTAssertEqual(options.wallAt?.card, 4)
        XCTAssertNil(options.said, "a `Ctrl-\\` is not a failure and says nothing in the footer")
    }

    func testAFailedMirrorBringsItsOwnSentence() {
        let options = parseArguments(["krd"] + Desk.wallArguments(
            at: (0, 2), exit: 1, said: "the window closed before it could be shown"))
        XCTAssertEqual(options.wallAt?.card, 2, "a failure still returns to the shelf it was clicked on")
        XCTAssertEqual(options.said?.exit, 1)
        XCTAssertEqual(options.said?.text, "the window closed before it could be shown")
    }

    func testTheMessageSurvivesItsSpacesAndPunctuation() {
        // It is one argv token, but it is a sentence: quotes, dashes and commas are the reason this
        // is not a `key=value` flag.
        let said = "Screen Recording is off for this terminal - grant it in System Settings"
        let options = parseArguments(["krd"] + Desk.wallArguments(at: nil, exit: 1, said: said))
        XCTAssertEqual(options.said?.text, said)
    }

    func testAnEmptySentenceIsStillAFailure() {
        // A mirror can fail without a word (a crash inside a framework): the exit status alone has to
        // survive the round trip, or the wall comes back as if nothing happened.
        let options = parseArguments(["krd"] + Desk.wallArguments(at: (0, 0), exit: 7, said: nil))
        XCTAssertEqual(options.said?.exit, 7)
        XCTAssertEqual(options.said?.text, "")
    }
}

/// `<stage>:<card>` is written by krd for krd, so a malformed one is a bug in the hand-over and not a
/// reader's typo: it is refused rather than clamped, and a missing value means "the fresh wall".
final class WallAtParsingTests: XCTestCase {
    func testBothHalvesAreRequired() {
        XCTAssertEqual(parseWallAt("2:1")?.stage, 2)
        XCTAssertEqual(parseWallAt("2:1")?.card, 1)
        XCTAssertEqual(parseWallAt("0:0")?.stage, 0)
        XCTAssertNil(parseWallAt("2"))
        XCTAssertNil(parseWallAt("2:"))
        XCTAssertNil(parseWallAt(":1"))
        XCTAssertNil(parseWallAt("a:b"))
        XCTAssertNil(parseWallAt("1:2:3"), "three halves is not two offsets")
        XCTAssertNil(parseWallAt("-1:0"), "an offset cannot be negative")
    }

    func testAFlagThatIsNotTheMirrorsLeavesTheWallAlone() {
        // `--wall-at` is bookkeeping, not a mode: it must not flip anything by itself.
        XCTAssertTrue(parseArguments(["krd", "--wall-at", "1:2"]).wall)
        XCTAssertFalse(parseArguments(["krd", "--mirror", "--wall-at", "1:2"]).wall)
        XCTAssertNil(parseArguments(["krd", "--wall-at", "nonsense"]).wallAt)
    }
}

/// When the child mirror stops, the wall a reader comes back to says why. The message is the child's
/// own sentence - it is the one that knows whether the window is gone or the grant is missing.
final class WallMirrorFailureTests: XCTestCase {
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

/// A mirror whose stream dies before its first frame names a target that will never open, so it
/// must exit with a sentence instead of retrying five times behind a blank pane (and behind the
/// wall's `waitpid`). The sentence comes from the same four modes a card's mask uses.
final class DeskSetupFailureTests: XCTestCase {
    private func streamError(_ code: Int) -> NSError {
        NSError(domain: SCStreamErrorDomain, code: code, userInfo: [
            NSLocalizedDescriptionKey: "the framework's own words",
        ])
    }

    func testAWindowThatLeftSaysSoInItsOwnWords() {
        XCTAssertEqual(Desk.setupFailure(streamError(-3813)),
                       "the window closed before it could be shown")
    }

    func testARefusedGrantNamesTheSettingTheReaderHasToOpen() {
        // -3801 (the TCC answer) and -3803 (the same answer with no dialog) are one situation.
        XCTAssertEqual(Desk.setupFailure(streamError(-3801)),
                       "Screen Recording is off for this terminal")
        XCTAssertEqual(Desk.setupFailure(streamError(-3803)),
                       "Screen Recording is off for this terminal")
    }

    func testATransientStreamFaultKeepsTheFrameworksMessage() {
        // -3805 ("application connection being interrupted") is what a VM's window server says when
        // it will not stream at all: nothing to translate, so the line the user reads is the line
        // the framework wrote.
        XCTAssertEqual(Desk.setupFailure(streamError(-3805)), "the framework's own words")
        XCTAssertEqual(Desk.setupFailure(DeskError.message("display 3 is not in the shareable list")),
                       "display 3 is not in the shareable list")
    }
}

/// The bar is window furniture, so it is on for a window the wall handed over (that is the only place
/// a reader can "shrink back"), and off for a mirror someone typed by hand - where a status bar on top
/// of a picture would be a new thing to explain rather than a familiar one.
final class MirrorBarDefaultTests: XCTestCase {
    func testAWindowEnteredFromTheWallWearsTheBar() {
        let options = parseArguments(["krd", "--window", "42", "--wall-at", "0:1"])
        XCTAssertEqual(options.bar, nil, "unset, i.e. decided by where the pane came from")
        XCTAssertNotNil(options.wallAt)
    }

    func testABareMirrorStaysBare() {
        let options = parseArguments(["krd", "--mirror"])
        XCTAssertNil(options.bar)
        XCTAssertNil(options.wallAt)
    }

    func testBothSpellingsWinInTheirOwnDirection() {
        XCTAssertEqual(parseArguments(["krd", "--mirror", "--bar"]).bar, true)
        XCTAssertEqual(parseArguments(["krd", "--window", "1", "--bar", "--no-bar"]).bar, false)
        XCTAssertEqual(parseArguments(["krd", "--window", "1", "--wall-at", "0:0", "--no-bar"]).bar, false,
                       "--no-bar overrides the wall's default")
    }
}
