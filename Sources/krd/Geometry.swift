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
    static var fallbackCell = (w: 8.0, h: 20.0)

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

    /// Cell size in pixels, either measured (CSI 16t) or assumed. 8x20 is what a default
    /// Terminal.app/Ghostty window gives; `--cell` overrides it.
    var cellSize: (w: Double, h: Double) {
        if pixelWidth > 0, pixelHeight > 0 {
            return (Double(pixelWidth) / Double(cols), Double(pixelHeight) / Double(rows))
        }
        return (TermGeometry.fallbackCell.w, TermGeometry.fallbackCell.h)
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


    /// Terminal cell (1-based, relative to the placement origin) -> global screen point.
    func point(forCell cx: Int, _ cy: Int) -> CGPoint {
        let fx = (Double(cx) - 0.5) / Double(max(cols, 1))
        let fy = (Double(cy) - 0.5) / Double(max(rows, 1))
        return CGPoint(
            x: sourceRect.minX + fx * sourceRect.width,
            y: sourceRect.minY + fy * sourceRect.height
        )
    }

    func contains(cell cx: Int, _ cy: Int) -> Bool {
        (1...max(cols, 1)).contains(cx) && (1...max(rows, 1)).contains(cy)
    }

    /// Pixel position inside the placement (SGR-Pixels mouse mode) -> global screen point.
    /// A cell is ~17x33 px here, so cell coordinates cannot address a traffic-light button;
    /// pixels can, and the terminal is asking the right question in the first place.
    func point(forPixel px: Int, _ py: Int) -> CGPoint {
        let fx = min(max(Double(px) / Double(max(pixelWidth, 1)), 0), 1)
        let fy = min(max(Double(py) / Double(max(pixelHeight, 1)), 0), 1)
        return CGPoint(
            x: sourceRect.minX + fx * sourceRect.width,
            y: sourceRect.minY + fy * sourceRect.height
        )
    }

    func contains(pixel px: Int, _ py: Int) -> Bool {
        px >= 0 && py >= 0 && px <= pixelWidth && py <= pixelHeight
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
    static func make(geometry: TermGeometry, aspect: Double, tileCols: Int, tileRows: Int,
                     bpp: Int = 3, scale: Double = 1, source: CGSize = CGSize(width: 0, height: 0)) -> TileGrid {
        let cell = geometry.cellSize
        return make(paneCols: geometry.cols, paneRows: geometry.rows,
                    cellW: cell.w, cellH: cell.h, aspect: aspect,
                    tileCols: tileCols, tileRows: tileRows, bpp: bpp, scale: scale,
                    source: source)
    }
}
