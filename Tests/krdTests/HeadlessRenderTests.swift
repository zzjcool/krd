#if KRD_HEADLESS_VT
import XCTest
@testable import krd
import krdcore
import KrdHeadlessVT

/// The wall, asserted on **cells** instead of on a pty's bytes (issue #218).
///
/// Every other test in this bundle that looks at the wall does one of two things: it compares bytes
/// (`WallCanvasTests`' four goldens) or it compares the full-row strings `WallCanvas.lines` returns.
/// Both answer "what came out", and neither can answer "what does the terminal *do* with it": a golden
/// says `\033[2;37;4m` is in the stream, not that the cells between column 1 and column 118 of the
/// footer row carry the faint bit and the underline bit at the same time, while the `N panels` tail on
/// the same row carries only the faint bit.
///
/// This file is that question, asked of a real terminal: `WallCanvas.draw` writes into libghostty-vt
/// and the test reads cells back. It runs only when the VT artifact is present —
/// `KRD_VT_XCFRAMEWORK=<path to ghostty-vt.xcframework> swift test --filter HeadlessRender`
/// (`docs/TESTING.md` §13). Without it this whole file is an empty translation unit, which is the
/// kill switch working.
///
/// **No sleeps.** libghostty-vt applies a write synchronously, including inside the
/// `?2026h`/`?2026l` synchronized-output blocks the wall emits (they are a hint to the renderer, not a
/// buffer), so the settle discipline here is a *property*, not a wait:
/// `testTheFrameLandsAndTheSecondDrawIsFree` asserts that the frame arrived (a cell it could not have
/// got from a partial write) and that a second identical draw is zero bytes and changes no cell. A
/// test that needed to wait would be hiding a real bug: the wall must be a pure function of its
/// inputs.
final class HeadlessRenderTests: XCTestCase {
    // MARK: the frame under test

    /// The pane the headless terminal is created at. It has to match the `cols:`/`rows:` the canvas
    /// was asked to draw for, or the CUP row/col lands on a different cell — which is the single most
    /// likely way to write a wrong headless test, so the two are one property here.
    private let cols = 100
    private let rows = 32

    /// Two displays and four windows: big enough for the stage, the stage caption, a card band with
    /// captions and the footer, small enough that every assertion below names cells a person could
    /// count. The awkward rows live in `WallCanvasTests.model()`; this one is deliberately plain,
    /// because what is under test here is the *terminal agreeing with the painter*, not the width math.
    private let testModel = WallModel(
        displays: [
            WallDisplay(name: "Built-in", width: 1512, height: 982, main: true),
            WallDisplay(name: "DELL U2720Q", width: 1728, height: 1117, main: false),
        ],
        windows: [
            OrderedWindow(windowID: 1, pid: 100, app: "Brave Browser", title: "krd — the wall",
                          bounds: CGRectCompat(x: 0, y: 0, width: 1452, height: 1050)),
            OrderedWindow(windowID: 2, pid: 101, app: "Xcode", title: "HeadlessRenderTests.swift",
                          bounds: CGRectCompat(x: 0, y: 0, width: 1440, height: 900)),
            OrderedWindow(windowID: 3, pid: 102, app: "Rex Beta", title: "π — kkrt",
                          bounds: CGRectCompat(x: 0, y: 0, width: 1200, height: 800)),
            OrderedWindow(windowID: 4, pid: 103, app: "WeChat", title: "Search chat history",
                          bounds: CGRectCompat(x: 0, y: 0, width: 900, height: 700)),
        ])

    /// A palette with an accent that is not any SGR colour and not the foreground: `#5EB8FF` in this
    /// tree is `Palette.brand`, and a test that used the default table would be asserting on `1;97`.
    private let palette = Palette(foreground: RGB(0xE6_E6_E6), background: RGB(0x11_11_11))

    private func layout(_ state: WallState) -> WallLayout {
        state.layout(cols: cols, rows: rows, displays: testModel.displays.count,
                     windows: testModel.windows.count)
    }

    /// One frame's bytes, and the layout they were drawn for.
    private func frame(state: WallState = WallState(), ring: WallAction? = nil,
                       palette: WallPalette? = nil) -> ([UInt8], WallLayout) {
        let layout = self.layout(state)
        let palette = palette ?? WallPalette(palette: self.palette)
        let bytes = WallCanvas().draw(cols: cols, rows: rows, model: testModel, layout: layout,
                                      focus: nil, ring: ring, palette: palette)
        return (bytes, layout)
    }

