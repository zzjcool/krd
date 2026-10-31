// #94 before/after: the incompressibility heuristic, exhaustive scan vs the exact fast scan.
//
// `ScreenWriter.looksCompressible` decides whether a tile is worth zlib at all (#53) and whether it
// is worth quantising (#59). It used to compare every byte of every tile of every frame. The
// decision is a majority vote (`> 0.5` of `|delta| <= 4`) over a *known* number of comparisons, so
// it can be settled early with a proof rather than an estimate -- which is what the fix does.
//
// The issue proposed a 1-in-4 *sample* instead (0.98 ms/frame, "198/198 verdicts"). This probe is
// the gate that rejected it: a sample answers the tiles that were never in doubt and gets the ones
// sitting on the cut wrong. Measured, on the bench's own frames: `photoReal` moves 0.24 % of its
// payload bytes under the sample (`krd --bench` report below), and that is a byte-contract break.
// Hence: same counters, same threshold, exact answer, early exit.
//
// Build & run (no product source is touched, nothing is written to .build):
//
//   swift build -c release
//   swiftc -O bench/incompressible-sample-probe.swift .build/release/krdcore.o \
//          -I .build/release -I Sources/CZlib -o /tmp/incompressible-sample-probe
//   /tmp/incompressible-sample-probe
//
// Layout is the one `bench/budget.json` and the issue quote: --pane 137x44 --cell 17x33
// --source 1920x1200 -> 2329x1452 px, 198 tiles of 8x4 cells. Minimums, not medians: the machine is
// shared with other lanes. Both shapes are `internal`, so the probe carries them verbatim.

import Foundation
import krdcore

@inline(__always) func nowMs() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
}

/// Best (minimum) of `n` runs; the round number reaches the body so nothing can be hoisted out.
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

// MARK: - the two shapes

/// The pre-#94 predictor, verbatim (`Sources/krdcore/Render.swift` @ 003f4c7).
func looksCompressibleExhaustive(_ pixels: [UInt8], rect: TileRect) -> Bool {
    let w = rect.w, h = rect.h
    guard w > 1, h > 0, pixels.count >= w * h else { return true }
    let bpp = max(1, pixels.count / (w * h))
    let rowBytes = w * bpp
    var smooth = 0, compared = 0
    for y in 0..<h {
        let row = y * rowBytes
        for i in row..<(row + rowBytes) {
            let reference = y > 0 ? i - rowBytes : (i - bpp >= row ? i - bpp : -1)
            guard reference >= 0 else { continue }
            compared += 1
            if abs(Int(pixels[i]) - Int(pixels[reference])) <= 4 { smooth += 1 }
        }
    }
    guard compared > 0 else { return true }
    return Double(smooth) / Double(compared) > 0.5
}

/// The post-#94 predictor, verbatim: the same counters and threshold, an exact early exit.
func looksCompressibleFast(_ pixels: [UInt8], rect: TileRect) -> Bool {
    let w = rect.w, h = rect.h
    guard w > 1, h > 0, pixels.count >= w * h else { return true }
    let bpp = max(1, pixels.count / (w * h))
    let rowBytes = w * bpp
    let total = h * rowBytes - bpp
    guard total > 0 else { return true }
    var smooth = 0, compared = 0
    var decided: Bool?
    pixels.withUnsafeBufferPointer { p in
        for y in 0..<h {
            let row = y * rowBytes
            let start = y == 0 ? row + bpp : row
            var i = start
            while i < row + rowBytes {
                // `UInt8` absolute difference: the wrapping delta alone is `(a-b) mod 256`, and
                // `d >= 252` on it also fires on `|a-b| ∈ {252...255}` (20 of 65,536 pairs).
                let a = p[i], b = p[y == 0 ? i - bpp : i - rowBytes]
                let d = a > b ? a &- b : b &- a
                if d <= 4 { smooth += 1 }
                i += 1
            }
            compared += row + rowBytes - start
            if 2 * smooth > total { decided = true; return }
            if 2 * (smooth + (total - compared)) <= total { decided = false; return }
        }
    }
    if let decided { return decided }
    return 2 * smooth > total
}

// MARK: - the bench content, verbatim from Sources/krd/Bench.swift

