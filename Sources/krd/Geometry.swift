import Foundation
import CoreGraphics
import krdcore

/// Terminal geometry and the pixel/cell/point conversions everything else depends on.
struct TermGeometry {
    var cols: Int
    var rows: Int
    /// Pixels the pane can actually show. 0 when the terminal does not report them.
    var pixelWidth: Int
    var pixelHeight: Int

    /// Some terminals only report the pixel size once the pane has been laid out on
    /// screen (a brand-new tab can report 0). Allow an explicit cell size as fallback.
    ///
    /// 8x16 (aspect 2.0), not the 8x20 (2.5) this used to assume: 20-pixel-tall cells belong to
    /// bitmap fonts on CRTs. A modern terminal is 2.0-2.2 - Rex *says* 8x16 when asked - and the
    /// aspect is what every fit depends on: 2.5 against a real 2.0 makes the wall's stage box 25%
    /// wider than the picture it holds, and a terminal that fits (rather than stretches) then draws
    /// the desktop at 80% of the width. That was "首页还是没有全宽" on a pane that ignored `CSI 16t`.
    static var fallbackCell = (w: 8.0, h: 16.0)

    /// Grid size of the terminal we last measured. A cell coordinate can never exceed it,
    /// so it tells us for sure whether an incoming mouse report is in cells or in pixels.
    static var lastGrid = (cols: 80, rows: 24)

    static func read() -> TermGeometry {
        var ws = winsize()
        var ok = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0
        if !ok || ws.ws_col == 0 {
            ok = ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0
        }
        if !ok || ws.ws_col == 0, let tty = fopen("/dev/tty", "r") {
            ok = ioctl(fileno(tty), TIOCGWINSZ, &ws) == 0
            fclose(tty)
        }
        let grid = TermGeometry(
            cols: ok ? max(Int(ws.ws_col), 1) : 80,
            rows: ok ? max(Int(ws.ws_row), 1) : 24,
            pixelWidth: ok ? Int(ws.ws_xpixel) : 0,
            pixelHeight: ok ? Int(ws.ws_ypixel) : 0
        )
        lastGrid = (grid.cols, grid.rows)
        return grid
    }

    /// `--cell WxH`: the operator's cell, in device pixels, as a *pin* and not a fallback.
    ///
    /// It beats every measurement because the one thing an operator knows and a terminal does not is
    /// its own cell: `CSI 16t` answers in points on some terminals, an sshd pty answers 0 for
    /// `ws_xpixel`, and a terminal that lies about its cell draws a picture that is not its cells'
    /// box. Set once at startup, from the one parsed `Options` (issue #146).
    static var pinnedCell: (w: Double, h: Double)? = nil

    /// One cell in pixels: the operator's pin, else the terminal's own answer, else the fallback.
    ///
    /// **This is the only cell derivation in the program**, and it divides by the *terminal's* grid.
    /// `cols`/`rows` here are the pane's cells, so a consumer that wants a smaller box must pass the
    /// box (see `TileGrid.make(geometry:rows:...)`) and never hand this a row count that already lost
    /// rows to the mirror's bar: `ws_ypixel / (73 - 1)` built a 33.46 px cell out of a 33 px one and a
    /// frame 20 px taller than the cells it is drawn on (issue #146). Chrome is not part of a cell.
    var cellSize: (w: Double, h: Double) {
        if let pin = TermGeometry.pinnedCell { return pin }
        if pixelWidth > 0, pixelHeight > 0 {
            return (Double(pixelWidth) / Double(cols), Double(pixelHeight) / Double(rows))
        }
        return (TermGeometry.fallbackCell.w, TermGeometry.fallbackCell.h)
    }
}

