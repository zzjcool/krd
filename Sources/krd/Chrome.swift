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
}

enum ChromePanel: String, CaseIterable {
    case stats, devices, settings, log, help

    var title: String { rawValue }

    /// Rows the panel wants, before the layout decides where it fits.
    var height: Int {
        switch self {
        case .stats: return 16
        case .settings: return 12
        case .devices: return 12
        case .log: return 14
        case .help: return 13
        }
    }
}

struct ChromeState {
    var panel: ChromePanel? = nil
    /// `Ctrl-\` was pressed and the next byte is a command.
    var prefix = false
    /// A short-lived hint, right-aligned on the status line.
    var toast: String? = nil
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
    var e2eMs = 0.0
    var zlibMs = 0.0
    var zlibP99Ms = 0.0
    /// `--quality` as it stands, and the bit depth it allows: "80" and "5-6-5", or "100 lossless".
    var quality = 80
    var qualityLabel = "5-6-5"
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

enum ChromeHit: Equatable {
    case statusSegment(String)
    case insidePanel
    case outside
}

final class Chrome {
    private struct Cell: Equatable {
        var ch: Character = " "
        var style: Style = .plain
        var hit: String = ""
        /// The second column of a 2-cell glyph. It is part of the cell before it: never a run of
        /// its own, never trimmed as a trailing blank, and never the target of a click.
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
    }

    private var cells: [Cell] = []
    private var prev: [Cell]?
    private(set) var cols = 0
    private(set) var rows = 0

    // MARK: layout

    /// `imageRows`/`imageCols` come from `TileGrid`: the chrome never guesses where the picture
    /// ends. A panel sits under the status line when it fits, and otherwise takes the screen and
    /// hides the picture — squeezing a 12-row panel into a picture that has no slack is worse
    /// than not showing the picture while the panel is open.
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
        guard let panel else { return geo }
        // Desk already took these rows out of the picture before fitting it, so this is a
        // bookkeeping check: clamp instead of floating a panel over the tiles.
        let room = max(0, rows - 1 - pictureRows)
        geo.panelHeight = min(panel.height, room)
        geo.panelTop = min(pictureRows + 1, rows - 1)
        return geo
    }

    // MARK: drawing

    func draw(geometry: ChromeGeometry, metrics m: ChromeMetrics, state: ChromeState) -> [UInt8] {
        resize(cols: geometry.cols, rows: geometry.rows)
        for y in geometry.chromeTop..<rows {
            for x in 0..<cols { set(x, y, " ", .plain) }
        }
        if let barRow = geometry.barRow {
            drawBar(row: barRow, geometry: geometry, m: m)
        }
        if geometry.devStatus {
            drawStatus(geometry: geometry, m: m, state: state)
            if let panel = state.panel { drawPanel(panel, geometry: geometry, m: m) }
        }
        return render(from: min(geometry.chromeTop, geometry.barRow ?? Int.max))
    }

    // MARK: bar

    /// The mirror's top bar: a macOS window dressed for a terminal pane.
    ///
    /// Left: three traffic lights (decoration - `--dev` has no window to close). Middle: what is
    /// being mirrored. Right: the live rate, the clock, and the one control that matters, `[ - ]`,
    /// which shrinks this window back into the wall it came from. One row, reversed end to end so it
    /// reads as furniture rather than as picture.
    private func drawBar(row: Int, geometry: ChromeGeometry, m: ChromeMetrics) {
        guard row >= 0, row < rows, cols > 0 else { return }
        for x in 0..<cols { set(x, row, " ", .reverse) }
        // Left cluster. The dots are the macOS window buttons; a click anywhere on them does what
        // the red one does, because there is only one thing a window can do here.
        var x = 0
        for dot in [" ● ", " ● ", " ● "] {
            text(x, row, dot, .reverse, hit: "shrink")
            x += DisplayWidth.of(dot)
        }
        x += 1
        // The title gets whatever the right side does not need, and is cut rather than wrapped.
        let button = " [ - ] "
        let clock = m.clock.isEmpty || cols < 44 ? "" : "  " + m.clock
        let rate = cols < 66 ? "" : String(format: "%4.0f fps  ·  %.1f MB/s", m.fps, m.mbps)
        let right = DisplayWidth.of(button) + DisplayWidth.of(clock) + DisplayWidth.of(rate)
        let room = max(0, cols - x - right - 1)
        if room > 8 {
            let title = DisplayWidth.truncate(m.title, to: room)
            text(x, row, title, .barBright, hit: "shrink")
        }
        var rx = cols - DisplayWidth.of(button)
        if !clock.isEmpty {
            rx -= DisplayWidth.of(clock)
            text(rx, row, clock, .barDim)
        }
        if !rate.isEmpty, rx - DisplayWidth.of(rate) > x {
            rx -= DisplayWidth.of(rate)
            text(rx, row, rate, .barDim)
        }
        text(cols - DisplayWidth.of(button), row, button, .barBright, hit: "shrink")
    }

    /// Force a full repaint on the next draw (after a resize or a cleared screen).
    func invalidate() { prev = nil }

