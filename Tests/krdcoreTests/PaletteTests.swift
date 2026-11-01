import XCTest
@testable import krdcore

/// `Palette` is a pure function of the two colours the terminal answered to `OSC 10`/`OSC 11`
/// (issue #213, design §4.3), and the two properties that matter are **behavioural**, not "a colour
/// exists":
///
///   1. **One code path, two schemes.** Every derived colour is an interpolation between the
///      background and the foreground, so its *direction* is the background's: the same derivation
///      answers a light pair and a dark pair with different surfaces. A constant ladder (or a
///      per-scheme table) satisfies "not nil" and fails this — which is the point, because a wall on
///      a light terminal used to look exactly like a wall on a dark one.
///   2. **The accent is contrast-checked, not the brand.** `#5EB8FF` against the dark reference
///      background is 8.81 and stays put; against the light one it is 1.86 — unreadable — so the
///      derivation has to walk it toward the foreground until it clears WCAG AA (4.5), and it has to
///      *refuse* to walk on the dark pair, where the brand already passes.
///
/// The reference pairs are the ones measured in `docs/design-ui-v2.zh-CN.md` §2.1 (Ghostty's and
/// Rex's defaults): `#E6EDF3` on `#0D1117`, and the same two colours with the roles exchanged. The
/// expected numbers below are the frozen implementation's, asserted so that a silent numeric drift —
/// a mix fraction, a rounding mode, a luminance threshold — is a test failure here instead of a
/// screenshot somebody notices a month later.
final class PaletteTests: XCTestCase {
    /// The dark reference pair: `#E6EDF3` text on `#0D1117`.
    private let dark = Palette(foreground: RGB(0xE6_ED_F3), background: RGB(0x0D_11_17))
    /// The light one, spelled out rather than derived, so the two palettes below are independent
    /// inputs (the `inverted()` relation is `testInvertingTwiceIsTheOriginal`'s business).
    private let light = Palette(foreground: RGB(0x0D_11_17), background: RGB(0xE6_ED_F3))

    // MARK: - the reference numbers

    /// The dark pair, colour by colour. Every one of these is an interpolation between `#0D1117` and
    /// `#E6EDF3` at a fixed fraction, so a moved fraction shows up as a moved hex value.
    func testTheDarkPairLandsOnTheReferencePalette() {
        XCTAssertEqual(dark.foreground, RGB(0xE6_ED_F3))
        XCTAssertEqual(dark.background, RGB(0x0D_11_17))
        XCTAssertEqual(dark.surface1, RGB(0x1A_1E_24), "6 % of the way from bg to fg")
        XCTAssertEqual(dark.surface2, RGB(0x23_27_2D), "10 %")
        XCTAssertEqual(dark.surface3, RGB(0x2E_32_38), "15 %")
        XCTAssertEqual(dark.border, RGB(0x41_46_4C), "24 %")
        XCTAssertEqual(dark.dimText, RGB(0x94_99_9F), "62 %")
        XCTAssertEqual(dark.accent, RGB(0x5E_B8_FF), "the brand passes on this background, so it stays")
    }

    /// The light pair: the *same* code path, the other direction. Read the six values against the
    /// dark table above — every one is different, and the surfaces run *away* from the background
    /// toward the foreground in both cases.
    func testTheLightPairLandsOnTheReferencePalette() {
        XCTAssertEqual(light.foreground, RGB(0x0D_11_17))
        XCTAssertEqual(light.background, RGB(0xE6_ED_F3))
        XCTAssertEqual(light.surface1, RGB(0xD9_E0_E6))
        XCTAssertEqual(light.surface2, RGB(0xD0_D7_DD))
        XCTAssertEqual(light.surface3, RGB(0xC5_CC_D2))
        XCTAssertEqual(light.border, RGB(0xB2_B8_BE))
        XCTAssertEqual(light.dimText, RGB(0x5F_65_6B))
        XCTAssertEqual(light.accent, RGB(0x3B_6F_9A), "the brand walked 14/32 toward the foreground")
    }

    /// Property A, stated as the failure it prevents: a light terminal must not get a dark terminal's
    /// surfaces. This is the assertion a background-independent ladder cannot pass, and it is the
    /// whole reason `Palette` takes the pair as an argument instead of reading a scheme.
    func testALightPairAndADarkPairShareNoDerivedColour() {
        let names = ["surface1", "surface2", "surface3", "border", "dimText", "accent"]
        let darkDerived = [dark.surface1, dark.surface2, dark.surface3, dark.border, dark.dimText,
                           dark.accent]
        let lightDerived = [light.surface1, light.surface2, light.surface3, light.border,
                            light.dimText, light.accent]
        for (name, pair) in zip(names, zip(darkDerived, lightDerived)) {
            XCTAssertNotEqual(pair.0, pair.1,
                              "\(name) is \(pair.0) on both a dark and a light terminal — the "
                              + "derivation is ignoring the background")
        }
    }

