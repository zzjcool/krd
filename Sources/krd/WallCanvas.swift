import krdcore

/// The `--wall` glyph table, and the reason there are two of it.
///
/// `▲ ▣ ⤢ ⬅ ╷ ╵` are East-Asian-Ambiguous: a terminal configured for CJK draws them two cells
/// wide, which slides every column after them right and would silently break the bar — the bar is
/// one column wide and `WallLayout.barCol` is the column a click on it maps to. `--symbols ascii`
/// is the escape hatch for those terminals.
///
/// Every glyph in **both** tables is one cell in `DisplayWidth` (§6.5: "both modes must lay out the
/// same columns"), so switching modes changes the picture without moving a single cell. `WallCanvasTests`
/// asserts the width of every glyph below and that the two modes render the same column count at
/// both golden geometries.
///
/// `display` is U+1F5A5 **without** the VS16 presentation selector on purpose: `DisplayWidth` counts
/// a VS16 as two cells (it is a presentation change, and a terminal may widen the glyph), so `🖥️`
/// would be three cells and push the whole stage caption off by two.
enum WallSymbols: String, CaseIterable {
    case emoji, ascii

    /// `nil` for anything that is not exactly one of the two names, case-insensitively. The
    /// caller (`main.swift`) turns that into `krd: --symbols wants emoji|ascii, got "…"` and
    /// `exit(2)`: a typo must not silently pick a mode and produce a wall the user did not ask for.
    init?(spec: String) {
        switch spec.lowercased() {
        case "emoji": self = .emoji
        case "ascii": self = .ascii
        default: return nil
        }
    }

    var bullet: String { self == .emoji ? "▪" : "*" }
    var display: String { self == .emoji ? "🖥" : "D" }
    var window: String { self == .emoji ? "▣" : "w" }
    var up: String { self == .emoji ? "▲" : "^" }
    var down: String { self == .emoji ? "▼" : "v" }
    var shaft: String { self == .emoji ? "│" : "|" }
    var thumb: String { self == .emoji ? "█" : "#" }
    var perButton: String { self == .emoji ? "⤢" : ">" }
    var back: String { self == .emoji ? "⬅" : "<" }
    var capTop: String { self == .emoji ? "╷" : "." }
    var capBottom: String { self == .emoji ? "╵" : "'" }
    /// A separator, not a glyph: the spaces are part of it (they are what keeps the two sides of
    /// "7 windows · 3 displays" from touching when a title ends in a wide character).
    var dot: String { self == .emoji ? " · " : " | " }
    var boxTL: String { self == .emoji ? "┌" : "+" }
    var boxTR: String { self == .emoji ? "┐" : "+" }
    var boxBL: String { self == .emoji ? "└" : "+" }
    var boxBR: String { self == .emoji ? "┘" : "+" }
    var boxH: String { self == .emoji ? "─" : "-" }
    var boxV: String { self == .emoji ? "│" : "|" }
    /// `1452×1050`.
    var times: String { self == .emoji ? "×" : "x" }
    /// The caption separator, `app — title`. East-Asian-Ambiguous on purpose: it is decoration,
    /// and the ascii table exists for exactly this kind of glyph.
    var dash: String { self == .emoji ? "—" : "-" }
    /// The page range, `1–3 / 7`.
    var enDash: String { self == .emoji ? "–" : "-" }
}

/// One display, as the wall shows it: what `NSScreen` knows and what the caption prints.
struct WallDisplay: Equatable {
    var name: String
    var width: Int
    var height: Int
    /// The menu-bar display (design §6.6: it comes first and its caption says so).
    var main: Bool
}

/// Exactly what the painter renders. Both lists are already ordered by `WallSource` (displays:
/// main first then left to right; windows: front to back), so the painter never sorts.
///
/// The empty defaults are load-bearing: the desk starts with `WallModel()` and fills it on the
/// first enumeration, and a first frame inside that window has to draw "no displays · no windows"
/// rather than trap.
struct WallModel: Equatable {
    var displays: [WallDisplay] = []
    var windows: [OrderedWindow] = []
}

