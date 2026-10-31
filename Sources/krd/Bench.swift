import Foundation
import krdcore

/// Benchmarks: the encoder (L1), the wire under a pty (L2) and replay of real frames (L4).
///
/// Design notes and the reasoning behind every number live in `docs/BENCHMARK.md`. The rules
/// this file obeys so its output stays comparable:
///
///  - one clock (`DispatchTime`, monotonic), never `Date`
///  - stages are timed separately: dedupe (the one scan that also yields the dirty tiles, #95),
///    dirty (a read of that scan's result), extract, heuristic, quantise, zlib (deflate alone
///    since #96), compress (the whole `ScreenWriter.compress` call, which is what this column
///    reported before the split), base64, assembly
///  - every result carries its configuration (pane, cell, tile, format, machine, cores)
///  - distributions, not best-of: p50/p95/p99 over `--rounds` frames
///  - warm-up rounds are discarded, so first-touch page faults and `LevelPolicy` learning
///    cannot win or lose a comparison
///  - the case list asserts its own dirty-tile counts: a case that claims "one character"
///    and emits 198 tiles is a bug in the harness, not a number to report

/// Monotonic milliseconds. `Date` is wall-clock and can jump backwards mid-run.

/// p50/p95/p99/max/mean over one stage of one case.
struct Percentiles {
    var n = 0
    var p50 = 0.0, p95 = 0.0, p99 = 0.0, max = 0.0, mean = 0.0

    init() {}
    init(_ values: [Double]) {
        guard !values.isEmpty else { return }
        let sorted = values.sorted()
        n = sorted.count
        func at(_ q: Double) -> Double {
            sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
        }
        p50 = at(0.50); p95 = at(0.95); p99 = at(0.99)
        max = sorted[sorted.count - 1]
        mean = sorted.reduce(0, +) / Double(sorted.count)
    }
}


#if DEBUG
let isDebugBuild = true
#else
let isDebugBuild = false
#endif

// MARK: - configuration

/// Everything a number needs to be interpretable a week later. `--bench --json` emits it.
struct BenchConfig {
    var pane: String
    var cell: String
    var tile: String
    var format: String
    var px: String
    var tiles: Int
    var rounds: Int
    var source: String
    /// Capture scale (`--scale`): the picture is `px` pixels at this fraction of the pane's pixels.
    var scale: String
    /// `--quality` and the rung it resolves to. Without it a table of wire bytes cannot be
    /// attributed: the same layout at 80 and at 50 differs by 1.3x, and nothing else in the JSON
    /// would say which one was measured.
    var quality: String
    var machine: String
    var arch: String
    var cores: Int
    var os: String
    var build: String

    static func current(layout: TileGrid, source: CGSize, rounds: Int, writer: ScreenWriter) -> BenchConfig {
        var uts = utsname()
        uname(&uts)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return BenchConfig(
            pane: "\(layout.paneCols)x\(layout.paneRows)",
            cell: "\(number(layout.cellW))x\(number(layout.cellH))",
            tile: "\(layout.tileCols)x\(layout.tileRows)",
            format: writer.format == .rgb ? "rgb" : "rgba",
            px: "\(layout.pixelW)x\(layout.pixelH)",
            tiles: layout.count,
            rounds: rounds,
            source: "\(Int(source.width))x\(Int(source.height))",
            scale: number(layout.scale),
            quality: "\(writer.quality.value) \(writer.quality.label)",
            machine: sysctlString("hw.model"),
            arch: unameField(&uts.machine),
            cores: ProcessInfo.processInfo.activeProcessorCount,
            os: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            build: isDebugBuild ? "debug" : "release"
        )
    }

    /// The config block on its own, without `cases`.
    var json: String {
        """
        {"schema":1,"krd":"\(krdVersion)","build":"\(build)",\
        "machine":{"model":"\(machine)","arch":"\(arch)","cores":\(cores),"os":"\(os)"},\
        "config":{"pane":"\(pane)","cell":"\(cell)","tile":"\(tile)","format":"\(format)",\
        "px":"\(px)","tiles":\(tiles),"rounds":\(rounds),"source":"\(source)",
        "scale":\(scale),"quality":"\(quality)"}}
        """
    }
}

private func number(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
}

private func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
    return String(cString: buffer)
}

