/// Which of the frames the capture delivers may draw, once `--quality auto` has taken the frame
/// rate down a rung (issue #140).
///
/// The capture keeps arriving at `--fps` -- reconfiguring ScreenCaptureKit mid-stream to save
/// frames is not worth the teardown -- so a rung below the capture rate is enforced by declining
/// frames here, before anything is encoded. The only question is *which* frames, and the naive
/// answer silently deletes a rung: "has a whole period passed since the last frame I drew?" accepts
/// every `ceil(due / capturePeriod)`-th frame, so the delivered period is a **multiple of the
/// capture period** and can never be `due`. A 20 fps capture (50 ms) asked for the 15 fps rung
/// (66.67 ms) draws every second frame -- 100 ms, i.e. **10 fps**, exactly the rung below it. The
/// governor then measures a link that is still behind, steps past the rung it never got, and
/// ping-pongs between 15 and 10 for the rest of the session.
///
/// So the gate carries an **owed-frame deadline** instead of a last-draw mark: the deadline moves
/// one whole period per frame that draws, and the frame that arrives on or after it is the one that
/// draws. From a 20 fps capture at the 15 fps rung that is `draw, drop, draw, draw, drop, ...`, and
/// the *mean* delivered rate is the rung -- which is what a frame rate means. A rung is a target,
/// not a floor: every rung other than "as fast as the capture" is delivered by declining frames, so
/// an interval of 66.67 ms out of a source that only ticks every 50 ms is sometimes 50 and sometimes
/// 100. `--stats` (and the `--dev` bar) print the delivered number next to the target for exactly
/// this reason: `15.0/15 fps` is the honest reading, a target with no delivered number would not be.
///
/// Two guards, both about keeping it from getting worse:
/// - A frame that arrives up to `toleranceMs` early still draws (that is timer jitter, not a rate
///   decision -- the old gate had the same millisecond of slack). The deadline still advances a
///   whole period, so the tolerance cannot accumulate into a faster-than-rung stream.
/// - A gate more than one period behind -- a stall, a resize, a rung change, the first frame -- pulls
///   the deadline back to now first, so a deficit is never paid back as a burst of frames
///   (`nextDue = now; nextDue += due`, the shape in issue #140).
public struct FrameGate: Equatable {
    /// The interval the rung asks for, in milliseconds (`1000 / fps`).
    public let periodMs: Double
    /// How early a frame may arrive and still count as due. Jitter, not rate.
    public let toleranceMs: Double
    /// When the next frame is owed, in the same clock the caller passes to `owesFrame`/`tookFrame`.
    /// `-infinity` until a frame has drawn for the first time, which owes every frame.
    public private(set) var dueAt = -Double.infinity

    public init(fps: Int, toleranceMs: Double = 1.0) {
        periodMs = 1000.0 / Double(max(fps, 1))
        self.toleranceMs = toleranceMs
    }

    /// Whether the frame that arrived at `now` (ms) may draw.
    ///
    /// Deliberately does not advance anything: the caller commits with `tookFrame` only once the
    /// frame is known to change the picture, so a frame that draws nothing does not spend the rung's
    /// slot (#95).
    public func owesFrame(at now: Double) -> Bool { now + toleranceMs >= dueAt }

    /// Record that the frame which arrived at `now` drew, and owe the next one a period later.
    public mutating func tookFrame(at now: Double) {
        if now - dueAt > periodMs { dueAt = now }
        dueAt += periodMs
    }

    /// Re-arm for a new rung: the next frame draws, and the deadline carries on from there.
    public mutating func rearm() { dueAt = -Double.infinity }
}