/// One snapshot of the terminal a wall draws into: the grid, and what one cell is worth.
///
/// Why one type and not the three sources the wall used before (a per-tick `ioctl`, a mutable
/// `TermGeometry.fallbackCell`, and the `CSI 16t` answer cached in a static): the fit, the capture
/// size and the click mapping each read the cell from a different place, so they could each be
/// computed from a different cell. Every "the picture does not fill its box" report of the last
/// rounds is a version of that. A value, taken once at start and once per resize, cannot disagree
/// with itself.
///
/// The wall's geometry is *cells*: the layout decides them, and with unicode placeholders the
/// terminal fits the image into exactly those cells (design §6.9). `cellW`/`cellH`/`dpr` therefore
/// only decide how much *quality* the picture is captured at - never where it goes, never how big
/// its box is.
struct PaneGeometry: Equatable {
    var cols: Int
    var rows: Int
    /// One cell, in the units the pty or `CSI 16t` answered in (device pixels when the pty reports
    /// `ws_xpixel`, otherwise whatever the terminal chose to call a pixel - Rex answers points).
    var cellW: Double
    var cellH: Double
    /// Device pixels per reported pixel: the quality multiplier the pixel-sized path needs and the
    /// placeholder path ignores.
    var dpr: Double
    /// Where the cell size came from, for the one log line a bug report needs.
    var source: String

    /// A cell's height over its width, which is the shape every wall fit is written in.
    var cellAspect: Double { cellW > 0 ? cellH / cellW : 2 }

    /// The same pane, new grid (a resize without a re-measure).
    func with(cols newCols: Int, rows newRows: Int) -> PaneGeometry {
        var copy = self
        copy.cols = max(1, newCols)
        copy.rows = max(1, newRows)
        return copy
    }

    /// One cell at `scale` device pixels per reported pixel: what a picture is captured against.
    func pictureCell(scale: Double) -> (w: Double, h: Double) {
        (w: cellW * scale, h: cellH * scale)
    }
}

