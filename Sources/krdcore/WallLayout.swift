/// The row budget, the two scroll bars and the hit table of the landing screen (`--wall`).
///
/// Pure geometry: no AppKit, no CoreGraphics, no strings, no I/O, no clocks. Everything that
/// decides *where* something is lives here, so the painter (`WallCanvas`) only has to render into
/// the rectangles this file hands out, and the click router only has to look one cell up in
/// `action(row:col:)`. Both of those can then be tested without a screen.
///
/// ## The row budget (design §6.5)
///
/// 1-based, top to bottom, `stageH` rows of stage and `cardH` rows of cards:
///
///     row 1                       header
///     row 2          … +stageH    the stage — one display, the full content width
///     row 2+stageH                the stage caption — exactly 1 row
///     row 3+stageH                the "recent" band header
///     row 4+stageH   … +cardH     the cards — one page of `per`, `winW` cells each
///     row 4+stageH+cardH          the card captions — exactly 1 row each
///     row 5+stageH+cardH          one blank row
///     row 6+stageH+cardH          the footer == the last pane row
///
/// `cardH == 0` means "no card band at all": the card rows vanish and `footerRow == 5 + stageH`.
/// The rows are placed with a cursor instead of by adding the constants up, because the constants
/// only hold while every band fits. A 6-row pane has no room for a card band, and a cursor that
/// skips the band keeps the caption and the footer on distinct rows rather than stacking them.
/// The constants above are what the tests pin for normal panes.
///
/// ## Why the scroll bar is two segments (design §6)
///
/// The top segment always scrolls the displays, the bottom one always scrolls the windows, so
/// "scroll the windows" is always the same place on screen: the target does not move when the
/// stage changes height or when a display appears. Two segments rather than one track because the
/// two stacks have separate lengths and separate positions — a single bar would have to rescale
/// both halves every time either count changed, and a click would land on a different thing than
/// the last time.
///
/// ## The final cell of the final row is never ours
///
/// The bar is one cell wide and exactly as tall as its band, and every band ends at least two rows
/// above the last row (the blank row and the footer). That is not cosmetic: writing the final cell
/// of the final row arms the terminal's pending-wrap, and the next byte scrolls the whole grid,
/// which puts a kitty placement one row off (`Chrome.swift` invariant 3 and `render(from:)`). So
/// no rectangle in this file may contain `(rows, cols)` — asserted for every pane size in
/// `WallLayoutTests`.
///
/// ## Never a negative size
///
/// Every `Int` below goes through `max(0, …)` or `max(1, …)`. A hostile pane size (0 columns, 3
/// rows, `per: 0`) has to produce a layout that is merely useless, not one that traps: the caller
/// is a resize handler, and a trap there leaves the terminal in the alternate screen.

/// A whole-cell rectangle. 1-based, the same coordinates the writer positions the cursor with.
public struct CellRect: Equatable {
    public let col, row, cols, rows: Int

    public init(col: Int, row: Int, cols: Int, rows: Int) {
        self.col = col
        self.row = row
        self.cols = cols
        self.rows = rows
    }

    /// An empty rect is how "this band does not exist in this pane" is spelled, so a consumer asks
    /// one question instead of unwrapping an `Int?` at every call site.
    public var isEmpty: Bool { cols <= 0 || rows <= 0 }

    public var maxRow: Int { row + rows - 1 }

    public var maxCol: Int { col + cols - 1 }

    /// Empty rects contain nothing: a zero-row band must not swallow the row it starts on, or a
    /// click on the band header would enter a card that is not drawn.
    public func contains(row r: Int, col c: Int) -> Bool {
        if isEmpty { return false }
        return r >= row && r <= maxRow && c >= self.col && c <= maxCol
    }

    public func intersects(_ other: CellRect) -> Bool {
        if isEmpty || other.isEmpty { return false }
        return self.col <= other.maxCol && other.col <= maxCol
            && self.row <= other.maxRow && other.row <= maxRow
    }
}

/// What a cell belongs to, before the click policy is applied. Kept separate from `WallAction` so
/// "this cell is card 2" and "clicking it enters window 5" stay independently testable.
public enum WallSlot: Equatable {
    case stage(Int)   // always 0: there is exactly one stage on screen
    case card(Int)    // index within the current page
}

/// What a click does. Payloads are already resolved: a `.enterCard` carries the index into the
/// whole window list, not the page slot, so the receiver never has to redo the arithmetic.
public enum WallAction: Equatable {
    case enterStage(Int)   // payload = display index, already clamped to 0..<displayCount
    case enterCard(Int)    // payload = index into the window list, already clamped
    case stageStep(Int)    // ±1
    case cardStep(Int)     // ±per: one page (design §5 — a page of cards is one step)
    case cardJump(Int)     // payload = the index that becomes the first card of the page
    case stageJump(Int)    // payload = the display that becomes the visible one
    case back              // the footer row
}

