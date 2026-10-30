import XCTest
import CoreGraphics
import krdcore
@testable import krd

/// Where a wall frame's time actually goes, measured on the pure (no window server) code that the
/// wall runs on its critical path: layout → plan → capture-side raster work → compress → placeholder
/// grid → text paint → diff.
///
/// WHY this file exists: the wall's cost has been a set of numbers in comments ("a whole wall's four
/// panels in 92.4 ms"), each measured once, on hardware that was doing something else, by a person
/// who then wrote the sentence that fitted. The questions asked of the landing screen - what is on
/// the critical path to the first picture, per-frame cost when nothing moves, what a page step
/// re-encodes, what the placeholder grid costs - can all be answered here, in process, with no
/// Screen Recording grant and no risk of photographing a desktop.
///
/// The numbers this prints are a *floor*, on purpose: `min` of N runs. The machine this normally runs
/// on has other work on it (this was measured at load average ~6 from four parallel audits), so a
/// mean would be a number about the machine rather than about the code. Run it with
/// `swift test -c release --filter WallPerf 2>&1 | grep PERF` for the real numbers — a debug build
/// is 5-20x slower on the pixel loops and only useful for relative comparisons.
///
/// Nothing here asserts a threshold: a timing assertion is a flaky test on any machine that is not
/// idle. It asserts *structure* (a diff that changes nothing emits nothing, a page step re-encodes
/// every panel) and prints the times.
final class WallPerfTests: XCTestCase {
    // MARK: the harness

    /// Best of `runs`, in milliseconds. `min`, not mean: see the class comment.
    @discardableResult
    private func bestMs(_ name: String, runs: Int = 5, _ body: () -> Void) -> Double {
        for _ in 0..<2 { body() }                      // warm-up: first-touch pages, lazy tables
        var best = Double.infinity
        var total = 0.0
        for _ in 0..<runs {
            let t0 = benchNowMs()
            body()
            let dt = benchNowMs() - t0
            best = min(best, dt)
            total += dt
        }
        let mean = total / Double(runs)
        print(String(format: "PERF %-40s min_ms=%8.3f mean_ms=%8.3f runs=%d",
                     (name as NSString).utf8String!, best, mean, runs))
        return best
    }

    private func note(_ name: String, _ value: String) {
        print("PERF-NOTE \(name) = \(value)")
    }

    // MARK: the fixed world (the demo model: same numbers on every machine)

    private let panes: [(cols: Int, rows: Int, label: String)] = [
        (137, 44, "137x44"), (100, 36, "100x36"), (60, 24, "60x24"),
    ]
    private func pane(_ cols: Int, _ rows: Int) -> PaneGeometry {
        PaneGeometry(cols: cols, rows: rows, cellW: 8, cellH: 16, dpr: 2, source: "perf")
    }

    /// What `Desk.wallPanels` builds, without the AppKit bridge: the layout and its pictures.
    private func plan(cols: Int, rows: Int, per: Int = 3, cardStart: Int = 0, scale: Double = 2)
        -> (WallLayout, [WallPanel]) {
        let model = WallSource.demoModel()
        var state = WallState()
        state.per = per
        state.cardStart = cardStart
        let display = model.displays[0]
        let aspect = Double(display.width) / Double(display.height)
        let layout = state.layout(cols: cols, rows: rows,
                                  displays: model.displays.count,
                                  windows: model.windows.count,
                                  stageAspect: aspect,
                                  cellAspect: pane(cols, rows).cellAspect)
        let cell = pane(cols, rows).pictureCell(scale: scale)
        let cards: [PanelSource?] = layout.cards.indices.map { slot in
            let index = layout.cardStart + slot
            guard model.windows.indices.contains(index) else { return nil }
            let window = model.windows[index]
            return PanelSource(kind: .window(window.windowID),
                               aspect: Double(window.bounds.width) / Double(window.bounds.height))
        }
        let panels = WallPanels.plan(layout: layout, cellW: cell.w, cellH: cell.h,
                                     stageSource: PanelSource(kind: .display(display.id), aspect: aspect),
                                     cardSources: cards)
        return (layout, panels)
    }

