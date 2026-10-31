import XCTest
@testable import krd
import krdcore

/// The chrome layer is the one part of krd allowed to write text to the tty, which means every
/// invariant it breaks is a corrupted picture rather than a cosmetic bug. Each test here is a
/// failure that actually happened while the layer was being built:
///
/// - a status line painted *over* the placement rect (the dock appeared on top of the bar);
/// - a panel whose bottom-right corner landed on the last cell, arming pending-wrap so the next
///   byte scrolled the whole grid and every placement shifted by a row;
/// - a newline in a "harmless" text write, which scrolled the picture away.
final class ChromeTests: XCTestCase {
    // MARK: byte-level helpers (no regex: the escapes are simpler than the literal syntax)

    /// Every `ESC [ row ; col H` in a byte stream, 1-based.
    private func cursorMoves(_ bytes: [UInt8]) -> [(row: Int, col: Int)] {
        var out: [(Int, Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0x1B, bytes[i + 1] == 0x5B {
                var j = i + 2
                var digits = ""
                var end: Int? = nil
                while j < bytes.count {
                    let b = bytes[j]
                    if b == UInt8(ascii: "H") { end = j; break }
                    if (b >= 0x30 && b <= 0x39) || b == UInt8(ascii: ";") {
                        digits.append(Character(UnicodeScalar(b)))
                        j += 1
                        continue
                    }
                    break
                }
                if let end, !digits.isEmpty {
                    let parts = digits.split(separator: ";").compactMap { Int($0) }
                    if parts.count == 2 { out.append((parts[0], parts[1])) }
                    i = end + 1
                    continue
                }
            }
            i += 1
        }
        return out
    }

    /// The printable text written to `row`, reading forward from the last write that starts it.
    private func textOnRow(_ bytes: [UInt8], row: Int) -> String {
        var text = ""
        var i = 0
        var onRow = false
        while i < bytes.count {
            if bytes[i] == 0x1B {
                // position?
                if i + 1 < bytes.count, bytes[i + 1] == 0x5B {
                    var j = i + 2
                    var digits = ""
                    while j < bytes.count, (bytes[j] >= 0x30 && bytes[j] <= 0x39) || bytes[j] == UInt8(ascii: ";") {
                        digits.append(Character(UnicodeScalar(bytes[j])))
                        j += 1
                    }
                    if j < bytes.count, bytes[j] == UInt8(ascii: "H") {
                        let parts = digits.split(separator: ";").compactMap { Int($0) }
                        onRow = parts.count == 2 && parts[0] == row
                        i = j + 1
                        continue
                    }
                }
                i += 1
                continue
            }
            if onRow { text.append(Character(UnicodeScalar(bytes[i]))) }
            i += 1
        }
        return text
    }

    /// Replay the positioned writes into a full text grid of `cols` columns and `rows` lines -- the
    /// same second opinion `WallCanvasTests.replay` gives the wall. `cursorMoves` says the escapes are
    /// there and `textOnRow` reads one row forward; this one says what a terminal would end up
    /// showing, including a write that lands on a row another write already painted.
    private func grid(_ bytes: [UInt8], cols: Int, rows: Int) -> [[Character]] {
        var cells = [Character](repeating: " ", count: cols * rows)
        /// True for the second cell of a wide glyph: it is covered by the character before it.
        var covered = [Bool](repeating: false, count: cols * rows)
        var row = 1, col = 1
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x1B, i + 1 < bytes.count, bytes[i + 1] == 0x5B {
                var j = i + 2
                while j < bytes.count, !(bytes[j] >= 0x40 && bytes[j] <= 0x7E) { j += 1 }
                if j < bytes.count, bytes[j] == UInt8(ascii: "H") {
                    let parts = String(decoding: bytes[(i + 2)..<j], as: UTF8.self)
                        .split(separator: ";").compactMap { Int($0) }
                    if parts.count == 2 { row = parts[0]; col = parts[1] }
                }
                i = j + 1
                continue
            }
            // One run of text: up to the next escape, decoded as a whole so a multi-scalar
            // character stays in one piece.
            var j = i
            while j < bytes.count, bytes[j] != 0x1B { j += 1 }
            for ch in String(decoding: bytes[i..<j], as: UTF8.self) {
                let width = DisplayWidth.of(ch)
                if width == 0 { continue }
                guard row >= 1, row <= rows, col >= 1, col + width - 1 <= cols else { continue }
                cells[(row - 1) * cols + (col - 1)] = ch
                covered[(row - 1) * cols + (col - 1)] = false
                if width == 2 { covered[(row - 1) * cols + col] = true }
                col += width
            }
            i = j
        }
        var out: [[Character]] = []
        for y in 0..<max(0, rows) {
            var line: [Character] = []
            for x in 0..<max(0, cols) where !covered[y * cols + x] { line.append(cells[y * cols + x]) }
            if line.count < cols { line.append(contentsOf: repeatElement(" ", count: cols - line.count)) }
            out.append(line)
        }
        return out
    }

    /// The panel's three text columns. `line(_:_:_:note:)` writes them at 0-based 2, 17 and 38, so a
    /// slice per column is exactly what the row shows -- and a label that another write painted over
    /// comes back blank or wrong here, which is the point. A row narrower than the note column has no
    /// columns at all. A row whose glyphs are not all one cell wide cannot be sliced by `Character`
    /// index at all, and reading the neighbouring cells silently would make an assertion pass for the
    /// wrong reason -- `ChromeMetrics` carries user strings (`recording`, `logPath`, `envSwitches`),
    /// so this has to fail loudly instead.
    private func columns(_ row: [Character]) -> (label: String, value: String, note: String) {
        // Measured in cells, not in `Character`s: a row of 38 characters can still be 39 cells wide.
        let cells = DisplayWidth.of(String(row))
        guard cells >= 39 else { return ("", "", "") }
        XCTAssertEqual(cells, row.count,
                       "a wide glyph makes array index != cell index here: \(String(row))")
        // A row of the box ends in its right border, which belongs to the box, not to the note
        // column: without this the note reads `TIOCOUTQ unavailable on this tty    │`.
        let end = row.last == "│" ? row.count - 1 : row.count
        return (String(row[2..<16]).trimmingCharacters(in: .whitespaces),
                String(row[17..<38]).trimmingCharacters(in: .whitespaces),
                String(row[38..<max(38, end)]).trimmingCharacters(in: .whitespaces))
    }

    /// Draw the stats panel and replay it onto a pane-sized grid. `panelRows` are the box's inside
    /// rows -- empty when the panel does not fit and `drawPanel` draws nothing. The clamps mirror the
    /// panel's own two (`h > 2, cols > 8`) and its height clamp (`rows - 1 - panelTop`: never the
    /// final row, autowrap), so a size sweep gets "no box" instead of a range that traps
    /// (`Range requires lowerBound <= upperBound`) or a bottom border `╰───╯` handed back as a row.
    private func drawStatsPanel(cols: Int, paneRows: Int, imageRows: Int, _ m: ChromeMetrics)
        -> (rows: [[Character]], panelRows: Range<Int>) {
        let geo = Chrome.layout(paneCols: cols, paneRows: paneRows, imageCols: cols, imageRows: imageRows,
                                panel: .stats)
        let bytes = Chrome().draw(geometry: geo, metrics: m, state: ChromeState(panel: .stats))
        let rows = grid(bytes, cols: geo.cols, rows: geo.rows)
        let top = geo.panelTop
        let h = min(geo.panelHeight, geo.rows - 1 - top)   // what drawPanel actually draws
        guard h > 2, geo.cols > 8 else { return (rows, (top + 1)..<(top + 1)) }
        return (rows, (top + 1)..<(top + h - 1))
    }

    /// The `--dev` status line as a string, read back from the same grid: `textOnRow` does not consume
    /// SGR, so its output carries `[1;97m` debris and a failing assertion becomes unreadable.
    private func statusLine(cols: Int, _ m: ChromeMetrics) -> String {
        let geo = Chrome.layout(paneCols: cols, paneRows: 20, imageCols: cols, imageRows: 19, panel: nil)
        let bytes = Chrome().draw(geometry: geo, metrics: m, state: ChromeState())
        return String(grid(bytes, cols: geo.cols, rows: geo.rows)[geo.statusRow])
    }

    private func metrics(cols: Int = 137) -> ChromeMetrics {
        var m = ChromeMetrics()
        m.target = "display 0 3024×1964"
        m.fpsTarget = 20
        m.fps = 19.4
        m.mbps = 3.2
        m.e2eMs = 54
        m.cellsW = cols
        m.cellsH = 44
        return m
    }

    /// The encoder row has to say what `--quality` is doing: a picture that looks soft because a
    /// number is wrong is the hardest kind of bug to see from the outside.
    func testStatsPanelNamesTheQualityAndTheTileCounts() {
        var m = metrics()
        m.quality = 50
        m.qualityLabel = "4-4-4"
        m.quantisedTiles = 41
        m.skippedTiles = 3
        let geo = Chrome.layout(paneCols: 137, paneRows: 75, imageCols: 137, imageRows: 44,
                                panel: .stats)
        let text = String(decoding: Chrome().draw(geometry: geo, metrics: m,
                                                 state: ChromeState(panel: .stats)),
                          as: UTF8.self)
        XCTAssertTrue(text.contains("q50 4-4-4"), "the encoder row must name the rung")
        XCTAssertTrue(text.contains("quantised 41"), "and how many tiles it actually applied to")
        XCTAssertTrue(text.contains("raw 3"), "and how many are being sent raw")
    }

    /// The default has to read as the thing krd has always done, not as a new mode.
    func testDefaultQualityReadsAsFiveSixFive() {
        let m = metrics()
        XCTAssertEqual(m.quality, 80)
        XCTAssertEqual(m.qualityLabel, "5-6-5")
    }

    /// The picture owns every row above the status line; the chrome owns everything below it.
    func testStatusLineSitsDirectlyUnderThePicture() {
        let geo = Chrome.layout(paneCols: 137, paneRows: 60, imageCols: 137, imageRows: 43, panel: nil)
        XCTAssertEqual(geo.statusRow, 43)
        XCTAssertEqual(geo.chromeTop, 43)
        XCTAssertEqual(geo.panelHeight, 0)
        XCTAssertLessThanOrEqual(geo.statusRow + 1, geo.rows)
    }

