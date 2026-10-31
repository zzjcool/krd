import XCTest
import Darwin
import krdcore

/// The pane's byte discipline, seen from outside the process: **the tty gets the paint and nothing
/// else.**
///
/// WHY this test spawns a process: the invariant is about the bytes that reach the terminal, and
/// there is no in-process way to see them. `Log`'s sink is stderr, and stderr *is* the tty unless
/// a file was configured — so a keypress used to emit `input: key code=12 flags=0\n`
/// there (`handleMouse`/`postKey` log on `dryRun || trace`, and `--wall` passed `dryRun: true`). The
/// `\n` landed on the last row of the pane and scrolled the whole wall, which is why the review saw
/// a broken picture and no test caught it: every existing wall test looks at the canvas, and the
/// canvas was never wrong. Only a pty can answer "what did the terminal receive".
///
/// The same question is asked of the **mirror** (`testABareMirrorPaintsWithoutASingleNewline`): it
/// was the path left out of `paintsThePane`, so the round-trip probe's `krd: rtt … ms` line printed
/// on top of the picture every 2 s. Same invariant, same instrument.
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
        // `--demo` for the same reason the golden wall tests use it: the wall paints **window
        // titles**, which on a developer's machine contain anything at all — a window showing this
        // repository is titled `zzjcool/krd: …`, and that made this assertion fail on the very
        // desktop it was written on while passing on CI. The invariant is about the bytes we emit,
        // so the content has to be fixed.
        child.arguments = ["--wall", "--demo", "--pane", "60x24"]
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

        // 1. Two markers, because the wall paints *before* it starts input (issue #99): `N windows`
        //    is the paint, and the mouse-mode enable is `InputReader.start()` - by the time those
        //    bytes are on the pane the tty is raw (`ISIG` cleared, so `0x1C` is a byte and not
        //    `SIGQUIT`) and no probe can run any more, so the keys below are the reader's and not
        //    the line discipline's (or a probe's: every probe runs before input).
        let painted = pump(master, into: &stream, timeoutMs: 3_000) { bytes in
            let text = String(decoding: bytes, as: UTF8.self)
            return text.contains(" windows") && text.contains("\u{1B}[?1003h")
        }
        let soFar = String(decoding: stream, as: UTF8.self)
        XCTAssertTrue(painted, "no wall paint + input install within 3 s; the pane has \(stream.count) B, tail: "
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
        // The demo model's titles are fixed ("16:9 window", …): if one of them is missing, the
        // hermeticity above is broken and the two assertions below would be measuring nothing.
        XCTAssertTrue(text.contains("16:9 window"), "the wall did not paint the demo model")
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

    /// The other path that owns the pane, and for a long time the only one outside the rule:
    /// `paintsThePane` was a list of flags (`--debug`/`--log`/`--stats-json`/`--wall`) and a plain
    /// `krd` was not in it, so `Log` kept its fallback sink — stderr, which *is* the picture. The
    /// round-trip probe writes one line every ~2 s (`krd: rtt 12.1 ms (CSI 5n round trip)`), so the
    /// mirror painted a line of text onto its own frame, on a loop, and the newline on the last row
    /// scrolled the grid the tiles were placed on.
    ///
    /// `--mock` is the capture source on purpose: the invariant is about *our* bytes, and a real
    /// ScreenCaptureKit capture would ask for a permission no test can grant.
    func testABareMirrorPaintsWithoutASingleNewline() throws {
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
        // The mirror, with the pixel source mocked out (`--pane` keeps the numbers deterministic).
        child.arguments = ["--mock", "--pane", "60x24"]
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

        // A graphics APC says the picture is owned, the mouse-mode enable says the tty is raw — so
        // the `0x1C` below is a byte for the reader, not `SIGQUIT` for the line discipline.
        let painted = pump(master, into: &stream, timeoutMs: 5_000) { bytes in
            let text = String(decoding: bytes, as: UTF8.self)
            return text.contains("\u{1B}_G") && text.contains("\u{1B}[?1003h")
        }
        let soFar = String(decoding: stream, as: UTF8.self)
        XCTAssertTrue(painted, "no mirror frame + input install within 5 s; the pane has \(stream.count) B, tail: "
                      + String(soFar.suffix(300)).debugDescription)
        guard painted else { return }

        // Two probe intervals' worth of silence first: `rtt` is written from the 1 Hz tick, so a
        // single frame is not enough time for the line this test exists to catch.
        _ = pump(master, into: &stream, timeoutMs: 2_500) { _ in false }
        writeAll(master, [0x1C])

        let deadline = Date().addingTimeInterval(5)
        while child.isRunning && Date() < deadline {
            _ = pump(master, into: &stream, timeoutMs: 50) { _ in false }
        }
        guard !child.isRunning else {
            XCTFail("the mirror did not exit within 5 s of Ctrl-\\; the defer kills it")
            return
        }
        _ = pump(master, into: &stream, timeoutMs: 50) { _ in false }
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0,
                       "the mirror did not exit on Ctrl-\\ (status \(child.terminationStatus))")

        XCTAssertFalse(stream.contains(0x0A),
                       "the mirror put a 0x0A on the tty (\(stream.filter { $0 == 0x0A }.count) of them): "
                       + "one newline on the last row scrolls the picture off its own grid")
        let text = String(decoding: stream, as: UTF8.self)
        XCTAssertFalse(text.contains("krd:"),
                       "the mirror wrote a `krd:` diagnostic onto its own pane")

        // The sink itself: `paintsThePane` gives every painting path a file, which is what makes
        // "nothing on the pane" true for the lines this test cannot provoke (the rtt probe needs a
        // terminal that answers `CSI 5n`, and a pty does not).
        let log = NSTemporaryDirectory() + "krd-\(child.processIdentifier).log"
        XCTAssertTrue(FileManager.default.fileExists(atPath: log),
                      "a bare mirror must configure a log file so no diagnostic can reach the pane; "
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
        // `--demo` for the same reason the golden wall tests use it: the wall paints **window
        // titles**, which on a developer's machine contain anything at all — a window showing this
        // repository is titled `zzjcool/krd: …`, and that made this assertion fail on the very
        // desktop it was written on while passing on CI. The invariant is about the bytes we emit,
        // so the content has to be fixed.
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

    /// The pointer shape the **terminal** is asked for, end to end: a hover on the wall comes out as
    /// `ESC ] 22 ; <shape> ST` (#202).
    ///
    /// The canvas tests pin the mapping (a target's *class*: a hand over anything that enters, the
    /// terminal's own shape over the furniture) and the writer tests pin the emission (one sequence,
    /// riding the frame's write). Neither can catch the two being wired up wrongly: a `drawWall` that
    /// forgets `writer.pointerShape`, or a mouse-mode toggle that resets the shape and is not told,
    /// looks exactly like a feature nobody implemented. Only a process with a pointer in it does.
    ///
    /// The cells come from the same layout the child builds (`--pane 60x24`, the demo model's one
    /// display and four windows, the pty's 8x20 cell), so this asserts a *class change* rather than a
    /// cell number: card → bar → card is two writes, and a hover that stays inside one card is none.
    func testThePointerShapeFollowsTheHoverTarget() throws {
        let binary = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("krd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("no krd binary at \(binary.path) — run `swift build` before `swift test`")
            return
        }

        /// `ESC ] 22 ; <name> ST`, in order.
        func shapes(_ bytes: [UInt8]) -> [String] {
            let open = Array("\u{1B}]22;".utf8)
            var out: [String] = [], i = 0
            while i + open.count <= bytes.count {
                guard Array(bytes[i..<(i + open.count)]) == open else { i += 1; continue }
                var j = i + open.count, name = ""
                while j < bytes.count, bytes[j] != 0x1B {
                    name.append(Character(UnicodeScalar(bytes[j])))
                    j += 1
                }
                out.append(name)
                i = j + 1
            }
            return out
        }

        // The demo model's layout, for a pane the test fixes and a cell the pty reports (8x20).
        let layout = WallLayout.make(paneCols: 60, paneRows: 24, displayCount: 1, windowCount: 4,
                                     per: 3, stageStart: 0, cardStart: 0,
                                     stageAspect: 2560.0 / 1600.0, cellAspect: 2.5)
        XCTAssertGreaterThanOrEqual(layout.cards.count, 2, "the demo's 4 windows must fill 2 cards")
        let card0 = layout.cards[0]
        let card1 = layout.cards[1]
        let barCol = layout.barCol

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

        // The paint, then the mouse modes: the second one is the toggle that resets the shape, so
        // hovering before it would be answered with a hand no terminal holds.
        let ready = pump(master, into: &stream, timeoutMs: 5_000) { bytes in
            let text = String(decoding: bytes, as: UTF8.self)
            return text.contains(" windows") && text.contains("\u{1B}[?1003h")
        }
        XCTAssertTrue(ready, "no wall paint + input install within 5 s; tail: "
                      + String(decoding: stream.suffix(300), as: UTF8.self).debugDescription)
        guard ready else { return }
        XCTAssertEqual(shapes(stream), [], "a wall nobody has pointed at asks for no shape")

        /// One SGR mouse *motion* report (button 35 = no button, moving), 1-based cells.
        ///
        /// The hop is reader thread → main queue → paint, so "did it arrive" is polled for rather than
        /// slept through: a loaded machine is a slower machine, not a different behaviour.
        func hover(_ row: Int, _ col: Int, expecting count: Int) {
            let before = stream.count
            writeAll(master, Array("\u{1B}[<35;\(col);\(row)M".utf8))
            let arrived = pump(master, into: &stream, timeoutMs: 2_000) { shapes($0).count >= count }
            XCTAssertTrue(arrived, "hover at \(row),\(col) asked for no shape within 2 s "
                          + "(\(stream.count - before) B arrived): \(shapes(stream))")
        }

        /// A report that must change nothing: settle, then the caller asserts the count did not move.
        func hoverWithoutAsking(_ row: Int, _ col: Int) -> Int {
            let before = stream.count
            writeAll(master, Array("\u{1B}[<35;\(col);\(row)M".utf8))
            _ = pump(master, into: &stream, timeoutMs: 300) { _ in false }
            return stream.count - before
        }

        // Onto a card: the hand.
        hover(card0.row + 1, card0.col + 1, expecting: 1)
        XCTAssertEqual(shapes(stream), ["pointer"],
                       "hovering a card must ask for the hand: \(shapes(stream))")

        // Inside the same card, then onto the next card: same class, so neither asks for anything —
        // and neither re-sends a frame (a frame here is ~9 KB of text).
        let sameClass = hoverWithoutAsking(card0.row + 1, card0.col + 2)
                      + hoverWithoutAsking(card1.row + 1, card1.col + 1)
        XCTAssertEqual(shapes(stream), ["pointer"],
                       "moving inside the card class asked again: \(shapes(stream))")
        XCTAssertLessThan(sameClass, 600, "two hovers in one class cost \(sameClass) B")

        // Out to the bar and back: two class changes, two writes.
        hover(card1.row + 1, barCol, expecting: 2)
        XCTAssertEqual(shapes(stream), ["pointer", "default"],
                       "the furniture is the terminal's own pointer: \(shapes(stream))")
        hover(card0.row + 1, card0.col + 1, expecting: 3)
        XCTAssertEqual(shapes(stream), ["pointer", "default", "pointer"],
                       "card → bar → card is two: \(shapes(stream))")

        // The way out resets it: a pane left holding a hand is a lie the shell inherits.
        writeAll(master, [0x1C])
        let deadline = Date().addingTimeInterval(5)
        while child.isRunning && Date() < deadline {
            _ = pump(master, into: &stream, timeoutMs: 50) { _ in false }
        }
        _ = pump(master, into: &stream, timeoutMs: 100) { _ in false }
        XCTAssertEqual(shapes(stream), ["pointer", "default", "pointer", "default"],
                       "the teardown must give the shape back: \(shapes(stream))")
        let leave = String(decoding: stream, as: UTF8.self)
        if let reset = leave.range(of: "\u{1B}]22;default"),
           let altScreen = leave.range(of: "\u{1B}[?1049l") {
            XCTAssertLessThan(reset.lowerBound, altScreen.lowerBound,
                              "the reset goes out before the alternate screen is left")
        } else {
            XCTFail("no reset, or no `?1049l`, in the teardown: \(leave.suffix(200).debugDescription)")
        }
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