extension TermGeometry {
    /// Write `bytes` to the terminal and collect what comes back for up to `timeoutMs`, with stdin
    /// in raw non-blocking mode. `nil` when nothing came back. Only used before input starts (a probe
    /// steals whatever it reads, so it must not run while the mouse is live).
    static func ask(_ bytes: String, timeoutMs: Int, until: (String) -> Bool) -> String? {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        // c_cc[0]/[1] are VEOF/VEOL on macOS, not VMIN/VTIME: name them, or the fd keeps blocking.
        withUnsafeMutableBytes(of: &raw.c_cc) { p in
            p[Int(VMIN)] = 0
            p[Int(VTIME)] = 0
        }
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return nil }
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
        // The probe's bytes leave through the same sink as everything else (issue #107): one write
        // loop, and `GraphicsAPC` asserts its envelope there rather than trusting each call site.
        GraphicsAPC.writeRaw(bytes)
        var response = ""
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var buffer = [UInt8](repeating: 0, count: 256)
        while Date() < deadline, !until(response) {
            var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1000))
            guard poll(&pfd, 1, remaining) > 0 else { continue }
            let n = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if n > 0 { response += String(decoding: buffer[0..<n], as: UTF8.self) }
        }
        return response.isEmpty ? nil : response
    }

    /// Does this terminal implement kitty unicode placeholders (`U=1`)?
    ///
    /// The wall's whole geometry question turns on this one bit. With `U=1` the *terminal* fits the
    /// image into the rectangle of placeholder cells, aspect preserved, so the picture's box is the
    /// layout and no estimate of a cell's pixel size can be wrong. Without it, krd has to guess the
    /// cell in device pixels and an image that does not match is drawn at the wrong size in the
    /// corner - the bug this replaces.
    ///
    /// A reply, not an assumption: the transmit is sent with `q=2` (silent) and the placement with
    /// `q=0`, so the only message that comes back is the placement's `OK` or `E...`. A terminal that
    /// ignores `U=1` draws the placeholder cells as missing-glyph boxes over the picture - much worse
    /// than a small picture - so "no answer" counts as "no".
    /// The probe's three APC bodies — the *only* copy of them.
    ///
    /// `supportsPlaceholders`, `DeleteProbeImage` and the test that walks the probe's bytes through
    /// `GraphicsAPC.isFullyEnveloped` all read this: a second literal copy is how a regression test
    /// ends up testing itself instead of the code that had the bug.
    enum PlaceholderProbe {
        static let transmit = "Ga=t,f=24,s=1,v=1,q=2,i=31;AAAA"
        static let place = "Gi=31,p=1,a=p,U=1,q=0,c=1,r=1"
        static let delete = "Ga=d,d=i,i=31"
    }

    /// The `U=1` verdict for this *process*, asked exactly once (issue #99).
    ///
    /// The probe is up to 600 ms of a terminal that will not answer, and it used to be asked twice per
    /// `--wall` start - once for the mirror's tiles (a value the wall never reads) and once for the
    /// wall's pictures. Two callers asking the same terminal the same question are asking it once, so
    /// the second one sends no bytes at all. `nil` ("no answer") is memoised too: a silent terminal
    /// stays silent for the life of the process, and re-asking it is the same 600 ms again.
    private static var placeholdersAsked = false
    private static var placeholdersAnswer: Bool?

    /// Test seam: forget the process-wide verdict (a test that wants to re-ask).
    static func resetPlaceholderProbeCache() { placeholdersAsked = false; placeholdersAnswer = nil }

    static func supportsPlaceholders(timeoutMs: Int = 600) -> Bool? {
        if placeholdersAsked { return placeholdersAnswer }
        // Both APCs come out of `GraphicsAPC`, so `--passthrough` reaches them too: inside tmux a raw
        // `a=t` is eaten by the multiplexer, which is the exact question this probe asks.
        let transmit = GraphicsAPC.sequence(PlaceholderProbe.transmit)
        let place = GraphicsAPC.sequence(PlaceholderProbe.place)
        // The reply echoes whatever the request carried, so it is `i=31,p=1;OK` here - *not*
        // `i=31;OK`. Matching the literal `i=31;OK` made every answer look like silence, which sent
        // the wall down the pixel path on a terminal that had accepted the placeholder (measured
        // against Rex: `ESC_Gi=31,p=1;OK ESC\`).
        let reply = ask(transmit + place, timeoutMs: timeoutMs) { text in
            placeholderProbeVerdict(text) != nil
        }
        DeleteProbeImage()
        placeholdersAnswer = placeholderProbeVerdict(reply)
        placeholdersAsked = true
        return placeholdersAnswer
    }

    /// The probe's APCs, as bytes, without a terminal — built from the same three constants
    /// `supportsPlaceholders` and `DeleteProbeImage` send, so the test cannot drift from the emitter.
    /// `ProbePassthroughTests` walks this through `GraphicsAPC.isFullyEnveloped`, so a probe APC
    /// emitted outside the sink fails the suite instead of the tmux pane.
    static func placeholderProbePayload() -> [UInt8] {
        Array((GraphicsAPC.sequence(PlaceholderProbe.transmit)
               + GraphicsAPC.sequence(PlaceholderProbe.place)
               + GraphicsAPC.sequence(PlaceholderProbe.delete)).utf8)
    }

    /// What a placeholder probe's reply means: `true` accepted, `false` refused, `nil` no answer yet.
    ///
    /// Split out of the probe so the one thing that broke can be tested without a terminal: the reply
    /// echoes the request's parameters, so an accepted placement answers `i=31,p=1;OK` and *not*
    /// `i=31;OK`. Matching the short form made Rex - which accepts `U=1` - look like a terminal that
    /// ignores it, and the wall silently fell back to drawing one image pixel per device pixel with a
    /// cell reported in points: the desktop at half size in the corner of its box.
    static func placeholderProbeVerdict(_ reply: String?) -> Bool? {
        guard let reply, reply.contains("i=31") else { return nil }
        if reply.contains(";OK") { return true }
        if reply.contains(";E") { return false }
        return nil
    }

    /// Remove the probe's image by id, so it can never sit on the wall as a stray pixel.
    /// Same sink, same envelope: an unwrapped `a=d` inside tmux leaves the probe image on screen.
    private static func DeleteProbeImage() {
        GraphicsAPC.write(PlaceholderProbe.delete)
    }

    /// Ask the terminal which grapheme-clustering mode (`DECRQM 2027`) it starts in.
    ///
    /// 2027 is DEC's "grapheme clustering" mode, and it is the whole difference between the two
    /// terminals this is tested against: Ghostty 1.4.0 answers `1` (**set**, and permanently so) and
    /// Rex answers `2` (recognized, reset). With it set, the *terminal* decides where a grapheme
    /// cluster ends — VS16, ZWJ, skin-tone modifiers, regional-indicator flags — and draws one glyph
    /// in the cells it needs; with it reset, each code point is laid out on its own and a flag is two
    /// separate letters. So `☰` and `🇨🇳` are one cell on a terminal that never asked anybody, and two
    /// on the same terminal with 2027 off (measured, both terminals, `probe/termcaps.py`).
    ///
    /// A session that wants the same cell counts on both turns it on for its own duration and turns
    /// it off again on the way out — never permanently, because the mode belongs to the pane, not to
    /// krd, and the shell behind us may be a program that lays out its own clusters.
    ///
    /// **One write, two questions.** `DECRQM` and `DA1` leave together, and DA1 is the terminator:
    /// a terminal that does not implement 2027 answers *nothing* to the first question, so without a
    /// sentinel the probe would wait out its whole timeout on exactly the terminals that have no
    /// such mode. Two writes would also cost a round trip each, and over ssh a second round trip is
    /// 20–40 ms of the probe's budget (`docs/design-ui-v2.zh-CN.md` §2.2).
    static func query2027(timeoutMs: Int = 300) -> Int?
    {
        let reply = ask("\u{1B}[?2027$p\u{1B}[c", timeoutMs: timeoutMs) { text in
            containsPrimaryAttributes(text)
        }
        return graphemeModeVerdict(reply)
    }

    /// What a `DECRQM 2027` + `DA1` reply means: the mode number (`0`…`4`, DECRQM's `Ps`), or `nil`
    /// when the terminal said nothing about 2027.
    ///
    /// Split out from the probe so the parse is testable without a terminal: `?2027;1$y` (set),
    /// `?2027;2$y` (reset), `?2027;0$y` (not recognized), DA1 alone (no DECRQM support at all), and
    /// a reply split across reads all have to land on the same answer.
    static func graphemeModeVerdict(_ reply: String?) -> Int? {
        guard let reply, let start = reply.range(of: "\u{1B}[?2027;") else { return nil }
        let rest = reply[start.upperBound...]
        guard let end = rest.firstIndex(of: "$") else { return nil }
        let digits = rest[..<end]
        // `DECRQM` answers `Ps $ y`; the `$y` has to be there or this was some other report that
        // happens to start the same way, and a wrong number is worse than no number.
        guard rest[end...].hasPrefix("$y") else { return nil }
        guard let value = Int(digits), (0...4).contains(value) else { return nil }
        return value
    }

    /// Does this reply carry a `DA1` (`CSI ? … c`)? The sentinel every startup probe ends on, so a
    /// batched query has one terminator instead of one per question.
    static func containsPrimaryAttributes(_ text: String) -> Bool {
        var index = text.startIndex
        while let start = text.range(of: "\u{1B}[", range: index..<text.endIndex) {
            var cursor = start.upperBound
            guard cursor < text.endIndex, text[cursor] == "?" else {
                index = start.upperBound
                continue
            }
            cursor = text.index(after: cursor)
            var digits = false
            while cursor < text.endIndex, text[cursor].isNumber || text[cursor] == ";" {
                if text[cursor].isNumber { digits = true }
                cursor = text.index(after: cursor)
            }
            if digits, cursor < text.endIndex, text[cursor] == "c" { return true }
            index = start.upperBound
        }
        return false
    }
}

