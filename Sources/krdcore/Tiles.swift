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
    /// The largest cell rectangle with the source's aspect that fits the pane, in pixels. A function
    /// of the pane, the cell and the aspect only - never of the tile size (issue #143).
    public let boxW: Int
    public let boxH: Int
    /// ...and in cells. The picture is placed in `paneCols x paneRows` of these; whatever the aspect
    /// leaves over belongs to the terminal. `boxCols <= paneCols` and `boxRows <= paneRows` hold by
    /// construction: a box bigger than the pane cannot be the pane's own aspect.
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

    /// Why the terminal has anything to stretch, in one clause for `--debug`.
    ///
    /// The frame *is* the placement box at full scale now (the stream upscales, see `make`), so
    /// `--scale` is the only thing that can leave the terminal a stretch to do - and that is
    /// exactly the number that explains the softness, independent of how big the picture is on
    /// screen.
    public var fitNote: String {
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
    ///
    /// `fillsCells` is the transport's promise, not a layout preference: true means "this transport
    /// cannot stretch an image into cells it is not already the size of", which is what a unicode
    /// placeholder grid does (it draws one image pixel per device pixel, design §6.9). The frame is
    /// then the cell box and `scale` cannot take pixels away from it - a tile narrower than its
    /// cells is a column of background at that tile's right edge (issue #86). `--scale`'s promise is
    /// kept by sending the picture as pixel placements instead (`Desk.scaleNeedsPixelPlacements`).
    public static func make(paneCols: Int, paneRows: Int, cellW: Double, cellH: Double,
                            aspect: Double, tileCols: Int, tileRows: Int,
                            bpp: Int = 3, scale: Double = 1, fillsCells: Bool = false,
                            source: CGSize = CGSize(width: 0, height: 0),
                            area: (top: Int, left: Int, cols: Int, rows: Int)? = nil) -> TileGrid {
        // Anything outside (0, 1] is "no scaling": a negative or absurd scale would ask for a
        // zero-pixel stream, which ScreenCaptureKit refuses.
        let requestedScale = (scale.isFinite && scale > 0 && scale <= 1) ? scale : 1
        let captureScale = fillsCells ? 1 : requestedScale
        // Largest cell rectangle with the source aspect that fits the pane.
        var cols = paneCols
        var rows = Int((Double(cols) * cellW / aspect / cellH).rounded())
        if rows > paneRows {
            rows = paneRows
            cols = Int((Double(rows) * cellH * aspect / cellW).rounded())
        }
        // **The tile size does not enter this arithmetic** (issue #143), and that is the point of
        // these two lines. They used to clamp the box *up* to at least one whole tile -
        // `max(tileCols, min(paneCols, cols))`, where the `max` undid the `min` - so whenever the
        // picture's box was smaller than one tile (a `--tile` bigger than the picture, or a pane
        // shorter or narrower than the tile) the box handed to `fit`/`boxW`/`boxH` was **bigger than
        // the pane**: the fit came out larger than the pane can hold and the `ceil` clamp below could
        // only trim the *cells*, leaving a frame taller than the pane (measured: `--tile 32x16` on a
        // 40x15 pane fitted into 16 rows of 16 px = 256 px, 6.3 % more than the 240 px the pane has)
        // and a cell box that was no longer the source's aspect (`--tile 24x20` gave 23x15 cells
        // instead of 17x15, a 36 % horizontal stretch; `--tile 8x4` on a 40x3 pane was 48 % wide).
        //
        // A box smaller than one tile needs nothing special: `rect` already sizes the one tile that
        // is there to the cells that exist (`min(tileCols, paneCols - tx * tileCols)`), and the frame
        // follows the final cells either way. `--tile` is how the picture is *cut*, never how big it
        // is - the aspect, the pane and the cell decide that, which is also what `--tile`'s own
        // documentation has always said.
        cols = min(paneCols, max(1, cols))
        rows = min(paneRows, max(1, rows))
        let boxCols = cols
        let boxRows = rows
        let boxW = max(1, Int((Double(cols) * cellW).rounded()))
        let boxH = max(1, Int((Double(rows) * cellH).rounded()))
        // Two independent factors (issue #71):
        //
        //  * how big the picture is *on screen* is `fit`, relative to the source's own points -- as
        //    large as the pane allows, which may mean the terminal draws it larger than the source;
        //  * how many pixels the frame *has* is cells x cell x `captureScale` (below), which is what
        //    the capturer is asked for -- never the source's own count, because ScreenCaptureKit
        //    pads instead of upscaling (issue #69) and a display mirror must not grow with the pane.
        //
        // So `--scale` buys bandwidth, not screen size: at 0.5 the frame is half as many pixels in
        // the same cells, and a terminal that scales stretches it back.
        let known = source.width >= 2 && source.height >= 2
        let fit = known ? min(Double(boxW) / source.width, Double(boxH) / source.height) : 1
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
            // **Cells decide the frame's pixels**, from the *final* cell rect (the fit above may
            // have shrunk `cols`/`rows`), the same rule the wall uses for its panels. A terminal
            // that draws an image one image pixel per device pixel - Rex does - cannot stretch a
            // frame that is a few percent narrower than its cells into them, and the tile split
            // then leaves that difference behind as a seam at every tile: measured as nine black
            // lines across a 117x38-cell display page (a 1920x1200 frame on a 1989x1254 cell box),
            // and as 14 vertical ones when the frame was a proportional slice rather than the cells
            // (issue #86). `fillsCells` makes `--scale` the one remaining way to be short, and only
            // on a transport that scales (a terminal stretches the smaller frame back).
            pixelW: max(2, Int((Double(cols) * cellW * captureScale).rounded())),
            pixelH: max(2, Int((Double(rows) * cellH * captureScale).rounded())),
            bpp: bpp, scale: captureScale,
            fit: fit, sourceW: source.width, sourceH: source.height, boxW: boxW, boxH: boxH,
            boxCols: boxCols, boxRows: boxRows, fittedW: fittedW, fittedH: fittedH,
            originCol: originCol, originRow: originRow
        )
    }

    /// Pixel rect of tile at grid position (tx, ty); edge tiles are smaller.
    ///
    /// The pixels are the tile's **own cell box**, at the capture scale: `round(i x cell x scale)` at
    /// both edges, which is the same arithmetic `make` uses for `pixelW`/`pixelH`. Two things follow
    /// from that, and both are load-bearing: the widths add up to the frame exactly (no gap, no
    /// overlap, nothing dropped by `extract`), *and* every tile's image is the size of the cells its
    /// placement covers - which is what a terminal that draws one image pixel per device pixel needs,
    /// because it has no way to stretch the difference (issue #86).
    ///
    /// It used to be a proportional slice of `pixelW` (`i / cols x pixelW`). That agrees with the
    /// cell box only while `pixelW` is exactly `cols x cellW` - true for an integer cell at full
    /// scale, false for a fractional cell, where the agreement was off by a rounding. The rest of a
    /// `--scale` frame's shortfall was `captureScale` in `make` and is still there when the caller
    /// keeps `fillsCells` off; it is `fillsCells` that pins the frame to the cell box.
    ///
    /// The one precondition is that a cell is at least one pixel at the capture scale. A `--scale`
    /// small enough to put several cells inside one pixel would round two edges of a tile onto the
    /// same column, so the edges are clamped into the frame: nothing is ever read past it, and the
    /// cost of that corner is a one-pixel overlap rather than an out-of-bounds `memcpy`.
    public func rect(_ tx: Int, _ ty: Int) -> (x: Int, y: Int, w: Int, h: Int, col: Int, row: Int, cols: Int, rows: Int) {
        let cx = min(tileCols, paneCols - tx * tileCols)
        let cy = min(tileRows, paneRows - ty * tileRows)
        // Pixel rects follow the capture scale; the cell box does not (`col/row/cols/rows` below).
        let pitchX = cellW * scale
        let pitchY = cellH * scale
        let x1Cells = tx * tileCols + cx
        let y1Cells = ty * tileRows + cy
        let x0 = min(Int((Double(tx * tileCols) * pitchX).rounded()), max(0, pixelW - 1))
        let y0 = min(Int((Double(ty * tileRows) * pitchY).rounded()), max(0, pixelH - 1))
        // The last row/column ends at the frame, not at `round(cells x pitch)`: those differ only
        // when `make` floored a degenerate frame at 2 px, and the remainder belongs to the last tile
        // so that the tiles still partition the frame.
        let x1 = min(max(x0 + 1, x1Cells == paneCols ? pixelW
                           : Int((Double(x1Cells) * pitchX).rounded())), pixelW)
        let y1 = min(max(y0 + 1, y1Cells == paneRows ? pixelH
                           : Int((Double(y1Cells) * pitchY).rounded())), pixelH)
        return (x0, y0, x1 - x0, y1 - y0,
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

    /// Both answers one scan of a frame can give: *is it byte-identical to the previous frame* and
    /// *which tiles changed*.
    ///
    /// These are the two questions the pipeline asks about every delivered frame, and they used to
    /// be answered by two different reads of the same 10 MB: `Capturer` compared the whole buffer
    /// with `Array ==` (element-wise for `UInt8`, measured 4.06–4.34 ms at 2329x1452) and then
    /// `TileGrid.dirty` read the same buffer again tile-row by tile-row (0.47–0.51 ms). The frame
    /// was compared twice, and the two answers could only agree by accident — issue #95.
    ///
    /// They cannot disagree here: the tiles partition the frame (see `rect`), so a differing byte
    /// always lands in some tile, and `identical == dirty.isEmpty` by construction — for a frame of
    /// this grid. The one branch that cannot promise it is the one that has already found the two
    /// buffers do not describe this grid (see `diff`), and it says so there.
    public struct FrameDiff: Equatable {
        /// Every byte of `previous` and `current` is the same, i.e. exactly `previous == current`.
        public let identical: Bool
        /// Indices of tiles whose pixels differ, ascending — the same set `dirty` always returned.
        public let dirty: [Int]

        public init(identical: Bool, dirty: [Int]) {
            self.identical = identical
            self.dirty = dirty
        }
    }

    /// One pass over the frame, answering both questions (`FrameDiff`).
    ///
    /// The scan is **one `memcmp` per row of the frame** (1452 calls at 2329x1452) instead of one
    /// per tile row (26,136 calls), and a row that differs is then split across the tile columns
    /// inside it — but only for the columns not already known dirty, and only for rows that
    /// actually differ. So a still screen (the common case, and the one that used to cost 4.5 ms)
    /// reads the frame exactly once, while the tile set stays *exactly* the one the per-tile-row
    /// `memcmp` produced, order included: over-reporting a tile would re-send bytes the old code
    /// did not send.
    ///
    /// Every tile dirty short-circuits the rest of the scan: nothing left to learn.
    public static func diff(previous: [UInt8], current: [UInt8], grid: TileGrid) -> FrameDiff {
        let frameBytes = grid.pixelW * grid.pixelH * grid.bpp
        // Not two frames of this grid (a resize, or a caller that hands in something else): the
        // tiles answer is the safe one -- everything -- and the identity question is answered the
        // plain way, because the tile geometry cannot be trusted for a buffer of the wrong size.
        // Here `identical` and `dirty` *can* disagree (an identical pair of short buffers is
        // "identical" and still asks for a full repaint): a caller that wants "nothing to do" must
        // test `identical`, which is what `handleFrame` does. The guard is also stricter than the
        // old `dirty`, which only compared the two lengths and then read `pixelW x pixelH x bpp`
        // bytes out of a short buffer.
        guard previous.count == current.count, current.count == frameBytes else {
            return FrameDiff(identical: previous == current, dirty: Array(0..<grid.count))
        }

        let stride = grid.pixelW * grid.bpp
        var mask = [Bool](repeating: false, count: grid.count)
        var dirty: [Int] = []
        var identical = true
        var unchanged = grid.count

        previous.withUnsafeBufferPointer { prev in
            current.withUnsafeBufferPointer { cur in
                // Cannot happen (the counts above are non-zero), and if it ever did, "everything
                // changed" is the safe answer: "identical" would drop a frame that has content.
                guard let p = prev.baseAddress, let c = cur.baseAddress else {
                    identical = false
                    dirty = Array(0..<grid.count)
                    return
                }
                for ty in 0..<grid.tilesY {
                    // A tile row's pixel rows come from `ty` alone (`rect` is separable: x from tx,
                    // y from ty), so the band is read once for the whole row of tiles.
                    let band = grid.rect(0, ty)
                    let base = ty * grid.tilesX
                    for row in band.y..<(band.y + band.h) {
                        let off = row * stride
                        if memcmp(p + off, c + off, stride) == 0 { continue }
                        identical = false
                        for tx in 0..<grid.tilesX where !mask[base + tx] {
                            let r = grid.rect(tx, ty)
                            let colOff = off + r.x * grid.bpp
                            if memcmp(p + colOff, c + colOff, r.w * grid.bpp) != 0 {
                                mask[base + tx] = true
                                unchanged -= 1
                            }
                        }
                        if unchanged == 0 {
                            dirty = Array(0..<grid.count)
                            return          // nothing left to learn: every tile is dirty
                        }
                    }
                    // Appended per band, so the result is ascending in index order (the order the
                    // encoder emits tiles in, and the one the old per-tile loop produced).
                    for tx in 0..<grid.tilesX where mask[base + tx] { dirty.append(base + tx) }
                }
            }
        }
        return FrameDiff(identical: identical, dirty: dirty)
    }

    /// Indices of tiles whose pixels differ — the tile-only face of `diff`.
    ///
    /// The pipeline asks both questions, so it calls `diff` and never pays for this read twice;
    /// this stays as the API for a caller that only wants the tiles (the bench, the tests).
    public static func dirty(previous: [UInt8], current: [UInt8], grid: TileGrid) -> [Int] {
        diff(previous: previous, current: current, grid: grid).dirty
    }
}
