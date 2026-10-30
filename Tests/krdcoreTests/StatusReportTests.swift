import XCTest
@testable import krdcore

/// `CSI 5n` is answered by the terminal with `CSI 0n`, and that answer is the round-trip probe's only
/// measurement (issue #52). Two properties matter, and they pull in opposite directions: the answer
/// must reach `krd` as an event, and it must never become *typing* — a terminal's reply landing in
/// the mirrored machine would press keys nobody pressed.
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
}
