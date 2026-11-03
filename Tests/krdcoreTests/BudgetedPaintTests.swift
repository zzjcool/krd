import XCTest
import CoreGraphics
@testable import krdcore

/// What a **budgeted** repaint looks like on the wire, and the two primitives a moved picture needs.
///
/// The bug this suite belongs to (issue #257) is measured, not suspected: a full repaint of a 140x45
/// cell mirror is 216 tiles in one `?2026h … ?2026l` block, 2.17 MiB, and the terminal answered `OK`
/// to every image and every placement and still drew a row-major *prefix* of them -- ~108 tiles, six
/// of the twelve tile rows. krd re-sends a tile only when its pixels change, so the rest of the
/// picture stays the terminal's background colour: a staircase of black at the bottom, in whole tile
/// rectangles.
///
/// The fix is three statements about bytes, and they are what this file pins:
///
///  1. a repaint cut into blocks is still **one block per emit** (`?2026h` … `?2026l` around each),
///     and the union of the placements covers every tile exactly once -- nothing duplicated, nothing
///     dropped, no tile outside the grid;
///  2. a tile the terminal already holds can be **re-placed** with no `a=t` at all (`U=1` grid, or a
///     `C=1` pixel placement), which is what a panel open/close costs instead of 2.17 MiB;
///  3. the rows a moved picture vacated can be erased with `2K`, which cannot arm the wrap that would
///     scroll every placement one row up.
///
/// The bytes come from `ScreenWriter.sink` (the seam issue #21 added), so this needs no tty and no
/// threads: the production sequence is replayed in order on one thread.
final class BudgetedPaintTests: XCTestCase {

    // MARK: - protocol needles

    private static let blockOpen = "\u{1B}[?2026h"
    private static let blockClose = "\u{1B}[?2026l"
    private static let placeholderCell = "\u{10EEEE}"

    // MARK: - the writer and its bytes

    /// A `ScreenWriter` plus everything it flushed, as text (every byte krd emits here is ASCII except
    /// the placeholder cells themselves).
    private final class Recorder {
        let writer = ScreenWriter()
        private(set) var bytes: [UInt8] = []
        init() {
            writer.sink = { [weak self] flushed in self?.bytes.append(contentsOf: flushed) }
        }
        var text: String { String(decoding: bytes, as: UTF8.self) }
        func occurrences(of needle: String) -> Int {
            text.components(separatedBy: needle).count - 1
        }
    }

    private let paneCols = 40, paneRows = 12
    private let cellW = 8.0, cellH = 16.0
    private let tileCols = 8, tileRows = 4

    /// A 40x12-cell picture of 5x3 tiles, entire: the aspect is the pane's own, so `paneCols`/
    /// `paneRows` are the pane's and `originCol`/`originRow` stay (1, 1).
    private func makeGrid() -> TileGrid {
        TileGrid.make(paneCols: paneCols, paneRows: paneRows, cellW: cellW, cellH: cellH,
                      aspect: cellW * Double(paneCols) / (cellH * Double(paneRows)),
                      tileCols: tileCols, tileRows: tileRows)
    }

