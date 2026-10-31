// Overnight perf probe (round A, surface: encoder byte path).
//
// Standalone micro-benchmarks of the *real* HEAD functions in `krdcore`, each against the
// candidate fix for the same step, so every number in the filed issues has a before/after pair
// measured on the same machine, minutes apart.
//
// Build & run (no product source is touched):
//
//   swift build -c release                     # produces .build/release/krdcore.o
//   swiftc -O bench/perf-probe.swift .build/release/krdcore.o \
//          -I .build/release -I Sources/CZlib -o /tmp/krd-overnight/perf-encoder/perf-probe
//   /tmp/krd-overnight/perf-encoder/perf-probe
//
// The layout is the documented one: --pane 137x44 --cell 17x33 --source 1920x1200
// (2329x1452 px, 198 tiles of 8x4 cells), i.e. exactly what `krd --bench --json` reports.
//
// Timings are min-of-N (N = 7 unless said otherwise); the machine is shared with other agents,
// so the minimum is the only comparable statistic here.

import Foundation
import krdcore
import CZlib
import Accelerate

// MARK: - harness

@inline(__always) func nowMs() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
}

/// Best (minimum) of `n` runs, in ms. The round number is handed to the body so nothing that
/// depends on its input can be hoisted out of the loop (a 10 MB `==` hoisted out reads as 0.000 ms).
func best(_ n: Int = 7, _ body: (Int) -> Void) -> Double {
    var lo = Double.infinity
    for i in 0..<n {
        let t0 = nowMs()
        body(i)
        let dt = nowMs() - t0
        if dt < lo { lo = dt }
    }
    return lo
}

/// Opaque calls: keep the optimiser from constant-folding a pure measurement.
/// A copy with its own storage (an opaque call, so `==`'s buffer-identity fast path cannot fire
/// and the comparison cannot be hoisted out of the timing loop).
@inline(never) func detachCopy(_ p: [UInt8], tag: Int) -> [UInt8] {
    var q = p
    q.withUnsafeMutableBufferPointer { $0[0] = $0[0] &+ UInt8(truncatingIfNeeded: tag &* 0) }
    return q
}

@inline(never) func opEQ(_ a: [UInt8], _ b: [UInt8]) -> Bool { a == b }
@inline(never) func opMemcmp(_ a: [UInt8], _ b: [UInt8]) -> Int32 {
    a.withUnsafeBytes { p in b.withUnsafeBytes { q in memcmp(p.baseAddress!, q.baseAddress!, p.count) } }
}
@inline(never) func opElementsEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool { a.elementsEqual(b) }
@inline(never) func opLook(_ p: [UInt8], _ r: TileRect) -> Bool { looksCompressible(p, rect: r) }
@inline(never) func opExtract(_ f: [UInt8], _ r: TileRect, _ g: TileGrid) -> [UInt8] { g.extract(f, rect: r) }
@inline(never) func opQuantiseHead(_ p: [UInt8]) -> [UInt8] { ScreenWriter.quantise565(p, bytesPerPixel: 3) }
@inline(never) func opZlib(_ p: [UInt8], _ level: Int) -> [UInt8]? { zlibCompress(p, level: level) }

/// Same, but returns the blackhole so the optimiser cannot drop the work.
var sinkByte = 0
var sinkBytes = 0

func report(_ name: String, _ ms: Double, _ extra: String = "") {
    print(String(format: "{\"probe\":\"%@\",\"ms\":%.4f%@}", name, ms, extra))
}

let layout = TileGrid.make(paneCols: 137, paneRows: 44, cellW: 17, cellH: 33,
                           aspect: 1920.0 / 1200.0, tileCols: 8, tileRows: 4, bpp: 3,
                           scale: 1, source: CGSize(width: 1920, height: 1200))
print("// layout \(layout.pixelW)x\(layout.pixelH) px, \(layout.tilesX)x\(layout.tilesY) = \(layout.count) tiles of \(layout.tileCols)x\(layout.tileRows) cells, bpp \(layout.bpp)")

let allTiles: [(x: Int, y: Int, w: Int, h: Int, col: Int, row: Int, cols: Int, rows: Int)] =
    (0..<layout.count).map { layout.rect($0 % layout.tilesX, $0 / layout.tilesX) }

// MARK: - content (copied from Sources/krd/Bench.swift so the frames match the shipped bench)

