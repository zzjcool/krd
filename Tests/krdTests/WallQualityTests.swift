import XCTest
import krdcore
@testable import krd

/// `--wall-quality` (issue #88): the landing screen's pictures lose *bits*, and nothing else.
///
/// The one thing that must never move is the geometry. The landing screen's rule is that the picture
/// is its cells (§6.6): a quality knob expressed as "a smaller picture in the same box" would reopen
/// #84 and draw a seam, so the tests below pin the arithmetic - same panels, same pixel size, same
/// alpha (a rounded corner is a hole in the picture, not a frame around it), same high bits - and then
/// pin that `--wall-quality 100` is the wall exactly as it was before this knob existed.
///
/// No window server: `WallPictures.demo` renders the test pattern through the *real* path (render →
/// quantise), which is why this can run anywhere. The byte counts the issue is about are measured on
/// the release binary (`krd --wall --demo --no-input --log …`, see the PR), because they belong to
/// zlib at the wall's level rather than to a unit here.
final class WallQualityTests: XCTestCase {
    private func pane(cols: Int = 40, rows: Int = 14) -> PaneGeometry {
        PaneGeometry(cols: cols, rows: rows, cellW: 8, cellH: 16, dpr: 2, source: "test")
    }

    /// The same panels `Desk.wallPanels` builds, without the AppKit bridge: a stage and one card.
    private func plan(cols: Int = 40, rows: Int = 14) -> [WallPanel] {
        let model = WallSource.demoModel()
        var state = WallState()
        state.per = 1
        let p = pane(cols: cols, rows: rows)
        let display = model.displays[0]
        let layout = state.layout(cols: p.cols, rows: p.rows,
                                  displays: model.displays.count,
                                  windows: model.windows.count,
                                  stageAspect: Double(display.width) / Double(display.height),
                                  cellAspect: p.cellAspect)
        let cell = p.pictureCell(scale: 2)
        let cards: [PanelSource?] = layout.cards.indices.map { slot in
            let index = layout.cardStart + slot
            guard model.windows.indices.contains(index) else { return nil }
            let window = model.windows[index]
            return PanelSource(kind: .window(window.windowID),
                               aspect: Double(window.bounds.width) / Double(window.bounds.height))
        }
        return WallPanels.plan(layout: layout, cellW: cell.w, cellH: cell.h,
                               stageSource: PanelSource(kind: .display(display.id),
                                                        aspect: Double(display.width)
                                                            / Double(display.height)),
                               cardSources: cards)
    }

    /// `WallPictures.demo`/`.quality` are process-wide and set once before a paint, so a test that
    /// sets them has to put them back: the next test must not inherit a rung it did not ask for.
    override func tearDown() {
        WallPictures.demo = false
        WallPictures.quality = .wall
        super.tearDown()
    }

    private func capture(_ panels: [WallPanel], quality: QualityBudget) async -> [WallPictures.Picture] {
        WallPictures.demo = true
        WallPictures.quality = quality
        return await WallPictures.capture(panels).pictures
    }

    // MARK: 100 is the wall as it was

    func testLosslessPassesThePixelsThroughUntouched() async {
        // The rule is arithmetic, not "the demo pattern happens to survive", and alpha is included:
        // 5-5-5 is a decision about three channels.
        let pixels: [UInt8] = [255, 128, 7, 0, 33, 66, 99, 128, 1, 2, 3, 255]
        XCTAssertEqual(WallPictures.quantised(pixels, quality: QualityBudget(100)), pixels)

        // And through the capture path: `--wall-quality 100` renders the demo pattern unquantised,
        // byte for byte, which is what a reader asking for the old wall gets.
        let pictures = await capture(plan(), quality: QualityBudget(100))
        XCTAssertFalse(pictures.isEmpty)
        for picture in pictures {
            XCTAssertEqual(picture.pixels,
                           DemoPicture.render(width: picture.width, height: picture.height),
                           "slot \(picture.panel.slot): 100 must not touch a pixel")
        }
    }

    /// The alpha the rounded corners *create*: `PanelImage.compose` punches a transparent hole in each
    /// corner, and this knob must leave the hole exactly as it was (a hole shows the wall underneath;
    /// an opaque hole is a frame around a smaller picture, the report behind §6.6). The demo pattern
    /// is opaque everywhere, so this composited canvas is the only place the property is visible.
    func testQuantisingLeavesTheRoundedCornersTransparent() {
        let width = 32, height = 32
        var content = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<content.count { content[i] = UInt8(truncatingIfNeeded: i &* 29 &+ 3) }
        let canvas = PanelImage.compose(content: content, width: width, height: height,
                                        panelWidth: width, panelHeight: height,
                                        originX: 0, originY: 0, cornerRadius: 6)
        XCTAssertEqual(canvas[3], 0, "the top-left corner is a hole to begin with")
        for quality in [QualityBudget.wall, QualityBudget(50), QualityBudget(100)] {
            let out = WallPictures.quantised(canvas, quality: quality)
            XCTAssertEqual(out.count, canvas.count)
            var alphaKept = true
            for i in stride(from: 0, to: canvas.count, by: 4) where out[i + 3] != canvas[i + 3] {
                alphaKept = false
            }
            XCTAssertTrue(alphaKept, "the alpha channel under --wall-quality \(quality.value)")
        }
    }

    // MARK: the knob moves bits, and only bits