    /// The ordering claim behind "one code path": `surface1` sits nearer the background than
    /// `surface3` whichever end of the ladder the background happens to be at, because both are the
    /// same interpolation and only `t` differs. Contrast against the background is how "nearer"
    /// becomes a number; it is 1.13 against 1.47 on the dark pair and 1.15 against 1.41 on the light
    /// one, so the ladder cannot be an accident of one direction.
    func testTheSurfaceLadderStepsAwayFromTheBackgroundInBothSchemes() {
        for palette in [dark, light] {
            let one = palette.surface1.contrast(palette.background)
            let two = palette.surface2.contrast(palette.background)
            let three = palette.surface3.contrast(palette.background)
            XCTAssertGreaterThan(one, 1.0, "surface1 is not the background")
            XCTAssertLessThan(one, two, "surface2 has to sit further from bg than surface1")
            XCTAssertLessThan(two, three, "surface3 has to sit further from bg than surface2")
            XCTAssertGreaterThan(palette.dimText.contrast(palette.background),
                                 three, "dimText still reads: it is past every surface")
        }
        // And "direction follows the background" in the plainest possible terms: the dark palette's
        // surfaces are brighter than its background, the light palette's are darker than theirs.
        XCTAssertGreaterThan(dark.surface1.luminance, dark.background.luminance)
        XCTAssertLessThan(light.surface1.luminance, light.background.luminance)
    }

    // MARK: - the accent

    /// On the dark reference pair the brand already clears 4.5 (8.81), so the answer is the brand
    /// **unchanged**: an accent that walked anyway would be a colour nobody chose.
    func testTheAccentKeepsTheBrandOnADarkTerminal() {
        XCTAssertGreaterThanOrEqual(Palette.brand.contrast(dark.background),
                                    Palette.minimumContrast)
        XCTAssertEqual(dark.accent, Palette.brand)
    }

    /// On the light pair the brand is 1.86 against its own background — the failure the rule exists
    /// for. The accent therefore has to have *moved*, and moved toward the foreground (darker), not
    /// away from it.
    func testTheAccentMovesOffTheBrandOnALightTerminal() {
        XCTAssertLessThan(Palette.brand.contrast(light.background), Palette.minimumContrast,
                          "the brand is unreadable on this background; that is the premise")
        XCTAssertNotEqual(light.accent, Palette.brand, "the accent was left on the unreadable brand")
        XCTAssertNotEqual(light.accent, dark.accent, "a light terminal gets its own accent")
        XCTAssertLessThan(light.accent.luminance, Palette.brand.luminance,
                          "the walk goes toward the foreground, which is dark here")
    }

    /// The invariant both of the above are instances of: whatever pair the terminal hands us, the
    /// accent is a foreground colour that clears WCAG AA against the background it will be drawn on.
    func testTheAccentClearsTheMinimumOnBothSchemes() {
        for (name, palette) in [("dark", dark), ("light", light)] {
            XCTAssertGreaterThanOrEqual(palette.accent.contrast(palette.background),
                                        Palette.minimumContrast,
                                        "\(name) accent \(String(format: "%06X", palette.accent.hex)) "
                                        + "does not clear \(Palette.minimumContrast):1")
        }
    }

    /// A white background is the case the brand fails hardest on (2.15). The rule is about the
    /// *pair*, not about the two reference pairs, so it has to hold here too.
    func testAWhiteBackgroundStillGetsAPassingAccent() {
        let palette = Palette(foreground: RGB(0x1E_1E_1E), background: RGB(0xFF_FF_FF))
        XCTAssertLessThan(Palette.brand.contrast(palette.background), Palette.minimumContrast)
        XCTAssertGreaterThanOrEqual(palette.accent.contrast(palette.background),
                                    Palette.minimumContrast)
        XCTAssertNotEqual(palette.accent, Palette.brand)
    }

    /// The honest half of the rule: a pair whose *foreground* does not clear the bar (a deliberately
    /// low-contrast theme) can never pass, and inventing a passing colour there would be a lie. The
    /// answer is the best sample of the walk — computed here from the public pieces, so this pins the
    /// fallback and not just its direction.
    func testAPairThatCanNeverPassReturnsTheBestSampleItSaw() {
        let foreground = RGB(0x80_80_80)
        let background = RGB(0xFF_FF_FF)
        XCTAssertLessThan(foreground.contrast(background), Palette.minimumContrast,
                          "premise: the foreground itself cannot read on this background")
        let palette = Palette(foreground: foreground, background: background)
        let walked = (0...Palette.accentSteps).map {
            Palette.brand.mixed(with: foreground, Double($0) / Double(Palette.accentSteps))
        }
        let best = walked.map { $0.contrast(background) }.max() ?? 0
        XCTAssertEqual(palette.accent.contrast(background), best, accuracy: 1e-9,
                       "the fallback is the best sample of the walk, not the brand and not a guess")
        XCTAssertNotEqual(palette.accent, Palette.brand, "it still moved as far as it could")
    }

