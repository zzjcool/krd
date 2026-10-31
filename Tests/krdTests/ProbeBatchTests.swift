import XCTest
import Darwin

/// What the fake terminal answers: everything (a normal terminal), or only the `DA1` (one that knows
/// none of the three capabilities — the case the sentinel exists for).
private enum Behaviour { case answersEverything, da1Only }

/// The startup's capability questions are asked in **one** write (issue #197).
///
/// Why this costs a round trip each: over ssh every answer queues behind OpenSSH's keystroke
/// obfuscation, so p50 is 23.5 ms for a question and its answer (`docs/design-ui-v2.zh-CN.md` §2.2 —
/// 20 questions one by one 488 ms, 20 in one write 17.7 ms). `CSI 16t`, `CSI 14t` and `DECRQM 2027`
/// are the same kind of question with the same shape of answer, so they leave in one write and the
/// batch ends on the `DA1` (`CSI ? … c`), which every terminal answers.
///
/// WHY a pty and not a unit test: "one write" is a property of the bytes that reach the terminal, and
/// the only thing that can see those is the other end of the pty. The fake terminal below answers the
/// way a real one does — everything it was just asked, in one write — and counts the **round trips**
/// it had to answer. A round trip is a burst of questions followed by a wait for the answer, which is
/// what a burst is on the wire: two `write(2)`s back to back with a read after them are one round trip
/// and rightly count as one; a write, a wait, another write is two. `WallProcessTests` established the
/// harness: the test bundle sits next to the `krd` binary, and a pty with a real window size is the
/// terminal.
final class ProbeBatchTests: XCTestCase {
    // MARK: - the batch

