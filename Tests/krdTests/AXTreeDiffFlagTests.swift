import XCTest
@testable import krd

/// Issue #108: `krd ax tree --diff` is a flag on one verb, and the six exit codes #123 pinned
/// are unchanged by it. Both halves are pure -- the parser and the exit table -- so neither
/// needs Accessibility permission, which is why they are pinned here and not by driving the
/// binary (`exit()` takes the test process with it).
final class AXTreeDiffFlagTests: XCTestCase {

    // MARK: the flag

    func testDiffParsesOntoTheTreeVerb() throws {
        let options = try AXCommand.parse(["tree", "--diff", "--app", "Finder"])
        XCTAssertEqual(options.verb, "tree")
        XCTAssertTrue(options.diff)
        XCTAssertEqual(options.app, "Finder")
    }

    func testDiffIsOffUnlessAskedFor() throws {
        XCTAssertFalse(try AXCommand.parse(["tree"]).diff)
        XCTAssertFalse(try AXCommand.parse(["tree", "--json"]).diff)
    }

    /// `--diff` compares two dumps of one window, so every other verb refuses it instead of
    /// silently ignoring a flag the caller believed in.
    func testDiffIsRefusedByEveryOtherVerb() {
        for args in [["windows", "--diff"], ["screen", "--diff"], ["doctor", "--diff"],
                     ["find", "Save", "--diff"], ["press", "@e7", "--diff"]] {
            XCTAssertThrowsError(try AXCommand.parse(args), "\(args) should be a usage failure") { error in
                guard case AXFailure.usage(let message)? = error as? AXFailure else {
                    return XCTFail("\(args): expected a usage failure, got \(error)")
                }
                XCTAssertTrue(message.contains("--diff only applies to tree"),
                              "\(args): the sentence has to say which verb owns the flag, got \(message)")
            }
        }
    }

    /// The help has to name it, or the flag exists only in the source.
    func testUsageNamesTheChangeFlag() {
        XCTAssertTrue(AXCommand.usage().contains("--diff"))
    }

    // MARK: the exit contract #123 pinned, which a diff does not touch

    /// Six outcomes, six codes. A successful diff exits 0 even when everything changed (`tree`
    /// did before it, and a diff is not a failure), and no diff path adds a seventh.
    func testTheSixOutcomesStillMapToSixCodes() {
        XCTAssertEqual(AXExit.ok.rawValue, 0)
        XCTAssertEqual(AXExit.usage.rawValue, 2)
        XCTAssertEqual(AXExit.permission.rawValue, 3)
        XCTAssertEqual(AXExit.environment.rawValue, 4)
        XCTAssertEqual(AXExit.notFound.rawValue, 5)
        XCTAssertEqual(AXExit.notActionable.rawValue, 6)

        let failures: [AXFailure] = [
            .usage("unknown option \"--nonsense\" (try `krd ax --help`)"),
            .permission(AXCommand.permissionText, ax: nil),
            .environment(AXCommand.environmentText(error: .cannotComplete), ax: nil),
            .notFound("no previous dump"),
            .notActionable("@e7 button \"Save\" does not answer press (AXPress)"),
        ]
        // A failure is still exactly one object on stdout, whichever verb produced it -- and a
        // diff failure is one of these five, not a new shape.
        for failure in failures {
            let output = AXCommand.failureOutput(failure, json: true)
            XCTAssertEqual(output.code, failure.code.rawValue)
            XCTAssertEqual(output.stdout.filter { $0 == "\n" }.count, 1,
                           "\(failure.code): one object on one line")
        }
    }

    /// The caps a text diff prints under. Constants, so the output size cannot drift silently.
    func testTextReportLimitsAreTheAdvertisedOnes() {
        XCTAssertEqual(AXDiff.anchorLimit, 3)
        XCTAssertEqual(AXDiff.changeLimit, 40)
        XCTAssertEqual(AXDiff.unchanged, "unchanged")
    }
}