    /// A panel that fits takes the rows under the bar, never any of the picture's rows.
    func testPanelOpensUnderTheStatusLine() {
        let geo = Chrome.layout(paneCols: 137, paneRows: 75, imageCols: 137, imageRows: 44,
                                panel: .stats)
        XCTAssertEqual(geo.panelTop, 45)
        XCTAssertEqual(geo.panelHeight, ChromePanel.stats.height)
        XCTAssertEqual(geo.imageRows, 44, "the panel must not eat picture rows that already fit")
    }

    /// When the pane has no slack the layout is what shrinks the picture, not the panel drawing
    /// over it — so there is no full-screen mode to get wrong.
    func testPanelNeverOverlapsThePicture() {
        for paneRows in [12, 20, 34, 60, 75] {
            for panel in ChromePanel.allCases {
                let imageRows = max(1, paneRows - 1 - panel.height)
                let geo = Chrome.layout(paneCols: 100, paneRows: paneRows, imageCols: 100,
                                        imageRows: imageRows, panel: panel)
                XCTAssertLessThanOrEqual(geo.panelTop, geo.panelHeight > 0 ? geo.rows - 1 : geo.panelTop)
                XCTAssertGreaterThanOrEqual(geo.panelTop, geo.imageRows + 1)
                XCTAssertLessThanOrEqual(geo.panelTop + geo.panelHeight, geo.rows)
            }
        }
    }

    /// Every drawn byte is positioned, no newline is ever emitted, and the final cell of the final
    /// row is left alone. Rendering into a 40x12 pane is the worst case: the panel bottom border
    /// lands on the last row.
    func testRenderedBytesArePositionedAndAvoidTheFinalCell() {
        let chrome = Chrome()
        var m = metrics(cols: 40)
        m.cellsH = 11
        for panel in [nil] + ChromePanel.allCases.map(Optional.init) {
            let geo = Chrome.layout(paneCols: 40, paneRows: 12, imageCols: 40,
                                    imageRows: max(1, 11 - (panel?.height ?? 0)), panel: panel)
            let bytes = chrome.draw(geometry: geo, metrics: m, state: ChromeState(panel: panel))
            let text = String(decoding: bytes, as: UTF8.self)
            XCTAssertFalse(text.contains("\n"), "a newline scrolls the grid: \(panel?.rawValue ?? "none")")
            XCTAssertFalse(text.contains("\r"), "a carriage return moves the cursor home")
            for move in cursorMoves(bytes) {
                XCTAssertGreaterThanOrEqual(move.row, geo.chromeTop + 1,
                                            "text above the picture in \(panel?.rawValue ?? "none")")
                XCTAssertFalse(move.row == geo.rows && move.col == geo.cols,
                               "the final cell arms pending-wrap")
            }
        }
    }

    /// A narrow pane loses segments instead of wrapping them onto the row below the picture.
    func testStatusLineDegradesByWidth() {
        func bar(_ cols: Int) -> String {
            let geo = Chrome.layout(paneCols: cols, paneRows: 20, imageCols: cols, imageRows: 19,
                                    panel: nil)
            let bytes = Chrome().draw(geometry: geo, metrics: metrics(cols: cols), state: ChromeState())
            return textOnRow(bytes, row: 20)
        }
        // >= 84: target, fps, MB/s, latency, menu
        XCTAssertTrue(bar(120).contains("display 0"))
        XCTAssertTrue(bar(120).contains("MB/s"))
        // 46..83: the target goes first, the rates stay
        XCTAssertFalse(bar(60).contains("display 0"), "the target segment is the first to go")
        XCTAssertTrue(bar(60).contains("fps"))
        XCTAssertTrue(bar(60).contains("MB/s"))
        // 30..45: latency and the menu only
        XCTAssertFalse(bar(40).contains("MB/s"))
        XCTAssertTrue(bar(40).contains("ms"))
        // 20..29: fps and latency
        XCTAssertTrue(bar(24).contains("fps"))
        XCTAssertTrue(bar(24).contains("ms"))
    }

    /// Clicking the bar is the primary way in, so a segment's widget must line up with what is drawn.
    func testTheStatusLineSegmentsAreWidgets() {
        let chrome = Chrome()
        let geo = Chrome.layout(paneCols: 120, paneRows: 40, imageCols: 120, imageRows: 39, panel: nil)
        _ = chrome.draw(geometry: geo, metrics: metrics(cols: 120), state: ChromeState())
        var found: Set<String> = []
        for col in 1...120 {
            if case .widget(let id) = chrome.route(row: geo.statusRow + 1, col: col, geometry: geo) {
                found.insert(id)
            }
        }
        // The two segments that open the stats panel carry their own ids, so a hover lights the one
        // number the pointer is on and not both (#200).
        XCTAssertTrue(found.contains("bandwidth"))
        XCTAssertTrue(found.contains("latency"))
        XCTAssertTrue(found.contains("help"))
        XCTAssertTrue(found.contains("target"))
        XCTAssertEqual(chrome.route(row: 1, col: 1, geometry: geo), .picture,
                       "a cell inside the picture must not be reported as chrome")
    }

    // MARK: the stats panel's rows (#117)

    /// The sparklines were positioned with `y + 9`, which is the `pty buffer` row: their label
    /// painted over that row's name while its value and note survived at columns 17 and 38
    /// (0-based). The row has to keep all three columns at every size where the panel has 10 inside
    /// rows.
    func testTheStatsPanelKeepsThePtyBufferRowForItsOwnNumber() {
        var m = metrics()
        m.queueBytes = 1024
        m.drainMbps = 3.4
        for (cols, paneRows, imageRows) in [(80, 24, 8), (137, 44, 27)] {
            let (rows, panelRows) = drawStatsPanel(cols: cols, paneRows: paneRows, imageRows: imageRows, m)
            let named = panelRows.filter { columns(rows[$0]).label == "pty buffer" }
            XCTAssertEqual(named.count, 1, "\(cols)x\(paneRows): the pty-buffer row lost its name")
            guard let i = named.first else { continue }
            XCTAssertTrue(columns(rows[i]).value.contains("1024 B"),
                          "\(cols)x\(paneRows): value column reads \"\(columns(rows[i]).value)\"")
            XCTAssertTrue(columns(rows[i]).note.contains("sshd took"),
                          "\(cols)x\(paneRows): note column reads \"\(columns(rows[i]).note)\"")
            for r in panelRows where ["MB/s", "pipe"].contains(columns(rows[r]).label) {
                XCTAssertFalse(columns(rows[r]).note.contains("sshd"),
                               "\(cols)x\(paneRows): a sparkline row carries another row's note")
            }
        }
    }

    /// One number per row. A hand-written row index can land on a row another line already took, and
    /// then two numbers share a `y` while one inside row is left blank. With every optional row on,
    /// no inside row may be blank and no label may appear twice. The pane is tall enough for the full
    /// 16-row panel, so `inside` is 14 and `recording` -- the last row this panel can draw, since
    /// `log` and `env` sit at indices 14/15 and `ChromePanel.stats.height` is 16 -- is exercised.
    func testEveryStatsRowOwnsOneLineOfThePanel() {
        var m = metrics()
        m.queueBytes = 1024
        m.mbpsHistory = [1, 2, 3, 4, 5, 6, 7, 8]
        m.latencyHistory = [2, 4, 6, 8, 6, 4, 2, 1]
        m.inputActive = true
        m.recording = "recorded 01:02 to /tmp/krd.mov"
        m.logPath = "/tmp/krd.log"
        m.envSwitches = "KRD_NO_RTT=1 KRD_GRID=1"
        m.devices = ["* display 0 1920x1200", "  window 42 -- Terminal"]
        let (rows, panelRows) = drawStatsPanel(cols: 137, paneRows: 60, imageRows: 8, m)
        let labels = panelRows.map { columns(rows[$0]).label }
        XCTAssertEqual(labels.count, 14, "the panel's `inside` is height - 2")
        XCTAssertFalse(labels.contains(""), "an inside row is blank: a row was skipped or overwritten")
        XCTAssertEqual(Set(labels).count, labels.count, "two rows share a label: \(labels)")
        // The range itself: without this pin an off-by-one in `statsPanel` would count the bottom
        // border as a row and the test above would keep passing while `recording` was never drawn.
        XCTAssertTrue(String(rows[panelRows.lowerBound - 1]).hasPrefix("╭"),
                      "the row above the range must be the box's top border")
        XCTAssertTrue(String(rows[panelRows.upperBound]).hasPrefix("╰"),
                      "the row at the range's end must be the box's bottom border")
    }

    /// On `--mock`/`--replay`/`--selftest` `e2e` is the pipe half alone (there is no PTS to subtract),
    /// so `frame 0 ms` claimed an end-to-end measurement nobody made, in the same row whose note
    /// said `cap — (no PTS)`.
    func testTheFrameRowSaysItWasNotMeasuredWhenTheCaptureHalfIsMissing() {
        var m = metrics()
        m.capMs = -1
        m.e2eMs = 0
        let (rows, panelRows) = drawStatsPanel(cols: 137, paneRows: 44, imageRows: 27, m)
        let frame = panelRows.map { columns(rows[$0]) }.first { $0.label == "frame" }
        XCTAssertEqual(frame?.value, "— ms", "the frame row must not print a confident 0")
        XCTAssertEqual(frame?.note.hasPrefix("cap — (no PTS)"), true,
                       "and the cap half still says why: \(frame?.note ?? "-")")
        let bar = statusLine(cols: 120, m)
        XCTAssertTrue(bar.contains("pipe 0 ms"), "the bar names the number for what it is: \(bar)")
        XCTAssertFalse(bar.contains("frame 0 ms"), "nothing was measured end to end: \(bar)")
    }

