import XCTest
@testable import krd

/// The wheel over an open panel (#118). The bug this file exists for: the panel drew its badge
/// (`2-11/11`) and the wheel never moved it, because "the chrome owns this cell" was expressed as
/// "the picture does not cover it" — and with `?1016h` the picture's pixel rect is measured in the
/// terminal's *own* pixel grid, so a wheel anywhere in the pane was a remote-desktop scroll and the
/// panel never saw the pointer.
///
/// These tests drive the two functions the product drives — `Chrome.route` (who owns the cell) and
/// `Chrome.panelScroll` (where the window lands) — with the *numbers* krd gets at 40x15, and they
/// pin the badge the drawer writes out of the same arithmetic. They deliberately do not compare
/// cells inside `Chrome` (the routing must not depend on the cell grid: the wheel runs on the reader
/// thread while the main queue repaints), so a `Chrome()` that has never drawn anything is the
/// fixture.
final class PanelWheelTests: XCTestCase {
    /// A log with more lines than the box at 40x15 can hold — the shape in the report (`2-11/11`).
    private func elevenLineLog() -> ChromeMetrics {
        var m = ChromeMetrics()
        m.logTail = (1...11).map { "line \($0)" }
        return m
    }

    /// 40x15 with a log panel open: one row of picture, the status line, and thirteen rows of box
    /// of which ten are inside (`Chrome.layout`). `panelInsideRows` is the number the badge and the
    /// clamp both count.
    private func logBoxAt40x15() -> ChromeGeometry {
        let pictureRows = Chrome.pictureRows(paneRows: 15, bar: false, panel: .log, chrome: true)
        return Chrome.layout(paneCols: 40, paneRows: 15, imageCols: 40, imageRows: pictureRows,
                             bar: false, dev: true, panel: .log)
    }

    /// The cell size the terminal reported in the session this was found in: a 40x15 pty that
    /// answers 320x3600 px, i.e. 8x240 cells. It is not a plausible laptop cell — it is what the
    /// pty said, and it is exactly why the pixel box could not stand in for the chrome's regions:
    /// krd builds the picture's frame out of these (`mirror grid 40x1 cells at 8x240 px, pane
    /// 40x15, frame 320x3600 px` in that session), so a report over the panel at y ≈ 1800 px is
    /// inside the picture's pixel frame as well as inside the panel.
    private let ptyCell = (w: 8.0, h: 240.0)

    // MARK: the layout the report was filed against

    func testFortyByFifteenLeavesTenRowsOfBoxForTheLog() {
        let geometry = logBoxAt40x15()
        XCTAssertEqual(geometry.imageRows, 1)
        XCTAssertEqual(geometry.statusRow, 1)
        XCTAssertEqual(geometry.panelTop, 2)
        XCTAssertEqual(geometry.panelHeight, 13)
        XCTAssertEqual(geometry.panelInsideRows, 10)
    }

    // MARK: (a) pixel mode

    func testAPixelReportOverThePanelIsThePanelsAndTheWindowMoves() {
        let geometry = logBoxAt40x15()
        let m = elevenLineLog()
        let chrome = Chrome()          // never drawn: the routing may not need the cell grid

        // Where `?1016h` puts a wheel over the box (y = 1800 px, x = 160 px — the middle of the
        // panel in that pty), mapped to cells by the terminal's own cell size: the same division
        // `InputReader.handleMouse` does, and the same pair the transcript logged (`row=8 col=21`).
        let cell = InputReader.cell(forPixel: 160, 1800, cellSize: ptyCell)
        XCTAssertEqual(cell.row, 8)
        XCTAssertEqual(cell.col, 21)
        XCTAssertEqual(chrome.route(row: cell.row, col: cell.col, geometry: geometry), .panel)

        // The guard that used to decide this: the pane's pixel rect, which is what SGR-Pixels
        // reports are in. It says "inside the picture", so the old path posted a desktop scroll.
        let pane = Viewport(pixelWidth: 320, pixelHeight: 3600, cols: 40, rows: 1,
                            sourceRect: CGRect(x: 0, y: 0, width: 320, height: 3600))
        XCTAssertTrue(pane.contains(pixel: 160, 1800))

        // One notch up: the log is read from its end, so it starts on its last window (`2-11/11`)
        // and the notch lands on the first one (`1-10/11`).
        let before = Chrome.panelWindow(.log, m, inside: geometry.panelInsideRows, requested: nil)
        XCTAssertEqual([before.offset, before.total, before.last], [1, 11, 1])
        XCTAssertEqual(Chrome.panelBadge(offset: before.offset, inside: geometry.panelInsideRows,
                                        total: before.total, room: 24), " 2-11/11 ↕ ")

        let up = Chrome.panelScroll(.log, m, inside: geometry.panelInsideRows, requested: nil, by: -1)
        XCTAssertEqual(up, 0)
        let after = Chrome.panelWindow(.log, m, inside: geometry.panelInsideRows, requested: up)
        XCTAssertEqual([after.offset, after.total, after.last], [0, 11, 1])
        XCTAssertEqual(Chrome.panelBadge(offset: after.offset, inside: geometry.panelInsideRows,
                                        total: after.total, room: 24), " 1-10/11 ↕ ")

        // …and one notch back down returns the log to its end, where the stored offset is `nil`
        // again (the tail is re-read every second; a pinned offset would freeze the newest line).
        let down = Chrome.panelScroll(.log, m, inside: geometry.panelInsideRows, requested: up, by: 1)
        XCTAssertNil(down)
        let back = Chrome.panelWindow(.log, m, inside: geometry.panelInsideRows, requested: down)
        XCTAssertEqual([back.offset, back.total, back.last], [1, 11, 1])
    }

