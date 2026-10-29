import Foundation
import CZlib

/// Turns pixel frames into kitty graphics escapes on the pty.
///
/// One rule learned the hard way: never let the screen hold "no image" between two frames,
/// and never depend on a delete. Each tile owns a fixed image id + placement id and simply
/// overwrites itself every frame (see `compress`), so no terminal state machine has to get
/// an eviction order right.
///
/// Compression is stateless (parallel, see `main.handleFrame`); everything below `emit` is
/// strictly serial because the escapes have to reach the pty in order.
final class ScreenWriter {
    /// q=2 silences every protocol reply; KRD_Q=0 reveals them while debugging.
    private let quiet = ProcessInfo.processInfo.environment["KRD_Q"] ?? "2"
    /// Pixel format on the wire: the desktop is opaque, so RGB (`f=24`) is ~17 % smaller than
    /// RGBA (`f=32`) and also compresses faster. `KRD_FORMAT=rgba` is the documented fallback
    /// for a terminal that does not implement `f=24`.
    var format: PixelFormat = {
        (ProcessInfo.processInfo.environment["KRD_FORMAT"] ?? "rgb").lowercased() == "rgba" ? .rgba : .rgb
    }()
    /// How the tiles of one frame are wrapped in DEC 2026 synchronized-update blocks.
    /// Reading the environment once here matters: it used to happen per tile, i.e. 54–770
    /// dictionary builds per frame, for a value that cannot change at runtime.
    private let syncMode: SyncMode = {
        let env = ProcessInfo.processInfo.environment
        if env["KRD_NOSYNC"] != nil { return .none }
        if (env["KRD_SYNC"] ?? "").lowercased() == "tile" { return .tile }
        return .frame
    }()
    private var batchOpen = false
    private var out = [UInt8]()

    private(set) var framesEmitted = 0
    private(set) var lastFrameBytes = 0
    /// Bytes that actually left the process for the last frame (escapes + base64 + headers).
    /// Accumulated across every flush of the frame, so the `?2026h`/`?2026l` wrapper and a
    /// nudge are counted too -- one flush in the middle of a frame is not the frame.
    private(set) var lastWireBytes = 0
    private var frameWireBytes = 0
    private(set) var totalBytes = 0
    private(set) var lastCompressMs = 0.0
    private(set) var lastWriteMs = 0.0

    // Write-path distribution. `lastWriteMs` is one sample; a stutter is a p99, and the
    // stats line used to average a number that spikes (docs/BENCHMARK.md, Q3).
    private(set) var writeSamples = 0
    private(set) var writeSumMs = 0.0
    private(set) var writeMaxMs = 0.0
    private(set) var writeOver5Ms = 0

    func resetWriteStats() {
        writeSamples = 0
        writeSumMs = 0
        writeMaxMs = 0
        writeOver5Ms = 0
    }

    private func recordWrite(_ ms: Double) {
        writeSamples += 1
        writeSumMs += ms
        if ms > writeMaxMs { writeMaxMs = ms }
        if ms > 5 { writeOver5Ms += 1 }
    }

    /// Per-tile zlib level, learned from the previous frame's compression ratio.
    private var levels = LevelPolicy(tiles: 0)
    private(set) var lastCompressedTiles = 0

    init() {
        out.reserveCapacity(1 << 21)
    }

    /// Called when the grid (and therefore the tile count) changes.
    func resize(tiles: Int) {
        if tiles != levels.count { levels = LevelPolicy(tiles: tiles) }
    }

    func level(for index: Int) -> Int { levels.level(for: index) }
    /// The tile loop compresses in parallel and reports the wall time once.
    func addCompressTime(_ ms: Double) { lastCompressMs += ms }
    func observe(index: Int, ratio: Double) { levels.observe(index: index, ratio: ratio) }

    // MARK: session

    /// Heal a pane whose parser was left mid-sequence by a killed predecessor:
    /// ST closes a dangling APC (which would otherwise swallow every later byte),
    /// and 2026l closes a dangling synchronized-update block (which would freeze drawing).
    private var healSequence: String {
        "\u{1B}\\\u{1B}[?2026l\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1006l\u{1B}[0m\u{1B}[?25h"
    }

    func beginSession() {
        // Alternate screen: keeps scrollback clean and makes the terminal hand us wheel
        // events instead of scrolling itself.
        // Mouse reporting is enabled later, by InputReader, once it knows stdin is readable.
        write(healSequence + "\u{1B}[?1049h\u{1B}[2J\u{1B}[H\u{1B}[?25l")
    }