/// The wall's cursor: which display is on stage, which page of windows is in the shelf, and
/// whether the user has picked one (the footer then shows the way back).
///
/// Pure state and pure transitions: `apply` is the whole click policy (a `WallAction` in, offsets
/// and focus out), so the routing can be tested with no terminal, no model and no clock. Ids in the
/// payloads are indices into the *whole* list, never page slots — `WallLayout.action` resolves the
/// page arithmetic, so nothing downstream has to repeat it.
struct WallState: Equatable {
    var per: Int = 3
    var stageStart: Int = 0
    var cardStart: Int = 0
    var focus: Focus? = nil

    /// `nil` = looking at the wall itself; otherwise which item the user picked (the phase-1
    /// placeholder for the mirror that P2 starts here).
    enum Focus: Equatable {
        case display(Int)
        case window(Int)
    }

    /// The geometry of the current pane. `WallLayout` does the clamping by itself, so passing in
    /// stale offsets cannot produce a rect pointing at a card that is not there.
    func layout(cols: Int, rows: Int, displays: Int, windows: Int) -> WallLayout {
        WallLayout.make(paneCols: cols, paneRows: rows, displayCount: displays, windowCount: windows,
                        per: per, stageStart: stageStart, cardStart: cardStart)
    }

    /// Pull both offsets back into range after the world changed under the wall (a display
    /// unplugged, a window closed). Called before every draw the model refresh triggers, so a
    /// stale `cardStart` cannot leave the shelf empty while six windows exist.
    mutating func clamp(displays: Int, windows: Int) {
        stageStart = Self.clamp(stageStart, 0, max(0, displays - 1))
        cardStart = Self.clamp(cardStart, 0, max(0, windows - perPage))
    }

    /// The click policy. Every payload is clamped again here even though `WallLayout` already
    /// clamped it: the state outlives the layout, and a pane resize between the click and the
    /// application must not be able to point the focus outside the model.
    mutating func apply(_ action: WallAction, displays: Int, windows: Int) {
        let lastDisplay = max(0, displays - 1)
        let lastPage = max(0, windows - perPage)
        switch action {
        case .enterStage(let i):
            // Entering a display also brings it on stage: the footer's "back" then returns to a
            // stage showing what was picked.
            stageStart = Self.clamp(i, 0, lastDisplay)
            focus = .display(stageStart)
        case .enterCard(let i):
            // The shelf does not move: the page the user was looking at stays where it was.
            focus = .window(Self.clamp(i, 0, max(0, windows - 1)))
        case .stageStep(let d):
            stageStart = Self.clamp(stageStart + d, 0, lastDisplay)
        case .stageJump(let i):
            stageStart = Self.clamp(i, 0, lastDisplay)
        case .cardStep(let d):
            cardStart = Self.clamp(cardStart + d, 0, lastPage)
        case .cardJump(let i):
            cardStart = Self.clamp(i, 0, lastPage)
        case .back:
            focus = nil
        }
    }

    /// One per page even for a hostile `per: 0`, so the clamps never divide by zero or produce a
    /// negative range.
    private var perPage: Int { max(1, per) }

    private static func clamp(_ value: Int, _ lo: Int, _ hi: Int) -> Int {
        min(max(value, lo), max(lo, hi))
    }
}