    /// Mouse coordinates arrive 1-based, in cells.
    func hitTest(row: Int, col: Int, geometry: ChromeGeometry) -> ChromeHit {
        let y = row - 1, x = col - 1
        guard y >= 0, y < rows, x >= 0, x < cols else { return .outside }
        // The status line and the bar are both single rows of clickable text; everything else the
        // chrome draws is either the picture (not ours) or a panel (which swallows its own clicks).
        if y == geometry.statusRow || y == geometry.barRow {
            let id = cells[y * cols + x].hit
            return id.isEmpty ? .outside : .statusSegment(id)
        }
        if geometry.panelHeight > 0,
           y >= geometry.panelTop, y < geometry.panelTop + geometry.panelHeight {
            return .insidePanel
        }
        return .outside
    }

    // MARK: cells

    private func resize(cols: Int, rows: Int) {
        guard cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        cells = [Cell](repeating: Cell(), count: cols * rows)
        prev = nil
    }

    private func set(_ x: Int, _ y: Int, _ ch: Character, _ style: Style, hit: String = "") {
        guard x >= 0, y >= 0, x < cols, y < rows else { return }
        let width = DisplayWidth.of(ch)
        if width == 2 {
            // A wide glyph needs the cell after it; at the right edge it would be clipped by the
            // terminal and drag the rest of the row left, so draw a blank there instead.
            guard x + 1 < cols else {
                cells[y * cols + x] = Cell(ch: " ", style: style, hit: hit)
                return
            }
            cells[y * cols + x] = Cell(ch: ch, style: style, hit: hit, wide: true)
            cells[y * cols + x + 1] = Cell(ch: " ", style: style, hit: hit, continuation: true)
            return
        }
        cells[y * cols + x] = Cell(ch: ch, style: style, hit: hit)
    }

    private func text(_ x: Int, _ y: Int, _ s: String, _ style: Style = .plain, hit: String = "") {
        var cx = x
        for ch in s {
            let width = DisplayWidth.of(ch)
            if width == 0 { continue }          // a lone combining mark has nothing to attach to
            if cx + width > cols { break }
            set(cx, y, ch, style, hit: hit)
            cx += width
        }
    }

