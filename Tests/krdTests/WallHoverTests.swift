import XCTest
@testable import krd
import krdcore

/// The wall's pointer: what is under it, and whether it is down.
///
/// Until this existed a mouse *move* was thrown away (`Input.handleMouse` only ever called
/// `onChromeClick` for a press), so nothing on the wall could answer the pointer at all: a reader
/// had to click a card to find out whether the thing they were aiming at was a card. That is the
/// first half of "everything is clickable" — the second half is that the highlight has to be
/// affordable, because a hover repaints on every cell boundary the pointer crosses.
///
/// Three properties are pinned here, in the order they matter:
///
/// 1. **Hover is the click table.** `WallState.focus(atRow:col:)` is derived from
///    `WallLayout.action`, so a highlight cannot sit on something a click would not act on — the
///    failure mode of a hand-written second hit test, and the reason it is not one.
/// 2. **It is cheap.** A hover that lights one card must not repaint the wall: budget 600 B per the
///    UI v2 plan (§5), and the number is asserted rather than hoped for.
/// 3. **It goes away.** Pressing down deepens it, releasing it and moving off clears it — a hover
///    that only hears about motion stays lit after the click it belonged to.
final class WallHoverTests: XCTestCase {
    private func window(_ i: Int) -> OrderedWindow {
        let apps = ["Safari", "Xcode", "Terminal"]
        let bounds = CGRectCompat(x: 0, y: 0, width: Double(800 + i), height: 600)
        return OrderedWindow(windowID: CGWindowID(100 + i), pid: Int32(1000 + i),
                             app: apps[i % 3], title: "window \(i)", bounds: bounds)
    }

    private func model() -> WallModel {
        let displays = [WallDisplay(name: "Built-in", width: 1512, height: 982, main: true)]
        var windows: [OrderedWindow] = []
        for i in 0..<7 { windows.append(window(i)) }
        return WallModel(displays: displays, windows: windows)
    }

    private func layout(_ state: WallState, cols: Int = 137, rows: Int = 44) -> WallLayout {
        let m = model()
        return state.layout(cols: cols, rows: rows, displays: m.displays.count,
                            windows: m.windows.count)
    }

    // MARK: - 1. hover is the click table

    func testACardAndItsCaptionBothHover() {
        let state = WallState()
        let l = layout(state)
        let box = l.cards[1]
        XCTAssertEqual(state.focus(atRow: box.row + 1, col: box.col + 2, in: l), .window(1),
                       "inside a card")
        let caption = l.cardCaptions[1]
        XCTAssertEqual(state.focus(atRow: caption.row, col: caption.col + 1, in: l), .window(1),
                       "the caption under a card is the same item (design §1: 点图或点说明都进入)")
    }

    func testTheStageHoversAsItsDisplay() {
        let state = WallState()
        let l = layout(state)
        XCTAssertEqual(state.focus(atRow: l.stage.row + 2, col: l.stage.col + 3, in: l),
                       .display(state.stageStart))
        XCTAssertEqual(state.focus(atRow: l.stageCaption.row, col: l.stageCaption.col + 2, in: l),
                       .display(state.stageStart), "the caption under the stage is the stage")
    }

    /// The bar, the band header, the footer and the blank margins are all things a click does
    /// *something* with (a page step, a width cycle, back) — but nothing to highlight, and hovering
    /// them must not light a card by accident.
    func testTheFurnitureDoesNotHover() {
        let state = WallState()
        let l = layout(state)
        XCTAssertNil(state.focus(atRow: l.headerRow, col: 2, in: l), "header")
        XCTAssertNil(state.focus(atRow: l.bandRow, col: 2, in: l), "band header")
        XCTAssertNil(state.focus(atRow: l.footerRow, col: 2, in: l), "footer")
        XCTAssertNil(state.focus(atRow: l.barCol, col: l.barCol, in: l).flatMap { focus -> WallState.Focus? in
            if case .display = focus { return focus } else { return nil }
        }, "the bar is not a card or a display")
    }

