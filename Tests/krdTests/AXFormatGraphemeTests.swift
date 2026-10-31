import XCTest
@testable import krd

/// Round C / bug-input: `AXText.sanitize`'s clamp counts **unicode scalars**, but what a terminal
/// draws — and what a reader reads — is **grapheme clusters**. A title or value that is cut in the
/// middle of a cluster is not a shorter string, it is a *different* one: a flag becomes a lone
/// regional-indicator letter, a Vietnamese name loses its accents, an emoji keeps a dangling ZWJ.
///
/// The function is pure (`Sources/krd/AXFormat.swift`), so this is the real code path a window
/// title takes to the terminal: `AXCommand` → `AXText.sanitize(…, limit: 60)` → `header()`/`render()`.
final class AXFormatGraphemeTests: XCTestCase {
    /// A flag is one grapheme built from two scalars. Cutting between them leaves a lone
    /// `U+1F1EF`, which every terminal draws as a boxed "J" — a visibly broken line.
    func testFlagIsNotSplitInHalf() {
        let flags = "🇯🇵🇺🇸"                     // 2 graphemes, 4 scalars
        let out = AXText.sanitize(flags, limit: 1)
        XCTAssertEqual(out, "🇯🇵…", "a clip inside a flag produced \(out.debugDescription)")
    }

    /// A combining sequence: "e" + U+0302 + U+0303 is one grapheme (`ễ`). Clipping scalars drops
    /// the marks and changes the name.
    func testCombiningMarksAreNotStranded() {
        let raw = "abc" + "e\u{0302}\u{0303}" + "xyz"
        let out = AXText.sanitize(raw, limit: 4)
        XCTAssertEqual(out, "abc\u{65}\u{0302}\u{0303}…",
                       "a clip inside a combining sequence produced \(out.debugDescription)")
    }

    /// A ZWJ sequence must never be cut with the joiner last: the next thing printed (`…`, a
    /// frame, the newline) is then glued to the emoji.
    func testNoDanglingZWJ() {
        let family = "👨\u{200D}👩\u{200D}👧\u{200D}👦"      // 1 grapheme, 7 scalars
        for limit in 1...7 {
            let out = AXText.sanitize(family + "x", limit: limit)
            // Compare scalars, not Characters: `"\u{200D}…"` is a single Character, so a String
            // `hasSuffix` cannot see a ZWJ left dangling in front of the ellipsis.
            let kept = Array(out.unicodeScalars.filter { $0 != "…" })
            XCTAssertNotEqual(kept.last?.value, 0x200D,
                              "limit \(limit): \(out.debugDescription) ends in a ZWJ")
        }
    }

    /// The whole-output invariant behind the three cases above: what is kept is a whole number of
    /// graphemes, and nothing in the middle of a cluster survives without its cluster.
    func testClipKeepsWholeGraphemes() {
        let raw = "a👨\u{200D}👩\u{200D}👧b🇯🇵c\u{0065}\u{0301}d"
        let clusters = Array(raw)
        for limit in 0...clusters.count + 2 {
            let out = AXText.sanitize(raw, limit: limit)
            let kept = out.hasSuffix("…") ? String(out.dropLast()) : out
            let expected = String(clusters.prefix(limit))
            XCTAssertTrue(kept == expected || kept == String(clusters.prefix(limit + 1)),
                          "limit \(limit): kept \(kept.debugDescription), "
                          + "expected a prefix of \(clusters)")
        }
    }

    /// Empty and enormous values: the clamp has to hold at both ends.
    func testEmptyAndHugeValues() {
        XCTAssertEqual(AXText.sanitize("", limit: 60), "")
        let huge = String(repeating: "a", count: 100_000)
        let out = AXText.sanitize(huge, limit: 60)
        XCTAssertEqual(out.count, 61)
        XCTAssertTrue(out.hasSuffix("…"))
    }

    /// Sanitisation must not leak a control byte even when the clamp lands on one.
    func testControlBytesAreGoneWhateverTheLimit() {
        let raw = "\u{1B}[2J" + "\t\n\u{0}" + String(repeating: "x", count: 80)
        for limit in [0, 1, 2, 5, 60] {
            let out = AXText.sanitize(raw, limit: limit)
            for scalar in out.unicodeScalars {
                XCTAssertFalse(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value),
                               "limit \(limit): \(out.debugDescription) leaks U+"
                               + String(scalar.value, radix: 16))
            }
        }
    }
}
