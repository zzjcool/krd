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
    /// The corner radius for a picture of this size: one twenty-fourth of its short side.
    ///
    /// Chosen to read as a rounded object at a glance without looking like a badge: at the VM's
    /// 1024x768 display fitted into a 137-column stage that is ~33 px, and a 731x416 card picture
    /// gets ~17 px - about what macOS gives a window. One rule for both, because a rounded card next
    /// to a square stage would look like two different things glued together.
    public static func cornerRadius(width: Int, height: Int) -> Int {
        max(0, min(width, height) / 24)
    }

    /// Fit `aspect` (width / height) inside `rect`, never cropping and never stretching.
    ///
    /// Both outputs come out of the same two numbers so the cells and the pixels cannot disagree:
    /// the pixel box is the truth, and the cell box is that box rounded to the grid.
    ///
    /// `maxHeight` lowers the picture without changing its aspect or its centre: the wall uses it to
    /// give a row of cards one height, so their top and bottom edges line up (design §6.6). It can
    /// only shrink - a cap above the fitted height is ignored, because the fit already did the
    /// clipping that keeps the picture inside `rect`.
    public static func fit(aspect: Double, in rect: CellRect,
                           cellW: Double, cellH: Double, maxHeight: Int? = nil) -> PanelFit {
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
        if let maxHeight, maxHeight > 0, maxHeight < h {
            h = maxHeight
            w = max(1, min(availW, Int((Double(h) * aspect).rounded())))
        }
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

    /// Paint `content` (RGB, `width` x `height`) onto a **transparent** panel-sized canvas.
    ///
    /// The bars are transparent, not tinted (design §6.6): the picture sits on cells the wall
    /// cleared, so the terminal's own background shows through and a card reads as a window lying on
    /// the wall rather than a window in a frame. The two earlier versions filled the bars with a
    /// colour (black, then the picture's edge colour); both were guesses at a background the
    /// terminal already has.
    ///
    /// Output is RGBA (`f=32` on the wire): the content is opaque, everything outside it is
    /// `0,0,0,0`.
    ///
    /// Clipped, never scaled: the capture is asked for exactly `fit`'s pixel size, and a scaler here
    /// would be a second resampler that could disagree with the terminal's. A content that is a
    /// pixel or two too big loses its edge instead of blurring.
    /// Paint `content` (RGB, `width` x `height`) onto a panel-sized canvas filled with `backdrop`.
    ///
    /// Clipped, never scaled: the capture is asked for exactly `fit`'s pixel size, and a scaler here
    /// would be a second resampler that could disagree with the terminal's. A content that is a
    /// pixel or two too big loses its edge instead of blurring.
    ///
    /// `cornerRadius` rounds the picture's own corners (in pixels, `0` = square): the alpha outside
    /// the arc is left at 0, so the wall's background shows through and a display or a window reads
    /// as a rounded object lying on the wall instead of a rectangle cut out of it. macOS windows are
    /// rounded anyway, so the card pictures lose nothing; the stage is a display, and its corners are
    /// the one thing a square cut cannot say.
    public static func compose(content: [UInt8], width: Int, height: Int,
                               panelWidth: Int, panelHeight: Int,
                               originX: Int, originY: Int,
                               cornerRadius: Int = 0) -> [UInt8] {
        guard panelWidth > 0, panelHeight > 0 else { return [] }
        // Alpha 0 everywhere: the bars are the terminal's own background, not a colour of ours.
        var canvas = [UInt8](repeating: 0, count: panelWidth * panelHeight * 4)
        guard width > 0, height > 0, content.count >= width * height * 3 else { return canvas }
        let dstStride = panelWidth * 4
        let srcStride = width * 3
        content.withUnsafeBufferPointer { src in
            canvas.withUnsafeMutableBufferPointer { dst in
                // The radius can never eat more than half the picture, or the four arcs would
                // cross and there would be no opaque pixel left at all.
                let r = max(0, min(cornerRadius, min(width, height) / 2))
                for row in 0..<height {
                    let y = originY + row
                    guard y >= 0, y < panelHeight else { continue }
                    var first = max(0, -originX)                    // clipped left edge
                    var last = min(width, panelWidth - originX)     // clipped right edge
                    if r > 0 {
                        // Only two rows out of each corner are narrowed: `dy` is the distance from
                        // the nearest horizontal edge, and `dx` is how much the arc takes off the
                        // row. The middle rows keep their full span, so the cost is the arcs alone.
                        let dyTop = r - row
                        let dyBottom = r - (height - 1 - row)
                        let dy = max(dyTop, dyBottom)
                        if dy > 0 {
                            let dx = r - Int((Double(r * r - dy * dy)).squareRoot().rounded(.down))
                            first = max(first, dx)
                            last = min(last, width - dx)
                        }
                    }
                    guard last > first else { continue }
                    let out = dst.baseAddress! + y * dstStride + (originX + first) * 4
                    let input = src.baseAddress! + row * srcStride + first * 3
                    // Row at a time, and the alpha with it: a cleared cell must stay cleared.
                    for i in 0..<(last - first) {
                        out[i * 4] = input[i * 3]
                        out[i * 4 + 1] = input[i * 3 + 1]
                        out[i * 4 + 2] = input[i * 3 + 2]
                        out[i * 4 + 3] = 255
                    }
                }
            }
        }
        return canvas
    }
}
