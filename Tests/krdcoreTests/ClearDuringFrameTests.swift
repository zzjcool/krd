import XCTest
@testable import krdcore

/// `ScreenWriter.clear()` can land *inside* the frame's open synchronized-update block.
///
/// The contract, verbatim from the docs:
///
///  * docs/PROTOCOL.md §2: "The whole frame shares one synchronized-update block, opened by
///    `ScreenWriter.beginFrame` and committed by `endFrame`".
///  * docs/PROTOCOL.md §4: "`a=d,d=a` (delete all placements) is sent **only** at those two points
///    [resize or explicit clear, and endSession], never between frames."
///
/// `clear()` does `append("ESC_Ga=d,d=aESC\\"); append("ESC[2J"); flush()` with **no** `batchOpen`
/// guard, while `writeControl()` in the same class does `guard !batchOpen else { return false }`.
/// A clear that arrives while `beginFrame`…`endFrame` is open therefore puts the delete *into* the
/// frame's commit: the tiles already emitted in that block are applied and then deleted by the same
/// commit, and only dirty tiles are re-sent next frame, so the pane keeps a hole until they change.
///
/// This suite is the red test for that; the two green tests pin why `clear()` is the outlier
/// (its sibling `writeControl` refuses) and that the one caller of `reapIfNeeded()` runs before
/// `beginFrame`, so the shape stays outside the block there.
///
/// The bytes come from `ScreenWriter.sink` (the test seam issue #21 added for `GoldenDumpTests`),
/// so this needs no tty and no threads: the production sequence is replayed in order on one thread.
final class ClearDuringFrameTests: XCTestCase {

    // MARK: - protocol needles

    private static let frameOpen = Array("\u{1B}[?2026h".utf8)
    private static let frameClose = Array("\u{1B}[?2026l".utf8)
    private static let deleteAll = Array("\u{1B}_Ga=d,d=a\u{1B}\\".utf8)
    private static let eraseScreen = Array("\u{1B}[2J".utf8)

    /// Everything a human needs to see the frame's shape in a failure message.
    private static var needles: [(String, [UInt8])] {
        [("ESC[?2026h  (block open)", frameOpen),
         ("ESC[?2026l  (commit)", frameClose),
         ("ESC_Ga=d,d=aESC\\  (delete every placement, §4)", deleteAll),
         ("ESC[2J  (erase the grid, §4)", eraseScreen),
         ("i=100,p=1000 (tile 0 placed)", Array("i=100,p=1000".utf8)),
         ("i=101,p=1001 (tile 1 placed)", Array("i=101,p=1001".utf8))]
    }

    // MARK: - helpers

    /// Every start offset of `needle` in `hay`. Naive on purpose: the streams here are kilobytes.
    private func occurrences(of needle: [UInt8], in hay: [UInt8]) -> [Int] {
        guard !needle.isEmpty, hay.count >= needle.count else { return [] }
        return (0...(hay.count - needle.count)).filter { start in
            hay[start..<(start + needle.count)].elementsEqual(needle)
        }
    }

    /// Offsets → printable timeline, so a failure shows the order of events, not a hex dump.
    private func timeline(_ bytes: [UInt8]) -> String {
        var hits: [(Int, String)] = []
        for (name, needle) in Self.needles {
            for offset in occurrences(of: needle, in: bytes) { hits.append((offset, name)) }
        }
        hits.sort { $0.0 < $1.0 }
        return hits.map { "    byte \($0.0): \($0.1)" }.joined(separator: "\n")
    }

    /// A `ScreenWriter` plus the bytes it flushes.
    private final class Recorder {
        let writer = ScreenWriter()
        private(set) var bytes: [UInt8] = []
        init() { writer.sink = { [weak self] flushed in self?.bytes.append(contentsOf: flushed) } }
    }

    private let paneCols = 16, paneRows = 8
    private let cellW = 8.0, cellH = 16.0
    private let tileCols = 8, tileRows = 4

    private func makeGrid() -> TileGrid {
        TileGrid.make(paneCols: paneCols, paneRows: paneRows, cellW: cellW, cellH: cellH,
                      aspect: 1.7, tileCols: tileCols, tileRows: tileRows)
    }