public struct WallLayout: Equatable {
    public let cols, rows: Int
    /// Content width: the bar takes the last column and one blank column keeps text off it.
    public let contentCols: Int
    /// The bar column — always the last one.
    public let barCol: Int
    public let headerRow: Int
    public let stage: CellRect
    /// Exactly one row, directly under `stage` (empty only in a pane too short to have one).
    public let stageCaption: CellRect
    /// The one-row rule between the stage block and the card section (design §6.5).
    public let dividerRow: CellRect
    /// The "recent" band header row, always present.
    public let bandRow: Int
    /// This page only: `min(per, windowCount - cardStart)` rects, none when there is no room.
    public let cards: [CellRect]
    /// Parallel to `cards`, exactly one row each.
    public let cardCaptions: [CellRect]
    /// The last pane row.
    public let footerRow: Int
    /// The effective per — may be smaller than the requested one on a narrow pane.
    public let per: Int
    /// Cells between two neighbouring cards on this pane (`cardGap(content)`).
    public let cardGap: Int
    public let stageStart: Int
    public let cardStart: Int
    public let displayCount: Int
    public let windowCount: Int
    public let bar: WallBar

    /// The two segments of the right-hand bar.
    public struct WallBar: Equatable {
        /// Always scrolls the displays.
        public let stage: Segment
        /// Always scrolls the windows.
        public let cards: Segment

        public struct Segment: Equatable {
            public let rect: CellRect
            /// Items in the track.
            public let count: Int
            /// The first visible item.
            public let start: Int
            /// Items on screen at once: 1 for the stage, `per` for the cards.
            public let visible: Int

            /// A track that already shows everything has nothing to scroll. Such a segment is
            /// drawn dim and answers nothing (design §5: no dead cells the user can click).
            public var scrollable: Bool { count > visible }

            public var maxStart: Int { max(0, count - visible) }

            /// The cells between the two arrows — the only place a thumb can go. Zero when the
            /// segment is 2 rows tall (arrows only) or empty.
            private var shaftCount: Int { max(0, rect.rows - 2) }

            /// Where the thumb is drawn, or nil when this segment cannot show a position.
            /// Two arrows plus at least one thumb row is the minimum (design §6: "no `◀ ▶`,
            /// one cell is too small to hit").
            public func thumbRow() -> Int? {
                guard scrollable, rect.rows >= 3, shaftCount >= 1 else { return nil }
                if shaftCount == 1 { return rect.row + 1 }
                let t = Double(start) / Double(maxStart)
                return rect.row + 1 + Int((t * Double(shaftCount - 1)).rounded())
            }

            /// The inverse of `thumbRow()`: clicking shaft cell `offset` (0-based, from the top of
            /// the shaft) makes `jumpTarget` the new start. Exact whenever the shaft has at least
            /// as many cells as there are positions; with fewer cells several starts share one
            /// thumb cell and the nearest one wins.
            public func jumpTarget(shaftOffset: Int) -> Int {
                guard maxStart > 0, shaftCount >= 2 else { return 0 }
                let offset = max(0, min(shaftCount - 1, shaftOffset))
                let t = Double(offset) / Double(shaftCount - 1)
                return max(0, min(maxStart, Int((t * Double(maxStart)).rounded())))
            }
        }
    }

    /// The floors below which a band is not drawn at all (design §6.5: "rather one card fewer than
    /// an 8-cell-wide thumbnail", and a 2-row stage is a line of text, not a picture).
    public static let minCardRows = 3
    public static let minStageRows = 3
    public static let minCardCols = 8
    /// Width / height of a card (design §6.5).
    public static let cardAspect = 1.62
    /// Cells are twice as tall as they are wide — the geometry the 14-row card at 44 cells was
    /// measured with. `cardAspect * cellAspect` turns a width in cells into a height in rows.
    public static let cellAspect = 2.0

    // MARK: build

