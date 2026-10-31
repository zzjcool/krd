import XCTest
@testable import krd

/// The width table, against the terminal's own answers.
///
/// Every expected number below was produced by libghostty itself (`ghostty_unicode_grapheme_width`
/// over the whole string, mode 2027 on) on the same v1.4.0 build `scripts/gen-widths.sh` read the
/// table from — that is what makes this a truth table rather than a restatement of `TextWidth.swift`.
/// The first two cases are the bug this replaces: `☰` and a flag were one cell in the hand-written
/// EastAsianWidth table and are two in both terminals krd is tested against, so every column after
/// one of them was off by one.
///
/// The other half of the table is the glyphs the chrome actually draws (`▲ ▣ ▸ ↺ ⤡ …`), including
/// the ones people usually get wrong: an emoji codepoint *without* VS16 is one cell (`🖥`, `⚙`), the
/// private-use range is one cell (no Nerd Font is required), and a variation selector only does
/// anything on a valid emoji base (`⌚` is two cells, `⌚︎` is one).
final class WidthTableTests: XCTestCase {
    private let truth: [(String, Int)] = [
        ("\u{2630}", 2),
        ("\u{1F1E8}\u{1F1F3}", 2),
        ("\u{1F5A5}\u{FE0F}", 2),
        ("\u{2699}\u{FE0F}", 2),
        ("\u{2764}\u{FE0F}", 2),
        ("\u{1F44D}\u{1F3FD}", 2),
        ("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", 2),
        ("\u{3042}", 2),
        ("\u{8BBF}\u{8FBE}", 4),
        ("\u{2026}", 1),
        ("e", 1),
        ("\u{25B2}", 1),
        ("\u{25A3}", 1),
        ("\u{2922}", 1),
        ("\u{1F5A5}", 1),
        ("\u{2699}", 1),
        ("\u{E0B6}", 1),
        ("\u{F015}", 1),
        ("\u{F0379}", 1),
        ("\u{1CD00}", 1),
        ("\u{258F}", 1),
        ("\u{25AA}", 1),
        ("\u{25BC}", 1),
        ("\u{2B05}", 1),
        ("\u{B7}", 1),
        ("\u{D7}", 1),
        ("\u{2014}", 1),
        ("\u{2013}", 1),
        ("\u{25CF}", 1),
        ("\u{2195}", 1),
        ("\u{2192}", 1),
        ("\u{256D}", 1),
        ("\u{2580}", 1),
        ("\u{2921}", 1),
        ("\u{25B8}", 1),
        ("\u{21BA}", 1),
        ("1\u{FE0F}\u{20E3}", 2),
        ("\u{231A}\u{FE0E}", 1),
        ("krd --dev", 9),
        ("\u{7A97}\u{53E3} title", 10),
        ("\u{E9}", 1),
        ("\u{E9}", 1),
        ("e\u{301}", 1),
        ("\u{301}", 0),
        ("\u{1F1E8}\u{1F1F3}\u{1F1EF}\u{1F1F5}", 4),
        ("\u{25AA}\u{25AB}", 2),
        ("\u{2588}\u{258C}\u{2590}", 3),
        ("\u{2192} \u{2195}", 3),
        ("\u{2699}\u{FE0F} \u{2699}", 4),
    ]

    func testTheTableMatchesTheTerminal() {
        for (text, cells) in truth {
            XCTAssertEqual(DisplayWidth.of(text), cells,
                           "\(text.debugDescription): the terminal draws \(cells) cells")
        }
    }

