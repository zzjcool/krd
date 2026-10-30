import Foundation

/// One dirty tile, compressed and ready to be turned into escapes.
///
/// Compression is the expensive half of a frame (usually >90 % of it), so it happens first, on
/// any thread, and produces a plain value. Only the escape assembly below touches writer state.
public struct CompressedTile {
    public let index: Int
    public let rect: TileRect
    public let payload: [UInt8]
    /// compressed / raw, remembered so the next frame can pick a zlib level for this tile.
    /// Exactly 1.0 when the payload is the raw pixels (issue #53).
    public let ratio: Double
    /// False when `payload` is raw pixels because zlib bought nothing on this tile. `emit` then
    /// leaves `o=z` off the escape: the terminal decodes the bytes as they are.
    public let isCompressed: Bool
    /// True when the pixels were quantised to 5-6-5 before encoding (issue #59), i.e. lossy. The
    /// wire format is still plain RGB — only the low bits are gone.
    public let isQuantised: Bool

    public init(index: Int, rect: TileRect, payload: [UInt8], ratio: Double,
                isCompressed: Bool = true, isQuantised: Bool = false) {
        self.index = index
        self.rect = rect
        self.payload = payload
        self.ratio = ratio
        self.isCompressed = isCompressed
        self.isQuantised = isQuantised
    }
}

public typealias TileRect = (x: Int, y: Int, w: Int, h: Int, col: Int, row: Int, cols: Int, rows: Int)

/// Per-tile zlib level policy.
///
/// The right level depends on the content, not on the tile: flat UI/text compresses 8x better at
/// level 9 and costs half a millisecond more, while a photo gains ~1 % going from level 1 to 12
/// for six times the CPU. The only free signal is the previous frame's ratio for the same tile,
/// which is why this is a small state machine with hysteresis instead of a static constant.
public struct LevelPolicy {
    private var ratio: [Double]
    private var level: [Int]
    /// Tiles whose last compression bought nothing: `plan(for:)` says level 0 and `compress` decides
    /// whether to send the pixels raw or re-test them cheaply.
    private var skipped: [Bool]
    /// Tiles that stay incompressible: quantise them to 5-6-5 before zlib (issue #59). A photo
    /// compresses 2.3x once the low bits are gone, and the terminal needs no new format for it.
    private var quantised: [Bool]
    /// Consecutive frames a tile's lossless attempt bought nothing. Two in a row before switching to
    /// quantisation: one noisy frame (a video cut, a scroll) is not a photo.
    private var streak: [Int]
    /// `--no-quantise` sets this false: lossless only, at the cost of the photo case.
    public let allowsQuantise: Bool
    private let threshold: Double
    private let hysteresis: Double
    private let textLevel: Int
    private let photoLevel: Int

    /// `compressed / raw` at or above this means zlib bought nothing. 1.0 inclusive on purpose: a
    /// tile sent raw reports exactly 1.0, so the state has to be stable at 1.0 as well as above it.
    public static let skipAt = 1.0

    public init(tiles: Int, textLevel: Int = 9, photoLevel: Int = 1, allowsQuantise: Bool = true) {
        ratio = [Double](repeating: -1, count: tiles)      // -1 = never seen
        level = [Int](repeating: 5, count: tiles)          // first frame: middle ground
        skipped = [Bool](repeating: false, count: tiles)
        quantised = [Bool](repeating: false, count: tiles)
        streak = [Int](repeating: 0, count: tiles)
        self.allowsQuantise = allowsQuantise
        threshold = 0.10
        hysteresis = 0.03
        self.textLevel = textLevel
        self.photoLevel = photoLevel
    }

    public var count: Int { level.count }

    /// 0 means "do not compress this tile" (issue #53); every other value is a zlib level.
    public func level(for index: Int) -> Int { plan(for: index).level }

    /// How many tiles the encoder is currently sending raw (tests and diagnostics).
    public var skippedCount: Int { skipped.lazy.filter { $0 }.count }

    /// How many tiles are being quantised to 5-6-5 (tests and diagnostics).
    public var quantisedCount: Int { quantised.lazy.filter { $0 }.count }

    /// What to do with one tile this frame: a zlib level (0 = do not compress) plus, when the
    /// content is incompressible, whether to drop the low bits first so that zlib has structure.
    public struct Plan: Equatable {
        public var level: Int
        public var quantise: Bool
        public init(level: Int, quantise: Bool = false) {
            self.level = level
            self.quantise = quantise
        }
    }

    public func plan(for index: Int) -> Plan {
        guard index < level.count else { return Plan(level: 5) }
        return Plan(level: skipped[index] ? 0 : level[index],
                    quantise: quantised[index] && allowsQuantise)
    }

    /// `quantisedIn` is what `compress` actually did with the tile: a quantised tile's ratio says
    /// nothing about what *lossless* compression would have done, so it must not drive the streak.
    mutating func observe(index: Int, ratio newRatio: Double, quantisedIn: Bool = false) {
        guard index < level.count else { return }
        ratio[index] = newRatio

        // Does compression pay for this tile at all? Enter at >= 1.0 (nothing gained, or expanded);
        // leave only once zlib wins clearly again (below 1.0 - hysteresis), so a tile hovering at
        // break-even does not flap between two encodings every frame.
        if quantisedIn {
            // The ratio came out of quantised bytes, so it says nothing about lossless (it is
            // small *because* the low bits are gone). Staying put is what stops the two encodings
            // from flapping every frame. Quantisation ends when `compress` finds content that
            // compresses losslessly again — a lossless ratio then comes back through here.
            skipped[index] = true
        } else if newRatio >= Self.skipAt {
            skipped[index] = true
            streak[index] += 1
            if streak[index] >= 2 { quantised[index] = true }        // two in a row: this is a photo
        } else if newRatio < Self.skipAt - hysteresis {
            skipped[index] = false
            streak[index] = 0
            quantised[index] = false      // a lossless attempt paid again: back to lossless
        }

        if newRatio < threshold - hysteresis {
            level[index] = textLevel
        } else if newRatio > threshold + hysteresis {
            level[index] = photoLevel
        }
    }
}

/// Pixel layout on the wire. The desktop is opaque, so RGB wins on bytes and on CPU time.
public enum PixelFormat {
    case rgb
    case rgba

    public var bytesPerPixel: Int { self == .rgb ? 3 : 4 }
    /// The `f=` field of the kitty protocol.
    public var protocolChannels: Int { self == .rgb ? 24 : 32 }
}

/// When the terminal is allowed to repaint.
public enum SyncMode {
    /// one `?2026h … ?2026l` around the whole frame: 16 bytes total instead of 16 per tile
    case frame
    /// the old behaviour, one block per tile (progressive commit, useful on very slow links)
    case tile
    case none
}
