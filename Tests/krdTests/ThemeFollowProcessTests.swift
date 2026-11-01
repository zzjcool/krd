import XCTest
import Darwin

/// The theme follow-up (`DEC mode 2031`), seen from the other end of a pty: **one report, one
/// text-layer repaint, and the mode given back on the way out** (issue #213, decisions D5 and D6).
///
/// WHY this spawns a process: every claim below is about bytes — how many, which ones, and which ones
/// are absent. `WallCanvasPaletteTests` and `ChromeBarPaletteTests` pin what the two adopters *draw*
/// for a given palette and `PaletteTests` pins what a palette *is*; none of them can see whether the
/// terminal's report ever reached the desk, whether `?2031h` was asked for before it, or whether
/// `?2031l` went back. The fake terminal below is the smallest one that can answer the capability
/// burst (`ProbeBatchTests`' shape, plus the two `OSC`s and the `2031` verdict).
///
/// The **light** case is pty-only evidence on purpose: Rex cannot flip its own theme from a script, so
/// the real-terminal run this was designed against is the *dark* one and the light run is a fake
/// terminal answering the swapped pair. Both are the same code path (`Palette.inverted()`), which is
/// what makes asserting the light accent here an assertion about the reversal and not about a terminal.
final class ThemeFollowProcessTests: XCTestCase {
    // MARK: - 1. one report, one repaint, inside the budget

    /// A colour-scheme report repaints the text layer **once**, inside design §5.1's 8 KB theme-switch
    /// budget, and a repeat of the same report costs nothing at all.
    ///
    /// Three failures, none of which a screenshot can tell apart from success:
    ///  * the desk ignores the report — the terminal turns light, the wall stays dark. The light
    ///    palette's accent (`#3B6F9A`, i.e. `38;2;59;111;154`) is the byte that failure never emits;
    ///  * the report repaints the *picture* — re-sending a tile is 100 KB+ on a 137x44 pane and a
    ///    visible flash, which is why the window must be `> 0` **and** `<= 8192` and must carry no
    ///    APC at all (`ESC _ G`): the pictures on screen are still the right pictures;
    ///  * the terminal repeats the report (a focus change is enough) and the desk repaints every time
    ///    — the second identical report must cost **0 B** (D6), which is the "repaint once" half of
    ///    the acceptance.
    func testAColourSchemeReportRepaintsTheTextLayerOnceAndCostsUnderEightKilobytes() throws {
        let run = try spawn(["--wall", "--mock", "--demo", "--pane", "137x44"], colourSchemeMode: 1)
        defer { run.stop() }

        XCTAssertTrue(run.terminal.pump(until: {
            $0.contains(string: "\u{1B}[?2031h") && $0.contains(string: "\u{1B}[?1003h")
        }, timeoutMs: 15_000),
                      "the wall never enabled 2031 and installed its reader; \(run.terminal.describe)")
        // Let the startup settle (the first paint, the re-measure behind it, the `U=1` probe this
        // fake deliberately does not answer) before the mark: only bytes *after* it are the report's.
        run.terminal.settleFrame()

        FakeTerminal.mark("test1: started, \(run.terminal.stream.count) B before the report")
        let mark = run.terminal.stream.count
        run.terminal.send("\u{1B}[?997;2n")              // light
        FakeTerminal.mark("test1: report sent")
        run.terminal.settleFrame()
        FakeTerminal.mark("test1: first drain done, \(run.terminal.stream.count) B")

        let repaint = run.terminal.repaint(since: mark)
        XCTAssertGreaterThan(repaint.count, 0,
                             "a light report painted nothing, so the wall still draws the dark "
                             + "palette: \(run.terminal.describe)")
        XCTAssertLessThanOrEqual(repaint.count, 8192,
                                 "the repaint cost \(repaint.count) B, over §5.1's 8 KB budget for a "
                                 + "theme switch — it is no longer a text-layer repaint: "
                                 + repaint.brief)
        XCTAssertTrue(repaint.contains(string: "38;2;59;111;154"),
                      "the window does not carry the light palette's accent (#3B6F9A), so either the "
                      + "report never reached the desk or it was not re-derived: " + repaint.brief)
        XCTAssertFalse(repaint.contains(string: "\u{1B}_G"),
                       "the theme switch re-sent a picture (an APC in the repaint): a switch is the "
                       + "text layer and nothing else: " + repaint.brief)

        // The same scheme, again: a terminal is free to report it on every focus change, and the desk
        // must not spend a byte on it. Asserted against the *stream*, not against an internal flag,
        // so a repaint that happens to produce an empty diff cannot pass this.
        FakeTerminal.mark("test1: checks done, second report now")
        let second = run.terminal.stream.count
        run.terminal.send("\u{1B}[?997;2n")              // light, twice
        run.terminal.settleFrame()
        FakeTerminal.mark("test1: second drain done, \(run.terminal.stream.count) B")
        XCTAssertEqual(run.terminal.repaint(since: second).count, 0,
                       "the second identical report wrote bytes; the same scheme reported twice must "
                       + "cost 0 B (D6): " + run.terminal.repaint(since: second).brief)
    }

