import XCTest
@testable import krdcore

/// Skipping zlib when it buys nothing (issue #53).
///
/// The decision is per tile and uses the previous frame's ratio, which is the only free signal the
/// encoder has. Two things have to hold: a noise tile must not be compressed twice in a row, and a
/// tile that turns back into text must go back to compressing on its own.
final class SkipCompressionTests: XCTestCase {
    private let rect: TileRect = (x: 0, y: 0, w: 16, h: 16, col: 1, row: 1, cols: 16, rows: 16)

    /// Deterministic noise: xorshift, so the fixture is the same on every machine.
    private func noise(count: Int, seed: UInt32 = 0x1234_5678) -> [UInt8] {
        var x = seed
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            out[i] = UInt8(truncatingIfNeeded: x)
        }
        return out
    }

    private func text(count: Int) -> [UInt8] {
        // Highly compressible, like a glyph grid: mostly one colour with sparse marks.
        var out = [UInt8](repeating: 255, count: count)
        for i in stride(from: 0, to: count, by: 97) { out[i] = 0 }
        return out
    }

    // MARK: compress

    func testLevelZeroSendsRawPixelsAndSaysSo() throws {
        // Level 0 + pixels zlib cannot win on. (Text at level 0 is the rescue path, below.)
        let pixels = noise(count: 16 * 16 * 3)
        let tile = try XCTUnwrap(ScreenWriter.compress(index: 0, rect: rect, pixels: pixels, level: 0))
        XCTAssertEqual(tile.payload, pixels, "level 0 must not touch the bytes")
        XCTAssertFalse(tile.isCompressed)
        XCTAssertEqual(tile.ratio, 1.0)
    }

    func testCompressibleTileStillCompresses() throws {
        let pixels = text(count: 16 * 16 * 3)
        let tile = try XCTUnwrap(ScreenWriter.compress(index: 0, rect: rect, pixels: pixels, level: 6))
        XCTAssertTrue(tile.isCompressed)
        XCTAssertEqual(tile.ratio, Double(tile.payload.count) / Double(pixels.count))
        XCTAssertLessThan(tile.ratio, 0.5)
    }

    func testExpandingTileIsSentRawInsteadOfBigger() throws {
        let pixels = noise(count: 16 * 16 * 3)
        let tile = try XCTUnwrap(ScreenWriter.compress(index: 0, rect: rect, pixels: pixels, level: 6))
        // zlib on noise expands; sending the compressed bytes would be strictly worse.
        XCTAssertFalse(tile.isCompressed)
        XCTAssertEqual(tile.payload, pixels)
        XCTAssertEqual(tile.ratio, 1.0)
    }

    func testEmptyTileIsStillDropped() {
        XCTAssertNil(ScreenWriter.compress(index: 0, rect: rect, pixels: [], level: 6))
    }

    // MARK: policy

    func testPolicyStopsCompressingATileThatDidNotPay() {
        var policy = LevelPolicy(tiles: 4)
        XCTAssertGreaterThan(policy.level(for: 2), 0, "first frame must compress: nothing is known yet")
        policy.observe(index: 2, ratio: 1.0002)
        XCTAssertEqual(policy.level(for: 2), 0)
        XCTAssertEqual(policy.level(for: 1), 5, "other tiles are unaffected")
        XCTAssertEqual(policy.skippedCount, 1)
    }

    func testSkippedTileIsRescuedWhenTheContentBecomesCompressible() throws {
        // Level 0 says "zlib did not pay last frame". The pixels get the last word: if they look
        // like text now, compressing again is free money and the policy relearns the ratio.
        let textTile = try XCTUnwrap(ScreenWriter.compress(index: 0, rect: rect,
                                                           pixels: text(count: 16 * 16 * 3), level: 0))
        XCTAssertTrue(textTile.isCompressed, "text must not stay uncompressed because a photo was here")
        XCTAssertLessThan(textTile.ratio, 0.5)

        let noiseTile = try XCTUnwrap(ScreenWriter.compress(index: 0, rect: rect,
                                                            pixels: noise(count: 16 * 16 * 3), level: 0))
        XCTAssertFalse(noiseTile.isCompressed, "noise must stay uncompressed")
    }

    func testPredictorSeesThroughGradientsAndNotThroughNoise() {
        // A gradient changes by 1 per pixel and still compresses 45x: the predictor compares
        // neighbouring bytes, not their values, so it must call this compressible.
        let w = 16, h = 16, bpp = 3
        var gradient = [UInt8](repeating: 0, count: w * h * bpp)
        for y in 0..<h {
            for x in 0..<w {
                let v = UInt8(min(255, x * 8))
                let o = (y * w + x) * bpp
                gradient[o] = v; gradient[o + 1] = v; gradient[o + 2] = v
            }
        }
        let rect16: TileRect = (x: 0, y: 0, w: w, h: h, col: 1, row: 1, cols: w, rows: h)
        XCTAssertTrue(ScreenWriter.looksCompressible(gradient, rect: rect16))
        XCTAssertTrue(ScreenWriter.looksCompressible(text(count: w * h * bpp), rect: rect16))
        XCTAssertFalse(ScreenWriter.looksCompressible(noise(count: w * h * bpp), rect: rect16))
    }

    func testContentThatBecomesCompressibleIsCompressedAgain() {
        var policy = LevelPolicy(tiles: 1)
        policy.observe(index: 0, ratio: 1.01)                   // noise: skip
        XCTAssertEqual(policy.level(for: 0), 0)
        policy.observe(index: 0, ratio: 0.12)                   // text arrived: zlib clearly wins
        XCTAssertGreaterThan(policy.level(for: 0), 0)
    }

    func testBreakEvenRatiosDoNotFlap() {
        var policy = LevelPolicy(tiles: 1)
        policy.observe(index: 0, ratio: 1.004)
        XCTAssertEqual(policy.level(for: 0), 0)
        // 0.99 is inside the hysteresis band: the decision must not change.
        policy.observe(index: 0, ratio: 0.99)
        XCTAssertEqual(policy.level(for: 0), 0, "0.99 is break-even, not a win")
        // Below 1.0 - 3 % it is a clear win again.
        policy.observe(index: 0, ratio: 0.96)
        XCTAssertGreaterThan(policy.level(for: 0), 0)
    }
}
