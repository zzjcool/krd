import XCTest
@testable import krdcore

/// The kitty keyboard protocol, decoded as data. No tty, no `CGEvent`, no buffer: `InputReader`
/// owns those, and what needs pinning is which key a report means and whether it is a press, a
/// repeat or a release.
///
/// The legacy half of these tests exists because #15's first requirement is that a terminal which
/// ignores the handshake behaves exactly as it did before: the parse must be the same expression,
/// not merely a similar one.
final class KeyboardTests: XCTestCase {
    // MARK: kitty reports

    func testTextKeyPressRepeatRelease() {
        XCTAssertEqual(KeyReport(kitty: "97"), KeyReport(code: 97))
        XCTAssertEqual(KeyReport(kitty: "97;1:1"), KeyReport(code: 97, phase: .press))
        XCTAssertEqual(KeyReport(kitty: "97;1:2"), KeyReport(code: 97, phase: .repeated))
        XCTAssertEqual(KeyReport(kitty: "97;1:3"), KeyReport(code: 97, phase: .release))
        // No modifier field at all is legal and means "no modifiers, press".
        XCTAssertEqual(KeyReport(kitty: "97;"), KeyReport(code: 97))
    }

    func testModifierFieldMatchesXtermBitOrder() {
        // The wire form is `1 + bits`; bit 8 is super, i.e. Cmd on the Mac.
        XCTAssertEqual(KeyReport(kitty: "99;2")?.mods, 1)                 // shift
        XCTAssertEqual(KeyReport(kitty: "99;3")?.mods, 2)                 // alt
        XCTAssertEqual(KeyReport(kitty: "99;5")?.mods, 4)                 // ctrl
        XCTAssertEqual(KeyReport(kitty: "99;9")?.mods, 8)                 // cmd
        XCTAssertEqual(KeyReport(kitty: "99;10")?.mods, 9)                // shift+cmd
        XCTAssertEqual(KeyReport(kitty: "99;5:3")?.mods, 4)
        XCTAssertEqual(KeyReport(kitty: "99;5:3")?.phase, .release)
    }

    func testCommandCombinationPostsTheBaseKeyWithCommand() {
        // Cmd-C: the shortcut the whole issue is about. Code 99 is 'c', so the macOS key is 8,
        // and the modifier must come through as .maskCommand rather than as anything else.
        let report = KeyReport(kitty: "99;9")
        XCTAssertEqual(Keyboard.keyCode(report ?? KeyReport(code: 0)), Keys.map["c"])
        XCTAssertEqual(report?.flags, Modifiers.maskCommand)
        XCTAssertEqual(report?.flags.contains(.maskShift), false)
    }

    func testAlternateKeyFields() {
        let report = KeyReport(kitty: "97:65:99;5")
        XCTAssertEqual(report?.code, 97)
        XCTAssertEqual(report?.shifted, 65)
        XCTAssertEqual(report?.base, 99)
        // An empty sub-field is absent, not zero.
        XCTAssertNil(KeyReport(kitty: "97::99;5")?.shifted)
        XCTAssertEqual(KeyReport(kitty: "97::99;5")?.base, 99)
        // The base layout key wins: on a Cyrillic layout ctrl+С must press the physical c key.
        XCTAssertEqual(Keyboard.text(KeyReport(kitty: "1089::99;5") ?? KeyReport(code: 0)), "c")
    }

    func testFunctionalKeysFromThePrivateUseArea() {
        XCTAssertEqual(Keyboard.keyCode(KeyReport(kitty: "27") ?? KeyReport(code: 0)), Keys.esc)
        XCTAssertEqual(Keyboard.keyCode(KeyReport(kitty: "13") ?? KeyReport(code: 0)), Keys.enter)
        XCTAssertEqual(Keyboard.keyCode(KeyReport(kitty: "9") ?? KeyReport(code: 0)), Keys.tab)
        XCTAssertEqual(Keyboard.keyCode(KeyReport(kitty: "127") ?? KeyReport(code: 0)), Keys.backspace)
        XCTAssertEqual(Keyboard.keyCode(KeyReport(kitty: "57376") ?? KeyReport(code: 0)), Keys.f13)
        XCTAssertEqual(Keyboard.keyCode(KeyReport(kitty: "57377") ?? KeyReport(code: 0)), Keys.f14)
    }

