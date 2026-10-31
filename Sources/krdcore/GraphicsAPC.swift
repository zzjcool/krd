import Foundation

/// The one place a kitty-graphics APC becomes bytes (issue #107).
///
/// The envelope is only worth anything if it cannot be walked around. It could: `Writer` wrapped
/// the APCs *it* emitted, while the geometry probe (`Sources/krd/Geometry.swift` — the `a=t` that
/// decides a cell's size, its `U=1` placement, and the `a=d` that removes the probe image) and the
/// `KRD_DELTEST` debug delete (`Sources/krd/main.swift`) each wrote their own bytes straight to
/// fd 1. Inside tmux those four stayed raw and were eaten by the multiplexer, so the one question
/// this feature exists to make answerable — "how big is a cell in this pane?" — was the one
/// question tmux never saw asked.
///
/// So the decision is *ambient*, not per-call-site: `passthrough` is set once from
/// `TmuxPassthrough.resolve` before anything is written, and `open`/`close`/`sequence`/`write` are
/// the only way a graphics escape is built. Every emitter goes through them — the nine `appendAPC`
/// sites in `Render`, the probe's two, and the debug delete — because there is no other constructor.
///
/// Two guards keep it that way without a grep:
/// - `isFullyEnveloped` is a real parser (§below), and `Writer.flushLocked` *and* `writeRaw`
///   assert it whenever `passthrough` is on. A future path that hand-rolls an APC fails the
///   assertions in every debug run that emits one.
/// - `TmuxPassthroughTests` runs the same predicate over a captured stream and over the probe's
///   own payloads, so "somebody added a tenth call site" is a test failure, not a screenshot.
public enum GraphicsAPC {
    /// Set once, at startup, from `TmuxPassthrough.resolve`. Ambience rather than a parameter
    /// because the probe runs before `Writer` exists and must not be able to disagree with it.
    public static var passthrough: Bool {
        get { state.lock.lock(); defer { state.lock.unlock() }; return state.on }
        set { state.lock.lock(); defer { state.lock.unlock() }; state.on = newValue }
    }

    private final class State {
        let lock = NSLock()
        var on = false
    }
    private static let state = State()

    /// `ESC _` — or, with passthrough on, `ESC Ptmux;` plus the introducer's already-doubled `ESC`.
    /// Split from `close` so a transmit's base64 payload can go straight into the frame buffer
    /// instead of being copied through a `String` (see `Writer.appendTransmitChunk`).
    public static var open: String {
        passthrough ? TmuxPassthrough.open : "\u{1B}_"
    }

    /// `ESC \` — or the doubled `ESC ESC \` and the envelope's own ST.
    public static var close: String {
        passthrough ? TmuxPassthrough.close : "\u{1B}\\"
    }

    /// One complete graphics APC: `ESC _ G<body> ESC \`, enveloped when passthrough is on.
    ///
    /// Every body krd emits is ESC-free (a control list, and for a transmit base64), so the
    /// envelope is the open/close pair and nothing else — it never re-encodes a payload.
    public static func sequence(_ body: String) -> String {
        open + body + close
    }

    /// `sequence(_:)` and the synchronous unbuffered write the pre-`Writer` probes need: raw stdin
    /// mode, no batch buffer, no return path. One byte loop for the probe path so the envelope and
    /// the write cannot drift apart.
    public static func write(_ body: String) {
        writeRaw(sequence(body))
    }

    /// The synchronous write itself. Used by `TermGeometry.ask` for every byte a probe sends —
    /// graphics APC or CSI query — so there is a single place where pre-`Writer` output leaves krd.
    public static func writeRaw(_ text: String) {
        let bytes = Array(text.utf8)
        assert(passthrough ? isFullyEnveloped(bytes) : true,
               "krd: a graphics APC left the probe path without its tmux envelope: "
               + escapedPreview(bytes))
        bytes.withUnsafeBufferPointer { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(STDOUT_FILENO, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    // MARK: - the guard

    /// Would tmux forward every graphics APC in this stream to the terminal behind it?
    ///
    /// A byte-level parser of the two envelope rules `TmuxPassthrough` documents, i.e. the same
    /// walk tmux's own `input_state_dcs_escape` does: outside an envelope an `ESC _` is an APC
    /// tmux will consume itself (fail); inside one, a *lone* `ESC` is a payload byte tmux reads as
    /// it likes (fail, because the envelope's end is then ambiguous); a doubled `ESC` is a payload
    /// `ESC` (fine); `ESC \` closes the envelope (fine). An envelope still open at the end of the
    /// stream is also a fail — it would swallow whatever comes next.
    ///
    /// Deliberately not a regex over `ESC _`: the point is to catch a bypass anywhere in a stream,
    /// including one spliced between envelopes, and to catch an envelope that half-closes.
    public static func isFullyEnveloped(_ stream: [UInt8]) -> Bool {
        let prefix = Array(TmuxPassthrough.prefix.utf8)      // ESC P t m u x ;
        let terminator = Array(TmuxPassthrough.terminator.utf8)   // ESC \
        var i = 0
        var inside = false
        while i < stream.count {
            let byte = stream[i]
            if !inside {
                if matches(stream, at: i, prefix) {
                    inside = true
                    i += prefix.count
                    continue
                }
                if byte == 0x1B, i + 1 < stream.count, stream[i + 1] == 0x5F { return false }  // raw APC
                i += 1
            } else {
                if matches(stream, at: i, terminator) {
                    inside = false
                    i += terminator.count
                    continue
                }
                if byte == 0x1B {
                    if i + 1 < stream.count, stream[i + 1] == 0x1B { i += 2; continue }  // doubled: fine
                    return false                                                          // lone ESC
                }
                i += 1
            }
        }
        return !inside
    }

    private static func matches(_ bytes: [UInt8], at index: Int, _ needle: [UInt8]) -> Bool {
        guard index + needle.count <= bytes.count else { return false }
        for k in 0..<needle.count where bytes[index + k] != needle[k] { return false }
        return true
    }

    /// A short, ESC-visible rendering for an assertion message (no raw escapes in the log).
    private static func escapedPreview(_ bytes: [UInt8], limit: Int = 96) -> String {
        bytes.prefix(limit).map { byte -> String in
            switch byte {
            case 0x1B: return "\\e"
            case 0x20..<0x7F: return String(UnicodeScalar(byte))
            default: return String(format: "\\x%02x", byte)
            }
        }.joined()
    }
}
