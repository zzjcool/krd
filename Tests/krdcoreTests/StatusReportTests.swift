import XCTest
@testable import krdcore

/// `CSI 5n` is answered by the terminal with `CSI 0n`, and that answer is the round-trip probe's only
/// measurement (issue #52). Two properties matter, and they pull in opposite directions: the answer
/// must reach `krd` as an event, and it must never become *typing* — a terminal's reply landing in
/// the mirrored machine would press keys nobody pressed.
///
/// A second report shares the final byte: DEC mode 2031 makes the terminal announce its colour scheme
/// with `CSI ? 997 ; 1 n` / `CSI ? 997 ; 2 n` (issue #212). It is a **private** `n` and therefore not
/// the answer — counted as one it would land in the probe's series as an instant round trip — so the
/// classifier below has to tell the two apart, and drop the private numbers it does not know.
final class StatusReportTests: XCTestCase {
    private func events(for bytes: String) -> [Event] {
        var out: [Event] = []
        let parser = InputParser()
        parser.onEvent = { out.append($0) }
        parser.feed(Array(bytes.utf8))
        return out
    }

    func testTheDeviceStatusReportIsAnEvent() {
        XCTAssertEqual(events(for: "\u{1B}[0n"), [.statusReport])
        XCTAssertEqual(events(for: "\u{1B}[0n").map(\.canonicalTrace), ["statusReport"])
    }

    func testAnUnknownReportIsStillDropped() {
        XCTAssertTrue(events(for: "\u{1B}[12;40R").isEmpty,
                      "a cursor-position report must not become input")
        XCTAssertTrue(events(for: "\u{1B}[?62;c").isEmpty, "nor a device-attributes report")
    }

    func testItSurvivesBeingSplitAcrossReads() {
        // A terminal's answer can arrive in two reads; the parser has to hold the partial sequence.
        var out: [Event] = []
        let parser = InputParser()
        parser.onEvent = { out.append($0) }
        parser.feed(Array("\u{1B}[".utf8))
        XCTAssertTrue(out.isEmpty)
        parser.feed(Array("0n".utf8))
        XCTAssertEqual(out, [.statusReport])
    }

    func testATypedNIsStillText() {
        XCTAssertEqual(events(for: "n"), [.text("n", [])])
    }

    /// DEC mode 2031's two reports, dark and light, each on its own.
    func testTheColourSchemeReportIsItsOwnEvent() {
        XCTAssertEqual(events(for: "\u{1B}[?997;1n"), [.colourScheme(.dark)])
        XCTAssertEqual(events(for: "\u{1B}[?997;2n"), [.colourScheme(.light)])
        XCTAssertEqual(events(for: "\u{1B}[?997;1n").map(\.canonicalTrace), ["colourScheme dark"])
        XCTAssertEqual(events(for: "\u{1B}[?997;2n").map(\.canonicalTrace), ["colourScheme light"])
    }

    /// A private `n` is a report *of a mode*, and the number in front of it says which. One krd never
    /// asked for is dropped rather than counted as an answer: a phantom answer is what the probe
    /// cannot survive (issue #212), so silence is the safe half of the trade. So is a body that is
    /// not the report's shape — three parameters, or none.
    func testAPrivateNThatNamesNoColourSchemeEmitsNothing() {
        for sequence in ["\u{1B}[?1;2n", "\u{1B}[?12n", "\u{1B}[?62;4n", "\u{1B}[?997n",
                         "\u{1B}[?997;0n", "\u{1B}[?997;3n", "\u{1B}[?997;1;2n",
                         "\u{1B}[?997;1;", "\u{1B}[?997;n"] {
            XCTAssertTrue(events(for: sequence).isEmpty, sequence)
        }
    }

    /// The other half of the classifier: a **non**-private `n` is untouched, including the spelling
    /// with no parameter at all (`CSI n` is `CSI 0n` with the default left out).
    func testAPlainNIsStillTheStatusReport() {
        XCTAssertEqual(events(for: "\u{1B}[n"), [.statusReport])
        XCTAssertEqual(events(for: "\u{1B}[5n"), [.statusReport])
    }

    func testTheColourSchemeReportSurvivesBeingSplitAcrossReads() {
        var out: [Event] = []
        let parser = InputParser()
        parser.onEvent = { out.append($0) }
        parser.feed(Array("\u{1B}[?997;".utf8))
        XCTAssertTrue(out.isEmpty)
        parser.feed(Array("2n".utf8))
        XCTAssertEqual(out, [.colourScheme(.light)])
    }
}
