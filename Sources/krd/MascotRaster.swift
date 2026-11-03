import Foundation
import CoreGraphics

/// Draws the generated mascot (`MascotArt`) with CoreGraphics.
///
/// The drawing is one list of layers in the vocabulary `docs/brand/tui/vector.mjs` defines —
/// absolute `M`/`L`/`C`/`Z` paths, a colour or a user-space gradient, a fill rule, an alpha, a
/// stroke width, a group transform, a clip — because that is the intersection of SVG 1.1, the
/// lab's own rasteriser and this. One drawing, three renderers, no transcription.
///
/// Two things here are the card's and not SVG's:
///
///  * **The picture box is the cell box.** The scene is fitted into `width x height` with `aspect`
///    as the only correction: a mosaic dot is half a cell (8x10 on an 8x20 cell), while a picture
///    pixel is square and the terminal scales it uniformly. Without that, one of the two
///    transports stretches the crab and the other does not.
///  * **The mosaic is one colour per dot.** A half-block cell cannot hold an edge, so a dot takes
///    the colour most of it shows (and is then snapped to the drawing's own palette), while the
///    picture averages its samples and keeps its edges soft for the terminal to scale.
///
/// Those two rules are the whole difference between the two styles; everything above is shared, so
/// the crab cannot come out different in the two transports.
enum MascotRaster {
    /// How many samples per output pixel the picture takes, in each direction. The hand-drawn card
    /// that this replaced sampled 2x2, which is why the number survives the redraw.
    static let samples = 2

    /// Which of the two transports a render is for. It changes the sampling and nothing else.
    enum Style {
        /// The fallback's `▀` grid: one sample per dot, no antialiasing, majority colour.
        case mosaic
        /// The picture the terminal scales: supersampled, antialiased, averaged.
        case picture
    }

    /// One pose, drawn into `width x height` pixels: RGB triplets, `paper` behind everything.
    ///
    /// `aspect` is how much taller than wide one *output pixel* is: 1 for the picture (square
    /// pixels), `cellH / (2 * cellW)` for the mosaic (a dot is half a cell).
    static func render(pose: Int, width: Int, height: Int, aspect: Double,
                       style: Style, paper: MascotRGB) -> [UInt8] {
        switch style {
        case .mosaic:
            /* one sample per dot, no antialiasing: a half-block cell holds a colour, and a
               blended edge is a colour nobody chose */
            return draw(pose: pose, width: width, height: height, aspect: aspect,
                        samples: 1, antialias: false, snap: true, paper: paper)
        case .picture:
            /* the terminal scales this one, so a soft edge is the edge that survives scaling */
            return draw(pose: pose, width: width, height: height, aspect: aspect,
                        samples: samples, antialias: true, snap: false, paper: paper)
        }
    }

    /// The same, with the sampling spelled out.
    private static func draw(pose: Int, width: Int, height: Int, aspect: Double,
                             samples: Int, antialias: Bool, snap: Bool,
                             paper: MascotRGB) -> [UInt8] {
        /* the card increments a counter, but `render` is internal: a negative pose must not be an
           Array trap on the one path that is painted before anything else is proven */
        let n = MascotArt.poses.count
        let p = MascotArt.poses[((pose % n) + n) % n]
        let view = MascotArt.view
        let vx = view[0], vy = view[1], vw = view[2], vh = view[3]
        let ss = max(1, samples), W = width * ss, H = height * ss

        var buffer = [UInt8](repeating: 0, count: W * H * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H,
                                      bitsPerComponent: 8, bytesPerRow: W * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.setFillColor(red: CGFloat(paper.r) / 255, green: CGFloat(paper.g) / 255,
                             blue: CGFloat(paper.b) / 255, alpha: 1)
            ctx.setShouldAntialias(antialias)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

            /* y down, origin top-left: user units then land in the buffer the way vector.mjs
               lays them out, and the drawing's own "down" is the terminal's "down". */
            ctx.translateBy(x: 0, y: CGFloat(H))
            ctx.scaleBy(x: 1, y: -1)

            /* one uniform scale that fits the view, centred — the same arithmetic as vector.mjs */
            let s = min(Double(W) / (vw * aspect), Double(H) / vh)
            let kx = s * aspect, ky = s
            let ox = (Double(W) - vw * kx) / 2, oy = (Double(H) - vh * ky) / 2
            ctx.translateBy(x: CGFloat(ox), y: CGFloat(oy))
            ctx.scaleBy(x: CGFloat(kx), y: CGFloat(ky))
            ctx.translateBy(x: CGFloat(-vx), y: CGFloat(-vy))

            for layer in MascotArt.layers {
                if let only = layer.only, (only == "shut") != p.shut { continue }
                draw(layer, pose: p, scale: s, ss: ss, ctx: ctx)
            }
        }
        return fold(buffer, width: width, height: height, samples: ss, snap: snap,
                    palette: snap ? MascotArt.palette.map(MascotRGB.init(hex:)) : [])
    }

