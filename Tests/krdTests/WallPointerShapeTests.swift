import XCTest
@testable import krd
import krdcore

/// The wall's **outer** pointer: the shape the terminal draws for the mouse while it is over the
/// wall (OSC 22, issue #202).
///
/// The hover (#195) answers the reader *inside* the pane — a card's caption reverses. This is the
/// other half: the pointer the terminal draws is the terminal's, and a program asks for it with
/// `ESC ] 22 ; <shape> ST`. The UI v2 plan (§4) allows three shapes and the wall uses exactly two:
///
///  * `pointer` (a hand) over anything that **enters** — the stage, a card, either one's caption;
///  * `default` over the wall's own furniture (the bar's arrows and shaft, `⤢ N`, the footer) and
///    over nothing at all: a page step is a click, not a target, which is the same decision that
///    dims the bar's ends.
///
/// `text` is deliberately not here: there is no text field in the wall, so the third shape belongs
/// to the mirror's later work. A case nobody can reach is a case that rots.
///
/// Two properties are pinned, and they are the two the issue measured:
///
/// 1. **The shape follows the target's *class*, not the cell.** Moving inside one card emits
///    nothing — that is what makes this affordable at all, because a pointer crossing a card
///    border many times a second would otherwise be a stream of OSC 22 writes.
/// 2. **It rides the frame's own write.** The sequence is prepended to the bytes the wall's text
///    layer was already sending, in the one `write(2)` that carries them (#197's whole point); a
///    hover that changes class is `39-97 B + 14 B`, not two writes.
///
/// `paintWall` is private and needs ScreenCaptureKit, so the harness below is the two lines
/// `Desk.drawWall` runs before it paints — the shape the pointer wants, then the frame's text in
/// the frame's write. `WallProcessTests` runs the real binary in a pty, which is what catches the
/// two drifting apart.
final class WallPointerShapeTests: XCTestCase {
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

    private let cols = 137
    private let rows = 44

    private func layout(_ state: WallState = WallState()) -> WallLayout {
        let m = model()
        return state.layout(cols: cols, rows: rows, displays: m.displays.count,
                            windows: m.windows.count)
    }

    /// The shape a cell asks for, through the click table — the same door the hover goes in by.
    ///
    /// Not `WallLayout.action` read again here: a second hit test is how a pointer ends up saying
    /// "hand" over something a click would not enter. `focus` is #195's answer, and the shape is a
    /// projection of it.
    private func shape(atRow row: Int, col: Int, _ state: WallState = WallState()) -> PointerShape {
        let l = layout(state)
        return WallPointer(over: state.focus(atRow: row, col: col, in: l)).shape
    }

    // MARK: - 1. the mapping: target class in, one of two shapes out

    func testNothingHoveredIsTheDefaultShape() {
        XCTAssertEqual(WallPointer().shape, .default)
        // A gap between the cards, and the blank column before the band's `⤢`: a hover that stays
        // where it is has to leave the terminal's own pointer alone.
        let l = layout()
        XCTAssertEqual(shape(atRow: l.headerRow, col: 1), .default, "the header is not a target")
        XCTAssertEqual(shape(atRow: l.bandRow, col: 1), .default, "the band's label is not a target")
        XCTAssertEqual(shape(atRow: l.dividerRow.row, col: 2), .default, "the rule is not a target")
    }

    func testACardIsThePointerShape() {
        let state = WallState()
        let l = layout(state)
        let card = l.cards[1]
        XCTAssertEqual(shape(atRow: card.row + 1, col: card.col + 2, state), .pointer, "inside a card")
        let caption = l.cardCaptions[1]
        XCTAssertEqual(shape(atRow: caption.row, col: caption.col + 1, state), .pointer,
                       "the caption under a card enters it too (design §1: 点图或点说明都进入)")
    }

    func testTheStageAndItsCaptionAreThePointerShape() {
        let state = WallState()
        let l = layout(state)
        XCTAssertEqual(shape(atRow: l.stage.row + 3, col: l.stage.col + 4, state), .pointer, "the stage")
        XCTAssertEqual(shape(atRow: l.stageCaption.row, col: l.stageCaption.col + 3, state), .pointer,
                       "the caption under the stage is the stage")
    }

