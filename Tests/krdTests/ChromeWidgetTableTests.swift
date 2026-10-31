import XCTest
@testable import krd
@testable import krdcore

/// The chrome's hit table (issue #200): **the table that draws is the table that hits.**
///
/// Before this, a chrome cell was a control only if the drawer happened to stamp an id on it, and
/// everything else on a chrome row — the bar's fill, its numbers, the status line's separators, the
/// clock, the toast — answered `.picture`, i.e. "not the chrome". `chromeOwns` therefore said no,
/// the report fell through to the outside-the-picture branch, and that branch hands the cell back to
/// `onChromeClick`, whose `.picture` arm does nothing: a **dead cell**, drawn as furniture and
/// answering nothing. (The one place a chrome cell could reach the desktop was a single pixel band
/// at the picture's far edge, where `Viewport.contains(pixel:)` is inclusive — which this change
/// closes for chrome rows, because `chromeOwns` now says yes there.) There was no hover and no
/// pressed state at all. The first two tests here measure the dead-cell half on a frame.
///
/// The rest pins the shape the issue asked for, in the order it matters:
///
/// 1. **The router is a function of the table.** For every cell of a frame, `route` must answer the
///    *topmost* widget the drawer registered there (or the row's background), never something else —
///    and, the other direction, no glyph may be painted on a chrome row outside every widget.
/// 2. **One shape of a control.** No cell is claimed by two widgets with different ids, and every
///    widget in the table is reachable — a control drawn is a control hit.
/// 3. **A disabled control is inert**: it does not route to itself, does not hover, does not press.
/// 4. **It is cheap and it re-sends no picture**: a hover repaint far under 600 B (and still under
///    it on a 400-column pane), the menu under 6 KB, and no kitty graphics APC anywhere in the
///    chrome's bytes (`docs/design-ui-v2` §5).
/// 5. **A press is visible before its effect** — the reader's order, the driver's order, and the
///    drawer's, each on its own.
final class ChromeWidgetTableTests: XCTestCase {
    // MARK: - fixtures

    private func metrics(cols: Int = 120, scale: Double = 1.0) -> ChromeMetrics {
        var m = ChromeMetrics()
        m.version = "test"
        m.target = "window 128444"
        m.title = "Terminal — admin — scroll.sh"
        m.clock = "20:07:17"
        m.fps = 18
        m.fpsTarget = 20
        m.mbps = 1.8
        m.scale = scale
        m.capMs = 42
        m.e2eMs = 61
        m.rttAvailable = true
        m.rttMs = 38
        m.quality = 80
        m.qualityLabel = "5-6-5"
        return m
    }

    /// The pane shapes the chrome is drawn in, each with a frame the drawer actually paints.
    private typealias Frame = (name: String, geometry: ChromeGeometry, state: ChromeState,
                               metrics: ChromeMetrics)

    private func frames() -> [Frame] {
        func one(_ name: String, cols: Int, rows: Int, bar: Bool, dev: Bool,
                 panel: ChromePanel?, scale: Double = 1.0) -> Frame {
            let picture = Chrome.pictureRows(paneRows: rows, bar: bar, panel: panel, chrome: dev)
            let geo = Chrome.layout(paneCols: cols, paneRows: rows, imageCols: cols,
                                    imageRows: (bar ? 1 : 0) + picture, bar: bar, dev: dev,
                                    panel: panel)
            return (name, geo, ChromeState(panel: panel), metrics(scale: scale))
        }
        return [
            one("bar+dev", cols: 120, rows: 30, bar: true, dev: true, panel: nil),
            one("bar+dev+menu", cols: 120, rows: 30, bar: true, dev: true, panel: .menu),
            one("bar only + menu", cols: 100, rows: 30, bar: true, dev: false, panel: .menu),
            one("dev only + stats", cols: 100, rows: 32, bar: false, dev: true, panel: .stats),
            one("scaled (the readout is drawn)", cols: 120, rows: 30, bar: true, dev: true,
                panel: nil, scale: 0.5),
            one("narrow", cols: 24, rows: 12, bar: true, dev: false, panel: nil),
        ]
    }

