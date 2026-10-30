import Foundation

/// Grid of whole-cell tiles.
///
/// Every tile occupies a whole number of terminal cells, so it can be placed with
/// `c`/`r` alone (no sub-cell pixel offsets) and the terminal never has to resample.
public struct TileGrid {
    public let paneCols: Int
    public let paneRows: Int
    public let cellW: Double
    public let cellH: Double
    /// Cells per tile.
    public let tileCols: Int
    public let tileRows: Int
    /// Scaled frame size in device pixels: exactly paneCols x paneRows cells.
    public let pixelW: Int
    public let pixelH: Int
    /// Bytes per pixel in the frame buffer we are handed (3 for RGB, 4 for RGBA).
    public let bpp: Int
    /// Image pixels per pane pixel: 1 captures what the pane can show, 0.5 captures half as many
    /// in each direction (a quarter of the bytes) and lets the terminal upscale. `pixelW/pixelH`
    /// and the pixel rects below are already scaled; the cells (`paneCols/paneRows`, `rect().col/row/
    /// cols/rows`) are not, because the picture must still fill the same cell box.
    public let scale: Double
    /// How much the picture is scaled on screen relative to the source's own points:
    /// `min(boxW/srcW, boxH/srcH)`. **May exceed 1**: a window smaller than the pane is drawn larger
    /// by the terminal, which costs no bytes. It is *not* the capture ratio -- that is
    /// `min(fit, 1) x scale`: we never ask for more pixels than the source has (asking
    /// ScreenCaptureKit for more does not upscale, it pads with black, issue #69), and `--scale` only
    /// takes pixels away (issue #71).
    public let fit: Double
    /// The source's own size in points, before any fitting (0 when the caller did not say).
    public let sourceW: Double
    public let sourceH: Double
    /// The largest cell rectangle with the source's aspect that fits the pane, in pixels.
    public let boxW: Int
    public let boxH: Int
    /// ...and in cells. The picture is placed in `paneCols x paneRows` of these; whatever the aspect
    /// leaves over belongs to the terminal.
    public let boxCols: Int
    public let boxRows: Int
    /// The on-screen size at `scale == 1`, i.e. the source x `fit` (may be larger than the source).
    public let fittedW: Int
    public let fittedH: Int
    /// Where the picture block starts inside the terminal, in 1-based cells.
    ///
    /// `(1, 1)` whenever the picture fills its area, which is the common case. A picture smaller
    /// than its area - a window whose own pixels are fewer than the pane's, or a pane taller than
    /// the source's aspect - is *centred* in it instead of pinned to the top-left: a picture with
    /// all the slack on one side reads as a rendering bug, and the slack is where the eye looks
    /// first (design §6.7).
    public let originCol: Int
    public let originRow: Int

    /// The placement's pixel size: where the picture actually is on screen, and therefore what an
    /// SGR-Pixels mouse coordinate has to be mapped against (issue #71).
    /// `pixelW/pixelH` is what we *ask the capturer for*, which is smaller when `scale < 1` or when
    /// the pane is smaller than the source.
    public var panePixelW: Int { max(2, Int((Double(paneCols) * cellW).rounded())) }
    public var panePixelH: Int { max(2, Int((Double(paneRows) * cellH).rounded())) }

    /// Why the frame is not the size of the pane box, in one clause for `--debug` (issue #69).
    public var fitNote: String {
        if fittedW == boxW && fittedH == boxH { return "" }        // the frame *is* the pane box
        if fit < 0.999 {
            return " (fitted to \(String(format: "%.3f", fit)) of the \(boxW)x\(boxH) px box)"
        }
        // How much the terminal has to stretch the frame to fill the placement: > 1 when the source is
        // smaller than the pane or when --scale sent fewer pixels. This is the number that says why
        // the picture is soft, and it is independent of how big the picture is on screen.
        let stretchX = Double(panePixelW) / Double(max(pixelW, 1))
        let stretchY = Double(panePixelH) / Double(max(pixelH, 1))
        guard stretchX > 1.02 || stretchY > 1.02 else { return "" }
        return " (the terminal stretches x\(String(format: "%.2f", max(stretchX, stretchY))): "
            + "\(pixelW)x\(pixelH) px in \(paneCols)x\(paneRows) cells)"
    }