    /// The furniture: it *does* answer a click (a page step, a width cycle, back) and it is not a
    /// target, so the terminal keeps its own pointer — the plan's decision, and the reason the bar's
    /// ends are dimmed.
    func testTheFurnitureIsTheDefaultShape() {
        let state = WallState()
        let l = layout(state)
        // The bar: its own column, over both segments and both caps.
        for row in l.bar.stage.rect.row...max(l.bar.stage.rect.row, l.bar.stage.rect.maxRow) {
            XCTAssertEqual(shape(atRow: row, col: l.barCol, state), .default, "bar row \(row)")
        }
        for row in l.bar.cards.rect.row...max(l.bar.cards.rect.row, l.bar.cards.rect.maxRow) {
            XCTAssertEqual(shape(atRow: row, col: l.barCol, state), .default, "bar row \(row)")
        }
        // `⤢ N`: the row-width control, which is a page-shape change and not an entry.
        XCTAssertFalse(l.bandTail.isEmpty, "the fixture pane has a row-width control")
        XCTAssertEqual(shape(atRow: l.bandTail.row, col: l.bandTail.col, state), .default, "⤢")
        // The footer: `back`, which is furniture by the same rule.
        XCTAssertEqual(shape(atRow: l.footerRow, col: 2, state), .default, "the footer")
    }

    /// The whole point of "the shape follows the class": two cells of one card answer the same
    /// shape, so a pointer that moves between them asks the terminal for nothing.
    func testTwoCellsOfOneCardAreTheSameClass() {
        let state = WallState()
        let l = layout(state)
        let card = l.cards[1]
        let caption = l.cardCaptions[1]
        let inside = shape(atRow: card.row + 1, col: card.col + 2, state)
        let elsewhere = shape(atRow: card.maxRow, col: card.maxCol - 1, state)
        let captionRow = shape(atRow: caption.row, col: caption.col, state)
        XCTAssertEqual(inside, .pointer)
        XCTAssertEqual(inside, elsewhere, "the same card, two cells, one shape")
        XCTAssertEqual(inside, captionRow, "the card and its caption are one target")
        // And two *different* cards are the same class as well — the shape is not per item.
        XCTAssertEqual(inside, shape(atRow: l.cards[l.cards.count - 1].row + 1,
                                     col: l.cards[l.cards.count - 1].col + 2, state))
    }

    // MARK: - 2. the bytes: the shape rides the frame's write, and only on a class change

    /// The wall's paint as `Desk.drawWall` + `paintWall` run it.
    private final class Pane {
        let writer = ScreenWriter()
        let canvas = WallCanvas(symbols: .emoji)
        var chunks: [[UInt8]] = []
        init() {
            writer.sink = { [weak self] chunk in self?.chunks.append(chunk) }
        }
        var bytes: [UInt8] { chunks.flatMap { $0 } }
        var shapes: [String] { WallPointerShapeTests.shapes(in: bytes) }
        var writes: Int { chunks.count }
    }

    private func paint(_ pane: Pane, pointer: WallPointer, state: WallState = WallState()) {
        // `drawWall`'s line: the shape this paint wants.
        pane.writer.pointerShape = pointer.shape
        // `paintWall`'s line: the frame's own text, in the frame's own write.
        let text = pane.canvas.draw(cols: cols, rows: rows, model: model(), layout: layout(state),
                                   focus: state.focus, pointer: pointer)
        pane.writer.writeChrome(text)
    }

