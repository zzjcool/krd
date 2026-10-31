import Foundation
import krdcore

/// The TUI layer: a status bar and a set of panels drawn on the rows the layout reserves for
/// chrome. This is the `--dev` surface, and it is deliberately a separate layer: nothing below
/// it knows about it, and it never touches the tile pipeline.
///
/// ## Invariants (each one is a failure that already happened once)
///
/// 1. **Only rows at or below `imageRows` are written.** Everything above belongs to the
///    picture; text there lands under a placement.
/// 2. **Every write is positioned** (`ESC[row;colH`) and this file never emits `\n`. A newline
///    on the last row scrolls the grid, and every placement is positioned by absolute cell, so
///    a scroll puts the whole picture one row off (`ARCHITECTURE.md` §7.2).
/// 3. **The final cell of the final row is never written.** Writing it arms the terminal's
///    pending-wrap; the next byte scrolls.
/// 4. **Chrome bytes go out between frames, never inside a tile's APC.** `ScreenWriter`
///    serializes them against `flush()`, so a text write cannot split a base64 payload.
///
/// Placement is not handled here: a kitty placement lands at the cursor, which is why
/// `ScreenWriter.emit` positions the cursor before every tile. Chrome writes move the cursor,
/// and that explicit move is what makes the two coexist.

/// Where the picture ends and the chrome begins, in cells.
struct ChromeGeometry: Equatable {
    var cols: Int
    var rows: Int
    /// Rows the picture occupies (the placement rect). Chrome starts at this row (0-based).
    var imageRows: Int
    var imageCols: Int
    /// 0-based row of the status line.
    var statusRow: Int
    var panelTop: Int
    var panelHeight: Int
    /// 0-based row of the mirror's own bar, when it has one. The bar is not the `--dev` chrome: it
    /// is the window furniture the wall's mirrors are dressed in (traffic lights, title, and the
    /// button that shrinks the mirror back into the wall).
    var barRow: Int? = nil
    /// Whether the `--dev` status line and panels are drawn at all. The bar can be on with `--dev`
    /// off, and the dev line's `target` segment is a measurement ("window 128444 moved to -192,…")
    /// that has no business in window furniture at the bottom of the pane.
    var devStatus: Bool = true

    var chromeTop: Int { imageRows }

    /// Whether a panel can be **drawn** in this geometry: the bar alone is enough furniture for one.
    ///
    /// The `--dev` status line and the panels used to share `devStatus`, and a handed-over mirror
    /// runs `--bar` with no `--dev` -- so `[ ≡ ]` opened a panel the drawer skipped while a
    /// rectangle computed from this geometry still claimed its rows, and the menu was invisible on
    /// exactly the page it was built for (issue #87). One predicate, read by the drawer; the click
    /// path asks the painted table instead of a second rectangle (#200), so the rows a click thinks
    /// are a panel are the rows a panel was drawn in, by construction.
    var panelsDrawable: Bool { barRow != nil || devStatus }

    /// Rows a panel's box has inside its two borders: what `drawPanel` writes into, and what the
    /// wheel's clamp is measured against. The box deliberately stops above the pane's final row
    /// (writing its last cell arms the terminal's pending-wrap, see the file's invariant 3), so the
    /// clamp lives here once instead of in the drawer and in the input path.
    var panelInsideRows: Int { max(0, min(panelHeight, rows - 1 - panelTop) - 2) }
}

enum ChromePanel: String, CaseIterable {
    case stats, devices, settings, log, help
    /// The three sliders (issue #87). A panel rather than a box of its own: a panel is what the
    /// layout already knows how to give rows to, and its cells go through the same positioned
    /// writes, the same `panelInsideRows` clamp and the same "never the final row" rule as every
    /// other one. The tracks below are the only controls inside a panel, which is why the wheel -- the
    /// one gesture a panel answers -- has to keep working on a cell that is also a control (#118).
    case menu

    var title: String { rawValue }

    /// Rows the panel wants, before the layout decides where it fits.
    var height: Int {
        switch self {
        case .stats: return 16
        case .settings: return 12
        case .devices: return 12
        case .log: return 14
        case .help: return 13
        case .menu: return 6
        }
    }

    /// Rows of content this panel has, before the box decides how many of them it can hold.
    ///
    /// Two numbers, not one: `height` is how much of the pane the panel asks for (borders
    /// included, and it is a wish the layout may overrule), while this is the length of the
    /// column of rows the panel has to show. The badge on the border and the wheel's clamp both
    /// read *this*, so the count a reader sees (`1-10/16`) and the row the last notch stops on
    /// are the same number -- two independent copies would drift the moment a row is added
    /// (#118). `ChromeTests` pins each panel's count and its last row (see
    /// `testEveryPanelCanReachItsLastRowAndCountsTheRowsItHas`), so a row appended here has to
    /// bring its count with it or its panel's last row stops being reachable.
    func contentRows(_ m: ChromeMetrics) -> Int {
        switch self {
        case .stats: return 16
        case .settings: return 10                  // eight switches, a gap, the hot/cold hint
        case .devices: return max(1, m.devices.count)      // the "none" row when the list is empty
        case .log: return max(1, m.logTail.count)
        case .help: return 11
        case .menu: return ChromeAxis.allCases.count + 1   // three sliders and the line that explains them
        }
    }

    /// Which end of its content the panel is read from. The log's answer is its newest line:
    /// `readLogTail` hands back the last twelve lines, and a reader opening the panel after a
    /// failure wants the last one of those, not the first (#118).
    var readsFromTheEnd: Bool { self == .log }
}

struct ChromeState {
    var panel: ChromePanel? = nil
    /// `Ctrl-\` was pressed and the next byte is a command.
    var prefix = false
    /// A short-lived hint, right-aligned on the status line.
    var toast: String? = nil
    /// First content row the panel's box shows. `nil` is "wherever this panel is read from" --
    /// the top, or the end for the log -- which is also what opening a panel starts at. The wheel
    /// moves it; the drawer clamps it with the same window arithmetic the wheel uses, so a scroll
    /// past the end cannot leave a panel blank.
    var panelOffset: Int? = nil
    /// What the pointer is doing over the chrome: the widget under it, and whether a button is down.
    ///
    /// The same value the wall keeps (`Pointer`), with a widget id as its target, because the
    /// chrome's answer to "what is here" is the table `route` reads (#200). The drawer is the only
    /// reader: a widget is drawn hovered by marking its *cells* (`ChromeHot`), never by checking this
    /// against a second copy of the widget's rectangle.
    var pointer = Pointer<String>()

    /// The widget under the pointer, and the one a press is on -- what the drawer lights up.
    var hover: String? { pointer.over }
    var pressed: String? { pointer.pressed }
}

extension ChromeMetrics {
    /// `40.2`, or `—` when the capture age was not measured (`capMs < 0`, which is what the mock and
    /// replay paths report). Negative cannot be formatted as a number anywhere: it would read as
    /// "very fast capture" instead of "we do not know".
    var capLabel: String { capMs < 0 ? "—" : Series.show(capMs) }
    var capP99Label: String { capMs < 0 ? "—" : Series.show(capP99Ms) }
    /// `34`, or `—` for "we did not ask" and `—` for "we asked and it did not answer": the two are
    /// different (one is a choice, one is a capability) and both are not a measurement.
    var rttLabel: String {
        guard rttAvailable else { return "—" }
        return Series.show(rttMs)
    }
    var rttP99Label: String {
        guard rttAvailable else { return "—" }
        return Series.show(rttP99Ms)
    }

    /// The bar's delay readout: **the round trip we measure**, with its unit.
    ///
    /// The same number the stats panel's `rtt` row and `--bench --json`'s `rtt_ms` print --
    /// `RTTProbe` sends `CSI 5n` and times the terminal's `CSI 0n` answer, so it is the one figure
    /// that covers the terminal side, which `frame ms` (cap + pipe) cannot see (issue #87). The unit
    /// stays on the `—` so the slot still reads as a delay with no measurement in it: a terminal
    /// without DSR is a capability, not a zero, and `0 ms` would be a lie.
    var delayLabel: String { "\(rttLabel) ms" }

    /// The whole frame, `cap + pipe`, or `—` when the capture half was not measured (`capMs < 0`:
    /// `--mock`, `--replay`, `--selftest`). With no `cap`, `e2eMs` *is* the pipe half, so printing it
    /// as the frame put a confident `0 ms` in one column of a row whose own note said
    /// `cap — (no PTS)` (#117). The unit belongs to the caller, like its two neighbours.
    var e2eLabel: String { capMs < 0 ? "—" : "\(Int(e2eMs))" }
}