    static func writeMouseReporting(_ on: Bool) {
        // 1003 = report every motion, not only while a button is held: a remote pointer has to
        // follow the mouse even when nobody is clicking. 1006 = SGR encoding, 1016 = SGR *pixels*.
        writeRaw(on ? "\u{1B}[?1003h\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?1016h"
                    : "\u{1B}[?1016l\u{1B}[?1006l\u{1B}[?1003l\u{1B}[?1002l")
    }

    /// Push the kitty keyboard enhancements krd can use, and ask which ones took.
    ///
    /// 15 = disambiguate (1) | report event types (2) | report alternate keys (4) | report all
    /// keys as escape codes (8). Every bit is load-bearing: without 1 the modified keys are still
    /// legacy bytes, without 2 there is no repeat or release, without 4 a non-US layout maps onto
    /// the wrong physical key, and without 8 text keys never become events at all. 16 ("associated
    /// text") stays off on purpose — IME is #16.
    ///
    /// A terminal that does not implement this ignores both sequences, which is the supported
    /// outcome: `InputReader` keeps the legacy encoding and nothing about the old parse changes.
    /// `endSession` pops the push so the shell behind us gets its own keyboard mode back.
    /// True once this process pushed the keyboard enhancements. `--selftest`, `--bench` and
    /// `--replay` call `endSession` without ever starting input, and a pop there would take a push
    /// that belongs to the shell (or the terminal's own UI).
    private static var keyboardPushed = false

    static func writeKeyboardProtocol(_ on: Bool) {
        if on {
            keyboardPushed = true
            writeRaw("\u{1B}[>15u\u{1B}[?u")
        } else if keyboardPushed {
            keyboardPushed = false
            writeRaw("\u{1B}[<u")
        }
    }