    public var tilesX: Int { (paneCols + tileCols - 1) / tileCols }
    public var tilesY: Int { (paneRows + tileRows - 1) / tileRows }
    public var count: Int { tilesX * tilesY }

    /// Fit `aspect` (width / height) into the pane, using whole cells.
    ///
    /// Plain numbers rather than a terminal struct: the core has no tty and no `TermGeometry`
    /// (issue #21). `krd` forwards its `TermGeometry` through an extension with the old signature.
    /// `area` is the cell rectangle the picture may use - the pane minus whatever chrome owns
    /// (`top`/`left` are 1-based, `cols`/`rows` the size). Omitted (or equal to the pane) it is the
    /// pane itself and the block lands at `(1, 1)`, which is every caller that predates centring.
    public static func make(paneCols: Int, paneRows: Int, cellW: Double, cellH: Double,
                            aspect: Double, tileCols: Int, tileRows: Int,
                            bpp: Int = 3, scale: Double = 1,
                            source: CGSize = CGSize(width: 0, height: 0),
                            area: (top: Int, left: Int, cols: Int, rows: Int)? = nil) -> TileGrid {
        // Anything outside (0, 1] is "no scaling": a negative or absurd scale would ask for a
        // zero-pixel stream, which ScreenCaptureKit refuses.
        let captureScale = (scale.isFinite && scale > 0 && scale <= 1) ? scale : 1
        // Largest cell rectangle with the source aspect that fits the pane.
        var cols = paneCols
        var rows = Int((Double(cols) * cellW / aspect / cellH).rounded())
        if rows > paneRows {
            rows = paneRows
            cols = Int((Double(rows) * cellH * aspect / cellW).rounded())
        }
        cols = max(tileCols, min(paneCols, cols))
        rows = max(tileRows, min(paneRows, rows))
        let boxCols = cols
        let boxRows = rows
        let boxW = max(1, Int((Double(cols) * cellW).rounded()))
        let boxH = max(1, Int((Double(rows) * cellH).rounded()))
        // Two independent factors (issue #71):
        //
        //  * how big the picture is *on screen* is `fit`, relative to the source's own points -- as
        //    large as the pane allows, which may mean the terminal draws it larger than the source;
        //  * how many pixels we *capture* is `min(fit, 1) x scale` -- never more than the source has
        //    (ScreenCaptureKit pads instead of upscaling, issue #69, and a display mirror must not
        //    grow with the pane), and `--scale` only ever takes pixels away.
        //
        // So `--scale` buys bandwidth, not screen size: at 0.5 the frame is half as many pixels in
        // the same cells, and the terminal stretches it back.
        let known = source.width >= 2 && source.height >= 2
        let fit = known ? min(Double(boxW) / source.width, Double(boxH) / source.height) : 1
        let capture = known ? min(fit, 1) * captureScale : captureScale
        let fittedW = max(2, Int((known ? source.width * fit : Double(boxW)).rounded()))
        let fittedH = max(2, Int((known ? source.height * fit : Double(boxH)).rounded()))
        // `ceil` because a partly used cell still has to be covered; anchored at the pane's
        // top-left, and whatever the aspect leaves over stays the terminal's.
        if known {
            cols = min(paneCols, max(1, Int((Double(fittedW) / cellW).rounded(.up))))
            rows = min(paneRows, max(1, Int((Double(fittedH) / cellH).rounded(.up))))
        }
        // Centre the block in the area it was given. Integer halves floor, so a spare row or column
        // (the odd case) goes to the right/bottom - the same rule every layout uses.
        let area = area ?? (top: 1, left: 1, cols: paneCols, rows: paneRows)
        let originRow = area.top + max(0, (area.rows - rows) / 2)
        let originCol = area.left + max(0, (area.cols - cols) / 2)
        return TileGrid(
            paneCols: cols, paneRows: rows,
            cellW: cellW, cellH: cellH,
            tileCols: tileCols, tileRows: tileRows,
            pixelW: max(2, Int((known ? source.width * capture : Double(boxW) * captureScale).rounded())),
            pixelH: max(2, Int((known ? source.height * capture : Double(boxH) * captureScale).rounded())),
            bpp: bpp, scale: captureScale,
            fit: fit, sourceW: source.width, sourceH: source.height, boxW: boxW, boxH: boxH,
            boxCols: boxCols, boxRows: boxRows, fittedW: fittedW, fittedH: fittedH,
            originCol: originCol, originRow: originRow
        )
    }

