import XCTest
@testable import krd
import krdcore

/// The wall's text layer: four byte goldens, the four write invariants, the symbol table and the
/// click state machine.
///
/// Regenerate the dumps on an intentional layout change: `KRD_UPDATE_FIXTURE=1 swift test` — **without
/// `--filter`**. With a filter, SwiftPM can skip this bundle entirely (seen on Swift 5.10: it prints
/// `Executed 0 tests` for the bundle that did not match, so "0 failures" is not evidence that the
/// fixture was rewritten — the next CI run then fails on bytes nobody changed). The update run
/// prints `golden fixture written: <path> (<n> B)`; no such line means nothing was regenerated.
///
/// What the four fixtures pin, so a later diff is explainable: the header, the stage box and its
/// centred label, the stage caption, the band header with its right-aligned `⤢ n`, three card boxes
/// (top-aligned app / title / size inside a fixed frame), three captions, the footer with its
/// right-aligned panel count, both bar segments with their arrows, thumb and caps — as bytes, i.e.
/// the cursor moves, the SGR choices and the trailing-blank trimming included, at a wide pane
/// (137x44: 3 cards of 44 cells and a 24-row stage) and a narrow one (60x24: 18-cell cards and a
/// 12-row stage) in both symbol modes. A change to *any* string template, style, position or
/// truncation shows up as a byte diff; a change to the width table shows up twice, once per mode.
final class WallCanvasTests: XCTestCase {
    // MARK: the fixed model

    /// Three displays, ordered by `WallSource` (main first, then left to right) and seven windows in
    /// the order the real `CGWindowList` returned them.
    ///
    /// Every awkward row of `Tests/krdcoreTests/Fixtures/cgwindowlist-host.json` is in here on
    /// purpose, because those are the rows the width math has to survive:
    /// a 52-cell CJK Brave title that must be truncated without splitting a glyph, a CJK Chrome
    /// title with full-width brackets and hyphens, two CJK *app* names (`腾讯云测试环境`,
    /// `企业微信`), a window whose title is `nil` (Screen Recording refused, or nothing named) which
    /// has to degrade to `window 6`, and sizes from 74x102 to 1440x2530 so the `W×H` line is both
    /// short and long.
    private func model() -> WallModel {
        WallModel(
            displays: [
                WallDisplay(name: "Built-in", width: 1512, height: 982, main: true),
                WallDisplay(name: "DELL U2720Q", width: 1728, height: 1117, main: false),
                WallDisplay(name: "BenQ PD2700U", width: 1920, height: 1080, main: false),
            ],
            windows: [
                OrderedWindow(windowID: 126324, pid: 55810, app: "Brave Browser",
                              title: "「沒有人知道為什麼行得通」《數學教你…到不該有用 - YouTube 🔊",
                              bounds: CGRectCompat(x: 42, y: -1050, width: 1452, height: 1050)),
                OrderedWindow(windowID: 124586, pid: 41379, app: "Google Chrome",
                              title: "云监控运营平台(BARAD) - 发布管理 - 控制台 - 统一运维运营平台",
                              bounds: CGRectCompat(x: -183, y: -831, width: 192, height: 177)),
                OrderedWindow(windowID: 119477, pid: 67529, app: "Rex Beta",
                              title: "π - kkrt - hidden-vale",
                              bounds: CGRectCompat(x: 1728, y: -1050, width: 1440, height: 2530)),
                OrderedWindow(windowID: 108251, pid: 38886, app: "腾讯云测试环境",
                              title: "腾讯云测试环境 - 成都主干环境",
                              bounds: CGRectCompat(x: -176, y: -646, width: 181, height: 151)),
                OrderedWindow(windowID: 78970, pid: 21825, app: "Xcode",
                              title: "SurfaceANSIRendererTests.swift",
                              bounds: CGRectCompat(x: -176, y: -470, width: 82, height: 112)),
                OrderedWindow(windowID: 124079, pid: 38773, app: "企业微信", title: nil,
                              bounds: CGRectCompat(x: 31, y: 191, width: 97, height: 117)),
                OrderedWindow(windowID: 114299, pid: 26465, app: "WeChat",
                              title: "Search chat history",
                              bounds: CGRectCompat(x: 16, y: 374, width: 74, height: 102)),
            ]
        )
    }

