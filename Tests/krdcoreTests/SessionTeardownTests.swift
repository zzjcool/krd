import XCTest
import Darwin
import Foundation
@testable import krdcore

/// A session must hand the terminal back the way it found it.
///
/// WHY this needs its own file, and why the assertion is "balanced", not "contains 1016l": the
/// terminal is a *state machine with no owner*. Every DEC private mode krd turns on is sticky:
/// `?1016h` (SGR-pixel mouse coordinates, a kitty extension of `?1006`) stays on until something
/// sends `?1016l`, and the terminal then reports clicks in **device pixels** where the next program
/// expects **cells**, so every click lands somewhere else - silently, with no error anywhere. Two
/// paths are supposed to undo krd's modes:
///
/// - PROTOCOL.md §1 documents the *heal* prefix of `beginSession()` as the repair for a pane left by
///   a killed predecessor ("Re-running krd fixes such a pane automatically"), and
/// - PROTOCOL.md §4 documents `endSession()` as "end of session", i.e. the teardown.
///
/// Both reset every mode the session turned on, from the one list `ScreenWriter.inputReset` (the
/// enable list reversed) - that is the contract this file pins. Before #134 each of the three was
/// written out by hand, mode by mode, and both session-level ones were missing `?1016`: a `kill -9`
/// mid-session skips `InputReader.loop`'s own `writeInputModes(false)` entirely, so the heal and
/// the teardown are the only two safety nets there are, and a mode either one forgets is left on for
/// the lifetime of the pane.
///
/// The tests below therefore never spell out the expected escape sequence. They *read it out of the
/// byte stream krd produces*, decide which modes the session turned on, and require those to be off
/// again. That is the only shape of the test that cannot go stale the next time a mode is added.
///
/// The sink is `ScreenWriter.sink` (the in-memory seam from issue #21), so no real terminal is
/// touched; the two `writeInputModes` calls are static and write straight to fd 1, so they are
/// captured by temporarily pointing fd 1 at a temp file. Both halves end up in one ordered byte array.
///
/// One mode in the table is not like the others (#110): `?1004` (focus reporting) is enabled only by
/// a session that reads input, so it is conditional on `ScreenWriter.focusReporting`. The two #110
/// tests at the bottom pin both halves: nothing at all with it off (the `--selftest` dump contract),
/// reset in the heal *and* the teardown with it on.
final class SessionTeardownTests: XCTestCase {

    /// Every case starts and ends with the shipped default: `focusReporting` is the one piece of
    /// `ScreenWriter` state a desk sets for a whole session, and a leaked `true` here would make the
    /// "no input, no 1004" test below pass or fail depending on test *order*.
    override func setUp() {
        super.setUp()
        ScreenWriter.focusReporting = false
    }

    override func tearDown() {
        ScreenWriter.focusReporting = false
        super.tearDown()
    }

    // MARK: - the modes, and what "on" means for each

    /// Every DEC private mode this suite can see krd emit, with the state krd itself sets up.
    ///
    /// `on` is not always `h`: krd turns the *hidden* cursor on (`?25l`) and restores the visible one
    /// with `?25h`, so the polarity of 25 is inverted. Getting that backwards would make the test
    /// demand `?25l` in a teardown that correctly sends `?25h`.
    private static let modeNames: [Int: String] = [
        25: "cursor hidden",
        1002: "button-event mouse tracking",
        1003: "any-motion mouse tracking",
        1004: "focus reporting (DECSET 1004)",
        1006: "SGR mouse encoding",
        1016: "SGR-PIXEL mouse coordinates (kitty extension)",
        1049: "alternate screen",
        2026: "synchronized update",
    ]

    private struct ModeEvent {
        let mode: Int
        /// True when, after this event, the mode is in the state krd turned on.
        let on: Bool
    }

