import XCTest
import CoreGraphics
@testable import krdcore

/// #95's one-scan frame diff has to give the *same two answers* as the two passes it replaced -- not
/// the same answers as the other new function.
///
/// WHY the old algorithm is copied in here rather than called: `TileGrid.dirty` is now
/// `diff(...).dirty`, so comparing the two is a tautology -- it would pass with the tiles
/// mis-numbered, the edge tile dropped, the rows off by one, or the wrong pixels read altogether.
/// The claim in the issue is "one scan, the same answers as two reads", and the only thing that can
/// test it is the two reads themselves, so `oldTwoPass` below is the pre-#95 pipeline verbatim:
/// `Capturer`/`main` did `previous == rgba` (a whole `Array ==`, 4.06-4.34 ms at 2329x1452) and then
/// `TileGrid.dirty` `memcmp`'d every tile row (26,136 of them at that size). Those are the two
/// answers, and they are what every case here is checked against.
///
/// WHY the cases are what they are: tiles partition the frame (see `rect`), so the interesting
/// failures are all at the seams of that partition -- the frame's first and last byte, a tile's
/// boundary column, a change straddling two tiles across and down, an edge tile that is narrower or
/// shorter than `tileCols`/`tileRows`, and a frame whose pixel rows are not a whole number of cells
/// (`--scale`). The random trials then cover the space in between: with a fixed-seed PRNG, so a
/// failure names the same bytes tomorrow.
final class FrameScanTests: XCTestCase {

    // MARK: - The two-pass pipeline being replaced, copied

    /// `Capturer`'s whole-frame dedupe followed by `TileGrid.dirty`'s per-tile-row `memcmp` -- the
    /// code #95 deletes, kept here as the answer to argue against.
    private func oldTwoPass(previous: [UInt8], current: [UInt8],
                            grid: TileGrid) -> (identical: Bool, dirty: [Int]) {
        // Capture.swift / main.swift: `previous == rgba` (Bench.swift: `previous == px`).
        let identical = previous == current
        var oldDirty: [Int] = []
        if previous.count != current.count {
            oldDirty = Array(0..<grid.count)
        } else {
            // Verbatim from `TileGrid.dirty` at the parent of the #95 branch: one `memcmp` per row
            // of every tile, breaking at the first differing row.
            let stride = grid.pixelW * grid.bpp
            previous.withUnsafeBufferPointer { prev in
                current.withUnsafeBufferPointer { cur in
                    for ty in 0..<grid.tilesY {
                        for tx in 0..<grid.tilesX {
                            let r = grid.rect(tx, ty)
                            var differs = false
                            let bytes = r.w * grid.bpp
                            for row in 0..<r.h {
                                let off = (r.y + row) * stride + r.x * grid.bpp
                                if memcmp(prev.baseAddress! + off, cur.baseAddress! + off, bytes) != 0 {
                                    differs = true
                                    break
                                }
                            }
                            if differs { oldDirty.append(ty * grid.tilesX + tx) }
                        }
                    }
                }
            }
        }
        // The pipeline re-sent no tiles for a frame it dropped as identical (`identical ? [] : ...`).
        return (identical, identical ? [] : oldDirty)
    }

    // MARK: - Grids under test

    /// The documented display page: 137x44 cells of 17x33 px in front of a 1920x1200 source --
    /// 2329x1452 px, 10.1 MB, 198 tiles in 18x11. The layout #95's 4.5 ms was measured on, and the
    /// only one big enough for the new scan's per-band shortcut to matter.
    private var bigGrid: TileGrid {
        TileGrid.make(paneCols: 137, paneRows: 44, cellW: 17, cellH: 33,
                      aspect: 1920.0 / 1200.0, tileCols: 8, tileRows: 4)
    }

    /// Small enough for hundreds of trials: 32x12 cells of 9x18 px = 288x216 px (186 KB) in 12
    /// tiles of 8x4 cells, so the tile split is exact in cells *and* in pixels.
    private var smallGrid: TileGrid {
        TileGrid.make(paneCols: 40, paneRows: 12, cellW: 9, cellH: 18,
                      aspect: 4.0 / 3.0, tileCols: 8, tileRows: 4)
    }