private func unameField<T>(_ field: inout T) -> String {
    withUnsafeBytes(of: &field) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

// MARK: - content

enum BenchContent: String, CaseIterable {
    /// Flat page with glyph-like strokes: what an editor or a browser looks like to zlib.
    case text
    /// Hash noise: no LZ77 matches at all, the worst case for bandwidth.
    case noise
    /// Flat blocks with 1px borders: Finder, browser chrome, IDE panels.
    case ui
    /// Smooth ramp: video pans and wallpapers; compresses well but costs zlib time.
    case gradient
    /// A photograph, statistically: low-frequency structure plus a little grain. `noise` is the
    /// worst case for compression and a poor model of the thing people actually mirror (issue #65).
    case photoReal

    /// Triangle wave in 0...255: the low-frequency structure a photograph has and hash noise does
    /// not. Integer arithmetic on purpose -- `sin()` would make the bytes depend on the platform's
    /// libm, and this case's whole value is that it is reproducible.
    private static func wave(_ v: Int, period: Int, phase: Int) -> Int {
        let p = ((v + phase) % period + period) % period
        let half = max(period / 2, 1)
        return (p < half ? p : period - p) * 255 / max(half - 1, 1)
    }

    private static func clamp8(_ v: Int) -> UInt8 { UInt8(min(255, max(0, v))) }

    /// `seed` shifts the pattern, so a "full repaint" round can differ from the previous one
    /// in every pixel without having to be rebuilt from a different generator.
    func pixel(_ x: Int, _ y: Int, seed: Int) -> (UInt8, UInt8, UInt8) {
        switch self {
        case .text:
            let glyph = ((x + seed) % 23 < 3 || (y + seed) % 41 < 2) ? UInt8(20) : UInt8(245)
            return (glyph, glyph, (y + seed) % 97 < 2 ? 0 : glyph)
        case .noise:
            var h = UInt32(truncatingIfNeeded: x &* 73856093)
                ^ UInt32(truncatingIfNeeded: y &* 19349663)
                ^ UInt32(truncatingIfNeeded: (seed &* 2654435761) & 0x7fff_ffff)
            h ^= h >> 13; h = h &* 1274126177; h ^= h >> 16
            return (UInt8(truncatingIfNeeded: h),
                    UInt8(truncatingIfNeeded: h >> 8),
                    UInt8(truncatingIfNeeded: h >> 16))
        case .ui:
            let sx = (x + seed * 3) / 64, sy = (y + seed) / 48
            let block = (sx + sy) % 5
            let border = (x + seed * 3) % 64 < 2 || (y + seed) % 48 < 2
            let base = UInt8(210 + block * 8)
            return border ? (90, 100, 120) : (base, base, UInt8(min(255, Int(base) + 6)))
        case .photoReal:
            // Luminance from two low-frequency waves (a photograph's structure), a gentle colour
            // cast, and +-4 grain. Channels are *correlated* on purpose: that is what a real
            // photograph has and hash noise does not, and it is what makes this case compress
            // losslessly while `photo` cannot.
            let lum = (Self.wave(x &* 2 &+ y, period: 2329, phase: seed &* 13) * 2
                       + Self.wave(y &* 2 &+ x / 3, period: 1452, phase: seed &* 7)) / 3
            let tint = (Self.wave(x &+ y &* 2, period: 1747, phase: seed &* 29) - 128) / 6
            // Grain from an integer hash. Frozen constants, no RNG state, no clock: this is the
            // whole determinism story for this case (two runs must be byte-identical).
            var h = UInt32(truncatingIfNeeded: x &* 374_761_393)
                ^ UInt32(truncatingIfNeeded: y &* 668_265_263)
                ^ UInt32(truncatingIfNeeded: (seed &* 2_246_822_519) & 0x7fff_ffff)
            h ^= h >> 15; h = h &* 2_246_822_519; h ^= h >> 13
            let grain = Int(h % 21) - 10
            return (Self.clamp8(lum + tint + grain),
                    Self.clamp8(lum + grain),
                    Self.clamp8(lum - tint + grain))
        case .gradient:
            let v = UInt8(truncatingIfNeeded: ((x + seed * 40) % 2329) * 255 / 2329)
            let w = UInt8(truncatingIfNeeded: ((y + seed * 20) % 1452) * 255 / 1452)
            return (v, w, UInt8(truncatingIfNeeded: (Int(v) + Int(w)) / 2))
        }
    }
}

/// Give an array its own storage without changing a byte of it.
@inline(__always)
func benchDetach(_ pixels: inout [UInt8]) {
    guard !pixels.isEmpty else { return }
    pixels.withUnsafeMutableBufferPointer { $0[0] = $0[0] }
}

/// Build a whole frame. Deliberately literal: the benchmark must not be cleverer than the
/// code it measures.
func benchMakeFrame(_ grid: TileGrid, _ content: BenchContent, seed: Int = 0) -> [UInt8] {
    let w = grid.pixelW, h = grid.pixelH, bpp = grid.bpp
    var px = [UInt8](repeating: 0, count: w * h * bpp)
    px.withUnsafeMutableBufferPointer { buf in
        for y in 0..<h {
            for x in 0..<w {
                let c = content.pixel(x, y, seed: seed)
                let o = (y * w + x) * bpp
                buf[o] = c.0; buf[o + 1] = c.1; buf[o + 2] = c.2
                if bpp == 4 { buf[o + 3] = 255 }
            }
        }
    }
    return px
}

// MARK: - cases

/// One benchmark scenario: a base frame plus a per-round delta in a known dirty region.
struct BenchCase {
    enum Tiles { case exactly(Int), exactlyRow, exactlyAll, none, any }
    let name: String
    let content: BenchContent
    let tiles: Tiles
    let patch: (inout [UInt8], TileGrid, Int) -> Void
    /// One byte per tile the case claims to dirty, derived from (round, index).
    ///
    /// The hand-written deltas are not enough on their own. `line` shifts glyph strokes by
    /// one pixel, and the stroke period is 19 px: with `--cell 8x20` the last tile of that
    /// row is 8 px wide and contains no crossing, so it did not change at all and the case
    /// reported 17 tiles where it claimed 18. A benchmark that asserts its own premise needs
    /// the premise to be guaranteed, not to be a property of the current cell size.
    func stamp(_ px: inout [UInt8], _ grid: TileGrid, _ round: Int) {
        var targets: [Int] = []
        switch tiles {
        case .exactly(let n):
            let middle = (grid.tilesY / 2) * grid.tilesX + grid.tilesX / 2
            targets = n == 1 ? [middle] : []
        case .exactlyRow:
            targets = (0..<grid.tilesX).map { (grid.tilesY / 2) * grid.tilesX + $0 }
        case .exactlyAll:
            targets = Array(0..<grid.count)
        case .none, .any:
            targets = []
        }
        guard !targets.isEmpty else { return }
        px.withUnsafeMutableBufferPointer { buf in
            for index in targets {
                let r = grid.rect(index % grid.tilesX, index / grid.tilesX)
                let o = (r.y * grid.pixelW + r.x) * grid.bpp
                guard o < buf.count else { continue }
                buf[o] = UInt8(truncatingIfNeeded: round &* 31 &+ index &* 7 &+ 1)
            }
        }
    }
}

/// A moving block: the smallest useful delta, and one that is guaranteed to stay inside a
/// single tile (so the "one character" case really is one tile, not two).
private func benchBlock(_ px: inout [UInt8], _ grid: TileGrid, ty: Int, tx: Int, shift: Int) {
    let r = grid.rect(tx, ty)
    let w = grid.pixelW, bpp = grid.bpp
    let x0 = r.x + r.w / 3 + shift, y0 = r.y + r.h / 4
    let x1 = min(r.x + r.w - 1, x0 + 24), y1 = min(r.y + r.h - 1, y0 + 48)
    guard x1 > x0, y1 > y0 else { return }
    px.withUnsafeMutableBufferPointer { buf in
        for y in y0..<y1 {
            for x in x0..<x1 {
                let o = (y * w + x) * bpp
                buf[o] = 20; buf[o + 1] = 20; buf[o + 2] = 20
                if bpp == 4 { buf[o + 3] = 255 }
            }
        }
    }
}

/// Glyph-like strokes inside a band of rows, shifted horizontally per round: what scrolling
/// one text line actually changes.
private func benchLine(_ px: inout [UInt8], _ grid: TileGrid, y0: Int, y1: Int, shift: Int) {
    let w = grid.pixelW, bpp = grid.bpp
    px.withUnsafeMutableBufferPointer { buf in
        for y in max(0, y0)..<min(grid.pixelH, y1) {
            for x in 0..<w {
                let on = (x + shift) % 19 < 3 || (y - y0) % 11 < 2
                let c: UInt8 = on ? 30 : 240
                let o = (y * w + x) * bpp
                buf[o] = c; buf[o + 1] = c; buf[o + 2] = c
                if bpp == 4 { buf[o + 3] = 255 }
            }
        }
    }
}

func benchCases(_ grid: TileGrid) -> [BenchCase] {
    let midTy = grid.tilesY / 2
    let midRow = grid.rect(0, midTy)

    return [
        BenchCase(name: "char", content: .text, tiles: .exactly(1),
                  patch: { px, grid, k in benchBlock(&px, grid, ty: grid.tilesY / 2,
                                                    tx: grid.tilesX / 2, shift: k % 2) }),
        BenchCase(name: "line", content: .text, tiles: .exactlyRow,
                  patch: { px, grid, k in
                      benchLine(&px, grid, y0: midRow.y, y1: midRow.y + midRow.h, shift: k % 2)
                  }),
        BenchCase(name: "full", content: .text, tiles: .exactlyAll,
                  patch: { px, grid, k in
                      benchLine(&px, grid, y0: 0, y1: grid.pixelH, shift: k % 2)
                  }),
        BenchCase(name: "photo", content: .noise, tiles: .exactlyAll,
                  patch: { px, grid, k in px = benchMakeFrame(grid, .noise, seed: k + 1) }),
        BenchCase(name: "photoReal", content: .photoReal, tiles: .exactlyAll,
                  patch: { px, grid, k in px = benchMakeFrame(grid, .photoReal, seed: k + 1) }),
        BenchCase(name: "gradient", content: .gradient, tiles: .exactlyAll,
                  patch: { px, grid, k in px = benchMakeFrame(grid, .gradient, seed: k + 1) }),
        BenchCase(name: "ui", content: .ui, tiles: .exactlyAll,
                  patch: { px, grid, k in px = benchMakeFrame(grid, .ui, seed: k + 1) }),
        BenchCase(name: "drag", content: .noise, tiles: .any,
                  patch: { px, grid, k in
                      // A 600x400 window being dragged: the classic full-region refresh.
                      let w = grid.pixelW, h = grid.pixelH
                      let x = w / 2 - 300 + (k * 8) % max(1, w / 4)
                      let y = h / 2 - 200 + (k * 4) % max(1, h / 4)
                      for row in 0..<400 {
                          let yy = y + row
                          guard yy >= 0, yy < h else { continue }
                          let o = (yy * w + max(0, x)) * grid.bpp
                          let n = min(600, w - max(0, x))
                          guard n > 0 else { continue }
                          px.withUnsafeMutableBufferPointer { buf in
                              for i in 0..<n {
                                  let oo = o + i * grid.bpp
                                  buf[oo] = UInt8(truncatingIfNeeded: (row &* 31) ^ (i &* 17))
                                  buf[oo + 1] = UInt8(truncatingIfNeeded: (row &* 13) ^ (i &* 7))
                                  buf[oo + 2] = 200
                                  if grid.bpp == 4 { buf[oo + 3] = 255 }
                              }
                          }
                      }
                  }),
        BenchCase(name: "none", content: .text, tiles: .none, patch: { _, _, _ in }),
    ]
}

// MARK: - results

struct StageResult {
    var name: String
    var content: String
    var tiles: Int
    var payloadBytes: Int
    var wireBytes: Int
    var dedupe: Percentiles
    var dirty: Percentiles
    var extract: Percentiles
    /// The compressibility predictor (`looksCompressible`) alone: pixel work, not compression.
    var heuristic: Percentiles
    /// The quantise pass alone (`ScreenWriter.quantise`): pixel work, not compression.
    var quantise: Percentiles
    /// Deflate alone (`zlibCompress`) — this is what the column name promised all along.
    var zlib: Percentiles
    /// The whole `ScreenWriter.compress` call: exactly the number the old mislabelled `zlib`
    /// column reported, kept under an honest name so old runs stay comparable (#96).
    var compress: Percentiles
    var base64: Percentiles
    var assemble: Percentiles
    var total: Percentiles
    var serial: Percentiles
    var parallel: Percentiles
}

enum Bench {
    /// Warm-up rounds are not measured: the first pass through a 10 MB buffer pays page
    /// faults, and `LevelPolicy` needs one frame per tile before it settles.
    static let warmup = 3

    /// Time the real encoder on synthetic frames. No terminal, no screen, no permissions.
    static func runStages(layout: TileGrid, writer: ScreenWriter, rounds: Int, serial: Bool,
                          source: CGSize, json: Bool) -> Never {
        writer.discardOutput = true
        let config = BenchConfig.current(layout: layout, source: source, rounds: rounds, writer: writer)
        var results: [StageResult] = []

        for c in benchCases(layout) {
            // Every round starts from the same base frame, exactly like a fresh capture
            // buffer does. Applying deltas cumulatively was the first version's bug: a
            // block that moves by 1 px paints over its own previous position and the second
            // round is byte-identical, so the case measured "idle" instead of "moving".
            let base = benchMakeFrame(layout, c.content)
            var previous = base
            var payloads: [Double] = [], wires: [Double] = []
            var dedupeMs: [Double] = [], dirtyMs: [Double] = []
            var extractMs: [Double] = [], heuristicMs: [Double] = []
            var quantiseMs: [Double] = [], zlibMs: [Double] = [], compressMs: [Double] = []
            var base64Ms: [Double] = [], assembleMs: [Double] = []
            var totalMs: [Double] = [], serialMs: [Double] = [], parallelMs: [Double] = []
            var tiles = 0

            var lastDirty: [Int] = []
            var lastFrame: [UInt8] = []
            for round in 0..<(rounds + warmup) {
                var px = base
                // Force a copy: `Capturer` always compares two distinct 10 MB buffers, but
                // `Array ==` short-circuits on a shared buffer, which made the idle case
                // report a 0.00 ms dedupe instead of the real memcmp cost.
                benchDetach(&px)
                c.patch(&px, layout, round)
                c.stamp(&px, layout, round)

                // The one scan the pipeline runs on every delivered frame (#95): it answers *did
                // anything change* and *which tiles* in the same pass over the pixels. On a static
                // screen this is the entire cost of the frame, and it is what the `dedupe` column
                // measures; the `dirty` column is 0 by construction now (same pass, no second read).
                let dedupeStart = benchNowMs()
                let scan = TileGrid.diff(previous: previous, current: px, grid: layout)
                let dedupe = benchNowMs() - dedupeStart
                let totalStart = benchNowMs()

                let dirtyStart = benchNowMs()
                let dirty: [Int] = scan.dirty
                let dirtyElapsed = benchNowMs() - dirtyStart
                previous = px
                lastDirty = dirty
                lastFrame = px

                writer.resize(tiles: layout.count)
                writer.beginFrame()
                var parallelMsRound = 0.0
                var b64 = 0.0, assemble = 0.0

                if dirty.isEmpty {
                    // idle: a delivered frame with no changes still costs a nudge downstream
                    writer.nudge()
                    tiles = 0
                } else {
                    let rects = dirty.map { layout.rect($0 % layout.tilesX, $0 / layout.tilesX) }
                    let plans = dirty.map { writer.plan(for: $0) }

                    // What the live path does: compress the dirty tiles on all cores.
                    var packed = [CompressedTile?](repeating: nil, count: dirty.count)
                    let parallelStart = benchNowMs()
                    packed.withUnsafeMutableBufferPointer { buffer in
                        let base = buffer.baseAddress!
                        DispatchQueue.concurrentPerform(iterations: dirty.count) { i in
                            let pixels = layout.extract(px, rect: rects[i])
                            base[i] = ScreenWriter.compress(index: dirty[i], rect: rects[i],
                                                            pixels: pixels, plan: plans[i])
                        }
                    }
                    parallelMsRound = benchNowMs() - parallelStart

                    var timing = EmitTiming()
                    withUnsafeMutablePointer(to: &timing) { timingPtr in
                        for case let tile? in packed {
                            writer.emit(tile, sync: writer.perTileSync, timing: timingPtr)
                            writer.observe(index: tile.index, ratio: tile.ratio,
                                           quantisedIn: tile.isQuantised)
                        }
                    }
                    b64 = timing.base64Ms
                    assemble = timing.assembleMs
                    tiles = packed.compactMap { $0 }.count
                }
                writer.endFrame()
                let total = benchNowMs() - totalStart

                guard round >= warmup else { continue }
                payloads.append(Double(writer.lastFrameBytes))
                wires.append(Double(writer.lastWireBytes))
                dedupeMs.append(dedupe)
                dirtyMs.append(dirtyElapsed)
                base64Ms.append(b64)
                assembleMs.append(assemble)
                totalMs.append(total)
                parallelMs.append(parallelMsRound)
            }

            // The single-threaded reference runs once, outside the timed frames: putting it
            // inside them made `total` include two compressions and read ~2x too slow.
            // Its stage split is also the per-stage column, for the same reason a parallel
            // timer cannot add up per-tile costs without a lock.
            if serial, !lastDirty.isEmpty {
                let rects = lastDirty.map { layout.rect($0 % layout.tilesX, $0 / layout.tilesX) }
                let plans = lastDirty.map { writer.plan(for: $0) }
                var best = Double.infinity, bestExtract = 0.0, bestCompressed = 0.0
                var bestTiming = CompressTiming()
                for _ in 0..<3 {
                    var extract = 0.0, compressed = 0.0
                    var timing = CompressTiming()
                    let start = benchNowMs()
                    for i in 0..<lastDirty.count {
                        let t0 = benchNowMs()
                        let pixels = layout.extract(lastFrame, rect: rects[i])
                        let t1 = benchNowMs()
                        withUnsafeMutablePointer(to: &timing) { timingPtr in
                            _ = ScreenWriter.compress(index: lastDirty[i], rect: rects[i],
                                                      pixels: pixels, plan: plans[i], timing: timingPtr)
                        }
                        let t2 = benchNowMs()
                        extract += t1 - t0; compressed += t2 - t1
                    }
                    let elapsed = benchNowMs() - start
                    if elapsed < best {
                        best = elapsed; bestExtract = extract; bestCompressed = compressed
                        bestTiming = timing
                    }
                }
                serialMs = [best]
                extractMs = [bestExtract]
                heuristicMs = [bestTiming.heuristicMs]
                quantiseMs = [bestTiming.quantiseMs]
                zlibMs = [bestTiming.deflateMs]
                compressMs = [bestCompressed]
            }

            // The case definition is an assertion, not a comment: a "one character" case that
            // dirties 198 tiles means the harness broke, and every byte below would be a lie.
            let expected: Int? = {
                switch c.tiles {
                case .exactly(let n): return n
                case .exactlyRow: return layout.tilesX
                case .exactlyAll: return layout.count
                case .none: return 0
                case .any: return nil
                }
            }()
            if let expected, tiles != expected {
                FileHandle.standardError.write(Data(
                    "krd: bench case \"\(c.name)\" dirtied \(tiles) tiles, expected \(expected)\n".utf8))
                exit(2)
            }

            results.append(StageResult(
                name: c.name, content: c.content.rawValue, tiles: tiles,
                payloadBytes: Int(Percentiles(payloads).p50),
                wireBytes: Int(Percentiles(wires).p50),
                dedupe: Percentiles(dedupeMs), dirty: Percentiles(dirtyMs),
                extract: Percentiles(extractMs),
                heuristic: Percentiles(heuristicMs), quantise: Percentiles(quantiseMs),
                zlib: Percentiles(zlibMs), compress: Percentiles(compressMs),
                base64: Percentiles(base64Ms), assemble: Percentiles(assembleMs),
                total: Percentiles(totalMs),
                serial: Percentiles(serialMs), parallel: Percentiles(parallelMs)
            ))
        }

        if json {
            print(benchJSON(config: config, results: results))
            FileHandle.standardError.write(Data(benchTable(config: config, results: results).utf8))
        } else {
            print(benchTable(config: config, results: results))
        }
        fflush(stdout); fflush(stderr)
        exit(0)
    }

    /// Right-align inside `width`; left-align when `left`. Written by hand because `%s`
    /// needs a C string and `String(format:)` with a Swift `String` is a segfault waiting
    /// to happen (it passes an NSString, `%s` then runs strlen on the object header).
    static func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
        let fill = max(0, width - text.count)
        return left ? text + String(repeating: " ", count: fill)
                    : String(repeating: " ", count: fill) + text
    }

    static func num(_ value: Double, _ decimals: Int = 2) -> String {
        String(format: "%.\(decimals)f", value)
    }

    static func benchTable(config: BenchConfig, results: [StageResult]) -> String {
        var text = """
        krd: bench \(config.px) px, \(config.tiles) tiles of \(config.tile) cells, \(config.format) (f=\(config.format == "rgb" ? 24 : 32))
        krd:       pane \(config.pane) cells, cell \(config.cell) px, source \(config.source) pt, \(config.rounds) rounds after \(warmup) warm-up
        krd:       \(config.machine) \(config.arch), \(config.cores) cores, macOS \(config.os), \(config.build) build

        """
        func header(_ cells: [String], _ widths: [Int]) -> String {
            "  " + zip(cells, widths).map { pad($0, $1) }.joined(separator: " ") + "\n"
        }
        text += header(["case", "tiles", "payload", "wire", "dedupe", "dirty", "p50 ms", "p99 ms"],
                       [10, 5, 10, 10, 8, 8, 8, 8])
        for r in results {
            let cells = [pad(r.name, 10, left: true), pad("\(r.tiles)", 5),
                         pad("\(r.payloadBytes)", 10), pad("\(r.wireBytes)", 10),
                         pad(num(r.dedupe.p50), 8), pad(num(r.dirty.p50), 8),
                         pad(num(r.total.p50), 8), pad(num(r.total.p99), 8)]
            text += "  " + cells.joined(separator: " ") + "\n"
        }
        text += "\n" + header(["case", "extract", "heuristic", "quantise", "zlib", "compress",
                                "base64", "assemble", "serial", "parallel"],
                               [10, 9, 9, 9, 9, 9, 9, 9, 9, 9])
        for r in results {
            let cells = [pad(r.name, 10, left: true), pad(num(r.extract.p50), 9),
                         pad(num(r.heuristic.p50), 9), pad(num(r.quantise.p50), 9),
                         pad(num(r.zlib.p50), 9), pad(num(r.compress.p50), 9),
                         pad(num(r.base64.p50), 9), pad(num(r.assemble.p50), 9),
                         pad(num(r.serial.p50), 9), pad(num(r.parallel.p50), 9)]
            text += "  " + cells.joined(separator: " ") + "\n"
        }
        return text
    }

    static func benchJSON(config: BenchConfig, results: [StageResult]) -> String {
        func stage(_ name: String, _ p: Percentiles) -> String {
            String(format: "\"\(name)\":{\"n\":%d,\"p50\":%.3f,\"p95\":%.3f,\"p99\":%.3f,\"max\":%.3f,\"mean\":%.3f}",
                   p.n, p.p50, p.p95, p.p99, p.max, p.mean)
        }
        let cases = results.map { r -> String in
            """
              {"name":"\(r.name)","content":"\(r.content)","tiles":\(r.tiles),
               "bytes":{"payload":\(r.payloadBytes),"wire":\(r.wireBytes)},
               "ms":{\(stage("dedupe", r.dedupe)),\(stage("dirty", r.dirty)),\
              \(stage("extract", r.extract)),\(stage("heuristic", r.heuristic)),\
              \(stage("quantise", r.quantise)),\(stage("zlib", r.zlib)),\
              \(stage("compress", r.compress)),\(stage("base64", r.base64)),\
              \(stage("assemble", r.assemble)),\
              \(stage("serial", r.serial)),\(stage("parallel", r.parallel)),\
              \(stage("total", r.total))}}
            """
        }
        let head = config.json.hasSuffix("}") ? String(config.json.dropLast()) : config.json
        return head + ",\"cases\":[\n" + cases.joined(separator: ",\n") + "\n]}\n"
    }
}

