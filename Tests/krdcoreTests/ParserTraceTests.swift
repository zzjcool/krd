import XCTest
@testable import krdcore

/// The input analogue of `GoldenDumpTests` (issue #45): one fed byte sequence, one committed trace.
///
/// The trace is produced by the parser alone (`Event.canonicalTrace`), so it pins the state machine
/// — framing, key decoding, mouse fields, mods — with nothing from the OS layer in the way. The
/// matching `--debug` trace comparison (before/after a refactor) is the other half of the evidence:
/// this fixture catches a *format* change, that one catches a change in what krd does with it.
///
/// Regenerate on an intentional protocol change: `KRD_UPDATE_FIXTURE=1 swift test` — **without
/// `--filter`** (see #43: a filter can skip this bundle and print `Executed 0 tests`, so a green run
/// is not evidence that the fixture was rewritten). The update run prints
/// `input trace written: <path> (<n> lines)`.
final class ParserTraceTests: XCTestCase {
    /// The seven sequences from the issue: plain keys, kitty `CSI u` with modifiers and release, a
    /// drag, a double click, the wheel, Ctrl-V, and an OSC 52 reply.
    private let feed: [String] = [
        "ab\r\t\u{7F}",
        "\u{1B}[?15u" + "\u{1B}[97;5u" + "\u{1B}[97;1:3u" + "\u{1B}[97;1:2u"
            + "\u{1B}[97;2u" + "\u{1B}[1092:0:97;1u"
            + "\u{1B}[A\u{1B}[1;5B\u{1B}OP\u{1B}[1~\u{1B}[3~",
        "\u{1B}[<0;12;7M\u{1B}[<32;15;9M\u{1B}[<0;15;9m",
        "\u{1B}[<0;20;10M\u{1B}[<0;20;10m\u{1B}[<0;20;10M\u{1B}[<0;20;10m",
        "\u{1B}[<64;20;10M\u{1B}[<65;20;10M\u{1B}[<66;20;10M",
        "\u{16}",
        "\u{1B}]52;c;dGVybWluYWwtdGV4dA==\u{1B}\\\u{1B}]0;title\u{07}\u{4E2D}",
        // Issue #109: the terminal's answers on stdin. `KRD_Q=0|1`, so an APC carries the status of
        // a transmit and of a placement, and the DCS is the shape a `tmux` passthrough answers in.
        "\u{1B}_Gi=31;OK\u{1B}\\"
            + "\u{1B}_Gi=137,p=7;EINVAL: decompression failed\u{1B}\\"
            + "\u{1B}P1;2|hello\u{1B}\\",
    ]

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/input-trace.dump")
    }

    /// Feed each sequence as its own chunk, the way a terminal delivers them, and render the trace.
    private func renderTrace() -> String {
        var lines: [String] = []
        let parser = InputParser()
        parser.onEvent = { lines.append($0.canonicalTrace) }
        for chunk in feed {
            parser.feed(Array(chunk.utf8))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func testParserReproducesTheCommittedTrace() throws {
        let got = renderTrace()
        let url = fixtureURL()

        if ProcessInfo.processInfo.environment["KRD_UPDATE_FIXTURE"] != nil {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(got.utf8).write(to: url)
            FileHandle.standardError.write(Data(
                "input trace written: \(url.path) (\(got.split(separator: "\n").count) lines)\n".utf8))
            return
        }

        let want = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(got, want, "the parser's trace changed; that is a protocol-level change")
    }

    /// A fixture that matches because both sides are empty proves nothing.
    func testTheTraceIsNotTriviallyEmpty() {
        XCTAssertGreaterThan(renderTrace().split(separator: "\n").count, 20)
    }
}
