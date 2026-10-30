import XCTest
@testable import krdcore

/// Round C / bug-input: the parser's *edges* — an unterminated sequence, an oversized sequence,
/// and 10k random byte strings. `InputParser` is pure, so all of this runs without a tty.
final class ParserBoundaryTests: XCTestCase {
    private func parse(_ bytes: [UInt8], chunk: Int? = nil) -> [Event] {
        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }
        if let chunk {
            var i = 0
            while i < bytes.count {
                let end = min(i + chunk, bytes.count)
                parser.feed(Array(bytes[i..<end]))
                i = end
            }
        } else {
            parser.feed(bytes)
        }
        return events
    }

    private func typable(_ events: [Event]) -> [Event] {
        events.filter {
            switch $0 {
            case .key, .press, .text, .control: return true
            default: return false
            }
        }
    }

    // MARK: - the quadratic path

    /// A CSI that never terminates (a truncated `ESC [ <…`, a terminal that died mid-sequence, a
    /// stray `ESC [` from a paste) is re-scanned from index 2 on **every** feed, and the buffer is
    /// never bounded. 10k such bytes therefore cost ~50M byte comparisons instead of 10k.
    ///
    /// The bound is deliberately loose (10x what a linear scan needs, measured on this box) so the
    /// test states the *shape* of the cost, not a machine.
    func testUnterminatedSIBytesAreNotQuadratic() {
        let n = 10_000
        let bytes = Array("\u{1B}[".utf8) + [UInt8](repeating: 0x31, count: n)   // ESC [ 1111…
        let start = Date()
        let events = parse(bytes, chunk: 1)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(events.count, 0, "an unterminated CSI must emit nothing")
        print("bug-input: \(n) unterminated CSI bytes one at a time -> "
              + String(format: "%.1f ms", elapsed * 1000))
        XCTAssertLessThan(elapsed, 0.050,
                          "byte-at-a-time unterminated CSI is quadratic: "
                          + "\(String(format: "%.1f ms", elapsed * 1000)) for \(n) bytes")
    }

    /// The result must not depend on how the bytes were cut up — the same stream in one read and
    /// one byte at a time has to produce the same events, forever.
    func testChunkingDoesNotChangeTheResult() {
        let stream = Array("hi\u{1B}[A\u{1B}[1;5A\u{1B}[97;5u\u{1B}[<35;4;5M\u{1B}]52;c;aGk=\u{1B}\\ok".utf8)
        let whole = parse(stream)
        for chunk in [1, 2, 3, 5, 7, 11] {
            XCTAssertEqual(parse(stream, chunk: chunk).map(\.canonicalTrace),
                           whole.map(\.canonicalTrace), "chunk \(chunk)")
        }
    }

    /// An unterminated sequence at EOF must not be replayed as keys, and the buffer must be
    /// bounded: 4 MB of `ESC [ 1…` with no final byte is a terminal that stopped talking.
    func testAnUnfinishedSequenceAtEOFIsBounded() {
        let bytes = Array("\u{1B}[".utf8) + [UInt8](repeating: 0x31, count: 4 << 20)
        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }
        parser.feed(bytes)
        XCTAssertEqual(typable(events).count, 0, "unfinished CSI replayed as input")
        print("bug-input: 4 MB unterminated CSI leaves \(parser.buffer.count) B buffered")
        XCTAssertLessThan(parser.buffer.count, 64 << 10,
                          "\(parser.buffer.count) B of an unterminated CSI is held forever")
    }

    /// An OSC that grows past the cap is dropped *head first* (`Input.swift:143-148`) and the rest
    /// of the body is then parsed as plain bytes. A clipboard read bigger than the cap therefore
    /// types its own base64 payload into the mirrored desktop.
    func testOversizedOSCDoesNotSpillItsPayloadAsKeys() {
        // Fed in 8 KB reads and stopped at the first typable event, because the spill itself is
        // quadratic (`removeFirst` per emitted key): the whole 2.8 MB at once takes 67 s here.
        let body = String(repeating: "A", count: InputParser.maxEncodedOSC + 4096)
        let stream = Array("\u{1B}]52;c;\(body)".utf8)
        let parser = InputParser()
        var leaked: [Event] = []
        parser.onEvent = { if case .notice = $0 { return }; leaked.append($0) }
        var i = 0
        while i < stream.count, leaked.isEmpty {
            let end = min(i + 8192, stream.count)
            parser.feed(Array(stream[i..<end]))
            i = end
        }
        print("bug-input: oversized OSC -> \(leaked.count) typable events from \(i) fed bytes; "
              + "first: \(leaked.first?.canonicalTrace ?? "-")")
        XCTAssertEqual(leaked.filter { event in
            switch event {
            case .key, .press, .text, .control: return true
            default: return false
            }
        }.count, 0, "keys from an oversized OSC body: "
           + "\(leaked.prefix(8).map(\.canonicalTrace).joined(separator: " | "))")
    }

    /// Same thing with the terminator present: an over-cap clipboard reply is still a reply.
    func testOversizedOSCWithTerminatorIsDroppedWhole() {
        let body = String(repeating: "A", count: InputParser.maxEncodedOSC + 4096)
        let stream = Array("\u{1B}]52;c;\(body)\u{1B}\\".utf8)
        XCTAssertEqual(typable(parse(stream)).count, 0, "over-cap clipboard reply became input")
    }

    // MARK: - CSI u / legacy edges

    /// The shapes the hunt list names: modifier chords, release, repeat, unknown codepoints,
    /// too many parameters, SS3 arrows, Alt, Ctrl-A..Z. These are expected to be *fine* — the
    /// test is here so a fix for the sequences above cannot quietly change them.
    func testKittyAndLegacyShapesStillMeanTheSameThing() {
        XCTAssertEqual(parse(Array("\u{1B}[97;5u".utf8)).map(\.canonicalTrace),
                       ["key 97 mods=4 press"])
        XCTAssertEqual(parse(Array("\u{1B}[97;1:3u".utf8)).map(\.canonicalTrace),
                       ["key 97 mods=0 release"])
        XCTAssertEqual(parse(Array("\u{1B}[97;1:2u".utf8)).map(\.canonicalTrace),
                       ["key 97 mods=0 repeated"])
        XCTAssertEqual(parse(Array("\u{1B}[1;2A".utf8)).map(\.canonicalTrace),
                       ["press 126 mods=131072 press"])
        XCTAssertEqual(parse(Array("\u{1B}OA".utf8)).map(\.canonicalTrace),
                       ["press 126 mods=0 press"])
        XCTAssertEqual(parse(Array("\u{1B}a".utf8)).map(\.canonicalTrace),
                       ["text U+61 mods=524288"])
        XCTAssertEqual(parse([0x01]).map(\.canonicalTrace), ["control 1"])
        // Too many parameters must not trap or be misread as a neighbouring key.
        XCTAssertEqual(parse(Array("\u{1B}[15;1;2;3;4;5;6;7;8~".utf8)).map(\.canonicalTrace),
                       ["press 96 mods=0 press"])
        // A codepoint nobody has a key for is still a report, not a crash.
        XCTAssertEqual(parse(Array("\u{1B}[1114111u".utf8)).map(\.canonicalTrace).count, 1)
    }

    /// 10 000 random byte strings: never trap, never loop, and always terminate with a bounded
    /// buffer. A parser that traps leaves the pane in raw mode (TROUBLESHOOTING §22).
    func testRandomBytesNeverTrapOrLoop() {
        var rng = SystemRandomNumberGenerator()
        for iteration in 0..<10_000 {
            let count = Int.random(in: 0...64, using: &rng)
            var bytes: [UInt8] = []
            bytes.reserveCapacity(count)
            for _ in 0..<count {
                // Bias towards the bytes the state machine cares about.
                switch Int.random(in: 0...3, using: &rng) {
                case 0: bytes.append([0x1B, 0x5B, 0x5D, 0x5F, 0x4F, 0x3B, 0x3C, 0x75, 0x7E, 0x07][
                    Int.random(in: 0...9, using: &rng)])
                case 1: bytes.append(UInt8.random(in: 0x20...0x7E, using: &rng))
                default: bytes.append(UInt8.random(in: 0...255, using: &rng))
                }
            }
            let parser = InputParser()
            parser.onEvent = { _ in }
            parser.feed(bytes)
            XCTAssertLessThan(parser.buffer.count, 1 << 20, "iteration \(iteration) buffered "
                              + "\(parser.buffer.count) B from \(count) bytes")
        }
    }
}
