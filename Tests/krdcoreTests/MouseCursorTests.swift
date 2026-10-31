import XCTest
@testable import krdcore

/// #105: the cursor scan in `InputParser.scanMouseSGR` replaced a `String` + `split` +
/// `compactMap` over the same bytes. This file pins the two together: the old reading lives here
/// as `legacyReport`, and every case below is required to agree with it — including the cases where
/// it yields no report at all. Nothing here asserts *how* the scan is implemented, so it stays a
/// behaviour pin rather than a copy of the code.
final class MouseCursorTests: XCTestCase {
    // MARK: the reference: `parseEscape`'s string path before #105

    /// `String(bytes: buffer[2..<i], encoding: .utf8) ?? ""` + `handleCSI`'s `hasPrefix("<")` +
    /// `handleMouse`'s `dropFirst`/`split`/`compactMap`, verbatim.
    private func legacyReport(params: ArraySlice<UInt8>, isRelease: Bool) -> MouseReport? {
        let params = String(bytes: params, encoding: .utf8) ?? ""
        guard params.hasPrefix("<") else { return nil }
        let body = params.dropFirst()
        let parts = body.split(separator: ";").compactMap { Int($0) }
        guard parts.count >= 3 else { return nil }
        let b = parts[0]
        return MouseReport(button: b & 3, x: parts[1], y: parts[2],
                           isWheel: (b & 64) != 0, isRelease: isRelease,
                           isMotion: (b & 32) != 0,
                           mods: InputParser.mouseModifiers(b))
    }

    /// The new reading, called the way `parseEscape` calls it: `params` includes the `<`, the scan
    /// starts just past it.
    private func cursorReport(params: [UInt8], isRelease: Bool) -> MouseReport? {
        params.withUnsafeBufferPointer { bytes in
            InputParser.scanMouseSGR(bytes: bytes, start: 1, end: bytes.count,
                                     isRelease: isRelease)
        }
    }

    /// The real thing: feed the whole sequence to a fresh parser and keep what came out.
    private func events(_ sequence: [UInt8]) -> [Event] {
        final class Sink { var events: [Event] = [] }
        let sink = Sink()
        let parser = InputParser()
        parser.onEvent = { sink.events.append($0) }
        parser.feed(sequence)
        return sink.events
    }

    private func sequence(params: String, final: UInt8) -> [UInt8] {
        Array("\u{1B}[".utf8) + Array(params.utf8) + [final]
    }

    /// The old pipeline for a byte sequence: the first byte in `0x40...0x7E` terminates the CSI
    /// (that is `parseEscape`'s scan), the body up to it becomes the `String` — and a sequence with
    /// no terminator yet emits nothing and stays buffered. It models the mouse branch only, so it
    /// is used for `M`/`m`; the finals that `handleCSI` reads *before* the mouse branch (`n`, `u`) and
    /// the ones that still reach it are pinned against the real parser in
    /// `testTheOtherFinalsKeepTheOldPath`.
    private func legacyEndToEnd(_ sequence: [UInt8]) -> MouseReport? {
        var i = 2
        while i < sequence.count {
            let b = sequence[i]
            if b >= 0x40 && b <= 0x7E {
                return legacyReport(params: sequence[2..<i], isRelease: b == 0x6D)
            }
            i += 1
        }
        return nil
    }

    private let pressM = UInt8(ascii: "M")
    private let releaseM = UInt8(ascii: "m")

    /// One case, three readings: the isolated scan, the string path on the same bytes, and the
    /// whole parser on the sequence those bytes would be sent as.
    private func assertAgrees(_ params: String, final: UInt8, line: UInt = #line) {
        let bytes = Array(params.utf8)
        let isRelease = final == releaseM
        XCTAssertEqual(cursorReport(params: bytes, isRelease: isRelease),
                       legacyReport(params: bytes[...], isRelease: isRelease),
                       "cursor scan disagreed with the string path for <\(params)", line: line)
        let got = events(sequence(params: params, final: final)).compactMap { event -> MouseReport? in
            if case let .mouse(report) = event { return report }
            return nil
        }
        let want = legacyEndToEnd(sequence(params: params, final: final))
        XCTAssertEqual(got, want.map { [$0] } ?? [],
                       "the parser disagreed with the string path for <\(params)", line: line)
    }

