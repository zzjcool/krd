import Foundation
import CoreGraphics
import krdcore

/// Input tables. `internal` rather than `private` on purpose: the test target pins them, and
/// the #14 crash was arithmetic on a table rather than a wrong key, so the table is the thing
/// worth testing.

/// Reads terminal input from stdin and injects it into the captured surface via CGEvent.
final class InputReader {
    private let currentViewport: () -> Viewport
    private let onQuit: () -> Void
    private let dryRun: Bool

    /// When the bytes that are being handled arrived: `parse start`, for the input half of issue
    /// #52. Zero means "no read in flight", which is the honest state for events posted by the
    /// clipboard bridge or a paste loop rather than by a key.
    private var readAt = Double(0)
    private var inputSeries = Series()
    /// `parse → CGEvent.post` for the most recent event, and the p99 over the last 300.
    private(set) var lastInputMs = Double(0)
    /// When the terminal's last `CSI 0n` arrived (seconds, `benchNowMs()` base), and how many there
    /// have been. Read by the diagnostics tick, which owns the probe's send time.
    private(set) var lastStatusReplyAt = Double(0)
    private(set) var statusReplies = 0
    /// Graphics replies the terminal sent (`APC G i=…;OK|E… ST`, issue #109), and how many of them
    /// were refusals. Data about the picture, never input: nothing here reaches `postKey`.
    private(set) var graphicReplies = 0
    private(set) var imageErrors = 0
    /// The last refusal, sanitized for a log line — `EINVAL: decompression failed`.
    private(set) var lastImageError: String?
    /// `(image, status)` pairs already reported. A refused tile is redrawn every frame and the
    /// terminal answers every time; the human needs the sentence once, not 20 times a second.
    private var reportedImageErrors: Set<String> = []
    var inputP99Ms: Double { inputSeries.percentile(0.99) }
    /// A copy of the recent samples, for the `SIGUSR2` report bundle.
    var inputSamples: Series { inputSeries }
    /// `false` = parse everything, inject nothing, and — unlike `--dry-run` — say nothing about it
    /// either. The wall (`--wall`) is the one mode with no remote desktop behind it, and the dry-run
    /// log has nowhere to go but the terminal that *is* the wall: `Log`'s sink is stderr until a
    /// file is configured, so a single `input: key code=12` line ended in a `\n` on the last row and
    /// scrolled the whole picture. Measured in a pty session. So this flag is not "dry run, quietly":
    /// it is the whole local half of the reader, and `--wall` also routes `Log` to a file
    /// (`main.swift` `Log.configure`) so the diagnostics nobody can suppress still land in one.
    private let forward: Bool
    /// `nil` = display mode, post globally. Non-nil = `--window`: ask it for the pid every event, so
    /// a window that closed mid-session is noticed instead of silently clicking into whatever is in
    /// front (issue #17).
    var targetPid: (() -> pid_t?)?
    /// The mirrored window's number, and "which window is on top at this point" -- together they say
    /// whether the global tap would reach the mirrored window (the pid path does not for mouse events
    /// on macOS 26, see `post`).
    var targetWindow: (() -> CGWindowID?)?
    var topmostWindow: ((CGPoint) -> CGWindowID?)?
    private var loggedTarget = false
    private var loggedFallback = false

    /// How characters reach the mirrored Mac (issue #16): physical keys so the target's input
    /// method composes, or injected text that bypasses it.
    var ime: IMEMode = .auto
    private var loggedInjectedText = false
    private var loggedDroppedText = false

    /// Clipboard directions (issue #18). `toTarget` gates `Ctrl-V` here; the target→terminal half
    /// lives in `ClipboardBridge`, because this class never reads the pasteboard itself.
    var clipboard: ClipboardPolicy = .off
    /// A clipboard the terminal handed back after an OSC 52 read.
    var onClipboardFromTerminal: ((String) -> Void)?
    /// Generation counter, so a late answer does not clear a newer request's timeout.
    private var pasteRequests = 0
    private var pendingPaste = 0
    private var loggedNoPasteAnswer = false
    /// With --debug every recognised event is logged, so "nothing happens" can be split
    /// into "the terminal never sent it" vs "the click went to the wrong place".
    var trace = false
    /// The last discard the trace has already reported (`InputParser.discardEndSerial`).
    private var loggedDiscardSerial = 0
    /// Prefix-mode byte handling for the TUI layer (`--dev`). Returns true when the byte belongs
    /// to the chrome, i.e. must not reach the remote desktop.
    ///
    /// Asked from three places, all of them the reader thread: `handleControl` (a control byte,
    /// armed or not), `ingest` (the bytes of one read that arrive while the prefix is armed) and
    /// `chromeChordByte` (the same rule stated for the parser's events). The last two are #115:
    /// every documented chord key is *printable*, so the parser used to turn it into a keystroke
    /// for the mirrored Mac before the chrome was ever asked.
    var onChromeKey: ((UInt8) -> Bool)?

    /// The terminal's own focus reports (`CSI I` / `CSI O`, DECSET 1004), and the same thing inferred
    /// from a human input event (issue #110). `true` = the pane is in front again.
    ///
    /// Nothing about this reaches the remote desktop -- focus is about the *picture's* rate, never
    /// about eating a keystroke -- so it is a notification, not a route. Asked for by the desk only
    /// for a session that reads input (`ScreenWriter.focusReporting`); a terminal that never reports
    /// focus simply never calls it, which is every terminal that was fine before this existed.
    var onFocus: ((Bool) -> Void)?

    /// The terminal's colour-scheme report (`CSI ? 997 ; N n`, DEC mode 2031) — issue #213's desk half.
    ///
    /// A *reply*, not input, and not a round-trip answer either (issue #212): the two properties the
    /// `.colourScheme` arm below has always kept are the reason this is a hook of its own and not a
    /// `postKey`. Nothing here reaches the remote desktop, and nothing here is stamped into
    /// `lastStatusReplyAt`.
    ///
    /// Called on the reader thread, like every other hook here. The receiver hops to the main queue:
    /// what a scheme change does is re-derive a palette and repaint, and both of those are the
    /// painter's, never the reader's.
    var onColourScheme: ((ColourScheme) -> Void)?