func contentPixel(_ x: Int, _ y: Int, noise: Bool) -> (UInt8, UInt8, UInt8) {
    if noise {
        var h = UInt32(truncatingIfNeeded: x &* 73856093)
            ^ UInt32(truncatingIfNeeded: y &* 19349663)
        h ^= h >> 13; h = h &* 1274126177; h ^= h >> 16
        return (UInt8(truncatingIfNeeded: h), UInt8(truncatingIfNeeded: h >> 8),
                UInt8(truncatingIfNeeded: h >> 16))
    }
    let glyph = (x % 23 < 3 || y % 41 < 2) ? UInt8(20) : UInt8(245)
    return (glyph, glyph, y % 97 < 2 ? 0 : glyph)
}

func makeFrame(_ grid: TileGrid, noise: Bool) -> [UInt8] {
    let w = grid.pixelW, h = grid.pixelH, bpp = grid.bpp
    var px = [UInt8](repeating: 0, count: w * h * bpp)
    px.withUnsafeMutableBufferPointer { buf in
        for y in 0..<h {
            for x in 0..<w {
                let c = contentPixel(x, y, noise: noise)
                let o = (y * w + x) * bpp
                buf[o] = c.0; buf[o + 1] = c.1; buf[o + 2] = c.2
            }
        }
    }
    return px
}

let noiseFrame = makeFrame(layout, noise: true)
let textFrame = makeFrame(layout, noise: false)

// MARK: - 1. whole-frame dedupe: `Array ==` vs memcmp  (Sources/krd/Capture.swift:236)

func probeDedupe() {
    // Two distinct buffers of the same size, exactly what Capturer compares: `rgba` and the
    // swapped-in `spare` never share storage.
    var a = noiseFrame
    var b = noiseFrame
    a.withUnsafeMutableBufferPointer { $0[0] = $0[0] &+ 1 }
    b.withUnsafeMutableBufferPointer { $0[1] = $0[1] &+ 1 }
    let n = a.count

    // Same buffers, differing in the first byte only (what a moving cursor looks like).
    var c = a
    c[0] = c[0] &+ 1
    // Identical content, distinct storage (the `none` bench case: a delivered frame that changed
    // nothing). One copy per round, so the comparison cannot be hoisted.
    let copies = (0..<12).map { detachCopy(a, tag: $0) }

    let eq = best(9) { i in if opEQ(a, b) { sinkByte += 1 + i * 0 } }
    report("dedupe.arrayEQ.differ.late-byte", eq, ",\"bytes\":\(n)")

    let eqEarly = best(9) { i in if opEQ(a, c) { sinkByte += 1 + i * 0 } }
    report("dedupe.arrayEQ.differ.first-byte", eqEarly, ",\"bytes\":\(n)")

    let eqSame = best(9) { i in if opEQ(a, copies[i]) { sinkByte += 1 } }
    report("dedupe.arrayEQ.identical", eqSame, ",\"bytes\":\(n)")

    let mem = best(9) { i in sinkByte += Int(opMemcmp(a, copies[i])) }
    report("dedupe.memcmp.identical", mem, ",\"bytes\":\(n)")

    let eqEl = best(9) { i in if opElementsEqual(a, copies[i]) { sinkByte += 1 } }
    report("dedupe.elementsEqual.identical", eqEl, ",\"bytes\":\(n)")
}

// MARK: - 2. the dirty scan (Sources/krdcore/Tiles.swift:196)

func probeDirty() {
    var frame = textFrame
    // One changed byte in the middle tile: the "one character" case.
    let mid = layout.count / 2
    let r = allTiles[mid]
    frame[(r.y * layout.pixelW + r.x) * layout.bpp] = 7

    let one = best(9) { _ in sinkBytes += opDirty(textFrame, frame, layout) }
    report("dirty.one-tile", one)

    let none = best(9) { _ in sinkBytes += opDirty(textFrame, frame, layout) }
    report("dirty.identical", none)

    // Candidate: one memcmp per row-run over the whole frame, then map the differing rows onto
    // tiles, instead of one memcmp call per tile row (198 tiles x 4 rows = 792 calls at 8x4).
    let stride = layout.pixelW * layout.bpp
    let rowBytes = layout.pixelW * layout.bpp
    let fused = best(9) { _ in
        var changedRows: [Int] = []
        textFrame.withUnsafeBufferPointer { prev in
            frame.withUnsafeBufferPointer { cur in
                for row in 0..<layout.pixelH {
                    let off = row * stride
                    if memcmp(prev.baseAddress! + off, cur.baseAddress! + off, rowBytes) != 0 {
                        changedRows.append(row)
                    }
                }
            }
        }
        sinkBytes += changedRows.count
    }
    report("dirty.rowscan-frame", fused)
}

