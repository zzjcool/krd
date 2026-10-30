import XCTest
@testable import krd
@testable import krdcore
import CoreGraphics

/// The two geometry questions a terminal may answer (issue #56).
///
/// The bug was a `guard let cell`: a terminal that answers only `CSI 14 t` (window size) fell back
/// to the 8x20 constant, so an 80x24 pane produced a 640x480 picture — soft, wrong aspect, exit
/// status 0. These tests pin the decision table, including the numbers, because "not nil" would
/// pass for a geometry that is still 8x20.
final class GeometryQueryTests: XCTestCase {
    /// 137x44 is the reference pane from `docs/BENCHMARK.md`; 2329x1452 is a 17x33 cell grid.
    private let cols = 137
    private let rows = 44
    private var pane: (w: Int, h: Int) { (cols * 17, rows * 33) }

    private func geometry(_ text: String) -> TermGeometry? {
        let answers = TermGeometry.answers(in: text)
        return TermGeometry.fromAnswers(cols: cols, rows: rows,
                                        cell: answers.cell, window: answers.window)
    }

    // MARK: the five cases from the issue

    func testBothAnswersKeepTodaysBehaviour() throws {
        let response = "\u{1B}[6;33;17t\u{1B}[4;1452;2329t"      // cell 17x33, window 2329x1452
        let g = try XCTUnwrap(geometry(response))
        XCTAssertEqual(g.cols, cols)
        XCTAssertEqual(g.rows, rows)
        XCTAssertEqual(g.pixelWidth, 2329)
        XCTAssertEqual(g.pixelHeight, 1452)
        // Both answered: the window is taken as-is, the cell is derived from it.
        XCTAssertEqual(g.cellSize.w, 17, accuracy: 0.001)
        XCTAssertEqual(g.cellSize.h, 33, accuracy: 0.001)
    }

    func testWindowOnlyDerivesTheCell() throws {
        // This is the bug: before #56 this returned nil and the caller assumed 8x20 -> 1096x880.
        let g = try XCTUnwrap(geometry("\u{1B}[4;1452;2329t"))
        XCTAssertEqual(g.pixelWidth, 2329)
        XCTAssertEqual(g.pixelHeight, 1452)
        XCTAssertEqual(g.cellSize.w, Double(pane.w) / Double(cols), accuracy: 0.001)
        XCTAssertEqual(g.cellSize.h, Double(pane.h) / Double(rows), accuracy: 0.001)
        XCTAssertEqual(g.cellSize.w, 17, accuracy: 0.001, "not the 8x20 fallback")
        XCTAssertEqual(g.cellSize.h, 33, accuracy: 0.001)
        // The picture is the pane, not a 640x480 (or 1096x880) guess.
        XCTAssertEqual(g.pixelWidth, pane.w)
        XCTAssertEqual(g.pixelHeight, pane.h)
    }

    func testCellOnlyDerivesTheWindow() throws {
        let g = try XCTUnwrap(geometry("\u{1B}[6;33;17t"))
        XCTAssertEqual(g.pixelWidth, cols * 17)
        XCTAssertEqual(g.pixelHeight, rows * 33)
        XCTAssertEqual(g.cellSize.w, 17, accuracy: 0.001)
    }

    func testNoAnswerIsNilSoTheCallerWarns() {
        XCTAssertNil(geometry(""))
        XCTAssertNil(geometry("nothing to do with terminals"))
    }

    func testTruncatedAnswerIsIgnoredNotCrashed() {
        // The terminator has not arrived: the numbers must not be used (they may still be growing).
        XCTAssertNil(geometry("\u{1B}[4;600;800"))
        XCTAssertNil(geometry("\u{1B}[4;600;"))
        XCTAssertNil(geometry("\u{1B}[4;"))
        // A complete answer followed by a truncated one keeps the complete one.
        let g = geometry("\u{1B}[6;33;17t\u{1B}[4;600;")
        XCTAssertEqual(g?.pixelWidth, cols * 17)
    }

    // MARK: edges worth pinning

    func testOrderOfAnswersDoesNotMatter() throws {
        let a = try XCTUnwrap(geometry("\u{1B}[6;33;17t\u{1B}[4;1452;2329t"))
        let b = try XCTUnwrap(geometry("\u{1B}[4;1452;2329t\u{1B}[6;33;17t"))
        XCTAssertEqual(a.pixelWidth, b.pixelWidth)
        XCTAssertEqual(a.pixelHeight, b.pixelHeight)
    }

    func testZeroSizedAnswersAreRejected() {
        // A terminal that answers 0x0 has not measured itself; that is not a cell size.
        XCTAssertNil(geometry("\u{1B}[4;0;0t"))
        XCTAssertNil(geometry("\u{1B}[6;0;17t"))
    }

    func testDegenerateGridIsRejected() {
        XCTAssertNil(TermGeometry.fromAnswers(cols: 0, rows: 0,
                                              cell: PixelSize(w: 17, h: 33), window: nil))
    }

    func testAnswerLabelSaysWhichQuestionWasAnswered() {
        // `--debug` has to be able to say "the cell came from the window", otherwise a soft picture
        // is again something the user can only guess about.
        TermGeometry.lastAnswer = .windowOnly
        XCTAssertEqual(TermGeometry.lastAnswer.label, "CSI 14t (cell derived)")
        XCTAssertEqual(TermGeometry.Answer.cellAndWindow.label, "CSI 16t+14t")
        XCTAssertEqual(TermGeometry.Answer.cellOnly.label, "CSI 16t")
    }
}