// MARK: - L2: the wire

extension Bench {
    /// Feed frames to the real pipeline at a fixed rate and let the pty decide the rest.
    ///
    /// Every frame prints one JSON line on **stderr** (stdout carries the escapes, exactly as
    /// in production, so `bench/wire.py` can put a rate-limited drain behind a real file
    /// descriptor). The numbers here are krd's own view; the harness measures the other side.
    static func runWire(layout: TileGrid, writer: ScreenWriter, caseName: String, fps: Int,
                        seconds: Double, source: CGSize,
                        feed: ([UInt8], Int, Int) -> Void) -> Never {
        guard let c = benchCases(layout).first(where: { $0.name == caseName }) else {
            let names = benchCases(layout).map(\.name).joined(separator: ", ")
            FileHandle.standardError.write(Data("krd: unknown bench case \"\(caseName)\" (one of \(names))\n".utf8))
            exit(2)
        }
        let frames = max(1, Int((seconds * Double(fps)).rounded()))
        let interval = 1000.0 / Double(max(fps, 1))
        var previous = benchMakeFrame(layout, c.content)
        let started = benchNowMs()
        var late = 0, skipped = 0, bytes = 0

        for k in 0..<frames {
            let before = previous
            var px = before
            c.patch(&px, layout, k)
            c.stamp(&px, layout, k)
            let identical = before == px
            previous = px

            let t0 = benchNowMs()
            if identical {
                // what `Capturer` does before anything else: a static frame costs nothing
                skipped += 1
            } else {
                feed(px, layout.pixelW, layout.pixelH)
            }
            let elapsed = benchNowMs() - t0
            bytes += writer.lastWireBytes
            if elapsed > interval { late += 1 }

            let line = String(
                format: "{\"frame\":%d,\"start_ms\":%.2f,\"pipe_ms\":%.2f,\"compress_ms\":%.2f,"
                    + "\"write_ms\":%.2f,\"payload\":%d,\"wire_bytes\":%d,\"tiles\":%d,\"skipped\":%d}\n",
                k, t0 - started, elapsed, writer.lastCompressMs, writer.lastWriteMs,
                writer.lastFrameBytes, writer.lastWireBytes, writer.lastCompressedTiles,
                identical ? 1 : 0)
            FileHandle.standardError.write(Data(line.utf8))

            let remaining = interval - elapsed
            if remaining > 0 { usleep(useconds_t(remaining * 1000)) }
        }

        let secondsElapsed = (benchNowMs() - started) / 1000.0
        let summary = String(
            format: "{\"wire\":{\"case\":\"%@\",\"fps\":%d,\"frames\":%d,\"skipped\":%d,\"late\":%d,"
                + "\"wire_bytes\":%d,\"seconds\":%.3f,\"mbps\":%.2f}}\n",
            caseName, fps, frames, skipped, late, bytes, secondsElapsed,
            Double(bytes) / 1_048_576.0 / max(secondsElapsed, 0.001))
        FileHandle.standardError.write(Data(summary.utf8))
        fflush(stdout); fflush(stderr)
        exit(0)
    }
}

