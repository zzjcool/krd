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

    // MARK: the fast scan (issue #94)

    /// The pre-#94 predictor, verbatim: every byte of the tile, straight loop, `Int` deltas. Kept
    /// here (not in the library) because it is the baseline the fast scan has to agree with, not the
    /// product.
    private func exhaustive(_ pixels: [UInt8], w: Int, h: Int) -> Bool {
        guard w > 1, h > 0, pixels.count >= w * h else { return true }
        let bpp = max(1, pixels.count / (w * h))
        let rowBytes = w * bpp
        var smooth = 0, compared = 0
        for y in 0..<h {
            let row = y * rowBytes
            for i in row..<(row + rowBytes) {
                let reference = y > 0 ? i - rowBytes : (i - bpp >= row ? i - bpp : -1)
                guard reference >= 0 else { continue }
                compared += 1
                if abs(Int(pixels[i]) - Int(pixels[reference])) <= 4 { smooth += 1 }
            }
        }
        guard compared > 0 else { return true }
        return Double(smooth) / Double(compared) > 0.5
    }

    /// "Cheaper" must not become "different" (issue #94): the fast scan exits early, drops the
    /// widen-to-`Int`, and uses a wrapping `UInt8` delta, so pin the agreement with the
    /// straightforward loop on the fixtures — at the suite's 16x16 and at the benchmark's 136x132
    /// tile, where the early exit actually fires.
    func testFastPredictorAgreesWithTheStraightforwardOne() {
        func gradientTile(_ w: Int, _ h: Int, bpp: Int) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: w * h * bpp)
            for y in 0..<h {
                for x in 0..<w {
                    let v = UInt8(min(255, x * 8)), o = (y * w + x) * bpp
                    out[o] = v; if bpp > 1 { out[o + 1] = v }; if bpp > 2 { out[o + 2] = v }
                }
            }
            return out
        }
        func noiseTile(_ w: Int, _ h: Int, bpp: Int) -> [UInt8] {
            // The class's own deterministic xorshift, sized like a tile.
            var x = UInt32(0x1234_5678)
            var out = [UInt8](repeating: 0, count: w * h * bpp)
            for i in 0..<out.count {
                x ^= x << 13; x ^= x >> 17; x ^= x << 5
                out[i] = UInt8(truncatingIfNeeded: x)
            }
            return out
        }
        func textTile(_ w: Int, _ h: Int, bpp: Int) -> [UInt8] {
            // The `text` content from Sources/krd/Bench.swift: glyph strokes on a flat page.
            var out = [UInt8](repeating: 0, count: w * h * bpp)
            for y in 0..<h {
                for x in 0..<w {
                    let glyph = (x % 23 < 3 || y % 41 < 2) ? UInt8(20) : UInt8(245)
                    let o = (y * w + x) * bpp
                    out[o] = glyph; if bpp > 1 { out[o + 1] = glyph }
                    if bpp > 2 { out[o + 2] = y % 97 < 2 ? 0 : glyph }
                }
            }
            return out
        }

        let shapes = [(w: 16, h: 16), (w: 136, h: 132), (w: 8, h: 4), (w: 3, h: 5)]
        let generators: [(String, (Int, Int, Int) -> [UInt8])] = [
            ("text", textTile), ("noise", noiseTile), ("gradient", gradientTile),
            ("flat", { w, h, bpp in [UInt8](repeating: 200, count: w * h * bpp) }),
        ]
        for (name, make) in generators {
            for bpp in [3, 4] {
                for shape in shapes {
                    let pixels = make(shape.w, shape.h, bpp)
                    let rect: TileRect = (x: 0, y: 0, w: shape.w, h: shape.h, col: 1, row: 1,
                                          cols: shape.w, rows: shape.h)
                    XCTAssertEqual(ScreenWriter.looksCompressible(pixels, rect: rect),
                                   exhaustive(pixels, w: shape.w, h: shape.h),
                                   "\(name) \(shape.w)x\(shape.h) bpp \(bpp): the sample changed the verdict")
                }
            }
        }
    }
}
