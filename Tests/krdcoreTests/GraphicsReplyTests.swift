import XCTest
@testable import krdcore

/// Round C / bug-input: the terminal *answers* graphcis requests on the same stdin that carries
/// keystrokes. Nothing here needs a terminal — `InputParser` is the pure half, and a reply is just
/// bytes — so these tests state exactly what the parser is supposed to do with the answers kitty's
/// graphics protocol defines.
///
/// Today every one of these fails: APC is not a case in the escape switch
/// (`Sources/krdcore/Input.swift:113-155`), so `ESC _ …` falls through to the Alt-key branch at
/// `:152` and the reply becomes keystrokes.
final class GraphicsReplyTests: XCTestCase {
    /// Everything a parsed stream would turn into a key press, an injected character or a control
    /// byte — i.e. the events that reach the mirrored desktop.
    private func injected(_ bytes: [UInt8], chunk: Int? = nil) -> [Event] {
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
        return events.filter {
            switch $0 {
            case .key, .press, .text, .control: return true
            case .mouse, .osc, .keyboardFlags, .statusReport, .notice: return false
            }
        }
    }

    private func trace(_ events: [Event]) -> String {
        events.map(\.canonicalTrace).joined(separator: " | ")
    }

    // MARK: - APC (`ESC _ … ST`): where every graphics reply comes back

    /// A successful tile placement, `KRD_Q=0` (`docs/PROTOCOL.md` §8). 13 bytes.
    func testAPCSuccessReplyIsNotTypedIntoTheDesktop() {
        let reply = Array("\u{1B}_Gi=31;OK\u{1B}\\".utf8)
        let events = injected(reply)
        XCTAssertEqual(events.count, 0, "APC reply became input: \(trace(events))")
    }

    /// A kitty *error* reply — the whole point of issue #109: a refused tile must be readable.
    func testAPCErrorReplyIsNotTypedIntoTheDesktop() {
        let reply = Array("\u{1B}_GEINVAL: decompression failed\u{1B}\\".utf8)
        let events = injected(reply)
        XCTAssertEqual(events.count, 0, "APC error reply became input: \(trace(events))")
    }

    /// The same reply split across two reads (a terminal writes it in one go, an ssh pty does not).
    func testAPCReplySplitAcrossReadsIsNotTyped() {
        let reply = Array("\u{1B}_Gi=31,p=1;OK\u{1B}\\".utf8)
        for split in 1..<reply.count {
            let events = injected(Array(reply[0..<split]) + Array(reply[split...]))
            XCTAssertEqual(events.count, 0, "split at \(split): \(trace(events))")
        }
        // ... and fed one byte at a time, which is what a slow pty actually does.
        let events = injected(reply, chunk: 1)
        XCTAssertEqual(events.count, 0, "byte-at-a-time: \(trace(events))")
    }

    /// A reply that is still arriving must not be typed *while* it is incomplete either.
    func testAPCPrefixAloneEmitsNothing() {
        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }
        parser.feed(Array("\u{1B}_Gi=31,p=1".utf8))
        XCTAssertEqual(events.count, 0, "an unfinished APC leaked: \(trace(events))")
    }

    /// DCS (`ESC P`), SOS (`ESC X`) and PM (`ESC ^`) are the same class of sequence: replies, not
    /// keys. A terminal that answers `CSI 6n` inside a DCS, or a `tmux` passthrough, lands here.
    func testOtherStringSequencesAreNotTypedEither() {
        XCTAssertEqual(injected(Array("\u{1B}P1;2|hello\u{1B}\\".utf8)).count, 0, "DCS became input")
        XCTAssertEqual(injected(Array("\u{1B}Xjunk\u{1B}\\".utf8)).count, 0, "SOS became input")
        XCTAssertEqual(injected(Array("\u{1B}^junk\u{1B}\\".utf8)).count, 0, "PM became input")
    }

    /// `KRD_Q=0` also makes the terminal answer the *transmit* (`ESC _ G a=t …`), with the same
    /// `i=<id>;OK`/`;E…` body. Same requirement, no `p=`.
    func testTransmitReplyIsNotTyped() {
        let reply = Array("\u{1B}_Gi=100;OK\u{1B}\\".utf8)
        let events = injected(reply)
        XCTAssertEqual(events.count, 0, "transmit reply became input: \(trace(events))")
    }
}