    /// - Parameters:
    ///   - stageAspect: the stage picture's own width/height, when the caller knows it. A tall pane's
    ///     budget gives the stage more rows than a 16:10 picture can use, and the band used to keep
    ///     them: the picture was fitted inside a band 11 rows taller than itself, which reads as "the
    ///     display is smaller than its frame". With the aspect here the band is what the picture
    ///     needs and the cards take the rest (widened, so their pictures grow too). `nil` keeps the
    ///     old row split, which is what the fixed layout table in the tests pins.
    ///   - cellAspect: `cellH / cellW`, i.e. how many cell-heights one column is worth. Measured from
    ///     the terminal where it answers (`CSI 16t`); the constant 2.0 is the 8x16 cell.
    public static func make(paneCols: Int, paneRows: Int, displayCount: Int, windowCount: Int,
                            per: Int, stageStart: Int, cardStart: Int,
                            stageAspect: Double? = nil,
                            cellAspect: Double = WallLayout.cellAspect) -> WallLayout {
        let cols = max(1, paneCols)
        let rows = max(1, paneRows)
        let displays = max(0, displayCount)
        let windows = max(0, windowCount)

        let content = max(1, cols - 2)

        // Narrower than a readable card? Show one card fewer (design §6.5). The loop stops at 1,
        // so even a 1-column pane gets a (1-cell) card instead of none.
        let gap = cardGap(content)
        var perEff = max(1, per)
        while perEff > 1 && cardWidth(content, perEff, gap: gap) < minCardCols { perEff -= 1 }
        let winW = max(1, cardWidth(content, perEff, gap: gap))

        // The fixed rows: header, stage caption, (divider), band header, blank, footer.
        //
        // The divider is one dim rule between the stage block and the card section. Without it the
        // caption, the band header and the tops of the cards arrive as three dense rows in a row -
        // the review's words were "too crowded" - and a rule is cheaper than a blank row: it says
        // where one section ends instead of just wasting the line.
        //
        // It is also the first thing dropped. In a pane this short a row of rule is worth less than
        // a row of picture, and nothing below depends on it existing: `dividerRow` is empty and the
        // painter draws nothing.
        let wantsDivider = rows >= 20
        let budget = max(0, rows - (wantsDivider ? 6 : 5))
        // **Seven rows of display to three rows of shelf** (design §6.5, his rule: "上面桌面 7,
        // 下面窗口 3"). The stage is the hero of this screen, and the old split gave it whatever the
        // cards did not want: on a 240x44 pane that was 14 rows for the display against 23 for the
        // cards, so the desktop arrived as a small picture in the middle of an empty wall. The card
        // band's own caption row is counted inside its three parts, and a band that cannot reach
        // `minCardRows` is dropped - its rows go to the stage rather than showing a 2-row strip.
        var stageH: Int
        var cardH: Int
        if windows == 0 {
            // Nothing to put in the band: the full budget goes to the stage instead of leaving an
            // empty strip that reads like a layout bug.
            stageH = max(0, budget)
            cardH = 0
        } else {
            stageH = max(minStageRows, Int((Double(budget) * 0.7).rounded()))
            stageH = min(stageH, budget)
            cardH = budget - stageH - 1   // -1 is the card caption row
            if cardH < minCardRows {
                // no in-between: an undrawable band is no band
                cardH = 0
                stageH = budget
            }
        }
        // The stage band is what its picture needs, not what the budget happens to leave over, and
        // the rows it does not need go to the cards - which are widened so their pictures grow into
        // them instead of gaining empty margin (`per` is an upper bound: a tall pane shows fewer,
        // larger cards). Without this a 137x73 pane gave the stage 53 rows for a 42-row picture and
        // the 11 rows showed up as wall between the caption and the divider.
        var effectivePer = perEff
        var effectiveWinW = winW
        if let stageAspect, stageAspect > 0, stageAspect.isFinite, cardH > 0 {
            let needed = max(minStageRows,
                             Int((Double(content) / (cellAspect * stageAspect)).rounded()))
            if needed < stageH {
                let freed = stageH - needed
                stageH = needed
                cardH += freed
                // A card as wide as the taller band is high, then as many of those as fit a page:
                // `per` is a maximum, so a tall pane trades the third card for two larger ones
                // instead of giving the third card 11 rows of empty band around its picture.
                let idealWidth = max(minCardCols,
                                     Int((Double(cardH) * cardAspect * cellAspect).rounded()))
                let fitting = max(1, Int((Double(content + gap) / Double(idealWidth + gap)).rounded()))
                let widest = max(1, min(effectivePer, fitting))
                let widthForPage = max(minCardCols, cardWidth(content, widest, gap: gap))
                if widthForPage > effectiveWinW {
                    effectivePer = widest
                    effectiveWinW = widthForPage
                }
            }
        }
        let perPage = max(1, effectivePer)
        let firstStage = Self.clamp(stageStart, 0, max(0, displays - 1))
        let firstCard = Self.clamp(cardStart, 0, max(0, windows - perPage))
        let pageCount = max(0, min(perPage, windows - firstCard))

        /// Clamp a band into the pane. Normal panes never move: the budget above is chosen so that
        /// the footer lands exactly on the last row. Only a pane too small for the fixed rows (or
        /// for `per` cards) reaches the clips, and clipping beats a rect pointing outside the pane.
        /// A band that would still reach the final cell of the final row loses that cell: a
        /// 1-column pane has nowhere else to put its content, and the cell is never ours to write
        /// (pending-wrap). The renderer stops at the same cell — this just makes the geometry say
        /// what the renderer does.
        func clip(col c0: Int, row r0: Int, width w: Int, height h: Int) -> CellRect {
            if c0 > cols || r0 > rows {
                return CellRect(col: max(1, min(c0, cols)), row: max(1, min(r0, rows)), cols: 0, rows: 0)
            }
            let c = max(1, c0), r = max(1, r0)
            var rect = CellRect(col: c, row: r,
                                cols: max(0, min(w, cols - c + 1)),
                                rows: max(0, min(h, rows - r + 1)))
            if rect.contains(row: rows, col: cols) {
                rect = CellRect(col: rect.col, row: rect.row, cols: rect.cols - 1, rows: rect.rows)
            }
            return rect
        }

        var row = 1                              // cursor: the next free row
        let headerRow = row
        row += 1

        let stage = clip(col: 1, row: row, width: content, height: stageH)
        row += stageH

        let stageCaption = clip(col: 1, row: row, width: content, height: 1)
        row += 1

        let dividerRow: CellRect
        if wantsDivider {
            dividerRow = clip(col: 1, row: row, width: content, height: 1)
            row += 1
        } else {
            dividerRow = CellRect(col: 1, row: row, cols: 0, rows: 0)
        }

        let bandRow = row
        row += 1

        // Where the card band would start: the bar's lower segment sits on exactly these rows even
        // when the band is dropped (then it has 0 rows and does not exist).
        let cardsTop = row
        var cards: [CellRect] = []
        var cardCaptions: [CellRect] = []
        if cardH > 0 {
            for i in 0..<pageCount {
                let col = 1 + i * (effectiveWinW + gap)
                cards.append(clip(col: col, row: cardsTop, width: effectiveWinW, height: cardH))
                cardCaptions.append(clip(col: col, row: cardsTop + cardH, width: effectiveWinW, height: 1))
            }
            row += cardH + 1
        }

        // The blank row is not drawn by anyone; it exists so the bar's lower `▼` never lands on the
        // footer row and never on the final cell of the final row.
        row += 1
        let footerRow = min(rows, row)

        let bar = WallBar(
            stage: WallBar.Segment(
                rect: clip(col: cols, row: stage.row, width: 1, height: stage.rows),
                count: displays, start: firstStage, visible: 1),
            cards: WallBar.Segment(
                rect: clip(col: cols, row: cardsTop, width: 1, height: cardH),
                count: windows, start: firstCard, visible: perPage)
        )

        return WallLayout(
            cols: cols, rows: rows,
            contentCols: content,
            barCol: cols,
            headerRow: headerRow,
            stage: stage,
            stageCaption: stageCaption,
            dividerRow: dividerRow,
            bandRow: bandRow,
            cards: cards,
            cardCaptions: cardCaptions,
            footerRow: footerRow,
            per: effectivePer,
            cardGap: gap,
            stageStart: firstStage,
            cardStart: firstCard,
            displayCount: displays,
            windowCount: windows,
            bar: bar
        )
    }