    /// The fixture state: `per = 3`, both offsets 0, nothing picked — the landing screen as it
    /// opens. `WallState`'s defaults are exactly that, and the goldens must pin the defaults, not a
    /// state the desk happens to construct.
    private func fixtureState() -> WallState { WallState() }

    private func makeLayout(_ state: WallState, cols: Int, rows: Int, _ model: WallModel) -> WallLayout {
        state.layout(cols: cols, rows: rows, displays: model.displays.count,
                     windows: model.windows.count)
    }

    /// Every geometry/glyph pair the goldens and the invariant tests cover.
    private let geometries: [(cols: Int, rows: Int)] = [(137, 44), (60, 24)]

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    /// A full repaint: a fresh canvas, so every cell is "changed" and the bytes are the whole wall.
    private func dump(cols: Int, rows: Int, symbols: WallSymbols) -> [UInt8] {
        let model = model()
        let state = fixtureState()
        let layout = makeLayout(state, cols: cols, rows: rows, model)
        return WallCanvas(symbols: symbols).draw(cols: cols, rows: rows, model: model,
                                                 layout: layout, focus: state.focus)
    }

    /// The three streams one pane can produce: the first paint, the second (must be empty) and a
    /// focus change (a one-row diff). The invariants have to hold for all of them, not just the
    /// convenient one.
    private func streams(cols: Int, rows: Int, symbols: WallSymbols) -> [(name: String, bytes: [UInt8])] {
        let model = model()
        let layout = makeLayout(fixtureState(), cols: cols, rows: rows, model)
        let canvas = WallCanvas(symbols: symbols)
        let repaint = canvas.draw(cols: cols, rows: rows, model: model, layout: layout, focus: nil)
        let unchanged = canvas.draw(cols: cols, rows: rows, model: model, layout: layout, focus: nil)
        let focus = canvas.draw(cols: cols, rows: rows, model: model, layout: layout,
                                focus: .display(2))
        return [("repaint", repaint), ("unchanged", unchanged), ("focus", focus)]
    }

    // MARK: the four goldens

    func testTheFourDumpsAreTheWallByteForByte() throws {
        let cases: [(cols: Int, rows: Int, symbols: WallSymbols)] = [
            (137, 44, .emoji), (137, 44, .ascii), (60, 24, .emoji), (60, 24, .ascii),
        ]
        let update = ProcessInfo.processInfo.environment["KRD_UPDATE_FIXTURE"] != nil
        for c in cases {
            let got = dump(cols: c.cols, rows: c.rows, symbols: c.symbols)
            let url = fixtureURL("wall-\(c.cols)x\(c.rows)-\(c.symbols.rawValue).dump")
            if update {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data(got).write(to: url)
                // stderr on purpose: XCTest swallows the test process's stdout, so a `print` here
                // would not be visible in `swift test` output — and an invisible confirmation is how
                // the broken `--filter` recipe went unnoticed.
                FileHandle.standardError.write(
                    Data("golden fixture written: \(url.path) (\(got.count) B)\n".utf8))
                continue
            }
            let want = [UInt8](try Data(contentsOf: url))
            XCTAssertEqual(got.count, want.count,
                           "\(url.lastPathComponent): the dump changed size — a template, a style or the trimming moved")
            if got != want {
                let i = (0..<min(got.count, want.count)).first { got[$0] != want[$0] }
                    ?? min(got.count, want.count)
                let lo = max(0, i - 24), hi = min(min(got.count, want.count), i + 24)
                XCTFail("\(url.lastPathComponent) changed at offset \(i)\n"
                        + "  want: \(String(decoding: want[lo..<hi], as: UTF8.self).debugDescription)\n"
                        + "  got:  \(String(decoding: got[lo..<hi], as: UTF8.self).debugDescription)")
            }
        }
    }

    func testTheDumpsAreNotTriviallySmall() {
        // Guard against a fixture that would pass because the wall came out empty.
        for c in geometries {
            XCTAssertGreaterThan(dump(cols: c.cols, rows: c.rows, symbols: .emoji).count, 2_000,
                                 "a \(c.cols)x\(c.rows) wall is not a handful of bytes")
        }
    }

