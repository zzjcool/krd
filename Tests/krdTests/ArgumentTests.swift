import XCTest
import krdcore
@testable import krd

/// The command line is the first thing krd reads, and until issue #122 it was the one thing it could
/// get wrong *silently*: `parseArguments` dropped every token it did not know (`default: break`) and
/// read a value-taking flag's missing value as `""`, so `krd --nonsense` and `krd --fps` came back as
/// a default `Options` and the process went on to paint — and stream — the desktop.
///
/// These tests call the parser directly: no pty, no capture, no timeout wrapper. The failure is a
/// `UsageError` the top of `main` turns into one stderr line and status `2`.
final class ArgumentTests: XCTestCase {
    /// The sentence the process would print for this argv, or nil if it parses.
    private func refusal(_ argv: [String]) -> String? {
        do {
            _ = try parseArguments(argv)
            return nil
        } catch let error as UsageError {
            return error.message
        } catch {
            return "not a UsageError: \(error)"
        }
    }

    func testAnUnknownOptionIsRefusedByName() {
        XCTAssertEqual(refusal(["krd", "--nonsense"]),
                       "unknown option \"--nonsense\" (try `krd --help`)")
        // A typo after a valid flag is the dangerous case: the valid half must not buy the typo a
        // capture, which is exactly what `--fps 20 --mirror-mode` used to do.
        XCTAssertEqual(refusal(["krd", "--fps", "20", "--mirror-mode"]),
                       "unknown option \"--mirror-mode\" (try `krd --help`)")
    }

    func testAStrayArgumentIsRefusedToo() {
        // `krd junk` opened the mirror as well: the switch dropped positionals one at a time.
        XCTAssertEqual(refusal(["krd", "junk"]),
                       "unexpected argument \"junk\" (try `krd --help`)")
    }

    func testAFlagWithNoValueIsRefusedAndNamesItself() {
        for flag in ["--fps", "--unfocused-fps", "--display", "--zoom", "--tile", "--cell",
                     "--format", "--window", "--quality", "--wall-quality", "--ime",
                     "--clipboard", "--log", "--scale"] {
            XCTAssertEqual(refusal(["krd", flag]), "\(flag) needs a value", flag)
        }
    }

    func testAnotherOptionIsNotAValue() {
        // `--fps --wall` used to read "--wall" as the rate and fall back to 20: a typo that also
        // silently dropped the next flag.
        XCTAssertEqual(refusal(["krd", "--fps", "--wall"]),
                       "--fps needs a value (got the option \"--wall\")")
        XCTAssertEqual(refusal(["krd", "--window", "--mirror"]),
                       "--window needs a value (got the option \"--mirror\")")
        XCTAssertEqual(refusal(["krd", "--log", "--verbose"]),
                       "--log needs a value (got the option \"--verbose\")")
    }

    func testAMalformedValueIsRefused() {
        // `--fps abc` used to stream at 20 fps instead of saying "abc is not a number". Every one of
        // these used to be swallowed and the default used instead.
        XCTAssertEqual(refusal(["krd", "--fps", "abc"]),
                       "--fps wants a whole number, got \"abc\"")
        XCTAssertEqual(refusal(["krd", "--tile", "8"]),
                       "--tile wants <cols>x<rows>, got \"8\"")
        XCTAssertEqual(refusal(["krd", "--cell", "17"]),
                       "--cell wants <width>x<height> in pixels, got \"17\"")
        XCTAssertEqual(refusal(["krd", "--format", "bgr"]),
                       "--format wants rgb or rgba, got \"bgr\"")
        XCTAssertEqual(refusal(["krd", "--zoom", "wide"]),
                       "--zoom wants a number, got \"wide\"")
        XCTAssertEqual(refusal(["krd", "--source", "1440"]),
                       "--source wants <width>x<height>, got \"1440\"")
        XCTAssertEqual(refusal(["krd", "--pane", "1x1"]),
                       "--pane wants <cols>x<rows> (at least 2x2), got \"1x1\"")
        XCTAssertEqual(refusal(["krd", "--rounds", "0"]),
                       "--rounds wants a positive number of rounds, got \"0\"")
        XCTAssertEqual(refusal(["krd", "--seconds", "0"]),
                       "--seconds wants a positive number of seconds, got \"0\"")
        XCTAssertEqual(refusal(["krd", "--wall-at", "nonsense"]),
                       "--wall-at wants <stage>:<card>, got \"nonsense\"")
        XCTAssertEqual(refusal(["krd", "--said", "1"]),
                       "--said needs <exit> <text> (the failed mirror's status and its sentence)")
        // The wall's own knob has the mirror's grammar, and its own sentence: a typo must not quietly
        // leave the landing screen at the default rung (issue #88).
        XCTAssertEqual(refusal(["krd", "--wall-quality", "150"]),
                       "--wall-quality wants 0...100 or auto, got \"150\"")
        XCTAssertEqual(refusal(["krd", "--wall-quality", "cheap"]),
                       "--wall-quality wants 0...100 or auto, got \"cheap\"")
        XCTAssertEqual(refusal(["krd", "--wall-quality=abc"]),
                       "--wall-quality wants 0...100 or auto, got \"abc\"")
    }

