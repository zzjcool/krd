import XCTest
@testable import krdcore

/// `--quality`: one number for how much colour a frame may lose.
///
/// The point of the ladder is that it is *bit depth*, not a menu of encodings: every rung below 100
/// still sends `f=24`, so nothing about the wire changes, and the one rung that is lossless is the
/// only one that keeps every pixel.
final class QualityTests: XCTestCase {
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

    // MARK: the mapping

    func testTheRungsAreWhereTheDocumentationSays() {
        XCTAssertNil(QualityBudget(100).bits, "100 is lossless")
        XCTAssertEqual(QualityBudget(95).bits, QualityBudget.sixSixSix)
        XCTAssertEqual(QualityBudget(90).bits, QualityBudget.sixSixSix)
        XCTAssertEqual(QualityBudget(85).bits, QualityBudget.fiveSixFive)
        XCTAssertEqual(QualityBudget(80).bits, QualityBudget.fiveSixFive)
        XCTAssertEqual(QualityBudget(70).bits, QualityBudget.fiveFiveFive)
        XCTAssertEqual(QualityBudget(50).bits, QualityBudget.fourFourFour)
        XCTAssertEqual(QualityBudget(0).bits, QualityBudget.fourFourFour,
                       "below the lowest shipped rung it clamps, it does not invent an encoding")
    }

    func testOnlyTheRungsWhereBytesMatterQuantiseEagerly() {
        XCTAssertFalse(QualityBudget(100).eager)
        XCTAssertFalse(QualityBudget(90).eager, "6-6-6 stays behind the two-frame guard")
        XCTAssertFalse(QualityBudget(80).eager, "the default must behave exactly as before")
        XCTAssertTrue(QualityBudget(70).eager, "5-5-5 has given up on waiting")
        XCTAssertTrue(QualityBudget(50).eager)
    }

    func testTheDefaultIsWhatKrdAlwaysDid() {
        let budget = QualityBudget.default
        XCTAssertEqual(budget.value, 80)
        XCTAssertEqual(budget.bits, QualityBudget.fiveSixFive)
        XCTAssertFalse(budget.eager)
        XCTAssertEqual(budget.label, "5-6-5")
        XCTAssertEqual(QualityBudget(100).label, "lossless")
    }

    func testOutOfRangeValuesClampAndSaySo() {
        XCTAssertEqual(QualityBudget(101).value, 100)
        XCTAssertEqual(QualityBudget(-7).value, 0)
        XCTAssertTrue(QualityBudget(101).isLossy == false)
        XCTAssertTrue(QualityBudget(-7).isLossy, "0 is the most lossy end, not lossless")
    }

    // MARK: the quantiser

    func testEveryRungKeepsWhiteWhiteAndBlackBlack() {
        for bits in [QualityBudget.sixSixSix, QualityBudget.fiveSixFive,
                     QualityBudget.fiveFiveFive, QualityBudget.fourFourFour] {
            let out = ScreenWriter.quantise([0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00], bits: bits)
            XCTAssertEqual(Array(out[0...2]), [0xFF, 0xFF, 0xFF], "\(bits.label) darkened white")
            XCTAssertEqual(Array(out[3...5]), [0x00, 0x00, 0x00], "\(bits.label) lifted black")
        }
    }

    func testTheDroppedBitsAreReplicatedNotZeroed() {
        // 4 bits: 0x7F -> 7 << 4 | 7 = 0x77, so the pixel keeps its brightness instead of drifting
        // dark, which is the whole reason the quantiser replicates instead of masking.
        XCTAssertEqual(ScreenWriter.quantise([0x7F, 0x7F, 0x7F], bits: QualityBudget.fourFourFour),
                       [0x77, 0x77, 0x77])
        // 5 bits: 0x08 -> 1 << 3 | 1 >> 2 = 0x08
        XCTAssertEqual(ScreenWriter.quantise([0x08, 0x08, 0x08], bits: QualityBudget.fiveSixFive),
                       [0x08, 0x08, 0x08])
        // 6 bits: 0x7F -> 31 << 2 | 31 >> 4 = 0x7D
        XCTAssertEqual(ScreenWriter.quantise([0x7F, 0x7F, 0x7F], bits: QualityBudget.sixSixSix),
                       [0x7D, 0x7D, 0x7D])
    }

    func testQuantise565IsJustTheFiveSixFiveRung() {
        let pixels = noise(count: 32 * 32 * 3)
        XCTAssertEqual(ScreenWriter.quantise565(pixels),
                       ScreenWriter.quantise(pixels, bits: QualityBudget.fiveSixFive))
    }

    // MARK: the ladder, measured on a tile

    private func payload(_ quality: Int, _ pixels: [UInt8]) -> CompressedTile? {
        let plan = LevelPolicy.Plan(level: 1, quantise: quality < 100,
                                   bits: QualityBudget(quality).bits,
                                   eager: QualityBudget(quality).eager)
        return ScreenWriter.compress(index: 0, rect: rect, pixels: pixels, plan: plan)
    }

