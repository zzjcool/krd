import Foundation

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

    /// Cell size in pixels, either measured or assumed (8x16 is the common default).
    var cellSize: (w: Double, h: Double) {
        if pixelWidth > 0, pixelHeight > 0 {
            return (Double(pixelWidth) / Double(cols), Double(pixelHeight) / Double(rows))
        }
        return (TermGeometry.fallbackCell.w, TermGeometry.fallbackCell.h)
    }

    var usablePixels: (w: Int, h: Int) {
        let c = cellSize
        return (Int(Double(cols) * c.w), Int(Double(rows) * c.h))
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

    /// Fit `sourceSize` (points) into the pane's usable pixels, preserving aspect.
    static func fit(source: CGSize, into geo: TermGeometry) -> (pixels: (w: Int, h: Int), cells: (c: Int, r: Int)) {
        let usable = geo.usablePixels
        let cell = geo.cellSize
        let scale = min(Double(usable.w) / max(source.width, 1), Double(usable.h) / max(source.height, 1))
        let pw = max(2, Int(source.width * scale))
        let ph = max(2, Int(source.height * scale))
        let c = max(1, min(geo.cols, Int((Double(pw) / cell.w).rounded())))
        let r = max(1, min(geo.rows, Int((Double(ph) / cell.h).rounded())))
        return ((pw, ph), (c, r))
    }

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
}

extension TermGeometry {
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
        var cell: (Int, Int)? = nil
        var window: (Int, Int)? = nil
        var buffer = [UInt8](repeating: 0, count: 256)
        while Date() < deadline, cell == nil || window == nil {
            var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let remaining = max(0, Int32(deadline.timeIntervalSinceNow * 1000))
            guard poll(&pfd, 1, remaining) > 0 else { usleep(5_000); continue }
            let n = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if n > 0 {
                response += String(decoding: buffer[0..<n], as: UTF8.self)
                if let r = parse(response, code: 6), cell == nil { cell = r }
                if let r = parse(response, code: 4), window == nil { window = r }
            } else {
                usleep(5_000)
            }
        }

        guard let cellSize = cell else { return nil }
        let pixelWidth = window.map { $0.0 } ?? cols * cellSize.0
        let pixelHeight = window.map { $0.1 } ?? rows * cellSize.1
        lastGrid = (cols, rows)
        return TermGeometry(cols: cols, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
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
