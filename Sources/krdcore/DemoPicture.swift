import Foundation

/// A picture that is not a screen: a test pattern the wall can draw with **no window server, no
/// ScreenRecording grant and no GUI**.
///
/// Why it exists: every geometry bug this wall has had was invisible in the code and obvious on the
/// screen ("the desktop is only half as wide as its box", "there is a black frame"), and the screen
/// needed a VM, a permission grant and a human to look at it. A deterministic pattern makes the same
/// failure readable in a terminal anywhere: run the wall with `--demo`, and the picture's *own*
/// borders are the measurement.
///
/// What the pattern shows, and why each part is there:
///
/// * a 2 px bright border - the picture's exact extent, which is the one thing a wrong placement or a
///   wrong scale changes;
/// * four corner squares in four colours - a crop, a flip or a rotation is visible at a glance;
/// * a circle - an aspect error (fit by stretching instead of fitting) turns it into an ellipse;
/// * concentric rings at 25/50/75 % - how much of the picture is inside the box;
/// * a crosshair - the centre, which a centred box must put at the box's centre;
/// * ruler ticks along the top - a scale error, counted rather than guessed.
public enum DemoPicture {
    public static let border = (r: UInt8(0), g: UInt8(255), b: UInt8(136))
    public static let background = (r: UInt8(16), g: UInt8(20), b: UInt8(24))

    /// RGBA, exactly `width * height * 4` bytes, alpha always opaque: the same wire shape the wall's
    /// captures use, so the demo travels the real path and not a special one.
    public static func render(width: Int, height: Int) -> [UInt8] {
        let w = max(1, width), h = max(1, height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let short = Double(min(w, h))
        let cx = Double(w - 1) / 2, cy = Double(h - 1) / 2
        let line = max(1, Int(short / 200))          // ~2 px at 400, 1 px when tiny

        /// Blend `colour` into the pixel at (x, y) with `alpha`.
        func put(_ x: Int, _ y: Int, _ colour: (r: UInt8, g: UInt8, b: UInt8), _ alpha: Double = 1) {
            guard x >= 0, y >= 0, x < w, y < h else { return }
            let i = (y * w + x) * 4
            let a = min(1, max(0, alpha))
            func mix(_ new: UInt8, _ old: UInt8) -> UInt8 {
                UInt8(Double(new) * a + Double(old) * (1 - a))
            }
            pixels[i] = mix(colour.r, pixels[i])
            pixels[i + 1] = mix(colour.g, pixels[i + 1])
            pixels[i + 2] = mix(colour.b, pixels[i + 2])
            pixels[i + 3] = 255
        }

        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                pixels[i] = background.r
                pixels[i + 1] = background.g
                pixels[i + 2] = background.b
                pixels[i + 3] = 255
            }
        }

        // Rulers: ticks along the top and left, one per 16th, so a scale error can be counted.
        let tick = (r: UInt8(120), g: UInt8(140), b: UInt8(160))
        for step in 0...16 {
            let x = Int((Double(w - 1) * Double(step) / 16).rounded())
            let y = Int((Double(h - 1) * Double(step) / 16).rounded())
            for d in 0..<(step % 4 == 0 ? line * 4 : line * 2) {
                for t in 0..<line {
                    put(x + t, d, tick)
                    put(d, y + t, tick)
                }
            }
        }

        // Concentric rings at 25 / 50 / 75 / 100 % of the short side.
        let ring = (r: UInt8(60), g: UInt8(70), b: UInt8(84))
        for fraction in [0.25, 0.5, 0.75, 1.0] {
            let halfW = Double(w - 1) * fraction / 2, halfH = Double(h - 1) * fraction / 2
            let x0 = Int(cx - halfW), x1 = Int(cx + halfW)
            let y0 = Int(cy - halfH), y1 = Int(cy + halfH)
            for x in x0...max(x0, x1) {
                for d in 0..<line {
                    put(x, y0 + d, ring)
                    put(x, y1 - d, ring)
                }
            }
            for y in y0...max(y0, y1) {
                for d in 0..<line {
                    put(x0 + d, y, ring)
                    put(x1 - d, y, ring)
                }
            }
        }

        // Crosshair: the centre of the picture, which a centred box must land on the box's centre.
        let cross = (r: UInt8(90), g: UInt8(100), b: UInt8(116))
        for x in 0..<w {
            for d in 0..<line { put(x, Int(cy) + d, cross) }
        }
        for y in 0..<h {
            for d in 0..<line { put(Int(cx) + d, y, cross) }
        }

        // A circle: an aspect error turns it into an ellipse. Radius 45 % of the short side.
        let radius = short * 0.45
        let orange = (r: UInt8(255), g: UInt8(150), b: UInt8(40))
        for y in 0..<h {
            for x in 0..<w {
                let dx = Double(x) - cx, dy = Double(y) - cy
                let d = (dx * dx + dy * dy).squareRoot()
                if abs(d - radius) <= Double(line) { put(x, y, orange) }
            }
        }

        // Corner squares, 1/8 of the short side, four different colours: a crop, a flip or a rotation
        // is visible without knowing what the picture was supposed to be.
        let side = max(2, Int(short / 8))
        let corners = [(0, 0, (r: UInt8(255), g: UInt8(60), b: UInt8(60))),
                       (w - side, 0, (r: UInt8(60), g: UInt8(255), b: UInt8(60))),
                       (0, h - side, (r: UInt8(80), g: UInt8(120), b: UInt8(255))),
                       (w - side, h - side, (r: UInt8(255), g: UInt8(230), b: UInt8(60)))]
        for (x0, y0, colour) in corners {
            for y in y0..<(y0 + side) {
                for x in x0..<(x0 + side) { put(x, y, colour) }
            }
        }

        // The border last, so nothing draws over it: this is the picture's own edge.
        for y in 0..<h {
            for x in 0..<w {
                let edge = x < line * 2 || y < line * 2
                    || x >= w - line * 2 || y >= h - line * 2
                if edge { put(x, y, border) }
            }
        }
        return pixels
    }
}
