import Foundation
import XCTest
@testable import krdcore

/// Issue #127: an over-cap OSC reply must never become input.
///
/// A `KRD_Q=0` terminal answers a `Ctrl-V` (an OSC 52 read) with the clipboard as base64, megabytes
/// of it. When the reply outgrew `InputParser.maxEncodedOSC` before its terminator arrived, the
/// parser used to drop only `ESC ]` and feed the rest to the ordinary loop, so the payload was
/// typed into the mirrored desktop (measured on main: 2,800,317 typable events from one body).
///
/// The body below is `maxEncodedOSC + 4096` bytes — the size the issue measured. Most tests feed it
/// in 1 MB reads rather than the read loop's 8 KB because the parser rescans a buffered sequence on
/// every `feed` (the quadratic scan is #105, a different issue); the bounded-memory test feeds
/// small reads on both sides of the cap crossing, and the split-ST test feeds the terminator alone.
final class OSCOverflowTests: XCTestCase {
    private var header: [UInt8] { Array("\u{1B}]52;c;".utf8) }
    private var body: [UInt8] { [UInt8](repeating: 0x41, count: InputParser.maxEncodedOSC + 4096) }
    private var stream: [UInt8] { header + body }

    /// Feed `bytes` in `chunk`-sized reads (the read loop's shape) and return what came out.
    private func parse(_ bytes: [UInt8], chunk: Int = 1 << 20) -> (events: [Event], parser: InputParser) {
        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }
        var i = 0
        while i < bytes.count {
            let end = min(i + chunk, bytes.count)
            parser.feed(Array(bytes[i..<end]))
            i = end
        }
        return (events, parser)
    }

    /// Everything `krd` would turn into a keystroke (or a click); `.notice`/`.osc` are not input.
    private func typable(_ events: [Event]) -> [Event] {
        events.filter {
            switch $0 {
            case .key, .press, .text, .control: return true
            default: return false
            }
        }
    }

    private func notices(_ events: [Event]) -> [String] {
        events.compactMap { if case let .notice(text) = $0 { return text } else { return nil } }
    }

    private func oscs(_ events: [Event]) -> [String] {
        events.compactMap { if case let .osc(body) = $0 { return body } else { return nil } }
    }

    /// `keys.prefix(8)` and nothing more: on main `keys` is 2.8 M events, and an array comparison in
    /// the failure message would dump all of them through the test log.
    private func preview(_ keys: [Event]) -> String {
        keys.prefix(8).map(\.canonicalTrace).joined(separator: " | ")
    }

    // MARK: - the defect

    /// (a) The body alone spills; it must produce nothing that can be typed.
    func testAnUnterminatedOverCapOSCProducesNoKeys() {
        let (events, parser) = parse(stream)
        let keys = typable(events)
        XCTAssertEqual(keys.count, 0, "the body of an over-cap OSC became input: \(preview(keys))")
        XCTAssertEqual(notices(events), ["osc dropped: over cap"], "exactly one notice per dropped reply")
        XCTAssertEqual(oscs(events).count, 0)
        XCTAssertEqual(parser.buffer.count, 0, "the reply is still buffered")
    }

    /// (b) Once the terminator arrives, the parser resumes at the next byte: the body is swallowed,
    /// the keys after it are not.
    func testParsingResumesAfterTheDiscardedReply() {
        let events = parse(stream + Array("\u{1B}\\hi".utf8) + Array("\u{1B}[A".utf8)).events
        let keys = typable(events)
        guard keys.count == 3 else {
            return XCTFail("\(keys.count) typable events after the reply; first: \(preview(keys))")
        }
        XCTAssertEqual(keys.map(\.canonicalTrace),
                       ["text U+68 mods=0", "text U+69 mods=0", "press 126 mods=0 press"],
                       "the bytes after the discarded reply did not parse normally")
        XCTAssertEqual(notices(events).count, 1, "the reply must be dropped with exactly one notice")
    }

    /// (c) The same reply with its terminator present is dropped whole — one notice, no keys, and
    /// no `.osc` event carrying a payload the clipboard layer would only reject anyway.
    func testAnOverCapReplyWithItsTerminatorIsDroppedWhole() {
        let events = parse(stream + Array("\u{1B}\\".utf8)).events
        XCTAssertEqual(typable(events).count, 0, "an over-cap reply with a terminator became input")
        XCTAssertEqual(notices(events).count, 1, "the reply must be dropped with exactly one notice")
        XCTAssertEqual(oscs(events).count, 0, "payload bytes reached an Event")
    }

    /// (d) The buffer never grows with the reply. 64 KB reads accumulate the body across dozens of
    /// feeds before the cap is crossed (the read loop takes many small reads; 64 KB keeps the read
    /// count realistic without paying #105's rescan on every 8 KB read), and the stream continues
    /// past the crossing so the discard state is fed — and observed — more than once.
    func testTheBufferStaysBoundedWhileDiscarding() {
        let chunk = 64 << 10
        let bytes = stream + [UInt8](repeating: 0x41, count: 8 * chunk)
        let parser = InputParser()
        var emitted = 0
        var noticeCount = 0
        parser.onEvent = {
            if case .notice = $0 { noticeCount += 1 } else { emitted += 1 }
        }
        var fed = 0
        while fed < bytes.count {
            let end = min(fed + chunk, bytes.count)
            parser.feed(Array(bytes[fed..<end]))
            fed = end
            XCTAssertLessThan(parser.buffer.count, InputParser.maxEncodedOSC + 32 + chunk,
                              "\(parser.buffer.count) B held after \(fed) fed bytes")
            if fed > InputParser.maxEncodedOSC + 32 {
                XCTAssertEqual(parser.buffer.count, 0,
                               "the discard state still holds \(parser.buffer.count) B after \(fed) fed bytes")
            }
        }
        XCTAssertEqual(emitted, 0, "the crossing of the cap emitted \(emitted) non-notice events")
        XCTAssertEqual(noticeCount, 1, "the reads after the crossing emitted \(noticeCount) notices")
        XCTAssertEqual(parser.buffer.count, 0)
    }

    /// (e) `ST` is two bytes and can be split across reads. The first half must not be mistaken for
    /// the Esc key (the read loop resets the parser on a lone `ESC`), nor lost.
    func testAnSTSplitAcrossTwoReadsStillEndsTheDiscard() {
        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }
        parser.feed(stream + [0x1B])
        parser.feed(Array("\\ok".utf8))
        let keys = typable(events)
        guard keys.count == 2 else {
            return XCTFail("\(keys.count) typable events; a split ST did not end the discard: \(preview(keys))")
        }
        XCTAssertEqual(keys.map(\.canonicalTrace), ["text U+6F mods=0", "text U+6B mods=0"])
        XCTAssertEqual(notices(events).count, 1, "a split ST must still drop the reply with one notice")
    }

    /// (e2) A held `ESC` is only the first half of `ST` if the next read starts with `\`. Any other
    /// byte is still payload: the discard must continue, not resume parsing the body.
    func testAHeldESCThatIsNotAnSTKeepsDiscarding() {
        let parser = InputParser()
        var events: [Event] = []
        parser.onEvent = { events.append($0) }
        parser.feed(stream + [0x1B])
        parser.feed(Array("Aok".utf8))                  // the held ESC was payload, not half of ST
        XCTAssertEqual(typable(events).count, 0, "the discard ended on a non-backslash byte: "
                       + preview(typable(events)))
        parser.feed([0x1B, 0x5C])                       // now a real ST
        parser.feed(Array("ok".utf8))
        let keys = typable(events)
        guard keys.count == 2 else {
            return XCTFail("\(keys.count) typable events after the real ST: \(preview(keys))")
        }
        XCTAssertEqual(keys.map(\.canonicalTrace), ["text U+6F mods=0", "text U+6B mods=0"])
        XCTAssertEqual(notices(events).count, 1)
    }

    /// (f) `BEL` is the other legal OSC terminator.
    func testBELAlsoEndsTheDiscard() {
        let events = parse(stream + [0x07] + Array("ok".utf8)).events
        let keys = typable(events)
        guard keys.count == 2 else {
            return XCTFail("\(keys.count) typable events; BEL did not end the discard: \(preview(keys))")
        }
        XCTAssertEqual(keys.map(\.canonicalTrace), ["text U+6F mods=0", "text U+6B mods=0"])
        XCTAssertEqual(notices(events).count, 1, "BEL must drop the reply with one notice")
    }

    /// (f2) Each dropped reply gets its own notice: the discard state must end at the terminator and
    /// the next sequence must be parsed from its own header.
    func testEachOverCapReplyGetsOneNotice() {
        let reply = stream + Array("\u{1B}\\".utf8)
        let events = parse(reply + reply).events
        XCTAssertEqual(typable(events).count, 0, "a payload byte from either reply became input")
        XCTAssertEqual(notices(events).count, 2, "two dropped replies must produce two notices")
    }

    // MARK: - the replies that must keep working

    /// A clipboard reply that fits the cap still arrives, even when it is fed one short read at a
    /// time; the cap must not have turned into a size limit on legal pastes.
    func testALegalOSCReplyStillArrives() {
        let payload = String(repeating: "A", count: 1024)
        let events = parse(Array("\u{1B}]52;c;\(payload)\u{1B}\\".utf8), chunk: 7).events
        XCTAssertEqual(oscs(events), ["52;c;\(payload)"])
        XCTAssertEqual(notices(events).count, 0, "a legal reply must not be dropped")
        XCTAssertEqual(typable(events).count, 0)
    }

    /// A 2 MB clipboard — the cap `OSC52` enforces — still fits the parser's window. The slack over
    /// `maxEncodedOSC` has to cover `ESC ] 52;c;` and `ST` around the base64; a payload in this test
    /// is a literal, so shrinking `maxEncodedOSC` cannot make the test agree with itself.
    func testATwoMegabyteClipboardReplyStillTerminates() {
        let payload = Data(repeating: 0x41, count: 2 << 20).base64EncodedString()
        let events = parse(Array("\u{1B}]52;c;\(payload)\u{1B}\\".utf8)).events
        XCTAssertEqual(oscs(events).count, 1, "a legal 2 MB clipboard reply was dropped")
        XCTAssertEqual(notices(events).count, 0, "a legal reply must not be dropped")
        XCTAssertEqual(typable(events).count, 0)
    }
}