extension PaneGeometry {
    /// The one place a wall's geometry is decided: the pty's grid, the pty's pixel size if it has
    /// one, else the terminal's own `CSI 16t`/`14t` answer, else the documented fallback.
    ///
    /// `grid` is `--pane CxR` (the bench and the mock path reproduce a wall at an exact size), and
    /// `cell` is `--cell WxH` (a cell the terminal will not answer for). Both win over measurement:
    /// a report has to be reproducible.
    ///
    /// `askTerminal: false` is the wall's *first* measurement (issue #99): the first frame may be
    /// drawn before the terminal has answered `CSI 16t`/`14t`, and that query costs up to 500 ms of an
    /// empty alternate screen - or forever on a terminal that never answers. So this call takes the
    /// documented fallback cell and never sends a byte; `probeBehindTheFirstPaint` re-measures with the
    /// query right behind the paint and repaints once, and only if the answer moved the cell. `--cell`
    /// and the pty's own `ws_xpixel`/`ws_ypixel` need no query, so they still win here unchanged.
    static func measure(cell explicitCell: (w: Double, h: Double)?,
                        grid: (cols: Int, rows: Int)?,
                        dpr: Double?,
                        askTerminal: Bool = true,
                        log: (String) -> Void) -> PaneGeometry {
        let pty = TermGeometry.read()
        let cols = max(1, grid?.cols ?? pty.cols)
        let rows = max(1, grid?.rows ?? pty.rows)
        var cellW: Double, cellH: Double, source: String
        /// Is the cell already in *device* pixels? Only then may a picture be sized 1:1.
        var deviceCell = false
        if let explicitCell, explicitCell.w > 0, explicitCell.h > 0 {
            (cellW, cellH, source) = (explicitCell.w, explicitCell.h, "--cell")
            deviceCell = true        // an operator's number is the number they meant
        } else if pty.pixelWidth > 0, pty.pixelHeight > 0 {
            // The only answer that needs no second guess: the pty's own window size.
            cellW = Double(pty.pixelWidth) / Double(cols)
            cellH = Double(pty.pixelHeight) / Double(rows)
            source = "the pty's pixel size \(pty.pixelWidth)x\(pty.pixelHeight)"
            deviceCell = true
        } else if askTerminal, let measured = TermGeometry.query(timeoutMs: 500) {
            (cellW, cellH) = (measured.cellSize.w, measured.cellSize.h)
            // Neither answer may be believed as *device* pixels: the protocol says `14t` is a pixel
            // count, but a terminal that reports its cell in points reports its text area in points
            // too (measured against Rex: 8x16 and a text area that divides to 8x16, on a 16x33 device
            // cell). Only the pty's own `ws_xpixel` and an explicit `--cell` are device pixels;
            // everything else is doubled by `dpr`, which is a no-op with placeholders (quality only).
            deviceCell = false
            source = "measured from the terminal (\(TermGeometry.lastAnswer.label))"
        } else {
            (cellW, cellH) = (TermGeometry.fallbackCell.w, TermGeometry.fallbackCell.h)
            source = askTerminal ? "assumed (the terminal did not answer)"
                                 : "assumed (the cell probe runs behind the first paint)"
        }
        // Device pixels per reported pixel. With unicode placeholders this is only *quality* - the
        // terminal fits the image into the cells - so one reported pixel per cell is enough and it
        // keeps a full-width stage inside a terminal's image budget. The pixel-sized path has no
        // fitting, so there the picture must be asked for in device pixels or it is drawn small.
        let pane = PaneGeometry(cols: cols, rows: rows, cellW: cellW, cellH: cellH,
                                dpr: dpr ?? (deviceCell ? 1 : 2), source: source)
        log("krd: wall cell \(Int(cellW))x\(Int(cellH)) px, \(source)\(deviceCell ? "" : " (not device pixels)") - "
            + "\(cols)x\(rows) cells, \(pane.dpr)x pictures\n")
        return pane
    }

