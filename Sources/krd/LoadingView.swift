import Foundation
import krdcore

/// The mascot card krd shows while the first frame is still in flight.
///
/// One picture, two transports — and the transport is decided once, by a probe, never guessed.
///
/// **The terminal animates it when it can** (`animates: true`, i.e. the `a=f` probe answered yes;
/// issue #217, design §4.3's last bullet and §5.1's "加载动画 < 4 KB/s" row). The old card rasterised
/// 36×36 dots and wrote them as `▀` with per-cell 24-bit SGR **every 110 ms** — ~22.6 KB and 9.09
/// ticks a second on a 137×44 pane, measured, i.e. ~205 KB/s for a picture with four poses. So the
/// four frames are now transmitted *once*: `start()` writes a single `?2026h … ?2026l` block carrying
/// the four frames as `a=t`/`a=f` (gap 220 ms), the two `a=a` that start the loop, and one
/// pixel-sized placement; after that the card writes **0 bytes until `stop()`**, because the
/// animation runs inside the terminal. The budget is met by construction rather than by shrinking the
/// picture: the cost is one transmit (~1.8 KB of base64 here) and then 0 B/s.
///
/// The frames are the *even* steps of `peek` — `shapes(2 * i)` for i in 0..<4 — so 4 × 220 ms is the
/// same 880 ms blink as 8 × 110 ms was, and the blink itself is not redesigned (D1). The pixel box is
/// derived from the cell the caller measured, not from a constant, so the picture's pixel aspect
/// equals the cell box's whichever way the terminal scales it (D2, `pictureHeight`).
///
/// **The card animates it when it cannot** (`animates: false`: no `a=f`, or the probe said nothing):
/// exactly today's card, byte for byte — the `▀` mosaic, the 110 ms `DispatchSourceTimer`, the
/// `frame % 4` ellipsis (D5). Deliberately not optimised here: a terminal that cannot animate has to
/// get what it always got, because a degrade that also changes the picture is a second bug on a path
/// nobody can reproduce remotely. `tick()` is that timer's handler, exposed so the fallback's cost
/// can be measured (`LoadingViewTests`) without a clock.
///
/// The drawing itself is twelve shapes from four primitives (ellipse, rounded rect, capsule,
/// polygon), rasterised at 2×2 samples per pixel. That is deliberately small: this file is the whole
/// reason the mascot can be redrawn from scratch in Swift instead of being shipped as an image.
///
/// `stop()` is idempotent and is called from the frame path: the first frame that lands takes the
/// card away, nothing else does. On the animated path it also deletes the image by id — a
/// pixel-sized placement is *not* erased by clearing cells, so the row clears alone would leave a
/// mascot floating over the picture that just arrived — and forgets the `IconCache` entry, so a
/// second card in this process re-transmits instead of placing an image the terminal no longer holds
/// (D4). Every APC goes through `GraphicsAPC.sequence` (#107: the tmux envelope is ambient, so it
/// cannot be walked around) and every one of them is `q=2`, so nothing here can put a reply on stdin
/// after `startInput()` owns it.
final class LoadingView {
    // MARK: geometry

    private struct P { var x: Double; var y: Double }
    private struct RGB { var r: UInt8; var g: UInt8; var b: UInt8 }

    private enum Shape {
        case ellipse(P, Double, Double, RGB)
        case rect(P, Double, Double, Double, RGB)          // x, y, w, h, radius
        case capsule([P], Double, RGB)
        case poly([P], RGB)
    }

    // The mascot's own colours: sand shell, coral crab, one brand-blue glint.
    private static let sand = RGB(r: 0xD9, g: 0xC4, b: 0xA1)
    private static let cream = RGB(r: 0xF4, g: 0xE7, b: 0xCC)
    private static let brown = RGB(r: 0x8A, g: 0x6A, b: 0x46)
    private static let brownDeep = RGB(r: 0x5B, g: 0x45, b: 0x30)
    private static let coral = RGB(r: 0xF1, g: 0x8A, b: 0x5E)
    private static let ink = RGB(r: 0x06, g: 0x08, b: 0x0D)
    private static let light = RGB(r: 0xE8, g: 0xF1, b: 0xFF)
    private static let blue = RGB(r: 0x5E, g: 0xB8, b: 0xFF)
    private static let paper = RGB(r: 0x08, g: 0x0A, b: 0x10)

