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
    /// widen-to-`Int`, and computes `|delta|` in `UInt8`, so pin the agreement with the
    /// straightforward loop on the fixtures — at the suite's 16x16 and at the benchmark's 136x132
    /// tile, where the early exit actually fires.
    ///
    /// This test compares **verdicts on content**: the largest channel delta any fixture below
    /// reaches is 225, so it structurally cannot see the cut at `|delta| ∈ {252...255}`, and the
    /// failure mode this suite exists to catch — a `UInt8` delta that only ever *adds* to `smooth` —
    /// survived it. The cut is pinned by `testTheBytePredicateIsTheAbsoluteDifference` (all 65,536
    /// pairs) and by the counter-level tiles in `testExtremeDeltaTilesMatchTheReferenceCounters`.
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

    // MARK: the cut at |delta| = 4, and the `UInt8` alias at 252

    /// The reference again, reporting the counters instead of only the Bool: the fast scan's contract
    /// is that its `smooth` and `total` are the reference's, and a verdict-only test can agree by
    /// luck — one count off, on a tile far enough from the threshold to hide the difference.
    private func exhaustiveCounts(_ pixels: [UInt8], w: Int, h: Int) -> (smooth: Int, total: Int) {
        guard w > 1, h > 0, pixels.count >= w * h else { return (0, 0) }
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
        return (smooth, compared)
    }

    /// The predicate itself, over every pair of bytes (issue #94).
    ///
    /// A 2x1 bpp-3 tile has exactly three comparisons and all three are the pair we put in it, so the
    /// majority vote reports the predicate directly: either all three are smooth (`2·3 > 3` → yes)
    /// or none are (→ no), and nothing in between is reachable. This is the test that would have
    /// caught the first version of the loop, which wrote `d <= 4 || d >= 252` on the *wrapping*
    /// delta `a &- b` — that is `|a - b| <= 4` only while `|a - b| < 128`. It counted
    /// `|a - b| ∈ {252...255}` as smooth: 20 pairs of 65,536, every one of them a maximally
    /// *unsmooth* pair, so the error only ever ran in the "this compresses" direction.
    func testTheBytePredicateIsTheAbsoluteDifference() {
        // Two pixels, three channels each, so all three comparisons are the ordered pair (a, b).
        let rect: TileRect = (x: 0, y: 0, w: 2, h: 1, col: 1, row: 1, cols: 2, rows: 1)
        var wrong: [(UInt8, UInt8)] = []
        for a in UInt8.min...UInt8.max {
            for b in UInt8.min...UInt8.max {
                let reference = abs(Int(a) - Int(b)) <= 4
                if ScreenWriter.looksCompressible([a, a, a, b, b, b], rect: rect) != reference {
                    wrong.append((a, b))
                }
            }
        }
        XCTAssertEqual(wrong.count, 0,
                       "the `UInt8` delta disagrees with `abs(Int(a) - Int(b)) <= 4` on "
                       + "\(wrong.count) of 65,536 pairs, e.g. "
                       + wrong.prefix(8).map { "\($0.0)/\($0.1)" }.joined(separator: " "))
        // The pairs the old spelling got wrong, named so a regression is legible.
        let maximallyUnsmooth: [(UInt8, UInt8)] = [(255, 0), (0, 255), (252, 0), (0, 252), (255, 4), (3, 255)]
        for (a, b) in maximallyUnsmooth {
            let d = a > b ? a &- b : b &- a
            XCTAssertGreaterThan(d, 4, "\(a)/\(b) is \(d) apart, so it is not a smooth pair")
            XCTAssertFalse(ScreenWriter.looksCompressible([a, a, a, b, b, b], rect: rect),
                           "\(a)/\(b) is maximally unsmooth: it must not claim zlib can win")
        }
    }

    /// Tiles that sit on the cut, the way an alternating black/white tile does — the counter and the
    /// verdict against the straight `Int` reference, on both sides of every boundary a `UInt8` delta
    /// can get wrong: `4` against `5`, and the alias at `252` (`251` apart is still 251 and was
    /// never counted; `252` apart wrapped back to `d = 252` and was).
    ///
    /// The old spelling called the first two tiles **compressible** — it counted 93 of 93 comparisons
    /// smooth on content whose every comparison is 255 apart — and that is the direction that costs
    /// a frame: `looksCompressible == true` is what suppresses the #59 quantise on exactly the
    /// high-contrast incompressible tiles the shortcut exists for.
    func testExtremeDeltaTilesMatchTheReferenceCounters() {
        let w = 8, h = 4, bpp = 3
        let total = h * w * bpp - bpp                    // 93 comparisons in an 8x4 bpp-3 tile
        func rect(_ w: Int, _ h: Int) -> TileRect {
            (x: 0, y: 0, w: w, h: h, col: 1, row: 1, cols: w, rows: h)
        }
        /// Checkerboard: every in-row and every in-column comparison is the same `|hi - lo|`, so the
        /// expected count is all of them or none of them.
        func checker(_ lo: UInt8, _ hi: UInt8) -> (name: String, pixels: [UInt8]) {
            var out = [UInt8](repeating: 0, count: w * h * bpp)
            for y in 0..<h {
                for x in 0..<w {
                    let v = (x + y) % 2 == 0 ? lo : hi
                    let o = (y * w + x) * bpp
                    out[o] = v; out[o + 1] = v; out[o + 2] = v
                }
            }
            return ("checker \(lo)/\(hi) (\(abs(Int(hi) - Int(lo))) apart)", out)
        }
        /// One flat colour per row: the 21 in-row comparisons are 0 apart, and each of the three row
        /// steps contributes 24 comparisons at its own delta — the knob that walks up to the majority
        /// threshold (`2·smooth > 93`, i.e. 47 of 93) instead of jumping over it.
        func rows(_ values: [UInt8]) -> (name: String, pixels: [UInt8]) {
            var out = [UInt8](repeating: 0, count: w * h * bpp)
            for y in 0..<h {
                for x in 0..<w {
                    let o = (y * w + x) * bpp
                    out[o] = values[y]; out[o + 1] = values[y]; out[o + 2] = values[y]
                }
            }
            return ("rows \(values)", out)
        }

        // (fixture, expected smooth count, expected verdict), hand-computed above; every one of them
        // is also checked against `exhaustiveCounts`, which is the machine check.
        let cases: [(fixture: (name: String, pixels: [UInt8]), smooth: Int, verdict: Bool)] = [
            // Maximally unsmooth: the case the old spelling got backwards.
            (checker(0, 255), 0, false),
            (checker(0, 252), 0, false),
            // ... and the neighbour where both spellings agree: 251 apart is not within 4 either.
            (checker(0, 251), 0, false),
            // Both sides of the cut itself: 4 apart is smooth, 5 apart is not.
            (checker(248, 252), total, true),
            (checker(247, 252), 0, false),
            (checker(0, 4), total, true),
            (checker(0, 5), 0, false),
            // Walking up to the majority threshold from both sides: 2·45 = 90 ≤ 93 loses,
            // 2·69 = 138 > 93 wins. The old spelling said 93/93 on both.
            (rows([0, 255, 0, 255]), 21, false),
            (rows([0, 255, 0, 0]), 45, false),
            (rows([0, 255, 255, 255]), 69, true),
            // Zero delta everywhere is still smooth: the fix must not over-correct.
            (rows([255, 255, 255, 255]), total, true),
        ]

        for c in cases {
            let reference = exhaustiveCounts(c.fixture.pixels, w: w, h: h)
            XCTAssertEqual(reference.total, total, "\(c.fixture.name): 93 comparisons in an 8x4 bpp-3 tile")
            XCTAssertEqual(reference.smooth, c.smooth, "\(c.fixture.name): the reference's smooth count")
            XCTAssertEqual(2 * reference.smooth > reference.total, c.verdict,
                           "\(c.fixture.name): the hand-computed verdict")
            let verdict = ScreenWriter.looksCompressible(c.fixture.pixels, rect: rect(w, h))
            XCTAssertEqual(verdict, c.verdict, "\(c.fixture.name): the scan's verdict")
            XCTAssertEqual(verdict, exhaustive(c.fixture.pixels, w: w, h: h),
                           "\(c.fixture.name): the scan and the reference disagree")
        }

        // The single-row case, where there is no pixel above and every comparison is horizontal:
        // eight alternating 0/255 cells have no smooth comparison at all.
        var single = [UInt8](repeating: 0, count: w * bpp)
        for x in 0..<w { for c in 0..<bpp { single[x * bpp + c] = x % 2 == 0 ? 0 : 255 } }
        let singleReference = exhaustiveCounts(single, w: w, h: 1)
        XCTAssertEqual(singleReference.total, w * bpp - bpp, "21 comparisons in an 8x1 bpp-3 tile")
        XCTAssertEqual(singleReference.smooth, 0, "every 8x1 comparison is 255 apart")
        XCTAssertFalse(ScreenWriter.looksCompressible(single, rect: rect(w, 1)))
    }
}