    /// Fold the samples down to one colour per dot.
    ///
    /// One colour per dot. The picture averages its samples, because the terminal will scale it;
    /// the mosaic has one sample to begin with, so its dot *is* that sample — then snapped to the
    /// drawing's own palette, because a half-block cell should show a colour the drawing contains
    /// (the alternative is an antialiased edge that no one chose, on a sprite that is mostly edge).
    private static func fold(_ buffer: [UInt8], width: Int, height: Int, samples ss: Int,
                             snap: Bool, palette: [MascotRGB]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 3)
        let n = ss * ss
        for y in 0..<height {
            for x in 0..<width {
                var r = 0, g = 0, b = 0
                for j in 0..<ss {
                    for i in 0..<ss {
                        let q = ((y * ss + j) * width * ss + x * ss + i) * 4
                        r += Int(buffer[q]); g += Int(buffer[q + 1]); b += Int(buffer[q + 2])
                    }
                }
                var c = MascotRGB(r: UInt8((r + n / 2) / n), g: UInt8((g + n / 2) / n),
                                  b: UInt8((b + n / 2) / n))
                if snap { c = nearest(c, in: palette) }
                let o = (y * width + x) * 3
                out[o] = c.r; out[o + 1] = c.g; out[o + 2] = c.b
            }
        }
        return out
    }

    // MARK: one layer

    private static func draw(_ layer: MascotLayer, pose: MascotPose, scale: Double, ss: Int,
                             ctx: CGContext) {
        let path = cgPath(layer.d)
        ctx.saveGState()
        /* A group's clip lives in its *parent's* space, so it is applied before the group's own
           transform: a pose that moves a group must not drag its clip along with it. */
        var parent: String? = layer.group
        var chain: [String] = []
        while let name = parent {
            chain.insert(name, at: 0)
            parent = MascotArt.groups[name]?.parent
        }
        for name in chain {
            guard let group = MascotArt.groups[name] else { continue }
            if let clip = group.clip { addClip(clip, ctx: ctx) }
            advance(name, group: group, pose: pose, ctx: ctx)
        }
        if let clip = layer.clip { addClip(clip, ctx: ctx) }
        ctx.setAlpha(CGFloat(layer.alpha))

        let rule: CGPathFillRule = layer.evenOdd ? .evenOdd : .winding
        let width = strokeWidth(layer, scale, ss: ss)
        if layer.under, let stroke = layer.stroke {
            apply(stroke, path: path, strokeWidth: width, rule: rule, ctx: ctx)
        }
        if let fill = layer.fill {
            apply(fill, path: path, strokeWidth: nil, rule: rule, ctx: ctx)
        }
        if !layer.under, let stroke = layer.stroke {
            apply(stroke, path: path, strokeWidth: width, rule: rule, ctx: ctx)
        }
        ctx.restoreGState()
    }

    /// The stroke's width in **user units**, which is what `setLineWidth` takes: the drawing's own
    /// width, floored at `minPx` output pixels.
    ///
    /// The division is the whole point. `minPx` is in *output* pixels (`vector.mjs` masks a stroke
    /// by radius in buffer pixels: `max(w * s, minPx) * ss / 2`), and the context here already
    /// carries `scale`, so a width handed to `setLineWidth` is multiplied by the scale on its way
    /// into the buffer. Without dividing, a 2.1-px floor became 2.1 *user units* — 0.24 buffer
    /// pixels on the mosaic, 1.2 on the picture — i.e. a hairline: the mosaic kept its outline only
    /// because a non-antialiased hairline still lands on some dot centres (which is why it looked
    /// dashed), and the picture lost every outline it had.
    private static func strokeWidth(_ layer: MascotLayer, _ scale: Double, ss: Int) -> Double {
        guard scale > 0 else { return layer.width }
        let buffer = max(layer.width * scale, layer.minPx * Double(ss))
        return buffer / scale
    }

    /// Paint the current path: a colour fills or strokes it; a gradient is drawn through it as a
    /// clip. A gradient *stroke* is clipped to the stroked outline — nothing in the sprite needs
    /// it, but the vocabulary allows it and the fallback would be a silent wrong colour.
    private static func apply(_ spec: String, path: CGPath, strokeWidth: Double?,
                              rule: CGPathFillRule, ctx: CGContext) {
        guard let paint = MascotPaint(spec) else { return }
        if let width = strokeWidth {
            ctx.addPath(path)
            ctx.setLineWidth(CGFloat(width))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if case .colour(let colour) = paint {
                ctx.setStrokeColor(colour)
                ctx.strokePath()
                return
            }
        } else {
            ctx.addPath(path)
            if case .colour(let colour) = paint {
                ctx.setFillColor(colour)
                ctx.fillPath(using: rule)
                return
            }
        }
        /* a gradient: paint it through the path (or the stroked outline) as a clip */
        guard case let .gradient(gradient, from, to, radial) = paint else { return }
        ctx.saveGState()
        if strokeWidth != nil { ctx.replacePathWithStrokedPath() }
        ctx.clip(using: rule)
        let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        if radial {
            ctx.drawRadialGradient(gradient, startCenter: from, startRadius: 0,
                                   endCenter: from, endRadius: to.x - from.x, options: options)
        } else {
            ctx.drawLinearGradient(gradient, start: from, end: to, options: options)
        }
        ctx.restoreGState()
    }

    private static func addClip(_ clip: MascotClip, ctx: CGContext) {
        ctx.addPath(cgPath(clip.d))
        ctx.clip(using: clip.evenOdd ? .evenOdd : .winding)
    }

    /// The pose's own transform for one group: translate, then rotate about the group's pivot —
    /// the order `vector.mjs` uses, which is SVG's `transform="translate(…) rotate(a px py)"`.
    private static func advance(_ name: String, group: MascotGroup, pose: MascotPose,
                                ctx: CGContext) {
        let move = pose.move[name] ?? [0, 0]
        if move[0] != 0 { ctx.translateBy(x: CGFloat(move[0]), y: 0) }
        if move[1] != 0 { ctx.translateBy(x: 0, y: CGFloat(move[1])) }
        let deg = pose.turn[name] ?? 0
        if deg != 0 {
            let pivot = group.pivot
            ctx.translateBy(x: CGFloat(pivot[0]), y: CGFloat(pivot[1]))
            ctx.rotate(by: CGFloat(deg * .pi / 180))
            ctx.translateBy(x: CGFloat(-pivot[0]), y: CGFloat(-pivot[1]))
        }
    }

    // MARK: paths

    /// Parsed paths, keyed by their own string. `CGPath` is immutable and `CGPath` objects are
    /// documented as safe to share, so the lock guards the dictionary and not the values.
    private static let cacheLock = NSLock()
    private static var pathCache: [String: CGPath] = [:]

    /// `M x y`, `L x y`, `C x1 y1 x2 y2 x y`, `Z` — the only commands vector.mjs emits.
    private static func cgPath(_ d: String) -> CGPath {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = pathCache[d] { return hit }
        let path = buildPath(d)
        pathCache[d] = path
        return path
    }

    private static func buildPath(_ d: String) -> CGPath {
        let p = CGMutablePath()
        var op: Character = "M"
        var nums: [Double] = []
        func flush() {
            defer { nums.removeAll(keepingCapacity: true) }
            switch op {
            case "M":
                guard nums.count >= 2 else { return }
                p.move(to: CGPoint(x: nums[0], y: nums[1]))
            case "L":
                guard nums.count >= 2 else { return }
                p.addLine(to: CGPoint(x: nums[0], y: nums[1]))
            case "C":
                guard nums.count >= 6 else { return }
                p.addCurve(to: CGPoint(x: nums[4], y: nums[5]),
                           control1: CGPoint(x: nums[0], y: nums[1]),
                           control2: CGPoint(x: nums[2], y: nums[3]))
            default:
                p.closeSubpath()
            }
        }
        for token in d.split(separator: " ") {
            if token.count == 1, let c = token.first, c.isLetter {
                flush()
                op = c
            } else if let v = Double(token) {
                nums.append(v)
            }
        }
        flush()
        return p
    }

    // MARK: colour

    private static func nearest(_ c: MascotRGB, in palette: [MascotRGB]) -> MascotRGB {
        guard !palette.isEmpty else { return c }
        var best = palette[0], bestD = Int.max
        for p in palette {
            let dr = Int(c.r) - Int(p.r), dg = Int(c.g) - Int(p.g), db = Int(c.b) - Int(p.b)
            let d = dr * dr + dg * dg + db * db
            if d < bestD { bestD = d; best = p }
        }
        return best
    }
}

