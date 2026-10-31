import XCTest
@testable import krdcore

/// Pure logic only: the terminal-byte → macOS key code tables in `Keys`. No `CGEvent` is posted
/// and no tty is opened, so this runs anywhere.
///
/// The tables get tests of their own because #14 was not a wrong key: `ESC [ 23 ~` and
/// `ESC [ 24 ~` went through `Keys.f[code - 11]`, i.e. indices 12 and 13 of a 12-entry array.
/// A Swift subscript trap is not catchable and no signal handler runs, so the process died
/// before `input.restore()` and left the pane in the alternate screen with raw mode on
/// (TROUBLESHOOTING §22). Arithmetic on a table is the bug class, so the table is what is pinned.
final class KeyTableTests: XCTestCase {
    /// Terminal number → F-key ordinal, in the order PROTOCOL.md §7.2 documents them.
    /// 16 and 22 are gaps in xterm's numbering, not omissions.
    private let functionCodes = [11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 23, 24, 25, 26]

    private var functionKeys: [CGKeyCode] {
        [Keys.f1, Keys.f2, Keys.f3, Keys.f4, Keys.f5, Keys.f6, Keys.f7,
         Keys.f8, Keys.f9, Keys.f10, Keys.f11, Keys.f12, Keys.f13, Keys.f14]
    }

    /// `CGEvent` posts whatever number it is handed, so a wrong entry looks like a working key in
    /// every log and every test that only checks "something was pressed". These are the real
    /// macOS virtual key codes (`kVK_F1`…`kVK_F14` in `Events.h`), and this is the only assertion
    /// here that pins literal key-code values instead of deriving them from `Keys` itself.
    func testFunctionKeysAreTheMacOnes() {
        XCTAssertEqual(functionKeys,
                       [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107])
    }

    /// F11/F12 are the two that used to trap; F1–F10 are here so a fix for them cannot silently
    /// shift the rest of the row.
    func testFunctionNumbersLandOnTheRightKeys() {
        let keys = functionKeys
        XCTAssertEqual(functionCodes.count, keys.count)
        for (ordinal, code) in functionCodes.enumerated() {
            XCTAssertEqual(Keys.numbered[code], keys[ordinal], "CSI \(code)~")
        }
    }

    /// The whole family rather than the entries: every number a terminal can plausibly put in
    /// `ESC [ <n> ~` either resolves to a key these tables own, or is dropped — never pressed as
    /// something else. Nothing indexes, so nothing can trap.
    func testNoNumberEscapesTheTable() {
        let owned = Set([Keys.home, Keys.end, Keys.forwardDelete, Keys.pageUp, Keys.pageDown]
                        + functionKeys)
        for code in 0...64 {
            if let key = Keys.numbered[code] {
                XCTAssertTrue(owned.contains(key),
                              "CSI \(code)~ maps to \(key), which is not a key this table owns")
            } else {
                XCTAssertNil(Keys.numberedPress([code]),
                             "CSI \(code)~ is not in the table but still resolves")
            }
        }
    }

    /// The parser's decision, not just the table under it. A regression that puts an array and
    /// `code - 11` back inside `handleCSI` — or that reads the modifier as the key, or drops the
    /// modifiers — fails here; the table tests above would not notice.
    func testNumberedReportsResolveToAKeyAndItsModifiers() {
        XCTAssertNil(Keys.numberedPress([]))          // `ESC [ ~`: no number at all
        XCTAssertNil(Keys.numberedPress([16]))        // a gap, not "the next F key"

        for (ordinal, code) in functionCodes.enumerated() {
            let press = Keys.numberedPress([code])
            XCTAssertEqual(press?.key, functionKeys[ordinal], "CSI \(code)~")
            XCTAssertEqual(press?.flags, Modifiers(), "CSI \(code)~ should carry no modifiers")
        }

        // The second number is the modifier, and must never be taken for the key: Shift-F11 =
        // `ESC [ 23 ; 2 ~`, plain F11 = `ESC [ 23 ; 1 ~`.
        XCTAssertEqual(Keys.numberedPress([23, 2])?.key, Keys.f11)
        XCTAssertEqual(Keys.numberedPress([23, 2])?.flags, Modifiers.maskShift)
        XCTAssertEqual(Keys.numberedPress([23, 1])?.flags, Modifiers())

        // xterm packs modifiers as `mods - 1`; krd reads bits 1/2/4/8 as shift/alt/ctrl/cmd.
        XCTAssertEqual(Keys.numberedPress([11, 6])?.flags,
                       [Modifiers.maskShift, Modifiers.maskControl])
        XCTAssertEqual(Keys.numberedPress([11, 9])?.flags, Modifiers.maskCommand)
        XCTAssertEqual(Keys.numberedPress([11, 16])?.flags,
                       [.maskShift, .maskAlternate, .maskControl, .maskCommand])
    }