    /// The measured mirror keeps today's number and today's name: `frame` is `cap + pipe`, and
    /// `54` is what it always printed.
    func testTheFrameRowKeepsItsNumberWhenTheCaptureHalfIsMeasured() {
        var m = metrics()
        m.capMs = 40
        m.e2eMs = 54
        let (rows, panelRows) = drawStatsPanel(cols: 137, paneRows: 44, imageRows: 27, m)
        let frame = panelRows.map { columns(rows[$0]) }.first { $0.label == "frame" }
        XCTAssertEqual(frame?.value, "54 ms")
        XCTAssertTrue(statusLine(cols: 120, m).contains("frame 54 ms"))
    }

    /// The issue is "every size where `inside > 9`", so the arithmetic has to hold at every height,
    /// not at the one the captures happened to use: from 13 pane rows there is an inside row, and at
    /// each size the range must sit between the two borders, carry a label on every row and never
    /// repeat one. A hand-written row index shows up here as a blank row or as a row on a border.
    func testNoStatsRowLandsOnTheBoxAtAnyHeight() {
        var m = metrics()
        m.queueBytes = 1024
        m.mbpsHistory = [1, 2, 3, 4, 5, 6, 7, 8]
        m.latencyHistory = [8, 7, 6, 5, 4, 3, 2, 1]
        m.inputActive = true
        for paneRows in 11...30 {
            let (rows, panelRows) = drawStatsPanel(cols: 137, paneRows: paneRows, imageRows: 8, m)
            guard !panelRows.isEmpty else {
                // `drawPanel` needs `h > 2`: with less room it draws nothing at all, and the rows
                // under the status line stay blank rather than holding half a box.
                let drawn = rows[9...].filter { !String($0).trimmingCharacters(in: .whitespaces).isEmpty }
                XCTAssertTrue(drawn.isEmpty, "\(paneRows) rows: something was drawn without room for it")
                continue
            }
            XCTAssertTrue(String(rows[panelRows.lowerBound - 1]).hasPrefix("╭"),
                          "\(paneRows) rows: the row above the range is not the top border")
            XCTAssertTrue(String(rows[panelRows.upperBound]).hasPrefix("╰"),
                          "\(paneRows) rows: the range ends on the bottom border")
            // A border is not a row: both of them carry solid `─` across the value column, so any
            // text there means something was drawn on the box. `hasPrefix` alone cannot see that --
            // a row written on the bottom border starts at column 2 and leaves the corner glyph
            // intact, which is exactly how an off-by-one in `line`'s `i < inside` would look.
            for border in [panelRows.lowerBound - 1, panelRows.upperBound] where rows[border].count > 38 {
                XCTAssertEqual(String(rows[border][17..<38]), String(repeating: "─", count: 21),
                               "\(paneRows) rows: a row is drawn on the border at \(border): "
                               + String(rows[border]))
            }
            let labels = panelRows.map { columns(rows[$0]).label }
            XCTAssertFalse(labels.contains(""), "\(paneRows) rows: an inside row is blank: \(labels)")
            XCTAssertEqual(Set(labels).count, labels.count, "\(paneRows) rows: two rows share a label")
        }
        // The two shapes that used to trap the helper (`Range requires lowerBound <= upperBound`):
        // a pane too short for any box, and a layout with no room for a panel at all (`panelHeight`
        // 0). Both must report "nothing drawn" rather than a backwards range.
        XCTAssertTrue(drawStatsPanel(cols: 80, paneRows: 11, imageRows: 8, m).panelRows.isEmpty,
                      "80 columns and 11 rows: no box, so no rows")
        XCTAssertTrue(drawStatsPanel(cols: 137, paneRows: 44, imageRows: 43, m).panelRows.isEmpty,
                      "panelHeight 0: no box, so no rows")
    }

    /// The width ladder has two rungs for the new name: at 84 columns the bar has room for
    /// `pipe`/`frame`, at 83 it prints the bare number, and nothing may call an unmeasured sum
    /// `frame` -- that name is what made `frame 0 ms` read as a measured end to end.
    func testTheLatencySegmentIsNamedOnlyWhereTheBarHasRoom() {
        var unmeasured = metrics()
        unmeasured.capMs = -1
        unmeasured.e2eMs = 0
        XCTAssertTrue(statusLine(cols: 84, unmeasured).contains("pipe 0 ms"),
                      "84 columns is where the bar has room for a name: \(statusLine(cols: 84, unmeasured))")
        XCTAssertFalse(statusLine(cols: 84, unmeasured).contains("frame"),
                       "nothing was measured end to end, so the bar must not say `frame`")
        let narrow = statusLine(cols: 83, unmeasured)
        XCTAssertTrue(narrow.contains("0 ms"), "the number stays at 83 columns: \(narrow)")
        XCTAssertFalse(narrow.contains("pipe"), "no room for a name at 83 columns: \(narrow)")
        XCTAssertFalse(narrow.contains("frame"), "no room for a name at 83 columns: \(narrow)")
        var measured = metrics()
        measured.capMs = 40
        measured.e2eMs = 54
        XCTAssertTrue(statusLine(cols: 84, measured).contains("frame 54 ms"),
                      "a measured mirror keeps the number and the name: \(statusLine(cols: 84, measured))")
    }

    /// `queueBytes = -1` is the tty that cannot answer `TIOCOUTQ`: the row has to say so, and it
    /// still owns exactly one line -- the collision left the row under `pipe` blank, so "the row
    /// below the pty row is the next number" is the pin.
    func testThePtyRowSaysWhenTheTtyCannotReportItsBuffer() {
        var m = metrics()
        m.queueBytes = -1
        m.mbpsHistory = [1, 2, 3]
        let (rows, panelRows) = drawStatsPanel(cols: 137, paneRows: 60, imageRows: 8, m)
        let labels = panelRows.map { columns(rows[$0]).label }
        let named = panelRows.map { columns(rows[$0]) }.filter { $0.label == "pty buffer" }
        XCTAssertEqual(named.count, 1, "the pty row must own exactly one line")
        XCTAssertEqual(named.first?.value, "—", "no buffer is not a zero-byte buffer")
        XCTAssertEqual(named.first?.note, "TIOCOUTQ unavailable on this tty")
        guard let i = labels.firstIndex(of: "pty buffer") else { return XCTFail("no pty row") }
        XCTAssertEqual(labels[i + 1], "MB/s", "the row under the pty row is blank: a row was left over")
    }

    // MARK: the rows a box cannot hold (#118)

    /// Draw one panel the way `applyLayout` would, and replay it onto a pane-sized grid. `offset` is
    /// the wheel's position (nil = where the panel is read from), and `inside` is the box's content
    /// rows as the geometry publishes them -- the number the wheel clamps against.
    private func panelGrid(_ panel: ChromePanel, cols: Int, paneRows: Int, imageRows: Int,
                           offset: Int? = nil, _ m: ChromeMetrics)
        -> (rows: [[Character]], geo: ChromeGeometry, inside: Range<Int>) {
        let geo = Chrome.layout(paneCols: cols, paneRows: paneRows, imageCols: cols,
                                imageRows: imageRows, panel: panel)
        var state = ChromeState(panel: panel)
        state.panelOffset = offset
        let bytes = Chrome().draw(geometry: geo, metrics: m, state: state)
        let rows = grid(bytes, cols: geo.cols, rows: geo.rows)
        let first = geo.panelTop + 1
        return (rows, geo, first..<(first + geo.panelInsideRows))
    }

    // MARK: what the renderer writes

    /// One draw of one panel, as bytes -- for the cases that are about what was *written*.
    private func chromeDraw(_ geo: ChromeGeometry, _ m: ChromeMetrics, _ state: ChromeState) -> [UInt8] {
        Chrome().draw(geometry: geo, metrics: m, state: state)
    }

    /// The border badge: `1-10/16 ↕` when the box holds ten of the panel's sixteen rows, nothing
    /// when it holds them all. It is how a squeezed panel stops dropping rows in silence.
    private func badge(_ row: [Character]) -> String {
        let text = String(row)
        guard let up = text.range(of: "↕") else { return "" }
        let token = text[text.startIndex..<up.lowerBound].split(separator: " ").last.map(String.init)
        guard let token else { return "" }
        return "\(token) ↕"
    }

    /// 40x15 is the size the issue reproduces at: the box holds ten rows, so the panel used to draw
    /// eight of sixteen and say nothing. Now the border carries the window and every row it does
    /// draw is one of its own -- no blank row, no label twice, and the order is the panel's.
    func testASqueezedPanelSaysWhichRowsItIsShowing() {
        var m = metrics(cols: 40)
        m.queueBytes = 1024
        m.mbpsHistory = [1, 2, 3, 4]
        m.latencyHistory = [4, 3, 2, 1]
        m.inputActive = true
        let (rows, geo, inside) = panelGrid(.stats, cols: 40, paneRows: 15, imageRows: 1, m)
        XCTAssertEqual(inside.count, 10, "40x15: the box holds ten content rows")
        XCTAssertEqual(badge(rows[geo.panelTop]), "1-10/16 ↕",
                       "the top border must say which rows these are and how many there are: "
                       + String(rows[geo.panelTop]))
        let labels = inside.map { columns(rows[$0]).label }
        XCTAssertEqual(labels, ["bandwidth", "frames", "frame", "rtt", "encoder", "capture",
                                "geometry", "wire", "pty buffer", "MB/s"],
                       "the window starts at the panel's first row, in its own order")
        XCTAssertFalse(labels.contains(""), "an inside row is blank: \(labels)")
        XCTAssertTrue(String(rows[inside.upperBound]).hasPrefix("╰"), "the bottom border survives")
    }

    /// The rows a squeezed box does not hold have to be reachable: every notch of the wheel moves
    /// the window one row, the last one lands on the last row, and between them they cover all
    /// sixteen. `log` and `env` are the two rows no box height could ever reach before (#117's own
    /// test says so: `ChromePanel.stats.height` is 16 and `inside` is height - 2).
    func testTheWheelReachesEveryStatsRow() {
        var m = metrics(cols: 40)
        m.queueBytes = 1024
        m.recording = "off"
        m.logPath = "/tmp/k.log"
        m.envSwitches = "none"
        var seen: [String] = []
        var offsets: [Int] = []
        for offset in 0...6 {
            let (rows, geo, inside) = panelGrid(.stats, cols: 40, paneRows: 15, imageRows: 1,
                                                offset: offset, m)
            offsets.append(offset)
            XCTAssertEqual(badge(rows[geo.panelTop]), "\(offset + 1)-\(offset + inside.count)/16 ↕",
                           "the badge must follow the window: \(String(rows[geo.panelTop]))")
            seen += inside.map { columns(rows[$0]).label }
        }
        XCTAssertEqual(Set(seen).count, 16, "the seven windows cover the panel's sixteen rows: \(seen)")
        XCTAssertTrue(seen.contains("log"), "the `log` row was unreachable")
        XCTAssertTrue(seen.contains("env"), "the `env` row was unreachable")
    }

