import XCTest
import ScreenCaptureKit
@testable import krd
import krdcore

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
        XCTAssertTrue(try parseArguments(["/usr/local/bin/krd"]).wall)
        XCTAssertTrue(try parseArguments(["/Users/me/bin/krd", "--fps", "30"]).wall,
                      "a mirror-only knob does not change which screen krd opens")
        XCTAssertTrue(try parseArguments(["krd", "--wall"]).wall, "--wall still means the wall")
        XCTAssertTrue(try parseArguments(["wall"]).wall)
        XCTAssertTrue(try parseArguments(["/usr/local/bin/wall", "--symbols", "ascii"]).wall)
    }

    func testMirrorIsOneFlagAway() {
        XCTAssertFalse(try parseArguments(["krd", "--mirror"]).wall)
        // The alias cannot out-vote an explicit flag: the flags are read after argv[0].
        XCTAssertFalse(try parseArguments(["wall", "--mirror"]).wall)
        // ...and order is ordinary: the last one wins.
        XCTAssertTrue(try parseArguments(["krd", "--mirror", "--wall"]).wall)
    }

    func testNamingOneWindowImpliesTheMirror() throws {
        let options = try parseArguments(["krd", "--window", "Safari"])
        XCTAssertFalse(options.wall, "--window asks for that window, i.e. for the mirror")
        XCTAssertEqual(options.windowQuery, "Safari")
        // Unless the wall is asked for after it.
        XCTAssertTrue(try parseArguments(["krd", "--window", "Safari", "--wall"]).wall)
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
    func testTheCleanWayBackHasNothingToExplain() throws {
        let arguments = Desk.wallArguments(at: (1, 4))
        XCTAssertEqual(arguments, ["--wall", "--wall-at", "1:4"])
        let options = try parseArguments(["krd"] + arguments)
        XCTAssertTrue(options.wall)
        XCTAssertEqual(options.wallAt?.stage, 1)
        XCTAssertEqual(options.wallAt?.card, 4)
        XCTAssertNil(options.said, "a `Ctrl-\\` is not a failure and says nothing in the footer")
    }

    func testAFailedMirrorBringsItsOwnSentence() throws {
        let options = try parseArguments(["krd"] + Desk.wallArguments(
            at: (0, 2), exit: 1, said: "the window closed before it could be shown"))
        XCTAssertEqual(options.wallAt?.card, 2, "a failure still returns to the shelf it was clicked on")
        XCTAssertEqual(options.said?.exit, 1)
        XCTAssertEqual(options.said?.text, "the window closed before it could be shown")
    }

    func testTheMessageSurvivesItsSpacesAndPunctuation() throws {
        // It is one argv token, but it is a sentence: quotes, dashes and commas are the reason this
        // is not a `key=value` flag.
        let said = "Screen Recording is off for this terminal - grant it in System Settings"
        let options = try parseArguments(["krd"] + Desk.wallArguments(at: nil, exit: 1, said: said))
        XCTAssertEqual(options.said?.text, said)
    }

    func testAnEmptySentenceIsStillAFailure() throws {
        // A mirror can fail without a word (a crash inside a framework): the exit status alone has to
        // survive the round trip, or the wall comes back as if nothing happened.
        let options = try parseArguments(["krd"] + Desk.wallArguments(at: (0, 0), exit: 7, said: nil))
        XCTAssertEqual(options.said?.exit, 7)
        XCTAssertEqual(options.said?.text, "")
    }

    /// The page flag is not a mode flag. `wallArguments` gives `--wall-at` to the wall it returns to,
    /// so every wall a reader has visited a card from carries it — and reading it as "I am a
    /// returning mirror" made `shutdown()` `exec` that wall again instead of leaving (`Ctrl-\` a
    /// repaint, SIGHUP an orphan with the capture stream still open). The mode is `options.wall`,
    /// the same bit `run()` uses to pick the page.
    func testAReturnedWallIsStillAWall() throws {
        let returned = try parseArguments(["krd"] + Desk.wallArguments(at: (0, 2)))
        XCTAssertTrue(returned.wall)
        XCTAssertEqual(returned.wallAt?.card, 2, "the page still has to be restored")
        XCTAssertFalse(Desk.returnsToWall(returned),
                       "a wall has no wall to return to; exec'ing it made Ctrl-\\ a repaint")

        // The two ways into a mirror are the two ways that *do* return to the wall.
        XCTAssertTrue(Desk.returnsToWall(try parseArguments(
            ["krd"] + Desk.mirrorArguments(windowID: nil, cell: nil, at: (0, 2)))))
        XCTAssertTrue(Desk.returnsToWall(try parseArguments(
            ["krd"] + Desk.mirrorArguments(windowID: 30, cell: nil, at: (1, 4)))))

        XCTAssertFalse(Desk.returnsToWall(try parseArguments(["krd", "--mirror"])),
                       "a mirror typed by hand has no page to go back to: Ctrl-\\ exits")
        XCTAssertFalse(Desk.returnsToWall(try parseArguments(["krd"])),
                       "and a wall typed by hand never returns to itself")
    }
}