// MARK: - 3. tile extraction: allocate+zero+copy per tile (Sources/krdcore/Tiles.swift:161)

func probeExtract() {
    // HEAD: a fresh, zero-filled [UInt8] per tile per frame.
    let baseline = best { _ in for r in allTiles { sinkBytes += opExtract(noiseFrame, r, layout).count } }
    report("extract.alloc-per-tile", baseline, ",\"tiles\":\(layout.count)")

    // Candidate: one persistent scratch buffer per tile, reused every frame (row memcpy only).
    var scratch = allTiles.map { [UInt8](repeating: 0, count: $0.w * $0.h * layout.bpp) }
    let reused = best { _ in
        for (i, r) in allTiles.enumerated() {
            extractInto(&scratch[i], noiseFrame, rect: r, grid: layout)
            sinkBytes += scratch[i].count
        }
    }
    report("extract.reused-scratch", reused, ",\"tiles\":\(layout.count)")

    // And without the zero-fill at all (uninitialised capacity), to price the memset alone.
    let uninit = best { _ in
        for r in allTiles {
            var out = [UInt8](unsafeUninitializedCapacity: r.w * r.h * layout.bpp) { buf, count in
                count = r.w * r.h * layout.bpp
                let stride = layout.pixelW * layout.bpp
                let rowBytes = r.w * layout.bpp
                noiseFrame.withUnsafeBufferPointer { src in
                    for row in 0..<r.h {
                        memcpy(buf.baseAddress! + row * rowBytes,
                               src.baseAddress! + (r.y + row) * stride + r.x * layout.bpp, rowBytes)
                    }
                }
            }
            sinkBytes += out.count
            out.removeAll(keepingCapacity: false)
        }
    }
    report("extract.no-zero-fill", uninit, ",\"tiles\":\(layout.count)")
}

func extractInto(_ out: inout [UInt8],
                 _ frame: [UInt8],
                 rect r: (x: Int, y: Int, w: Int, h: Int, col: Int, row: Int, cols: Int, rows: Int),
                 grid: TileGrid) {
    let stride = grid.pixelW * grid.bpp
    let rowBytes = r.w * grid.bpp
    frame.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
            for row in 0..<r.h {
                memcpy(dst.baseAddress! + row * rowBytes,
                       src.baseAddress! + (r.y + row) * stride + r.x * grid.bpp, rowBytes)
            }
        }
    }
}

// MARK: - 4. zlib: one compress2 per tile vs one reused stream (Sources/krdcore/Render.swift:768)