    /// Did the second measurement (the one with a terminal, issue #99) move anything the paint uses?
    ///
    /// Everything but `source`: `measure(askTerminal:)` names the *same* fallback cell differently on
    /// purpose, so a whole-value comparison would call a silent terminal's two identical measurements
    /// a move and repaint a first frame that nothing moved - the one thing the re-measure exists to
    /// avoid. `source` is the sentence for the log, not geometry.
    func paintsDifferently(from other: PaneGeometry) -> Bool {
        cols != other.cols || rows != other.rows
            || cellW != other.cellW || cellH != other.cellH || dpr != other.dpr
    }
}

/// Where the picture goes and how a terminal cell maps back to source points.
struct Viewport {
    /// Captured/scaled frame size in device pixels.
    var pixelWidth: Int
    var pixelHeight: Int
    /// Placement footprint in terminal cells (what we tell the terminal).
    var cols: Int
    var rows: Int
    /// Source region in global screen *points* (CGEvent coordinate space).
    var sourceRect: CGRect
    /// Where the placement starts inside the terminal: 1-based cells, and the same in window
    /// pixels. `(1, 1)` / `(0, 0)` for every picture that fills its pane; a centred picture is the
    /// one case where a report's cell is not already relative to the placement (`TileGrid.originRow`).
    var originCol: Int = 1
    var originRow: Int = 1
    var originPixelX: Int = 0
    var originPixelY: Int = 0