    // MARK: well-formed reports

    /// Buttons 0-3, the 32 motion bit, the 4/8/16 modifier bits and the 64-67 wheel block, with
    /// coordinates that are ordinary, zero, negative and past the 223 of the legacy encoding —
    /// both finals, because `M` and `m` are the press/release distinction.
    func testEveryButtonAndCoordinateAgreesWithTheStringPath() {
        let coordinates = [(0, 0), (1, 1), (12, 7), (80, 24), (223, 223), (224, 224),
                           (1000, 4095), (65535, 65535), (-1, -5), (-200, -3200)]
        for b in 0...67 {
            for (x, y) in coordinates {
                assertAgrees("<\(b);\(x);\(y)", final: pressM)
                assertAgrees("<\(b);\(x);\(y)", final: releaseM)
            }
        }
    }

    /// The bits the decoder reads, spelled out: button = `b & 3`, wheel = `b & 64`, motion = `b & 32`,
    /// shift/alt/ctrl = `b & 4/8/16`, and `m` is a release.
    func testTheReportedBitsAreTheDocumentedOnes() {
        XCTAssertEqual(cursorReport(params: Array("<35;100;40".utf8), isRelease: false),
                       MouseReport(button: 3, x: 100, y: 40, isWheel: false, isRelease: false,
                                   isMotion: true, mods: []))
        XCTAssertEqual(cursorReport(params: Array("<64;20;10".utf8), isRelease: false)?.isWheel, true)
        XCTAssertEqual(cursorReport(params: Array("<67;20;10".utf8), isRelease: false)?.button, 3)
        XCTAssertEqual(cursorReport(params: Array("<0;1;2".utf8), isRelease: true)?.isRelease, true)
        XCTAssertEqual(cursorReport(params: Array("<28;1;2".utf8), isRelease: false)?.mods,
                       [.maskShift, .maskAlternate, .maskControl])
        // Past the 223 of the 8-bit encoding, and negative, unharmed.
        let far = cursorReport(params: Array("<0;4096;-37".utf8), isRelease: false)
        XCTAssertEqual(far?.x, 4096)
        XCTAssertEqual(far?.y, -37)
    }

    // MARK: malformed reports

    /// Everything the string path rejects must still be rejected, and everything it accepted by
    /// accident must still be accepted: `split` drops empty fields and `compactMap` drops fields
    /// that are not numbers, so `b`, `x`, `y` are the first three fields that survive.
    func testMalformedReportsAgreeWithTheStringPath() {
        let malformed = [
            "", "<", "<0", "<0;", "<0;1", "<0;1;", "<;", "<;;", "<;;;",
            "<0;;12;7",                 // an empty field vanishes, so 12;7 take x and y
            "<0;x;12;7",                // a non-number vanishes, and the positions shift
            "<0;1;2;3;4",               // a fourth field is not part of the report
            "<0;1;2x", "<0;1; 2", "<0;1;2 ", "<;1;2", "<0;1;2\t",
            "<a;b;c", "<0;1", "<0;;;;;1;2",
            "<0;9223372036854775807;1",  // Int.max is a number
            "<0;9223372036854775808;1",  // Int.max+1 is not: dropped, so x becomes 1
            "<0;-9223372036854775808;1", // Int.min is a number
            "<0;-9223372036854775809;1", // one past Int.min is not: dropped
            "<0;99999999999999999999;1;2",
            "<+1;+2;+3", "<-1;-2;-3", "<007;008;009", "<-0;-0;-0",
            "<-5;10;20", "<0;1;2\u{7F}", // DEL is not a digit
            "<0;é;1;2",                  // valid UTF-8 non-ASCII: still three fields survive
            "<\u{7F};;2", "<0;1;2\u{7F}",
        ]
        for params in malformed {
            assertAgrees(params, final: pressM)
            assertAgrees(params, final: releaseM)
        }
    }

