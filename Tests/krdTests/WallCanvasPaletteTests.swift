import XCTest
import krdcore
@testable import krd

/// The wall's two palette adopters, and the proof that there are only two (issue #213, decision D7).
///
/// The palette (`.pi-legion/contract.md` D2/D3) is a value derived from the two colours the terminal
/// answered to `OSC 10`/`OSC 11`. What this file pins is the *adoption*, which is a narrower claim
/// than "the wall is themed":
///
/// 1. **The chrome row draws the palette.** The wordmark (`▪ krd`) is the palette's accent, the
///    counts line its dim text, and the footer's lead sentence, its `N panels` tail and the demo note
///    are its dim text and foreground. Those are the cells where a fixed SGR is a *wrong* colour
///    rather than an unambitious one: `1;97` is the terminal's bright white and vanishes on a light
///    background, which is the bug the palette exists to fix.
/// 2. **One code path, two answers.** The same wall, drawn twice, once from a dark pair and once from
///    a light one, has to produce two different byte streams with two different colours in them — the
///    accent is contrast-checked against the background, so the light wall gets a darker blue. A
///    palette that were a global or a constant would pass every other test in this file.
/// 3. **No palette is today's table, byte for byte.** `WallPalette.none` is the default, so the four
///    golden dumps (`WallCanvasTests.testTheFourDumpsAreTheWallByteForByte`) and every existing call
///    site keep the bytes they had; a wall must emit no `38;2;` at all when the terminal answered
///    nothing (contract D4).
/// 4. **The palette is applied once and diffed.** The same palette twice is 0 bytes — the wall's §5.1
///    idle rule, which is also why a theme switch costs one repaint — and a *changed* palette
///    re-emits the header and footer rows and nothing else. That last assertion is the one that
///    proves the adoption did not leak into the stage, the cards or the bar: a single stray
///    `palette.accent` in `drawCards` would move a card's rows into the diff and fail here.
final class WallCanvasPaletteTests: XCTestCase {
    // MARK: - fixtures

    /// The geometry the wide goldens use, so a byte count here is comparable with a dump.
    private let cols = 137
    private let rows = 44

    /// A dark terminal: GitHub's dark pair, i.e. `#E6EDF3` on `#0D1117`.
    ///
    /// Chosen because the brand blue clears WCAG AA against it at step 0, so the accent this file
    /// asserts literally (`38;2;94;184;255`) is `Palette.brand` unchanged — the assertion then says
    /// "the accent came through", not "the contrast walk moved by an amount I wrote down".
    private func darkPalette() -> Palette {
        Palette(foreground: RGB(0xE6_ED_F3), background: RGB(0x0D_11_17))
    }

    /// The same two colours with the roles exchanged — the light side of the *same* code path.
    ///
    /// Its accent is `#3B6F9A` rather than the brand blue because 4.5:1 is measured against the
    /// background, and no light-enough blue clears it on `#E6EDF3`. Its dim text moves from
    /// `148;153;159` to `95;101;107` for the same reason: every derived colour is an interpolation
    /// *between* the pair, so its direction follows the background.
    private func lightPalette() -> Palette {
        Palette(foreground: RGB(0x0D_11_17), background: RGB(0xE6_ED_F3))
    }

    /// The demo model and the layout helper `WallCanvasTests` itself uses: the goldens' own lens, so
    /// a row index here is a row index there.
    private func wall() -> (model: WallModel, layout: WallLayout) {
        let model = WallSource.demoModel()
        let layout = WallState().layout(cols: cols, rows: rows,
                                        displays: model.displays.count,
                                        windows: model.windows.count)
        return (model, layout)
    }

    private func draw(_ palette: WallPalette, on canvas: WallCanvas = WallCanvas()) -> [UInt8] {
        let (model, layout) = wall()
        return canvas.draw(cols: cols, rows: rows, model: model, layout: layout, focus: nil,
                           palette: palette)
    }

    // MARK: - byte-level helpers (no regex: the escapes are simpler than the literal syntax)

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