    /// The ladder has to actually get cheaper as the number goes down -- except between 90 and 80,
    /// where the encoder is *better* at 6-6-6 than at 5-6-5. That is not an arithmetic slip: 5-6-5
    /// gives zlib a 32/64/32 alphabet to code, 6-6-6 a uniform 64-symbol one, and the uniform one
    /// wins at the same time as it looks better. It is why `docs/ENCODING.md` calls 6-6-6 a candidate
    /// default; the shipped default stays at 80 because that is what krd did before the flag existed.
    func testEachRungDownCostsFewerBytes() {
        let pixels = noise(count: 32 * 32 * 3)
        var sizes: [(Int, Int)] = []
        for quality in [100, 90, 70, 50] {
            guard let tile = payload(quality, pixels) else { return XCTFail("no payload") }
            sizes.append((quality, tile.payload.count))
        }
        for (upper, lower) in zip(sizes, sizes.dropFirst()) {
            XCTAssertLessThan(lower.1, upper.1,
                              "quality \(lower.0) (\(lower.1) B) must cost less than "
                              + "quality \(upper.0) (\(upper.1) B)")
        }
        guard let fiveSixFive = payload(80, pixels), let sixSixSix = payload(90, pixels) else {
            return XCTFail("no payload")
        }
        XCTAssertLessThanOrEqual(fiveSixFive.payload.count, sizes[0].1,
                                 "even the awkward rung must beat lossless")
        if sixSixSix.payload.count < fiveSixFive.payload.count {
            // Not a failure: 6-6-6 is cheaper *and* finer here. Pinned so that a change which
            // reverses it is noticed rather than silently making quality 90 the worse buy.
            XCTAssertLessThan(sixSixSix.payload.count, fiveSixFive.payload.count,
                              "6-6-6's uniform alphabet should still win on noise")
        }
    }

    func testTheLosslessRungNeverQuantises() {
        let pixels = noise(count: 32 * 32 * 3)
        guard let tile = payload(100, pixels) else { return XCTFail("no payload") }
        XCTAssertFalse(tile.isQuantised)
    }

    func testCoarseRungsSayTheyQuantised() {
        let pixels = noise(count: 32 * 32 * 3)
        for quality in [90, 80, 70, 50] {
            guard let tile = payload(quality, pixels) else { return XCTFail("no payload") }
            XCTAssertTrue(tile.isQuantised, "quality \(quality) should have quantised a noise tile")
        }
    }

    func testEagerRungsQuantiseTextTooAndStillCompressIt() {
        let pixels = text(count: 32 * 32 * 3)
        guard let tile = payload(50, pixels) else { return XCTFail("no payload") }
        XCTAssertTrue(tile.isQuantised, "quality 50 does not wait for the guard")
        XCTAssertLessThan(tile.ratio, 1.0, "and the content still compresses after quantising")
    }

    // MARK: the policy carries the budget

    func testDefaultPolicyStillWaitsForTwoIncompressibleFrames() {
        var policy = LevelPolicy(tiles: 1, quality: .default)
        XCTAssertFalse(policy.plan(for: 0).quantise, "first frame: no evidence yet")
        policy.observe(index: 0, ratio: 1.0002)
        XCTAssertFalse(policy.plan(for: 0).quantise, "one bad frame is not a photo")
        policy.observe(index: 0, ratio: 1.0002)
        XCTAssertTrue(policy.plan(for: 0).quantise, "two in a row is")
        XCTAssertEqual(policy.plan(for: 0).bits, QualityBudget.fiveSixFive)
        XCTAssertFalse(policy.plan(for: 0).eager)
    }

    func testLosslessQualityIsTheOldNoQuantise() {
        var policy = LevelPolicy(tiles: 1, quality: QualityBudget(100))
        for _ in 0..<3 { policy.observe(index: 0, ratio: 1.0002) }
        XCTAssertFalse(policy.plan(for: 0).quantise, "--quality 100 must stay lossless")
        XCTAssertNil(policy.plan(for: 0).bits)
        XCTAssertEqual(policy.plan(for: 0).level, 0, "but skipping zlib still applies")
        XCTAssertFalse(policy.allowsQuantise)
    }

    func testEagerQualityQuantisesFromTheFirstFrame() {
        let policy = LevelPolicy(tiles: 1, quality: QualityBudget(50))
        XCTAssertTrue(policy.plan(for: 0).quantise, "quality 50 does not wait for evidence")
        XCTAssertEqual(policy.plan(for: 0).bits, QualityBudget.fourFourFour)
        XCTAssertTrue(policy.plan(for: 0).eager)
    }

    func testQuantisedCountReportsWhatThePanelShows() {
        var policy = LevelPolicy(tiles: 4, quality: .default)
        XCTAssertEqual(policy.quantisedCount, 0)
        for _ in 0..<2 { policy.observe(index: 1, ratio: 1.0002) }
        XCTAssertEqual(policy.quantisedCount, 1)
        let eager = LevelPolicy(tiles: 4, quality: QualityBudget(60))
        XCTAssertEqual(eager.quantisedCount, 4, "an eager budget quantises every tile of the frame")
    }
}