/// `<stage>:<card>` is written by krd for krd, so a malformed one is a bug in the hand-over and not a
/// reader's typo: it is refused rather than clamped. `parseArguments` turns that refusal -- and a
/// missing value -- into a usage error (issue #122), so a broken hand-over fails loudly instead of
/// quietly landing the reader on a fresh wall.
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
        XCTAssertTrue(try parseArguments(["krd", "--wall-at", "1:2"]).wall)
        XCTAssertFalse(try parseArguments(["krd", "--mirror", "--wall-at", "1:2"]).wall)
        // A malformed value is a usage error now, like every other flag's (issue #122): it used to
        // come back as a silent nil, i.e. a hand-over that quietly landed on a fresh wall.
        XCTAssertThrowsError(try parseArguments(["krd", "--wall-at", "nonsense"]))
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
    func testAWindowEnteredFromTheWallWearsTheBar() throws {
        let options = try parseArguments(["krd", "--window", "42", "--wall-at", "0:1"])
        XCTAssertEqual(options.bar, nil, "unset, i.e. decided by where the pane came from")
        XCTAssertNotNil(options.wallAt)
    }

    func testABareMirrorStaysBare() throws {
        let options = try parseArguments(["krd", "--mirror"])
        XCTAssertNil(options.bar)
        XCTAssertNil(options.wallAt)
    }

    func testBothSpellingsWinInTheirOwnDirection() {
        XCTAssertEqual(try parseArguments(["krd", "--mirror", "--bar"]).bar, true)
        XCTAssertEqual(try parseArguments(["krd", "--window", "1", "--bar", "--no-bar"]).bar, false)
        XCTAssertEqual(try parseArguments(["krd", "--window", "1", "--wall-at", "0:0", "--no-bar"]).bar, false,
                       "--no-bar overrides the wall's default")
    }
}

/// One pane, two pages: the hand-over is a new process, so every flag that is not in its `argv` is a
/// default again. `--scale` and `--quality` are exactly the flags a reader sets *because* the link is
/// slow, and the page that streams at 20 fps (the display mirror) used to forget both of them.
final class StickyArgumentTests: XCTestCase {
    private func options(_ arguments: [String]) throws -> Options {
        try parseArguments(["/usr/local/bin/krd"] + arguments)
    }

    func testCheapSettingsSurviveBothDirections() throws {
        let typed = try options(["--scale", "0.8", "--quality", "70", "--wall-quality", "50",
                             "--fps", "10", "--cell", "17x33", "--dpr", "1", "--square", "--cursor"])
        let sticky = Desk.stickyArguments(typed)
        XCTAssertEqual(sticky, ["--cell", "17x33", "--scale", "0.8", "--quality", "70",
                                "--wall-quality", "50",
                                "--fps", "10", "--dpr", "1", "--square", "--cursor"])

        // The wall's way back and the mirror's way forward both carry it, and re-parsing has to give
        // the same answer: a flag that means something else in the other mode is worse than none.
        for arguments in [Desk.wallArguments(at: (1, 2), sticky: sticky),
                          Desk.mirrorArguments(windowID: nil, cell: nil, at: (1, 2), sticky: sticky)] {
            let again = try options(arguments)
            XCTAssertEqual(again.scale, 0.8, "\(arguments)")
            XCTAssertTrue(again.scalePinned)
            XCTAssertEqual(again.quality.value, 70)
            XCTAssertTrue(again.qualityPinned)
            // The two knobs are independent: the wall's rung is not the mirror's (issue #88).
            XCTAssertEqual(again.wallQuality.value, 50, "\(arguments)")
            XCTAssertEqual(again.wallQuality.label, "4-4-4")
            XCTAssertEqual(again.fps, 10)
            XCTAssertEqual(again.dpr, 1)
            XCTAssertEqual(again.cell?.w, 17)
            XCTAssertTrue(again.square)
            XCTAssertTrue(again.drawsCursor)
        }
    }