/// Triangle wave in 0...255, integer-only so the bytes are reproducible (`BenchContent.wave`).
func wave(_ v: Int, period: Int, phase: Int) -> Int {
    let p = ((v + phase) % period + period) % period
    let half = max(period / 2, 1)
    return (p < half ? p : period - p) * 255 / max(half - 1, 1)
}

func clamp8(_ v: Int) -> UInt8 { UInt8(min(255, max(0, v))) }

func contentPixel(_ kind: String, _ x: Int, _ y: Int, seed: Int) -> (UInt8, UInt8, UInt8) {
    switch kind {
    case "text":
        let glyph = ((x + seed) % 23 < 3 || (y + seed) % 41 < 2) ? UInt8(20) : UInt8(245)
        return (glyph, glyph, (y + seed) % 97 < 2 ? 0 : glyph)
    case "noise":
        var h = UInt32(truncatingIfNeeded: x &* 73856093)
            ^ UInt32(truncatingIfNeeded: y &* 19349663)
            ^ UInt32(truncatingIfNeeded: (seed &* 2654435761) & 0x7fff_ffff)
        h ^= h >> 13; h = h &* 1274126177; h ^= h >> 16
        return (UInt8(truncatingIfNeeded: h),
                UInt8(truncatingIfNeeded: h >> 8),
                UInt8(truncatingIfNeeded: h >> 16))
    case "ui":
        let sx = (x + seed * 3) / 64, sy = (y + seed) / 48
        let block = (sx + sy) % 5
        let border = (x + seed * 3) % 64 < 2 || (y + seed) % 48 < 2
        let base = UInt8(210 + block * 8)
        return border ? (90, 100, 120) : (base, base, UInt8(min(255, Int(base) + 6)))
    case "photoReal":
        let lum = (wave(x &* 2 &+ y, period: 2329, phase: seed &* 13) * 2
                   + wave(y &* 2 &+ x / 3, period: 1452, phase: seed &* 7)) / 3
        let tint = (wave(x &+ y &* 2, period: 1747, phase: seed &* 29) - 128) / 6
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393)
            ^ UInt32(truncatingIfNeeded: y &* 668_265_263)
            ^ UInt32(truncatingIfNeeded: (seed &* 2_246_822_519) & 0x7fff_ffff)
        h ^= h >> 15; h = h &* 2_246_822_519; h ^= h >> 13
        let grain = Int(h % 21) - 10
        return (clamp8(lum + tint + grain), clamp8(lum + grain), clamp8(lum - tint + grain))
    default:  // gradient
        let v = UInt8(truncatingIfNeeded: ((x + seed * 40) % 2329) * 255 / 2329)
        let w = UInt8(truncatingIfNeeded: ((y + seed * 20) % 1452) * 255 / 1452)
        return (v, w, UInt8(truncatingIfNeeded: (Int(v) + Int(w)) / 2))
    }
}

func makeFrame(_ grid: TileGrid, _ kind: String, seed: Int = 0) -> [UInt8] {
    var px = [UInt8](repeating: 0, count: grid.pixelW * grid.pixelH * grid.bpp)
    px.withUnsafeMutableBufferPointer { buf in
        for y in 0..<grid.pixelH {
            for x in 0..<grid.pixelW {
                let c = contentPixel(kind, x, y, seed: seed)
                let o = (y * grid.pixelW + x) * grid.bpp
                buf[o] = c.0; buf[o + 1] = c.1; buf[o + 2] = c.2
                if grid.bpp == 4 { buf[o + 3] = 255 }
            }
        }
    }
    return px
}

/// `BenchCase.stamp`: one byte per tile the case claims to dirty, from (round, index).
func stamp(_ px: inout [UInt8], _ grid: TileGrid, tiles: String, round: Int) {
    var targets: [Int] = []
    switch tiles {
    case "one": targets = [(grid.tilesY / 2) * grid.tilesX + grid.tilesX / 2]
    case "row": targets = (0..<grid.tilesX).map { (grid.tilesY / 2) * grid.tilesX + $0 }
    case "all": targets = Array(0..<grid.count)
    default: targets = []
    }
    px.withUnsafeMutableBufferPointer { buf in
        for index in targets {
            let r = grid.rect(index % grid.tilesX, index / grid.tilesX)
            let o = (r.y * grid.pixelW + r.x) * grid.bpp
            guard o < buf.count else { continue }
            buf[o] = UInt8(truncatingIfNeeded: round &* 31 &+ index &* 7 &+ 1)
        }
    }
}

