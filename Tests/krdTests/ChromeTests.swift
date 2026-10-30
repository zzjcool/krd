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