    /// A `Character` is one cluster, however many codepoints it took, and the width rule is the
    /// terminal's: first codepoint, then VS16/VS15 on a valid base, then "widens" for the rest.
    func testAClusterIsOneGlyphNotEmptyCells() {
        XCTAssertEqual(DisplayWidth.of(Character("👨\u{200D}👩\u{200D}👧")), 2, "ZWJ family")
        XCTAssertEqual(DisplayWidth.of(Character("🇨🇳")), 2, "a flag is one glyph, not two letters")
        XCTAssertEqual(DisplayWidth.of(Character("e\u{301}")), 1, "a combining accent adds no cell")
        XCTAssertEqual(DisplayWidth.of(Character("\u{301}")), 0, "a lone mark is malformed, not wide")
        XCTAssertEqual(DisplayWidth.of(Character("⚙")), 1)
        XCTAssertEqual(DisplayWidth.of(Character("⚙\u{FE0F}")), 2, "VS16 on a valid base")
        XCTAssertEqual(DisplayWidth.of(Character("⌚")), 2, "already wide")
        XCTAssertEqual(DisplayWidth.of(Character("⌚\u{FE0E}")), 1, "VS15 makes it narrow")
        XCTAssertEqual(DisplayWidth.of(Character("A\u{FE0F}")), 1, "VS16 on a non-base is ignored")
        XCTAssertEqual(DisplayWidth.of(Character("👍\u{1F3FD}")), 2, "a skin tone widens")
    }

    /// A regenerated table must stay sorted, merged and inside Unicode, or the binary search is
    /// meaningless — and it fails silently: a bad table draws text at the wrong column and nothing
    /// else in the build would notice.
    func testTheTablesAreSortedAndMerged() {
        let sets: [(String, [UInt32])] = [
            ("wide", WidthTable.wide), ("zero", WidthTable.zero),
            ("widens", WidthTable.widens), ("vsBase", WidthTable.vsBase),
        ]
        for (name, pairs) in sets {
            XCTAssertFalse(pairs.isEmpty, "\(name) is empty")
            XCTAssertEqual(pairs.count % 2, 0, "\(name) is not (start, end) pairs")
            var previousEnd: UInt32? = nil
            var index = 0
            while index < pairs.count {
                let start = pairs[index], end = pairs[index + 1]
                XCTAssertLessThanOrEqual(start, end, "\(name): [\(start), \(end)] is backwards")
                XCTAssertLessThan(end, 0x110000, "\(name): \(end) is past Unicode")
                if let previousEnd {
                    XCTAssertGreaterThan(start, previousEnd + 1,
                                         "\(name): [\(start), \(end)] should have been merged")
                }
                previousEnd = end
                index += 2
            }
        }
        // Spot checks that the generator read the sets it meant to: a wrong index would still be
        // sorted and merged, so ordering alone cannot catch it.
        XCTAssertTrue(WidthTable.contains(WidthTable.wide, 0x2630), "☰ is wide")
        XCTAssertTrue(WidthTable.contains(WidthTable.wide, 0x1F1E8), "a regional indicator is wide")
        XCTAssertTrue(WidthTable.contains(WidthTable.zero, 0x200D), "ZWJ occupies no cell")
        // The set that is load-bearing: an Indic spacing mark widens a one-cell base (`का` is two
        // cells), while a combining accent does not (`á` is one). A skin tone does *not* — `☝🏽` is
        // one cell in the terminal, because the base is narrow and the modifier joins without
        // widening — which is why this is a generated set and not a guess.
        XCTAssertTrue(WidthTable.contains(WidthTable.widens, 0x093E), "DEVANAGARI VOWEL SIGN AA")
        XCTAssertFalse(WidthTable.contains(WidthTable.widens, 0x0301), "COMBINING ACUTE ACCENT")
        XCTAssertEqual(DisplayWidth.of("का"), 2, "क + ा is one glyph, two cells")
        XCTAssertTrue(WidthTable.contains(WidthTable.vsBase, 0x2699), "⚙ is a VS base")
        XCTAssertFalse(WidthTable.contains(WidthTable.vsBase, 0x2630), "☰ is not")
    }

    /// The chrome's own contract, unchanged by the new table: exactly `cells` columns, never a split
    /// glyph, and never a control character on the grid.
    func testPaddingAndTruncationStillHold() {
        for s in ["abc", "访达", "👨\u{200D}👩\u{200D}👧 x", "", "☰ ☰", "⚙\u{FE0F}"] {
            for cells in 0...14 {
                XCTAssertEqual(DisplayWidth.of(DisplayWidth.pad(s, to: cells)), cells)
            }
        }
        XCTAssertEqual(DisplayWidth.truncate("a\nb", to: 10), "a b")
    }
}