// MARK: - L3: stats as NDJSON

/// One line per second, same numbers as the `stats:` line, in a shape a script can diff.
final class StatsJSONWriter {
    private let handle: FileHandle?
    private let started = benchNowMs()

    init?(path: String?) {
        guard let path else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        self.handle = handle
    }

    /// One line per second, from the **same** `ChromeMetrics` the panel renders: the panel and this
    /// file disagreeing about what `tiles` or `pipe_ms` means was the bug this signature removes
    /// (issue #52).
    func write(_ m: ChromeMetrics, late: Int = 0, frames: Int = 0) {
        guard let handle else { return }
        // Typed on its own line: passing `m.capMs < 0 ? -1 : m.capMs` straight into a `%f` vararg
        // makes Swift pick `Int` for the literal branch and the value comes out as `nan`
        // (reproduced: `String(format: "%.2f", x < 0 ? -1 : x)` prints nan for any x < 0).
        let capMs: Double = m.capMs < 0 ? -1 : m.capMs
        // Same trap as `capMs` above: a `? x : -1` passed straight into `%f` compiles into an Int
        // and prints `nan`. Typed here, once.
        let rttMs: Double = m.rttAvailable ? m.rttMs : -1
        let rttP99: Double = m.rttAvailable ? m.rttP99Ms : -1
        // One field about the *picture's* rate rather than the pipe's (issue #110): `focused` says
        // whether the throttle in `fps` is `--unfocused-fps` holding the picture down or the rung the
        // governor chose. Typed, for the same reason as `capMs`.
        let focused: Int = m.focused ? 1 : 0
        // `nan` is not JSON. A series that has no samples yet (the first second of a session) must
        // still produce a line `jq` can read, so anything non-finite becomes -1 = "not measured".
        func n(_ value: Double) -> Double { value.isFinite ? value : -1 }
        let line = String(
            format: "{\"t\":%.2f,\"tiles\":%d,\"tiles_total\":%d,\"dirty\":%d,\"kb\":%d,"
                + "\"mbps\":%.3f,\"fps\":%.2f,\"capture_fps\":%.2f,\"tiles_per_s\":%.1f,"
                + "\"skipped_per_s\":%.1f,\"idle_per_s\":%.1f,"
                + "\"zlib_ms\":%.2f,\"zlib_p99_ms\":%.2f,\"write_ms\":%.2f,\"write_max_ms\":%.2f,"
                + "\"write_over5\":%d,\"cap_ms\":%.2f,\"cap_p99_ms\":%.2f,"
                + "\"pipe_ms\":%.2f,\"pipe_p99_ms\":%.2f,\"pipe_max_ms\":%.2f,\"e2e_ms\":%.2f,"
                + "\"input_ms\":%.2f,\"input_p99_ms\":%.2f,"
                + "\"rtt_ms\":%.2f,\"rtt_p99_ms\":%.2f,"
                + "\"px\":[%d,%d],\"cells\":[%d,%d],"
                + "\"delivered\":%d,\"skipped\":%d,\"callbacks\":%d,\"idle\":%d,\"bad\":%d,"
                + "\"late\":%d,\"frames\":%d,\"scale\":%.3f,\"quality\":%d,\"focused\":%d}\n",
            (benchNowMs() - started) / 1000.0, m.tilesPerSec, m.framesTotal, m.dirty, m.kbPerFrame,
            n(m.mbps), m.fps, m.captureFps, Double(m.tilesPerSec),
            n(m.skippedPerSec), n(m.idlePerSec),
            n(m.zlibMs), n(m.zlibP99Ms), n(m.writeMs), n(m.writeMaxMs), m.writeOver5,
            capMs, n(m.capP99Ms),
            n(m.pipeMs), n(m.pipeP99Ms), n(m.pipeMaxMs), n(m.e2eMs),
            n(m.inputMs), n(m.inputP99Ms),
            n(rttMs), n(rttP99),
            m.pxW, m.pxH, m.cellsW, m.cellsH,
            m.delivered, m.skipped, m.callbacks, m.idle, m.bad,
            late, frames, n(m.scale), m.quality, focused)
        handle.write(Data(line.utf8))
    }
}