    /// `floor((content - (n - 1) * gap) / n)`: the cards share the content width with `gap` cells
    /// between neighbours and are all the same width (design §6.5: 137 cols / 3 -> 43).
    private static func cardWidth(_ content: Int, _ n: Int, gap: Int) -> Int {
        guard n > 0 else { return 0 }
        return (content - (n - 1) * gap) / n
    }

    /// Cells between two neighbouring cards: one cell was the first version and read as the cards
    /// touching ("窗口的间距可以再大点" in review). It scales with the pane rather than being a
    /// constant, because air is only free where there is width to spend: on 137 columns a 3-cell gap
    /// still leaves every card 43 cells - the same 14 rows as before, so it costs nothing - while on
    /// 60 columns a 3-cell gap is a fifth of a 13-cell card and would drop `per` from 4 to 3 to pay
    /// for it.
    static func cardGap(_ content: Int) -> Int { max(1, content / 45) }

    private static func clamp(_ value: Int, _ lo: Int, _ hi: Int) -> Int {
        min(max(value, lo), max(lo, hi))
    }

    // MARK: hit test

    /// The band a cell belongs to. The bar is not a slot: it scrolls instead of entering.
    public func slot(row: Int, col: Int) -> WallSlot? {
        if stage.contains(row: row, col: col) || stageCaption.contains(row: row, col: col) {
            return .stage(0)
        }
        if let i = cards.firstIndex(where: { $0.contains(row: row, col: col) }) {
            return .card(i)
        }
        if let i = cardCaptions.firstIndex(where: { $0.contains(row: row, col: col) }) {
            return .card(i)
        }
        return nil
    }

