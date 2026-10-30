import Foundation

/// The mascot card krd shows while the first frame is still in flight.
///
/// It is plain ANSI — 36×18 half blocks with 24-bit colour — so it needs no kitty graphics and can
/// be painted before the graphics path has proven anything. `stop()` is idempotent and is called
/// from the frame path: the first frame that lands takes the card away, nothing else does.
///
/// The drawing is twelve shapes from four primitives (ellipse, rounded rect, capsule, polygon),
/// rasterised at 2×2 samples per dot. That is deliberately small: this file is the whole reason the
/// mascot can be redrawn from scratch in Swift instead of being shipped as an image.
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

    // MARK: state

    private let writeText: (String) -> Void
    private let paneCols: Int
    private let paneRows: Int
    private var timer: DispatchSourceTimer?
    private var frame = 0
    private var painted = false

    init(paneCols: Int, paneRows: Int, write: @escaping (String) -> Void) {
        self.paneCols = paneCols
        self.paneRows = paneRows
        self.writeText = write
    }

    private var originRow: Int { max(0, (paneRows - (Self.dotH / 2 + 2)) / 2) }
    private var originCol: Int { max(0, (paneCols - Self.dotW) / 2) + 1 }

    func start() {
        guard timer == nil else { return }
        paint()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(110), repeating: .milliseconds(110))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.frame += 1
            self.paint()
        }
        t.resume()
        timer = t
    }

    func stop() {
        guard let t = timer else { return }
        t.cancel()
        timer = nil
        guard painted else { return }
        painted = false
        // Clear exactly what we drew: the card's rows, nothing else. The frame path owns the rest.
        var out = ""
        for row in 0..<(Self.dotH / 2 + 2) {
            out += "\u{1B}[\(originRow + row + 1);1H\u{1B}[2K"
        }
        out += "\u{1B}[\(originRow + 1);1H"
        writeText(out)
    }

    // MARK: paint

    private func paint() {
        let shapes = Self.shapes(frame)
        let (dots, w, h) = Self.raster(shapes)
        var out = ""
        for row in 0..<(h / 2) {
            out += "\u{1B}[\(originRow + row + 1);1H\u{1B}[2K"
            out += String(repeating: " ", count: originCol)
            for col in 0..<w {
                let top = dots[(row * 2) * w + col], bottom = dots[(row * 2 + 1) * w + col]
                out += "\u{1B}[38;2;\(top.r);\(top.g);\(top.b);48;2;\(bottom.r);\(bottom.g);\(bottom.b)m▀"
            }
            out += "\u{1B}[0m"
        }
        let label = "waiting for first frame" + String(repeating: ".", count: (frame % 4))
        let sub = "krd · connecting"
        let pad = max(0, (Self.dotW - label.count) / 2)
        out += "\u{1B}[\(originRow + h / 2 + 1);1H\u{1B}[2K"
        out += String(repeating: " ", count: originCol + pad)
        out += "\u{1B}[38;2;140;150;170m\(label)\u{1B}[0m"
        let pad2 = max(0, (Self.dotW - sub.count) / 2)
        out += "\u{1B}[\(originRow + h / 2 + 2);1H\u{1B}[2K"
        out += String(repeating: " ", count: originCol + pad2)
        out += "\u{1B}[38;2;88;98;118m\(sub)\u{1B}[0m"
        painted = true
        writeText(out)
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

    /// 2×2 samples per dot, over the 96-unit drawing space, zoomed out to 0.72 so nothing clips.
    private static func raster(_ shapes: [Shape]) -> ([RGB], Int, Int) {
        var dots = [RGB](repeating: paper, count: dotW * dotH)
        for y in 0..<dotH {
            for x in 0..<dotW {
                var r = 0, g = 0, b = 0, n = 0
                for sy in 0..<2 {
                    for sx in 0..<2 {
                        let u0 = margin + ((Double(x) + (Double(sx) + 0.5) / 2) / Double(dotW)) * 88
                        let v0 = margin + ((Double(y) + (Double(sy) + 0.5) / 2) / Double(dotH)) * 88
                        let u = 48 + (u0 - 48) / 0.72, v = 48 + (v0 - 48) / 0.72
                        guard let c = colour(shapes, u, v) else { continue }
                        r += Int(c.r); g += Int(c.g); b += Int(c.b); n += 1
                    }
                }
                let k = Double(n) / 4
                if n > 0 {
                    dots[y * dotW + x] = RGB(
                        r: UInt8(Double(r / n) * k + Double(paper.r) * (1 - k)),
                        g: UInt8(Double(g / n) * k + Double(paper.g) * (1 - k)),
                        b: UInt8(Double(b / n) * k + Double(paper.b) * (1 - k)))
                }
            }
        }
        return (dots, dotW, dotH)
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