/// The text painter for `--wall`: a whole-pane cell grid plus a per-cell diff renderer.
///
/// ## The four write invariants
///
/// These are the same four that `Chrome.swift:8-20` states, and they are restated here because
/// they are the only thing that makes the bytes safe — a text write that breaks one of them
/// corrupts the terminal, not just the wall:
///
/// 1. **Every write is positioned** `ESC[row;colH`, and this file never emits `\n`. A newline on
///    the last row scrolls the grid, and a kitty placement is positioned by absolute cell, so a
///    scroll puts the picture one row off.
/// 2. **The final cell of the final row `(rows, cols)` is never written.** Writing it arms the
///    terminal's pending-wrap; the next byte scrolls. `Grid.set` refuses that cell outright and
///    `render` additionally hard-stops a run at `cols - 1` on the last row. The layout already
///    keeps every band two rows above the footer; the guard is what makes that structural
///    property unbreakable from here.
/// 3. **Nothing above row 1.** The clamp is `max(0, …)`, never a negative row.
/// 4. **Per-cell diff against the previous grid.** An unchanged wall emits zero bytes (that is
///    also "0 B/s when nothing moves"); a resize, or `invalidate()`, drops the previous grid and
///    the next draw is a full repaint. Trail of blanks is trimmed and changed cells are merged
///    into runs while they stay contiguous, so a redraw costs one escape per row, not per cell.
///
/// ## Why a second cell grid instead of reusing `Chrome` (contract §5.5)
///
/// `Chrome.render(from:)` is anchored to "the rows below the picture" and is parameterised by
/// `ChromeGeometry`, while the wall owns every row and has no placement at all. Sharing the
/// renderer would mean parameterising `Chrome` in two directions and editing the one file whose
/// byte discipline is already pinned by a golden. So the grid and the renderer are a copy of that
/// discipline (invariants above) and the *style table* is shared instead: `Chrome.Style.sgr`, so
/// the wall and the chrome cannot drift to different colours.
///
/// Everything above the byte layer is "text in a rect": the geometry comes from `WallLayout`, the
/// strings from the templates in the contract, and every truncation and every alignment goes
/// through `DisplayWidth` (CJK and emoji are two cells, and a title is not ours to be trusted).
final class WallCanvas {
    /// One terminal cell. `continuation` marks the second half of a wide glyph: it is never the
    /// start of a run, never trimmed as a trailing blank, and never written on its own.
    private struct Cell: Equatable {
        var ch: Character = " "
        var style: Chrome.Style = .plain
        var continuation = false
    }

    /// The grid being painted. A separate struct rather than methods on the canvas so a full
    /// paint (`build`) cannot accidentally read or write the *previous* grid: the diff is the
    /// only place that knows about it.
    private struct Grid {
        var cells: [Cell]
        let cols: Int
        let rows: Int

        init(cols: Int, rows: Int) {
            self.cols = cols
            self.rows = rows
            cells = [Cell](repeating: Cell(), count: max(0, cols) * max(0, rows))
        }

        /// One cell, 1-based. Out-of-pane writes are dropped instead of clipped, and the final
        /// cell of the final row is never written (invariant 2) — no caller has to remember
        /// either rule, which is the point of putting it here rather than at the call sites.
        mutating func set(row: Int, col: Int, _ ch: Character, _ style: Chrome.Style) {
            guard row >= 1, row <= rows, col >= 1, col <= cols else { return }
            guard !(row == rows && col == cols) else { return }
            let width = DisplayWidth.of(ch)
            if width == 0 { return }                     // a lone combining mark has nothing to attach to
            if width == 2 {
                // A wide glyph needs the cell after it and both must be inside the pane: at the
                // right edge the terminal would clip it and drag the rest of the row left, and on
                // the last row it would land on the cell the terminal reserves for wrap.
                guard col + 1 <= cols, !(row == rows && col + 1 == cols) else { return }
                cells[(row - 1) * cols + (col - 1)] = Cell(ch: ch, style: style)
                cells[(row - 1) * cols + col] = Cell(ch: " ", style: style, continuation: true)
                return
            }
            cells[(row - 1) * cols + (col - 1)] = Cell(ch: ch, style: style)
        }

