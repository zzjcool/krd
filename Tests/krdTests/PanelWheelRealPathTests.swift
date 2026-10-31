import XCTest
@testable import krd
@testable import krdcore

/// The wheel over an open panel, driven through the **product's own path** (#118).
///
/// `PanelWheelTests` pins the pieces — `InputReader.chromeCell`, `Chrome.route`, `Chrome.panelWindow`
/// — but a previous gate found the feature did not work in a real terminal, and none of those
/// pieces could have said so: each of them was individually correct while the thing the reader calls
/// (`Desk.chromeClick`) still routed by `Chrome.hitTest` (which ignores the wheel), still took the
/// viewport path first in pixel mode, and still had to survive a hop to the main queue before
/// `scrollPanel` ran. So these tests start where the reader starts and end at the bytes the drawer
/// writes:
///
///     InputReader.chromeCell  →  Desk.chromeClick  →  (main queue)  →  Desk.scrollPanel  →  drawer
///
/// Each of the four is the real function, called with the numbers a real 40x15 pty produces
/// (px(160,112) is row 8 col 21 at that terminal's own 8x16 cell; the cell-mode report is row 6).
/// The assertion in both modes is the same two-part one: the *stored* offset — the thing the next
/// notch and the next repaint both read — moved, and the badge the drawer emitted for it changed
/// from `2-11/11` to `1-10/11`. "Up one notch then down one notch" has to come back to the end.
final class PanelWheelRealPathTests: XCTestCase {
    /// The 40x15 pty's own cell, `ws_xpixel/cols` and `ws_ypixel/rows` (320/40, 240/15) — the
    /// division `InputReader.cell(forPixel:)` makes and the one the report's `row=8 col=21` came
    /// from. Deliberately *not* the fit's cell: with one picture row the mirror line prints 8x240.
    private let ttyCell = (w: 8.0, h: 16.0)
    private let inside = 10        // rows inside the box at 40x15 (Chrome.layout, measured below)

    /// A `Desk` in the state the product is in when the pointer is over an open log panel: `--dev`
    /// with `--dev-panel log`, the geometry `applyLayout` computes for 40x15, and the eleven-line
    /// log that produces the `2-11/11` badge from the report.
    ///
    /// Everything a notch is about to touch is the product's own (`chromeGeometry`, `chromeMetrics`,
    /// `chromeState`); nothing is stubbed but the terminal.
    private func deskWithLogPanel() -> (Desk, () -> [UInt8]) {
        var options = Options()
        options.wall = false        // `Options` defaults to the wall; this is the mirror
        options.dev = true          // `--dev`: the status line and the panels
        options.mock = true
        options.devPanel = "log"
        let desk = Desk(options: options)

        // What the drawer would be handed: `Chrome.pictureRows` for this pane, then `Chrome.layout`.
        // Built here through the same two calls `applyLayout` makes, so a change to either moves
        // this fixture with it instead of leaving it testing a geometry the product never builds.
        let pictureRows = Chrome.pictureRows(paneRows: 15, bar: false, panel: .log, chrome: true)
        desk.chromeGeometry = Chrome.layout(paneCols: 40, paneRows: 15, imageCols: 40,
                                            imageRows: pictureRows, bar: false, dev: true,
                                            panel: .log)
        desk.chromeMetrics.logTail = (1...11).map { "line \($0)" }

        // The drawer's bytes, so the assertion can be on what a reader would see rather than on a
        // number that happens to feed it.
        var drawn: [UInt8] = []
        desk.writer.sink = { drawn.append(contentsOf: $0) }
        return (desk, { drawn })
    }