func probeZlib() {
    let tiles = allTiles.map { layout.extract(noiseFrame, rect: $0) }

    // HEAD: zlibCompress -> compressBound + fresh zero-filled output + compress2 (which is
    // deflateInit + deflate + deflateEnd, i.e. a full ~200 KB deflate_state per tile).
    let head = best { _ in for t in tiles { sinkBytes += opZlib(t, 1)?.count ?? 0 } }
    report("zlib.compress2-per-tile.level1", head, ",\"tiles\":\(tiles.count)")

    // Price the stream churn on its own: init + end, no bytes.
    let initOnly = best { _ in
        for _ in 0..<tiles.count {
            var s = z_stream()
            if deflateInit2_(&s, 1, Z_DEFLATED, 15, 8, Z_DEFAULT_STRATEGY,
                             ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK {
                deflateEnd(&s)
                sinkByte += 1
            }
        }
    }
    report("zlib.deflateInit2+end", initOnly, ",\"tiles\":\(tiles.count)")

    // Price the output allocation + memset on its own.
    let maxBound = tiles.map { Int(compressBound(uLong($0.count))) }.max() ?? 1
    let alloc = best { _ in for _ in 0..<tiles.count { var o = [UInt8](repeating: 0, count: maxBound); sinkBytes += o.count; o.removeAll() } }
    report("zlib.output-alloc-zero-fill", alloc, ",\"bytes\":\(maxBound)")

    // Candidate: one deflate stream, reset per tile, one preallocated output buffer.
    var stream = z_stream()
    let ok = deflateInit2_(&stream, 1, Z_DEFLATED, 15, 8, Z_DEFAULT_STRATEGY,
                           ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    precondition(ok, "deflateInit2 failed")
    var out = [UInt8](repeating: 0, count: maxBound)
    let reused = best { _ in
        for t in tiles {
            sinkBytes += deflateInto(&stream, t, &out)
        }
    }
    deflateEnd(&stream)
    report("zlib.reused-stream.level1", reused, ",\"tiles\":\(tiles.count)")

    // Both must produce identical bytes, else the comparison is meaningless.
    if let a = zlibCompress(tiles[0], level: 1) {
        var s2 = z_stream()
        _ = deflateInit2_(&s2, 1, Z_DEFLATED, 15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                          Int32(MemoryLayout<z_stream>.size))
        var o2 = [UInt8](repeating: 0, count: Int(compressBound(uLong(tiles[0].count))))
        let n = deflateInto(&s2, tiles[0], &o2)
        deflateEnd(&s2)
        let same = n == a.count && Array(o2[0..<n]) == a
        print("// reused-stream bytes == zlibCompress bytes: \(same) (\(a.count) B)")
    }

    // Level policy: the same tile at the levels LevelPolicy actually picks (9 text, 1 photo, 5 first).
    for level in [1, 5, 9] {
        let t = best(5) { _ in for x in tiles { sinkBytes += opZlib(x, level)?.count ?? 0 } }
        report("zlib.compress2-per-tile.level\(level)", t, ",\"tiles\":\(tiles.count)")
    }
}

/// deflateReset + one deflate(Z_FINISH) into a caller-owned buffer. Returns the byte count.
func deflateInto(_ stream: inout z_stream, _ input: [UInt8], _ out: inout [UInt8]) -> Int {
    deflateReset(&stream)
    var produced = 0
    input.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
            stream.next_in = UnsafeMutablePointer(mutating: src.baseAddress)
            stream.avail_in = uInt(src.count)
            stream.next_out = dst.baseAddress
            stream.avail_out = uInt(dst.count)
            if deflate(&stream, Z_FINISH) == Z_STREAM_END { produced = Int(stream.total_out) }
        }
    }
    return produced
}

// MARK: - 5. per-tile vs whole-frame zlib (the framing question)

func probeFraming() {
    let perTile = best(5) { _ in for r in allTiles { sinkBytes += opZlib(opExtract(noiseFrame, r, layout), 5)?.count ?? 0 } }
    var perTileBytes = 0
    for r in allTiles { perTileBytes += zlibCompress(layout.extract(noiseFrame, rect: r), level: 5)?.count ?? 0 }
    report("zlib.framing.per-tile.level5", perTile, ",\"bytes\":\(perTileBytes)")

    var wholeBytes = 0
    let whole = best(5) { _ in
        let c = opZlib(noiseFrame, 5) ?? []
        wholeBytes = c.count
        sinkBytes += c.count
    }
    report("zlib.framing.whole-frame.level5", whole, ",\"bytes\":\(wholeBytes)")

    // text, where cross-tile matches are cheap and real.
    var textPerTile = 0
    for r in allTiles { textPerTile += zlibCompress(layout.extract(textFrame, rect: r), level: 5)?.count ?? 0 }
    var textWhole = 0
    for _ in 0..<3 { textWhole = zlibCompress(textFrame, level: 5)?.count ?? 0 }
    print("{\"probe\":\"zlib.framing.text\",\"per_tile_bytes\":\(textPerTile),\"whole_frame_bytes\":\(textWhole)}")
}

// MARK: - 6. quantise: scalar Swift vs a hoisted/unrolled loop (Sources/krdcore/Render.swift:280)