    /// A frame that is cheap to compress and deterministic: one flat colour per tile, no RNG, no clock,
    /// so every tile's payload is a few hundred bytes and the *count* of tiles per block is what the
    /// test controls.
    private func frame(_ grid: TileGrid) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: grid.pixelW * grid.pixelH * grid.bpp)
        for ty in 0..<grid.tilesY {
            for tx in 0..<grid.tilesX {
                let rect = grid.rect(tx, ty)
                let colour = (UInt8(40 + (ty * 17) % 200), UInt8(90 + (tx * 23) % 160), UInt8(120))
                for y in rect.y..<(rect.y + rect.h) {
                    for x in rect.x..<(rect.x + rect.w) {
                        let o = (y * grid.pixelW + x) * grid.bpp
                        pixels[o] = colour.0
                        pixels[o + 1] = colour.1
                        pixels[o + 2] = colour.2
                        if grid.bpp == 4 { pixels[o + 3] = 255 }
                    }
                }
            }
        }
        return pixels
    }

    /// A frame zlib cannot compress (a seeded LCG, so it is still deterministic): what a photographed
    /// tile really costs, which is the number a cells-only pass is compared against.
    private func noisyFrame(_ grid: TileGrid) -> [UInt8] {
        var seed: UInt32 = 0x9E37_79B9
        var pixels = [UInt8](repeating: 0, count: grid.pixelW * grid.pixelH * grid.bpp)
        for i in 0..<pixels.count {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[i] = UInt8((seed >> 16) & 0xFF)
        }
        return pixels
    }

    /// Emit one block of `indices`, exactly as `Desk` does: compress (serially here -- the product's
    /// `concurrentPerform` cannot reorder the emits), then one `beginFrame` … `endFrame` per block.
    private func paint(_ indices: [Int], grid: TileGrid, pixels: [UInt8], into recorder: Recorder) {
        let writer = recorder.writer
        writer.resize(tiles: grid.count)
        writer.beginFrame()
        for index in indices {
            let rect = grid.rect(index % grid.tilesX, index / grid.tilesX)
            guard let tile = ScreenWriter.compress(index: index, rect: rect,
                                                   pixels: grid.extract(pixels, rect: rect),
                                                   level: 6) else {
                XCTFail("tile \(index) did not compress")
                continue
            }
            writer.emit(tile, sync: writer.perTileSync)
        }
        writer.endFrame()
    }

    /// One block of a cells-only pass, exactly as `Desk` assembles it (the erase first, then the
    /// placements, one `beginFrame` … `endFrame` for the lot).
    private func replace(_ indices: [Int], grid: TileGrid, placeholder: Bool,
                         into recorder: Recorder) {
        let writer = recorder.writer
        writer.beginFrame()
        for index in indices {
            let rect = grid.rect(index % grid.tilesX, index / grid.tilesX)
            writer.replaceTilePlacement(index: index, row: rect.row, col: rect.col,
                                        cols: rect.cols, rows: rect.rows,
                                        placeholder: placeholder, sync: writer.perTileSync)
        }
        writer.endFrame()
    }

    /// Every byte that is **not** part of an escape sequence, i.e. every byte a terminal would draw in
    /// a cell. The pane's invariants ("never write the final cell", "no newline") are statements about
    /// this string; the escapes around it are how krd addresses the cells in the first place.
    private func drawnGlyphs(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            guard bytes[i] == 0x1B else {
                out.append(bytes[i])
                i += 1
                continue
            }
            guard i + 1 < bytes.count else { break }
            if bytes[i + 1] == 0x5B {                      // CSI: ESC [ params… final 0x40...0x7E
                i += 2
                while i < bytes.count, bytes[i] < 0x40 || bytes[i] > 0x7E { i += 1 }
                i += 1
            } else if bytes[i + 1] == 0x5F {                // APC: ESC _ … ESC \
                i += 2
                while i + 1 < bytes.count, !(bytes[i] == 0x1B && bytes[i + 1] == 0x5C) { i += 1 }
                i += 2
            } else {
                i += 2
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    override func setUp() {
        super.setUp()
        // Process-wide and set by the probe in a real run; a stray `on` from another suite would put
        // every APC inside a tmux envelope and every byte assertion here would read as a missing
        // needle rather than as this file's subject.
        GraphicsAPC.passthrough = false
    }

    // MARK: - 1. a budgeted repaint unrolls, and still covers the picture exactly once

    /// The whole point: the same 15 tiles, cut into blocks of 4, arrive as four commits of their own --
    /// top to bottom, left to right -- and each tile is placed exactly once. The list of placements a
    /// block carries is the *old* single block's list, sliced: nothing is re-sent, nothing is lost, and
    /// no tile index outside the grid is ever emitted.
    func testABudgetedRepaintIsSeveralBlocksAndCoversEveryTileOnce() {
        let grid = makeGrid()
        let pixels = frame(grid)
        let recorder = Recorder()
        let perBlock = 4
        var blocks: [[Int]] = []
        for start in stride(from: 0, to: grid.count, by: perBlock) {
            let indices = Array(start..<min(start + perBlock, grid.count))
            blocks.append(indices)
            paint(indices, grid: grid, pixels: pixels, into: recorder)
        }

        XCTAssertEqual(grid.count, 15, "5x3 tiles")
        XCTAssertGreaterThanOrEqual(blocks.count, 2, "a budgeted repaint has to be more than one block")
        let text = recorder.text
        XCTAssertEqual(recorder.occurrences(of: Self.blockOpen), blocks.count,
                       "one ?2026h per block")
        XCTAssertEqual(recorder.occurrences(of: Self.blockClose), blocks.count,
                       "and every block is closed, in order")
        XCTAssertFalse(text.contains("\n"), "nothing on the pane may contain a newline")
        XCTAssertFalse(text.contains("Ga=d"), "a repaint never deletes: the placements replace themselves")

        // The union of the placements is every tile exactly once...
        for index in 0..<grid.count {
            XCTAssertEqual(recorder.occurrences(of: "i=\(100 + index),p=\(1000 + index)"), 1,
                           "tile \(index) is placed once")
        }
        // ...and each block carries the next slice of that list, in order, so the picture really is
        // painted top to bottom rather than in whatever order a budget happened to fall on.
        let whole = (0..<grid.count).filter { text.contains("i=\(100 + $0),p=\(1000 + $0)") }
        XCTAssertEqual(whole, blocks.flatMap { $0 }, "the blocks are consecutive slices of the grid")
        XCTAssertEqual(blocks.flatMap { $0 }, Array(0..<grid.count))
    }

    /// A block is *closed* before the next one opens: the terminal commits 4 tiles, then the next 4.
    /// Written as a shape assertion (h, 4x p, l, h, …) because "two blocks" would also be satisfied by
    /// two opens followed by two closes.
    func testEveryBlockIsClosedBeforeTheNextOpens() {
        let grid = makeGrid()
        let pixels = frame(grid)
        let recorder = Recorder()
        paint([0, 1], grid: grid, pixels: pixels, into: recorder)
        paint([2, 3], grid: grid, pixels: pixels, into: recorder)
        let text = recorder.text
        // The stream is exactly: open (tile, tile) close open (tile, tile) close.
        let opens = recorder.occurrences(of: Self.blockOpen)
        let closes = recorder.occurrences(of: Self.blockClose)
        XCTAssertEqual(opens, 2)
        XCTAssertEqual(closes, 2)
        // Each tile appears between a `h` before it and an `l` after it, and the second block's first
        // tile is after the first block's close.
        let secondOpen = text.range(of: Self.blockOpen, options: .backwards)
        let firstClose = text.range(of: Self.blockClose)
        let tile2 = text.range(of: "i=102,p=1002")
        XCTAssertNotNil(secondOpen)
        XCTAssertNotNil(firstClose)
        XCTAssertNotNil(tile2)
        if let secondOpen, let firstClose, let tile2 {
            XCTAssertLessThan(firstClose.lowerBound, secondOpen.lowerBound,
                              "the first block is closed before the second opens")
            XCTAssertLessThan(secondOpen.lowerBound, tile2.lowerBound,
                              "and the second block's tiles come after its open")
        }
    }

    // MARK: - 2. budget 0 is today's single block

    /// `--paint-budget 0` (and every path pinned to it: `--selftest`, `--bench`, `--bench-wire`,
    /// `--replay`, `--pane`) is the old shape byte for byte: **one** synchronized block with every
    /// tile in it. Pinned as a count, not as a payload: the payload is zlib's business and the tests
    /// that own it are the golden dumps.
    func testABudgetOfZeroIsOneBlock() {
        let grid = makeGrid()
        let recorder = Recorder()
        paint(Array(0..<grid.count), grid: grid, pixels: frame(grid), into: recorder)
        XCTAssertEqual(recorder.occurrences(of: Self.blockOpen), 1)
        XCTAssertEqual(recorder.occurrences(of: Self.blockClose), 1)
        for index in 0..<grid.count {
            XCTAssertEqual(recorder.occurrences(of: "i=\(100 + index),p=\(1000 + index)"), 1)
        }
    }

    // MARK: - 3. cells-only: the picture the terminal already holds, moved

    /// A placeholder tile that only moved: no pixels (`a=t`), the virtual placement at the new
    /// rectangle, the invisible cells on it -- and the grid's own first cell at the end, which is the
    /// wrap cancel (`appendPlaceholderGrid`): writing the final cell of the final row arms the
    /// terminal's pending wrap, and the next byte would scroll every placement one row up.
    func testACellsOnlyPlaceholderTileSendsNoPixelsAndEndsOnTheWrapCancel() {
        let grid = makeGrid()
        let rect = grid.rect(1, 1)
        let recorder = Recorder()
        replace([grid.tilesX + 1], grid: grid, placeholder: true, into: recorder)
        let writer = recorder.writer
        let text = recorder.text
        XCTAssertFalse(text.contains("a=t"), "a cells-only placement transmits nothing")
        XCTAssertTrue(text.contains("Gi=\(100 + grid.tilesX + 1),p=\(1000 + grid.tilesX + 1),a=p,U=1,"
                                    + "q=\(writer.quietLabel),c=\(rect.cols),r=\(rect.rows)"),
                      "the virtual placement names the rectangle the terminal should draw into")
        // The invisible grid is written at the given rect, one CUP per row...
        XCTAssertTrue(text.contains("\u{1B}[\(rect.row);\(rect.col)H"))
        XCTAssertTrue(text.contains("\u{1B}[\(rect.row + 1);\(rect.col)H"))
        // ...and the last thing *drawn* is the grid's first cell, i.e. the wrap is cancelled.
        XCTAssertTrue(text.contains("\u{1B}[\(rect.row);\(rect.col)H\u{1B}[?2026l"),
                      "the block has to end on the wrap cancel: \(text.suffix(24))")
        // What it costs is cells and nothing else: `cols x rows` placeholder characters plus the one
        // row diacritic each, and not a printable byte besides.
        XCTAssertEqual(drawnGlyphs(recorder.bytes).unicodeScalars.filter { $0 == "\u{10EEEE}" }.count,
                       rect.cols * rect.rows, "cols x rows cells")
        XCTAssertEqual(recorder.occurrences(of: Self.blockOpen), 1)
        XCTAssertEqual(recorder.occurrences(of: Self.blockClose), 1)
    }

    /// The same move on a terminal that draws pixel placements: a CUP and `a=p` with `C=1`, no
    /// transmit, no placeholder cells. The fixed (id, pid) pair is why no delete is needed: the
    /// placement replaces itself where it now belongs (docs/PROTOCOL.md §4).
    func testACellsOnlyPixelTileIsACursorMoveAndAPlacement() {
        let grid = makeGrid()
        let rect = grid.rect(2, 1)
        let recorder = Recorder()
        replace([grid.tilesX + 2], grid: grid, placeholder: false, into: recorder)
        let writer = recorder.writer
        let text = recorder.text
        XCTAssertFalse(text.contains("a=t"))
        XCTAssertFalse(text.contains(Self.placeholderCell), "pixel placements write no cells")
        XCTAssertTrue(text.contains("Gi=\(100 + grid.tilesX + 2),p=\(1000 + grid.tilesX + 2),a=p,"
                                    + "q=\(writer.quietLabel),C=1,c=\(rect.cols),r=\(rect.rows)"),
                      "C=1 keeps the cursor where the CUP put it")
        XCTAssertTrue(text.contains("\u{1B}[\(rect.row);\(rect.col)H"),
                      "the cell comes first, the placement is anchored there")
        XCTAssertEqual(drawnGlyphs(recorder.bytes), "", "not one cell byte: this is a placement move")
        XCTAssertEqual(recorder.occurrences(of: Self.blockOpen), 1)
        XCTAssertEqual(recorder.occurrences(of: Self.blockClose), 1)
    }

    /// One tile's cells-only move is a couple of hundred bytes against the ~16 KiB its pixels cost --
    /// the claim the whole `--paint-budget` change is worth making, measured on the writer itself.
    func testACellsOnlyMoveIsFarCheaperThanTransmitting() {
        let grid = makeGrid()
        let pixels = noisyFrame(grid)
        let moved = Recorder()
        replace([0], grid: grid, placeholder: true, into: moved)
        let retransmitted = Recorder()
        paint([0], grid: grid, pixels: pixels, into: retransmitted)
        XCTAssertGreaterThan(retransmitted.bytes.count, 5000, "a real tile payload, not an empty stream")
        XCTAssertLessThan(moved.bytes.count * 8, retransmitted.bytes.count,
                          "a re-place costs a fraction of a transmit (\(moved.bytes.count) vs "
                          + "\(retransmitted.bytes.count) bytes)")
    }

    // MARK: - 4. erasing the rows a picture vacated

    /// Exactly the given rows, one `CUP` + one `2K` each, and nothing drawn on the wire: `2K` erases in
    /// place (the cursor does not move and no printable byte is written), so the pane's final cell is
    /// never armed for the wrap that would scroll the picture one row up.
    func testEraseRowsClearsExactlyThoseRowsAndWritesNothingPrintable() {
        let recorder = Recorder()
        recorder.writer.beginFrame()
        recorder.writer.eraseRows(3..<5, cols: 40)
        recorder.writer.endFrame()
        XCTAssertTrue(recorder.text.hasPrefix("\u{1B}[?2026h\u{1B}[3;1H\u{1B}[2K\u{1B}[4;1H\u{1B}[2K"))
        XCTAssertEqual(drawnGlyphs(recorder.bytes), "",
                       "an erased row is erased, never drawn on: no glyph, no placeholder, no newline")
        // Row 5 is not in the range, and neither is row 2.
        XCTAssertFalse(recorder.text.contains("\u{1B}[5;1H"))
        XCTAssertFalse(recorder.text.contains("\u{1B}[2;1H"))
        // Every cursor move is column 1: nothing here ever puts the cursor on a cell it could write.
        XCTAssertEqual(recorder.occurrences(of: "\u{1B}[3;1H"), 1)
        XCTAssertEqual(recorder.occurrences(of: "\u{1B}[4;1H"), 1)
    }

    /// An empty range writes nothing at all -- the erase is a fix for a move, and a picture that did
    /// not move owes the pane no bytes.
    func testErasingNothingWritesNothing() {
        let recorder = Recorder()
        recorder.writer.eraseRows(4..<4, cols: 40)
        // ...and neither does a pane with no columns: there is no row to erase on it.
        recorder.writer.eraseRows(1..<3, cols: 0)
        XCTAssertTrue(recorder.bytes.isEmpty)
    }

    // MARK: - after the session is over

    /// A block that outlives the session must never reach the pane.
    ///
    /// Why it can: the frame path holds `emitLock`, not the writer's `writeLock`, across a whole block
    /// (`beginFrame` … compress … write … `endFrame`), so `shutdown()` -- which must stay bounded, it
    /// cannot wait for a slow link to swallow 128 KiB -- can retire the screen while `endFrame` is
    /// still ahead. Without a latch the *rest* of that block lands after `?1049l`: APCs, `a=p`, and
    /// `eraseRows`' `ESC[r;1H ESC[2K` erase rows of the shell's screen.
    ///
    /// The interleaving is exact and single-threaded here: a half-built block, `endSession`, then the
    /// rest of the block (which is what the painter does after the session ended).
    func testNothingBuiltAfterTheSessionEndsReachesThePane() {
        let recorder = Recorder()
        let writer = recorder.writer
        let grid = makeGrid()
        let pixels = frame(grid)
        writer.beginSession()
        writer.beginFrame()
        // The first half of the block: two tiles.
        for index in 0..<2 {
            let rect = grid.rect(index % grid.tilesX, index / grid.tilesX)
            let tile = ScreenWriter.compress(index: index, rect: rect,
                                             pixels: grid.extract(pixels, rect: rect),
                                             plan: writer.plan(for: index))!
            writer.emit(tile, sync: false)
        }
        // ...the teardown lands in the middle of it.
        writer.endSession()
        let afterTeardown = recorder.bytes.count
        XCTAssertTrue(recorder.text.contains("\u{1B}[?1049l"), "the teardown retired the screen")
        // The rest of the block, exactly as `paintNextChunk` would emit it: it must vanish.
        for index in 2..<4 {
            let rect = grid.rect(index % grid.tilesX, index / grid.tilesX)
            let tile = ScreenWriter.compress(index: index, rect: rect,
                                             pixels: grid.extract(pixels, rect: rect),
                                             plan: writer.plan(for: index))!
            writer.emit(tile, sync: false)
            writer.replaceTilePlacement(index: index, row: rect.row, col: rect.col,
                                        cols: rect.cols, rows: rect.rows,
                                        placeholder: true, sync: false)
        }
        writer.eraseRows(3..<5, cols: grid.paneCols)
        writer.endFrame()
        writer.beginFrame()
        writer.endFrame()
        writer.nudge()
        writer.clear()
        XCTAssertEqual(recorder.bytes.count, afterTeardown,
                       "not one byte after the teardown: the pane belongs to the shell again")
        let tail = String(decoding: recorder.bytes[(afterTeardown - 32)...], as: UTF8.self)
        XCTAssertFalse(tail.contains("\u{1B}[2K"), "no row erase on the shell's screen")
        XCTAssertFalse(tail.contains("a=p"), "no placement on the shell's screen")
        XCTAssertFalse(tail.contains(Self.blockOpen), "no block opened after the teardown")
        // A new session may paint again (the failed-`exec` `resumeWall` path).
        writer.beginSession()
        writer.beginFrame()
        writer.endFrame()
        XCTAssertGreaterThan(recorder.bytes.count, afterTeardown)
    }

    /// A reap wipes the store (`a=d,d=a`) but says so by *returning*, not by `repaintNeeded` -- which
    /// only `clear()` arms. `Desk` folds that into its store check (`storeLost = reaped ||
    /// repaintNeeded`); this pins why it has to.
    func testAReapWipesTheStoreWithoutClaimingARepaint() {
        let recorder = Recorder()
        let writer = recorder.writer
        XCTAssertFalse(writer.repaintNeeded)
        writer.reapInterval = 1
        XCTAssertTrue(writer.reapIfNeeded())
        XCTAssertFalse(writer.repaintNeeded, "a reap is a full repaint that `repaintNeeded` never reports")
    }
}