/// One RGB triple: the shape the mosaic and the picture both want.
struct MascotRGB: Equatable {
    var r: UInt8, g: UInt8, b: UInt8
    init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
    init(hex: String) {
        let v = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let n = UInt32(v, radix: 16) ?? 0
        r = UInt8((n >> 16) & 0xff); g = UInt8((n >> 8) & 0xff); b = UInt8(n & 0xff)
    }
}

/// A paint parsed from the strings `logo-tui.mjs --swift` writes.
enum MascotPaint {
    /// `#rrggbb`
    case colour(CGColor)
    /// `@L x1 y1 x2 y2 o:h:a …` / `@R cx cy r o:h:a …` — `from`/`to` are the gradient's ends,
    /// and for a radial `to.x - from.x` is its radius.
    case gradient(CGGradient, from: CGPoint, to: CGPoint, radial: Bool)

    init?(_ spec: String) {
        if spec.hasPrefix("#") {
            let c = MascotRGB(hex: spec)
            let colour = CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                                 blue: CGFloat(c.b) / 255, alpha: 1)
            self = .colour(colour)
            return
        }
        let parts = spec.split(separator: " ").map(String.init)
        let radial = parts.first == "@R"
        guard radial || parts.first == "@L" else { return nil }
        let coords = radial ? 3 : 4
        guard parts.count >= coords + 3 else { return nil }   // at least two stops
        let v = parts[1...coords].compactMap(Double.init)
        guard v.count == coords else { return nil }
        let stops = parts[(coords + 1)...].compactMap { token -> (CGFloat, CGColor)? in
            let f = token.split(separator: ":").map(String.init)
            guard f.count == 3, let o = Double(f[0]), let a = Double(f[2]) else { return nil }
            let c = MascotRGB(hex: f[1])
            let colour = CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                                 blue: CGFloat(c.b) / 255, alpha: CGFloat(a))
            return (CGFloat(o), colour)
        }
        guard stops.count >= 2,
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: stops.map { $0.1 } as CFArray,
                                        locations: stops.map { $0.0 }) else { return nil }
        if radial {
            let from = CGPoint(x: v[0], y: v[1])
            self = .gradient(gradient, from: from, to: CGPoint(x: v[0] + v[2], y: v[1]), radial: true)
        } else {
            self = .gradient(gradient, from: CGPoint(x: v[0], y: v[1]),
                             to: CGPoint(x: v[2], y: v[3]), radial: false)
        }
    }
}