    /// Terminal cell (1-based, absolute in the pane) -> global screen point.
    func point(forCell cx: Int, _ cy: Int) -> CGPoint {
        let fx = (Double(cx - originCol) + 0.5) / Double(max(cols, 1))
        let fy = (Double(cy - originRow) + 0.5) / Double(max(rows, 1))
        return CGPoint(
            x: sourceRect.minX + fx * sourceRect.width,
            y: sourceRect.minY + fy * sourceRect.height
        )
    }

    /// Whether a mouse report belongs to the picture, i.e. is forwarded to the remote desktop.
    ///
    /// A **zero-size** viewport contains nothing, and that guard is load-bearing: the wall
    /// (`--wall`) has no picture, so its viewport is size zero — while `(1...max(cols, 1))` calls
    /// `(1, 1)` "inside the picture", which turned a click on the wall's own header row into a
    /// remote click at the screen origin (`Input.swift:267-279`). A viewport with no cells must
    /// never route into the remote path. No mirroring path builds a zero-size viewport
    /// (`TileGrid.make` floors the pane at 1), so today's picture cannot change from this.
    func contains(cell cx: Int, _ cy: Int) -> Bool {
        cols > 0 && rows > 0
            && (originCol..<(originCol + cols)).contains(cx)
            && (originRow..<(originRow + rows)).contains(cy)
    }

    /// Pixel position inside the placement (SGR-Pixels mouse mode) -> global screen point.
    /// A cell is ~17x33 px here, so cell coordinates cannot address a traffic-light button;
    /// pixels can, and the terminal is asking the right question in the first place.
    func point(forPixel px: Int, _ py: Int) -> CGPoint {
        let fx = min(max(Double(px - originPixelX) / Double(max(pixelWidth, 1)), 0), 1)
        let fy = min(max(Double(py - originPixelY) / Double(max(pixelHeight, 1)), 0), 1)
        return CGPoint(
            x: sourceRect.minX + fx * sourceRect.width,
            y: sourceRect.minY + fy * sourceRect.height
        )
    }

    func contains(pixel px: Int, _ py: Int) -> Bool {
        pixelWidth > 0 && pixelHeight > 0
            && (originPixelX...(originPixelX + pixelWidth)).contains(px)
            && (originPixelY...(originPixelY + pixelHeight)).contains(py)
    }

    /// The rect whose *size* caps a layout's pixel budget: the capture, not the frame it came from.
    ///
    /// `--zoom` cuts `sourceRect` down to a crop, and ScreenCaptureKit is then asked for
    /// `width`/`height` pixels of that crop. Handing the layout the *full* frame's size instead
    /// makes it ask for as many pixels as the window has, out of a crop that has fewer points: a
    /// 2x zoom got a 2x-upscaled picture at four times the bytes (issue #73). Placement is not
    /// affected — `fit` is derived from this same size, so the picture still fills the pane.
    static func layoutSource(crop: CGRect, full: CGRect) -> CGSize {
        (crop.width >= 2 && crop.height >= 2) ? crop.size : full.size
    }