    func testPrivateUseAreaIsNeverTypedAsText() {
        // A functional key without a mapping must be dropped. Falling through to the unicode path
        // would type U+E02x into the mirrored app, which is worse than doing nothing.
        for code in [57400, 57441, 57358, 0xE000] {
            let report = KeyReport(kitty: String(code))
            XCTAssertNotNil(report)
            XCTAssertNil(Keyboard.text(report ?? KeyReport(code: 0)), "U+\(String(code, radix: 16))")
        }
    }

    func testModifierKeysAreNotForwarded() {
        // Every report already carries the modifier state, and a forwarded Cmd would be posted as
        // a tap. Swallowing them is what makes "release the modifier" impossible to get stuck.
        for code in Keyboard.modifierKeys {
            XCTAssertNil(Keyboard.text(KeyReport(kitty: String(code)) ?? KeyReport(code: 0)))
            XCTAssertNil(Keyboard.keyCode(KeyReport(kitty: String(code)) ?? KeyReport(code: 0)))
        }
    }

    // MARK: the quit chord

    func testQuitChordIsPressOrRepeatOnly() {
        XCTAssertTrue(KeyReport(kitty: "92;5")?.isQuit ?? false)
        XCTAssertTrue(KeyReport(kitty: "92;5:1")?.isQuit ?? false)
        XCTAssertTrue(KeyReport(kitty: "92;5:2")?.isQuit ?? false)
        // The release must not quit a second time.
        XCTAssertFalse(KeyReport(kitty: "92;5:3")?.isQuit ?? true)
        // Ctrl-\ with any other modifier is an ordinary key press.
        XCTAssertFalse(KeyReport(kitty: "92;6")?.isQuit ?? true)      // ctrl+shift
        XCTAssertFalse(KeyReport(kitty: "92;9")?.isQuit ?? true)      // cmd
        XCTAssertFalse(KeyReport(kitty: "92;13")?.isQuit ?? true)     // ctrl+alt
    }

    func testQuitChordReleaseIsSwallowedWhole() {
        // The release is still *the chord* (so it must not be forwarded as a Ctrl-\\ the mirrored
        // app never saw pressed), but it is not a quit.
        let release = KeyReport(kitty: "92;5:3")
        XCTAssertTrue(release?.isQuitChord ?? false)
        XCTAssertFalse(release?.isQuit ?? true)
        XCTAssertTrue(KeyReport(kitty: "92;5:1")?.isQuit ?? false)
    }

    // MARK: legacy parity

    /// The parse a terminal that ignores the handshake gets must be the *same expression* the
    /// pre-#15 code ran: `params.split(";").map { Int($0) ?? 0 }`, with no event phase.
    func testLegacyFieldsAreTheOldParse() {
        let cases = ["", ";", "1", "11", "11;2", "1;5", "23", "2", "3", "1;2;3", "11;", ";5"]
        for params in cases {
            let old = params.split(separator: ";").map { Int($0) ?? 0 }
            let parsed = KeyReport.legacyFields(params)
            XCTAssertEqual(parsed.numbers, old, "params \"\(params)\"")
            XCTAssertEqual(parsed.phase, .press, "params \"\(params)\"")
        }
    }

    func testLegacyFieldsCarryTheEventSubfield() {
        // kitty appends `:event` to the legacy functional forms when event types are on:
        // `CSI 1;5:3 A` is ctrl+up released, `CSI 23;2:3 ~` is Shift-F11 released.
        let arrow = KeyReport.legacyFields("1;5:3")
        XCTAssertEqual(arrow.numbers, [1, 5])
        XCTAssertEqual(arrow.phase, .release)
        let function = KeyReport.legacyFields("23;2:3")
        XCTAssertEqual(function.numbers, [23, 2])
        XCTAssertEqual(function.phase, .release)
        // A garbage sub-field must not swallow the key.
        XCTAssertEqual(KeyReport.legacyFields("23;2:9").numbers, [23, 2])
        XCTAssertEqual(KeyReport.legacyFields("23;2:9").phase, .press)
    }

    // MARK: malformed input

    func testMalformedReportsAreDropped() {
        for params in ["", ";", ":", ":5", "0;1", "abc", "-1", "u"] {
            XCTAssertNil(KeyReport(kitty: params), "params \"\(params)\"")
        }
    }
}