    /// A cell with nothing on it. An unwritten cell in a terminal reads back as a space — that is
    /// literally the same cell state — and the painter's `Grid.underline` deliberately marks *text*,
    /// so every attribute assertion below skips these (a blank cell carries no claim either way).
    private func isBlank(_ cell: HeadlessCell) -> Bool { cell.text.isEmpty || cell.text == " " }

    /// A terminal the size of the pane, with the frame written into it.
    private func makeTerminal(_ bytes: [UInt8]) throws -> HeadlessTerminal {
        let terminal = try HeadlessTerminal(cols: cols, rows: rows)
        terminal.write(bytes)
        return terminal
    }

    // MARK: the frame lands, and it lands once

    func testTheFrameLandsAndTheSecondDrawIsFree() throws {
        let canvas = WallCanvas()
        let layout = self.layout(WallState())
        let palette = WallPalette(palette: self.palette)
        let first = canvas.draw(cols: cols, rows: rows, model: testModel, layout: layout,
                                focus: nil, palette: palette)
        XCTAssertFalse(first.isEmpty, "the first draw is a full repaint")

        let terminal = try HeadlessTerminal(cols: cols, rows: rows)
        terminal.write(first)
        let before = (0..<rows).map { terminal.row($0) }

        // The frame is *there*: the wordmark the canvas painted at the header row, read back as a
        // cell. A partial write (a dropped buffer, a `?2026` block that swallowed the rest) fails
        // here rather than in whichever assertion happens to read that row.
        XCTAssertEqual(terminal.cell(col: 0, row: layout.headerRow - 1).text, WallSymbols.emoji.bullet,
                       "the header row's first cell is the wordmark's bullet")
        XCTAssertEqual(terminal.line(layout.headerRow - 1).prefix(5),
                       "\(WallSymbols.emoji.bullet) krd")

        // Per-cell diff, seen from the terminal: redrawing the same frame emits nothing *and* moves
        // nothing. This is the settle discipline — the second draw is the proof that the first one
        // finished, without a sleep anywhere in this file.
        let second = canvas.draw(cols: cols, rows: rows, model: testModel, layout: layout,
                                 focus: nil, palette: palette)
        XCTAssertTrue(second.isEmpty,
                      "an unchanged wall re-emits zero bytes (was \(second.count) B)")
        terminal.write(second)
        for row in 0..<rows {
            XCTAssertEqual(terminal.row(row), before[row], "row \(row) changed on a no-op draw")
        }

        // And the frame did not scroll or arm the pending wrap: `WallCanvas`'s write invariants 1 and
        // 2, checked by the only thing that can check them.
        XCTAssertEqual(terminal.scrollbackRows, 0, "a wall frame must never scroll the pane")
        XCTAssertFalse(terminal.cursor.pendingWrap, "the last cell of the last row was written")
    }

    // MARK: the wordmark is the palette's accent

    /// Issue #218's first assertion: `▪ krd` is drawn in `palette.accent`, and the counts beside it are
    /// not — one frame, two colours, both read from the cells the terminal settled on.
    func testTheHeaderWordmarkIsThePalettesAccent() throws {
        let (bytes, layout) = frame()
        let terminal = try makeTerminal(bytes)
        let row = layout.headerRow - 1

        let accent = HeadlessColor(red: palette.accent.r, green: palette.accent.g, blue: palette.accent.b)
        let dim = HeadlessColor(red: palette.dimText.r, green: palette.dimText.g, blue: palette.dimText.b)

        // `▪ krd` — five cells: the bullet, the space, the three letters.
        let wordmark = Array("\u{25AA} krd")
        XCTAssertEqual(wordmark.count, 5)
        for (index, character) in wordmark.enumerated() {
            let cell = terminal.cell(col: index, row: row)
            XCTAssertEqual(cell.text, String(character), "wordmark cell \(index)")
            XCTAssertEqual(cell.foreground, accent,
                           "`\(character)` at col \(index + 1) is not palette.accent "
                           + "(#\(String(accent.hex, radix: 16)))")
        }

        // The counts start right after it, and they are the palette's dim text — otherwise the
        // assertion above would also pass on a terminal that painted the whole row one colour.
        XCTAssertEqual(terminal.cell(col: wordmark.count, row: row).text, " ",
                       "one blank cell separates the wordmark from its counts")
        let counts = terminal.cell(col: wordmark.count + 4, row: row)
        XCTAssertEqual(counts.text, "\(testModel.windows.count)",
                       "the counts row starts `    4 windows`")
        XCTAssertEqual(counts.foreground, dim, "the counts are palette.dimText, not the accent")
        XCTAssertNotEqual(accent, dim, "the two roles must be different colours for this to bite")
    }

