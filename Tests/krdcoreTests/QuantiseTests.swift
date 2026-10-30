import XCTest
@testable import krdcore

/// Quantising to 5-6-5 before zlib (issue #59).
///
/// The point is not a new wire format — the terminal still gets `f=24` — but that dropping the low
/// bits gives zlib repeats to point at, which is what a photograph on screen is missing.
final class QuantiseTests: XCTestCase {
    private let rect: TileRect = (x: 0, y: 0, w: 32, h: 32, col: 1, row: 1, cols: 32, rows: 32)

    private func noise(count: Int, seed: UInt32 = 0x9E37_79B9) -> [UInt8] {
        var x = seed
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            out[i] = UInt8(truncatingIfNeeded: x)
        }
        return out
    }

    private func text(count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 250, count: count)
        for i in stride(from: 0, to: count, by: 131) { out[i] = 10 }
        return out
    }

    // MARK: the quantiser itself

    func testBitReplicationIsCorrect() {
        // 5 bits replicate their top 3 into the low 3 (v << 3 | v >> 2); 6 bits their top 2.
        // 5 bits + replication: the top 5 bits survive, the low 3 are a copy of the top 3.
        for v in 0...255 {
            let q = Int(ScreenWriter.quantise565([UInt8(v), UInt8(v), UInt8(v)])[0])
            XCTAssertEqual(q >> 3, v >> 3, "top 5 bits preserved (v=\(v))")
            XCTAssertEqual(q & 0x07, q >> 5, "low 3 bits replicate the top 3 (v=\(v))")
            XCTAssertLessThanOrEqual(abs(q - v), 7, "5-bit reach (v=\(v))")
        }
        // 6 bits + replication: same idea, one bit wider.
        for v in 0...255 {
            let q = Int(ScreenWriter.quantise565([0, UInt8(v), 0])[1])
            XCTAssertEqual(q >> 2, v >> 2, "top 6 bits preserved (v=\(v))")
            XCTAssertEqual(q & 0x03, q >> 6, "low 2 bits replicate the top 2 (v=\(v))")
            XCTAssertLessThanOrEqual(abs(q - v), 3, "6-bit reach (v=\(v))")
        }
        // Exact cases: the ends of the range and one bit-pattern in the middle.
        XCTAssertEqual(ScreenWriter.quantise565([0, 0, 0]), [0, 0, 0])
        XCTAssertEqual(ScreenWriter.quantise565([255, 255, 255]), [255, 255, 255])
        XCTAssertEqual(ScreenWriter.quantise565([8, 4, 8]), [8, 4, 8])     // smallest steps survive
        XCTAssertEqual(ScreenWriter.quantise565([12, 0, 0])[0], 8)         // 12 -> bucket 1 -> 8
    }

    func testReplicationDoesNotBiasDownward() {
        // Truncation loses up to 7 and always downward, so a flat area drifts darker. Replication
        // splits the error either side of zero: the mean over the whole ramp is ~0.
        var sum = 0.0
        for v in 0...255 {
            let q = Int(ScreenWriter.quantise565([UInt8(v), 0, 0])[0])
            sum += Double(q - v)
        }
        XCTAssertLessThan(abs(sum / 256), 0.75, "mean error \(sum / 256), truncation would be ~-3.5")
    }

    func testQuantiseKeepsThePixelCountAndSkipsAlpha() {
        let rgba = noise(count: 4 * 3 * 4)
        let q = ScreenWriter.quantise565(rgba, bytesPerPixel: 4)
        XCTAssertEqual(q.count, rgba.count, "no format change: still 4 bytes per pixel")
        for i in stride(from: 3, to: q.count, by: 4) {
            XCTAssertEqual(q[i], rgba[i], "alpha untouched at offset \(i)")
        }
    }

    func testQuantisedNoiseCompresses() throws {
        let pixels = noise(count: 32 * 32 * 3)
        // Lossless: zlib on noise does not pay, so the tile goes out raw (#53).
        let lossless = try XCTUnwrap(ScreenWriter.compress(index: 0, rect: rect, pixels: pixels, level: 0))
        XCTAssertFalse(lossless.isCompressed)
        XCTAssertFalse(lossless.isQuantised)
        // Quantised: now it does pay, and the payload is meaningfully smaller.
        let quantised = try XCTUnwrap(ScreenWriter.compress(index: 0, rect: rect, pixels: pixels,
                                                            level: 0, quantise: true))
        XCTAssertTrue(quantised.isQuantised)
        XCTAssertTrue(quantised.isCompressed)
        XCTAssertLessThan(quantised.payload.count, pixels.count * 4 / 5,
                          "5-6-5 should cut noise well below 80 % of raw")
    }

    func testCompressibleContentIsNeverQuantised() throws {
        // Text is compressible, so the policy would not ask — and even if it did, the predictor
        // rescues it: precision is not spent where zlib already wins.
        let pixels = text(count: 32 * 32 * 3)
        let tile = try XCTUnwrap(ScreenWriter.compress(index: 0, rect: rect, pixels: pixels,
                                                       level: 0, quantise: true))
        XCTAssertFalse(tile.isQuantised)
        XCTAssertTrue(tile.isCompressed)
        XCTAssertLessThan(tile.ratio, 0.3)
    }

    // MARK: the state machine

    func testSwitchNeedsTwoIncompressibleFrames() {
        var policy = LevelPolicy(tiles: 4)
        policy.observe(index: 1, ratio: 1.0002)
        XCTAssertFalse(policy.plan(for: 1).quantise, "one noisy frame is a scroll, not a photo")
        XCTAssertEqual(policy.plan(for: 1).level, 0, "but zlib is already skipped (#53)")
        policy.observe(index: 1, ratio: 1.0002)
        XCTAssertTrue(policy.plan(for: 1).quantise, "two in a row: quantise")
        XCTAssertEqual(policy.plan(for: 1).level, 0)
        XCTAssertEqual(policy.quantisedCount, 1)
        XCTAssertFalse(policy.plan(for: 2).quantise, "other tiles are unaffected")
    }

    func testQuantisedFramesDoNotFlapBackToLossless() {
        var policy = LevelPolicy(tiles: 1)
        policy.observe(index: 0, ratio: 1.0002)
        policy.observe(index: 0, ratio: 1.0002)
        XCTAssertTrue(policy.plan(for: 0).quantise)
        // A quantised frame reports a good ratio — that must not be read as "content became text".
        for _ in 0..<10 {
            policy.observe(index: 0, ratio: 0.77, quantisedIn: true)
            XCTAssertTrue(policy.plan(for: 0).quantise, "a quantised tile stays quantised")
        }
    }

    func testContentThatCompressesAgainReturnsToLossless() {
        var policy = LevelPolicy(tiles: 1)
        policy.observe(index: 0, ratio: 1.0002)
        policy.observe(index: 0, ratio: 1.0002)
        XCTAssertTrue(policy.plan(for: 0).quantise)
        policy.observe(index: 0, ratio: 0.19)          // lossless won again (text arrived)
        XCTAssertFalse(policy.plan(for: 0).quantise)
        XCTAssertGreaterThan(policy.plan(for: 0).level, 0, "and it compresses losslessly")
    }

    func testNoQuantiseKeepsEverythingLossless() {
        var policy = LevelPolicy(tiles: 1, allowsQuantise: false)
        policy.observe(index: 0, ratio: 1.0002)
        policy.observe(index: 0, ratio: 1.0002)
        policy.observe(index: 0, ratio: 1.0002)
        XCTAssertFalse(policy.plan(for: 0).quantise, "--no-quantise must stay lossless")
        XCTAssertEqual(policy.plan(for: 0).level, 0, "but skipping zlib still applies")
    }
}