    // MARK: - 2. a mode nobody was asked about stays off the wire

    /// A terminal that answers `?2031;0$y` (recognised by the parser, not implemented) is **never
    /// sent** the mode — and therefore never gets the reset either — and a report it sends anyway
    /// repaints nothing.
    ///
    /// Both halves are asserted on the wire, not on `ScreenWriter.followsColourScheme`: an internal
    /// flag that is right while the bytes are wrong is exactly the bug D5 exists to prevent (a mode
    /// written into a pane that ignores it, and a `?2031l` nobody can undo). The wall still painting
    /// its header is the control: the session ran, it simply has nothing to follow.
    func testATerminalThatIsNotAskedNeverSeesTheModeOnTheWire() throws {
        let run = try spawn(["--wall", "--mock", "--demo", "--pane", "137x44"], colourSchemeMode: 0)
        defer { run.stop() }

        XCTAssertTrue(run.terminal.pump(until: { $0.contains(string: "\u{1B}[?1003h") }, timeoutMs: 15_000),
                      "the wall never installed its reader; \(run.terminal.describe)")
        run.terminal.settleFrame()

        let mark = run.terminal.stream.count
        run.terminal.send("\u{1B}[?997;2n")              // a report nobody asked for
        run.terminal.settleFrame()
        XCTAssertEqual(run.terminal.repaint(since: mark).count, 0,
                       "a report repainted this pane even though 2031 was never enabled — the desk "
                       + "acted on a mode it did not ask for (D5): "
                       + run.terminal.repaint(since: mark).brief)

        // ...and the whole session, both directions.
        let whole = run.terminal.stream
        XCTAssertFalse(whole.contains(string: "\u{1B}[?2031h"),
                       "`?2031h` reached a terminal that said it does not know the mode: "
                       + run.terminal.describe)
        XCTAssertFalse(whole.contains(string: "\u{1B}[?2031l"),
                       "`?2031l` was written for a mode this session never turned on (it is not "
                       + "idempotent on the wire, only in the flag): " + run.terminal.describe)
        // The control: the wall is on the pane. Without it, "0 bytes" would also pass on a krd that
        // painted nothing at all.
        XCTAssertTrue(whole.contains(string: "krd"), "the wall never painted its header: "
                      + run.terminal.describe)
    }

    // MARK: - 3. what was turned on is given back

