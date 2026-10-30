/// A fixed-size ring of recent samples, with the statistics a "why does it feel slow" question needs.
///
/// Every number the diagnostics show is one of these: `cap`, `pipe`, `write`, `zlib`, `input`. They
/// are all "how long did the last few hundred of these take", and the answer is always a percentile
/// rather than an average — a stutter is a p99, and averaging it away is how a 300 ms hiccup once
/// looked like a stable 45 ms (docs/BENCHMARK.md, Q3).
public struct Series: Equatable {
    public let capacity: Int
    private var values: [Double] = []
    /// Where the next sample goes, once the ring is full.
    private var next = 0

    public init(capacity: Int = 300) {
        self.capacity = Swift.max(1, capacity)
        values.reserveCapacity(self.capacity)
    }

    public mutating func add(_ value: Double) {
        if values.count < capacity {
            values.append(value)
        } else {
            values[next] = value
            next = (next + 1) % capacity
        }
    }

    public mutating func removeAll() {
        values.removeAll(keepingCapacity: true)
        next = 0
    }

    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }

    /// The most recent sample, or `nan` when there is none. `nan` rather than 0 on purpose: a panel
    /// that prints `0 ms` before the first frame is a lie, and one that prints `—` is not.
    public var last: Double { values.isEmpty ? .nan : values[(next + values.count - 1) % values.count] }

    /// Nearest-rank percentile over the ring, `q` in 0...1. `nan` when empty.
    public func percentile(_ q: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let rank = Int((Double(sorted.count - 1) * Swift.min(Swift.max(q, 0), 1)).rounded())
        return sorted[rank]
    }

    public var max: Double { values.max() ?? .nan }
    public var mean: Double {
        guard !values.isEmpty else { return .nan }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Oldest first, for the report bundle.
    public var all: [Double] {
        guard values.count == capacity else { return values }
        return Array(values[next...] + values[..<next])
    }

    /// `12.3` / `—`, so a missing sample cannot be mistaken for a measurement of zero.
    public static func show(_ value: Double, decimals: Int = 1) -> String {
        guard !value.isNaN else { return "—" }
        return String(format: "%.\(decimals)f", value)
    }
}

/// The rates the diagnostics show, computed in **one** place so the panel and `--stats-json` cannot
/// disagree about what `tiles/s` means.
///
/// Two counter snapshots and the wall clock between them; everything else is a division. Counters
/// only ever grow, and a reset (a new layout, a reconnect) shows up as a negative delta, which is
/// clamped to zero rather than printed as a negative rate.
public struct Rates: Equatable {
    public var fps: Double = 0
    public var captureFps: Double = 0
    public var tilesPerSec: Double = 0
    public var skippedPerSec: Double = 0
    public var idlePerSec: Double = 0
    public var mbps: Double = 0

    public struct Counters: Equatable {
        /// Frames the loop drew.
        public var frames: Int
        /// Frames ScreenCaptureKit delivered (including the ones the loop declined).
        public var delivered: Int
        /// Tiles emitted.
        public var tiles: Int
        /// Bytes of tile payload.
        public var bytes: Int
        /// Frames the capturer skipped, and frames it reported idle.
        public var skipped: Int
        public var idle: Int
        public init(frames: Int = 0, delivered: Int = 0, tiles: Int = 0, bytes: Int = 0,
                    skipped: Int = 0, idle: Int = 0) {
            self.frames = frames
            self.delivered = delivered
            self.tiles = tiles
            self.bytes = bytes
            self.skipped = skipped
            self.idle = idle
        }
    }

    public init() {}

    /// Rates over the interval between two counter snapshots taken `seconds` apart.
    public init(previous: Counters, current: Counters, seconds: Double) {
        guard seconds > 0.001 else { return }
        func rate(_ now: Int, _ before: Int) -> Double {
            Double(max(0, now - before)) / seconds
        }
        fps = rate(current.frames, previous.frames)
        captureFps = rate(current.delivered, previous.delivered)
        tilesPerSec = rate(current.tiles, previous.tiles)
        mbps = Double(max(0, current.bytes - previous.bytes)) / 1_048_576.0 / seconds
        skippedPerSec = rate(current.skipped, previous.skipped)
        idlePerSec = rate(current.idle, previous.idle)
    }
}