    /// Tiles that do not divide the pane: 29x11 cells leaves the last tile column 5 cells wide and
    /// the last tile row 3 cells high, so `rect` hands back short edge tiles on both axes -- the
    /// tiles a scan that assumed `tileCols x tileRows` everywhere would get wrong.
    private var raggedGrid: TileGrid {
        TileGrid.make(paneCols: 37, paneRows: 11, cellW: 9, cellH: 18,
                      aspect: 4.0 / 3.0, tileCols: 8, tileRows: 4)
    }

    /// The same pane with RGBA frames: `bpp` is a stride, not a constant.
    private var rgbaGrid: TileGrid {
        TileGrid.make(paneCols: 40, paneRows: 12, cellW: 9, cellH: 18,
                      aspect: 4.0 / 3.0, tileCols: 8, tileRows: 4, bpp: 4)
    }

    /// `--scale 0.5`: half the pixels in the same cells, so a tile's pixel rect comes from
    /// `cellW * scale` (4.5 px) and its width is no longer a whole number of cells.
    private var halfScaleGrid: TileGrid {
        TileGrid.make(paneCols: 40, paneRows: 12, cellW: 9, cellH: 18,
                      aspect: 4.0 / 3.0, tileCols: 8, tileRows: 4, scale: 0.5)
    }

    /// The cheap grids, in the order the failures should surface in; the 10 MB page comes last.
    private var smallGrids: [(String, TileGrid)] {
        [("small", smallGrid), ("ragged", raggedGrid), ("rgba", rgbaGrid), ("scale0.5", halfScaleGrid)]
    }

    private var allGrids: [(String, TileGrid)] {
        smallGrids + [("display page 137x44", bigGrid)]
    }

    // MARK: - Frames

    private func frameBytes(_ grid: TileGrid) -> Int { grid.pixelW * grid.pixelH * grid.bpp }

    private func blank(_ grid: TileGrid) -> [UInt8] {
        [UInt8](repeating: 0, count: frameBytes(grid))
    }

    /// A non-uniform frame that is cheap *at any size*: one store per 4096 bytes, so 2,476 of them
    /// on the 10 MB page rather than ten million. A real picture is not needed -- what the scan
    /// looks at is where the bytes are, not what they mean -- but a uniform frame would let a scan
    /// that read the wrong row still agree.
    private func textured(_ grid: TileGrid) -> [UInt8] {
        var frame = blank(grid)
        var i = 0
        while i < frame.count {
            frame[i] = UInt8(truncatingIfNeeded: i &* 2_654_435_761 &+ 17)
            i += 4096
        }
        return frame
    }

    /// Invert a `w x h` pixel rectangle: the single-byte, slab and whole-tile changes all come
    /// through here, so "which pixels changed" is one expression per case.
    private func flipPixels(_ frame: inout [UInt8], _ grid: TileGrid,
                            x: Int, y: Int, w: Int = 1, h: Int = 1) {
        precondition(x >= 0 && y >= 0 && w >= 1 && h >= 1
                     && x + w <= grid.pixelW && y + h <= grid.pixelH,
                     "flip outside the frame: (\(x),\(y)) \(w)x\(h) in \(grid.pixelW)x\(grid.pixelH)")
        for row in 0..<h {
            let off = ((y + row) * grid.pixelW + x) * grid.bpp
            for i in 0..<(w * grid.bpp) { frame[off + i] ^= 0xFF }
        }
    }

    /// Deterministic PRNG (xorshift64). `Int.random` would make a failing trial unreproducible and
    /// the suite nondeterministic; a seed does not.
    private struct XorShift64 {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        /// `0 ..< bound`. The modulo bias does not matter to a test that only wants a spread.
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    /// A copy of `frame` with `flips` random bytes inverted -- the "0.1 % of the screen moved" frame.
    private func noisyCopy(of frame: [UInt8], flips: Int, rng: inout XorShift64) -> [UInt8] {
        var out = frame
        for _ in 0..<max(1, flips) {
            let i = rng.below(out.count)
            out[i] ^= 0x5A       // xor with a non-zero value always changes the byte
        }
        return out
    }

    // MARK: - The differential check

