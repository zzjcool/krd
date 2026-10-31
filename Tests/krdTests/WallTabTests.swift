import XCTest
@testable import krd
import krdcore

/// The wall's keyboard: `Tab` reaches everything a click can, because both read the same table.
///
/// "Everything is clickable" is half of a TUI. The other half is that a mouse must not be the only
/// way to reach any of it — over a link where the mouse reports are late (plan §2.2: p50 23.5 ms
/// with OpenSSH's obfuscation on) the wall was unusable without one, because `WallInput.consumes`
/// swallowed every key and `WallState` had nowhere to put a keyboard's position.
///
/// Four properties, in the order they matter:
///
/// 1. **The ring is the click table.** `WallLayout.stops()` is one scan of `action(row:col:)` over
///    the pane, so "the keyboard reaches exactly what the mouse can" is true *by construction*:
///    there is no second list to forget when a control is added. The test asserts the bijection in
///    both directions anyway, because a guard is what keeps it a construction and not a comment.
/// 2. **Activation is the click.** `Enter` hands the ring's own `WallAction` to the caller, which
///    runs it through the same `apply` a click does — the keyboard has no `switch` of its own.
/// 3. **The ring is not the hover.** A pointer move can never move it, it is drawn with a different
///    attribute (an underline, not the pointer's reverse video), and both can sit on one item.
/// 4. **It is cheap and quiet.** The first frame is byte-identical (the ring is off until a key is
///    pressed) and a focus move repaints two items' text, no pictures: budget 600 B, the same
///    number the hover is pinned to (`WallHoverTests`).
final class WallTabTests: XCTestCase {
    // MARK: - fixtures

    private func display(_ i: Int) -> WallDisplay {
        WallDisplay(name: "Display \(i)", width: 1512 + i, height: 982, id: UInt32(100 + i),
                    main: i == 0)
    }

    private func window(_ i: Int) -> OrderedWindow {
        let apps = ["Safari", "Xcode", "Terminal"]
        return OrderedWindow(windowID: CGWindowID(100 + i), pid: Int32(1000 + i),
                             app: apps[i % 3], title: "window \(i)",
                             bounds: CGRectCompat(x: 0, y: 0, width: Double(800 + i), height: 600))
    }

    private func model(displays: Int = 3, windows: Int = 7) -> WallModel {
        WallModel(displays: (0..<max(0, displays)).map(display),
                  windows: (0..<max(0, windows)).map(window))
    }

    private func layout(_ state: WallState, cols: Int = 137, rows: Int = 44,
                        displays: Int = 3, windows: Int = 7) -> WallLayout {
        state.layout(cols: cols, rows: rows, displays: displays, windows: windows)
    }

    /// One key press, as `Desk.wallKey` performs it: the policy is `WallState.key`, and whatever
    /// action it hands back is applied through the *click's* `apply`.
    @discardableResult
    private func press(_ key: WallKey, _ state: inout WallState, _ l: WallLayout,
                       displays: Int = 3, windows: Int = 7) -> WallAction? {
        guard let action = state.key(key, in: l) else { return nil }
        state.apply(action, displays: displays, windows: windows, capacity: l.capacity)
        return action
    }

    /// `Tab` until the ring is on `stop`. Bounded on purpose: a stop the ring cannot reach must fail
    /// the test, not hang it.
    private func tab(to stop: WallAction, _ state: inout WallState, _ l: WallLayout,
                     displays: Int = 3, windows: Int = 7,
                     file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<(l.stops().count + 1) {
            if state.ring == stop { return }
            press(.next, &state, l, displays: displays, windows: windows)
        }
        XCTFail("Tab never reached \(stop)", file: file, line: line)
    }

    /// One click, as `Desk.wallClick` performs it.
    @discardableResult
    private func click(_ state: inout WallState, row: Int, col: Int, _ l: WallLayout,
                       displays: Int = 3, windows: Int = 7) -> WallAction? {
        guard let action = l.action(row: row, col: col) else { return nil }
        state.apply(action, displays: displays, windows: windows, capacity: l.capacity)
        return action
    }

