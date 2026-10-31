import XCTest
@testable import krd

/// Issue #124: `krd --list` owes stdout its listing and nothing else, and `--list --json` owes a
/// program the same listing as one object.
///
/// The escape that used to precede the listing came from the placeholder probe in `Desk.run()`,
/// which no unit test can run (it needs a terminal). What *is* testable is the half that was
/// missing entirely: the listing itself, as records. `ListOutput` is those records and their two
/// renderings, so text bytes and JSON keys are pinned here without a screen, and the failure
/// envelope is pinned without an exit code (the code is returned as a value, as in
/// `AXJSONFailureShapeTests`).
final class ListOutputTests: XCTestCase {

    // MARK: - the fixed record set every format test reads

    private var displays: [ListDisplay] {
        [ListDisplay(index: 0, id: 2, width: 1440, height: 2560, main: true),
         ListDisplay(index: 1, id: 1, width: 1512, height: 982, main: false)]
    }

    private var windows: [ListWindow] {
        [
            // A backdrop window: layer below the desktop, covering display 0 of 2.
            ListWindow(id: 83, app: "", title: "Display 2 Backstop",
                       frame: CGRect(x: 0, y: 0, width: 1440, height: 2560),
                       display: 0, backdropDisplay: 0, targetable: false),
            // An ordinary window, on the second display, with a title macOS did withhold.
            ListWindow(id: 679, app: "Google Chrome", title: "Pull requests · zzjcool/krd",
                       frame: CGRect(x: -1512, y: 950, width: 1512, height: 949),
                       display: 1, backdropDisplay: nil, targetable: true),
            ListWindow(id: 935, app: "Google Chrome", title: "-",
                       frame: CGRect(x: -1175, y: 993, width: 100, height: 21),
                       display: 1, backdropDisplay: nil, targetable: true),
        ]
    }

