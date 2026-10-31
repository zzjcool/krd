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
    /// `CGDirectDisplayID`, the id a capture addresses this display by. 0 when nobody filled it in
    /// (a mock, a test): the wall still draws, it just cannot take a picture of that panel.
    var id: UInt32 = 0
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

/// What the text layer draws in a slot that a picture may cover.
///
/// Three states, one rectangle: phase 1's placeholder, nothing at all (a real picture lands there),
/// or the mask (the capture failed). Keeping the rectangle identical in all three is what lets a
/// picture replace a placeholder without the wall moving a cell (design §4).
enum WallSlotPaint: Equatable {
    case placeholder
    case picture
    case mask
}

/// What the pointer is doing on the wall: what it is over, and whether a button is down.
///
/// The wall has no hover of its own — it is drawn as text, and text does not know where the mouse is.
/// This is the value the *input* path computes (`WallState.focus(atRow:col:)`, i.e. the click table)
/// and the painter styles: the target's border in the accent colour, and the same row reversed while
/// the button is down. It deliberately carries nothing about *what a click does* — a pointer is a
/// question, not an action.
struct WallPointer: Equatable {
    /// The item under the pointer, in `WallState.Focus`'s vocabulary: a display (the stage) or a
    /// window (a card or its caption). `nil` is the furniture, which nothing highlights.
    var over: WallState.Focus? = nil
    /// A press that has not been released yet. The wall's only feedback before the mirror opens, so
    /// it has to be visible in one row (`press` is what makes a click feel received).
    var down: Bool = false

    /// The shape the *terminal's* pointer should take while this is the pointer (OSC 22, #202).
    ///
    /// A projection of `over` and of nothing else, which is what makes it a **class** rather than a
    /// per-cell answer: a card and the stage are both "something a click enters", so the hand stays
    /// on across the gap between them and the wall emits nothing. The furniture — the bar's arrows
    /// and shaft, `⤢ N`, the footer, the header, every blank — answers a click too, but it is not a
    /// target (the plan's decision, and why the bar's ends are dimmed), so the terminal keeps its own
    /// pointer there. `down` is not in it either: a press is not a different shape, it is the same
    /// target being pushed (the wall already says so in reverse video).
    ///
    /// `text` has no case to reach: the wall has no text field, so #202 keeps the wall at two shapes
    /// and the third belongs to the mirror's later work.
    var shape: PointerShape { over == nil ? .default : .pointer }
}

/// The paint state of every slot of one frame: the stage, then the cards of the current page.
///
/// A missing entry means `.placeholder`, so a caller that knows nothing about pictures gets exactly
/// the phase-1 wall.
struct WallSlotPaints: Equatable {
    var stage: WallSlotPaint = .placeholder
    var cards: [WallSlotPaint] = []
    /// Something the reader has to know about *this* frame, said in the footer instead of the
    /// click hint. One reason exists today and it is the one that cost the most time to diagnose:
    /// four boxes saying "no picture" are not an answer to "why is my wall empty".
    var notice: WallNotice? = nil
    /// The `--demo` sentence: the numbers this frame was drawn from, in the wall's own words.
    ///
    /// Why it is on screen and not only in the log: the picture's geometry has been the one thing
    /// that could not be checked without a screenshot, and a reader with no screenshot tool can still
    /// read a line of text. "border at half the width" plus "cell 8x16 · pic 688x432 px" is enough to
    /// tell a scaling terminal from a 1:1 one.
    var demoNote: String? = nil
    /// Why a slot shows a mask, in one word, per slot. A mask is the same rectangle for every reason,
    /// so without this "no picture" is all a reader can report - and "no picture" was the question, not
    /// the answer (TROUBLESHOOTING 23b/23c). Empty means the caller did not say, and the mask falls
    /// back to the old wording.
    var maskReasons: [Int: String] = [:]
    /// The cells each card's picture actually occupies, when it has one. A card's box is as wide as
    /// the page shares out; the picture inside it keeps its own aspect and is centred, so it can be
    /// much narrower than the box. Its caption goes under the *picture* - under the box's left edge
    /// it would sit in the empty margin, reading as a label for nothing (design §6.6: one caption
    /// row under each picture, text never under a placement).
    ///
    /// Keyed like `mark(slot:)` and `card(slot:)`: 0 is the stage and 1... are this page's cards in
    /// `layout.cards` order. The painter reads it with a card *index*, so it adds one - mixing the
    /// two conventions put card n's caption under card n-1's picture.
    var cardPictureCells: [Int: CellRect] = [:]

    func pictureCells(_ slot: Int) -> CellRect? { cardPictureCells[slot] }

    func maskReason(_ slot: Int) -> String? { maskReasons[slot] }

    func card(_ slot: Int) -> WallSlotPaint {
        cards.indices.contains(slot) ? cards[slot] : .placeholder
    }

    mutating func mark(slot: Int, _ paint: WallSlotPaint) {
        if slot == 0 {
            stage = paint
        } else {
            while cards.count < slot { cards.append(.placeholder) }
            cards[slot - 1] = paint
        }
    }
}

/// Why a frame has no pictures, in the words the footer has room for.
enum WallNotice: Equatable {
    /// The terminal cannot draw a picture at all: `Terminal.app` has no kitty graphics protocol and
    /// never will (README: "the terminal must speak the kitty graphics protocol"). No grant and no
    /// repaint can help, so the footer names the terminals that can. This is a hard-coded fact about
    /// one terminal rather than a probe - krd does not ask a terminal what it supports, and the
    /// alternative here is an empty wall with no explanation.
    case terminalCannotShowPictures(terminal: String)
    /// Every panel in the frame failed with `denied`: the terminal app krd runs under has not been
    /// granted Screen Recording. `terminal` is `TERM_PROGRAM` when the terminal says (Terminal
    /// writes `Apple_Terminal`), because "grant it to this app" is only actionable with a name.
    case screenRecordingDenied(terminal: String?)
    /// The child mirror krd spawned for a clicked picture exited without doing its job: the code and
    /// whatever it said on stderr. Without this the click looks like a no-op - the pane blinks and
    /// the wall comes straight back - and the reason is only in a log file nobody opens.
    case mirrorStopped(exit: Int32, message: String?)

