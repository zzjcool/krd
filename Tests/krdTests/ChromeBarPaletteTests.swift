import XCTest
import krdcore
@testable import krd

/// The mirror bar's two palette adopters (issue #213, decision D7): the title and the link pill —
/// and, just as importantly, nothing else on the bar.
///
/// **Why the two sites want opposite halves of the colour.** The bar is reversed end to end (SGR 7,
/// `for x in 0..<cols { set(x, row, " ", .reverse) }`), and a reversed cell paints its **background
/// attribute as the glyph** and its **foreground attribute as the patch**. So:
///
///  * the title is *text on the bar* — the word the reader reads is the cell's background, so it
///    takes the palette's foreground (`48;2;…`). That is what turns the title from today's fixed
///    `1;97` (the terminal's bright white, i.e. invisible on a light terminal) into dark-on-light on
///    a light terminal and light-on-dark on a dark one;
///  * the pill is a *lit capsule* — the capsule is the cell's background and its letters are the
///    cell's foreground, so it takes the palette's accent (`38;2;…`) and reads as brand blue with the
///    bar's own colour for the letters.
///
/// Everything below fails on a specific way of getting that wrong: swapping the two planes (a blue
/// title and a grey pill), tinting the whole bar (the numbers and the two buttons must keep `7;2;37`
/// / `7;1;97`), dropping the hot state (a hovered pill must stay underlined *and* tinted — the tint
/// is appended to `Style.sgr(_:_:)`, never used instead of it), and re-emitting the palette per
/// frame (an unchanged palette is 0 bytes, a changed one is the bar's own tinted cells).
final class ChromeBarPaletteTests: XCTestCase {
    // MARK: - fixtures (the `bar()` / `metrics(link:)` shape `LinkPillChromeTests` draws with, so a
    // real bar is painted: the dots, the title, the numbers, the pill and both buttons)

    /// A dark terminal: GitHub's dark pair, `#E6EDF3` on `#0D1117`, whose accent is the brand blue
    /// unchanged (it clears WCAG AA against that background at step 0).
    private func darkPalette() -> Palette {
        Palette(foreground: RGB(0xE6_ED_F3), background: RGB(0x0D_11_17))
    }

    /// The same pair with the roles exchanged: the light terminal's accent is the contrast-checked
    /// `#3B6F9A`, and its foreground is `#0D1117` — i.e. the tint that reads on a light bar.
    private func lightPalette() -> Palette {
        Palette(foreground: RGB(0x0D_11_17), background: RGB(0xE6_ED_F3))
    }

    private func metrics(link: LinkVerdict = .held) -> ChromeMetrics {
        var m = ChromeMetrics()
        m.version = "test"
        m.target = "window 128444"
        m.title = "Terminal — admin — scroll.sh"
        m.clock = "20:07:17"
        m.fps = 18
        m.fpsTarget = 20
        m.mbps = 1.8
        m.scale = 1.0
        m.capMs = 42
        m.e2eMs = 61
        m.rttAvailable = true
        m.rttMs = 22.4
        m.rttP99Ms = 30.1
        m.rttMinMs = 0.7
        m.link = link
        return m
    }

    /// A bar-only mirror: `--bar`, no `--dev`, the same geometry `LinkPillChromeTests.bar()` builds.
    private func bar(cols: Int = 120, rows: Int = 30) -> ChromeGeometry {
        let picture = Chrome.pictureRows(paneRows: rows, bar: true, panel: nil, chrome: false)
        return Chrome.layout(paneCols: cols, paneRows: rows, imageCols: cols, imageRows: 1 + picture,
                             bar: true, dev: false, panel: nil)
    }

