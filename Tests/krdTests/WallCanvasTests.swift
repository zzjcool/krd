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
/// (the app / title / size block centred in the frame, as many lines as fit), three captions, the
/// footer with its right-aligned panel count, both bar segments with their arrows, thumb and caps
/// (including the `╵`/`╷` break between the segments on the band row) — as bytes, i.e.
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
        // The block of three lines is centred in the interior (the phase-1 mask is centred in its
        // rect), so the title sits on the second line of that block. Derived from the card's own
        // height rather than pinned: the 137x44 golden's card is 10 rows tall since the 7:3 split.
        let interior = card.rows - 2
        let blockTop = card.row + 1 + max(0, (interior - 3) / 2)
        XCTAssertEqual(touched, Set([blockTop + 1, layout.cardCaptions[1].row]))
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

    // MARK: a line that shrinks must erase what it used to say

    /// The bug these three tests exist for: the diff renderer trims trailing blanks from a changed
    /// run, and as long as it trims them **unconditionally** it also drops the blanks that are there
    /// to *overwrite* the previous frame. Nothing in a single draw can see that — `lines` is right
    /// and the bytes look plausible — so every case replays the second stream onto the pane the
    /// first one left behind, which is the only grid that still holds those glyphs.
    ///
    /// The footer is the live reproduction: a pick turns it into `⬅ 🖥 back · picked … · the mirror
    /// follows in the capture phase`, `back` (`focus: nil`) turns it into the short landing line, and
    /// the tail of the picked sentence has to be painted over with blanks.
    func testALineThatShrinksErasesItsOldTail() {
        var picked = fixtureState()
        picked.focus = .window(2)
        let cases: [(String, (model: WallModel, state: WallState),
                     (model: WallModel, state: WallState))] = [
            ("footer: picked -> nothing picked",
             (model(), picked), (model(), fixtureState())),
            // The reverse direction is the same codepath (a run of new cells) and must agree with
            // `lines` too: a line that *grows* writes its whole length, no trimming involved.
            ("footer: nothing picked -> picked",
             (model(), fixtureState()), (model(), picked)),
        ]
        for (label, first, second) in cases {
            assertTwoDrawsMatchThePane(label, first: first, second: second, cols: 137, rows: 44)
        }
    }

    /// The same shape one level down: the same window count, only window 0's title gets shorter, so
    /// the card's title line, the card caption under it and the title inside the picked footer all
    /// end earlier than the text the pane is showing.
    func testATitleThatShrinksErasesTheOldTitle() {
        var short = model()
        short.windows[0] = retitled(short.windows[0], "π")
        var picked = fixtureState()
        picked.focus = .window(0)
        let cases: [(String, (model: WallModel, state: WallState),
                     (model: WallModel, state: WallState))] = [
            ("title: long -> short", (model(), fixtureState()), (short, fixtureState())),
            ("title: short -> long", (short, fixtureState()), (model(), fixtureState())),
            ("picked title: long -> short", (model(), picked), (short, picked)),
            ("picked title: short -> long", (short, picked), (model(), picked)),
        ]
        for (label, first, second) in cases {
            assertTwoDrawsMatchThePane(label, first: first, second: second, cols: 137, rows: 44)
        }
    }

    /// And the band's own label: `▣ recent    1–3 / 7` shrinks to `1–2 / 2` when windows close, and
    /// the third card (frame, centred text, caption) disappears entirely — the widest case of "the
    /// cells that used to hold glyphs are blank in the new grid".
    func testAWindowListThatShrinksErasesTheGoneCard() {
        var small = model()
        small.windows = Array(small.windows.prefix(2))
        let cases: [(String, (model: WallModel, state: WallState),
                     (model: WallModel, state: WallState))] = [
            ("windows: 7 -> 2", (model(), fixtureState()), (small, fixtureState())),
            ("windows: 2 -> 7", (small, fixtureState()), (model(), fixtureState())),
        ]
        for (label, first, second) in cases {
            assertTwoDrawsMatchThePane(label, first: first, second: second, cols: 137, rows: 44)
        }
        // The 60x24 geometry too: there the stage and the cards are squeezed, so the shrink has to
        // erase part of a card instead of a whole one.
        for (label, first, second) in cases {
            assertTwoDrawsMatchThePane("60x24 " + label, first: first, second: second,
                                       cols: 60, rows: 24)
        }
    }

    /// Draw `first` and then `second` on one canvas, and require the *pane* to end up on `second`.
    ///
    /// The second assertion is the whole point: the second stream is replayed onto the grid the first
    /// one left, not onto a blank one, and it must reproduce `lines` cell for cell. A trimmed blank
    /// that the previous grid had filled with a glyph fails here and nowhere else.
    private func assertTwoDrawsMatchThePane(_ label: String,
                                            first: (model: WallModel, state: WallState),
                                            second: (model: WallModel, state: WallState),
                                            cols: Int, rows: Int,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let canvas = WallCanvas()
        let a = paint(canvas, first, cols: cols, rows: rows)
        let b = paint(canvas, second, cols: cols, rows: rows)
        XCTAssertFalse(a.bytes.isEmpty,
                       "\(label): the first draw is a full repaint", file: file, line: line)
        XCTAssertEqual(replay(a.bytes, cols: cols, rows: rows), a.lines,
                       "\(label): the first stream does not reproduce the first frame",
                       file: file, line: line)
        XCTAssertNotEqual(a.lines, b.lines,
                          "\(label): the two frames are identical, so the case proves nothing",
                          file: file, line: line)
        XCTAssertFalse(b.bytes.isEmpty,
                       "\(label): a changed wall has to emit something", file: file, line: line)
        XCTAssertEqual(replay([a.bytes, b.bytes], cols: cols, rows: rows), b.lines,
                       "\(label): the second draw left the first frame's glyphs on the pane",
                       file: file, line: line)
    }

    /// One `draw` plus the `lines` of the *same* frame, from the same layout.
    private func paint(_ canvas: WallCanvas, _ frame: (model: WallModel, state: WallState),
                       cols: Int, rows: Int) -> (bytes: [UInt8], lines: [String]) {
        let layout = makeLayout(frame.state, cols: cols, rows: rows, frame.model)
        return (canvas.draw(cols: cols, rows: rows, model: frame.model, layout: layout,
                            focus: frame.state.focus),
                canvas.lines(cols: cols, rows: rows, model: frame.model, layout: layout,
                             focus: frame.state.focus))
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

    // MARK: the two polish items the mockup asked for

    /// Design §6 breaks the bar between its two segments (`中间用 ╵/╷ 断开`): `╵` closes the display
    /// segment on the stage caption row and `╷` opens the card segment on the band header row, with
    /// `╷` above the display segment and `╵` under the cards. The band row used to draw nothing, so
    /// the two shafts read as one continuous bar down the pane.
    ///
    /// The lower cap closes the card *section*: it sits on the row under the lower segment, which is
    /// the first card's caption row while a page is one row tall (both goldens) and the section's own
    /// last row when the page has several (`testATwoRowPagePaintsBothRowsAndOneCaptionEach`).
    func testTheBarBreaksBetweenItsTwoSegments() {
        let model = model()
        for c in geometries {
            for symbols in WallSymbols.allCases {
                let layout = makeLayout(fixtureState(), cols: c.cols, rows: c.rows, model)
                let lines = WallCanvas(symbols: symbols).lines(cols: c.cols, rows: c.rows,
                                                               model: model, layout: layout,
                                                               focus: nil)
                // The bar owns the last column, and every glyph in it is one cell wide, so the last
                // character of a row is that row's bar cell (`lines` drops style; the goldens pin
                // the `.dim` SGR).
                XCTAssertEqual(layout.cardRowCount, 1, "\(c.cols)x\(c.rows): one row of cards here")
                let caps: [(row: Int, glyph: String)] = [
                    (layout.headerRow, symbols.capTop),
                    (layout.stageCaption.row, symbols.capBottom),
                    (layout.bandRow, symbols.capTop),
                    (layout.cardCaptions[0].row, symbols.capBottom),
                ]
                XCTAssertEqual(layout.cardCaptions[0].row, layout.bar.cards.rect.maxRow + 1,
                               "\(c.cols)x\(c.rows): the segment ends on the caption row")
                for cap in caps {
                    XCTAssertEqual(lines[cap.row - 1].last, cap.glyph.first,
                                   "\(c.cols)x\(c.rows) \(symbols.rawValue): cell "
                                   + "(\(cap.row),\(layout.barCol)) is not \(cap.glyph)")
                }
            }
        }
    }

    // MARK: a segment with one shaft cell (issue #135)

    /// A 3-row segment is `▲`, one `█`, `▼`: the thumb really is drawn in the segment's only shaft
    /// cell, so the bar says "you are here" — and a click on that cell has to keep the position it
    /// shows, not answer page 0 (on every pane whose card band or stage band is exactly 3 rows that
    /// is what it did before #135). Pinned at the glyph, at the hit table and through `WallState`,
    /// because the layout payload alone would still pass if the painter stopped drawing the thumb
    /// the click is agreeing with.
    func testAOneCellShaftDrawsTheThumbTheClickKeeps() {
        let model = model()                                  // 7 windows, 3 displays

        // The card band: 24x17 with one card to a row is 3 rows, and the shelf is on its last page
        // (6 = maxStart), so "the page the thumb shows" and "the first page" differ.
        var cards = fixtureState()
        cards.per = 1
        cards.cardStart = 6
        let cardsLayout = makeLayout(cards, cols: 24, rows: 17, model)
        let cardSegment = cardsLayout.bar.cards
        XCTAssertEqual(cardSegment.rect.rows, 3, "24x17, one card to a row: a 3-row card band")
        XCTAssertEqual(cardSegment.maxStart, 6, "…and the shelf is on its last page")
        for symbols in WallSymbols.allCases {
            let lines = WallCanvas(symbols: symbols).lines(cols: 24, rows: 17, model: model,
                                                           layout: cardsLayout, focus: nil)
            XCTAssertEqual(lines[cardSegment.rect.row - 1].last, symbols.up.first,
                           "\(symbols.rawValue): the segment's top cell is the arrow")
            XCTAssertEqual(lines[cardSegment.rect.row].last, symbols.thumb.first,
                           "\(symbols.rawValue): the thumb is drawn in the only shaft cell")
            XCTAssertEqual(lines[cardSegment.rect.maxRow - 1].last, symbols.down.first,
                           "\(symbols.rawValue): the segment's bottom cell is the arrow")
        }
        let cardClick = cardsLayout.action(row: cardSegment.rect.row + 1, col: cardsLayout.barCol)
        XCTAssertEqual(cardClick, .cardJump(6), "the thumb's cell answers with the page it shows")
        cards.apply(cardClick!, displays: model.displays.count, windows: model.windows.count,
                    capacity: cardsLayout.capacity)
        XCTAssertEqual(cards.cardStart, 6, "…and the click does not move the shelf")

        // The stage: a pane too short for a card band (24x8) hands the whole budget to the stage,
        // so the upper segment has one shaft cell too.
        var stage = fixtureState()
        stage.stageStart = 2
        let stageLayout = makeLayout(stage, cols: 24, rows: 8, model)
        let stageSegment = stageLayout.bar.stage
        XCTAssertEqual(stageSegment.rect.rows, 3, "24x8: the stage is the whole 3-row budget")
        XCTAssertEqual(stageSegment.maxStart, 2, "…and the last display is up")
        for symbols in WallSymbols.allCases {
            let lines = WallCanvas(symbols: symbols).lines(cols: 24, rows: 8, model: model,
                                                           layout: stageLayout, focus: nil)
            XCTAssertEqual(lines[stageSegment.rect.row].last, symbols.thumb.first,
                           "\(symbols.rawValue): the stage's thumb is in its only shaft cell")
        }
        let stageClick = stageLayout.action(row: stageSegment.rect.row + 1, col: stageLayout.barCol)
        XCTAssertEqual(stageClick, .stageJump(2), "the stage's thumb answers with the display it shows")
        stage.apply(stageClick!, displays: model.displays.count, windows: model.windows.count,
                    capacity: stageLayout.capacity)
        XCTAssertEqual(stage.stageStart, 2, "…and the click does not move the stage")
    }

    // MARK: a band that holds more than one row of cards (issue #83)

    /// The reporter's pane: 118x73, a 17x33 cell, a 16:10 display. The band holds two rows of three
    /// previews, so a page is six windows and the state has to step by six - not by the row width.
    func testAPageOfTwoRowsStepsBySix() {
        let model = model()                                  // 7 windows, 3 displays
        var state = fixtureState()
        let layout = state.layout(cols: 118, rows: 73, displays: model.displays.count,
                                  windows: model.windows.count,
                                  stageAspect: 1.6, cellAspect: 33.0 / 17.0)
        XCTAssertEqual(layout.per, 3, "the row width")
        XCTAssertEqual(layout.cardRowCount, 2, "two rows of previews fit the band")
        XCTAssertEqual(layout.capacity, 6, "so a page is six windows")
        XCTAssertEqual(layout.cards.count, 6)
        XCTAssertEqual(layout.bar.cards.visible, 6)
        XCTAssertEqual(layout.bar.cards.maxStart, 1, "7 windows, 6 on a page")

        // The bar's `▼` sends `.cardStep(capacity)`; the state accepts exactly that (clamped to the
        // last page, which starts at `windowCount - capacity`).
        XCTAssertEqual(layout.action(row: layout.bar.cards.rect.maxRow, col: layout.barCol),
                       .cardStep(6))
        XCTAssertEqual(layout.action(row: layout.bar.cards.rect.row, col: layout.barCol),
                       .cardStep(-6))
        state.apply(.cardStep(6), displays: model.displays.count, windows: model.windows.count,
                    capacity: layout.capacity)
        XCTAssertEqual(state.cardStart, 1, "a page forward lands on the last page")
        state.apply(.cardStep(6), displays: model.displays.count, windows: model.windows.count,
                    capacity: layout.capacity)
        XCTAssertEqual(state.cardStart, 1, "and stays there")
        state.apply(.cardStep(-6), displays: model.displays.count, windows: model.windows.count,
                    capacity: layout.capacity)
        XCTAssertEqual(state.cardStart, 0, "back to the landing page")
    }

    /// A page of two rows has to be painted as one: every card gets its box, every box its own
    /// caption directly under it, the band header counts what the page holds (`1-6 / 7`) while still
    /// printing the row width (`> 3`), and the bar's `╵` closes the section on its last row instead
    /// of in the middle of it.
    func testATwoRowPagePaintsBothRowsAndOneCaptionEach() {
        let model = model()
        let symbols = WallSymbols.ascii
        let cols = 118, rows = 73
        let state = fixtureState()
        let layout = state.layout(cols: cols, rows: rows, displays: model.displays.count,
                                  windows: model.windows.count,
                                  stageAspect: 1.6, cellAspect: 33.0 / 17.0)
        let lines = WallCanvas(symbols: symbols).lines(cols: cols, rows: rows, model: model,
                                                      layout: layout, focus: nil)
        XCTAssertEqual(layout.cards.count, 6)
        XCTAssertEqual(layout.cardRowCount, 2)
        for (i, card) in layout.cards.enumerated() {
            XCTAssertEqual(cellAt(lines[card.row - 1], card.col), Character(symbols.boxTL),
                           "card \(i): (row \(card.row), col \(card.col)) is not its top-left corner")
            XCTAssertEqual(cellAt(lines[card.row - 1], card.maxCol), Character(symbols.boxTR),
                           "card \(i): its top-right corner is not at its own last column")
            XCTAssertEqual(cellAt(lines[card.maxRow - 1], card.col), Character(symbols.boxBL),
                           "card \(i): its bottom border is not on its own last row")
            // The caption sits on the row right under the picture, starting at its left column.
            XCTAssertEqual(cellAt(lines[card.maxRow], card.col), Character(symbols.window),
                           "card \(i): the caption is not directly under it")
            XCTAssertTrue(lines[card.maxRow].contains("\(symbols.dash)"),
                          "card \(i): the caption row is empty")
        }
        // Row two starts under row one's caption, not over it.
        XCTAssertEqual(layout.cards[3].row, layout.cards[0].maxRow + 2)
        // The band header: the row width on the right, what the page holds on the left.
        XCTAssertTrue(lines[layout.bandRow - 1].contains("\(symbols.perButton) 3"),
                      "the band header still prints the row width: \(lines[layout.bandRow - 1].debugDescription)")
        XCTAssertTrue(lines[layout.bandRow - 1].contains("1-6 / 7"),
                      "the range counts the page, not the row: \(lines[layout.bandRow - 1].debugDescription)")
        // The bottom cap of the bar is on the section's last row (the row under the segment), which
        // is two rows below the last caption - not on the first row's caption.
        XCTAssertEqual(cellAt(lines[layout.bar.cards.rect.maxRow], layout.barCol),
                       Character(symbols.capBottom),
                       "the lower segment's cap is not at the bottom of the section")
        XCTAssertGreaterThan(layout.bar.cards.rect.maxRow + 1, layout.cardCaptions[0].row,
                             "and it is not on the first caption row")
        XCTAssertEqual(layout.bar.cards.rect.maxRow + 1, layout.footerRow - 2,
                       "the blank row and the footer are under the section")
    }

    /// The three lines are centred in the card's interior, because what phase 1 draws there is the
    /// §4 mask (centred in its rectangle), not the picture yet. Two things must not change with it:
    /// an interior with no room to centre keeps the block at the top, and a squeezed card keeps only
    /// the lines that fit.
    func testTheCardTextBlockIsCentredInItsInterior() {
        let model = model()
        let symbols = WallSymbols.emoji
        let canvas = WallCanvas(symbols: symbols)

        // The common card: 43 wide and as tall as the 7:3 split leaves (10 rows at 137x44, 13 in
        // the design's own table). The block is centred in the interior, so its top follows from
        // `card.rows` rather than from a pinned row number.
        let wide = makeLayout(fixtureState(), cols: 137, rows: 44, model)
        let lines = canvas.lines(cols: 137, rows: 44, model: model, layout: wide, focus: nil)
        let card = wide.cards[0]
        XCTAssertEqual(card.cols, 43)
        let interior = card.rows - 2
        let blockTop = card.row + 1 + max(0, (interior - 3) / 2)
        XCTAssertTrue(cardInterior(lines, row: blockTop, card)
                        .hasPrefix("\(symbols.window) Brave Browser"),
                      "the app line leads the block, at the block's left edge")
        XCTAssertTrue(cardInterior(lines, row: blockTop + 1, card).hasPrefix("「沒有人知道"),
                      "the title is the block's second line")
        XCTAssertTrue(cardInterior(lines, row: blockTop + 2, card)
                        .hasPrefix("1452\(symbols.times)1050"),
                      "the size is the block's third line")
        for row in (card.row + 1)..<(max(blockTop, card.row + 1)) {
            XCTAssertEqual(cardInterior(lines, row: row, card), blankInterior(card),
                           "row \(row) is above the centred block and has to be empty")
        }
        for row in (blockTop + 3)..<(max(card.maxRow, blockTop + 3)) {
            XCTAssertEqual(cardInterior(lines, row: row, card), blankInterior(card),
                           "row \(row) is below the centred block and has to be empty")
        }

        // No room to centre: a 4-row card (2 interior rows) still starts at the top, and a 3-row
        // card (1 interior row) draws only the app line. Both are today's behaviour, kept on
        // purpose — the mask has to fill the short frame, not float in it.
        //
        // 22 and 18 rows are the smallest panes that still have a card band at all: the 7:3 split
        // gives the stage round(0.7 * budget) rows, a band under `minCardRows` is dropped, and its
        // rows go to the stage instead.
        for (rows, cardH, shown) in [(22, 4, 2), (18, 3, 1)] {
            let small = makeLayout(fixtureState(), cols: 60, rows: rows, model)
            let smallLines = canvas.lines(cols: 60, rows: rows, model: model, layout: small,
                                          focus: nil)
            let box = small.cards[0]
            XCTAssertEqual(box.rows, cardH, "60x\(rows): card height")
            XCTAssertTrue(cardInterior(smallLines, row: box.row + 1, box)
                            .hasPrefix("\(symbols.window) Brave"),
                          "60x\(rows): the app line stays on the first interior row")
            if shown == 2 {
                XCTAssertTrue(cardInterior(smallLines, row: box.row + 2, box)
                                .hasPrefix("「沒有人知道"),
                              "60x\(rows): the title takes the second and last interior row")
                XCTAssertFalse(cardInterior(smallLines, row: box.row + 2, box)
                                .contains("1452"),
                               "60x\(rows): the size line does not fit and must not be squeezed in")
            } else {
                // The card is a slot now, so its left column is not the pane's first: compare the
                // border without the margin in front of it.
                XCTAssertTrue(smallLines[box.maxRow - 1].trimmingCharacters(in: .whitespaces)
                                .hasPrefix(symbols.boxBL),
                              "60x\(rows): the row under the app line is the card's bottom border")
            }
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

    /// `capacity:` is required, and it is `WallLayout.capacity` — the page size, i.e. exactly the
    /// number of cards the layout fits (`per` x the rows of them the band holds). In these
    /// transitions the pages are one row tall, so `3` is both the row width and the page;
    /// `testEveryWindowIsReachableOnANarrowPane` and `testAPageOfTwoRowsStepsBySix` are the cases
    /// where the two differ.
    func testStateStepsClampAtBothEnds() {
        var state = fixtureState()
        state.apply(.stageStep(-1), displays: 3, windows: 7, capacity: 3)
        XCTAssertEqual(state.stageStart, 0, "a step back from the first display stops at 0")
        state.apply(.stageStep(1), displays: 3, windows: 7, capacity: 3)
        XCTAssertEqual(state.stageStart, 1)
        state.apply(.stageStep(5), displays: 3, windows: 7, capacity: 3)
        XCTAssertEqual(state.stageStart, 2, "the last display is displayCount - 1")

        XCTAssertEqual(state.cardStart, 0)
        state.apply(.cardStep(-3), displays: 3, windows: 7, capacity: 3)
        XCTAssertEqual(state.cardStart, 0, "a page back from the first page stops at 0")
        state.apply(.cardStep(3), displays: 3, windows: 7, capacity: 3)
        XCTAssertEqual(state.cardStart, 3)
        state.apply(.cardStep(3), displays: 3, windows: 7, capacity: 3)
        XCTAssertEqual(state.cardStart, 4, "one page past the end stops at windowCount - per")
        state.apply(.cardStep(3), displays: 3, windows: 7, capacity: 3)
        XCTAssertEqual(state.cardStart, 4, "and stays there")
        // Fewer windows than one page: there is nothing to scroll in either direction.
        state.apply(.cardStep(-3), displays: 3, windows: 2, capacity: 3)
        XCTAssertEqual(state.cardStart, 0)
        state.apply(.cardStep(3), displays: 3, windows: 2, capacity: 3)
        XCTAssertEqual(state.cardStart, 0)
    }

    func testStateJumpsSetTheStart() {
        var state = fixtureState()
        state.apply(.stageJump(2), displays: 3, windows: 7, capacity: 3)
        XCTAssertEqual(state.stageStart, 2)
        state.apply(.cardJump(4), displays: 3, windows: 7, capacity: 3)
        XCTAssertEqual(state.cardStart, 4)
        // A jump carries a proportion computed from the bar, so it is clamped, never trusted.
        state.apply(.stageJump(99), displays: 3, windows: 7, capacity: 3)
        XCTAssertEqual(state.stageStart, 2)
        state.apply(.cardJump(-5), displays: 3, windows: 7, capacity: 3)
        XCTAssertEqual(state.cardStart, 0)
    }

    func testStateEnterSetsFocusAndBackClearsIt() {
        var state = fixtureState()
        state.apply(.enterStage(2), displays: 3, windows: 7, capacity: 3)
        XCTAssertEqual(state.focus, WallState.Focus.display(2))
        XCTAssertEqual(state.stageStart, 2, "entering a display also brings it on stage")
        state.apply(.enterCard(5), displays: 3, windows: 7, capacity: 3)
        XCTAssertEqual(state.focus, WallState.Focus.window(5))
        XCTAssertEqual(state.cardStart, 0, "entering a card must not move the shelf")
        state.apply(.back, displays: 3, windows: 7, capacity: 3)
        XCTAssertNil(state.focus)
        XCTAssertEqual(state.cardStart, 0)
        // The payloads are indices into the whole list, and they are clamped to the model.
        state.apply(.enterCard(99), displays: 3, windows: 7, capacity: 3)
        XCTAssertEqual(state.focus, WallState.Focus.window(6))
        state.apply(.enterStage(99), displays: 3, windows: 7, capacity: 3)
        XCTAssertEqual(state.focus, WallState.Focus.display(2))
        XCTAssertEqual(state.stageStart, 2)
    }

    func testStateClampPullsBothOffsetsBackIntoRange() {
        var state = fixtureState()
        state.stageStart = 2
        state.cardStart = 4
        // A monitor unplugged and the windows closed while the wall was showing page two.
        state.clamp(displays: 1, windows: 2, capacity: 3)
        XCTAssertEqual(state.stageStart, 0)
        XCTAssertEqual(state.cardStart, 0)
        // The rack grew again: the clamp never invents an offset past the end.
        state.clamp(displays: 3, windows: 7, capacity: 3)
        XCTAssertEqual(state.stageStart, 0)
        XCTAssertEqual(state.cardStart, 0)
    }

    /// The wall has no keyboard vocabulary: every one of the 256 bytes belongs to a remote that does
    /// not exist, except `Ctrl-\`, which the reader still turns into "quit". A consumed key must
    /// never reach `postKey`/`postUnicode` — and on the wall it must not even be *logged* as injected,
    /// because that log's sink is the pane the wall is drawn on (`InputReader(forward:)`).
    ///
    /// This pins the policy table; `WallProcessTests` pins the bytes that actually reach the tty.
    func testTheWallConsumesEveryKeyExceptQuit() {
        var passedBack: [UInt8] = []
        for byte in UInt8.min...UInt8.max where !WallInput.consumes(byte) {
            passedBack.append(byte)
        }
        XCTAssertEqual(passedBack, [0x1C], "Ctrl-\\ is the only byte the wall hands back to the reader")
    }

    /// The bug this test exists for: the shelf was clamped against the *requested* page size while
    /// `WallLayout.make` shrinks its page to keep a card readable, so below 28 columns the two
    /// disagreed about `maxStart`. 27x24/7 windows: the layout's last page starts at 5, the state
    /// clamped to 4 — the bar's shaft cell computes `.cardJump(5)`, `apply` dragged it back to 4 and
    /// nothing moved, so the last window (at 12–18 columns, the last two) could not be reached by
    /// any click at all.
    ///
    /// One pass per pane width, starting from the landing page: step a whole page until the shelf
    /// stops moving, and require the stop to *be* the layout's last page, with the last window on
    /// it. Then the same place through a jump, which is what a click on the shaft actually sends.
    func testEveryWindowIsReachableOnANarrowPane() {
        let windows = 7, displays = 3, rows = 24
        for cols in 12...60 {
            var state = fixtureState()              // cardStart = 0: the landing page
            let layout = state.layout(cols: cols, rows: rows, displays: displays, windows: windows)
            // `.cardStep(capacity)` is what the bar's `▼` sends (design §5: one page is one step).
            for _ in 0..<64 {                        // the guard only keeps a broken clamp from spinning
                let before = state.cardStart
                state.apply(.cardStep(layout.capacity), displays: displays, windows: windows,
                            capacity: layout.capacity)
                if state.cardStart == before { break }
            }
            let lastPage = layout.bar.cards.maxStart
            XCTAssertEqual(state.cardStart, lastPage,
                           "\(cols)x\(rows): the shelf stops at \(state.cardStart), the layout's last "
                           + "page is \(lastPage) (capacity \(layout.capacity) of \(windows))")
            XCTAssertGreaterThan(state.cardStart + layout.capacity, windows - 1,
                                 "\(cols)x\(rows): window \(windows) is not on the final page")
            var jumped = fixtureState()
            jumped.apply(.cardJump(lastPage), displays: displays, windows: windows,
                         capacity: layout.capacity)
            XCTAssertEqual(jumped.cardStart, state.cardStart,
                           "\(cols)x\(rows): a jump to the layout's maxStart must land there")
            // And through the real click route, shaft cell by shaft cell: what the layout's own hit
            // table computes must be what the state accepts. This is the cell the review clicked.
            let segment = layout.bar.cards
            guard segment.scrollable, segment.rect.rows >= 3 else { continue }
            for row in (segment.rect.row + 1)..<segment.rect.maxRow {
                guard let action = layout.action(row: row, col: layout.barCol) else { continue }
                var clicked = fixtureState()
                clicked.apply(action, displays: displays, windows: windows,
                              capacity: layout.capacity)
                XCTAssertEqual(clicked.cardStart,
                               segment.jumpTarget(shaftOffset: row - segment.rect.row - 1),
                               "\(cols)x\(rows): shaft cell \(row) jumps where the state refuses to go")
            }
        }
    }

    // MARK: the row-width control on the band header (issue #112)

    /// The control the band header promises: the three cells of `layout.bandTail` are exactly the
    /// drawn `⤢ 3` / `> 3` — glyph, blank, digit — in both symbol tables, the cell to their left is
    /// the blank column that keeps the glyph off the label, and those three cells are exactly the
    /// ones `action(row:col:)` answers. The defect was a glyph with no rectangle, so the rect, the
    /// glyph and the click are all pinned here, at three pane sizes.
    func testTheBandTailCellsAreTheDrawnRowWidthControl() {
        let model = model()
        for (cols, rows) in [(137, 44), (100, 36), (60, 24)] {
            for symbols in WallSymbols.allCases {
                let layout = fixtureState().layout(cols: cols, rows: rows,
                                                  displays: model.displays.count,
                                                  windows: model.windows.count)
                let label = "\(cols)x\(rows) \(symbols.rawValue)"
                XCTAssertFalse(layout.bandTail.isEmpty, "\(label): a wide pane draws the control")
                let line = WallCanvas(symbols: symbols)
                    .lines(cols: cols, rows: rows, model: model, layout: layout,
                           focus: nil)[layout.bandRow - 1]
                XCTAssertEqual(cellAt(line, layout.bandTail.col), symbols.perButton.first,
                               "\(label): the glyph sits on the rect's first cell")
                XCTAssertEqual(cellAt(line, layout.bandTail.col + 1), " ",
                               "\(label): the rect's middle cell is the blank")
                XCTAssertEqual(cellAt(line, layout.bandTail.maxCol), Character("\(layout.per)"),
                               "\(label): the digit sits on the rect's last cell")
                XCTAssertEqual(cellAt(line, layout.bandTail.col - 1), " ",
                               "\(label): one blank column keeps the glyph off the label")
                // …and the cells that show the control are exactly the cells that answer.
                let want = WallLayout.nextPer(after: layout.per, paneCols: cols)
                for col in layout.bandTail.col...layout.bandTail.maxCol {
                    XCTAssertEqual(layout.action(row: layout.bandRow, col: col),
                                   want.map(WallAction.cyclePer),
                                   "\(label): (\(layout.bandRow),\(col)) shows the control")
                }
                XCTAssertNil(layout.action(row: layout.bandRow, col: layout.bandTail.col - 1),
                             "\(label): the blank column before the glyph is not a target")
            }
        }
    }

    /// The issue's three clicks: at 137x44 the control walks `⤢ 3 → ⤢ 4 → ⤢ 2` and the page follows,
    /// because `capacity = per x cardRowCount` and the band's row count is not what changed. Four
    /// windows, so the range says what the page holds and a reader can watch a row of three become a
    /// row of four.
    func testACycleMovesTheGlyphThePageAndTheRange() {
        var model = model()
        model.windows = Array(model.windows.prefix(4))
        let cols = 137, rows = 44
        let displays = model.displays.count, windows = model.windows.count
        // The glyph's number, the page size, how many cards are drawn and the range beside it.
        let expected: [(per: Int, capacity: Int, cards: Int, range: String)] = [
            (3, 3, 3, "1–3 / 4"),
            (4, 4, 4, "1–4 / 4"),
            (2, 2, 2, "1–2 / 4"),
            (3, 3, 3, "1–3 / 4"),
        ]
        // Both symbol tables: the ascii mode spells the same glyph and the same dash, and a cycle
        // that only worked on `⤢` would be a cycle that only worked on one terminal.
        for symbols in WallSymbols.allCases {
            var state = fixtureState()
            let canvas = WallCanvas(symbols: symbols)
            for (i, want) in expected.enumerated() {
                let layout = state.layout(cols: cols, rows: rows, displays: displays, windows: windows)
                let label = "\(symbols.rawValue) click \(i): per \(want.per)"
                XCTAssertEqual(layout.per, want.per, label)
                XCTAssertEqual(layout.capacity, want.capacity, "\(label): the page follows the row width")
                XCTAssertEqual(layout.cards.count, want.cards, "\(label): \(want.cards) cards are drawn")
                let line = canvas.lines(cols: cols, rows: rows, model: model, layout: layout,
                                        focus: nil)[layout.bandRow - 1]
                XCTAssertTrue(line.contains("\(symbols.perButton) \(want.per)"),
                              "\(label): the header is \(line.debugDescription)")
                XCTAssertTrue(line.contains(want.range.replacingOccurrences(of: "–",
                                                                         with: symbols.enDash)),
                              "\(label): the range is \(line.debugDescription)")
                guard i + 1 < expected.count else { break }
                guard let action = layout.action(row: layout.bandRow, col: layout.bandTail.col) else {
                    return XCTFail("\(label): the control answers nothing")
                }
                XCTAssertEqual(action, .cyclePer(expected[i + 1].per),
                               "\(label): the glyph asks for the next width the pane honours")
                state.apply(action, displays: displays, windows: windows, capacity: layout.capacity)
            }
            // A payload outside the cycle is clamped rather than trusted: the layout lowers what it
            // must anyway, but the state never stores a width wider than the cycle allows; `make`
            // lowers whatever this pane cannot honour.
            state.apply(.cyclePer(9), displays: displays, windows: windows, capacity: 3)
            XCTAssertEqual(state.per, 4, "clamped to the widest row the cycle offers")
        }
    }

    /// A cycle does not move the shelf: the page size depends on the band's row count as well, and
    /// `WallLayout.make` already clamps `cardStart` on every draw (`firstCard`). So the page after a
    /// cycle is never empty, and the last page is still reachable with the bar's own
    /// `.cardStep(capacity)` — the naive `per % 4 + 1` clamp the contract rejects would lose it.
    func testACycleKeepsThePageValidAndTheLastPageReachable() {
        let model = model()                                  // 7 windows, 3 displays
        let cols = 137, rows = 44
        let displays = model.displays.count, windows = model.windows.count
        var state = fixtureState()
        // Page two of three at per 3 (the landing page is 0…2), then widen the row.
        state.cardStart = 3
        state.apply(.cyclePer(4), displays: displays, windows: windows, capacity: 3)
        XCTAssertEqual(state.per, 4)
        XCTAssertEqual(state.cardStart, 3, "the state does not move the shelf")
        let wider = state.layout(cols: cols, rows: rows, displays: displays, windows: windows)
        XCTAssertEqual(wider.capacity, 4)
        XCTAssertEqual(wider.cardStart, 3, "and the layout's own clamp leaves it there")
        XCTAssertEqual(wider.cards.count, 4, "the page is not empty: windows 3, 4, 5, 6")
        XCTAssertEqual(wider.bar.cards.maxStart, windows - wider.capacity)
        XCTAssertEqual(state.cardStart, wider.bar.cards.maxStart, "…and it is the last page")

        // From the landing page, one page forward lands on that same last page with four cards.
        var landing = fixtureState()
        landing.apply(.cyclePer(4), displays: displays, windows: windows, capacity: 3)
        landing.apply(.cardStep(wider.capacity), displays: displays, windows: windows,
                      capacity: wider.capacity)
        XCTAssertEqual(landing.cardStart, windows - wider.capacity)
        let last = landing.layout(cols: cols, rows: rows, displays: displays, windows: windows)
        XCTAssertEqual(last.cards.count, 4)
        XCTAssertEqual(last.cardStart + last.cards.count, windows,
                       "the last page ends on the last window")
        let line = WallCanvas(symbols: .emoji)
            .lines(cols: cols, rows: rows, model: model, layout: last,
                   focus: nil)[last.bandRow - 1]
        XCTAssertTrue(line.contains("4–7 / 7"),
                      "the range follows the page it is on: \(line.debugDescription)")
    }

    /// The review's repro, and the reason a draw writes the layout's clamp back before it paints.
    ///
    /// `apply(.cyclePer)` leaves `cardStart` alone on purpose, and `WallLayout.make` is what pulls it
    /// back when a wider row leaves fewer windows after it. `refreshWall` skips its clamp while the
    /// model and the pane stand still (`main.swift:1364`), and a click changes neither — so without `adopt` the
    /// state would keep stepping from the offset the reader has left behind, and the next `▲`/`▼`
    /// would land on a page nobody was shown.
    func testTheStateAdoptsThePageTheDrawPutOnScreen() {
        var model = model()
        model.windows.append(model.windows[0])       // 8 windows: (7 + a duplicate) of ids
        let cols = 137, rows = 44
        let displays = model.displays.count, windows = model.windows.count
        func bandLine(_ state: WallState) -> String {
            let layout = state.layout(cols: cols, rows: rows, displays: displays, windows: windows)
            return WallCanvas(symbols: .emoji)
                .lines(cols: cols, rows: rows, model: model, layout: layout,
                       focus: nil)[layout.bandRow - 1]
        }

        var state = fixtureState()
        state.cardStart = 5                          // the last page at row width 3 (capacity 3)
        let before = state.layout(cols: cols, rows: rows, displays: displays, windows: windows)
        XCTAssertEqual(before.capacity, 3)
        XCTAssertEqual(before.cardStart, 5)
        XCTAssertTrue(bandLine(state).contains("6–8 / 8"), "\(bandLine(state).debugDescription)")

        state.apply(.cyclePer(4), displays: displays, windows: windows, capacity: before.capacity)
        XCTAssertEqual(state.per, 4)
        XCTAssertEqual(state.cardStart, 5, "`apply` does not move the shelf: the layout does")
        let wider = state.layout(cols: cols, rows: rows, displays: displays, windows: windows)
        XCTAssertEqual(wider.capacity, 4, "the wider row holds one card more")
        XCTAssertEqual(wider.cardStart, 4, "so the last page starts one window earlier")
        XCTAssertTrue(bandLine(state).contains("5–8 / 8"),
                      "and that is what is on screen: \(bandLine(state).debugDescription)")

        // Without the write-back the next page step starts from 5 — the page the reader was on one
        // frame ago, when the row held three (`6–8 / 8`) — while the screen shows the page that
        // starts at 4. Four back from 5 is start index 1, so the step lands on `2–5 / 8`, which
        // shares exactly one card (window 5) with the `5–8 / 8` on screen.
        var stale = state
        stale.apply(.cardStep(-wider.capacity), displays: displays, windows: windows,
                    capacity: wider.capacity)
        XCTAssertEqual(stale.cardStart, 1, "stepping from the offset the reader has left behind")
        XCTAssertTrue(bandLine(stale).contains("2–5 / 8"), "\(bandLine(stale).debugDescription)")

        // What `drawWall` does, and what the reader gets instead.
        state.adopt(wider)
        XCTAssertEqual(state.cardStart, 4, "the state holds the page on screen")
        state.apply(.cardStep(-wider.capacity), displays: displays, windows: windows,
                    capacity: wider.capacity)
        XCTAssertEqual(state.cardStart, 0, "one page back from the page that is on screen")
        XCTAssertTrue(bandLine(state).contains("1–4 / 8"), "\(bandLine(state).debugDescription)")
    }

    /// The other half of the issue: at 40x15 the layout drops the card section, so the header used to
    /// promise `1–3 / 7` and a `⤢ 3` over a pane drawing zero cards (the issue's own photograph has
    /// four windows, hence its `1–3 / 4`). Now it says `no room`, prints no range and draws no
    /// control — and the cells that used to carry the glyph answer nothing.
    func testAPaneWithoutACardBandSaysNoRoomAndDrawsNoControl() {
        let model = model()
        let cols = 40, rows = 15
        let layout = fixtureState().layout(cols: cols, rows: rows,
                                          displays: model.displays.count,
                                          windows: model.windows.count)
        XCTAssertEqual(layout.cardBandRows, 0, "40x15 has no card band")
        XCTAssertTrue(layout.cards.isEmpty)
        XCTAssertTrue(layout.bandTail.isEmpty, "no card to change the width of, so no control")
        for symbols in WallSymbols.allCases {
            let line = WallCanvas(symbols: symbols)
                .lines(cols: cols, rows: rows, model: model, layout: layout,
                       focus: nil)[layout.bandRow - 1]
            XCTAssertTrue(line.contains("no room"),
                          "\(symbols.rawValue): the header is \(line.debugDescription)")
            XCTAssertFalse(line.contains(symbols.perButton),
                           "\(symbols.rawValue): a control that cannot act is not drawn")
            XCTAssertFalse(line.contains(" / "),
                           "\(symbols.rawValue): and no range: \(line.debugDescription)")
            XCTAssertFalse(line.contains(symbols.enDash),
                           "\(symbols.rawValue): not even a dash: \(line.debugDescription)")
        }
        for col in 1..<cols {
            XCTAssertNil(layout.action(row: layout.bandRow, col: col), "band header cell \(col)")
        }
    }

    /// …and the *other* reason a control can be missing: a pane that honours a single row width has
    /// nowhere to cycle to, so the glyph goes even though the band — and its range — are on screen.
    /// This is the pane the review's mutant fooled: a painter that fell back to right-aligning the
    /// glyph when the rect was empty drew `⤢ 2` over cells that answer nothing, i.e. exactly the
    /// defect #112 is about. Both panes here draw cards, so `no room` must **not** appear.
    func testAPaneWithOneHonouredWidthDrawsNoControlButKeepsItsRange() {
        let model = model()
        for (cols, rows) in [(20, 24), (26, 24)] {
            let layout = fixtureState().layout(cols: cols, rows: rows,
                                              displays: model.displays.count,
                                              windows: model.windows.count)
            let label = "\(cols)x\(rows)"
            XCTAssertEqual(WallLayout.perChoices(paneCols: cols).count, 1, "\(label): one row width")
            XCTAssertFalse(layout.cards.isEmpty, "\(label): the band is on screen")
            XCTAssertTrue(layout.bandTail.isEmpty, "\(label): so the control is not")
            for symbols in WallSymbols.allCases {
                let line = WallCanvas(symbols: symbols)
                    .lines(cols: cols, rows: rows, model: model, layout: layout,
                           focus: nil)[layout.bandRow - 1]
                XCTAssertFalse(line.contains(symbols.perButton),
                               "\(label) \(symbols.rawValue): no glyph over a dead rect: "
                               + "\(line.debugDescription)")
                XCTAssertFalse(line.contains("no room"),
                               "\(label) \(symbols.rawValue): the band is there: "
                               + "\(line.debugDescription)")
                XCTAssertTrue(line.contains("\(layout.cardStart + 1)"),
                              "\(label) \(symbols.rawValue): the range is not: "
                              + "\(line.debugDescription)")
            }
            // Every cell of that row is wall: nothing pretends to be pressable.
            for col in 1..<cols where col != layout.barCol {
                XCTAssertNil(layout.action(row: layout.bandRow, col: col),
                             "\(label): band header cell \(col)")
            }
        }
    }

    /// The header's own budget: the glyph keeps its cells plus the blank column before it, so a range
    /// long enough to reach the right edge must be truncated *before* it, not painted over the
    /// control. Only an absurd window count makes the range that long, which is exactly why nothing
    /// else notices if the budget is wrong.
    func testALongRangeNeverPaintsOverTheControl() {
        let model = model()
        let cols = 30, rows = 24
        let layout = WallLayout.make(paneCols: cols, paneRows: rows, displayCount: 1,
                                     windowCount: 123_456_789, per: 3, stageStart: 0, cardStart: 0)
        XCTAssertFalse(layout.bandTail.isEmpty, "30x24 honours two row widths, so there is a control")
        for symbols in WallSymbols.allCases {
            let line = WallCanvas(symbols: symbols)
                .lines(cols: cols, rows: rows, model: model, layout: layout,
                       focus: nil)[layout.bandRow - 1]
            // Glyph, blank, digit: the three cells the control reserved, none of them touched by
            // the range. With the budget wrong, the range reaches `bandTail.col` and `bandTail.col
            // + 1` and the row reads `… 123456 ⤢ 3` — a live cell with the wrong glyph on it.
            XCTAssertEqual(cellAt(line, layout.bandTail.col), symbols.perButton.first,
                           "\(symbols.rawValue): the glyph is still there: \(line.debugDescription)")
            XCTAssertEqual(cellAt(line, layout.bandTail.col + 1), " ",
                           "\(symbols.rawValue): its blank is still blank: \(line.debugDescription)")
            XCTAssertEqual(cellAt(line, layout.bandTail.maxCol), Character("\(layout.per)"),
                           "\(symbols.rawValue): the digit is still the row width: "
                           + "\(line.debugDescription)")
            XCTAssertTrue(line.contains("12345"),
                          "\(symbols.rawValue): the range is truncated, not dropped: "
                          + "\(line.debugDescription)")
            XCTAssertFalse(line.contains("123456789"),
                           "\(symbols.rawValue): it does not fit: \(line.debugDescription)")
        }
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

    /// The text cells of a card on `row`: inside the two borders *and* the one blank cell each side
    /// keeps, i.e. exactly `rect.cols - 4` characters. The callers only ask this about card 0, which
    /// starts at column 1, so no wide glyph to its left can shift the character indexing (inside the
    /// frame there is either one block of text or nothing).
    /// The cell at `col` of a `lines` row. Not `Array(line)[col - 1]`: a CJK title makes a Character
    /// index shorter than the cell it sits at, and caption rows carry titles.
    private func cellAt(_ line: String, _ col: Int) -> Character? {
        var at = 1
        for ch in line {
            let width = DisplayWidth.of(ch)
            if at == col { return ch }
            at += width
            if at > col { return " " }              // the second half of a wide glyph
        }
        return nil
    }

    private func cardInterior(_ lines: [String], row: Int, _ rect: CellRect) -> String {
        let chars = Array(lines[row - 1])
        let lo = rect.col + 1, hi = rect.maxCol - 3
        guard hi >= lo, chars.count > hi else { return "" }
        return String(chars[lo...hi])
    }

    /// What `cardInterior` reads for an empty one, so "blank" is a comparison and not an absence.
    private func blankInterior(_ rect: CellRect) -> String {
        String(repeating: " ", count: max(0, rect.cols - 4))
    }

    /// Replay a byte stream onto a blank pane and read it out again.
    private func replay(_ bytes: [UInt8], cols: Int, rows: Int) -> [String] {
        replay([bytes], cols: cols, rows: rows)
    }

    /// Replay a *sequence* of streams onto **one** pane and read the grid out only after the last
    /// one — a terminal that drew two frames keeps whatever the second stream forgot to overwrite.
    /// It understands exactly what the painter emits — `ESC[<row>;<col>H`, `ESC[<sgr>m` (styles
    /// ignored: the goldens are what pin them) and UTF-8 text — and it reads the cursor after every
    /// write, so it is an independent second opinion on both the positions and the wide-glyph cells.
    /// The cursor survives from one stream to the next, like a terminal's.
    private func replay(_ streams: [[UInt8]], cols: Int, rows: Int) -> [String] {
        var cells = [Character](repeating: " ", count: cols * rows)
        /// True for the second cell of a wide glyph: it is covered by the character before it.
        var covered = [Bool](repeating: false, count: cols * rows)
        var row = 1, col = 1
        for bytes in streams {
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
                    // Writing into a cell un-covers it: on a second frame the pane may still have a
                    // wide glyph's continuation cell here, and a stale flag would hide the glyph
                    // this stream just put there (the painter always writes both halves of a wide
                    // glyph it erases, so the flag is cleared by the write, not by the readout).
                    covered[(row - 1) * cols + (col - 1)] = false
                    if width == 2 { covered[(row - 1) * cols + col] = true }
                    col += width
                }
                i = j
            }
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

    /// Design §6.6: the picture keeps its own proportions. A band that is wider than the panel gets
    /// a narrower box centred in it, and a rotated panel gets a shorter one — the box never grows
    /// past either edge, which is also the rect the capture path will fill.
    func testTheStageBoxKeepsTheDisplaysProportions() {
        let band = CellRect(col: 1, row: 1, cols: 135, rows: 24)
        // 16:10 landscape in a 2.9:1 band (17x33 cells): height-bound, 75 wide at 17x33.
        let land = WallCanvas.fittedRect(aspect: 1920.0 / 1200.0, inside: band,
                                        cellW: 17, cellH: 33)
        XCTAssertEqual(land.rows, 24)
        XCTAssertEqual(land.cols, 75)
        XCTAssertEqual(land.col, 1 + (135 - 75) / 2)
        // 9:16 portrait in the same band: still height-bound, just a narrow box centred in it —
        // the picture is not squashed to fill the width.
        let port = WallCanvas.fittedRect(aspect: 1200.0 / 1920.0, inside: band,
                                        cellW: 17, cellH: 33)
        XCTAssertEqual(port.cols, 29)
        XCTAssertEqual(port.rows, 24)
        XCTAssertEqual(port.col, 1 + (135 - 29) / 2)
        // A band narrower than the picture: now the width is the constraint and the box is short.
        let narrow = WallCanvas.fittedRect(aspect: 1.6, inside: CellRect(col: 0, row: 0, cols: 20, rows: 40),
                                          cellW: 17, cellH: 33)
        XCTAssertEqual(narrow.cols, 20)
        XCTAssertEqual(narrow.rows, 6)
        XCTAssertEqual(narrow.row, (40 - 6) / 2)
        // Nothing to go on: the band itself, so a display with no known size still draws.
        XCTAssertEqual(WallCanvas.fittedRect(aspect: 0, inside: band, cellW: 17, cellH: 33), band)
        XCTAssertEqual(WallCanvas.fittedRect(aspect: 1.6, inside: band, cellW: 0, cellH: 0), band)
    }

    /// The fallback contract: a slot whose capture failed draws the mask **on the same rectangle**
    /// the picture would have filled, and the caption row still names the thing.
    ///
    /// This is the half of "picture or mask, never a reflow" that can be asserted without a screen.
    /// The other half — a real failed capture reaching this state — is `PanelCapture.classify` plus
    /// one `catch` in `paintWall`; the case a reader actually hits (a window closed) is not even a
    /// mask: the window leaves the model and the next one takes the card.
    func testAPictureSlotLeavesItsCellsEmptyAndAMaskKeepsTheRect() {
        let model = WallModel(displays: [WallDisplay(name: "Built-in", width: 1512, height: 982,
                                                     id: 1, main: true)],
                              windows: [OrderedWindow(windowID: 11, pid: 1, app: "Safari",
                                                      title: "Apple", bounds: .init(x: 0, y: 0,
                                                                                    width: 1200, height: 800)),
                                        OrderedWindow(windowID: 12, pid: 2, app: "Notes",
                                                      title: "Memo", bounds: .init(x: 0, y: 0,
                                                                                  width: 900, height: 640))])
        let layout = WallLayout.make(paneCols: 137, paneRows: 44, displayCount: 1,
                                     windowCount: 2, per: 3, stageStart: 0, cardStart: 0)
        let canvas = WallCanvas(symbols: .emoji)

        // A picture in the stage: nothing of the placeholder survives inside the rect.
        var picturePaints = WallSlotPaints()
        picturePaints.mark(slot: 0, .picture)
        let pictured = canvas.lines(cols: 137, rows: 44, model: model, layout: layout,
                                    focus: nil, cellW: 17, cellH: 33, paints: picturePaints)
        // `lines` is 0-based, the layout is 1-based: index by row - 1, the way the rest of this
        // suite does.
        let stageRows = pictured[(layout.stage.row - 1)..<layout.stage.maxRow]
        XCTAssertFalse(stageRows.joined().contains("Built-in"), "no text under a placement")
        // ...and cleared, not merely skipped: the picture's bars are transparent, so anything an
        // earlier frame drew in these cells would show through them.
        for line in stageRows {
            XCTAssertEqual(line.count, 137)
            // Only the stage's own columns: the scroll bar shares these rows at column 137.
            let inside = line.prefix(layout.stage.cols)
            XCTAssertTrue(inside.allSatisfy { $0 == " " }, "a pictured slot must be blank: \(line)")
        }

        // A mask in the stage: the rect is still a box, and it says why it is empty.
        var maskPaints = WallSlotPaints()
        maskPaints.mark(slot: 0, .mask)
        let masked = canvas.lines(cols: 137, rows: 44, model: model, layout: layout,
                                  focus: nil, cellW: 17, cellH: 33, paints: maskPaints)
        let maskRows = masked[(layout.stage.row - 1)..<layout.stage.maxRow]
        XCTAssertTrue(maskRows.joined().contains("no picture"))
        // The caption row keeps naming the display, so only the pixels are lost.
        XCTAssertTrue(masked[layout.stageCaption.row - 1].contains("Built-in"))
    }
}


/// Four boxes saying "no picture" are not an answer to "why is my wall empty": when every panel
/// failed for want of the Screen Recording grant, the footer says so instead of how to click.
/// In the same file as `WallCanvasTests` on purpose: the fixture model and `makeLayout` are
/// private to it, and a second copy of them would be a second thing to keep in step.
extension WallCanvasTests {
    /// A card's caption goes under its **picture**, not under its box: the box is the slot's whole
    /// width and the picture inside it is fitted by aspect, so a 4:3 window in a 16:9 slot keeps
    /// margins either side. `cardPictureCells` is keyed by *slot* (1... are the cards, like
    /// `mark(slot:)`) while the painter walks the page by *index*, and mixing the two put card n's
    /// caption under card n-1's picture: on a page whose last row starts again at column 1 that drew
    /// a one-cell `…` at the right edge of the card (a page of 4 at 118x73 does exactly that).
    func testACardCaptionFollowsItsPictureNotItsBox() {
        let model = model()                                  // 7 windows
        let layout = makeLayout(fixtureState(), cols: 118, rows: 73, model)
        let box = layout.cards[0]
        XCTAssertGreaterThan(box.cols, 16, "the box has room for a narrower picture inside it")
        let picture = CellRect(col: box.col + 4, row: box.row, cols: box.cols - 8, rows: box.rows)
        var paints = WallSlotPaints()
        paints.mark(slot: 1, .picture)
        paints.cardPictureCells[1] = picture
        let lines = WallCanvas(symbols: .ascii).lines(cols: 118, rows: 73, model: model,
                                                     layout: layout, focus: nil, paints: paints)
        // `cellAt`, not `Array(line)[col]`: a caption row carries CJK titles, and a Character index
        // is not a column once one is on the row.
        let first = lines[layout.cardCaptions[0].row - 1]
        XCTAssertEqual(cellAt(first, picture.col), Character(WallSymbols.ascii.window),
                       "the caption starts under the picture, not under the box")
        for col in box.col..<picture.col {
            XCTAssertEqual(cellAt(first, col), " ", "cell \(col) is margin, not label")
        }
        // …and card 2's caption is its own: it was the one that used to inherit card 1's picture.
        let second = lines[layout.cardCaptions[1].row - 1]
        XCTAssertEqual(cellAt(second, layout.cards[1].col), Character(WallSymbols.ascii.window))
    }

    func testTheFooterNamesTheTerminalThatNeedsTheGrant() {
        let canvas = WallCanvas(symbols: .emoji)
        let model = model()
        let layout = makeLayout(fixtureState(), cols: 137, rows: 44, model)
        var paints = WallSlotPaints()
        for slot in 0...3 { paints.mark(slot: slot, .mask) }
        paints.notice = .screenRecordingDenied(terminal: "Apple_Terminal")
        let lines = canvas.lines(cols: 137, rows: 44, model: model, layout: layout, focus: nil,
                                 paints: paints)
        let footer = lines[layout.footerRow - 1]   // footerRow is 1-based
        XCTAssertTrue(footer.contains("grant Screen Recording to Terminal"), footer)
        XCTAssertFalse(footer.contains("click a card"), "the notice replaces the hint, not adds to it")
    }

    func testATerminalThatCannotDrawPicturesIsToldWhichOnesCan() {
        let notice = WallNotice.terminalCannotShowPictures(terminal: "Terminal")
        let text = notice.text(bullet: "-", dash: " - ")
        XCTAssertEqual(text, "- Terminal cannot draw pictures - use rex, Ghostty, kitty or WezTerm")
        // The *diagnosis* has to fit on the narrowest real pane (60 columns, 58 cells of content)
        // even when the list of alternatives is truncated after it.
        let diagnosis = "- Terminal cannot draw pictures"
        XCTAssertLessThan(diagnosis.count, 44)
        XCTAssertTrue(text.hasPrefix(diagnosis + " - use "), text)
    }

    func testAnUnknownTerminalGetsTheGenericSentence() {
        let notice = WallNotice.screenRecordingDenied(terminal: nil)
        XCTAssertEqual(notice.text(bullet: "-", dash: " - "),
                       "- no picture - grant Screen Recording to your terminal")
        // A named one keeps its own name: iTerm and friends are what the grant is actually given to.
        XCTAssertEqual(WallNotice.screenRecordingDenied(terminal: "WezTerm").text(bullet: "-", dash: " - "),
                       "- no picture - grant Screen Recording to WezTerm")
    }

    func testWithoutANoticeTheFooterStillExplainsTheClick() {
        let canvas = WallCanvas(symbols: .emoji)
        let model = model()
        let layout = makeLayout(fixtureState(), cols: 137, rows: 44, model)
        let lines = canvas.lines(cols: 137, rows: 44, model: model, layout: layout, focus: nil)
        XCTAssertTrue(lines[layout.footerRow - 1].contains("click a card"))
    }
}