    /// The footer sentence, ASCII-safe apart from the leading bullet (which the symbol table owns).
    func text(bullet: String, dash: String) -> String {
        switch self {
        case let .terminalCannotShowPictures(terminal):
            return "\(bullet) \(terminal) cannot draw pictures\(dash)use rex, Ghostty, kitty "
                + "or WezTerm"
        case let .screenRecordingDenied(terminal):
            let name = terminal.map { $0 == "Apple_Terminal" ? "Terminal" : $0 } ?? "your terminal"
            return "\(bullet) no picture\(dash)grant Screen Recording to \(name)"
        case let .mirrorStopped(code, message):
            if let message, !message.isEmpty {
                return "\(bullet) the mirror stopped (exit \(code))\(dash)\(message)"
            }
            return "\(bullet) the mirror stopped (exit \(code))"
        }
    }
}

/// One key the wall acts on, in the wall's own vocabulary.
///
/// Deliberately the smallest set that reaches the whole wall (issue #201): `Tab`/`Shift-Tab` walk
/// the stop list `WallLayout.stops()` derives from the click table, the four arrows walk it inside
/// the band the ring is in, `Enter`/`Space` do what a click on the stop does, and `Esc` puts it
/// away. Everything else stays swallowed — a wall has no remote desktop to forward to — and
/// `Ctrl-\` is not in this set at all: it is the *reader's* quit (`WallInput.consumes` hands it
/// back, `InputReader` turns it into `onQuit`), which is the one key a wall still owes the user.
enum WallKey: Equatable {
    /// `Tab`: next stop in reading order, wrapping.
    case next
    /// `Shift-Tab`: the same ring backwards.
    case previous
    /// `Left` / `Up`: the previous stop *inside the current band*.
    case backward
    /// `Right` / `Down`: the next stop inside the current band.
    case forward
    /// `Enter` / `Space`: what a click on this stop does.
    case activate
    /// `Esc`: clear the ring; with no ring, leave the pick (the footer's own cell).
    case cancel
}

/// The wall's whole keyboard policy, in one named place: which bytes mean something
/// (`key(for:)`) and which the reader hands back (`consumes`).
///
/// `consumes` is unchanged from phase 1 and that is the point: the wall still owns every byte it
/// is handed, because there is no remote desktop behind it. What is new is that a handful of them
/// now *do* something before they are dropped.
enum WallInput {
    /// Every key belongs to a remote that does not exist; `Ctrl-\` is the one the reader still owes
    /// the user (it becomes "quit" after this closure returns false). `0x1C` is spelled out rather
    /// than derived from `Keys` because it is a *control byte* here, not a key code: the terminal
    /// sends it as `.control(0x1C)` and `InputReader` reads it as "leave" once the chrome says it
    /// does not own it.
    static func consumes(_ byte: UInt8) -> Bool { byte != 0x1C }

    /// What one parsed key event means to the wall, or `nil` for the ones that mean nothing.
    ///
    /// It lives here rather than in `Input.swift` for the same reason `consumes` does: the wall's
    /// vocabulary is the wall's, and the reader should not grow a second opinion about which keys
    /// a TUI owns. The reader keeps the one job it is good at — knowing what the *terminal* sent
    /// (a legacy `CSI Z`, a kitty report, a bare control byte, a space that arrives as text) — and
    /// this turns that into one of six verbs.
    ///
    /// Only unmodified keys are the wall's, `Shift` excepted on `Tab`:
    /// `Ctrl-Left` is a word step and `Alt-Enter` is a newline — those belong to a desktop, and
    /// the wall must not quietly eat a key it would not act on anyway (the same rule the chrome's
    /// own chord table states).
    static func key(for event: Event) -> WallKey? {
        switch event {
        case let .press(code, mods, phase):
            // A release is not a second press: a wall that acted on one would act twice per key.
            guard phase != .release else { return nil }
            guard mods.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty else {
                return nil
            }
            switch code {
            case Keys.tab: return mods.contains(.maskShift) ? .previous : .next
            case Keys.enter, Keys.space: return .activate
            case Keys.esc: return .cancel
            case Keys.left, Keys.up: return .backward
            case Keys.right, Keys.down: return .forward
            default: return nil
            }
        case let .text(ch, mods):
            // A space is text in the legacy encoding (and a tab in a terminal that reports it
            // that way), which is why the vocabulary is stated for both spellings of a key.
            guard mods.isEmpty else { return nil }
            switch ch {
            case " ", "\r", "\n": return .activate
            case "\t": return .next
            default: return nil
            }
        case let .key(report):
            // The kitty protocol's `CSI code;mods u`: the codes are code points for the keys that
            // are ASCII and Private-Use numbers for the rest, and the arrows arrive through
            // `.press` in every encoding krd parses, so only these four code points are ours.
            guard report.phase != .release else { return nil }
            guard report.mods & 0b1110 == 0 else { return nil }
            switch report.code {
            case 9: return report.mods & 0b1 != 0 ? .previous : .next
            case 13, 32: return .activate
            case 27: return .cancel
            default: return nil
            }
        case let .control(byte):
            switch byte {
            case 0x09: return .next
            case 0x0A, 0x0D, 0x20: return .activate
            case 0x1B: return .cancel
            default: return nil          // `0x1C` included: it is the reader's quit, not a wall key
            }
        default:
            return nil
        }
    }
}

/// The wall's cursor: which display is on stage, which page of windows is in the shelf, and
/// whether the user has picked one (the footer then shows the way back).
///
/// Pure state and pure transitions: `apply` is the whole click policy (a `WallAction` in, offsets
/// and focus out), so the routing can be tested with no terminal, no model and no clock. Ids in the
/// payloads are indices into the *whole* list, never page slots — `WallLayout.action` resolves the
/// page arithmetic, so nothing downstream has to repeat it.
struct WallState: Equatable {
    /// Cards **per row** — the reader's *request*. Where the control is drawn, the band header
    /// prints the width the layout resolved from it (the layout lowers it rather than draw a card under `minCardCols`, until one
    /// card is all that is left), and a click on that glyph sets this to the next width the pane
    /// honours (`WallLayout.perChoices`). The page that resolved width produces is `WallLayout`'s
    /// `capacity`, which also counts the rows of previews the band fits, so the layout decides both;
    /// the band's height is the pane's business and not a setting.
    var per: Int = 3
    var stageStart: Int = 0
    var cardStart: Int = 0
    var focus: Focus? = nil
    /// Where the *keyboard* is: the action a click on the same item or control would perform, or
    /// `nil` while nobody has pressed a key — which is the reason the opening frame is unchanged
    /// (the four goldens in `WallCanvasTests` hold the wall PR #195 left behind).
    ///
    /// One value at a time, and the value is an *action*, not a rectangle: `WallLayout.stops()`
    /// derives the list from the click table, so the ring can only ever sit on something a click
    /// would act on. The hover is `pointer.over` and the pick is `focus`; three questions, three
    /// fields, and no two of them can answer for each other.
    var ring: WallAction? = nil
    /// Where the pointer is, and whether it is down. Not part of `apply`: a click changes what is on
    /// stage, a hover only changes how what is already there is drawn.
    var pointer = WallPointer()

