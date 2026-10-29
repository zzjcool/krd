import XCTest
@testable import krdcore

/// The byte contract, pinned (issue #21).
///
/// `--selftest` plus `KRD_DUMP` already produce a byte stream, but a stream is only a regression
/// test if the *inputs* are pinned too — the compressor's level and the tile geometry both move
/// the bytes. This suite drives the encoder directly, at a fixed geometry and a fixed zlib level,
/// and compares against a dump committed to the repository. If a change to the escapes, the tiling
/// or the level policy reaches production, this fails with the first differing byte.
///
/// Regenerate on an intentional format change: `KRD_UPDATE_FIXTURE=1 swift test --filter Golden`.
final class GoldenDumpTests: XCTestCase {
    /// 80x24 cells of 17x33 px, 8x4-cell tiles — the geometry `--selftest --pane 80x24 --cell 17x33`
    /// uses, so the numbers here mean the same thing as the CLI's.
    private let paneCols = 80, paneRows = 24
    private let cellW = 17.0, cellH = 33.0
    private let tileCols = 8, tileRows = 4
    /// Pinned on purpose: `LevelPolicy` normally learns a level per tile from the last frame's
    /// ratio, which would make the golden bytes depend on the previous frames.
    private let level = 6

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/selftest-80x24-17x33-l6.dump")
    }

    private func makeGrid() -> TileGrid {
        TileGrid.make(paneCols: paneCols, paneRows: paneRows, cellW: cellW, cellH: cellH,
                      aspect: 1.7, tileCols: tileCols, tileRows: tileRows)
    }

    /// Two frames of a deterministic pattern: quadrants, a checkerboard dim, and a bar that moves
    /// between frames so the second frame dirties a different set of tiles (a dump with one frame
    /// would never exercise the dirty-only path).
    private func frame(_ grid: TileGrid, pass: Int) -> [UInt8] {
        let w = grid.pixelW, h = grid.pixelH, bpp = grid.bpp
        var px = [UInt8](repeating: 0, count: w * h * bpp)
        let quadrants: [(UInt8, UInt8, UInt8)] = [(255, 0, 255), (255, 255, 0), (0, 255, 255), (255, 128, 0)]
        for y in 0..<h {
            for x in 0..<w {
                let q = (y >= h / 2 ? 2 : 0) + (x >= w / 2 ? 1 : 0)
                let c = quadrants[q]
                let dim: UInt8 = ((x / 32 + y / 32) % 2 == 0) ? 255 : 190
                let bar = abs(x - (pass * w / 2)) < 8
                let o = (y * w + x) * bpp
                px[o] = bar ? 255 : c.0
                px[o + 1] = bar ? 255 : c.1
                px[o + 2] = bar ? 255 : c.2
                if bpp == 4 { px[o + 3] = bar ? 255 : dim }
            }
        }
        return px
    }

    /// The same sequence `Desk.handleFrame` runs, minus the concurrency and the learned levels:
    /// dirty tiles in index order, compressed at a pinned level, emitted serially.
    private func emit(_ writer: ScreenWriter, grid: TileGrid, pixels: [UInt8], previous: [UInt8]?) {
        let dirty = previous.map { TileGrid.dirty(previous: $0, current: pixels, grid: grid) }
            ?? Array(0..<grid.count)
        writer.resize(tiles: grid.count)
        writer.beginFrame()
        guard !dirty.isEmpty else {
            writer.nudge()
            writer.endFrame()
            return
        }
        for index in dirty {
            let rect = grid.rect(index % grid.tilesX, index / grid.tilesX)
            guard let tile = ScreenWriter.compress(index: index, rect: rect,
                                                   pixels: grid.extract(pixels, rect: rect),
                                                   level: level) else {
                XCTFail("compress returned nil for tile \(index)")
                continue
            }
            writer.emit(tile, sync: writer.perTileSync)
        }
        writer.endFrame()
    }

    /// One session: begin, two frames, end. Returns every byte the writer flushed.
    private func renderDump() -> [UInt8] {
        let grid = makeGrid()
        let writer = ScreenWriter()
        var bytes: [UInt8] = []
        writer.sink = { bytes.append(contentsOf: $0) }
        writer.beginSession()
        var previous: [UInt8]?
        for pass in 0..<2 {
            let pixels = frame(grid, pass: pass)
            emit(writer, grid: grid, pixels: pixels, previous: previous)
            previous = pixels
        }
        writer.endSession()
        return bytes
    }

    func testEncoderReproducesTheCommittedDumpByteForByte() throws {
        let got = renderDump()
        let url = fixtureURL()

        if ProcessInfo.processInfo.environment["KRD_UPDATE_FIXTURE"] != nil {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(got).write(to: url)
            print("golden fixture written: \(url.path) (\(got.count) B)")
            return
        }

        let want = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(got.count, want.count, "the dump changed size — escape format or tiling moved")
        // Compare in full: a first-difference diagnostic is worth more than "not equal".
        if got != want {
            let i = (0..<min(got.count, want.count)).first { got[$0] != want[$0] } ?? min(got.count, want.count)
            let lo = max(0, i - 24), hi = min(min(got.count, want.count), i + 24)
            XCTFail("the byte stream changed at offset \(i)\n"
                    + "  want: \(String(decoding: want[lo..<hi], as: UTF8.self).debugDescription)\n"
                    + "  got:  \(String(decoding: got[lo..<hi], as: UTF8.self).debugDescription)")
        }
    }

    func testTheDumpIsNotTriviallySmall() {
        // Guard against a fixture that would pass because both sides are empty.
        XCTAssertGreaterThan(renderDump().count, 10_000)
    }
}