/// One second of numbers: the same counters the `--debug` stats line prints, plus the rates it
/// only implies and the switches that are otherwise invisible.
struct ChromeMetrics {
    var version = ""
    var target = "-"
    /// What the bar calls this window: the app and its title, or the display's size. Empty when the
    /// caller did not set it, in which case the bar shows no title at all rather than a diagnosis.
    var title = ""
    var fpsTarget = 20
    var fps = 0.0
    /// Whether the pane has the terminal's focus (`CSI I` / `CSI O`, DECSET 1004, issue #110). False
    /// means the picture is throttled to `--unfocused-fps` -- 0 fps being a frozen picture -- so the
    /// panel's `x/y fps` row is a cap being held and not a pipe that cannot keep up.
    var focused = true
    /// The capture scale in effect, and whether it is allowed to move (issue #73: the default is
    /// adaptive, so a resolution that changes on its own has to be visible).
    var scale = 1.0
    var scaleAuto = false
    var captureFps = 0.0
    /// How often the capturer skipped / reported an unchanged screen, per second. A starved capture
    /// (nothing delivered at all) is otherwise indistinguishable from a fast one in the panel.
    var skippedPerSec = 0.0
    var idlePerSec = 0.0
    var mbps = 0.0
    var kbPerFrame = 0
    var tilesPerSec = 0
    var dirty = 0
    var tilesTotal = 0
    /// Frames drawn since the session began (a counter, unlike `fps`).
    var framesTotal = 0
    /// Age of the frame at ScreenCaptureKit's callback (`callback − PTS`), and our own share of the
    /// delay (`callback → last byte written`). `e2eMs` is their sum. `capMs < 0` = not measured
    /// (mock, replay), which the panel shows as `cap —` rather than as a confident zero.
    var capMs = 0.0
    var capP99Ms = 0.0
    var pipeMs = 0.0
    /// `parse → CGEvent.post` for the last key or click: the only input number that says whether the
    /// typing lag is ours or the network's.
    /// Round trip of the terminal's own DSR answer (`CSI 5n` → `CSI 0n`), in ms. `nan` until the
    /// first answer; `rttAvailable` is false for a path that does not probe, or a terminal that
    /// never answers.
    var rttMs = Double.nan
    var rttP99Ms = Double.nan
    var rttAvailable = false
    var inputMs = 0.0
    var inputP99Ms = 0.0
    /// Bytes sitting in the pty's own output buffer (`TIOCOUTQ`), -1 = not available.
    ///
    /// Not a lag meter: the buffer is ~1 KB and sshd drains it immediately into its *userspace*
    /// buffer, which is where megabytes of un-sent picture actually accumulate. So a healthy
    /// link shows 0 here; sustained non-zero means sshd has stopped reading. The honest signal
    /// for "the link is the bottleneck" is `write` blocking, not this.
    var queueBytes = -1
    var queueMs = 0.0
    /// `MB/s` minus the bytes that piled up in the pty buffer: bytes sshd actually took off our
    /// hands. Equals `MB/s` unless sshd stalls, which is the point — it separates "we sent it"
    /// from "the pty would not take it".
    var drainMbps = 0.0
    /// Wall clock, printed so the *user* can measure the real end-to-end delay by comparing it
    /// with their own clock. Over ssh nothing on this side can see the other end.
    var clock = ""
    var pipeP99Ms = 0.0
    /// The worst `pipe` in the ring. `pipeP99Ms` is the 4th-worst of 300 frames, so a *single*
    /// 1,368 ms frame cannot move it; this is the number that shows one hiccup (issue #91).
    var pipeMaxMs = 0.0
    var e2eMs = 0.0
    var zlibMs = 0.0
    var zlibP99Ms = 0.0
    /// `--quality` as it stands, and the bit depth it allows: "80" and "5-6-5", or "100 lossless".
    var quality = 80
    var qualityLabel = "5-6-5"
    /// Whether the encoder quantises every tile rather than only the ones that proved
    /// incompressible -- the second half of `--quality` (`QualityBudget.eager`), which the menu's
    /// second slider moves on its own.
    var qualityEager = false
    /// The axes a click has pinned (issue #87): the value column says `pinned` and no governor
    /// takes it back. One set, because the two halves of `--quality` and the frame rate pin on the
    /// same click and the menu has to say which of its three rows is the user's now -- the bug was
    /// a slider whose value walked back by itself.
    var pinned: Set<ChromeAxis> = []
    /// Tiles the encoder is currently quantising and the tiles it is sending raw (#53/#59).
    var quantisedTiles = 0
    var skippedTiles = 0
    var writeMs = 0.0
    var writeMaxMs = 0.0
    var writeOver5 = 0
    var callbacks = 0
    var delivered = 0
    var skipped = 0
    var idle = 0
    var bad = 0
    var pxW = 0
    var pxH = 0
    var cellsW = 0
    var cellsH = 0
    var cellW = 0.0
    var cellH = 0.0
    var format = "-"
    var tileSpec = "-"
    var sync = "-"
    var quiet = "-"
    var inputActive = false
    var dryRun = false
    var cursorDrawn = true
    var logPath = "-"
    var recording = "-"
    var envSwitches = "-"
    var geometrySource = "-"
    /// Display/window rows for the devices panel, "*" marks the active one.
    var devices: [String] = []
    /// The last lines of the log file, for the log panel.
    var logTail: [String] = []
    var mbpsHistory: [Double] = []
    var latencyHistory: [Double] = []
}

/// The menu's three axes, and the one table that says what a position on each of them means.
///
/// The drawer, the `hit` id on a tick and the click path all read this: a tick cannot draw one
/// value and set another, and the two halves of `--quality` (the bit depth and how eagerly the
/// encoder spends it) get one axis each instead of two sliders fighting over one number.
///
/// The mapping is the one issue #87 proposed and `QualityBudget`'s own table already encodes:
/// **colour** is the bit depth a frame may lose (50 = 4-4-4, 70 = 5-5-5, 80 = 5-6-5, 90 = 6-6-6,
/// 100 = lossless), and **quality** is `eager` -- quantise every tile, or only the ones that proved
/// incompressible. Between them they are exactly today's `--quality`, so nothing about the encoder
/// had to change.
enum ChromeAxis: String, CaseIterable {
    case colour, quality, fps

    var label: String {
        switch self {
        case .colour: return "colour"
        case .quality: return "quality"
        case .fps: return "fps"
        }
    }

    /// Positions on the track. Steps are 0-based everywhere: the id, the drawer and the click.
    var steps: Int {
        switch self {
        case .colour: return ChromeAxis.colourValues.count
        case .quality: return 2
        case .fps: return ChromeAxis.fpsRange.count
        }
    }

    /// The `--quality` numbers the colour track lands on: `QualityBudget`'s four shipped bit depths
    /// and lossless, i.e. the rungs its own table documents.
    static let colourValues = [50, 70, 80, 90, 100]
    /// `--fps`'s documented range; one cell per frame, so the track is the number.
    static let fpsRange = 1...20

    static func colourValue(step: Int) -> Int {
        colourValues[min(max(0, step), colourValues.count - 1)]
    }

    static func fpsValue(step: Int) -> Int {
        fpsRange.lowerBound + min(max(0, step), fpsRange.count - 1)
    }

    /// Where the current `--quality` sits on the colour track: the highest rung it can still reach,
    /// so the default 80 lands on 5-6-5 and a `--no-quantise` 100 lands on the lossless end.
    static func colourStep(for quality: Int) -> Int {
        var step = 0
        for (i, value) in colourValues.enumerated() where quality >= value { step = i }
        return step
    }

    /// The tick this axis is on, given what the stream is doing now.
    func step(_ m: ChromeMetrics) -> Int {
        switch self {
        case .colour: return ChromeAxis.colourStep(for: m.quality)
        case .quality: return m.qualityEager ? 1 : 0
        case .fps: return min(max(0, m.fpsTarget - 1), steps - 1)
        }
    }

    /// What the value column says next to the track. `pinned` is part of the value, not a note
    /// three rows down: the reader has to see that the governor no longer owns this number at the
    /// number itself, which is where they looked when it walked back (issue #87).
    func value(_ m: ChromeMetrics) -> String {
        let held = m.pinned.contains(self) ? " · pinned" : ""
        switch self {
        case .colour: return "\(m.qualityLabel) (\(m.quality))\(held)"
        case .quality: return (m.qualityEager ? "eager — quantise every tile"
                                             : "guarded — only what will not compress") + held
        case .fps: return "\(m.fpsTarget) fps\(held)"
        }
    }

    /// `rung:colour:2`. Prefixed, so it can never collide with a status segment or a bar button: the
    /// id is the widget's *name* — the hover answers it and the `--debug` line prints it — while what
    /// a click on that widget does is the `ChromeAction` it carries (`.rung(axis, step)`).
    static func id(_ axis: ChromeAxis, _ step: Int) -> String { "rung:\(axis.rawValue):\(step)" }
}

