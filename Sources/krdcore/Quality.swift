/// How much colour a frame may lose, as one number from 0 to 100.
///
/// The number is a *ceiling on the bit depth*, not a target: every tile still gets the encoder that
/// is cheapest for its content, and the ceiling says how far that encoder may go. That is why 100
/// means "not one pixel changes" and why the default (80) is exactly what krd has always done.
///
/// Bit depth is the right axis because it is the one that both the bytes and the eye follow: leaving
/// the low bits off gives zlib repeats to point at, and the visible damage grows smoothly with the
/// number of bits dropped. Channel count is *not* a quality rung -- a greyscale frame at 8 bits per
/// pixel costs 2.2x less than lossless, while a 3-3-2 colour frame at the same 8 bits costs 5.1x,
/// because coarse quantisation is what creates the repeats (measured, docs/ENCODING.md).
///
/// The rungs between 50 and 100 all stay on `f=24`, so no terminal, no protocol and no decoder
/// changes are involved; below 50 the encoder needs PNG payloads (grey/paletted `f=100`) and those
/// rungs are not shipped yet, so values under 50 clamp to 4-4-4.
///
/// | value | bits per pixel | what the tiles look like        | bytes vs lossless |
/// |------:|---------------:|---------------------------------|------------------:|
/// |   100 |             24 | lossless                        |             1.00x |
/// |    90 |             18 | 6-6-6, 262k colours             |             1.35x |
/// |  *80* |             16 | 5-6-5, 65k colours (the default)|             1.57x |
/// |    70 |             15 | 5-5-5, 32k colours              |             1.80x |
/// |    50 |             12 | 4-4-4, 4096 colours             |             2.26x |
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

    /// The value the user asked for, clamped to 0...100.
    public let value: Int
    /// `nil` means lossless. Otherwise the bit depth every quantised tile is reduced to.
    public let bits: Bits?
    /// Quantise every tile, instead of only the ones that proved incompressible. Set from 70 down:
    /// at that point the bytes matter more than the guard's small fidelity win on text.
    public let eager: Bool

    public init(_ value: Int) {
        let clamped = min(100, max(0, value))
        self.value = clamped
        self.bits = Self.bits(for: clamped)
        self.eager = clamped <= 70
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