func probeQuantise() {
    // HEAD: `ScreenWriter.quantise` (a `specs` array built per call, `specs.enumerated()` inside the
    // pixel loop, one bounds-checked store per channel).
    let head = best { _ in for r in allTiles { sinkBytes += opQuantiseHead(opExtract(noiseFrame, r, layout)).count } }
    report("quantise.head.565.per-tile", head, ",\"tiles\":\(layout.count)")

    let headWhole = best { _ in sinkBytes += opQuantiseHead(noiseFrame).count }
    report("quantise.head.565.whole-frame", headWhole, ",\"bytes\":\(noiseFrame.count)")

    // Candidate: hoisted constants, no arrays, no enumerate, unrolled for bpp == 3.
    let fast = best { _ in for r in allTiles { sinkBytes += opQuantiseFast(opExtract(noiseFrame, r, layout)).count } }
    report("quantise.fast.565.per-tile", fast, ",\"tiles\":\(layout.count)")

    // Byte-identical?
    let a = ScreenWriter.quantise565(noiseFrame, bytesPerPixel: 3)
    let b = quantiseFast565(noiseFrame)
    print("// quantiseFast565 == quantise565 for 5-6-5: \(a == b)")

    // Fused with the extraction: copy + quantise in one pass over the frame, no second buffer
    // round trip. This is the shape a fix would take (quantise the tile while it is still hot).
    var scratch = allTiles.map { [UInt8](repeating: 0, count: $0.w * $0.h * 3) }
    let fused = best { _ in
        for (i, r) in allTiles.enumerated() { extractAndQuantise(&scratch[i], noiseFrame, rect: r, grid: layout) }
        sinkBytes += scratch.count
    }
    report("quantise.fused-with-extract", fused, ",\"tiles\":\(layout.count)")
    print("// extract+quantise fused == quantise565(extract): \(scratch[3] == ScreenWriter.quantise565(layout.extract(noiseFrame, rect: allTiles[3]), bytesPerPixel: 3))")

    // How much of a `photo` frame that is: quantise runs on every tile of a photo once the
    // two-frame guard has flipped (LevelPolicy.quantised).
    print("// Photo 198 tiles: quantise is a per-frame cost, not a one-off.")
}

@inline(never) func opQuantiseFast(_ p: [UInt8]) -> [UInt8] { quantiseFast565(p) }
@inline(never) func opDirty(_ a: [UInt8], _ b: [UInt8], _ g: TileGrid) -> Int {
    TileGrid.dirty(previous: a, current: b, grid: g).count
}

@inline(__always)
func quantiseFast565(_ pixels: [UInt8]) -> [UInt8] {
    var out = pixels
    let n = out.count
    out.withUnsafeMutableBufferPointer { buf in
        guard let p = buf.baseAddress else { return }
        var i = 0
        while i + 2 < n {
            let r = p[i] >> 3; p[i] = (r << 3) | (r >> 2)
            let g = p[i + 1] >> 2; p[i + 1] = (g << 2) | (g >> 4)
            let b = p[i + 2] >> 3; p[i + 2] = (b << 3) | (b >> 2)
            i += 3
        }
    }
    return out
}

@inline(__always)
func extractAndQuantise(_ out: inout [UInt8], _ frame: [UInt8],
                        rect r: (x: Int, y: Int, w: Int, h: Int, col: Int, row: Int, cols: Int, rows: Int),
                        grid: TileGrid) {
    let stride = grid.pixelW * grid.bpp
    let rowBytes = r.w * grid.bpp
    frame.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
            for row in 0..<r.h {
                memcpy(dst.baseAddress! + row * rowBytes,
                       src.baseAddress! + (r.y + row) * stride + r.x * grid.bpp, rowBytes)
            }
            var i = 0
            let n = r.w * r.h * 3
            while i + 2 < n {
                let rr = dst[i] >> 3; dst[i] = (rr << 3) | (rr >> 2)
                let gg = dst[i + 1] >> 2; dst[i + 1] = (gg << 2) | (gg >> 4)
                let bb = dst[i + 2] >> 3; dst[i + 2] = (bb << 3) | (bb >> 2)
                i += 3
            }
        }
    }
}

// MARK: - 7. the skip heuristic: looksCompressible (Sources/krdcore/Render.swift:243)