        /// A run of text from `col`, never wider than `limit` cells and never past the pane.
        /// Returns the cells it used, so a caller can continue on the same row (that is what makes
        /// "label, then a dim range" possible without measuring the label twice).
        @discardableResult
        mutating func text(_ s: String, row: Int, col: Int, _ style: Chrome.Style,
                           limit: Int = .max) -> Int {
            var c = col
            var used = 0
            for ch in s {
                let width = DisplayWidth.of(ch)
                if width == 0 { continue }
                if used + width > limit { break }
                if c + width - 1 > cols { break }
                set(row: row, col: c, ch, style)
                c += width
                used += width
            }
            return used
        }
    }

    private let symbols: WallSymbols
    private var cols = 0
    private var rows = 0
    /// The last grid this canvas emitted, or nil for "repaint everything".
    private var prev: [Cell]?

    init(symbols: WallSymbols = .emoji) {
        self.symbols = symbols
    }

    /// Force a full repaint on the next `draw` — after a resize, or a screen the terminal cleared
    /// under us. Same meaning as `Chrome.invalidate()`.
    func invalidate() { prev = nil }

    // MARK: surface

    /// The paint, as bytes ready for `ScreenWriter.writeChrome`. Never contains `\n`, never ends a
    /// run on `(rows, cols)`, and is empty when nothing changed since the last call.
    func draw(cols: Int, rows: Int, model: WallModel, layout: WallLayout,
              focus: WallState.Focus?) -> [UInt8] {
        let cells = build(cols: cols, rows: rows, model: model, layout: layout, focus: focus)
        return render(cells, cols: cols, rows: rows)
    }

    /// The same cell grid `draw` renders from, one full-width string per row.
    ///
    /// `lines` exists for the tests (and for the "both symbol modes are the same number of
    /// columns" assertion) and is built by the *same* `build`, so it cannot describe a wall the
    /// painter does not draw. It does not touch the diff state: calling it between two draws must
    /// not turn the second draw into a full repaint.
    func lines(cols: Int, rows: Int, model: WallModel, layout: WallLayout,
               focus: WallState.Focus?) -> [String] {
        let cells = build(cols: cols, rows: rows, model: model, layout: layout, focus: focus)
        var out: [String] = []
        out.reserveCapacity(max(0, rows))
        for y in 0..<max(0, rows) {
            out.append(rowString(cells, y, cols: cols))
        }
        return out
    }

    // MARK: painting

    private func build(cols: Int, rows: Int, model: WallModel, layout: WallLayout,
                       focus: WallState.Focus?) -> [Cell] {
        var grid = Grid(cols: cols, rows: rows)
        guard grid.cols > 0, grid.rows > 0 else { return grid.cells }
        // Order matters only where two elements share a row: the footer and the band header draw
        // their left-hand text first and the right-aligned tail second, so the tail always wins the
        // cells it needs if a degenerate pane makes them collide.
        drawHeader(&grid, model: model, layout: layout)
        drawStage(&grid, model: model, layout: layout)
        drawStageCaption(&grid, model: model, layout: layout)
        drawBand(&grid, model: model, layout: layout)
        drawCards(&grid, model: model, layout: layout)
        drawCardCaptions(&grid, model: model, layout: layout)
        drawFooter(&grid, model: model, layout: layout, focus: focus)
        drawBar(&grid, layout: layout)
        return grid.cells
    }

    /// `▪ krd    7 windows · 3 displays · most recently used first`
    ///
    /// The counts come from the model, not from the layout: the layout is geometry and may have
    /// been built for a stale model, while "how many windows are there" is a fact about the data.
    private func drawHeader(_ grid: inout Grid, model: WallModel, layout: WallLayout) {
        let content = min(layout.contentCols, grid.cols)
        let title = "\(symbols.bullet) krd"
        let used = grid.text(title, row: layout.headerRow, col: 1, .bright, limit: content)
        let counts = "    \(model.windows.count) windows\(symbols.dot)\(model.displays.count) displays"
            + "\(symbols.dot)most recently used first"
        grid.text(counts, row: layout.headerRow, col: 1 + used, .dim, limit: max(0, content - used))
    }