    // MARK: the four write invariants

    func testAnUnchangedWallEmitsNothing() {
        let model = model()
        let layout = makeLayout(fixtureState(), cols: 137, rows: 44, model)
        let canvas = WallCanvas()
        let first = canvas.draw(cols: 137, rows: 44, model: model, layout: layout, focus: nil)
        XCTAssertFalse(first.isEmpty, "the first draw is a full repaint")
        // This is also the design's "0 B/s when nothing moves": an idle wall rewrites nothing, so
        // the 1 s timer costs no bytes when the model has not changed.
        XCTAssertEqual(canvas.draw(cols: 137, rows: 44, model: model, layout: layout, focus: nil).count, 0,
                       "drawing the same wall twice must emit nothing")
        // A resize (and `invalidate`) drops the previous grid, so the next draw is a full repaint
        // again — the terminal may have reflowed or cleared under us.
        canvas.invalidate()
        XCTAssertFalse(canvas.draw(cols: 137, rows: 44, model: model, layout: layout, focus: nil).isEmpty)
    }

    func testAChangedTitleTouchesOnlyThatCardsRows() {
        let model = model()
        let layout = makeLayout(fixtureState(), cols: 137, rows: 44, model)
        let canvas = WallCanvas()
        _ = canvas.draw(cols: 137, rows: 44, model: model, layout: layout, focus: nil)

        var changed = model
        changed.windows[1] = retitled(changed.windows[1], "a different title")
        let bytes = canvas.draw(cols: 137, rows: 44, model: changed, layout: layout, focus: nil)
        XCTAssertFalse(bytes.isEmpty, "a changed title has to repaint its cells")

        // Card 1's box and its caption row; nothing else. So a keystroke-sized change in the data
        // cannot cost a full wall: no header, no stage, no band, no footer, no other card.
        let card = layout.cards[1]
        let allowed = Set(Array(card.row...card.maxRow) + [layout.cardCaptions[1].row])
        let touched = Set(cursorMoves(bytes).map(\.row))
        XCTAssertFalse(touched.isEmpty)
        XCTAssertTrue(touched.isSubset(of: allowed),
                      "rows outside card 1 were repainted: \(touched.sorted())")
        // And the two rows that actually changed: the title line inside the box, the caption.
        XCTAssertEqual(touched, Set([card.row + 2, layout.cardCaptions[1].row]))
        XCTAssertFalse(bytes.contains(0x0A))
    }

    func testNoStreamContainsANewlineOrWritesTheFinalCell() {
        for c in geometries {
            for symbols in WallSymbols.allCases {
                for stream in streams(cols: c.cols, rows: c.rows, symbols: symbols) {
                    let label = "\(stream.name) at \(c.cols)x\(c.rows) \(symbols.rawValue)"
                    // Invariant 1: a newline on the last row scrolls the grid.
                    XCTAssertFalse(stream.bytes.contains(0x0A), "\(label) contains 0x0A")
                    if stream.name == "unchanged" {
                        XCTAssertTrue(stream.bytes.isEmpty, "\(label) is not empty")
                    } else {
                        XCTAssertFalse(stream.bytes.isEmpty, "\(label) is empty")
                    }
                    // Invariants 2 and 3: positioned writes, never above row 1 or left of column 1,
                    // never on the final cell of the final row (pending-wrap).
                    for move in cursorMoves(stream.bytes) {
                        XCTAssertGreaterThanOrEqual(move.row, 1, "\(label) moved above row 1")
                        XCTAssertGreaterThanOrEqual(move.col, 1, "\(label) moved left of column 1")
                        XCTAssertLessThanOrEqual(move.row, c.rows, "\(label) moved past the last row")
                        XCTAssertLessThanOrEqual(move.col, c.cols, "\(label) moved past the last column")
                        XCTAssertFalse(move.row == c.rows && move.col == c.cols,
                                       "\(label) wrote the final cell: pending-wrap")
                    }
                }
            }
        }
    }

    // MARK: the grid behind the bytes

