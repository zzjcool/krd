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
        // The panel **is** the picture: `rect` is the fitted rectangle inside the layout's band
        // (mask rect == picture rect, so the caption hangs under the picture and a failed capture
        // never reflows anything), and the pixels are the picture's own size - no canvas, no bars.
        // The band is only what the fit had to work with, which is why every rect has to stay inside
        // the rectangle the text layer left empty.
        XCTAssertEqual(panels[0].rect, panels[0].fit.cellRect)
        XCTAssertEqual(panels[1].rect, panels[1].fit.cellRect)
        for (panel, band) in zip(panels, [layout.stage] + layout.cards) {
            XCTAssertGreaterThanOrEqual(panel.rect.col, band.col)
            XCTAssertGreaterThanOrEqual(panel.rect.row, band.row)
            XCTAssertLessThanOrEqual(panel.rect.maxCol, band.maxCol)
            XCTAssertLessThanOrEqual(panel.rect.maxRow, band.maxRow)
        }
        XCTAssertEqual(panels[0].pixelWidth, panels[0].fit.contentWidth)
        XCTAssertEqual(panels[0].pixelHeight, panels[0].fit.contentHeight)
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

    /// A panel's canvas is the picture and nothing else, and the picture never leaves its band.
    ///
    /// Both halves were a visible bug: a panel-sized canvas padded the picture with *transparent*
    /// bars, which Rex paints black - "the display is smaller than its frame, with a black ring".
    /// Cells outside the picture are now unpainted, so the patch of wall behind it shows.
    func testThePanelIsExactlyThePictureAndStaysInItsBand() {
        for aspect in [0.4, 1.0, 1.6, 2.4, 3.0] {
            let layout = self.layout()
            let panels = WallPanels.plan(layout: layout, cellW: 17, cellH: 33,
                                        stageSource: PanelSource(kind: .display(1), aspect: aspect),
                                        cardSources: [])
            let panel = panels[0]
            XCTAssertEqual(panel.rect, panel.fit.cellRect, "aspect \(aspect)")
            XCTAssertEqual(panel.pixelWidth, panel.fit.contentWidth, "aspect \(aspect)")
            XCTAssertEqual(panel.pixelHeight, panel.fit.contentHeight, "aspect \(aspect)")
            // No bars to pad with: the fit's offsets are the panel's origin by construction.
            XCTAssertEqual(panel.fit.originX, 0, "aspect \(aspect)")
            XCTAssertEqual(panel.fit.originY, 0, "aspect \(aspect)")
            XCTAssertGreaterThanOrEqual(panel.rect.col, layout.stage.col, "aspect \(aspect)")
            XCTAssertGreaterThanOrEqual(panel.rect.row, layout.stage.row, "aspect \(aspect)")
            XCTAssertLessThanOrEqual(panel.rect.maxCol, layout.stage.maxCol, "aspect \(aspect)")
            XCTAssertLessThanOrEqual(panel.rect.maxRow, layout.stage.maxRow, "aspect \(aspect)")
            let drawn = Double(panel.pixelWidth) / Double(panel.pixelHeight)
            XCTAssertEqual(drawn, aspect, accuracy: 0.05, "aspect \(aspect): the picture changed shape")
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
        // A shorter picture is centred in its band, not pinned to the top. The *panel* is the
        // picture, so the centring lives in the rect the picture was placed at, not in an origin
        // offset: the cells the picture does not use are left unpainted.
        for (panel, band) in zip(cardsOut, layout.cards) {
            XCTAssertEqual(panel.rect, panel.fit.cellRect)
            XCTAssertEqual(panel.rect.row, band.row + (band.rows - panel.rect.rows) / 2)
            XCTAssertEqual(panel.rect.col, band.col + (band.cols - panel.rect.cols) / 2)
            XCTAssertLessThanOrEqual(panel.rect.rows, band.rows)
            XCTAssertLessThanOrEqual(panel.rect.cols, band.cols)
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
            // One cell is the slack: the picture is sized by the cells the layout gave it, so an
            // aspect is right to within half a cell on each axis (a 44x14 card at 17x33 px cells is
            // 748x462 -> 1.6%). Tighter than that would mean the pixels disagree with the layout,
            // which is the bug this replaced.
            let cellW = 17.0, cellH = 33.0
            let slack = max(cellW / Double(panel.fit.contentWidth),
                            cellH / Double(panel.fit.contentHeight))
            XCTAssertEqual(aspect, cards[index].aspect, accuracy: cards[index].aspect * slack * 1.2,
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
        // Uncapped: exactly the rectangle one fit of that aspect gives, i.e. it uses as much of the
        // band as its shape allows. Only the offsets differ: the panel *is* that rectangle, so its
        // origin is 0,0 and the band's padding is not part of it (see WallPanels.make).
        let fitted = PanelImage.fit(aspect: 1.62, in: layout.cards[0], cellW: 17, cellH: 33)
        let panel = panels[0]
        XCTAssertEqual(panel.rect, fitted.cellRect)
        XCTAssertEqual(panel.pixelWidth, fitted.contentWidth)
        XCTAssertEqual(panel.pixelHeight, fitted.contentHeight)
        XCTAssertEqual(panel.fit.originX, 0)
        XCTAssertEqual(panel.fit.originY, 0)
    }

    func testASlotWithNoSourceDoesNotDragTheRowDown() {
        let layout = self.layout()
        let cards: [PanelSource?] = [PanelSource(kind: .window(11), aspect: 1.62), nil,
                                     PanelSource(kind: .window(13), aspect: 1.62)]
        let panels = WallPanels.plan(layout: layout, cellW: 17, cellH: 33,
                                    stageSource: nil, cardSources: cards)
        XCTAssertEqual(panels.count, 2)
        for panel in panels { XCTAssertEqual(panel.fit.contentHeight, 330) }   // 10 rows
    }
}