    /// A frame that is cheap to compress and deterministic (no RNG, no Date, no learned levels).
    private func frame(_ grid: TileGrid, phase: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: grid.pixelW * grid.pixelH * grid.bpp)
        for y in 0..<grid.pixelH {
            for x in 0..<grid.pixelW {
                let o = (y * grid.pixelW + x) * grid.bpp
                px[o] = UInt8((x * 7 + phase * 31) % 256)
                px[o + 1] = UInt8((y * 5) % 256)
                px[o + 2] = UInt8((x < grid.pixelW / 2) ? 200 : 40)
            }
        }
        return px
    }

    /// The tile loop of `Desk.handleFrame` for one tile: compress at a pinned level, then emit.
    /// `sync: writer.perTileSync` is `false` in the default `KRD_SYNC=frame` mode, i.e. the tile
    /// adds no `?2026` escapes of its own — the frame's block is the only one.
    @discardableResult
    private func emitTile(_ writer: ScreenWriter, grid: TileGrid, pixels: [UInt8],
                          index: Int) -> Bool {
        let rect = grid.rect(index % grid.tilesX, index / grid.tilesX)
        guard let tile = ScreenWriter.compress(index: index, rect: rect,
                                               pixels: grid.extract(pixels, rect: rect),
                                               level: 6) else {
            XCTFail("compress returned nil for tile \(index)")
            return false
        }
        writer.emit(tile, sync: writer.perTileSync)
        return true
    }

    /// The single `ESC[?2026h … ESC[?2026l` block of a frame, as absolute offsets into `bytes`.
    private func frameBlock(in bytes: [UInt8]) throws -> (open: Int, close: Int) {
        let opens = occurrences(of: Self.frameOpen, in: bytes)
        XCTAssertEqual(opens.count, 1,
                       "one frame must produce exactly one synchronized block (docs/PROTOCOL.md §2):\n"
                       + timeline(bytes))
        guard let open = opens.first else { throw XCTSkip("no synchronized block to inspect") }
        let closes = occurrences(of: Self.frameClose, in: bytes).filter { $0 > open }
        XCTAssertFalse(closes.isEmpty,
                       "the frame's block was never closed (docs/PROTOCOL.md §2):\n" + timeline(bytes))
        guard let close = closes.first else { throw XCTSkip("the block was never closed") }
        return (open, close)
    }

    // MARK: - RED: clear() inside an open frame

    /// The production sequence, one thread, no tty:
    ///
    ///     beginSession
    ///     beginFrame            (main.swift:2643, on the capture queue)
    ///     emit tile 0
    ///     clear()               (main.swift:2736 — `Desk.handleResize` lands on the main queue)
    ///     emit tile 1
    ///     endFrame              (main.swift:2697)
    ///
    /// Expected: `a=d,d=a` and `ESC[2J` never appear between `?2026h` and `?2026l` (PROTOCOL §4).
    /// Actual on HEAD: both land inside the block, i.e. in the same commit as tile 0's placement.
    func testClearInsideAnOpenFrameMustNotInjectDeleteAllIntoTheSynchronizedBlock() throws {
        let rec = Recorder()
        let writer = rec.writer
        try XCTSkipUnless(writer.syncLabel == "frame",
                          "KRD_SYNC/KRD_NOSYNC in the environment turned off the one-block-per-frame "
                          + "mode this test pins (syncLabel = \(writer.syncLabel))")

        let grid = makeGrid()
        let px = frame(grid, phase: 0)

        writer.beginSession()
        writer.resize(tiles: grid.count)
        writer.beginFrame()
        XCTAssertTrue(emitTile(writer, grid: grid, pixels: px, index: 0))
        writer.clear()                     // a resize, mid-frame
        XCTAssertTrue(emitTile(writer, grid: grid, pixels: px, index: 1))
        writer.endFrame()

        let bytes = rec.bytes
        let block = try frameBlock(in: bytes)
        let body = Array(bytes[block.open..<block.close])

        let deletes = occurrences(of: Self.deleteAll, in: body)
        let erases = occurrences(of: Self.eraseScreen, in: body)

        XCTAssertEqual(deletes.count, 0, """
            `a=d,d=a` was sent INSIDE the frame's synchronized-update block.

            docs/PROTOCOL.md §2: "The whole frame shares one synchronized-update block, opened by
            `ScreenWriter.beginFrame` and committed by `endFrame`".
            docs/PROTOCOL.md §4: "`a=d,d=a` (delete all placements) is sent only at those two points
            [resize or explicit clear, and endSession], never between frames."

            The delete is injected by `ScreenWriter.clear()` (Sources/krdcore/Render.swift:234-238),
            which appends `ESC_Ga=d,d=aESC\\` + `ESC[2J` and flushes without checking `batchOpen`;
            compare `ScreenWriter.writeControl()` (Sources/krdcore/Render.swift:738-744), which does
            `guard !batchOpen else { return false }`.

            Consequence: tile 0's placement, emitted into this same block, is applied and then
            deleted by the same commit while `ESC[2J` erases the grid — and tile 0 is not re-sent
            next frame (only dirty tiles are), so the pane keeps a hole until it changes.

            §4 licenses the delete at a resize or an explicit clear; what it does not license is the
            delete arriving between `beginFrame` and `endFrame`. That stretch is the frame's single
            commit, so a delete inside it cancels what the frame just placed.

            frame block = bytes \(block.open)…\(block.close), delete at +\(deletes) inside it
            transitions seen:
            \(timeline(bytes))
            """)
        XCTAssertEqual(erases.count, 0, """
            `ESC[2J` was sent INSIDE the frame's synchronized-update block.

            docs/PROTOCOL.md §4 puts `ESC[2J` with the delete, i.e. at an explicit clear/teardown,
            never inside the frame's one block (docs/PROTOCOL.md §2). `ScreenWriter.clear()`
            (Sources/krdcore/Render.swift:234-238) emits it with no `batchOpen` guard.

            transitions seen:
            \(timeline(bytes))
            """)

        // Not the point of the test, but it makes the failure above unambiguous: both tiles really
        // do sit in the one block (§2), so nothing here is a "the block moved" artefact. The needle
        // is the `a=p` placement command: base64 cannot contain a comma, so it cannot be payload.
        XCTAssertFalse(occurrences(of: Array("i=100,p=1000".utf8), in: body).isEmpty,
                       "tile 0's placement must be inside the frame's block (docs/PROTOCOL.md §2)")
        XCTAssertFalse(occurrences(of: Array("i=101,p=1001".utf8), in: body).isEmpty,
                       "tile 1's placement must be inside the frame's block (docs/PROTOCOL.md §2)")
    }

    // MARK: - GREEN: the sibling that gets it right

    /// `writeControl` refuses to write while a batch is open, which is exactly the guard `clear()`
    /// lacks: the class already knows that `out` is the frame's batch buffer, and that appending to
    /// it mid-frame lands inside the synchronized block. This test is green on HEAD and exists to
    /// make the asymmetry in `clear()` visible rather than a matter of taste.
    func testWriteControlRefusesToWriteInsideAnOpenFrame() throws {
        let rec = Recorder()
        let writer = rec.writer
        try XCTSkipUnless(writer.syncLabel == "frame",
                          "KRD_SYNC/KRD_NOSYNC disabled the block this test pins "
                          + "(syncLabel = \(writer.syncLabel))")

        writer.beginSession()
        writer.beginFrame()
        XCTAssertFalse(writer.writeControl("MIDFRAME-PROBE"),
                       "writeControl must refuse while the frame's block is open "
                       + "(Sources/krdcore/Render.swift:741)")
        XCTAssertTrue(occurrences(of: Array("MIDFRAME-PROBE".utf8), in: rec.bytes).isEmpty,
                      "the refused write must not have reached the sink")
        writer.endFrame()

        // …and it goes out between frames, so `false` is about the batch, not about the sequence.
        XCTAssertTrue(writer.writeControl("MIDFRAME-PROBE"),
                      "writeControl must succeed once the frame's block is closed")
        XCTAssertFalse(occurrences(of: Array("MIDFRAME-PROBE".utf8), in: rec.bytes).isEmpty,
                       "the accepted write must have reached the sink")
    }

    // MARK: - GREEN: the other unguarded `a=d` append, and why it is safe

    /// `reapIfNeeded()` has the same shape as `clear()` — it appends `a=d,d=a` with no `batchOpen`
    /// guard — but its one caller (`Desk.handleFrame`, Sources/krd/main.swift:2632) runs it
    /// *before* `beginFrame()` (main.swift:2643), because a reap's answer is "repaint every tile",
    /// which is only meaningful at frame start. This pins that order: the delete stays outside the
    /// block. It does not license calling `reapIfNeeded()` mid-frame; it just shows the shape is not
    /// reachable there (and `KRD_REAP` defaults to 0, so the path is dead in production —
    /// docs/PROTOCOL.md §6.3).
    func testReapIfNeededRunsBeforeBeginFrameSoItsDeleteStaysOutsideTheBlock() throws {
        let rec = Recorder()
        let writer = rec.writer
        try XCTSkipUnless(writer.syncLabel == "frame",
                          "KRD_SYNC/KRD_NOSYNC disabled the block this test pins "
                          + "(syncLabel = \(writer.syncLabel))")

        let grid = makeGrid()
        let px = frame(grid, phase: 1)

        writer.reapInterval = 1            // the first call trips
        writer.beginSession()

        // Exactly the order in main.swift:2632 (reap) then :2637/:2643 (beginFrame).
        XCTAssertTrue(writer.reapIfNeeded(), "reapInterval = 1 must trip on the first frame")
        writer.resize(tiles: grid.count)
        writer.beginFrame()
        XCTAssertTrue(emitTile(writer, grid: grid, pixels: px, index: 0))
        writer.endFrame()

        let bytes = rec.bytes
        let block = try frameBlock(in: bytes)
        let deletes = occurrences(of: Self.deleteAll, in: bytes)
        XCTAssertEqual(deletes.count, 1, "one reap → one delete-all:\n" + timeline(bytes))
        if let delete = deletes.first {
            XCTAssertLessThan(delete, block.open,
                              "a reap's delete must be committed before the frame's block opens "
                              + "(Sources/krd/main.swift:2632 runs before beginFrame):\n"
                              + timeline(bytes))
        }
        XCTAssertTrue(occurrences(of: Self.deleteAll, in: Array(bytes[block.open..<block.close]))
                        .isEmpty,
                      "the reap's delete must not appear inside the frame's block "
                      + "(docs/PROTOCOL.md §4, §2):\n" + timeline(bytes))
    }
}