    /// Every action a click anywhere on this pane can produce. Walked out of the table itself, cell
    /// by cell, so it is independent of the way `stops()` implements the same walk.
    private func clickActions(_ l: WallLayout) -> [WallAction] {
        var seen: [WallAction] = []
        guard l.cols > 0, l.rows > 0 else { return seen }
        for row in 1...l.rows {
            for col in 1...l.cols {
                guard let action = l.action(row: row, col: col) else { continue }
                if !seen.contains(action) { seen.append(action) }
            }
        }
        return seen
    }

    /// The geometries and worlds the bijection has to hold for: a full pane, a small one, a pane
    /// too narrow for a card, an empty desk and a desk with everything.
    private let worlds: [(cols: Int, rows: Int, displays: Int, windows: Int)] = [
        (137, 44, 3, 7), (80, 24, 2, 12), (60, 24, 1, 4), (40, 20, 3, 20),
        (20, 12, 2, 3), (12, 24, 1, 7), (137, 44, 0, 0), (100, 30, 1, 0),
    ]

    // MARK: - 1. the ring is the click table

    /// Both directions, at once: every action a click can produce is a stop, and every stop is an
    /// action a click can produce. This is the property that decays if it is written twice.
    func testEveryActionAClickCanProduceIsATabStopAndViceVersa() {
        for w in worlds {
            let state = WallState()
            let l = layout(state, cols: w.cols, rows: w.rows,
                           displays: w.displays, windows: w.windows)
            let clicks = clickActions(l)
            let stops = l.stops()
            let where_ = "\(w.cols)x\(w.rows) \(w.displays)d \(w.windows)w"
            XCTAssertEqual(stops.map(\.action), clicks,
                           "the ring and the click table disagree at \(where_): "
                           + "stops \(stops.map(\.action)) vs clicks \(clicks)")
            XCTAssertEqual(Set(stops.map(\.action)).count, stops.count,
                           "a stop is visited twice at \(where_): \(stops.map(\.action))")
            // A stop is a *thing*, not a cell: it was found at the first cell that answers it.
            for stop in stops {
                XCTAssertEqual(l.action(row: stop.row, col: stop.col), stop.action,
                               "the stop \(stop.action) does not live at (\(stop.row),\(stop.col))")
            }
        }
    }

    /// The same property from the keyboard's side: `Tab` walks the table's actions, in reading
    /// order, once each, and wraps.
    func testTabWalksEveryStopInReadingOrderThenWraps() {
        for w in [(137, 44, 3, 7), (60, 24, 1, 4), (40, 20, 3, 20), (12, 24, 1, 7)] {
            var state = WallState()
            let l = layout(state, cols: w.0, rows: w.1, displays: w.2, windows: w.3)
            let stops = l.stops()
            XCTAssertFalse(stops.isEmpty, "\(w.0)x\(w.1): a wall with no stop at all")
            var walked: [WallAction] = []
            for _ in 0..<stops.count {
                press(.next, &state, l, displays: w.2, windows: w.3)
                walked.append(state.ring!)
            }
            XCTAssertEqual(walked, stops.map(\.action),
                           "Tab does not walk the table at \(w.0)x\(w.1)")
            // Reading order: row, then column — the order a reader's eye takes the wall apart.
            for (a, b) in zip(stops, stops.dropFirst()) {
                XCTAssertTrue(a.row < b.row || (a.row == b.row && a.col < b.col),
                              "\(a.action) at (\(a.row),\(a.col)) comes before "
                              + "\(b.action) at (\(b.row),\(b.col))")
            }
            // And it wraps rather than falling off the end.
            press(.next, &state, l, displays: w.2, windows: w.3)
            XCTAssertEqual(state.ring, stops.first?.action, "Tab did not wrap at \(w.0)x\(w.1)")
        }
    }

    /// `Shift-Tab` is the same ring walked the other way, and it starts at the end when the keyboard
    /// has not been used yet.
    func testShiftTabWalksTheSameRingBackwards() {
        var state = WallState()
        let l = layout(state)
        let stops = l.stops()
        press(.previous, &state, l)
        XCTAssertEqual(state.ring, stops.last?.action, "Shift-Tab starts at the end")
        var walked: [WallAction] = []
        for _ in 0..<stops.count {
            walked.append(state.ring!)
            press(.previous, &state, l)
        }
        XCTAssertEqual(walked, stops.map(\.action).reversed())
    }