    // MARK: 1. layout + plan — the pure per-refresh maths

    func testLayoutAndPlanCost() {
        for p in panes {
            bestMs("layout.make @\(p.label)") {
                _ = WallLayout.make(paneCols: p.cols, paneRows: p.rows, displayCount: 3,
                                    windowCount: 7, per: 3, stageStart: 0, cardStart: 0)
            }
        }
        // `refreshWall` builds the layout for the clamp and `drawWall` builds it again — so this is
        // the cost that is paid *twice* per repaint, before any pixel is asked for.
        bestMs("layout.make x2 (the two per repaint) @137x44") {
            for _ in 0..<2 {
                _ = WallLayout.make(paneCols: 137, paneRows: 44, displayCount: 3, windowCount: 7,
                                    per: 3, stageStart: 0, cardStart: 0)
            }
        }
        bestMs("WallPanels.plan @137x44") {
            let (layout, _) = self.plan(cols: 137, rows: 44)
            let cell = self.pane(137, 44).pictureCell(scale: 2)
            let source = PanelSource(kind: .display(1), aspect: 1.6)
            let cards: [PanelSource?] = layout.cards.map {
                PanelSource(kind: .window(1), aspect: Double($0.cols) / Double($0.rows) * 1.6)
            }
            _ = WallPanels.plan(layout: layout, cellW: cell.w, cellH: cell.h,
                                stageSource: source, cardSources: cards)
        }
    }

    // MARK: 2. the text layer — build vs render, and the diff

    private func canvasDraw(_ canvas: WallCanvas, cols: Int, rows: Int, model: WallModel,
                            layout: WallLayout) -> Int {
        canvas.draw(cols: cols, rows: rows, model: model, layout: layout, focus: nil,
                    cellW: 8, cellH: 16).count
    }

    func testTextLayerBuildAndDiffCost() {
        let model = WallSource.demoModel()
        for p in panes {
            let (layout, _) = plan(cols: p.cols, rows: p.rows)
            var bytes = 0
            bestMs("WallCanvas.lines (build only) @\(p.label)") {
                let canvas = WallCanvas(symbols: .emoji)
                bytes = canvas.lines(cols: p.cols, rows: p.rows, model: model, layout: layout,
                                     focus: nil, cellW: 8, cellH: 16)
                    .reduce(0) { $0 + DisplayWidth.of($1) }
            }
            note("build cells @\(p.label)", "\(bytes) cells")
        }

        // A fresh canvas per run = a full repaint, which is what a resize, a re-entry and the first
        // paint all pay.
        for p in panes {
            let (layout, _) = plan(cols: p.cols, rows: p.rows)
            let canvas = WallCanvas(symbols: .emoji)
            bestMs("draw full repaint @\(p.label)") {
                canvas.invalidate()
                _ = canvasDraw(canvas, cols: p.cols, rows: p.rows, model: model, layout: layout)
            }
            let bytes = canvasDraw(canvas, cols: p.cols, rows: p.rows, model: model, layout: layout)
            note("full repaint bytes @\(p.label)", "\(bytes) B")
        }

        // The idle frame: same model, same pane. The contract says zero bytes; this measures both
        // the bytes and what the check costs.
        for p in panes {
            let (layout, _) = plan(cols: p.cols, rows: p.rows)
            let canvas = WallCanvas(symbols: .emoji)
            _ = canvasDraw(canvas, cols: p.cols, rows: p.rows, model: model, layout: layout)
            var bytes = -1
            bestMs("draw idle diff @\(p.label)") {
                bytes = canvasDraw(canvas, cols: p.cols, rows: p.rows, model: model, layout: layout)
            }
            note("idle diff bytes @\(p.label)", "\(bytes) B")
            XCTAssertEqual(bytes, 0, "an unchanged wall must emit nothing (invariant 4)")
        }

        // One changed character: a window title grows by one letter, i.e. exactly what the 1 s tick
        // does when a terminal's title changes.
        let p = panes[0]
        let (layout, _) = plan(cols: p.cols, rows: p.rows)
        let canvas = WallCanvas(symbols: .emoji)
        _ = canvasDraw(canvas, cols: p.cols, rows: p.rows, model: model, layout: layout)
        let w0 = model.windows[0]
        var changed = model
        changed.windows[0] = OrderedWindow(windowID: w0.windowID, pid: w0.pid, app: w0.app,
                                          title: (w0.title ?? "") + "!", bounds: w0.bounds)
        var bytes = -1
        bestMs("draw one-title-changed @\(p.label)") {
            bytes = canvasDraw(canvas, cols: p.cols, rows: p.rows, model: changed, layout: layout)
        }
        note("one-title-changed bytes", "\(bytes) B")

        // `--symbols ascii`: the fallback for a terminal that draws `▲ ▣ ⤢` two cells wide. Two
        // cell widths per glyph is a table lookup, so the mode should cost nothing — measured
        // because "the ascii path is slow" would be invisible in the golden dumps.
        for symbols in [WallSymbols.emoji, WallSymbols.ascii] {
            let canvas = WallCanvas(symbols: symbols)
            bestMs("draw full repaint \(symbols) @137x44") {
                canvas.invalidate()
                _ = canvasDraw(canvas, cols: 137, rows: 44, model: model, layout: layout)
            }
            let n = { () -> Int in
                canvas.invalidate()
                return self.canvasDraw(canvas, cols: 137, rows: 44, model: model, layout: layout)
            }()
            note("full repaint bytes \(symbols)", "\(n) B")
        }
    }