    /// The raw bytes written to each 1-based row, in order.
    ///
    /// A row and not the whole stream: "the header got the accent" is a claim about *that row*, and
    /// the same `38;2;94;184;255` anywhere else is exactly the leak D7 forbids (the stage's box, the
    /// cards and the bar must keep today's table). Searching the whole stream would pass on a wall
    /// that had painted the palette into every card.
    private func bytesOnRows(_ bytes: [UInt8]) -> [Int: [UInt8]] {
        var out: [Int: [UInt8]] = [:]
        var i = 0
        var current: (row: Int, start: Int)? = nil
        func flush(_ end: Int) {
            guard let c = current, c.start <= end else { return }
            out[c.row, default: []].append(contentsOf: bytes[c.start..<end])
        }
        while i < bytes.count {
            if bytes[i] == 0x1B, i + 1 < bytes.count, bytes[i + 1] == 0x5B {
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
                    if parts.count == 2 {
                        flush(i)
                        current = (parts[0], end + 1)
                        i = end + 1
                        continue
                    }
                }
            }
            i += 1
        }
        flush(bytes.count)
        return out
    }

    private func text(onRow row: Int, of bytes: [UInt8]) -> String {
        String(decoding: bytesOnRows(bytes)[row] ?? [], as: UTF8.self)
    }

    // MARK: - 1. the chrome row draws the palette

    func testTheDarkPaletteReachesTheHeaderAndTheFooter() {
        let (_, layout) = wall()
        let bytes = draw(WallPalette(palette: darkPalette()))
        let header = text(onRow: layout.headerRow, of: bytes)
        let footer = text(onRow: layout.footerRow, of: bytes)
        // The wordmark: `▪ krd`, today `.bright` (`1;97`, the terminal's own bright white), now the
        // palette's accent.
        XCTAssertTrue(header.contains("38;2;94;184;255"),
                      "the wordmark is not the palette's accent: \(header.debugDescription)")
        // The counts line, today `.dim`, now the palette's dim text. Also on the header row, which is
        // why the accent assertion above is not enough on its own.
        XCTAssertTrue(header.contains("38;2;148;153;159"),
                      "the counts are not the palette's dim text: \(header.debugDescription)")
        // The footer: the lead sentence and the `N panels` tail.
        XCTAssertTrue(footer.contains("38;2;148;153;159"),
                      "the footer is not the palette's dim text: \(footer.debugDescription)")
        // The fixed table is gone from this row, not merely accompanied: a wall that drew both would
        // look themed in one cell and unthemed in the next.
        XCTAssertFalse(header.contains("1;97"),
                       "the header still draws the fixed bright white: \(header.debugDescription)")
        XCTAssertFalse(footer.contains("2;37"),
                       "the footer still draws the fixed dim: \(footer.debugDescription)")
    }

    /// The two footer sentences that are not `.dim`: the demo note is the palette's foreground.
    func testTheDemoNoteIsThePalettesForeground() {
        let (model, layout) = wall()
        var paints = WallSlotPaints()
        paints.demoNote = "--demo · 4 windows · cell 8x20"
        let bytes = WallCanvas().draw(cols: cols, rows: rows, model: model, layout: layout,
                                      focus: nil, paints: paints,
                                      palette: WallPalette(palette: darkPalette()))
        let footer = text(onRow: layout.footerRow, of: bytes)
        XCTAssertTrue(footer.contains("38;2;230;237;243"),
                      "the demo note is not the palette's foreground: \(footer.debugDescription)")
        XCTAssertTrue(footer.contains("demo"), "the demo note was not drawn at all")
    }

    // MARK: - 2. one code path, two answers

    func testALightPairDrawsDifferentBytesFromTheSameCode() {
        let dark = draw(WallPalette(palette: darkPalette()))
        let light = draw(WallPalette(palette: lightPalette()))
        XCTAssertNotEqual(dark, light, "a light terminal got the dark wall's bytes")
        let (_, layout) = wall()
        let lightHeader = text(onRow: layout.headerRow, of: light)
        let lightFooter = text(onRow: layout.footerRow, of: light)
        // The light accent: the brand blue walked toward the foreground until it cleared 4.5:1 on
        // `#E6EDF3`, which lands on `#3B6F9A`.
        XCTAssertTrue(lightHeader.contains("38;2;59;111;154"),
                      "the light wall's accent is not the contrast-checked blue: "
                          + lightHeader.debugDescription)
        // The light dim text: the same 62% interpolation, measured from the other end of the pair.
        XCTAssertTrue(lightHeader.contains("38;2;95;101;107"),
                      "the light wall's dim text did not follow its background: "
                          + lightHeader.debugDescription)
        XCTAssertTrue(lightFooter.contains("38;2;95;101;107"),
                      "the light footer kept the dark dim text: \(lightFooter.debugDescription)")
        // The dark accent must not survive anywhere in the light wall: that is what a palette being
        // a constant rather than a derived value would look like.
        let lightStream = String(decoding: light, as: UTF8.self)
        XCTAssertFalse(lightStream.contains("38;2;94;184;255"),
                       "the light wall still draws the dark accent somewhere")
        XCTAssertFalse(lightStream.contains("38;2;148;153;159"),
                       "the light wall still draws the dark dim text somewhere")
    }

    // MARK: - 3. no palette is today's table, byte for byte

    func testNoPaletteDrawsTodaysTableAndEmitsNoTrueColour() {
        let (model, layout) = wall()
        // The default (no argument) and an explicit `.none` are the same wall: the parameter's
        // default is load-bearing for every call site that predates the palette.
        let byDefault = WallCanvas().draw(cols: cols, rows: rows, model: model, layout: layout,
                                          focus: nil)
        let explicit = draw(.none)
        XCTAssertEqual(byDefault, explicit, "the default palette is not `.none`")
        let stream = String(decoding: byDefault, as: UTF8.self)
        // Contract D4: a terminal that answered nothing gets no 24-bit colour at all — not a guess,
        // not a fallback pair, not a "safe" default theme.
        XCTAssertFalse(stream.contains("38;2;"), "a palette-less wall emitted a true-colour foreground")
        XCTAssertFalse(stream.contains("48;2;"), "a palette-less wall emitted a true-colour background")
        // …and the cells it *does* write are the ones the goldens hold.
        let header = text(onRow: layout.headerRow, of: byDefault)
        let footer = text(onRow: layout.footerRow, of: byDefault)
        XCTAssertTrue(header.contains("1;97"), "the wordmark left the fixed table: \(header.debugDescription)")
        XCTAssertTrue(header.contains("2;37"), "the counts left the fixed table: \(header.debugDescription)")
        XCTAssertTrue(footer.contains("2;37"), "the footer left the fixed table: \(footer.debugDescription)")
    }

    // MARK: - 4. the palette is applied once and diffed

    func testAnUnchangedWallWithTheSamePaletteEmitsNothing() {
        let canvas = WallCanvas()
        let palette = WallPalette(palette: darkPalette())
        let first = draw(palette, on: canvas)
        print("palette wall repaint: \(first.count) B (\(cols)x\(rows), demo, dark palette)")
        XCTAssertFalse(first.isEmpty, "the first draw is a full repaint")
        // §5.1 in one line: a palette is a property of the frame, not an event, so a second frame
        // drawn from the same palette costs nothing. A tint re-emitted per frame would put the
        // header and footer on the wire 1×/s forever.
        let second = draw(palette, on: canvas)
        print("palette wall unchanged: \(second.count) B")
        XCTAssertEqual(second.count, 0, "an unchanged wall re-emitted its palette")
    }

    // MARK: - 5. only the two adopters move

    func testAPaletteChangeReemitsOnlyTheHeaderAndFooterRows() {
        let (_, layout) = wall()
        let canvas = WallCanvas()
        _ = draw(WallPalette(palette: darkPalette()), on: canvas)
        let bytes = draw(WallPalette(palette: lightPalette()), on: canvas)
        print("palette change: \(bytes.count) B (dark -> light, \(cols)x\(rows), demo)")
        XCTAssertFalse(bytes.isEmpty,
                       "a palette change painted nothing: the wall kept the colours it had")
        // The two adopter rows, and nothing the palette does not touch. This is the assertion that
        // D7 held: the stage, the captions, the cards, the band, the bar and the ring are drawn from
        // the fixed table, so a theme switch moves two rows and the diff proves it.
        let allowed: Set<Int> = [layout.headerRow, layout.footerRow]
        let touched = Set(cursorMoves(bytes).map(\.row))
        XCTAssertFalse(touched.isEmpty, "the palette change wrote no cells")
        XCTAssertTrue(touched.isSubset(of: allowed),
                      "the palette leaked out of the chrome row: rows \(touched.sorted()), "
                          + "allowed \(allowed.sorted())")
        XCTAssertEqual(touched, allowed,
                       "one of the two adopter rows did not change: \(touched.sorted())")
        XCTAssertFalse(bytes.contains(0x0A), "the repaint contains a newline")
    }
}
