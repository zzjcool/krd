import XCTest
@testable import krdcore

/// The `--ime` decision table (issue #16). Every row here is a keystroke that would otherwise be
/// discovered by typing into a mirrored app and watching nothing happen.
final class IMETests: XCTestCase {
    /// `a`: code 97, no alternate keys reported.
    private func plain(_ code: Int, mods: Int = 0) -> KeyReport {
        KeyReport(code: code, shifted: nil, base: nil, mods: mods, phase: .press)
    }

    private func keyOf(_ plan: KeyPlan, file: StaticString = #filePath, line: UInt = #line) -> CGKeyCode? {
        guard case let .key(code, _) = plan else {
            XCTFail("expected a key plan, got \(plan)", file: file, line: line)
            return nil
        }
        return code
    }

    private func textOf(_ plan: KeyPlan, file: StaticString = #filePath, line: UInt = #line) -> Character? {
        guard case let .text(ch) = plan else {
            XCTFail("expected a text plan, got \(plan)", file: file, line: line)
            return nil
        }
        return ch
    }

    // MARK: the ASCII fast path must not change in any mode

    func testASCIIAlwaysPressesItsKey() {
        for mode in IMEMode.allCases {
            let plan = Keyboard.plan(for: plain(97), mode: mode)          // a
            XCTAssertEqual(keyOf(plan), Keys.map["a"], "mode \(mode) changed the ASCII path")
        }
    }

    func testShiftedASCIIKeepsTheShiftFlag() {
        // Shift+a: the spec says `code` is the unshifted 97 and shift rides in the modifier field.
        let report = KeyReport(code: 97, shifted: nil, base: nil, mods: 0b0001, phase: .press)
        for mode in IMEMode.allCases {
            guard case let .key(code, flags) = Keyboard.plan(for: report, mode: mode) else {
                return XCTFail("expected a key plan in mode \(mode)")
            }
            XCTAssertEqual(code, Keys.map["a"])
            XCTAssertTrue(flags.contains(.maskShift), "mode \(mode) dropped shift")
        }
    }

    func testShiftedSymbolUsesItsBaseKey() {
        // `!` arrives as code 33 on a terminal without alternate keys; pressing 1 with shift is the
        // only way to type it. Same in every mode: this is still "a character with a key".
        for mode in IMEMode.allCases {
            guard case let .key(code, flags) = Keyboard.plan(for: plain(33), mode: mode) else {
                return XCTFail("expected a key plan in mode \(mode)")
            }
            XCTAssertEqual(code, Keys.map["1"])
            XCTAssertTrue(flags.contains(.maskShift))
        }
    }

    // MARK: a non-ASCII character that does have a physical key

    /// Cyrillic `ф` on the key where a US keyboard has `a`: kitty's alternate-key field reports
    /// `base = 97`. Pressing `a` is exactly the point of plan A — the target's layout or IME turns
    /// it into whatever that key means there.
    func testAlternateKeysWinInAutoAndRaw() {
        let report = KeyReport(code: 1092, shifted: nil, base: 97, mods: 0, phase: .press)
        for mode in [IMEMode.auto, .raw] {
            guard case let .key(code, _) = Keyboard.plan(for: report, mode: mode) else {
                return XCTFail("mode \(mode) should press the physical key")
            }
            XCTAssertEqual(code, Keys.map["a"])
        }
        // `unicode` is the "just give me the character" mode.
        XCTAssertEqual(textOf(Keyboard.plan(for: report, mode: .unicode)), "ф")
    }

    // MARK: non-ASCII with no key at all (the CJK case)

    func testComposedCJKIsInjectedInAutoAndDroppedInRaw() {
        let report = plain(0x4E2D)                                     // 中
        XCTAssertEqual(textOf(Keyboard.plan(for: report, mode: .auto)), "中")
        XCTAssertEqual(textOf(Keyboard.plan(for: report, mode: .unicode)), "中")
        // Raw exists so a composition never gets half-injected text in the middle of it.
        XCTAssertEqual(Keyboard.plan(for: report, mode: .raw), .drop)
    }

    func testLatin1LetteredWithoutABaseDegradesTheSameWay() {
        let report = plain(0xE9)                                       // é, no alternate-key field
        XCTAssertEqual(textOf(Keyboard.plan(for: report, mode: .auto)), "é")
        XCTAssertEqual(Keyboard.plan(for: report, mode: .raw), .drop)
    }

    // MARK: functional keys are not characters

    func testFunctionalKeysAreNeverTurnedIntoText() {
        let f13 = plain(57376)
        for mode in IMEMode.allCases {
            guard case let .key(code, _) = Keyboard.plan(for: f13, mode: mode) else {
                return XCTFail("mode \(mode) lost F13")
            }
            XCTAssertEqual(code, Keys.f13)
        }
    }

    func testModifierKeyReportsPlanNothing() {
        // Modifier reports are swallowed before the plan runs, but a plan of `.drop` is the right
        // answer if one ever slips through: posting U+E050 as text would type a glyph.
        XCTAssertEqual(Keyboard.plan(for: plain(57441), mode: .auto), .drop)
    }

    func testModeParsingRejectsTypos() {
        XCTAssertEqual(IMEMode(spec: "auto"), .auto)
        XCTAssertEqual(IMEMode(spec: "RAW"), .raw)
        XCTAssertEqual(IMEMode(spec: "unicode"), .unicode)
        XCTAssertNil(IMEMode(spec: "rawkeys"))
        XCTAssertNil(IMEMode(spec: ""))
    }
}