    /// A terminal that *does* answer `?2031;1$y` is told `?2031h` once, when the session opens, and
    /// `?2031l` once, before the alternate screen is left.
    ///
    /// WHY the order is the assertion: `endSession` writes the resets *before* `?1049l` so the shell
    /// behind krd never inherits a mode krd turned on (the class of bug #134/#193 is exactly that
    /// inversion). And WHY "exactly one" of each: a session that turns the mode on twice, or gives it
    /// back twice, is a mode whose ownership nobody is tracking any more — `restoreColourSchemeMode`
    /// is idempotent on purpose (the two ways out, `endSession` and `handOver`, can both run).
    func testATerminalThatFollowsTheModeGetsItBackOnTheWayOut() throws {
        let run = try spawn(["--wall", "--mock", "--demo", "--pane", "137x44"], colourSchemeMode: 1)
        defer { run.stop() }

        XCTAssertTrue(run.terminal.pump(until: {
            $0.contains(string: "\u{1B}[?2031h") && $0.contains(string: "\u{1B}[?1003h")
        }, timeoutMs: 15_000),
                      "the wall never enabled 2031 and installed its reader; \(run.terminal.describe)")
        run.terminal.settleFrame()

        // `Ctrl-\` is the documented way out, and in wall mode it is the *only* one the reader owns.
        run.terminal.send("\u{1C}")
        let deadline = Date().addingTimeInterval(8)
        while run.child.isRunning, Date() < deadline { run.terminal.drain(forMs: 50) }
        XCTAssertFalse(run.child.isRunning, "the wall did not leave within 8 s of Ctrl-\\")
        run.terminal.drain(forMs: 200)
        run.child.waitUntilExit()
        XCTAssertEqual(run.child.terminationStatus, 0,
                       "the wall exited \(run.child.terminationStatus) instead of 0")

        let stream = run.terminal.stream
        XCTAssertEqual(stream.occurrences(of: "\u{1B}[?2031h"), 1,
                       "`?2031h` went out \(stream.occurrences(of: "\u{1B}[?2031h")) times, not once: "
                       + run.terminal.describe)
        XCTAssertEqual(stream.occurrences(of: "\u{1B}[?2031l"), 1,
                       "`?2031l` went out \(stream.occurrences(of: "\u{1B}[?2031l")) times, not once — "
                       + "a mode turned on once has to be given back once: " + run.terminal.describe)

        guard let enable = stream.firstRange(of: Array("\u{1B}[?2031h".utf8)),
              let disable = stream.firstRange(of: Array("\u{1B}[?2031l".utf8)),
              let enter = stream.firstRange(of: Array("\u{1B}[?1049h".utf8)),
              let leave = stream.lastRange(of: Array("\u{1B}[?1049l".utf8)) else {
            XCTFail("expected ?1049h/?1049l/?2031h/?2031l in the stream; \(run.terminal.describe)")
            return
        }
        XCTAssertLessThan(enter.lowerBound, enable.lowerBound,
                          "`?2031h` was written before the session it belongs to: no terminal "
                          + "follows a mode set on the screen that is already gone")
        XCTAssertLessThan(disable.lowerBound, leave.lowerBound,
                          "`?2031l` came after `?1049l`, so the shell behind krd inherits a mode krd "
                          + "turned on (#134's class)")
    }

    // MARK: - 4. the mirror bar, the same report

    /// The mirror's bar — the other adopter — follows the same report: one repaint, inside the same
    /// 8 KB budget, confined to the bar's row, in the *background* plane.
    ///
    /// The two things this pins that the canvas tests cannot: the bar is the only thing that changes
    /// (every cursor move in the window targets row 1, so no tile of the picture was re-sent — a
    /// theme switch that repainted the picture would move the cursor all over the pane), and the tint
    /// is on the correct half of a reversed cell. The bar is reversed end to end, so the title's
    /// *background* attribute is the glyph: the light palette's foreground `#0D1117` must therefore
    /// arrive as `48;2;13;17;23` (a `38;` there would be a dark font on a dark bar — the exact
    /// mistake `Chrome.Tint` exists to name).
    ///
    /// `--bar` is spelled out because `--mirror --mock` alone has no chrome at all (`barEnabled` is
    /// false without `--bar` or `--wall-at`), and `--unfocused-fps 0` plus an `ESC [ O` freezes the
    /// mock's picture: without that the animation writes tiles into every window and "≤ 8 KB" would
    /// be measuring the animation rather than the repaint. Neither flag is part of what is being
    /// tested — they are what makes the pane quiet enough to measure.
    func testTheMirrorBarFollowsTheSameReport() throws {
        let run = try spawn(["--mirror", "--mock", "--bar", "--pane", "100x30", "--cell", "8x20",
                             "--unfocused-fps", "0"], colourSchemeMode: 1)
        defer { run.stop() }

        XCTAssertTrue(run.terminal.pump(until: {
            $0.contains(string: "[ - ]") && $0.contains(string: "\u{1B}[?1003h")
        }, timeoutMs: 15_000),
                      "the mirror drew no bar; \(run.terminal.describe)")
        // Freeze the picture: this is a session that reports focus-out, so the mock's frames stop
        // being drawn (`--unfocused-fps 0`) and every byte after the mark is the bar's.
        run.terminal.send("\u{1B}[O")
        run.terminal.settleFrame()

        let mark = run.terminal.stream.count
        run.terminal.send("\u{1B}[?997;2n")              // light
        run.terminal.drain(forMs: 900)
        let repaint = run.terminal.repaint(since: mark)

        XCTAssertGreaterThan(repaint.count, 0,
                             "the bar did not repaint on the report: " + run.terminal.describe)
        XCTAssertLessThanOrEqual(repaint.count, 8192,
                                 "the bar's repaint cost \(repaint.count) B, over the 8 KB theme "
                                 + "budget: " + repaint.brief)
        XCTAssertTrue(repaint.contains(string: "48;2;13;17;23"),
                      "the bar's title is not the light palette's foreground in the background plane "
                      + "(#0D1117): " + repaint.brief)
        let rows = repaint.cursorRows()
        XCTAssertFalse(rows.isEmpty,
                       "the repaint carries no cursor move at all, so it did not paint cells: "
                       + repaint.brief)
        XCTAssertEqual(Set(rows), [1],
                       "the repaint moved the cursor to rows \(Set(rows).sorted()), not just the bar's "
                       + "row — a theme switch repainted cells outside the bar: " + repaint.brief)
    }

    // MARK: - the process under test

    private struct Run {
        let master: Int32
        let child: Process
        let terminal: FakeTerminal

        func stop() {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            close(master)
        }
    }

    /// `krd` behind a pty that reports **no** pixel size — the sshd pty, i.e. the pane that has to be
    /// asked (`TermCaps`). The fake terminal answers the burst, so the answers are the geometry too.
    private func spawn(_ arguments: [String], colourSchemeMode: Int?) throws -> Run {
        let binary = try krdBinary()
        let (master, slave) = try openPTY(cols: 137, rows: 44)
        let child = Process()
        child.executableURL = binary
        child.arguments = arguments
        let pane = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        child.standardInput = pane
        child.standardOutput = pane
        child.standardError = pane
        try child.run()
        close(slave)                                    // the child holds its own copy now
        return Run(master: master, child: child,
                   terminal: FakeTerminal(master: master, colourSchemeMode: colourSchemeMode))
    }

    /// The `krd` built next to the test bundle; a missing one fails loudly rather than skipping.
    private func krdBinary() throws -> URL {
        let binary = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("krd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("no krd binary at \(binary.path) — run `swift build` before `swift test`")
            throw NSError(domain: "ThemeFollowProcessTests", code: 1)
        }
        return binary
    }

    /// A pty whose `ws_xpixel`/`ws_ypixel` are **zero**: the pixel size a wall would otherwise read
    /// from `TIOCGWINSZ` is absent, so the capability batch is what fills it in — which is also the
    /// write that carries the two colour questions.
    private func openPTY(cols: Int, rows: Int) throws -> (master: Int32, slave: Int32) {
        var master: Int32 = 0
        var slave: Int32 = 0
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "openpty failed"])
        }
        var t = termios()
        if tcgetattr(slave, &t) == 0 {
            t.c_lflag &= ~UInt(ECHO | ICANON | ISIG | IEXTEN)
            t.c_iflag &= ~UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
            t.c_oflag &= ~UInt(OPOST)
            t.c_cflag |= UInt(CS8)
            withUnsafeMutableBytes(of: &t.c_cc) { p in
                p[Int(VMIN)] = 1
                p[Int(VTIME)] = 0
            }
            tcsetattr(slave, TCSANOW, &t)
        }
        return (master, slave)
    }
}