    /// A page offset moves the *slot*, not the item: the highlight belongs to the window the click
    /// would enter, which is `cardStart + slot`. Getting this wrong lights the card on the previous
    /// page — visible only after scrolling.
    func testHoverCarriesTheAbsoluteIndexNotTheSlot() {
        var state = WallState()
        state.cardStart = 3
        let l = layout(state)
        let slot0 = l.cards[0]
        XCTAssertEqual(state.focus(atRow: slot0.row + 1, col: slot0.col + 2, in: l), .window(3),
                       "the first card of page 2 is window 3")
    }

    // MARK: - 2/3. the paint

    /// Full paint, then the same wall with one card hovered: the bytes that answer a hover.
    private func hoverStream(_ pointer: WallPointer, state: WallState = WallState())
        -> (first: [UInt8], hover: [UInt8]) {
        let m = model()
        let l = layout(state)
        let canvas = WallCanvas(symbols: .emoji)
        let first = canvas.draw(cols: 137, rows: 44, model: m, layout: l, focus: state.focus)
        let hover = canvas.draw(cols: 137, rows: 44, model: m, layout: l, focus: state.focus,
                               pointer: pointer)
        return (first, hover)
    }

    func testAHoveredCardIsDrawnInTheAccentColour() {
        let (_, hover) = hoverStream(WallPointer(over: .window(1)))
        let text = String(decoding: hover, as: UTF8.self)
        XCTAssertFalse(text.isEmpty, "a hover that emits nothing is not a hover")
        XCTAssertTrue(text.contains("\u{1B}[36m"), "the accent SGR (cyan) is what marks it: \(text.debugDescription)")
    }

    func testHoveringNothingPaintsNothing() {
        let (_, hover) = hoverStream(WallPointer(over: nil))
        XCTAssertEqual(hover.count, 0, "no pointer over anything is not a repaint")
    }

    func testAPressDeepensTheHighlightAndReleasingItGoesBack() {
        let (_, hover) = hoverStream(WallPointer(over: .window(1)))
        let (_, pressed) = hoverStream(WallPointer(over: .window(1), down: true))
        XCTAssertNotEqual(hover, pressed, "a press has to be visible: it is the only feedback before the mirror opens")
        XCTAssertTrue(String(decoding: pressed, as: UTF8.self).contains("\u{1B}[7m"),
                      "the pressed state is the reverse video of the same row")
    }

    /// The budget from `docs/design-ui-v2.zh-CN.md` §5: a hover repaint must stay under 600 B, or a
    /// pointer crossing the shelf at 60 events a second becomes a stream of frames.
    func testAHoverRepaintCostsLessThanSixHundredBytes() {
        let (first, hover) = hoverStream(WallPointer(over: .window(1)))
        XCTAssertLessThan(first.count, 60_000, "sanity: the full wall is the big number")
        XCTAssertLessThan(hover.count, 600,
                          "a hover repainted \(hover.count) B; the budget is 600")
        XCTAssertGreaterThan(hover.count, 0)
    }

    /// Moving from one card to the next is one repaint, not two: the old card loses its accent and
    /// the new one gains it, in the same diff.
    func testMovingBetweenCardsIsOneRepaint() {
        let m = model()
        let l = layout(WallState())
        let canvas = WallCanvas(symbols: .emoji)
        _ = canvas.draw(cols: 137, rows: 44, model: m, layout: l, focus: nil,
                        pointer: WallPointer(over: .window(0)))
        let moved = canvas.draw(cols: 137, rows: 44, model: m, layout: l, focus: nil,
                                pointer: WallPointer(over: .window(1)))
        XCTAssertLessThan(moved.count, 1200, "two cards' worth of change, one write: \(moved.count) B")
        let text = String(decoding: moved, as: UTF8.self)
        XCTAssertTrue(text.contains("\u{1B}[36m"), "the new card is accent")
        XCTAssertTrue(text.contains("\u{1B}[2;37m"), "and the old one is dim again")
    }
}