    private func drawn(_ frame: Frame) -> Chrome {
        let chrome = Chrome()
        _ = chrome.draw(geometry: frame.geometry, metrics: frame.metrics, state: frame.state)
        return chrome
    }

    /// What the table says a cell should answer — the router's whole rule, spelled out here so the
    /// test is a second opinion and not a call into the code it is checking.
    private func expected(_ widget: ChromeWidget?, chromeRow: Bool) -> ChromeRoute {
        guard let widget else { return chromeRow ? .background : .picture }
        switch widget.role {
        case .control: return widget.disabled ? .background : .widget(widget.id)
        case .panel: return .panel
        case .furniture: return .background
        }
    }

    /// Let the main queue run: every seam here hops (the reader is on its own thread), so a test
    /// that skipped the hop would pass on a version where nothing happened.
    private func drainMainQueue() {
        let drained = expectation(description: "the main queue has run everything queued so far")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    /// A chrome row: the bar, or anything at or below where the picture ends.
    private func isChromeRow(_ y: Int, _ geo: ChromeGeometry) -> Bool {
        y == geo.barRow || y >= geo.chromeTop
    }

    private func hasGraphicsAPC(_ bytes: [UInt8]) -> Bool {
        stride(from: 0, to: max(0, bytes.count - 2), by: 1)
            .contains { bytes[$0] == 0x1B && bytes[$0 + 1] == 0x5F && bytes[$0 + 2] == 0x47 }
    }

    private func utf8(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    /// Every cell, in 0-based cells, where the frame painted **something other than a blank** — read
    /// out of the bytes a terminal would replay, not out of the drawer's own bookkeeping.
    ///
    /// This is the second opinion the table cannot give itself: a glyph on a chrome row that belongs
    /// to no widget is exactly the "drawn but not hit-testable" cell the issue was filed for, and a
    /// test that asks the table where its widgets are would never see it.
    private func inkedCells(_ bytes: [UInt8], cols: Int, rows: Int) -> [(row: Int, col: Int)] {
        var out: [(row: Int, col: Int)] = []
        let text = Array(String(decoding: bytes, as: UTF8.self))
        var row = 0, col = 0, i = 0
        while i < text.count {
            if text[i] == "\u{1B}", i + 1 < text.count, text[i + 1] == "[" {
                var j = i + 2
                var params = ""
                while j < text.count, !text[j].isLetter {
                    params.append(text[j])
                    j += 1
                }
                if j < text.count, text[j] == "H" {
                    let parts = params.split(separator: ";").compactMap { Int($0) }
                    if parts.count == 2 { row = parts[0] - 1; col = parts[1] - 1 }
                }
                i = j + 1
                continue
            }
            let width = DisplayWidth.of(text[i])
            if text[i] != " " { out.append((row, col)) }
            col += max(1, width)
            i += 1
        }
        return out
    }

    // MARK: - 0. the gap this closes (the red half)

    /// The drawer paints the *whole* bar row as the window's own furniture — a reversed fill, three
    /// dots, the title, the numbers and two buttons — and on the base every cell of it that carried
    /// no id answered "the picture". A cell a reader can see as furniture is a cell the chrome owns:
    /// it must answer the chrome, not the picture, whether or not it carries a control.
    func testNoCellTheBarPaintsBelongsToThePicture() {
        let geo = Chrome.layout(paneCols: 120, paneRows: 30, imageCols: 120, imageRows: 28,
                                bar: true, dev: true, panel: nil)
        let chrome = Chrome()
        _ = chrome.draw(geometry: geo, metrics: metrics(), state: ChromeState())
        var picture: [Int] = []
        for col in 1...geo.cols where chrome.route(row: 1, col: col, geometry: geo) == .picture {
            picture.append(col)
        }
        XCTAssertEqual(picture, [], "the bar row is furniture end to end; cols \(picture) answer .picture")
    }

    /// The same rule for the status line: the separators between the segments, the clock at the
    /// right edge and the toast all paint on a chrome row, so none of them is the picture either —
    /// on the base each of them was a dead cell that answered nothing at all.
    func testNoCellTheStatusLinePaintsBelongsToThePicture() {
        let geo = Chrome.layout(paneCols: 120, paneRows: 30, imageCols: 120, imageRows: 28,
                                bar: false, dev: true, panel: nil)
        let chrome = Chrome()
        var state = ChromeState()
        state.toast = "^\\ then ? for keys"
        _ = chrome.draw(geometry: geo, metrics: metrics(), state: state)
        var picture: [Int] = []
        for col in 1...geo.cols
        where chrome.route(row: geo.statusRow + 1, col: col, geometry: geo) == .picture {
            picture.append(col)
        }
        XCTAssertEqual(picture, [], "the status row is furniture end to end; cols \(picture) answer .picture")
    }

    // MARK: - 1. the router is a function of the table

    /// For every cell of every frame: the answer must be the *topmost* widget the drawer registered
    /// there — the last one drawn, which is how a tick inside the menu's box wins over the box — or
    /// the row's background, or (above the picture) the picture. Nothing else is an answer.
    func testEveryCellAnswersTheWidgetTheDrawerDrewThere() {
        for frame in frames() {
            let chrome = drawn(frame)
            let geo = frame.geometry
            var mismatches: [String] = []
            for y in 0..<geo.rows {
                for x in 0..<geo.cols {
                    let top = chrome.widgets.last { $0.rect.contains(row: y, col: x) }
                    let want = expected(top, chromeRow: isChromeRow(y, geo))
                    let got = chrome.route(row: y + 1, col: x + 1, geometry: geo)
                    if got != want {
                        mismatches.append("row \(y + 1) col \(x + 1): \(got) != \(want) "
                                          + "(topmost \(top?.id ?? "-"))")
                    }
                }
            }
            XCTAssertEqual(mismatches.prefix(6), [], "\(frame.name): \(mismatches.count) cells disagree "
                           + "with the table the drawer built")
        }
    }

    /// A cell drawn twice as two different things is the failure the issue names: two copies of the
    /// same arithmetic `DisplayWidth` apart. Only one nesting is legal — a control inside an open
    /// panel's box — and the control wins because it was drawn last.
    func testNoCellIsClaimedByTwoControls() {
        for frame in frames() {
            let chrome = drawn(frame)
            var clashes: [String] = []
            for (i, a) in chrome.widgets.enumerated() {
                for b in chrome.widgets[(i + 1)...] where a.id != b.id {
                    guard a.rect.intersects(b.rect) else { continue }
                    // The one legal overlap: a control drawn on a panel's box (or on the bar).
                    if case .panel = a.role { continue }
                    if case .panel = b.role { continue }
                    clashes.append("\(a.id) ⊓ \(b.id)")
                }
            }
            XCTAssertEqual(clashes.prefix(6), [], "\(frame.name): two controls claim the same cell: "
                           + "\(clashes.count)")
        }
    }

    /// Every widget in the table is reachable: draw one, and some cell of its rect answers it. A
    /// widget nobody can reach is a control that looks live and is not (and on the base it was the
    /// other way round: cells that looked live and were not controls).
    func testEveryWidgetTheTableHoldsIsReachable() {
        for frame in frames() {
            let chrome = drawn(frame)
            let geo = frame.geometry
            var reached: Set<String> = []
            for y in 0..<geo.rows {
                for x in 0..<geo.cols {
                    if case .widget(let id) = chrome.route(row: y + 1, col: x + 1, geometry: geo) {
                        reached.insert(id)
                    }
                }
            }
            // Only *controls* are in this set: a panel's box is a container (its cells answer
            // `.panel`, asserted below), and furniture is not a control at all.
            let controls = Set(chrome.widgets.filter { widget in
                guard case .control = widget.role else { return false }
                return !widget.disabled
            }.map(\.id))
            XCTAssertEqual(reached, controls, "\(frame.name): drawn controls \(controls.sorted()) "
                           + "vs reachable \(reached.sorted())")
            // …and at least one cell per widget, not just one id overall: a control whose own rect
            // answers a *neighbour* would pass the set comparison above.
            for w in chrome.widgets where !w.disabled {
                let cells = (w.rect.row..<(w.rect.row + w.rect.height)).flatMap { y in
                    (w.rect.col..<(w.rect.col + w.rect.width)).map { x in (y, x) }
                }
                let answer = cells.map { chrome.route(row: $0.0 + 1, col: $0.1 + 1, geometry: geo) }
                switch w.role {
                case .control:
                    XCTAssertTrue(answer.contains(.widget(w.id)),
                                  "\(frame.name): \(w.id) at \(w.rect) answers \(answer) — never itself")
                case .panel:
                    XCTAssertTrue(answer.contains(.panel),
                                  "\(frame.name): the box at \(w.rect) answers \(answer) — not the panel")
                case .furniture:
                    continue
                }
            }
        }
    }

    /// The other direction of the same invariant, and the one the table cannot check about itself:
    /// **nothing the drawer paints on a chrome row lies outside the table.** Walk the frame's own
    /// bytes, take every cell that carries a glyph, and require a widget whose rect holds it. The
    /// two deliberate fills (`draw`'s clearing and the bar's reversed background) write blanks and
    /// are therefore not ink — they are the row's background, which `route` answers by row.
    func testNoGlyphOnAChromeRowIsPaintedOutsideTheTable() {
        for frame in frames() {
            let chrome = Chrome()
            let bytes = chrome.draw(geometry: frame.geometry, metrics: frame.metrics,
                                    state: frame.state)
            let geo = frame.geometry
            var orphans: [String] = []
            for (y, x) in inkedCells(bytes, cols: geo.cols, rows: geo.rows) where isChromeRow(y, geo) {
                if !chrome.widgets.contains(where: { $0.rect.contains(row: y, col: x) }) {
                    orphans.append("row \(y + 1) col \(x + 1)")
                }
            }
            XCTAssertEqual(Array(orphans.prefix(6)), [],
                           "\(frame.name): \(orphans.count) glyphs on a chrome row belong to no widget")
        }
    }

    // MARK: - 2. hover / pressed / disabled

    private func barFrame(cols: Int = 120, rows: Int = 30) -> (ChromeGeometry, ChromeMetrics) {
        let geo = Chrome.layout(paneCols: cols, paneRows: rows, imageCols: cols, imageRows: rows - 1,
                                bar: true, dev: false, panel: nil)
        return (geo, metrics())
    }

    /// One frame of the chrome, then the same frame with a different pointer: the bytes that answer
    /// a pointer are the difference between the two draws, which is exactly what `writeChrome` sends.
    private func pointerBytes(_ from: ChromeState, _ to: ChromeState, geometry: ChromeGeometry,
                              metrics m: ChromeMetrics) -> [UInt8] {
        let chrome = Chrome()
        _ = chrome.draw(geometry: geometry, metrics: m, state: from)
        return chrome.draw(geometry: geometry, metrics: m, state: to)
    }

    func testAHoverRepaintStaysInsideItsBudget() {
        let (geo, m) = barFrame()
        var out = ChromeState()
        var onMenu = ChromeState()
        onMenu.pointer = Pointer(over: "menu")
        var onShrink = ChromeState()
        onShrink.pointer = Pointer(over: "shrink")
        let enter = pointerBytes(out, onMenu, geometry: geo, metrics: m)
        let across = pointerBytes(onMenu, onShrink, geometry: geo, metrics: m)
        let leave = pointerBytes(onShrink, out, geometry: geo, metrics: m)
        print("hover bytes: enter \(enter.count) B, across \(across.count) B, leave \(leave.count) B")
        for (name, bytes) in [("enter", enter), ("across", across), ("leave", leave)] {
            XCTAssertFalse(bytes.isEmpty, "\(name): a hover that emits nothing is not a hover")
            // The plan's ceiling is 600 B; these are one control's own cells (a segment, a button),
            // so the real figure is a few dozen bytes. Pin something tight enough that a widened
            // target — a title sucked into the highlight, a whole row repainted — fails here.
            XCTAssertLessThan(bytes.count, 200, "\(name): \(bytes.count) B is not one control's cells")
            XCTAssertLessThan(bytes.count, 600, "\(name): \(bytes.count) B is over the 600 B budget")
            XCTAssertFalse(hasGraphicsAPC(bytes), "\(name): a hover re-sent a picture")
        }
        // …and moving *inside* one control costs nothing at all: same pointer, nothing changed.
        XCTAssertEqual(pointerBytes(onMenu, onMenu, geometry: geo, metrics: m).count, 0)
    }

    /// The highlight is the *control's* cells, not the row's: a bar on a 400-column pane has a very
    /// long title, and a hover that swept it in would put the budget in the hands of whoever named
    /// the window. The title is a readout (`furniture`), and this is the test that keeps it one.
    func testAWideBarDoesNotGrowTheHover() {
        let (geo, m) = barFrame(cols: 400, rows: 20)
        var out = ChromeState()
        var onShrink = ChromeState()
        onShrink.pointer = Pointer(over: "shrink")
        let enter = pointerBytes(out, onShrink, geometry: geo, metrics: m)
        print("hover bytes on a 400-column bar: \(enter.count) B")
        XCTAssertFalse(enter.isEmpty)
        XCTAssertLessThan(enter.count, 200, "\(enter.count) B: the title is in the highlight")
        // …and a cell of the title is furniture, not a control.
        let chrome = Chrome()
        _ = chrome.draw(geometry: geo, metrics: m, state: out)
        let title = chrome.widgets.first { $0.id == "title" }
        if let title {
            XCTAssertEqual(chrome.route(row: title.rect.row + 1, col: title.rect.col + 1, geometry: geo),
                           .background, "a window's name is not a button")
        }
    }

    /// A press has to be visible: it is the only feedback there is before the action it belongs to
    /// lands (a panel opening, or the window shrinking back into the wall).
    func testAPressIsDrawnDifferentlyFromAHover() {
        let (geo, m) = barFrame()
        var hover = ChromeState()
        hover.pointer = Pointer(over: "menu")
        var pressed = ChromeState()
        pressed.pointer = Pointer(over: "menu", down: true)
        let toHover = pointerBytes(ChromeState(), hover, geometry: geo, metrics: m)
        let toPressed = pointerBytes(hover, pressed, geometry: geo, metrics: m)
        print("press bytes: \(toPressed.count) B")
        XCTAssertFalse(toPressed.isEmpty, "a press that looks like the hover is a click with no feedback")
        XCTAssertNotEqual(utf8(toHover), utf8(toPressed))
        XCTAssertLessThan(toPressed.count, 600, "\(toPressed.count) B is over the hover budget")
        XCTAssertFalse(hasGraphicsAPC(toPressed), "a press re-sent a picture")
        XCTAssertEqual(pointerBytes(pressed, pressed, geometry: geo, metrics: m).count, 0,
                       "an unchanged press is not a repaint")
    }

    /// The `scale` readout is the one control the table draws and disables: it names a number
    /// nothing can change from here, so it is not clickable — and the difference between "a readout"
    /// and "a control that does nothing when clicked" is exactly `disabled`.
    func testADisabledControlNeitherHoversNorPressesNorRoutes() {
        let geo = Chrome.layout(paneCols: 120, paneRows: 30, imageCols: 120, imageRows: 28,
                                bar: true, dev: true, panel: nil)
        let m = metrics(scale: 0.5)
        let chrome = Chrome()
        _ = chrome.draw(geometry: geo, metrics: m, state: ChromeState())
        guard let scale = chrome.widgets.first(where: { $0.id == "scale" }) else {
            return XCTFail("the scale readout was not drawn at scale 0.5: \(chrome.widgets.map(\.id))")
        }
        XCTAssertTrue(scale.disabled, "the scale readout is drawn but has no action: it is disabled")
        XCTAssertEqual(chrome.widgets.filter(\.disabled).map(\.id), ["scale"],
                       "exactly one control is disabled today")
        // It does not route to itself…
        for y in scale.rect.row..<(scale.rect.row + scale.rect.height) {
            for x in scale.rect.col..<(scale.rect.col + scale.rect.width) {
                XCTAssertEqual(chrome.route(row: y + 1, col: x + 1, geometry: geo), .background,
                               "row \(y) col \(x) is the disabled readout and must not be forwarded")
            }
        }
        // …it does not hover, and it does not press.
        var hovering = ChromeState()
        hovering.pointer = Pointer(over: "scale")
        var pressing = ChromeState()
        pressing.pointer = Pointer(over: "scale", down: true)
        XCTAssertEqual(pointerBytes(ChromeState(), hovering, geometry: geo, metrics: m), [],
                       "a disabled control must not answer the pointer")
        XCTAssertEqual(pointerBytes(ChromeState(), pressing, geometry: geo, metrics: m), [])
        // …and a click on it is "nothing there": the click path asks the table and gets a widget
        // it must skip. It used to be an id `chromeClick` had no case for, which is the same
        // nothing only by accident — the next control added with an id in the wrong column would
        // have been inert too, silently.
        XCTAssertEqual(chrome.widget(row: scale.rect.row + 1, col: scale.rect.col + 1,
                                     geometry: geo)?.disabled, true,
                       "the click path must be told it is disabled, not handed it as a control")
    }

    // MARK: - 3. budgets

    /// Opening the menu is a text-layer repaint: `< 6 KB` (the plan's §5), and not one picture byte.
    /// The frame is measured from an invalidated drawer, which is what the layout change a panel
    /// causes does (`Chrome.invalidate` in `applyLayout`).
    func testTheMenuCostsLessThanItsBudget() {
        let rows = 30, cols = 120
        let closedRows = Chrome.pictureRows(paneRows: rows, bar: true, panel: nil, chrome: false)
        let openRows = Chrome.pictureRows(paneRows: rows, bar: true, panel: .menu, chrome: false)
        let closed = Chrome.layout(paneCols: cols, paneRows: rows, imageCols: cols,
                                   imageRows: 1 + closedRows, bar: true, dev: false, panel: nil)
        let open = Chrome.layout(paneCols: cols, paneRows: rows, imageCols: cols,
                                 imageRows: 1 + openRows, bar: true, dev: false, panel: .menu)
        let chrome = Chrome()
        _ = chrome.draw(geometry: closed, metrics: metrics(), state: ChromeState())
        // The relayout invalidates the drawer (it re-fits the picture), so the paint that follows is
        // a whole-chrome one — the expensive case, not the cheap one.
        chrome.invalidate()
        let bytes = chrome.draw(geometry: open, metrics: metrics(), state: ChromeState(panel: .menu))
        print("menu open bytes: \(bytes.count) B on a \(cols)x\(rows) pane")
        XCTAssertFalse(bytes.isEmpty)
        XCTAssertTrue(utf8(bytes).contains("╭"), "the menu's box is what those bytes are")
        XCTAssertLessThan(bytes.count, 6 * 1024, "\(bytes.count) B is over the 6 KB menu budget")
        XCTAssertFalse(hasGraphicsAPC(bytes), "the menu is a text layer: it must not re-send a picture")
    }

    // MARK: - 4. a press is visible before its effect

    /// The reader's half: it reports the pointer *before* it routes the event, so a press arrives
    /// as down on its way to the click (this is the order the wall's hover already relies on).
    func testTheReaderReportsThePointerBeforeTheClick() {
        TermGeometry.lastGrid = (cols: 120, rows: 30)
        let reader = InputReader(viewport: {
            Viewport(pixelWidth: 960, pixelHeight: 480, cols: 120, rows: 30, sourceRect: .zero)
        }, onQuit: {})
        var order: [String] = []
        reader.onChromeHover = { _, _, down in order.append("hover down=\(down)") }
        reader.chromeOwns = { _, _ in true }
        reader.onChromeClick = { _, _, _ in order.append("click") }
        reader.handleMouse(MouseReport(button: 0, x: 110, y: 1, isWheel: false, isRelease: false,
                                       isMotion: false, mods: []))
        XCTAssertEqual(order, ["hover down=true", "click"],
                       "the press must be reported before the click it becomes")
    }

    /// The seam the product actually installs, driven end to end. `installChromeSeams` is the only
    /// wiring between the reader and this class (it is what `startInput` installs), so it is asked
    /// here instead of having a test write the two closures again: a mouse report goes in at
    /// `InputReader.handleMouse` and the pointer and the bytes come out the other side. Nothing but
    /// the terminal is stubbed.
    func testTheInstalledSeamMovesThePointerAndRepaints() {
        var options = Options()
        options.wall = false
        options.dev = false          // a handed-over mirror: the bar only
        options.bar = true
        options.mock = true
        let desk = Desk(options: options)
        let rows = 30, cols = 120
        let geo = Chrome.layout(paneCols: cols, paneRows: rows, imageCols: cols,
                                imageRows: rows - 1, bar: true, dev: false, panel: nil)
        let m = metrics()
        desk.chromeGeometry = geo
        desk.chromeMetrics = m
        var chunks: [[UInt8]] = []
        desk.writer.sink = { chunks.append($0) }
        desk.drawChrome()
        chunks.removeAll()

        let probe = Chrome()
        _ = probe.draw(geometry: geo, metrics: m, state: ChromeState())
        guard let menu = probe.widgets.first(where: { $0.id == "menu" }) else {
            return XCTFail("the bar drew no menu button: \(probe.widgets.map(\.id))")
        }
        let row = menu.rect.row + 1, col = menu.rect.col + 1

        TermGeometry.lastGrid = (cols: cols, rows: rows)
        // `dryRun`: this test is about the routing, and a bare motion report is a real
        // `mouseMoved` for the desktop once the chrome has passed on it.
        let reader = InputReader(viewport: {
            Viewport(pixelWidth: 960, pixelHeight: 480, cols: cols, rows: rows, sourceRect: .zero)
        }, dryRun: true, onQuit: {})
        desk.installChromeSeams(reader)

        func move(row: Int, col: Int) {
            reader.handleMouse(MouseReport(button: 3, x: col, y: row, isWheel: false,
                                           isRelease: false, isMotion: true, mods: []))
            drainMainQueue()
        }

        move(row: row, col: col)
        XCTAssertEqual(desk.chromeState.pointer, Pointer(over: "menu"),
                       "the seam did not reach the chrome")
        XCTAssertEqual(chunks.count, 1, "a pointer that moved onto a control is one paint")
        XCTAssertFalse(chunks.first?.isEmpty ?? true)

        // The same cell again: the answer did not change, so nothing goes out.
        move(row: row, col: col)
        XCTAssertEqual(chunks.count, 1, "a pointer that did not move is not a repaint")

        // Off the bar, onto the picture: the pointer clears, and the chrome says so once.
        move(row: 20, col: 5)
        XCTAssertNil(desk.chromeState.pointer.over, "the pointer left the chrome")
        XCTAssertEqual(chunks.count, 2)
    }

    /// The driver's half: a press is painted, and only then does the action it belongs to run. The
    /// three writes are the product's (`drawChrome`, `chromeHover`, `chromeClick`), and the geometry
    /// is what `applyLayout` would compute for the open menu — a `Desk` with no capturer never
    /// re-lays out, so the fixture is the relayout the product performs, not a stand-in for it.
    func testAClickPaintsItsPressBeforeItOpensThePanel() {
        var options = Options()
        options.wall = false
        options.dev = false          // a handed-over mirror: the bar and no `--dev` line
        options.bar = true
        options.mock = true
        let desk = Desk(options: options)

        let rows = 30, cols = 120
        let picture = Chrome.pictureRows(paneRows: rows, bar: true, panel: .menu, chrome: false)
        let geo = Chrome.layout(paneCols: cols, paneRows: rows, imageCols: cols,
                                imageRows: 1 + picture, bar: true, dev: false, panel: .menu)
        let m = metrics()
        desk.chromeGeometry = geo
        desk.chromeMetrics = m
        XCTAssertNil(desk.chromeState.panel, "the menu starts closed")
        var chunks: [[UInt8]] = []
        desk.writer.sink = { chunks.append($0) }

        // Where `[ ≡ ]` is, asked of the drawer rather than written down here: the bar's arithmetic
        // is the drawer's business, and a second copy of it in a test is the bug this issue is about.
        let probe = Chrome()
        _ = probe.draw(geometry: geo, metrics: m, state: ChromeState())
        guard let menu = probe.widgets.first(where: { $0.id == "menu" }) else {
            return XCTFail("the bar drew no menu button: \(probe.widgets.map(\.id))")
        }
        let row = menu.rect.row + 1, col = menu.rect.col + 1

        desk.drawChrome()                       // the frame the reader is looking at
        // The click on its own: no pointer report first, so the only thing that can put the press
        // on screen is the click's own job (`performChrome`). A test that hovered first would be
        // satisfied by the hover's paint and would pass even if the click painted the panel first.
        desk.chromeClick(row: row, col: col, wheel: 0)
        drainMainQueue()

        XCTAssertGreaterThanOrEqual(chunks.count, 3, "rest, press, panel: \(chunks.map(\.count))")
        let press = utf8(chunks[1])
        XCTAssertTrue(press.contains("\u{1B}[7;1;36m"),
                      "the press is the bar button's accent fill: \(press.debugDescription)")
        XCTAssertFalse(press.contains("╭"),
                       "the press is painted *before* the panel it opens, not with it")
        let panel = utf8(chunks[2])
        XCTAssertTrue(panel.contains("╭"), "the panel's box is the paint that follows: \(panel.debugDescription)")
        XCTAssertTrue(panel.contains("a click sets it"), "…with the menu's own rows in it")
    }

    // MARK: - 5. one pointer shape for both surfaces

    /// The wall's pointer and the chrome's are the same type, with a different target: `WallPointer`
    /// is a `Pointer<WallState.Focus>` now, and the chrome's is a `Pointer<String>`. Two copies of
    /// "what am I over, is it pressed" is what the issue forbids.
    func testTheChromeAndTheWallShareOnePointerType() {
        let wall: Pointer<WallState.Focus> = WallPointer(over: .window(0), down: true)
        XCTAssertEqual(wall.pressed, .window(0), "a press is the target under a down button")
        XCTAssertEqual(wall.shape, .pointer, "and the target is what asks for a hand")
        XCTAssertEqual(WallPointer().shape, .default)
        let chrome: Pointer<String> = Pointer(over: "menu")
        XCTAssertNil(chrome.pressed, "no button down, no press")
        XCTAssertEqual(chrome.shape, .pointer)
        XCTAssertEqual(ChromeState(panel: .menu).hover, nil, "the chrome's hover starts empty")
    }
}