    /// The window is clamped at both ends by the same arithmetic the drawer uses, so a flick of the
    /// wheel past either end cannot leave the panel blank.
    func testTheWindowStopsAtBothEnds() {
        let m = metrics(cols: 40)
        XCTAssertEqual(Chrome.panelWindow(.stats, m, inside: 10, requested: -5).offset, 0)
        XCTAssertEqual(Chrome.panelWindow(.stats, m, inside: 10, requested: 999).offset, 6)
        XCTAssertEqual(Chrome.panelWindow(.stats, m, inside: 10, requested: nil).offset, 0,
                       "a panel is read from its top")
        var log = m
        log.logTail = (1...12).map { "line \($0)" }
        XCTAssertEqual(Chrome.panelWindow(.log, log, inside: 10, requested: nil).offset, 2,
                       "a log is read from its newest line: the last ten of twelve")
        XCTAssertEqual(Chrome.panelWindow(.log, log, inside: 10, requested: 1).offset, 1,
                       "…and the wheel can go back up to the first of them")
        XCTAssertEqual(Chrome.panelWindow(.log, log, inside: 12, requested: nil).offset, 0,
                       "a box that holds the whole tail is not scrolled")
        // The clamp and the state agree: `last` is where the input path stores its answer.
        XCTAssertEqual(Chrome.panelWindow(.stats, m, inside: 10, requested: nil).last, 6)
        XCTAssertEqual(Chrome.panelWindow(.stats, m, inside: 16, requested: nil).last, 0,
                       "a box that holds every row has nowhere to scroll")
        // Whatever the box and the request, the window stays inside the content: a notch that
        // arrives at either end lands on that end instead of one row past it.
        for inside in [1, 5, 10, 12, 17, 20] {
            for requested in [nil, -5, 0, 3, 6, 99] as [Int?] {
                for panel in [ChromePanel.stats, .log] {
                    let window = Chrome.panelWindow(panel, log, inside: inside, requested: requested)
                    let where_ = "\(panel.rawValue) inside \(inside) requested \(String(describing: requested))"
                    XCTAssertEqual(window.last, max(0, window.total - inside), where_)
                    XCTAssertGreaterThanOrEqual(window.offset, 0, where_)
                    XCTAssertLessThanOrEqual(window.offset, window.last, where_)
                    if inside <= window.total {
                        XCTAssertLessThanOrEqual(window.offset + inside, window.total, where_)
                    }
                }
            }
        }
    }

    /// The log panel's job is the newest lines. It used to take the first `inside` entries of
    /// `readLogTail`'s last-12 window, which is the *oldest* of the twelve: at 40x15 the panel showed
    /// the session's first lines forever, the exact symptom `TROUBLESHOOTING.md` sends people to it
    /// for. The badge says the window is not the whole tail.
    func testTheLogPanelShowsTheNewestLineFirst() {
        var m = metrics(cols: 40)
        m.logTail = (1...12).map { "krd: line \($0)" }
        let (rows, geo, inside) = panelGrid(.log, cols: 40, paneRows: 15, imageRows: 1, m)
        let text = inside.map { String(rows[$0]) }
        XCTAssertTrue(text.contains { $0.contains("krd: line 12") },
                      "the newest line must be on screen: \(text)")
        XCTAssertFalse(text.contains { $0.contains("krd: line 1  ") },
                       "the first of the twelve must be the one scrolled off: \(text)")
        XCTAssertEqual(badge(rows[geo.panelTop]), "3-12/12 ↕",
                       "the border says the window starts at the third line: \(String(rows[geo.panelTop]))")
        XCTAssertTrue(String(rows[inside.upperBound]).hasPrefix("╰"))
    }

    /// …and a box tall enough holds the whole tail, with no badge and nothing cut: the marker only
    /// appears when something really is out of reach.
    /// "A box tall enough holds the whole tail and says nothing" is only worth asserting if the app
    /// can produce that box: a log panel's inside is `height - 3`, so eleven lines is the most that
    /// ever fits at 137x44, and the twelfth is where the marker has to appear. The pane height comes
    /// from `Chrome.pictureRows`, the same function `applyLayout` uses (#118).
    func testTheWholeLogTailFitsWhenTheBoxIsTall() {
        var m = metrics(cols: 137)
        m.logTail = (1...11).map { "krd: line \($0)" }
        let picture = Chrome.pictureRows(paneRows: 44, bar: false, panel: .log, chrome: true)
        let (rows, geo, inside) = panelGrid(.log, cols: 137, paneRows: 44, imageRows: picture, m)
        XCTAssertEqual(inside.count, 11, "eleven rows is what a 44-row pane gives the log panel")
        XCTAssertEqual(badge(rows[geo.panelTop]), "", "nothing is hidden, so there is no marker")
        XCTAssertTrue(inside.map { String(rows[$0]) }.first!.contains("krd: line 1 "),
                      "a tail that fits is shown from its first line")
        XCTAssertTrue(String(rows[inside.upperBound - 1]).contains("krd: line 11"))
        // One more line than the box holds and the same pane starts saying so.
        m.logTail = (1...12).map { "krd: line \($0)" }
        let (tighter, tightGeo, tightInside) = panelGrid(.log, cols: 137, paneRows: 44,
                                                         imageRows: picture, m)
        XCTAssertEqual(badge(tighter[tightGeo.panelTop]), "2-12/12 ↕",
                       "the twelfth line is the one that no longer fits: "
                       + String(tighter[tightGeo.panelTop]))
        XCTAssertTrue(String(tighter[tightInside.first!]).contains("krd: line 2"),
                      "and the line that scrolls off is the oldest")
    }

    /// `line()`'s value column is a cell budget, and a cut is an `…` -- never half a glyph. The
    /// `--dev` panels print strings the user does not control (`--log` path, `--record`, env), so
    /// this is where a CJK path meets a 40-column pane.
    func testAPanelValueIsCutWithAnEllipsisAndNeverMidGlyph() {
        var m = metrics(cols: 40)
        m.logPath = String(repeating: "日志", count: 12)          // 24 two-cell glyphs, 48 cells
        let geo = Chrome.layout(paneCols: 40, paneRows: 20, imageCols: 40, imageRows: 4,
                                panel: .stats)
        var state = ChromeState(panel: .stats)
        state.panelOffset = 14                                     // the window that holds `log`
        let text = String(decoding: Chrome().draw(geometry: geo, metrics: m, state: state),
                          as: UTF8.self)
        // Nine whole glyphs and the ellipsis: 19 of the 20 cells the value column owns. A tenth
        // glyph would be 20 cells and there would be no room for the `…`, so a cut that kept ten
        // would have had to split one.
        XCTAssertTrue(text.contains("日志日志日志日志日…"), "the cut is nine whole glyphs and an ellipsis")
        XCTAssertFalse(text.contains("日志日志日志日志日志"),
                       "ten glyphs are twenty cells and cannot also hold the `…`")
    }

    /// A 2-cell glyph is written as one character, and the terminal advances two columns for it. The
    /// diff renderer used to write the glyph's *covered* cell as a space as well, so every wide glyph
    /// pushed the rest of the row one column right: a CJK `--log` path ran past its column, and the
    /// box's right border was written past the edge of the pane and never appeared.
    func testAWideGlyphOwnsItsTwoCellsAndIsWrittenOnce() {
        var m = metrics(cols: 40)
        m.recording = "日志日志日志"                                  // 6 glyphs, 12 cells
        let geo = Chrome.layout(paneCols: 40, paneRows: 24, imageCols: 40, imageRows: 4,
                                panel: .stats)
        let text = String(decoding: chromeDraw(geo, m, ChromeState(panel: .stats)), as: UTF8.self)
        guard let run = text.range(of: "日志日志日志") else {
            return XCTFail("the six glyphs are not in the stream")
        }
        // The value is written as one run (`line` writes it in one go, one style): six glyphs and
        // nothing between them. The covered cell used to be written too, which made this run
        // `日 志 日 志 日 志` -- eighteen cells for a twelve-cell value.
        let value = String(text[run.lowerBound...].prefix { $0 != "\u{1B}" })
            .trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(value, "日志日志日志", "the covered cell of a wide glyph must not be written")
        XCTAssertEqual(DisplayWidth.of(value), 12, "six glyphs are twelve cells, not eighteen")
    }

