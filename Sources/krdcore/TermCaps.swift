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
///     CSI 16 t              one cell, in pixels
///     CSI 14 t              the text area, in pixels
///     CSI ? 2027 $ p        DECRQM: the grapheme-clustering mode
///     CSI ? 2031 $ p        DECRQM: the colour-scheme-follow mode
///     OSC 10 ; ? ST         the terminal's foreground colour
///     OSC 11 ; ? ST         the terminal's background colour
///     CSI c                 DA1 — identity, and the batch's terminator
///
/// The two colour questions belong in the *same* write for the reason the batch exists at all
/// (issue #213): a second round trip is another 20–40 ms of an empty alternate screen on ssh, and it
/// would have to happen before the first frame — the palette is what the wall and the chrome are
/// drawn with. A terminal that answers no `OSC` costs nothing extra for being asked: the `DA1` is
/// still last and still ends the read, so the silent case pays one round trip, not two. The answers
/// themselves are `OSC`s, which is why they can neither collide with a `CSI` nor be mistaken for the
/// terminator (`containsPrimaryAttributes` only ever looks at `CSI ? … c`).
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
    /// `OSC 10`'s answer: the terminal's own foreground colour, or `nil` when it did not answer (or
    /// answered something that is not a colour).
    ///
    /// Never a zero and never a default: `RGB(0,0,0)` is a *black* foreground, and a terminal that
    /// said nothing would be handed a palette built from a colour nobody chose — every cell of the
    /// pane then drawn in the wrong one.
    public var foreground: RGB?
    /// `OSC 11`'s answer: the terminal's own background colour, or `nil`. Same rule as `foreground`.
    public var background: RGB?
    /// `DECRQM ? 2031`'s `Ps`, in the same 0…4 vocabulary as `graphemeMode`: the mode that makes the
    /// terminal *report* the colour scheme (`CSI ? 997 ; N n`, issue #212) and follow it.
    /// `nil` when the terminal said nothing about 2031 — not "reset", and not "unsupported" either
    /// (a terminal whose parser is older than `DECRQM` cannot say which).
    public var colourSchemeMode: Int?
    /// Did the `DA1` that ends the batch arrive? `false` means the read stopped on its timeout
    /// mid-answer: the fields above are then whatever was there before the deadline, never invented.
    public var terminated: Bool

    public init(cell: Size? = nil, window: Size? = nil, graphemeMode: Int? = nil,
                foreground: RGB? = nil, background: RGB? = nil, colourSchemeMode: Int? = nil,
                terminated: Bool = false) {
        self.cell = cell
        self.window = window
        self.graphemeMode = graphemeMode
        self.foreground = foreground
        self.background = background
        self.colourSchemeMode = colourSchemeMode
        self.terminated = terminated
    }

    /// Nothing came back at all — not even the `DA1`.
    public static let none = TermCaps()

    /// Nothing is known: what a terminal that answered **only** the `DA1` reports.
    ///
    /// Optional fields rather than zeros, because `0x0` is not an answer: a caller that read it as one
    /// would draw a picture zero cells wide — or paint the pane black because "the background is
    /// `#000000`". `isEmpty` is what makes "no answer" sayable — and it is what a silent terminal and
    /// a `DA1`-only one have in common.
    public var isEmpty: Bool {
        cell == nil && window == nil && graphemeMode == nil
            && foreground == nil && background == nil && colourSchemeMode == nil
    }

    /// May a session turn `DECSET 2031` on for its own duration?
    ///
    /// True only when `DECRQM` said the mode is *recognised and not permanently reset* — `Ps` 1, 2 or
    /// 3: set now, reset now, or permanently set. `4` is a terminal saying "never", `0` is a DECTCEM
    /// style "never heard of it", and `nil` (silence) is false for the same reason: a terminal that
    /// did not answer the question would ignore `?2031h` too, and writing a mode nobody understands
    /// into an empty alternate screen is a mode nobody gives back.
    public var supportsColourSchemeFollow: Bool {
        guard let mode = colourSchemeMode else { return false }
        return (1...3).contains(mode)
    }

    /// The interface palette, when **both** colours were answered; `nil` otherwise.
    ///
    /// Both-or-nothing on purpose: `Palette` is an interpolation *between* the two colours, so one
    /// colour is not a palette, and inventing the other end would put a wrong colour on every cell of
    /// the pane. `nil` is the documented degrade — today's hard-coded SGR table, byte for byte (issue
    /// #213's D4), which is also why this is derived rather than stored: it cannot drift from the two
    /// answers it is made of.
    public var palette: Palette? {
        guard let foreground, let background else { return nil }
        return Palette(foreground: foreground, background: background)
    }

    /// The batch, exactly as it goes on the wire.
    ///
    /// One string, because the whole point is that it is **one** `write(2)`: separate writes with a
    /// wait between them cost a round trip each, and on a link that is 20–40 ms of an empty alternate
    /// screen apiece. Every question is a distinct introducer (`CSI 16t`, `CSI 14t`, `CSI ?2027$p`,
    /// `CSI ?2031$p`, `OSC 10;?`, `OSC 11;?`) and the `DA1` is last, so the read loop has one
    /// terminator instead of one condition per question.
    ///
    /// The two `OSC`s are terminated with `ST` (`ESC \`) rather than `BEL`: `ST` is the form every
    /// terminal that parses `OSC` at all accepts, while `BEL` is the shortcut only the xterm family
    /// implements — and an answer whose terminator a terminal does not know is an answer that
    /// swallows the questions behind it.
    public static let query = "\u{1B}[16t\u{1B}[14t\u{1B}[?2027$p\u{1B}[?2031$p"
        + "\u{1B}]10;?\u{1B}\\\u{1B}]11;?\u{1B}\\" + "\u{1B}[c"

    /// Everything the terminal answered, out of one reply.
    ///
    /// A pure scan of the accumulated string, so the order the answers arrive in cannot matter and a
    /// reply that was assembled out of several reads parses exactly like one that arrived whole.
    public static func parse(_ reply: String?) -> TermCaps {
        guard let reply, !reply.isEmpty else { return .none }
        return TermCaps(cell: size(reply, code: 6),
                        window: size(reply, code: 4),
                        graphemeMode: decrqmVerdict(reply, mode: 2027),
                        foreground: oscColour(reply, code: 10),
                        background: oscColour(reply, code: 11),
                        colourSchemeMode: decrqmVerdict(reply, mode: 2031),
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

    /// What a `DECRQM <mode>` answer means: its `Ps` (`0`…`4`), or `nil` when the terminal said
    /// nothing about that mode.
    ///
    /// One reader for both modes the batch asks about (`2027` grapheme clustering, `2031` colour
    /// scheme), because "is this report for *my* mode" is the part with a wrong answer available: a
    /// `?2031;1$y` sitting next to a `?2027;2$y` in the same buffer must not be read as 2027's
    /// verdict, and a `?2027;2$` whose `y` has not arrived yet is not a verdict at all.
    public static func decrqmVerdict(_ reply: String?, mode: Int) -> Int? {
        guard let reply, let start = reply.range(of: "\u{1B}[?\(mode);") else { return nil }
        let rest = reply[start.upperBound...]
        guard let end = rest.firstIndex(of: "$") else { return nil }
        let digits = rest[..<end]
        // `DECRQM` answers `Ps $ y`; the `$y` has to be there or this was some other report that
        // happens to start the same way, and a wrong number is worse than no number.
        guard rest[end...].hasPrefix("$y") else { return nil }
        guard let value = Int(digits), (0...4).contains(value) else { return nil }
        return value
    }

    /// What a `DECRQM 2027` answer means: the mode number (`0`…`4`), or `nil` when the terminal said
    /// nothing about 2027.
    ///
    /// `?2027;1$y` (set), `?2027;2$y` (reset), `?2027;0$y` (not recognised), `DA1` alone (no `DECRQM`
    /// support at all) and a reply split across reads all have to land on the same answer, so this is
    /// split out from the probe and tested without a terminal.
    public static func graphemeModeVerdict(_ reply: String?) -> Int? {
        decrqmVerdict(reply, mode: 2027)
    }

    /// An `OSC 10` (foreground) / `OSC 11` (background) answer out of the accumulated reply, or `nil`.
    ///
    /// The shape is `ESC ] <code> ; <body> (BEL | ST)`, and both terminators are in the wild: xterm
    /// and Ghostty answer with `ST` (`ESC \`), Rex with `BEL`. An answer whose terminator has not
    /// arrived is `nil` rather than a guess — the body may still be growing, exactly like a truncated
    /// `CSI 14 t` — and so is a body `RGB.parse` refuses. What is left is the answer, and "no answer"
    /// is what keeps a palette from being invented out of half a colour.
    private static func oscColour(_ text: String, code: Int) -> RGB? {
        guard let start = text.range(of: "\u{1B}]\(code);") else { return nil }
        let rest = text[start.upperBound...]
        let bel = rest.firstIndex(of: "\u{07}")
        let st = rest.range(of: "\u{1B}\\")?.lowerBound
        guard let end = [bel, st].compactMap({ $0 }).min() else { return nil }
        return RGB.parse(String(rest[..<end]))
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