    /// One burst, four questions, and the answers are actually parsed and used.
    ///
    /// RED before #197: the geometry probe asked two of the four (`CSI 16t` `CSI 14t`) in one write
    /// and there was no `DECRQM` at all, so the assertion on the burst's *content* is what fails —
    /// the burst *count* was already 1, for the pair.
    func testTheCapabilityQuestionsGoOutInOneWrite() throws {
        let run = try spawn(.answersEverything)
        defer { run.stop() }

        XCTAssertTrue(run.terminal.pump(until: { run.terminal.sawInputInstall($0) }, timeoutMs: 10_000),
                      "the wall never installed input; the pane has \(run.terminal.stream.count) B, "
                      + "tail: \(run.terminal.tail)")

        let bursts = run.terminal.capabilityBursts
        XCTAssertEqual(bursts.count, 1,
                       "the capability questions went out in \(bursts.count) writes, not one: "
                       + bursts.map(\.escaped).description)
        guard let batch = bursts.first else { return }
        // The one write, at byte level: every question, and the `DA1` that terminates the read.
        XCTAssertTrue(batch.contains("\u{1B}[16t"), "no `CSI 16 t` in the batch: \(batch.escaped)")
        XCTAssertTrue(batch.contains("\u{1B}[14t"), "no `CSI 14 t` in the batch: \(batch.escaped)")
        XCTAssertTrue(batch.contains("\u{1B}[?2027$p"), "no `DECRQM 2027` in the batch: \(batch.escaped)")
        XCTAssertTrue(batch.contains("\u{1B}[c"), "no `DA1` terminator in the batch: \(batch.escaped)")
        XCTAssertTrue(batch.hasSuffix("\u{1B}[c"),
                      "the `DA1` is not the last thing written, so it cannot terminate the read: "
                      + batch.escaped)

        // Asked once. A second `CSI 16t` anywhere in the stream is a second round trip.
        let pane = String(decoding: run.terminal.stream, as: UTF8.self)
        XCTAssertEqual(pane.occurrences(of: "\u{1B}[16t"), 1,
                       "the cell was asked for \(pane.occurrences(of: "\u{1B}[16t")) times, not once")

        // ...and the batch was believed: both answers were parsed and reached the wall's geometry.
        // Without this, "one write" could be satisfied by a batch nobody can read.
        let log = run.log()
        XCTAssertTrue(log.contains("measured from the terminal (CSI 16t+14t)"),
                      "the batched answer did not reach the wall's geometry; the log says:\n"
                      + log.split(separator: "\n").filter { $0.contains("wall cell") }.joined(separator: "\n"))

        // The `DECRQM 2027` answer from the same write reaches the session too: `?2027h` goes out in
        // the alternate-screen write and the log says the one sentence #193 pinned for it. Without
        // this, the batch could be answering the mode question and dropping the answer on the floor.
        XCTAssertTrue(pane.contains("\u{1B}[?2027h"),
                      "the mode the batch reported (`2`, reset) was not turned on for the session")
        XCTAssertTrue(log.contains("grapheme clustering (2027) was 2"),
                      "the 2027 answer did not reach the session's log line; the log says:\n"
                      + log.split(separator: "\n").filter { $0.contains("2027") }.joined(separator: "\n"))
    }

    /// A terminal that implements none of the three questions still answers the `DA1`, and that answer
    /// has to *end the read* — otherwise the batch waits out its whole timeout on exactly the
    /// terminals it was batched for.
    ///
    /// What is asserted is the clock: the next probe (`U=1`, which cannot join the batch) arrives
    /// milliseconds after the `DA1`, not 500 ms after it. The old code waited for the cell and window
    /// answers, so this measures the timeout it paid there.
    func testDA1EndsTheReadWithoutWaitingOutTheTimeout() throws {
        let run = try spawn(.da1Only)
        defer { run.stop() }

        XCTAssertTrue(run.terminal.pump(until: { run.terminal.sawInputInstall($0) }, timeoutMs: 10_000),
                      "the wall never painted; the pane has \(run.terminal.stream.count) B, "
                      + "tail: \(run.terminal.tail)")
        let bursts = run.terminal.bursts
        guard let first = bursts.firstIndex(where: { $0.capability }),
              let next = bursts.dropFirst(first + 1).first else {
            XCTFail("expected a capability burst and a probe after it; got "
                    + bursts.map(\.text.escaped).description)
            return
        }
        let gap = next.at.timeIntervalSince(bursts[first].at)
        XCTAssertLessThan(gap, 0.4,
                          String(format: "the probe after the DA1 waited %.3f s, i.e. the read ran to its "
                                 + "timeout instead of stopping on the sentinel", gap))
        // A `DA1`-only reply says nothing about the cell: the wall must take the documented fallback,
        // not zeros that look like answers.
        let log = run.log()
        XCTAssertTrue(log.contains("assumed (the terminal did not answer)"),
                      "a DA1-only reply was read as a measurement; the log says:\n"
                      + log.split(separator: "\n").filter { $0.contains("wall cell") }.joined(separator: "\n"))
    }

    // MARK: - the paths that must ask nothing

    /// No tty on stdin, no probe bytes at all — `--bench`, `--selftest` and a pipe (`krd --wall >
    /// file`, the wall under `ssh` without `-t`) all reach this: the batch is written to stdout but
    /// read from stdin, and a terminal that is not there must not be asked. `TermCaps.ask` fails on
    /// its `tcgetattr` *before* writing, so the bytes never leave; `TermGeometry.query` additionally
    /// refuses to ask a pane whose `TIOCGWINSZ` has no width. `i=31;AAAA` and `a=d,d=i,i=31` are the
    /// `U=1` probe's own transmit and delete — the one probe that is not in the batch — so "no bytes"
    /// covers both, and the wall's own image ids (which do reach 31) cannot stand in for them.
    func testAStdinThatIsNotATTYIsAskedNothing() throws {
        let binary = try krdBinary()
        let child = Process()
        child.executableURL = binary
        child.arguments = ["--wall", "--demo", "--pane", "60x24"]
        // A pipe that is never written to and never closed: reading it blocks instead of hitting EOF,
        // which is what a `ssh` without `-t` looks like to the child.
        let input = Pipe()
        let output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = output
        try child.run()
        defer {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            try? output.fileHandleForWriting.close()
            try? input.fileHandleForWriting.close()
        }
        let fd = output.fileHandleForReading.fileDescriptor
        var stream: [UInt8] = []
        let painted = pumpPipe(fd, into: &stream, timeoutMs: 10_000) {
            String(decoding: $0, as: UTF8.self).contains("windows")
        }
        XCTAssertTrue(painted, "the wall never painted onto a pipe; got \(stream.count) B")
        usleep(500_000)                  // any probe would have gone out by now (the batch is 30 bytes)
        _ = pumpPipe(fd, into: &stream, timeoutMs: 50) { _ in false }
        let pane = String(decoding: stream, as: UTF8.self)
        for question in ["\u{1B}[16t", "\u{1B}[14t", "\u{1B}[?2027$p", "\u{1B}[c", "i=31;AAAA", "a=d,d=i,i=31"] {
            XCTAssertFalse(pane.contains(question),
                           "a probe byte reached a pane with no tty on stdin: \"\(question.escaped)\"")
        }
    }

    // MARK: - the process under test

    private struct Run {
        let master: Int32
        let child: Process
        let terminal: FakeTerminal

        /// The `--wall` log file (`Log.configure` names it after the pid), read once it is there.
        func log() -> String {
            let path = NSTemporaryDirectory() + "krd-\(child.processIdentifier).log"
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if let text = try? String(contentsOfFile: path, encoding: .utf8),
                   text.contains("wall cell") {
                    return text
                }
                usleep(20_000)
            }
            return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        }

        func stop() {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            close(master)
        }
    }

