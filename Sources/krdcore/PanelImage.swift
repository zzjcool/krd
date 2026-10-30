import Foundation

/// A colour the bars around a fitted picture are painted in, one byte per channel.
///
/// Plain numbers rather than `CGColor`: the compositor, the tests and the terminal path all work on
/// bytes, and nothing on this path needs a colour space (design §6.6).
public struct PanelColor: Equatable, Hashable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let black = PanelColor(r: 0, g: 0, b: 0)
}

/// Where a picture's content sits inside its panel, in pixels and in cells.
///
/// Both, from one calculation, on purpose: the painter draws the placeholder on `cellRect` and the
/// capture asks ScreenCaptureKit for `contentWidth x contentHeight`, and if those two came from
/// separate fits they would drift by a cell and the picture would jump when it lands.
public struct PanelFit: Equatable {
    /// The picture itself, in device pixels: the size to ask the capture for.
    public let contentWidth: Int
    public let contentHeight: Int
    /// Where that picture sits inside the panel, in pixels (bars fill the rest).
    public let originX: Int
    public let originY: Int
    /// The same box in terminal cells, for the text layer's placeholder and its caption row.
    public let cellRect: CellRect

    /// No picture yet (no display, no window): the panel is one flat colour.
    public var isEmpty: Bool { contentWidth <= 0 || contentHeight <= 0 }
}

/// The picture maths shared by the text layer and the capture path (design §6.6).
public enum PanelImage {
    /// Fit `aspect` (width / height) inside `rect`, never cropping and never stretching.
    ///
    /// Both outputs come out of the same two numbers so the cells and the pixels cannot disagree:
    /// the pixel box is the truth, and the cell box is that box rounded to the grid.
    public static func fit(aspect: Double, in rect: CellRect,
                           cellW: Double, cellH: Double) -> PanelFit {
        guard !rect.isEmpty, aspect > 0, aspect.isFinite, cellW > 0, cellH > 0 else {
            return PanelFit(contentWidth: 0, contentHeight: 0, originX: 0, originY: 0, cellRect: rect)
        }
        let availW = max(1, Int((Double(rect.cols) * cellW).rounded()))
        let availH = max(1, Int((Double(rect.rows) * cellH).rounded()))
        var w = availW
        var h = Int((Double(availW) / aspect).rounded())
        if h > availH {
            // The band is wider than the picture: height is the constraint (a rotated display).
            h = availH
            w = Int((Double(availH) * aspect).rounded())
        }
        w = max(1, min(availW, w))
        h = max(1, min(availH, h))
        let x = (availW - w) / 2
        let y = (availH - h) / 2

        // The cell box is the same rectangle seen through the grid: round the pixel box, then
        // centre it, and never let rounding push it past the panel's own edges.
        let cols = max(1, min(rect.cols, Int((Double(w) / cellW).rounded())))
        let rows = max(1, min(rect.rows, Int((Double(h) / cellH).rounded())))
        let cellRect = CellRect(col: rect.col + (rect.cols - cols) / 2,
                                row: rect.row + (rect.rows - rows) / 2,
                                cols: cols, rows: rows)
        return PanelFit(contentWidth: w, contentHeight: h, originX: x, originY: y, cellRect: cellRect)
    }