    func testLinesAreExactlyThePaneWidthAndBothModesAgree() {
        let model = model()
        for c in geometries {
            let layout = makeLayout(fixtureState(), cols: c.cols, rows: c.rows, model)
            let emoji = WallCanvas(symbols: .emoji).lines(cols: c.cols, rows: c.rows, model: model,
                                                          layout: layout, focus: nil)
            let ascii = WallCanvas(symbols: .ascii).lines(cols: c.cols, rows: c.rows, model: model,
                                                          layout: layout, focus: nil)
            XCTAssertEqual(emoji.count, c.rows, "one string per row")
            XCTAssertEqual(ascii.count, c.rows, "one string per row")
            for (i, row) in emoji.enumerated() {
                XCTAssertEqual(DisplayWidth.of(row), c.cols,
                               "emoji row \(i + 1) at \(c.cols)x\(c.rows) is not \(c.cols) cells")
            }
            for (i, row) in ascii.enumerated() {
                XCTAssertEqual(DisplayWidth.of(row), c.cols,
                               "ascii row \(i + 1) at \(c.cols)x\(c.rows) is not \(c.cols) cells")
            }
            // The contract that makes `--symbols ascii` a switch and not a re-layout: the same
            // number of columns in both modes (the glyphs differ — see below).
            for (i, pair) in zip(emoji, ascii).enumerated() {
                XCTAssertEqual(DisplayWidth.of(pair.0), DisplayWidth.of(pair.1),
                               "row \(i + 1): the two modes lay out different columns")
            }
            XCTAssertNotEqual(emoji, ascii, "the modes must actually differ")
        }
    }

    /// `lines` describes the grid `draw` renders from: replay the emitted bytes onto a blank pane
    /// and they must reproduce `lines` exactly. This is the end-to-end version of "the painter and
    /// the tests look at the same wall" — a `lines` that drifted from the bytes would be a test
    /// suite measuring a wall nobody draws.
    func testTheBytesReproduceTheLinesTheCanvasReports() {
        let model = model()
        for c in geometries {
            for symbols in WallSymbols.allCases {
                let layout = makeLayout(fixtureState(), cols: c.cols, rows: c.rows, model)
                let canvas = WallCanvas(symbols: symbols)
                let bytes = canvas.draw(cols: c.cols, rows: c.rows, model: model, layout: layout,
                                        focus: nil)
                let lines = canvas.lines(cols: c.cols, rows: c.rows, model: model, layout: layout,
                                         focus: nil)
                XCTAssertEqual(replay(bytes, cols: c.cols, rows: c.rows), lines,
                               "\(c.cols)x\(c.rows) \(symbols.rawValue): the bytes and `lines` disagree")
            }
        }
    }

    /// The two `focus` footers are the only strings the goldens cannot reach (the fixtures have
    /// `focus == nil`), so they are pinned here: a pick rewrites the footer row and nothing else.
    func testTheFocusFooterIsOneRowAndSaysWhatWasPicked() {
        let model = model()
        let cols = 137, rows = 44
        let layout = makeLayout(fixtureState(), cols: cols, rows: rows, model)
        let canvas = WallCanvas()
        let plain = canvas.lines(cols: cols, rows: rows, model: model, layout: layout, focus: nil)
        for (focus, wanted) in [(WallState.Focus.display(1), "picked DELL U2720Q"),
                                (WallState.Focus.window(1), "picked Google Chrome")] {
            let picked = canvas.lines(cols: cols, rows: rows, model: model, layout: layout,
                                      focus: focus)
            XCTAssertEqual(picked.count, rows)
            for (i, pair) in zip(plain, picked).enumerated() where pair.0 != pair.1 {
                XCTAssertEqual(i + 1, layout.footerRow, "a pick may only rewrite the footer row")
            }
            let footer = picked[layout.footerRow - 1]
            XCTAssertTrue(footer.contains(wanted), "\(focus): footer is \(footer.debugDescription)")
            XCTAssertTrue(footer.contains("back"), "\(focus): no way back in \(footer.debugDescription)")
            XCTAssertEqual(DisplayWidth.of(footer), cols)
        }
    }

    // MARK: the symbol table

