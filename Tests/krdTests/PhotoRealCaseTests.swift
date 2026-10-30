import XCTest
@testable import krd
@testable import krdcore

/// The `photoReal` bench case (issue #65).
///
/// `photo` is hash noise — every pixel independent — so it is the worst case for compression and a
/// poor model of what people mirror. `photoReal` has to be (a) byte-identical on every run and every
/// machine, (b) clearly compressible losslessly, and (c) the kind of content where 5-6-5
/// quantisation pays about twice over. All three are pinned here, because a benchmark case that
/// silently drifts is worse than no case at all.
final class PhotoRealCaseTests: XCTestCase {
    private func frame(_ content: BenchContent, seed: Int = 0) -> ([UInt8], TileGrid) {
        let grid = TileGrid.make(paneCols: 137, paneRows: 44, cellW: 17, cellH: 33,
                                 aspect: 2329.0 / 1452.0, tileCols: 8, tileRows: 4, bpp: 3)
        return (benchMakeFrame(grid, content, seed: seed), grid)
    }

    private func ratio(_ pixels: [UInt8], quantised: Bool) -> Double {
        let input = quantised ? ScreenWriter.quantise565(pixels) : pixels
        let packed = zlibCompress(input, level: 5)
        return Double(packed?.count ?? input.count) / Double(pixels.count)
    }

    func testSameBytesOnEveryRun() {
        let (a, _) = frame(.photoReal)
        let (b, _) = frame(.photoReal)
        XCTAssertEqual(a, b, "the case must not depend on a clock, a seed or an RNG")
        // And a different seed must actually change it, or `patch` cannot produce a new frame.
        let (c, _) = frame(.photoReal, seed: 1)
        XCTAssertNotEqual(a, c)
    }

    func testItCompressesLosslessly() {
        let (pixels, _) = frame(.photoReal)
        let lossless = ratio(pixels, quantised: false)
        XCTAssertLessThan(lossless, 0.90, "must be photo-like, not noise (ratio \(lossless))")
        // For reference, the noise case cannot do this at all.
        let (noise, _) = frame(.noise)
        XCTAssertGreaterThan(ratio(noise, quantised: false), 0.99)
    }

    func testQuantisationPaysAboutTwiceOver() {
        let (pixels, _) = frame(.photoReal)
        let lossless = ratio(pixels, quantised: false)
        let quantised = ratio(pixels, quantised: true)
        let gain = lossless / quantised
        XCTAssertGreaterThan(gain, 1.8, "5-6-5 should pay ~2x here (lost \(lossless) -> \(quantised))")
        // The noise case is the one that only pays 1.29x; that asymmetry is the point of #65.
        let (noise, _) = frame(.noise)
        let noiseGain = ratio(noise, quantised: false) / ratio(noise, quantised: true)
        XCTAssertLessThan(noiseGain, 1.45)
        if ProcessInfo.processInfo.environment["KRD_PRINT_RATIOS"] != nil {
            let (n, _) = frame(.noise)
            FileHandle.standardError.write(Data(String(
                format: "photoReal lossless=%.4f quantised=%.4f gain=%.2fx | noise lossless=%.4f quantised=%.4f gain=%.2fx\n",
                lossless, quantised, gain,
                ratio(n, quantised: false), ratio(n, quantised: true), noiseGain).utf8))
        }
    }

    func testWideColourRangeSoTheQuantiserIsExercised() {
        // If the content sat on a handful of colours, quantising it would be a no-op and the case
        // would quietly stop testing anything.
        let (pixels, _) = frame(.photoReal)
        var seen = Set<UInt8>()
        for i in stride(from: 0, to: pixels.count, by: 3) { seen.insert(pixels[i]) }
        XCTAssertGreaterThan(seen.count, 64, "only \(seen.count) distinct red values")
    }
}