    // MARK: - 2. the vocabulary

    /// The wall's own keys, and the one byte that is not: `Ctrl-\` stays the reader's quit, and the
    /// wall still swallows every byte it is handed (nothing else may reach a remote that is not
    /// there — `WallCanvasTests.testTheWallConsumesEveryKeyExceptQuit`).
    func testTheWallsKeysAreTabEnterSpaceEscAndTheArrows() {
        func key(_ code: UInt16, _ mods: Modifiers = [], _ phase: KeyReport.Phase = .press)
            -> WallKey? {
            WallInput.key(for: .press(code, mods, phase))
        }
        XCTAssertEqual(key(Keys.tab), .next)
        XCTAssertEqual(key(Keys.tab, [.maskShift]), .previous)
        XCTAssertEqual(key(Keys.enter), .activate)
        XCTAssertEqual(key(Keys.space), .activate)
        XCTAssertEqual(key(Keys.esc), .cancel)
        XCTAssertEqual(key(Keys.left), .backward)
        XCTAssertEqual(key(Keys.up), .backward)
        XCTAssertEqual(key(Keys.right), .forward)
        XCTAssertEqual(key(Keys.down), .forward)
        // A release is not a second press: a wall that acted on one would act twice per key.
        XCTAssertNil(key(Keys.enter, [], .release))
        // A modified key is the desktop's (Ctrl-Left is a word step), never the wall's.
        XCTAssertNil(key(Keys.left, [.maskControl]))
        XCTAssertNil(key(Keys.tab, [.maskControl]))
        XCTAssertNil(key(Keys.enter, [.maskAlternate]))
        // The space a terminal sends as text rather than as a key code, and the tab some do too.
        XCTAssertEqual(WallInput.key(for: .text(" ", [])), .activate)
        XCTAssertNil(WallInput.key(for: .text(" ", [.maskAlternate])))
        XCTAssertEqual(WallInput.key(for: .text("\t", [])), .next)
        // `q` was the bug in `WallProcessTests`: a printable key is never the wall's.
        XCTAssertNil(WallInput.key(for: .text("q", [])))
        // `Ctrl-\` is not in this vocabulary at all: `consumes` hands it back to the reader.
        XCTAssertNil(WallInput.key(for: .control(0x1C)))
        XCTAssertFalse(WallInput.consumes(0x1C))
        XCTAssertTrue(WallInput.consumes(0x09), "the wall still owns every byte it is handed")
    }

    // MARK: - 3. activation is the click

    /// `Enter` on a card hands back the very action a click on that card's caption produces, and
    /// applying it lands in the same state — including the `focus` the click's switch sets, which is
    /// the whole of "entered" in phase 1.
    func testEnterOnACardIsAClickOnIt() {
        var ringed = WallState()
        let l = layout(ringed)
        tab(to: .enterCard(1), &ringed, l)
        let byKey = press(.activate, &ringed, l)

        var clicked = WallState()
        let caption = l.cardCaptions[1]
        let byClick = click(&clicked, row: caption.row, col: caption.col + 3, l)

        XCTAssertEqual(byKey, .enterCard(1))
        XCTAssertEqual(byKey, byClick)
        XCTAssertEqual(ringed.focus, clicked.focus, "the keyboard and the click entered differently")
        XCTAssertEqual(ringed.stageStart, clicked.stageStart)
        XCTAssertEqual(ringed.cardStart, clicked.cardStart)
        XCTAssertEqual(ringed.focus, .window(1))
        // The ring is a *position*, not part of the pick: activating an item does not move it away.
        XCTAssertEqual(ringed.ring, .enterCard(1))
    }

