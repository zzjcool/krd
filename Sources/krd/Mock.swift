import Foundation

/// A capture source with nothing behind it: a desktop drawn in process, at `--fps`, forever.
///
/// `--mock` replaces `Capturer` with this. Everything above it is the real pipeline — the dirty
/// rects, the tile extraction, zlib, the placements, the chrome — so the only thing mocked is
/// ScreenCaptureKit. No screen-recording permission, no display, and the frames never stop.
///
/// `pixels(at:)` is a pure function of the frame index, which is what makes it useful for more
/// than looking at: a test can compare bytes, and two runs render the same sequence.
final class MockDesktop {
    private let onFrame: ([UInt8], Int, Int) -> Void
    private let fps: Int
    private let bpp: Int
    private var timer: DispatchSourceTimer?
    private var index = 0
    private var width = 0
    private var height = 0
    /// Everything that does not move between frames, so the per-frame cost is one copy plus the
    /// moving parts (a pointer and a progress bar).
    private var backdrop: [UInt8] = []
    private var frameBuffer: [UInt8] = []

    init(width: Int, height: Int, bpp: Int, fps: Int,
         onFrame: @escaping ([UInt8], Int, Int) -> Void) {
        self.onFrame = onFrame
        self.bpp = bpp == 4 ? 4 : 3
        self.fps = max(1, fps)
        resize(width: width, height: height)
    }

    /// The terminal changed size: the "display" follows it, exactly like the real capturer.
    func resize(width: Int, height: Int) {
        guard width > 8, height > 8, width != self.width || height != self.height else { return }
        self.width = width
        self.height = height
        backdrop = MockCanvas(width: width, height: height, bpp: bpp).rendered(backdrop: true)
        frameBuffer = backdrop
        index = 0
    }

    func start() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(max(1, 1000 / fps)),
                       leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.emitNext() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func emitNext() {
        guard width > 8, height > 8 else { return }
        frameBuffer = backdrop                       // COW: the copy happens on the first write
        var canvas = MockCanvas(width: width, height: height, bpp: bpp, buffer: frameBuffer)
        canvas.drawMovingParts(frame: index)
        frameBuffer = canvas.buffer
        index &+= 1
        onFrame(frameBuffer, width, height)
    }

    /// Frame `n`, without touching the timer. Deterministic by design.
    func pixels(at n: Int) -> [UInt8] {
        var canvas = MockCanvas(width: width, height: height, bpp: bpp, buffer: backdrop)
        canvas.drawMovingParts(frame: n)
        return canvas.buffer
    }
}

/// RGB(A) canvas plus the shape of the fake desktop. Colours are hand-picked to look like a Mac
/// rather than to mean anything: the point is a frame with flat areas, text-like lines, sharp
/// edges and a few saturated patches, i.e. something an encoder has to work at.
struct MockCanvas {
    let width: Int
    let height: Int
    let bpp: Int
    var buffer: [UInt8]

    init(width: Int, height: Int, bpp: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.bpp = bpp == 4 ? 4 : 3
        buffer = [UInt8](repeating: 0, count: self.width * self.height * self.bpp)
    }