    /// The `krd` built next to the test bundle; a missing one fails loudly rather than skipping.
    private func krdBinary() throws -> URL {
        let binary = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("krd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("no krd binary at \(binary.path) — run `swift build` before `swift test`")
            throw NSError(domain: "ProbeBatchTests", code: 1)
        }
        return binary
    }

    /// Read a pipe, polling up to `timeoutMs` for `done` to be satisfied — the pipe twin of
    /// `FakeTerminal.pump`, for the case where the child has no terminal to talk to.
    private func pumpPipe(_ fd: Int32, into stream: inout [UInt8], timeoutMs: Int,
                          until done: ([UInt8]) -> Bool) -> Bool {
        if done(stream) { return true }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var chunk = [UInt8](repeating: 0, count: 8192)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 25) > 0 else {
                if done(stream) { return true }
                continue
            }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return done(stream) }
            stream.append(contentsOf: chunk[0..<n])
            if done(stream) { return true }
        }
        return done(stream)
    }

    /// `--wall --demo --pane 60x24` behind a pty that reports **no** pixel size — the sshd pty, which
    /// is the case that makes krd ask `CSI 16t`/`14t` in the first place (`TermGeometry.read` has no
    /// `ws_xpixel` to fall back on).
    private func spawn(_ behaviour: Behaviour) throws -> Run {
        let binary = try krdBinary()
        let (master, slave) = try openPTY(cols: 60, rows: 24)
        let child = Process()
        child.executableURL = binary
        // `--demo`: the wall paints window titles, and on a developer's machine those are whatever is
        // open (a test that reads titles is not a test). The invariant here is about the probe's bytes.
        child.arguments = ["--wall", "--demo", "--pane", "60x24"]
        let pane = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        child.standardInput = pane
        child.standardOutput = pane
        child.standardError = pane
        try child.run()
        close(slave)                                    // the child holds its own copy now
        return Run(master: master, child: child, terminal: FakeTerminal(master: master, behaviour: behaviour))
    }

    /// A pty whose `ws_xpixel`/`ws_ypixel` are **zero**, i.e. an sshd pty: the pixel size a wall would
    /// otherwise read from `TIOCGWINSZ` is absent, so the terminal has to be asked.
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

/// The other end of the pty: answers what it was asked the way a terminal does — everything it has just
/// read, in one write — and records each burst with the moment it arrived, so "one write here" and "the
/// sentinel ended the read then" are both measurable.
private final class FakeTerminal {
    struct Burst {
        let text: String
        let at: Date
        /// Did this burst ask one of the four capability questions?
        let capability: Bool
    }

    /// `CSI 16 t` (cell), `CSI 14 t` (window), `DECRQM ?2027` (grapheme clustering), `DA1` (identity —
    /// and the terminator, because every terminal answers it).
    private static let cellQuestion = "\u{1B}[16t"
    private static let windowQuestion = "\u{1B}[14t"
    private static let graphemeQuestion = "\u{1B}[?2027$p"
    private static let da1Question = "\u{1B}[c"
    /// The kitty `U=1` probe's placement, by the ids only that probe uses: its answer echoes the
    /// request's parameters (`i=31,p=1;OK`), which is what `placeholderProbeVerdict` matches.
    private static let placeholderQuestion = "i=31,p=1,a=p,U=1"

