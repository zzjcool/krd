import Foundation

/// Grid of whole-cell tiles.
///
/// Every tile occupies a whole number of terminal cells, so it can be placed with
/// `c`/`r` alone (no sub-cell pixel offsets) and the terminal never has to resample.
struct TileGrid {
    let paneCols: Int
    let paneRows: Int
    let cellW: Double
    let cellH: Double
    /// Cells per tile.
    let tileCols: Int
    let tileRows: Int
    /// Scaled frame size in device pixels: exactly paneCols x paneRows cells.
    let pixelW: Int
    let pixelH: Int

    var tilesX: Int { (paneCols + tileCols - 1) / tileCols }
    var tilesY: Int { (paneRows + tileRows - 1) / tileRows }
    var count: Int { tilesX * tilesY }

    /// Fit `aspect` (width / height) into the pane, using whole cells.
    static func make(geometry: TermGeometry, aspect: Double, tileCols: Int, tileRows: Int) -> TileGrid {
        let cell = geometry.cellSize
        // Largest cell rectangle with the source aspect that fits the pane.
        var cols = geometry.cols
        var rows = Int((Double(cols) * cell.w / aspect / cell.h).rounded())
        if rows > geometry.rows {
            rows = geometry.rows
            cols = Int((Double(rows) * cell.h * aspect / cell.w).rounded())
        }
        cols = max(tileCols, min(geometry.cols, cols))
        rows = max(tileRows, min(geometry.rows, rows))
        return TileGrid(
            paneCols: cols, paneRows: rows,
            cellW: cell.w, cellH: cell.h,
            tileCols: tileCols, tileRows: tileRows,
            pixelW: max(2, Int((Double(cols) * cell.w).rounded())),
            pixelH: max(2, Int((Double(rows) * cell.h).rounded()))
        )
    }

    /// Pixel rect of tile at grid position (tx, ty); edge tiles are smaller.
    func rect(_ tx: Int, _ ty: Int) -> (x: Int, y: Int, w: Int, h: Int, col: Int, row: Int, cols: Int, rows: Int) {
        let cx = min(tileCols, paneCols - tx * tileCols)
        let cy = min(tileRows, paneRows - ty * tileRows)
        let x0 = Int((Double(tx * tileCols) * cellW).rounded())
        let y0 = Int((Double(ty * tileRows) * cellH).rounded())
        let x1 = Int((Double(tx * tileCols + cx) * cellW).rounded())
        let y1 = Int((Double(ty * tileRows + cy) * cellH).rounded())
        return (x0, y0, max(1, x1 - x0), max(1, y1 - y0),
                tx * tileCols + 1, ty * tileRows + 1, cx, cy)
    }

    /// Copy one tile out of a full RGBA frame into a tight buffer.
    func extract(_ frame: [UInt8], rect r: (x: Int, y: Int, w: Int, h: Int, col: Int, row: Int, cols: Int, rows: Int)) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: r.w * r.h * 4)
        let stride = pixelW * 4
        frame.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for row in 0..<r.h {
                    let s = (r.y + row) * stride + r.x * 4
                    let d = row * r.w * 4
                    memcpy(dst.baseAddress! + d, src.baseAddress! + s, r.w * 4)
                }
            }
        }
        return out
    }

    /// Indices of tiles whose pixels differ.
    static func dirty(previous: [UInt8], current: [UInt8], grid: TileGrid) -> [Int] {
        guard previous.count == current.count else { return Array(0..<grid.count) }
        var result: [Int] = []
        let stride = grid.pixelW * 4
        previous.withUnsafeBufferPointer { prev in
            current.withUnsafeBufferPointer { cur in
                for ty in 0..<grid.tilesY {
                    for tx in 0..<grid.tilesX {
                        let r = grid.rect(tx, ty)
                        var differs = false
                        for row in 0..<r.h {
                            let off = (r.y + row) * stride + r.x * 4
                            if memcmp(prev.baseAddress! + off, cur.baseAddress! + off, r.w * 4) != 0 {
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
