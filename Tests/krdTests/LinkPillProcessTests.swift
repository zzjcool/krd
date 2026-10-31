import XCTest
import Darwin
import krdcore

/// The pill, seen from outside the process (issue #199): **a slow link that is not slow says so**,
/// and saying it does not cost the wall its idle byte contract.
///
/// WHY this drives a wall through a pty with a fake terminal: the pill's whole condition is a
/// property of the *round trip*, and there is no in-process way to have one. `RTTProbe` is fed by
/// the terminal's own answer to `CSI 5n`, so the only honest instrument is a terminal that answers
/// — and answers the way OpenSSH 10 does with `ObscureKeystrokeTiming` on (`docs/design-ui-v2` §2.2):
/// **most replies on the 18-22 ms batching grid, one of them immediate**. The minimum staying under
/// 2 ms while the median is 20 ms is exactly the signature the design turns into a symptom
/// (`LinkVerdict.held`), and it is the pair of numbers no unit test can invent for itself.
///
/// The wall is the surface because the wall is the mode that needs a probe tick for this at all:
/// `startDiagnostics()` is mirror-only, `--wall` had no `CSI 5n` in it, and a mirror cannot be
/// spawned in a test without Screen Recording. So one run proves both halves of the issue — the tick
/// exists, and the pill it feeds is painted.
///
/// The second half of the test is the byte contract: after the pill is up, an answer that changes no
/// symptom must put **zero** bytes on the pane. The probes themselves are subtracted rather than
/// ignored: they are the only thing an idle wall may still write here, and counting them is what
/// keeps "the wall stayed quiet" from passing because nothing ran at all.
final class LinkPillProcessTests: XCTestCase {
    /// The pill's text (`LinkVerdict.pill`), spelled out here so the test is a second opinion about
    /// what a reader sees and not a call into the string it is checking.
    private let pill = "keys held"
    /// `LinkVerdict.minAnswers`, spelled out for the same reason: the issue's number is frozen, and a
    /// test that reads it back from the code cannot notice it being moved.
    private let minAnswers = 8

    func testAWallOnAHeldLinkSaysSoAndThenPaintsNothing() throws {
        let binary = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("krd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("no krd binary at \(binary.path) — run `swift build` before `swift test`")
            return
        }

        let (master, slave) = try openPTY(cols: 70, rows: 24)
        let child = Process()
        child.executableURL = binary
        // `--pane` fixes the geometry the assertions are about; `--demo` fixes the *content*, so a
        // window titled after whatever this machine has open cannot make the header row differ.
        child.arguments = ["--wall", "--demo", "--pane", "70x24"]
        // The shipped cadence is one probe every 2 s — two ticks of the wall's 1 Hz tick — so eight
        // answers would be a 15 s test. `RTTProbe.setInterval` clamps to 500 ms, which is the
        // fastest honest setting: one probe per tick, eight ticks. The rule under test is unchanged
        // (`minAnswers` is 8 whatever the interval is).
        child.environment = ProcessInfo.processInfo.environment
            .merging(["KRD_RTT_INTERVAL_MS": "500"]) { _, new in new }
        let pane = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        child.standardInput = pane
        child.standardOutput = pane
        child.standardError = pane
        try child.run()
        close(slave)
        let terminal = FakeTerminal(master: master)
        defer {
            terminal.stop()
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }

        // 1. The pill. Eight answers at one per second is ~8 s, and the verdict is decided on the
        //    tick that consumes the eighth, so 20 s is the timeout and not the wait.
        let appeared = pump(terminal, timeoutMs: 20_000) { $0.text.contains(self.pill) }
        let seen = terminal.text
        // The wall's own log file is where the verdict's numbers land, so a failure says *why* the
        // pill did not light — a slow `min` reads as congestion and the pill is right to stay off.
        let log = NSTemporaryDirectory() + "krd-\(child.processIdentifier).log"
        let why = (try? String(contentsOfFile: log, encoding: .utf8))?.suffix(600) ?? ""
        XCTAssertTrue(appeared,
                      "the wall never drew the pill for a link whose minimum is fast and whose "
                      + "median is late (\(terminal.probes) probes, \(terminal.answers) answers, "
                      + "\(seen.utf8.count) B on the pane); its last bytes: "
                      + String(seen.suffix(400)).debugDescription
                      + "; its log: " + String(why))
        guard appeared else { return }

        // 2. …and the answer it drew is a symptom the rule could speak about: the probe ran and was
        //    answered at least `minAnswers` times.
        XCTAssertGreaterThanOrEqual(terminal.answers, minAnswers,
                                    "the pill appeared on fewer than \(minAnswers) answers")

        // 3. The idle contract: an answer that changes no symptom paints nothing. Counted over three
        //    more ticks, with the probes subtracted, so anything left is a repaint nobody asked for —
        //    a picture re-send included, which is why the delta is asserted to be *empty* rather than
        //    merely free of kitty payloads. The 300 ms of slack first is the paint that carried the
        //    pill: it is what this test is about, but it is not part of the quiet window.
        usleep(300_000)
        let before = terminal.allBytes.count
        _ = pump(terminal, timeoutMs: 3_500) { _ in false }
        let grew = String(decoding: terminal.bytes(after: before), as: UTF8.self)
        let probes = grew.components(separatedBy: "\u{1B}[5n").count - 1
        let rest = grew.replacingOccurrences(of: "\u{1B}[5n", with: "")
        XCTAssertGreaterThan(probes, 0, "no probe was sent in 3.5 s: the wall's tick is not running")
        XCTAssertEqual(rest.utf8.count, 0,
                       "an unchanged verdict painted \(rest.utf8.count) B after the pill: "
                       + rest.debugDescription)
    }