/// 0-based cells in the chrome's own grid — the drawer's coordinates, so what it painted and what a
/// report asks about are measured with one arithmetic.
struct ChromeRect: Equatable {
    var row: Int
    var col: Int
    var width: Int
    var height: Int = 1

    func contains(row y: Int, col x: Int) -> Bool {
        width > 0 && height > 0 && y >= row && y < row + height && x >= col && x < col + width
    }

    /// Rects that share at least one cell. A zero-size rect shares nothing, so a widget that painted
    /// no cells would claim no cell either.
    func intersects(_ other: ChromeRect) -> Bool {
        width > 0 && height > 0 && other.width > 0 && other.height > 0
            && col < other.col + other.width && other.col < col + width
            && row < other.row + other.height && other.row < row + height
    }
}

/// The pointer state a cell was drawn in — the third thing the renderer's diff compares, which is
/// what makes a hover re-emit exactly the cells whose look changed and no others.
enum ChromeHot: Equatable {
    case none, hover, pressed
}

/// What a click on a control does — the only place a control's behaviour lives.
///
/// The drawer writes it when it draws the control and the click path runs it
/// (`Desk.performChrome`), so no id string appears in either: a control in the table is a control
/// that does something, and a control whose *name* is misspelled cannot exist (#200).
enum ChromeAction: Equatable {
    /// A status segment: the panel it opens.
    case openPanel(ChromePanel)
    /// `[ ≡ ]`: the same button closes what it opened.
    case togglePanel(ChromePanel)
    /// `[ - ]`, the traffic lights and the title: back into the wall.
    case shrink
    /// One tick of the menu's three tracks.
    case rung(ChromeAxis, Int)
}

enum ChromeWidgetRole: Equatable {
    case control(ChromeAction)
    /// An open panel's box: the wheel scrolls it, a click does nothing.
    case panel
    /// Drawn and chrome-owned, but not a control: the bar's numbers, a separator, a clock, a toast.
    case furniture
}

/// One thing a frame drew, in the coordinates it drew it in.
///
/// **The table that draws is the table that hits** (#200). Every cell the chrome paints belongs to
/// one of these, `Chrome.route` is this list plus the row the cell is on, and the hover and the click
/// read it and nothing else — so a control cannot be drawn in one place and act in another, which is
/// what two copies of the same arithmetic always eventually were.
struct ChromeWidget: Equatable {
    var id: String
    /// Measured from the cells the paint actually wrote, clipped at the pane's edge: a title cut at
    /// the last column has the rect it was cut to, not the one it asked for.
    var rect: ChromeRect
    var role: ChromeWidgetRole
    /// Drawn and chrome-owned, but not a control: no hover, no press, and `route` answers
    /// `.background`. Exactly one widget is disabled today — the `scale` readout, which names a
    /// number nothing here can move, so it is a readout rather than a button that does nothing.
    var disabled: Bool = false
}

/// Who owns a cell — the decision the input path routes a mouse report on, and the one the hover and
/// the click both read (#200).
///
/// The order is the whole rule: the topmost widget the drawer registered at that cell (its last write
/// there wins, so a tick inside a panel's box is the tick), then the row the cell is on. A panel cell
/// or a chrome row is *not* "outside the picture" in general — with `?1016h` a one-row picture's
/// pixel box is the whole pane, so `Viewport.contains(pixel:)` answers true over the panel and the
/// wheel never reached it (#118). Hence a chrome region must never be expressed as "a cell the
/// picture does not cover".
enum ChromeRoute: Equatable {
    /// An enabled control's cell: a click does its action.
    case widget(String)
    /// An open panel's box (and the cells the box fills): the wheel scrolls it.
    case panel
    /// The chrome's own rows: nothing to click, and nothing that reaches the desktop either.
    case background
    /// Not the chrome's: the report keeps its old meaning.
    case picture
}

final class Chrome {
    private struct Cell: Equatable {
        var ch: Character = " "
        var style: Style = .plain
        /// The widget whose paint wrote this cell: an index into the frame's table, `-1` for none.
        /// It is what makes "the cells this widget drew" a fact rather than a second rectangle the
        /// painter would have to compute again.
        var widget: Int32 = -1
        /// The pointer state the widget was in while it wrote this cell. On the *cell* because the
        /// renderer's diff is per cell: a hover has to re-emit exactly what changed, and a rect copy
        /// on the widget would be the second source of truth this issue deleted.
        var hot: ChromeHot = .none
        /// The second column of a 2-cell glyph. It is part of the cell before it: never a run of
        /// its own, never trimmed as a trailing blank, and never a widget's own first column.
        var continuation = false
        var wide = false
    }

    enum Style: UInt8 {
        case plain, dim, bright, accent, warn, bad, reverse
        /// The bar is reversed end to end, so its own text needs the reverse bit too - otherwise a
        /// bright title would punch a hole in the furniture.
        case barDim, barBright
        var sgr: String {
            switch self {
            case .plain: return "0"
            case .dim: return "2;37"
            case .bright: return "1;97"
            case .accent: return "36"
            case .warn: return "33"
            case .bad: return "31"
            case .reverse: return "7"
            case .barDim: return "7;2;37"
            case .barBright: return "7;1;97"
            }
        }

        /// The SGR a cell is written with, given what the pointer is doing on it (#200).
        ///
        /// One table, and no colour arithmetic in it: a hover adds underline to the style's own
        /// weight, a press replaces the look with reverse video, and every style names its own pair.
        /// That is what lets the diff stay a per-cell comparison — two cells with the same style but
        /// different pointer states are different bytes, which is exactly what a hover repaint is.
        static func sgr(_ style: Style, _ hot: ChromeHot) -> String {
            switch hot {
            case .none:
                return style.sgr
            case .hover:
                switch style {
                case .plain, .dim: return "4;36"
                case .bright: return "1;4;97"
                case .accent: return "1;4;36"
                case .warn: return "1;4;33"
                case .bad: return "1;4;31"
                case .reverse: return "7;4;97"
                case .barDim: return "7;4;37"
                case .barBright: return "7;1;4;97"
                }
            case .pressed:
                switch style {
                case .plain, .dim: return "7;1"
                case .bright: return "7;1;97"
                case .accent: return "7;1;36"
                case .warn: return "7;1;33"
                case .bad: return "7;1;31"
                case .reverse: return "7;1;36"
                case .barDim, .barBright: return "7;1;36"
                }
            }
        }
    }

    /// One frame's paint: the grid, the table that explains it, and the size it was laid out for.
    ///
    /// Two of these exist, and the split is the whole point. `frame` is the drawing buffer, mutated
    /// cell by cell in `draw` on the main queue; `published` is the frame that *finished*, swapped in
    /// with one assignment at the end of `draw`. The reader thread (`route`, `widget`) answers from
    /// `published`, so a report that arrives mid-paint is answered by the previous frame — never by a
    /// half-built table, and never by a size that belongs to the next one.
    private struct Frame {
        var cells: [Cell] = []
        var widgets: [ChromeWidget] = []
        var cols = 0
        var rows = 0
    }

    private var frame = Frame()
    /// The last frame `draw` completed. The only thing the reader thread reads.
    private var published = Frame()
    private var prev: [Cell]?
    private var cols: Int { frame.cols }
    private var rows: Int { frame.rows }

    /// The widgets this frame drew, in drawing order.
    var widgets: [ChromeWidget] { published.widgets }

    // MARK: the table

    /// Where one widget's paint landed, in 0-based cells: the extent of the cells it wrote.
    private struct Paint {
        var row: Int, col: Int, maxRow: Int, maxCol: Int
    }

    /// The widget the paint in progress belongs to (`-1` = none) and the pointer state it is in.
    private var stampWidget: Int32 = -1
    private var stampHot: ChromeHot = .none
    /// What each widget actually painted. Its rect is this and never a second computation.
    private var painted: [Int32: Paint] = [:]
    /// The pointer this frame is drawn for, taken from the state `draw` was handed.
    private var pointer = Pointer<String>()

    // MARK: layout

