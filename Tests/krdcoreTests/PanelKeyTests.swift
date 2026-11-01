import XCTest
import krdcore

/// `PanelKey` (issue #100): what makes two pictures "the same picture".
///
/// The rule the wall's cache runs on is one equality, so the whole test is which inputs move the
/// key and which must not. Pure: panels come from `WallPanels.plan`, the same call the wall makes,
/// so nothing here needs a window server, a terminal or a desktop.
///
/// The interesting half is what is **not** in the key: a picture's slot and its cell rectangle are
/// *where* it goes, and a page step changes exactly those (and nothing else) for a window that stays
/// on the page. A key that carried placement would re-photograph the whole page on every `▼`.
final class PanelKeyTests: XCTestCase {
    private let cellW = 8.0
    private let cellH = 16.0

    private func layout(cards: Int, per: Int = 2) -> WallLayout {
        WallLayout.make(paneCols: 80, paneRows: 24, displayCount: 1,
                        windowCount: max(1, cards), per: per, stageStart: 0, cardStart: 0,
                        stageAspect: 1.6, cellAspect: 2)
    }

    private func display(_ id: UInt32 = 1, _ width: Int = 2560,
                         _ height: Int = 1600) -> PanelSource {
        PanelSource(kind: .display(id), aspect: Double(width) / Double(height),
                    stamp: PanelSourceStamp(kind: .display(width: width, height: height)))
    }

    private func window(_ id: UInt32 = 42, x: Double = 10, y: Double = 20,
                        width: Double = 1440, height: Double = 900,
                        title: String? = "Mail") -> PanelSource {
        PanelSource(kind: .window(id), aspect: width / height,
                    stamp: PanelSourceStamp(kind: .window(x: x, y: y, width: width, height: height,
                                                          title: title)))
    }

    private func plan(_ layout: WallLayout, stage: PanelSource?,
                      cards: [PanelSource?]) -> [WallPanel] {
        WallPanels.plan(layout: layout, cellW: cellW, cellH: cellH,
                        stageSource: stage, cardSources: cards)
    }

    /// The one card of a one-card plan, which is what most of these are about.
    private func cardPanel(_ source: PanelSource) throws -> WallPanel {
        let panels = plan(layout(cards: 1, per: 1), stage: nil, cards: [source])
        return try XCTUnwrap(panels.first { $0.slot == 1 },
                             "the layout must give this pane one card")
    }

    private func key(_ panel: WallPanel) -> PanelKey { panel.key(quality: 70, rounded: true) }

    // MARK: the same panel, twice

    func testTheSamePanelTwiceHasTheSameKey() {
        let layout = layout(cards: 2)
        let first = plan(layout, stage: display(), cards: [window(), window(43)])
        let second = plan(layout, stage: display(), cards: [window(), window(43)])
        XCTAssertEqual(first.count, 3, "a stage and two cards")
        XCTAssertEqual(first.map(key), second.map(key),
                       "the same world must produce the same keys, panel for panel")
    }

    // MARK: what makes a source a different picture

    func testAWindowThatMovedIsADifferentPicture() throws {
        let before = try cardPanel(window(x: 10, y: 20))
        let after = try cardPanel(window(x: 11, y: 20))
        XCTAssertNotEqual(key(before), key(after), "a window that moved shows something else")
        XCTAssertEqual(key(before).contentWidth, key(after).contentWidth,
                       "same size, so only the stamp can tell them apart")
    }

    func testAWindowThatResizedIsADifferentPicture() throws {
        XCTAssertNotEqual(key(try cardPanel(window(width: 1440, height: 900))),
                          key(try cardPanel(window(width: 1440, height: 901))))
    }

    func testARetitledWindowIsADifferentPicture() throws {
        XCTAssertNotEqual(key(try cardPanel(window(title: "Mail"))),
                          key(try cardPanel(window(title: "Inbox"))))
        XCTAssertNotEqual(key(try cardPanel(window(title: "Mail"))),
                          key(try cardPanel(window(title: nil))),
                          "a window the list has no name for is not the same as a titled one")
    }

    func testADisplayResolutionChangeIsADifferentPicture() throws {
        let layout = layout(cards: 1)
        let before = try XCTUnwrap(plan(layout, stage: display(1, 2560, 1600), cards: []).first)
        let after = try XCTUnwrap(plan(layout, stage: display(1, 1920, 1200), cards: []).first)
        XCTAssertNotEqual(key(before), key(after))
    }

    // MARK: what placement must not change

    func testACardThatMovedToAnotherSlotKeepsItsKey() throws {
        // Two cards from the *same* source: the plan puts them side by side, so they are the same
        // window photographed at the same size in two different rectangles. That is a page step's
        // stage - same picture, new place - and the key must not notice.
        let panels = plan(layout(cards: 2, per: 2), stage: nil, cards: [window(), window()])
        XCTAssertEqual(panels.count, 2, "this pane must fit two cards")
        let left = panels[0], right = panels[1]
        XCTAssertEqual(left.slot, 1)
        XCTAssertEqual(right.slot, 2)
        XCTAssertNotEqual(left.rect, right.rect, "the two cards are at different cells")
        XCTAssertEqual(left.fit.contentWidth, right.fit.contentWidth)
        XCTAssertEqual(left.fit.contentHeight, right.fit.contentHeight)
        XCTAssertEqual(key(left), key(right),
                       "slot and rect are where a picture goes, not what it is")
        XCTAssertNotEqual(left.imageID, right.imageID, "the *placement* still differs, by slot")
    }

    // MARK: the two process-wide knobs

    func testTheQualityRungIsPartOfTheKey() throws {
        let panel = try cardPanel(window())
        XCTAssertNotEqual(panel.key(quality: 70, rounded: true),
                          panel.key(quality: 80, rounded: true),
                          "a different rung quantises the payload differently")
        XCTAssertEqual(panel.key(quality: 70, rounded: true),
                       panel.key(quality: 70, rounded: true))
    }

    func testTheCornerShapeIsPartOfTheKey() throws {
        let panel = try cardPanel(window())
        XCTAssertNotEqual(panel.key(quality: 70, rounded: true),
                          panel.key(quality: 70, rounded: false),
                          "--square changes the corner alpha, so the pixels differ")
    }

    // MARK: a display is not a window

    func testTheStageIsNotTheSamePictureAsAWindow() throws {
        let panels = plan(layout(cards: 1), stage: display(42, 1440, 900), cards: [])
        let stage = try XCTUnwrap(panels.first)
        XCTAssertEqual(stage.source, .display(42))
        let card = try cardPanel(window(42, width: 1440, height: 900))
        XCTAssertEqual(card.source, .window(42))
        XCTAssertNotEqual(key(stage), key(card),
                          "the same numbers on a display and on a window are two pictures")
    }

    // MARK: the log's half of the identity

    func testTheStampLabelSaysWhatMatched() {
        XCTAssertEqual(PanelSourceStamp(kind: .display(width: 2560, height: 1600)).label,
                       "display 2560x1600")
        XCTAssertEqual(PanelSourceStamp(kind: .window(x: 10, y: 20, width: 1440, height: 900,
                                                      title: "Mail")).label,
                       "window 1440x900 @ 10,20 title=\"Mail\"")
        XCTAssertEqual(PanelSourceStamp(kind: .window(x: 0, y: 0, width: 800, height: 600,
                                                      title: nil)).label,
                       "window 800x600 @ 0,0", "a window with no name prints as a rectangle")
    }
}