    /// Pixel rect of tile at grid position (tx, ty); edge tiles are smaller.
    public func rect(_ tx: Int, _ ty: Int) -> (x: Int, y: Int, w: Int, h: Int, col: Int, row: Int, cols: Int, rows: Int) {
        let cx = min(tileCols, paneCols - tx * tileCols)
        let cy = min(tileRows, paneRows - ty * tileRows)
        // Pixel rects follow the capture scale; the cell box does not (`col/row/cols/rows` below).
        // The pixels are split in proportion to the cells, not by `cells x cellW`, because the image
        // is not necessarily the size of its cell box (issue #69: a 1024-px window in 61 cells of
        // 17 px is 1037 px of box). Proportional splitting keeps every tile within ~1 % of its box
        // instead of squeezing the last column. When the image *is* the box the two agree.
        let x0 = Int((Double(tx * tileCols) / Double(max(paneCols, 1)) * Double(pixelW)).rounded())
        let y0 = Int((Double(ty * tileRows) / Double(max(paneRows, 1)) * Double(pixelH)).rounded())
        let x1 = Int((Double(tx * tileCols + cx) / Double(max(paneCols, 1)) * Double(pixelW)).rounded())
        let y1 = Int((Double(ty * tileRows + cy) / Double(max(paneRows, 1)) * Double(pixelH)).rounded())
        return (x0, y0, max(1, x1 - x0), max(1, y1 - y0),
                originCol + tx * tileCols, originRow + ty * tileRows, cx, cy)
    }

    /// Copy one tile out of a full frame into a tight buffer.
    public func extract(_ frame: [UInt8],
                 rect r: (x: Int, y: Int, w: Int, h: Int, col: Int, row: Int, cols: Int, rows: Int)) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: r.w * r.h * bpp)
        let stride = pixelW * bpp
        let rowBytes = r.w * bpp
        frame.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for row in 0..<r.h {
                    let s = (r.y + row) * stride + r.x * bpp
                    memcpy(dst.baseAddress! + row * rowBytes, src.baseAddress! + s, rowBytes)
                }
            }
        }
        return out
    }

    /// Indices of tiles whose pixels differ.
    public static func dirty(previous: [UInt8], current: [UInt8], grid: TileGrid) -> [Int] {
        guard previous.count == current.count else { return Array(0..<grid.count) }
        var result: [Int] = []
        let stride = grid.pixelW * grid.bpp
        let rowBytes = { (r: (x: Int, y: Int, w: Int, h: Int, col: Int, row: Int, cols: Int, rows: Int)) in r.w * grid.bpp }
        previous.withUnsafeBufferPointer { prev in
            current.withUnsafeBufferPointer { cur in
                for ty in 0..<grid.tilesY {
                    for tx in 0..<grid.tilesX {
                        let r = grid.rect(tx, ty)
                        var differs = false
                        let bytes = rowBytes(r)
                        for row in 0..<r.h {
                            let off = (r.y + row) * stride + r.x * grid.bpp
                            if memcmp(prev.baseAddress! + off, cur.baseAddress! + off, bytes) != 0 {
                                differs = true
                                break
                            }
                        }
                        if differs { result.append(ty * grid.tilesX + tx) }
                    }
                }
            }
        }
        return result
    }
}
