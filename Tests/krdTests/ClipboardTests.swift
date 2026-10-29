import XCTest
import Foundation
@testable import krd

/// The pure half of the clipboard bridge (issue #18): direction parsing, the `--no-input` rule, and
/// the OSC 52 framing/limits. The pasteboard half is exercised by hand in the VM (see the PR), since
/// `NSPasteboard.general` needs a logged-in session.
final class ClipboardTests: XCTestCase {
    // MARK: policy

    func testInlineSpecParsesEveryDirection() {
        XCTAssertEqual(ClipboardPolicy(spec: "off"), ClipboardPolicy.off)
        XCTAssertEqual(ClipboardPolicy(spec: "in"), ClipboardPolicy(toTerminal: true, toTarget: false))
        XCTAssertEqual(ClipboardPolicy(spec: "out"), ClipboardPolicy(toTerminal: false, toTarget: true))
        XCTAssertEqual(ClipboardPolicy(spec: "both"), ClipboardPolicy(toTerminal: true, toTarget: true))
        // Spelled the long way round, and case-insensitively: a flag that is a coin flip to type is
        // a flag people get wrong.
        XCTAssertEqual(ClipboardPolicy(spec: "IN"), ClipboardPolicy(toTerminal: true, toTarget: false))
        XCTAssertEqual(ClipboardPolicy(spec: "to-terminal"), ClipboardPolicy(toTerminal: true, toTarget: false))
        XCTAssertEqual(ClipboardPolicy(spec: "to-target"), ClipboardPolicy(toTerminal: false, toTarget: true))
        XCTAssertEqual(ClipboardPolicy(spec: "none"), ClipboardPolicy.off)
    }

    func testUnknownSpecIsNotSilentlyOff() {
        // nil, so the caller can fail with a usage error: "--clipbord=both" must not look like it
        // worked while the feature is quietly disabled.
        XCTAssertNil(ClipboardPolicy(spec: "nope"))
        XCTAssertNil(ClipboardPolicy(spec: ""))
        XCTAssertNil(ClipboardPolicy(spec: "inout"))
    }

    func testReadOnlyViewerKeepsOnlyTheReadDirection() {
        let both = ClipboardPolicy(spec: "both")!
        XCTAssertEqual(both.allowing(noInput: true), ClipboardPolicy(toTerminal: true, toTarget: false))
        XCTAssertEqual(both.allowing(noInput: false), both)
        let out = ClipboardPolicy(spec: "out")!
        XCTAssertEqual(out.allowing(noInput: true), ClipboardPolicy.off)
        XCTAssertEqual(ClipboardPolicy.off.allowing(noInput: true), ClipboardPolicy.off)
    }

    func testDescriptionsRoundTrip() {
        for spec in ["off", "in", "out", "both"] {
            XCTAssertEqual(ClipboardPolicy(spec: spec)?.description, spec)
        }
    }

    // MARK: OSC 52 framing

    func testEncodeIsTheSequenceTerminalsAccept() {
        let data = Data("hi".utf8)                    // base64 "aGk="
        XCTAssertEqual(OSC52.encode(data), "\u{1B}]52;c;aGk=\u{1B}\\")
        // ST, not BEL: BEL is legal OSC, but a stray 0x07 in a terminal's parser heals worse.
        XCTAssertTrue(OSC52.encode(data).hasSuffix("\u{1B}\\"))
    }

    func testDecodeRoundTripsUTF8() {
        let text = "中文 🙂 emoji and ascii"
        let encoded = OSC52.encode(Data(text.utf8))
        // Strip the framing the way the input parser does before calling decode.
        let inner = String(encoded.dropFirst(2).dropLast(2))    // "52;c;<b64>"
        let decoded = OSC52.decode(parameters: inner)
        XCTAssertEqual(decoded.map { String(decoding: $0, as: UTF8.self) }, text)
    }

    func testDecodeRejectsWhatWeDoNotOwn() {
        XCTAssertNil(OSC52.decode(parameters: "52;c;?"), "a read request is not a payload")
        XCTAssertNil(OSC52.decode(parameters: "0;c;aGk="), "not OSC 52")
        XCTAssertNil(OSC52.decode(parameters: "52;p;aGk="), "primary selection, not the clipboard")
        XCTAssertNil(OSC52.decode(parameters: "52;c;"), "empty payload")
        XCTAssertNil(OSC52.decode(parameters: "52;c;not base64!!"))
    }

    func testDecodeRejectsPayloadsOverTheCap() {
        // Constructing 2 MB+1 of base64 is the point: the cap has to hold before the decode
        // allocates anything, and an over-cap clipboard is dropped rather than pasted halfway.
        let overCap = String(repeating: "A", count: OSC52.maxEncodedBytes + 8)
        XCTAssertNil(OSC52.decode(parameters: "52;c;\(overCap)"))

        let justOver = Data(repeating: 0x41, count: OSC52.maxBytes + 1)
        XCTAssertGreaterThan(justOver.count, OSC52.maxBytes)
        XCTAssertNil(OSC52.decode(parameters: "52;c;\(justOver.base64EncodedString())"))
    }

    func testDecodeAcceptsAPayloadAtTheCap() {
        let atCap = Data(repeating: 0x41, count: OSC52.maxBytes)
        let decoded = OSC52.decode(parameters: "52;c;\(atCap.base64EncodedString())")
        XCTAssertEqual(decoded?.count, OSC52.maxBytes)
    }

    func testEncodedBoundIsBigEnoughForTheCap() {
        // The input parser bounds an unterminated OSC by `maxEncodedBytes`; if that were smaller
        // than the base64 of a payload at the cap, a legal paste would be dropped mid-sequence.
        let atCap = Data(repeating: 0x42, count: OSC52.maxBytes).base64EncodedString()
        XCTAssertLessThan(atCap.utf8.count, OSC52.maxEncodedBytes)
    }

    func testReadRequestAsksForTheClipboardSelection() {
        XCTAssertEqual(OSC52.readRequest, "\u{1B}]52;c;?\u{1B}\\")
    }
}
