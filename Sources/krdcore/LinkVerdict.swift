/// What the terminal's own round trip says about the link, as a **symptom** rather than a number
/// (issue #199).
///
/// A slow ssh session has two very different causes, and on screen they look identical:
///
/// 1. **the link is behind** — real congestion, and the quality ladder's job (#187, #189);
/// 2. **the link is fine and every keystroke is held anyway**, because OpenSSH 10's
///    `ObscureKeystrokeTiming` batches the terminal's own replies (keys, mouse reports, `CSI 0n`
///    answers) onto an 18-22 ms grid.
///
/// The second is fixed by one line in `~/.ssh/config`, and nothing in krd used to say so. Measured on
/// a lossless ssh connection (`probe/termcaps.py`, `docs/design-ui-v2` §2.2): p50 round trip **23.5 ms**
/// with obfuscation on, **0.59 ms** with `ObscureKeystrokeTiming no` — and the *minimum* stays
/// **0.71 ms** in both cases.
///
/// So the signature is the minimum, and the minimum is what keeps this from misfiring on a link that
/// really is slow:
///
/// | verdict   | condition                                    | what it means                                  |
/// |-----------|----------------------------------------------|------------------------------------------------|
/// | `held`    | min < 2 ms ∧ p50 ≥ 15 ms ∧ ≥ 8 answers        | the wire is fast; the keystrokes are held      |
/// | `slow`    | min ≥ 2 ms ∧ p50 ≥ 15 ms ∧ ≥ 8 answers        | the wire itself is behind — congestion         |
/// | `fine`    | p50 < 15 ms                                  | measured, nothing to say                       |
/// | `unknown` | no answer, too few answers, or the probe is off | nothing to say — the rest state               |
///
/// Both thresholds come from those measurements with a factor of ~2 of slack, and they are frozen by
/// the issue: `min` under 2 ms is "no packet was ever waiting", `p50` over 15 ms is "the median is
/// late anyway", and eight answers is what keeps the pill from blinking on the first second.
///
/// Freshness is not decided here. It cannot be: a series of numbers cannot say whether its newest
/// sample is still a measurement, which is `RTTProbe.linkVerdict()`'s guard — the same "no answer to
/// the outstanding probe" condition #187 put in front of `isLate`.
public enum LinkVerdict: String, Equatable, CaseIterable, Sendable {
    /// Nothing measured: the probe is off, the terminal does not answer `CSI 5n`, the outstanding
    /// probe expired, or there are fewer than `minAnswers` answers.
    case unknown
    /// Measured, and the median is not late. Nothing to say.
    case fine
    /// The link is fast and the keystrokes are held anyway: `ObscureKeystrokeTiming`.
    case held
    /// The minimum climbed too: this is congestion, and the quality ladder owns it.
    case slow

    /// `min` under this means no packet was ever waiting — the wire itself is fast.
    public static let heldMinMs = 2.0
    /// `p50` at or over this means the median round trip is late.
    public static let heldP50Ms = 15.0
    /// Answers before the rule may speak at all, so the pill does not blink on the first second.
    public static let minAnswers = 8

    /// The rule. Pure arithmetic over a series' three summary numbers, so a test can state the
    /// signature without a terminal, a clock or a pty.
    public static func classify(minMs: Double, p50Ms: Double, count: Int) -> LinkVerdict {
        // A missing measurement is not a fast one: `Series` answers `nan` for an empty ring, and
        // `nan < 2` is false, which would have read as `slow`.
        guard count >= minAnswers, minMs.isFinite, p50Ms.isFinite else { return .unknown }
        guard p50Ms >= heldP50Ms else { return .fine }
        // The one comparison the whole design turns on: a congested link has a minimum that climbed,
        // because there is no moment at which nothing was queued.
        return minMs < heldMinMs ? .held : .slow
    }

    /// Whether the link is saying something a reader should be told. `fine` and `unknown` are both
    /// "nothing to say", and the visible difference between them is exactly zero on purpose: a
    /// terminal that does not implement DSR is a capability, not a symptom (#87: never print `0`).
    public var isSymptom: Bool { self == .held || self == .slow }

    /// The pill, in one string for both places it is drawn — the mirror's bar (`Chrome.drawBar`) and
    /// the wall's header row (`WallCanvas.drawHeader`) — so the two grids cannot come to say
    /// different things about one measurement. `nil` is the rest state, and it has to stay `nil` for
    /// everything but `held`: a slow link gets no pill because the ladder already reacts to it, and
    /// this pill's whole sentence is "the link is *not* slow".
    public var pill: String? { self == .held ? "[ keys held ]" : nil }

    /// One line for the panel the pill opens, naming what a reader can do about it. Empty for the two
    /// states with nothing to act on.
    public var advice: String? {
        switch self {
        case .held:
            // The setting, spelled as it appears in `~/.ssh/config`, because the fix is the sentence.
            return "ssh holds the replies: ObscureKeystrokeTiming no"
        case .slow:
            return "the minimum climbed too — congestion, not the client"
        case .fine, .unknown:
            return nil
        }
    }
}
