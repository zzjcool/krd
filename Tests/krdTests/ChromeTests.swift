import XCTest
@testable import krd

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

    /// Clicking the bar is the primary way in, so hit ids must line up with what is drawn.
    func testHitTestFindsTheStatusSegments() {
        let chrome = Chrome()
        let geo = Chrome.layout(paneCols: 120, paneRows: 40, imageCols: 120, imageRows: 39, panel: nil)
        _ = chrome.draw(geometry: geo, metrics: metrics(cols: 120), state: ChromeState())
        var found: Set<String> = []
        for col in 1...120 {
            if case .statusSegment(let id) = chrome.hitTest(row: geo.statusRow + 1, col: col, geometry: geo) {
                found.insert(id)
            }
        }
        XCTAssertTrue(found.contains("stats"))
        XCTAssertTrue(found.contains("help"))
        XCTAssertTrue(found.contains("target"))
        if case .outside = chrome.hitTest(row: 1, col: 1, geometry: geo) {} else {
            XCTFail("a cell inside the picture must not be reported as chrome")
        }
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

    func testTheButtonIsOneClickTargetAcrossTheWholeRow() {
        let geo = geometry()
        let (_, chrome) = drawn(geo)
        // The right end of the row is the button; the traffic lights on the left do the same thing.
        XCTAssertEqual(chrome.hitTest(row: 1, col: geo.cols - 2, geometry: geo),
                       .statusSegment("shrink"))
        XCTAssertEqual(chrome.hitTest(row: 1, col: 2, geometry: geo), .statusSegment("shrink"))
        // A row that is neither the bar nor the status line belongs to the picture.
        XCTAssertEqual(chrome.hitTest(row: 5, col: 2, geometry: geo), .outside)
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
        XCTAssertEqual(chrome.hitTest(row: 1, col: 22, geometry: geo), .statusSegment("shrink"))
    }
}