// MARK: - the probe

let layout = TileGrid.make(paneCols: 137, paneRows: 44, cellW: 17, cellH: 33,
                           aspect: 1920.0 / 1200.0, tileCols: 8, tileRows: 4, bpp: 3,
                           scale: 1, source: CGSize(width: 1920, height: 1200))
print("// layout \(layout.pixelW)x\(layout.pixelH) px, \(layout.tilesX)x\(layout.tilesY) = "
      + "\(layout.count) tiles of \(layout.tileCols)x\(layout.tileRows) cells, bpp \(layout.bpp), "
      + "\(layout.pixelW * layout.pixelH * layout.bpp) B/frame")

// name -> (content, dirty-set as in `benchCases`)
let cases: [(String, String, String)] = [
    ("char", "text", "one"),
    ("line", "text", "row"),
    ("full", "text", "all"),
    ("photo", "noise", "all"),
    ("photoReal", "photoReal", "all"),
    ("gradient", "gradient", "all"),
    ("ui", "ui", "all"),
    ("drag", "noise", ""),
    ("none", "text", ""),
]

let rects = (0..<layout.count).map { layout.rect($0 % layout.tilesX, $0 / layout.tilesX) }
var totalTiles = 0, totalDiffer = 0

// 1. the verdict table: every tile of every case, on the frames the bench actually encodes
for (name, kind, dirty) in cases {
    var agree = 0, differ = 0, compOld = 0, compNew = 0, tiles = 0
    for round in 0..<3 {
        var px = makeFrame(layout, kind)
        stamp(&px, layout, tiles: dirty, round: round)
        for (index, rect) in rects.enumerated() {
            let pixels = layout.extract(px, rect: rect)
            // One-byte-per-tile stamps only touch channels of the first pixel; a tile the case
            // does not dirty is encoded identically either way, so it is still a real sample.
            if round > 0 && dirty.isEmpty { break }
            let old = looksCompressibleExhaustive(pixels, rect: rect)
            let new = looksCompressibleFast(pixels, rect: rect)
            // The encoder predicts again on the *quantised* tile (issue #59), and that is where the
            // boundary sits: check both shapes, or the flip hides.
            let q = ScreenWriter.quantise565(pixels)
            let qOld = looksCompressibleExhaustive(q, rect: rect)
            let qNew = looksCompressibleFast(q, rect: rect)
            _ = index
            tiles += 2
            if old { compOld += 1 }
            if new { compNew += 1 }
            if qOld { compOld += 1 }
            if qNew { compNew += 1 }
            if old == new { agree += 1 } else { differ += 1 }
            if qOld == qNew { agree += 1 } else { differ += 1 }
        }
    }
    totalTiles += tiles
    totalDiffer += differ
    print("{\"case\":\"\(name)\",\"tiles\":\(tiles),\"compressible.old\":\(compOld),"
          + "\"compressible.new\":\(compNew),\"agree\":\(agree),\"differ\":\(differ)}")
}
print("// verdicts: \(totalTiles - totalDiffer)/\(totalTiles) agree, \(totalDiffer) differ")

// 2. cost per frame, over every tile (the `full` and `photo` shapes: the predictor runs on all
//    198 tiles there, which is the per-frame cost the issue quotes)
var sink = 0
for (name, kind) in [("photo", "noise"), ("text", "text")] {
    let frame = makeFrame(layout, kind)
    let tiles = rects.map { layout.extract(frame, rect: $0) }
    let old = best { _ in
        var n = 0
        for (i, rect) in rects.enumerated() where looksCompressibleExhaustive(tiles[i], rect: rect) { n += 1 }
        sink &+= n
    }
    let new = best { _ in
        var n = 0
        for (i, rect) in rects.enumerated() where looksCompressibleFast(tiles[i], rect: rect) { n += 1 }
        sink &+= n
    }
    print(String(format: "{\"probe\":\"looksCompressible.%@.per-frame\",\"old_ms\":%.3f,"
                 + "\"new_ms\":%.3f,\"ratio\":%.1fx}", name, old, new, old / max(new, 0.0001)))
}
print("// sanity \(sink)")