    func testSymbolSpecParsing() {
        XCTAssertEqual(WallSymbols(spec: "emoji"), .emoji)
        XCTAssertEqual(WallSymbols(spec: "ascii"), .ascii)
        XCTAssertEqual(WallSymbols(spec: "ASCII"), .ascii)
        XCTAssertEqual(WallSymbols(spec: "Emoji"), .emoji)
        // A typo must fail loudly (the argument parser exits 2), not silently pick a mode.
        for bad in ["", "emo", "ascii ", " emoji", "emojis", "ascii,"] {
            XCTAssertNil(WallSymbols(spec: bad), "\(bad.debugDescription) must not pick a mode")
        }
        XCTAssertEqual(WallSymbols.allCases, [.emoji, .ascii])
    }

    func testEveryGlyphInBothModesIsOneCellWide() {
        for symbols in WallSymbols.allCases {
            let table: [(String, String)] = [
                ("bullet", symbols.bullet), ("display", symbols.display),
                ("window", symbols.window), ("up", symbols.up), ("down", symbols.down),
                ("shaft", symbols.shaft), ("thumb", symbols.thumb),
                ("perButton", symbols.perButton), ("back", symbols.back),
                ("capTop", symbols.capTop), ("capBottom", symbols.capBottom),
                ("boxTL", symbols.boxTL), ("boxTR", symbols.boxTR),
                ("boxBL", symbols.boxBL), ("boxBR", symbols.boxBR),
                ("boxH", symbols.boxH), ("boxV", symbols.boxV), ("times", symbols.times),
                ("dash", symbols.dash), ("enDash", symbols.enDash),
            ]
            for (name, glyph) in table {
                // One cluster *and* one cell: a two-cluster glyph would move a column, and a
                // two-cell one would move two — both break `barCol` and every caption after it.
                XCTAssertEqual(glyph.count, 1, "\(symbols.rawValue).\(name) is not one character")
                XCTAssertEqual(DisplayWidth.of(glyph), 1,
                               "\(symbols.rawValue).\(name) is not one cell")
            }
            // `dot` is a separator by definition — space, one-cell glyph, space.
            XCTAssertEqual(symbols.dot.count, 3)
            XCTAssertEqual(DisplayWidth.of(symbols.dot), 3, "\(symbols.rawValue).dot")
        }
    }

    // MARK: the click state machine

    func testStateStepsClampAtBothEnds() {
        var state = fixtureState()
        state.apply(.stageStep(-1), displays: 3, windows: 7)
        XCTAssertEqual(state.stageStart, 0, "a step back from the first display stops at 0")
        state.apply(.stageStep(1), displays: 3, windows: 7)
        XCTAssertEqual(state.stageStart, 1)
        state.apply(.stageStep(5), displays: 3, windows: 7)
        XCTAssertEqual(state.stageStart, 2, "the last display is displayCount - 1")

        XCTAssertEqual(state.cardStart, 0)
        state.apply(.cardStep(-3), displays: 3, windows: 7)
        XCTAssertEqual(state.cardStart, 0, "a page back from the first page stops at 0")
        state.apply(.cardStep(3), displays: 3, windows: 7)
        XCTAssertEqual(state.cardStart, 3)
        state.apply(.cardStep(3), displays: 3, windows: 7)
        XCTAssertEqual(state.cardStart, 4, "one page past the end stops at windowCount - per")
        state.apply(.cardStep(3), displays: 3, windows: 7)
        XCTAssertEqual(state.cardStart, 4, "and stays there")
        // Fewer windows than one page: there is nothing to scroll in either direction.
        state.apply(.cardStep(-3), displays: 3, windows: 2)
        XCTAssertEqual(state.cardStart, 0)
        state.apply(.cardStep(3), displays: 3, windows: 2)
        XCTAssertEqual(state.cardStart, 0)
    }

    func testStateJumpsSetTheStart() {
        var state = fixtureState()
        state.apply(.stageJump(2), displays: 3, windows: 7)
        XCTAssertEqual(state.stageStart, 2)
        state.apply(.cardJump(4), displays: 3, windows: 7)
        XCTAssertEqual(state.cardStart, 4)
        // A jump carries a proportion computed from the bar, so it is clamped, never trusted.
        state.apply(.stageJump(99), displays: 3, windows: 7)
        XCTAssertEqual(state.stageStart, 2)
        state.apply(.cardJump(-5), displays: 3, windows: 7)
        XCTAssertEqual(state.cardStart, 0)
    }