    /// `contentRows` is what the badge counts and what the wheel clamps against, so it has to be the
    /// number of rows the panel really has. A row appended to a panel without touching
    /// `contentRows` would be unreachable forever; a count one too high would make the last notch
    /// scroll into a blank window; a count one too low would leave the last row off the border's
    /// count. Every panel is asked here for its *own last row* by name, in a box that fits it and in
    /// one that has to scroll.
    func testEveryPanelCanReachItsLastRowAndCountsTheRowsItHas() {
        var m = metrics(cols: 60)
        m.queueBytes = 0
        m.recording = "off"
        m.logPath = "/tmp/k.log"
        m.envSwitches = "none"
        m.devices = ["* display 0 1920×1200", "  window 42 — Terminal", "  window 43 — x"]
        m.logTail = (1...9).map { "krd: log line \($0)" }
        // (panel, the rows it has, a substring only its last row carries)
        let cases: [(ChromePanel, Int, String)] = [
            (.stats, 16, "env"),
            (.settings, 10, "bold = hot"),
            (.devices, 3, "window 43"),
            (.log, 9, "log line 9"),
            (.help, 11, "--no-chrome"),
        ]
        // A pane tall enough for every panel, and one where the box has three rows: the same claims
        // have to hold at both ends of the ladder.
        for (paneRows, imageRows) in [(30, 2), (8, 1)] {
            for (panel, rows, lastRow) in cases {
                let geo = Chrome.layout(paneCols: 60, paneRows: paneRows, imageCols: 60,
                                        imageRows: imageRows, panel: panel)
                let inside = geo.panelInsideRows
                XCTAssertGreaterThan(inside, 0, "\(panel.rawValue): no box at \(paneRows) rows")
                let window = Chrome.panelWindow(panel, m, inside: inside, requested: nil)
                XCTAssertEqual(window.total, rows,
                               "\(panel.rawValue): contentRows is not the number of rows it has")
                let (offset, _, _) = Chrome.panelWindow(panel, m, inside: inside, requested: rows)
                XCTAssertEqual(offset, max(0, rows - inside),
                               "\(panel.rawValue): the last notch does not land on the last row")
                var state = ChromeState(panel: panel)
                state.panelOffset = offset
                let drawn = grid(Chrome().draw(geometry: geo, metrics: m, state: state),
                                 cols: geo.cols, rows: geo.rows)
                let first = geo.panelTop + 1
                let inner = (first..<(first + inside)).map { String(drawn[$0]) }
                XCTAssertTrue(inner.contains { $0.contains(lastRow) },
                              "\(panel.rawValue) at \(paneRows) rows: the window \(offset)"
                              + "+\(inside) never reaches its last row: \(inner)")
            }
        }
    }

    /// Who gives up the room when a panel does not fit. This is the headline of #118 -- the picture
    /// used to keep three rows whatever the panel cost -- and it is arithmetic, so it is asked
    /// directly instead of through a pty capture: the four sizes the issue and the captures use,
    /// plus the row where a one-row picture stops leaving room for a box at all.
    func testThePanelGetsItsRowsAndThePictureKeepsAStrip() {
        // (pane rows, panel, picture rows)
        let cases: [(Int, ChromePanel?, Int)] = [
            (40, nil, 39),            // no panel: the picture keeps everything the status line leaves
            (40, .stats, 23),         // 40 - 1 status - 16 panel: the panel fits, nothing is taken
            (24, .stats, 7),          // 80x24: the same 7 rows it always had
            (44, .stats, 27),         // 137x44: the same 27 rows it always had
            (18, .stats, 1),          // the first size where stats stops fitting: strip, not three
            (15, .stats, 1),          // 40x15, the issue's size
            (20, .stats, 3),          // still room for three rows of picture and a full panel
            (15, .log, 1),
            (17, .help, 3),           // 1 status + 13 panel + the rest to the picture
            (6, .stats, 1),           // a strip and a three-row box
            (5, .stats, 3),           // too short for a box: the picture keeps its three rows
            (4, .stats, 4),           // below the fitting window entirely
        ]
        for (rows, panel, expected) in cases {
            XCTAssertEqual(Chrome.pictureRows(paneRows: rows, bar: false, panel: panel, chrome: true),
                           expected, "\(rows) rows, \(panel?.rawValue ?? "no panel"): picture rows")
        }
        // The mirror's bar is a row of furniture the picture's share never included.
        XCTAssertEqual(Chrome.pictureRows(paneRows: 44, bar: true, panel: .stats, chrome: true), 26)
        XCTAssertEqual(Chrome.pictureRows(paneRows: 15, bar: true, panel: .stats, chrome: true), 1)
        // --dev off: the picture is the pane, panel or no panel.
        XCTAssertEqual(Chrome.pictureRows(paneRows: 15, bar: false, panel: .stats, chrome: false), 15)
        // A panel never costs the picture more than the panel asks for: 40 rows of pane and a
        // 12-row panel leaves the picture everything the panel cannot use.
        XCTAssertEqual(Chrome.pictureRows(paneRows: 40, bar: false, panel: .settings, chrome: true), 27)
    }

    /// A box narrower than the full badge can say the count in a shorter form instead of saying
    /// nothing: silence on a 26-column pane would be the original bug on the width axis.
    func testANarrowBoxStillSaysHowManyRowsItHolds() {
        var m = metrics(cols: 28)
        // 28 columns: `─ stats ─` ends at 8, ` ^\ q/esc ` starts at 19, so nine cells are free
        // between them -- enough for the count but not for the window.
        let (rows, geo, inside) = panelGrid(.stats, cols: 28, paneRows: 15, imageRows: 1, m)
        XCTAssertEqual(inside.count, 10)
        XCTAssertEqual(badge(rows[geo.panelTop]), "10/16 ↕",
                       "no room for the window, but the count still fits: "
                       + String(rows[geo.panelTop]))
        // …and the wide form comes back as soon as it fits.
        let (wide, wideGeo, _) = panelGrid(.stats, cols: 40, paneRows: 15, imageRows: 1, m)
        XCTAssertEqual(badge(wide[wideGeo.panelTop]), "1-10/16 ↕")
        // One column narrower and there is no room between the title and the two ways out. Pinned
        // so the floor is a decision rather than an accident.
        let (tiny, tinyGeo, _) = panelGrid(.stats, cols: 27, paneRows: 15, imageRows: 1, m)
        XCTAssertEqual(badge(tiny[tinyGeo.panelTop]), "", "27 columns has no room for a marker")
    }

    /// The value column is capped at the note column, not at `w - 20`: a note row's value may not
    /// reach into the cells its note is written in. `wire` carries `m.format` as its value and a
    /// note after it, which is a value long enough to see the cap.
    func testANoteRowsValueStopsOneCellBeforeItsNote() {
        var m = metrics(cols: 80)
        m.format = String(repeating: "x", count: 30)
        let (rows, _, inside) = panelGrid(.stats, cols: 80, paneRows: 20, imageRows: 4, m)
        guard let wire = inside.first(where: { columns(rows[$0]).label == "wire" }) else {
            return XCTFail("the wire row must be in the box")
        }
        XCTAssertEqual(columns(rows[wire]).value, String(repeating: "x", count: 19) + "…",
                       "the value is cut to the note column, with its `…`: "
                       + "\(columns(rows[wire]).value)")
        XCTAssertTrue(columns(rows[wire]).note.hasPrefix("sync"), "and the note starts at column 38")
        // A row *without* a note keeps `w - 20`, which is why `cursor`, `recording`, `log` and
        // `env` are not cut at the note column. `columns()` slices 17..<38 and so cannot show a
        // value wider than that; the drawn stream can.
        m.logPath = String(repeating: "y", count: 30)
        let geo = Chrome.layout(paneCols: 80, paneRows: 20, imageCols: 80, imageRows: 4,
                                panel: .stats)
        var state = ChromeState(panel: .stats)
        state.panelOffset = 6
        let text = String(decoding: chromeDraw(geo, m, state), as: UTF8.self)
        XCTAssertTrue(text.contains(String(repeating: "y", count: 30)),
                      "a note-less value keeps the whole value column")
    }

    /// The note column is `w - 40` cells wide and at 40 columns that is zero: the column does not
    /// exist there, and the row is still a complete line (label and value) rather than a truncated
    /// one. Where it does exist the note is cut with an `…` and never reaches the box.
    func testANoteIsEitherInsideItsColumnOrNotOnTheLineAtAll() {
        var m = metrics(cols: 40)
        m.pxW = 640
        m.pxH = 384
        m.cellsW = 86
        m.cellsH = 27
        m.geometrySource = "--cell"
        let (narrow, _, narrowRows) = panelGrid(.stats, cols: 40, paneRows: 20, imageRows: 4, m)
        guard let geometryRow = narrowRows.first(where: { columns(narrow[$0]).label == "geometry" })
        else { return XCTFail("the geometry row must be in the box") }
        XCTAssertFalse(String(narrow[geometryRow]).contains("cells ·"),
                       "40 columns has no note column, so no note: \(String(narrow[geometryRow]))")
        XCTAssertTrue(columns(narrow[geometryRow]).value.contains("640×384 px"),
                      "and the value it does have is whole: \(columns(narrow[geometryRow]).value)")
        let (wide, _, wideRows) = panelGrid(.stats, cols: 80, paneRows: 20, imageRows: 4, m)
        guard let wideRow = wideRows.first(where: { columns(wide[$0]).label == "geometry" })
        else { return XCTFail("the geometry row must be in the 80-column box too") }
        XCTAssertTrue(columns(wide[wideRow]).note.contains("cells ·"),
                      "80 columns has room for the note: \(columns(wide[wideRow]).note)")
        XCTAssertTrue(columns(wide[wideRow]).note.hasSuffix("…"), "a cut note ends in an ellipsis")
        XCTAssertEqual(wide[wideRow].last, "│",
                       "and never reaches the border: \(String(wide[wideRow]))")
    }

    /// A row whose value gets shorter must lose its tail glyphs. The diff renderer trims a run's
    /// trailing spaces, and it used to do that even for cells that *had* text in the previous frame:
    /// the terminal then kept the old glyph (`0 BB`, `56 tiles/ss` — both visible in the captures
    /// this issue was filed with). A panel cannot be honest about a number it leaves debris beside.
    func testAShorterValueDoesNotLeaveTheLastGlyphBehind() {
        let chrome = Chrome()
        var m = metrics(cols: 60)
        m.queueBytes = 1000                                        // `1000 B`
        let geo = Chrome.layout(paneCols: 60, paneRows: 24, imageCols: 60, imageRows: 4,
                                panel: .stats)
        var stream: [UInt8] = []
        stream += chrome.draw(geometry: geo, metrics: m, state: ChromeState(panel: .stats))
        m.queueBytes = 0                                           // `0 B`, three cells over six
        stream += chrome.draw(geometry: geo, metrics: m, state: ChromeState(panel: .stats))
        let rows = grid(stream, cols: geo.cols, rows: geo.rows)    // replayed as the terminal did
        guard let i = rows.firstIndex(where: { columns($0).label == "pty buffer" }) else {
            return XCTFail("the pty row must be in the box")
        }
        XCTAssertEqual(columns(rows[i]).value, "0 B",
                       "the shorter value left the previous frame's glyphs behind: \""
                       + String(rows[i]) + "\"")
        XCTAssertEqual(columns(rows[i]).note, "0 ms at this rate ·…", "the note column still ends in its `…`")
    }
}