    /// How far the crab is out of its shell, per frame. One blink, not a pulse: a sine looks like a
    /// piston, an eye that closes once looks like it is waiting for you.
    private static let peek: [Double] = [0.05, 0.45, 0.8, 1, 1, 1, 0.8, 0.45]

    private static let dotW = 36, dotH = 36                 // dots; two dots per cell row
    private static let margin = 4.0                          // 96-unit space

    /// 220 ms: the gap the terminal plays the four frames at. Half of the old 110 ms tick because
    /// the animation now carries the even steps of `peek`, so 4 × 220 = 880 ms is the cycle the
    /// mosaic had at 8 × 110 (D1). The gap lives on the `a=f` frames and on the `a=a` that starts
    /// the loop — a base image carries no gap of its own, so without the second one nothing plays.
    private static let frameGapMs = 220

    /// The dot grid's cell box: 36 columns, 18 rows. The animated path places the picture over it,
    /// so both transports cover the same cells (and `stop()` clears the same 20 rows for both).
    private static let cellCols = dotW, cellRows = dotH / 2

    // MARK: state

    private let writeText: (String) -> Void
    private let paneCols: Int
    private let paneRows: Int
    /// Which transport this card got, decided once by the probe before the card exists (D5). Never
    /// re-decided here: the picture path and the mosaic path draw different things, and a mid-flight
    /// switch would leave the terminal holding an image nobody deletes.
    private(set) var animates: Bool
    /// The cell the caller measured. Only the animated path reads it (`pictureHeight`); the mosaic is
    /// expressed in cells and needs no pixel size.
    private let cell: (w: Double, h: Double)
    private let cache: IconCache
    private let palette: UInt64
    private var timer: DispatchSourceTimer?
    private var frame = 0
    private var painted = false
    /// The image the terminal is holding, while it holds it: the id `stop()` has to delete, and the
    /// graphic `IconCache.forget` needs to drop the book. `nil` on the mosaic path (`animates:
    /// false`) and after `stop()` — the two states in which there is nothing to take away.
    private var picture: (id: Int, graphic: IconCache.Graphic)?

    init(paneCols: Int, paneRows: Int, cell: (w: Double, h: Double),
         animates: Bool = false, cache: IconCache = IconCache(), paletteKey: UInt64 = 0,
         write: @escaping (String) -> Void) {
        self.paneCols = paneCols
        self.paneRows = paneRows
        self.cell = cell
        self.animates = animates
        self.cache = cache
        self.palette = paletteKey
        self.writeText = write
    }

    private var originRow: Int { max(0, (paneRows - (Self.cellRows + 2)) / 2) }
    private var originCol: Int { max(0, (paneCols - Self.cellCols) / 2) + 1 }

    func start() {
        guard timer == nil, !painted else { return }
        if animates {
            startPicture()
        } else {
            paint()
            startMosaic()
        }
    }