    private func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int, title: String) {
        guard w > 4, h > 2 else { return }
        text(x, y, "╭" + String(repeating: "─", count: w - 2) + "╮", .dim)
        for yy in (y + 1)..<(y + h - 1) {
            set(x, yy, "│", .dim)
            set(x + w - 1, yy, "│", .dim)
            for xx in (x + 1)..<(x + w - 1) { set(xx, yy, " ", .plain) }
        }
        text(x, y + h - 1, "╰" + String(repeating: "─", count: w - 2) + "╯", .dim)
        text(x + 2, y, " \(title) ", .bright)
        text(x + w - 9, y, " ^\\ q/esc ", .dim)
    }

    // MARK: status line

    /// Segments degrade by width instead of wrapping; every rung is a complete, valid list.
    private func segments(_ m: ChromeMetrics, prefix: Bool) -> [(String, Style, String)] {
        let fpsStyle: Style = m.fpsTarget > 0 && m.fps < Double(m.fpsTarget) * 0.85 ? .warn : .plain
        let latStyle: Style = m.e2eMs > 200 ? .bad : (m.e2eMs > 110 ? .warn : .plain)
        typealias Seg = (String, Style, String)
        let sep: Seg = ("  │  ", .dim, "")
        let target: Seg = (" \(m.target) ", .bright, "target")
        let fps: Seg = ("\(String(format: "%.1f", m.fps))/\(m.fpsTarget) fps", fpsStyle, "fps")
        // Only when it is not 1: the segment then appears exactly when the picture changed quality,
        // which is the moment it has to be noticed.
        let scale: Seg = ("\(String(format: "%.2g", m.scale))×", m.scaleAuto ? .accent : .warn, "scale")
        let bw: Seg = ("\(String(format: "%.1f", m.mbps)) MB/s", .plain, "stats")
        // `frame`, not `pipe`: since #52 this number is cap + pipe, and the bar must not call all of
        // it ours -- at 10 fps the capture half is ~50 ms on its own.
        let lat: Seg = (cols >= 84 ? "frame \(Int(m.e2eMs)) ms" : "\(Int(m.e2eMs)) ms", latStyle, "stats")
        let menu: Seg = (prefix ? "^\\ … " : "^\\ menu ", .dim, "help")
        let scaled = m.scale < 0.999
        switch cols {
        case 84...: return scaled ? [target, sep, fps, sep, scale, sep, bw, sep, lat, sep, menu]
                                 : [target, sep, fps, sep, bw, sep, lat, sep, menu]
        case 46...: return scaled ? [fps, sep, scale, sep, bw, sep, lat, sep, menu]
                                 : [fps, sep, bw, sep, lat, sep, menu]
        case 30...: return scaled ? [fps, sep, scale, sep, lat, sep, menu] : [fps, sep, lat, sep, menu]
        case 20...: return scaled ? [fps, sep, scale, sep, lat] : [fps, sep, lat]
        default: return [(String(format: "%.0f", m.fps), fpsStyle, "fps")]
        }
    }

    private func drawStatus(geometry: ChromeGeometry, m: ChromeMetrics, state: ChromeState) {
        let y = geometry.statusRow
        guard y >= 0, y < rows, cols > 0 else { return }
        var x = 0
        for (body0, style, hit) in segments(m, prefix: state.prefix) {
            var body = body0
            if x + DisplayWidth.of(body) > cols { body = DisplayWidth.truncate(body, to: max(0, cols - x)) }
            guard !body.isEmpty else { break }
            text(x, y, body, style, hit: hit)
            x += DisplayWidth.of(body)
        }
        // The clock is the end-to-end instrument: compare it with your own and you are looking at
        // capture -> encode -> write -> ssh -> terminal, sshd's buffering included. Nothing
        // measurable from this side covers that last part.
        var right = cols - 1
        if !m.clock.isEmpty, cols >= 60 {
            right = DisplayWidth.rightAlignedStart(m.clock, cells: cols - 1)
            text(right, y, m.clock, .dim)
            right -= 2
        }
        if let toast = state.toast, x + DisplayWidth.of(toast) + 2 < right {
            text(max(x + 1, right - DisplayWidth.of(toast)), y, toast, .dim)
        }
    }

    // MARK: panels

    private func drawPanel(_ panel: ChromePanel, geometry: ChromeGeometry, m: ChromeMetrics) {
        let y = geometry.panelTop
        let h = min(geometry.panelHeight, rows - 1 - y)     // never the final row: autowrap
        guard h > 2, cols > 8 else { return }
        let w = cols
        box(0, y, w, h, title: panel.title)
        let inside = h - 2
        func line(_ i: Int, _ label: String, _ value: String, _ note: String = "", _ style: Style = .plain) {
            guard i < inside else { return }
            text(2, y + 1 + i, DisplayWidth.pad(label, to: 14), .dim)
            text(17, y + 1 + i, DisplayWidth.truncate(value, to: max(0, w - 20)), style)
            if !note.isEmpty {
                text(38, y + 1 + i, DisplayWidth.truncate(note, to: max(0, w - 40)), .dim)
            }
        }
        switch panel {
        case .stats:
            // Rows are counted, not written out by hand: the sparklines used to be positioned with
            // `y + 9`, which is the `pty buffer` row, so their label painted over that row's name
            // while its value and note survived (#117). A row appended now cannot land on another.
            var row = 0
            func next() -> Int { defer { row += 1 }; return row }
            line(next(), "bandwidth", String(format: "%.2f MB/s", m.mbps),
                 "\(m.kbPerFrame) KB last frame · \(m.tilesPerSec) tiles/s")
            line(next(), "frames", String(format: "%.1f / %d fps", m.fps, m.fpsTarget),
                 String(format: "capture %.1f/s · dirty %d/%d tiles", m.captureFps, m.dirty, m.tilesTotal),
                 m.fpsTarget > 0 && m.fps < Double(m.fpsTarget) * 0.85 ? .warn : .plain)
            // The split that answers "was it the capture or the write" (issue #52).
            let cap = m.capMs < 0 ? "cap — (no PTS)"
                : String(format: "cap %.0f p99 %.0f", m.capMs, m.capP99Ms)
            line(next(), "frame", "\(Int(m.e2eMs)) ms",
                 String(format: "%@ · pipe %.0f p99 %.0f", cap, m.pipeMs, m.pipeP99Ms))
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
            if inside > items.count + 1 {
                text(2, y + 2 + items.count, "bold = hot (no restart) · dim = cold (restart the stream)", .dim)
            }
        case .devices:
            if m.devices.isEmpty {
                text(2, y + 1, "no ScreenCaptureKit content (needs screen-recording permission)", .dim)
            }
            for (i, row) in m.devices.enumerated() where i < inside {
                let active = row.hasPrefix("*")
                text(2, y + 1 + i, DisplayWidth.truncate(String(row.dropFirst()), to: max(0, w - 4)),
                     active ? .accent : .plain)
            }
        case .log:
            if m.logTail.isEmpty {
                text(2, y + 1, "no log yet — pass --log <path> or --debug", .dim)
            }
            for (i, row) in m.logTail.enumerated() where i < inside {
                text(2, y + 1 + i, DisplayWidth.truncate(row, to: max(8, w - 4)), .dim)
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
                ("", ""),
                ("clock", "compare it with your own: that is the real delay"),
                ("--dev", "this layer on"),
                ("--no-chrome", "force it off (scripts, CI)"),
            ]
            for (i, item) in help.enumerated() where i < inside {
                text(2, y + 1 + i, DisplayWidth.pad(item.0, to: 12), .bright)
                text(15, y + 1 + i, item.1, .plain)
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
    private func render(from fromRow: Int) -> [UInt8] {
        var out = [UInt8]()
        var style: Style? = nil
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
                while end > x, cells[y * cols + end - 1].ch == " ", !cells[y * cols + end - 1].continuation {
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