    /// The stage. Phase 1 has no picture, so the panel's rectangle is a dim box with the display
    /// centred in it — the contract's stand-in for the §4 mask, deliberately occupying exactly the
    /// rect the picture will occupy in P2, so nothing moves when it appears.
    private func drawStage(_ grid: inout Grid, model: WallModel, layout: WallLayout) {
        let rect = layout.stage
        guard !rect.isEmpty else { return }
        let shown = model.displays.indices.contains(layout.stageStart)
            ? model.displays[layout.stageStart] : nil
        let label = shown.map { "\($0.name) \(symbols.dash) \($0.width)\(symbols.times)\($0.height)" }
            ?? "no display"
        // The middle row is the same expression for a box (any `rows >= 3`) and for the "too short
        // for a box" case, so the label does not move when the pane crosses that threshold.
        let middle = rect.row + (rect.rows - 1) / 2
        if rect.rows >= 3, rect.cols >= 2 {
            drawBox(&grid, rect: rect)
            let inner = max(0, rect.cols - 2)          // inside the two side borders
            let body = DisplayWidth.truncate(label, to: inner)
            let offset = max(0, (inner - DisplayWidth.of(body)) / 2)
            grid.text(body, row: middle, col: rect.col + 1 + offset,
                      shown == nil ? .dim : .bright, limit: max(0, inner - offset))
        } else {
            // Two rows or one: no box (a box needs a top, a bottom and a side), just the label.
            let body = DisplayWidth.truncate(label, to: rect.cols)
            let offset = max(0, (rect.cols - DisplayWidth.of(body)) / 2)
            grid.text(body, row: middle, col: rect.col + offset,
                      shown == nil ? .dim : .bright, limit: max(0, rect.cols - offset))
        }
    }

    /// `🖥 Built-in — 1512×982 · main · 1/3`
    private func drawStageCaption(_ grid: inout Grid, model: WallModel, layout: WallLayout) {
        let rect = layout.stageCaption
        guard !rect.isEmpty else { return }
        let text: String
        if layout.displayCount > 0, model.displays.indices.contains(layout.stageStart) {
            let d = model.displays[layout.stageStart]
            text = "\(symbols.display) \(d.name) \(symbols.dash) \(d.width)\(symbols.times)\(d.height)"
                + (d.main ? "\(symbols.dot)main" : "")
                + "\(symbols.dot)\(layout.stageStart + 1)/\(layout.displayCount)"
        } else {
            text = "\(symbols.display) no displays"
        }
        grid.text(DisplayWidth.truncate(text, to: rect.cols), row: rect.row, col: rect.col, .plain,
                  limit: rect.cols)
    }

    /// `▣ recent    1–3 / 7                                          ⤢ 3`
    private func drawBand(_ grid: inout Grid, model: WallModel, layout: WallLayout) {
        let content = min(layout.contentCols, grid.cols)
        let budget = drawTail(&grid, row: layout.bandRow, content: content,
                              "\(symbols.perButton) \(layout.per)", .dim)
        let range: String
        if layout.windowCount == 0 {
            range = "no windows"
        } else {
            let first = layout.cardStart + 1
            let last = min(layout.cardStart + layout.per, layout.windowCount)
            range = "\(first)\(symbols.enDash)\(last) / \(layout.windowCount)"
        }
        let used = grid.text("\(symbols.window) recent", row: layout.bandRow, col: 1, .plain,
                             limit: budget)
        grid.text("    " + range, row: layout.bandRow, col: 1 + used, .dim,
                  limit: max(0, budget - used))
    }