    /// The fallback's clock: unchanged from before #217, 110 ms repeating, and it exists only on
    /// this path. The picture path has no timer at all — that *is* the saving.
    private func startMosaic() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(110), repeating: .milliseconds(110))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        if let t = timer {
            t.cancel()
            timer = nil
        }
        guard painted else { return }
        painted = false
        // Clear exactly what we drew: the card's rows, nothing else. The frame path owns the rest.
        var out = ""
        for row in 0..<(Self.cellRows + 2) {
            out += "\u{1B}[\(originRow + row + 1);1H\u{1B}[2K"
        }
        // A pixel-sized placement is not part of the text grid: blanking the cells under it leaves
        // the picture on screen, floating over the frame that just arrived, until something else
        // deletes it — and the writer's own `clear()` runs before the card, not after it (D4).
        if let picture {
            out += GraphicsAPC.sequence("Gi=\(picture.id),a=d,d=i,i=\(picture.id)")
            cache.forget(picture.graphic, palette: palette)
            self.picture = nil
        }
        out += "\u{1B}[\(originRow + 1);1H"
        writeText(out)
    }

    /// One beat of the fallback's animation: exactly what the timer's handler has always done.
    ///
    /// Exposed because it is the only way to measure the mosaic without a clock — the budget is
    /// judged on bytes per tick, and a test that slept 110 ms nine times would be a test that fails
    /// on a loaded machine (D3's note; issue #217's acceptance). On the picture path a tick writes
    /// nothing: the terminal owns the animation, so there is nothing to repaint.
    func tick() {
        guard !animates else { return }
        frame += 1
        paint()
    }

    // MARK: the picture (the terminal animates it)

    /// The one write of the animated card: blank the card's rows, park the cursor on the picture's
    /// cell box, hand over the frames and the placement, and label it.
    ///
    /// The `?2026` block is the caller's, not the cache's (`IconCache.Emit` says so): a nested pair
    /// would end this block early, and the whole point of one block is that a slow link never shows
    /// half a card — twenty blank rows with no mascot in them.
    ///
    /// The label is written *after* the picture and outside the block, the way a re-place is: text is
    /// cheap and it must not be able to disturb a transmit that is still assembling.
    private func startPicture() {
        let graphic = makeGraphic()
        let emit = cache.draw(graphic, palette: palette,
                              at: .pixels(cols: Self.cellCols, rows: Self.cellRows))
        // `id 0` is the cache refusing the picture (a frame that will not compress): there is then
        // nothing on screen to delete, and `a=d,i=0` would be a delete of nothing.
        if emit.id > 0 { picture = (emit.id, graphic) }
        painted = true
        var out = "\u{1B}[?2026h"
        for row in 0..<(Self.cellRows + 2) {
            out += "\u{1B}[\(originRow + row + 1);1H\u{1B}[2K"
        }
        out += "\u{1B}[\(originRow + 1);\(originCol)H"
        out += emit.bytes
        out += "\u{1B}[?2026l"
        out += labels()
        writeText(out)
    }

    /// The four frames, at the size the terminal's own scaler wants (D1/D2).
    ///
    /// `IconCache.Graphic` compresses, chunks and numbers them: the id bookkeeping lives in krdcore
    /// so that a second card (or the chrome, later) can place an image this one already sent.
    private func makeGraphic() -> IconCache.Graphic {
        let height = Self.pictureHeight(cellW: cell.w, cellH: cell.h)
        let frames = (0..<4).map { i in
            IconImage(width: Self.dotW, height: height,
                      pixels: Self.bytes(Self.raster(Self.shapes(2 * i),
                                                     width: Self.dotW, height: height)))
        }
        return IconCache.Graphic(frames: frames, gapMs: Self.frameGapMs)
    }

    /// The picture's pixel height from the cell the caller measured (D2).
    ///
    /// `36 × round(36 · cellH / (2 · cellW))`: the dot grid is 36 dots across a 36-cell box and 36
    /// dot rows down its 18 rows, so a picture whose *pixel* aspect equals that box's *cell* aspect
    /// is 36 wide and `18 · cellH / cellW` tall — 45 on an 8×20 cell, 35 on a 17×33 one. That is the
    /// whole point of deriving it from `cell:` instead of hard-coding it: a terminal that stretches
    /// a `c`/`r` placement to fill the box and one that fits it with the aspect preserved then agree
    /// with each other, and both agree with the mosaic the fallback draws.
    ///
    /// The guard is not arithmetic paranoia: `Int(_:)` traps on infinity, so a `0 x 0` cell (a pane
    /// that has not been measured yet) would crash the one card that is painted *before* anything
    /// else is proven. 45 is the 8×20 cell's own answer, which is what an unmeasured pane gets.
    private static func pictureHeight(cellW: Double, cellH: Double) -> Int {
        guard cellW > 0, cellH > 0 else { return 45 }
        return max(1, Int((Double(dotW) * cellH / (2 * cellW)).rounded()))
    }

    private static func bytes(_ dots: [RGB]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(dots.count * 3)
        for dot in dots {
            out.append(dot.r)
            out.append(dot.g)
            out.append(dot.b)
        }
        return out
    }

    // MARK: the mosaic (the card animates it)

    private func paint() {
        let shapes = Self.shapes(frame)
        let dots = Self.raster(shapes, width: Self.dotW, height: Self.dotH)
        var out = ""
        for row in 0..<Self.cellRows {
            out += "\u{1B}[\(originRow + row + 1);1H\u{1B}[2K"
            out += String(repeating: " ", count: originCol)
            for col in 0..<Self.dotW {
                let top = dots[(row * 2) * Self.dotW + col]
                let bottom = dots[(row * 2 + 1) * Self.dotW + col]
                out += "\u{1B}[38;2;\(top.r);\(top.g);\(top.b);48;2;\(bottom.r);\(bottom.g);\(bottom.b)m▀"
            }
            out += "\u{1B}[0m"
        }
        out += labels()
        painted = true
        writeText(out)
    }

    /// The two caption rows, in the card's own colours, centred on the dot grid.
    ///
    /// `frame` drives the ellipsis and nothing else, which is why the picture path can write this
    /// once: frame 0 is the bare label, and there is no second frame to add a dot to. Keeping the
    /// pulse here (rather than in `paint`) is what makes "the fallback is unchanged, byte for byte"
    /// a property of one function that both paths call.
    private func labels() -> String {
        let label = "waiting for first frame" + String(repeating: ".", count: (frame % 4))
        let sub = "krd · connecting"
        let pad = max(0, (Self.dotW - label.count) / 2)
        var out = "\u{1B}[\(originRow + Self.cellRows + 1);1H\u{1B}[2K"
        out += String(repeating: " ", count: originCol + pad)
        out += "\u{1B}[38;2;140;150;170m\(label)\u{1B}[0m"
        let pad2 = max(0, (Self.dotW - sub.count) / 2)
        out += "\u{1B}[\(originRow + Self.cellRows + 2);1H\u{1B}[2K"
        out += String(repeating: " ", count: originCol + pad2)
        out += "\u{1B}[38;2;88;98;118m\(sub)\u{1B}[0m"
        return out
    }

    // MARK: the mascot

    private static func shapes(_ i: Int) -> [Shape] {
        let p = peek[i % peek.count]
        let blink = i % peek.count == 4
        var s: [Shape] = [
            .ellipse(P(x: 37, y: 53), 32, 31, brownDeep),
            .ellipse(P(x: 36, y: 50), 30, 28, sand),
            .capsule(spiral(36, 50, 23, 10, 1.05, -2.6), 9, brown),
            .capsule(spiral(36, 50, 26, 3, 1.75, -0.35), 4.4, cream),
            .capsule(spiral(36, 50, 23.5, 2, 1.75, -0.15), 2.2, brown),
            .ellipse(P(x: 61, y: 58), 14, 18, brownDeep),
            .capsule([P(x: 51, y: 37), P(x: 46, y: 58), P(x: 54, y: 78)], 7, sand),
            .ellipse(P(x: 70, y: 60 + (1 - p) * 2), 13, 14, coral),
        ]
        let eyeY = 44 + (1 - p) * 14, eyeY2 = eyeY - 3
        s.append(.capsule([P(x: 67, y: 52), P(x: 63, y: eyeY)], 6.5, coral))
        s.append(.capsule([P(x: 78, y: 50), P(x: 84, y: eyeY2)], 6.5, coral))
        if blink {
            s.append(.ellipse(P(x: 61, y: eyeY), 9.5, 2.2, cream))
            s.append(.ellipse(P(x: 85, y: eyeY2), 9.5, 2.2, cream))
            s.append(.ellipse(P(x: 61, y: eyeY), 9.5, 0.9, ink))
            s.append(.ellipse(P(x: 85, y: eyeY2), 9.5, 0.9, ink))
        } else {
            s.append(.ellipse(P(x: 61, y: eyeY), 9.5, 9.5, cream))
            s.append(.ellipse(P(x: 62.5, y: eyeY + 0.5), 5.2, 5.2, ink))
            s.append(.ellipse(P(x: 64.5, y: eyeY - 3), 2.2, 2.2, light))
            s.append(.ellipse(P(x: 60.5, y: eyeY + 3), 1.4, 1.4, blue))
            s.append(.ellipse(P(x: 85, y: eyeY2), 9.5, 9.5, cream))
            s.append(.ellipse(P(x: 86.5, y: eyeY2 + 0.5), 5.2, 5.2, ink))
            s.append(.ellipse(P(x: 88.5, y: eyeY2 - 3), 2.2, 2.2, light))
            s.append(.ellipse(P(x: 84.5, y: eyeY2 + 3), 1.4, 1.4, blue))
        }
        return s
    }

    private static func spiral(_ cx: Double, _ cy: Double, _ r0: Double, _ r1: Double,
                               _ turns: Double, _ a0: Double, _ steps: Int = 64) -> [P] {
        (0...steps).map { i in
            let t = Double(i) / Double(steps)
            let a = a0 + t * turns * 2 * .pi
            let r = r0 + (r1 - r0) * t
            return P(x: cx + cos(a) * r, y: cy + sin(a) * r)
        }
    }

    // MARK: raster

    /// 2×2 samples per pixel, over the 96-unit drawing space, zoomed out to 0.72 so nothing clips.
    ///
    /// `width`/`height` are the destination's own pixels, and the two callers want different ones:
    /// the mosaic asks for the 36×36 **dot grid** (one dot is one half block), the picture asks for
    /// the 36×`pxH` image the terminal will scale. One rasteriser, because the alternative is two
    /// drawings that drift — the mascot would change shape the day one of them was touched. Rendering
    /// the picture at its own size rather than resampling the dot grid also keeps the edges sharp:
    /// interpolating 36 dot rows up to 45 would blur a picture that is about to be scaled to 288×360
    /// anyway.
    private static func raster(_ shapes: [Shape], width: Int, height: Int) -> [RGB] {
        var dots = [RGB](repeating: paper, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var r = 0, g = 0, b = 0, n = 0
                for sy in 0..<2 {
                    for sx in 0..<2 {
                        let u0 = margin + ((Double(x) + (Double(sx) + 0.5) / 2) / Double(width)) * 88
                        let v0 = margin + ((Double(y) + (Double(sy) + 0.5) / 2) / Double(height)) * 88
                        let u = 48 + (u0 - 48) / 0.72, v = 48 + (v0 - 48) / 0.72
                        guard let c = colour(shapes, u, v) else { continue }
                        r += Int(c.r); g += Int(c.g); b += Int(c.b); n += 1
                    }
                }
                let k = Double(n) / 4
                if n > 0 {
                    dots[y * width + x] = RGB(
                        r: UInt8(Double(r / n) * k + Double(paper.r) * (1 - k)),
                        g: UInt8(Double(g / n) * k + Double(paper.g) * (1 - k)),
                        b: UInt8(Double(b / n) * k + Double(paper.b) * (1 - k)))
                }
            }
        }
        return dots
    }

    private static func colour(_ shapes: [Shape], _ x: Double, _ y: Double) -> RGB? {
        var hit: RGB?
        for s in shapes {
            switch s {
            case let .ellipse(c, rx, ry, col):
                let dx = (x - c.x) / rx, dy = (y - c.y) / ry
                if dx * dx + dy * dy <= 1 { hit = col }
            case let .rect(c, w, h, radius, col):
                if x < c.x || x > c.x + w || y < c.y || y > c.y + h { continue }
                let r = min(radius, min(w, h) / 2)
                let nx = min(max(x, c.x + r), c.x + w - r)
                let ny = min(max(y, c.y + r), c.y + h - r)
                if (x - nx) * (x - nx) + (y - ny) * (y - ny) <= r * r { hit = col }
            case let .capsule(points, width, col):
                var inside = false
                for i in 0..<max(0, points.count - 1) where !inside {
                    inside = distance(x, y, points[i], points[i + 1]) <= width / 2
                }
                if inside { hit = col }
            case let .poly(points, col):
                if contains(x, y, points) { hit = col }
            }
        }
        return hit
    }

    private static func distance(_ x: Double, _ y: Double, _ a: P, _ b: P) -> Double {
        let vx = b.x - a.x, vy = b.y - a.y
        let len = vx * vx + vy * vy
        let t = len == 0 ? 0 : min(max(((x - a.x) * vx + (y - a.y) * vy) / len, 0), 1)
        return ((x - (a.x + vx * t)) * (x - (a.x + vx * t)) + (y - (a.y + vy * t)) * (y - (a.y + vy * t))).squareRoot()
    }

    private static func contains(_ x: Double, _ y: Double, _ points: [P]) -> Bool {
        var inside = false, j = points.count - 1
        for i in 0..<points.count {
            let a = points[i], b = points[j]
            if (a.y > y) != (b.y > y), x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}