    /// The same for every stop in the table — the stage, every card, the bar's arrows and jumps, the
    /// `⤢` and the footer: `Enter` on a stop and a click on the cell it lives at must send the same
    /// `WallAction` and leave the same state. That is what "the keyboard has no switch of its own"
    /// means, and it is the property a duplicated activation path would break.
    func testEnterOnEveryStopIsAClickOnTheCellItLivesAt() {
        for w in [(137, 44, 3, 7), (60, 24, 1, 4), (40, 20, 3, 20), (12, 24, 1, 7)] {
            let fresh = WallState()
            let l = layout(fresh, cols: w.0, rows: w.1, displays: w.2, windows: w.3)
            for stop in l.stops() {
                var byKey = fresh
                byKey.ring = stop.action
                let keyAction = press(.activate, &byKey, l, displays: w.2, windows: w.3)

                var byClick = fresh
                let clickAction = click(&byClick, row: stop.row, col: stop.col, l,
                                        displays: w.2, windows: w.3)

                let where_ = "\(stop.action) at (\(stop.row),\(stop.col)) on \(w.0)x\(w.1)"
                XCTAssertEqual(keyAction, clickAction, "Enter is not a click for \(where_)")
                XCTAssertEqual(byKey.stageStart, byClick.stageStart, "stage offset after \(where_)")
                XCTAssertEqual(byKey.cardStart, byClick.cardStart, "page offset after \(where_)")
                XCTAssertEqual(byKey.focus, byClick.focus, "pick after \(where_)")
                XCTAssertEqual(byKey.per, byClick.per, "row width after \(where_)")
            }
        }
    }

    /// A ring that names a stop this pane no longer draws is not somewhere to act from: the window
    /// list shrank under it, and `Enter` must be a no-op rather than an action for an item that is
    /// gone.
    func testARingOnAStopThatIsGoneDoesNotAct() {
        var state = WallState()
        // Card 2 is on the landing page at 137x44 (three to a row, one row of them) and card 6 is
        // not: the ring is over what is *on screen*, which is what a mouse can reach too.
        XCTAssertNil(WallState(ring: .enterCard(6)).ringStop(in: layout(state, windows: 7)))
        state.ring = .enterCard(2)
        XCTAssertEqual(state.ringStop(in: layout(state, windows: 7)), .enterCard(2))
        let shrunken = layout(state, windows: 2)
        XCTAssertNil(state.ringStop(in: shrunken), "a card that is not on screen is not a stop")
        XCTAssertNil(press(.activate, &state, shrunken, windows: 2))
        XCTAssertEqual(state.focus, nil, "a key acted on a stop that does not exist")
    }

    /// The ring survives an activation that leaves the stop in place (a page step the reader may
    /// want to repeat) and lands on the band it was in when the stop is gone (`⤢` rewrites its own
    /// payload).
    func testTheRingSettlesOnAStopThePaneStillDraws() {
        var state = WallState()
        let l = layout(state)
        tab(to: .cardStep(l.capacity), &state, l)
        press(.activate, &state, l)
        XCTAssertEqual(state.cardStart, l.capacity, "the page moved")
        state.settleRing(in: layout(state))
        XCTAssertEqual(state.ring, .cardStep(l.capacity), "the bar's arrow is still the bar's arrow")

        var cycled = WallState()
        tab(to: .cyclePer(WallLayout.nextPer(after: 3, paneCols: 137) ?? 2), &cycled, l)
        press(.activate, &cycled, l)
        XCTAssertEqual(cycled.per, 4, "the row width cycled")
        cycled.settleRing(in: layout(cycled))
        XCTAssertNotNil(cycled.ringStop(in: layout(cycled)),
                        "the ring was left naming a width the control no longer offers")
        XCTAssertEqual(cycled.ring, .cyclePer(WallLayout.nextPer(after: 4, paneCols: 137) ?? 2))
    }

    // MARK: - 4. the arrows stay in their band