    /// `nil` = looking at the wall itself; otherwise which item the user picked (the phase-1
    /// placeholder for the mirror that P2 starts here).
    enum Focus: Equatable {
        case display(Int)
        case window(Int)
    }

    /// What a click at this cell would act on, in the vocabulary a highlight needs.
    ///
    /// Derived from `WallLayout.action` — the very table the click path runs — rather than from a
    /// second look at the rectangles. A second hit test is how a hover ends up sitting on something
    /// a click would not enter, and the wall already has one table for "what is here"
    /// (`slot`), one for "what does a click do" (`action`), and no appetite for a third.
    ///
    /// `nil` for the furniture: the bar, the band's `⤢ N`, the footer and the margins all *do*
    /// something on a click (a page step, a width cycle, back) and none of them is an item, so
    /// nothing lights up there.
    func focus(atRow row: Int, col: Int, in layout: WallLayout) -> Focus? {
        switch layout.action(row: row, col: col) {
        case let .enterStage(i): return .display(i)
        case let .enterCard(i): return .window(i)
        default: return nil
        }
    }

    /// The geometry of the current pane. `WallLayout` does the clamping by itself, so passing in
    /// stale offsets cannot produce a rect pointing at a card that is not there.
    /// - Parameters:
    ///   - stageAspect: the on-stage display's width/height, when the model has it; the layout then
    ///     gives the stage the rows its picture needs and hands the rest to the cards (WallLayout).
    ///   - cellAspect: `cellH / cellW` from the pane (measured from the terminal when it answers).
    func layout(cols: Int, rows: Int, displays: Int, windows: Int,
                stageAspect: Double? = nil,
                cellAspect: Double = WallLayout.cellAspect) -> WallLayout {
        WallLayout.make(paneCols: cols, paneRows: rows, displayCount: displays, windowCount: windows,
                        per: per, stageStart: stageStart, cardStart: cardStart,
                        stageAspect: stageAspect, cellAspect: cellAspect)
    }

    /// Pull both offsets back into range after the world changed under the wall (a display
    /// unplugged, a window closed). Called before every draw the model refresh triggers, so a
    /// stale `cardStart` cannot leave the shelf empty while six windows exist.
    ///
    /// `capacity` is the **page size** — `WallLayout.capacity`, i.e. how many cards the layout
    /// actually put on one page — not the state's requested `per`, which is a row width now.
    /// Below 28 columns the layout shrinks its page to keep a card readable, and a tall band shows
    /// two or three rows of them, so clamping against `per` would compute a wider page than the one
    /// on screen: `maxStart` would be smaller here than in the layout, so the last window (or the
    /// last five) could not be reached by any click — the bar's shaft cell jumps to the layout's
    /// `maxStart`, this clamp drags it back, and nothing moves. `max(1, capacity)` also keeps a
    /// hostile `capacity: 0` from producing a negative range.
    mutating func clamp(displays: Int, windows: Int, capacity: Int) {
        stageStart = Self.clamp(stageStart, 0, max(0, displays - 1))
        cardStart = Self.clamp(cardStart, 0, max(0, windows - max(1, capacity)))
    }