/// The other end of the pty: a terminal that answers the capability burst the way a real one does —
/// everything it was just asked, in one write (`ProbeBatchTests`' shape) — with one knob: what it
/// answers to `DECRQM ?2031`. It always reports its own colours (GitHub's dark pair, `#E6EDF3` on
/// `#0D1117`), because that pair is what makes the *light* case a statement about `Palette.inverted()`
/// rather than about a terminal. "Answers no `OSC` at all" is D4's case and is pinned where it
/// belongs: `TermCapsTests` for the parse and the `--selftest` sha256 for the bytes.
private final class FakeTerminal {
    private static let cellQuestion = "\u{1B}[16t"
    private static let windowQuestion = "\u{1B}[14t"
    private static let graphemeQuestion = "\u{1B}[?2027$p"
    private static let colourSchemeQuestion = "\u{1B}[?2031$p"
    private static let foregroundQuestion = "\u{1B}]10;?"
    private static let backgroundQuestion = "\u{1B}]11;?"
    private static let da1Question = "\u{1B}[c"

    private let master: Int32
    /// The `Ps` of `CSI ? 2031 ; Ps $ y`, or `nil` for a terminal that does not answer `DECRQM` about
    /// it at all (the `DA1` still ends krd's read).
    private let colourSchemeMode: Int?
    /// Where the bytes this terminal has not answered yet begin.
    private var answerCursor = 0