    /// `Left`/`Right`/`Up`/`Down` move inside the band the ring is in: a reader in the shelf stays in
    /// the shelf (page step included), and one on the stage stays on the stage's own controls.
    func testTheArrowsMoveWithinTheBand() {
        var state = WallState()
        let l = layout(state)
        let stops = l.stops()
        tab(to: .enterCard(0), &state, l)
        var visited: [WallAction] = []
        for _ in 0..<(stops.count * 2) {
            press(.forward, &state, l)
            visited.append(state.ring!)
            XCTAssertEqual(stops.first { $0.action == state.ring! }?.band, .shelf,
                           "an arrow left the shelf: \(state.ring!)")
        }
        XCTAssertTrue(visited.contains(.cardStep(l.capacity)), "the shelf's page step is in the band")
        for _ in 0..<(stops.count * 2) {
            press(.backward, &state, l)
            XCTAssertEqual(stops.first { $0.action == state.ring! }?.band, .shelf,
                           "an arrow left the shelf going back: \(state.ring!)")
        }
        // The stage's band is the display plus the bar's two arrows and jumps over it.
        var stage = WallState()
        tab(to: .enterStage(0), &stage, l)
        var seen: Set<WallAction> = []
        for _ in 0..<8 {
            press(.forward, &stage, l)
            seen.insert(stage.ring!)
            XCTAssertEqual(stops.first { $0.action == stage.ring! }?.band, .stage,
                           "an arrow left the stage: \(stage.ring!)")
        }
        XCTAssertTrue(seen.contains(.stageStep(1)), "the stage's own step is in the band")
        XCTAssertTrue(seen.contains { if case .stageJump = $0 { return true } else { return false } },
                      "a jump on the stage's bar is in the band")
    }

    // MARK: - 5. Esc

    /// `Esc` clears the ring before it does anything else — and only when there is no ring does it
    /// do what a click on the footer's own cell does (leave the pick).
    func testEscClearsTheRingBeforeItGoesBack() {
        var state = WallState()
        let l = layout(state)
        // A pick, as a click on a card would leave it.
        _ = click(&state, row: l.cardCaptions[0].row, col: l.cardCaptions[0].col + 2, l)
        XCTAssertEqual(state.focus, .window(0))
        press(.next, &state, l)
        XCTAssertNotNil(state.ring)
        XCTAssertNil(press(.cancel, &state, l), "Esc with a ring on performed something")
        XCTAssertNil(state.ring, "Esc did not clear the ring")
        XCTAssertEqual(state.focus, .window(0), "Esc cleared a pick it was not asked about")
        // No ring: Esc is the footer's `back`, and only that.
        XCTAssertEqual(press(.cancel, &state, l), .back)
        XCTAssertNil(state.focus, "Esc did not leave the pick")
        // And with neither, it is nothing at all — never a quit, never a byte.
        XCTAssertNil(press(.cancel, &state, l))
        XCTAssertNil(state.ring)
    }

    // MARK: - 6. the paint

    private func canvasBytes(ring: WallAction?, pointer: WallPointer = WallPointer(),
                             state: WallState = WallState(), cols: Int = 137, rows: Int = 44,
                             canvas: WallCanvas) -> [UInt8] {
        let m = model()
        let l = layout(state, cols: cols, rows: rows)
        return canvas.draw(cols: cols, rows: rows, model: m, layout: l, focus: state.focus,
                           paints: WallSlotPaints(), pointer: pointer, ring: ring)
    }

    /// The first screen is the screen PR #195 left behind: the ring is off until a key is pressed, so
    /// the four golden dumps (`WallCanvasTests`) are byte-identical and the idle wall costs nothing.
    func testAKeyboardNobodyUsesChangesNothing() {
        var state = WallState()
        XCTAssertNil(state.ring, "the wall opens with a ring on")
        let fresh = canvasBytes(ring: nil, canvas: WallCanvas(symbols: .emoji))
        // The budget the wall has always had; a ring that painted here would move these bytes.
        XCTAssertEqual(fresh, canvasBytes(ring: nil, state: state, canvas: WallCanvas(symbols: .emoji)))
        XCTAssertFalse(String(decoding: fresh, as: UTF8.self).contains("Tab selects"),
                       "the keyboard hint is on the idle first screen")
        // One Tab, and the wall is a different wall: the ring is visible.
        let l = layout(state)
        press(.next, &state, l)
        XCTAssertNotEqual(canvasBytes(ring: state.ring, state: state,
                                      canvas: WallCanvas(symbols: .emoji)), fresh,
                          "Tab painted nothing")
    }