    /// A body that is not valid UTF-8 used to become `""`, which is not a mouse report at all; the
    /// scan is not allowed to turn those bytes into one.
    func testABodyThatIsNotUTF8IsStillNotAReport() {
        let invalid: [[UInt8]] = [
            Array("<0;".utf8) + [0xFF] + Array(";2".utf8),
            Array("<0;1;".utf8) + [0xC3],                 // a truncated two-byte scalar
            Array("<0;1;".utf8) + [0x80, 0x80],
            Array("<0;1;2".utf8) + [0xF0, 0x9F],          // a truncated four-byte scalar
        ]
        for params in invalid {
            XCTAssertNil(cursorReport(params: params, isRelease: false))
            XCTAssertNil(legacyReport(params: params[...], isRelease: false))
            XCTAssertEqual(events(Array("\u{1B}[".utf8) + params + [pressM]).count, 0)
        }
    }

    // MARK: the state machine around it

    /// Only `M`/`m` take the byte path. The rest keep `handleCSI`'s order: `n` is a status report
    /// and `u` is the kitty keyboard query, both read *before* the `<` branch, while `H`, `~`, `A`,
    /// `Z` and `S` fall through to it and emit a mouse report — no terminal sends those, but the
    /// new gate must not change what they do. The last four cases pin the new `buffer[2]` read: a
    /// body that does not start with `<` was never a mouse report.
    func testTheOtherFinalsKeepTheOldPath() {
        func mouse(_ sequence: String) -> [MouseReport] {
            events(Array(sequence.utf8)).compactMap { event -> MouseReport? in
                if case let .mouse(report) = event { return report }
                return nil
            }
        }
        let report = MouseReport(button: 0, x: 1, y: 2, isWheel: false, isRelease: false,
                                 isMotion: false, mods: [])
        for final in ["H", "~", "A", "Z", "S"] {
            XCTAssertEqual(mouse("\u{1B}[<0;1;2\(final)"), [report], "final \(final)")
        }
        XCTAssertEqual(events(Array("\u{1B}[<0;1;2n".utf8)), [.statusReport])
        XCTAssertEqual(events(Array("\u{1B}[<0;1;2u".utf8)), [])
        for sequence in ["\u{1B}[1;2M", "\u{1B}[0M", "\u{1B}[M", "\u{1B}[3;4m"] {
            XCTAssertEqual(mouse(sequence), [], sequence)
        }
    }

    /// A truncated `ESC [ <` keeps its bytes and parses once the rest arrives — the fast path is
    /// re-entered on the growing buffer, not on a stale scan position.
    func testATruncatedReportKeepsItsBytes() {
        let parser = InputParser()
        var got: [Event] = []
        parser.onEvent = { got.append($0) }
        parser.feed(Array("\u{1B}[<0;1;".utf8))
        XCTAssertEqual(got, [])
        XCTAssertEqual(parser.buffer.count, 7)
        parser.feed(Array("2M".utf8))
        XCTAssertEqual(got, [.mouse(MouseReport(button: 0, x: 1, y: 2, isWheel: false,
                                                isRelease: false, isMotion: false, mods: []))])
        XCTAssertEqual(parser.buffer.count, 0)
    }

    /// A report that arrives one byte per `feed` is the same report: the scan runs on whatever is
    /// buffered once the final byte shows up.
    func testAReportSplitAcrossFeedsIsTheSameReport() {
        let bytes = sequence(params: "<35;224;-9", final: pressM)
        let parser = InputParser()
        var got: [Event] = []
        parser.onEvent = { got.append($0) }
        for byte in bytes { parser.feed([byte]) }
        XCTAssertEqual(got, [.mouse(MouseReport(button: 3, x: 224, y: -9, isWheel: false,
                                                isRelease: false, isMotion: true, mods: []))])
    }

    /// A long stream of reports in one feed keeps its order and its count (the buffer is drained
    /// in place; nothing about the queued bytes changes).
    func testAStreamOfReportsKeepsItsOrder() {
        var bytes: [UInt8] = []
        for i in 0..<500 {
            bytes += sequence(params: "<\(i % 68);\(i);\(i + 1)", final: i % 2 == 0 ? pressM : releaseM)
        }
        let got = events(bytes).compactMap { event -> MouseReport? in
            if case let .mouse(report) = event { return report }
            return nil
        }
        XCTAssertEqual(got.count, 500)
        for (i, report) in got.enumerated() {
            XCTAssertEqual(report.button, (i % 68) & 3)
            XCTAssertEqual(report.x, i)
            XCTAssertEqual(report.y, i + 1)
            XCTAssertEqual(report.isRelease, i % 2 == 1)
        }
    }
}
