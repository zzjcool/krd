import Foundation
import krdcore

/// `--dump-termcaps <path>`: what this terminal **actually** answered, written to a file (issue #226).
///
/// Every capability number the UI v2 plan rests on came from one terminal, or from a pty harness that
/// *plays* a terminal, and the fallbacks were tested against a fake that says "no" — no krd had been
/// run inside a terminal that really says no. The answers arrive on stdin, so making them visible
/// needs no screenshot and no Screen Recording grant: a process only has to write them down.
///
/// **The same batch, not a second probe path.** The dump calls `TermCaps.probeReport` — the one write
/// `prepareGraphemeMode` sends at start-up (`#197`) — and then the two graphics questions through
/// `TermGeometry.supportsPlaceholders`/`supportsAnimationFrames`, which is the product's own probe
/// (`TermGeometry.GraphicsProbe`). Asking a *different* set of questions and writing that down would
/// be evidence about a program nobody runs.
///
/// Why those two are in the report although they are not in the batch: they are the product's
/// questions and the matrix has no row without them (`U=1` decides whether pictures are cell-sized,
/// `a=f` whether the loading card costs 1.14 KB/s or 206 KB/s). They cannot ride in the batch — an
/// APC answer is not a `CSI`, and a refusal is *silence*, so they need a timeout of their own — so
/// they are the second write. Only the order differs from a start-up, and only from a mirror's (it
/// asks the graphics probe before the batch; a wall asks it behind the first paint): the questions,
/// the bytes and the read loops are the product's own, and order cannot change an answer.
///
/// The report also carries the two facts a parsed `TermCaps` cannot: how many `read(2)`s the answers
/// took (a terminal that answers in more than one write is a finding, issue #226) and how long the
/// read ran (a terminal that drops the `DA1` pays the whole timeout — that is a finding too).
enum TermCapsDump {
    /// Everything the file says, gathered first — so the JSON is a pure function of this value and
    /// the reading of a real terminal is one value to compare between two terminals.
    struct Report {
        var krd: String
        var at: Date
        /// The variables that name a terminal: `TERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`,
        /// `COLORTERM`. The version string `TERM_PROGRAM_VERSION` is what a table row is pinned to.
        var environment: [String: String]
        /// `false` means the batch was never written: `TermCaps.ask` refuses a stdin that is not a
        /// tty *before* sending a byte, and every field below is then "not asked" rather than "no".
        var stdinIsATTY: Bool
        /// `TIOCGWINSZ` as it arrived — the *other* half of the geometry question, so a dump can say
        /// whether the pty itself reported pixels and whether the `CSI 16t` answer agreed.
        var tty: (cols: Int, rows: Int, xpixel: Int, ypixel: Int)?
        var batch: TermCaps.Probe
        /// `nil` is "no answer", which is not "no": a silent terminal and a refusing one differ.
        var placeholders: Bool?
        var animationFrames: Bool?
        /// The APCs' own answers (`i=31,p=1;OK`, `Gi=32,r=2;OK`, `;EINVAL`), so the two verdicts
        /// above can be read *and* checked. `nil` when the probe was never answered.
        var graphicsReply: String?
    }

    /// Ask this terminal the product's question set, and hand back the answers.
    ///
    /// One function with no clock of its own apart from `at`, so the whole reading of a terminal is a
    /// value: the JSON below cannot disagree with anything a caller checks about the report.
    static func ask(environment: [String: String] = ProcessInfo.processInfo.environment,
                    at: Date = Date()) -> Report {
        // The batch first: it is the question under test, and it is the one write a start-up sends
        // before anything else might slow the read down.
        let batch = TermCaps.probeReport()
        let placeholders = TermGeometry.supportsPlaceholders()
        let animationFrames = TermGeometry.supportsAnimationFrames()
        return Report(krd: krdVersion,
                      at: at,
                      environment: environment,
                      stdinIsATTY: isatty(STDIN_FILENO) != 0,
                      tty: windowSize(),
                      batch: batch,
                      placeholders: placeholders,
                      animationFrames: animationFrames,
                      graphicsReply: TermGeometry.graphicsProbeReply)
    }

    /// `TIOCGWINSZ` on the pane, or `nil` when there is no window size to read (a tty that is not
    /// there, or a pty that has never been sized). Pixels of 0 are kept as 0: "the pty reported no
    /// pixel size" is exactly the fact `CSI 16t` exists to make up for.
    static func windowSize() -> (cols: Int, rows: Int, xpixel: Int, ypixel: Int)? {
        var ws = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 else { return nil }
        return (Int(ws.ws_col), Int(ws.ws_row), Int(ws.ws_xpixel), Int(ws.ws_ypixel))
    }