    // MARK: the caption row

    /// `🖥 Built-in — 1512×982 · main · 1/2`, one cell per cell, at the columns `WallLayout` says.
    ///
    /// This is the check the byte goldens cannot make and the width table pretends to: the painter's
    /// idea of each glyph's width and the terminal's own have to agree, or the row drifts. Both sides
    /// came from libghostty (`scripts/gen-widths.sh`), so this is a loop closing, not a coincidence.
    func testTheStageCaptionIsOneCellPerGlyph() throws {
        let (bytes, layout) = frame()
        let terminal = try makeTerminal(bytes)
        let rect = layout.stageCaption
        XCTAssertFalse(rect.isEmpty, "a \(cols)x\(rows) pane has a caption row")

        let expected = "\u{1F5A5} Built-in \u{2014} 1512\u{00D7}982 \u{00B7} main \u{00B7} 1/2"
        let row = terminal.row(rect.row - 1)
        // `stageCaption` is clipped to start at column 1, which is why the caption is the row's
        // prefix — said out loud, because a range that silently turned out empty would assert
        // nothing at all.
        XCTAssertEqual(rect.col, 1, "a \(cols)x\(rows) pane puts the caption in column 1")
        XCTAssertTrue(terminal.line(rect.row - 1).hasPrefix(expected))
        // Nothing else was written on the row either: the cells past the text are blank, and the
        // only other glyph on it is the bar's cap in the last column. (This is also the assertion
        // that reads a cell nothing wrote to, i.e. that a blank cell reads as blank.)
        // The range has to be non-empty or this loop asserts nothing at all — the comment below
        // used to *say* that, and saying it is not the same as being told. A caption that grew to
        // the bar's cap would turn the assertion into silence, which reads exactly like a pass.
        XCTAssertLessThan(DisplayWidth.of(expected), layout.barCol - 1,
                          "\(DisplayWidth.of(expected)) columns of caption in a \(layout.barCol) cell bar "
                          + "leaves no blank cell to check")
        for col in DisplayWidth.of(expected)..<(layout.barCol - 1) {
            XCTAssertTrue(isBlank(terminal.cell(col: col, row: rect.row - 1)),
                          "row \(rect.row) col \(col + 1) is a leftover the caption did not paint")
        }
        let cells = Array(row[(rect.col - 1)..<(rect.col - 1 + rect.cols)])
        let text = cells.filter { !$0.continuation }.map { $0.text.isEmpty ? " " : $0.text }.joined()
        XCTAssertEqual(text.trimmingTrailingSpaces, expected)

        // The `🖥` is one cell, not two: the caption's own comment depends on it (a VS16 would make
        // it three and push the whole row right by two).
        XCTAssertEqual(cells[0].text, "\u{1F5A5}")
        XCTAssertFalse(cells[0].wide, "U+1F5A5 without VS16 is one cell — the painter relies on it")
        XCTAssertEqual(cells[1].text, " ")

        // Plain cells: the caption is reverse video only when the pointer is over the display, and
        // this frame has no pointer. No colour of its own, so the terminal's default foreground.
        for (index, cell) in cells.prefix(DisplayWidth.of(expected)).enumerated() where !cell.text.isEmpty {
            XCTAssertNil(cell.foreground, "caption cell \(index) carries a colour the painter never set")
            XCTAssertFalse(cell.attributes.inverse, "caption cell \(index) is reversed with no pointer")
        }
    }

    // MARK: the focus ring

