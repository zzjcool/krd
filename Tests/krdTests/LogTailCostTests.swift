import XCTest
@testable import krd

/// The tick cost of the log panel's read, on the file the issue is about (#90): a 19 MB `--debug`
/// log, which is what an hour with a moving pointer writes.
///
/// Opt-in (`KRD_LOGTAIL_COST=1 swift test -c release --filter LogTailCost`), because it writes a 19 MB
/// file and the *before* number is a quarter second per repetition: a suite that paid for this on
/// every run would be slower than the bug it measures. The reader is the real one; `wholeFileTail` is
/// the body this replaces, copied from `Desk.readLogTail` at `0161bff`:
///
/// ```swift
/// guard let path = Log.path, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
/// return Log.tail(of: text, lines: lines)
/// ```
///
/// Both are measured in the same process, on the same file, back to back.
final class LogTailCostTests: XCTestCase {
    private let bytes = 19_000_000
    private let file = NSTemporaryDirectory() + "krd-logtail-cost.log"

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KRD_LOGTAIL_COST"] != nil,
                          "set KRD_LOGTAIL_COST=1: this test writes a 19 MB file")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: file)
    }

    private func makeFile(bytes size: Int) throws {
        let line = Data("krd: frame 12.4 ms cap 6.1 pipe 6.3 tiles 48/48 512 KB q80\n".utf8)
        var data = Data()
        data.reserveCapacity(size)
        while data.count < size { data.append(line) }
        try data.prefix(size).write(to: URL(fileURLWithPath: file))
    }

    /// The read the panel used to do: the whole file, split into lines, last twelve kept.
    private func wholeFileTail() -> [String] {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        return Log.tail(of: text, lines: 12)
    }

    func testTickCostIsBoundedByWhatIsDisplayedAndNotByTheFileSize() throws {
        var rows: [(String, Double, Double, Double)] = []
        for size in [1_000_000, 5_000_000, 19_000_000, 50_000_000] {
            try makeFile(bytes: size)
            var reader = LogTailReader()
            _ = reader.update(path: file)                       // first tick: it re-anchors

            var whole = Double.infinity
            for _ in 0..<3 {
                let t = DispatchTime.now().uptimeNanoseconds
                _ = wholeFileTail()
                whole = min(whole, Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
            }
            var quiet = Double.infinity, anchor = Double.infinity, grown = Double.infinity
            var quietReader = LogTailReader()
            _ = quietReader.update(path: file)
            for _ in 0..<5 {
                let t = DispatchTime.now().uptimeNanoseconds
                _ = quietReader.update(path: file)               // the same file, second tick
                quiet = min(quiet, Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
                let t2 = DispatchTime.now().uptimeNanoseconds
                var fresh = LogTailReader()
                _ = fresh.update(path: file)                     // a panel just opened
                anchor = min(anchor, Double(DispatchTime.now().uptimeNanoseconds - t2) / 1e6)
            }
            for _ in 0..<5 {
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("krd: one more line\n".utf8))
                try handle.close()
                let t = DispatchTime.now().uptimeNanoseconds
                _ = reader.update(path: file)                    // one line appended since the tick
                grown = min(grown, Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
            }
            XCTAssertEqual(reader.update(path: file).last, "krd: one more line", "and it is the right line")
            rows.append((String(format: "%6.1f MB", Double(size) / 1e6), whole, anchor, quiet))
            print(String(format: "  %6.1f MB   whole file %8.2f ms   re-anchor %6.3f ms   unchanged %6.3f ms   one line %6.3f ms",
                         Double(size) / 1e6, whole, anchor, quiet, grown))
        }
        // The claim, in one line: the reader's cost does not follow the file, the old one's does.
        let biggest = rows.last!
        XCTAssertLessThan(biggest.2, 5.0, "a 50 MB log re-anchors in a fraction of a millisecond")
        XCTAssertLessThan(biggest.3, 1.0, "and a tick that finds nothing new is a `stat`")
        XCTAssertGreaterThan(biggest.1, biggest.2 * 50, "which is the magnitude the whole-file read cost")
    }
}