    /// The part of `full` a `scale`-times zoom shows, centred on `focus`.
    ///
    /// Total by construction, because every input here comes from a display or from a pointer
    /// that may be on another monitor: a non-finite scale or focus falls back to the whole
    /// rect, a scale below 1 means "no zoom", and the origin is clamped so the crop never
    /// leaves `full`. A crop smaller than one point is widened to one point -- ScreenCaptureKit
    /// rejects a zero-sized sourceRect and a 1-point crop still fills the pane.
    static func crop(full: CGRect, scale: Double, focus: CGPoint) -> CGRect {
        guard full.width > 0, full.height > 0 else { return full }
        let factor = (scale.isFinite && scale > 1) ? scale : 1
        let width = min(max(full.width / factor, 1), full.width)
        let height = min(max(full.height / factor, 1), full.height)
        let fx = focus.x.isFinite ? focus.x : full.midX
        let fy = focus.y.isFinite ? focus.y : full.midY
        let x = min(max(fx - width / 2, full.minX), full.maxX - width)
        let y = min(max(fy - height / 2, full.minY), full.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// A pixel size a terminal reported: one cell (`CSI 16 t`) or the whole window (`CSI 14 t`).
struct PixelSize: Equatable {
    var w: Int
    var h: Int
}

extension TermGeometry {
    /// Which question the terminal actually answered. `windowOnly` is the case in issue #56: the
    /// cell is derived from the window and the grid, and `--debug` says so.
    enum Answer {
        case cellAndWindow, cellOnly, windowOnly, none

        /// What `--debug` prints for `geometrySource`.
        var label: String {
            switch self {
            case .cellAndWindow: return "CSI 16t+14t"
            case .cellOnly: return "CSI 16t"
            case .windowOnly: return "CSI 14t (cell derived)"
            case .none: return "-"
            }
        }

        /// Did the terminal tell us its text area in *pixels* (`CSI 14t`)? A cell divided out of
        /// that is a device pixel cell, which is the only kind a picture can be sized 1:1 against.
        var sawWindowPixels: Bool {
            self == .windowOnly || self == .cellAndWindow
        }
    }

    /// Which of the two answers `query()` last produced.
    static var lastAnswer: Answer = .none

    /// The two answers out of a raw response string. Half an answer is not an answer: a sequence
    /// only counts once its terminating `t` has arrived, which is also what makes a truncated
    /// `ESC[14;600;800` harmless.
    static func answers(in text: String) -> (cell: PixelSize?, window: PixelSize?) {
        let cell = parse(text, code: 6).map { PixelSize(w: $0.0, h: $0.1) }
        let window = parse(text, code: 4).map { PixelSize(w: $0.0, h: $0.1) }
        return (cell, window)
    }

    /// The geometry those answers imply, or nil when the terminal answered neither question.
    ///
    /// `CSI 16 t` wins when both arrived — it is the number the terminal computed itself. With only
    /// `CSI 14 t` the cell is derived from the window and the grid (issue #56): strictly better
    /// information than the 8x20 constant, and the same arithmetic `cellSize` already applies to
    /// TIOCGWINSZ's pixel fields. A 137x44 pane that answers 2329x1452 comes out at exactly the
    /// 17x33 cell it really is, instead of 8x20 and a 1096x880 picture.
    static func fromAnswers(cols: Int, rows: Int, cell: PixelSize?, window: PixelSize?) -> TermGeometry? {
        guard cols > 0, rows > 0 else { return nil }
        if let cell {
            return TermGeometry(cols: cols, rows: rows,
                                pixelWidth: window?.w ?? cols * cell.w,
                                pixelHeight: window?.h ?? rows * cell.h)
        }
        if let window {
            return TermGeometry(cols: cols, rows: rows, pixelWidth: window.w, pixelHeight: window.h)
        }
        return nil
    }

    /// Ask the terminal for its geometry instead of trusting TIOCGWINSZ.
    ///
    /// Needed because a pty created by sshd (or by some terminals) reports 0 for
    /// `ws_xpixel`/`ws_ypixel`, which leaves the aspect ratio and mouse mapping guessed.
    /// `CSI 16 t` answers with the cell size in pixels, `CSI 14 t` with the window size.
    static func query(timeoutMs: Int = 250) -> TermGeometry? {
        let fd = STDOUT_FILENO
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        // NOTE: c_cc[0]/[1] are VEOF/VEOL on macOS, not VMIN/VTIME -- setting those leaves
        // the fd in blocking mode, which hangs the whole startup. Name them explicitly.
        withUnsafeMutableBytes(of: &raw.c_cc) { p in
            p[Int(VMIN)] = 0
            p[Int(VTIME)] = 0
        }
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return nil }
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &original) }

        var ws = winsize()
        guard ioctl(fd, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 else { return nil }
        let cols = Int(ws.ws_col), rows = Int(ws.ws_row)

        func writeAll(_ text: String) {
            let bytes = Array(text.utf8)
            bytes.withUnsafeBufferPointer { buf in
                var off = 0
                while off < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                    if n <= 0 { return }
                    off += n
                }
            }
        }
        writeAll("\u{1B}[16t\u{1B}[14t")     // cell size, then window size, in pixels

        var response = ""
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var cell: PixelSize? = nil
        var window: PixelSize? = nil
        var buffer = [UInt8](repeating: 0, count: 256)
        while Date() < deadline, cell == nil || window == nil {
            var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let remaining = max(0, Int32(deadline.timeIntervalSinceNow * 1000))
            guard poll(&pfd, 1, remaining) > 0 else { usleep(5_000); continue }
            let n = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if n > 0 {
                response += String(decoding: buffer[0..<n], as: UTF8.self)
                let answers = answers(in: response)
                if let r = answers.cell, cell == nil { cell = r }
                if let r = answers.window, window == nil { window = r }
            } else {
                usleep(5_000)
            }
        }

        guard let geometry = fromAnswers(cols: cols, rows: rows, cell: cell, window: window) else {
            lastAnswer = .none
            return nil
        }
        lastAnswer = cell != nil ? (window != nil ? .cellAndWindow : .cellOnly) : .windowOnly
        lastGrid = (cols, rows)
        return geometry
    }