    /// The click table. Cards and captions both enter their item (design §1: "点图或点说明都进入"),
    /// the bar's arrows step, its shaft jumps, the footer goes back, and everything else — header,
    /// band, blank row, the gap column, the caps, a segment with nothing to scroll — is nil, i.e.
    /// swallowed by the wall rather than forwarded to the remote desktop.
    public func action(row: Int, col: Int) -> WallAction? {
        // The bar is checked first: it owns the last column, and `barAction` decides which of its
        // rows are live, so a cap row or the footer row can never fall through to a
        // neighbouring band.
        if col == barCol { return barAction(row: row) }
        if let slot = slot(row: row, col: col) {
            switch slot {
            case .stage: return .enterStage(stageStart)
            case .card(let i): return .enterCard(cardStart + i)
            }
        }
        if row == footerRow { return .back }
        return nil
    }

    /// A wheel notch over a cell: one display or one card, decided by which band the row is in.
    ///
    /// One at a time, not a page. The bar's `▲`/`▼` are a click and therefore a page (design §5),
    /// while a wheel is a continuous gesture and a page per notch overshoots: three cards per notch
    /// make a trackpad flick jump from the first window to the last.
    ///
    /// `nil` for a shelf with nothing to scroll - including the bar's own segments, which is why
    /// the column is taken: the bar's rows are shared with the band it points at, so the column is
    /// what tells "I aimed at the bar" from "I aimed at the cards".
    public func wheelAction(row: Int, col: Int, direction: Int) -> WallAction? {
        guard direction != 0 else { return nil }
        let step = direction > 0 ? 1 : -1
        let canScrollStage = bar.stage.count > bar.stage.visible
        let canScrollCards = bar.cards.count > bar.cards.visible
        let onBar = col == barCol

        if row >= stage.row, row <= stage.maxRow { return canScrollStage ? .stageStep(step) : nil }
        if row == stageCaption.row { return canScrollStage ? .stageStep(step) : nil }
        if onBar, !bar.stage.rect.isEmpty, row == bar.stage.rect.row || row == bar.stage.rect.maxRow {
            return canScrollStage ? .stageStep(step) : nil
        }
        if onBar, !bar.cards.rect.isEmpty, row >= bar.cards.rect.row, row <= bar.cards.rect.maxRow {
            return canScrollCards ? .cardStep(step) : nil
        }
        if row == bandRow { return canScrollCards ? .cardStep(step) : nil }
        if let first = cards.first, row >= first.row, row < first.row + first.rows {
            return canScrollCards ? .cardStep(step) : nil
        }
        if let caption = cardCaptions.first, row == caption.row {
            return canScrollCards ? .cardStep(step) : nil
        }
        return nil
    }

    /// Stage first, then cards — the segments never share a row, so the order is arbitrary but
    /// deterministic.
    private func barAction(row: Int) -> WallAction? {
        if let a = segmentAction(bar.stage, row: row,
                                 up: .stageStep(-1), down: .stageStep(1),
                                 jump: { .stageJump($0) }) {
            return a
        }
        return segmentAction(bar.cards, row: row,
                             up: .cardStep(-per), down: .cardStep(per),
                             jump: { .cardJump($0) })
    }

    /// Top row = one step back, bottom row = one step forward, the shaft = jump to the position
    /// under the cursor. Fewer than 2 rows (the arrows would be the same cell) or nothing to
    /// scroll (`scrollable == false`) means the whole segment is dead, caps included — that is
    /// what makes the grey `▲`/`▼` honestly grey (design §5).
    private func segmentAction(_ segment: WallBar.Segment, row: Int,
                               up: WallAction, down: WallAction,
                               jump: (Int) -> WallAction) -> WallAction? {
        guard segment.scrollable, segment.rect.rows >= 2 else { return nil }
        guard row >= segment.rect.row, row <= segment.rect.maxRow else { return nil }
        if row == segment.rect.row { return up }
        if row == segment.rect.maxRow { return down }
        return jump(segment.jumpTarget(shaftOffset: row - segment.rect.row - 1))
    }
}