/// The mock source is what makes `--dev` checkable without a screen, so it has to be both
/// deterministic (two runs → the same bytes) and honest about size (a frame that does not match
/// the layout would read past the end of the buffer in `extract`).
final class MockDesktopTests: XCTestCase {
    func testFrameIsDeterministic() {
        let mock = MockDesktop(width: 320, height: 200, bpp: 3, fps: 20) { _, _, _ in }
        XCTAssertEqual(mock.pixels(at: 7), mock.pixels(at: 7))
        XCTAssertNotEqual(mock.pixels(at: 7), mock.pixels(at: 8), "frames must differ or nothing is dirty")
    }

    func testFrameMatchesTheRequestedSizeAndFormat() {
        for (w, h, bpp) in [(320, 200, 3), (60, 40, 3), (321, 201, 4)] {
            let mock = MockDesktop(width: w, height: h, bpp: bpp, fps: 20) { _, _, _ in }
            XCTAssertEqual(mock.pixels(at: 3).count, w * h * bpp)
        }
    }

    /// A frame has to contain the kinds of region the encoder is judged on: flat wallpaper,
    /// high-contrast text-like lines, and a saturated dock.
    func testFrameIsNotUniform() {
        let mock = MockDesktop(width: 400, height: 300, bpp: 3, fps: 20) { _, _, _ in }
        let px = mock.pixels(at: 12)
        let unique = Set(stride(from: 0, to: px.count, by: 3).map { px[$0] })
        XCTAssertGreaterThan(unique.count, 8, "a flat frame would not exercise dirty rects or zlib")
    }
}

/// `String.count` is grapheme clusters, not cells. A Chinese app name in a window title used to
/// shift every column after it, which is why width lives in one place and is tested on its own.
final class DisplayWidthTests: XCTestCase {
    func testAsciiIsOneCell() {
        XCTAssertEqual(DisplayWidth.of("krd --dev"), 9)
        XCTAssertEqual(DisplayWidth.of("…"), 1)
    }

    func testCjkAndEmojiAreTwoCells() {
        XCTAssertEqual(DisplayWidth.of("访达"), 4)
        XCTAssertEqual(DisplayWidth.of("窗口 title"), 4 + 1 + 5)
        XCTAssertEqual(DisplayWidth.of("❤️"), 2, "an emoji presentation selector makes it wide")
        XCTAssertEqual(DisplayWidth.of("👨‍👩‍👧"), 2, "a ZWJ sequence is one 2-cell cluster")
    }

    func testCombiningMarksAddNothing() {
        XCTAssertEqual(DisplayWidth.of("e\u{301}"), 1)
        XCTAssertEqual(DisplayWidth.of("\u{301}"), 0)
    }

    func testTruncateNeverSplitsAGlyph() {
        for cells in 1...10 {
            let out = DisplayWidth.truncate("访问控制面板", to: cells)
            XCTAssertLessThanOrEqual(DisplayWidth.of(out), cells, "\(cells) cells produced \(out)")
        }
        XCTAssertEqual(DisplayWidth.truncate("访问控制", to: 5), "访问…")
        XCTAssertEqual(DisplayWidth.truncate("abc", to: 5), "abc", "no ellipsis when nothing is dropped")
    }

    func testPadIsExactlyTheRequestedWidth() {
        for s in ["abc", "访达", "👨‍👩‍👧 x", ""] {
            for cells in 0...12 {
                XCTAssertEqual(DisplayWidth.of(DisplayWidth.pad(s, to: cells)), cells)
            }
        }
    }

    /// End to end: a pane whose target name is Chinese must not push the bar past the last column
    /// or leave half a glyph at the edge.
    /// A window title is written by whatever app owns the window, so the wall cannot assume it is
    /// one line of printable text: a `\n` in it scrolls the grid the picture is positioned on, and an
    /// `ESC` would let the title emit its own escape sequence.
    func testControlCharactersNeverReachTheGrid() {
        XCTAssertEqual(DisplayWidth.truncate("a\nb", to: 10), "a b")
        XCTAssertEqual(DisplayWidth.truncate("a\u{1B}[2Jb", to: 10), "a [2Jb")
        XCTAssertEqual(DisplayWidth.truncate("tab\there", to: 10), "tab here")
        XCTAssertEqual(DisplayWidth.truncate("bell\u{7}", to: 10), "bell ")
        XCTAssertFalse(DisplayWidth.truncate("x\ny", to: 10).contains("\n"))
    }

    func testWideTargetStaysInsideTheStatusLine() {
        for cols in [20, 24, 30, 46, 80, 84, 120] {
            var m = ChromeMetrics()
            m.target = "访达 — 桌面"
            m.fpsTarget = 20
            m.fps = 19.4
            m.e2eMs = 54
            m.cellsW = cols
            let geo = Chrome.layout(paneCols: cols, paneRows: 20, imageCols: cols, imageRows: 19, panel: nil)
            let bytes = Chrome().draw(geometry: geo, metrics: m, state: ChromeState())
            // Replay the escapes: every glyph must start and end inside the pane, and none may
            // start in the last column unless it is one cell wide.
            var col = 0
            var i = 0
            let text = Array(String(decoding: bytes, as: UTF8.self))
            while i < text.count {
                if text[i] == "\u{1B}" {
                    var j = i + 1
                    var digits = ""
                    if j < text.count, text[j] == "[" {
                        j += 1
                        while j < text.count, text[j].isNumber || text[j] == ";" {
                            digits.append(text[j])
                            j += 1
                        }
                        if j < text.count, text[j] == "H" {
                            let parts = digits.split(separator: ";").compactMap { Int($0) }
                            if parts.count == 2 { col = parts[1] - 1 }
                        }
                        while j < text.count, !text[j].isLetter { j += 1 }
                        i = j + 1
                        continue
                    }
                    i += 1
                    continue
                }
                let w = DisplayWidth.of(text[i])
                if w > 0 {
                    XCTAssertLessThanOrEqual(col + w, cols,
                                             "a glyph overflows at cols=\(cols): \(text[i]) at \(col)")
                    col += w
                }
                i += 1
            }
        }
    }
}

/// Over ssh the interesting part of the path is past `write()`, so the bar carries a wall clock
/// the user can compare against their own — and it must not appear in a pane too narrow for it.
final class ClockTests: XCTestCase {
    private func bar(cols: Int) -> String {
        var m = ChromeMetrics()
        m.target = "display 0"
        m.fpsTarget = 20
        m.fps = 19.4
        m.e2eMs = 54
        m.cellsW = cols
        m.clock = "12:34:56"
        let geo = Chrome.layout(paneCols: cols, paneRows: 20, imageCols: cols, imageRows: 19, panel: nil)
        let bytes = Chrome().draw(geometry: geo, metrics: m, state: ChromeState())
        var text = ""
        var onRow = false
        var i = 0
        let chars = Array(String(decoding: bytes, as: UTF8.self))
        while i < chars.count {
            if chars[i] == "\u{1B}" {
                var j = i + 1
                var digits = ""
                if j < chars.count, chars[j] == "[" {
                    j += 1
                    while j < chars.count, chars[j].isNumber || chars[j] == ";" { digits.append(chars[j]); j += 1 }
                    if j < chars.count, chars[j] == "H", digits == "20;1" { onRow = true } else if j < chars.count, chars[j] == "H" { }
                    while j < chars.count, !chars[j].isLetter { j += 1 }
                    i = j + 1
                    continue
                }
                i += 1
                continue
            }
            if onRow { text.append(chars[i]) }
            i += 1
        }
        return text
    }

    func testClockAppearsAtTheRightEdge() {
        let text = bar(cols: 120)
        XCTAssertTrue(text.contains("12:34:56"))
    }

    func testClockIsDroppedInANarrowPane() {
        XCTAssertFalse(bar(cols: 40).contains("12:34:56"))
    }

    /// The bar names the number for what it is. Since #52 it is `cap + pipe` — the capture half can
    /// be ~50 ms at 10 fps — so calling it `pipe` (as it did before the split existed) would blame
    /// our encoder for the compositor's interval.
    func testTheFrameNumberIsLabelledAsTheWholeFrame() {
        XCTAssertTrue(bar(cols: 120).contains("frame 54 ms"))
        XCTAssertFalse(bar(cols: 120).contains("pipe 54 ms"))
    }
}

/// The mirror's top bar (design §6.8): one reversed row with the window's name and the one control a
/// terminal window can have - shrink back into the wall it came from. It is not the `--dev` status
/// line: that one is a measurement and lives at the bottom, this one is furniture and lives on top.
final class ChromeBarTests: XCTestCase {
    private func geometry(cols: Int = 100, rows: Int = 30, bar: Bool = true, dev: Bool = false,
                          pictureRows: Int = 28) -> ChromeGeometry {
        Chrome.layout(paneCols: cols, paneRows: rows, imageCols: cols,
                      imageRows: (bar ? 1 : 0) + pictureRows, bar: bar, dev: dev, panel: nil)
    }

    private func drawn(_ geometry: ChromeGeometry, title: String = "Terminal — admin — scroll.sh")
        -> (text: String, chrome: Chrome) {
        let chrome = Chrome()
        var metrics = ChromeMetrics()
        metrics.title = title
        metrics.clock = "12:34:56"
        metrics.fps = 18
        metrics.mbps = 1.8
        let bytes = chrome.draw(geometry: geometry, metrics: metrics, state: ChromeState())
        // The bytes are positioned writes: keep the printable ones and drop the escapes.
        var text = ""
        var i = 0
        let chars = Array(String(decoding: bytes, as: UTF8.self))
        var skipping = false
        while i < chars.count {
            let c = chars[i]
            if c == "\u{1B}" { skipping = true; i += 1; continue }
            if skipping {
                if c == "m" || c == "H" { skipping = false }
                i += 1
                continue
            }
            text.append(c)
            i += 1
        }
        return (text, chrome)
    }

    func testTheBarOwnsTheFirstRowAndThePictureStartsUnderIt() {
        let geo = geometry()
        XCTAssertEqual(geo.barRow, 0)
        XCTAssertEqual(geo.imageRows, 1 + 28)
        XCTAssertEqual(geo.statusRow, geo.imageRows, "the dev line would start here, and it is off")
    }

