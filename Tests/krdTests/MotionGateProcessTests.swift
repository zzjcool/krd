import XCTest
import Darwin
import Foundation

/// Issue #203, asked from outside the process: **no motion reports while nobody can see them.**
///
/// WHY a pty: the mode set is written straight to fd 1 by static helpers
/// (`ScreenWriter.writeInputModes`, and now the one `?1003h`/`?1003l` a focus change costs), so no
/// in-process seam can answer "what did the pane receive". Same instrument as `WallProcessTests`,
/// and the same two spawns: `--mirror --mock` (a real capture asks for a TCC grant no test can
/// give) and `--wall --demo` (a wall paints window titles, which on any developer machine contain
/// anything at all, so the wall's content has to be fixed).
///
/// Every count below starts **after** the enable run, not at byte 0: `beginSession`'s heal resets
/// the whole ownership list *before* the session enables anything (`?1016l ?1006l ?1002l ?1003l`,
/// PROTOCOL §1), so a `?1003l` count over the whole stream is 1 on a wall that never gave the mode
/// back at all. The marker is the enable run itself — the last thing krd writes before the session
/// it is measuring.
///
/// WHAT it asserts, and this is the whole of #203:
///
/// 1. the mirror starts focused, so the enable is the **whole** list, in one write, 1003 first:
///    `?1003h ?1002h ?1006h ?1016h` (+ `?1004h`, the focus reports this test then speaks);
/// 2. focus-out (`CSI O`) costs exactly **one** `?1003l` — the live set becomes `1002 1006 1016`,
///    because a hover while nobody is looking at the pane is invisible and a click still arrives
///    as a button event under `?1002`;
/// 3. a *second* focus-out writes nothing (the state did not change — the same rule the picture
///    rate follows in `noteFocus`), and a focus-in costs exactly one `?1003h`, once;
/// 4. the teardown still hands `?1003` back exactly once after a focus round trip — the reset list
///    is the whole ownership list, not the focus-filtered enable list, or a pane left unfocused
///    would keep reporting motion for whatever program gets it next (#134's bug class);
/// 5. the wall is **exempt**: it never arms `?1004` (so it never learns about focus), a `CSI O` it
///    should never see changes nothing on the wire, and its teardown is the only `?1003l`.
///
/// The mirror half is the red test of this issue: on the base the full list goes out and stays out,
/// so (2) fails with `?1003` still on.
final class MotionGateProcessTests: XCTestCase {

    /// The enable list is one write, so these four escapes are adjacent on the wire. Its position
    /// is the boundary every count below is relative to (see the type comment).
    private let enableRun = "\u{1B}[?1003h\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?1016h"

    // MARK: - the mirror

