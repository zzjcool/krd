import Foundation
import CZlib

/// Monotonic milliseconds. In the core because the writer measures itself (issue #21).
@inline(__always) public func benchNowMs() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
}

/// Per-tile stage timings, written by `ScreenWriter.emit` only when a bench asks for them.
/// Lives here because `emit` takes a pointer to it (issue #21).
public struct EmitTiming {
    public var base64Ms = 0.0
    public var assembleMs = 0.0
    public init() {}
}

/// Turns pixel frames into kitty graphics escapes on the pty.
///
/// One rule learned the hard way: never let the screen hold "no image" between two frames,
/// and never depend on a delete. Each tile owns a fixed image id + placement id and simply
/// overwrites itself every frame (see `compress`), so no terminal state machine has to get
/// an eviction order right.
///
/// Compression is stateless (parallel, see `main.handleFrame`); everything below `emit` is
/// strictly serial because the escapes have to reach the pty in order.
public final class ScreenWriter {
    /// q=2 silences every protocol reply; KRD_Q=0 reveals them while debugging.
    private let quiet = ProcessInfo.processInfo.environment["KRD_Q"] ?? "2"
    /// Pixel format on the wire: the desktop is opaque, so RGB (`f=24`) is ~17 % smaller than
    /// RGBA (`f=32`) and also compresses faster. `KRD_FORMAT=rgba` is the documented fallback
    /// for a terminal that does not implement `f=24`.
    public var format: PixelFormat = {
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
    /// A `clear()` that arrived while the frame's block was open (see `clear`): the delete may not
    /// be written yet, so `endFrame` sends it as a commit of its own.
    private var pendingClear = false
    /// The screen lost placements since the last commit, so the frame about to start has to repaint
    /// **every** tile: the dirty pass only re-sends the ones that changed, and after a delete-all
    /// the rest of the pane would stay blank. Armed by the deferred clear above, see `clear`.
    private var needsFullRepaint = false
    /// `a=d,d=a` + `ESC[2J`: the pair docs/PROTOCOL.md §4 licenses at a resize/clear (and at
    /// teardown, through `clear`). Written from two places -- `clear` itself and the deferred commit
    /// in `endFrame` -- so the pair is written down once.
    private static let clearBytes = Array("\u{1B}_Ga=d,d=a\u{1B}\\\u{1B}[2J".utf8)
    /// Chrome text arrives on the main queue while tiles are assembled on the capture queue.
    /// One lock around "append + flush" means a text write can never land inside a base64
    /// payload, and the picture never waits for a UI tick (it is one uncontended lock).
    private let writeLock = NSRecursiveLock()

    /// `--quality`: how far the encoder may drop below lossless (see `QualityBudget`). 100 keeps
    /// every pixel; 80 is the long-standing adaptive 5-6-5; 70 and below quantise eagerly.
    ///
    /// Rebuilds the policy, because the budget is captured when it is constructed: setting this
    /// after the first `resize` (as the bench and the replay path do) used to leave the old budget
    /// in place and silently ignore the flag.
    public var quality = QualityBudget.default {
        didSet {
            guard quality != oldValue else { return }
            levels = LevelPolicy(tiles: levels.count, quality: quality)
        }
    }

    public private(set) var framesEmitted = 0
    public private(set) var lastFrameBytes = 0
    /// Bytes that actually left the process for the last frame (escapes + base64 + headers).
    /// Accumulated across every flush of the frame, so the `?2026h`/`?2026l` wrapper and a
    /// nudge are counted too -- one flush in the middle of a frame is not the frame.
    public private(set) var lastWireBytes = 0
    private var frameWireBytes = 0
    public private(set) var totalBytes = 0
    public private(set) var lastCompressMs = 0.0
    public private(set) var lastWriteMs = 0.0

    // Write-path distribution. `lastWriteMs` is one sample; a stutter is a p99, and the
    // stats line used to average a number that spikes (docs/BENCHMARK.md, Q3).
    public private(set) var writeSamples = 0
    public private(set) var writeSumMs = 0.0
    public private(set) var writeMaxMs = 0.0
    public private(set) var writeOver5Ms = 0

    public func resetWriteStats() {
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
    public private(set) var lastCompressedTiles = 0

    public init() {
        out.reserveCapacity(1 << 21)
    }

    /// Called when the grid (and therefore the tile count) changes.
    public func resize(tiles: Int) {
        if tiles != levels.count { levels = LevelPolicy(tiles: tiles, quality: quality) }
    }

    public func level(for index: Int) -> Int { levels.level(for: index) }
    /// Level + quantise, the two decisions the tile loop needs per tile.
    public func plan(for index: Int) -> LevelPolicy.Plan { levels.plan(for: index) }
    /// What the last frame actually did: how many tiles it quantised and how many it sent raw.
    ///
    /// Counted from `observe` rather than read back out of `LevelPolicy` on the UI thread: the
    /// policy is mutated per tile on the capture queue, and walking its arrays from the chrome
    /// timer was a race (and, under an eager budget, a guess: it reported the grid size rather than
    /// what was encoded).
    public private(set) var lastFrameQuantised = 0
    public private(set) var lastFrameRaw = 0
    public var quantisedTiles: Int { lastFrameQuantised }
    public var skippedTiles: Int { lastFrameRaw }
    /// The tile loop compresses in parallel and reports the wall time once.
    public func addCompressTime(_ ms: Double) { lastCompressMs += ms }
    public func observe(index: Int, ratio: Double, quantisedIn: Bool = false) {
        if quantisedIn { lastFrameQuantised += 1 } else if ratio >= 1 { lastFrameRaw += 1 }
        levels.observe(index: index, ratio: ratio, quantisedIn: quantisedIn)
    }

    // MARK: session

    /// Heal a pane whose parser was left mid-sequence by a killed predecessor:
    /// ST closes a dangling APC (which would otherwise swallow every later byte),
    /// and 2026l closes a dangling synchronized-update block (which would freeze drawing).
    /// The four mouse resets are the §7 enable list reversed, so a killed predecessor's pixel
    /// mode is repaired here too.
    private var healSequence: String {
        "\u{1B}\\\u{1B}[?2026l" + Self.mouseReset + "\u{1B}[0m\u{1B}[?25h"
    }

    public func beginSession() {
        // Alternate screen: keeps scrollback clean and makes the terminal hand us wheel
        // events instead of scrolling itself.
        // Mouse reporting is enabled later, by InputReader, once it knows stdin is readable.
        write(healSequence + "\u{1B}[?1049h\u{1B}[2J\u{1B}[H\u{1B}[?25l")
    }

    /// Every DEC private **mouse** mode a session turns on, in the order it turns them on.
    ///
    /// One list, because three hand-written copies of it had already drifted: the enable path and
    /// `writeMouseReporting(false)` knew `?1016` (SGR *pixel* coordinates), while `beginSession`'s
    /// heal and `endSession` reset only three of the four -- so a `kill -9` (or any exit that skips
    /// `InputReader`'s own reset) handed the pane on still reporting in device pixels where the next
    /// program expects cells: every click lands somewhere else, silently (issue #134). The reset is
    /// this list reversed, so a mode added here is reset by all three by construction.
    ///
    /// 1003 = report every motion, not only while a button is held: a remote pointer has to follow
    /// the mouse even when nobody is clicking. 1002 = button events (press/drag/release). 1006 = SGR
    /// encoding, 1016 = SGR *pixels*.
    static let mouseModes = [1003, 1002, 1006, 1016]
    /// `?<mode>h` in order, and `?<mode>l` in reverse: the enable set and the reset set are
    /// complementary by construction, never by hand.
    static let mouseEnable = mouseModes.map { "\u{1B}[?\($0)h" }.joined()
    static let mouseReset = mouseModes.reversed().map { "\u{1B}[?\($0)l" }.joined()

    public static func writeMouseReporting(_ on: Bool) {
        writeRaw(on ? mouseEnable : mouseReset)
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

    /// One lock for everything that reaches the terminal. The frame path flushes a whole frame
    /// through several `write(2)` calls, so a concurrent OSC 52 (clipboard) or mouse-mode sequence
    /// (input) could otherwise land between two tiles of the same image.
    public static let outLock = NSLock()

    public static func writeKeyboardProtocol(_ on: Bool) {
        if on {
            keyboardPushed = true
            writeRaw("\u{1B}[>15u\u{1B}[?u")
        } else if keyboardPushed {
            keyboardPushed = false
            writeRaw("\u{1B}[<u")
        }
    }

    /// Straight to the tty, bypassing the frame buffer: input-mode sequences, OSC 52 and the like
    /// must not land in the middle of a placement (and must work before the first frame exists).
    public static func writeRaw(_ text: String) {
        // Same lock as the frame path: an OSC 52 or a mouse-mode change landing in the middle of a
        // tile image would be decoded as image data and corrupt that tile.
        outLock.lock()
        defer { outLock.unlock() }
        Array(text.utf8).withUnsafeBufferPointer { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(STDOUT_FILENO, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    public func endSession() {
        // Terminate any half-written APC *first*, then retire the screen. The keyboard push goes
        // with it: a pop after the alternate screen is gone is still our business, not the shell's.
        write("\u{1B}\\\u{1B}[?2026l")
        // Those bytes went out *after* whatever a frame had buffered, so the block is closed on the
        // wire even if one was in flight. It must not still look open here: `clear` would defer the
        // teardown delete to an `endFrame` that is never coming, and the pane would keep the
        // pictures it has to lose.
        writeLock.lock()
        batchOpen = false
        writeLock.unlock()
        clear()
        write(Self.mouseReset + "\u{1B}[?25h\u{1B}[?1049l")
        Self.writeKeyboardProtocol(false)
    }

    /// Frames between "drop every image and repaint everything" cycles.
    ///
    /// 0 disables it, which is the default: each tile overwrites its own fixed placement, so
    /// placements cannot pile up and there is nothing to reclaim. Set `KRD_REAP=<n>` only on a
    /// terminal that leaks placements (symptom: memory grows, tiles go stale after a while) --
    /// the cost is one full repaint, i.e. a visible blink, every n frames.
    public var reapInterval = Int(ProcessInfo.processInfo.environment["KRD_REAP"] ?? "0") ?? 0
    private var sinceReap = 0

    /// True when the screen lost placements since the last commit, so the frame about to start has
    /// to repaint all of them (see `clear`). False on every normal frame.
    public var repaintNeeded: Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        return needsFullRepaint
    }

    /// Returns true when the caller must repaint everything.
    public func reapIfNeeded() -> Bool {
        guard reapInterval > 0 else { return false }   // 0 disables it; must not mean "always"
        sinceReap += 1
        guard sinceReap >= reapInterval else { return false }
        writeLock.lock()
        defer { writeLock.unlock() }
        // The same rule as in `clear`: while the block is open, `out` is that frame's batch buffer,
        // so the delete would be committed *with* the frame instead of before it (§4). The one
        // caller runs before `beginFrame`, but that is the caller's promise; this makes it the
        // writer's, so no future caller can reach the delete mid-frame.
        guard !batchOpen else { return false }
        sinceReap = 0
        append("\u{1B}_Ga=d,d=a\u{1B}\\")   // no flush: goes out with the repaint below
        return true
    }

    /// A terminal only repaints when something arrives; one harmless byte keeps a static
    /// frame committed (Herdr otherwise waits for the next output cycle to show a placement).
    public func nudge() {
        write("\u{1B}[?25l")
    }

    /// Drop every placement and erase the grid (docs/PROTOCOL.md §4).
    ///
    /// `out` doubles as the frame's batch buffer, so this may not append while the frame's block is
    /// open: the delete used to land **inside** it (issue #132), in the same commit as the tiles
    /// already emitted -- they were applied and deleted at once, `2J` erased the grid, and the next
    /// frame re-sends only *dirty* tiles, so the pane kept a hole. A clear that arrives mid-frame is
    /// therefore queued, and `endFrame` sends it right after the frame's commit, as a commit of its
    /// own. Either way the screen has lost placements, so the next frame has to repaint everything
    /// (`repaintNeeded`) rather than trust the caller to do it.
    ///
    /// Only the default block-per-frame mode is covered here: with `KRD_SYNC=tile` there is no
    /// frame-level block to stay out of, and the per-tile ones are the emit path's own business
    /// (issue #107 owns the unlocked appends up there).
    public func clear() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !batchOpen else {
            // Deferred, not dropped: every caller clears once per event (`handleResize`,
            // `reconcileCaptureTarget`, `endSession`) and relies on it, so "somebody else will
            // clear again" is not true of any of them -- and `clear()` returns nothing, so unlike
            // `writeControl` it cannot report back that its write was skipped.
            pendingClear = true
            return
        }
        pendingClear = false               // this delete supersedes one that was queued
        // Not only the deferred path: this delete wiped the pane, and the caller's own repaint can
        // be one frame too early for it (its `previousFrame` reset can land before the next dirty
        // pass). Asking unconditionally is what makes the hole impossible, not the caller's care.
        needsFullRepaint = true
        out.append(contentsOf: Self.clearBytes)
        flushLocked()
    }

    // MARK: batching

    /// DEC 2026: the terminal commits everything until endBatch() in one repaint.
    /// Reset the per-frame counters and, in the default mode, open the single synchronized
    /// block that wraps every tile of this frame.
    public func beginFrame() {
        lastFrameBytes = 0
        lastCompressMs = 0
        lastWriteMs = 0
        lastCompressedTiles = 0
        lastFrameQuantised = 0
        lastFrameRaw = 0
        frameWireBytes = 0
        writeLock.lock()
        defer { writeLock.unlock() }
        // The frame that begins here is the one that answers an armed repaint request (`clear`).
        // Disarming on the *write* side, not when `handleFrame` reads it, keeps the flag from
        // outliving the frame it belongs to.
        needsFullRepaint = false
        if syncMode == .frame && !batchOpen {
            append("\u{1B}[?2026h")
            batchOpen = true
        }
    }

    /// Close the frame's synchronized block and push the bytes out.
    public func endFrame() {
        writeLock.lock()
        defer { writeLock.unlock() }
        if batchOpen {
            append("\u{1B}[?2026l")
            batchOpen = false
        }
        let t0 = benchNowMs()
        flushLocked()
        lastWriteMs = benchNowMs() - t0
        // A clear that landed mid-frame goes out here, as a commit of its own: the block above is
        // closed and its bytes are out, so the delete sits inside nothing (see `clear`). The frame
        // it interrupted was built from the *old* grid, and the pane now holds no placements at
        // all, so the next one has to repaint everything rather than only the dirty tiles.
        if pendingClear {
            pendingClear = false
            needsFullRepaint = true
            out.append(contentsOf: Self.clearBytes)
            flushLocked()
        }
        recordWrite(lastWriteMs)
        lastWireBytes = frameWireBytes
    }

    public func beginBatch() {
        out.removeAll(keepingCapacity: true)
        frameWireBytes = 0
        append("\u{1B}[?2026h")
        batchOpen = true
        lastFrameBytes = 0
        lastCompressMs = 0
    }

    public func endBatch() {
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
    /// `level <= 0` means "zlib did not pay for this tile last frame" (issue #53). The pixels are
    /// then sent raw — unless they have changed into something zlib *can* win on, which is decided
    /// by a predictor that costs ~10 µs against the ~800 µs zlib would spend on the tile. Learning
    /// this by compressing and hoping (a probe) would send up to a frame of uncompressed text after
    /// every photo, which is megabytes on the wire.
    public static func compress(index: Int, rect: TileRect, pixels: [UInt8], level: Int,
                               quantise: Bool = false) -> CompressedTile? {
        // The old signature is the 5-6-5 shape of this decision, kept for callers (and tests) that
        // predate `--quality`; it goes through the same code as a `Plan` does.
        compress(index: index, rect: rect, pixels: pixels,
                 plan: LevelPolicy.Plan(level: level, quantise: quantise,
                                        bits: quantise ? QualityBudget.fiveSixFive : nil))
    }

    public static func compress(index: Int, rect: TileRect, pixels: [UInt8],
                                plan: LevelPolicy.Plan) -> CompressedTile? {
        guard !pixels.isEmpty else { return nil }
        var pixels = pixels
        var quantised = false
        // Two ways to deal with content zlib cannot help with: the content became compressible
        // again (lossless, issue #53), or it stays incompressible long enough to quantise (#59).
        // The predictor is what tells them apart, and it costs ~10 µs.
        if plan.quantise, let bits = plan.bits,
           plan.eager || !looksCompressible(pixels, rect: rect) {
            pixels = quantise(pixels, bits: bits,
                              bytesPerPixel: max(3, pixels.count / max(1, rect.w * rect.h)))
            quantised = true
        } else if plan.level <= 0 && !looksCompressible(pixels, rect: rect) {
            return CompressedTile(index: index, rect: rect, payload: pixels, ratio: 1, isCompressed: false)
        }
        // else: content is compressible after all -> fall through and compress losslessly
        let level = plan.level > 0 ? plan.level : 1
        // Deflate, not huffman-only, once the low bits are gone. Quantised bytes are *more*
        // repetitive than the original (that is the point of dropping them), so LZ77 finds long
        // matches immediately: measured on a 136x132 photo tile, full deflate is both smaller
        // (5-6-5: 31,270 B against 37,905 B, -17.5%) and faster (0.70 ms against 1.1 ms) than
        // huffman-only. Huffman-only also broke the ladder's ordering: with every symbol coded
        // independently, 6-6-6 could come out cheaper than 5-6-5.
        guard let payload = zlibCompress(pixels, level: level, huffmanOnly: false),
              !payload.isEmpty else { return nil }
        let ratio = Double(payload.count) / Double(pixels.count)
        if payload.count >= pixels.count {
            return CompressedTile(index: index, rect: rect, payload: pixels, ratio: 1,
                                  isCompressed: false, isQuantised: quantised)
        }
        return CompressedTile(index: index, rect: rect, payload: payload, ratio: ratio,
                              isQuantised: quantised)
    }

    /// Would zlib find anything here? One pass, comparing every byte with the same channel of the
    /// pixel above (or to its left, on the first row): zlib cannot win on content that changes every
    /// pixel (hash noise, a video frame), and wins hugely on content where neighbouring pixels are
    /// close — flat UI, text, and gradients, where the delta is 1 per pixel and the ratio is still
    /// 45×. Measured fractions: hash noise ~3 %, text ~90 %, gradient 100 %.
    static func looksCompressible(_ pixels: [UInt8], rect: TileRect) -> Bool {
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

    /// 5-6-5 colour with bit replication, still 3 bytes per pixel (issue #59).
    ///
    /// The terminal is told nothing new: it receives an ordinary `f=24` image. What changes is that
    /// the low 3/2/3 bits are gone, so zlib finally has repeats to point at — hash noise compresses
    /// 1.29x and a photo 2.3x, where lossless zlib managed 1.00x. Cost: ~37 dB PSNR, visible as
    /// banding on smooth ramps (docs/ENCODING.md).
    public static func quantise565(_ pixels: [UInt8], bytesPerPixel bpp: Int = 3) -> [UInt8] {
        quantise(pixels, bits: QualityBudget.fiveSixFive, bytesPerPixel: bpp)
    }

    /// Drop the low bits of every channel and replicate the high ones into the space they left, so a
    /// white pixel stays white instead of drifting dark (`--quality 70` is 5-5-5, `50` is 4-4-4).
    public static func quantise(_ pixels: [UInt8], bits: QualityBudget.Bits,
                               bytesPerPixel bpp: Int = 3) -> [UInt8] {
        guard bpp >= 3 else { return pixels }
        // Validate *before* any arithmetic: `8 - bits` is a UInt8 subtraction, so a bit count above 8
        // traps before a guard could reject it (and a count below 4 would need a negative right shift
        // to fill the low bits). 4...7 is the range the replication is defined for; the ladder never
        // leaves it, but `Bits` is public.
        let channels = [bits.r, bits.g, bits.b]
        guard channels.allSatisfy({ (4...7).contains($0) }) else { return pixels }
        let specs: [(shift: UInt8, low: UInt8)] = channels.map { (8 - $0, $0) }
        var out = pixels
        var i = 0
        while i + 2 < out.count {
            for (c, spec) in specs.enumerated() {
                let high = out[i + c] >> spec.shift
                out[i + c] = (high << spec.shift) | (high >> (spec.low - spec.shift))
            }
            i += bpp
        }
        return out
    }

    /// Turn an already compressed tile into escapes. Single-threaded: the order of the tiles
    /// (and therefore the cursor moves) has to stay deterministic.
    public func emit(_ tile: CompressedTile, sync: Bool, timing: UnsafeMutablePointer<EmitTiming>? = nil) {
        let r = tile.rect
        let iid = 100 + tile.index
        let pid = 1000 + tile.index

        lastCompressMs += 0                                     // timing is measured by the caller
        lastFrameBytes += tile.payload.count
        totalBytes += tile.payload.count
        framesEmitted += 1
        lastCompressedTiles += 1

        emitImage(id: iid, placementID: pid, row: r.row, col: r.col, cols: r.cols, rows: r.rows,
                  width: r.w, height: r.h, channels: format.protocolChannels,
                  compressed: tile.isCompressed, payload: tile.payload, sync: sync, timing: timing)
    }

    /// One picture at one rect: the wall's panel.
    ///
    /// Same wire shape as a tile (`a=t` in 4096-char chunks, then `a=p` at the cursor), but the
    /// ids, the cell rect, the pixel size and the channel count all come from the caller - the wall
    /// places several pictures at arbitrary rects, which `TileGrid.rect` cannot express (its origin
    /// is 1,1 and its id is the tile index).
    ///
    /// `format` is per call rather than per writer because the wall's pictures carry alpha (their
    /// bars are transparent, design §6.6) while the mirror's tiles are opaque RGB, and the two run
    /// in the same process. Returns the payload size, which is what went over the wire.
    @discardableResult
    public func emitPanel(id: Int, placementID: Int, row: Int, col: Int, cols: Int, rows: Int,
                          pixels: [UInt8], width: Int, height: Int, level: Int,
                          format panelFormat: PixelFormat = .rgb, sync: Bool = true) -> Int {
        guard width > 0, height > 0, cols > 0, rows > 0,
              let payload = zlibCompress(pixels, level: level), !payload.isEmpty else { return 0 }
        lastFrameBytes += payload.count
        totalBytes += payload.count
        framesEmitted += 1
        lastCompressedTiles += 1
        emitImage(id: id, placementID: placementID, row: row, col: col, cols: cols, rows: rows,
                  width: width, height: height, channels: panelFormat.protocolChannels,
                  compressed: true, payload: payload, sync: sync, timing: nil)
        return payload.count
    }

    /// The diacritics that encode a row/column number for unicode placeholders: index 0 is U+0305,
    /// index 1 is U+030D, and so on (kitty's `rowcolumn-diacritics.txt`). Only the first 256 are
    /// kept - a pane never has more rows.
    static let placeholderDiacritics: [Character] = ["\u{0305}", "\u{030D}", "\u{030E}", "\u{0310}", "\u{0312}", "\u{033D}", "\u{033E}", "\u{033F}", "\u{0346}", "\u{034A}", "\u{034B}", "\u{034C}", "\u{0350}", "\u{0351}", "\u{0352}", "\u{0357}", "\u{035B}", "\u{0363}", "\u{0364}", "\u{0365}", "\u{0366}", "\u{0367}", "\u{0368}", "\u{0369}", "\u{036A}", "\u{036B}", "\u{036C}", "\u{036D}", "\u{036E}", "\u{036F}", "\u{0483}", "\u{0484}", "\u{0485}", "\u{0486}", "\u{0487}", "\u{0592}", "\u{0593}", "\u{0594}", "\u{0595}", "\u{0597}", "\u{0598}", "\u{0599}", "\u{059C}", "\u{059D}", "\u{059E}", "\u{059F}", "\u{05A0}", "\u{05A1}", "\u{05A8}", "\u{05A9}", "\u{05AB}", "\u{05AC}", "\u{05AF}", "\u{05C4}", "\u{0610}", "\u{0611}", "\u{0612}", "\u{0613}", "\u{0614}", "\u{0615}", "\u{0616}", "\u{0617}", "\u{0657}", "\u{0658}", "\u{0659}", "\u{065A}", "\u{065B}", "\u{065D}", "\u{065E}", "\u{06D6}", "\u{06D7}", "\u{06D8}", "\u{06D9}", "\u{06DA}", "\u{06DB}", "\u{06DC}", "\u{06DF}", "\u{06E0}", "\u{06E1}", "\u{06E2}", "\u{06E4}", "\u{06E7}", "\u{06E8}", "\u{06EB}", "\u{06EC}", "\u{0730}", "\u{0732}", "\u{0733}", "\u{0735}", "\u{0736}", "\u{073A}", "\u{073D}", "\u{073F}", "\u{0740}", "\u{0741}", "\u{0743}", "\u{0745}", "\u{0747}", "\u{0749}", "\u{074A}", "\u{07EB}", "\u{07EC}", "\u{07ED}", "\u{07EE}", "\u{07EF}", "\u{07F0}", "\u{07F1}", "\u{07F3}", "\u{0816}", "\u{0817}", "\u{0818}", "\u{0819}", "\u{081B}", "\u{081C}", "\u{081D}", "\u{081E}", "\u{081F}", "\u{0820}", "\u{0821}", "\u{0822}", "\u{0823}", "\u{0825}", "\u{0826}", "\u{0827}", "\u{0829}", "\u{082A}", "\u{082B}", "\u{082C}", "\u{082D}", "\u{0951}", "\u{0953}", "\u{0954}", "\u{0F82}", "\u{0F83}", "\u{0F86}", "\u{0F87}", "\u{135D}", "\u{135E}", "\u{135F}", "\u{17DD}", "\u{193A}", "\u{1A17}", "\u{1A75}", "\u{1A76}", "\u{1A77}", "\u{1A78}", "\u{1A79}", "\u{1A7A}", "\u{1A7B}", "\u{1A7C}", "\u{1B6B}", "\u{1B6D}", "\u{1B6E}", "\u{1B6F}", "\u{1B70}", "\u{1B71}", "\u{1B72}", "\u{1B73}", "\u{1CD0}", "\u{1CD1}", "\u{1CD2}", "\u{1CDA}", "\u{1CDB}", "\u{1CE0}", "\u{1DC0}", "\u{1DC1}", "\u{1DC3}", "\u{1DC4}", "\u{1DC5}", "\u{1DC6}", "\u{1DC7}", "\u{1DC8}", "\u{1DC9}", "\u{1DCB}", "\u{1DCC}", "\u{1DD1}", "\u{1DD2}", "\u{1DD3}", "\u{1DD4}", "\u{1DD5}", "\u{1DD6}", "\u{1DD7}", "\u{1DD8}", "\u{1DD9}", "\u{1DDA}", "\u{1DDB}", "\u{1DDC}", "\u{1DDD}", "\u{1DDE}", "\u{1DDF}", "\u{1DE0}", "\u{1DE1}", "\u{1DE2}", "\u{1DE3}", "\u{1DE4}", "\u{1DE5}", "\u{1DE6}", "\u{1DFE}", "\u{20D0}", "\u{20D1}", "\u{20D4}", "\u{20D5}", "\u{20D6}", "\u{20D7}", "\u{20DB}", "\u{20DC}", "\u{20E1}", "\u{20E7}", "\u{20E9}", "\u{20F0}", "\u{2CEF}", "\u{2CF0}", "\u{2CF1}", "\u{2DE0}", "\u{2DE1}", "\u{2DE2}", "\u{2DE3}", "\u{2DE4}", "\u{2DE5}", "\u{2DE6}", "\u{2DE7}", "\u{2DE8}", "\u{2DE9}", "\u{2DEA}", "\u{2DEB}", "\u{2DEC}", "\u{2DED}", "\u{2DEE}", "\u{2DEF}", "\u{2DF0}", "\u{2DF1}", "\u{2DF2}", "\u{2DF3}", "\u{2DF4}", "\u{2DF5}", "\u{2DF6}", "\u{2DF7}", "\u{2DF8}", "\u{2DF9}", "\u{2DFA}", "\u{2DFB}", "\u{2DFC}", "\u{2DFD}", "\u{2DFE}", "\u{2DFF}", "\u{A66F}", "\u{A67C}", "\u{A67D}", "\u{A6F0}", "\u{A6F1}", "\u{A8E0}", "\u{A8E1}", "\u{A8E2}", "\u{A8E3}", "\u{A8E4}", "\u{A8E5}"]

    /// One picture, drawn as **unicode placeholders** instead of a pixel-sized placement.
    ///
    /// Why this shape: a placeholder placement (`U=1`) hands the *sizing* to the terminal. The image
    /// is fitted into the rectangle of placeholder cells, aspect preserved ("The image will
    /// eventually be fit to the specified rectangle, its aspect ratio preserved", kitty protocol
    /// §Unicode placeholders), so the picture's cell rectangle - which krd knows exactly, because it
    /// is the layout - is the only geometry that matters. No cell-pixel estimate, no `--dpr`, no
    /// "the picture is half its box because the terminal reports points": the class of bug that put
    /// the wall's desktop at the box's top-left four times in one evening.
    ///
    /// The cost is transmission efficiency: the placeholder grid is ordinary text (invisible), so it
    /// has to be rewritten whenever those cells are repainted, and the terminal does the resampling.
    @discardableResult
    public func emitPanelAsPlaceholder(id: Int, placementID: Int, row: Int, col: Int,
                                       cols: Int, rows: Int, pixels: [UInt8], width: Int,
                                       height: Int, level: Int, paneCols: Int, paneRows: Int,
                                       format panelFormat: PixelFormat = .rgba,
                                       sync: Bool = true) -> Int {
        guard width > 0, height > 0, cols > 0, rows > 0,
              let payload = zlibCompress(pixels, level: level), !payload.isEmpty else { return 0 }
        lastFrameBytes += payload.count
        totalBytes += payload.count
        framesEmitted += 1
        lastCompressedTiles += 1

        if sync { append("\u{1B}[?2026h") }
        // 1. Transmit only - a placeholder image must not carry a placement of its own.
        appendTransmit(id: id, payload: payload, width: width, height: height,
                       compressed: true, channels: panelFormat.protocolChannels)
        // 2. The virtual placement: the cell rectangle the picture should fill.
        append("\u{1B}_Gi=\(id),p=\(placementID),a=p,U=1,q=\(quiet),c=\(cols),r=\(rows)\u{1B}\\")
        // 3. The placeholder cells, clipped so this never writes the final cell of the final row (a
        //    pending wrap there scrolls the grid and takes every placement on it one row up).
        let r = (id >> 16) & 0xFF, g = (id >> 8) & 0xFF, b = id & 0xFF
        let colour = "\u{1B}[38;2;\(r);\(g);\(b)m"
        for line in 0..<rows {
            let paneRow = row + line
            guard paneRow <= paneRows else { break }
            var cells = cols
            if paneRow == paneRows { cells = min(cells, paneCols - col) }
            if cells <= 0 { break }
            append("\u{1B}[\(paneRow);\(col)H")
            append(colour)
            for cell in 0..<cells {
                append("\u{10EEEE}")
                if cell == 0, let mark = Self.placeholderDiacritic(line) {
                    append(String(mark))
                }
            }
            append("\u{1B}[39m")
        }
        if sync { append("\u{1B}[?2026l") }
        return payload.count
    }

    /// One **tile** as a unicode placeholder - the mirror's transport, the same shape as the wall's
    /// panel (design §6.9).
    ///
    /// Why the mirror gets it too: a `c`/`r` placement asks the terminal to scale an image into a cell
    /// rectangle, and a terminal is free to draw one image pixel per device pixel instead (Rex does).
    /// A tile captured at the pane's *reported* pixels then lands at half size on a pane whose cell it
    /// reports in points, and `--scale` / `--quality` move the picture instead of only its sharpness.
    /// A placeholder cell has no size of its own - the terminal fits the image into the cells - so the
    /// picture is the cells and the pixel count is quality, which is what those two levers were always
    /// meant to be.
    ///
    /// The cost is `cols * rows` invisible characters per dirty tile (at 8x4 cells: 32 cells, ~128 B)
    /// plus one diacritic per row decoded as "the row of the image". Next to the tile's payload that is
    /// a rounding error - and only dirty tiles are rewritten.
    public func emitTileAsPlaceholder(_ tile: CompressedTile, sync: Bool = true) {
        let rect = tile.rect
        guard rect.cols > 0, rect.rows > 0, rect.w > 0, rect.h > 0 else { return }
        let iid = 100 + tile.index
        let pid = 1000 + tile.index
        lastFrameBytes += tile.payload.count
        totalBytes += tile.payload.count
        framesEmitted += 1
        lastCompressedTiles += 1

        if sync { append("\u{1B}[?2026h") }
        // 1. Transmit only: a placeholder image must not carry a placement of its own.
        appendTransmit(id: iid, payload: tile.payload, width: rect.w, height: rect.h,
                       compressed: tile.isCompressed)
        // 2. The virtual placement on this tile's cells.
        append("\u{1B}_Gi=\(iid),p=\(pid),a=p,U=1,q=\(quiet),c=\(rect.cols),r=\(rect.rows)\u{1B}\\")
        // 3. The invisible grid. The image id travels in the foreground colour and one diacritic per
        //    row is enough (a cell inherits "left cell, column + 1").
        appendPlaceholderGrid(id: iid, row: rect.row, col: rect.col,
                              cols: rect.cols, rows: rect.rows)
        if sync { append("\u{1B}[?2026l") }
    }

    /// The transmit half of the kitty protocol, in 4096-character chunks, in the writer's format.
    ///
    /// Shared by the tile, panel and placeholder emitters: any difference between them shows up as
    /// "the wall works and the mirror does not", which is the hardest kind of bug to read.
    func appendTransmit(id iid: Int, payload: [UInt8], width: Int, height: Int,
                        compressed: Bool, channels: Int? = nil) {
        let chars = Array(Data(payload).base64EncodedString().utf8)
        let compression = compressed ? ",o=z" : ""
        let control = "Gf=\(channels ?? format.protocolChannels),s=\(width),v=\(height),a=t"
            + "\(compression),q=\(quiet),i=\(iid)"
        var i = 0
        var first = true
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
    }

    /// The invisible placeholder cells of one image: `cols * rows` `U+10EEEE` characters, a row
    /// diacritic on the first cell of each row, the image id in the foreground colour.
    ///
    /// Ends with a cursor move into the grid's own first cell. Writing the final cell of the final row
    /// arms the terminal's pending wrap, and the *next* printable byte would then scroll the whole grid
    /// - which drags every placement on it up one row. The wall avoids that cell entirely (its pictures
    /// are never at the pane's last cell); a mirror's tiles are, so the wrap is cancelled here instead.
    func appendPlaceholderGrid(id iid: Int, row: Int, col: Int, cols: Int, rows: Int) {
        let r = (iid >> 16) & 0xFF, g = (iid >> 8) & 0xFF, b = iid & 0xFF
        let colour = "\u{1B}[38;2;\(r);\(g);\(b)m"
        for line in 0..<rows {
            append("\u{1B}[\(row + line);\(col)H")
            append(colour)
            for cell in 0..<cols {
                append("\u{10EEEE}")
                if cell == 0, let mark = Self.placeholderDiacritic(line) {
                    append(String(mark))
                }
            }
            append("\u{1B}[39m")
        }
        append("\u{1B}[\(row);\(col)H")
    }

    /// The diacritic for a row number, or `nil` when the table runs out (a pane taller than 256
    /// rows), in which case the row is drawn without one - the terminal then reuses the row above,
    /// which is wrong but better than a crash.
    static func placeholderDiacritic(_ row: Int) -> Character? {
        row >= 0 && row < placeholderDiacritics.count ? placeholderDiacritics[row] : nil
    }

    /// The escapes both a tile and a panel need. Kept in one place so a terminal that draws tiles
    /// draws panels: any difference between the two would show up as "the mirror works, the wall
    /// does not", which is the hardest kind of bug to read.
    private func emitImage(id iid: Int, placementID pid: Int, row: Int, col: Int,
                           cols: Int, rows: Int, width: Int, height: Int, channels: Int,
                           compressed: Bool, payload: [UInt8], sync: Bool,
                           timing: UnsafeMutablePointer<EmitTiming>?) {
        // Two `now` calls per picture, and only when a benchmark asked for the split: the live
        // path pays one nil check per picture, nothing else.
        var mark = 0.0
        if timing != nil { mark = benchNowMs() }
        let b64 = Data(payload).base64EncodedString()
        let chars = Array(b64.utf8)
        if let timing {
            let now = benchNowMs()
            timing.pointee.base64Ms += now - mark
            mark = now
        }

        if sync { append("\u{1B}[?2026h") }
        append("\u{1B}[\(row);\(col)H")
        var i = 0
        var first = true
        // `o=z` is per picture, not per writer: the wall always compresses its panels, while a
        // mirror tile may arrive raw (issue #53), and both run in the same process.
        let compression = compressed ? ",o=z" : ""
        let control = "Gf=\(channels),s=\(width),v=\(height),a=t\(compression),q=\(quiet),i=\(iid)"
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
        append("\u{1B}_Gi=\(iid),p=\(pid),a=p,q=\(quiet),C=1,c=\(cols),r=\(rows)\u{1B}\\")
        if sync { append("\u{1B}[?2026l") }
        if let timing { timing.pointee.assembleMs += benchNowMs() - mark }
    }

    /// Should `emit` wrap this tile in its own synchronized block?
    public var perTileSync: Bool { syncMode == .tile }

    /// Diagnostic: draw one block with an explicitly chosen protocol shape, so a human can
    /// tell which variant a terminal actually honours.
    /// 0 = a=T with id, 1 = a=T without id, 2 = a=t + a=p with id, 3 = a=T with id inside 2026
    public func emitVariant(_ variant: Int, id: Int, row: Int, col: Int,
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

    public func emitFullFrame(rgba: [UInt8], width: Int, height: Int,
                              row: Int = 1, col: Int = 1, cols: Int, rows: Int) {
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
        append("\u{1B}[\(row);\(col)H")
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

    public func write(_ text: String) {
        writeLock.lock()
        defer { writeLock.unlock() }
        append(text)
        flushLocked()
    }

    private func append(_ text: String) {
        out.append(contentsOf: Array(text.utf8))
    }

    /// Writes a control sequence **between** frames, and says whether it went out.
    ///
    /// `out` doubles as the frame batch buffer, so appending to it while a batch is open would either
    /// land inside the synchronized block or be thrown away by the next `beginBatch`. The DSR probe
    /// (issue #52) is the one caller: it retries on the next tick if the answer is `false`.
    @discardableResult
    public func writeControl(_ text: String) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !batchOpen else { return false }
        out.append(contentsOf: Array(text.utf8))
        flushLocked()
        return true
    }

    /// KRD_DUMP=/path captures every byte we send, for offline protocol diffing.
    private static let dumpHandle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["KRD_DUMP"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    /// Benchmarks exercise the whole encoder without a terminal to write to.
    public var discardOutput = false
    /// Test seam (issue #21): when set, flushed bytes go here instead of the tty, so the golden
    /// dump test can compare a byte stream in memory. `nil` in production, where the pty is the sink.
    public var sink: (([UInt8]) -> Void)?

    private func flush() {
        writeLock.lock()
        defer { writeLock.unlock() }
        flushLocked()
    }

    /// Writes TUI-layer text. Positioned escapes only: the caller guarantees no newline and no
    /// write above the picture (Chrome.swift), and this lock guarantees no split escape.
    public func writeChrome(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        out.append(contentsOf: bytes)
        flushLocked()
    }

    /// What `KRD_SYNC` / `KRD_NOSYNC` actually selected, for the stats panel.
    public var syncLabel: String {
        switch syncMode {
        case .frame: return "frame"
        case .tile: return "tile"
        case .none: return "none"
        }
    }
    public var quietLabel: String { quiet }

    private func flushLocked() {
        guard !out.isEmpty else { return }
        frameWireBytes += out.count
        if let sink {
            sink(out)
            out.removeAll(keepingCapacity: true)
            return
        }
        if discardOutput {
            out.removeAll(keepingCapacity: true)
            return
        }
        if let dump = ScreenWriter.dumpHandle {
            dump.write(Data(out))
        }
        ScreenWriter.outLock.lock()
        defer { ScreenWriter.outLock.unlock() }
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
public func zlibCompress(_ input: [UInt8], level: Int = 5, huffmanOnly: Bool = false) -> [UInt8]? {
    guard !input.isEmpty else { return nil }
    if huffmanOnly { return zlibCompressHuffmanOnly(input) }
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

/// `Z_HUFFMAN_ONLY`: one pass over the input, one Huffman table, no match search (issue #59).
///
/// Quantised pixels are noise with a 32- or 64-symbol alphabet: there is nothing to match, so the
/// entropy coder is the whole win, and skipping deflate's hash chains is most of the cost. Measured
/// on the `photo` case: same 1.29x, a fraction of the time.
private func zlibCompressHuffmanOnly(_ input: [UInt8]) -> [UInt8]? {
    var stream = z_stream()
    guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15, 8, Z_HUFFMAN_ONLY,
                        ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
    defer { deflateEnd(&stream) }
    var out = [UInt8](repeating: 0, count: Int(compressBound(uLong(input.count))))
    let status = input.withUnsafeBufferPointer { src -> Int32 in
        out.withUnsafeMutableBufferPointer { dst -> Int32 in
            stream.next_in = UnsafeMutablePointer(mutating: src.baseAddress)
            stream.avail_in = uInt(src.count)
            stream.next_out = dst.baseAddress
            stream.avail_out = uInt(dst.count)
            return deflate(&stream, Z_FINISH)
        }
    }
    guard status == Z_STREAM_END else { return nil }
    out.removeSubrange(Int(stream.total_out)...)
    return out
}
