import XCTest
@testable import krdcore

/// The unicode-placeholder transport (`emitPanelAsPlaceholder`), pinned byte by byte.
///
/// Why this is worth its own file: the whole point of the transport is that the *terminal* sizes the
/// picture, so krd's bytes carry no pixel geometry at all - only a cell rectangle and a grid of
/// placeholder characters. If that grid is off by one cell, on a terminal that honours `U=1` the
/// picture is the wrong shape, and on a terminal that does not honour it the leftovers show as
/// missing-glyph boxes. Neither failure can be seen from inside a test process any other way.
final class PlaceholderTests: XCTestCase {
    private let placeholder = "\u{10EEEE}"

    /// One 3x2 picture into a 10x5 pane.
    private func emit(cols: Int = 3, rows: Int = 2, row: Int = 2, col: Int = 4,
                      paneCols: Int = 10, paneRows: Int = 5) -> String {
        let writer = ScreenWriter()
        var bytes: [UInt8] = []
        writer.sink = { bytes.append(contentsOf: $0) }
        writer.beginSession()
        writer.beginFrame()
        let pixels = [UInt8](repeating: 0x40, count: cols * rows * 4)
        let sent = writer.emitPanelAsPlaceholder(id: 5000, placementID: 9000, row: row, col: col,
                                                 cols: cols, rows: rows, pixels: pixels,
                                                 width: cols, height: rows, level: 3,
                                                 paneCols: paneCols, paneRows: paneRows)
        writer.endFrame()
        writer.endSession()
        XCTAssertGreaterThan(sent, 0, "a placeholder panel must transmit the picture")
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The placement is the picture's cell rectangle, and it is a *virtual* one (`U=1`) - an image
    /// that also carried `c`/`r` on the transmit would be placed twice.
    func testTheVirtualPlacementCarriesTheRectAndTheTransmitCarriesNoPlacement() throws {
        let out = emit()
        XCTAssertTrue(out.contains("a=p,U=1,q=2,c=3,r=2"),
                      "the virtual placement must be the picture's cells: \(out.prefix(200))")
        // The transmit chunk: `a=t` must not mention `c=`, `r=` or `U=1`.
        let chunks = out.components(separatedBy: "\u{1B}_").filter { $0.hasPrefix("G") }
        let transmits = chunks.filter { $0.contains("a=t") }
        XCTAssertFalse(transmits.isEmpty)
        for chunk in transmits {
            XCTAssertFalse(chunk.contains("U=1"), "a transmit must not be a placement")
            XCTAssertFalse(chunk.contains(",c="), "a transmit must not carry a cell count")
        }
    }

    /// Exactly `cols * rows` placeholder cells, and one row diacritic per row - the protocol lets a
    /// cell inherit "the cell to its left, column + 1", so only the first cell of a row needs one.
    func testTheGridHasOneCellPerCellAndOneDiacriticPerRow() {
        let out = emit()
        // Counted in unicode *scalars*: a placeholder plus its row diacritic is one grapheme
        // cluster in Swift's String, so a character-wise count would miss every row's first cell.
        let cells = out.unicodeScalars.filter { $0 == "\u{10EEEE}" }.count
        XCTAssertEqual(cells, 3 * 2, "found \(cells) placeholder cells for a 3x2 picture")
        XCTAssertTrue(out.contains(placeholder + "\u{0305}"), "row 0 is U+0305")
        XCTAssertTrue(out.contains(placeholder + "\u{030D}"), "row 1 is U+030D")
    }

    /// The id travels in the foreground colour, three bytes of it, so a terminal knows which image a
    /// placeholder cell belongs to without a second escape.
    func testTheImageIdIsTheCellForegroundColour() {
        let out = emit()
        XCTAssertTrue(out.contains("\u{1B}[38;2;0;19;136m"), "5000 = 0x001388 in truecolor")
    }

    /// A pending wrap at the final cell of the final row scrolls the grid, which drags every
    /// placement on it one row up. `WallLayout.clip` keeps the layout out of that cell; the emitter
    /// must not write it even if a caller asks.
    func testTheFinalCellOfTheFinalRowIsNeverWritten() {
        // Row 5 of a 5-row pane, starting at column 9 of 10: writing 4 cells would reach column 13,
        // and the cell at column 10 is the last one on the last row - the pending wrap there scrolls
        // the whole grid. One cell is all that may be written.
        let out = emit(cols: 4, rows: 1, row: 5, col: 9, paneCols: 10, paneRows: 5)
        let cells = out.unicodeScalars.filter { $0 == "\u{10EEEE}" }.count
        XCTAssertEqual(cells, 1, "the last column of the last row would wrap and scroll")
        // One row up there is room, so the same picture is written in full.
        let above = emit(cols: 4, rows: 1, row: 4, col: 7, paneCols: 10, paneRows: 5)
        XCTAssertEqual(above.unicodeScalars.filter { $0 == "\u{10EEEE}" }.count, 4)
    }

    /// The table is kitty's `rowcolumn-diacritics.txt` in order; the first three are the ones any
    /// wall draws every frame, so a shuffled table would be visible immediately.
    func testTheDiacriticTableIsInKittyOrder() {
        XCTAssertEqual(ScreenWriter.placeholderDiacritics.count, 256)
        XCTAssertEqual(ScreenWriter.placeholderDiacritics[0], "\u{0305}")
        XCTAssertEqual(ScreenWriter.placeholderDiacritics[1], "\u{030D}")
        XCTAssertEqual(ScreenWriter.placeholderDiacritics[2], "\u{030E}")
        // Every entry must be a combining mark, or the terminal draws it as a character of its own.
        for scalar in ScreenWriter.placeholderDiacritics {
            XCTAssertTrue(scalar.unicodeScalars.allSatisfy { $0.properties.generalCategory == .nonspacingMark },
                          "\(scalar) is not a combining mark")
        }
        XCTAssertNil(ScreenWriter.placeholderDiacritic(256), "past the table there is no row mark")
    }
}
