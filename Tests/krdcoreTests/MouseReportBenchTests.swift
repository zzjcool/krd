import XCTest
@testable import krdcore

/// #105, measured: ns per SGR mouse report, the string path against the cursor scan, on the
/// machine that runs the suite. The machine is shared (other lanes build and test on it), so the
/// numbers are the *minimum of five passes* and the ratio is what to read — not the absolute value.
///
/// It prints, it does not assert a duration: a wall-clock threshold in CI is a flaky test, and the
/// cost that matters is the one a reader can re-measure. Run it with
/// `swift test -c release --filter MouseReportBenchTests`; `-c release` is mandatory, the debug
/// build's bounds checks and missing inlining change both sides by an order of magnitude.
final class MouseReportBenchTests: XCTestCase {
    private let report = "<35;100;40"
    private let reports = 50_000
    private let passes = 5

    private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private func minOfPasses(_ body: () -> Int) -> (ns: Double, sink: Int) {
        var best = Double.infinity
        var sink = 0
        for _ in 0..<passes {
            let start = now()
            sink = body()
            let elapsed = Double(now() - start)
            best = Swift.min(best, elapsed)
        }
        return (best / Double(reports), sink)
    }

    /// `parseEscape` + `handleMouse` as they were: a `String` for the parameter body, `dropFirst`,
    /// `split`, `compactMap { Int($0) }`, then the same `MouseReport`.
    private func legacy(_ body: ArraySlice<UInt8>, isRelease: Bool) -> MouseReport? {
        let params = String(bytes: body, encoding: .utf8) ?? ""
        guard params.hasPrefix("<") else { return nil }
        let parts = params.dropFirst().split(separator: ";").compactMap { Int($0) }
        guard parts.count >= 3 else { return nil }
        let b = parts[0]
        return MouseReport(button: b & 3, x: parts[1], y: parts[2],
                           isWheel: (b & 64) != 0, isRelease: isRelease,
                           isMotion: (b & 32) != 0,
                           mods: InputParser.mouseModifiers(b))
    }

    func testOneMouseReportBeforeAndAfter() throws {
        let body = Array(report.utf8)
        let sequence = Array("\u{1B}[".utf8) + body + [UInt8(ascii: "M")]

        let before = minOfPasses {
            var sink = 0
            for _ in 0..<reports { sink &+= legacy(body[...], isRelease: false)?.x ?? 0 }
            return sink
        }
        // `withUnsafeBufferPointer` inside the loop, once per report: that is what `parseEscape`
        // does, so the column is not flattered by a hoist the production path does not have.
        let after = minOfPasses {
            var sink = 0
            for _ in 0..<reports {
                body.withUnsafeBufferPointer { bytes in
                    sink &+= InputParser.scanMouseSGR(bytes: bytes, start: 1, end: bytes.count,
                                                      isRelease: false)?.x ?? 0
                }
            }
            return sink
        }
        // The same bytes through the real state machine, one report per `feed` — what a terminal
        // with `?1003h` motion reporting actually does. One long-lived parser, as in `InputReader`.
        let input = InputParser()
        var received = 0
        input.onEvent = { event in
            if case let .mouse(report) = event { received &+= report.x }
        }
        let parser = minOfPasses {
            received = 0
            for _ in 0..<reports {
                input.feed(sequence)
                input.reset()
            }
            return received
        }

        XCTAssertEqual(before.sink, after.sink, "both readings must agree on the reports")
        XCTAssertEqual(before.sink, parser.sink, "both readings must agree on the reports")
        print("""

        [#105] one SGR mouse report <\(report), \(reports) reports, min of \(passes) passes
          \(ProcessInfo.processInfo.operatingSystemVersionString), shared machine, expect a noisy absolute value
          string path (String + dropFirst + split + compactMap)   \(String(format: "%6.1f", before.ns)) ns/report  1.00x
          cursor scan (InputParser.scanMouseSGR)                  \(String(format: "%6.1f", after.ns)) ns/report  \(String(format: "%5.1f", before.ns / after.ns))x
          whole parser (ESC [ < … M, one feed per report)         \(String(format: "%6.1f", parser.ns)) ns/report  \(String(format: "%5.1f", before.ns / parser.ns))x

        """)
    }
}
