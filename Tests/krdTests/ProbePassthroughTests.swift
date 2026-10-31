import XCTest
@testable import krd
@testable import krdcore

/// The geometry probe is the one APC path that runs before `Writer` exists, and it is the path a tmux
/// pane cannot afford to lose: `a=t` is how krd learns a cell's size (issue #107 rework).
///
/// These pin the *bytes* the probe sends, without a terminal: before the rework the three APCs below
/// were `Darwin.write`n raw, so inside tmux the multiplexer ate the question and krd fell back to a
/// guessed cell — the exact failure `--passthrough` exists to prevent.
final class ProbePassthroughTests: XCTestCase {
    private let esc = "\u{1B}"

    override func tearDown() {
        GraphicsAPC.passthrough = false   // process-wide by design: never leak into another case
        super.tearDown()
    }

    func testTheProbePayloadIsEnvelopedWhenPassthroughIsOn() {
        GraphicsAPC.passthrough = true
        let payload = TermGeometry.placeholderProbePayload()
        XCTAssertTrue(GraphicsAPC.isFullyEnveloped(payload),
                      "all \(payload.count) probe bytes must be inside envelopes")
        let text = String(decoding: payload, as: UTF8.self)
        XCTAssertEqual(occurrences(of: TmuxPassthrough.prefix, in: text), 3, "transmit, placement, delete")
        for body in ["Ga=t,f=24", "Gi=31,p=1,a=p,U=1", "Ga=d,d=i,i=31"] {
            XCTAssertTrue(text.contains(body), "the probe body is unchanged, only enveloped: \(body)")
        }
        // No *bare* introducer may survive: every `ESC _` in there has to be the doubled one that
        // follows `ESC Ptmux;`, which is what the auditor above already proved byte by byte.
        XCTAssertEqual(occurrences(of: "\(esc)\(esc)_", in: text), 3,
                       "each APC's introducer is exactly the doubled form")
        XCTAssertEqual(occurrences(of: "\(esc)_", in: text), 3,
                       "and no undoubled `ESC _` exists anywhere in the probe payload")
    }

    /// The other half of the contract: with the flag off the probe is byte-identical to what krd has
    /// always sent, so a normal terminal sees no envelope at all.
    func testTheProbePayloadIsRawWhenPassthroughIsOff() {
        GraphicsAPC.passthrough = false
        let text = String(decoding: TermGeometry.placeholderProbePayload(), as: UTF8.self)
        XCTAssertEqual(text,
                       "\(esc)_Ga=t,f=24,s=1,v=1,q=2,i=31;AAAA\(esc)\\"
                       + "\(esc)_Gi=31,p=1,a=p,U=1,q=0,c=1,r=1\(esc)\\"
                       + "\(esc)_Ga=d,d=i,i=31\(esc)\\")
    }

    /// `KRD_DELTEST`'s lone delete is the fourth former bypass; it goes through the writer's sink now.
    func testTheDebugDeleteIsEnvelopedToo() {
        GraphicsAPC.passthrough = true
        let writer = ScreenWriter()
        var bytes: [UInt8] = []
        writer.sink = { bytes.append(contentsOf: $0) }
        writer.writeAPC("Ga=d,i=901")
        XCTAssertTrue(GraphicsAPC.isFullyEnveloped(bytes))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("Ga=d,i=901"))
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0, search = haystack[...]
        while let range = search.range(of: needle) {
            count += 1
            search = search[range.upperBound...]
        }
        return count
    }
}