    /// Hand over the card, then off to the bar and back. The *crossing* is two class changes, so two
    /// OSC 22 writes — the first hover is the one that establishes the hand and is counted apart.
    ///
    /// The three cells are real: the first card's box, the bar's own column beside it, and the third
    /// card. Nothing here reads the pointer target directly — the shape comes from
    /// `WallState.focus`, i.e. from the click table, the same door the hover goes in by.
    func testCrossingCardBarCardIsExactlyTwoShapeWrites() {
        XCTAssertGreaterThanOrEqual(layout().cards.count, 2, "the fixture pane shows more than one card")
        let pane = Pane()
        let state = WallState()
        let l = layout(state)
        let first = l.cards[0]
        let last = l.cards[l.cards.count - 1]

        func hover(_ row: Int, _ col: Int) {
            paint(pane, pointer: WallPointer(over: state.focus(atRow: row, col: col, in: l)), state: state)
        }

        hover(first.row + 1, first.col + 2)                       // onto card 0: the hand goes on
        let afterFirst = pane.shapes
        XCTAssertEqual(afterFirst, ["pointer"], "the first hover asks for the hand: \(afterFirst)")

        hover(first.row + 1, l.barCol)                            // out to the bar
        hover(last.row + 1, last.col + 2)                         // back onto a card
        XCTAssertEqual(Array(pane.shapes.dropFirst()), ["default", "pointer"],
                       "card → bar → card is two class changes: \(pane.shapes)")
        XCTAssertEqual(pane.shapes.count - afterFirst.count, 2, "exactly two: \(pane.shapes)")
    }

    /// Inside one card nothing is asked for: the terminal's pointer is already a hand, and a hover
    /// that crosses cell boundaries is the common case (a trackpad reports motion continuously).
    func testMovingInsideOneCardAsksForNoShapeAtAll() {
        let pane = Pane()
        let state = WallState()
        let l = layout(state)
        let card = l.cards[1]
        let caption = l.cardCaptions[1]
        paint(pane, pointer: WallPointer(over: state.focus(atRow: card.row + 1, col: card.col + 2, in: l)),
              state: state)
        let shapesAfterEntering = pane.shapes.count
        let writesAfterEntering = pane.writes
        XCTAssertEqual(shapesAfterEntering, 1)

        // Three more cells of the same card, and its caption row: four paints, four diffs of the
        // caption's reverse video, and not one OSC 22.
        for (row, col) in [(card.row + 2, card.col + 3), (card.maxRow, card.maxCol - 2),
                           (caption.row, caption.col + 1), (card.row + 1, card.col + 1)] {
            let over = state.focus(atRow: row, col: col, in: l)
            XCTAssertEqual(over, .window(1), "the fixture cells are all card 1")
            paint(pane, pointer: WallPointer(over: over), state: state)
        }
        XCTAssertEqual(pane.shapes.count, shapesAfterEntering,
                       "moving inside one card asked for a shape: \(pane.shapes)")
        XCTAssertEqual(pane.writes, writesAfterEntering,
                       "a hover that stays inside one target does not even repaint (39-97 B on a real pane "
                       + "is a *moving* pointer, i.e. one that changed target)")
    }

    /// A whole-wall paint with nothing hovered asks the terminal for nothing: the writer's shape
    /// machinery is silent, and the frame is still one write.
    ///
    /// The goldens themselves are pinned next door (`WallCanvasTests
    /// .testTheFourDumpsAreTheWallByteForByte`, which paints the same `draw` this test paints with
    /// `pointer: nil`) — the canvas is not what #202 changed, so the four dumps are byte for byte
    /// what they were; what is new here is that the *writer* adds no shape byte to a frame that has
    /// no pointer in it.
    func testNothingHoveredAsksForNoShape() {
        let cases: [(cols: Int, rows: Int, symbols: WallSymbols)] = [
            (137, 44, .emoji), (137, 44, .ascii), (60, 24, .emoji), (60, 24, .ascii),
        ]
        for c in cases {
            let pane = Pane()
            pane.writer.pointerShape = WallPointer().shape
            let text = pane.canvas.draw(cols: c.cols, rows: c.rows, model: model(),
                                        layout: layout(WallState()), focus: nil)
            XCTAssertFalse(text.isEmpty, "\(c.cols)x\(c.rows) \(c.symbols.rawValue): a wall paints")
            pane.writer.writeChrome(text)
            XCTAssertEqual(pane.shapes, [], "\(c.cols)x\(c.rows) asked for a pointer shape")
            XCTAssertEqual(pane.writes, 1, "the frame is one write")
        }
    }