    /// Compare the new one-scan answer with the two passes, on every axis the test can see.
    @discardableResult
    private func assertAgrees(_ previous: [UInt8], _ current: [UInt8], _ grid: TileGrid, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) -> TileGrid.FrameDiff {
        let old = oldTwoPass(previous: previous, current: current, grid: grid)
        let new = TileGrid.diff(previous: previous, current: current, grid: grid)

        XCTAssertEqual(new.identical, old.identical,
                       "\(label): `identical` is not what `previous == current` said", file: file, line: line)
        XCTAssertEqual(new.dirty, old.dirty,
                       "\(label): dirty tiles are not the set the per-tile-row memcmp found",
                       file: file, line: line)

        // The contract on its own, so a *wrong* old answer cannot make a wrong new one pass: the
        // indices are ascending (the order the encoder emits tiles in), unique, inside the grid,
        // and "no tiles" is the same statement as "byte-identical" -- tiles partition the frame.
        XCTAssertEqual(new.dirty, new.dirty.sorted(), "\(label): dirty is not ascending", file: file, line: line)
        XCTAssertEqual(Set(new.dirty).count, new.dirty.count, "\(label): duplicate tile", file: file, line: line)
        XCTAssertTrue(new.dirty.allSatisfy { $0 >= 0 && $0 < grid.count },
                      "\(label): tile index outside 0..<\(grid.count)", file: file, line: line)
        XCTAssertEqual(new.identical, new.dirty.isEmpty,
                       "\(label): `identical` and an empty tile list disagree", file: file, line: line)

        // The tile-only face of `diff`, pinned once per case: `dirty` must be exactly `diff().dirty`.
        XCTAssertEqual(TileGrid.dirty(previous: previous, current: current, grid: grid), new.dirty,
                       "\(label): `dirty` is not `diff(...).dirty`", file: file, line: line)
        return new
    }

    // MARK: - The grid the issue measured

    func testTheGridsAreTheOnesTheIssueMeasured() {
        // The documented page from the issue, so this file cannot quietly stop testing it.
        let grid = bigGrid
        XCTAssertEqual(grid.pixelW, 2329)
        XCTAssertEqual(grid.pixelH, 1452)
        XCTAssertEqual(grid.count, 198)
        XCTAssertEqual(frameBytes(grid), 10_145_124)
        // Every case below reads two tiles on both axes, so the seams it looks for exist.
        for (name, small) in smallGrids {
            XCTAssertGreaterThanOrEqual(small.tilesX, 2, name)
            XCTAssertGreaterThanOrEqual(small.tilesY, 2, name)
        }
        XCTAssertTrue(raggedGrid.paneCols % raggedGrid.tileCols != 0
                      && raggedGrid.paneRows % raggedGrid.tileRows != 0, "the ragged grid must be ragged")
        XCTAssertEqual(halfScaleGrid.scale, 0.5)
        XCTAssertEqual(rgbaGrid.bpp, 4)
    }

    // MARK: - Identical frames

    func testIdenticalFramesAgree() {
        for (name, grid) in allGrids {
            let a = textured(grid)
            // The same buffer twice: `Array ==` short-circuits on it, and so may a scan that checks
            // for a shared buffer first. The pipeline compares two, but both answers must be "same".
            assertAgrees(a, a, grid, "\(name): the same array twice")

            // Two distinct buffers holding the same bytes -- what `Capturer` actually compares. The
            // round trip through a value change is what forces the copy; `let b = a` shares storage.
            var b = a
            b[0] = b[0] &+ 1
            b[0] = b[0] &- 1
            let r = assertAgrees(a, b, grid, "\(name): two buffers, identical bytes")
            XCTAssertTrue(r.identical, "\(name): identical frames reported as changed")
            XCTAssertEqual(r.dirty, [], "\(name): identical frames reported a dirty tile")
        }
    }

    // MARK: - Every seam of the tile partition

