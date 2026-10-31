/// How much colour a frame may lose, as one number from 0 to 100.
///
/// The number is a *ceiling on the bit depth*, not a target: every tile still gets the encoder that
/// is cheapest for its content, and the ceiling says how far that encoder may go. That is why 100
/// means "not one pixel changes", and why the default (80) is the decision krd has always made:
/// 5-6-5 on a tile that proved incompressible, lossless everywhere else.
///
/// Bit depth is the right axis because it is the one that both the bytes and the eye follow: leaving
/// the low bits off gives zlib repeats to point at, and the visible damage grows smoothly with the
/// number of bits dropped. Channel count is *not* a quality rung -- a greyscale frame at 8 bits per
/// pixel costs 2.2x less than lossless, while a 3-3-2 colour frame at the same 8 bits costs 5.1x,
/// because coarse quantisation is what creates the repeats (measured, docs/ENCODING.md).
///
/// The rungs between 50 and 100 all stay on `f=24`, so no terminal, no protocol and no decoder
/// changes are involved; below 50 the encoder needs PNG payloads (grey/paletted `f=100`) and those
/// rungs are not shipped yet, so anything under 70 resolves to 4-4-4 and the panel says so.
///
/// | value | bits per pixel | what the tiles look like        | bytes vs lossless |
/// |------:|---------------:|---------------------------------|------------------:|
/// Byte counts below are `krd --bench --json --rounds 4`, `photo` case (hash noise), wire bytes:
///
/// | value | bits per pixel | what a quantised tile looks like  | wire   | vs 100 |
/// |------:|---------------:|----------------------------------|-------:|-------:|
/// |   100 |             24 | lossless                         | 521,797 | 1.00x |
/// |    90 |             18 | 6-6-6, 262k colours              | 399,955 | 1.30x |
/// |  *80* |             16 | 5-6-5, 65k colours (the default) | 408,935 | 1.28x |
/// |    70 |             15 | 5-5-5, 32k colours               | 351,947 | 1.48x |
/// |    50 |             12 | 4-4-4, 4096 colours              | 308,143 | 1.69x |
///
/// 6-6-6 comes out *cheaper* than 5-6-5 because a uniform 64-symbol alphabet codes better than
/// 5-6-5's 32/64/32 one -- it is a candidate default, kept off only because 80 has to stay what krd
/// did before this type existed.
public struct QualityBudget: Equatable {
    /// Bits kept per channel, high bits first. Losing bits this way is what gives zlib structure.
    public struct Bits: Equatable {
        public var r: UInt8
        public var g: UInt8
        public var b: UInt8

        public init(r: UInt8, g: UInt8, b: UInt8) {
            self.r = r
            self.g = g
            self.b = b
        }

        public var bitsPerPixel: Int { Int(r) + Int(g) + Int(b) }
        /// `5-6-5`, for the panel and for error messages.
        public var label: String { "\(r)-\(g)-\(b)" }
    }

    public static let sixSixSix = Bits(r: 6, g: 6, b: 6)
    public static let fiveSixFive = Bits(r: 5, g: 6, b: 5)
    public static let fiveFiveFive = Bits(r: 5, g: 5, b: 5)
    public static let fourFourFour = Bits(r: 4, g: 4, b: 4)

    /// The lowest rung that needs no PNG payload. Anything below clamps here.
    public static let lowestShipped = 50
    /// 5-6-5 behind the two-frame guard: what krd did before `--quality` existed.
    public static let `default` = QualityBudget(80)

    /// The landing screen's own rung: 5-5-5, and quantised *eagerly* rather than behind the
    /// incompressible-tile guard (issue #88).
    ///
    /// Why the wall gets its own number instead of following `--quality`: the two spend different
    /// things. The mirror's number answers "how much fidelity is worth paying for per frame on this
    /// link" and its ladder moves it 80 -> 70 -> 50 as the pipe falls behind. The wall has no ladder
    /// and no frames: it captures once per change, and what the reader waits for is
    /// *time-to-first-picture* over a link that already carries the picture.
    ///
    /// Why 5-5-5 is the right rung for these pixels specifically: the stage is a desktop screenshot - dark
    /// title bars, flat backgrounds, near-flat gradients, big runs of one colour - and the cards are
    /// window thumbnails of the same material. Dropping the low bits is what gives deflate long
    /// matches to point at, and it is *cheaper to encode* than lossless, so the rung buys bytes and
    /// milliseconds on the same axis. The damage is invisible at the size these pictures are drawn:
    /// the stage is a 1955x1221 picture of a 1920x1199 desktop (issue #88), i.e. nobody is reading
    /// 24-bit gradients off it.
    ///
    /// The one thing this rung must never become is a *smaller picture*: the wall's rule is that the
    /// picture is its cells (§6.6, #121), so a quality knob for it may only drop bits per pixel, never
    /// pixels per cell. `PanelImage.fit` stays the only thing that decides the picture's size.
    public static let wall = QualityBudget(70)

    /// The value the user asked for, clamped to 0...100.
    public let value: Int
    /// `nil` means lossless. Otherwise the bit depth every quantised tile is reduced to.
    public let bits: Bits?
    /// Quantise every tile, instead of only the ones that proved incompressible. Set from 70 down:
    /// at that point the bytes matter more than the guard's small fidelity win on text.
    public let eager: Bool

    /// `eager` overrides the rung's own default. The two axes are separable on purpose (issue #87):
    /// the *bit depth* is how much colour a frame may lose and the *guard* is how eagerly the
    /// encoder spends it, and the menu's two sliders move one each. `QualityBudget(80)` is still
    /// "5-6-5 behind the guard" -- nothing about the default, and therefore nothing about the
    /// byte contract, moved.
    public init(_ value: Int, eager: Bool? = nil) {
        let clamped = min(100, max(0, value))
        self.value = clamped
        self.bits = Self.bits(for: clamped)
        self.eager = eager ?? (clamped <= 70)
    }

    private static func bits(for value: Int) -> Bits? {
        switch value {
        case 90...100: return value >= 100 ? nil : sixSixSix
        case 80..<90: return fiveSixFive
        case 70..<80: return fiveFiveFive
        default: return fourFourFour              // 50 and below: lowest shipped rung
        }
    }

    /// `lossless`, or `5-6-5` -- short enough for a status line.
    public var label: String { bits?.label ?? "lossless" }

    /// True when this budget cannot keep a frame lossless.
    public var isLossy: Bool { bits != nil }
}
