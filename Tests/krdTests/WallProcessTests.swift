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

    /// A wall lands on a pane that may have been a mirror a moment ago: leaving a window mirror
    /// `exec`s the wall in its place, and a kitty placement outlives the process that made it. The
    /// terminal's `2J` clears characters only, so the wall has to drop the images itself - measured
    /// before this test: after a return, the mirror's last picture covered the cards and the captions
    /// drawn under it.
    func testTheWallDropsWhateverImagesThePaneHeld() throws {
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
        child.arguments = ["--wall", "--pane", "60x24"]
        let pane = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        child.standardInput = pane
        child.standardOutput = pane
        child.standardError = pane
        try child.run()
        close(slave)
        defer {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            close(master)
        }
        _ = pump(master, into: &stream, timeoutMs: 3_000) { bytes in
            String(decoding: bytes, as: UTF8.self).contains(" windows")
        }
        writeAll(master, [0x1C])
        let deadline = Date().addingTimeInterval(5)
        while child.isRunning && Date() < deadline {
            _ = pump(master, into: &stream, timeoutMs: 50) { _ in false }
        }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }

        // `a=d,d=a` is "drop every image this terminal holds"; kitty spells it as an APC.
        let clear = Array("\u{1B}_Ga=d,d=a\u{1B}\\".utf8)
        let session = Array("\u{1B}[?1049h".utf8)
        guard let clearAt = stream.firstRange(of: clear) else {
            XCTFail("the wall never deleted the pane's images (\(stream.count) B)")
            return
        }
        guard let sessionAt = stream.firstRange(of: session) else {
            XCTFail("the wall never entered the alternate screen")
            return
        }
        XCTAssertLessThan(sessionAt.lowerBound, clearAt.lowerBound,
                          "the images must be dropped *after* the session starts, or the terminal "
                          + "may still be on the main screen when the delete arrives")
    }

    /// A mirror on its way back must *leave* the alternate screen before the wall takes it.
    ///
    /// WHY: the mirror's tiles are kitty placements inside the alternate screen it drew in. A
    /// terminal may keep pictures keyed to that screen and keep painting them after the wall's
    /// `a=d,d=a` has been answered — measured in Rex: after `[ - ]` the shelf painted correctly and
    /// the mirror's last picture still floated on top of the cards, for good. Leaving the alternate
    /// screen (which the returning mirror can do, since the exec happens after it) tears down the
    /// screen the pictures were attached to; the wall's `beginSession()` then builds a new one. The
    /// test watches the bytes, because that is the only place the ordering exists.
    func testAReturningMirrorLeavesTheAlternateScreenBeforeTheWallTakesIt() throws {
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
        // A mirror that knows where it came from: the `[ - ]` button and `Ctrl-\` both end here.
        // `--cell` because a pty reports no pixel size, and the query path would spend the test's
        // first seconds waiting for a reply that never comes.
        child.arguments = ["--mirror", "--wall-at", "0:0", "--pane", "60x24", "--cell", "8x20"]
        let pane = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        child.standardInput = pane
        child.standardOutput = pane
        child.standardError = pane
        try child.run()
        close(slave)
        defer {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            close(master)
        }

        // The mirror owns the alternate screen before the return can be tested. Screen Recording may
        // be denied inside a test bundle; that path exits as a mirror too (`--said`), so the shape
        // this test is about does not depend on a frame ever arriving.
        guard pump(master, into: &stream, timeoutMs: 8_000, until: { bytes in
            bytes.firstRange(of: Array("\u{1B}[?1049h".utf8)) != nil
        }) else {
            XCTFail("the mirror never entered the alternate screen (\(stream.count) B): "
                    + String(decoding: stream, as: UTF8.self).debugDescription)
            return
        }
        // A mirror whose capture cannot start hands the pane back at once (that is the fast-fail
        // path), so the leave may already be in the stream: pressing Ctrl-\\ then would quit the
        // *wall* instead and test nothing. Only press when the mirror still owns the pane.
        let leftEarly = stream.firstRange(of: Array("\u{1B}[?1049l".utf8)) != nil
        if !leftEarly { writeAll(master, [0x1C]) }
        let enter = Array("\u{1B}[?1049h".utf8)
        let clear = Array("\u{1B}_Ga=d,d=a\u{1B}\\".utf8)
        // Wait for the *whole* return: the wall's fresh screen, the image delete, and text on it.
        // Breaking on the screen switch alone would read the bytes before the wall wrote them.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            _ = pump(master, into: &stream, timeoutMs: 50) { _ in false }
            guard let back = stream.lastRange(of: enter), let left = stream.lastRange(of: Array("\u{1B}[?1049l".utf8)),
                  left.lowerBound < back.lowerBound else { continue }
            let since = stream[back.lowerBound...]
            if since.firstRange(of: clear) != nil,
               String(decoding: since, as: UTF8.self).contains(" windows") { break }
        }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }

        let leave = Array("\u{1B}[?1049l".utf8)
        guard let left = stream.lastRange(of: leave),
              let back = stream.lastRange(of: enter), left.lowerBound < back.lowerBound else {
            XCTFail("the mirror never left the alternate screen before the wall re-entered it")
            return
        }
        guard let cleared = stream[back.lowerBound...].firstRange(of: clear) else {
            XCTFail("the returning wall did not delete the pane's images")
            return
        }
        XCTAssertLessThan(back.lowerBound, cleared.lowerBound)
        // The wall's own screen must not carry the mirror's frames: the tiles belong before the
        // leave, and the panels after it are the wall's (ids 5000+/9000+, never the mirror's).
    }

    /// A mirror handed over from the wall must draw its top bar, and `--mock` is how that is tested
    /// without a grant: the mock source replaces the pixels, nothing else.
    ///
    /// WHY this exists: `applyLayout` laid the chrome out only `if chromeEnabled` (the `--dev` layer)
    /// instead of `if chromeAvailable` (either layer), so a handed-over mirror — which runs `--bar`
    /// with no `--dev` — never got a `chromeGeometry`, `drawChrome` bailed on it, and the bar with
    /// the `[ - ]` button was simply absent. Nothing failed: the picture was correct and the way back
    /// was gone. The merge of #76 is where the gate flipped.
    func testAMockMirrorDrawsItsBar() throws {
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
        // `--wall-at` is the whole switch: it is what a mirror handed over by the wall carries, and
        // it is what turns the bar on by default (`barEnabled`).
        child.arguments = ["--mock", "--wall-at", "0:0", "--pane", "60x24", "--cell", "8x20"]
        let pane = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        child.standardInput = pane
        child.standardOutput = pane
        child.standardError = pane
        try child.run()
        close(slave)
        defer {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            close(master)
        }

        let bar = pump(master, into: &stream, timeoutMs: 5_000) { bytes in
            String(decoding: bytes, as: UTF8.self).contains("[ - ]")
        }
        XCTAssertTrue(bar, "the mirror drew no bar; the pane has \(stream.count) B, tail: "
                      + String(decoding: stream.suffix(400), as: UTF8.self).debugDescription)
        // The button is the way back, and `Ctrl-\\` is the same path (`shutdown`): with `--wall-at`
        // the process does not exit, it execs the wall, so the marker is the wall's own header and
        // not the child's exit status.
        let before = stream.count
        writeAll(master, [0x1C])
        let handedBack = pump(master, into: &stream, timeoutMs: 8_000) { bytes in
            String(decoding: bytes[before...], as: UTF8.self).contains(" windows · ")
        }
        XCTAssertTrue(handedBack, "Ctrl-\\ did not hand the pane back to the wall; tail: "
                      + String(decoding: stream.suffix(300), as: UTF8.self).debugDescription)
    }

    // MARK: pty plumbing

    /// A pty with a real window size, already raw on our side: the child sets its own termios when
    /// input starts, but the pty must not echo or cook what the test writes before/after that.
    ///
    /// The pixel size is real (`8x20` per cell) and not zero: a zero one sends krd down the
    /// `CSI 16t` query path, where it waits for a reply this harness will never write, and every
    /// test that starts a session would spend its first seconds there.
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