    /// The card boxes of this page: a dim frame, then (top aligned, only what fits) the app, the
    /// title and the size. `cardH` may be as small as 3, i.e. a single interior row — then only the
    /// app line is drawn, because a box with its second line missing still reads as a panel, while
    /// a squeezed one that overwrites its own border does not.
    private func drawCards(_ grid: inout Grid, model: WallModel, layout: WallLayout) {
        for (slot, rect) in layout.cards.enumerated() {
            guard !rect.isEmpty, rect.rows >= 3, rect.cols >= 2 else { continue }
            let index = layout.cardStart + slot
            guard model.windows.indices.contains(index) else { continue }
            let window = model.windows[index]
            drawBox(&grid, rect: rect)

            let inner = rect.cols - 4              // one blank cell inside each border
            guard inner >= 1 else { continue }
            let col = rect.col + 2
            let last = rect.maxRow - 1              // the row above the bottom border
            var row = rect.row + 1

            grid.text(DisplayWidth.truncate("\(symbols.window) \(window.app)", to: inner),
                      row: row, col: col, .bright, limit: inner)
            row += 1

            if row <= last {
                if let title = wallTitle(window) {
                    grid.text(DisplayWidth.truncate(title, to: inner), row: row, col: col,
                              .plain, limit: inner)
                } else {
                    // No screen-recording grant (or a window without a name) degrades to a
                    // position, which is still a label the user can tell apart (design §3).
                    grid.text(DisplayWidth.truncate("window \(index + 1)", to: inner),
                              row: row, col: col, .dim, limit: inner)
                }
                row += 1
            }

            if row <= last {
                let size = "\(pixels(window.bounds.width))\(symbols.times)"
                    + "\(pixels(window.bounds.height))"
                grid.text(DisplayWidth.truncate(size, to: inner), row: row, col: col, .dim,
                          limit: inner)
            }
        }
    }

    /// `▣ Safari — Apple…` — the same width as its card, so a click on the caption enters the card
    /// right above it (design §1: "点图或点说明都进入").
    private func drawCardCaptions(_ grid: inout Grid, model: WallModel, layout: WallLayout) {
        for (slot, rect) in layout.cardCaptions.enumerated() {
            guard rect.rows == 1, !rect.isEmpty else { continue }
            let index = layout.cardStart + slot
            guard model.windows.indices.contains(index) else { continue }
            let window = model.windows[index]
            let title = wallTitle(window) ?? "window \(index + 1)"
            let text = "\(symbols.window) \(window.app) \(symbols.dash) \(title)"
            grid.text(DisplayWidth.truncate(text, to: rect.cols), row: rect.row, col: rect.col,
                      .plain, limit: rect.cols)
        }
    }

    /// The footer: how many panels there are (right, right-aligned) and what a click does here
    /// (left). After a pick it becomes the way back, which in phase 1 is the whole of "entered".
    private func drawFooter(_ grid: inout Grid, model: WallModel, layout: WallLayout,
                            focus: WallState.Focus?) {
        let content = min(layout.contentCols, grid.cols)
        let budget = drawTail(&grid, row: layout.footerRow, content: content,
                              "\(1 + layout.cards.count) panels", .dim)
        let lead: String
        switch focus {
        case nil:
            lead = "\(symbols.bullet) click a card\(symbols.dot)scroll with the right bar"
        case .display(let i):
            let name = model.displays.indices.contains(i) ? model.displays[i].name : "no display"
            lead = "\(symbols.back) \(symbols.display) back\(symbols.dot)picked \(name)"
                + "\(symbols.dot)the mirror follows in the capture phase"
        case .window(let i):
            let window = model.windows.indices.contains(i) ? model.windows[i] : nil
            let app = window?.app ?? ""
            let title = window.flatMap { wallTitle($0) } ?? "window \(i + 1)"
            lead = "\(symbols.back) \(symbols.display) back\(symbols.dot)picked "
                + "\(app) \(symbols.dash) \(title)"
                + "\(symbols.dot)the mirror follows in the capture phase"
        }
        grid.text(DisplayWidth.truncate(lead, to: budget), row: layout.footerRow, col: 1, .dim,
                  limit: budget)
    }

