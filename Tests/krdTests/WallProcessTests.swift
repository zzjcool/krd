import XCTest
import Darwin

/// The wall's byte discipline, seen from outside the process: **the tty gets the paint and nothing
/// else.**
///
/// WHY this test spawns a process: the invariant is about the bytes that reach the terminal, and
/// there is no in-process way to see them. `Log`'s sink is stderr, and stderr *is* the tty unless
/// `--debug`/`--log` configured a file — so a keypress used to emit `input: key code=12 flags=0\n`
/// there (`handleMouse`/`postKey` log on `dryRun || trace`, and `--wall` passed `dryRun: true`). The
/// `\n` landed on the last row of the pane and scrolled the whole wall, which is why the review saw
/// a broken picture and no test caught it: every existing wall test looks at the canvas, and the
/// canvas was never wrong. Only a pty can answer "what did the terminal receive".
///
/// The run is one keystroke of each kind: `q` (a printable key, i.e. `.text` → `postUnicode`) and
/// then `Ctrl-\` (0x1C → quit). Whatever the wall prints for them on the pane is a bug.
final class WallProcessTests: XCTestCase {
    func testABareWallPaintsWithoutASingleNewline() throws {
        // The test bundle sits in `.build/debug`, next to the executable it is testing. A missing
        // binary fails loudly: a silently skipped test is worse than a failing one, because this is
        // the only test that can catch a diagnostic escaping onto the pane.
        let binary = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("krd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("no krd binary at \(binary.path) — run `swift build` before `swift test`")
            return
        }

        let (master, slave) = try openPTY(cols: 60, rows: 24)
        var stream: [UInt8] = []
        let child = Process()
        child.executableURL = binary
        // `--pane` keeps the numbers the golden tests use, so the paint is the 60x24 wall.
        child.arguments = ["--wall", "--pane", "60x24"]
        // All three descriptors are the pty: that is the whole point — the child's stderr is its
        // pane, and the wall draws on the same bytes.
        let pane = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        child.standardInput = pane
        child.standardOutput = pane
        child.standardError = pane
        try child.run()
        close(slave)                                    // the child holds its own copy now
        defer {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            close(master)
        }

        // 1. The header's `N windows` is the marker: it exists only once `runWall()` reached
        //    `refreshWall`, i.e. after `startInput()` (the reader has the tty in raw mode by then),
        //    so the keys below are the reader's and not the line discipline's.
        let painted = pump(master, into: &stream, timeoutMs: 3_000) { bytes in
            String(decoding: bytes, as: UTF8.self).contains(" windows")
        }
        let soFar = String(decoding: stream, as: UTF8.self)
        XCTAssertTrue(painted, "no wall paint within 3 s; the pane has \(stream.count) B, tail: "
                      + String(soFar.suffix(300)).debugDescription)
        guard painted else { return }

        // 2. A printable key, then the quit chord. `q` is the case that used to reach the tty: it
        //    arrives as `.text` (never through `onChromeKey`), so only `forward:` keeps it local.
        writeAll(master, Array("q".utf8))
        usleep(300_000)
        writeAll(master, [0x1C])

        // 3. Drain until the child exits (5 s), then read what is left in the pty. A child that does
        //    not exit must fail the test, not hang it (`waitUntilExit()` would block forever).
        let deadline = Date().addingTimeInterval(5)
        while child.isRunning && Date() < deadline {
            _ = pump(master, into: &stream, timeoutMs: 50) { _ in false }
        }
        guard !child.isRunning else {
            XCTFail("the wall did not exit within 5 s of Ctrl-\\; the defer kills it")
            return
        }
        _ = pump(master, into: &stream, timeoutMs: 50) { _ in false }
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0,
                       "the wall did not exit on Ctrl-\\ (status \(child.terminationStatus))")

        // 4. The invariant. A `\n` anywhere scrolls the grid the wall is positioned on, so one byte
        //    is the difference between a wall and a shredded one.
        XCTAssertFalse(stream.contains(0x0A),
                       "the wall put a 0x0A on the tty (\(stream.filter { $0 == 0x0A }.count) of them)")
        let text = String(decoding: stream, as: UTF8.self)
        XCTAssertFalse(text.contains("input:"),
                       "the wall logged reader diagnostics onto its own pane")
        XCTAssertFalse(text.contains("krd:"),
                       "the wall wrote a `krd:` diagnostic onto its own pane")

        // The other half of the sink (contract §2D item 11): in wall mode the diagnostics have a
        // file to go to, which is what makes "nothing on the pane" true even for the lines this
        // test cannot provoke. Without it, `Log` falls back to stderr, i.e. to the wall.
        let log = NSTemporaryDirectory() + "krd-\(child.processIdentifier).log"
        XCTAssertTrue(FileManager.default.fileExists(atPath: log),
                      "--wall must configure a log file so no diagnostic can reach the pane; "
                      + "expected \(log)")
    }

    // MARK: pty plumbing

    /// A pty with a real window size, already raw on our side: the child sets its own termios when
    /// input starts, but the pty must not echo or cook what the test writes before/after that.
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

    /// Read what the pty has, polling up to `timeoutMs` for it to arrive. Returns whether `done` is
    /// satisfied (it is also checked against what already arrived), and never throws: a pty whose
    /// other end is gone (the child exited) simply stops delivering.
    private func pump(_ master: Int32, into stream: inout [UInt8], timeoutMs: Int32,
                      until done: ([UInt8]) -> Bool) -> Bool {
        if done(stream) { return true }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var chunk = [UInt8](repeating: 0, count: 8192)
        while Date() < deadline {
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 25)
            if ready > 0 {
                let n = read(master, &chunk, chunk.count)
                if n <= 0 { return done(stream) }
                stream.append(contentsOf: chunk[0..<n])
                if done(stream) { return true }
            }
        }
        return done(stream)
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
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
