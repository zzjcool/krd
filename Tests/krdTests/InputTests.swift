import XCTest
import CoreGraphics
@testable import krd

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
            XCTAssertEqual(press?.flags, CGEventFlags(), "CSI \(code)~ should carry no modifiers")
        }

        // The second number is the modifier, and must never be taken for the key: Shift-F11 =
        // `ESC [ 23 ; 2 ~`, plain F11 = `ESC [ 23 ; 1 ~`.
        XCTAssertEqual(Keys.numberedPress([23, 2])?.key, Keys.f11)
        XCTAssertEqual(Keys.numberedPress([23, 2])?.flags, CGEventFlags.maskShift)
        XCTAssertEqual(Keys.numberedPress([23, 1])?.flags, CGEventFlags())

        // xterm packs modifiers as `mods - 1`; krd reads bits 1/2/4/8 as shift/alt/ctrl/cmd.
        XCTAssertEqual(Keys.numberedPress([11, 6])?.flags,
                       [CGEventFlags.maskShift, CGEventFlags.maskControl])
        XCTAssertEqual(Keys.numberedPress([11, 9])?.flags, CGEventFlags.maskCommand)
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