    init(width: Int, height: Int, bpp: Int, buffer: [UInt8]) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.bpp = bpp == 4 ? 4 : 3
        self.buffer = buffer
    }

    // MARK: pixels

    mutating func set(_ x: Int, _ y: Int, _ r: Int, _ g: Int, _ b: Int, alpha: Double = 1) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let o = (y * width + x) * bpp
        let t = min(1, max(0, alpha))
        if t >= 1 {
            buffer[o] = UInt8(clamping: r)
            buffer[o + 1] = UInt8(clamping: g)
            buffer[o + 2] = UInt8(clamping: b)
        } else {
            buffer[o] = UInt8(clamping: Int(Double(buffer[o]) * (1 - t) + Double(r) * t))
            buffer[o + 1] = UInt8(clamping: Int(Double(buffer[o + 1]) * (1 - t) + Double(g) * t))
            buffer[o + 2] = UInt8(clamping: Int(Double(buffer[o + 2]) * (1 - t) + Double(b) * t))
        }
        if bpp == 4 { buffer[o + 3] = 255 }
    }

    mutating func row(_ y: Int, _ x0: Int, _ x1: Int, _ r: Int, _ g: Int, _ b: Int, alpha: Double = 1) {
        guard y >= 0, y < height else { return }
        let a = max(0, x0), e = min(width, x1)
        guard e > a else { return }
        if alpha >= 1 {
            var o = (y * width + a) * bpp
            for _ in a..<e {
                buffer[o] = UInt8(clamping: r)
                buffer[o + 1] = UInt8(clamping: g)
                buffer[o + 2] = UInt8(clamping: b)
                if bpp == 4 { buffer[o + 3] = 255 }
                o += bpp
            }
        } else {
            for x in a..<e { set(x, y, r, g, b, alpha: alpha) }
        }
    }

    mutating func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ r: Int, _ g: Int, _ b: Int,
                       alpha: Double = 1) {
        guard w > 0, h > 0 else { return }
        for yy in y..<(y + h) { row(yy, x, x + w, r, g, b, alpha: alpha) }
    }

    mutating func roundRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ radius: Int,
                            _ r: Int, _ g: Int, _ b: Int, alpha: Double = 1) {
        guard w > 0, h > 0 else { return }
        let rad = max(0, min(radius, min(w, h) / 2))
        for yy in 0..<h {
            let dy = min(yy, h - 1 - yy)
            var inset = 0
            if dy < rad {
                let cy = Double(rad - dy) - 0.5
                inset = rad - Int((Double(rad * rad) - cy * cy).squareRoot().rounded())
            }
            row(y + yy, x + inset, x + w - inset, r, g, b, alpha: alpha)
        }
    }

    // MARK: the fake desktop

    /// Wallpaper, menu bar, two windows and a dock. Drawn once per size.
    func rendered(backdrop: Bool) -> [UInt8] {
        var c = self
        let H = Double(height), W = Double(width)

        for y in 0..<height {
            let t = Double(y) / H
            if t < 0.55 {
                let k = t / 0.55
                c.row(y, 0, width, Int(13 + 14 * k), Int(22 + 20 * k), Int(48 + 37 * k))
            } else {
                let k = (t - 0.55) / 0.45
                c.row(y, 0, width, Int(27 + 16 * k), Int(42 - 11 * k), Int(85 - 19 * k))
            }
        }
        // a soft bloom in the upper left: a large flat area the encoder has to work through
        let bx = W * 0.20, by = H * 0.08, br = W * 0.40
        for y in 0..<Int(min(H, by + br)) {
            for x in 0..<Int(min(W, bx + br)) {
                let d = hypot(Double(x) - bx, Double(y) - by) / br
                if d < 1 { c.set(x, y, 90, 130, 210, alpha: 0.16 * (1 - d) * (1 - d)) }
            }
        }
        // menu bar
        let barH = max(16, Int(H * 0.026))
        c.rect(0, 0, width, barH, 20, 22, 30, alpha: 0.92)
        var mx = Int(W * 0.012)
        c.roundRect(mx, barH / 2 - barH / 8, Int(W * 0.012), barH / 4, barH / 8, 235, 235, 245)
        mx += Int(W * 0.022)
        for frac in [0.020, 0.016, 0.010, 0.018, 0.024] {
            let w = Int(W * frac)
            c.roundRect(mx, barH / 2 - barH / 9, w, barH / 4, barH / 9, 150, 152, 165)
            mx += w + Int(W * 0.010)
        }
        var rx = width - Int(W * 0.012)
        for frac in [0.026, 0.010, 0.016] {
            let w = Int(W * frac)
            rx -= w
            c.roundRect(rx, barH / 2 - barH / 9, w, barH / 4, barH / 9, 150, 152, 165)
            rx -= Int(W * 0.008)
        }

        // document window
        let wx = Int(W * 0.070), wy = Int(H * 0.100)
        let ww = Int(W * 0.60), wh = Int(H * 0.64)
        let radius = max(10, Int(W * 0.007))
        for step in 0..<5 {          // shadow
            let grow = step * 2
            c.roundRect(wx - grow, wy + 6 - grow, ww + grow * 2, wh + grow * 2, radius + grow,
                        0, 0, 0, alpha: 0.10 - Double(step) * 0.016)
        }
        c.roundRect(wx, wy, ww, wh, radius, 250, 250, 253)
        let titleH = max(22, Int(H * 0.030))
        c.roundRect(wx, wy, ww, titleH + radius, radius, 232, 232, 240)
        c.rect(wx, wy + titleH / 2, ww, titleH / 2, 250, 250, 253)
        let lightR = max(4, Int(H * 0.007))
        for (i, col) in [(255, 95, 87), (254, 188, 46), (40, 200, 64)].enumerated() {
            let cx = wx + Int(W * 0.013) + i * (lightR * 3)
            c.roundRect(cx, wy + titleH / 2 - lightR, lightR * 2, lightR * 2, lightR, col.0, col.1, col.2)
        }
        // sidebar
        let sideW = Int(Double(ww) * 0.20)
        c.rect(wx + 1, wy + titleH, sideW, wh - titleH - 1, 243, 243, 248)
        var sy = wy + titleH + Int(H * 0.022)
        for i in 0..<8 {
            let indent = Int(Double(sideW) * (i == 0 ? 0.10 : (i % 3 == 0 ? 0.18 : 0.26)))
            let lw = Int(Double(sideW) * (i == 0 ? 0.55 : 0.62))
            if i == 3 {
                c.roundRect(wx + 6, sy - 3, sideW - 12, max(10, Int(H * 0.016)), max(4, Int(H / 200)), 52, 120, 246)
                c.roundRect(wx + indent, sy + 1, lw, max(4, Int(H / 220)), 2, 245, 248, 255)
            } else {
                c.roundRect(wx + indent, sy, lw, max(5, Int(H / 200)), 2, 205, 205, 216)
            }
            sy += max(12, Int(H * 0.026))
        }
        // content lines
        let contentX = wx + sideW + Int(W * 0.018)
        let contentW = ww - sideW - Int(W * 0.036)
        var cy = wy + titleH + Int(H * 0.024)
        let widths: [Double] = [0.92, 0.78, 0.96, 0.55, 0.88, 0.72, 0.94, 0.61, 0.84, 0.90, 0.47, 0.76]
        for (i, frac) in widths.enumerated() {
            let lw = Int(Double(contentW) * frac)
            let lh = max(4, Int(H / 210))
            if i == 3 {
                c.roundRect(contentX, cy - 2, lw, lh + 4, lh / 2, 52, 120, 246)
                c.roundRect(contentX + 6, cy + lh / 2 - 2, max(8, Int(Double(contentW) * 0.10)),
                            max(3, lh), lh / 2, 235, 242, 255)
            } else {
                let shade = i == 0 ? 150 : 200
                c.roundRect(contentX, cy, lw, lh, lh / 2, shade, shade + 1, shade + 12)
            }
            cy += max(11, Int(H * 0.0245))
            if cy > wy + wh - Int(H * 0.03) { break }
        }

        // terminal window
        let tx = Int(W * 0.545), ty = Int(H * 0.41)
        let tw = Int(W * 0.395), th = Int(H * 0.46)
        for step in 0..<4 {
            let grow = step * 2
            c.roundRect(tx - grow, ty + 6 - grow, tw + grow * 2, th + grow * 2, radius + grow,
                        0, 0, 0, alpha: 0.12 - Double(step) * 0.02)
        }
        c.roundRect(tx, ty, tw, th, radius, 28, 28, 34)
        let tTitle = max(18, Int(H * 0.026))
        c.roundRect(tx, ty, tw, tTitle + radius, radius, 44, 44, 52)
        c.rect(tx, ty + tTitle / 2, tw, tTitle / 2, 28, 28, 34)
        for i in 0..<3 {
            let r = max(3, Int(H / 420))
            c.roundRect(tx + Int(W * 0.008) + i * (r * 3), ty + tTitle / 2 - r, r * 2, r * 2, r, 92, 92, 102)
        }
        var ly = ty + tTitle + Int(H * 0.024)
        for (i, frac) in [0.34, 0.62, 0.48, 0.72, 0.40].enumerated() {
            let lw = Int(Double(tw) * frac * 0.72)
            let lh = max(4, Int(H / 220))
            if i == 0 {
                c.roundRect(tx + Int(W * 0.016), ly, lw, lh, lh / 2, 62, 207, 106)
            } else {
                c.roundRect(tx + Int(W * 0.016), ly, lw, lh, lh / 2, 78, 78, 90)
            }
            ly += max(12, Int(H * 0.028))
        }
        // the progress bar and the cursor are the moving parts; keep their home here
        _ = ly

        // dock
        let dockH = Int(H * 0.072), dockW = Int(W * 0.30)
        let dockX = (width - dockW) / 2, dockY = height - dockH - Int(H * 0.020)
        c.roundRect(dockX, dockY, dockW, dockH, dockH / 2, 255, 255, 255, alpha: 0.13)
        c.roundRect(dockX, dockY, dockW, dockH / 2, dockH / 2, 255, 255, 255, alpha: 0.05)
        let icon = Int(Double(dockH) * 0.68)
        let palette: [(Int, Int, Int)] = [(75, 139, 255), (62, 207, 106), (255, 179, 64),
                                          (255, 95, 126), (160, 107, 255), (36, 200, 216)]
        let gap = (dockW - icon * palette.count) / (palette.count + 1)
        for (i, col) in palette.enumerated() {
            c.roundRect(dockX + gap + i * (icon + gap), dockY + (dockH - icon) / 2, icon, icon,
                        icon / 4, col.0, col.1, col.2)
        }
        return c.buffer
    }

    /// The pointer, a sweeping progress bar in the terminal window and a blinking cursor. Three
    /// different dirty-rect shapes: a diagonal walk, a growing band, and a one-cell flip.
    mutating func drawMovingParts(frame n: Int) {
        let H = Double(height), W = Double(width)
        let radius = max(10, Int(W * 0.007))

        // progress bar: 40 steps, then it starts over
        let tx = Int(W * 0.545), ty = Int(H * 0.41)
        let tw = Int(W * 0.395), th = Int(H * 0.46)
        let tTitle = max(18, Int(H * 0.026))
        let phase = Double(n % 40) / 40.0
        let barY = ty + tTitle + Int(H * 0.024) + 6 * max(12, Int(H * 0.028))
        let barH = max(5, Int(H / 200))
        if barY < ty + th - barH - 4 {
            let full = tw - Int(W * 0.032)
            rect(tx + Int(W * 0.016), barY, full, barH, 48, 48, 58)
            roundRect(tx + Int(W * 0.016), barY, max(4, Int(Double(full) * phase)), barH, barH / 2,
                      120, 168, 255)
        }

        // pointer: a black arrow with a white halo, walking a Lissajous
        let t = Double(n) * 0.055
        let px = Int(W * (0.50 + 0.36 * sin(t)))
        let py = Int(H * (0.46 + 0.26 * sin(t * 1.7 + 1.1)))
        let size = max(12, Int(H * 0.030))
        drawArrow(px - 2, py - 2, size + 3, 252, 252, 255)
        drawArrow(px, py, size, 24, 24, 30)

        // cursor blink in the terminal
        if n % 20 < 10 {
            let cx = tx + Int(W * 0.016) + Int(Double(tw) * 0.26)
            let cy = ty + tTitle + Int(H * 0.024) + max(12, Int(H * 0.028))
            rect(cx, cy, max(3, Int(W * 0.004)), max(5, Int(H / 220)), 160, 200, 255)
        }
        _ = radius
    }

    private mutating func drawArrow(_ x: Int, _ y: Int, _ size: Int, _ r: Int, _ g: Int, _ b: Int) {
        for row in 0..<size {
            let w = max(1, Int(Double(row) * 0.80))
            for col in 0...w { set(x + col, y + row, r, g, b) }
        }
        for row in (size * 6 / 10)..<(size * 5 / 4) {
            for col in (size * 22 / 100)...(size * 45 / 100) { set(x + col, y + row, r, g, b) }
        }
    }
}