    // MARK: - the fake terminal

    /// The other end of the pty: it keeps every byte krd writes, and answers `CSI 5n` the way
    /// OpenSSH 10 with `ObscureKeystrokeTiming` on does — late on an ~20 ms grid, with every fifth
    /// answer immediate, so the *minimum* never climbs.
    ///
    /// The read loop is `poll` with a zero timeout plus a 200 µs sleep rather than a blocking poll:
    /// the immediate answer has to reach krd inside the 2 ms `held` allows its minimum, and a 25 ms
    /// poll timeout (what the wall's other process tests use) would have made every answer look like
    /// congestion — i.e. the negative case, measured by accident.
    private final class FakeTerminal {
        private let master: Int32
        private let lock = NSLock()
        private var stream: [UInt8] = []
        private var sent = 0
        private var answered = 0
        private var running = true
        /// Where the batching grid puts an answer, in milliseconds. The measured p50 is this plus
        /// the pty's own cost; the design's threshold is 15 ms, so there is room.
        private let gridMs = 20

        init(master: Int32) {
            self.master = master
            let t = Thread { [weak self] in self?.loop() }
            t.stackSize = 1 << 17
            t.start()
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: stream, as: UTF8.self)
        }
        var allBytes: [UInt8] { lock.lock(); defer { lock.unlock() }; return stream }
        var probes: Int { lock.lock(); defer { lock.unlock() }; return sent }
        var answers: Int { lock.lock(); defer { lock.unlock() }; return answered }

        func bytes(after count: Int) -> [UInt8] {
            lock.lock(); defer { lock.unlock() }
            return count < stream.count ? Array(stream[count...]) : []
        }

        func stop() { lock.lock(); running = false; lock.unlock() }

        /// Answer the outstanding probe `delayMs` from now.
        private func reply(afterMs delayMs: Int) {
            let fire = { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let live = self.running
                if live { self.answered += 1 }
                self.lock.unlock()
                guard live else { return }
                FakeTerminal.writeAll(self.master, Array("\u{1B}[0n".utf8))
            }
            if delayMs == 0 { fire() } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delayMs),
                                                  execute: fire)
            }
        }

        private func loop() {
            var chunk = [UInt8](repeating: 0, count: 4096)
            var pending: [UInt8] = []
            let probe = Array("\u{1B}[5n".utf8)
            while true {
                lock.lock()
                let live = running
                lock.unlock()
                if !live { return }
                var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, 0) > 0 else { usleep(200); continue }
                let n = read(master, &chunk, chunk.count)
                if n <= 0 { return }
                lock.lock()
                stream.append(contentsOf: chunk[0..<n])
                pending.append(contentsOf: chunk[0..<n])
                lock.unlock()
                // Every complete probe in what was read, in order. Three answers out of eight are
                // immediate, so the *minimum* is robustly fast even on a loaded machine: the rule
                // takes the best of them, and a single descheduled read must not turn a held link
                // into a congested one.
                while let at = FakeTerminal.indexOf(probe, in: pending) {
                    pending.removeFirst(at + probe.count)
                    lock.lock()
                    sent += 1
                    let n = sent
                    lock.unlock()
                    reply(afterMs: (n == 1 || n % 3 == 0) ? 0 : gridMs)
                }
                // Keep only what could still be the start of a probe, so the scan stays cheap.
                if pending.count > probe.count { pending.removeFirst(pending.count - probe.count) }
            }
        }

        private static func indexOf(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
            guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
            for i in 0...(haystack.count - needle.count) where haystack[i] == needle[0] {
                if Array(haystack[i..<(i + needle.count)]) == needle { return i }
            }
            return nil
        }

        static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
            bytes.withUnsafeBufferPointer { buf in
                var off = 0
                while off < buf.count {
                    let n = write(fd, buf.baseAddress! + off, buf.count - off)
                    if n <= 0 { return }
                    off += n
                }
            }
        }
    }

    /// Wait for `done` over the fake terminal's stream: asked about what already arrived first (a
    /// pill drawn before this call still counts), then polled — the reader thread is what collects.
    private func pump(_ terminal: FakeTerminal, timeoutMs: Int,
                      until done: (FakeTerminal) -> Bool) -> Bool {
        if done(terminal) { return true }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            usleep(20_000)
            if done(terminal) { return true }
        }
        return false
    }

    // MARK: - pty plumbing (the shapes the wall's own process tests use)

    private func openPTY(cols: Int, rows: Int) throws -> (master: Int32, slave: Int32) {
        var master: Int32 = 0
        var slave: Int32 = 0
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols),
                           ws_xpixel: UInt16(cols * 8), ws_ypixel: UInt16(rows * 20))
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
