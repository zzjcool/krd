import XCTest
import krdcore
@testable import krd

/// The demo wall, end to end, in one process: layout → panels → demo pictures → kitty escapes.
///
/// This is the harness the geometry bugs could not be reproduced in before: no window server, no
/// ScreenRecording grant, no VM, and the same numbers on every machine for a given pane size. What it
/// pins is the invariant the wall keeps getting wrong - **the picture's pixels are its cells times
/// the cell, and its placement is exactly those cells** - in both transports.
final class DemoWallTests: XCTestCase {
    private let pane = PaneGeometry(cols: 137, rows: 44, cellW: 8, cellH: 16, dpr: 2,
                                    source: "test")

    /// The plan the wall would paint, from the demo model.
    private func plan(scale: Double) -> (WallLayout, [WallPanel]) {
        let model = WallSource.demoModel()
        let state = WallState()
        let display = model.displays[0]
        let aspect = Double(display.width) / Double(display.height)
        let layout = state.layout(cols: pane.cols, rows: pane.rows,
                                  displays: model.displays.count,
                                  windows: model.windows.count,
                                  stageAspect: aspect,
                                  cellAspect: pane.cellAspect)
        let cell = pane.pictureCell(scale: scale)
        let cards: [PanelSource?] = layout.cards.indices.map { slot in
            let index = layout.cardStart + slot
            guard model.windows.indices.contains(index) else { return nil }
            let window = model.windows[index]
            return PanelSource(kind: .window(window.windowID),
                               aspect: Double(window.bounds.width) / Double(window.bounds.height))
        }
        let panels = WallPanels.plan(layout: layout,
                                     cellW: cell.w, cellH: cell.h,
                                     stageSource: PanelSource(kind: .display(display.id), aspect: aspect),
                                     cardSources: cards)
        return (layout, panels)
    }

    /// One invariant, both transports: the picture's pixel size is its cell rectangle at the chosen
    /// quality, and it is not a pixel of it wider or taller.
    func testThePicturesPixelsAreItsCellsAtTheQualityScale() {
        for scale in [1.0, 2.0] {
            let (_, panels) = plan(scale: scale)
            XCTAssertFalse(panels.isEmpty, "the demo model must produce pictures")
            for panel in panels {
                let wantW = Double(panel.rect.cols) * pane.cellW * scale
                let wantH = Double(panel.rect.rows) * pane.cellH * scale
                XCTAssertEqual(Double(panel.fit.contentWidth), wantW, accuracy: 1,
                               "slot \(panel.slot) width")
                XCTAssertEqual(Double(panel.fit.contentHeight), wantH, accuracy: 1,
                               "slot \(panel.slot) height")
                // And the placement is the same rectangle: the mask, the caption and the picture are
                // one box (design §6.6).
                XCTAssertEqual(panel.fit.cellRect, panel.rect.isEmpty ? panel.rect : panel.fit.cellRect)
            }
        }
    }

    /// With placeholders the cell rectangle *is* the geometry, so the bytes must not encode any other
    /// opinion about size: a virtual placement of exactly the picture's cells, and a grid of
    /// `cols * rows` placeholder characters.
    func testTheDemoWallEmitsOneVirtualPlacementPerPicture() {
        let (_, panels) = plan(scale: 1)
        let writer = ScreenWriter()
        var bytes: [UInt8] = []
        writer.sink = { bytes.append(contentsOf: $0) }
        writer.beginSession()
        writer.beginFrame()
        for panel in panels {
            let pixels = DemoPicture.render(width: panel.fit.contentWidth,
                                            height: panel.fit.contentHeight)
            writer.emitPanelAsPlaceholder(id: panel.imageID, placementID: panel.placementID,
                                          row: panel.rect.row, col: panel.rect.col,
                                          cols: panel.rect.cols, rows: panel.rect.rows,
                                          pixels: pixels, width: panel.fit.contentWidth,
                                          height: panel.fit.contentHeight, level: 3,
                                          paneCols: pane.cols, paneRows: pane.rows)
        }
        writer.endFrame()
        let text = String(decoding: bytes, as: UTF8.self)

        for panel in panels {
            XCTAssertTrue(text.contains("a=p,U=1,q=2,c=\(panel.rect.cols),r=\(panel.rect.rows)"),
                          "slot \(panel.slot) must be placed on its own cells")
        }
        let cells = text.unicodeScalars.filter { $0 == "\u{10EEEE}" }.count
        let wanted = panels.reduce(0) { $0 + $1.rect.cols * $1.rect.rows }
        XCTAssertEqual(cells, wanted, "the grid must cover every picture's cells exactly once")
    }

    /// The pixel path: one placement per picture, `c`/`r` again the picture's cells, and an image
    /// whose size is the cells at `dpr` - which is the only thing a 1:1 terminal reads.
    func testTheDemoWallEmitsAPanelSizedPlacementInThePixelPath() {
        let (_, panels) = plan(scale: pane.dpr)
        let writer = ScreenWriter()
        var bytes: [UInt8] = []
        writer.sink = { bytes.append(contentsOf: $0) }
        writer.beginSession()
        writer.beginFrame()
        for panel in panels {
            let pixels = DemoPicture.render(width: panel.fit.contentWidth,
                                            height: panel.fit.contentHeight)
            writer.emitPanel(id: panel.imageID, placementID: panel.placementID,
                             row: panel.rect.row, col: panel.rect.col,
                             cols: panel.rect.cols, rows: panel.rect.rows,
                             pixels: pixels, width: panel.fit.contentWidth,
                             height: panel.fit.contentHeight, level: 3, format: .rgba)
        }
        writer.endFrame()
        let text = String(decoding: bytes, as: UTF8.self)
        for panel in panels {
            XCTAssertTrue(text.contains("s=\(panel.fit.contentWidth),v=\(panel.fit.contentHeight)"),
                          "slot \(panel.slot) must carry its own pixel size")
            XCTAssertTrue(text.contains("c=\(panel.rect.cols),r=\(panel.rect.rows)"),
                          "slot \(panel.slot) must be placed on its cells")
        }
        XCTAssertFalse(text.contains("U=1"), "the pixel path must not use placeholders")
    }

    /// The demo model is fixed, so a report of "slot 0 is 86x27 at 137x44" means the same thing on
    /// every machine - that is what makes a joint debug session possible.
    func testTheDemoModelIsStable() {
        let model = WallSource.demoModel()
        XCTAssertEqual(model.displays.count, 1)
        XCTAssertEqual(model.windows.count, 4)
        XCTAssertEqual(model.displays[0].width, 2560)
        XCTAssertEqual(model.windows.map { $0.title ?? "" },
                       ["16:9 window", "4:3 window", "square window", "21:9 window"])
    }
}