    func testTheDefaultsHandOverNothing() {
        // A reader who typed nothing must not get a command line that pins the defaults: `--scale
        // auto` and the adaptive quality governor have to stay free to react.
        XCTAssertEqual(Desk.stickyArguments(Options()), [])
        XCTAssertEqual(Desk.wallArguments(at: (0, 0)), ["--wall", "--wall-at", "0:0"])
    }

    func testForcedTransportAndQualityAutoAreCarried() throws {
        let sticky = Desk.stickyArguments(try options(["--no-placeholders", "--quality", "auto"]))
        XCTAssertEqual(sticky, ["--quality", "auto", "--no-placeholders"])
        // `options` already supplies argv[0]; the extra "krd" here used to be a stray positional
        // that the old `default: break` swallowed -- the new parser refuses it (issue #122).
        let again = try options(Desk.wallArguments(at: nil, sticky: sticky))
        XCTAssertEqual(again.placeholders, false)
        XCTAssertTrue(again.qualityAuto)
    }

    /// An eager 80 came back guarded across a wall -> mirror hand-over: `--quality 80` is the bit
    /// depth and cannot spell the other half of the same `QualityBudget` (issue #87).
    func testTheEagerHalfOfQualitySurvivesTheHandOver() throws {
        let typed = try options(["--quality", "80", "--eager"])
        XCTAssertTrue(typed.quality.eager, "--eager is the menu's second slider as a flag")
        let sticky = Desk.stickyArguments(typed)
        XCTAssertEqual(sticky, ["--quality", "80", "--eager"])
        let again = try options(Desk.wallArguments(at: nil, sticky: sticky))
        XCTAssertEqual(again.quality.value, 80)
        XCTAssertTrue(again.quality.eager, "an eager 80 has to stay eager across a hand-over")
        // Guarded is the default, so an untyped knob still hands over nothing extra.
        XCTAssertEqual(Desk.stickyArguments(try options(["--quality", "80"])), ["--quality", "80"])
        // …and the colour pin the menu sets is carried as the number it pinned.
        // A 70 made *guarded* is an override of the rung's own table, so it needs the other flag.
        let guarded = try options(["--quality", "70", "--no-eager"])
        XCTAssertFalse(guarded.quality.eager)
        XCTAssertEqual(Desk.stickyArguments(guarded), ["--quality", "70", "--no-eager"])
        var held = try options(["--quality", "auto"])
        held.qualityHeld = true
        held.quality = QualityBudget(80)
        XCTAssertEqual(Desk.stickyArguments(held), ["--quality", "80"])
    }

    /// A governor rung carries colour *and* frame rate; a click pins one of them (issue #87).
    /// Pure, so "the fps slider does not walk back" is a test rather than a demo.
    func testAPinnedAxisIsTheOneTheGovernorGivesUp() {
        XCTAssertEqual(Desk.qualityChangeTargets(qualityHeld: false, fpsPinned: false).quality, true)
        XCTAssertEqual(Desk.qualityChangeTargets(qualityHeld: false, fpsPinned: false).fps, true)
        XCTAssertEqual(Desk.qualityChangeTargets(qualityHeld: true, fpsPinned: false).quality, false)
        XCTAssertEqual(Desk.qualityChangeTargets(qualityHeld: true, fpsPinned: false).fps, true)
        XCTAssertEqual(Desk.qualityChangeTargets(qualityHeld: false, fpsPinned: true).quality, true)
        XCTAssertEqual(Desk.qualityChangeTargets(qualityHeld: false, fpsPinned: true).fps, false,
                       "a late rung must not overwrite a rate the slider just set")
    }