    func testSingleByteChangesLandInTheTileThatHoldsThem() {
        for (name, grid) in allGrids {
            let base = textured(grid)
            let bytes = frameBytes(grid)

            // 1. The very first byte of the frame: the top-left corner, tile (0, 0).
            var first = base
            first[0] ^= 0xFF
            XCTAssertEqual(assertAgrees(base, first, grid, "\(name): first byte").dirty, [0],
                           "\(name): a change in the first byte is not tile 0")

            // 2. The very last byte: the bottom-right corner, i.e. the last edge tile.
            var last = base
            last[bytes - 1] ^= 0xFF
            XCTAssertEqual(assertAgrees(base, last, grid, "\(name): last byte").dirty, [grid.count - 1],
                           "\(name): a change in the last byte is not the last tile")

            // 3. A byte in the first pixel column of tile (1, 0): the tile boundary column, where a
            //    scan whose column range is off by one blames tile 0 instead of tile 1.
            let tile1 = grid.rect(1, 0)
            var boundary = base
            flipPixels(&boundary, grid, x: tile1.x, y: 0)
            XCTAssertEqual(assertAgrees(base, boundary, grid, "\(name): tile boundary column").dirty, [1],
                           "\(name): the boundary column belongs to tile 1, not tile 0")

            // 4. Two pixels straddling that boundary: tile 0's last column and tile 1's first.
            var straddle = base
            flipPixels(&straddle, grid, x: tile1.x - 1, y: 0, w: 2)
            XCTAssertEqual(assertAgrees(base, straddle, grid, "\(name): straddling two tiles").dirty, [0, 1],
                           "\(name): a change across a tile boundary did not dirty both tiles")

            // 5. Two pixels straddling a tile *row* boundary: the last row of band 0 and the first
            //    row of band 1. The new scan reads bands, so an off-by-one row would hide a change
            //    here and nowhere else.
            let band1 = grid.rect(0, 1)
            var down = base
            flipPixels(&down, grid, x: 0, y: band1.y - 1, h: 2)
            XCTAssertEqual(assertAgrees(base, down, grid, "\(name): straddling two bands").dirty,
                           [0, grid.tilesX],
                           "\(name): a change across a band boundary did not dirty both bands")

            // 6. The first pixel of the last tile *column*: an edge tile narrower than `tileCols`
            //    cells, whose pixel width is the frame's remainder.
            let edgeCol = grid.rect(grid.tilesX - 1, 0)
            var across = base
            flipPixels(&across, grid, x: edgeCol.x, y: 0)
            XCTAssertEqual(assertAgrees(base, across, grid, "\(name): last tile column").dirty,
                           [grid.tilesX - 1],
                           "\(name): a change in the last tile column is not that tile")

            // 7. ...and of the last tile *row*, the one `rect` makes shorter than `tileRows`.
            let edgeRow = grid.rect(0, grid.tilesY - 1)
            var lastRow = base
            flipPixels(&lastRow, grid, x: 0, y: edgeRow.y)
            XCTAssertEqual(assertAgrees(base, lastRow, grid, "\(name): last tile row").dirty,
                           [(grid.tilesY - 1) * grid.tilesX],
                           "\(name): a change in the last tile row is not that band")
        }
    }

    // MARK: - Whole-tile and every-byte changes

    func testEveryByteChangedIsEveryTile() {
        for (name, grid) in allGrids {
            let base = textured(grid)
            let all = base.map { $0 ^ 0xFF }
            let r = assertAgrees(base, all, grid, "\(name): every byte changed")
            XCTAssertEqual(r.dirty, Array(0..<grid.count), "\(name): every byte changed is every tile")
            XCTAssertFalse(r.identical, "\(name): a fully changed frame reported as identical")
        }
    }