    // MARK: (b) cell mode

    func testACellReportOverThePanelDoesTheSame() {
        let geometry = logBoxAt40x15()
        let m = elevenLineLog()
        let chrome = Chrome()
        // A terminal that ignored `?1016h` sends the cell itself: row 6, col 21.
        XCTAssertEqual(chrome.route(row: 6, col: 21, geometry: geometry), .panel)
        XCTAssertEqual(chrome.route(row: 8, col: 21, geometry: geometry), .panel)
        let up = Chrome.panelScroll(.log, m, inside: geometry.panelInsideRows, requested: nil, by: -1)
        XCTAssertEqual(up, 0)
        let shown = Chrome.panelWindow(.log, m, inside: geometry.panelInsideRows, requested: up)
        XCTAssertEqual([shown.offset, shown.total, shown.last], [0, 11, 1])
    }

    // MARK: (c) the picture keeps its scroll

    func testACellOverThePictureIsStillTheRemoteDesktop() {
        let geometry = logBoxAt40x15()
        let chrome = Chrome()
        // Row 1 is the one row of picture: not the chrome's, so the report keeps the viewport path
        // and the wheel still scrolls the mirrored desktop.
        XCTAssertEqual(chrome.route(row: 1, col: 21, geometry: geometry), .picture)
        // The status line is a chrome row, but only a cell that carries a `hit` id is a control:
        // an undrawn chrome has no ids, so this is "nobody's" and must not swallow the report.
        XCTAssertEqual(chrome.route(row: 2, col: 21, geometry: geometry), .picture)
        // The panel's reserved rect reaches the pane's last row (`panelHeight` is what the layout
        // gave up for it), even though the drawer stops one row short of it: a wheel there still
        // belongs to the panel, and the clamp is what keeps it from scrolling into a blank window.
        XCTAssertEqual(chrome.route(row: 15, col: 21, geometry: geometry), .panel)
        // And the rectangle is not "everything below the picture": left and right of nothing, but a
        // column outside the pane is not a panel cell either.
        XCTAssertEqual(chrome.route(row: 6, col: 41, geometry: geometry), .picture)
    }

    // MARK: (d) a taller pane

    func testAt80x24TheLogFitsAndTheWheelHasNowhereToGo() {
        let pictureRows = Chrome.pictureRows(paneRows: 24, bar: false, panel: .log, chrome: true)
        let geometry = Chrome.layout(paneCols: 80, paneRows: 24, imageCols: 80, imageRows: pictureRows,
                                     bar: false, dev: true, panel: .log)
        XCTAssertEqual(geometry.panelInsideRows, 11)
        let m = elevenLineLog()
        // The box holds all eleven rows, so the badge is empty (nothing is hidden) and a notch at
        // either end is a no-op rather than a blank window.
        XCTAssertEqual(Chrome.panelBadge(offset: 0, inside: geometry.panelInsideRows, total: 11,
                                         room: 60), "")
        XCTAssertNil(Chrome.panelScroll(.log, m, inside: geometry.panelInsideRows, requested: nil, by: -1))
        XCTAssertNil(Chrome.panelScroll(.log, m, inside: geometry.panelInsideRows, requested: nil, by: 1))
        // And the route still says panel: the box is the box, whether or not it can scroll.
        XCTAssertEqual(Chrome().route(row: geometry.panelTop + 1, col: 40, geometry: geometry), .panel)
    }
}