    /// The fps pin travels with its number: `--fps 7` alone came back unpinned and the next rung
    /// moved it (issue #87).
    func testTheFpsPinTravelsWithItsNumber() throws {
        let pinned = try options(["--fps", "7", "--fps-pinned"])
        XCTAssertTrue(pinned.fpsPinned)
        XCTAssertEqual(Desk.stickyArguments(pinned), ["--fps", "7", "--fps-pinned"])
        let again = try options(Desk.wallArguments(at: nil, sticky: Desk.stickyArguments(pinned)))
        XCTAssertTrue(again.fpsPinned && again.fps == 7)
        // A plain `--fps` stays a capture cadence the governor may lower.
        XCTAssertEqual(Desk.stickyArguments(try options(["--fps", "7"])), ["--fps", "7"])
    }

    /// `--eager` is the other half of `--quality` and it changes the bytes the `--selftest` hash
    /// covers, so it is refused next to it like any other lossy rung.
    func testEagerIsRefusedNextToTheSelftestHash() throws {
        XCTAssertTrue(Desk.selftestRefusesLossy(try options(["--selftest", "--eager"])))
        XCTAssertTrue(Desk.selftestRefusesLossy(try options(["--selftest", "--quality", "70"])))
        XCTAssertTrue(Desk.selftestRefusesLossy(try options(["--selftest", "--quality", "auto"])))
        XCTAssertFalse(Desk.selftestRefusesLossy(try options(["--selftest"])),
                       "the default rung is the hash everyone already has")
        XCTAssertFalse(Desk.selftestRefusesLossy(try options(["--eager"])),
                       "--eager alone is a normal command line")
    }

    func testOnePageFlagsAreNotCarried() throws {
        // `--zoom` and `--demo` mean nothing to the wall (or the opposite of something), so they stay
        // where they were typed rather than following the reader around.
        let sticky = Desk.stickyArguments(try options(["--zoom", "2", "--demo", "--dev"]))
        XCTAssertEqual(sticky, [])
    }
}

extension StickyArgumentTests {
    /// Diagnostics follow their file, never the picture: a mirror that inherits `--debug` but not
    /// `--log` writes its `frame ... px` line *onto the reader's screen*, which is also the picture.
    func testDebugIsCarriedOnlyWithALogFile() throws {
        XCTAssertEqual(try Desk.stickyArguments(options(["--debug"])), [])
        XCTAssertEqual(try Desk.stickyArguments(options(["--debug", "--log", "/tmp/krd.log"])),
                       ["--log", "/tmp/krd.log", "--debug"])
    }
}

/// A pinned `--scale` below 1 has to leave the placeholder transport behind, because a placeholder
/// grid draws one image pixel per device pixel and cannot stretch a smaller frame into its cells.
/// Measured on Rex at `--scale 0.8`: 15x10 tiles each at 80 % of its slot - 14 vertical seams and 9
/// horizontal ones, which the reader described as "画面被割裂".
final class ScaleTransportTests: XCTestCase {
    func testScaleBelowOnePicksPixelPlacementsOnADeviceCellTerminal() {
        XCTAssertTrue(Desk.scaleNeedsPixelPlacements(placeholdersForced: nil, pinnedScale: 0.8,
                                                     deviceCell: true))
    }

    func testFullScaleKeepsPlaceholders() {
        // The default. Placeholders are sharp and cheap on the image budget; nothing to give up.
        XCTAssertFalse(Desk.scaleNeedsPixelPlacements(placeholdersForced: nil, pinnedScale: 1,
                                                      deviceCell: true))
        XCTAssertFalse(Desk.scaleNeedsPixelPlacements(placeholdersForced: nil, pinnedScale: nil,
                                                      deviceCell: true))
    }

    func testATerminalThatStretchesKeepsPlaceholders() {
        // A cell reported in points (kitty: 8x16 for a 16x33 device cell) means the terminal scales
        // images itself, so `--scale` there is bandwidth only - the picture stays in its cells.
        XCTAssertFalse(Desk.scaleNeedsPixelPlacements(placeholdersForced: nil, pinnedScale: 0.8,
                                                      deviceCell: false))
    }

    func testForcingPlaceholdersWins() {
        // An explicit --placeholders is an answer to this question; a scale cannot overrule it.
        XCTAssertFalse(Desk.scaleNeedsPixelPlacements(placeholdersForced: true, pinnedScale: 0.8,
                                                      deviceCell: true))
        XCTAssertFalse(Desk.scaleNeedsPixelPlacements(placeholdersForced: false, pinnedScale: 0.8,
                                                      deviceCell: true))
    }

    // MARK: the frame has to be the cell box (issue #86)

