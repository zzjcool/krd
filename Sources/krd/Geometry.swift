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

    /// Does this terminal implement the two graphics capabilities krd asks about — kitty unicode
    /// placeholders (`U=1`) and kitty animation frames (`a=f`)?
    ///
    /// The wall's whole geometry question turns on the first bit. With `U=1` the *terminal* fits the
    /// image into the rectangle of placeholder cells, aspect preserved, so the picture's box is the
    /// layout and no estimate of a cell's pixel size can be wrong. Without it, krd has to guess the
    /// cell in device pixels and an image that does not match is drawn at the wrong size in the
    /// corner - the bug this replaces.
    ///
    /// The second bit is the loading card's (issue #217). A picture the terminal plays by itself
    /// costs 0 B/s after the transmit; one it does not play has to be redrawn here every 110 ms,
    /// which is the 1.4 KB per tick this issue exists for. So `a=f` is *asked*, never assumed, even
    /// of a terminal that just accepted `a=t`: drawing a picture and playing an animation are two
    /// different bits of a graphics stack, and the design's P4 (§6) makes every new capability a
    /// probe for exactly that reason. Guessing it the other way round is worse than the bytes: a
    /// card whose frames the terminal holds but never plays is a frozen mascot, and nothing in the
    /// stream says so.
    ///
    /// A reply, not an assumption: the transmits are sent with `q=2` (silent) and the two questions
    /// with `q=0`, so the only messages that come back are the answered ones' `OK` or `E...`. A
    /// terminal that ignores `U=1` draws the placeholder cells as missing-glyph boxes over the
    /// picture - much worse than a small picture - so "no answer" counts as "no". `a=f` reads the
    /// same way: no answer is a no, because the fallback card is correct and a silent animation is
    /// not.
    /// The probe's APC bodies — the *only* copy of them.
    ///
    /// `supportsPlaceholders`, `supportsAnimationFrames`, `DeleteProbeImages` and the test that
    /// walks the probe's bytes through `GraphicsAPC.isFullyEnveloped` all read this: a second
    /// literal copy is how a regression test ends up testing itself instead of the code that had
    /// the bug.
    enum GraphicsProbe {
        /// Silent, so it can only ever be an image: this is the picture the `U=1` placement below
        /// has to point at. Id 31, because 32 belongs to the animation question (see `frame32`).
        static let transmit31 = "Ga=t,f=24,s=1,v=1,q=2,i=31;AAAA"
        /// The frame probe's own image: `a=f` on `q=0` asks "can you play this?", and that needs
        /// something to play. Silent for the same reason as the one above.
        static let transmit32 = "Ga=t,f=24,s=1,v=1,q=2,i=32;AAAA"
        /// Asked (`q=0`): a terminal that plays it answers `Gi=32,r=2;OK` - the `r=` is the
        /// terminal's own echo of the animation it would keep, not something this request sent
        /// (design §2.1) - and one that does not replies `;E...`, or not at all.
        static let frame32 = "Ga=f,f=24,s=1,v=1,q=0,i=32;AAAA"
        /// Asked (`q=0`); its answer is the *last* one in the write, so it is the one the read
        /// stops on - see `runGraphicsProbeOnce` for why that order is load-bearing.
        static let place31 = "Gi=31,p=1,a=p,U=1,q=0,c=1,r=1"
        /// Both images go: a transmit nobody deletes is a picture the terminal keeps for the life
        /// of the pane, and these two carry 3 bytes of `AAAA` each that nobody will ever look at.
        static let delete = ["Ga=d,d=i,i=31", "Ga=d,d=i,i=32"]

        /// The four APCs that leave in **one** write, in the order the read depends on: the frame
        /// probe's answer arrives before the placement's (which ends the read), so a terminal that
        /// places pictures but refuses `a=f` costs no timeout.
        static var asked: [String] { [transmit31, transmit32, frame32, place31] }
    }

    /// The two verdicts for this *process*, asked exactly once (issue #99, then #217).
    ///
    /// The probe is up to 600 ms of a terminal that will not answer, and it used to be asked twice per
    /// `--wall` start - once for the mirror's tiles (a value the wall never reads) and once for the
    /// wall's pictures. Two callers asking the same terminal the same question are asking it once, so
    /// the second one sends no bytes at all. `nil` ("no answer") is memoised too: a silent terminal
    /// stays silent for the life of the process, and re-asking it is the same 600 ms again.
    ///
    /// The frame question rides along on the same write (issue #217) and shares `probeAsked`: a
    /// second probe would be a second read and, on a terminal that answers neither question, a
    /// second 600 ms - where the three extra APCs are ~90 bytes on a write that was going out
    /// anyway. So whichever of the two is asked first sends all six APCs and fills *both* memos; the
    /// other then costs nothing.
    private static var probeAsked = false
    private static var placeholdersAnswer: Bool?
    private static var animationFramesAnswer: Bool?

    /// Test seam: forget the process-wide verdicts (a test that wants to re-ask).
    static func resetGraphicsProbeCache() {
        probeAsked = false
        placeholdersAnswer = nil
        animationFramesAnswer = nil
    }

    /// The `U=1` verdict, memoised per process (`nil` = no answer, memoised too).
    static func supportsPlaceholders(timeoutMs: Int = 600) -> Bool? {
        runGraphicsProbeOnce(timeoutMs: timeoutMs)
        return placeholdersAnswer
    }

    /// The `a=f` verdict, from the same write as `supportsPlaceholders` (`nil` = no answer).
    ///
    /// The caller decides what a `nil` means; the loader treats it as "no", because the still card
    /// is correct on every terminal and an animation the terminal never plays is not.
    static func supportsAnimationFrames(timeoutMs: Int = 600) -> Bool? {
        runGraphicsProbeOnce(timeoutMs: timeoutMs)
        return animationFramesAnswer
    }

    private static func runGraphicsProbeOnce(timeoutMs: Int) {
        if probeAsked { return }
        // Every APC comes out of `GraphicsAPC`, so `--passthrough` reaches them too: inside tmux a raw
        // `a=t` is eaten by the multiplexer, which is the exact question this probe asks.
        let request = GraphicsProbe.asked.map(GraphicsAPC.sequence).joined()
        // The reply echoes whatever the request carried, so an accepted placement is `i=31,p=1;OK`
        // here - *not* `i=31;OK`. Matching the literal `i=31;OK` made every answer look like silence,
        // which sent the wall down the pixel path on a terminal that had accepted the
        // placeholder (measured against Rex: `ESC_Gi=31,p=1;OK ESC\`).
        //
        // The read stops on the *placement's* answer, the last one in the write, so the frame probe
        // has already been answered (or has stayed silent) by then and its verdict is in the same
        // buffer: a terminal that refuses `a=f` costs no timeout for saying so. In the other order
        // every terminal without `a=f` - which is most of them - would pay the full 600 ms here.
        let reply = TermCaps.ask(request, timeoutMs: timeoutMs) { text in
            placeholderProbeVerdict(text) != nil
        }
        // Only a terminal that was asked can hold the probe's images. `TermCaps.ask` writes nothing
        // without a tty on stdin (`--bench`, `--selftest`, a pipe: `krd --wall > file`), and the blind
        // delete was the one probe APC those paths still emitted — 20 bytes of cleanup for a transmit
        // that never happened (issue #197). A *silent* terminal is asked, so it still gets the
        // delete - both of them now, since the write transmits two images.
        if isatty(STDIN_FILENO) != 0 { DeleteProbeImages() }
        placeholdersAnswer = placeholderProbeVerdict(reply)
        animationFramesAnswer = animationFrameVerdict(reply)
        probeAsked = true
    }

    /// The probe's APCs, as bytes, without a terminal — built from the same bodies
    /// `supportsPlaceholders`/`supportsAnimationFrames` send and `DeleteProbeImages` deletes, so
    /// the test cannot drift from the emitter. `ProbePassthroughTests` walks this through
    /// `GraphicsAPC.isFullyEnveloped`, so a probe APC emitted outside the sink fails the suite
    /// instead of the tmux pane.
    static func graphicsProbePayload() -> [UInt8] {
        Array((GraphicsProbe.asked + GraphicsProbe.delete).map(GraphicsAPC.sequence).joined().utf8)
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

    /// What the `a=f` probe's reply means: `true` plays it, `false` refused it, `nil` no answer.
    ///
    /// Split out of the probe for the same reason as the `U=1` verdict: this is the decision the
    /// whole loading card turns on, and it has to be testable without a terminal.
    ///
    /// Two things this must *not* do, both of which have a shape a real reply produces:
    /// - read a `;OK` from someone else. Both answers start `Gi=` and both arrive in one read, and
    ///   the placement's `;OK` comes later in that string (it is the answer that ends the read). A
    ///   terminal that refused `a=f` with `Gi=32;EINVAL` and then placed the probe would otherwise
    ///   be believed, and the card would start an animation nothing plays - a frozen mascot, which
    ///   no byte count would ever show.
    /// - read past the answer itself. The verdict is the token right after this id's first `;`
    ///   (`;OK` accepted, `;E...` refused, kitty's own vocabulary), and the answer ends at its
    ///   `ESC`.
    static func animationFrameVerdict(_ reply: String?) -> Bool? {
        guard let reply, let id = reply.range(of: "i=32") else { return nil }
        let answer = reply[id.upperBound...].prefix { $0 != "\u{1B}" }
        guard let sep = answer.firstIndex(of: ";") else { return nil }
        let verdict = answer[answer.index(after: sep)...]
        if verdict.hasPrefix("OK") { return true }
        if verdict.hasPrefix("E") { return false }
        return nil
    }

    /// Remove the probe's images by id, so they can never sit on the wall as stray pixels.
    /// Same sink, same envelope: an unwrapped `a=d` inside tmux leaves the probe image on screen.
    /// Both ids, because one write transmits two images (issue #217): a leftover is a leftover
    /// whether or not its question was answered.
    private static func DeleteProbeImages() {
        for body in GraphicsProbe.delete { GraphicsAPC.write(body) }
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
    /// `refreshCaps` re-asks the terminal's capability batch even when this process already has an
    /// answer: the resize handler is the one caller, because a pane that has only now been laid out
    /// may finally answer `CSI 16t` where it said nothing at startup.
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
                        refreshCaps: Bool = false,
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
        } else if askTerminal, let measured = TermGeometry.query(timeoutMs: 500, refresh: refreshCaps) {
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
    ///
    /// One parser for the whole batch (`TermCaps.parse`, issue #197) read here as geometry: the two
    /// sizes have to mean the same thing whether they came alone or behind a `DECRQM` and a `DA1`.
    static func answers(in text: String) -> (cell: PixelSize?, window: PixelSize?) {
        let caps = TermCaps.parse(text)
        return (caps.cell.map { PixelSize(w: $0.w, h: $0.h) },
                caps.window.map { PixelSize(w: $0.w, h: $0.h) })
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

    /// The capability batch (`TermCaps.probe`), asked **once per process** (issue #197).
    ///
    /// Two callers want the same answer before the first cell: `prepareGraphemeMode` has to know the
    /// `DECRQM 2027` mode *before* the session starts (`?2027h` goes out in the same write as the
    /// alternate screen), and the wall/mirror want the cell. Asking twice would put the batch on the
    /// wire twice — two round trips where the batch exists to have one — so the answer is memoised
    /// exactly like the `U=1` verdict (`placeholdersAsked`, #99/#183). `refresh` is for the one caller
    /// whose question can genuinely change: the wall's re-measure on a resize, where a pane that has
    /// only now been laid out may finally answer.
    ///
    /// A silent terminal is memoised too: it stays silent for the life of the process, and re-asking
    /// it is the same timeout again.
    private static var capsAsked = false
    private static var capsAnswer = TermCaps.none

    static func terminalCaps(refresh: Bool = false, timeoutMs: Int = 500) -> TermCaps {
        if !refresh, capsAsked { return capsAnswer }
        capsAnswer = TermCaps.probe(timeoutMs: timeoutMs)
        capsAsked = true
        return capsAnswer
    }

    /// Ask the terminal for its geometry instead of trusting TIOCGWINSZ.
    ///
    /// Needed because a pty created by sshd (or by some terminals) reports 0 for
    /// `ws_xpixel`/`ws_ypixel`, which leaves the aspect ratio and mouse mapping guessed.
    /// `CSI 16 t` answers with the cell size in pixels, `CSI 14 t` with the window size.
    ///
    /// The question is not asked here: `TermCaps.probe` sends all **seven** questions — `16t`, `14t`,
    /// `DECRQM 2027`, `DECRQM 2031`, `OSC 10;?` (the foreground), `OSC 11;?` (the background) and the
    /// terminating `DA1` — in **one** write (issue #197's batch, widened by #213's D1), so the seven
    /// questions cost one round trip between them — on a link where a round trip is 20–40 ms, that is
    /// the difference between one wait and seven. This function is that one answer read as a grid;
    /// `lastAnswer` still says which half of it arrived, and the colours and the two modes are read
    /// off the same memoised answer by their own callers (`prepareTheme`, `prepareGraphemeMode`).
    static func query(timeoutMs: Int = 250, refresh: Bool = false) -> TermGeometry? {
        // The grid, before any bytes: a pane without a size is not a pane to ask questions of, and
        // today's behaviour is no probe at all when TIOCGWINSZ fails.
        var ws = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 else { return nil }
        let cols = Int(ws.ws_col), rows = Int(ws.ws_row)

        // The batch was asked in front of the first byte (`prepareGraphemeMode`) and its answer *is*
        // the cell's, so this reads the memo instead of writing again. Ask afresh only when the batch
        // said nothing about the size at all: that is a terminal which was too slow in front of the
        // paint, and the re-measure behind it is exactly what #99 keeps this call site for.
        var caps = terminalCaps(refresh: refresh)
        if caps.cell == nil, caps.window == nil {
            caps = terminalCaps(refresh: true, timeoutMs: timeoutMs)
        }
        let cell = caps.cell.map { PixelSize(w: $0.w, h: $0.h) }
        let window = caps.window.map { PixelSize(w: $0.w, h: $0.h) }
        guard let geometry = fromAnswers(cols: cols, rows: rows, cell: cell, window: window) else {
            lastAnswer = .none
            return nil
        }
        lastAnswer = cell != nil ? (window != nil ? .cellAndWindow : .cellOnly) : .windowOnly
        lastGrid = (cols, rows)
        return geometry
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
