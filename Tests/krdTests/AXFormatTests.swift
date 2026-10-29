import XCTest
@testable import krd
@testable import krdcore

/// Pure logic only: the text a model ends up reading. Everything that needs a window
/// server (the walk itself, the preflight) is exercised by `krd ax doctor` /
/// `krd ax tree` on a real machine instead -- see docs/research-ax-text-channel.md.
final class AXTextTests: XCTestCase {
    func testSanitizeRemovesWhatATerminalWouldInterpret() {
        // A window title is attacker-controlled (SECURITY.md, "untrusted titles").
        XCTAssertEqual(AXText.sanitize("a\u{1B}[2Jb"), "a [2Jb")
        XCTAssertEqual(AXText.sanitize("line\nbreak"), "line break")
        XCTAssertEqual(AXText.sanitize("bell\u{07}"), "bell ")
        XCTAssertEqual(AXText.sanitize("c1\u{9B}end"), "c1 end")
        XCTAssertEqual(AXText.sanitize("rtl\u{202E}!"), "rtl !")
        XCTAssertEqual(AXText.sanitize("sep\u{2028}x"), "sep x")
    }

    func testSanitizeKeepsTextAndClamps() {
        XCTAssertEqual(AXText.sanitize("保存 Save", limit: 20), "保存 Save")
        let long = String(repeating: "字", count: 10)
        XCTAssertEqual(AXText.sanitize(long, limit: 4), "字字字字…")
        // An unsafe scalar at the clamp boundary must not be allowed to slip past it.
        XCTAssertEqual(AXText.sanitize("abcd\u{1B}ef", limit: 4), "abcd…")
    }

    func testShortNames() {
        XCTAssertEqual(AXText.shortRole("AXButton"), "button")
        XCTAssertEqual(AXText.shortRole("AXWebArea"), "webarea")
        XCTAssertEqual(AXText.shortRole("AXTextArea"), "textarea")
        XCTAssertEqual(AXText.shortRole("AX"), "unknown")
        XCTAssertEqual(AXText.shortAction("AXShowMenu"), "showmenu")
    }

    func testWhatEarnsALine() {
        // Actionable: always, whether labelled or not.
        XCTAssertTrue(AXText.isEmittable(role: "AXButton", name: "", interactiveOnly: true))
        // Structure: only when it carries a name; an unlabelled group is a wrapper.
        XCTAssertFalse(AXText.isEmittable(role: "AXGroup", name: "", interactiveOnly: false))
        XCTAssertTrue(AXText.isEmittable(role: "AXGroup", name: "Toolbar", interactiveOnly: false))
        // -i drops named-but-passive text, which is the bulk of a document window.
        XCTAssertFalse(AXText.isEmittable(role: "AXStaticText", name: "Downloads", interactiveOnly: true))
        XCTAssertTrue(AXText.isEmittable(role: "AXStaticText", name: "Downloads", interactiveOnly: false))
        // The skeleton stays so the reader can see where it is.
        XCTAssertTrue(AXText.isEmittable(role: "AXWindow", name: "", interactiveOnly: true))
        XCTAssertTrue(AXText.isEmittable(role: "AXWebArea", name: "", interactiveOnly: true))
    }

    func testFrameFormatIsScreenshotSpace() {
        XCTAssertEqual(AXText.frameText(CGRect(x: 12.4, y: -3.6, width: 64, height: 24.2)),
                       "[12,-4 64x24]")
        XCTAssertEqual(AXText.frameText(CGRect(x: 0, y: 0, width: 0, height: 24)), "")
        XCTAssertEqual(AXText.frameText(nil), "")
    }

    func testHostileGeometryCannotTrap() {
        // The numbers come from another process: NaN, ±inf and absurd values must clamp,
        // not crash Int(_:).
        XCTAssertEqual(AXText.coordinate(CGFloat.nan), 0)
        XCTAssertEqual(AXText.coordinate(.infinity), 0)
        XCTAssertEqual(AXText.coordinate(-.infinity), 0)
        XCTAssertEqual(AXText.coordinate(1e30), 1_000_000)
        XCTAssertEqual(AXText.coordinate(12.6), 13)
        XCTAssertEqual(AXText.frameText(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)), "[0,0 10x10]")
    }

    func testHostileRoleCannotReachTheTerminal() {
        // An app controls its own role string; shortRole prints it raw.
        XCTAssertEqual(AXText.shortRole("AXButton"), "button")
        XCTAssertEqual(AXText.shortRole("\u{1B}[2KAXButton"), " [2kaxbutton")
        XCTAssertEqual(AXText.shortRole(""), "unknown")
    }

    func testLineLayout() {
        let node = AXNode(ref: "@e3", depth: 1, role: "AXButton", name: "Save",
                          detail: "value=\"hi\"", frame: CGRect(x: 1, y: 2, width: 3, height: 4),
                          actions: ["press", "showmenu"])
        XCTAssertEqual(AXText.render(node), "@e3    button  \"Save\"  value=\"hi\"  [1,2 3x4]  press,showmenu")

        // Absent fields are omitted instead of being left as empty columns.
        let bare = AXNode(ref: "@e1", depth: 0, role: "AXWindow", name: "", detail: "",
                          frame: nil, actions: [])
        XCTAssertEqual(AXText.render(bare), "@e1  window")
    }

    func testHeaderStaysOneLinePerFact() {
        let header = AXText.header(app: "Finder", window: "Down\nloads", index: 0, count: 2,
                                   shown: 30, truncated: true, menuBar: false)
        let lines = header.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("Finder"))
        XCTAssertTrue(lines[0].contains("window 1/2"))
        // The title is sanitized, so it cannot break the line contract.
        XCTAssertFalse(header.contains("\nloads"))
        XCTAssertTrue(lines[1].contains("truncated"))
    }
}