    /// The click policy. Every payload is clamped again here even though `WallLayout` already
    /// clamped it: the state outlives the layout, and a pane resize between the click and the
    /// application must not be able to point the focus outside the model.
    ///
    /// `capacity` is `WallLayout.capacity` (the page size), for the reason spelled out on `clamp`:
    /// the last page is `windows - capacity`, and "capacity" here and in the layout have to be the
    /// same number or the two disagree about how many cards fit.
    mutating func apply(_ action: WallAction, displays: Int, windows: Int, capacity: Int) {
        let lastDisplay = max(0, displays - 1)
        let lastPage = max(0, windows - max(1, capacity))
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
        case .cyclePer(let n):
            // A new row width, and nothing else: `cardStart` is deliberately left alone. The page
            // size depends on `per` *and* on the rows of previews the band fits, which is the
            // layout's business, so the clamp that matters is `WallLayout.make`'s `firstCard` — and
            // `adopt(_:)` is what writes that answer back, because a click does not re-enumerate the
            // model and so never reaches `refreshWall`'s clamp. The clamp here only keeps a stale or
            // hostile payload inside `1...perCycle.max()`; `make` lowers it further on a pane that
            // honours fewer widths.
            per = Self.clamp(n, 1, WallLayout.perCycle.max() ?? n)
        case .back:
            focus = nil
        }
    }

    private static func clamp(_ value: Int, _ lo: Int, _ hi: Int) -> Int {
        min(max(value, lo), max(lo, hi))
    }

    /// Take the layout's clamp as the state's own, so the offsets in here are exactly the ones on
    /// screen.
    ///
    /// `WallLayout` is the only place that knows how many cards fit — its answer depends on the
    /// band's row count as well as on `per` — so it is the authority on which page exists, and
    /// whoever draws has to write its answer back. That is not pedantry: until `⤢` existed,
    /// `capacity` could only change together with the model or the pane, and both of those send
    /// `refreshWall` through `clamp(capacity:)`. A row-width click changes the page size with
    /// neither, and `refreshWall` returns before its clamp while the model and the pane stand still
    /// (`refreshWall`), so a `cardStart` the layout had already pulled back would stay stale for
    /// as long as the wall is up — and the next `▲`/`▼` would step from the page the state
    /// remembers rather than the one on screen, landing on a page the reader never saw (8 windows
    /// at 137x44, last page at row width 3, click `⤢`, click `▲`: `2–5 / 8`, where one page back
    /// from the `5–8 / 8` on screen is `1–4 / 8`).
    mutating func adopt(_ layout: WallLayout) {
        stageStart = layout.stageStart
        cardStart = layout.cardStart
    }

    // MARK: the keyboard

    /// The ring's action, when this pane still draws it.
    ///
    /// A ring that names a stop the current layout does not have — the window list shrank under it,
    /// the pane lost its `⤢` — is not somewhere to act from, and this is what says so. The stop list
    /// is the authority, exactly as it is for `Tab`.
    func ringStop(in layout: WallLayout) -> WallAction? {
        guard let ring, layout.stops().contains(where: { $0.action == ring }) else { return nil }
        return ring
    }

    /// One key, as the wall understands it.
    ///
    /// The only branch that *does* something is `activate`, and even it does nothing itself: it
    /// hands the ring's own `WallAction` back, and the caller runs it through `apply` — the click
    /// policy. There is deliberately no second `switch` over the actions in the keyboard, which is
    /// the duplication issue #201 is about: one table, one policy, two ways in.
    ///
    /// Returns the action to perform, or `nil` when the key only moved the ring (or did nothing).
    mutating func key(_ key: WallKey, in layout: WallLayout) -> WallAction? {
        let stops = layout.stops()
        switch key {
        case .next:
            moveRing(step: 1, stops: stops, withinBand: false)
            return nil
        case .previous:
            moveRing(step: -1, stops: stops, withinBand: false)
            return nil
        case .forward:
            moveRing(step: 1, stops: stops, withinBand: true)
            return nil
        case .backward:
            moveRing(step: -1, stops: stops, withinBand: true)
            return nil
        case .activate:
            guard let ring, stops.contains(where: { $0.action == ring }) else { return nil }
            return ring
        case .cancel:
            // Focus first, and nothing else: `Esc` is the way out of the ring, and a reader who
            // presses it twice means "and out of this pick too" — which is the footer's `back`.
            // With neither there is nothing to leave, and `Esc` is then nothing at all.
            if ring != nil {
                ring = nil
                return nil
            }
            return focus == nil ? nil : .back
        }
    }

    /// One step through the ring.
    ///
    /// `withinBand` is what the arrow keys ask for: the stops of the band the ring is on, in the same
    /// reading order, so `Right` in the shelf steps cards and page steps and never wanders onto the
    /// stage. A ring that is on no stop (nothing pressed yet, or the world moved under it) starts at
    /// the front going forward and at the back going backwards, the way a ring buffer reads.
    private mutating func moveRing(step: Int, stops: [WallStop], withinBand: Bool) {
        let here = ring.flatMap { action in stops.first { $0.action == action } }
        let pool = withinBand ? stops.filter { $0.band == (here?.band ?? .stage) } : stops
        guard !pool.isEmpty else {
            ring = nil
            return
        }
        guard let index = here.flatMap({ stop in pool.firstIndex { $0.action == stop.action } })
        else {
            ring = (step > 0 ? pool.first : pool.last)?.action
            return
        }
        ring = pool[((index + step) % pool.count + pool.count) % pool.count].action
    }

    /// After an action moved the world, keep the ring on a stop this pane still draws.
    ///
    /// Most activations leave their own stop in place (the bar's `▼` is still the bar's `▼` after it
    /// paged), and then this does nothing — that is what makes `Enter` repeatable. The one that does
    /// not is `⤢`: its payload *is* the next width, so applying it rewrites the very stop that was
    /// pressed. The ring then stays in the same band rather than disappearing (a ring nobody can see
    /// while the footer says `Tab selects` would be a lie about where the keyboard is).
    mutating func settleRing(in layout: WallLayout) {
        guard let ring else { return }
        let stops = layout.stops()
        if stops.contains(where: { $0.action == ring }) { return }
        let band = WallBand(ring)
        self.ring = stops.first { $0.band == band }?.action
    }
}

/// The wall's per-cell style: `Chrome.Style`'s table, spelled exactly as the chrome spells it so the
/// two cannot drift to different colours, plus one attribute the chrome has no use for — the
/// underline that says "the keyboard is here".
///
/// A style is an SGR string rather than an enum case because the ring has to *compose* with what is
/// already on the cell. The pointer's reverse video and the keyboard's underline are different bits
/// of one SGR (`7` and `4`), which is what lets both sit on the same item at once instead of one
/// hiding the other; a case list could only ever hold one of them.
struct WallStyle: Equatable {
    var sgr: String

    init(_ sgr: String) { self.sgr = sgr }

    static let plain = WallStyle(Chrome.Style.plain.sgr)
    static let dim = WallStyle(Chrome.Style.dim.sgr)
    static let bright = WallStyle(Chrome.Style.bright.sgr)
    static let accent = WallStyle(Chrome.Style.accent.sgr)
    static let reverse = WallStyle(Chrome.Style.reverse.sgr)