    /// Is the chrome waiting for the second key of its chord (`Ctrl-\` then `s`/`d`/`f`/`l`/`?`/`q`)?
    ///
    /// The prefix state belongs to the chrome (`Desk.chromeKey` is its only writer, on this same
    /// thread), so the reader asks instead of keeping a second copy that could disagree. Never true
    /// outside `--dev`, and never true in a wall session, which has no chrome and arms nothing: those
    /// route byte-for-byte as they always did.
    var chromePrefixArmed: (() -> Bool)?
    /// The wall's own keyboard (`--wall`): asked once per key event, before anything can be posted
    /// or logged, and told which of its six verbs the event is (`WallInput.key(for:)`).
    ///
    /// A seam of its own because the wall is the one mode with no remote desktop: every key belongs
    /// to nobody, and yet a handful of them have to reach the TUI the reader is looking at (#201 —
    /// `Tab`/`Shift-Tab` walk the focus ring, the arrows move inside a band, `Enter`/`Space` activate
    /// and `Esc` clears). Nothing else changes for a session whose wall has not asked: the hook is
    /// `nil` outside `--wall`, and a key this returns `true` for is one the reader posts nothing for.
    ///
    /// Called on the reader thread, like every other hook here; the receiver hops, because what a
    /// wall key changes is the state the painter owns.
    var onWallKey: ((WallKey) -> Bool)?

    /// A click outside the picture, in 1-based cells: the status line and its panels, and — with
    /// `--wall` — the whole pane, which has no picture at all. The third argument is the wheel's
    /// direction: `0` for a click, `-1` for a notch up, `+1` for a notch down. A wall click is a
    /// click on a control and a wheel report over it must not enter anything, so the receiver has to
    /// be able to tell the two apart; a panel needs the sign as well as the flag, because one notch
    /// up and one notch down scroll opposite ways (issue #118).
    var onChromeClick: ((Int, Int, Int) -> Void)?
    /// The pointer moved, or a button changed state, over a cell: 1-based row and column, and whether
    /// a press is down.
    ///
    /// Called for *every* mouse report except a wheel — motion, press and release alike. Before this
    /// existed only a press was routed anywhere and a move was thrown away, so nothing on the wall
    /// could answer the pointer: a reader had to click a card to find out whether the thing they were
    /// aiming at was a card at all. The receiver gets the raw cell (the chrome's own hit test is what
    /// decides if it means anything) and the button state, so a highlight can end on the release it
    /// belongs to instead of staying lit.
    ///
    /// Reports arrive on the reader thread; `Desk` hops to the main queue, because a hover changes
    /// what the wall paints.
    var onChromeHover: ((Int, Int, Bool) -> Void)?
    /// Does the chrome own this cell? 1-based row and column, in cells.
    ///
    /// Asked *before* the viewport guards, and for every non-motion, non-release report, because the
    /// picture's box cannot answer this question: with `?1016h` the box is the pane's own pixel
    /// grid (a 40x15 pty with 8x16 cells reports 320x240 px and builds its frame out of them, so a
    /// wheel over the panel — px(160,112) is row 8 — is inside the picture's 320x240 px frame as
    /// well), so `Viewport.contains(pixel:)` is true over the panel and a wheel there was posted to
    /// the remote desktop instead of moving the panel's window (#118). The chrome's own regions do
    /// not depend on the picture's box; a cell that is neither a panel cell nor a status-line button
    /// answers `false` here and takes the viewport path exactly as before, so a legitimate desktop
    /// scroll is untouched. `Desk` supplies it, and this stays a closure so the reader keeps its
    /// one-way dependency on the chrome layer.
    var chromeOwns: ((Int, Int) -> Bool)?

    /// Is a press the chrome took still in flight, i.e. is its release still to come?
    ///
    /// A press the chrome is offered never reaches the remote desktop, and neither may the rest of
    /// its gesture: in pixel mode the picture's box is the whole pane, so the drag and the release
    /// of that same click would fall through the viewport guards and arrive as
    /// `leftMouseDragged`/`leftMouseUp` with no `leftMouseDown` before them — a mirrored app left
    /// holding a button it never saw pressed (#118). Set when a press is routed to the chrome,
    /// cleared by its release, and cleared by a press that is not the chrome's (a fresh down means
    /// the release of the old gesture is never coming). A wheel ends nothing, so it neither sets
    /// nor clears it.
    private var chromePress = false

    /// Is a press the chrome took still waiting for its release? The flag above, as a question the
    /// tests can ask: the rule is a rule about a *sequence*, and "was the drag swallowed" is only
    /// observable through this (nothing else in the reader changes when a report is dropped).
    var chromePressInFlight: Bool { chromePress }

    /// `kitty` reports the flags the terminal answered with, or nil when it stayed silent — the
    /// capability handshake in `ScreenWriter.writeKeyboardProtocol`. Silence is a normal outcome:
    /// it means "legacy encoding only", which is exactly what the pre-#15 parser handled.
    private(set) var keyboardFlags: Int?

    private func log(_ text: String) {
        Log.write("input: " + text + "\n")
    }

    /// The one line that says what a discard did: which introducer, how many bytes, and which of the
    /// three conditions ended it. It replaces a line that guessed "a reply that stopped arriving"
    /// for **every** latch — including the user's own Alt-`]` — and sent the reader after a terminal
    /// bug that does not exist (issue #109, round 6).
    private func logDiscardEnd() {
        guard trace, parser.discardEndSerial != loggedDiscardSerial,
              let report = parser.lastDiscard else { return }
        loggedDiscardSerial = parser.discardEndSerial
        log("discard ended at \(report.end.rawValue): \(report.dropped) B dropped, "
            + "\(Int(report.livedMs)) ms, from \(report.introducer.rawValue)")
    }
    /// The CSI/SS3 state machine, in krdcore (issue #45). It owns the byte buffer; this class owns
    /// the tty, the `CGEvent`s and every decision about what a parsed event means.
    let parser = InputParser()
    private var downButton: MouseButton?
    private var clickCount = 1
    private var lastPress: (time: TimeInterval, point: CGPoint, count: Int)?
    /// Sticky: once a report carries a coordinate beyond the grid, the terminal is talking
    /// pixels (SGR-Pixels). Terminals that ignore `?1016h` keep sending cells, and then this
    /// stays false and the old mapping applies.
    private var pixelMouse = false
    private var savedTermios: termios?

