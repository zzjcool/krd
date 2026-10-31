import XCTest
@testable import krd
@testable import krdcore

/// The `--dev` chord, driven through the **product's own path** (#115).
///
/// The report was "`Ctrl-\` then `s`/`d`/`f`/`l`/`?`/`q` are typed into the remote desktop, and no
/// panel opens", and the cause was a hand-off: `onChromeKey` was consulted from exactly one place,
/// `InputReader.handleControl`, which only the parser's `.control(byte)` event reaches — so every
/// documented chord key, all of them *printable*, was posted to the mirrored Mac instead. A parser
/// test cannot see that (the parse was correct); a `Chrome` test cannot see it either (the table was
/// correct). These tests start where a keystroke starts and end at what the reader did with it:
///
///     InputReader.ingest  →  InputParser  →  InputReader.apply  →  Desk.chromeKey
///
/// `ingest` is one `read(2)`'s worth of bytes — the same function `loop()` calls — and the chrome is
/// the real `Desk.chromeKey` with the real `chromeState`, wired exactly as `Desk.startInput()` wires
/// it (`startInput` itself needs a tty, which a test process does not have). "Not forwarded" is read
/// off `Log`, where every injection is recorded by `postKey`/`postUnicode` under `--debug` — the same
/// `input:` lines the issue's own transcript was taken from.
final class DevChordTests: XCTestCase {
    /// `kVK_ANSI_S` — what `s` presses on the remote, i.e. the character that must not arrive.
    private let kVK_S: CGKeyCode = 1
    /// `kVK_ANSI_Q` — the chord's exit key.
    private let kVK_Q: CGKeyCode = 12

    override func setUp() {
        super.setUp()
        // Every `postKey`/`postUnicode` writes an `input:` line; without a destination that is the
        // test's stderr, which is not where a suite should put a keystroke log. The ring
        // (`Log.recentLines`) is what the assertions read, and it is fed whatever the handle is.
        Log.configure(explicitPath: NSTemporaryDirectory() + "krd-chord-\(getpid()).log",
                      wantsLogging: true)
    }

    // MARK: fixture

    /// A `--dev --mock` desk and a reader wired the way `Desk.startInput()` wires it, with the
    /// injection *logged but not posted*: `dryRun` is the "parse everything, inject nothing, say what
    /// it would have injected" half of the reader, so an attempt to type into the remote leaves a
    /// trace here instead of a keystroke in whatever app has focus.
    private func makeDev() -> (desk: Desk, reader: InputReader) {
        var options = Options()
        options.wall = false        // `Options` defaults to the wall; this is the mirror
        options.dev = true          // `--dev`: the status line and the panels
        options.mock = true
        let desk = Desk(options: options)
        desk.writer.sink = { _ in }         // there is no terminal here

        let reader = InputReader(viewport: { Viewport(pixelWidth: 320, pixelHeight: 240, cols: 40,
                                                      rows: 15,
                                                      sourceRect: CGRect(x: 0, y: 0, width: 320,
                                                                         height: 240)) },
                                 dryRun: true, forward: true) {}
        reader.trace = true
        reader.onChromeKey = { [desk] byte in desk.chromeKey(byte) }
        reader.chromePrefixArmed = { [desk] in desk.chromeState.prefix }
        return (desk, reader)
    }

    /// One key press as the terminal sends it: `[0x1c]` is `Ctrl-\`, `"s"` is the byte `s`.
    private func press(_ reader: InputReader, _ bytes: [UInt8]) {
        reader.ingest(bytes[...])
    }

    /// The `input:` lines the reader appended while running `body`. Every line is a keystroke that
    /// went to the mirrored Mac, so "the chord was not forwarded" is `added == []`.
    private func inputLines(while body: () -> Void) -> [String] {
        let before = Log.recentLines.count
        body()
        let after = Log.recentLines
        let added = after.count > before ? Array(after.dropFirst(before)) : []
        return added.filter { $0.hasPrefix("input: ") }
    }

    // MARK: the chord opens the panel and the letter never reaches the desktop

    func testTheChordOpensEachPanelAndTheChordKeyIsNeverForwarded() {
        let panels: [(key: String, panel: ChromePanel)] = [
            ("s", .stats), ("d", .devices), ("f", .settings), ("l", .log),
            ("?", .help), ("h", .help),
        ]
        for (key, expected) in panels {
            let (desk, reader) = makeDev()
            XCTAssertNil(desk.chromeState.panel, "\(key): nothing is open to begin with")

            let forwarded = inputLines {
                press(reader, [0x1C])
                XCTAssertTrue(desk.chromeState.prefix, "\(key): Ctrl-\\ arms the prefix")
                press(reader, Array(key.utf8))
            }
            XCTAssertEqual(desk.chromeState.panel, expected, "^\\(key) must open \(expected.rawValue)")
            XCTAssertFalse(desk.chromeState.prefix, "\(key): the chord is consumed, not left armed")
            XCTAssertEqual(forwarded, [], "\(key): the chord key reached the mirrored Mac")
        }
    }