    /// The measurement the issue asks for: what a class change costs on top of the repaint it
    /// already caused. The plan's budget for a hover is 600 B (`docs/design-ui-v2.zh-CN.md` §5);
    /// one OSC 22 is 14 B, so the shape is noise — and it must not be a second write.
    ///
    /// Measured as a pair: the same five paints once with the shape machinery engaged and once with
    /// it left at `default`, so the difference between the two is the sequence and nothing else.
    func testAClassChangeCostsFourteenBytesAndNoExtraWrite() {
        func paintAll(_ pane: Pane, shapes: Bool) -> [Int] {
            // The wall is already on the pane before a pointer can arrive: the first `draw` of a fresh
            // canvas is the *whole* wall (9 KB of text here), and every hover after it is a diff
            // against that frame. Prime it without writing — `WallHoverTests` primes the same way.
            _ = pane.canvas.draw(cols: cols, rows: rows, model: model(),
                                 layout: layout(WallState()), focus: nil, pointer: WallPointer())
            pane.chunks.removeAll()
            let pointers = [WallPointer(over: .window(0)),           // onto a card: the hand goes on
                            WallPointer(over: .window(1)),           // another card: same class
                            WallPointer(),                           // out to the bar
                            WallPointer(over: .window(2)),           // back onto a card
                            WallPointer(over: .window(2), down: true)]  // a press: same target
            for pointer in pointers {
                let before = pane.chunks.count
                if shapes { pane.writer.pointerShape = pointer.shape }
                let text = pane.canvas.draw(cols: cols, rows: rows, model: model(),
                                           layout: layout(WallState()), focus: nil, pointer: pointer)
                pane.writer.writeChrome(text)
                XCTAssertEqual(pane.chunks.count, before + 1, "one paint, one write")
            }
            return pane.chunks.map(\.count)
        }

        let with = Pane()
        let sizesWith = paintAll(with, shapes: true)
        let without = Pane()
        let sizesWithout = paintAll(without, shapes: false)

        XCTAssertEqual(with.shapes, ["pointer", "default", "pointer"],
                       "two class changes after the first hand: \(with.shapes)")
        XCTAssertEqual(without.shapes, [], "a writer that was never asked sends nothing")
        XCTAssertEqual(with.writes, without.writes, "the shape never costs a write of its own")
        // The card→card paint and the press ask for nothing; the three that change class carry
        // exactly one sequence each.
        let deltas = zip(sizesWith, sizesWithout).map { $0 - $1 }
        XCTAssertEqual(deltas, [14, 0, 14, 14, 0],
                       "one OSC 22 per class change: \(deltas) on \(sizesWith) vs \(sizesWithout)")
        XCTAssertLessThan(sizesWithout[0], 600, "onto a card: \(sizesWithout[0]) B")
        XCTAssertLessThan(sizesWithout[1], 1_200,
                          "two cards' worth of change in one repaint: \(sizesWithout[1]) B "
                          + "(`WallHoverTests` pins the same 1200 for a card-to-card move)")
        XCTAssertLessThan(sizesWithout[2], 600, "leaving the shelf: \(sizesWithout[2]) B")
        XCTAssertLessThan(sizesWithout[3], 600, "onto another card: \(sizesWithout[3]) B")
        XCTAssertLessThan(sizesWithout[4], 600, "a press: \(sizesWithout[4]) B")
    }

    // MARK: - plumbing

    /// Every `ESC ] 22 ; <name> ST` in a stream, in order.
    private static func shapes(in bytes: [UInt8]) -> [String] {
        let open = Array("\u{1B}]22;".utf8)
        var out: [String] = []
        var i = 0
        while i + open.count <= bytes.count {
            guard Array(bytes[i..<(i + open.count)]) == open else { i += 1; continue }
            var j = i + open.count
            var name = ""
            while j < bytes.count, bytes[j] != 0x1B { name.append(Character(UnicodeScalar(bytes[j]))); j += 1 }
            out.append(name)
            i = j + 1
        }
        return out
    }
}