    /// `imageRows`/`imageCols` come from `TileGrid`: the chrome never guesses where the picture
    /// ends, and `panelHeight` is whatever `applyLayout` left under the status line.
    ///
    /// A panel that fits sits under the status line and costs the picture nothing. A panel that
    /// does not fit gets what the pane has and the *picture* gives up the room, down to a one-row
    /// strip -- squeezing a twelve-row panel into a picture that has no slack is worse than showing
    /// a strip of picture beside a panel that says how many of its rows are above or below the
    /// window (`Chrome.panelWindow`, issue #118). The box is never drawn over the picture: this
    /// function only does arithmetic on rows the caller has already given up.
    static func layout(paneCols: Int, paneRows: Int, imageCols: Int, imageRows: Int,
                       bar: Bool = false, dev: Bool = true, panel: ChromePanel?) -> ChromeGeometry {
        let cols = max(2, paneCols)
        let rows = max(2, paneRows)
        // `imageRows` already excludes the status line and the panel (the Desk subtracts them before
        // fitting the picture), so this clamp is bookkeeping. The bar is *inside* that area: it is
        // row 0 and the picture is centred in the rows below it.
        let pictureRows = max(1, min(imageRows, rows - 1))
        var geo = ChromeGeometry(cols: cols, rows: rows, imageRows: pictureRows,
                                 imageCols: min(imageCols, cols), statusRow: pictureRows,
                                 panelTop: pictureRows + 1, panelHeight: 0,
                                 barRow: bar ? 0 : nil, devStatus: dev)
        guard let panel, geo.panelsDrawable else { return geo }
        // Desk already took these rows out of the picture before fitting it, so this is a
        // bookkeeping check: clamp instead of floating a panel over the tiles.
        let room = max(0, rows - 1 - pictureRows)
        geo.panelHeight = min(panel.height, room)
        // With no `--dev` there is no status line either, so the box starts on the row the status
        // line would have taken instead of leaving a blank one between picture and panel.
        geo.panelTop = min(dev ? pictureRows + 1 : pictureRows, rows - 1)
        return geo
    }

    /// How many rows the picture keeps when a panel is open, in a pane of `paneRows` with `bar`
    /// rows of furniture on top. `0` when the chrome is off or no panel is open.
    ///
    /// This is the one number that decides who is squeezed, so it lives here as arithmetic rather
    /// than inside the Desk's fitting step: the panel takes what it asks for and the picture keeps
    /// at least one row (a strip of the picture still says what is being mirrored, and the panel's
    /// border says which of its rows the box is not showing). The exception is a pane so short that
    /// not even a box would be drawn in it -- two borders and a row, and the drawer keeps off the
    /// pane's final row -- where the picture keeps its three rows instead of feeding a box that
    /// would never appear (#118).
    static func pictureRows(paneRows: Int, bar: Bool, panel: ChromePanel?, chrome: Bool) -> Int {
        let barRows = bar ? 1 : 0
        var rows = max(1, paneRows - barRows)
        // The same predicate `ChromeGeometry.panelsDrawable` uses -- the bar alone can open a panel
        // -- but narrower: with no panel open there is nothing to reserve, and a bar-only mirror
        // must not lose a picture row (and gain a blank one) to a box that is not there.
        guard chrome || (bar && panel != nil), rows > 4 else { return rows }
        let panelRows = panel?.height ?? 0
        // What the panel would get with a one-row picture: -1 picture, -1 status line.
        let forPanel = min(panelRows, rows - 2)
        let pictureFloor = forPanel - 1 >= 3 ? 1 : 3
        rows = max(pictureFloor, rows - 1 - min(panelRows, rows - pictureFloor - 1))
        return rows
    }

    // MARK: drawing

    func draw(geometry: ChromeGeometry, metrics m: ChromeMetrics, state: ChromeState) -> [UInt8] {
        resize(cols: geometry.cols, rows: geometry.rows)
        // A frame is painted from nothing: the table, the extents and the pointer are this draw's,
        // and a widget left over from the previous one would be a control with a stale rectangle.
        frame.widgets.removeAll(keepingCapacity: true)
        painted.removeAll(keepingCapacity: true)
        stampWidget = -1
        stampHot = .none
        pointer = state.pointer
        for y in geometry.chromeTop..<rows {
            for x in 0..<cols { set(x, y, " ", .plain) }
        }
        if let barRow = geometry.barRow {
            drawBar(row: barRow, geometry: geometry, m: m)
        }
        if geometry.devStatus {
            drawStatus(geometry: geometry, m: m, state: state)
        }
        // `panelsDrawable`, not `devStatus`: a mirror handed over as `--bar` (no `--dev`) still has
        // `[ ≡ ]`, and a click that opens a panel nothing paints is the blocker of issue #87.
        if geometry.panelsDrawable, let panel = state.panel {
            drawPanel(panel, geometry: geometry, m: m, requested: state.panelOffset)
        }
        let bytes = render(from: min(geometry.chromeTop, geometry.barRow ?? Int.max))
        // Everything above was half-built state; this one assignment is what the reader thread is
        // allowed to see, and it happens only once the frame is whole (see `Frame`).
        published = frame
        return bytes
    }

    // MARK: bar

    /// The mirror's top bar: a macOS window dressed for a terminal pane.
    ///
    /// Left: three traffic lights (decoration - `--dev` has no window to close). Middle: what is
    /// being mirrored. Right: the live rate, **the delay we measure**, the clock, and the two
    /// controls -- `[ ≡ ]`, which opens the three sliders, and `[ - ]`, which shrinks this window
    /// back into the wall it came from. One row, reversed end to end so it reads as furniture
    /// rather than as picture.
    ///
    /// The delay is `rttLabel`: the terminal's own round trip (`CSI 5n` out, `CSI 0n` back), the
    /// same series the stats panel's `rtt` row prints -- *not* `frame ms`, which is cap + pipe and
    /// stops at our last write. It carries its unit, and `— ms` when there is no measurement
    /// (probe off, or a terminal that never answers `CSI 5n`); issue #87: do not print `0`.
    ///
    /// The numbers share one ladder (`barNumbers`): fps > delay > clock > rate, so a narrow pane
    /// gives up the rate first and the delay outlives both the clock and the rate.
    private func drawBar(row: Int, geometry: ChromeGeometry, m: ChromeMetrics) {
        guard row >= 0, row < rows, cols > 0 else { return }
        // The fill is not a widget of its own: it *is* the row's background (the row rule in
        // `route` answers for it), and a widget spanning the row would claim the same cells as every
        // control drawn on it -- one cell, one owner.
        for x in 0..<cols { set(x, row, " ", .reverse) }
        // Left cluster. The dots are the macOS window buttons; a click anywhere on them does what
        // the red one does, because there is only one thing a window can do here. Three boxes, one
        // id: hovering any of them lights all three, which is what "one control" means here.
        // The title between them is furniture (see below): the window's name is not a button.
        var x = 0
        for dot in [" ● ", " ● ", " ● "] {
            paint("shrink", .control(.shrink)) { text(x, row, dot, .reverse) }
            x += DisplayWidth.of(dot)
        }
        x += 1
        // The two buttons own the right edge and are never dropped -- `[ ≡ ]` is the only way into
        // the sliders and `[ - ]` is the only way out of the window, and a bar that can only be
        // looked at is exactly what issue #87 was about.
        let button = " [ - ] "
        let menu = " [ ≡ ] "
        let buttons = DisplayWidth.of(button) + DisplayWidth.of(menu)
        let numbers = Chrome.barNumbers(room: max(0, cols - x - buttons - 1),
                                        fps: String(format: "%4.0f fps", m.fps),
                                        mbps: String(format: "%.1f MB/s", m.mbps),
                                        delay: m.delayLabel,
                                        clock: m.clock)
        // The title gets whatever the right side does not need, and is cut rather than wrapped.
        let right = buttons + (numbers.isEmpty ? 0 : DisplayWidth.of(numbers) + 2)
        let room = max(0, cols - x - right - 1)
        if room > 8 {
            let title = DisplayWidth.truncate(m.title, to: room)
            // The title is a readout, not a control: what it names is the window, and a title that
            // hovered would make the hover's cost grow with the window's name (a 400-column pane
            // would blow the 600 B budget on one crossing). The dots and `[ - ]` are the way out.
            paint("title", .furniture) { text(x, row, title, .barBright) }
        }
        var rx = cols - DisplayWidth.of(button)
        paint("shrink", .control(.shrink)) { text(rx, row, button, .barBright) }
        rx -= DisplayWidth.of(menu)
        paint("menu", .control(.togglePanel(.menu))) { text(rx, row, menu, .barBright) }
        if !numbers.isEmpty {
            rx -= DisplayWidth.of(numbers) + 2
            paint("numbers", .furniture) { text(rx, row, "  " + numbers, .barDim) }
        }
    }

