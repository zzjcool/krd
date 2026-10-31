/// The row budget, the two scroll bars and the hit table of the landing screen (`--wall`).
///
/// Pure geometry: no AppKit, no CoreGraphics, no strings, no I/O, no clocks. Everything that
/// decides *where* something is lives here, so the painter (`WallCanvas`) only has to render into
/// the rectangles this file hands out, and the click router only has to look one cell up in
/// `action(row:col:)`. Both of those can then be tested without a screen.
///
/// ## The row budget (design §6.5)
///
/// 1-based, top to bottom, `stageH` rows of stage and `cardH` picture rows of cards:
///
///     row 1                       header
///     row 2          … +stageH    the stage — one display, the full content width
///     row 2+stageH                the stage caption — exactly 1 row
///     row 3+stageH                the "recent" band header
///     row 4+stageH   … +cardH     the card section — a page of `per` x `cardRowCount`
///     row 4+stageH+cardH          cards, each its picture's height, its caption under it
///     row 5+stageH+cardH          one blank row
///     row 6+stageH+cardH          the footer == the last pane row
///
/// `cardH == 0` means "no card band at all": the card rows vanish and `footerRow == 5 + stageH`.
/// The rows are placed with a cursor instead of by adding the constants up, because the constants
/// only hold while every band fits. A 6-row pane has no room for a card band, and a cursor that
/// skips the band keeps the caption and the footer on distinct rows rather than stacking them.
/// The constants above are what the tests pin for normal panes.
///
/// `cardH` is the *picture* rows the band gives; the section owns one caption row more, and the
/// page's cards fill as many rows of it as fit (`cardRowCount`). See `make(…)` for why the band's
/// spare height is spent on more rows of previews instead of on empty wall.
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
    case cardStep(Int)     // ±capacity: one page (design §5 — a page of cards is one step)
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
    /// This page only: `min(capacity, windowCount - cardStart)` rects, none when there is no room.
    public let cards: [CellRect]
    /// Parallel to `cards`, exactly one row each.
    public let cardCaptions: [CellRect]
    /// The last pane row.
    public let footerRow: Int
    /// **Cards per row** — the reader's number. It may be smaller than the requested one on a
    /// narrow pane, where a card narrower than `minCardCols` is not drawn at all.
    public let per: Int
    /// Rows of cards on a page: how many rows of `per` the band fits. `0` when the band is dropped.
    public let cardRowCount: Int
    /// **Cards per page** = `per x cardRowCount`: what one step of the shelf moves by, what the
    /// bar's lower segment shows as visible, and the width of its thumb's track.
    public let capacity: Int
    /// Cells between two neighbouring cards on this pane (`cardGap(content)`).
    public let cardGap: Int
    /// The rows the card *section* owns, which is not `cards[0].rows * count`: a card is as tall as
    /// its picture needs, several rows of them share the band, and the rest of the band stays empty
    /// wall (§6.5's 7:3 split still holds, the footer is still the last row).
    public let cardBandRows: Int
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
            /// Items on screen at once: 1 for the stage, `capacity` for the cards.
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
            /// one cell is too small to hit"). With exactly one shaft cell the thumb goes in that
            /// cell for *every* `start`: a single cell can say "somewhere in this track", not
            /// *where*, so the click on it has to agree — see `jumpTarget` (issue #135).
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
            ///
            /// A shaft of **at most one cell** cannot invert anything: every `start` shares that
            /// cell, so an offset cannot single out a page, and the only position left to name is
            /// the one the thumb is drawn for — the reader's own. The click is then a no-op (the
            /// state clamps it back to the same start, and the text layer's per-cell diff writes
            /// nothing). It used to answer `0`, which turned the one live shaft cell of a 3-row
            /// segment into a "go to the first page" button that looked like "you are here"
            /// (issue #135).
            public func jumpTarget(shaftOffset: Int) -> Int {
                guard maxStart > 0 else { return 0 }
                // `make` already clamps `start` into 0...maxStart; the clamp keeps this function's
                // range contract independent of the caller.
                guard shaftCount >= 2 else { return max(0, min(maxStart, start)) }
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
    ///   - per: **cards per row.** The reader's number; the layout only lowers it when a card would be
    ///     narrower than `minCardCols`. One page is `per x cardRowCount` cards (`capacity`).
    ///   - stageAspect: the stage picture's own width/height, when the caller knows it. A tall pane's
    ///     budget gives the stage more rows than a 16:10 picture can use, and the band used to keep
    ///     them: the picture was fitted inside a band 11 rows taller than itself, which reads as "the
    ///     display is smaller than its frame". With the aspect here the band is what the picture
    ///     needs and the card section takes the rest (more rows of the same previews, `cardRowCount`).
    ///     `nil` keeps the old row split, which is what the fixed layout table in the tests pins.
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
        // the rows it does not need go to the card section - which spends them on more rows of
        // previews rather than on empty wall (see `cardRowCount` below). Without this a 137x73 pane
        // gave the stage 53 rows for a 42-row picture and the 11 rows showed up as wall between the
        // caption and the divider.
        if let stageAspect, stageAspect > 0, stageAspect.isFinite, cardH > 0 {
            let needed = max(minStageRows,
                             Int((Double(content) / (cellAspect * stageAspect)).rounded()))
            if needed < stageH {
                let freed = stageH - needed
                stageH = needed
                cardH += freed
                // `per` is the reader's number, and it stays: a tall band used to trade the third
                // card for two larger ones ("窗口的预览可以再小一点…一排可以显示三个窗口"), which is
                // the opposite of what a shelf of small previews wants. The band keeps its row
                // width and the rows the stage hands back buy more *rows* of the same previews.
            }
        }
        let perPage = max(1, perEff)
        let firstStage = Self.clamp(stageStart, 0, max(0, displays - 1))

        // **A page is `per` cards per row and as many rows as the band fits** (issue #83). The 7:3
        // split was agreed and stays, and the band it gives is taller than one row of previews: the
        // 118x73 pane's band is 29 picture rows for a 12-row preview, so 17 of its 30 rows were
        // empty wall under a footer that still sat on the last row ("下方窗口太高了"). A preview's
        // height comes from its slot width (`cardAspect`), so the spare height cannot make it bigger
        // without changing the slot - it buys another row of the same previews instead.
        let slotW = max(1, cardWidth(content, perPage, gap: gap))
        let cardRows = max(minCardRows,
                           min(cardH, Int((Double(slotW) / (cardAspect * cellAspect)).rounded())))
        // A row of cards is its picture plus the caption directly under it (§6.6), and the section
        // owns `cardH` picture rows plus one caption row, so one row needs `cardRows + 1` of them
        // and `(cardH + 1) / (cardRows + 1)` fit.
        let cardRowCount = cardH > 0 ? max(1, (cardH + 1) / (cardRows + 1)) : 0
        // `max(1, …)`: a dropped band draws no card, and a zero here would make the bar's track look
        // infinitely scrollable to anyone who forgot the rect is empty. The row width is the least
        // surprising answer, and it is what the band header prints.
        let capacity = perPage * max(1, cardRowCount)
        let firstCard = Self.clamp(cardStart, 0, max(0, windows - capacity))
        let pageCount = max(0, min(capacity, windows - firstCard))

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
            // **A card is one slot of `per`, whatever the page holds, and a page is as many rows of
            // those slots as the band fits.** A page of one used to blow its card up to the whole
            // band - a 115x29 box around an 11-row picture - and the review asked for the opposite:
            // small previews, three to a row ("窗口的预览可以再小一点…很小的一个图片就可以了，一排
            // 可以显示三个窗口"). Each row of cards is centred in the band, so a page of one sits in
            // the middle instead of hugging the left edge, and a partial last row is centred the
            // same way (§6.7).
            //
            // A card is as tall as its picture needs, not as tall as the band: the caption belongs
            // directly under the picture (§6.6). `cardAspect * cellAspect` turns the slot's width
            // into rows; the band caps it, `minCardRows` floors it.
            //
            // The stack of rows is centred in the band too, and the section's leftover rows are
            // split above and below it rather than pooled under the last row - a band that paints
            // two rows of previews and then 4 empty rows still reads as "too tall". An odd leftover
            // row goes to the bottom, the way every layout here rounds (§6.7).
            let sectionRows = cardH + 1                 // picture rows + the caption row of a row
            let usedRows = cardRowCount * (cardRows + 1)
            let top = cardsTop + max(0, (sectionRows - usedRows) / 2)
            for i in 0..<pageCount {
                let rowIndex = i / perPage, colIndex = i % perPage
                let inRow = min(perPage, pageCount - rowIndex * perPage)
                let rowW = inRow * slotW + max(0, inRow - 1) * gap
                let col = 1 + max(0, (content - rowW) / 2) + colIndex * (slotW + gap)
                let rowTop = top + rowIndex * (cardRows + 1)
                cards.append(clip(col: col, row: rowTop, width: slotW, height: cardRows))
                cardCaptions.append(clip(col: col, row: rowTop + cardRows, width: slotW, height: 1))
            }
            // The band keeps its rows in the row accounting even when the cards are shorter than
            // it: the footer is the pane's last row (§6.5), and a shelf of small previews must not
            // pull it up into the middle of the wall. What the cards do not use stays empty wall.
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
                count: windows, start: firstCard, visible: capacity)
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
            per: perPage,
            cardRowCount: cardRowCount,
            capacity: capacity,
            cardGap: gap,
            cardBandRows: cardH,
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
    /// while a wheel is a continuous gesture and a page per notch overshoots: a page of six cards per
    /// notch makes a trackpad flick jump from the first window to the last.
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
        // The whole section scrolls, not one row of it: the previews are a grid now, and the blank
        // band rows above and below the stack (the centring) and the caption rows between the rows
        // of pictures are all "the shelf" to a reader aiming at it. The section's last row is the
        // bar segment's `maxRow + 1` when the band exists - the band header is `bandRow` above it.
        if !bar.cards.rect.isEmpty, row >= bar.cards.rect.row, row <= bar.cards.rect.maxRow + 1 {
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
        let step = max(1, capacity)
        return segmentAction(bar.cards, row: row,
                             up: .cardStep(-step), down: .cardStep(step),
                             jump: { .cardJump($0) })
    }

    /// Top row = one step back, bottom row = one step forward, the shaft = jump to the position
    /// under the cursor (a one-cell shaft can only hold the one it is showing, so that jump is a
    /// no-op — `jumpTarget`). Fewer than 2 rows (the arrows would be the same cell) or nothing to
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