    func testTheMirrorGivesMotionReportsBackWhileThePaneIsUnfocused() throws {
        let binary = try krdBinary()
        let (master, slave) = try openPTY(cols: 60, rows: 24)
        var stream: [UInt8] = []
        let child = Process()
        child.executableURL = binary
        child.arguments = ["--mirror", "--mock", "--pane", "60x24"]
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

        // 1. The first sequence: focused mirror, the whole list, one write.
        let started = pump(master, into: &stream, timeoutMs: 5_000) { bytes in
            self.text(bytes).contains(self.enableRun)
        }
        XCTAssertTrue(started, """
            the focused mirror never sent the whole enable list in one write \
            (`?1003h?1002h?1006h?1016h`); the pane has \(stream.count) B, tail: \
            \(text(stream).suffix(400).debugDescription)
            """)
        guard started else { return }
        XCTAssertEqual(count(of: "\u{1B}[?1004h", in: text(stream)), 1,
                       "the mirror is the session that arms focus reporting; without ?1004h this "
                       + "test's CSI O / CSI I would travel a path a real terminal never uses")

        // 2. Focus-out. `CSI O` is the report `?1004` buys, and the only thing that tells krd
        //    nobody is looking at the pane.
        writeAll(master, Array("\u{1B}[O".utf8))
        let lost = pump(master, into: &stream, timeoutMs: 3_000) { bytes in
            self.modeStates(in: self.text(bytes))[1003] == false
        }
        XCTAssertTrue(lost, """
            the mirror kept `?1003` on after the terminal reported focus-out. While the pane is \
            unfocused a motion report can be seen by nobody: it is upstream traffic the terminal \
            sends at 60–120 Hz, for an event the mirrored desktop does not act on (a click still \
            arrives as a button event under `?1002`). Expected exactly one `?1003l`; the last \
            1003 event in the stream is \
            \(String(describing: modeStates(in: text(stream))[1003])).
            """)
        let afterLosing = modeStates(in: text(stream))
        XCTAssertEqual(afterLosing[1003], false, "?1003 must be off while the pane is unfocused")
        XCTAssertEqual(afterLosing[1002], true,
                       "?1002 (button press/drag/release) is not focus-gated: a click that reaches "
                       + "an unfocused terminal is still a button event")
        XCTAssertEqual(afterLosing[1006], true, "?1006 (SGR encoding) is not focus-gated")
        XCTAssertEqual(afterLosing[1016], true,
                       "?1016 (SGR pixels) is not focus-gated: a drag while unfocused still has to "
                       + "land in pixels")
        XCTAssertEqual(count(of: "\u{1B}[?1003l", in: after(enable: text(stream))), 1, """
            a focus change costs exactly one escape: one `?1003l`, not a pair and not the whole \
            reset list (that would take the button and wheel modes away from an unfocused pane \
            too, which is a regression of the mouse, not a saving).
            """)

        // 3a. Focus-out twice is one escape: nothing to say when the state did not change.
        writeAll(master, Array("\u{1B}[O".utf8))
        _ = pump(master, into: &stream, timeoutMs: 700) { _ in false }
        XCTAssertEqual(count(of: "\u{1B}[?1003l", in: after(enable: text(stream))), 1,
                       "a repeated focus-out wrote a second ?1003l; the state did not change")

        // 3b. Focus-in: one `?1003h`, and the pane reports motion again.
        writeAll(master, Array("\u{1B}[I".utf8))
        let regained = pump(master, into: &stream, timeoutMs: 3_000) { bytes in
            self.count(of: "\u{1B}[?1003h", in: self.after(enable: self.text(bytes))) == 1
        }
        XCTAssertTrue(regained, """
            the mirror did not take `?1003` back when the terminal reported focus-in, so a reader \
            who comes back finds a pointer that no longer follows the chrome (#200's hover). \
            Expected a `?1003h` after the focus-out; the stream has \
            \(count(of: "\u{1B}[?1003h", in: after(enable: text(stream)))) after the enable.
            """)
        XCTAssertEqual(modeStates(in: text(stream))[1003], true, "?1003 must be back on when focused")
        XCTAssertEqual(count(of: "\u{1B}[?1003h", in: after(enable: text(stream))), 1,
                       "a focus change costs exactly one escape: one `?1003h`")

        // 3c. … and focus-in twice is one escape, for the same reason as 3a.
        writeAll(master, Array("\u{1B}[I".utf8))
        _ = pump(master, into: &stream, timeoutMs: 700) { _ in false }
        XCTAssertEqual(count(of: "\u{1B}[?1003h", in: after(enable: text(stream))), 1,
                       "a repeated focus-in wrote a second ?1003h; the state did not change")

        // 4. Quit and check the teardown over the whole session: after one focus-out and one
        //    focus-in there are exactly two `?1003l` — the focus-out's and the teardown's. The
        //    reset list is the whole ownership list, unfiltered by the focus state, which is what
        //    lets a session that ends unfocused clean up after itself.
        writeAll(master, [0x1C])
        let deadline = Date().addingTimeInterval(5)
        while child.isRunning && Date() < deadline {
            _ = pump(master, into: &stream, timeoutMs: 50) { _ in false }
        }
        XCTAssertFalse(child.isRunning, "the mirror did not exit within 5 s of Ctrl-\\; the defer kills it")
        if !child.isRunning {
            _ = pump(master, into: &stream, timeoutMs: 50) { _ in false }
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 0,
                           "the mirror did not exit on Ctrl-\\ (status \(child.terminationStatus))")
        }
        XCTAssertEqual(count(of: "\u{1B}[?1003l", in: after(enable: text(stream))), 2, """
            the teardown must reset `?1003` exactly once after one focus-out and one focus-in \
            (the focus-out's `?1003l` is the other one). A reset list filtered by the *current* \
            focus state is the #134 bug again: the pane keeps reporting motion for the shell.
            """)
        let final = modeStates(in: text(stream))
        for mode in [1003, 1002, 1006, 1016, 1004] {
            XCTAssertEqual(final[mode], false, "?\(mode) is still on in the pane after the teardown")
        }
    }

    // MARK: - the wall

    /// The wall is the mode with the most to hover and it never arms `?1004` (`focusReporting` is
    /// `!noInput && !wall`), so it can never learn that it lost focus — and it must not: a wall
    /// repaints its hover the moment the pointer moves, and the pointer does not stop moving because
    /// another window took the keyboard. `?1003` there is unconditional, and a `CSI O` a real
    /// terminal would never send it must move nothing on the wire.
    func testTheWallKeepsMotionReportsWhateverTheFocus() throws {
        let binary = try krdBinary()
        let (master, slave) = try openPTY(cols: 60, rows: 24)
        var stream: [UInt8] = []
        let child = Process()
        child.executableURL = binary
        child.arguments = ["--wall", "--demo", "--pane", "60x24"]
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

        let started = pump(master, into: &stream, timeoutMs: 5_000) { bytes in
            let text = self.text(bytes)
            return text.contains(" windows") && text.contains(self.enableRun)
        }
        XCTAssertTrue(started, """
            the wall did not paint + install the whole mouse-mode list within 5 s; the pane has \
            \(stream.count) B, tail: \(text(stream).suffix(400).debugDescription)
            """)
        guard started else { return }

        XCTAssertEqual(count(of: "\u{1B}[?1004", in: text(stream)), 0,
                       "the wall armed focus reporting: it has no reader to spend `CSI I`/`CSI O` "
                       + "on, and ?1003 must not become conditional through a mode it never asked for")

        // A focus report a real terminal cannot send here: it must be inert.
        writeAll(master, Array("\u{1B}[O".utf8))
        _ = pump(master, into: &stream, timeoutMs: 800) { _ in false }
        XCTAssertEqual(count(of: "\u{1B}[?1003l", in: after(enable: text(stream))), 0, """
            the wall gave `?1003` back on a focus report. The wall is exempt (#203): it never arms \
            `?1004`, it answers the pointer everywhere, and its hover is the one thing in krd that \
            repaints *on the move* — taking motion reports away from it is the regression of #200.
            """)
        XCTAssertEqual(modeStates(in: text(stream))[1003], true,
                       "the wall keeps ?1003 unconditionally")

        writeAll(master, Array("\u{1B}[I".utf8))
        _ = pump(master, into: &stream, timeoutMs: 800) { _ in false }
        XCTAssertEqual(count(of: "\u{1B}[?1003h", in: after(enable: text(stream))), 0,
                       "a focus-in the wall cannot use wrote a second ?1003h")

        // … and it still leaves on the one key it owes the reader.
        writeAll(master, [0x1C])
        let deadline = Date().addingTimeInterval(5)
        while child.isRunning && Date() < deadline {
            _ = pump(master, into: &stream, timeoutMs: 50) { _ in false }
        }
        XCTAssertFalse(child.isRunning, "the wall did not exit within 5 s of Ctrl-\\; the defer kills it")
        if !child.isRunning {
            _ = pump(master, into: &stream, timeoutMs: 50) { _ in false }
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 0,
                           "the wall did not exit on Ctrl-\\ (status \(child.terminationStatus))")
        }
        XCTAssertEqual(count(of: "\u{1B}[?1003l", in: after(enable: text(stream))), 1,
                       "the wall's teardown resets ?1003 (and only the teardown does)")
    }

    // MARK: - reading the stream

    private func text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// The part of the stream that comes after the enable run: what a focus change, a repeated
    /// report and the teardown added to it. The heal's resets (PROTOCOL §1) are before this.
    private func after(enable whole: String) -> String {
        guard let r = whole.range(of: enableRun) else { return "" }
        return String(whole[r.upperBound...])
    }

    /// `CSI ? <n> h|l` in order, last event wins: the state the *terminal* would be in. h is on,
    /// l is off — no polarity gymnastics, unlike the cursor mode `SessionTeardownTests` also tracks.
    private func modeStates(in text: String) -> [Int: Bool] {
        let chars = Array(text)
        var state: [Int: Bool] = [:]
        var i = 0
        while i < chars.count {
            guard chars[i] == "\u{1B}", i + 3 < chars.count,
                  chars[i + 1] == "[", chars[i + 2] == "?" else { i += 1; continue }
            var j = i + 3
            var digits = ""
            while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
            guard let mode = Int(digits), j < chars.count,
                  chars[j] == "h" || chars[j] == "l" else { i += 1; continue }
            state[mode] = chars[j] == "h"
            i = j + 1
        }
        return state
    }

    /// How many times a byte sequence occurs. Counted on the decoded string: every byte krd puts in
    /// a pane is UTF-8-decodable (escape sequences, base64 payloads, the bar's glyphs), and the
    /// needles here are escapes.
    private func count(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - plumbing (same shape as WallProcessTests, per-target by design)

    private func krdBinary() throws -> URL {
        // The test bundle sits in `.build/debug`, next to the executable it is testing. A missing
        // binary fails loudly: a silently skipped test is worse than a failing one.
        let binary = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("krd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw NSError(domain: "MotionGateProcessTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "no krd binary at \(binary.path) — run `swift build` "
                    + "before `swift test`"])
        }
        return binary
    }

    /// A pty with a real window size, already raw on our side: the child sets its own termios when
    /// input starts, but the pty must not echo or cook what the test writes before/after that. The
    /// pixel size is real (`8x20` per cell) and not zero: a zero one sends krd down the `CSI 16t`
    /// query path, where it waits for a reply this harness will never write.
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
