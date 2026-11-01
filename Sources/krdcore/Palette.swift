import Foundation

/// One 24-bit colour — the only colour type the interface has (issue #213).
///
/// The interface used to have no palette at all: every colour was either the terminal's own default
/// (SGR 37/97/2) or a hard-coded 16-colour SGR (`Chrome.Style.sgr`), so a wall on a light terminal
/// looked like a wall on a dark one — and the brand blue did not exist in the source
/// (`grep -rn 5EB8FF Sources` was empty before this file).
///
/// A value, not a global: `Palette(foreground:background:)` is a pure function of the two colours
/// the terminal answered to `OSC 10`/`OSC 11`, so a test can hand it a light pair and a dark pair and
/// get two palettes out of one code path.
public struct RGB: Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// `0xRRGGBB` — the way a colour is written in prose, in a theme file, and in this tree's tests.
    public init(_ hex: UInt32) {
        self.init(r: UInt8((hex >> 16) & 0xFF), g: UInt8((hex >> 8) & 0xFF), b: UInt8(hex & 0xFF))
    }

    public var hex: UInt32 { UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b) }

    /// `38;2;r;g;b` — a foreground colour as an SGR parameter list (no `ESC [`, no `m`), the form the
    /// two adopters append to the style table they already have.
    public var foregroundSGR: String { "38;2;\(r);\(g);\(b)" }
    /// `48;2;r;g;b` — the same colour as a background parameter.
    public var backgroundSGR: String { "48;2;\(r);\(g);\(b)" }

    /// WCAG relative luminance in linear sRGB — libghostty's `ghostty_color_luminance`.
    ///
    /// The transfer function is the sRGB one (`c <= 0.04045`), not WCAG 2.0's older `0.03928`: for
    /// 8-bit input the two thresholds fall in the same empty interval (`0.03928 × 255 = 10.02`,
    /// `0.04045 × 255 = 10.31`, and there is no integer channel value between them), so every colour
    /// this program can hold has the same luminance either way.
    public var luminance: Double {
        func linear(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio, 1…21 — libghostty's `ghostty_color_contrast`.
    ///
    /// The order of the two arguments does not matter: the brighter luminance is always the
    /// numerator, which is what makes "an accent against a background" a number with a meaning
    /// (4.5 is WCAG AA for body text).
    public func contrast(_ other: RGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Linear interpolation in 8-bit sRGB: `t = 0` is this colour, `t = 1` is `other`.
    ///
    /// Every derived surface is one of these, which is what makes a light pair and a dark pair land
    /// on *different* answers from one code path: the surfaces sit between the two colours the
    /// terminal gave us, so their direction follows the background.
    public func mixed(with other: RGB, _ t: Double) -> RGB {
        let f = min(max(t, 0), 1)
        func step(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Double(a) + (Double(b) - Double(a)) * f).rounded())
        }
        return RGB(r: step(r, other.r), g: step(g, other.g), b: step(b, other.b))
    }

    /// An `OSC 10` / `OSC 11` answer body (everything after the `10;` / `11;`), or `nil`.
    ///
    /// Two forms are in the wild and both are accepted:
    ///
    ///     rgb:1e1e/1e1e/1e1e     xterm's 16-bit-per-channel form — what Ghostty and Rex answer
    ///     rgb:1e/1e/1e           8-bit
    ///     #1e1e1e                the shortened form some terminals answer anyway
    ///
    /// xterm's rule is that each channel is 1–4 hex digits scaled to the 16-bit range, so `rgb:f/f/f`
    /// is white and `rgb:1e1/1e1/1e1` is the same colour as `rgb:1e1e/1e1e/1e1e`. Anything else —
    /// a wrong channel count, a non-hex digit, an empty body, `rgba:`, a body with trailing junk — is
    /// `nil`, because a palette derived from a *misparsed* colour is a wrong colour on the pane and
    /// the default table is the correct answer to "I do not know".
    public static func parse(_ body: String) -> RGB? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { return parseHexTriplet(String(text.dropFirst())) }
        guard text.hasPrefix("rgb:") else { return nil }
        let fields = text.dropFirst(4).split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        var channels: [UInt8] = []
        channels.reserveCapacity(3)
        for field in fields {
            guard let value = scaleChannel(String(field)) else { return nil }
            channels.append(value)
        }
        return RGB(r: channels[0], g: channels[1], b: channels[2])
    }

    /// `#RRGGBB` or `#RGB`, nothing else.
    private static func parseHexTriplet(_ digits: String) -> RGB? {
        guard digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        switch digits.count {
        case 6:
            guard let value = UInt32(digits, radix: 16) else { return nil }
            return RGB(value)
        case 3:
            var value: UInt32 = 0
            for ch in digits {
                guard let nibble = ch.hexDigitValue else { return nil }
                value = value << 4 | UInt32(nibble)
            }
            func nibble(_ shift: UInt32) -> UInt8 { UInt8((value >> shift & 0xF) * 0x11) }
            return RGB(r: nibble(8), g: nibble(4), b: nibble(0))
        default:
            return nil
        }
    }

    /// One `rgb:` channel: 1–4 hex digits, scaled to 0…255 the way xterm does it (the value is
    /// stretched to the full 16-bit range and the high byte is kept).
    private static func scaleChannel(_ digits: String) -> UInt8? {
        guard (1...4).contains(digits.count), digits.allSatisfy({ $0.isHexDigit }),
              let value = UInt32(digits, radix: 16) else { return nil }
        let maxValue = UInt32(1 << (4 * digits.count)) - 1
        let scaled = (value * 0xFFFF + maxValue / 2) / maxValue
        return UInt8(scaled >> 8)
    }
}