    private func draw(_ link: LinkVerdict = .held, on chrome: Chrome = Chrome(),
                      state: ChromeState = ChromeState()) -> [UInt8] {
        chrome.draw(geometry: bar(), metrics: metrics(link: link), state: state)
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

    // MARK: - 1. the two sites, in the two planes

    func testThePaletteTintsTheTitleAsTextAndThePillAsAPatch() {
        let chrome = Chrome()
        chrome.palette = darkPalette()
        let bytes = draw(on: chrome)
        let stream = String(decoding: bytes, as: UTF8.self)
        // The title: `.barBright` (`7;1;97`) plus the palette's *foreground* in the background half.
        XCTAssertTrue(stream.contains("7;1;97;48;2;230;237;243"),
                      "the title is not the palette's foreground: \(stream.debugDescription)")
        // The pill: the same base style plus the palette's *accent* in the foreground half.
        XCTAssertTrue(stream.contains("7;1;97;38;2;94;184;255"),
                      "the pill is not the palette's accent: \(stream.debugDescription)")
        // Not swapped. A `48;2;94;184;255` would be a blue *font* on the bar (the failure the plane
        // exists to prevent), and `38;2;230;237;243` a grey pill.
        XCTAssertFalse(stream.contains("48;2;94;184;255"), "the pill took the text plane")
        XCTAssertFalse(stream.contains("38;2;230;237;243"), "the title took the patch plane")
        // The rest of the bar keeps today's table: the numbers are `7;2;37`, and the traffic lights,
        // `[ - ]` and `[ ≡ ]` are `7;1;97` with no tint at all.
        XCTAssertTrue(stream.contains("7;2;37"), "the bar's numbers lost their dim style")
        XCTAssertTrue(stream.contains("[ - ]") && stream.contains("[ ≡ ]"),
                      "the two ways out are not on this bar")
        // A pill is only drawn while the link has a symptom, so the assertion above is about a pill
        // that exists (`LinkPillChromeTests` pins when it does).
        XCTAssertTrue(chrome.widgets.contains { $0.id == "link" }, "no pill was drawn")
    }

    /// The tint rides *on top of* the hot state: `render` appends it to `Style.sgr(_:_:)`'s answer, so
    /// a hovered pill is still underlined and a pressed one still reversed — with the accent as an
    /// extra parameter, never instead of the hot state's own three.
    func testAHotPillKeepsItsHoverOrPressAndRidesTheTintOnTop() {
        let chrome = Chrome()
        chrome.palette = darkPalette()
        let hovered = String(decoding: draw(on: chrome,
                                            state: ChromeState(pointer: Pointer(over: "link"))),
                             as: UTF8.self)
        XCTAssertTrue(hovered.contains("7;1;4;97;38;2;94;184;255"),
                      "a hovered pill lost its underline or its accent: \(hovered.debugDescription)")
        let pressed = Chrome()
        pressed.palette = darkPalette()
        let down = String(decoding: draw(on: pressed,
                                         state: ChromeState(pointer: Pointer(over: "link",
                                                                            down: true))),
                          as: UTF8.self)
        XCTAssertTrue(down.contains("7;1;36;38;2;94;184;255"),
                      "a pressed pill lost its reverse or its accent: \(down.debugDescription)")
    }

    /// The same two sites on a light terminal: the title's glyph colour flips to the dark foreground
    /// and the pill's capsule to the contrast-checked blue. Two pointers, two answers, one code path.
    func testALightPairMovesBothSitesAndDiffersFromTheDarkBar() {
        let dark = Chrome()
        dark.palette = darkPalette()
        let darkBytes = draw(on: dark)
        let light = Chrome()
        light.palette = lightPalette()
        let lightBytes = draw(on: light)
        XCTAssertNotEqual(darkBytes, lightBytes, "a light terminal got the dark bar's bytes")
        let stream = String(decoding: lightBytes, as: UTF8.self)
        XCTAssertTrue(stream.contains("7;1;97;48;2;13;17;23"),
                      "the light title is not the light palette's foreground: \(stream.debugDescription)")
        XCTAssertTrue(stream.contains("7;1;97;38;2;59;111;154"),
                      "the light pill is not the light palette's accent: \(stream.debugDescription)")
        XCTAssertFalse(stream.contains("48;2;230;237;243"),
                       "the light bar still draws the dark title colour")
    }

    // MARK: - 2. no palette is today's bar, byte for byte

    func testNoPaletteDrawsTodaysBarAndEmitsNoTrueColour() {
        let chrome = Chrome()
        // Contract D4: `nil` is the default and it is what a terminal that answered nothing gets.
        XCTAssertNil(chrome.palette, "the chrome made up a palette")
        let bytes = draw(on: chrome)
        let stream = String(decoding: bytes, as: UTF8.self)
        XCTAssertEqual(bytes, draw(on: Chrome()), "the two palette-less bars differ")
        // The bar's own table, both sites, exactly as they are today: the title, the pill and both
        // buttons are `7;1;97`.
        XCTAssertTrue(stream.contains("7;1;97"), "the bar lost its barBright style")
        let barBright = stream.components(separatedBy: "7;1;97").count - 1
        XCTAssertGreaterThanOrEqual(barBright, 2,
                                    "fewer than two cells carry today's bright bar style: "
                                        + stream.debugDescription)
        XCTAssertFalse(stream.contains("38;2;"), "a palette-less bar emitted a true-colour foreground")
        XCTAssertFalse(stream.contains("48;2;"), "a palette-less bar emitted a true-colour background")
    }

    // MARK: - 3. a palette change moves only the cells that carry it

    func testAPaletteChangeReemitsOnlyCellsOnTheBarRow() {
        let chrome = Chrome()
        let geo = bar()
        chrome.palette = darkPalette()
        _ = draw(on: chrome)
        chrome.palette = lightPalette()
        let bytes = draw(on: chrome)
        print("bar palette change: \(bytes.count) B (dark -> light, 120x30 bar)")
        XCTAssertFalse(bytes.isEmpty,
                       "a palette change painted nothing: the bar kept the colours it had")
        // The title and the pill are the only tinted cells, and both are on the bar's own row. A
        // palette that had reached the traffic lights, the numbers or the buttons would show up here
        // as a cursor move anywhere else — the bar is the only row the chrome draws at all.
        guard let barRow = geo.barRow else { return XCTFail("the fixture has no bar") }
        let touched = Set(cursorMoves(bytes).map(\.row))
        XCTAssertFalse(touched.isEmpty, "the palette change wrote no cells")
        XCTAssertTrue(touched.isSubset(of: [barRow + 1]),
                      "the palette leaked off the bar row: rows \(touched.sorted())")
    }

    // MARK: - 4. applied once and diffed

    func testTheSamePaletteTwicePaintsNothing() {
        let chrome = Chrome()
        chrome.palette = darkPalette()
        let first = draw(on: chrome)
        print("bar palette repaint: \(first.count) B (120x30 bar, dark palette)")
        XCTAssertFalse(first.isEmpty, "the first draw is a full repaint")
        let second = draw(on: chrome)
        print("bar palette unchanged: \(second.count) B")
        XCTAssertEqual(second.count, 0, "an unchanged palette re-emitted the bar")
    }
}