    /// 16 and 22 are holes in the numbering. Treating them as "the next F key" would press
    /// something the user did not ask for — the usual way a bounds fix makes things worse.
    func testNumberingGapsStayEmpty() {
        for code in [0, 16, 22, 64] {
            XCTAssertNil(Keys.numbered[code], "CSI \(code)~")
        }
    }

    /// `ESC O P` … `ESC O S` and `ESC [ 11 ~` … `ESC [ 14 ~` are two spellings of the same four
    /// keys, and `ss3Function` is built from `numbered`, so they cannot drift. This pins that the
    /// four entries and the four keys are still the same pairs.
    func testSS3SpellingMatchesTheCSISpelling() throws {
        let pairs: [(Character, Int)] = [("P", 11), ("Q", 12), ("R", 13), ("S", 14)]
        for (letter, code) in pairs {
            let csi = try XCTUnwrap(Keys.numbered[code], "CSI \(code)~ is missing")
            XCTAssertEqual(Keys.ss3Function[letter], csi, "ESC O \(letter) vs CSI \(code)~")
        }
        XCTAssertEqual(Keys.ss3Function.count, pairs.count)
    }
}

/// DECSET 1004 (issue #110): the terminal reports focus with two plain 2-byte CSIs, `ESC [ I` and
/// `ESC [ O`, and they are the *entire* input surface of the feature.
///
/// They are tested here, at the parser, for the reason `#14` taught: what matters is not that the
/// bytes mean something, but that they mean *exactly one* thing. Two failure modes are silent — a
/// `CSI I` that is dropped is a pane that never unfocuses, and a `CSI O` that falls through to
/// "some key" is an ESC/`[`/`O` sequence typed into the mirrored desktop, which is worse than not
/// having the feature. So the assertions are `==` against the whole event list, never "contains".
final class FocusEventTests: XCTestCase {
    private func parse(_ bytes: [UInt8]) -> [Event] {
        var events: [Event] = []
        let parser = InputParser()
        parser.onEvent = { events.append($0) }
        parser.feed(bytes)
        return events
    }

    /// `CSI I`: focus gained. One event, and no keystroke beside it.
    func testFocusInIsExactlyOneFocusEvent() {
        XCTAssertEqual(parse(Array("\u{1B}[I".utf8)), [.focus(true)])
    }

    /// `CSI O`: focus lost. One event, and no keystroke beside it.
    func testFocusOutIsExactlyOneFocusEvent() {
        XCTAssertEqual(parse(Array("\u{1B}[O".utf8)), [.focus(false)])
    }

    /// Two reports in one read keep their order: a terminal that loses and regains focus sends both,
    /// and the rate machine on the other side is a state machine, not a counter.
    func testFocusReportsKeepTheOrderTheTerminalSentThemIn() {
        XCTAssertEqual(parse(Array("\u{1B}[O\u{1B}[I".utf8)), [.focus(false), .focus(true)])
    }

    /// A read can split anywhere (a pty hands over whatever has arrived), and the CSI state machine
    /// already buffers a partial sequence — these two must not be the exception.
    func testFocusReportsSurviveAByteAtATime() {
        var events: [Event] = []
        let parser = InputParser()
        parser.onEvent = { events.append($0) }
        for byte in Array("\u{1B}[O\u{1B}[I".utf8) {
            parser.feed([byte])
        }
        XCTAssertEqual(events, [.focus(false), .focus(true)])
    }

    /// The trace form the golden input fixture is made of (`Event.canonicalTrace`).
    func testFocusHasACanonicalTrace() {
        XCTAssertEqual(Event.focus(true).canonicalTrace, "focus 1")
        XCTAssertEqual(Event.focus(false).canonicalTrace, "focus 0")
    }
}
