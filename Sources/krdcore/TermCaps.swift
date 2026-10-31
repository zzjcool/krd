import Foundation
import Darwin

/// What the terminal answered when krd asked which capabilities it has — **one write, one round trip**
/// (issue #197).
///
/// The questions used to leave as separate probes with a wait each: `CSI 16 t` + `CSI 14 t` for the
/// cell and the text area, then `DECRQM ? 2027` for grapheme clustering. Over ssh every *wait* is a
/// round trip, and OpenSSH's keystroke obfuscation puts every reply on a ~20 ms grid (measured p50
/// 23.5 ms; twenty questions one by one 488 ms, twenty in one write 17.7 ms —
/// `docs/design-ui-v2.zh-CN.md` §2.2). So they leave together, in one `write(2)`:
///
///     CSI 16 t          one cell, in pixels
///     CSI 14 t          the text area, in pixels
///     CSI ? 2027 $ p    DECRQM: the grapheme-clustering mode
///     CSI c             DA1 — identity, and the batch's terminator
///
/// **`DA1` terminates the read because it is the one question nothing can ignore.** A terminal that
/// does not implement `DECRQM` answers *nothing* to it, so without a sentinel the read waits out its
/// whole timeout exactly where there was nothing to learn — measured on the code before this: the
/// `DA1`-only case paid 517 ms of timeout before the next probe could start
/// (`ProbeBatchTests.testDA1EndsTheReadWithoutWaitingOutTheTimeout`).
///
/// The kitty `U=1` placeholder probe does not join the batch: its answer is an APC (`ESC _ G
/// i=31;OK ESC \`), not a `CSI`, and its *refusal is silence*, so it needs a timeout of its own. It is
/// already asked once per process (`TermGeometry.supportsPlaceholders`, issue #99/#183).
///
/// The parse is pure and total — no terminal, no clock — so `TermCapsTests` drives it with the replies
/// real terminals send, including a reply split across reads and one that carries only the `DA1`.
public struct TermCaps: Equatable {
    /// A pixel size a terminal reported: one cell (`CSI 16 t`) or the whole text area (`CSI 14 t`).
    public struct Size: Equatable {
        public var w: Int
        public var h: Int

        public init(w: Int, h: Int) {
            self.w = w
            self.h = h
        }
    }

    /// `CSI 16 t`: one cell, in whatever this terminal calls a pixel (Rex answers points).
    public var cell: Size?
    /// `CSI 14 t`: the text area.
    public var window: Size?
    /// `DECRQM ? 2027`'s `Ps`: 1 set, 2 reset, 3 permanently set, 4 permanently reset, 0 not recognised.
    /// `nil` when the terminal said nothing about the mode — which is not the same as "reset".
    public var graphemeMode: Int?
    /// Did the `DA1` that ends the batch arrive? `false` means the read stopped on its timeout
    /// mid-answer: the fields above are then whatever was there before the deadline, never invented.
    public var terminated: Bool

    public init(cell: Size? = nil, window: Size? = nil, graphemeMode: Int? = nil,
                terminated: Bool = false) {
        self.cell = cell
        self.window = window
        self.graphemeMode = graphemeMode
        self.terminated = terminated
    }

    /// Nothing came back at all — not even the `DA1`.
    public static let none = TermCaps()

    /// Nothing is known: what a terminal that answered **only** the `DA1` reports.
    ///
    /// Optional fields rather than zeros, because `0x0` is not an answer: a caller that read it as one
    /// would draw a picture zero cells wide. `isEmpty` is what makes "no answer" sayable — and it is
    /// what a silent terminal and a `DA1`-only one have in common.
    public var isEmpty: Bool { cell == nil && window == nil && graphemeMode == nil }

    /// The batch, exactly as it goes on the wire.
    ///
    /// One string, because the whole point is that it is **one** `write(2)`: three writes with a wait
    /// between them cost three round trips, and on a link that is 3 × 20–40 ms of an empty alternate
    /// screen. Every question is a distinct `CSI` prefix and the `DA1` is last, so the read loop has
    /// one terminator instead of one condition per question.
    public static let query = "\u{1B}[16t\u{1B}[14t\u{1B}[?2027$p\u{1B}[c"

    /// Everything the terminal answered, out of one reply.
    public static func parse(_ reply: String?) -> TermCaps {
        guard let reply, !reply.isEmpty else { return .none }
        return TermCaps(cell: size(reply, code: 6),
                        window: size(reply, code: 4),
                        graphemeMode: graphemeModeVerdict(reply),
                        terminated: containsPrimaryAttributes(reply))
    }

    /// Is the batch finished? True once the `DA1` answer is in — the `DA1` is the last question asked,
    /// so its answer means every other answer has either arrived or never will.
    public static func isComplete(_ reply: String) -> Bool { containsPrimaryAttributes(reply) }