/// Verbatim copy of `ScreenWriter.looksCompressible` (internal at HEAD, so it cannot be imported).
func looksCompressible(_ pixels: [UInt8], rect: TileRect) -> Bool {
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

/// Candidate: the same decision from every 4th pixel (stride 4), which is one quarter of the work.
func looksCompressibleSampled(_ pixels: [UInt8], rect: TileRect, stride: Int = 4) -> Bool {
    let w = rect.w, h = rect.h
    guard w > 1, h > 0, pixels.count >= w * h else { return true }
    let bpp = max(1, pixels.count / (w * h))
    let rowBytes = w * bpp
    var smooth = 0, compared = 0
    var y = 0
    while y < h {
        let row = y * rowBytes
        var i = row
        while i < row + rowBytes {
            let reference = y > 0 ? i - rowBytes : (i - bpp >= row ? i - bpp : -1)
            if reference >= 0 {
                compared += 1
                if abs(Int(pixels[i]) - Int(pixels[reference])) <= 4 { smooth += 1 }
            }
            i += bpp * stride
        }
        y += 1
    }
    guard compared > 0 else { return true }
    return Double(smooth) / Double(compared) > 0.5
}

@inline(never) func opLookSampled(_ p: [UInt8], _ r: TileRect) -> Bool { looksCompressibleSampled(p, rect: r) }

func probeHeuristic() {
    let noiseTiles = allTiles.map { layout.extract(noiseFrame, rect: $0) }
    let textTiles = allTiles.map { layout.extract(textFrame, rect: $0) }
    let noiseMs = best { _ in for (i, r) in allTiles.enumerated() { if opLook(noiseTiles[i], r) { sinkByte += 1 } } }
    report("looksCompressible.noise.per-frame", noiseMs, ",\"tiles\":\(layout.count)")
    let textMs = best { _ in for (i, r) in allTiles.enumerated() { if opLook(textTiles[i], r) { sinkByte += 1 } } }
    report("looksCompressible.text.per-frame", textMs, ",\"tiles\":\(layout.count)")

    let noiseSampled = best { _ in for (i, r) in allTiles.enumerated() { if opLookSampled(noiseTiles[i], r) { sinkByte += 1 } } }
    report("looksCompressible.noise.sampled-stride4", noiseSampled, ",\"tiles\":\(layout.count)")
    let textSampled = best { _ in for (i, r) in allTiles.enumerated() { if opLookSampled(textTiles[i], r) { sinkByte += 1 } } }
    report("looksCompressible.text.sampled-stride4", textSampled, ",\"tiles\":\(layout.count)")
    // Same verdict on every tile?
    var agree = 0
    for (i, r) in allTiles.enumerated() {
        if looksCompressible(noiseTiles[i], rect: r) == looksCompressibleSampled(noiseTiles[i], rect: r) { agree += 1 }
    }
    var agreeText = 0
    for (i, r) in allTiles.enumerated() {
        if looksCompressible(textTiles[i], rect: r) == looksCompressibleSampled(textTiles[i], rect: r) { agreeText += 1 }
    }
    print("// sampled==head verdict: noise \(agree)/\(layout.count), text \(agreeText)/\(layout.count)")
}

// MARK: - 8. base64 + assembly (Sources/krdcore/Render.swift:520)

func probeBase64() {
    let payload = zlibCompress(noiseFrame, level: 5) ?? []
    // HEAD: Data(payload).base64EncodedString() -> String, then Array(b64.utf8) -> [UInt8],
    // then `out.append(contentsOf: chars[i..<end])` in 4096-char chunks.
    let head = best(9) { _ in
        let b64 = Data(payload).base64EncodedString()
        let chars = Array(b64.utf8)
        sinkBytes += chars.count
    }
    report("base64.head.string-roundtrip", head, ",\"payload\":\(payload.count)")

    // Candidate: base64 into a Data (no String, no UTF8 view), which is what the escapes want.
    let dataOut = best(9) { _ in
        let d = Data(payload).base64EncodedData()
        sinkBytes += d.count
    }
    report("base64.base64EncodedData", dataOut, ",\"payload\":\(payload.count)")

    // Price the two copies on their own.
    let stringOnly = best(9) { _ in sinkBytes += Data(payload).base64EncodedString().utf8.count }
    report("base64.string-only", stringOnly, ",\"payload\":\(payload.count)")
    let charsOnly = best(9) { _ in let s = Data(payload).base64EncodedString(); sinkBytes += Array(s.utf8).count }
    report("base64.string+Array", charsOnly, ",\"payload\":\(payload.count)")
}

// MARK: - 9. the whole photo frame, parallel, HEAD vs the candidate internals

/// HEAD's `ScreenWriter.compress` for the one plan that matters here: 5-6-5 quantisation behind the
/// two-frame guard, level 1, i.e. exactly what `LevelPolicy` hands the `photo` case.
func compressHead(_ pixels: [UInt8], _ rect: TileRect) -> [UInt8]? {
    var px = pixels
    if !looksCompressible(px, rect: rect) {
        px = ScreenWriter.quantise565(px, bytesPerPixel: 3)
    }
    guard let out = zlibCompress(px, level: 1), out.count < px.count else { return nil }
    return out
}

/// The same decision with the three candidate internals (fused extract+quantise, sampled
/// heuristic, unrolled quantise) and nothing else changed.
func compressFast(_ pixels: [UInt8], _ rect: TileRect) -> [UInt8]? {
    if !looksCompressibleSampled(pixels, rect: rect) {
        let q = quantiseFast565(pixels)
        guard let out = zlibCompress(q, level: 1), out.count < q.count else { return nil }
        return out
    }
    guard let out = zlibCompress(pixels, level: 1), out.count < pixels.count else { return nil }
    return out
}

func probePipeline() {
    let rects = allTiles
    var headResult = [Int](repeating: 0, count: rects.count)
    var fastResult = [Int](repeating: 0, count: rects.count)

    // Serial first, so the two variants can be compared without the machine's core count in the
    // way, then the real shape: concurrentPerform over the dirty tiles.
    let headSerial = best(3) { _ in
        for (i, r) in rects.enumerated() {
            let px = opExtract(noiseFrame, r, layout)
            headResult[i] = compressHead(px, r)?.count ?? -1
        }
    }
    report("pipeline.photo.serial.head", headSerial, ",\"tiles\":\(rects.count)")

    let fastSerial = best(3) { _ in
        for (i, r) in rects.enumerated() {
            let px = opExtract(noiseFrame, r, layout)
            fastResult[i] = compressFast(px, r)?.count ?? -1
        }
    }
    report("pipeline.photo.serial.candidate", fastSerial, ",\"tiles\":\(rects.count)")
    print("// identical payload for every tile: \(headResult == fastResult) (\(headResult.reduce(0,+)) B)")

    var headPar = Double.infinity, fastPar = Double.infinity
    for _ in 0..<5 {
        let t0 = nowMs()
        headResult.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: rects.count) { i in
                let px = opExtract(noiseFrame, rects[i], layout)
                base[i] = compressHead(px, rects[i])?.count ?? -1
            }
        }
        let dt = nowMs() - t0
        if dt < headPar { headPar = dt }
    }
    report("pipeline.photo.parallel.head", headPar, ",\"tiles\":\(rects.count)")

    for _ in 0..<5 {
        let t0 = nowMs()
        fastResult.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: rects.count) { i in
                let px = opExtract(noiseFrame, rects[i], layout)
                base[i] = compressFast(px, rects[i])?.count ?? -1
            }
        }
        let dt = nowMs() - t0
        if dt < fastPar { fastPar = dt }
    }
    report("pipeline.photo.parallel.candidate", fastPar, ",\"tiles\":\(rects.count)")
    print(String(format: "// parallel gain: %.2f -> %.2f ms (%.1f%%)", headPar, fastPar,
                 100 * (fastPar - headPar) / headPar))
}

