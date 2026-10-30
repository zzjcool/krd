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

/// Review asked for one thing the row could not give on its own: the three pictures must reach the
/// same height. Fit is per picture, so a 16:9 window is shorter than a square one, and the row's top
/// and bottom edges disagree. The tallest height every picture can reach without cutting or
/// stretching is the widest window's.
final class WallPanelRowHeightTests: XCTestCase {
    private func layout(per: Int = 3, windows: Int = 7) -> WallLayout {
        WallLayout.make(paneCols: 137, paneRows: 44, displayCount: 2, windowCount: windows,
                        per: per, stageStart: 0, cardStart: 0)
    }

    func testEveryCardInTheRowIsTheSameHeight() {
        let layout = self.layout()
        let cards = [PanelSource(kind: .window(11), aspect: 1.62),
                     PanelSource(kind: .window(12), aspect: 1.03),      // nearly square
                     PanelSource(kind: .window(13), aspect: 1.78)]
        let panels = WallPanels.plan(layout: layout, cellW: 17, cellH: 33,
                                    stageSource: PanelSource(kind: .display(1), aspect: 1.6),
                                    cardSources: cards)
        let cardsOut = Array(panels.dropFirst())
        XCTAssertEqual(cardsOut.count, 3)
        let heights = Set(cardsOut.map(\.fit.contentHeight))
        XCTAssertEqual(heights.count, 1, "one height for the row: \(heights)")
        // The widest window is the one that decides it, and it keeps the card's full width.
        let widest = cardsOut.max { $0.fit.contentWidth * 1000 / $0.fit.contentHeight
                                     < $1.fit.contentWidth * 1000 / $1.fit.contentHeight }!
        XCTAssertEqual(widest.fit.contentWidth, widest.pixelWidth, "the wide picture is not narrowed")
        XCTAssertEqual(widest.fit.contentHeight, cardsOut[0].fit.contentHeight)
        // A shorter picture is centred, not pinned to the top, so the cards look like one row.
        for panel in cardsOut {
            XCTAssertEqual(panel.fit.originY, (panel.pixelHeight - panel.fit.contentHeight) / 2)
            XCTAssertEqual(panel.fit.originX, (panel.pixelWidth - panel.fit.contentWidth) / 2)
            XCTAssertLessThanOrEqual(panel.fit.contentHeight, panel.pixelHeight)
            XCTAssertLessThanOrEqual(panel.fit.contentWidth, panel.pixelWidth)
        }
    }

    func testNothingIsCutOrStretched() {
        let layout = self.layout()
        let cards = [PanelSource(kind: .window(11), aspect: 1.03),
                     PanelSource(kind: .window(12), aspect: 2.4),
                     PanelSource(kind: .window(13), aspect: 1.33)]
        let panels = WallPanels.plan(layout: layout, cellW: 17, cellH: 33,
                                    stageSource: nil, cardSources: cards)
        for (index, panel) in panels.enumerated() {
            let aspect = Double(panel.fit.contentWidth) / Double(panel.fit.contentHeight)
            // Rounding to whole pixels is the only slack allowed.
            XCTAssertEqual(aspect, cards[index].aspect, accuracy: 0.01,
                           "card \(index) changed shape")
        }
    }

    func testASingleCardKeepsTheWholeRect() {
        let layout = self.layout(per: 1, windows: 1)
        let cards = [PanelSource(kind: .window(11), aspect: 1.62)]
        XCTAssertNil(WallPanels.sharedCardHeight(layout: layout, cardSources: cards,
                                                cellW: 17, cellH: 33),
                     "a card with no neighbour has nothing to line up with")
        let panels = WallPanels.plan(layout: layout, cellW: 17, cellH: 33,
                                    stageSource: nil, cardSources: cards)
        // Uncapped: exactly what one fit of that aspect gives, i.e. it uses as much of the rect as
        // its shape allows.
        XCTAssertEqual(panels[0].fit,
                       PanelImage.fit(aspect: 1.62, in: layout.cards[0], cellW: 17, cellH: 33))
    }

    func testASlotWithNoSourceDoesNotDragTheRowDown() {
        let layout = self.layout()
        let cards: [PanelSource?] = [PanelSource(kind: .window(11), aspect: 1.62), nil,
                                     PanelSource(kind: .window(13), aspect: 1.62)]
        let panels = WallPanels.plan(layout: layout, cellW: 17, cellH: 33,
                                    stageSource: nil, cardSources: cards)
        XCTAssertEqual(panels.count, 2)
        for panel in panels { XCTAssertEqual(panel.fit.contentHeight, 429) }   // 13 rows
    }
}