    /// Straight to the tty, bypassing the frame buffer: input-mode sequences must not land in the
    /// middle of a placement (and must work before the first frame exists).
    static func writeRaw(_ text: String) {
        Array(text.utf8).withUnsafeBufferPointer { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(STDOUT_FILENO, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    func endSession() {
        // Terminate any half-written APC *first*, then retire the screen. The keyboard push goes
        // with it: a pop after the alternate screen is gone is still our business, not the shell's.
        write("\u{1B}\\\u{1B}[?2026l")
        clear()
        write("\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1006l\u{1B}[?25h\u{1B}[?1049l")
        Self.writeKeyboardProtocol(false)
    }

    /// Frames between "drop every image and repaint everything" cycles.
    ///
    /// 0 disables it, which is the default: each tile overwrites its own fixed placement, so
    /// placements cannot pile up and there is nothing to reclaim. Set `KRD_REAP=<n>` only on a
    /// terminal that leaks placements (symptom: memory grows, tiles go stale after a while) --
    /// the cost is one full repaint, i.e. a visible blink, every n frames.
    var reapInterval = Int(ProcessInfo.processInfo.environment["KRD_REAP"] ?? "0") ?? 0
    private var sinceReap = 0

    /// Returns true when the caller must repaint everything.
    func reapIfNeeded() -> Bool {
        guard reapInterval > 0 else { return false }   // 0 disables it; must not mean "always"
        sinceReap += 1
        guard sinceReap >= reapInterval else { return false }
        sinceReap = 0
        append("\u{1B}_Ga=d,d=a\u{1B}\\")   // no flush: goes out with the repaint below
        return true
    }

    /// A terminal only repaints when something arrives; one harmless byte keeps a static
    /// frame committed (Herdr otherwise waits for the next output cycle to show a placement).
    func nudge() {
        write("\u{1B}[?25l")
    }

    func clear() {
        append("\u{1B}_Ga=d,d=a\u{1B}\\")   // drop every image this terminal holds
        append("\u{1B}[2J")
        flush()
    }

    // MARK: batching

    /// DEC 2026: the terminal commits everything until endBatch() in one repaint.
    /// Reset the per-frame counters and, in the default mode, open the single synchronized
    /// block that wraps every tile of this frame.
    func beginFrame() {
        lastFrameBytes = 0
        lastCompressMs = 0
        lastWriteMs = 0
        lastCompressedTiles = 0
        frameWireBytes = 0
        if syncMode == .frame && !batchOpen {
            append("\u{1B}[?2026h")
            batchOpen = true
        }
    }

    /// Close the frame's synchronized block and push the bytes out.
    func endFrame() {
        if batchOpen {
            append("\u{1B}[?2026l")
            batchOpen = false
        }
        let t0 = benchNowMs()
        flush()
        lastWriteMs = benchNowMs() - t0
        recordWrite(lastWriteMs)
        lastWireBytes = frameWireBytes
    }

    func beginBatch() {
        out.removeAll(keepingCapacity: true)
        frameWireBytes = 0
        append("\u{1B}[?2026h")
        batchOpen = true
        lastFrameBytes = 0
        lastCompressMs = 0
    }

    func endBatch() {
        append("\u{1B}[?2026l")
        batchOpen = false
        let t0 = benchNowMs()
        flush()
        lastWriteMs = benchNowMs() - t0
        recordWrite(lastWriteMs)
        lastWireBytes = frameWireBytes
    }

    // MARK: tiles

    // MARK: tiles

    /// Compress one tile. Pure: touches no writer state and allocates its own output, so the
    /// dirty tiles of a frame can be compressed concurrently.
    ///
    /// The image id and the placement id are fixed per tile and reused every frame. Deletes are
    /// not an option (Herdr and rex treat `a=d,i=<id>` as "drop the whole image set" -> black
    /// screen) and alternating ids are not an option either (two images then own the same cells
    /// and the stale one shows through), so a tile simply overwrites its own placement.
    static func compress(index: Int, rect: TileRect, pixels: [UInt8], level: Int) -> CompressedTile? {
        guard let payload = zlibCompress(pixels, level: level), !payload.isEmpty else { return nil }
        let ratio = pixels.isEmpty ? 0 : Double(payload.count) / Double(pixels.count)
        return CompressedTile(index: index, rect: rect, payload: payload, ratio: ratio)
    }

    /// Turn an already compressed tile into escapes. Single-threaded: the order of the tiles
    /// (and therefore the cursor moves) has to stay deterministic.
    func emit(_ tile: CompressedTile, sync: Bool, timing: UnsafeMutablePointer<EmitTiming>? = nil) {
        let r = tile.rect
        let iid = 100 + tile.index
        let pid = 1000 + tile.index

        lastCompressMs += 0                                     // timing is measured by the caller
        lastFrameBytes += tile.payload.count
        totalBytes += tile.payload.count
        framesEmitted += 1
        lastCompressedTiles += 1

        // Two `now` calls per tile, and only when a benchmark asked for the split: the live
        // path pays one nil check per tile, nothing else.
        var mark = 0.0
        if timing != nil { mark = benchNowMs() }
        let b64 = Data(tile.payload).base64EncodedString()
        let chars = Array(b64.utf8)
        if let timing {
            let now = benchNowMs()
            timing.pointee.base64Ms += now - mark
            mark = now
        }

        if sync { append("\u{1B}[?2026h") }
        append("\u{1B}[\(r.row);\(r.col)H")
        var i = 0
        var first = true
        let control = "Gf=\(format.protocolChannels),s=\(r.w),v=\(r.h),a=t,o=z,q=\(quiet),i=\(iid)"
        while i < chars.count {
            let end = min(i + 4096, chars.count)
            let more = end == chars.count ? 0 : 1
            append("\u{1B}_")
            append(first ? "\(control),m=\(more);" : "Gm=\(more);")
            out.append(contentsOf: chars[i..<end])
            append("\u{1B}\\")
            i = end
            first = false
        }
        append("\u{1B}_Gi=\(iid),p=\(pid),a=p,q=\(quiet),C=1,c=\(r.cols),r=\(r.rows)\u{1B}\\")
        if sync { append("\u{1B}[?2026l") }
        if let timing { timing.pointee.assembleMs += benchNowMs() - mark }
    }

    /// Should `emit` wrap this tile in its own synchronized block?
    var perTileSync: Bool { syncMode == .tile }

    /// Diagnostic: draw one block with an explicitly chosen protocol shape, so a human can
    /// tell which variant a terminal actually honours.
    /// 0 = a=T with id, 1 = a=T without id, 2 = a=t + a=p with id, 3 = a=T with id inside 2026
    func emitVariant(_ variant: Int, id: Int, row: Int, col: Int,
                     pixels: [UInt8], width: Int, height: Int, cols: Int, rows: Int) {
        guard let compressed = zlibCompress(pixels), !compressed.isEmpty else { return }
        let b64 = Array(Data(compressed).base64EncodedString().utf8)
        let sync = variant == 3
        if sync { append("\u{1B}[?2026h") }
        append("\u{1B}[\(row);\(col)H")
        var i = 0
        var first = true
        let transmitAction = variant == 2 ? "t" : "T"
        let idPart = variant == 1 ? "" : "i=\(id),"
        while i < b64.count {
            let end = min(i + 4096, b64.count)
            let more = end == b64.count ? 0 : 1
            append("\u{1B}_")
            if first {
                append("Gf=32,s=\(width),v=\(height),a=\(transmitAction),o=z,q=\(quiet),\(idPart)C=1,c=\(cols),r=\(rows),m=\(more);")
            } else {
                append("Gm=\(more);")
            }
            out.append(contentsOf: b64[i..<end])
            append("\u{1B}\\")
            i = end
            first = false
        }
        if variant == 2 {
            append("\u{1B}_Gi=\(id),a=p,q=\(quiet),C=1,c=\(cols),r=\(rows)\u{1B}\\")
        }
        if sync { append("\u{1B}[?2026l") }
        flush()
    }

    // MARK: full frame (fallback / comparison)

    func emitFullFrame(rgba: [UInt8], width: Int, height: Int, cols: Int, rows: Int) {
        // Same reasoning as emitTile: one fixed image id and placement id, overwritten in
        // place. Nothing is ever deleted, so no terminal can lose the picture to `a=d`.
        let newID = 2
        let placementID = 2

        let t0 = Date()
        guard let compressed = zlibCompress(rgba), !compressed.isEmpty else { return }
        lastCompressMs = Date().timeIntervalSince(t0) * 1000
        lastFrameBytes = compressed.count
        totalBytes += compressed.count
        framesEmitted += 1

        let b64 = Data(compressed).base64EncodedString()
        let chars = Array(b64.utf8)
        append("\u{1B}[1;1H")
        var i = 0
        var first = true
        while i < chars.count {
            let end = min(i + 4096, chars.count)
            let more = end == chars.count ? 0 : 1
            append("\u{1B}_")
            append(first
                   ? "Gf=\(format.protocolChannels),s=\(width),v=\(height),a=t,o=z,q=\(quiet),i=\(newID),m=\(more);"
                   : "Gm=\(more);")
            out.append(contentsOf: chars[i..<end])
            append("\u{1B}\\")
            i = end
            first = false
        }
        append("\u{1B}_Gi=\(newID),p=\(placementID),a=p,q=\(quiet),C=1,c=\(cols),r=\(rows)\u{1B}\\")
    }

    // MARK: plumbing

    func write(_ text: String) {
        append(text)
        flush()
    }

    private func append(_ text: String) {
        out.append(contentsOf: Array(text.utf8))
    }

    /// KRD_DUMP=/path captures every byte we send, for offline protocol diffing.
    private static let dumpHandle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["KRD_DUMP"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    /// Benchmarks exercise the whole encoder without a terminal to write to.
    var discardOutput = false

    private func flush() {
        guard !out.isEmpty else { return }
        frameWireBytes += out.count
        if discardOutput {
            out.removeAll(keepingCapacity: true)
            return
        }
        if let dump = ScreenWriter.dumpHandle {
            dump.write(Data(out))
        }
        out.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(STDOUT_FILENO, buf.baseAddress!.advanced(by: off), buf.count - off)
                if n <= 0 { return }
                off += n
            }
        }
        out.removeAll(keepingCapacity: true)
    }
}

/// RFC1950 zlib via system libz -- exactly what the protocol's `o=z` requires.
/// (Apple's COMPRESSION_ZLIB emits *raw* DEFLATE, which the terminal rejects.)
func zlibCompress(_ input: [UInt8], level: Int = 5) -> [UInt8]? {
    guard !input.isEmpty else { return nil }
    var capacity = compressBound(uLong(input.count))
    var out = [UInt8](repeating: 0, count: Int(capacity))
    let status = input.withUnsafeBufferPointer { src -> Int32 in
        out.withUnsafeMutableBufferPointer { dst -> Int32 in
            compress2(dst.baseAddress, &capacity, src.baseAddress, uLong(src.count), Int32(level))
        }
    }
    guard status == Z_OK else { return nil }
    out.removeSubrange(Int(capacity)...)
    return out
}