    func testTheBarNamesTheWindowAndOffersTheWayBack() {
        let geo = geometry()
        let (text, _) = drawn(geo)
        XCTAssertTrue(text.contains("Terminal — admin — scroll.sh"))
        XCTAssertTrue(text.contains("[ - ]"), "the shrink button is the whole point of the bar")
        XCTAssertTrue(text.contains("12:34:56"), "the clock is what a macOS menu bar is for")
        XCTAssertTrue(text.contains("18 fps"))
    }

    /// The two boxes are the click target, and the title between them is not.
    func testTheTwoBoxesAreTheTargetAndTheTitleIsNot() {
        let geo = geometry()
        let (_, chrome) = drawn(geo)
        // The right end of the row is the button; the traffic lights on the left do the same thing.
        XCTAssertEqual(chrome.route(row: 1, col: geo.cols - 2, geometry: geo), .widget("shrink"))
        XCTAssertEqual(chrome.route(row: 1, col: 2, geometry: geo), .widget("shrink"))
        // The window's name is drawn between them and is a readout: hovering it lights nothing, and a
        // click on it is nobody's (the row itself is still the chrome's, never the picture's).
        let title = chrome.widgets.first { $0.id == "title" }
        XCTAssertNotNil(title, "the bar draws the window's name")
        if let title {
            XCTAssertEqual(title.role, .furniture)
            XCTAssertEqual(chrome.route(row: 1, col: title.rect.col + 1, geometry: geo), .background)
        }
        // A row that is neither the bar nor the status line belongs to the picture.
        XCTAssertEqual(chrome.route(row: 5, col: 2, geometry: geo), .picture)
    }

    func testTheDevStatusLineIsNotDrawnWhenOnlyTheBarIsOn() {
        let geo = geometry(dev: false)
        let (text, _) = drawn(geo)
        // `target` is the dev line's measurement; it must not appear in window furniture.
        XCTAssertFalse(text.contains("window 128444"))
    }

    func testAPaneTooNarrowForTheRightSideKeepsTheButton() {
        // 24 columns: the clock and the rate are dropped, the button is not - it is the only
        // affordance, and a bar without it is decoration pretending to be a control.
        let geo = geometry(cols: 24, pictureRows: 20)
        let (text, chrome) = drawn(geo)
        XCTAssertTrue(text.contains("[ - ]"))
        XCTAssertFalse(text.contains("12:34:56"))
        XCTAssertEqual(chrome.route(row: 1, col: 22, geometry: geo), .widget("shrink"))
    }
}

/// Issue #87: the bar carries the delay we already measure, and `[ ≡ ]` opens three sliders — colour
/// (the bit depth `--quality` allows), quality (how eagerly the encoder spends it) and fps (1…20).
/// Each tick is a `hit` id on a panel cell, so a click is the whole interaction: no key opens the
/// menu and no key moves a slider (the chord table is somebody else's table, and the bar exists on
/// pages without `--dev`).
final class ChromeMenuTests: XCTestCase {
    private func barText(_ m: ChromeMetrics, cols: Int = 120) -> String {
        let geo = Chrome.layout(paneCols: cols, paneRows: 20, imageCols: cols, imageRows: 18,
                                bar: true, dev: false, panel: nil)
        let bytes = Chrome().draw(geometry: geo, metrics: m, state: ChromeState())
        // Positioned writes, so the printable runs are in order and the escapes between them do not
        // break a `contains`.
        return String(decoding: bytes, as: UTF8.self)
    }

    private func menuMetrics(quality: Int = 80, label: String = "5-6-5", eager: Bool = false,
                             fps: Int = 12) -> ChromeMetrics {
        var m = ChromeMetrics()
        m.title = "Terminal — admin — scroll.sh"
        m.clock = "12:34:56"
        m.fps = 18
        m.mbps = 1.8
        m.rttAvailable = true
        m.rttMs = 38
        m.quality = quality
        m.qualityLabel = label
        m.qualityEager = eager
        m.fpsTarget = fps
        return m
    }

    // MARK: the delay

    /// The bar's delay is the measured round trip, with its unit, and the two "no measurement"
    /// states are the ones `rttLabel` already distinguishes from a zero (issue #87: do not print 0).
    func testTheBarShowsTheMeasuredRoundTripWithItsUnit() {
        let text = barText(menuMetrics())
        XCTAssertTrue(text.contains("38.0 ms"), "the round trip belongs on the bar: \(text)")
        XCTAssertTrue(text.contains("[ ≡ ]"), "and the way into the three sliders")
        XCTAssertTrue(text.contains("1.8 MB/s"), "…next to the rate, as the issue asks")
        XCTAssertTrue(text.contains("12:34:56"), "…and the clock the user compares with their own")

        var off = menuMetrics()
        off.rttAvailable = false
        off.rttMs = .nan
        let unmeasured = barText(off)
        XCTAssertTrue(unmeasured.contains("— ms"), "no probe / no DSR is not a number: \(unmeasured)")
        XCTAssertFalse(unmeasured.contains("0.0 ms"), "a terminal without DSR is a capability, not zero")
        XCTAssertFalse(unmeasured.contains("0 ms"), "a terminal without DSR is a capability, not zero")
    }

    /// The ladder, without a pane: fps > delay > clock > rate (issue #87).
    func testTheBarDropsTheRateBeforeTheDelayAndTheFpsLast() {
        func numbers(_ room: Int) -> String {
            Chrome.barNumbers(room: room, fps: "  18 fps", mbps: "1.8 MB/s", delay: "38.0 ms",
                              clock: "12:34:56")
        }
        XCTAssertEqual(numbers(200), "  18 fps · 1.8 MB/s · 38.0 ms · 12:34:56")
        XCTAssertEqual(numbers(30), "  18 fps · 38.0 ms · 12:34:56", "the rate goes first")
        XCTAssertEqual(numbers(26), "  18 fps · 38.0 ms", "then the clock")
        XCTAssertEqual(numbers(8), "  18 fps", "the delay outlives the clock; fps never leaves")
        XCTAssertEqual(numbers(0), "", "no room is no numbers, not a clipped one")
    }

    // MARK: the menu

    /// Every tick is a control and everything else in the box is still the panel's (the wheel needs
    /// it), which is the one thing this route change could have broken.
    func testEveryMenuTickIsAClickTargetAndTheRestOfTheBoxIsStillThePanels() {
        let geo = Chrome.layout(paneCols: 120, paneRows: 30, imageCols: 120, imageRows: 20,
                                bar: true, dev: true, panel: .menu)
        let chrome = Chrome()
        _ = chrome.draw(geometry: geo, metrics: menuMetrics(), state: ChromeState(panel: .menu))
        var ids: Set<String> = []
        var panelCells = 0
        for row in (geo.panelTop + 1)...(geo.panelTop + geo.panelHeight) {
            for col in 1...geo.cols {
                switch chrome.route(row: row, col: col, geometry: geo) {
                case .widget(let id): ids.insert(id)
                case .panel: panelCells += 1
                case .background, .picture: XCTFail("row \(row) col \(col) is inside the box")
                }
            }
        }
        // The tick each axis is currently on, one id per drawn cell of the track.
        XCTAssertTrue(ids.contains("rung:colour:2"), "80 is 5-6-5, the third rung: \(ids)")
        XCTAssertTrue(ids.contains("rung:quality:0"), "guarded: \(ids)")
        XCTAssertTrue(ids.contains("rung:fps:11"), "12 fps is step 11: \(ids)")
        XCTAssertTrue(ids.contains("rung:colour:4"), "the lossless end is reachable: \(ids)")
        XCTAssertTrue(ids.contains("rung:fps:19"), "…and so is 20 fps: \(ids)")
        XCTAssertFalse(ids.contains("rung:fps:20"), "the track stops at the documented maximum")
        XCTAssertGreaterThan(panelCells, 0, "the label column still belongs to the panel")
    }

    /// The bar's way in is a control like `[ - ]`, on the bar's own row.
    func testTheBarOffersTheMenuNextToTheWayOut() {
        let geo = Chrome.layout(paneCols: 120, paneRows: 20, imageCols: 120, imageRows: 18,
                                bar: true, dev: false, panel: nil)
        let chrome = Chrome()
        _ = chrome.draw(geometry: geo, metrics: menuMetrics(), state: ChromeState())
        var found: Set<String> = []
        for col in 1...geo.cols {
            if case .widget(let id) = chrome.route(row: 1, col: col, geometry: geo) {
                found.insert(id)
            }
        }
        XCTAssertEqual(found, ["shrink", "menu"], "the bar has exactly two controls: \(found)")
    }

    /// What a click means: one table, so a tick cannot draw one value and set another.
    func testTheTracksAreClampedToTheDocumentedRanges() {
        XCTAssertEqual(ChromeAxis.colourValues, [50, 70, 80, 90, 100])
        XCTAssertEqual(ChromeAxis.colourStep(for: 80), 2)
        XCTAssertEqual(ChromeAxis.colourStep(for: 100), 4)
        XCTAssertEqual(ChromeAxis.colourStep(for: 0), 0)
        XCTAssertEqual(ChromeAxis.colourValue(step: 0), 50)
        XCTAssertEqual(ChromeAxis.colourValue(step: 99), 100, "a step past the end is the end")
        XCTAssertEqual(ChromeAxis.fpsValue(step: 0), 1)
        XCTAssertEqual(ChromeAxis.fpsValue(step: 19), 20)
        XCTAssertEqual(ChromeAxis.fpsValue(step: 99), 20)
        // …and the two halves of `--quality` are separate: the same number, guarded or eager.
        XCTAssertEqual(QualityBudget(80).eager, false)
        XCTAssertEqual(QualityBudget(80, eager: true).eager, true)
        XCTAssertEqual(QualityBudget(80, eager: true).label, "5-6-5", "eager is not a bit depth")
        XCTAssertEqual(QualityBudget(70).eager, true, "the rung's own default is unchanged")
    }