    func testQuantisingKeepsEveryCellsWorthOfPixels() async {
        let panels = plan()
        let lossless = await capture(panels, quality: QualityBudget(100))
        let cheap = await capture(panels, quality: .wall)

        XCTAssertEqual(lossless.count, cheap.count, "the knob must not add or drop a panel")
        XCTAssertEqual(lossless.map(\.panel), cheap.map(\.panel),
                       "geometry is the layout's: mask rect == picture rect, exactly as before")
        XCTAssertEqual(lossless.map(\.width), cheap.map(\.width), "a quality knob is not a smaller picture")
        XCTAssertEqual(lossless.map(\.height), cheap.map(\.height))

        for (before, after) in zip(lossless, cheap) {
            XCTAssertEqual(before.pixels.count, after.pixels.count)
            XCTAssertEqual(before.width * before.height * 4, after.pixels.count,
                           "RGBA, exactly the panel's pixels: nothing cropped, nothing padded")
            var alphabet = [Set<UInt8>](repeating: [], count: 3)
            var highBitsKept = true, alphaKept = true, smallError = true, changed = false
            for i in stride(from: 0, to: before.pixels.count, by: 4) {
                for channel in 0..<3 {
                    let old = before.pixels[i + channel], new = after.pixels[i + channel]
                    // 5-5-5: the top five bits *are* the picture, the bottom three are replicated.
                    if old >> 3 != new >> 3 { highBitsKept = false }
                    if abs(Int(old) - Int(new)) > 7 { smallError = false }
                    alphabet[channel].insert(new)
                    if old != new { changed = true }
                }
                // Alpha is not colour: a rounded corner is a hole, and a hole is what lets a cut
                // corner show the wall underneath instead of a frame (§6.6).
                if before.pixels[i + 3] != after.pixels[i + 3] { alphaKept = false }
            }
            XCTAssertTrue(highBitsKept, "slot \(before.panel.slot): kept the high bits of every channel")
            XCTAssertTrue(smallError, "slot \(before.panel.slot): 5-5-5 moves a channel by at most 7")
            XCTAssertTrue(alphaKept, "slot \(before.panel.slot): the alpha channel is untouched")
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(alphabet[channel].count, 32,
                                         "slot \(before.panel.slot): a 5-bit channel has 32 values, "
                                         + "and that alphabet is what gives deflate its repeats")
            }
            XCTAssertTrue(changed, "slot \(before.panel.slot): the demo pattern does lose bits")
        }
    }

    // MARK: the lever's own unit: bytes

    /// What `--wall-quality` is *for*, on the closest thing to a desktop this machine has without a
    /// Screen Recording grant: the mock desktop (`MockCanvas`, the synthetic screen `--mock` streams
    /// through the real pipeline - wallpaper gradient, menu bar, two windows, a dock).
    ///
    /// zlib at the wall's own level, on the same pixels, quantised exactly as `WallPictures` does it.
    /// The assertion is the one direction that must hold on *any* content: dropping low bits never
    /// costs bytes, because the quantised alphabet is smaller than the one it came from.
    func testQuantisingADesktopLikePanelNeverCostsBytes() {
        let pixels = MockCanvas(width: 1920, height: 1199, bpp: 4).rendered(backdrop: true)
        var sizes: [Int] = []
        for quality in [QualityBudget(100), QualityBudget.wall, QualityBudget(50)] {
            let quantised = WallPictures.quantised(pixels, quality: quality)
            // `Desk.wallPanelLevel` is 3: a wall picture is encoded once per change, so the
            // level trades a few percent of size for ~3x less CPU.
            let bytes = zlibCompress(quantised, level: 3)?.count ?? 0
            print("WALLQ \(quality.value) \(quality.label) px=\(pixels.count) zlib=\(bytes) B")
            sizes.append(bytes)
        }
        XCTAssertLessThanOrEqual(sizes[1], sizes[0], "5-5-5 must not cost bytes on a desktop")
        XCTAssertLessThanOrEqual(sizes[2], sizes[1], "4-4-4 must not cost bytes on a desktop")
    }

    func testEachRungDropsWhatItSaysItDrops() async {
        let panels = plan()
        let lossless = await capture(panels, quality: QualityBudget(100))
        let cheap = await capture(panels, quality: QualityBudget(50))   // 4-4-4
        XCTAssertEqual(lossless.count, cheap.count)
        for (before, after) in zip(lossless, cheap) {
            var highBitsKept = true, replicated = true
            var alphabet = Set<UInt8>()
            for i in stride(from: 0, to: after.pixels.count, by: 4) {
                for channel in 0..<3 {
                    let old = before.pixels[i + channel], new = after.pixels[i + channel]
                    if old >> 4 != new >> 4 { highBitsKept = false }
                    // 4-4-4 replicating its high nibble into the low one: every value is high * 0x11.
                    if new % 17 != 0 { replicated = false }
                    alphabet.insert(new)
                }
                XCTAssertEqual(after.pixels[i + 3], before.pixels[i + 3])
            }
            XCTAssertTrue(highBitsKept, "slot \(before.panel.slot): kept the high nibble of every channel")
            XCTAssertTrue(replicated, "slot \(before.panel.slot): 4-4-4 replicates, it does not truncate")
            XCTAssertLessThanOrEqual(alphabet.count, 16,
                                     "slot \(before.panel.slot): a 4-bit channel has 16 values")
        }
    }
}