    // MARK: 3. the picture path — raster, compose, compress, placeholder grid

    /// The same size a stage picture is on a 137x44 pane at dpr 2 (see `plan`).
    private func stagePixels(_ panels: [WallPanel]) -> (w: Int, h: Int) {
        let stage = panels.first { $0.slot == 0 }
        return (stage?.fit.contentWidth ?? 0, stage?.fit.contentHeight ?? 0)
    }

    private func cgImage(width: Int, height: Int) -> CGImage? {
        // A real, non-uniform picture: the demo pattern has the contrast a screenshot has (edges,
        // text-like ticks, flat areas), which is what the compressor and the resampler see.
        let pixels = DemoPicture.render(width: width, height: height)
        let provider = CGDataProvider(data: Data(pixels) as CFData)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider!, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    func testPicturePathCost() {
        let (_, panels) = plan(cols: 137, rows: 44)
        let (sw, sh) = stagePixels(panels)
        note("stage picture px", "\(sw)x\(sh)")
        guard sw > 0, sh > 0, let source = cgImage(width: 1920, height: 1200) else {
            return XCTFail("no stage picture in the demo plan")
        }

        // 1. PanelRaster.rgb: CGContext draw (+ one upscale when SCK could not answer the size) and
        //    the RGBA→RGB vImage pass. This is paid per panel, per capture.
        var raster: (pixels: [UInt8], width: Int, height: Int)? = nil
        bestMs("PanelRaster.rgb 1920x1200 -> \(sw)x\(sh)") {
            raster = PanelRaster.rgb(source, width: sw, height: sh)
        }
        guard let raster else { return XCTFail("raster failed") }

        // 2. PanelImage.compose: the corner rounding, one pass over the picture's pixels. It runs on
        //    a full RGBA canvas of the picture's own size, so the stage pays 4 bytes per pixel.
        bestMs("PanelImage.compose \(raster.width)x\(raster.height) r=16") {
            _ = PanelImage.compose(content: raster.pixels, width: raster.width, height: raster.height,
                                   panelWidth: raster.width, panelHeight: raster.height,
                                   originX: 0, originY: 0,
                                   cornerRadius: PanelImage.cornerRadius(width: raster.width,
                                                                        height: raster.height))
        }

        let canvas = PanelImage.compose(content: raster.pixels, width: raster.width,
                                        height: raster.height,
                                        panelWidth: raster.width, panelHeight: raster.height,
                                        originX: 0, originY: 0,
                                        cornerRadius: PanelImage.cornerRadius(width: raster.width,
                                                                             height: raster.height))

        // 3. zlib at the level the wall actually uses (3).
        var payload = 0
        bestMs("zlibCompress stage rgba l=3") {
            payload = zlibCompress(canvas, level: 3)?.count ?? 0
        }
        note("stage payload", "\(payload) B of \(canvas.count) B input "
             + String(format: "(%.1f%%)", 100.0 * Double(payload) / Double(max(1, canvas.count))))

        // 4. The placeholder grid + transmit, i.e. everything the wall puts on the wire per panel.
        let writer = ScreenWriter()
        writer.discardOutput = true
        writer.beginSession()
        var wire = 0
        bestMs("emitPanelAsPlaceholder stage") {
            writer.beginFrame()
            writer.emitPanelAsPlaceholder(id: 5000, placementID: 9000,
                                          row: panels[0].rect.row, col: panels[0].rect.col,
                                          cols: panels[0].rect.cols, rows: panels[0].rect.rows,
                                          pixels: canvas, width: raster.width, height: raster.height,
                                          level: 3, paneCols: 137, paneRows: 44,
                                          format: .rgba, sync: false)
            writer.endFrame()
        }
        wire = writer.lastWireBytes
        note("stage panel wire bytes", "\(wire) B for \(panels[0].rect.cols)x\(panels[0].rect.rows) cells")
        note("stage panel cells", "\(panels[0].rect.cols * panels[0].rect.rows) placeholder cells")

        // 5. The whole wall's pictures in one frame: the stage plus the page's cards. This is what a
        //    single click costs today (`paintWall` re-emits every panel, not only the changed ones).
        bestMs("emitPanelAsPlaceholder whole wall (4 panels)") {
            writer.beginFrame()
            for panel in panels {
                let px = DemoPicture.render(width: panel.fit.contentWidth,
                                            height: panel.fit.contentHeight)
                writer.emitPanelAsPlaceholder(id: panel.imageID, placementID: panel.placementID,
                                              row: panel.rect.row, col: panel.rect.col,
                                              cols: panel.rect.cols, rows: panel.rect.rows,
                                              pixels: px, width: panel.fit.contentWidth,
                                              height: panel.fit.contentHeight, level: 3,
                                              paneCols: 137, paneRows: 44,
                                              format: .rgba, sync: false)
            }
            writer.endFrame()
        }
    }

    /// The placeholder grid alone: `cols * rows` invisible U+10EEEE characters per panel, appended
    /// one `String` at a time. What the current implementation costs, and what one pre-built row
    /// buffer would cost, on the same machine and in the same process.
    func testPlaceholderGridTextCost() {
        let (_, panels) = plan(cols: 137, rows: 44)
        let cells = panels.reduce(0) { $0 + $1.rect.cols * $1.rect.rows }
        note("placeholder cells per repaint", "\(cells)")

        // Current shape (Render.append per cell): the same escapes the product emits, built here so
        // the measurement does not need the compressor in the loop.
        bestMs("grid text: per-cell append (current shape)") {
            var out = [UInt8]()
            out.reserveCapacity(1 << 16)
            for panel in panels {
                for line in 0..<panel.rect.rows {
                    out.append(contentsOf: Array("\u{1B}[\(panel.rect.row + line);\(panel.rect.col)H".utf8))
                    out.append(contentsOf: Array("\u{1B}[38;2;19;136;80m".utf8))
                    for _ in 0..<panel.rect.cols {
                        out.append(contentsOf: Array("\u{10EEEE}".utf8))
                    }
                    out.append(contentsOf: Array("\u{1B}[39m".utf8))
                }
            }
        }

        // One pre-built row, appended once: the same bytes, one allocation per row instead of one
        // per cell.
        let glyph = Array("\u{10EEEE}".utf8)
        var rowBuffer: [UInt8] = []
        rowBuffer.reserveCapacity(137 * glyph.count)
        bestMs("grid text: one pre-built row buffer") {
            var out = [UInt8]()
            out.reserveCapacity(1 << 16)
            for panel in panels {
                rowBuffer.removeAll(keepingCapacity: true)
                for _ in 0..<panel.rect.cols { rowBuffer.append(contentsOf: glyph) }
                for line in 0..<panel.rect.rows {
                    out.append(contentsOf: Array("\u{1B}[\(panel.rect.row + line);\(panel.rect.col)H".utf8))
                    out.append(contentsOf: Array("\u{1B}[38;2;19;136;80m".utf8))
                    out.append(contentsOf: rowBuffer)
                    out.append(contentsOf: Array("\u{1B}[39m".utf8))
                }
            }
        }
    }

    /// A *page step* (one click on the bar's `▼`, or one wheel notch) moves `cardStart` by `per`.
    /// The layout and every card's picture change, the stage does not — and today the stage is
    /// captured and re-encoded anyway. This measures what that costs, minus the capture itself.
    func testPageStepReEncodeCost() {
        let (layoutA, panelsA) = plan(cols: 137, rows: 44, cardStart: 0)
        let (layoutB, panelsB) = plan(cols: 137, rows: 44, cardStart: 3)
        note("page A cards", panelsA.map { "\($0.slot):\($0.rect.cols)x\($0.rect.rows)" }
            .joined(separator: " "))
        note("page B cards", panelsB.map { "\($0.slot):\($0.rect.cols)x\($0.rect.rows)" }
            .joined(separator: " "))
        XCTAssertEqual(layoutA.stage, layoutB.stage, "the stage band does not move on a page step")
        // The stage panel is the same rectangle *and* the same source: a page step cannot change it.
        let stageA = panelsA.first { $0.slot == 0 }
        let stageB = panelsB.first { $0.slot == 0 }
        XCTAssertEqual(stageA?.rect, stageB?.rect)
        XCTAssertEqual(stageA?.source, stageB?.source)
        note("stage unchanged on a page step", "yes (source + rect equal)")

        let writer = ScreenWriter()
        writer.discardOutput = true
        writer.beginSession()
        bestMs("re-emit every panel for one page step") {
            writer.beginFrame()
            for panel in panelsB {
                let px = DemoPicture.render(width: panel.fit.contentWidth,
                                            height: panel.fit.contentHeight)
                writer.emitPanelAsPlaceholder(id: panel.imageID, placementID: panel.placementID,
                                              row: panel.rect.row, col: panel.rect.col,
                                              cols: panel.rect.cols, rows: panel.rect.rows,
                                              pixels: px, width: panel.fit.contentWidth,
                                              height: panel.fit.contentHeight, level: 3,
                                              paneCols: 137, paneRows: 44,
                                              format: .rgba, sync: false)
            }
            writer.endFrame()
        }
    }

    // MARK: 4. retained memory

    func testRetainedPictureMemory() {
        let (_, panels) = plan(cols: 137, rows: 44)
        var total = 0
        for panel in panels {
            let rgba = panel.fit.contentWidth * panel.fit.contentHeight * 4
            total += rgba
            print("PERF-NOTE panel \(panel.slot) \(panel.rect.cols)x\(panel.rect.rows) cells "
                  + "\(panel.fit.contentWidth)x\(panel.fit.contentHeight) px "
                  + "rgba=\(rgba / 1024) KiB")
        }
        note("wall pictures per frame (rgba)", "\(total / 1024) KiB")
        // Two frames are alive at once during a repaint: the one being encoded and the one on
        // screen (`pictures` is captured by the paint closure).
        note("peak while repainting (2 frames)", "\(2 * total / 1024) KiB")
    }
}
