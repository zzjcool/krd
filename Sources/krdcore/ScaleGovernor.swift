import Foundation

/// Decides when to capture fewer pixels, from the *write* side of the pipeline (issue #64).
///
/// The signal is not how long encoding takes -- it is whether the frame was written before the next
/// one was ready, i.e. `pipe_ms > 1000/fps`. When a link cannot carry the picture, that is what
/// grows first, and it is what the user feels as stutter while the encoder keeps producing frames
/// nobody will ever see (#26 measured 1.55 fps on a 20 MB/s link with the encoder still at 20).
///
/// Two things make this safe to run unattended:
///
/// - **The thresholds are asymmetric.** Going down is cheap and reversible (a softer picture), going
///   up is a bet that the link has room (a stutter the user sees). So a downgrade needs a majority
///   of late frames over a short window (50 % over 3 s), an upgrade needs near-silence over a long
///   one (5 % over 10 s).
/// - **A failed upgrade waits longer before trying again.** Without this the governor oscillates:
///   quiet at 0.5 → up → immediately late → down → quiet → up … which looks worse than either end
///   state. After an upgrade that is undone within `probeSeconds`, the next quiet window it demands
///   is multiplied by `backoff`, so a bad link settles into "mostly at 0.5, one probe every few
///   minutes" instead of flapping. A probe that survives `probeSeconds` resets that penalty.
///
/// Pure arithmetic: no clocks, no ScreenCaptureKit, so the whole decision table is unit-tested.
public struct ScaleGovernor {
    public struct Change: Equatable {
        public let from: Double
        public let to: Double
        public let reason: String
        public var line: String { "\(reason); scale \(ScaleGovernor.show(from)) -> \(ScaleGovernor.show(to))" }
    }

    /// Most pixels first. 1 is "what the pane can show"; 0.5 is a quarter of the bytes.
    public static let ladder: [Double] = [1, 0.5, 0.25]

    public static func show(_ scale: Double) -> String {
        scale == scale.rounded() ? String(Int(scale)) : String(format: "%g", scale)
    }

    /// > 50 % of frames late over 3 s: the link is losing, stop paying for pixels nobody sees.
    public var downRatio = 0.5
    public var downWindow = 3.0
    /// A window also needs a few frames in it: when the pipe has collapsed to 0.7 fps there are two
    /// frames in 3 s, and two frames are not a trend. Three frames that each took seconds to write
    /// are, so a sparse stream's window is widened to hold them (never beyond `maxWindow`).
    public var downMinSamples = 3
    /// The widest a sparse stream's window may get before it is "not enough evidence".
    public var maxWindow = 60.0
    /// < 5 % late over 10 s: probably room. Long on purpose -- see the type comment.
    public var upRatio = 0.05
    public var upWindow = 10.0
    public var upMinSamples = 8
    /// Never change twice within this, in either direction.
    public var minDwell = 5.0
    /// An upgrade undone within this many seconds counts as a failed probe.
    public var probeSeconds = 20.0
    /// What a failed probe multiplies the next quiet window by (capped at `maxUpWindow`).
    public var backoff = 3.0
    public var maxUpWindow = 300.0

    public private(set) var level: Double
    /// The frames the governor may still look at; older ones are dropped.
    private var samples: [(t: Double, late: Bool)] = []
    private var lastChangeAt: Double = -.infinity
    private var lastUpgradeAt: Double?
    private var upWindowScale = 1.0

    public init(start: Double = 1) {
        level = ScaleGovernor.ladder.contains(start) ? start : 1
    }

    /// The window an upgrade currently needs, backoff included (for logs and tests).
    public var requiredQuietWindow: Double { min(maxUpWindow, upWindow * upWindowScale) }

    /// One frame: `late` is "this frame took longer than the interval it has to fit in".
    public mutating func observe(at t: Double, late: Bool) -> Change? {
        samples.append((t, late))
        while let first = samples.first, t - first.t > maxWindow + 1 {
            samples.removeFirst()
        }
        guard t - lastChangeAt >= minDwell else { return nil }

        // Down first: if frames are being lost, a softer picture beats no picture.
        if let next = ScaleGovernor.ladder.first(where: { $0 < level - 1e-9 }) {
            if let window = window(at: t, seconds: downWindow, minSamples: downMinSamples),
               ratio(window) > downRatio {
                let change = Change(from: level, to: next, reason: "pipe is behind")
                lastChangeAt = t
                if let upgradedAt = lastUpgradeAt {
                    if t - upgradedAt < probeSeconds {
                        // We just came up and it did not hold: wait longer before trying again.
                        upWindowScale = min(maxUpWindow / upWindow, upWindowScale * backoff)
                    } else {
                        upWindowScale = 1        // the probe held, this is a new situation
                    }
                    // Either way the probe is finished, so a later `settle` must not undo the
                    // penalty we just applied (that was the flap: the reset kept handing the
                    // governor a 10-second window again and again).
                    lastUpgradeAt = nil
                }
                level = next
                samples.removeAll()
                return change
            }
        }

        // Up: only after the *whole* quiet window has been observed, not just the last few samples.
        if let previous = ScaleGovernor.ladder.last(where: { $0 > level + 1e-9 }) {
            if let window = window(at: t, seconds: requiredQuietWindow, minSamples: upMinSamples),
               ratio(window) < upRatio {
                let change = Change(from: level, to: previous, reason: "pipe has headroom")
                lastChangeAt = t
                lastUpgradeAt = t
                level = previous
                samples.removeAll()
                return change
            }
        }
        return nil
    }

    /// A probe that survived long enough to count as success gives the next one full permission.
    public mutating func settle(at t: Double) {
        guard let upgradedAt = lastUpgradeAt, t - upgradedAt >= probeSeconds else { return }
        upWindowScale = 1
        lastUpgradeAt = nil
    }

    /// The frames to judge on: the last `seconds` of them, widened to hold at least `minSamples`
    /// when the stream is too sparse to fill the window (a pipe that has collapsed to 0.7 fps
    /// produces two frames in 3 s). The window must also *span* its seconds, so a change cannot be
    /// decided on the two frames that arrived right after the previous one.
    private func window(at t: Double, seconds: Double, minSamples: Int) -> [(t: Double, late: Bool)]? {
        let recent = samples.filter { $0.t >= t - seconds }
        if let first = recent.first, recent.count >= minSamples, t - first.t >= seconds * 0.9 {
            return recent
        }
        let widened = samples.filter { $0.t >= t - maxWindow }
        guard let first = widened.first, widened.count >= minSamples,
              t - first.t >= seconds * 0.9 else { return nil }
        return widened
    }

    private func ratio(_ window: [(t: Double, late: Bool)]) -> Double {
        guard !window.isEmpty else { return 0 }
        return Double(window.filter(\.late).count) / Double(window.count)
    }
}