    /// The bar: two segments, a cap above and below each. The arrows are only drawn when the
    /// segment can actually move — a dead end is dim and inert (design §5), so there is no `▲` that
    /// swallows a click.
    ///
    /// The caps are the three positions §2C enumerates: above the display segment (on the header
    /// row), below it (on the stage caption row), and below the card segment (on the card caption
    /// row; row 0 == "there is no card band", and the grid never writes row 0).
    private func drawBar(_ grid: inout Grid, layout: WallLayout) {
        let col = layout.barCol
        grid.set(row: layout.headerRow, col: col, glyph(symbols.capTop), .dim)
        grid.set(row: layout.stageCaption.row, col: col, glyph(symbols.capBottom), .dim)
        if let first = layout.cardCaptions.first {
            grid.set(row: first.row, col: col, glyph(symbols.capBottom), .dim)
        }
        drawSegment(&grid, layout.bar.stage, barCol: col)
        drawSegment(&grid, layout.bar.cards, barCol: col)
    }

    private func drawSegment(_ grid: inout Grid, _ segment: WallLayout.WallBar.Segment,
                             barCol: Int) {
        let rect = segment.rect
        guard !rect.isEmpty else { return }
        // `rect.rows == 1` can still be `scrollable`: the two arrows would be the same cell, so
        // such a segment draws no arrows at all (and no thumb — a thumb needs three rows).
        let live = segment.scrollable && rect.rows >= 2
        if live {
            for row in (rect.row + 1)..<rect.maxRow {
                grid.set(row: row, col: barCol, glyph(symbols.shaft), .dim)
            }
            grid.set(row: rect.row, col: barCol, glyph(symbols.up), .bright)
            grid.set(row: rect.maxRow, col: barCol, glyph(symbols.down), .bright)
            if let thumb = segment.thumbRow() {
                grid.set(row: thumb, col: barCol, glyph(symbols.thumb), .accent)
            }
        } else {
            // Nothing to scroll: one continuous dim line. Not "arrow glyphs in grey" — a glyph the
            // user cannot act on is a lie about where the bar's live cells are.
            for row in rect.row...rect.maxRow {
                grid.set(row: row, col: barCol, glyph(symbols.shaft), .dim)
            }
        }
    }

    // MARK: primitives

    /// A dim frame filling `rect`. The caller guarantees `rows >= 3 && cols >= 2` (the corners are
    /// the only thing that needs two columns; with exactly two there is no horizontal run).
    private func drawBox(_ grid: inout Grid, rect: CellRect) {
        guard rect.rows >= 3, rect.cols >= 2 else { return }
        let run = String(repeating: symbols.boxH, count: rect.cols - 2)
        grid.text(symbols.boxTL + run + symbols.boxTR, row: rect.row, col: rect.col, .dim,
                  limit: rect.cols)
        for row in (rect.row + 1)..<rect.maxRow {
            grid.set(row: row, col: rect.col, glyph(symbols.boxV), .dim)
            grid.set(row: row, col: rect.maxCol, glyph(symbols.boxV), .dim)
        }
        grid.text(symbols.boxBL + run + symbols.boxBR, row: rect.maxRow, col: rect.col, .dim,
                  limit: rect.cols)
    }

    /// Right-aligned text on `row` inside a `content`-wide band starting at column 1, and the
    /// number of cells the left-hand text may use so the two never touch. Right-aligned counts are
    /// the first thing to give way on a narrow pane, so they are placed first and the left text is
    /// then truncated into what is left.
    @discardableResult
    private func drawTail(_ grid: inout Grid, row: Int, content: Int, _ text: String,
                          _ style: Chrome.Style) -> Int {
        let width = DisplayWidth.of(text)
        let start = 1 + DisplayWidth.rightAlignedStart(text, cells: content)
        grid.text(text, row: row, col: start, style, limit: width)
        return max(0, content - width - 1)
    }

    /// A glyph from the table, as the one `Character` the grid stores. The table only holds
    /// single-cluster strings; the fallback keeps an edited table from trapping in a resize
    /// handler (where a trap would leave the terminal in the alternate screen).
    private func glyph(_ s: String) -> Character { s.first ?? " " }