    /// A parseable value keeps its old normalisation even when it is out of the useful range: the
    /// issue is about values that are not numbers at all, not about re-deciding `--fps 0` (which has
    /// always meant 1).
    func testAParseableOutOfRangeValueKeepsItsOldMeaning() throws {
        XCTAssertEqual(try parseArguments(["krd", "--fps", "0"]).fps, 1)
        XCTAssertEqual(try parseArguments(["krd", "--fps", "-1"]).fps, 1)
        XCTAssertEqual(try parseArguments(["krd", "--zoom", "0"]).zoom, 0)
        XCTAssertEqual(try parseArguments(["krd", "--display", "-1"]).displayIndex, -1)
    }

    /// The two quality knobs are one grammar and two answers (issue #88): a value is a rung of the
    /// same ladder, `auto` is "krd decides", and the wall's default is not the mirror's.
    func testTheWallQualityKnobIsItsOwnDefault() throws {
        let untouched = try parseArguments(["krd"])
        XCTAssertEqual(untouched.wallQuality, QualityBudget.wall)
        XCTAssertEqual(untouched.wallQuality.value, 70)
        XCTAssertEqual(untouched.wallQuality.label, "5-5-5")
        XCTAssertEqual(untouched.quality, QualityBudget.default, "the mirror's default is untouched")
        XCTAssertFalse(untouched.qualityPinned)

        // Both spellings, and every rung of the ladder the mirror already knows.
        XCTAssertEqual(try parseArguments(["krd", "--wall-quality", "100"]).wallQuality.bits, nil)
        XCTAssertEqual(try parseArguments(["krd", "--wall-quality", "80"]).wallQuality.label, "5-6-5")
        XCTAssertEqual(try parseArguments(["krd", "--wall-quality=50"]).wallQuality.label, "4-4-4")
        XCTAssertEqual(try parseArguments(["krd", "--wall-quality", "auto"]).wallQuality,
                       QualityBudget.wall, "auto is the default rung: the wall has no ladder")
        XCTAssertEqual(try parseArguments(["krd", "--wall-quality", "AUTO"]).wallQuality,
                       QualityBudget.wall)
        // Naming one knob must not move the other: a reader who types only `--wall-quality 50` keeps
        // the mirror's own default (`--quality auto`).
        let wallOnly = try parseArguments(["krd", "--wall-quality", "50"])
        XCTAssertEqual(wallOnly.quality, QualityBudget.default)
        XCTAssertFalse(wallOnly.qualityPinned)
        XCTAssertFalse(wallOnly.qualityAuto)
    }

    /// The rate the picture drops to while the terminal reports focus-out (issue #110). It is its own
    /// flag rather than a second meaning for `--fps` because the two answer different questions: how
    /// fast the capture may run, and how fast it may run when nobody is looking. `0` is a *value*
    /// here (freeze the picture), which is the one place its grammar differs from `--fps`'s.
    func testTheUnfocusedRateDefaultsToOneAndMayBeZero() throws {
        XCTAssertEqual(try parseArguments(["krd"]).unfocusedFps, 1,
                       "1, not 0: a lost focus-in report must leave a pane updating slowly, not dead")
        XCTAssertEqual(try parseArguments(["krd", "--unfocused-fps", "0"]).unfocusedFps, 0)
        XCTAssertEqual(try parseArguments(["krd", "--unfocused-fps", "3"]).unfocusedFps, 3)
        // The other knob keeps its own default: naming one rate must not move the other.
        let both = try parseArguments(["krd", "--fps", "30", "--unfocused-fps", "2"])
        XCTAssertEqual(both.fps, 30)
        XCTAssertEqual(both.unfocusedFps, 2)
        // A parseable value below the range is normalised, not refused -- the same rule `--fps 0`
        // has always had (it means 1); here the floor is 0, i.e. "frozen".
        XCTAssertEqual(try parseArguments(["krd", "--unfocused-fps", "-5"]).unfocusedFps, 0)
        // What is *not* a number is still a usage error, and a missing value names the flag.
        XCTAssertEqual(refusal(["krd", "--unfocused-fps", "x"]),
                       "--unfocused-fps wants a whole number, got \"x\"")
        XCTAssertEqual(refusal(["krd", "--unfocused-fps"]), "--unfocused-fps needs a value")
        XCTAssertEqual(refusal(["krd", "--unfocused-fps", "--mirror"]),
                       "--unfocused-fps needs a value (got the option \"--mirror\")")
    }