    /// The bar's numbers, given the cells they have: `fps`, the rate, the delay, the clock.
    ///
    /// One list in the bar's priority order (issue #87: **fps > delay > clock > rate**), trimmed
    /// from the bottom until it fits, so a narrow pane loses the rate first and `fps` last and the
    /// delay the issue asked for outlives the clock. Pure arithmetic -- a test can ask the ladder
    /// about a width without a pane, a pty or a terminal.
    static func barNumbers(room: Int, fps: String, mbps: String, delay: String, clock: String,
                           sep: String = " · ") -> String {
        guard room > 0, !fps.isEmpty else { return "" }
        let parts = [fps, mbps, delay, clock]
        var keep = [true, true, true, !clock.isEmpty]      // fps, rate, delay, clock
        func joined() -> String {
            parts.enumerated().filter { keep[$0.offset] }.map(\.element).joined(separator: sep)
        }
        guard DisplayWidth.of(joined()) > room else { return joined() }
        // Lowest priority first: the rate, then the clock, then the delay. `fps` is never dropped -
        // it is the one number the bar always had.
        for i in [1, 3, 2] {
            keep[i] = false
            if DisplayWidth.of(joined()) <= room { break }
        }
        let text = joined()
        return DisplayWidth.of(text) <= room ? text : ""
    }

    /// Force a full repaint on the next draw (after a resize or a cleared screen).
    func invalidate() { prev = nil }

    // MARK: the table

    /// The topmost widget whose rect holds this cell (1-based), or nil.
    ///
    /// The last write wins, which is what makes the menu's ticks reachable: they are drawn after the
    /// box they sit in, so a tick is the answer and the box is what the cells around it answer. No
    /// widget's rect reaches outside the pane, so the geometry here is only the pane's extent.
    func widget(row: Int, col: Int, geometry: ChromeGeometry) -> ChromeWidget? {
        guard row >= 1, row <= geometry.rows, col >= 1, col <= geometry.cols else { return nil }
        return Chrome.topmost(published.widgets, row: row - 1, col: col - 1)
    }

    private static func topmost(_ widgets: [ChromeWidget], row: Int, col: Int) -> ChromeWidget? {
        for w in widgets.reversed() where w.rect.contains(row: row, col: col) { return w }
        return nil
    }

    /// Who owns this cell (1-based): the widget the drawer registered there, read through its role,
    /// and otherwise the row the cell sits on.
    ///
    /// The rule, in full — there is no second arithmetic of where things are, which is the whole
    /// invariant (#200):
    ///
    ///  * a cell outside the pane is nobody's, so it stays the picture's (claiming a column that does
    ///    not exist would swallow a desktop scroll);
    ///  * a widget's cell: `.widget(id)` for an enabled control, `.panel` for a box, `.background`
    ///    for furniture and for the disabled readout (drawn and chrome-owned, but inert);
    ///  * otherwise a chrome row — the bar, or at or below `chromeTop` — is `.background`: nothing to
    ///    click and nothing for the input path to hand anywhere else. It used to be `.picture`, which
    ///    made a click on the window's own furniture a *dead* cell: `chromeOwns` said no, the report
    ///    fell to the outside-the-picture branch, and the chrome's `.picture` arm dropped it. (One
    ///    pixel band at the picture's edge did reach the remote desktop, because
    ///    `Viewport.contains(pixel:)` uses closed ranges where `contains(cell:)` is half-open;
    ///    answering for chrome rows here closes that too.) A chrome row is the chrome's by layout,
    ///    painted or not: the row is the one the drawer paints, so a report that arrives before that
    ///    paint belongs to the chrome too -- it just has no control under it yet;
    ///  * otherwise the picture, whose report keeps its old meaning.
    func route(row: Int, col: Int, geometry: ChromeGeometry) -> ChromeRoute {
        // The frame the drawer *finished*, read as one value: a report that arrives mid-paint is
        // answered by the previous frame rather than by the half-built one (see `Frame`).
        let table = published
        let y = row - 1, x = col - 1
        guard row >= 1, row <= geometry.rows, col >= 1, col <= geometry.cols else { return .picture }
        if let w = Chrome.topmost(table.widgets, row: y, col: x) {
            switch w.role {
            case .control: return w.disabled ? .background : .widget(w.id)
            case .panel: return .panel
            case .furniture: return .background
            }
        }
        return y == geometry.barRow || y >= geometry.chromeTop ? .background : .picture
    }

    /// Whether a wheel notch on this widget scrolls the open panel instead of being swallowed (#87).
    ///
    /// The box's own cells always scroll it (#118), and a *rung* is still a panel cell: the menu's
    /// tracks are panel rows with a control on them, and `guard wheel == 0` in the click path used to
    /// eat exactly those notches, which is how the box's last row became unreachable at the sizes
    /// where it scrolls. The bar's and the status line's controls keep ignoring the wheel. Pure, so
    /// the rule is a test rather than a gesture.
    static func scrollsPanel(_ widget: ChromeWidget?, wheel: Int) -> Bool {
        guard wheel != 0, let widget, !widget.disabled else { return false }
        switch widget.role {
        case .panel: return true
        case .control(.rung(_, _)): return true
        case .control, .furniture: return false
        }
    }

    // MARK: cells

    private func resize(cols: Int, rows: Int) {
        guard cols != frame.cols || rows != frame.rows else { return }
        frame.cols = cols
        frame.rows = rows
        frame.cells = [Cell](repeating: Cell(), count: cols * rows)
        prev = nil
    }

    /// Paint one widget: the cells `body` writes are stamped with it, and their extent becomes its
    /// rect — the one the hover, the click and the wheel all read.
    ///
    /// A widget with nothing drawn is not registered at all: a widget in the table that no cell
    /// answers is a control that looks live and is not, and a test asks every one of them for a
    /// cell. Every call site therefore asks its own guard first (no room for a title, a segment the
    /// width ladder dropped).
    private func paint(_ id: String, _ role: ChromeWidgetRole, disabled: Bool = false,
                       _ body: () -> Void) {
        let index = Int32(frame.widgets.count)
        frame.widgets.append(ChromeWidget(id: id, rect: ChromeRect(row: 0, col: 0, width: 0),
                                          role: role, disabled: disabled))
        let saved = (stampWidget, stampHot)
        stampWidget = index
        stampHot = Chrome.hot(role, id: id, disabled: disabled, pointer: pointer)
        body()
        (stampWidget, stampHot) = saved
        guard let extent = painted.removeValue(forKey: index) else {
            // Nothing was drawn: a widget in the table that no cell answers is a control that looks
            // live and is not. Removed by index, because a body may register widgets of its own (the
            // panel's box paints its ticks), so this one need not be the last entry.
            frame.widgets.remove(at: Int(index))
            return
        }
        frame.widgets[Int(index)].rect = ChromeRect(row: extent.row, col: extent.col,
                                                    width: extent.maxCol - extent.col + 1,
                                                    height: extent.maxRow - extent.row + 1)
    }

    /// What the pointer is doing on this widget: a press beats a hover, and only a control with
    /// something to do answers the pointer at all — the `scale` readout is drawn and inert.
    private static func hot(_ role: ChromeWidgetRole, id: String, disabled: Bool,
                            pointer: Pointer<String>) -> ChromeHot {
        guard case .control = role, !disabled, id == pointer.over else { return .none }
        return pointer.down ? .pressed : .hover
    }

    private func set(_ x: Int, _ y: Int, _ ch: Character, _ style: Style) {
        guard x >= 0, y >= 0, x < cols, y < rows else { return }
        let width = DisplayWidth.of(ch)
        if width == 2 {
            // A wide glyph needs the cell after it; at the right edge it would be clipped by the
            // terminal and drag the rest of the row left, so draw a blank there instead.
            guard x + 1 < cols else {
                put(x, y, Cell(ch: " ", style: style, widget: stampWidget, hot: stampHot))
                return
            }
            put(x, y, Cell(ch: ch, style: style, widget: stampWidget, hot: stampHot, wide: true))
            put(x + 1, y, Cell(ch: " ", style: style, widget: stampWidget, hot: stampHot,
                               continuation: true))
            return
        }
        put(x, y, Cell(ch: ch, style: style, widget: stampWidget, hot: stampHot))
    }

    /// Write one cell and extend the widget the paint belongs to. The two go together: a rect that
    /// was computed separately from the cells is how a control ends up drawn in one place and hit in
    /// another, which is the bug this table replaced.
    private func put(_ x: Int, _ y: Int, _ cell: Cell) {
        frame.cells[y * cols + x] = cell
        guard stampWidget >= 0 else { return }
        guard var extent = painted[stampWidget] else {
            painted[stampWidget] = Paint(row: y, col: x, maxRow: y, maxCol: x)
            return
        }
        extent.row = min(extent.row, y)
        extent.col = min(extent.col, x)
        extent.maxRow = max(extent.maxRow, y)
        extent.maxCol = max(extent.maxCol, x)
        painted[stampWidget] = extent
    }

    private func text(_ x: Int, _ y: Int, _ s: String, _ style: Style = .plain) {
        var cx = x
        for ch in s {
            let width = DisplayWidth.of(ch)
            if width == 0 { continue }          // a lone combining mark has nothing to attach to
            if cx + width > cols { break }
            set(cx, y, ch, style)
            cx += width
        }
    }

