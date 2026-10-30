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