    private let master: Int32
    private let behaviour: Behaviour
    /// Where the bytes this terminal has not answered yet begin: the start of the burst in flight.
    private var answerCursor = 0
    private var answeredPlaceholder = false

    private(set) var stream: [UInt8] = []
    private(set) var bursts: [Burst] = []

    var capabilityBursts: [String] { bursts.filter(\.capability).map(\.text) }
    var tail: String { String(decoding: stream.suffix(400), as: UTF8.self).escaped }

    init(master: Int32, behaviour: Behaviour) {
        self.master = master
        self.behaviour = behaviour
    }

    /// The wall paints *before* it probes (issue #99), and `?1003h` is `InputReader.start()` — the last
    /// moment a probe may run, because a probe reads stdin and would steal the reader's bytes.
    func sawInputInstall(_ bytes: [UInt8]) -> Bool {
        String(decoding: bytes, as: UTF8.self).contains("\u{1B}[?1003h")
    }

    /// Read the pane, answer every question as it arrives, until `done` or the timeout.
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

    /// Is the unanswered tail a question? Then a real terminal answers it now. The short quiet window is
    /// what makes "one write" the thing being measured rather than the pty's read boundaries: a
    /// terminal answers what has arrived, and krd blocks after its write, so one burst is one quiet
    /// period followed by one answer.
    private func answerIfAsked() {
        let pending = String(decoding: stream[answerCursor...], as: UTF8.self)
        let asksCapability = pending.contains(Self.cellQuestion)
            || pending.contains(Self.windowQuestion)
            || pending.contains(Self.graphemeQuestion)
            || pending.contains(Self.da1Question)
        let asksPlaceholder = pending.contains(Self.placeholderQuestion) && !answeredPlaceholder
        guard asksCapability || asksPlaceholder else { return }

        usleep(20_000)                       // let the rest of the same write land, if the pty split it
        drain()
        let raw = String(decoding: stream[answerCursor...], as: UTF8.self)
        answerCursor = stream.count
        // The wall paints before it probes (issue #99), so a read can hold the frame *and* the batch.
        // The burst is the questions: from the first one asked to the end of what arrived.
        let start = questionStart(in: raw) ?? raw.startIndex
        let burst = String(raw[start...])
        bursts.append(Burst(text: burst, at: Date(), capability: asksCapability))

        var reply = ""
        if asksCapability {
            switch behaviour {
            case .answersEverything:
                if burst.contains(Self.cellQuestion) { reply += "\u{1B}[6;33;17t" }      // 17x33 cell
                if burst.contains(Self.windowQuestion) { reply += "\u{1B}[4;792;1020t" } // 1020x792 pane
                if burst.contains(Self.graphemeQuestion) { reply += "\u{1B}[?2027;2$y" } // recognised, reset
            case .da1Only:
                break                // knows none of the three; still answers the `DA1` below
            }
        }
        if burst.contains(Self.da1Question) { reply += "\u{1B}[?62;22c" }                // DA1
        if asksPlaceholder {
            reply += "\u{1B}_Gi=31,p=1;OK\u{1B}\\"                                      // U=1 accepted
            answeredPlaceholder = true
        }
        guard !reply.isEmpty else { return }
        writeAll(reply)
    }

    /// Everything the child has written since the last read — without waiting. Only used inside
    /// `answerIfAsked`, after the quiet window.
    private func drain() {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 0) > 0 else { return }
            let n = read(master, &chunk, chunk.count)
            if n <= 0 { return }
            stream.append(contentsOf: chunk[0..<n])
        }
    }

    /// Where the first question in `text` begins, so a burst that shares a read with the wall's paint
    /// is still measured as the questions and nothing else.
    private func questionStart(in text: String) -> String.Index? {
        [Self.cellQuestion, Self.windowQuestion, Self.graphemeQuestion, Self.da1Question,
         Self.placeholderQuestion]
            .compactMap { text.range(of: $0)?.lowerBound }
            .min()
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

private extension String {
    /// Bytes in a form a failure message can be read in: escapes spelled out, so "the batch asked two
    /// of the four questions" is visible in the test output.
    var escaped: String {
        var out = ""
        for ch in self {
            switch ch {
            case "\u{1B}": out += "\\e"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        return out
    }

    func occurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