    /// Reads `CSI ? <n> h|l` out of a byte stream, in order.
    ///
    /// Deliberately a hand scanner and not a regex over the whole string: only *private mode set/reset*
    /// is interesting, and everything else in the stream (image payloads, SGR colours, CUP) must be
    /// skipped without a chance of a false match inside a base64 body.
    private func modeEvents(in text: String) -> [ModeEvent] {
        let chars = Array(text)
        var events: [ModeEvent] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "\u{1B}", i + 3 < chars.count,
                  chars[i + 1] == "[", chars[i + 2] == "?" else { i += 1; continue }
            var j = i + 3
            var digits = ""
            while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
            guard let mode = Int(digits), j < chars.count,
                  chars[j] == "h" || chars[j] == "l" else { i += 1; continue }
            events.append(ModeEvent(mode: mode, on: mode == 25 ? chars[j] == "l" : chars[j] == "h"))
            i = j + 1
        }
        return events
    }

    private func everSetOn(_ events: [ModeEvent]) -> Set<Int> {
        Set(events.filter { $0.on }.map { $0.mode })
    }

    private func setOff(_ events: [ModeEvent]) -> Set<Int> {
        Set(events.filter { !$0.on }.map { $0.mode })
    }

    /// The state each mode is in when the stream ends (last event wins - that is how a terminal sees it).
    private func finalStates(_ events: [ModeEvent]) -> [Int: Bool] {
        var state: [Int: Bool] = [:]
        for e in events { state[e.mode] = e.on }
        return state
    }

    private func describe(_ modes: Set<Int>) -> String {
        modes.sorted().map { "?\($0) (\(Self.modeNames[$0] ?? "unknown mode"))" }.joined(separator: ", ")
    }

    // MARK: - plumbing

    /// Runs `body` with fd 1 redirected into a temp file and returns the bytes krd wrote there.
    ///
    /// `ScreenWriter.writeInputModes` (and `writeKeyboardProtocol`) are `static` and go straight
    /// to the tty by design - they must not queue behind a frame - so the sink seam cannot see them.
    /// The window is one `write(2)` per call and XCTest runs the cases of a class on one thread, so
    /// nothing of the runner's own output can slip in between.
    private func captureFd1(_ body: () -> Void) -> [UInt8] {
        let path = NSTemporaryDirectory() + "krd-teardown-\(UUID().uuidString)"
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { XCTFail("could not open \(path) for the fd-1 capture"); return [] }
        defer { unlink(path) }
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else { close(fd); XCTFail("could not dup fd 1"); return [] }
        // Restore in a `defer`: if anything inside `body()` traps, fd 1 must not stay pointed at a
        // deleted temp file and swallow the rest of the test run's output.
        defer {
            fflush(stdout)
            dup2(saved, STDOUT_FILENO)
            close(saved)
            close(fd)
        }
        dup2(fd, STDOUT_FILENO)
        body()
        return (FileManager.default.contents(atPath: path) ?? Data()).map { $0 }
    }

    private func tile(index: Int) -> CompressedTile {
        // Raw payload on purpose: the escape assembly is what is under test here, and `o=z` would
        // put a base64 body into the stream that this file's scanner has to skip (it does, but a
        // short stream keeps a failure readable).
        CompressedTile(index: index,
                      rect: (x: 0, y: 0, w: 34, h: 33, col: 1, row: 1, cols: 2, rows: 1),
                      payload: [UInt8](repeating: 0x41, count: 12),
                      ratio: 1, isCompressed: false)
    }

    // MARK: - 1. whatever a session enables, the teardown disables

    /// The teardown must be self-sufficient: it is the last code that runs before the shell gets the
    /// pane back, and after a `kill -9` it is the *only* code that runs at all (in the next process,
    /// as `beginSession`'s heal).
    func testWhateverTheSessionEnablesTheTeardownDisables() {
        let writer = ScreenWriter()
        var session: [UInt8] = []
        writer.sink = { session.append(contentsOf: $0) }

        // A realistic session, in the order the process produces it.
        writer.beginSession()                                    // heal + alt screen + ?25l
        session.append(contentsOf: captureFd1 {                  // InputReader.start()
            ScreenWriter.writeInputModes(true)
        })
        for frame in 0..<2 {                                     // a couple of frames
            writer.beginFrame()
            writer.emit(tile(index: frame), sync: writer.perTileSync)
            writer.endFrame()
        }
        session.append(contentsOf: captureFd1 {                  // InputReader.stop()
            ScreenWriter.writeInputModes(false)
        })
        let teardownStart = session.count                        // everything from here is endSession()
        writer.endSession()

        let wholeSession = String(decoding: session, as: UTF8.self)
        let teardown = String(decoding: session[teardownStart...], as: UTF8.self)
        let enabled = everSetOn(modeEvents(in: wholeSession))

        XCTAssertTrue(enabled.isSuperset(of: [1003, 1002, 1006, 1016]),
                      "the instrument must see the four mouse modes the session turns on; saw \(describe(enabled))")

        // (a) The whole session, as a whole, is balanced. Green on HEAD because `InputReader.loop`
        // sends `writeInputModes(false)` in its defer - which is exactly what `kill -9`, a
        // crash, or a `--no-input` path that never started the reader does **not** run.
        let leftover = finalStates(modeEvents(in: wholeSession)).filter { $0.value }.keys
        XCTAssertTrue(leftover.isEmpty,
                      "the session ends with \(describe(Set(leftover))) still on")

        // (b) The teardown alone must cover everything the session turned on. This is the assertion
        // that fails on HEAD: PROTOCOL.md §4 lists the teardown as `?1003l ?1002l ?1006l`, i.e. the
        // three modes `writeInputModes(false)` handles _plus one fewer than it handles_ - 1016 is
        // missing from the teardown although the enable path (Render.swift writeInputModes(true))
        // and the disable path (`false`) both mention it. The terminal keeps reporting in device
        // pixels for the rest of the pane's life.
        let turnedOffByTeardown = setOff(modeEvents(in: teardown))
        let offenders = enabled.subtracting(turnedOffByTeardown)
        XCTAssertFalse(offenders.contains(1016), """
            Every mode this session turned ON has to be reset by `endSession()`, which PROTOCOL.md \
            §4 documents as the teardown: an enabled mode is sticky, so one left on outlives krd and \
            belongs to whoever gets the pane next. `?1016` (SGR-pixel mouse coordinates) is the one \
            that used to be missed here - the terminal keeps reporting clicks in **device pixels** \
            where the next program expects **cells**, so every click lands somewhere else, silently, \
            with no krd left in the loop to notice it.
            teardown = \(teardown.debugDescription)
            """)
        XCTAssertTrue(offenders.isEmpty, """
            endSession() leaves mode(s) ON that this session enabled: \(describe(offenders)).
            A teardown that is written by hand, mode by mode, drifts away from the enable path; \
            every mode krd sets has to be reset by the same last-resort sequence that PROTOCOL.md §4 \
            calls "end of session".
            teardown = \(teardown.debugDescription)
            """)
    }

    // MARK: - 2. the heal must repair what a kill -9 leaves behind

    /// `kill -9` between `writeInputModes(true)` and the next prompt leaves the pane with mouse
    /// reporting on, possibly mid-frame (`?2026h` open), hidden cursor and an APC that may never have
    /// been terminated. PROTOCOL.md §1 calls the prefix of `beginSession()` the repair for exactly
    /// that pane and promises re-running krd fixes it. So the heal has to reset every mode that a
    /// killed session can leave on - not the three that happened to exist when it was written.
    ///
    /// On HEAD this fails for the same single reason as test 1 (1016), which is why both belong to
    /// one finding: the mode is in the enable path and in the per-call disable, and in neither of the
    /// two session-level sequences.
    func testBeginSessionHealsEveryModeAKilledSessionLeavesOn() {
        let writer = ScreenWriter()
        var bytes: [UInt8] = []
        writer.sink = { bytes.append(contentsOf: $0) }
        writer.beginSession()

        let text = String(decoding: bytes, as: UTF8.self)
        // The heal is the prefix of beginSession(): everything before the alternate-screen switch.
        let heal = text.components(separatedBy: "\u{1B}[?1049h").first ?? ""
        XCTAssertTrue(heal.contains("?2026l"), "the heal must close a dangling synchronized block")

        // What a killed session can leave on: the four mouse modes (1003/1002/1006/1016), 2026, and
        // the hidden cursor (krd hides it at the end of `beginSession` and again in `nudge()`).
        // 1049 (alternate screen) is not in this list on purpose: the heal cannot "leave" it - the
        // session re-enters the alternate screen two escapes later and `endSession` sends ?1049l.
        let killedSessionCanLeaveOn = [25, 1003, 1002, 1006, 1016]
        let healed = setOff(modeEvents(in: heal))
        for mode in killedSessionCanLeaveOn where !healed.contains(mode) {
            XCTFail("""
                beginSession()'s heal does not reset ?\(mode) (\(Self.modeNames[mode] ?? "unknown")), \
                so a pane whose previous krd was kill -9'd keeps that mode for the rest of its life.
                PROTOCOL.md §1 says the heal is what repairs such a pane ("Re-running krd fixes such a \
                pane automatically"), so it has to reset every mode a killed session can leave on, out \
                of `ScreenWriter.inputReset` - all four of them, not the three that happened to be \
                there before #134. A ?1016h left by the killed process survives the repair, and the \
                *next* program in the pane gets device pixels from a terminal it never asked for them \
                from.
                heal = \(heal.debugDescription)
                """)
        }
    }

    // MARK: - 3. every ?2026h is closed before the next one opens

    /// `KRD_SYNC` / `KRD_NOSYNC` are read once in `ScreenWriter.init`, so the environment cannot be
    /// changed inside a test process: the default mode is pinned here (and skipped if the ambient
    /// environment overrides it), and the per-tile shape is exercised by asking the per-tile emitters
    /// for `sync: true` - which is literally what `KRD_SYNC=tile` does at the call site.
    ///
    /// Open-on-open is the failure this catches: `?2026h` is not a counter, a terminal that gets a
    /// second `h` while a block is open is free to treat the first `?2026l` as the commit, and an
    /// unbalanced block that is never closed freezes the pane's output completely.
    func testEverySynchronizedUpdateBlockIsClosedBeforeTheNextOneOpens() throws {
        let writer = ScreenWriter()
        var bytes: [UInt8] = []
        writer.sink = { bytes.append(contentsOf: $0) }
        writer.beginSession()

        var frameSegments: [String] = []
        if writer.syncLabel == "frame" {
            for _ in 0..<3 {
                let start = bytes.count
                writer.beginFrame()
                XCTAssertFalse(writer.perTileSync, "the default mode wraps the frame, not the tile")
                writer.emit(tile(index: 0), sync: writer.perTileSync)
                writer.emit(tile(index: 1), sync: writer.perTileSync)
                writer.endFrame()
                frameSegments.append(String(decoding: bytes[start...], as: UTF8.self))
            }
        }

        // The per-tile shape: `KRD_SYNC=tile` passes `sync: true` per emitter and opens no
        // frame-level block, and the placeholder transport / the wall's panels do the same
        // (`emitTileAsPlaceholder(..., sync: true)`). So: no `beginFrame` here - that is what would
        // wrap the two blocks in a third one - and `endFrame` only for the flush.
        let tileStart = bytes.count
        writer.emit(tile(index: 2), sync: true)
        writer.emitTileAsPlaceholder(tile(index: 3), sync: true)
        writer.endFrame()
        let tileSegment = String(decoding: bytes[tileStart...], as: UTF8.self)

        let teardownStart = bytes.count
        writer.endSession()
        let teardown = String(decoding: bytes[teardownStart...], as: UTF8.self)

        for (i, segment) in frameSegments.enumerated() {
            assertSyncBalanced(segment, label: "frame \(i) (default KRD_SYNC=frame)")
        }
        assertSyncBalanced(tileSegment, label: "per-tile blocks (KRD_SYNC=tile shape)")
        // The teardown starts with `?2026l` on purpose, to close a block a killed predecessor may
        // have left open (PROTOCOL.md §4, first escape) - that one close has no matching open here.
        assertSyncBalanced(teardown, label: "endSession()", allowDefensiveClose: true)
        XCTAssertTrue(teardown.contains("?2026l"), "the teardown closes any dangling block")

        try XCTSkipUnless(writer.syncLabel == "frame",
                          "KRD_SYNC/KRD_NOSYNC is set in this environment, so the default frame mode "
                          + "is not what this process runs; the per-tile shape above still held")
        XCTAssertEqual(frameSegments.count, 3)
    }

    /// The property: `?2026h` is a flag, not a counter, so inside one stream no block may be opened
    /// while another is open, and none may be left open at the end.
    ///
    /// A close with nothing open is normally an error too - except the one defensive `?2026l` the
    /// teardown (and the heal) send to close whatever a killed predecessor left behind.
    private func assertSyncBalanced(_ text: String, label: String, allowDefensiveClose: Bool = false,
                                    file: StaticString = #filePath, line: UInt = #line) {
        var open = false
        var opened = 0
        var defensiveCloses = 0
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i] == "\u{1B}", i + 7 < chars.count, chars[i + 1] == "[" else { i += 1; continue }
            guard chars[i + 2] == "?", chars[i + 3] == "2", chars[i + 4] == "0", chars[i + 5] == "2",
                  chars[i + 6] == "6" else { i += 1; continue }
            switch chars[i + 7] {
            case "h":
                XCTAssertFalse(open, """
                    \(label): a second ?2026h opens while a block is already open. DEC 2026 is a flag, \
                    not a counter: the terminal may commit on the first ?2026l and paint the rest of \
                    the block live.
                    """, file: file, line: line)
                open = true
                opened += 1
            case "l":
                if open {
                    open = false
                } else {
                    defensiveCloses += 1
                    XCTAssertTrue(allowDefensiveClose, """
                        \(label): ?2026l with nothing open.
                        """, file: file, line: line)
                    XCTAssertLessThanOrEqual(defensiveCloses, 1, """
                        \(label): more than one defensive ?2026l.
                        """, file: file, line: line)
                }
            default:
                break
            }
            i += 8
        }
        XCTAssertFalse(open, """
            \(label): the stream ends with a synchronized-update block still open \
            (\(opened) opened) - a pane in that state shows nothing at all until the next ?2026l.
            """, file: file, line: line)
    }

    // MARK: - 4. the enable list and the reset list are one list

    /// The property issue #134 asks for by name: "add a unit test that the enable set and the reset
    /// set are complementary".
    ///
    /// Both strings are derived from `ScreenWriter.inputModes` (the reset is that list reversed), so
    /// this test is the lock on the derivation, not on a particular mode: same mode set, opposite
    /// polarity, and the reset is exactly the enable order backwards. A mode added to the list shows
    /// up on both sides here; a mode added by hand to *one* string fails. Issue #110 leans on
    /// exactly this: 1004 joins `inputModes`, so it joins the enable set and the reset set at once.
    func testTheEnableSetAndTheResetSetAreComplementary() {
        let enable = modeEvents(in: ScreenWriter.inputEnable)
        let reset = modeEvents(in: ScreenWriter.inputReset)

        XCTAssertEqual(enable.map { $0.mode }, ScreenWriter.inputModes,
                       "inputEnable must carry exactly the documented list, in its order")
        XCTAssertEqual(ScreenWriter.inputModes, ScreenWriter.mouseModes,
                       "with focus reporting off - the shipped default - the input-mode set *is* "
                       + "the mouse set; 1004 is conditional and has no business here")
        XCTAssertTrue(enable.allSatisfy { $0.on }, "every escape in inputEnable must set its mode")
        XCTAssertTrue(reset.allSatisfy { !$0.on }, "every escape in inputReset must reset its mode")

        XCTAssertEqual(Set(enable.map { $0.mode }), Set(reset.map { $0.mode }),
                       "the same modes are enabled and reset; enable \(enable.map { $0.mode }), "
                       + "reset \(reset.map { $0.mode })")
        XCTAssertEqual(enable.map { $0.mode }, Array(reset.map { $0.mode }.reversed()),
                       "one list, written forwards to enable and backwards to reset: a mode can no "
                       + "longer be turned on without the same list turning it off")

        // What is *in* the list is the contract, not a consequence of it. Everything above is
        // derived from `mouseModes`, so deleting a mode keeps both sides complementary - and the
        // four modes themselves are what PROTOCOL §7's table and issue #134's ownership table name.
        // Pinned literally, so adding or removing a mode is a deliberate edit here *and* in the
        // docs, never a silent drift in one of them.
        XCTAssertEqual(ScreenWriter.mouseModes, [1003, 1002, 1006, 1016],
                       "the mouse modes krd owns are exactly the four PROTOCOL §7 documents; a "
                       + "fifth, or a missing one, has to change the doc table and the ownership "
                       + "table with it")
    }

    // MARK: - 5. what a session that never enables the mouse still resets

    /// The other half of the invariant: a session that never turns the mouse on must not emit a
    /// single mouse-mode *enable*, and the modes it does touch are exactly the ones the ownership
    /// table (issue #134) documents - no more, no fewer.
    ///
    /// This is the test that fails when a future mode is enabled somewhere without an owner: the
    /// reset set below is written out by hand on purpose, so adding `?2027h` (or resetting 1016 in
    /// only two of the three places) cannot pass silently. It also pins the *absence* half of the
    /// contract - a mouse-less session still sends the four mouse resets, because that is the
    /// defensive part, but it enables none of them and resets nothing krd does not own (`?1000l`,
    /// `?1005l`), which is where a hand-written list drifts next.
    func testASessionThatNeverEnablesMouseGainsNoModeBytes() {
        let writer = ScreenWriter()
        var bytes: [UInt8] = []
        writer.sink = { bytes.append(contentsOf: $0) }

        // `--selftest` / `--bench-wire` / `--replay` shape: no input reader, so no mouse reporting.
        writer.beginSession()
        for frame in 0..<2 {
            writer.beginFrame()
            writer.emit(tile(index: frame), sync: writer.perTileSync)
            writer.endFrame()
        }
        writer.endSession()

        let text = String(decoding: bytes, as: UTF8.self)
        let events = modeEvents(in: text)

        for mode in [1003, 1002, 1006, 1016] {
            XCTAssertFalse(text.contains("\u{1B}[?\(mode)h"),
                           "a session that never calls writeInputModes(true) sent ?\(mode)h")
            XCTAssertFalse(events.contains { $0.mode == mode && $0.on },
                           "?\(mode) (\(Self.modeNames[mode] ?? "unknown")) is on in a stream that "
                           + "never enabled it")
        }

        XCTAssertEqual(setOff(events), Set([2026, 1016, 1006, 1002, 1003, 25, 1049]), """
            the reset set of a mouse-less session is not the ownership table's: \
            \(describe(setOff(events))).
            Every mode here has to be one krd owns, documented in issue #134's table (2026 sync \
            block, the four mouse modes, 25 cursor, 1049 alternate screen) - a mode that appears \
            here without an owner is a reset for something the session never turned on, and a mode \
            that goes missing is one a killed predecessor keeps.
            """)
    }

    // MARK: - 6. DECSET 1004 is conditional (issue #110)

    /// The half of #110 that must not move: with `focusReporting` off (the shipped default) a whole
    /// session -- heal, frames, teardown -- carries no 1004 byte at all.
    ///
    /// "Balanced" would not be enough, and neither would "reset before it matters": `--no-input`,
    /// `--selftest`, `--bench`, `--replay` and the wall never read stdin, so 1004 would only ever
    /// send bytes to a reader that does not exist -- and the `--selftest` dump is a byte-exact
    /// contract whose sha a single `?1004h`/`?1004l` would move. So the assertion is absence. It is
    /// also the one thing `testASessionThatNeverEnablesMouseGainsNoModeBytes` cannot say: that test
    /// pins a reset *set*, which keeps passing with 1004 in it as long as the set is edited too.
    func testASessionWithoutInputEmitsNoFocusReportingByte() {
        XCTAssertFalse(ScreenWriter.focusReporting,
                       "the shipped default is `false`, and #110's byte contract depends on it")

        let writer = ScreenWriter()
        var bytes: [UInt8] = []
        writer.sink = { bytes.append(contentsOf: $0) }
        writer.beginSession()
        for frame in 0..<2 {
            writer.beginFrame()
            writer.emit(tile(index: frame), sync: writer.perTileSync)
            writer.endFrame()
        }
        writer.endSession()

        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("?1004"), """
            a session that never reads input sent a ?1004 sequence. The mode's whole purpose is to \
            send `CSI I`/`CSI O` to a reader, and a `--no-input` / `--selftest` / `--bench` / \
            `--replay` / wall session has none - and the `--selftest` dump is byte-exact, so this \
            is a sha change too (issue #110). Such a session emits nothing for 1004.
            stream = \(text.debugDescription)
            """)
        XCTAssertFalse(modeEvents(in: text).contains { $0.mode == 1004 },
                       "not a single `CSI ? 1004 h|l` in a session with no input reader")
    }

    /// The other half: `focusReporting` on. 1004 joins the one input-mode list, so #134's single
    /// derivation turns it on for input (`writeInputModes(true)`) and off in *both* session-level
    /// sequences - the heal that repairs a killed predecessor's pane, and the teardown. Each half is
    /// asserted where it lives, and the total is counted, so a mode reset in only one of the two
    /// places cannot pass.
    func testASessionWithInputResetsFocusReportingInTheHealAndTheTeardown() {
        let previous = ScreenWriter.focusReporting
        ScreenWriter.focusReporting = true
        defer { ScreenWriter.focusReporting = previous }

        // The list itself, before a byte is written: the mouse modes, then focus.
        XCTAssertEqual(ScreenWriter.inputModes, ScreenWriter.mouseModes + [1004])
        XCTAssertTrue(ScreenWriter.inputReset.hasPrefix("\u{1B}[?1004l"), """
            the reset is the concatenated list reversed, so 1004 - last on the enable list - is the \
            *first* reset. Got \(ScreenWriter.inputReset.debugDescription).
            """)

        let enableBytes = captureFd1 { ScreenWriter.writeInputModes(true) }
        let enable = String(decoding: enableBytes, as: UTF8.self)
        XCTAssertEqual(modeEvents(in: enable).map { $0.mode }, ScreenWriter.inputModes,
                       "the enable path sends exactly `inputModes`, 1004 included")
        XCTAssertTrue(enable.contains("\u{1B}[?1004h"),
                      "`focusReporting = true` did not enable 1004")

        let writer = ScreenWriter()
        var bytes: [UInt8] = []
        writer.sink = { bytes.append(contentsOf: $0) }
        writer.beginSession()                      // the heal is the first thing a session writes
        let teardownStart = bytes.count
        writer.endSession()

        let whole = String(decoding: bytes, as: UTF8.self)
        let heal = whole.components(separatedBy: "\u{1B}[?1049h").first ?? ""
        let teardown = String(decoding: bytes[teardownStart...], as: UTF8.self)
        let resets = whole.components(separatedBy: "\u{1B}[?1004l").count - 1

        XCTAssertTrue(heal.contains("\u{1B}[?1004l"), """
            beginSession()'s heal does not reset ?1004: a pane whose previous krd was killed while \
            focus reporting was on keeps sending `CSI I`/`CSI O` to the next program, and \
            PROTOCOL.md §1 promises the heal repairs such a pane.
            heal = \(heal.debugDescription)
            """)
        XCTAssertTrue(teardown.contains("\u{1B}[?1004l"), """
            endSession() does not reset ?1004, so the mode outlives krd in the pane the shell gets \
            back (PROTOCOL.md §4 - the teardown).
            teardown = \(teardown.debugDescription)
            """)
        XCTAssertGreaterThanOrEqual(resets, 2, """
            a beginSession/endSession round trip reset ?1004 \(resets) time(s): the heal and the \
            teardown each own one, both out of `ScreenWriter.inputReset`.
            stream = \(whole.debugDescription)
            """)
    }
}