    /// The assertion that is an *attribute* and not a string: with `Tab` on the stage caption, every
    /// cell of that row is underlined and no other cell in the pane is.
    ///
    /// A byte test can find `\033[4m` in the stream. It cannot say which cells ended up underlined
    /// after the paint order (the ring is drawn last, over cells that already carry a style), nor that
    /// it underlined *exactly* the caption's rectangle — which is the whole contract of `drawRing`
    /// (issue #201: the ring must not move a caption by one cell or re-truncate a title).
    func testTheFocusRingIsAnUnderlineOnTheCaptionRowAndNowhereElse() throws {
        let (bytes, layout) = frame(ring: .enterStage(0))
        let terminal = try makeTerminal(bytes)
        let rect = layout.stageCaption

        // A blank cell inside the rect is not underlined, and that is the painter's rule rather than
        // an accident: `Grid.underline` skips cells nothing was written to (`ch == " "`), so the ring
        // marks *text*. This assertion says exactly that, cell by cell.
        var underlined = 0
        for row in 0..<rows {
            for col in 0..<cols {
                let cell = terminal.cell(col: col, row: row)
                let inRing = (rect.row - 1) == row && (rect.col - 1)..<(rect.col - 1 + rect.cols) ~= col
                let wanted = inRing && !isBlank(cell)
                if wanted { underlined += 1 }
                if cell.attributes.underline != wanted {
                    XCTFail("row \(row + 1), col \(col + 1) '\(cell.text)': "
                            + "underline=\(cell.attributes.underline), ring=\(inRing)")
                    return
                }
            }
        }
        XCTAssertGreaterThan(underlined, 20, "the ring underlined the caption it was put on")

        // The control: the same frame with no ring has no underlined cell at all, so the assertion
        // above is about the ring and not about something the painter always does.
        let (plain, _) = frame(ring: nil)
        let bare = try makeTerminal(plain)
        for row in 0..<rows {
            for col in 0..<cols where bare.cell(col: col, row: row).attributes.underline {
                XCTFail("no ring, but (row \(row + 1), col \(col + 1)) is underlined")
                return
            }
        }
    }

    /// The ring *composes*: `WallStyle.underlined` appends `;4` to whatever the cell already carried,
    /// so a dim footer row becomes faint **and** underlined, and the `N panels` tail — the same row,
    /// the same style, but outside the control — keeps only the faint bit.
    ///
    /// The boundary is the point. `drawRing(.back)` underlines `content - tail - 1` cells, so a test
    /// that asked "is the footer underlined" would pass on a ring that underlined the whole row,
    /// including a tail that is not part of the control. Asking the terminal per cell is what makes
    /// the difference visible; this frame uses `WallPalette.none` because that is the table whose dim
    /// role is the *attribute* `2;37` rather than an RGB colour.
    func testTheRingComposesWithTheStyleAlreadyOnTheCell() throws {
        let state = WallState()
        let layout = self.layout(state)
        let (bytes, _) = frame(state: state, ring: .back, palette: WallPalette.none)
        let terminal = try makeTerminal(bytes)
        let row = layout.footerRow - 1

        // The tail is `N panels`, right-aligned into the content width; the ring stops one column
        // short of it (`content - tail - 1`), which is the boundary this test is about.
        let tailWidth = DisplayWidth.of("\(1 + layout.cards.count) panels")
        let content = min(layout.contentCols, cols)
        let tailStart = content - tailWidth            // 0-based column of the tail's first cell
        let leadEnd = content - tailWidth - 1          // 0-based column of the separator blank

        let lead = terminal.cell(col: 0, row: row)
        XCTAssertEqual(lead.text, WallSymbols.emoji.bullet, "the footer's lead starts at column 1")
        XCTAssertTrue(lead.attributes.faint, "the footer lead is the dim style (`2;37`)")
        XCTAssertTrue(lead.attributes.underline, "the ring appends `4` — it does not replace `2;37`")

        // Every written cell of the lead carries both bits; the tail carries only the dim one. One
        // row, one style table, two different attribute sets, and the terminal is the thing that says
        // so.
        var composed = 0
        var plainDim = 0
        for col in 0..<content {
            let cell = terminal.cell(col: col, row: row)
            guard !isBlank(cell) else { continue }
            if col < tailStart {
                composed += 1
                XCTAssertTrue(cell.attributes.faint && cell.attributes.underline,
                              "lead cell \(col + 1) '\(cell.text)' lost an attribute "
                              + "(faint=\(cell.attributes.faint), underline=\(cell.attributes.underline))")
            } else {
                plainDim += 1
                XCTAssertTrue(cell.attributes.faint, "tail cell \(col + 1) is dim like the row")
                XCTAssertFalse(cell.attributes.underline,
                               "tail cell \(col + 1) '\(cell.text)' is not part of the control")
            }
        }
        XCTAssertGreaterThan(composed, 10, "the lead is more than a word")
        XCTAssertGreaterThan(plainDim, 5, "the tail is the `N panels` count")
        XCTAssertEqual(terminal.cell(col: leadEnd, row: row).attributes.underline, false,
                       "the blank separator between lead and tail is outside the control")
    }
}

private extension String {
    var trimmingTrailingSpaces: String {
        var copy = self
        while copy.last == " " { copy.removeLast() }
        return copy
    }
}
#endif