    /// The file: one JSON object, sorted keys, so two dumps of two terminals diff line by line.
    ///
    /// Raw bytes are kept as a JSON string with `\u001b` escapes — exact, printable, and copyable back
    /// into a test fixture. `null` is "the terminal did not answer", never "no".
    static func json(_ report: Report) -> String {
        let caps = report.batch.caps
        let parsed: [String: Any] = [
            "cell": sizeJSON(caps.cell),
            "window": sizeJSON(caps.window),
            // `DECRQM`'s `Ps`: 0 not recognised, 1 set, 2 reset, 3 permanently set, 4 permanently
            // reset. `null` = the terminal said nothing about the mode at all.
            "graphemeMode": caps.graphemeMode.map { $0 as Any } ?? NSNull(),
            "colourSchemeMode": caps.colourSchemeMode.map { $0 as Any } ?? NSNull(),
            "foreground": hexJSON(caps.foreground),
            "background": hexJSON(caps.background),
            "paletteScheme": caps.palette.map { $0.scheme.rawValue as Any } ?? NSNull(),
            "supportsColourSchemeFollow": caps.supportsColourSchemeFollow,
            "terminated": caps.terminated,
            "isEmpty": caps.isEmpty,
        ]
        let batch: [String: Any] = [
            "query": TermCaps.query,
            "queryBytes": TermCaps.query.utf8.count,
            "raw": report.batch.reply.map { $0 as Any } ?? NSNull(),
            "rawBytes": report.batch.reply?.utf8.count ?? 0,
            "reads": report.batch.reads,
            "elapsedMs": (report.batch.elapsedMs * 1000).rounded() / 1000,
            "parsed": parsed,
        ]
        let tty: Any = report.tty.map {
            ["cols": $0.cols, "rows": $0.rows, "xpixel": $0.xpixel, "ypixel": $0.ypixel]
        } ?? NSNull()
        let object: [String: Any] = [
            "krd": report.krd,
            "at": ISO8601DateFormatter().string(from: report.at),
            "terminal": [
                "TERM": named(report.environment, "TERM"),
                "TERM_PROGRAM": named(report.environment, "TERM_PROGRAM"),
                "TERM_PROGRAM_VERSION": named(report.environment, "TERM_PROGRAM_VERSION"),
                "COLORTERM": named(report.environment, "COLORTERM"),
            ],
            "stdinIsATTY": report.stdinIsATTY,
            "tty": tty,
            "batch": batch,
            "graphics": [
                "u1": report.placeholders.map { $0 as Any } ?? NSNull(),
                "animationFrames": report.animationFrames.map { $0 as Any } ?? NSNull(),
                "raw": report.graphicsReply.map { $0 as Any } ?? NSNull(),
            ],
        ]
        return AXCommand.jsonString(object)
    }

    /// Write the report, and hand back the one line that says what was found (the caller prints it).
    ///
    /// Throws rather than exiting: the caller owns the exit status, and a dump that cannot be written
    /// is a reason to exit non-zero, not a diagnostic to swallow.
    static func write(_ report: Report, to path: String) throws -> String {
        let text = json(report) + "\n"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return summary(report)
    }

    /// One line for stderr: the answers a reader can check against the file at a glance.
    ///
    /// The no-tty case says so instead of "the read timed out": nothing was asked, and a timeout is a
    /// fact about a terminal that was asked and did not answer.
    static func summary(_ report: Report) -> String {
        guard report.stdinIsATTY else { return "stdin is not a tty: the batch was not written" }
        let caps = report.batch.caps
        let raw = report.batch.reply == nil
            ? "no answer"
            : "\(report.batch.reply?.utf8.count ?? 0) B in \(report.batch.reads) read(s)"
        let sizes = [caps.cell.map { "cell \($0.w)x\($0.h)" }, caps.window.map { "area \($0.w)x\($0.h)" }]
            .compactMap { $0 }.joined(separator: ", ")
        let own = [report.placeholders.map { "U=1 \($0 ? "yes" : "no")" },
                   report.animationFrames.map { "a=f \($0 ? "yes" : "no")" }]
            .compactMap { $0 }.joined(separator: ", ")
        let ms = String(format: "%.1f ms", report.batch.elapsedMs)
        return "\(raw), \(ms), \(sizes.isEmpty ? "no size answer" : sizes), "
            + "\(own.isEmpty ? "no graphics answer" : own), "
            + (caps.terminated ? "DA1 ended the read" : "no DA1: the read timed out")
    }

    /// A named environment variable, or `null` — a missing `TERM_PROGRAM_VERSION` is a fact about the
    /// terminal too (`Terminal.app` sets it; a pty on the far end of `ssh` sets nothing).
    private static func named(_ environment: [String: String], _ key: String) -> Any {
        environment[key].map { $0 as Any } ?? NSNull()
    }

    private static func sizeJSON(_ size: TermCaps.Size?) -> Any {
        size.map { ["w": $0.w, "h": $0.h] } ?? NSNull()
    }

    private static func hexJSON(_ rgb: RGB?) -> Any {
        rgb.map { String(format: "#%06X", $0.hex) } ?? NSNull()
    }
}
