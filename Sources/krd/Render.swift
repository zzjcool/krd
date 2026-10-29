import Foundation
import CZlib

/// Turns RGBA frames into kitty graphics escapes on the pty.
///
/// Two rules learned the hard way:
///  * never let the screen hold "no image" between two frames -> we place the new
///    placement first and only then delete the old one (delete-then-place flashes black);
///  * per-image-id replacement is not guaranteed to be atomic on every terminal, so
///    each tile rotates between two image ids.
final class ScreenWriter {
    /// q=2 silences every protocol reply; KRD_Q=0 reveals them while debugging.
    private let quiet = ProcessInfo.processInfo.environment["KRD_Q"] ?? "2"
    private var out = [UInt8]()
    private var generation = 0

    private(set) var framesEmitted = 0
    private(set) var lastFrameBytes = 0
    private(set) var totalBytes = 0
    private(set) var lastCompressMs = 0.0
    private(set) var lastEncodeMs = 0.0
    private(set) var lastWriteMs = 0.0

    init() {
        out.reserveCapacity(1 << 21)
    }

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
        let text = on ? "\u{1B}[?1003h\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?1016h"
                      : "\u{1B}[?1016l\u{1B}[?1006l\u{1B}[?1003l\u{1B}[?1002l"
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
        // Terminate any half-written APC *first*, then retire the screen.
        write("\u{1B}\\\u{1B}[?2026l")
        clear()
        write("\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1006l\u{1B}[?25h\u{1B}[?1049l")
    }

    /// Placements accumulate (we never delete one by one), so every so often drop the whole
    /// set and repaint. Cheap: one full frame every `reapInterval` updates.
    private var sinceReap = 0
    /// With per-tile deletes working, placements cannot pile up, so the periodic "drop
    /// everything and repaint" is off by default (it used to be the only way to reclaim
    /// them, at the cost of one visible blink every few minutes). Raise it if a terminal
    /// ignores `a=d,i=` (then also set KRD_NO_DELETE=1).
    var reapInterval = 0

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
    /// Reset the per-frame counters (the tile path emits one sync block per tile).
    func beginFrame() {
        generation &+= 1
        lastFrameBytes = 0
        lastCompressMs = 0
        lastWriteMs = 0
    }

    func beginBatch() {
        out.removeAll(keepingCapacity: true)
        append("\u{1B}[?2026h")
        generation &+= 1
        lastFrameBytes = 0
        lastCompressMs = 0
    }

    func endBatch() {
        append("\u{1B}[?2026l")
        let t0 = Date()
        flush()
        lastWriteMs = Date().timeIntervalSince(t0) * 1000
    }

    // MARK: tiles

    /// Place a tile. Order is: transmit -> place (z above the previous one) -> delete the
    /// previous id, so no repaint can ever land in a gap.
    func emitTile(index: Int, rect r: (x: Int, y: Int, w: Int, h: Int, col: Int, row: Int, cols: Int, rows: Int),
                  pixels: [UInt8]) {
        // One image id *and* one placement id per tile, reused every frame.
        //
        // Deletes are not an option here: both Herdr and rex treat `a=d,i=<id>` as "drop the
        // whole image set", which shows up as a black screen. Alternating ids is not an
        // option either: two images then own the same cells and the stale one shows through.
        // Reusing the pair means every tile owns exactly one placement that simply gets
        // overwritten, so there is nothing to delete and nothing to leave behind.
        let iid = 100 + index
        let pid = 1000 + index

        let t0 = Date()
        guard let compressed = zlibCompress(pixels), !compressed.isEmpty else { return }
        lastCompressMs += Date().timeIntervalSince(t0) * 1000
        lastFrameBytes += compressed.count
        totalBytes += compressed.count
        framesEmitted += 1

        let b64 = Data(compressed).base64EncodedString()
        let chars = Array(b64.utf8)

        let sync = ProcessInfo.processInfo.environment["KRD_NOSYNC"] == nil
        if sync { append("\u{1B}[?2026h") }
        append("\u{1B}[\(r.row);\(r.col)H")
        var i = 0
        var first = true
        let control = "Gf=32,s=\(r.w),v=\(r.h),a=t,o=z,q=\(quiet),i=\(iid)"
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
        let t1 = Date()
        flush()
        lastWriteMs = Date().timeIntervalSince(t1) * 1000
    }

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
                   ? "Gf=32,s=\(width),v=\(height),a=t,o=z,q=\(quiet),i=\(newID),m=\(more);"
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

    private func flush() {
        guard !out.isEmpty else { return }
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
func zlibCompress(_ input: [UInt8]) -> [UInt8]? {
    guard !input.isEmpty else { return nil }
    var capacity = compressBound(uLong(input.count))
    var out = [UInt8](repeating: 0, count: Int(capacity))
    let status = input.withUnsafeBufferPointer { src -> Int32 in
        out.withUnsafeMutableBufferPointer { dst -> Int32 in
            compress2(dst.baseAddress, &capacity, src.baseAddress, uLong(src.count), 5)
        }
    }
    guard status == Z_OK else { return nil }
    out.removeSubrange(Int(capacity)...)
    return out
}