    /// The window's title, or nil when there is nothing to print. Empty is treated like missing:
    /// `WindowOrder` never produces `""`, but a card must not render a blank second line either way.
    private func wallTitle(_ window: OrderedWindow) -> String? {
        guard let title = window.title, !title.isEmpty else { return nil }
        return title
    }

    /// Bounds are `Double` and come from another process: `Int(1e300)` or `Int(.nan)` traps, and a
    /// trap here would be triggered by a window title's own geometry.
    private func pixels(_ value: Double) -> Int {
        guard value.isFinite, value >= 0 else { return 0 }
        return Int(min(value, 1e9).rounded())
    }

    private func rowString(_ cells: [Cell], _ y: Int, cols: Int) -> String {
        var s = ""
        for x in 0..<max(0, cols) {
            let cell = cells[y * cols + x]
            if cell.continuation { continue }       // the wide glyph before it already covers this cell
            s.append(cell.ch)
        }
        // Exactly `cols` cells is the contract (`lines` is what the tests measure and what the
        // "both modes, same columns" assertion compares). A row *wider* than the pane would be a
        // painter bug and is reported as one rather than papered over here.
        let width = DisplayWidth.of(s)
        if width < cols { s += String(repeating: " ", count: cols - width) }
        return s
    }

    // MARK: diff renderer

    /// Positioned writes for the cells that changed. No newline, no `(rows, cols)`, no row above 1.
    private func render(_ cells: [Cell], cols: Int, rows: Int) -> [UInt8] {
        if cols != self.cols || rows != self.rows {
            // A resize invalidates: the previous grid's indices mean nothing at the new width, so
            // the next paint is a full repaint.
            self.cols = cols
            self.rows = rows
            prev = nil
        }
        let old = prev
        var out: [UInt8] = []
        var style: Chrome.Style?
        for y in 0..<max(0, rows) {
            var x = 0
            while x < cols {
                let idx = y * cols + x
                if cells[idx].continuation { x += 1; continue }
                let changed = old == nil || old!.count != cells.count || old![idx] != cells[idx]
                if !changed { x += 1; continue }
                // Extend the run while the cells stay changed and contiguous; a run is one cursor
                // move plus one SGR change, so leaving a gap closed costs more than reopening.
                var end = x + 1
                while end < cols {
                    let i2 = y * cols + end
                    if cells[i2].continuation { end += 1; continue }
                    if let old, old.count == cells.count, old[i2] == cells[i2] { break }
                    end += 1
                }
                while end > x, cells[y * cols + end - 1].ch == " ",
                      !cells[y * cols + end - 1].continuation {
                    end -= 1                    // trailing blanks are already blank: do not send them
                }
                if y == max(0, rows) - 1 {
                    end = min(end, cols - 1)    // never arm pending-wrap on the final cell
                    if end > x, end < cols, cells[y * cols + end].continuation { end -= 1 }
                }
                if end <= x { x = max(x + 1, end + 1); continue }
                out.append(contentsOf: Array("\u{1B}[\(y + 1);\(x + 1)H".utf8))
                for i in x..<end {
                    let cell = cells[y * cols + i]
                    // The second half of a wide glyph is never sent: the terminal advanced two
                    // cells for the glyph itself, so a space here would land *after* it and shift
                    // the rest of the row right by one per wide glyph (a CJK title would push the
                    // card's own border off its column).
                    if cell.continuation { continue }
                    if style != cell.style {
                        out.append(contentsOf: Array("\u{1B}[\(cell.style.sgr)m".utf8))
                        style = cell.style
                    }
                    out.append(contentsOf: Array(String(cell.ch).utf8))
                }
                x = end
            }
        }
        if !out.isEmpty { out.append(contentsOf: Array("\u{1B}[0m".utf8)) }
        prev = cells
        return out
    }
}