    /// Does this reply carry a `DA1` answer (`CSI ? … c`)?
    ///
    /// The sentinel every startup probe ends on, so a batched query has one terminator instead of one
    /// per question. Scanner rather than `contains("\u{1B}[?…c")`: the parameters are a `;`-list that
    /// differs per terminal (`?62c`, `?62;22c`, `?62;22;52c`), and a naive search for `c` would accept
    /// a truncated reply — `ESC [ ? 6 2` followed by the next answer's `c`.
    public static func containsPrimaryAttributes(_ text: String) -> Bool {
        var index = text.startIndex
        while let start = text.range(of: "\u{1B}[", range: index..<text.endIndex) {
            var cursor = start.upperBound
            guard cursor < text.endIndex, text[cursor] == "?" else {
                index = start.upperBound
                continue
            }
            cursor = text.index(after: cursor)
            var digits = false
            while cursor < text.endIndex, text[cursor].isNumber || text[cursor] == ";" {
                if text[cursor].isNumber { digits = true }
                cursor = text.index(after: cursor)
            }
            if digits, cursor < text.endIndex, text[cursor] == "c" { return true }
            index = start.upperBound
        }
        return false
    }

    /// What a `DECRQM 2027` answer means: the mode number (`0`…`4`), or `nil` when the terminal said
    /// nothing about 2027.
    ///
    /// `?2027;1$y` (set), `?2027;2$y` (reset), `?2027;0$y` (not recognised), `DA1` alone (no `DECRQM`
    /// support at all) and a reply split across reads all have to land on the same answer, so this is
    /// split out from the probe and tested without a terminal.
    public static func graphemeModeVerdict(_ reply: String?) -> Int? {
        guard let reply, let start = reply.range(of: "\u{1B}[?2027;") else { return nil }
        let rest = reply[start.upperBound...]
        guard let end = rest.firstIndex(of: "$") else { return nil }
        let digits = rest[..<end]
        // `DECRQM` answers `Ps $ y`; the `$y` has to be there or this was some other report that
        // happens to start the same way, and a wrong number is worse than no number.
        guard rest[end...].hasPrefix("$y") else { return nil }
        guard let value = Int(digits), (0...4).contains(value) else { return nil }
        return value
    }

    /// Write the batch and read until the `DA1` — the one probe (issue #197).
    ///
    /// Returns `.none` when there is no terminal to ask: `ask` fails on a stdin that is not a tty
    /// *before* writing a byte, so a pipe (`krd --wall > file`, `ssh` without `-t`) is asked nothing.
    /// The paths that own stdout and read no input — `--bench`, `--selftest`, `--list` — never call this
    /// in the first place.
    public static func probe(timeoutMs: Int = 500) -> TermCaps {
        parse(ask(query, timeoutMs: timeoutMs, until: isComplete))
    }

    /// Write `bytes` to the terminal and collect what comes back for up to `timeoutMs`, with stdin in
    /// raw non-blocking mode. `nil` when nothing came back.
    ///
    /// The one raw-mode read loop: only used before input starts (a probe steals whatever it reads, so
    /// it must not run while the mouse is live). `probe` is one caller; the `U=1` placeholder probe in
    /// `TermGeometry` is the other, because it cannot be batched and needs its own timeout.
    ///
    /// The bytes leave through the same sink as everything else (issue #107): one write loop, and
    /// `GraphicsAPC.writeRaw` asserts its envelope there rather than trusting each call site.
    public static func ask(_ bytes: String, timeoutMs: Int, until: (String) -> Bool) -> String? {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        // c_cc[0]/[1] are VEOF/VEOL on macOS, not VMIN/VTIME: name them, or the fd keeps blocking.
        withUnsafeMutableBytes(of: &raw.c_cc) { p in
            p[Int(VMIN)] = 0
            p[Int(VTIME)] = 0
        }
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return nil }
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
        GraphicsAPC.writeRaw(bytes)
        var response = ""
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var buffer = [UInt8](repeating: 0, count: 256)
        while Date() < deadline, !until(response) {
            var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1000))
            guard poll(&pfd, 1, remaining) > 0 else { continue }
            let n = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if n > 0 { response += String(decoding: buffer[0..<n], as: UTF8.self) }
        }
        return response.isEmpty ? nil : response
    }

    /// `CSI <code> ; <height> ; <width> t` — one of the two size answers.
    ///
    /// A sequence only counts once its terminating `t` has arrived, which is also what makes a
    /// truncated `ESC [ 14;600;800` harmless: those numbers may still be growing.
    private static func size(_ text: String, code: Int) -> Size? {
        let pattern = "\u{1B}[\(code);"
        guard let start = text.range(of: pattern) else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: "t") else { return nil }
        let parts = rest[..<end].split(separator: ";")
        guard parts.count == 2, let h = Int(parts[0]), let w = Int(parts[1]), h > 0, w > 0 else {
            return nil
        }
        return Size(w: w, h: h)
    }
}