    func testStateEnterSetsFocusAndBackClearsIt() {
        var state = fixtureState()
        state.apply(.enterStage(2), displays: 3, windows: 7)
        XCTAssertEqual(state.focus, WallState.Focus.display(2))
        XCTAssertEqual(state.stageStart, 2, "entering a display also brings it on stage")
        state.apply(.enterCard(5), displays: 3, windows: 7)
        XCTAssertEqual(state.focus, WallState.Focus.window(5))
        XCTAssertEqual(state.cardStart, 0, "entering a card must not move the shelf")
        state.apply(.back, displays: 3, windows: 7)
        XCTAssertNil(state.focus)
        XCTAssertEqual(state.cardStart, 0)
        // The payloads are indices into the whole list, and they are clamped to the model.
        state.apply(.enterCard(99), displays: 3, windows: 7)
        XCTAssertEqual(state.focus, WallState.Focus.window(6))
        state.apply(.enterStage(99), displays: 3, windows: 7)
        XCTAssertEqual(state.focus, WallState.Focus.display(2))
        XCTAssertEqual(state.stageStart, 2)
    }

    func testStateClampPullsBothOffsetsBackIntoRange() {
        var state = fixtureState()
        state.stageStart = 2
        state.cardStart = 4
        // A monitor unplugged and the windows closed while the wall was showing page two.
        state.clamp(displays: 1, windows: 2)
        XCTAssertEqual(state.stageStart, 0)
        XCTAssertEqual(state.cardStart, 0)
        // The rack grew again: the clamp never invents an offset past the end.
        state.clamp(displays: 3, windows: 7)
        XCTAssertEqual(state.stageStart, 0)
        XCTAssertEqual(state.cardStart, 0)
    }

    // MARK: helpers

    private func retitled(_ window: OrderedWindow, _ title: String?) -> OrderedWindow {
        OrderedWindow(windowID: window.windowID, pid: window.pid, app: window.app, title: title,
                      bounds: window.bounds)
    }

    /// Every `ESC [ row ; col H` in a byte stream, 1-based. No regex: the escapes are simpler than
    /// the literal syntax (`ChromeTests` does the same).
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

    /// Replay a byte stream onto a blank pane and read it out again. It understands exactly what
    /// the painter emits — `ESC[<row>;<col>H`, `ESC[<sgr>m` (styles ignored: the goldens are what
    /// pin them) and UTF-8 text — and it reads the cursor after every write, so it is an
    /// independent second opinion on both the positions and the wide-glyph cells.
    private func replay(_ bytes: [UInt8], cols: Int, rows: Int) -> [String] {
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
                    let params = String(decoding: bytes[(i + 2)..<j], as: UTF8.self)
                    let parts = params.split(separator: ";").compactMap { Int($0) }
                    if parts.count == 2 { row = parts[0]; col = parts[1] }
                }
                i = j + 1
                continue
            }
            // One run of text: up to the next escape. Decoded as a whole so a multi-byte (or
            // multi-scalar) character stays in one piece.
            var j = i
            while j < bytes.count, bytes[j] != 0x1B { j += 1 }
            for ch in String(decoding: bytes[i..<j], as: UTF8.self) {
                let width = DisplayWidth.of(ch)
                if width == 0 { continue }
                guard row >= 1, row <= rows, col >= 1, col + width - 1 <= cols else { continue }
                cells[(row - 1) * cols + (col - 1)] = ch
                if width == 2 { covered[(row - 1) * cols + col] = true }
                col += width
            }
            i = j
        }
        var out: [String] = []
        for y in 0..<max(0, rows) {
            var line = ""
            for x in 0..<max(0, cols) where !covered[y * cols + x] {
                line.append(cells[y * cols + x])
            }
            let width = DisplayWidth.of(line)
            if width < cols { line += String(repeating: " ", count: cols - width) }
            out.append(line)
        }
        return out
    }
}