    /// Let the main queue run. `chromeClick` hops to it before touching the window (the reader is
    /// on its own thread), so this is part of the path, not test scaffolding: a test that skipped
    /// the hop would pass on a version where `scrollPanel` never ran at all.
    private func drainMainQueue() {
        let drained = expectation(description: "the main queue has run everything queued so far")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    /// The drawer's bytes replayed onto a 40x15 grid, the way a terminal replays them: `CUP` moves
    /// the cursor, `SGR` changes nothing this test reads, printable text lands under the cursor.
    ///
    /// A replay rather than a substring search because the drawer *diffs*: the second notch emits
    /// `CUP row 3 col 22` + `"2"` and `CUP row 3 col 25` + `"1"`, not the string `2-11/11`. The
    /// screen is the only honest reading of what the reader would see, and it is the same reading
    /// the pty transcript in the PR body makes.
    private func screen(_ bytes: [UInt8]) -> [String] {
        let cols = 40, rows = 15
        var grid = [[Character]](repeating: [Character](repeating: " ", count: cols), count: rows)
        let stream = Array(String(decoding: bytes, as: UTF8.self))
        var row = 0, col = 0, i = 0
        while i < stream.count {
            if stream[i] == "\u{1B}", i + 1 < stream.count {
                if stream[i + 1] == "[" {
                    var j = i + 2
                    var params = ""
                    while j < stream.count, !(stream[j] >= "@" && stream[j] <= "~") {
                        params.append(stream[j]); j += 1
                    }
                    if j < stream.count, stream[j] == "H" {          // CUP: row;col, both 1-based
                        let parts = params.split(separator: ";").map { Int($0) ?? 1 }
                        row = (parts.first ?? 1) - 1
                        col = (parts.count > 1 ? parts[1] : 1) - 1
                    }
                    i = j + 1
                    continue
                }
                i += 2
                continue
            }
            if row >= 0, row < rows, col >= 0, col < cols { grid[row][col] = stream[i] }
            col += 1
            i += 1
        }
        return grid.map { String($0) }
    }

    /// The badge on the open box's top border, off the replayed screen. `""` when no panel row has
    /// a count on it at all, which is itself a failure the assertion message names.
    private func drawnBadge(_ bytes: [UInt8]) -> String {
        screen(bytes).first { $0.contains("/11") } ?? ""
    }

    // MARK: the fixture is the pane the report was filed against

    func testTheFixtureIsTheFortyByFifteenPaneOfTheReport() {
        let (desk, _) = deskWithLogPanel()
        let geometry = try! XCTUnwrap(desk.chromeGeometry)
        XCTAssertEqual(geometry.imageRows, 1)
        XCTAssertEqual(geometry.panelTop, 2)
        XCTAssertEqual(geometry.panelInsideRows, inside)
        // And the badge the panel opens with: read from its end, so the last ten of eleven rows.
        let open = Chrome.panelWindow(.log, desk.chromeMetrics, inside: inside, requested: nil)
        XCTAssertEqual(open.offset, 1)
        XCTAssertEqual(Chrome.panelBadge(offset: open.offset, inside: inside, total: open.total,
                                         room: 24), " 2-11/11 ↕ ")
    }

    // MARK: (a) pixel mode — `?1016h`, a report in the terminal's device pixels

    func testPixelWheelOverTheOpenPanelMovesItsWindowInBothDirections() {
        let (desk, drawn) = deskWithLogPanel()

        // The reader's own decision, with the reader's own function: px(160,112) is inside the
        // open box, and it is offered to the desktop only if `chromeOwns` says the cell is nobody's.
        let up = try! XCTUnwrap(InputReader.chromeCell(row: 112, col: 160, pixelMouse: true,
                                                       wheel: -1, cellSize: ttyCell,
                                                       owns: desk.chromeOwns),
                                "a pixel wheel over the panel must be offered to the chrome")
        XCTAssertEqual(up.row, 8)
        XCTAssertEqual(up.col, 21)

        // …and the desk takes it. One notch up: the log starts at its end (`2-11/11`), so up is
        // the first window (`1-10/11`), and the *stored* offset is where it landed.
        desk.chromeClick(row: up.row, col: up.col, wheel: -1)
        drainMainQueue()
        XCTAssertEqual(desk.chromeState.panelOffset, 0, "the notch was swallowed before scrollPanel")
        XCTAssertTrue(drawnBadge(drawn()).contains("1-10/11"),
                          "the drawer did not repaint on the new window: got \(drawnBadge(drawn()))")

        // One notch back down: the end again, stored as `nil` so the log keeps following its tail.
        let down = try! XCTUnwrap(InputReader.chromeCell(row: 112, col: 160, pixelMouse: true,
                                                         wheel: 1, cellSize: ttyCell,
                                                         owns: desk.chromeOwns))
        desk.chromeClick(row: down.row, col: down.col, wheel: 1)
        drainMainQueue()
        XCTAssertNil(desk.chromeState.panelOffset)
        XCTAssertTrue(drawnBadge(drawn()).contains("2-11/11"),
                      "the badge did not follow the log back to its end: got \(drawnBadge(drawn()))")

        // A third notch: the clamp, driven through the product. The end is the end.
        desk.chromeClick(row: down.row, col: down.col, wheel: 1)
        drainMainQueue()
        XCTAssertNil(desk.chromeState.panelOffset)
    }

    // MARK: (b) cell mode — a terminal that ignored `?1016h` and sends the cell

    func testCellWheelOverTheOpenPanelMovesItsWindowInBothDirections() {
        let (desk, drawn) = deskWithLogPanel()

        // Cell mode hands over the cell itself: row 6, col 21 is inside the box. No division, and
        // the same desk, the same `chromeClick`, the same `scrollPanel`.
        let up = try! XCTUnwrap(InputReader.chromeCell(row: 6, col: 21, pixelMouse: false,
                                                       wheel: -1, cellSize: ttyCell,
                                                       owns: desk.chromeOwns))
        XCTAssertEqual(up.row, 6)
        XCTAssertEqual(up.col, 21)

        desk.chromeClick(row: up.row, col: up.col, wheel: -1)
        drainMainQueue()
        XCTAssertEqual(desk.chromeState.panelOffset, 0)
        XCTAssertTrue(drawnBadge(drawn()).contains("1-10/11"),
                      "the drawer did not repaint on the new window: got \(drawnBadge(drawn()))")

        let down = try! XCTUnwrap(InputReader.chromeCell(row: 6, col: 21, pixelMouse: false,
                                                         wheel: 1, cellSize: ttyCell,
                                                         owns: desk.chromeOwns))
        desk.chromeClick(row: down.row, col: down.col, wheel: 1)
        drainMainQueue()
        XCTAssertNil(desk.chromeState.panelOffset)
        XCTAssertTrue(drawnBadge(drawn()).contains("2-11/11"),
                      "the badge did not follow the log back to its end: got \(drawnBadge(drawn()))")
    }

    // MARK: (c) the picture keeps its scroll — the thing the fix must not break

    func testBothModesStillLeaveThePictureToTheDesktopWithNoPanelOpen() {
        // No panel: the pane is picture, status line, and nothing else. A wheel there is the
        // remote desktop's, in both report modes — `chromeOwns` has to say no, or `handleMouse`
        // would hand it to `chromeClick` and the mirrored app would stop scrolling.
        for pixelMouse in [true, false] {
            var options = Options()
            options.wall = false
            options.dev = true
            options.mock = true
            let desk = Desk(options: options)
            desk.writer.sink = { _ in }
            let pictureRows = Chrome.pictureRows(paneRows: 15, bar: false, panel: nil, chrome: true)
            desk.chromeGeometry = Chrome.layout(paneCols: 40, paneRows: 15, imageCols: 40,
                                                imageRows: pictureRows, bar: false, dev: true,
                                                panel: nil)

            // The picture's own row at the top of the pane, in each mode's own coordinates: a cell
            // report says row 1, a pixel report says py 8 at the tty's 8x16 cell. Either way the
            // reader divides it the same way it divides a panel report -- and lands on the picture.
            let inPicture = InputReader.cell(forPixel: pixelMouse ? 160 : 21,
                                             pixelMouse ? 8 : 1, cellSize: ttyCell)
            XCTAssertEqual(inPicture.row, 1)
            XCTAssertNil(InputReader.chromeCell(row: inPicture.row, col: inPicture.col,
                                                pixelMouse: false, wheel: -1,
                                                cellSize: ttyCell, owns: desk.chromeOwns),
                         "pixelMouse=\(pixelMouse): row 1 is the picture, so the desktop keeps the notch")
            XCTAssertFalse(desk.chromeOwns(row: inPicture.row, col: inPicture.col),
                           "pixelMouse=\(pixelMouse): row \(inPicture.row) is the picture")
        }
    }

    // MARK: (e) a press the chrome takes keeps its whole gesture

    /// The third commit of this PR, and the one a unit test of `Chrome` alone cannot see: a press
    /// the chrome is offered never reaches the remote desktop, and in pixel mode *neither may the
    /// rest of its gesture* — the drag and the release would otherwise arrive as
    /// `leftMouseDragged`/`leftMouseUp` with no `leftMouseDown` before them, leaving a mirrored app
    /// holding a button it never saw pressed. Drives `InputReader.handleMouse` — the one function
    /// the reader's byte loop calls for a mouse report — with the three reports of one gesture.
    func testAPressThePanelTakesOwnsItsMotionAndItsRelease() {
        // No tty in a test binary, and `handleMouse` latches "these are pixels" when a coordinate
        // exceeds the grid it last read: pin the grid this pane really has, so a cell report is
        // read as cells and this test measures the routing rather than the latch.
        let saved = TermGeometry.lastGrid
        TermGeometry.lastGrid = (cols: 40, rows: 15)
        defer { TermGeometry.lastGrid = saved }

        let (desk, _) = deskWithLogPanel()
        desk.writer.sink = { _ in }
        var clicks: [(row: Int, col: Int, wheel: Int)] = []
        // `forward: false` is the no-tty half of the reader: the routing runs, the injection does
        // not. Everything under test is before that gate.
        let reader = InputReader(viewport: { Viewport(pixelWidth: 320, pixelHeight: 240, cols: 40,
                                                      rows: 1,
                                                      sourceRect: CGRect(x: 0, y: 0, width: 320,
                                                                         height: 240)) },
                                 dryRun: true, forward: false) {}
        reader.chromeOwns = { [desk] row, col in desk.chromeOwns(row: row, col: col) }
        reader.onChromeClick = { clicks.append((row: $0, col: $1, wheel: $2)) }

        func report(_ code: Int, _ x: Int, _ y: Int,
                    motion: Bool = false, release: Bool = false) -> MouseReport {
            MouseReport(button: code & 3, x: x, y: y, isWheel: (code & 64) != 0,
                        isRelease: release, isMotion: motion, mods: Modifiers(rawValue: 0))
        }

        // Press on the box (row 6, col 21), drag across it, release somewhere else entirely.
        XCTAssertFalse(reader.chromePressInFlight, "nothing in flight before the gesture")
        reader.handleMouse(report(0, 21, 6))
        XCTAssertTrue(reader.chromePressInFlight, "the press went to the chrome")
        reader.handleMouse(report(32, 30, 6, motion: true))
        XCTAssertTrue(reader.chromePressInFlight, "the drag is part of the same gesture")
        reader.handleMouse(report(0, 30, 6, release: true))
        XCTAssertFalse(reader.chromePressInFlight, "the release ended the gesture")

        XCTAssertEqual(clicks.count, 1, "only the press is the chrome's; the gesture is not a second click")
        XCTAssertEqual(clicks.first?.row, 6)
        XCTAssertEqual(clicks.first?.col, 21)

        // The release ended it: a fresh press on the picture's one row is the desktop's, and it is
        // not swallowed by a flag the previous gesture left set.
        reader.handleMouse(report(0, 21, 1))
        XCTAssertEqual(clicks.count, 1, "row 1 is the picture, so the chrome must not hear about it")
        XCTAssertFalse(reader.chromePressInFlight, "a press that is not the chrome's clears the flag")
    }

    // MARK: (d) a wall click is not a panel click

    func testAnUndrawnChromeOwnsNothingSoTheStatusLineStillFallsThrough() {
        let (desk, _) = deskWithLogPanel()
        // The status line is a chrome row, but a cell with no button drawn on it is nobody's: the
        // rectangle is the *panel's*, and widening it to "everything below the picture" is the
        // bug `route` exists to avoid.
        XCTAssertFalse(desk.chromeOwns(row: 2, col: 1))
        // And a notch that is not over the box is not the panel's either, so the desktop keeps it.
        XCTAssertTrue(desk.chromeOwns(row: 15, col: 21), "the box reaches the pane's last row")
        XCTAssertFalse(desk.chromeOwns(row: 1, col: 21), "row 1 is the picture")
    }
}
