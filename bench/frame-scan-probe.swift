// #95 before/after: one scan per delivered frame instead of `Array ==` + a second tile pass.
//
// The pipeline used to compare every delivered frame twice: `Capturer` did `previous == rgba`
// (Sources/krd/Capture.swift) and then `TileGrid.dirty` read the same bytes again tile-row by
// tile-row. This probe times all three shapes on the documented layout, in one process, minutes
// apart, so every number has its own before/after pair on the same machine:
//
//   dedupe.arrayEQ   the pre-#95 identity check: `a == b` on two distinct 10 MB buffers (element-
//                    wise for `UInt8`, no memcmp fast path)
//   dirty.old        the pre-#95 tile pass: one memcmp per tile row (198 tiles x 132 rows at 8x4)
//   twoPass.old      both of the above, i.e. what one delivered frame cost before
//   diff.new         `TileGrid.diff` -- one scan answering both questions (what HEAD does now)
//
// Build & run (no product source is touched, nothing is written to .build):
//
//   swift build -c release
//   swiftc -O bench/frame-scan-probe.swift .build/release/krdcore.o \
//          -I .build/release -I Sources/CZlib -o /tmp/frame-scan-probe
//   /tmp/frame-scan-probe                  # min-of-9 ms per probe, one JSON line each
//
// The layout is the one `docs/BENCHMARK.md` and the issue quote:
// --pane 137x44 --cell 17x33 --source 1920x1200 -> 2329x1452 px, 198 tiles of 8x4 cells.
//
// Minimums, not medians: the machine is shared with other agents (other lanes are compiling), so a
// mean measures the neighbours. `krd --bench --json` is the other half of the measurement and
// reports p50/p99 over 20 rounds.

import Foundation
import krdcore

@inline(__always) func nowMs() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
}

/// Best (minimum) of `n` runs. The round number reaches the body so nothing can be hoisted out of
/// the loop: a pure comparison hoisted out reads as 0.000 ms.
func best(_ n: Int = 9, _ body: (Int) -> Void) -> Double {
    var lo = Double.infinity
    for i in 0..<n {
        let t0 = nowMs()
        body(i)
        let dt = nowMs() - t0
        if dt < lo { lo = dt }
    }
    return lo
}

/// Opaque, so `detachCopy` cannot be elided. A copy has its own storage, which is what `Capturer`
/// hands the comparison: it alternates two buffers, so the two sides never alias (#1).
@inline(never) func detachCopy(_ p: [UInt8], tag: Int) -> [UInt8] {
    var q = p
    q.withUnsafeMutableBufferPointer { $0[0] = $0[0] &+ UInt8(truncatingIfNeeded: tag &* 0) }
    return q
}

@inline(never) func opArrayEQ(_ a: [UInt8], _ b: [UInt8]) -> Bool { a == b }

