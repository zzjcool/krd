/// A round-trip probe built on the terminal's own status report: we write `CSI 5n`, a VT terminal
/// answers `CSI 0n`, and the answer comes back over the same ssh connection the picture goes down.
///
/// Why this and not just the write path: `write(2)` blocking only fires *after* sshd's userspace
/// buffer is full, so a slow link is invisible until seconds of picture have piled up. The probe is
/// 4 bytes every couple of seconds, and because its answer queues behind the picture it measures the
/// delay a person actually feels — buffering included.
///
/// The state machine is pure arithmetic (no clocks, no I/O), so `RTTProbeTests` can drive it with a
/// fake timeline. `Desk` feeds it `benchNowMs() / 1000` seconds.
public struct RTTProbe: Equatable {
    /// Seconds between probes. Probed from a 1 Hz tick, so the effective period is rounded up.
    public var interval: Double
    /// A probe unanswered for this long counts as lost (the terminal may not implement DSR).
    public var timeout: Double
    /// Lost probes in a row before the probe switches itself off. Not one: a terminal can miss a
    /// single report while it is busy repainting.
    public var missesBeforeOff: Int

    /// When the outstanding probe was written, in the same seconds as `due(at:)`.
    public private(set) var pendingSince: Double?
    /// Probes written, answers received, and lost probes.
    public private(set) var sent = 0
    public private(set) var answered = 0
    public private(set) var misses = 0
    /// `true` once enough probes were lost: the terminal does not answer, so stop asking.
    public private(set) var unavailable = false
    /// Recent round trips, in ms.
    public private(set) var series: Series

    private var lastSentAt = -Double.greatestFiniteMagnitude

    public init(interval: Double = 2, timeout: Double = 2, missesBeforeOff: Int = 3,
                capacity: Int = 300) {
        self.interval = interval
        self.timeout = timeout
        self.missesBeforeOff = max(1, missesBeforeOff)
        self.series = Series(capacity: capacity)
    }

    public var isMeasuring: Bool { !unavailable }
    /// The last round trip in ms (`nan` before the first answer).
    public var lastMs: Double { series.last }
    public var p99Ms: Double { series.percentile(0.99) }
    public var p50Ms: Double { series.percentile(0.5) }
    /// The smallest round trip in the ring, in ms (`nan` before the first answer).
    ///
    /// The one number that tells "held" from "slow" (issue #199): a fast minimum means no packet
    /// was ever waiting, so a late median is the ssh client batching replies rather than a pipe that
    /// is behind. `nan` on an empty ring, and `LinkVerdict.classify` treats that as no measurement
    /// rather than as a very fast one.
    public var minMs: Double { series.min }

    /// The frame path's lateness question about the link: "is the round trip bad enough that the next
    /// frame should count as late" (#52, #187).
    ///
    /// **Two** answers have to be over budget, not one. On OpenSSH 10 the terminal holds the `CSI 0n`
    /// reply behind `ObscureKeystrokeTiming`, so a single answer came back at 258 ms on a link whose
    /// round trip is 25 ms. The probe goes out every 2 s and the tick that consumes it runs at 1 Hz,
    /// so that one answer was "the latest" for ~2 s: read as `lastMs > budget`, it made every frame
    /// written in those seconds late — 31 of 61 at 20 fps, a majority, which spent a rung of the
    /// quality ladder on a link that was never congested. A round trip that is genuinely too long is
    /// a *sustained* condition; one outlier is a batching artefact, not a pipe that is behind.
    ///
    /// Not late while the probe is measuring nothing, either: no answer yet, switched off
    /// (`unavailable`), or the newest probe expired unanswered — the freshest sample is then stale.
    /// `expire()` leaves `series` alone on purpose (the report still wants the history), so the last
    /// number that happened to land can sit in `lastMs` for good; that is the `rtt —` case in the
    /// panel once the probe switches itself off, and it is not a measurement of anything.
    ///
    /// This is the second opinion `QualityGovernor.frameSample(writeMs:targetFps:rttLate:)` takes;
    /// `writeMs` stays the immediate signal, and #93's span weighting decides how much a late frame
    /// weighs. The fix is upstream of `late`, so those rules are untouched.
    public func isLate(budgetMs: Double) -> Bool {
        guard isMeasuring, misses == 0, series.count >= 2 else { return false }
        return series.all.suffix(2).allSatisfy { $0 > budgetMs }
    }

    /// The link's symptom, from the probe's own history (issue #199). **The rule is
    /// `LinkVerdict.classify`**; this function is the guard in front of it, and the guard is the same
    /// one #187 put in front of `isLate`: no verdict may be derived from an answer that is no longer
    /// a measurement.
    ///
    /// Three ways that happens, and all three answer `unknown`: the probe switched itself off (a
    /// terminal without DSR), the newest probe expired unanswered (`expire()` deliberately leaves
    /// `series` alone, so the last number that happened to land can sit there for good), and there is
    /// no answer at all (`Series` answers `nan`, which must not be read as a minimum of zero).
    public func linkVerdict() -> LinkVerdict {
        guard isMeasuring, misses == 0 else { return .unknown }
        return LinkVerdict.classify(minMs: series.min, p50Ms: p50Ms, count: series.count)
    }

    /// Should a probe be written now? A query only: pair it with `sent(at:)` once the bytes are out,
    /// so a probe that could not be written (a frame batch was open) is retried next tick.
    public func due(at now: Double) -> Bool {
        guard !unavailable, pendingSince == nil else { return false }
        return now - lastSentAt >= interval
    }

    /// Record that the probe actually went out.
    public mutating func sent(at now: Double) {
        pendingSince = now
        lastSentAt = now
        sent += 1
    }

    /// Feed the terminal's answer. Returns the round trip in ms, or `nil` for an answer with nothing
    /// outstanding (a stray report from a previous probe, or a terminal echoing one back late).
    public mutating func reply(at now: Double) -> Double? {
        guard let since = pendingSince else { return nil }
        pendingSince = nil
        misses = 0
        answered += 1
        let ms = max(0, (now - since) * 1000)
        series.add(ms)
        return ms
    }

    /// Called every tick: `true` when the outstanding probe has just been given up on, and `true`
    /// again once per later tick only if it became unavailable (see `unavailable`).
    @discardableResult
    public mutating func expire(at now: Double) -> Bool {
        guard let since = pendingSince, now - since > timeout else { return false }
        pendingSince = nil
        misses += 1
        if misses >= missesBeforeOff { unavailable = true }
        return true
    }

    /// Lower the probe rate in the cheap rungs: a probe is 4 bytes, but it is also a wake-up for the
    /// far end, and there is no point asking more often than the picture arrives.
    public mutating func setInterval(_ seconds: Double) {
        interval = max(0.5, seconds)
    }
}
