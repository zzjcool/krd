import XCTest
import CZlib
@testable import krd
@testable import krdcore

/// Pure logic only: the tiling maths, the dirty detection, the zlib policy. Anything that
/// touches ScreenCaptureKit, a tty or the window server is out of scope here on purpose --
/// those are covered by `krd --selftest` and `krd --bench`, which need neither a test host
/// nor accessibility permissions.
final class TileGridTests: XCTestCase {
    private func geometry(cols: Int = 137, rows: Int = 44) -> TermGeometry {
        // No pixel report: the grid falls back to fallbackCell, so pin it per test.
        TermGeometry.fallbackCell = (w: 17, h: 33)
        return TermGeometry(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    func testLayoutFitsThePane() {
        let grid = TileGrid.make(geometry: geometry(), aspect: 0.5625, tileCols: 8, tileRows: 4)
        XCTAssertLessThanOrEqual(grid.paneCols, 137)
        XCTAssertLessThanOrEqual(grid.paneRows, 44)
        XCTAssertEqual(grid.pixelW, grid.paneCols * Int(grid.cellW.rounded()))
        XCTAssertEqual(grid.pixelH, grid.paneRows * Int(grid.cellH.rounded()))
        XCTAssertEqual(grid.tilesX, (grid.paneCols + 7) / 8)
        XCTAssertEqual(grid.tilesY, (grid.paneRows + 3) / 4)
        XCTAssertEqual(grid.count, grid.tilesX * grid.tilesY)
    }

    func testTilesCoverEveryPixelExactlyOnce() {
        let grid = TileGrid.make(geometry: geometry(), aspect: 0.5625, tileCols: 8, tileRows: 4)
        var seen = [Int](repeating: 0, count: grid.pixelW * grid.pixelH)
        for ty in 0..<grid.tilesY {
            for tx in 0..<grid.tilesX {
                let r = grid.rect(tx, ty)
                XCTAssertGreaterThan(r.w, 0)
                XCTAssertGreaterThan(r.h, 0)
                for y in r.y..<(r.y + r.h) {
                    for x in r.x..<(r.x + r.w) {
                        seen[y * grid.pixelW + x] += 1
                    }
                }
            }
        }
        XCTAssertTrue(seen.allSatisfy { $0 == 1 }, "every pixel belongs to exactly one tile")
    }

    func testEdgeTilesAreTheRemainder() {
        let grid = TileGrid.make(geometry: geometry(), aspect: 0.5625, tileCols: 8, tileRows: 4)
        let full = grid.rect(0, 0)
        let lastX = grid.rect(grid.tilesX - 1, 0)
        let lastY = grid.rect(0, grid.tilesY - 1)
        XCTAssertEqual(full.x, 0)
        XCTAssertEqual(full.y, 0)
        XCTAssertEqual(lastX.x + lastX.w, grid.pixelW)
        XCTAssertEqual(lastY.y + lastY.h, grid.pixelH)
        XCTAssertLessThanOrEqual(lastX.w, full.w)
        XCTAssertLessThanOrEqual(lastY.h, full.h)
    }

    func testDirtyOnlyReportsChangedTiles() {
        let grid = TileGrid.make(geometry: geometry(), aspect: 0.5625, tileCols: 8, tileRows: 4)
        let bytes = grid.pixelW * grid.pixelH * 3
        var a = [UInt8](repeating: 0, count: bytes)
        var b = a
        XCTAssertEqual(TileGrid.dirty(previous: a, current: b, grid: grid), [])

        let target = grid.rect(2, 1)
        let offset = ((target.y + target.h / 2) * grid.pixelW + target.x + target.w / 2) * 3
        b[offset] = 255
        a = a.map { $0 }                     // keep both sides uniquely referenced
        XCTAssertEqual(TileGrid.dirty(previous: a, current: b, grid: grid), [1 * grid.tilesX + 2])
    }

    func testExtractCopiesTheRightRegionForBothFormats() {
        for bpp in [3, 4] {
            let grid = TileGrid.make(geometry: geometry(), aspect: 0.5625,
                                     tileCols: 8, tileRows: 4, bpp: bpp)
            var frame = [UInt8](repeating: 0, count: grid.pixelW * grid.pixelH * bpp)
            for i in 0..<frame.count { frame[i] = UInt8(truncatingIfNeeded: i &* 7) }
            let r = grid.rect(1, 2)
            let tile = grid.extract(frame, rect: r)
            XCTAssertEqual(tile.count, r.w * r.h * bpp)
            for row in 0..<r.h {
                let src = ((r.y + row) * grid.pixelW + r.x) * bpp
                let dst = row * r.w * bpp
                XCTAssertEqual(Array(tile[dst..<(dst + r.w * bpp)]),
                               Array(frame[src..<(src + r.w * bpp)]), "bpp=\(bpp) row=\(row)")
            }
        }
    }
}

final class EncodingTests: XCTestCase {
    private func inflate(_ input: [UInt8]) -> [UInt8] {
        let capacity = 1 << 22
        var out = [UInt8](repeating: 0, count: capacity)
        var length = uLongf(capacity)
        let status = out.withUnsafeMutableBufferPointer { dst -> Int32 in
            input.withUnsafeBufferPointer { src in
                uncompress(dst.baseAddress, &length, src.baseAddress, uLong(input.count))
            }
        }
        XCTAssertEqual(status, Z_OK)
        return Array(out[0..<Int(length)])
    }

    func testZlibRoundTripsAndHonoursTheLevel() {
        // Compressible content: level 9 has to be at least as small as level 1.
        let text = [UInt8](repeating: 200, count: 40000).enumerated().map { i, v in
            UInt8(truncatingIfNeeded: Int(v) + (i % 97 < 3 ? 40 : 0))
        }
        guard let fast = zlibCompress(text, level: 1), let best = zlibCompress(text, level: 9) else {
            return XCTFail("zlibCompress returned nil")
        }
        XCTAssertEqual(inflate(fast), text)
        XCTAssertEqual(inflate(best), text)
        XCTAssertLessThanOrEqual(best.count, fast.count)
    }

    func testCompressedTileCarriesTheExpectedPixelBytes() {
        let w = 136, h = 132
        let pixels = (0..<(w * h * 3)).map { UInt8(truncatingIfNeeded: $0) }
        let rect: TileRect = (x: 0, y: 0, w: w, h: h, col: 1, row: 1, cols: 8, rows: 4)
        guard let tile = ScreenWriter.compress(index: 7, rect: rect, pixels: pixels, level: 5) else {
            return XCTFail("compress returned nil")
        }
        XCTAssertEqual(tile.index, 7)
        XCTAssertEqual(inflate(tile.payload), pixels)
        XCTAssertGreaterThan(tile.ratio, 0)
        XCTAssertLessThanOrEqual(tile.ratio, 1.0 + 1e-9)
    }

    func testLevelPolicyPrefersNineForTextAndOneForNoise() {
        var policy = LevelPolicy(tiles: 4)
        XCTAssertEqual(policy.level(for: 0), 5, "unknown content starts in the middle")
        policy.observe(index: 0, ratio: 0.02)      // text compresses to 2 %
        XCTAssertEqual(policy.level(for: 0), 9)
        policy.observe(index: 1, ratio: 0.95)      // noise stays at 95 %
        XCTAssertEqual(policy.level(for: 1), 1)
        policy.observe(index: 1, ratio: 0.11)      // inside the hysteresis band: keep 1
        XCTAssertEqual(policy.level(for: 1), 1)
        policy.observe(index: 0, ratio: 0.30)      // clearly a photo now
        XCTAssertEqual(policy.level(for: 0), 1)
    }

    func testLevelPolicyIgnoresOutOfRangeTiles() {
        var policy = LevelPolicy(tiles: 2)
        policy.observe(index: 99, ratio: 0.01)
        XCTAssertEqual(policy.level(for: 99), 5)
    }
}