    /// A change confined to one tile must dirty exactly that tile -- including at its last pixel,
    /// which is where a scan that walks `..<` instead of `...` loses a byte, and in the edge tiles,
    /// whose rect is short.
    func testAChangeInsideOneTileDirtiesExactlyThatTile() {
        for (name, grid) in smallGrids {
            let base = textured(grid)
            for ty in 0..<grid.tilesY {
                for tx in 0..<grid.tilesX {
                    let r = grid.rect(tx, ty)
                    let index = ty * grid.tilesX + tx
                    // Its first pixel, its last pixel, and a 2x2 block in the middle: inside one
                    // tile, so neighbours must stay clean.
                    let spots = [(0, 0), (r.w - 1, r.h - 1), (r.w / 2, r.h / 2)]
                    for (dx, dy) in spots {
                        var frame = base
                        flipPixels(&frame, grid, x: r.x + dx, y: r.y + dy,
                                   w: min(2, r.w - dx), h: min(2, r.h - dy))
                        XCTAssertEqual(assertAgrees(base, frame, grid,
                                                    "\(name): inside tile \(index) at (\(dx),\(dy))").dirty,
                                       [index],
                                       "\(name): a change inside tile \(index) dirtied more than it")
                    }
                    // ...and ONE byte only: the last one of the tile's last row, i.e. the blue
                    // channel of its last pixel. A column range that stops one byte short rather
                    // than one pixel short (`r.w * bpp - 1`) still sees the other two channels of
                    // that pixel and so passes every case above; this single byte does not.
                    var byte = base
                    let lastByte = ((r.y + r.h - 1) * grid.pixelW + r.x + r.w - 1) * grid.bpp + grid.bpp - 1
                    byte[lastByte] ^= 0xFF
                    XCTAssertEqual(assertAgrees(base, byte, grid,
                                                "\(name): last byte of tile \(index)").dirty,
                                   [index],
                                   "\(name): the last byte of tile \(index) was read as unchanged")
                }
            }
        }

        // ...and once on the 10 MB page, in its bottom-right edge tile, whose pixel rect is what the
        // 2329x1452 frame has left over.
        let grid = bigGrid
        let base = textured(grid)
        let corner = grid.rect(grid.tilesX - 1, grid.tilesY - 1)
        var frame = base
        flipPixels(&frame, grid, x: corner.x + corner.w - 1, y: corner.y + corner.h - 1)
        XCTAssertEqual(assertAgrees(base, frame, grid, "big page: bottom-right edge tile").dirty,
                       [grid.count - 1])
    }

    // MARK: - Random trials

    func testNoiseAgrees() {
        var rng = XorShift64(seed: 0x5EED_0095)
        var trials = 0
        for (name, grid) in smallGrids {
            let base = textured(grid)
            let bytes = frameBytes(grid)
            for trial in 0..<200 {
                // Half the trials are a single changed byte -- the sparsest real case, and the one
                // where a scan that mis-orders or repeats its tile list shows up -- and the rest are
                // ~0.1 % of the frame, the "something on screen moved" case.
                let flips = trial % 2 == 0 ? 1 : max(1, bytes / 1000)
                let noisy = noisyCopy(of: base, flips: flips, rng: &rng)
                let r = assertAgrees(base, noisy, grid, "\(name): trial \(trial) with \(flips) bytes changed")
                XCTAssertFalse(r.dirty.isEmpty,
                               "\(name): trial \(trial) flipped \(flips) bytes and reported no dirty tile")
                trials += 1
            }
        }
        XCTAssertEqual(trials, 800)
    }

    func testNoiseOnTheDocumentedDisplayPage() {
        let grid = bigGrid
        let base = textured(grid)
        let bytes = frameBytes(grid)
        var rng = XorShift64(seed: 0x2329_1452)
        for trial in 0..<6 {
            // One byte, then ~0.1 % (10,145 bytes): enough to dirty most of the 198 tiles, which is
            // the case where the scan's per-band shortcut ("nothing left to learn") fires early.
            let flips = trial == 0 ? 1 : max(1, bytes / 1000)
            let noisy = noisyCopy(of: base, flips: flips, rng: &rng)
            let r = assertAgrees(base, noisy, grid, "big page: trial \(trial) with \(flips) bytes changed")
            XCTAssertFalse(r.dirty.isEmpty, "big page: trial \(trial) reported no dirty tile")
        }
    }

    // MARK: - Not two frames of this grid

    func testALengthMismatchIsEveryTileAndNotIdentical() {
        for (name, grid) in allGrids {
            let base = textured(grid)
            // A resize: the grid the pipeline holds no longer describes the frame it was handed, so
            // the frame is never read tile by tile and the answer is "everything, and not identical".
            let shorter = Array(base.dropLast(1))
            let r = assertAgrees(base, shorter, grid, "\(name): one byte short")
            XCTAssertFalse(r.identical, "\(name): frames of different lengths reported as identical")
            XCTAssertEqual(r.dirty, Array(0..<grid.count), "\(name): a length mismatch is not every tile")

            let longer = shorter + [0]
            XCTAssertEqual(assertAgrees(shorter, longer, grid, "\(name): one byte long").dirty,
                           Array(0..<grid.count))
        }
    }
}