    private static func parse(_ text: String, code: Int) -> (Int, Int)? {
        // \e[<code>;<height>;<width>t
        let pattern = "\u{1B}[\(code);"
        guard let start = text.range(of: pattern) else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: "t") else { return nil }
        let parts = rest[..<end].split(separator: ";")
        guard parts.count == 2, let h = Int(parts[0]), let w = Int(parts[1]), h > 0, w > 0 else { return nil }
        return (w, h)
    }
}

extension TileGrid {
    /// `TermGeometry` owns the tty and stays in this module; the arithmetic is `krdcore`'s
    /// (issue #21). Same numbers in, same grid out — call sites did not change.
    ///
    /// `rows` is how many rows the picture may use — the pane minus the bar and the panels. It
    /// decides the *box* (`paneRows`, the fit, the tile count) and **not the cell**: the cell is read
    /// off `geometry`'s own grid, which is the terminal's. That split is the whole of issue #146; the
    /// old shape (a `TermGeometry` whose `rows` had been reassigned) fed the chrome budget into
    /// `cellH` and made the frame a fraction of a row taller than the cells it covers.
    static func make(geometry: TermGeometry, rows pictureRows: Int? = nil,
                     aspect: Double, tileCols: Int, tileRows: Int,
                     bpp: Int = 3, scale: Double = 1, fillsCells: Bool = false,
                     source: CGSize = CGSize(width: 0, height: 0),
                     area: (top: Int, left: Int, cols: Int, rows: Int)? = nil) -> TileGrid {
        let cell = geometry.cellSize
        return make(paneCols: geometry.cols, paneRows: max(1, pictureRows ?? geometry.rows),
                    cellW: cell.w, cellH: cell.h, aspect: aspect,
                    tileCols: tileCols, tileRows: tileRows, bpp: bpp, scale: scale,
                    fillsCells: fillsCells, source: source, area: area)
    }
}