// MARK: - 10. the capture-side colour conversion (Sources/krd/Capture.swift:203)

func probeBGRA() {
    let w = layout.pixelW, h = layout.pixelH
    // What ScreenCaptureKit hands over: 32BGRA, row-padded to a multiple of 16 bytes.
    let srcRow = (w * 4 + 15) / 16 * 16
    var bgra = [UInt8](repeating: 0x7f, count: srcRow * h)
    for i in stride(from: 0, to: bgra.count, by: 4) { bgra[i + 3] = 255 }
    var dst = [UInt8](repeating: 0, count: w * h * 3)

    let ms = best(7) { _ in
        bgra.withUnsafeMutableBytes { s in
            dst.withUnsafeMutableBytes { d in
                var src = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h),
                                        width: vImagePixelCount(w), rowBytes: srcRow)
                var out = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h),
                                        width: vImagePixelCount(w), rowBytes: w * 3)
                sinkByte += Int(vImageConvert_BGRA8888toRGB888(&src, &out, vImage_Flags(kvImageNoFlags)))
            }
        }
    }
    report("capture.bgra->rgb.vImage", ms, ",\"px\":\(w * h)")
}

// MARK: - run

let which = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"
switch which {
case "dedupe": probeDedupe()
case "dirty": probeDirty()
case "extract": probeExtract()
case "zlib": probeZlib()
case "framing": probeFraming()
case "quantise": probeQuantise()
case "heuristic": probeHeuristic()
case "base64": probeBase64()
case "pipeline": probePipeline()
case "bgra": probeBGRA()
default:
    probeDedupe(); probeDirty(); probeExtract(); probeZlib()
    probeFraming(); probeQuantise(); probeHeuristic(); probeBase64()
    probePipeline(); probeBGRA()
}
print("// sink \(sinkByte) \(sinkBytes)")