    /// The colour the bars take: the picture's most common colour.
    ///
    /// Sampling a 16x16 grid instead of averaging the whole picture is the point - an average turns
    /// a dark window with a white page into grey, which then reads as "not part of the picture".
    /// Each sample is quantised to 5 bits per channel, the fullest bucket wins, and ties go to the
    /// bucket nearest the mean colour (predictable and stable across frames).
    public static func dominantColor(rgb: [UInt8], width: Int, height: Int) -> PanelColor {
        guard width > 0, height > 0, rgb.count >= width * height * 3 else { return .black }
        let grid = 16
        var buckets: [UInt32: (count: Int, r: Int, g: Int, b: Int)] = [:]
        var sumR = 0, sumG = 0, sumB = 0, samples = 0
        for gy in 0..<grid {
            let y = min(height - 1, (gy * height + height / 2) / grid)
            for gx in 0..<grid {
                let x = min(width - 1, (gx * width + width / 2) / grid)
                let o = (y * width + x) * 3
                let r = Int(rgb[o]), g = Int(rgb[o + 1]), b = Int(rgb[o + 2])
                sumR += r; sumG += g; sumB += b; samples += 1
                let key = UInt32(r >> 3) << 10 | UInt32(g >> 3) << 5 | UInt32(b >> 3)
                var bucket = buckets[key] ?? (0, 0, 0, 0)
                bucket.count += 1
                bucket.r += r; bucket.g += g; bucket.b += b
                buckets[key] = bucket
            }
        }
        guard samples > 0, !buckets.isEmpty else { return .black }
        let mean = (Double(sumR) / Double(samples), Double(sumG) / Double(samples),
                    Double(sumB) / Double(samples))
        // Sorted, so a tie is broken the same way on every frame of the same picture.
        var best: (count: Int, r: Int, g: Int, b: Int)?
        for key in buckets.keys.sorted() {
            let bucket = buckets[key]!
            guard let champion = best else { best = bucket; continue }
            if bucket.count > champion.count {
                best = bucket
            } else if bucket.count == champion.count, distance(bucket, mean) < distance(champion, mean) {
                best = bucket
            }
        }
        guard let winner = best, winner.count > 0 else { return .black }
        // The bucket's average, not its centre: a bucket spans 8 levels per channel.
        return PanelColor(r: UInt8(winner.r / winner.count),
                          g: UInt8(winner.g / winner.count),
                          b: UInt8(winner.b / winner.count))
    }

    private static func distance(_ bucket: (count: Int, r: Int, g: Int, b: Int),
                                 _ mean: (Double, Double, Double)) -> Double {
        let n = Double(bucket.count)
        let dr = Double(bucket.r) / n - mean.0
        let dg = Double(bucket.g) / n - mean.1
        let db = Double(bucket.b) / n - mean.2
        return dr * dr + dg * dg + db * db
    }

    /// Paint `content` (RGB, `width` x `height`) onto a panel-sized canvas filled with `backdrop`.
    ///
    /// Clipped, never scaled: the capture is asked for exactly `fit`'s pixel size, and a scaler here
    /// would be a second resampler that could disagree with the terminal's. A content that is a
    /// pixel or two too big loses its edge instead of blurring.
    public static func compose(content: [UInt8], width: Int, height: Int,
                               panelWidth: Int, panelHeight: Int, originX: Int, originY: Int,
                               backdrop: PanelColor) -> [UInt8] {
        guard panelWidth > 0, panelHeight > 0 else { return [] }
        var canvas = [UInt8](repeating: 0, count: panelWidth * panelHeight * 3)
        for i in stride(from: 0, to: canvas.count, by: 3) {
            canvas[i] = backdrop.r
            canvas[i + 1] = backdrop.g
            canvas[i + 2] = backdrop.b
        }
        guard width > 0, height > 0, content.count >= width * height * 3 else { return canvas }
        let dstStride = panelWidth * 3
        let srcStride = width * 3
        content.withUnsafeBufferPointer { src in
            canvas.withUnsafeMutableBufferPointer { dst in
                for row in 0..<height {
                    let y = originY + row
                    guard y >= 0, y < panelHeight else { continue }
                    let first = max(0, -originX)                    // clipped left edge
                    let last = min(width, panelWidth - originX)     // clipped right edge
                    guard last > first else { continue }
                    // Row at a time: the bars are already painted, so only the picture is copied.
                    memcpy(dst.baseAddress! + y * dstStride + (originX + first) * 3,
                           src.baseAddress! + row * srcStride + first * 3,
                           (last - first) * 3)
                }
            }
        }
        return canvas
    }
}