/// The pre-#95 `TileGrid.dirty`, verbatim: one memcmp per tile row, break at the first row of a
/// tile that differs. Kept here (not in the library) because it is the baseline, not the product.
func oldDirty(previous: [UInt8], current: [UInt8], grid: TileGrid) -> [Int] {
    guard previous.count == current.count else { return Array(0..<grid.count) }
    var result: [Int] = []
    let stride = grid.pixelW * grid.bpp
    previous.withUnsafeBufferPointer { prev in
        current.withUnsafeBufferPointer { cur in
            for ty in 0..<grid.tilesY {
                for tx in 0..<grid.tilesX {
                    let r = grid.rect(tx, ty)
                    var differs = false
                    for row in 0..<r.h {
                        let off = (r.y + row) * stride + r.x * grid.bpp
                        if memcmp(prev.baseAddress! + off, cur.baseAddress! + off, r.w * grid.bpp) != 0 {
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

var sinkInt = 0
var sinkBool = false

func report(_ name: String, _ ms: Double, _ extra: String = "") {
    print(String(format: "{\"probe\":\"%@\",\"ms\":%.4f%@}", name, ms, extra))
}

let layout = TileGrid.make(paneCols: 137, paneRows: 44, cellW: 17, cellH: 33,
                           aspect: 1920.0 / 1200.0, tileCols: 8, tileRows: 4, bpp: 3,
                           scale: 1, source: CGSize(width: 1920, height: 1200))
print("// layout \(layout.pixelW)x\(layout.pixelH) px, \(layout.tilesX)x\(layout.tilesY) = "
      + "\(layout.count) tiles of \(layout.tileCols)x\(layout.tileRows) cells, bpp \(layout.bpp), "
      + "\(layout.pixelW * layout.pixelH * layout.bpp) B/frame")

// The `text` content generator from Sources/krd/Bench.swift, so the frames match `krd --bench`.
func textFrame(_ grid: TileGrid) -> [UInt8] {
    var px = [UInt8](repeating: 0, count: grid.pixelW * grid.pixelH * grid.bpp)
    px.withUnsafeMutableBufferPointer { buf in
        for y in 0..<grid.pixelH {
            for x in 0..<grid.pixelW {
                let glyph = (x % 23 < 3 || y % 41 < 2) ? UInt8(20) : UInt8(245)
                let o = (y * grid.pixelW + x) * grid.bpp
                buf[o] = glyph; buf[o + 1] = glyph
                if grid.bpp == 4 { buf[o + 3] = 255 } else { buf[o + 2] = y % 97 < 2 ? 0 : glyph }
            }
        }
    }
    return px
}

let base = textFrame(layout)
// Identical *content* with its own storage: what `Capturer` hands the identity check, since it
// alternates two buffers and `Array ==`'s buffer-identity shortcut can never fire (#1). Comparing
// an array with itself would measure a pointer check.
let baseCopy = detachCopy(base, tag: 0)
// One changed byte in the middle tile: the "one character" case.
var oneTile = base
let mid = layout.rect(layout.count / 2 % layout.tilesX, layout.count / 2 / layout.tilesX)
oneTile[(mid.y * layout.pixelW + mid.x) * layout.bpp] = 7
// Every byte changed: a scrolled page, the worst case for the tile map.
var allTiles = base
for i in stride(from: 0, to: allTiles.count, by: 3) { allTiles[i] = allTiles[i] &+ 1 }

let frames = [("identical", baseCopy, base), ("one-tile", oneTile, base), ("all", allTiles, base)]
let copies = (0..<12).map { detachCopy(base, tag: $0) }

// 1. the identity check on its own: `Array ==` (pre-#95) vs the scan that replaced it
let eqIdentical = best { i in sinkBool = opArrayEQ(base, copies[i]) }
report("dedupe.arrayEQ.identical", eqIdentical, ",\"bytes\":\(base.count)")

// 2. the tile pass on its own, old vs new
for (name, current, previous) in frames {
    let o = best { _ in sinkInt += oldDirty(previous: previous, current: current, grid: layout).count }
    report("dirty.old.\(name)", o)
    let n = best { _ in sinkInt += TileGrid.diff(previous: previous, current: current, grid: layout).dirty.count }
    report("diff.new.\(name)", n)
}

// 3. the whole per-frame scan, both answers: what one delivered frame cost before vs now
for (name, current, previous) in frames {
    let two = best { i in
        let prev = i == 0 ? previous : detachCopy(previous, tag: i)
        sinkBool = opArrayEQ(prev, current)
        sinkInt += oldDirty(previous: prev, current: current, grid: layout).count
    }
    report("twoPass.old.\(name)", two)
    let one = best { _ in sinkInt += TileGrid.diff(previous: previous, current: current, grid: layout).dirty.count }
    report("oneScan.new.\(name)", one)
}

// 4. the answers must agree, byte for byte, on every frame above
for (name, current, previous) in frames {
    let d = TileGrid.diff(previous: previous, current: current, grid: layout)
    let old = oldDirty(previous: previous, current: current, grid: layout)
    let same = d.identical == opArrayEQ(previous, current) && d.dirty == old
    print("// agree[\(name)] = \(same)  identical=\(d.identical) tiles=\(d.dirty.count)")
}