    /// `foreground == background` is a terminal in a broken state, not a crash: the palette is
    /// whatever the arithmetic gives (every surface *is* that colour), and the accent is still a
    /// colour rather than a `nil` or a `0x000000`.
    func testADegeneratePairDoesNotCrash() {
        let colour = RGB(0x33_33_33)
        let palette = Palette(foreground: colour, background: colour)
        XCTAssertEqual(palette.surface1, colour)
        XCTAssertEqual(palette.surface3, colour)
        XCTAssertEqual(palette.border, colour)
        XCTAssertEqual(palette.accent, Palette.brand, "every sample is the same colour, so the best "
                      + "one is the brand it started from")
    }

    /// The theme switch `ColourScheme` reports has to land back on the palette it started from, or
    /// `InputReader`'s "same scheme twice is 0 bytes" rule (#212) becomes "same scheme twice is a
    /// repaint with a slightly different colour".
    func testInvertingTwiceIsTheOriginal() {
        XCTAssertEqual(dark.inverted(), light)
        XCTAssertEqual(dark.inverted().inverted(), dark)
        XCTAssertEqual(light.inverted().inverted(), light)
    }

    /// Which scheme a pair *looks* like, by the background's luminance — the thing the first
    /// `?997;Nn` report is compared against, so a terminal that starts light is not "re-derived"
    /// into its own inverse.
    func testTheSchemeComesFromTheBackgroundsLuminance() {
        XCTAssertEqual(dark.scheme, .dark)
        XCTAssertEqual(light.scheme, .light)
        XCTAssertEqual(Palette(foreground: RGB(0x00_00_00), background: RGB(0xFF_FF_FF)).scheme, .light)
    }

    // MARK: - the body an OSC 10/11 answer carries

    /// Both forms in the wild: xterm's 16-bit-per-channel `rgb:`, the 8-bit short one, and the
    /// `#RRGGBB` / `#RGB` spellings some terminals answer anyway. xterm's rule is 1–4 hex digits per
    /// channel scaled to the full range, so `rgb:f/f/f` is white and `rgb:1e1/1e1/1e1` is the same
    /// colour as `rgb:1e1e/1e1e/1e1e`; a parser that read the digits as a fixed-width byte would get
    /// both of those wrong in a way nobody would notice until a screenshot looked off.
    func testEveryBodyATerminalAnswersWithParses() {
        XCTAssertEqual(RGB.parse("rgb:1e1e/1e1e/1e1e"), RGB(0x1E_1E_1E), "Ghostty, 16-bit")
        XCTAssertEqual(RGB.parse("rgb:1e/1e/1e"), RGB(0x1E_1E_1E), "8-bit")
        XCTAssertEqual(RGB.parse("rgb:0d0d/1111/1717"), RGB(0x0D_11_17), "Rex's dark background")
        XCTAssertEqual(RGB.parse("rgb:1e1/1e1/1e1"), RGB(0x1E_1E_1E), "3 digits scale to the same colour")
        XCTAssertEqual(RGB.parse("rgb:f/f/f"), RGB(0xFF_FF_FF), "one digit is the whole range")
        XCTAssertEqual(RGB.parse("#1E1E1E"), RGB(0x1E_1E_1E))
        XCTAssertEqual(RGB.parse("#1e1e1e"), RGB(0x1E_1E_1E))
        XCTAssertEqual(RGB.parse("#fff"), RGB(0xFF_FF_FF))
        XCTAssertEqual(RGB.parse(" #0D1117\n"), RGB(0x0D_11_17),
                       "the body is trimmed: only a misparse would keep the terminal's padding")
    }

    /// Everything else is `.none`. A palette derived from a *misparsed* colour is a wrong colour on
    /// every cell of the pane, and `nil` — today's hard-coded SGR table — is the correct answer to
    /// "I do not know".
    func testEveryMalformedBodyIsRefused() {
        for body in ["rgb:gg/00/00",      // a non-hex digit
                     "rgb:1/2",           // two channels
                     "rgb:1e/1e/1e/1e",   // four
                     "rgb:12345/1/1",     // five digits in a channel
                     "rgb:",              // nothing at all
                     "",                  // nor this
                     "rgba:1e/1e/1e/1",   // four channels with alpha
                     "1e1e1e",            // the hex without its introducer
                     "#12", "#1234", "#12345", "#1234567",   // wrong lengths
                     "#gggggg",           // a non-hex digit after `#`
                     "rgb:1e /1e/1e"] {   // a space inside a channel
            XCTAssertNil(RGB.parse(body), "\(body.debugDescription) is not a colour")
        }
    }
}
