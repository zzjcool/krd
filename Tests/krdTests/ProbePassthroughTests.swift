import XCTest
@testable import krd
@testable import krdcore

/// The geometry probe is the one APC path that runs before `Writer` exists, and it is the path a tmux
/// pane cannot afford to lose: `a=t` is how krd learns a cell's size (issue #107 rework).
///
/// These pin the *bytes* the probe sends, without a terminal: before the rework those APCs were
/// `Darwin.write`n raw, so inside tmux the multiplexer ate the question and krd fell back to a
/// guessed cell — the exact failure `--passthrough` exists to prevent.
///
/// Six APCs now, not three (issue #217): the probe asks two graphics questions in one write, `U=1`
/// and `a=f`, and each needs an image to point at - four asked APCs (two silent transmits, the
/// frame question, the placement) and one delete per transmitted image.
final class ProbePassthroughTests: XCTestCase {
    private let esc = "\u{1B}"

    /// The bodies, in the order they are written: the frame question before the placement, because
    /// the read stops on the placement's answer (`PaneGeometryTests` pins that order).
    private let bodies = ["Ga=t,f=24,s=1,v=1,q=2,i=31;AAAA",
                          "Ga=t,f=24,s=1,v=1,q=2,i=32;AAAA",
                          "Ga=f,f=24,s=1,v=1,q=0,i=32;AAAA",
                          "Gi=31,p=1,a=p,U=1,q=0,c=1,r=1",
                          "Ga=d,d=i,i=31",
                          "Ga=d,d=i,i=32"]

    override func tearDown() {
        GraphicsAPC.passthrough = false   // process-wide by design: never leak into another case
        super.tearDown()
    }

    func testTheProbePayloadIsEnvelopedWhenPassthroughIsOn() {
        GraphicsAPC.passthrough = true
        let payload = TermGeometry.graphicsProbePayload()
        XCTAssertTrue(GraphicsAPC.isFullyEnveloped(payload),
                      "all \(payload.count) probe bytes must be inside envelopes")
        let text = String(decoding: payload, as: UTF8.self)
        XCTAssertEqual(occurrences(of: TmuxPassthrough.prefix, in: text), 6,
                       "four asked APCs and two deletes, one envelope each")
        for body in bodies {
            XCTAssertTrue(text.contains(body), "the probe body is unchanged, only enveloped: \(body)")
        }
        // No *bare* introducer may survive: every `ESC _` in there has to be the doubled one that
        // follows `ESC Ptmux;`, which is what the auditor above already proved byte by byte.
        XCTAssertEqual(occurrences(of: "\(esc)\(esc)_", in: text), 6,
                       "each APC's introducer is exactly the doubled form")
        XCTAssertEqual(occurrences(of: "\(esc)_", in: text), 6,
                       "and no undoubled `ESC _` exists anywhere in the probe payload")
    }

    /// The other half of the contract: with the flag off the probe is byte-identical to what krd
    /// has always sent, so a normal terminal sees no envelope at all. Written out rather than
    /// derived from `bodies`, so the byte contract is readable in one place.
    func testTheProbePayloadIsRawWhenPassthroughIsOff() {
        GraphicsAPC.passthrough = false
        let text = String(decoding: TermGeometry.graphicsProbePayload(), as: UTF8.self)
        XCTAssertEqual(text,
                       "\(esc)_Ga=t,f=24,s=1,v=1,q=2,i=31;AAAA\(esc)\\"
                       + "\(esc)_Ga=t,f=24,s=1,v=1,q=2,i=32;AAAA\(esc)\\"
                       + "\(esc)_Ga=f,f=24,s=1,v=1,q=0,i=32;AAAA\(esc)\\"
                       + "\(esc)_Gi=31,p=1,a=p,U=1,q=0,c=1,r=1\(esc)\\"
                       + "\(esc)_Ga=d,d=i,i=31\(esc)\\"
                       + "\(esc)_Ga=d,d=i,i=32\(esc)\\")
    }

    /// Both probe images are deleted, one delete each: a single write now transmits two images
    /// (issue #217), and a transmit nobody deletes is a picture the terminal holds for the life of
    /// the pane - on the wall, at the probe's own 1x1 size, in a corner it does not belong in.
    func testTheProbeDeletesBothOfItsImages() {
        GraphicsAPC.passthrough = false
        let text = String(decoding: TermGeometry.graphicsProbePayload(), as: UTF8.self)
        XCTAssertEqual(occurrences(of: "Ga=d,d=i,i=", in: text), 2,
                       "one delete per transmitted image")
        XCTAssertTrue(text.contains("\(esc)_Ga=d,d=i,i=31\(esc)\\"), "image 31 is left on the pane")
        XCTAssertTrue(text.contains("\(esc)_Ga=d,d=i,i=32\(esc)\\"), "image 32 is left on the pane")
        XCTAssertTrue(text.hasSuffix("\(esc)_Ga=d,d=i,i=32\(esc)\\"),
                      "the deletes come last: an `a=d` ahead of its own `a=p` would remove the "
                      + "image the placement points at")
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