    /// The report's exact pair, byte for byte: `input: raw 1 bytes: 1c`, then `73`, then nothing.
    /// The `s` used to be the `input: key code=1 flags=0` line in the issue's trace.
    func testTheStatsChordLeavesNoKeystrokeBehind() {
        let (desk, reader) = makeDev()
        let forwarded = inputLines {
            press(reader, [0x1C])
            press(reader, [0x73])       // `s`
        }
        XCTAssertEqual(desk.chromeState.panel, .stats)
        XCTAssertEqual(forwarded, [])
        XCTAssertFalse(forwarded.contains { $0.contains("key code=\(kVK_S)") },
                       "`s` is the `kVK_ANSI_S` press the issue reproduced")
    }

    /// `Ctrl-\` and the key after it frequently arrive in **one** read — the issue's own transcript
    /// has `input: raw 2 bytes: 1c 71` — and then the prefix is armed mid-chunk, after the parser has
    /// already decoded the second key. Same answer: the chrome's, not the desktop's.
    func testAChordThatArrivesInOneReadIsStillTheChromes() {
        let (desk, reader) = makeDev()
        let forwarded = inputLines { press(reader, [0x1C, 0x73]) }     // Ctrl-\ + s together
        XCTAssertEqual(desk.chromeState.panel, .stats)
        XCTAssertEqual(forwarded, [])
    }

    /// A terminal that took the kitty handshake reports `s` as `CSI 115;1u`, not as the byte `0x73`.
    /// The chord is a rule about *keys*, so it must not depend on which encoding carried the key.
    func testTheChordKeyIsCaughtInTheKittyEncodingToo() {
        let (desk, reader) = makeDev()
        let forwarded = inputLines {
            press(reader, [0x1C])
            press(reader, Array("\u{1B}[115;1u".utf8))     // kitty: `s`, no modifiers
        }
        XCTAssertEqual(desk.chromeState.panel, .stats)
        XCTAssertEqual(forwarded, [])
    }

    // MARK: the exit chord

    /// `^\ q` is the documented exit and, since `s` was dead, the *only* keyboard exit under `--dev`
    /// (the issue: "I cannot leave"). `Desk.chromeKey`'s `q` arm calls `shutdown()`, which ends the
    /// process and therefore cannot run in a test; what a test can pin is the half the bug was in —
    /// the byte is handed to the chrome and never forwarded. The exit itself is asserted by the pty
    /// transcript in the PR (the child exits 0 on `1c 71` there).
    func testTheQuitKeyIsHandedToTheChromeAndNotForwarded() {
        let reader = InputReader(viewport: { Viewport(pixelWidth: 320, pixelHeight: 240, cols: 40,
                                                      rows: 15, sourceRect: .zero) },
                                 dryRun: true, forward: true) {}
        reader.trace = true
        // `chromeKey`'s table, minus the exit: armed after `Ctrl-\`, everything it is offered while
        // armed is its own.
        var armed = false
        var asked: [UInt8] = []
        reader.onChromeKey = { byte in
            asked.append(byte)
            if !armed, byte == 0x1C { armed = true; return true }
            armed = false
            return true
        }
        reader.chromePrefixArmed = { armed }

        let forwarded = inputLines {
            press(reader, [0x1C])
            press(reader, [0x71])       // `q`
        }
        XCTAssertEqual(asked, [0x1C, 0x71], "the chrome heard both halves of the chord")
        XCTAssertEqual(forwarded, [], "`q` reached the mirrored Mac")
        XCTAssertFalse(forwarded.contains { $0.contains("key code=\(kVK_Q)") })
    }

    // MARK: nothing else moved

    /// The regression guard: with the prefix not armed, the reader is what it always was — a letter
    /// is a keystroke for the mirrored Mac and a control byte keeps its own meaning (`Ctrl-C` is
    /// forwarded by design, README:94).
    func testUnprefixedKeysStillReachTheRemote() {
        let (desk, reader) = makeDev()
        var forwarded: [String] = []
        forwarded += inputLines { press(reader, [0x73]) }        // `s`
        forwarded += inputLines { press(reader, [0x03]) }        // Ctrl-C
        XCTAssertNil(desk.chromeState.panel, "a bare `s` opens nothing")
        XCTAssertFalse(desk.chromeState.prefix)
        XCTAssertTrue(forwarded.contains { $0.hasPrefix("input: key code=\(kVK_S) ") },
                      "`s` must still be typed into the remote; got \(forwarded)")
        XCTAssertTrue(forwarded.contains { $0.hasPrefix("input: key code=8 ") },
                      "Ctrl-C is forwarded by design; got \(forwarded)")
    }

    /// `ESC` is the first byte of a sequence, not a chord key: a key that *starts* with `ESC` (an
    /// arrow here) reaches the remote exactly as it did before, and the prefix stays armed for the
    /// next real chord key. Pinned because the cheap version of this fix ate the `ESC` and typed the
    /// rest of the sequence (`[A`) into the desktop.
    func testAnEscapeSequenceIsStillTheParsersAndStillReachesTheRemote() {
        let (desk, reader) = makeDev()
        var forwarded: [String] = []
        forwarded += inputLines {
            press(reader, [0x1C])
            press(reader, Array("\u{1B}[A".utf8))       // Up arrow
        }
        XCTAssertNil(desk.chromeState.panel)
        XCTAssertTrue(desk.chromeState.prefix, "an arrow is not a chord key, so the prefix is still armed")
        XCTAssertTrue(forwarded.contains { $0.hasPrefix("input: key code=126 ") },
                      "Up arrow still goes to the remote; got \(forwarded)")
    }
}
