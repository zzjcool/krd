import Foundation

/// Decides how much colour a frame may lose, and then how many frames there may be -- from the
/// *write* side of the pipeline, exactly like `ScaleGovernor` decides the pixel count (#64).
///
/// The order is the whole point. Losing colour is mild on text and photographs and fatal on nothing;
/// losing resolution is fatal on text; losing frames is noticeable but honest. So the ladder spends
/// bits first and geometry last:
///
///     quality 80 → 70 → 50, then fps 20 → 15 → 10, and only after that is there anything left to
///     take (which is `--scale auto`'s job, deliberately a separate governor: it reconfigures the
///     capture stream, while these two are just numbers the encoder and the frame loop read).
///
/// Two properties keep it safe to run unattended, both borrowed from `ScaleGovernor` because they
/// were the two things that made *that* one stop flapping:
///
/// - **Asymmetric thresholds.** A downgrade needs a majority of late frames over a short window
///   (50 % over 3 s); going back up needs near-silence over a long one (5 % over 10 s), because a
///   downgrade costs a slightly worse picture and an upgrade that was wrong costs a stutter.
/// - **A failed upgrade waits longer.** An upgrade undone within `probeSeconds` multiplies the next
///   quiet window by `backoff`, so a link that cannot hold a rung settles instead of oscillating.
///
/// `--scale auto` stays on top and outranks this: while the governor below has not finished its own
/// ladder, `handOver` is false and the caller must not let the scale governor act.
public struct QualityGovernor {
    /// One rung: how much colour, and how many frames per second the loop will allow.
    public struct Step: Equatable {
        public let quality: Int
        public let fps: Int
        public init(quality: Int, fps: Int) {
            self.quality = quality
            self.fps = fps
        }
        /// `q70 20fps` -- for the log line and the panel.
        public var label: String { "quality \(quality), \(fps) fps" }
    }

    public struct Change: Equatable {
        public let from: Step
        public let to: Step
        public let reason: String
        public var line: String {
            "\(reason); \(from.label) -> \(to.label)"
        }
    }

    /// Most quality first, fewest compromises last.
    public static let ladder: [Step] = [
        Step(quality: 80, fps: 20),
        Step(quality: 70, fps: 20),
        Step(quality: 50, fps: 20),
        Step(quality: 50, fps: 15),
        Step(quality: 50, fps: 10),
    ]

    /// The rung the capture was asked for, before the governor touched anything.
    public let floor: Step
    public var downRatio = 0.5
    public var downWindow = 3.0
    public var downMinSamples = 3
    public var maxWindow = 60.0
    public var upRatio = 0.05
    public var upWindow = 10.0
    public var upMinSamples = 8
    public var minDwell = 5.0
    public var probeSeconds = 20.0
    public var backoff = 3.0
    public var maxUpWindow = 300.0

    /// Index into `ladder`. Only ever moves one rung at a time.
    public private(set) var index: Int
    private var samples: [(t: Double, late: Bool)] = []
    private var lastChangeAt: Double = -.infinity
    private var lastUpgradeAt: Double?
    private var upWindowScale = 1.0

    public init(start: Step = QualityGovernor.ladder[0]) {
        floor = start
        // Start at the rung the user asked for, or the nearest one at or above it: a `--quality 60
        // --fps 20` start means "no better than 60 but no worse than that if the link allows", so it
        // begins at the first rung whose quality is <= 60.
        index = QualityGovernor.ladder.firstIndex { $0.quality <= start.quality } ?? 0
    }

    public var step: Step { QualityGovernor.ladder[index] }
    /// True once colour and frame rate have nothing left to give: the caller may let `--scale auto`
    /// take the next step, in that order and not before.
    public var handOver: Bool { index == QualityGovernor.ladder.count - 1 }
    public var requiredQuietWindow: Double { min(maxUpWindow, upWindow * upWindowScale) }

    /// One frame: `late` is "this frame took longer than the interval it has to fit in".
    public mutating func observe(at t: Double, late: Bool) -> Change? {
        samples.append((t, late))
        while let first = samples.first, t - first.t > maxWindow + 1 {
            samples.removeFirst()
        }
        guard t - lastChangeAt >= minDwell else { return nil }

        if index + 1 < QualityGovernor.ladder.count {
            if let window = window(at: t, seconds: downWindow, minSamples: downMinSamples),
               ratio(window) > downRatio {
                let change = Change(from: step, to: QualityGovernor.ladder[index + 1],
                                    reason: "pipe is behind")
                lastChangeAt = t
                if let upgradedAt = lastUpgradeAt {
                    if t - upgradedAt < probeSeconds {
                        upWindowScale = min(maxUpWindow / upWindow, upWindowScale * backoff)
                    } else {
                        upWindowScale = 1
                    }
                    lastUpgradeAt = nil
                }
                index += 1
                samples.removeAll()
                return change
            }
        }

        if index > 0 {
            if let window = window(at: t, seconds: requiredQuietWindow, minSamples: upMinSamples),
               ratio(window) < upRatio {
                let change = Change(from: step, to: QualityGovernor.ladder[index - 1],
                                    reason: "pipe has headroom")
                lastChangeAt = t
                lastUpgradeAt = t
                index -= 1
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
