import Foundation

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

/// One second of numbers: the same counters the `--debug` stats line prints, plus the rates it
/// only implies and the switches that are otherwise invisible.
struct ChromeMetrics {
    var version = ""
    var target = "-"
    var fpsTarget = 20
    var fps = 0.0
    var captureFps = 0.0
    var mbps = 0.0
    var kbPerFrame = 0
    var tilesPerSec = 0
    var dirty = 0
    var tilesTotal = 0
    var capMs = 0.0
    var pipeMs = 0.0
    var pipeP99Ms = 0.0
    var e2eMs = 0.0
    var zlibMs = 0.0
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
    }

    enum Style: UInt8 {
        case plain, dim, bright, accent, warn, bad, reverse
        var sgr: String {
            switch self {
            case .plain: return "0"
            case .dim: return "2;37"
            case .bright: return "1;97"
            case .accent: return "36"
            case .warn: return "33"
            case .bad: return "31"
            case .reverse: return "7"
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
                       panel: ChromePanel?) -> ChromeGeometry {
        let cols = max(2, paneCols)
        let rows = max(2, paneRows)
        // One row is always reserved for the status line.
        let pictureRows = max(1, min(imageRows, rows - 1))
        var geo = ChromeGeometry(cols: cols, rows: rows, imageRows: pictureRows,
                                 imageCols: min(imageCols, cols), statusRow: pictureRows,
                                 panelTop: pictureRows + 1, panelHeight: 0)
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
            for x in 0..<cols { set(x, y, " ", .plain, "") }
        }
        drawStatus(geometry: geometry, m: m, state: state)
        if let panel = state.panel { drawPanel(panel, geometry: geometry, m: m) }
        return render(from: geometry.chromeTop)
    }

    /// Force a full repaint on the next draw (after a resize or a cleared screen).
    func invalidate() { prev = nil }

    /// Mouse coordinates arrive 1-based, in cells.
    func hitTest(row: Int, col: Int, geometry: ChromeGeometry) -> ChromeHit {
        let y = row - 1, x = col - 1
        guard y >= 0, y < rows, x >= 0, x < cols else { return .outside }
        if y == geometry.statusRow {
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

    private func set(_ x: Int, _ y: Int, _ ch: Character, _ style: Style, _ hit: String = "") {
        guard x >= 0, y >= 0, x < cols, y < rows else { return }
        cells[y * cols + x] = Cell(ch: ch, style: style, hit: hit)
    }

    private func text(_ x: Int, _ y: Int, _ s: String, _ style: Style = .plain, hit: String = "") {
        var cx = x
        for ch in s {
            set(cx, y, ch, style, hit)
            cx += 1
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
        let bw: Seg = ("\(String(format: "%.1f", m.mbps)) MB/s", .plain, "stats")
        let lat: Seg = ("\(Int(m.e2eMs)) ms", latStyle, "stats")
        let menu: Seg = (prefix ? "^\\ … " : "^\\ menu ", .dim, "help")
        switch cols {
        case 84...: return [target, sep, fps, sep, bw, sep, lat, sep, menu]
        case 46...: return [fps, sep, bw, sep, lat, sep, menu]
        case 30...: return [fps, sep, lat, sep, menu]
        case 20...: return [fps, sep, lat]
        default: return [(String(format: "%.0f", m.fps), fpsStyle, "fps")]
        }
    }

    private func drawStatus(geometry: ChromeGeometry, m: ChromeMetrics, state: ChromeState) {
        let y = geometry.statusRow
        guard y >= 0, y < rows, cols > 0 else { return }
        var x = 0
        for (body0, style, hit) in segments(m, prefix: state.prefix) {
            var body = body0
            if x + body.count > cols { body = String(body.prefix(max(0, cols - x))) }
            guard !body.isEmpty else { break }
            text(x, y, body, style, hit: hit)
            x += body.count
        }
        if let toast = state.toast, x + toast.count + 2 < cols {
            text(cols - toast.count - 1, y, toast, .dim)
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
            text(2, y + 1 + i, label.padding(toLength: 14, withPad: " ", startingAt: 0), .dim)
            text(17, y + 1 + i, String(value.prefix(max(0, w - 20))), style)
            if !note.isEmpty {
                text(38, y + 1 + i, String(note.prefix(max(0, w - 40))), .dim)
            }
        }
        switch panel {
        case .stats:
            line(0, "bandwidth", String(format: "%.2f MB/s", m.mbps),
                 "\(m.kbPerFrame) KB last frame · \(m.tilesPerSec) tiles/s")
            line(1, "frames", String(format: "%.1f / %d fps", m.fps, m.fpsTarget),
                 String(format: "capture %.1f/s · dirty %d/%d tiles", m.captureFps, m.dirty, m.tilesTotal),
                 m.fpsTarget > 0 && m.fps < Double(m.fpsTarget) * 0.85 ? .warn : .plain)
            let cap = m.capMs < 0 ? "cap —" : String(format: "cap %.0f", m.capMs)
            line(2, "latency e2e", "\(Int(m.e2eMs)) ms",
                 String(format: "%@ + pipe %.0f · max %.0f", cap, m.pipeMs, m.pipeP99Ms))
            line(3, "encoder", String(format: "zlib %.1f ms", m.zlibMs),
                 String(format: "write %.1f max %.1f over5 %d", m.writeMs, m.writeMaxMs, m.writeOver5))
            line(4, "capture", "\(m.callbacks)/s callbacks",
                 "delivered \(m.delivered) · skipped \(m.skipped) · idle \(m.idle) · bad \(m.bad)")
            line(5, "geometry", "\(m.pxW)×\(m.pxH) px",
                 "\(m.cellsW)×\(m.cellsH) cells · cell \(Int(m.cellW))×\(Int(m.cellH)) · \(m.geometrySource)")
            line(6, "wire", m.format, "sync \(m.sync) · q=\(m.quiet) · \(m.tileSpec) cells")
            if inside > 8 {
                text(2, y + 8, "MB/s".padding(toLength: 14, withPad: " ", startingAt: 0), .dim)
                text(17, y + 8, spark(m.mbpsHistory, width: max(8, w - 20)), .accent)
            }
            if inside > 9 {
                text(2, y + 9, "e2e".padding(toLength: 14, withPad: " ", startingAt: 0), .dim)
                text(17, y + 9, spark(m.latencyHistory, width: max(8, w - 20)), .warn)
            }
            if inside > 11 {
                line(11, "input", m.inputActive ? "active" : "off",
                     m.dryRun ? "dry-run: parsed, never posted" : "CGEvent posting")
            }
            if inside > 12 {
                line(12, "cursor", m.cursorDrawn ? "drawn into the picture (--cursor)" : "hidden (the default)")
            }
            if inside > 13 { line(13, "recording", m.recording) }
            if inside > 14 { line(14, "log", m.logPath) }
            if inside > 15 { line(15, "env", m.envSwitches) }
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
                text(2, y + 1 + i, String(row.dropFirst().prefix(max(0, w - 4))), active ? .accent : .plain)
            }
        case .log:
            if m.logTail.isEmpty {
                text(2, y + 1, "no log yet — pass --log <path> or --debug", .dim)
            }
            for (i, row) in m.logTail.enumerated() where i < inside {
                text(2, y + 1 + i, String(row.prefix(max(8, w - 4))), .dim)
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
                ("--dev", "this layer on"),
                ("--no-chrome", "force it off (scripts, CI)"),
            ]
            for (i, item) in help.enumerated() where i < inside {
                text(2, y + 1 + i, item.0.padding(toLength: 12, withPad: " ", startingAt: 0), .bright)
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
                let changed = prev == nil || prev!.count != cells.count || prev![idx] != cells[idx]
                if !changed { x += 1; continue }
                var end = x
                while end < cols {
                    let i2 = y * cols + end
                    if prev != nil, prev!.count == cells.count, prev![i2] == cells[i2] { break }
                    end += 1
                }
                while end > x, cells[y * cols + end - 1].ch == " " { end -= 1 }
                if y == rows - 1 { end = min(end, cols - 1) }   // never arm autowrap
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
