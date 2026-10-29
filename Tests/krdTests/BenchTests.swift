import XCTest
import CZlib
@testable import krd
@testable import krdcore

/// L0: the pure functions, with no terminal, no screen and no permissions.
///
/// These are micro benchmarks, not tests of correctness — but each one also asserts the
/// invariant the benchmark depends on, because "it got slower" and "it got wrong" look
/// identical in a timing table. Run them in release for numbers that mean anything:
///
///     swift test -c release --filter MicroBench
///     swift test                      # correctness only; debug numbers are ~10x slower
final class MicroBenchTests: XCTestCase {
    private func grid(tileCols: Int = 8, tileRows: Int = 4) -> TileGrid {
        TermGeometry.fallbackCell = (w: 8, h: 16)
        let geometry = TermGeometry(cols: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)
        return TileGrid.make(geometry: geometry, aspect: 1.6, tileCols: tileCols, tileRows: tileRows, bpp: 3)
    }

    private func frame(_ grid: TileGrid, _ content: BenchContent = .text, seed: Int = 0) -> [UInt8] {
        benchMakeFrame(grid, content, seed: seed)
    }

    // MARK: dirty detection

    /// The hot path: every delivered frame is scanned for changes, and the common answer is
    /// "nothing". This is the number that decides how much a static desktop costs.
    func testDirtyIdentical() {
        let grid = self.grid()
        let base = frame(grid)
        var current = base
        benchDetach(&current)          // Capturer compares two distinct buffers
        XCTAssertEqual(TileGrid.dirty(previous: base, current: current, grid: grid).count, 0)
        measure { _ = TileGrid.dirty(previous: base, current: current, grid: grid) }
    }

    func testDirtyOneTile() {
        let grid = self.grid()
        let base = frame(grid)
        var current = base
        benchDetach(&current)
        // one 24x48 block in the middle tile: exactly one tile must be dirty
        let r = grid.rect(grid.tilesX / 2, grid.tilesY / 2)
        for y in (r.y + 20)..<(r.y + 44) {
            for x in (r.x + 20)..<(r.x + 40) {
                current[(y * grid.pixelW + x) * grid.bpp] ^= 0xFF
            }
        }
        XCTAssertEqual(TileGrid.dirty(previous: base, current: current, grid: grid).count, 1)
    }

    func testDirtyAll() {
        let grid = self.grid()
        let base = frame(grid, .text, seed: 0)
        let other = frame(grid, .text, seed: 1)
        XCTAssertEqual(TileGrid.dirty(previous: base, current: other, grid: grid).count, grid.count)
    }

    // MARK: extract

    func testExtract() {
        let grid = self.grid()
        let pixels = frame(grid)
        let rect = grid.rect(1, 1)
        let tile = grid.extract(pixels, rect: rect)
        XCTAssertEqual(tile.count, rect.w * rect.h * grid.bpp)
        // first pixel of the tile must be the frame's pixel at (rect.x, rect.y)
        let offset = (rect.y * grid.pixelW + rect.x) * grid.bpp
        XCTAssertEqual(Array(tile.prefix(3)), Array(pixels[offset..<(offset + 3)]))
        measure { _ = grid.extract(pixels, rect: rect) }
    }

    // MARK: zlib levels

    /// Why `LevelPolicy` exists, as a measurement instead of a comment: text gains a lot from
    /// level 9, noise gains almost nothing for six times the CPU.
    func testZlibLevels() {
        let grid = self.grid()
        let textTile = grid.extract(frame(grid, .text), rect: grid.rect(0, 0))
        let noiseTile = grid.extract(frame(grid, .noise), rect: grid.rect(0, 0))

        let text = [1, 5, 9].map { level in zlibCompress(textTile, level: level)! }
        let noise = [1, 5, 9].map { level in zlibCompress(noiseTile, level: level)! }

        XCTAssertLessThan(text[2].count, text[0].count, "level 9 must beat level 1 on text")
        XCTAssertLessThan(noise[1].count, Int(Double(noiseTile.count) * 1.01) + 1)

        var options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(options: options) {
            for level in [1, 5, 9] { _ = zlibCompress(textTile, level: level) }
            for level in [1, 5, 9] { _ = zlibCompress(noiseTile, level: level) }
        }
    }

    // MARK: base64

    /// `emit` builds `Data -> String -> [UInt8]` per tile. Measured because the alternative
    /// (a direct byte writer) is an obvious optimisation, and it should be argued with a number.
    func testBase64() {
        let grid = self.grid()
        let tile = grid.extract(frame(grid, .noise), rect: grid.rect(0, 0))
        let payload = zlibCompress(tile, level: 5)!
        measure {
            let text = Data(payload).base64EncodedString()
            XCTAssertEqual(Array(text.utf8).count, ((payload.count + 2) / 3) * 4)
        }
    }

    // MARK: escape assembly

    func testEmit() {
        let grid = self.grid()
        let rect = grid.rect(0, 0)
        let tile = ScreenWriter.compress(index: 0, rect: rect,
                                         pixels: grid.extract(frame(grid), rect: rect), level: 5)!
        let writer = ScreenWriter()
        writer.discardOutput = true
        measure {
            writer.beginFrame()
            writer.emit(tile, sync: false)
            writer.endFrame()
        }
    }
}