    /// The focus ring, on whatever the cell already carries: SGR 4 appended, so the pointer's `7`
    /// becomes `7;4` (reversed *and* underlined), a dim row becomes `2;37;4`, and neither signal is
    /// taken away from the other. Appending is safe for every member of the table because an SGR
    /// parameter list is a set of independent attributes; nothing in it is order-sensitive the way a
    /// reset would be.
    var underlined: WallStyle { WallStyle(sgr + ";4") }
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
///    the next draw is a full repaint. A trailing blank is trimmed *only* when the previous grid
///    already had a blank in that cell (see `render`: trimming a blank over an old glyph is how a
///    shrinking line leaves its tail on the terminal), and changed cells are merged into runs while
///    they stay contiguous, so a redraw costs one escape per row, not per cell.
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
        var style: WallStyle = .plain
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
        mutating func set(row: Int, col: Int, _ ch: Character, _ style: WallStyle) {
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
        mutating func text(_ s: String, row: Int, col: Int, _ style: WallStyle,
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

        /// Underline what is already drawn in `rect`, without touching a single glyph.
        ///
        /// This is what makes the focus ring's promise true: it is an *attribute*, so a card's title
        /// keeps every cell it had, nothing reflows, and no caption is one character shorter because
        /// the keyboard arrived. Blanks are skipped — underlining a space would put bytes on the pane
        /// to say nothing, and the ring costs what its text costs and no more. The second half of a
        /// wide glyph is skipped too: it is not a cell of its own (the terminal advances two for the
        /// glyph, and the renderer never writes it), so restyling it would only make the diff see a
        /// change it cannot write.
        mutating func underline(rect: CellRect) {
            guard !rect.isEmpty else { return }
            for row in rect.row...rect.maxRow {
                guard row >= 1, row <= rows else { continue }
                for col in rect.col...rect.maxCol {
                    guard col >= 1, col <= cols else { continue }
                    let i = (row - 1) * cols + (col - 1)
                    guard !cells[i].continuation, cells[i].ch != " " else { continue }
                    cells[i].style = cells[i].style.underlined
                }
            }
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
    ///
    /// `ring` is `WallState.ring`, the keyboard's position: `nil` (nobody has pressed a key) draws
    /// exactly the wall PR #195 left behind, which is what keeps the four golden dumps byte for
    /// byte and the idle wall free.
    func draw(cols: Int, rows: Int, model: WallModel, layout: WallLayout,
              focus: WallState.Focus?, cellW: Double = 8, cellH: Double = 20,
              paints: WallSlotPaints = WallSlotPaints(),
              pointer: WallPointer = WallPointer(),
              ring: WallAction? = nil) -> [UInt8] {
        let cells = build(cols: cols, rows: rows, model: model, layout: layout, focus: focus,
                          cellW: cellW, cellH: cellH, paints: paints, pointer: pointer, ring: ring)
        return render(cells, cols: cols, rows: rows)
    }

    /// The same cell grid `draw` renders from, one full-width string per row.
    ///
    /// `lines` exists for the tests (and for the "both symbol modes are the same number of
    /// columns" assertion) and is built by the *same* `build`, so it cannot describe a wall the
    /// painter does not draw. It does not touch the diff state: calling it between two draws must
    /// not turn the second draw into a full repaint.
    func lines(cols: Int, rows: Int, model: WallModel, layout: WallLayout,
               focus: WallState.Focus?, cellW: Double = 8, cellH: Double = 20,
               paints: WallSlotPaints = WallSlotPaints(),
               pointer: WallPointer = WallPointer(),
               ring: WallAction? = nil) -> [String] {
        let cells = build(cols: cols, rows: rows, model: model, layout: layout, focus: focus,
                          cellW: cellW, cellH: cellH, paints: paints, pointer: pointer, ring: ring)
        var out: [String] = []
        out.reserveCapacity(max(0, rows))
        for y in 0..<max(0, rows) {
            out.append(rowString(cells, y, cols: cols))
        }
        return out
    }

    /// The largest rect inside `rect` whose pixel aspect is `aspect` (design §6.6): the picture is
    /// **fitted, never cropped**, and the cells it does not cover keep the picture's dominant colour
    /// once the capture lands.
    ///
    /// One implementation, in `krdcore`: the capture path asks ScreenCaptureKit for exactly
    /// `PanelImage.fit`'s pixel box, so the placeholder drawn here and the picture that replaces it
    /// are the same rectangle by construction.
    static func fittedRect(aspect: Double, inside rect: CellRect,
                           cellW: Double, cellH: Double) -> CellRect {
        PanelImage.fit(aspect: aspect, in: rect, cellW: cellW, cellH: cellH).cellRect
    }

    // MARK: painting

    private func build(cols: Int, rows: Int, model: WallModel, layout: WallLayout,
                       focus: WallState.Focus?, cellW: Double = 8, cellH: Double = 20,
                       paints: WallSlotPaints = WallSlotPaints(),
                       pointer: WallPointer = WallPointer(),
                       ring: WallAction? = nil) -> [Cell] {
        var grid = Grid(cols: cols, rows: rows)
        guard grid.cols > 0, grid.rows > 0 else { return grid.cells }
        // Order matters only where two elements share a row: the footer and the band header place
        // their right-aligned tail first and draw the left-hand text second, into the budget the
        // tail leaves, so the tail keeps the cells it needs even if a degenerate pane makes them
        // collide.
        drawHeader(&grid, model: model, layout: layout)
        drawStage(&grid, model: model, layout: layout, cellW: cellW, cellH: cellH, paints: paints,
                  pointer: pointer)
        drawStageCaption(&grid, model: model, layout: layout, pointer: pointer)
        drawDivider(&grid, layout: layout)
        drawBand(&grid, model: model, layout: layout)
        drawCards(&grid, model: model, layout: layout, paints: paints, pointer: pointer)
        drawCardCaptions(&grid, model: model, layout: layout, paints: paints, pointer: pointer)
        drawFooter(&grid, model: model, layout: layout, focus: focus, notice: paints.notice,
                   demoNote: paints.demoNote, ring: ring)
        drawBar(&grid, layout: layout)
        // The ring last, and as an attribute: it underlines what is already drawn, so it cannot
        // move a caption by one cell or re-truncate a title (issue #201).
        drawRing(&grid, layout: layout, ring: ring)
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
    private func drawStage(_ grid: inout Grid, model: WallModel, layout: WallLayout,
                           cellW: Double, cellH: Double, paints: WallSlotPaints,
                           pointer: WallPointer = WallPointer()) {
        guard !layout.stage.isEmpty else { return }
        switch paints.stage {
        case .picture:
            // A picture fills the rect, and its bars are transparent, so the cells under it must be
            // *cleared* rather than left alone: whatever the previous frame drew there (a
            // placeholder box, an older picture's cells) would otherwise show through the bars.
            // No text is drawn (Chrome.swift:11-14) - the caption row names the display.
            clear(&grid, rect: layout.stage)
            return
        case .mask:
            let lit = pointer.over == .display(layout.stageStart)
            drawMask(&grid, rect: layout.stage, reason: paints.maskReason(0),
                     style: lit ? (pointer.down ? .reverse : .accent) : .dim)
            return
        case .placeholder:
            break
        }
        let shown = model.displays.indices.contains(layout.stageStart)
            ? model.displays[layout.stageStart] : nil
        // Keep the display's own proportions: a 16:10 panel drawn into a 2.8:1 band was the
        // "wrong-looking wall" in review. The cells the picture does not cover are where its
        // dominant colour goes when the capture lands.
        let rect = shown.map {
            Self.fittedRect(aspect: Double($0.width) / Double(max(1, $0.height)),
                            inside: layout.stage, cellW: cellW, cellH: cellH)
        } ?? layout.stage
        let label = shown.map { "\($0.name) \(symbols.dash) \($0.width)\(symbols.times)\($0.height)" }
            ?? "no display"
        // The middle row is the same expression for a box (any `rows >= 3`) and for the "too short
        // for a box" case, so the label does not move when the pane crosses that threshold.
        let middle = rect.row + (rect.rows - 1) / 2
        let lit = pointer.over == .display(layout.stageStart)
        if rect.rows >= 3, rect.cols >= 2 {
            drawBox(&grid, rect: rect, style: lit ? .accent : .dim)
            let inner = max(0, rect.cols - 2)          // inside the two side borders
            let body = DisplayWidth.truncate(label, to: inner)
            let offset = max(0, (inner - DisplayWidth.of(body)) / 2)
            grid.text(body, row: middle, col: rect.col + 1 + offset,
                      lit ? (pointer.down ? .reverse : .accent) : (shown == nil ? .dim : .bright),
                      limit: max(0, inner - offset))
        } else {
            // Two rows or one: no box (a box needs a top, a bottom and a side), just the label.
            let body = DisplayWidth.truncate(label, to: rect.cols)
            let offset = max(0, (rect.cols - DisplayWidth.of(body)) / 2)
            grid.text(body, row: middle, col: rect.col + offset,
                      shown == nil ? .dim : .bright, limit: max(0, rect.cols - offset))
        }
    }

    /// `🖥 Built-in — 1512×982 · main · 1/3`
    private func drawStageCaption(_ grid: inout Grid, model: WallModel, layout: WallLayout,
                                 pointer: WallPointer = WallPointer()) {
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
        // Reverse video, not a colour: it is the one signal that also works on a slot whose picture
        // covers the box, and it is exactly one row of bytes in the diff.
        let lit = pointer.over == .display(layout.stageStart)
        grid.text(DisplayWidth.truncate(text, to: rect.cols), row: rect.row, col: rect.col,
                  lit ? .reverse : .plain, limit: rect.cols)
    }

    /// `▣ recent    1–3 / 7                                          ⤢ 3`
    /// `────────────...` — one dim rule between the stage block and the cards.
    ///
    /// Review: the stage caption, the band header and the tops of the cards arrived as three dense
    /// rows with nothing between them. A rule costs one row and says where one section ends; a
    /// blank row costs the same and says nothing.
    private func drawDivider(_ grid: inout Grid, layout: WallLayout) {
        let rect = layout.dividerRow
        guard !rect.isEmpty else { return }
        grid.text(String(repeating: symbols.boxH, count: rect.cols), row: rect.row, col: rect.col,
                  .dim, limit: rect.cols)
    }

    private func drawBand(_ grid: inout Grid, model: WallModel, layout: WallLayout) {
        let content = min(layout.contentCols, grid.cols)
        // `⤢ per` is the row width - the reader's number - while the range below it is what the
        // page actually holds (`capacity`, cut off at `windowCount`), so a tall band shows
        // `1–6 / 7` under a `⤢ 3`.
        //
        // The glyph is written *into* its own rect (`layout.bandTail`) instead of being right-aligned
        // to the content: `action(row:col:)` answers for exactly that rectangle, so the cells that
        // show the control and the cells that respond to a click cannot drift apart. An empty rect
        // means no glyph at all — `WallLayout` empties it whenever the control could not act, or
        // could not show its number truthfully, and a control that cannot act is not drawn
        // (design §5: no dead cells that swallow clicks).
        let tail = layout.bandTail
        if !tail.isEmpty {
            // `.dim` is weight, not liveness: the footer's whole `⬅ back` row is dim and live. What
            // marks a control the reader cannot press is that its own glyph is not drawn at all —
            // the way a dead bar segment keeps only its plain `│` and no arrows.
            grid.text("\(symbols.perButton) \(layout.per)", row: tail.row, col: tail.col, .dim,
                      limit: tail.cols)
        }
        // The glyph keeps its own cells plus the blank column that separates it from the label; with
        // no glyph the label gets the whole content width back.
        let budget = tail.isEmpty ? content : max(0, content - tail.cols - 1)
        let range: String
        if layout.windowCount == 0 {
            range = "no windows"
        } else if layout.cards.isEmpty {
            // The layout dropped the card section (a pane too short for one), so `capacity` would
            // name cards the pane does not draw and there is no page to count: say `no room`, the
            // same honesty `no windows` already had. A pane with no *window* is the branch above.
            range = "no room"
        } else {
            let first = layout.cardStart + 1
            let last = min(layout.cardStart + layout.capacity, layout.windowCount)
            range = "\(first)\(symbols.enDash)\(last) / \(layout.windowCount)"
        }
        let used = grid.text("\(symbols.window) recent", row: layout.bandRow, col: 1, .plain,
                             limit: budget)
        grid.text("    " + range, row: layout.bandRow, col: 1 + used, .dim,
                  limit: max(0, budget - used))
    }

    /// The card boxes of this page: a dim frame, then as many of the three lines (app, title, size)
    /// as fit, vertically centred in the interior.
    ///
    /// Centred, not top aligned, because what phase 1 draws here is the §4 *mask*, not the picture:
    /// the common card is 44x14, i.e. a 12-row interior, and three lines hanging under the top
    /// border read as an empty panel that happens to have some text in it. The picture the capture
    /// phase paints into exactly this rect will be centred, so the text is too — nothing jumps when
    /// it arrives. An interior of 1 or 2 rows has no room to centre and keeps the block at the top
    /// (`max(0, …)`), and `cardH < 3` is no card at all: the frame itself needs three rows, so such
    /// a rect never reaches here. A squeezed box still keeps its first lines and never overwrites a
    /// border.
    private func drawCards(_ grid: inout Grid, model: WallModel, layout: WallLayout,
                           paints: WallSlotPaints, pointer: WallPointer = WallPointer()) {
        for (slot, rect) in layout.cards.enumerated() {
            guard !rect.isEmpty else { continue }
            switch paints.card(slot) {
            case .picture:
                clear(&grid, rect: rect)    // transparent bars show what is under the picture
                continue
            case .mask:
                let lit = pointer.over == .window(layout.cardStart + slot)
                drawMask(&grid, rect: rect, reason: paints.maskReason(1 + slot),
                         style: lit ? (pointer.down ? .reverse : .accent) : .dim)
                continue
            case .placeholder:
                break
            }
            guard rect.rows >= 3, rect.cols >= 2 else { continue }
            let index = layout.cardStart + slot
            guard model.windows.indices.contains(index) else { continue }
            let window = model.windows[index]
            // The pointer is on *this* item, not on this slot: the index is absolute, so page 2's
            // first card answers for window 3 (`cardStart + slot`), the same index a click enters.
            let lit = pointer.over == .window(index)
            drawBox(&grid, rect: rect, style: lit ? .accent : .dim)

            let inner = rect.cols - 4              // one blank cell inside each border
            guard inner >= 1 else { continue }
            let col = rect.col + 2

            // The block is built first so it can be positioned as a whole.
            var lines: [(text: String, style: WallStyle)] = [
                (DisplayWidth.truncate("\(symbols.window) \(window.app)", to: inner), .bright),
            ]
            if let title = wallTitle(window) {
                lines.append((DisplayWidth.truncate(title, to: inner), .plain))
            } else {
                // No screen-recording grant (or a window without a name) degrades to a position,
                // which is still a label the user can tell apart (design §3).
                lines.append((DisplayWidth.truncate("window \(index + 1)", to: inner), .dim))
            }
            lines.append((DisplayWidth.truncate("\(pixels(window.bounds.width))\(symbols.times)"
                                                + "\(pixels(window.bounds.height))",
                                                to: inner), .dim))

            let interior = rect.rows - 2           // rows between the two borders
            let shown = lines.prefix(max(0, interior))
            var row = rect.row + 1 + max(0, (interior - shown.count) / 2)
            for (i, line) in shown.enumerated() {
                // Only the card's first line (the app name) deepens on a press: reversing the whole
                // block would repaint every row of a card for one click, and the box already says
                // which card it is.
                let style: WallStyle = lit && pointer.down && i == 0 ? .reverse : line.style
                grid.text(line.text, row: row, col: col, style, limit: inner)
                row += 1
            }
        }
    }

    /// `▣ Safari — Apple…` — the same width as its card, so a click on the caption enters the card
    /// right above it (design §1: "点图或点说明都进入").
    private func drawCardCaptions(_ grid: inout Grid, model: WallModel, layout: WallLayout,
                                 paints: WallSlotPaints, pointer: WallPointer = WallPointer()) {
        for (slot, box) in layout.cardCaptions.enumerated() {
            guard box.rows == 1, !box.isEmpty else { continue }
            let index = layout.cardStart + slot
            guard model.windows.indices.contains(index) else { continue }
            let window = model.windows[index]
            let title = wallTitle(window) ?? "window \(index + 1)"
            let text = "\(symbols.window) \(window.app) \(symbols.dash) \(title)"
            // Under the picture when there is one, under the box otherwise (a mask fills its box,
            // so there the two are the same rectangle). A picture narrower than its box would
            // otherwise leave its caption out in the margin. `slot` is the card index; the paints
            // are keyed by slot id (1... are the cards), so ask for `slot + 1`.
            var rect = box
            if let cells = paints.pictureCells(slot + 1), cells.cols >= 8 {
                let col = max(box.col, min(cells.col, box.maxCol))
                rect = CellRect(col: col, row: box.row,
                                cols: max(0, min(cells.cols, box.maxCol - col + 1)), rows: 1)
            }
            // The same row for both states of the card: a picture card draws no box, so this is the
            // only hover it can show, and `press` is already said by the box and the app line above.
            let lit = pointer.over == .window(index)
            grid.text(DisplayWidth.truncate(text, to: rect.cols), row: rect.row, col: rect.col,
                      lit ? .reverse : .plain, limit: rect.cols)
        }
    }

    /// The footer: how many panels there are (right, right-aligned) and what a click does here
    /// (left). After a pick it becomes the way back, which in phase 1 is the whole of "entered".
    ///
    /// `ring` only decides one sentence: once the keyboard is in use the click hint gains its
    /// keyboard twin (issue #201). Not before — the opening frame says what a reader with a mouse
    /// needs, and it is the frame the four goldens hold.
    private func drawFooter(_ grid: inout Grid, model: WallModel, layout: WallLayout,
                            focus: WallState.Focus?, notice: WallNotice? = nil,
                            demoNote: String? = nil, ring: WallAction? = nil) {
        let content = min(layout.contentCols, grid.cols)
        let budget = drawTail(&grid, row: layout.footerRow, content: content,
                              "\(1 + layout.cards.count) panels", .dim)
        // The demo's numbers come before everything: while they are up, that line *is* the point of
        // the frame, and the click hint can wait.
        if let demoNote {
            grid.text(DisplayWidth.truncate(demoNote, to: budget), row: layout.footerRow, col: 1,
                      .bright, limit: budget)
            return
        }
        let lead: String
        switch focus {
        case nil:
            // A frame with something to report says that instead of how to click: the reader's
            // question at that moment is "why is this empty", not "what does a click do".
            //
            // Two hints, not one line holding everything: the mouse's is the wall's whole vocabulary
            // until a key is pressed, and the keyboard's only matters once `Tab` has been. `Esc` is
            // in the second because it is the way *out* of that vocabulary, and a key nobody can
            // discover is a key nobody uses.
            if notice == nil, ring != nil {
                lead = "\(symbols.bullet) Tab selects\(symbols.dot)Enter opens"
                    + "\(symbols.dot)Esc clears"
            } else {
                lead = notice?.text(bullet: symbols.bullet, dash: symbols.dash)
                    ?? "\(symbols.bullet) click a card\(symbols.dot)wheel or the right bar scrolls"
            }
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
    /// The caps are the four positions the design asks for: above the display segment (header row),
    /// below it (stage caption row), above the card segment (band header row) and below that one
    /// (the card section's last row; no card band → nothing there, the grid never writes row 0).
    ///
    /// The band-row cap is what makes the two segments *two*: §6 breaks them with `╵` / `╷`, and
    /// with only the stage's bottom cap the shafts would read as one bar running from the header to
    /// the cards, leaving the `▣ recent` row unpainted where the mockup has a `╷`.
    private func drawBar(_ grid: inout Grid, layout: WallLayout) {
        let col = layout.barCol
        grid.set(row: layout.headerRow, col: col, glyph(symbols.capTop), .dim)
        grid.set(row: layout.stageCaption.row, col: col, glyph(symbols.capBottom), .dim)
        grid.set(row: layout.bandRow, col: col, glyph(symbols.capTop), .dim)
        // The bottom cap closes the card *section*, not the first row of cards: with two or three
        // rows of them the caption the bar ends beside is the last row's, and the section's own last
        // row is the one under the segment (`cardCaptions.first` was that row while a page was one
        // row tall).
        if !layout.bar.cards.rect.isEmpty {
            grid.set(row: layout.bar.cards.rect.maxRow + 1, col: col, glyph(symbols.capBottom), .dim)
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

    /// The focus ring: an underline on the row the stop's own label lives on, or — for the bar's
    /// controls, which have no label of their own — on the one cell a click there is aimed at.
    ///
    /// Why an underline and not the pointer's reverse video: a mouse move must never look like a
    /// focus change, and the two signals have to be able to sit on one item at once. SGR 4 and 7 are
    /// different bits of one attribute list (`7;4` is both), so a hovered *and* focused caption says
    /// both things at once instead of one of them winning. It also costs no content:
    /// `WallStyle.underlined` restyles cells that are already drawn, so a long title is not
    /// truncated by one character because the keyboard arrived, and a card whose *picture* covers its
    /// box still has the caption row to underline (the same reason the pointer's universal signal is
    /// the caption).
    private func drawRing(_ grid: inout Grid, layout: WallLayout, ring: WallAction?) {
        guard let ring else { return }
        switch ring {
        case .enterStage:
            grid.underline(rect: layout.stageCaption)
        case .enterCard(let index):
            // The slot is absolute-minus-page, exactly as a click resolves it: the ring is an
            // `.enterCard` for the window, and the caption belongs to the card showing it.
            let slot = index - layout.cardStart
            guard layout.cardCaptions.indices.contains(slot) else { return }
            grid.underline(rect: layout.cardCaptions[slot])
        case .cyclePer:
            grid.underline(rect: layout.bandTail)
        case .back:
            // The footer's own row. The `N panels` tail on the right is not part of the control, so
            // the ring stops where the tail starts — the same arithmetic `drawFooter` uses for the
            // budget it hands its lead text.
            let content = min(layout.contentCols, grid.cols)
            let tail = DisplayWidth.of("\(1 + layout.cards.count) panels")
            grid.underline(rect: CellRect(col: 1, row: layout.footerRow,
                                          cols: max(0, content - tail - 1), rows: 1))
        case .stageStep, .stageJump, .cardStep, .cardJump:
            // The bar is one column wide and every glyph in it means something (`▲` a step back,
            // `█` where the shelf is): the ring goes *on* that cell and never replaces it, and the
            // cell is the one the click table answered — the stop's own first cell.
            guard let stop = layout.stops().first(where: { $0.action == ring }) else { return }
            grid.underline(rect: CellRect(col: stop.col, row: stop.row, cols: 1, rows: 1))
        }
    }

    // MARK: primitives

    /// A dim frame filling `rect`. The caller guarantees `rows >= 3 && cols >= 2` (the corners are
    /// the only thing that needs two columns; with exactly two there is no horizontal run).
    /// The fallback for a slot whose capture failed (window closed, permission denied, no pixel
    /// buffer): a box on the same rect with one dim line in the middle.
    ///
    /// Deliberately not an error message and not a hatch: the wall is a picture of a desk, and "no
    /// picture here" is a state of the desk, not a problem to report. The caption row still names
    /// the window or display, so nothing is lost but the pixels.
    /// Blank every cell of `rect`, which is what a transparent picture needs underneath it.
    private func clear(_ grid: inout Grid, rect: CellRect) {
        guard !rect.isEmpty else { return }
        for row in rect.row...rect.maxRow {
            grid.text(String(repeating: " ", count: rect.cols), row: row, col: rect.col,
                      .plain, limit: rect.cols)
        }
    }

    /// A slot whose picture did not arrive. `style` is the pointer's: a mask is a box like any
    /// other, and the pointer has to be acknowledged here too — a wall whose captures failed (no
    /// Screen Recording grant, a display that is not shareable) is *all* masks, and a hover that
    /// did nothing on it would look like the input path was broken.
    private func drawMask(_ grid: inout Grid, rect: CellRect, reason: String? = nil,
                          style: WallStyle = .dim) {
        guard !rect.isEmpty else { return }
        guard rect.rows >= 3, rect.cols >= 2 else {
            let label = DisplayWidth.truncate(symbols.dash, to: rect.cols)
            grid.text(label, row: rect.row + (rect.rows - 1) / 2, col: rect.col, style,
                      limit: rect.cols)
            return
        }
        drawBox(&grid, rect: rect, style: style)
        let inner = max(0, rect.cols - 2)
        // One word if the caller knows it ("closed", "denied", "no stream"): a reader looking at a
        // card that will not show its window needs the reason on the card, not in a log file.
        let body = DisplayWidth.truncate(reason ?? "no picture", to: inner)
        let offset = max(0, (inner - DisplayWidth.of(body)) / 2)
        grid.text(body, row: rect.row + (rect.rows - 1) / 2, col: rect.col + 1 + offset,
                  style == .dim ? .dim : style, limit: max(0, inner - offset))
    }

    /// The frame around a card or the stage. `style` is the pointer's to choose: `.dim` is the wall
    /// at rest, `.accent` is "under the pointer", and nothing else about the box moves — a highlight
    /// that changed the geometry would reflow the card and cost a full row of bytes.
    private func drawBox(_ grid: inout Grid, rect: CellRect, style: WallStyle = .dim) {
        guard rect.rows >= 3, rect.cols >= 2 else { return }
        let run = String(repeating: symbols.boxH, count: rect.cols - 2)
        grid.text(symbols.boxTL + run + symbols.boxTR, row: rect.row, col: rect.col, style,
                  limit: rect.cols)
        for row in (rect.row + 1)..<rect.maxRow {
            grid.set(row: row, col: rect.col, glyph(symbols.boxV), style)
            grid.set(row: row, col: rect.maxCol, glyph(symbols.boxV), style)
        }
        grid.text(symbols.boxBL + run + symbols.boxBR, row: rect.maxRow, col: rect.col, style,
                  limit: rect.cols)
    }

    /// Right-aligned text on `row` inside a `content`-wide band starting at column 1, and the
    /// number of cells the left-hand text may use so the two never touch. Right-aligned counts are
    /// the first thing to give way on a narrow pane, so they are placed first and the left text is
    /// then truncated into what is left.
    @discardableResult
    private func drawTail(_ grid: inout Grid, row: Int, content: Int, _ text: String,
                          _ style: WallStyle) -> Int {
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

    /// True when the pane already shows `cells[i]`: either there is no previous grid (a full
    /// repaint) or `prev` holds that very cell there. Equality is the whole test — the cell that is
    /// blank now must have been that same blank before for a trailing trim to be a no-op on screen.
    private func showsAlready(_ old: [Cell]?, at i: Int, _ cells: [Cell]) -> Bool {
        guard let old, old.count == cells.count else { return true }
        return old[i] == cells[i]
    }

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
        var style: WallStyle?
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
                      !cells[y * cols + end - 1].continuation,
                      showsAlready(old, at: y * cols + end - 1, cells) {
                    // A trailing blank is dropped only when the pane *already* shows a blank there.
                    // On a full repaint (`old == nil`) that is every one of them, which is what keeps
                    // the dumps small. On a diff it is what makes a line that got shorter erase
                    // itself: the cells past the new text held glyphs in the previous grid, so
                    // trimming them drops the only bytes that would paint over those glyphs — the
                    // old text then survives on the terminal while `lines`, the diff and the byte
                    // count all look right. That is a silent stale-glyph bug, not an optimisation.
                    end -= 1
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