    private(set) var stream: [UInt8] = []

    init(master: Int32, colourSchemeMode: Int?) {
        self.master = master
        self.colourSchemeMode = colourSchemeMode
    }

    /// The pane as text, for a failure message that can be read.
    var describe: String {
        "\(stream.count) B, tail: " + Array(stream.suffix(400)).escaped
    }

    /// What a terminal writes into krd's stdin: a key, or one of the reports only a terminal can send.
    func send(_ text: String) { writeAll(text) }

    /// Read the pane, answering every question as it arrives, until `done` or the timeout.
    func pump(until done: ([UInt8]) -> Bool, timeoutMs: Int) -> Bool {
        if done(stream) { return true }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var chunk = [UInt8](repeating: 0, count: 8192)
        while Date() < deadline {
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 25) > 0 else {
                if done(stream) { return true }
                continue
            }
            let n = read(master, &chunk, chunk.count)
            if n <= 0 { return done(stream) }
            stream.append(contentsOf: chunk[0..<n])
            answerIfAsked()
            if done(stream) { return true }
        }
        return done(stream)
    }

    /// Read until the pane has been silent for `quietMs` — "the paint is over" decided by the wire
    /// going still instead of by a sleep that happens to be long enough on this machine.
    ///
    /// The wall is idle between its own 1 Hz `CSI 5n` link probe (4 B, and `repaint(since:)` takes
    /// those back out), so a quiet window is always reachable; the outer deadline is what keeps a
    /// pane that never goes quiet from hanging the test.
    func drainUntilQuiet(quietMs: Int = 800, timeoutMs: Int = 8_000) {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var lastGrowth = Date()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while Date() < deadline {
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 25) > 0 {
                let n = read(master, &chunk, chunk.count)
                if n <= 0 { return }
                stream.append(contentsOf: chunk[0..<n])
                answerIfAsked()
                lastGrowth = Date()
                continue
            }
            if Date().timeIntervalSince(lastGrowth) * 1000 >= Double(quietMs) { return }
        }
    }

    /// Drain until the pane has been quiet **and stayed** quiet.
    ///
    /// One quiet window is not enough on a loaded runner: the wall can pause for longer than
    /// `quietMs` in the middle of its first frame (measured on CI: the write was still going at
    /// 9.6 KB when a report was sent, and 125 KB arrived afterwards), so a window taken on a single
    /// quiet claim attributes the rest of that frame to whatever came next. The loop repeats while
    /// the stream keeps growing, bounded by an outer deadline: a pane that never settles has to fail
    /// the assertion after the window, not hang here.
    func settle(quietMs: Int = 800, timeoutMs: Int = 20_000) {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var last = -1
        while Date() < deadline, stream.count != last {
            last = stream.count
            let left = max(200, Int(deadline.timeIntervalSinceNow * 1000))
            drainUntilQuiet(quietMs: quietMs, timeoutMs: min(8_000, left))
        }
    }

    /// Drain until a **frame is finished**: the pane is quiet and no `?2026` block is left open.
    ///
    /// This is the window a byte budget needs, and it is structural rather than timed. `settle()` alone
    /// is not enough on a loaded runner: measured on CI (run 41348747078) the wall's first pictures
    /// frame was still being written after a quiet window had already been declared, so the 125 KB
    /// that arrived next was attributed to whatever the test did in between. Since #198 one frame is
    /// one block, so "quiet *and* nothing open" is exactly "a frame ended" — and it holds whatever the
    /// runner's speed is.
    ///
    /// Bounded: a pane that never closes its block fails the assertion after the window, with the
    /// open block named, instead of hanging here.
    func settleFrame(timeoutMs: Int = 25_000) {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        let open = Array("\u{1B}[?2026h".utf8)
        let close = Array("\u{1B}[?2026l".utf8)
        while Date() < deadline {
            settle(timeoutMs: min(20_000, max(400, Int(deadline.timeIntervalSinceNow * 1000))))
            func lastIndex(_ needle: [UInt8]) -> Int? {
                guard stream.count >= needle.count else { return nil }
                var found: Int?, i = 0
                while i + needle.count <= stream.count {
                    if Array(stream[i..<(i + needle.count)]) == needle { found = i }
                    i += 1
                }
                return found
            }
            let opened = lastIndex(open)
            let closed = lastIndex(close)
            let pending = opened != nil && (closed == nil || opened! > closed!)
            if !pending { return }
            drain(forMs: 100)          // a block is open: the frame is still being written
        }
    }

    /// Read for a fixed stretch of wall clock. What the mirror's window uses: its bar is redrawn once
    /// a second by the diagnostics tick (the clock, the rates), so "silent for 800 ms" is not a state
    /// a mirror is ever in — and the tick's own cells are on the bar's row, which is what the caller
    /// asserts about.
    func drain(forMs ms: Int) {
        let deadline = Date().addingTimeInterval(Double(ms) / 1000)
        var chunk = [UInt8](repeating: 0, count: 8192)
        while Date() < deadline {
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 20) > 0 else { continue }
            let n = read(master, &chunk, chunk.count)
            if n <= 0 { return }
            stream.append(contentsOf: chunk[0..<n])
            answerIfAsked()
        }
    }

    /// The bytes this window *wrote*, without the wall's own heartbeat: `CSI 5n` is the 1 Hz link
    /// probe (`Desk.wallTick`, issue #199), 4 B that an idle wall and a repainting one write alike, so
    /// counting it would make "a report costs 0 B" and "a repaint is under 8 KB" both untrue for
    /// reasons that have nothing to do with the palette.
    func repaint(since mark: Int) -> [UInt8] {
        guard mark < stream.count else { return [] }
        let probe = Array("\u{1B}[5n".utf8)
        var out: [UInt8] = []
        var i = mark
        while i < stream.count {
            if i + probe.count <= stream.count, Array(stream[i..<(i + probe.count)]) == probe {
                i += probe.count
                continue
            }
            out.append(stream[i])
            i += 1
        }
        return out
    }

    /// Is the unanswered tail a question? Then a real terminal answers it now. The short quiet window
    /// is what makes one burst one answer rather than one per pty read.
    private func answerIfAsked() {
        guard answerCursor < stream.count else { return }
        let pending = String(decoding: stream[answerCursor...], as: UTF8.self)
        let asksCapability = pending.contains(Self.cellQuestion)
            || pending.contains(Self.windowQuestion)
            || pending.contains(Self.graphemeQuestion)
            || pending.contains(Self.colourSchemeQuestion)
            || pending.contains(Self.da1Question)
        guard asksCapability else { return }

        usleep(20_000)                       // let the rest of the same write land, if the pty split it
        drainAvailable()
        let raw = String(decoding: stream[answerCursor...], as: UTF8.self)
        answerCursor = stream.count

        var reply = ""
        if raw.contains(Self.cellQuestion) { reply += "\u{1B}[6;33;17t" }          // 17x33 cell
        if raw.contains(Self.windowQuestion) { reply += "\u{1B}[4;792;1020t" }     // 1020x792 area
        if raw.contains(Self.graphemeQuestion) { reply += "\u{1B}[?2027;2$y" }     // recognised, reset
        if raw.contains(Self.colourSchemeQuestion), let mode = colourSchemeMode {
            reply += "\u{1B}[?2031;\(mode)$y"
        }
        // The colours, in the 16-bit `rgb:` form Ghostty and Rex answer with — never `#RRGGBB`, so a
        // parser that only understood the short form would land on "no answer" and this whole file
        // would pass while the feature did not work.
        if raw.contains(Self.foregroundQuestion) {
            reply += "\u{1B}]10;rgb:e6e6/eded/f3f3\u{1B}\\"
        }
        if raw.contains(Self.backgroundQuestion) {
            reply += "\u{1B}]11;rgb:0d0d/1111/1717\u{1B}\\"
        }
        // The `DA1` last, because it is what ends krd's read on every terminal that answers nothing
        // else (and this fake deliberately says nothing to the `U=1` probe: the pixel path is the one
        // a theme switch could leak a tile on).
        if raw.contains(Self.da1Question) { reply += "\u{1B}[?62;22c" }
        guard !reply.isEmpty else { return }
        writeAll(reply)
    }

    /// Everything the child has written since the last read — without waiting. Only used inside
    /// `answerIfAsked`, after the quiet window.
    private func drainAvailable() {
        var chunk = [UInt8](repeating: 0, count: 8192)
        // Bounded on purpose: this is the one loop in this file with no deadline, so a pane that
        // writes without pause (a 1 Hz probe plus a repaint, on a slow runner) would otherwise spin
        // here appending megabytes and never give the test a chance to fail. 512 chunks is 4 MB in
        // one answer window — far more than a burst, far less than a hang.
        for _ in 0..<512 {
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 0) > 0 else { return }
            let n = read(master, &chunk, chunk.count)
            if n <= 0 { return }
            stream.append(contentsOf: chunk[0..<n])
        }
    }

    /// One line to `stderr`, unbuffered, for the runner that has to say *where* a silent test died.
    /// `print` goes through a buffer the CI log only flushes at exit, which is exactly the case this
    /// exists for: a test that never reaches its own assertions shows nothing at all.
    static func mark(_ what: String) {
        FileHandle.standardError.write(Data("krd-test: \(what)\n".utf8))
    }

    private func writeAll(_ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buf in
            var off = 0
            while off < buf.count {
                let n = write(master, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }
}

private extension Array where Element == UInt8 {
    /// Does the stream carry this byte run?
    func contains(string: String) -> Bool {
        firstIndex(of: Array(string.utf8)) != nil
    }

    /// The index of the first occurrence of `needle`, or `nil`.
    private func firstIndex(of needle: [UInt8]) -> Int? {
        guard !needle.isEmpty, needle.count <= count else { return nil }
        for start in 0...(count - needle.count) where Array(self[start..<(start + needle.count)]) == needle {
            return start
        }
        return nil
    }

    /// Bytes in a form a failure message can be read in: escapes spelled out, so "the repaint carried
    /// an APC" is visible in the test output.
    var escaped: String {
        var out = ""
        for byte in self {
            switch byte {
            case 0x1B: out += "\\e"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            default:
                // Printable ASCII as itself, everything else as a hex byte: a tile payload is binary
                // and printing it raw would bury the assertion it belongs to.
                out += (0x20...0x7E).contains(byte)
                    ? String(UnicodeScalar(byte))
                    : String(format: "\\x%02x", byte)
            }
        }
        return out
    }

    /// The first 480 B of `escaped`, then a count of what is left. A failure message is read inside a
    /// CI log, and a 125 KB line is not read at all — GitHub drops it, which turns a failed assertion
    /// into a silent one. The number is kept because that is what a budget test is about.
    var brief: String {
        let limit = 480
        let head = Array(prefix(limit)).escaped
        return count <= limit ? head : head + " … +\(count - limit) B"
    }

    /// Non-overlapping occurrences of a byte run.
    func occurrences(of string: String) -> Int {
        let needle = Array(string.utf8)
        guard !needle.isEmpty else { return 0 }
        var found = 0
        var i = 0
        while i + needle.count <= count {
            if Array(self[i..<(i + needle.count)]) == needle {
                found += 1
                i += needle.count
            } else {
                i += 1
            }
        }
        return found
    }

    /// Every `ESC [ <row> ; <col> H` in the stream, 1-based rows — the cells a repaint touched.
    ///
    /// Parsed here rather than with a regex: the escapes are simpler than the literal syntax, and this
    /// is what makes "confined to the bar's row" a measurement instead of a claim.
    func cursorRows() -> [Int] {
        let open: [UInt8] = [0x1B, 0x5B]
        var rows: [Int] = []
        var i = 0
        while i + open.count <= count {
            guard Array(self[i..<(i + open.count)]) == open else { i += 1; continue }
            var j = i + open.count
            var digits = ""
            var end: Int?
            while j < count {
                let b = self[j]
                if b == UInt8(ascii: "H") { end = j; break }
                if (b >= 0x30 && b <= 0x39) || b == UInt8(ascii: ";") { digits.append(Character(UnicodeScalar(b))); j += 1; continue }
                break
            }
            if let end, let row = digits.split(separator: ";").first.flatMap({ Int($0) }) {
                rows.append(row)
                i = end + 1
                continue
            }
            i = j
        }
        return rows
    }
}
