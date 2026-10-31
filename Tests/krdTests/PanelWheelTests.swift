import XCTest
@testable import krd

/// The wheel over an open panel (#118). The bug this file exists for: the panel drew its badge
/// (`2-11/11`) and the wheel never moved it, because "the chrome owns this cell" was expressed as
/// "the picture does not cover it" — and with `?1016h` the picture's pixel rect is measured in the
/// terminal's *own* pixel grid, so a wheel anywhere in the pane was a remote-desktop scroll and the
/// panel never saw the pointer.
///
/// These tests drive the three functions the product drives — `InputReader.chromeCell` (is this
/// report offered to the chrome at all, and as what cell), `Chrome.route` (who owns that cell) and
/// `Chrome.panelScroll` (where the window lands) — with the *numbers* krd gets at 40x15, and they
/// pin the badge the drawer writes out of the same arithmetic. `route` answers from the table the
/// drawer built, so the fixtures that ask it paint the frame first (`painted`): the frame a report is
/// made over is the frame that answers it, and a pane nothing has painted yet has claimed no control
/// (issue #200).
final class PanelWheelTests: XCTestCase {
    /// The frame a report is made over, as the drawer paints it: a `Chrome` answers `route` out of the
    /// widgets its last `draw` registered, so a fixture that never drew has an empty table to ask —
    /// which is the honest state of a pane nothing has painted, not a stand-in for this one.
    private func painted(_ geometry: ChromeGeometry, _ m: ChromeMetrics,
                         panel: ChromePanel = .log) -> Chrome {
        let chrome = Chrome()
        _ = chrome.draw(geometry: geometry, metrics: m, state: ChromeState(panel: panel))
        return chrome
    }

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

    /// The cell the routing divides by in the pty this was reproduced in: a 40x15 pane whose
    /// `ws_xpixel`/`ws_ypixel` are 320x240, which `TermGeometry.cellSize` turns into 8x16
    /// (`ws_xpixel / cols`, `ws_ypixel / rows`). That division is what makes px(160,112) row 8 of a
    /// fifteen-row pane — the middle of the open box, as the debug log of that session shows
    /// (`row=8 col=21`).
    ///
    /// It is *not* the cell size the `krd: mirror grid …` line prints. That line reports the fit's
    /// cell, computed against the picture's row budget — with one picture row the same pty prints
    /// `8x240 px`, i.e. 320/40 and 240/1, not 240/15. Reading that `240` as the cell is how the
    /// routing came to be measured in the wrong units; the wheel divides by `ttyCell`.
    private let ttyCell = (w: 8.0, h: 16.0)
    /// That pty's picture frame (`krd: mirror grid 40x1 cells at 8x240 px … frame 320x240 px`). With
    /// `?1016h` a report over the panel is inside it — the whole bug (#118).
    private let pictureFrame = (w: 320, h: 240)

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
        let chrome = painted(geometry, m)      // the frame the report is made over

        // Where `?1016h` puts a wheel over the box: px(160, 112), the middle of the open panel in
        // the 40x15 pty, mapped to cells by the terminal's own cell size — the same division
        // `InputReader.chromeCell` does, and the same pair the transcript logged (`row=8 col=21`).
        let cell = InputReader.cell(forPixel: 160, 112, cellSize: ttyCell)
        XCTAssertEqual(cell.row, 8)
        XCTAssertEqual(cell.col, 21)
        XCTAssertEqual(chrome.route(row: cell.row, col: cell.col, geometry: geometry), .panel)

        // The guard that used to decide this: the pane's pixel rect, which is what SGR-Pixels
        // reports are in. It says "inside the picture", so the old path posted a desktop scroll.
        let pane = Viewport(pixelWidth: pictureFrame.w, pixelHeight: pictureFrame.h, cols: 40,
                            rows: 1, sourceRect: CGRect(x: 0, y: 0, width: pictureFrame.w,
                                                        height: pictureFrame.h))
        XCTAssertTrue(pane.contains(pixel: 160, 112))

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

    // MARK: (c) the decision step itself — what `handleMouse` asks before the viewport guards

    /// The pre-guard, driven through the one function `handleMouse` calls (`InputReader.chromeCell`),
    /// so this test stands or falls with the routing being in the reader at all: it is not a second
    /// copy of the arithmetic living only in the tests.
    func testThePreGuardOffersThePanelCellAndNotThePicture() {
        let geometry = logBoxAt40x15()
        let chrome = painted(geometry, elevenLineLog())
        func owns(_ row: Int, _ col: Int) -> Bool {
            chrome.route(row: row, col: col, geometry: geometry) != .picture
        }

        // pixel mode (`?1016h`): px(160,112) is row 8, col 21 at the tty's 8x16 cell, and row 8 is
        // inside the open box — `owns` says yes and the panel takes the report.
        let overPanel = InputReader.chromeCell(row: 112, col: 160, pixelMouse: true, wheel: -1,
                                               cellSize: ttyCell, owns: owns)
        XCTAssertEqual(overPanel?.row, 8)
        XCTAssertEqual(overPanel?.col, 21)

        // The same pixel report one row up: py 8 is row 1, the single row of picture in this
        // geometry, so the route says `.picture` and the chrome is not offered the report at all —
        // the desktop keeps its scroll.
        XCTAssertEqual(InputReader.cell(forPixel: 160, 8, cellSize: ttyCell).row, 1)
        XCTAssertNil(InputReader.chromeCell(row: 8, col: 160, pixelMouse: true, wheel: -1,
                                            cellSize: ttyCell, owns: owns))

        // Cell mode: a terminal that ignored `?1016h` sends the cell itself, and it is passed
        // through un-divided — row 6 is the box, row 1 is the picture.
        XCTAssertEqual(InputReader.chromeCell(row: 6, col: 21, pixelMouse: false, wheel: -1,
                                              cellSize: ttyCell, owns: owns)?.row, 6)
        XCTAssertNil(InputReader.chromeCell(row: 1, col: 21, pixelMouse: false, wheel: -1,
                                            cellSize: ttyCell, owns: owns))
    }

    // MARK: (b) cell mode

    func testACellReportOverThePanelDoesTheSame() {
        let geometry = logBoxAt40x15()
        let m = elevenLineLog()
        let chrome = painted(geometry, m)
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
        let chrome = painted(geometry, elevenLineLog())
        // Row 1 is the one row of picture: not the chrome's, so the report keeps the viewport path
        // and the wheel still scrolls the mirrored desktop.
        XCTAssertEqual(chrome.route(row: 1, col: 21, geometry: geometry), .picture)
        // The status line next to it is a chrome row with no control on it, so the route says
        // `.background` — nothing to click, and since #200 the cell is nobody's rather than dead (it
        // used to be `.picture`, which no arm of the click path acted on).
        XCTAssertEqual(chrome.route(row: 2, col: 21, geometry: geometry), .background)
        // The box the drawer painted stops one row short of the pane's last row (writing that cell
        // arms the terminal's pending-wrap), so the last row is the chrome's background and not the
        // panel: a wheel there is swallowed rather than scrolling a box that was never drawn. The
        // rows the box does cover are the panel's — that is the wheel tests' assertion, above.
        XCTAssertEqual(chrome.route(row: 14, col: 21, geometry: geometry), .panel)
        XCTAssertEqual(chrome.route(row: 15, col: 21, geometry: geometry), .background)
        // And the route is not "everything below the picture": a column outside the pane is nobody's.
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
        XCTAssertEqual(painted(geometry, m).route(row: geometry.panelTop + 1, col: 40, geometry: geometry),
                       .panel)
    }
}