    /// A box with the panel's title at the left of the top border and its two ways out at the
    /// right. `badge` is the row window (`1-10/16 ↕`) and is drawn between them, only when the panel
    /// has more rows than the box holds -- the marker that replaces silently dropping them (#118).
    /// The row window as it fits between the title and the two ways out: `1-10/16 ↕` where there is
    /// room for the window, `10/16 ↕` where there is only room for the count, and no marker at all
    /// on a box narrower than that -- a twenty-column pane has no space between `─ stats ─` and
    /// ` ^\ q/esc ` for anything else. Narrowing the marker is what keeps "a squeezed panel says
    /// so" true down to ~26 columns instead of ~30 (#118).
    static func panelBadge(offset: Int, inside: Int, total: Int, room: Int) -> String {
        guard total > inside, room > 0 else { return "" }
        let full = " \(offset + 1)-\(offset + inside)/\(total) ↕ "
        if DisplayWidth.of(full) <= room { return full }
        let counted = " \(offset + inside)/\(total) ↕ "
        return DisplayWidth.of(counted) <= room ? counted : ""
    }

    private func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int, title: String, badge: String = "") {
        guard w > 4, h > 2 else { return }
        text(x, y, "╭" + String(repeating: "─", count: w - 2) + "╮", .dim)
        for yy in (y + 1)..<(y + h - 1) {
            set(x, yy, "│", .dim)
            set(x + w - 1, yy, "│", .dim)
            for xx in (x + 1)..<(x + w - 1) { set(xx, yy, " ", .plain) }
        }
        text(x, y + h - 1, "╰" + String(repeating: "─", count: w - 2) + "╯", .dim)
        text(x + 2, y, " \(title) ", .bright)
        // Right-aligned, ending one cell before ` ^\ q/esc `: at a narrow pane it would otherwise
        // sit on top of the title, and two pieces of chrome text sharing a cell is the bug this
        // whole file's row arithmetic exists to avoid. Where there is no room between them the
        // badge is dropped -- the box is too narrow for a count and a way out at once.
        let badgeCells = DisplayWidth.of(badge)
        let titleEnd = x + 2 + DisplayWidth.of(" \(title) ")
        if badgeCells > 0, x + w - 9 - badgeCells > titleEnd {
            text(x + w - 9 - badgeCells, y, badge, .accent)
        }
        text(x + w - 9, y, " ^\\ q/esc ", .dim)
    }

    // MARK: status line

    /// One status segment: what to draw, how, and who owns its cells once they are drawn — an
    /// enabled control (its id and what a click on it does, together, so the two cannot name
    /// different things), the disabled `scale` readout, or the plain furniture of a separator.
    private struct Segment {
        var body: String
        var style: Style
        var id: String = ""
        var role: ChromeWidgetRole = .furniture
        /// A readout: drawn and chrome-owned, carrying the action a click *would* have if it were
        /// ever made live (the stats panel is where the scale is explained) — `disabled` is why it
        /// does not run. One kind of thing with a flag between them, not two kinds.
        var readout = false
    }

    /// Segments degrade by width instead of wrapping; every rung is a complete, valid list.
    private func segments(_ m: ChromeMetrics, prefix: Bool) -> [Segment] {
        let fpsStyle: Style = m.fpsTarget > 0 && m.fps < Double(m.fpsTarget) * 0.85 ? .warn : .plain
        let latStyle: Style = m.e2eMs > 200 ? .bad : (m.e2eMs > 110 ? .warn : .plain)
        let sep = Segment(body: "  │  ", style: .dim, id: "separator")
        // Unique ids for the two segments that open the stats panel, even though they do the same
        // thing: the hover answers a widget *id*, so two boxes sharing one id would light up together
        // and the reader could not tell which number the pointer is on (#200).
        let target = Segment(body: " \(m.target) ", style: .bright,
                             id: "target", role: .control(.openPanel(.devices)))
        let fps = Segment(body: "\(String(format: "%.1f", m.fps))/\(m.fpsTarget) fps", style: fpsStyle,
                          id: "fps", role: .control(.openPanel(.settings)))
        // Only when it is not 1: the segment then appears exactly when the picture changed quality,
        // which is the moment it has to be noticed. A readout (`readout`, i.e. `disabled`): it names
        // the scale the capture is at, and there is nothing a click on it could change here -- which
        // is why the click path never had a case for it, only an absent string.
        let scale = Segment(body: "\(String(format: "%.2g", m.scale))×",
                            style: m.scaleAuto ? .accent : .warn, id: "scale",
                            role: .control(.openPanel(.stats)), readout: true)
        let bw = Segment(body: "\(String(format: "%.1f", m.mbps)) MB/s", style: .plain,
                         id: "bandwidth", role: .control(.openPanel(.stats)))
        // `frame`, not `pipe`: since #52 this number is cap + pipe, and the bar must not call all of
        // it ours -- at 10 fps the capture half is ~50 ms on its own. With no `cap` measured the sum
        // *is* the pipe half, so the segment takes the panel's name for that half; `frame 0 ms` read
        // as a measured end to end (#117).
        let latencyName = m.capMs < 0 ? "pipe" : "frame"
        let lat = Segment(body: cols >= 84 ? "\(latencyName) \(Int(m.e2eMs)) ms"
                                          : "\(Int(m.e2eMs)) ms",
                          style: latStyle, id: "latency", role: .control(.openPanel(.stats)))
        let menu = Segment(body: prefix ? "^\\ … " : "^\\ menu ", style: .dim,
                           id: "help", role: .control(.openPanel(.help)))
        let scaled = m.scale < 0.999
        switch cols {
        case 84...: return scaled ? [target, sep, fps, sep, scale, sep, bw, sep, lat, sep, menu]
                                 : [target, sep, fps, sep, bw, sep, lat, sep, menu]
        case 46...: return scaled ? [fps, sep, scale, sep, bw, sep, lat, sep, menu]
                                 : [fps, sep, bw, sep, lat, sep, menu]
        case 30...: return scaled ? [fps, sep, scale, sep, lat, sep, menu] : [fps, sep, lat, sep, menu]
        case 20...: return scaled ? [fps, sep, scale, sep, lat] : [fps, sep, lat]
        default:
            return [Segment(body: String(format: "%.0f", m.fps), style: fpsStyle,
                            id: "fps", role: .control(.openPanel(.settings)))]
        }
    }

    private func drawStatus(geometry: ChromeGeometry, m: ChromeMetrics, state: ChromeState) {
        let y = geometry.statusRow
        guard y >= 0, y < rows, cols > 0 else { return }
        var x = 0
        for seg in segments(m, prefix: state.prefix) {
            var body = seg.body
            if x + DisplayWidth.of(body) > cols { body = DisplayWidth.truncate(body, to: max(0, cols - x)) }
            guard !body.isEmpty else { break }
            // The body actually drawn is what the widget's rect is measured from, so a segment cut by
            // the pane's edge is hit exactly where it is visible.
            paint(seg.id, seg.role, disabled: seg.readout) { text(x, y, body, seg.style) }
            x += DisplayWidth.of(body)
        }
        // The clock is the end-to-end instrument: compare it with your own and you are looking at
        // capture -> encode -> write -> ssh -> terminal, sshd's buffering included. Nothing
        // measurable from this side covers that last part.
        var right = cols - 1
        if !m.clock.isEmpty, cols >= 60 {
            right = DisplayWidth.rightAlignedStart(m.clock, cells: cols - 1)
            paint("clock", .furniture) { text(right, y, m.clock, .dim) }
            right -= 2
        }
        if let toast = state.toast, x + DisplayWidth.of(toast) + 2 < right {
            let at = max(x + 1, right - DisplayWidth.of(toast))
            paint("toast", .furniture) { text(at, y, toast, .dim) }
        }
    }

    // MARK: panels

    /// The window a panel's box shows: which content row is at its top, and how many rows the panel
    /// has in total. `requested` is where the wheel has moved the window to, or `nil` for "wherever
    /// this panel is read from" -- the top, and the end for the log.
    ///
    /// The drawer and the input path both call this, so the count in the border badge and the row
    /// the last notch stops on are one number, and a request past either end lands on that end
    /// rather than scrolling into blank rows (#118).
    /// `last` is the furthest the window can start and still be full; the input path stores its
    /// clamped answer, so a notch that lands on either end leaves the state on that end instead of
    /// one row past it.
    static func panelWindow(_ panel: ChromePanel, _ m: ChromeMetrics, inside: Int,
                            requested: Int?) -> (offset: Int, total: Int, last: Int) {
        let total = panel.contentRows(m)
        let last = max(0, total - inside)
        let start = requested ?? (panel.readsFromTheEnd ? last : 0)
        return (min(max(0, start), last), total, last)
    }

    /// One wheel notch on a panel: the offset to store, or `nil` for "wherever this panel is read
    /// from" — the log's end, which is also what keeps a log sitting on its newest line when the
    /// tail is re-read every second.
    ///
    /// This is `Chrome.panelWindow` plus one row, in one place, because the wheel and the drawer
    /// have to agree about both ends: a notch that walks off either end lands on that end (the
    /// clamp), and the notch that lands back on the log's end forgets the offset instead of pinning
    /// the old last row (#118). Separated from `Desk.scrollPanel` so a test can drive the real
    /// arithmetic without a pty, a timer or a main queue.
    static func panelScroll(_ panel: ChromePanel, _ m: ChromeMetrics, inside: Int,
                            requested: Int?, by rows: Int) -> Int? {
        let (current, _, last) = panelWindow(panel, m, inside: inside, requested: requested)
        let wanted = min(max(0, current + rows), last)
        return (panel.readsFromTheEnd && wanted == last) ? nil : wanted
    }

    /// One open panel, drawn as **one widget**: the box is what a wheel over its rows scrolls, and
    /// everything its rows hold — the title, the badge, the labels, the values — is inside the box's
    /// rect, so a cell that is not one of the menu's ticks answers `.panel` (the wheel needs that,
    /// #118) while the ticks, drawn after the box, win their own cells (issue #87).
    ///
    /// The box is named after the panel it is; that is a name, not a lookup — `route` answers it by
    /// role, so nothing downstream reads it.
    private func drawPanel(_ panel: ChromePanel, geometry: ChromeGeometry, m: ChromeMetrics,
                           requested: Int?) {
        let y = geometry.panelTop
        let inside = geometry.panelInsideRows          // h - 2, and never the final row: autowrap
        guard inside > 0, cols > 8 else { return }
        paint(panel.rawValue, .panel) {
            panelBody(panel, y: y, inside: inside, m: m, requested: requested)
        }
    }

    private func panelBody(_ panel: ChromePanel, y: Int, inside: Int, m: ChromeMetrics,
                           requested: Int?) {
        let w = cols
        let (offset, total, _) = Chrome.panelWindow(panel, m, inside: inside, requested: requested)
        // A marker, not silence: a panel with more rows than its box holds says which rows it is
        // showing and how many there are, so half a panel cannot be read as the whole one. The wheel
        // moves `offset` (`chromeClick`). The badge sits on the border because that is the row a
        // squeezed box has to spare -- the content rows are what the reader came for (#118).
        // The cells strictly between the title and ` ^\ q/esc `, which is where the marker has to fit.
        let badgeRoom = w - 9 - (2 + DisplayWidth.of(" \(panel.title) "))
        let badge = Chrome.panelBadge(offset: offset, inside: inside, total: total, room: badgeRoom)
        box(0, y, w, inside + 2, title: panel.title, badge: badge)
        /// Where content row `i` lands inside the box, or nil when the window does not hold it.
        /// Every panel walks its rows through this, so a row is either drawn at its own row or not
        /// drawn at all: the count in the badge is true by construction, and a panel that grows a
        /// row cannot push another one off the bottom without the badge saying so.
        func slot(_ i: Int) -> Int? {
            let r = i - offset
            return (r >= 0 && r < inside) ? r : nil
        }
        // The panel's three columns, in 0-based cells, named once because the budgets below are
        // derived from them: a value that could reach past the note column would paint over another
        // row's note, which is the #117 collision one axis over.
        let valueCol = 17, noteCol = 38
        func line(_ i: Int, _ label: String, _ value: String, _ note: String = "",
                  _ style: Style = .plain) {
            guard let r = slot(i) else { return }
            // A row with a note owns two columns, so its value stops one cell short of the note's. A
            // row without one keeps the full width -- that is why the `cursor`, `recording`, `log`
            // and `env` values are not cut at the note column. At a pane narrower than the note
            // column `w - 40` is 0 and that column does not exist; the value keeps its own budget
            // instead of being squeezed into it. Both cuts go through `DisplayWidth.truncate`, the
            // cell- and grapheme-aware one (#128): a cut is always an `…`, never half a glyph.
            let valueCells = note.isEmpty ? max(0, w - 20)
                : min(max(0, w - 20), max(0, noteCol - 1 - valueCol))
            text(2, y + 1 + r, DisplayWidth.pad(label, to: 14), .dim)
            text(valueCol, y + 1 + r, DisplayWidth.truncate(value, to: valueCells), style)
            if !note.isEmpty {
                text(noteCol, y + 1 + r, DisplayWidth.truncate(note, to: max(0, w - 40)), .dim)
            }
        }
        switch panel {
        case .stats:
            // Rows are counted, not written out by hand: the sparklines used to be positioned with
            // `y + 9`, which is the `pty buffer` row, so their label painted over that row's name
            // while its value and note survived (#117). A row appended now cannot land on another,
            // and `slot` puts the window on top of that: `contentRows` for this panel is the number
            // of `next()` calls below (16), and a test asks the last of them by name.
            var row = 0
            func next() -> Int { defer { row += 1 }; return row }
            line(next(), "bandwidth", String(format: "%.2f MB/s", m.mbps),
                 "\(m.kbPerFrame) KB last frame · \(m.tilesPerSec) tiles/s")
            line(next(), "frames", String(format: "%.1f / %d fps", m.fps, m.fpsTarget),
                 String(format: "capture %.1f/s · dirty %d/%d tiles", m.captureFps, m.dirty, m.tilesTotal)
                     + (m.focused ? "" : " · unfocused"),
                 m.fpsTarget > 0 && m.fps < Double(m.fpsTarget) * 0.85 ? .warn : .plain)
            // The split that answers "was it the capture or the write" (issue #52).
            let cap = m.capMs < 0 ? "cap — (no PTS)"
                : String(format: "cap %.0f p99 %.0f", m.capMs, m.capP99Ms)
            line(next(), "frame", "\(m.e2eLabel) ms",
                 String(format: "%@ · pipe %.0f p99 %.0f max %.0f", cap, m.pipeMs, m.pipeP99Ms,
                        m.pipeMaxMs))
            // The network's own share, which `pipe` cannot see: it is measured on the terminal's
            // reply, so it includes whatever is still queued in front of the picture.
            line(next(), "rtt", "\(m.rttLabel) ms",
                 m.rttAvailable ? "p99 \(m.rttP99Label) · CSI 5n round trip"
                     : (m.inputActive ? "no answer (terminal has no DSR)" : "off"))
            line(next(), "encoder", String(format: "zlib %.1f ms", m.zlibMs),
                 String(format: "write %.1f max %.1f over5 %d · q%d %@",
                        m.writeMs, m.writeMaxMs, m.writeOver5, m.quality, m.qualityLabel))
            line(next(), "capture", String(format: "%.1f/s frames", m.captureFps),
                 String(format: "skipped %.0f/s · idle %.0f/s · bad %d · total %d/%d/%d",
                        m.skippedPerSec, m.idlePerSec, m.bad, m.delivered, m.skipped, m.idle))
            line(next(), "geometry", "\(m.pxW)×\(m.pxH) px",
                 "\(m.cellsW)×\(m.cellsH) cells · cell \(Int(m.cellW))×\(Int(m.cellH)) · \(m.geometrySource)"
                 + " · scale \(String(format: "%.2g", m.scale))×"
                 + (m.scaleAuto ? " (auto)" : ""),
                 m.scale < 0.999 && m.scaleAuto ? .warn : .plain)
            line(next(), "wire", m.format,
                 "sync \(m.sync) · q=\(m.quiet) · \(m.tileSpec) cells · "
                 + "quantised \(m.quantisedTiles) raw \(m.skippedTiles)")
            let ptyRow = next()
            if m.queueBytes >= 0 {
                line(ptyRow, "pty buffer", "\(m.queueBytes) B",
                     String(format: "%.0f ms at this rate · sshd took %.1f MB/s", m.queueMs, m.drainMbps))
            } else {
                line(ptyRow, "pty buffer", "—", "TIOCOUTQ unavailable on this tty")
            }
            // The sparks are rows like any other: `line` owns the label and value columns, so a
            // hand-written column here could drift from them just as the hand-written row did.
            line(next(), "MB/s", spark(m.mbpsHistory, width: max(8, w - 20)), "", .accent)
            line(next(), "pipe", spark(m.latencyHistory, width: max(8, w - 20)), "", .warn)
            line(next(), "input",
                 m.inputActive ? String(format: "%.1f ms", m.inputMs) : "off",
                 m.dryRun ? "dry-run: parsed, never posted"
                     : String(format: "p99 %.1f · parse → CGEvent.post", m.inputP99Ms))
            line(next(), "cursor", m.cursorDrawn ? "drawn into the picture (--cursor)" : "hidden (the default)")
            line(next(), "recording", m.recording)
            line(next(), "log", m.logPath)
            line(next(), "env", m.envSwitches)
        case .settings:
            let items: [(String, String, Style)] = [
                ("--fps", "\(m.fpsTarget)", .plain),
                ("--tile", m.tileSpec, .plain),
                ("--format", m.format, .dim),
                ("--cursor", m.cursorDrawn ? "on" : "off", .plain),
                ("--no-input", m.inputActive ? "off" : "on", .dim),
                ("--dry-run", m.dryRun ? "on" : "off", .dim),
                ("--display / --window", m.target, .dim),
                ("--log", m.logPath, .dim),
            ]
            for (i, item) in items.enumerated() { line(i, item.0, item.1, "", item.2) }
            if let r = slot(items.count + 1) {
                text(2, y + 1 + r, "bold = hot (no restart) · dim = cold (restart the stream)", .dim)
            }
        case .menu:
            // Three axes, one row each: the label column every panel uses, a track of ticks, and the
            // value as it stands. Every tick is a control of its own (`rung:<axis>:<step>`), so a
            // click is the whole interaction -- no key opens this and no key moves it. The bar exists
            // on pages without `--dev` (a handed-over window mirror) and the chord table is being
            // reworked elsewhere (#180), so the mouse route has to stand on its own (issue #87).
            for (i, axis) in ChromeAxis.allCases.enumerated() {
                guard let r = slot(i) else { continue }
                let y0 = y + 1 + r
                text(2, y0, DisplayWidth.pad(axis.label, to: 14), .dim)
                let selected = axis.step(m)
                // The track keeps a value column to its right; on a narrow pane that is what gives
                // way, and a tick that is not drawn is a tick that cannot be clicked.
                let valueRoom = max(6, DisplayWidth.of(axis.value(m)) + 1)
                let track = max(1, min(axis.steps, w - valueCol - valueRoom - 1))
                for step in 0..<track {
                    let reached = step <= selected
                    // One widget per tick, and its action is what a click does: the id is only the
                    // name the hover answers and the `--debug` line prints.
                    paint(ChromeAxis.id(axis, step), .control(.rung(axis, step))) {
                        text(valueCol + step, y0, reached ? "█" : "▁",
                             step == selected ? .barBright : (reached ? .accent : .dim))
                    }
                }
                text(valueCol + track + 2, y0,
                     DisplayWidth.truncate(axis.value(m), to: max(0, w - valueCol - track - 3)),
                     .bright)
            }
            if let r = slot(ChromeAxis.allCases.count) {
                // Says the two things a reader cannot guess: how to close it, and what `pinned`
                // means -- a slider whose value walks back by itself is the worst of the options,
                // so a click pins the axis it touches (issue #87).
                text(2, y + 1 + r,
                     DisplayWidth.truncate("a click sets it and pins that axis (no governor takes "
                                           + "it back) · [ ≡ ] closes", to: max(0, w - 4)), .dim)
            }
        case .devices:
            if m.devices.isEmpty, let r = slot(0) {
                text(2, y + 1 + r, "no ScreenCaptureKit content (needs screen-recording permission)", .dim)
            }
            for (i, row) in m.devices.enumerated() {
                guard let r = slot(i) else { continue }
                let active = row.hasPrefix("*")
                text(2, y + 1 + r, DisplayWidth.truncate(String(row.dropFirst()), to: max(0, w - 4)),
                     active ? .accent : .plain)
            }
        case .log:
            if m.logTail.isEmpty, let r = slot(0) {
                text(2, y + 1 + r, "no log yet — pass --log <path> or --debug", .dim)
            }
            // The window, not the head. `panelWindow` starts a log at its end, so the newest line is
            // on screen the moment the panel opens: a reader who opens this after a failure is
            // looking for the last line, and paging to it is the bug (#118). One notch up is what
            // reaches the older lines, which is the direction a log is read backwards in.
            for (i, row) in m.logTail.enumerated() {
                guard let r = slot(i) else { continue }
                text(2, y + 1 + r, DisplayWidth.truncate(row, to: max(8, w - 4)), .dim)
            }
        case .help:
            let help: [(String, String)] = [
                ("^\\ then q", "quit"),
                ("^\\ then s", "stats panel"),
                ("^\\ then d", "displays and windows"),
                ("^\\ then f", "settings panel"),
                ("^\\ then l", "tail the log"),
                ("^\\ then ?", "this list"),
                ("click", "a status segment"),
                // The wheel takes the separator's row rather than adding one: the help panel's box
                // holds ten of its rows at 137x44, and an extra row would push `--dev` out of a
                // window that used to show it (#118).
                ("wheel", "scroll a squeezed panel"),
                ("clock", "compare it with your own: that is the real delay"),
                ("--dev", "this layer on"),
                ("--no-chrome", "force it off (scripts, CI)"),
            ]
            for (i, item) in help.enumerated() {
                guard let r = slot(i) else { continue }
                text(2, y + 1 + r, DisplayWidth.pad(item.0, to: 12), .bright)
                text(15, y + 1 + r, item.1, .plain)
            }
        }
    }

    private func spark(_ values: [Double], width: Int) -> String {
        let blocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        let v = Array(values.suffix(max(1, width)))
        guard let mx = v.max(), mx > 0 else { return String(repeating: "▁", count: v.count) }
        return String(v.map { blocks[min(7, Int(($0 / mx) * 7.999))] })
    }

    // MARK: diff renderer

    /// Positioned writes for the rows that changed. No newline, no last cell of the last row,
    /// no row above `fromRow`.
    ///
    /// A cell counts as changed when its glyph, its style **or its pointer state** differs from the
    /// previous frame, and the SGR it is written with is the pair (`Style.sgr(_:_:)`) — so a hover
    /// re-emits the cells it changed, the style around them once, and nothing else (#200: the budget
    /// only allows a repaint that is a handful of cells).
    private func render(from fromRow: Int) -> [UInt8] {
        var out = [UInt8]()
        // One snapshot of the grid: `frame` is a value, and reading `frame.cells[i]` per cell would
        // copy-check the array in every index expression.
        let cells = frame.cells, cols = frame.cols, rows = frame.rows
        var sgr: String? = nil
        for y in max(0, fromRow)..<rows {
            var x = 0
            while x < cols {
                let idx = y * cols + x
                if cells[idx].continuation { x += 1; continue }
                let changed = prev == nil || prev!.count != cells.count || prev![idx] != cells[idx]
                if !changed { x += 1; continue }
                var end = x + 1
                while end < cols {
                    let i2 = y * cols + end
                    if cells[i2].continuation { end += 1; continue }
                    if prev != nil, prev!.count == cells.count, prev![i2] == cells[i2] { break }
                    end += 1
                }
                // Trailing blanks are not written -- the terminal already has them -- *unless* that
                // cell carried text in the previous frame: then this write is the only one that can
                // erase it. Trimming blindly left the last glyph of every value that got shorter on
                // screen (`0 BB`, `56 tiles/ss`: the row then shows a number the panel never drew,
                // #118). A cell that was the covered half of a wide glyph counts as text for the
                // same reason: it leaves a half-glyph behind if nothing overwrites it. With no
                // previous frame nothing was there to erase, so the trim is free there.
                while end > x, cells[y * cols + end - 1].ch == " ",
                      !cells[y * cols + end - 1].continuation,
                      prev == nil || prev!.count != cells.count
                          || (prev![y * cols + end - 1].ch == " "
                              && !prev![y * cols + end - 1].continuation) {
                    end -= 1
                }
                if y == rows - 1 {
                    end = min(end, cols - 1)    // never arm autowrap
                    // …and never split a wide glyph across that edge either
                    if end > x, end < cols, cells[y * cols + end].continuation { end -= 1 }
                }
                if end <= x { x = max(x + 1, end + 1); continue }
                out.append(contentsOf: Array("\u{1B}[\(y + 1);\(x + 1)H".utf8))
                for i in x..<end {
                    let cell = cells[y * cols + i]
                    // The second cell of a 2-cell glyph is part of the glyph before it: the terminal
                    // already advanced two columns for that glyph, so writing the cell's blank here
                    // would push the rest of the row one column right per wide glyph -- a CJK path
                    // overflowed its column and lost the box's border (#118). It is never a run of
                    // its own (see `Cell.continuation`), so it is never written at all.
                    if cell.continuation { continue }
                    let want = Style.sgr(cell.style, cell.hot)
                    if sgr != want {
                        out.append(contentsOf: Array("\u{1B}[\(want)m".utf8))
                        sgr = want
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