    private func json(_ string: String, label: String, file: StaticString = #filePath,
                      line: UInt = #line) -> [String: Any] {
        XCTAssertTrue(string.hasSuffix("\n"), "\(label): output should end in a newline", file: file, line: line)
        XCTAssertEqual(string.filter { $0 == "\n" }.count, 1,
                       "\(label): should be one object on one line, got \(string)", file: file, line: line)
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("\(label): not a JSON object: \(string)", file: file, line: line)
            return [:]
        }
        return object
    }

    // MARK: - text

    /// The listing a terminal reads: the same bytes the builder inside `main` produced, minus the
    /// escape `--list` no longer emits. Both backdrop-hint variants are pinned — `N` when the
    /// fallback display list was the one `--display` numbers, `<n>` when it was not.
    func testTheTextListingIsTheBytesTheTerminalHasAlwaysRead() {
        XCTAssertEqual(ListOutput.text(displays: displays, windows: windows), """
        [0] display 2  1440x2560 pt
        [1] display 1  1512x982 pt
            window 83  @0,0 1440x2560  app=  title=Display 2 Backstop  (backdrop — use --display 0)
            window 679  @-1512,950 1512x949  app=Google Chrome  title=Pull requests · zzjcool/krd
            window 935  @-1175,993 100x21  app=Google Chrome  title=-

        """)
    }

    /// The index-less variant: a backdrop window whose covered display is not in the list
    /// `--display` numbers prints `<n>` rather than a number nobody can use.
    func testABackdropWithNoKnownDisplaySaysNInsteadOfGuessing() {
        let window = ListWindow(id: 42, app: "Finder", title: "-",
                                frame: CGRect(x: 0, y: 0, width: 1440, height: 2560),
                                display: nil, backdropDisplay: nil, targetable: false)
        XCTAssertEqual(ListOutput.text(displays: [], windows: [window]),
                       "    window 42  @0,0 1440x2560  app=Finder  title=-"
                       + "  (backdrop — use --display <n>)\n")
    }

    /// The hint is the display a backdrop **covers**, not the one its centre is on.
    ///
    /// These are two different questions and a real window can answer them differently: a desktop
    /// window inset by the menu bar has its centre on the display it almost covers, but one that
    /// straddles two displays does not. Text has to keep printing the number it printed before
    /// issue #124 (the `--display` that captures a picture instead of a black frame), so the record
    /// carries both numbers and each format reads its own.
    func testTheBackdropHintNamesTheCoveredDisplayNotTheCentreOne() {
        let straddling = ListWindow(id: 7, app: "Finder", title: "-",
                                    frame: CGRect(x: -400, y: 0, width: 1400, height: 900),
                                    display: 0, backdropDisplay: 1, targetable: false)
        XCTAssertTrue(ListOutput.text(displays: displays, windows: [straddling]).hasSuffix(
            "  app=Finder  title=-  (backdrop — use --display 1)\n"))

        let row = (json(ListOutput.json(displays: displays, windows: [straddling]),
                       label: "list")["windows"] as? [[String: Any]])?.first ?? [:]
        XCTAssertEqual(row["display"] as? Int, 0, "JSON keeps asking where the window is")
    }

    /// Nothing is invented: an empty desktop is an empty listing, not a blank line.
    func testAnEmptyListingIsTheEmptyString() {
        XCTAssertEqual(ListOutput.text(displays: [], windows: []), "")
    }

    /// The escape removal is a decision, not a side effect: `--list` alone paints nothing and owes
    /// the terminal no capability query (#124), while `--list` riding on a path that still paints
    /// (`--replay`, `--mock`) keeps the probe that makes those frames sharp.
    func testOnlyAPureListingSkipsThePlaceholderProbe() throws {
        XCTAssertTrue(Desk.listsOnly(try parseArguments(["krd", "--list", "--json"])))
        XCTAssertTrue(Desk.listsOnly(try parseArguments(["krd", "--list", "--replay", "x"])) == false)
        XCTAssertTrue(Desk.listsOnly(try parseArguments(["krd", "--list", "--mock"])) == false)
        XCTAssertFalse(Desk.listsOnly(try parseArguments(["krd", "--wall"])))
    }

    /// Both keys are present when both lists are empty: a caller that filters on `--json` must not
    /// have to tell "no windows" from "the field moved".
    func testAnEmptyDesktopIsAnEmptyObject() {
        let object = json(ListOutput.json(displays: [], windows: []), label: "list")
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object.keys.sorted(), ["displays", "ok", "windows"])
        XCTAssertEqual((object["displays"] as? [Any])?.count, 0)
        XCTAssertEqual((object["windows"] as? [Any])?.count, 0)
    }

    // MARK: - json

    func testTheJSONListingIsOneObjectWithTheSameRecords() {
        let object = json(ListOutput.json(displays: displays, windows: windows), label: "list")

        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object.keys.sorted(), ["displays", "ok", "windows"])

        let displayRows = object["displays"] as? [[String: Any]] ?? []
        XCTAssertEqual(displayRows.count, 2)
        XCTAssertEqual(displayRows.first?["index"] as? Int, 0)
        XCTAssertEqual(displayRows.first?["id"] as? Int, 2)
        XCTAssertEqual(displayRows.first?["width"] as? Int, 1440)
        XCTAssertEqual(displayRows.first?["height"] as? Int, 2560)
        XCTAssertEqual(displayRows.first?["main"] as? Bool, true)
        XCTAssertEqual(displayRows.last?["main"] as? Bool, false)
        XCTAssertEqual(displayRows.first?.keys.sorted(), ["height", "id", "index", "main", "width"])

        let windowRows = object["windows"] as? [[String: Any]] ?? []
        XCTAssertEqual(windowRows.count, 3)
        XCTAssertEqual(windowRows.first?.keys.sorted(),
                       ["app", "display", "frame", "id", "targetable", "title"])

        // The window `--window` takes, the name and the title the text prints.
        XCTAssertEqual(windowRows[1]["id"] as? Int, 679)
        XCTAssertEqual(windowRows[1]["app"] as? String, "Google Chrome")
        XCTAssertEqual(windowRows[1]["title"] as? String, "Pull requests · zzjcool/krd")
        // ...and the same four digits, in the same order as the row: `@x,y WxH`.
        XCTAssertEqual(windowRows[1]["frame"] as? [Int], [-1512, 950, 1512, 949])
        XCTAssertEqual(windowRows[1]["display"] as? Int, 1)
        XCTAssertEqual(windowRows[1]["targetable"] as? Bool, true)
    }

    /// The prose the text path prints as a hint is a field here: a backdrop is `targetable:false`
    /// plus the display it covers, because that is what the reader has to do about it.
    func testABackdropWindowIsNotTargetableAndNamesItsDisplay() {
        let windowRows = json(ListOutput.json(displays: displays, windows: windows),
                              label: "list")["windows"] as? [[String: Any]] ?? []
        XCTAssertEqual(windowRows[0]["targetable"] as? Bool, false)
        XCTAssertEqual(windowRows[0]["display"] as? Int, 0)
    }

    /// "Not on any display" has to be readable as such, so the key is present and `null` — not
    /// missing, and not `0`, which is a real display.
    func testAWindowOnNoDisplayAnswersNull() {
        let window = ListWindow(id: 9, app: "offscreen", title: "-",
                                frame: CGRect(x: -9000, y: -9000, width: 80, height: 80),
                                display: nil, backdropDisplay: nil, targetable: true)
        let object = json(ListOutput.json(displays: displays, windows: [window]), label: "list")
        let row = (object["windows"] as? [[String: Any]])?.first ?? [:]
        XCTAssertNotNil(row["display"] as? NSNull,
                        "display should be null, got \(String(describing: row["display"]))")
        XCTAssertEqual(row["frame"] as? [Int], [-9000, -9000, 80, 80])
    }

    // MARK: - failures

    /// #123, on the listing path: one object on stdout, the prose on stderr, and the exit code the
    /// caller is handed is the one `error.exit` states.
    func testAFailureIsOneLineDecodableAndExitsWithItsOwnCode() {
        let cases: [(code: String, exit: Int32)] = [("usage", 2), ("permission", 3), ("environment", 4)]
        for (code, status) in cases {
            let output = ListOutput.failure(code: code, exit: status,
                                            message: "the window server said no",
                                            next: "do the thing then re-run")

            XCTAssertEqual(output.exit, status, "\(code): the returned status is the error's")
            XCTAssertEqual(output.stderr, "the window server said no\n", "\(code): prose on stderr")

            let object = json(output.stdout, label: code)
            XCTAssertEqual(object["ok"] as? Bool, false, "\(code)")
            XCTAssertEqual(object.keys.sorted(), ["error", "ok"], "\(code): no stray keys")
            let error = object["error"] as? [String: Any] ?? [:]
            // The key set is pinned: #123's envelope is a contract, so a renamed or extra key is a
            // break, not a nicety.
            XCTAssertEqual(error.keys.sorted(), ["code", "exit", "message", "next"], "\(code)")
            XCTAssertEqual(error["code"] as? String, code)
            XCTAssertEqual(error["exit"] as? Int, Int(status), "\(code): error.exit is the exit code")
            XCTAssertEqual(error["message"] as? String, "the window server said no")
            XCTAssertEqual(error["next"] as? String, "do the thing then re-run")
        }
    }

    /// A refused command line: the sentence a human has always seen, plus the object a program
    /// asked for by typing `--json`.
    func testAUsageFailureKeepsTheSentenceAndAddsTheObject() {
        let output = ListOutput.usageFailure("unknown option \"--nonsense\" (try `krd --help`)")

        XCTAssertEqual(output.stderr, "krd: unknown option \"--nonsense\" (try `krd --help`)\n")
        XCTAssertEqual(output.exit, AXExit.usage.rawValue)

        let object = json(output.stdout, label: "usage")
        let error = object["error"] as? [String: Any] ?? [:]
        XCTAssertEqual(error["code"] as? String, "usage")
        XCTAssertEqual(error["exit"] as? Int, 2)
        XCTAssertEqual(error["message"] as? String,
                       "unknown option \"--nonsense\" (try `krd --help`)")
        // `next` has to lead somewhere: the whole flag surface is behind `krd --help`.
        XCTAssertTrue((error["next"] as? String ?? "").contains("krd --help"),
                      "next should point at `krd --help`, got \(String(describing: error["next"]))")
    }

    // MARK: - the plumbing that feeds the records

    /// `--list --json` is two flags on one branch; neither may swallow the other.
    func testListAndJSONParseTogether() throws {
        let options = try parseArguments(["krd", "--list", "--json"])
        XCTAssertTrue(options.listOnly)
        XCTAssertTrue(options.benchJSON)
    }
}
