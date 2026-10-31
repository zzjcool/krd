import XCTest
@testable import krd

/// What the log panel is handed. The panel shows a *window* onto this array and anchors a log at its
/// end (#118), so "the last element is the newest line" has to be true of the array itself.
///
/// The rule that needs a test is the trailing newline: a log file ends in one, and that newline does
/// not start a line. Counting it made the tail one entry longer than the file, and an end-anchored
/// window then spent one of its rows on a blank — at 137x44 that is one of eleven lines.
final class LogTailTests: XCTestCase {
    func testTheNewestLineIsLast() {
        let tail = Log.tail(of: "a\nb\nc\n", lines: 12)
        XCTAssertEqual(tail, ["a", "b", "c"])
        XCTAssertEqual(tail.last, "c", "the newest line is the last one")
    }

    /// A blank line in the middle is a line, and an EOF with no newline is a line: only the newline
    /// that *terminates* the last line is dropped.
    func testBlankLinesInsideAreKeptAndAnUnterminatedLastLineSurvives() {
        XCTAssertEqual(Log.tail(of: "a\n\nb\n", lines: 12), ["a", "", "b"])
        XCTAssertEqual(Log.tail(of: "a\nb", lines: 12), ["a", "b"], "no final newline: nothing to drop")
        XCTAssertEqual(Log.tail(of: "", lines: 12), [], "an empty file has no lines")
    }

    /// The window is the tail, and its size is the caller's: twelve by default, fewer when asked.
    func testItKeepsTheLastLinesOnly() {
        let text = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        XCTAssertEqual(Log.tail(of: text, lines: 12).count, 12)
        XCTAssertEqual(Log.tail(of: text, lines: 12).last, "line 30")
        XCTAssertEqual(Log.tail(of: text, lines: 3), ["line 28", "line 29", "line 30"])
        XCTAssertEqual(Log.tail(of: text, lines: 0), [])
    }
}