    /// A squeezed pane keeps the tracks it can draw and drops ticks, never draws text past the box.
    func testANarrowBoxShrinksTheTrackInsteadOfTheBorder() {
        for cols in [30, 40, 60, 100] {
            let geo = Chrome.layout(paneCols: cols, paneRows: 30, imageCols: cols, imageRows: 20,
                                    bar: true, dev: true, panel: .menu)
            let bytes = Chrome().draw(geometry: geo, metrics: menuMetrics(),
                                      state: ChromeState(panel: .menu))
            let text = String(decoding: bytes, as: UTF8.self)
            XCTAssertFalse(text.contains("\n"), "a newline scrolls the picture away at \(cols) cols")
        }
    }

    // MARK: the blocker of the rework

    /// The drawn runs as `(1-based row, text)`: the panel row of every positioned write.
    private func runs(_ bytes: [UInt8]) -> [(row: Int, text: String)] {
        var out: [(Int, String)] = []
        let chars = Array(String(decoding: bytes, as: UTF8.self))
        var i = 0
        var row: Int? = nil
        var buf = ""
        func flush() {
            if let row, !buf.isEmpty { out.append((row, buf)) }
            buf = ""
        }
        while i < chars.count {
            if chars[i] == "\u{1B}", i + 1 < chars.count, chars[i + 1] == "[" {
                var j = i + 2
                var digits = ""
                while j < chars.count, chars[j].isNumber || chars[j] == ";" {
                    digits.append(chars[j])
                    j += 1
                }
                // `H` moves the cursor; every other CSI (colour, synchronized output) leaves it
                // where it was, so the run that follows a style change still belongs to this row.
                if j < chars.count, chars[j] == "H" {
                    flush()
                    row = digits.split(separator: ";").first.flatMap { Int($0) }
                }
                i = j + 1
                continue
            }
            if row != nil { buf.append(chars[i]) }
            i += 1
        }
        flush()
        return out
    }

    /// The menu is invisible on exactly the page it was built for: a handed-over mirror has the bar
    /// and **no `--dev`**, and `draw` used to gate the panel on `devStatus` while a rectangle computed
    /// from the geometry did not -- so `[ ≡ ]` opened a panel nothing painted, and a strip of the
    /// picture answered `.panel` to clicks and the wheel. One table decides both now: the box a click
    /// reads is the box the drawer wrote, and this is the test that keeps them from drifting apart.
    func testThePanelIsDrawnWhereverItsTableClaimsIt() {
        // (bar, dev) -- the first row is the mirror the issue is about.
        for (bar, dev) in [(true, false), (true, true), (false, true)] {
            let geo = Chrome.layout(paneCols: 100, paneRows: 30, imageCols: 100, imageRows: 22,
                                    bar: bar, dev: dev, panel: .menu)
            let chrome = Chrome()
            let bytes = chrome.draw(geometry: geo, metrics: menuMetrics(),
                                    state: ChromeState(panel: .menu))
            let drawn = runs(bytes)
            let label = "bar=\(bar) dev=\(dev)"
            XCTAssertEqual(geo.panelsDrawable, bar || dev, label)
            XCTAssertGreaterThan(geo.panelHeight, 0, "\(label): the box has rows")
            // The box is in the table the click path asks...
            guard let box = chrome.widgets.first(where: { $0.role == .panel }) else {
                return XCTFail("\(label): the menu was drawn without a box in the table")
            }
            // The tracks are painted...
            // Panel rows only: the drawer emits whole rows, so the axis label is inside the run,
            // and `fps` alone would also match the bar and the status line above the box.
            let ink = drawn.filter {
                $0.row > geo.imageRows && $0.row != geo.statusRow + 1
                    && ($0.text.contains("colour") || $0.text.contains("quality")
                        || $0.text.contains("fps") || $0.text.contains("a click sets it"))
            }
            XCTAssertFalse(ink.isEmpty, "\(label): the menu was not drawn at all")
            // ...inside the rows a click believes are a panel's: every row of ink answers `.panel`
            // where it is not a tick, so the wheel reaches the box at the rows it was painted in.
            for (row, text) in ink {
                XCTAssertEqual(chrome.route(row: row, col: 2, geometry: geo), .panel,
                               "\(label): row \(row) is drawn but the table does not answer it as "
                               + "the panel's: \(text)")
            }
            // ...and the other direction: every row the table's box covers has something drawn on
            // it, so a click can never be swallowed by a strip of the picture.
            let inkedRows = Set(drawn.map(\.row))
            for row in box.rect.row..<(box.rect.row + box.rect.height) {
                XCTAssertTrue(inkedRows.contains(row + 1),
                              "\(label): the table claims row \(row + 1) with nothing drawn")
            }
            // And the ticks on those rows are the controls the click path expects.
            let tickRow = ink.first { $0.text.contains("colour") }?.row ?? 0
            XCTAssertEqual(geo.panelHeight > 0, tickRow > 0)
        }
    }

    /// No bar and no `--dev`: no panel can be drawn, so nothing may claim a panel either -- the other
    /// end of the same agreement.
    func testNoPanelClaimWithoutAFurnitureRowToDrawItIn() {
        let geo = Chrome.layout(paneCols: 100, paneRows: 30, imageCols: 100, imageRows: 22,
                                bar: false, dev: false, panel: .menu)
        XCTAssertFalse(geo.panelsDrawable)
        XCTAssertEqual(geo.panelHeight, 0, "no panel is drawn, so none may reserve rows")
        let chrome = Chrome()
        let text = String(decoding: chrome.draw(geometry: geo, metrics: menuMetrics(),
                                                state: ChromeState(panel: .menu)),
                          as: UTF8.self)
        XCTAssertFalse(text.contains("colour"), "nothing draws the menu without furniture")
        XCTAssertFalse(chrome.widgets.contains { $0.role == .panel },
                       "nothing draws the menu, so no box may be in the table")
        var claimed: [(row: Int, col: Int)] = []
        for row in 1...geo.rows {
            for col in 1...geo.cols where chrome.route(row: row, col: col, geometry: geo) == .panel {
                claimed.append((row, col))
            }
        }
        XCTAssertEqual(claimed.count, 0, "cells claimed by a panel nothing paints: \(claimed.prefix(4))")
    }

    /// A pinned axis says so **at its value**, which is where the reader looked when the number
    /// walked back. `qualityEager` and `fpsTarget` are the same numbers the bar and status print, so
    /// the three agree: one value, one owner (issue #87).
    func testAPinnedAxisSaysPinnedNextToItsValue() {
        let geo = Chrome.layout(paneCols: 120, paneRows: 30, imageCols: 120, imageRows: 22,
                                bar: true, dev: false, panel: .menu)
        var m = menuMetrics()
        m.pinned = [.colour, .fps]
        let text = String(decoding: Chrome().draw(geometry: geo, metrics: m,
                                                  state: ChromeState(panel: .menu)),
                          as: UTF8.self)
        XCTAssertTrue(text.contains("5-6-5 (80) · pinned"), "the colour rung is the user's: \(text)")
        XCTAssertTrue(text.contains("12 fps · pinned"), "the frame rate is the user's: \(text)")
        XCTAssertFalse(text.contains("guarded — only what will not compress · pinned"),
                       "the quality axis was not pinned and must not claim it")
    }

    /// The wheel must reach the box's last row even when the pointer is over a tick -- the menu's
    /// tracks are panel rows with a control on them, and `guard wheel == 0` in the click path ate
    /// exactly those notches (issue #87, and #118's "the wheel reaches the rest").
    func testAWheelNotchOverATickStillScrollsThePanel() {
        func control(_ id: String, _ action: ChromeAction) -> ChromeWidget {
            ChromeWidget(id: id, rect: ChromeRect(row: 0, col: 0, width: 1), role: .control(action))
        }
        let box = ChromeWidget(id: "menu", rect: ChromeRect(row: 0, col: 0, width: 10, height: 6),
                               role: .panel)
        XCTAssertTrue(Chrome.scrollsPanel(box, wheel: 1))
        XCTAssertTrue(Chrome.scrollsPanel(control("rung:fps:6", .rung(.fps, 6)), wheel: -1))
        XCTAssertTrue(Chrome.scrollsPanel(control("rung:colour:2", .rung(.colour, 2)), wheel: 1))
        XCTAssertFalse(Chrome.scrollsPanel(control("shrink", .shrink), wheel: 1),
                       "the way out is not a scroller")
        XCTAssertFalse(Chrome.scrollsPanel(control("menu", .togglePanel(.menu)), wheel: 1))
        XCTAssertFalse(Chrome.scrollsPanel(control("rung:fps:6", .rung(.fps, 6)), wheel: 0),
                       "a click is not a notch")
        // A disabled control is inert for the wheel too, and a cell no widget claims is the
        // picture's: neither of them scrolls anything.
        let readout = ChromeWidget(id: "scale", rect: ChromeRect(row: 0, col: 0, width: 1),
                                   role: .control(.openPanel(.stats)), disabled: true)
        XCTAssertFalse(Chrome.scrollsPanel(readout, wheel: 1), "a disabled control does not scroll")
        XCTAssertFalse(Chrome.scrollsPanel(nil, wheel: 1), "the picture keeps its scroll")
    }

    /// The row a bar-only mirror gives up for a panel it is not showing: nothing. The panel
    /// reservation is the *bar or the panel's* business, not the `--dev` chrome's (issue #87).
    func testABarOnlyPaneReservesRowsForAPanelOnlyWhenOneIsOpen() {
        let closed = Chrome.pictureRows(paneRows: 30, bar: true, panel: nil, chrome: false)
        XCTAssertEqual(closed, 29, "a closed menu costs the picture nothing")
        let open = Chrome.pictureRows(paneRows: 30, bar: true, panel: .menu, chrome: false)
        XCTAssertEqual(open, 22, "an open menu takes its six rows out of the picture")
        // …and the geometry it feeds agrees: the box fits above the pane's last row.
        let geo = Chrome.layout(paneCols: 100, paneRows: 30, imageCols: 100,
                                imageRows: 1 + open, bar: true, dev: false, panel: .menu)
        XCTAssertEqual(geo.panelHeight, 6)
        XCTAssertEqual(geo.panelTop + geo.panelHeight, 29, "never the final row")
    }
}
