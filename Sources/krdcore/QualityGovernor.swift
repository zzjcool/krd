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
///
/// ## A sample is *time*, not a frame (issue #93)
///
/// The ratio above used to be a ratio of **frames**, and that is self-defeating on a pipe that
/// stalls: a frame whose `write(2)` blocks for 2.5 s removes exactly the frames that would have
/// been its samples. One hang contributed **one** late frame, the burst of fast frames after it
/// diluted the ratio to ~2.5 %, and a link that froze the picture nine times in 34 s never left the
/// top rung (`--mock`, 5 KB/s drain, issue #93's measurement).
///
/// So each sample carries the **wall time it accounts for** (`span`): the blocked duration of the
/// write that produced it, floored at one frame interval. The ratio is then `Σ span(late) / Σ span`
/// — the fraction of wall clock the pipe spent behind — and the ladder reads:
///
/// - a **hang**: one sample, `span = 2.5 s`, i.e. 50 frame intervals out of a 3 s window. It steps
///   down on the first one, which is the point: the picture is already frozen.
/// - a **slow link that still moves**: many samples, each `span ≈ 50 ms` and each late. Same ratio,
///   same step — this is the behaviour that already worked, unchanged.
/// - a **calm link**: not late, `span = 50 ms` each, ratio 0.
///
/// The span is derived from the write duration and floored at the frame interval, **never** from the
/// gap between samples: an idle screen emits no frames at all (a deduped frame writes nothing, #95),
/// so a still picture contributes no samples and cannot look like a stall. Counting "frames that
/// never arrived" — the obvious alternative — would do exactly that.
///
/// The same arithmetic fixes the *up* side: one stall in ten quiet seconds weighs 25 % and can no
/// longer pass as "0.5 % of the frames were late, the link is quiet".
/// Weighting by frames is a mean over frames, and a mean is how a stall disappears; weighting by
/// wall time is the tail.
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

    /// What one emitted frame tells the ladder (issue #93).
    ///
    /// `late` is the causal question — did this write take longer than the interval the frame had to
    /// fit in — and `span` is how much wall clock this frame stands for: its blocked write time,
    /// floored at the frame interval, because a frame that wrote quickly still occupied its slot.
    /// A blocked write *is* the missing frames, which is why the two travel together.
    public struct FrameSample: Equatable {
        public let late: Bool
        /// Seconds of wall time this frame accounts for. Strictly positive.
        public let span: Double
        public init(late: Bool, span: Double) {
            self.late = late
            self.span = span
        }
    }

    /// The rule from one frame's `write_ms` (and the round trip's second opinion, #52).
    ///
    /// Pure, so the rule the frame loop uses is the rule the tests feed a synthetic timeline to:
    /// `main.swift` calls this, `Tests/krdcoreTests/QualityGovernorTests` builds nine 2.5 s hangs
    /// with it and checks the rungs it takes.
    public static func frameSample(writeMs: Double, targetFps: Int, rttLate: Bool = false)
        -> FrameSample {
        let period = 1.0 / Double(Swift.max(targetFps, 1))
        return FrameSample(late: writeMs > period * 1000.0 || rttLate,
                           span: Swift.max(writeMs / 1000.0, period))
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
    private var samples: [(t: Double, late: Bool, span: Double)] = []
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

    /// One frame: `late` is "this frame took longer than the interval it has to fit in", and `span`
    /// is the wall time it accounts for (see `frameSample`, and the stall note in the type's doc).
    public mutating func observe(at t: Double, late: Bool, span: Double) -> Change? {
        samples.append((t, late, Swift.max(span, 0)))
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

    private func window(at t: Double, seconds: Double, minSamples: Int)
        -> [(t: Double, late: Bool, span: Double)]? {
        let recent = samples.filter { $0.t >= t - seconds }
        if let first = recent.first, recent.count >= minSamples, t - first.t >= seconds * 0.9 {
            return recent
        }
        let widened = samples.filter { $0.t >= t - maxWindow }
        guard let first = widened.first, widened.count >= minSamples,
              t - first.t >= seconds * 0.9 else { return nil }
        return widened
    }

    /// Late **wall time** over total wall time, not late frames over frames: a stall is one sample
    /// worth seconds (see the type's doc). Zero-width windows (every span 0, which the clamp in
    /// `observe` prevents but a caller can synthesise) read as calm rather than as a division by 0.
    private func ratio(_ window: [(t: Double, late: Bool, span: Double)]) -> Double {
        let total = window.reduce(0) { $0 + $1.span }
        guard total > 0 else { return 0 }
        return window.reduce(0) { $0 + ($1.late ? $1.span : 0) } / total
    }
}