    /// The other half of the same decision: *where* the placeholder frame must be the cell box. On a
    /// terminal that draws one image pixel per device pixel a shorter frame is a seam at every tile
    /// column; on one that scales the image into its cells `--scale` is bandwidth and nothing else, so
    /// taking it away there would be a regression (`testATerminalThatStretchesKeepsPlaceholders`).
    func testOnlyATerminalThatDrawsOneToOneNeedsTheCellBox() {
        XCTAssertTrue(Desk.placeholderNeedsCellBox(placeholders: true, deviceCell: true))
        XCTAssertFalse(Desk.placeholderNeedsCellBox(placeholders: true, deviceCell: false),
                       "a terminal that stretches keeps --scale as bandwidth")
        XCTAssertFalse(Desk.placeholderNeedsCellBox(placeholders: false, deviceCell: true),
                       "a pixel placement is scaled by the terminal")
        XCTAssertFalse(Desk.placeholderNeedsCellBox(placeholders: false, deviceCell: false))
    }
}

/// `--mock` used to be dropped in silence on the wall (issue #114). The parse is where the mode is
/// decided, so the parse is where the truth is pinned — a pane cannot be asserted in a unit test,
/// and "the flag says one thing, the branch does another" is how this bug survived.
final class MockAndDevModeTests: XCTestCase {
    func testTheMockMirrorDoesNotPretendToBeAWall() throws {
        let options = try parseArguments(["krd", "--mock"])
        XCTAssertTrue(options.mock)
        XCTAssertFalse(options.wall,
                       "the mock branch is the mirror; the stale `wall` is what switched --dev off")
        XCTAssertFalse(try parseArguments(["krd", "--mirror", "--mock"]).wall)
        XCTAssertFalse(try parseArguments(["krd", "--mock", "--dev"]).wall, "make dev-mock")
    }

    func testTheWallCanBeAskedForAndTheMockSuppliesItsWindowList() throws {
        for argv in [["krd", "--wall", "--mock"], ["krd", "--mock", "--wall"], ["wall", "--mock"],
                     ["krd", "--wall", "--mock", "--pane", "137x44"]] {
            let options = try parseArguments(argv)
            XCTAssertTrue(options.wall, "\(argv) is the wall")
            XCTAssertTrue(options.mock, "\(argv) paints it from the fake list, not the screen")
        }
        // ...and the mirror stays one flag away, as it always was.
        XCTAssertFalse(try parseArguments(["krd", "--wall", "--mock", "--mirror"]).wall)
    }
}

/// The fake window list `--wall --mock` paints (`WallSource.mockModel`, issue #114). Its point is
/// the §11.6 fixture work: the text layer's risky cases — page arithmetic over a long list, CJK and
/// emoji titles, a title the window server withheld, a panel that cannot be captured — on a machine
/// with no Screen Recording grant.
final class WallMockModelTests: XCTestCase {
    func testTheListReachesWhatAGrantFreeMachineCannot() {
        let model = WallSource.mockModel()
        XCTAssertEqual(model.displays.count, 2, "the stage pages too")
        XCTAssertEqual(model.windows.count, 12, "a three-card-visible shelf: several pages of arithmetic")
        XCTAssertEqual(model.displays.filter(\.main).count, 1)
        XCTAssertTrue(model.windows.contains { ($0.title ?? "").isEmpty },
                      "a withheld title draws `window N`")
        XCTAssertTrue(model.windows.contains { ($0.title ?? "").contains("日本語") })
        XCTAssertTrue(model.windows.contains { ($0.title ?? "").contains("🎨") },
                      "a two-cell emoji in a truncated line")
        XCTAssertTrue(model.windows.contains { $0.bounds.width < 1 || $0.bounds.height < 1 },
                      "a window with no pixels is the mask")
    }

    func testTheStageCanBeCapturedAndTheIdsAreUnambiguous() {
        let model = WallSource.mockModel()
        XCTAssertNotEqual(model.displays[0].id, 0,
                          "a display with id 0 has no picture: the stage would be a mask")
        XCTAssertGreaterThan(model.displays[0].width, 0)
        XCTAssertGreaterThan(model.displays[0].height, 0)
        let ids = model.windows.map(\.windowID)
        XCTAssertEqual(ids.count, Set(ids).count,
                       "the fingerprint sums the ids: two equal ones would make it ambiguous")
    }
}