    init(viewport: @escaping () -> Viewport, dryRun: Bool = false, forward: Bool = true,
         onQuit: @escaping () -> Void) {
        self.currentViewport = viewport
        self.dryRun = dryRun
        self.forward = forward
        self.onQuit = onQuit
        // Wired here, not in `start()`: the parser is this class's decoder, and a test that drives
        // `ingest` has to reach `apply` without owning a tty (`DevChordTests`, #115).
        parser.onEvent = { [weak self] event in self?.apply(event) }
    }

    // MARK: lifecycle

    @discardableResult
    func start() -> Bool {
        guard isatty(STDIN_FILENO) == 1 else {
            Log.write("""
            krd: input DISABLED - stdin is not a tty, so mouse/keyboard cannot work.
                     Run it over ssh with -t (ssh -t host krd ...), not ssh host krd.
                     Mouse reporting is left off, otherwise the terminal's reports would just
                     be echoed onto the screen as text.

            """)
            return false
        }
        // Only ask the terminal for its reports (the mouse modes, plus focus reporting when the desk
        // asked for it) once we know we can read them back.
        ScreenWriter.writeInputModes(true)
        // Push the keyboard enhancements and ask which ones took. A terminal that does not know
        // the sequence ignores it and stays on the legacy encoding, so this is safe to send blind.
        ScreenWriter.writeKeyboardProtocol(true)
        var t = termios()
        if tcgetattr(STDIN_FILENO, &t) == 0 {
            savedTermios = t
            var raw = t
            // No echo/signals/line discipline: every key belongs to the remote side.
            raw.c_lflag &= ~UInt(ECHO | ICANON | ISIG | IEXTEN)
            raw.c_iflag &= ~UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
            raw.c_oflag &= ~UInt(OPOST)
            raw.c_cflag |= UInt(CS8)
            withUnsafeMutableBytes(of: &raw.c_cc) { p in
                p[Int(VMIN)] = 1
                p[Int(VTIME)] = 0
            }
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        Thread.detachNewThread { [weak self] in self?.loop() }
        return true
    }

    func restore() {
        if let t = savedTermios {
            var copy = t
            tcsetattr(STDIN_FILENO, TCSANOW, &copy)
            savedTermios = nil
        }
    }

    /// Stop the reader thread and give the terminal back.
    ///
    /// The wall hands the tty to a child `krd` when a card is clicked, and two readers on one tty
    /// would steal each other's reports. This waits for the thread to leave its `poll` (it wakes at
    /// least every 100 ms), so the caller can rely on nobody reading once it returns.
    func stop() {
        stopLock.lock()
        stopFlag = true
        stopLock.unlock()
        _ = stoppedSignal.wait(timeout: .now() + 1)
    }

    private var isStopped: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopFlag
    }

    // MARK: read loop

