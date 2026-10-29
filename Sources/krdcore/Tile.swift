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
    public let ratio: Double
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
    private let threshold: Double
    private let hysteresis: Double
    private let textLevel: Int
    private let photoLevel: Int

    public init(tiles: Int, textLevel: Int = 9, photoLevel: Int = 1) {
        ratio = [Double](repeating: -1, count: tiles)      // -1 = never seen
        level = [Int](repeating: 5, count: tiles)          // first frame: middle ground
        threshold = 0.10
        hysteresis = 0.03
        self.textLevel = textLevel
        self.photoLevel = photoLevel
    }

    public var count: Int { level.count }

    public func level(for index: Int) -> Int {
        guard index < level.count else { return 5 }
        return level[index]
    }

    mutating func observe(index: Int, ratio newRatio: Double) {
        guard index < level.count else { return }
        ratio[index] = newRatio
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