    func testAValidCommandLineParsesExactlyAsBefore() throws {
        // The other half of the contract: none of the tightening above may change what a valid
        // command line means. Every field the flags touch is pinned to the value that was typed.
        let options = try parseArguments([
            "krd", "--fps", "30", "--display", "1", "--tile", "16x8", "--cell", "17x33",
            "--format", "rgba", "--dpr", "2", "--zoom", "2", "--zoom-at", "10,20",
            "--window", "Safari", "--no-input", "--scale", "0.5", "--quality", "70",
            "--symbols", "ascii", "--log", "/tmp/krd.log",
        ])
        XCTAssertEqual(options.fps, 30)
        XCTAssertEqual(options.displayIndex, 1)
        XCTAssertEqual(options.tileCols, 16)
        XCTAssertEqual(options.tileRows, 8)
        XCTAssertEqual(options.cell?.w, 17)
        XCTAssertEqual(options.cell?.h, 33)
        XCTAssertEqual(options.pixelFormat, .rgba)
        XCTAssertEqual(options.dpr, 2)
        XCTAssertEqual(options.zoom, 2)
        XCTAssertEqual(options.zoomAt, CGPoint(x: 10, y: 20))
        XCTAssertEqual(options.windowQuery, "Safari")
        XCTAssertFalse(options.wall, "--window asks for the mirror")
        XCTAssertTrue(options.noInput)
        XCTAssertEqual(options.scale, 0.5)
        XCTAssertFalse(options.scaleAuto)
        XCTAssertTrue(options.scalePinned)
        XCTAssertEqual(options.quality.value, 70)
        XCTAssertTrue(options.qualityPinned)
        XCTAssertEqual(options.symbols, .ascii)
        XCTAssertEqual(options.logPath, "/tmp/krd.log")
    }

    func testTheDiagnosticModesStillParse() throws {
        XCTAssertTrue(try parseArguments(["krd"]).wall)
        let selftest = try parseArguments(["krd", "--selftest", "--no-input"])
        XCTAssertTrue(selftest.selftest)
        XCTAssertTrue(selftest.noInput)
        XCTAssertTrue(try parseArguments(["krd", "--list"]).listOnly)
    }

    /// The other half of the contract lives outside the parser: the sentence must arrive on
    /// **stderr**, stdout (the picture stream) must stay empty, and the status must be 2. Only a
    /// spawned process can show that -- `UsageError.status` alone would stay green if `main` printed
    /// to stdout or exited 1. `--nonsense` returns immediately, so no timeout wrapper is needed.
    func testAUsageErrorLeavesTheProcessWithStatusTwoAndAQuietStdout() throws {
        let binary = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("krd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("no krd binary at \(binary.path) — run `swift build` before `swift test`")
            return
        }
        let cases: [([String], String)] = [
            (["--nonsense"], "krd: unknown option \"--nonsense\" (try `krd --help`)\n"),
            (["--fps"], "krd: --fps needs a value\n"),
            (["--unfocused-fps"], "krd: --unfocused-fps needs a value\n"),
            (["--fps", "--wall"], "krd: --fps needs a value (got the option \"--wall\")\n"),
            (["--fps", "abc"], "krd: --fps wants a whole number, got \"abc\"\n"),
        ]
        for (arguments, sentence) in cases {
            let child = Process()
            child.executableURL = binary
            child.arguments = arguments
            let out = Pipe()
            let err = Pipe()
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = out
            child.standardError = err
            try child.run()
            // A bound, not a hang. Before the fix this argv starts the mirror, and a plain
            // `waitUntilExit()` would block the whole suite on a 20 fps capture into a full pipe --
            // a red contract must be a failure, not a hung test run. Five seconds is already a
            // hundred times what a clean exit takes.
            let deadline = Date().addingTimeInterval(5)
            while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
                XCTFail("krd \(arguments) did not exit within 5 s; a usage error must not start a capture")
                continue
            }
            XCTAssertEqual(child.terminationStatus, 2, "\(arguments)")
            XCTAssertEqual(out.fileHandleForReading.readDataToEndOfFile().count, 0,
                           "stdout is the picture stream; \(arguments) must not touch it")
            XCTAssertEqual(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                           sentence, "\(arguments)")
        }
    }

    /// The wall hands a failed mirror's sentence back as one argv token, and that sentence can begin
    /// with `--` (a refused `--selftest --scale` does), so `--said`'s text is the one value the
    /// "looks like an option" test must not touch.
    func testAHandOversSentenceSurvivesEvenWhenItStartsWithAnOption() throws {
        let said = "--selftest always captures at scale 1; drop --scale"
        let options = try parseArguments(["krd"] + Desk.wallArguments(at: (0, 2), exit: 1, said: said))
        XCTAssertEqual(options.said?.exit, 1)
        XCTAssertEqual(options.said?.text, said)
        XCTAssertEqual(options.wallAt?.card, 2, "a failure still knows which card to return to")
    }

    func testTheUsageStatusIsTheDocumentedTwo() {
        // The README's contract (`0` ok, `2` usage), and the code `krd ax` already leaves for the
        // same class of mistake. `main` prints the message and exits with exactly this.
        XCTAssertEqual(UsageError.status, 2)
    }
}
