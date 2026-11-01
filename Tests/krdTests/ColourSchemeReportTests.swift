import XCTest
@testable import krd
@testable import krdcore

/// The colour-scheme report reaches the probe's counter through exactly one arm of
/// `InputReader.apply`, and this drives that arm the way a running session does (issue #212).
///
/// `RTTProbeTests` owns the arithmetic and `StatusReportTests` the parse; the seam neither can see is
/// between them. `Desk` consumes the probe's answer by *watching the counter* — once
/// `input.statusReplies` moves it calls `rttProbe.reply(at: input.lastStatusReplyAt)` — so an arm
/// that stamped that timestamp would hand the probe a theme change as a completed round trip, and the
/// `min` the link verdict reads would be an instant one. That is the whole bug, and it lives here,
/// not in either half.
final class ColourSchemeReportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The arm traces the reply under `--debug`; with no destination that line lands on the
        // test's stderr, which is not where a suite should put a log. Same temp-file-plus-ring as
        // `DevChordTests`, whose assertions also read `Log.recentLines`.
        Log.configure(explicitPath: NSTemporaryDirectory() + "krd-colourscheme-\(getpid()).log",
                      wantsLogging: true)
    }

    /// A reader wired without a tty (`DevChordTests` is the pattern): `ingest` is one `read(2)`, the
    /// parser is the real one, and `dryRun` means an injection would be logged rather than posted.
    private func reader() -> InputReader {
        let reader = InputReader(viewport: { Viewport(pixelWidth: 320, pixelHeight: 240, cols: 40,
                                                      rows: 15,
                                                      sourceRect: CGRect(x: 0, y: 0, width: 320,
                                                                         height: 240)) },
                                 dryRun: true, forward: true) {}
        reader.trace = true
        return reader
    }

    func testTheThemeReportMovesNeitherTheCounterNorTheTimestamp() {
        let reader = reader()
        let before = Log.recentLines.count
        reader.ingest(Array("\u{1B}[?997;1n".utf8)[...])
        XCTAssertEqual(reader.statusReplies, 0, "a theme change is not an answer to `CSI 5n`")
        XCTAssertEqual(reader.lastStatusReplyAt, 0, "so there is nothing for the tick to consume")
        // …and the arm that counted nothing is the arm that *ran*: without this, a parser that
        // dropped the report would give the same two zeros.
        let added = Array(Log.recentLines.dropFirst(before))
        XCTAssertTrue(added.contains { $0.contains("colour scheme report dark") },
                      "the reader saw the report as a report: \(added)")

        // The answer itself still moves both: that is what says the zeros above are the report being
        // separated out, and not the reader having stopped counting.
        reader.ingest(Array("\u{1B}[0n".utf8)[...])
        XCTAssertEqual(reader.statusReplies, 1)
        XCTAssertGreaterThan(reader.lastStatusReplyAt, 0)
    }
}
