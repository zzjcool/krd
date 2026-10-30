import XCTest
import krdcore

/// The plan the wall photographs: which slots get a picture, of what, and how big.
///
/// The interesting cases are the ones a reader cannot see in a working screenshot — a display with
/// no id, a window whose size is unknown, a slot past the end of the page — because those are the
/// ones that would otherwise ask the capture for a 0x0 picture at 1 s intervals.
final class WallPanelsTests: XCTestCase {
    private func layout(displays: Int = 3, windows: Int = 7, cardStart: Int = 0) -> WallLayout {
        WallLayout.make(paneCols: 137, paneRows: 44, displayCount: displays,
                        windowCount: windows, per: 3, stageStart: 0, cardStart: cardStart)
    }

    func testTheStageIsSlotZeroAndTheCardsFollow() {
        let layout = self.layout()
        let stage = PanelSource(kind: .display(1), aspect: 1.6)
        let cards = [PanelSource(kind: .window(11), aspect: 1.5),
                     PanelSource(kind: .window(12), aspect: 1.0),
                     PanelSource(kind: .window(13), aspect: 2.0)]
        let panels = WallPanels.plan(layout: layout, cellW: 17, cellH: 33,
                                    stageSource: stage, cardSources: cards)
        XCTAssertEqual(panels.count, 4)
        XCTAssertEqual(panels.map(\.slot), [0, 1, 2, 3])
        XCTAssertEqual(panels[0].source, .display(1))
        XCTAssertEqual(panels[2].source, .window(12))
        // The stage is the whole band, the cards are one card wide: the plan uses the layout's
        // rects, so a picture can never be placed somewhere the text layer did not leave empty.
        XCTAssertEqual(panels[0].rect, layout.stage)
        XCTAssertEqual(panels[1].rect, layout.cards[0])
        XCTAssertEqual(panels[0].pixelWidth, layout.stage.cols * 17)
        XCTAssertEqual(panels[0].pixelHeight, layout.stage.rows * 33)
    }

    func testAPanelGetsItsOwnIDsAndTheyDoNotMoveBetweenFrames() {
        let stage = PanelSource(kind: .display(1), aspect: 1.6)
        let first = WallPanels.plan(layout: layout(), cellW: 17, cellH: 33,
                                    stageSource: stage, cardSources: [])
        let second = WallPanels.plan(layout: layout(displays: 2, windows: 9), cellW: 17, cellH: 33,
                                     stageSource: stage, cardSources: [])
        XCTAssertEqual(first[0].imageID, second[0].imageID)
        XCTAssertEqual(first[0].placementID, second[0].placementID)
        XCTAssertNotEqual(first[0].imageID, 100)        // not one of the tile ids
        XCTAssertNotEqual(first[0].placementID, first[0].imageID)
    }

    func testAnUnknownOrEmptySourceSimplyHasNoPanel() {
        let layout = self.layout()
        let cards: [PanelSource?] = [nil,
                                     PanelSource(kind: .window(2), aspect: 0),
                                     PanelSource(kind: .window(3), aspect: 1.5)]
        let panels = WallPanels.plan(layout: layout, cellW: 17, cellH: 33,
                                    stageSource: PanelSource(kind: .display(1), aspect: .nan),
                                    cardSources: cards)
        // No stage (NaN aspect), no slots 1 and 2 (nil / 0 aspect), only the third card.
        XCTAssertEqual(panels.map(\.slot), [3])
        XCTAssertEqual(panels[0].source, .window(3))
    }

    func testFewerSourcesThanCardsLeavesTheRestToThePlaceholder() {
        let panels = WallPanels.plan(layout: layout(), cellW: 17, cellH: 33,
                                    stageSource: PanelSource(kind: .display(1), aspect: 1.6),
                                    cardSources: [PanelSource(kind: .window(7), aspect: 1.2)])
        XCTAssertEqual(panels.map(\.slot), [0, 1])
    }

    func testTheContentIsAlwaysInsideThePanel() {
        for aspect in [0.4, 1.0, 1.6, 2.4, 3.0] {
            let panels = WallPanels.plan(layout: layout(), cellW: 17, cellH: 33,
                                        stageSource: PanelSource(kind: .display(1), aspect: aspect),
                                        cardSources: [])
            let panel = panels[0]
            XCTAssertLessThanOrEqual(panel.fit.contentWidth, panel.pixelWidth, "aspect \(aspect)")
            XCTAssertLessThanOrEqual(panel.fit.contentHeight, panel.pixelHeight, "aspect \(aspect)")
            XCTAssertGreaterThanOrEqual(panel.fit.originX, 0, "aspect \(aspect)")
            XCTAssertGreaterThanOrEqual(panel.fit.originY, 0, "aspect \(aspect)")
            XCTAssertEqual(panel.fit.originX + panel.fit.contentWidth <= panel.pixelWidth, true)
            XCTAssertEqual(panel.fit.originY + panel.fit.contentHeight <= panel.pixelHeight, true)
        }
    }
}
