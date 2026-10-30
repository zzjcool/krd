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
    /// How much the source had to be shrunk to fit the pane's box, `min(boxW/srcW, boxH/srcH, 1)`.
    /// 1 means the pane has room for the source at 1:1 (a small window in a big pane); below 1 the
    /// source is downscaled to the box. It is never above 1: asking ScreenCaptureKit for a box
    /// *larger* than the source does not upscale, it pads with black (issue #69).
    public let fit: Double
    /// The source's own size in points, before any fitting (0 when the caller did not say).
    public let sourceW: Double
    public let sourceH: Double
    /// The pane box the source was fitted into, in the pane's pixels at `scale == 1`.
    public let boxW: Int
    public let boxH: Int
    /// ...and in cells, before the source's own size trimmed it (`paneCols/paneRows` after).
    public let boxCols: Int
    public let boxRows: Int
    /// The frame at `scale == 1`: the source after fitting.
    public let fittedW: Int
    public let fittedH: Int

    /// The pane's own pixel size: what a terminal means by an SGR-Pixels mouse coordinate.
    /// `pixelW/pixelH` is what we *ask the capturer for*, which is smaller when `scale < 1`.
    public var panePixelW: Int { max(2, Int((Double(paneCols) * cellW).rounded())) }
    public var panePixelH: Int { max(2, Int((Double(paneRows) * cellH).rounded())) }

    /// Why the frame is not the size of the pane box, in one clause for `--debug` (issue #69).
    public var fitNote: String {
        if fittedW == boxW && fittedH == boxH { return "" }        // the frame *is* the pane box
        let leftCols = max(0, boxCols - paneCols), leftRows = max(0, boxRows - paneRows)
        if fit < 0.999 {
            return " (fitted to \(String(format: "%.3f", fit)) of the \(boxW)x\(boxH) px box)"
        }
        guard leftCols > 0 || leftRows > 0 else { return "" }
        return " (the source is smaller than the pane box: \(pixelW)x\(pixelH) px at 1:1, "
            + "\(leftCols)x\(leftRows) cells left to the terminal)"
    }

    public var tilesX: Int { (paneCols + tileCols - 1) / tileCols }
    public var tilesY: Int { (paneRows + tileRows - 1) / tileRows }
    public var count: Int { tilesX * tilesY }

    /// Fit `aspect` (width / height) into the pane, using whole cells.
    ///
    /// Plain numbers rather than a terminal struct: the core has no tty and no `TermGeometry`
    /// (issue #21). `krd` forwards its `TermGeometry` through an extension with the old signature.
    public static func make(paneCols: Int, paneRows: Int, cellW: Double, cellH: Double,
                            aspect: Double, tileCols: Int, tileRows: Int,
                            bpp: Int = 3, scale: Double = 1,
                            source: CGSize = CGSize(width: 0, height: 0)) -> TileGrid {
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
        // Never ask for a box bigger than the source: ScreenCaptureKit does not upscale to fill it,
        // it pads with black (issue #69), and then the pointer mapping spreads over pixels that do
        // not exist. Fit the source into the box instead, keeping its own aspect by construction.
        var fit = 1.0
        if source.width >= 2, source.height >= 2 {
            fit = min(min(Double(boxW) / source.width, Double(boxH) / source.height), 1)
        }
        // The image at scale 1, and the cell box the terminal upscales it into. `ceil` because a
        // partly used cell still has to be covered, and the picture is anchored at the pane's
        // top-left -- the cells it does not reach are left to the terminal's own background.
        let fittedW = max(2, Int((source.width >= 2 ? source.width * fit : Double(boxW)).rounded()))
        let fittedH = max(2, Int((source.height >= 2 ? source.height * fit : Double(boxH)).rounded()))
        if source.width >= 2, source.height >= 2 {
            cols = min(paneCols, max(1, Int((Double(fittedW) / cellW).rounded(.up))))
            rows = min(paneRows, max(1, Int((Double(fittedH) / cellH).rounded(.up))))
        }
        return TileGrid(
            paneCols: cols, paneRows: rows,
            cellW: cellW, cellH: cellH,
            tileCols: tileCols, tileRows: tileRows,
            pixelW: max(2, Int((Double(fittedW) * captureScale).rounded())),
            pixelH: max(2, Int((Double(fittedH) * captureScale).rounded())),
            bpp: bpp, scale: captureScale,
            fit: fit, sourceW: source.width, sourceH: source.height, boxW: boxW, boxH: boxH,
            boxCols: boxCols, boxRows: boxRows, fittedW: fittedW, fittedH: fittedH
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
                tx * tileCols + 1, ty * tileRows + 1, cx, cy)
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