/// The interface palette, derived from the terminal's own foreground and background (issue #213,
/// design §4.3).
///
/// Two colours in, eight out: three surface steps *between* the background and the foreground (cards,
/// panels, the shelf), a border, a dimmed text colour, and the accent. Nothing is assumed about the
/// terminal's theme — the same code path answers a light pair and a dark pair differently, because
/// every derived colour is an interpolation whose *direction* is the background's.
///
/// The accent starts at the brand blue `#5EB8FF` and is moved toward the foreground until it passes
/// WCAG AA (4.5:1) against the background. A fixed blue is fine on a dark terminal and unreadable on a
/// light one, which is the failure this rule exists to prevent — so on a light background the accent
/// comes out a darker blue, and on a dark one it is the brand colour unchanged.
///
/// A value: `Palette(foreground:background:)` takes no terminal, no clock and no global, so
/// `PaletteTests` drives it with two pairs and compares.
public struct Palette: Equatable, Sendable {
    /// The brand blue, the one colour in this file that is not derived: `#5EB8FF`.
    public static let brand = RGB(0x5E_B8_FF)

    /// WCAG AA for body text, which is the bar the accent has to clear as a *foreground* colour.
    public static let minimumContrast = 4.5

    /// How far toward the foreground each derived colour sits. Fixed fractions rather than a
    /// per-theme table: they are what makes one code path serve both schemes.
    static let surface1Mix = 0.06
    static let surface2Mix = 0.10
    static let surface3Mix = 0.15
    static let borderMix = 0.24
    static let dimTextMix = 0.62

    /// How many steps the accent walks toward the foreground before it gives up (1/32 of the way
    /// each). Coarse on purpose: the answer is a colour a person reads, and 32 samples of a
    /// contrast ratio settles to within one 8-bit step of the exact crossing.
    static let accentSteps = 32

    public let foreground: RGB
    public let background: RGB

    /// A raised surface: the card and panel fills, nearest the background.
    public let surface1: RGB
    /// The next step up: a hovered card, the top of a shelf.
    public let surface2: RGB
    /// The highest step: a pressed card, an open panel.
    public let surface3: RGB
    /// The hairline around a surface, and the wall's rules.
    public let border: RGB
    /// Text that must be readable but not compete with the foreground: counts, captions, the footer.
    public let dimText: RGB
    /// The brand accent, contrast-checked against `background`.
    public let accent: RGB

    public init(foreground: RGB, background: RGB) {
        self.foreground = foreground
        self.background = background
        func mix(_ t: Double) -> RGB { background.mixed(with: foreground, t) }
        self.surface1 = mix(Self.surface1Mix)
        self.surface2 = mix(Self.surface2Mix)
        self.surface3 = mix(Self.surface3Mix)
        self.border = mix(Self.borderMix)
        self.dimText = mix(Self.dimTextMix)
        self.accent = Palette.contrastChecked(Self.brand, background: background,
                                             foreground: foreground)
    }

    /// The same palette with the two colours' roles swapped — what a `DEC mode 2031` report means
    /// when the terminal cannot be asked `OSC 10`/`OSC 11` again (a probe reads stdin, and stdin
    /// belongs to the input reader once the mouse is live).
    ///
    /// A theme switch is, in the overwhelming majority of terminals, the same two colours with the
    /// roles exchanged: the light scheme's background is the dark scheme's foreground. So the palette
    /// is re-derived from the pair we already know and not invented. `inverted().inverted()` is the
    /// original palette, which is what makes a second report of the same scheme free.
    public func inverted() -> Palette { Palette(foreground: background, background: foreground) }

    /// Which scheme these two colours *look* like, by the background's luminance.
    ///
    /// Needed because `OSC 10`/`OSC 11` say what the colours are but not which scheme the terminal
    /// believes it is in, and the first `?997;Nn` report has to be compared against something: a
    /// terminal that starts light and reports light must not be "re-derived" into its inverse.
    public var scheme: ColourScheme { background.luminance >= 0.5 ? .light : .dark }

    /// `brush` moved toward `foreground` in `accentSteps` until its contrast against `background`
    /// passes `minimum`; the best sample if it never does.
    ///
    /// Walking toward the *foreground* is the rule the design asks for: the foreground is by
    /// definition the colour that reads on this background, so the walk can only improve the contrast
    /// of a mid-tone accent. The "best sample" fallback is for a pair whose foreground does not
    /// itself clear the bar (a deliberately low-contrast theme) — there the honest answer is the
    /// closest the palette can get, not a colour that pretends to pass.
    static func contrastChecked(_ brush: RGB, background: RGB, foreground: RGB) -> RGB {
        var best = brush
        var bestContrast = brush.contrast(background)
        for step in 0...accentSteps {
            let candidate = brush.mixed(with: foreground, Double(step) / Double(accentSteps))
            let contrast = candidate.contrast(background)
            if contrast >= minimumContrast { return candidate }
            if contrast > bestContrast {
                best = candidate
                bestContrast = contrast
            }
        }
        return best
    }
}