    private let stopLock = NSLock()
    private var stopFlag = false
    private let stoppedSignal = DispatchSemaphore(value: 0)
    /// 100 ms ticks with no bytes: the only clock the idle decisions run on. The *policy* — what a
    /// bare `ESC ]` releases, and when a discard is past its fixed deadline — lives in
    /// `InputParser.resolveStall`, so the parser can be tested against a fake clock.
    private func loop() {
        defer {
            // Whatever made the loop return, the terminal goes back to the shell in a state that
            // works: input reporting off (`?1004` included, when it was asked for), kitty flags off,
            // termios restored.
            ScreenWriter.writeInputModes(false)
            ScreenWriter.writeKeyboardProtocol(false)
            restore()
            stoppedSignal.signal()
        }
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            if isStopped { return }
            var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 100)
            if ready == 0 {
                // A read that returned no data: an escape sequence that stopped arriving. This is
                // the only clock the parser's idle decisions ever see, and it decides only two
                // things — a bare `ESC ]` is the Alt-`]` key, and a discard past its fixed
                // deadline is abandoned. `ESC _` is **not** decided here: it waits for the byte
                // that decides it, so a reply written in pieces far apart is still a reply
                // (`InputParser.resolveStall`, issue #109 round 4).
                //
                // Nothing here resets the parser and keeps parsing the remainder: `reset()` drops
                // the buffered head and the *rest* of the sequence then arrives as input, which is
                // how `SECRET` got typed into the mirrored desktop.
                let held = parser.buffer
                if held.count == 1, held[0] == 0x1B {
                    parser.reset()
                    // A bare `Esc` is the one key that does not arrive as a parsed event (it is
                    // decided by the *absence* of the next byte), so the wall is asked here too:
                    // without this the reader would own the only key that clears the focus ring.
                    if let onWallKey, onWallKey(.cancel) { continue }
                    postKey(Keys.esc, [])
                    continue
                }
                let outcome = parser.resolveStall()
                if trace {
                    switch outcome {
                    case .none, .escape, .pending, .abandoned:
                        break                       // `abandoned` emitted its own `.notice`
                    case .released:
                        log("released a stalled `ESC ]` as the Alt+] keystroke")
                    case .sequence:
                        // A reply latched a discard; half a keystroke simply went away. What is
                        // logged here is the *start*; `logDiscardEnd` reports how it ended, and
                        // that is the line to read when a discard ate something unexpected.
                        if let introducer = parser.discardIntroducer {
                            log("discard opened by \(introducer.rawValue), \(held.count) B held; "
                                + "it swallows to its terminator")
                        } else {
                            log("dropped an unterminated escape sequence (\(held.count) B)")
                        }
                    }
                }
                logDiscardEnd()
                continue
            }
            let n = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
            if n <= 0 { return }
            if trace {
                let hex = chunk[0..<n].map { String(format: "%02x", $0) }.joined(separator: " ")
                log("raw \(n) bytes: \(hex)")
            }
            readAt = benchNowMs()
            ingest(chunk[0..<n])
            logDiscardEnd()
        }
    }

    /// One `read(2)`'s worth of bytes: the chrome's armed chord first, then the parser.
    ///
    /// `internal` for the same reason as `handleMouse` — it is the one entry point a read takes, and
    /// that hand-off is exactly what #115 got wrong. The tty is the only part of `loop()` a test
    /// process cannot have. Nothing changes for a session whose prefix is not armed: the bytes go to
    /// `parser.feed` in one slice, as they always did.
    func ingest(_ bytes: ArraySlice<UInt8>) {
        var start = bytes.startIndex
        if let armed = chromePrefixArmed, let chrome = onChromeKey {
            while start < bytes.endIndex, armed() {
                let byte = bytes[start]
                // Only a key that is one byte on the wire and one key on the keyboard can be the
                // second half of a chord: `ESC` starts a sequence (the parser is the only thing that
                // can say which one, and it has to see the whole of it) and a byte with the high bit
                // set is half a character. Both keep the old path and leave the prefix armed.
                guard byte != 0x1B, byte < 0x80 else { break }
                guard chrome(byte) else { break }
                start += 1
            }
        }
        if start < bytes.endIndex { parser.feed(bytes[start...]) }
    }

    /// The chrome's chord byte, when this event is the second key of an armed prefix (#115).
    ///
    /// `ingest` catches a chord byte before it is parsed, which is what keeps it out of the parser's
    /// buffer. This is the same rule stated in the parser's own vocabulary, and it is not redundant:
    /// `Ctrl-\` and the key after it usually arrive in *one* read (`input: raw 2 bytes: 1c 71`), so the
    /// prefix is armed mid-chunk and the second key has already been parsed by the time it is due.
    ///
    /// Three shapes, because the wire has three: a control byte, `text` (the legacy encoding) and a
    /// kitty key report (`CSI u`). Only unmodified single keys are chord keys — `Ctrl-C` keeps its
    /// documented meaning of "forwarded to the remote", and no multi-byte character is one of
    /// `s`/`d`/`f`/`l`/`?`/`h`/`q`.
    private func chromeChordByte(_ event: Event) -> UInt8? {
        guard chromePrefixArmed?() == true else { return nil }
        let byte: UInt8?
        switch event {
        case let .control(b):
            byte = b
        case let .text(ch, mods):
            byte = mods.isEmpty ? ch.asciiValue : nil
        case let .key(report):
            byte = report.mods == 0 && report.phase != .release ? UInt8(exactly: report.code) : nil
        default:
            byte = nil
        }
        // `ESC` is never a chord key: see `ingest`.
        guard let byte, byte != 0x1B else { return nil }
        return byte
    }

    // MARK: events from krdcore

    /// What one parsed event means for this machine (issue #45). The parser only says what the
    /// bytes were; the mapping, the IME policy, the click counter and the clipboard all live here.
    private func apply(_ event: Event) {
        // Focus comes first, and before the chord: a focus report is not a key the chrome could take,
        // and a human input event says "the person is here" whatever the terminal last reported
        // (issue #110 I5). Any key, click or wheel counts, because a terminal that loses a `CSI I` --
        // a multiplexer, a resize, a pane that never got one -- would otherwise leave the picture
        // throttled until the terminal answered a report it does not send. Terminal *replies*
        // (`keyboardFlags`, `statusReport`, `colourScheme`, `graphicReply`, `notice`, `osc`) are not
        // input and must not count: a 1 Hz probe would then wake the picture forever.
        switch event {
        case let .focus(on):
            onFocus?(on)
            // Nothing else: no post, no trace line about the desktop. The reader's job for a focus
            // report is over here (the `.focus` arm of the switch below is the exhaustiveness one).
            return
        case .key, .press, .text, .control, .mouse:
            onFocus?(true)
        default:
            break
        }
        // The wall's keys are the wall's before they are anybody else's: `--wall` has no remote
        // desktop, and a key it acts on must not also be a keystroke for a picture that is not there.
        // Asked here — after `onFocus`, before the chord — so that a wall session keeps the one
        // behaviour it shares with a mirror (a keypress says the reader is here).
        if let onWallKey, let key = WallInput.key(for: event), onWallKey(key) { return }
        // The chord is the chrome's before it is the desktop's (see `chromeChordByte`).
        if let chord = chromeChordByte(event), onChromeKey?(chord) == true { return }
        switch event {
        case let .key(report):
            handleKeyReport(report)
        case let .press(code, mods, phase):
            postKey(code, cg(mods), phase: phase)
        case let .text(ch, mods):
            handleKey(ch, flags: cg(mods))
        case .statusReport:
            // The round-trip probe's answer (issue #52). Timestamped here, on the input thread, so
            // the 1 Hz diagnostics tick can compute an accurate round trip from it.
            lastStatusReplyAt = benchNowMs() / 1000
            statusReplies += 1
        case let .colourScheme(scheme):
            // DEC mode 2031's report (issue #212): a terminal *reply*, not input — and deliberately
            // **not** stamped above, because a theme change is not a completed round trip. Both of
            // those are load-bearing and neither is an oversight to be "fixed": (a) `lastStatusReplyAt`
            // is the round-trip probe's clock, and a report nobody asked for is not a completed round
            // trip — stamping it would fake an RTT the diagnostics tick then believes; (b) the switch
            // above only wakes the picture for `.key`/`.press`/`.text`/`.control`/`.mouse`, because a
            // reply is not a person, and a 1 Hz probe that counted as input would wake the picture
            // forever (issue #110).
            //
            // What it *does* do since #213 is reach the desk: the palette is derived once from it
            // (`Desk.applyColourScheme`), which is a repaint of the text layer and nothing else.
            if trace { log("colour scheme report \(scheme.rawValue)") }
            onColourScheme?(scheme)
        case let .control(byte):
            handleControl(byte)
        case let .mouse(report):
            handleMouse(report)
        case let .osc(params):
            handleOSC(params)
        case let .keyboardFlags(flags):
            keyboardFlags = flags
            if trace { log("keyboard protocol flags=\(flags.map(String.init) ?? "unparsed")") }
        case let .graphicReply(reply):
            handleGraphicReply(reply)
        case let .notice(text):
            if trace { log(text) }
        case .focus:
            // Handled above, on the way in: focus is about the picture's rate, never about eating a
            // keystroke or posting one (issue #110). This arm exists so the switch stays exhaustive.
            break
        }
    }

    /// A graphics reply is a statement about the wire, not a keystroke (issue #109). It used to be
    /// typed into the mirrored desktop as Alt-`G`-and-friends when `KRD_Q` asked the terminal to
    /// answer; now it is counted, and the *first* refusal per `(image, status)` becomes one line in
    /// the log, which is where a human already looks for a black tile.
    private func handleGraphicReply(_ reply: GraphicsReply) {
        graphicReplies += 1
        let status = Self.logSafe(reply.status)
        guard reply.isError else {
            if trace {
                log("graphic reply \(reply.isOK ? "ok" : "unparsed")"
                    + " image=\(reply.image.map(String.init) ?? "-")"
                    + " placement=\(reply.placement.map(String.init) ?? "-")"
                    + " status=\(status)")
            }
            return
        }
        imageErrors += 1
        lastImageError = status
        guard reportedImageErrors.insert("\(reply.image.map(String.init) ?? "-")/\(status)").inserted
        else { return }
        let image = reply.image.map(String.init) ?? (reply.imageNumber.map { "number \($0)" } ?? "?")
        Log.write("krd: image \(image) refused: \(status)\n")
    }

    /// The terminal's own words, made safe for a one-line log: no control bytes (a reply is
    /// attacker-influenceable text on a tty), no newline, and a length a human can read.
    private static func logSafe(_ text: String) -> String {
        // The reply is terminal-supplied text on a tty, so only printable ASCII gets through: a
        // stray U+009B or a bidi override in an error message would otherwise edit the log itself.
        let cleaned = String(text.unicodeScalars.filter { (0x20...0x7E).contains($0.value) })
        return String(cleaned.prefix(200))
    }

    /// Same bits on both sides of the boundary (issue #45): `CGEventFlags` and `Modifiers` agree on
    /// every value krd uses, so this is a reinterpretation, not a conversion table.
    private func cg(_ mods: Modifiers) -> CGEventFlags { CGEventFlags(rawValue: mods.rawValue) }

    // MARK: parsing

    /// One decoded report: decide what it means and post it. Press and repeat stay a down+up tap
    /// (what every legacy key does today, and what makes hold-to-repeat work without the mirrored
    /// app ever holding a key the terminal forgot); a release is an up on its own.
    private func handleKeyReport(_ report: KeyReport) {
        if trace {
            log("key \(report.code) mods=\(report.mods) \(report.phase)"
                + (report.base.map { " base=\($0)" } ?? ""))
        }
        // Ctrl-V is krd's paste key (issue #18) and has to work in both encodings: a terminal that
        // answered the kitty handshake reports it as `CSI 118;5 u`, never as the 0x16 byte.
        if let v = Keys.map["v"], report.code == v, report.mods == 4, report.phase != .release {
            requestPaste()
            return
        }
        if report.isQuitChord {
            if report.isQuit { onQuit() }
            return
        }
        if Keyboard.modifierKeys.contains(report.code) {
            if trace { log("modifier \(report.code) \(report.phase) not forwarded") }
            return
        }
        switch Keyboard.plan(for: report, mode: ime) {
        case let .key(code, flags):
            postKey(code, cg(flags), phase: report.phase)
        case let .text(ch):
            noteInjectedText(ch)
            postUnicode(ch, cg(report.flags), phase: report.phase)
        case .drop:
            noteDroppedText(report.code)
        }
    }

    // MARK: mouse

    /// Mouse buttons, in the order SGR encodes them in the low two bits of the button code.
    /// 3 is not a button: inside a motion report it means "nothing is held".
    private enum MouseButton: Int {
        case left = 0, middle = 1, right = 2

        var cgButton: CGMouseButton {
            switch self {
            case .left: return .left
            case .middle: return .center
            case .right: return .right
            }
        }

        func type(press: Bool) -> CGEventType {
            switch self {
            case .left: return press ? .leftMouseDown : .leftMouseUp
            case .middle: return press ? .otherMouseDown : .otherMouseUp
            case .right: return press ? .rightMouseDown : .rightMouseUp
            }
        }

        var dragType: CGEventType {
            switch self {
            case .left: return .leftMouseDragged
            case .middle: return .otherMouseDragged
            case .right: return .rightMouseDragged
            }
        }
    }

    /// Modifier bits the terminal puts in the button code (xterm's "meta" is Option on the Mac).
    private func modifiers(from b: Int) -> CGEventFlags {
        var flags: CGEventFlags = []
        if b & 4 != 0 { flags.insert(.maskShift) }
        if b & 8 != 0 { flags.insert(.maskAlternate) }
        if b & 16 != 0 { flags.insert(.maskControl) }
        return flags
    }

    /// One mouse report, in the terminal's own units. Everything that needs *this* machine happens
    /// here: the cell-vs-pixel latch (a cell can never exceed the grid), the viewport transform,
    /// the click counter and the injection (issue #45 keeps those on this side of the boundary).
    ///
    /// `internal`, not `private`: it is the one entry point a report takes, and the gesture rule
    /// (`chromePress`, #118) is a rule about a *sequence* of reports — `PanelWheelRealPathTests`
    /// feeds it three and asserts the desk heard one click. The tty is the only thing left in
    /// `loop()`, so nothing here touches a file descriptor.
    func handleMouse(_ report: MouseReport) {
        reportHover(report)
        handleMouseBody(report)
    }

    /// Tell the receiver where the pointer is, before the event is routed.
    ///
    /// Before, because "is a button down" is a fact about the *state the event arrives in*: a press
    /// is down (and `chromePress` is not set until the route below decides it belongs to the
    /// chrome), a release is up, and a motion is down exactly when a chrome press is still in flight
    /// — the drag of a click that the picture must never see (#118). After routing, the same motion
    /// during a press would read as "up", and the pressed look would flicker with every drag report.
    private func reportHover(_ report: MouseReport) {
        guard let hover = onChromeHover, !report.isWheel else { return }
        let px = report.x, py = report.y
        // A cell coordinate can never be larger than the grid; anything bigger is a pixel coordinate,
        // i.e. the terminal honoured `?1016h` — the same test `handleMouseBody` makes, for the same
        // reason (the wall runs with pixel reporting on, so this is the normal path there).
        let pixel = px > TermGeometry.lastGrid.cols || py > TermGeometry.lastGrid.rows
        let cell = pixel
            ? Self.cell(forPixel: px, py, cellSize: TermGeometry.read().cellSize)
            : (row: py, col: px)
        let down = !report.isRelease && (report.isMotion ? chromePress : true)
        hover(cell.row, cell.col, down)
    }

    private func handleMouseBody(_ report: MouseReport) {
        let cx = report.x, cy = report.y
        let motion = report.isMotion

        // A cell coordinate can never be larger than the terminal grid; anything bigger is a
        // pixel coordinate, i.e. the terminal honoured `?1016h`.
        if cx > TermGeometry.lastGrid.cols || cy > TermGeometry.lastGrid.rows {
            pixelMouse = true
        }

        // The rest of a gesture the chrome already took: swallowed, so the picture never sees it
        // half-done (see `chromePress`). The release is where it ends; until then every motion
        // report of that drag belongs to the chrome too.
        if chromePress, motion || report.isRelease {
            if report.isRelease { chromePress = false }
            if trace {
                log("swallowed the chrome press's \(report.isRelease ? "release" : "motion") at "
                    + "\(pixelMouse ? "px" : "cell")(\(cx),\(cy))")
            }
            return
        }

        let viewport = currentViewport()
        // The chrome answers first (see `chromeOwns`): priority is the panel's rectangle, then a
        // status-line button, then the picture. `chromeCell` is the decision, in one place, so a
        // test can ask it the same question this line asks.
        if !motion, !report.isRelease, let owns = chromeOwns, let click = onChromeClick {
            // The cell size is only divided by in pixel mode, and `TermGeometry.read()` is an
            // ioctl: ask for it when it is used.
            let cell = Self.chromeCell(row: cy, col: cx, pixelMouse: pixelMouse,
                                       wheel: report.wheelStep,
                                       cellSize: pixelMouse ? TermGeometry.read().cellSize
                                                            : TermGeometry.fallbackCell,
                                       owns: owns)
            if let cell {
                click(cell.row, cell.col, report.wheelStep)
                if !report.isWheel { chromePress = true }   // a wheel ends nothing (see above)
                downButton = nil
                return
            }
            // A press (not a wheel) that is not the chrome's: the gesture in flight, if any, is
            // not coming back, so drop the flag instead of letting it swallow a later drag.
            if !report.isWheel { chromePress = false }
        }
        let point: CGPoint
        let spot: String
        if pixelMouse {
            guard viewport.contains(pixel: cx, cy) else {
                if !motion, trace {
                    // The picture does not fill the pane (issue #69): the cells past it belong to the
                    // terminal, so this is not a click on the mirrored screen. Say so instead of
                    // posting a guessed point.
                    log("mouse at px(\(cx),\(cy)) is outside the picture "
                        + "(\(viewport.pixelWidth)x\(viewport.pixelHeight) px); ignored")
                }
                // Press only: a release is the same click again, and the wall's bar *steps* per
                // click (`cardStep(per)`), so delivering both would move two pages for one click.
                // The chrome path opened a panel twice before this and that was invisible, because
                // opening an already-open panel is a no-op.
                if !motion, !report.isRelease, let click = onChromeClick {
                    let cell = Self.cell(forPixel: cx, cy, cellSize: TermGeometry.read().cellSize)
                    click(cell.row, cell.col, report.wheelStep)
                }
                if !motion { downButton = nil }
                return
            }
            point = viewport.point(forPixel: cx, cy)
            spot = "px(\(cx),\(cy))"
        } else {
            guard viewport.contains(cell: cx, cy) else {
                if !motion, !report.isRelease { onChromeClick?(cy, cx, report.wheelStep) }
                if !motion { downButton = nil }
                return
            }
            point = viewport.point(forCell: cx, cy)
            spot = "cell(\(cx),\(cy))"
        }
        let flags = cg(report.mods)

        if report.isWheel {                                 // wheel: 64/65 vertical, 66/67 horizontal
            let kind = report.button
            if dryRun || trace {
                log("wheel \(kind) at \(spot) -> (\(Int(point.x)),\(Int(point.y))) flags=\(flags.rawValue)")
            }
            if !dryRun { postScroll(kind, flags: flags) }
            return
        }

        let index = report.button
        let button = MouseButton(rawValue: index) ?? MouseButton.left
        let type: CGEventType
        if motion && index == 3 {                           // 1003: pointer moving, nothing held
            type = CGEventType.mouseMoved
            downButton = nil
        } else if motion {
            type = button.dragType
            downButton = button
        } else if report.isRelease {
            type = button.type(press: false)
            downButton = nil
        } else {
            type = button.type(press: true)
            downButton = button
            clickCount = nextClickCount(for: point)
        }
        if dryRun || trace {
            log("mouse \(Self.name(type)) at \(spot) -> (\(Int(point.x)),\(Int(point.y))) "
                + "click=\(clickCount) flags=\(flags.rawValue)")
            if dryRun { return }
        }
        postMouse(type, button: button, at: point, flags: flags)
    }

    /// The chrome's routing decision, as one pure step: the 1-based cell the chrome is to be asked
    /// about, or `nil` when this report is not to be offered to it at all.
    ///
    /// Press-shaped reports only — a press and a wheel are both `!motion, !isRelease`, and the
    /// chrome takes both (`Desk.chromeClick` reads `wheel` to tell them apart). A drag or a release
    /// never gets here: those belong to whatever the press went to (`chromePress`). In pixel mode
    /// (`?1016h`) the report is in device pixels, so the cell is the pixel divided by the
    /// terminal's own cell size — the same division the outside-picture path has always done.
    /// `wheel` travels with the report so the caller hands over the whole report rather than half
    /// of it; the cell does not depend on it, because a wheel and a press over the panel are the
    /// same cell and that is the point (#118). Pure so the decision can be tested with a pty's real
    /// numbers (`PanelWheelTests`) rather than a pty.
    static func chromeCell(row: Int, col: Int, pixelMouse: Bool, wheel: Int,
                           cellSize: (w: Double, h: Double),
                           owns: (Int, Int) -> Bool) -> (row: Int, col: Int)? {
        let cell = pixelMouse ? self.cell(forPixel: col, row, cellSize: cellSize)
                              : (row: row, col: col)
        return owns(cell.row, cell.col) ? cell : nil
    }

    /// A SGR-Pixels report (`?1016h`) → the 1-based cell it is over. One cell size, from the
    /// terminal: the pty's `ws_xpixel`/`ws_ypixel` divided by the grid, or the documented fallback
    /// when the terminal does not report pixels. Pure so the pixel half of the routing can be tested
    /// against the real numbers (`PanelWheelTests`) instead of a pty.
    static func cell(forPixel px: Int, _ py: Int,
                     cellSize: (w: Double, h: Double)) -> (row: Int, col: Int) {
        (row: Int(Double(py) / max(cellSize.h, 1)) + 1,
         col: Int(Double(px) / max(cellSize.w, 1)) + 1)
    }

    /// Double and triple clicks: same spot within half a second, like the real thing.
    private func nextClickCount(for point: CGPoint) -> Int {
        let now = Date().timeIntervalSinceReferenceDate
        if let last = lastPress, now - last.time < 0.5,
           abs(last.point.x - point.x) < 4, abs(last.point.y - point.y) < 4 {
            let count = min(last.count + 1, 3)
            lastPress = (now, point, count)
            return count
        }
        lastPress = (now, point, 1)
        return 1
    }

    private static func name(_ type: CGEventType) -> String {
        switch type {
        case .mouseMoved: return "move"
        case .leftMouseDown: return "left-down"
        case .leftMouseUp: return "left-up"
        case .leftMouseDragged: return "left-drag"
        case .rightMouseDown: return "right-down"
        case .rightMouseUp: return "right-up"
        case .rightMouseDragged: return "right-drag"
        case .otherMouseDown: return "middle-down"
        case .otherMouseUp: return "middle-up"
        case .otherMouseDragged: return "middle-drag"
        default: return "type(\(type.rawValue))"
        }
    }

    // MARK: keys

    /// `OSC ... BEL|ST` from the terminal. Only OSC 52 is ours; a title change or a hyperlink used
    /// to be typed into the mirrored app as Alt+] text, so handling the whole sequence (and ignoring
    /// the ones we do not implement) is a fix as much as a feature - but the payload never reaches
    /// the log, whatever it is.
    private func handleOSC(_ params: String) {
        guard let data = OSC52.decode(parameters: params) else {
            if trace { log("osc ignored (\(params.prefix(3)))") }
            return
        }
        guard clipboard.toTarget else {
            if trace { log("clipboard: terminal sent \(data.count) B, out direction off") }
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            if trace { log("clipboard: terminal sent \(data.count) B, not UTF-8") }
            return
        }
        pendingPaste = 0                     // the answer arrived: the timeout must not fire
        onClipboardFromTerminal?(text)
    }

    /// `Ctrl-V`: ask the terminal for its clipboard, then put it on the target's pasteboard and post
    /// `Cmd-V` (the answer comes back as an OSC 52 on stdin, in `handleOSC`).
    ///
    /// Terminals that cannot read OSC 52 simply never answer - the timeout below says so once,
    /// instead of leaving "Ctrl-V did nothing" to be diagnosed from scratch.
    private func requestPaste() {
        // The OSC 52 read goes to the *terminal*, not to the target, so it is not covered by the
        // dry-run gate below — and a wall has no pasteboard to hand anything to either.
        guard forward else { return }
        guard clipboard.toTarget else {
            if trace { log("clipboard: Ctrl-V ignored, out direction off") }
            return
        }
        pasteRequests += 1
        let generation = pasteRequests
        pendingPaste = generation
        if trace { log("clipboard: asked the terminal for its clipboard (OSC 52 read)") }
        ScreenWriter.writeRaw(OSC52.readRequest)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.pendingPaste == generation else { return }
            self.pendingPaste = 0
            guard !self.loggedNoPasteAnswer else { return }
            self.loggedNoPasteAnswer = true
            Log.write("krd: this terminal did not answer the OSC 52 read, so Ctrl-V has nothing to paste.\n"
                      + "         Use --clipboard-paste <file> for the terminal-to-target direction (see --help).\n")
        }
    }

    /// One `Cmd-V` into the target, through the same route as every other key - so in `--window`
    /// mode it lands in that window's process (issue #17) instead of in whatever is frontmost.
    func postPasteCommand() {
        guard let v = Keys.map["v"] else { return }
        postKey(v, .maskCommand)
    }

    private func handleControl(_ byte: UInt8) {
        if onChromeKey?(byte) == true { return }
        switch byte {
        case 0x1C:                                          // Ctrl-\ : leave
            onQuit()
        case 0x16:                                          // Ctrl-V: paste the terminal's clipboard
            requestPaste()
        case 0x00:
            postKey(Keys.space, .maskControl)
        case 0x1B:
            postKey(Keys.esc, [])
        default:
            guard byte >= 0x01, byte <= 0x1A,
                  let ch = Character(UnicodeScalar(byte + 0x60)) as Character? else { return }
            handleKey(ch, flags: [.maskControl])
        }
    }

    private func handleText(_ text: String) {
        for ch in text {
            handleKey(ch, flags: [])
        }
    }

    private func handleKey(_ ch: Character, flags: CGEventFlags) {
        if let code = Keys.map[ch] {
            postKey(code, flags)
            return
        }
        if let base = Keys.shifted[ch], let code = Keys.map[base] {
            postKey(code, flags.union(.maskShift))
            return
        }
        if ch.isUppercase, let code = Keys.map[Character(ch.lowercased())] {
            postKey(code, flags.union(.maskShift))
            return
        }
        // No physical key to press: either the terminal did not report one, or it never will
        // (a plain UTF-8 byte stream carries characters, not keys). Same policy as a report.
        if ime == .raw {
            noteDroppedText(Int(ch.unicodeScalars.first?.value ?? 0))
            return
        }
        noteInjectedText(ch)
        postUnicode(ch, flags)
    }

    /// Text went in through `keyboardSetUnicodeString`, i.e. the target's input method was skipped.
    /// Says so once, without the character itself: this is a diagnosis, not a keystroke log.
    private func noteInjectedText(_ ch: Character) {
        if trace { log("text \(ch.debugDescription) injected (no physical key)") }
        guard !loggedInjectedText else { return }
        loggedInjectedText = true
        Log.write("krd: this character has no key on the local layout, so krd injects it as text:\n"
                  + "         the target's input method never composes it (no candidate window, no\n"
                  + "         Korean jamo assembly) and keycode-reading apps receive nothing.\n"
                  + "         Turn the local input method off to type through the target's own IME.\n")
    }

    /// `--ime=raw` with nothing pressable: dropping is the point — half-injected text in the middle
    /// of a composition is worse than nothing.
    private func noteDroppedText(_ codepoint: Int) {
        if trace { log("dropped U+\(String(codepoint, radix: 16, uppercase: true)) (--ime=raw)") }
        guard !loggedDroppedText else { return }
        loggedDroppedText = true
        Log.write("krd: --ime=raw dropped text the terminal sent without a physical key.\n"
                  + "         Turn the local input method off (so the keys arrive raw), or use --ime=auto.\n")
    }

    private func postKey(_ code: CGKeyCode, _ flags: CGEventFlags, phase: KeyReport.Phase = .press) {
        // The wall has no remote desktop: nothing is injected, and nothing is *logged* about
        // injecting (see `forward`). This is checked before the trace line, not after it.
        guard forward else { return }
        if dryRun || trace {
            log("key code=\(code) flags=\(flags.rawValue)"
                + (phase == .press ? "" : " phase=\(phase)") + pidSuffix())
        }
        if dryRun { return }
        for down in phase == .release ? [false] : [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            post(event)
        }
    }

    private func postUnicode(_ ch: Character, _ flags: CGEventFlags, phase: KeyReport.Phase = .press) {
        guard forward else { return }        // same reason as `postKey`
        if dryRun || trace {
            log("text \(ch.debugDescription) flags=\(flags.rawValue)"
                + (phase == .press ? "" : " phase=\(phase)") + pidSuffix())
        }
        // `--dry-run` means "parse input but never post a CGEvent" -- this path used to post anyway,
        // which made the flag dishonest for every character outside `Keys.map`.
        if dryRun { return }
        var utf16 = Array(String(ch).utf16)
        for down in phase == .release ? [false] : [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
            event.flags = flags
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            post(event)
        }
    }

    private func postMouse(_ type: CGEventType, button: MouseButton, at point: CGPoint, flags: CGEventFlags) {
        guard forward else { return }        // same reason as `postKey`
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button.cgButton) else { return }
        // Always set the flags from the report itself. A CGEvent built with a nil source inherits
        // the session's modifier state, and postKey() sets .maskControl on the events it posts, so
        // a stale Control would turn every later click into a Control-click -- i.e. a right click
        // that pops a context menu and refuses to drag anything.
        event.flags = flags
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        default:
            break
        }
        post(event, describe: "\(type.rawValue) at \(Int(point.x)),\(Int(point.y))")
    }

    private static func isMouseEvent(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
             .otherMouseDragged, .mouseMoved, .scrollWheel:
            return true
        default:
            return false
        }
    }

    /// `kind` follows xterm: 64 up, 65 down, 66 left, 67 right.
    private func postScroll(_ kind: Int, flags: CGEventFlags) {
        guard forward else { return }        // same reason as `postKey`
        let vertical = kind < 2
        let sign: Int32 = kind % 2 == 0 ? 1 : -1            // the even codes are up / left
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                 wheel1: vertical ? sign : 0,
                                 wheel2: vertical ? 0 : sign,
                                 wheel3: 0) else { return }
        event.flags = flags                                 // same reason as postMouse
        post(event, describe: "scroll \(sign)")
    }

    /// One place that decides where an event goes.
    ///
    /// A window mirror has to reach *its* window even when another app is in front, and the window
    /// manager is what would otherwise decide (issue #17). `CGEventPostToPid` hands the event to the
    /// owning process instead; the coordinates stay global, which is what the app hit-tests with,
    /// and in window mode `Viewport.sourceRect` is already the window's own frame (`Geometry.swift`)
    /// — no second mapping is computed here on purpose.
    ///
    /// A window that closed mid-session has no pid: fall back to the global tap and say so once,
    /// because a silent fallback means clicks quietly start going to the desktop.
    private func post(_ event: CGEvent, describe: String? = nil) {
        defer { noteInputLatency() }
        if let targetPid, let pid = targetPid(), pid > 0 {
            // macOS 26 drops *mouse* events posted to a pid -- Safari and TextEdit both ignore them
            // without a word, while keys still arrive -- so a mirrored window could not be clicked
            // at all (issue #69). When the mirrored window is the one on top at the pointer, the
            // global tap delivers to exactly that window, so use it there; the pid path stays for
            // a covered window, where the global tap would hit whatever is in front (issue #17).
            if Self.isMouseEvent(event.type), let targetWindow, let topmostWindow,
               let window = targetWindow(), let top = topmostWindow(event.location), top == window {
                if trace, let describe { log("\(describe) -> global tap (the mirrored window is on top)") }
                event.post(tap: .cghidEventTap)
                return
            }
            if trace, let describe { log("pid \(pid) <- \(describe)") }
            if trace, !loggedTarget {
                loggedTarget = true
                log("posting to pid \(pid) (window mode): events bypass the window manager")
            }
            event.postToPid(pid)
            return
        }
        if targetPid != nil, !loggedFallback {
            loggedFallback = true
            Log.write("krd: the mirrored window is gone (no pid) — falling back to global injection;\n"
                      + "         clicks and keys now go to whatever is in front. Restart with --window <id> to re-attach.\n")
        }
        event.post(tap: .cghidEventTap)
    }

    /// `parse → post` for the event just sent. Measured here rather than at the call sites because
    /// this is the only funnel every path (keys, text, clicks, scroll) goes through.
    private func noteInputLatency() {
        guard readAt > 0 else { return }
        let ms = benchNowMs() - readAt
        guard ms >= 0, ms < 5_000 else { return }
        lastInputMs = ms
        inputSeries.add(ms)
    }

    /// Appended to a trace line so `--debug` shows which process an event was aimed at.
    private func pidSuffix() -> String {
        guard let targetPid else { return "" }
        if let pid = targetPid(), pid > 0 { return " pid=\(pid)" }
        return " pid=gone"
    }

    private func utf8Length(_ first: UInt8) -> Int {
        switch first {
        case 0x00..<0x80: return 1
        case 0xC0..<0xE0: return 2
        case 0xE0..<0xF0: return 3
        default: return 4
        }
    }
}