    /// The ring is not the hover: an underline, not the pointer's reverse video — and both can sit on
    /// the same item at once, because SGR 4 and SGR 7 are different bits.
    func testTheRingIsAnUnderlineAndItStacksWithThePointer() {
        let ring = WallAction.enterCard(1)
        let alone = String(decoding: canvasBytes(ring: ring, canvas: WallCanvas(symbols: .emoji)),
                           as: UTF8.self)
        XCTAssertTrue(alone.contains("\u{1B}[0;4m"),
                      "the ring on a plain caption is SGR 0;4: \(alone.debugDescription)")
        XCTAssertFalse(alone.contains("\u{1B}[7m"), "the ring reused the pointer's reverse video")
        let hovered = String(decoding: canvasBytes(ring: ring,
                                                  pointer: WallPointer(over: .window(1)),
                                                  canvas: WallCanvas(symbols: .emoji)),
                             as: UTF8.self)
        XCTAssertTrue(hovered.contains("\u{1B}[7;4m"),
                      "a hovered, focused caption is reverse and underlined: "
                      + hovered.debugDescription)
        // The pointer alone stays exactly what it was: no underline anywhere.
        let pointerOnly = String(decoding: canvasBytes(ring: nil,
                                                       pointer: WallPointer(over: .window(1)),
                                                       canvas: WallCanvas(symbols: .emoji)),
                                 as: UTF8.self)
        XCTAssertFalse(pointerOnly.contains(";4m"), "a mouse move looked like a focus change")
    }

    /// Moving the ring repaints the two items it left and arrived at — and no picture, no frame.
    func testAMoveRepaintsTwoItemsAndNoPictures() {
        let state = WallState()
        let l = layout(state)
        let stops = l.stops()
        let canvas = WallCanvas(symbols: .emoji)
        // Open on the first stop, then ask each move for its bytes.
        var worst = 0
        var walked = 0
        var from: WallAction? = nil
        for stop in stops {
            let moved = canvasBytes(ring: stop.action, state: state, canvas: canvas)
            let text = String(decoding: moved, as: UTF8.self)
            XCTAssertFalse(text.contains("\u{1B}_G"), "a focus move re-sent a picture")
            XCTAssertFalse(text.contains("\u{1B}[?2026"), "a focus move restarted the frame")
            if from != nil {
                worst = max(worst, moved.count)
                walked += 1
            }
            from = stop.action
        }
        XCTAssertGreaterThan(walked, 0)
        XCTAssertLessThan(worst, 600, "a focus move cost \(worst) B; the budget is 600")
        // Moving within one item is nothing at all.
        _ = canvasBytes(ring: .enterCard(0), state: state, canvas: canvas)
        XCTAssertEqual(canvasBytes(ring: .enterCard(0), state: state, canvas: canvas).count, 0,
                       "a repaint of the same ring is not a repaint")
        // The number the PR quotes. `stderr` because XCTest swallows the test process's stdout.
        if ProcessInfo.processInfo.environment["KRD_WALL_FOCUS_BYTES"] != nil {
            FileHandle.standardError.write(Data(
                "wall focus: worst move \(worst) B over \(walked) moves on 137x44\n".utf8))
        }
    }

    /// The footer's click hint gains its keyboard twin once the keyboard is in use — and only then,
    /// because the first screen is unchanged.
    func testTheFooterGainsItsKeyboardTwinOnlyWhenTheRingIsOn() {
        let m = model()
        let state = WallState()
        let l = layout(state)
        func footer(_ ring: WallAction?) -> String {
            let lines = WallCanvas(symbols: .emoji).lines(cols: 137, rows: 44, model: m,
                                                          layout: l, focus: nil, ring: ring)
            return lines[l.footerRow - 1]
        }
        XCTAssertTrue(footer(nil).contains("click a card"), "the click hint is still the hint")
        XCTAssertFalse(footer(nil).contains("Tab selects"))
        XCTAssertTrue(footer(.enterCard(0)).contains("Tab selects"),
                      "the keyboard twin: \(footer(.enterCard(0)))")
        XCTAssertTrue(footer(.enterCard(0)).contains("Enter opens"))
        // A pick still says where it came from, and a notice still wins over both.
        let picked = WallCanvas(symbols: .emoji).lines(cols: 137, rows: 44, model: m, layout: l,
                                                       focus: .window(0), ring: .enterCard(0))
        XCTAssertTrue(picked[l.footerRow - 1].contains("back"), "a pick is still a way back")
    }
}
