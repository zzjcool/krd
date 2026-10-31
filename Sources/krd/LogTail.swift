import Foundation

/// The log panel's window onto the log file, read incrementally (#90).
///
/// `--debug` appends ~5 KB/s to that file and nothing rotates it, so an hour of a moving pointer is
/// 19 MB. The panel used to read the whole file once a second (`String(contentsOfFile:)` plus a
/// `split`) and paid 220 ms per tick for it, on the main queue, next to `SIGWINCH`, clicks and the
/// wall tick -- and the price grew with the session, because every tick re-read and re-split bytes
/// that had scrolled past twelve rows long ago. What the panel can *show* is bounded: twelve rows,
/// each cut to the pane's width. So the read is bounded the same way, and the cost stops depending
/// on the size of the file:
///
/// * **nothing new** (`stat` reports the same size, mtime and inode) -- the lines in hand are
///   returned, zero bytes read, zero allocation;
/// * **the writer appended** -- exactly those bytes are read and appended to the line buffer;
/// * **the file shrank or was replaced** (truncated, rotated onto another inode, rewritten in place
///   at the same length) -- everything is forgotten and the reader re-anchors on the file that is
///   there now: the tail of *that* file, read from its own start when it is small enough;
/// * **the writer got further ahead than a window** -- the reader re-anchors on the last
///   `windowBytes` rather than digesting a gap that cannot reach twelve rows.
///
/// Measured against a 19 MB file, both bodies in one process, release (`LogTailCostTests`,
/// `KRD_LOGTAIL_COST=1 swift test -c release --filter LogTailCost`): the whole-file read costs
/// 16.9 ms at 1 MB, 86.5 ms at 5 MB, 357 ms at 19 MB and 1072 ms at 50 MB, while a re-anchor here is
/// 1.10 ms and an unchanged tick 0.026 ms at every one of those sizes. The numbers are flat in the
/// size of the file, and a tick that swallows one appended line reads one line (0.03 ms).
///
/// A struct, not a class, so the reader's whole state is the panel's own and a test can drive it
/// against a real file (`Tests/krdTests/LogTailTests.swift`) instead of a mocked file system.
struct LogTailReader {
    /// Rows the panel shows, and therefore the most lines the buffer keeps: the log's window is
    /// anchored at the newest row (`ChromePanel.readsFromTheEnd`), and the wheel can only reach the
    /// rows of `ChromeMetrics.logTail`, so older lines would have nowhere to go.
    var keep = 12

    /// Most bytes one re-anchor reads. Twelve `--debug` lines are ~2 KB; the headroom is for long
    /// ones (a mouse-trace line is ~100 B, a report line can be a few KB) so the ordinary case gets
    /// its twelve rows out of a single window.
    static let windowBytes = 64 * 1024

    /// Most bytes one continuation may append before it gives up digesting the gap and re-anchors.
    static let appendBytes = 16 * 1024

    /// The newest complete lines, oldest first, and the bytes of the line after them that has no
    /// newline yet. `--debug` writes a whole line per `write`, but a half-written line is a real
    /// state (a short write, or a note that ends without a newline): painting it and then jumping
    /// to the rest of it a tick later is the one thing the panel must not do.
    private var lines: [String] = []
    private var pending = ""
    /// Whether a newline has been seen at all: a file that is one unterminated line has nothing
    /// else to show, so that line *is* the tail (see `Log.tail`'s "no final newline" rule).
    private var sawNewline = false

    /// How far into the file the buffer has read, and which file that was. `(device, inode, size,
    /// mtime)` is what separates "grown" from "replaced" from "unchanged" without reading a byte.
    private var read: UInt64 = 0
    private var identity: FileIdentity? = nil

    /// What `fstat` says about the file, in the four numbers the decision above needs.
    struct FileIdentity: Equatable {
        var device: UInt64
        var inode: UInt64
        var size: UInt64
        /// `mtime` in nanoseconds: a file rewritten in place with the same length changes nothing
        /// but this, and a panel that ignored it would keep showing the replaced content.
        var modified: Int64
    }

    /// The last `keep` complete lines of the file at `path`, or `[]` when there is no file
    /// (`--debug`/`--log` off) -- the state the panel draws as "no log yet".
    mutating func update(path: String?) -> [String] {
        guard let path, let handle = FileHandle(forReadingAtPath: path) else {
            reset()
            return []
        }
        defer { try? handle.close() }
        guard let now = LogTailReader.identity(of: handle) else { return lines }
        let was = identity
        if was == now { return lines }                       // nothing was written: reads nothing
        identity = now

        // Only "the same file, grown by a little" is a continuation. Everything else -- truncated,
        // rotated onto another inode, rewritten in place, or a gap too big for twelve rows -- is a
        // re-anchor, because the buffer's bytes no longer describe the file's tail.
        let sameFile = was?.device == now.device && was?.inode == now.inode
        let grew = now.size > read && now.size - read <= UInt64(LogTailReader.appendBytes)
        if sameFile, was != nil, grew {
            consume(handle, from: read, to: now.size)
        } else {
            reanchor(handle, size: now.size)
        }
        return lines
    }

    /// Forget the file: the next `update` starts from scratch.
    mutating func reset() {
        lines = []
        pending = ""
        sawNewline = false
        read = 0
        identity = nil
    }

    /// Read the tail of the file as it is now: the last `windowBytes` of it, or the whole file when
    /// it is smaller than that (`from == 0`, the case where "the start" and "the tail" are the same
    /// place -- this is also what a truncation re-reads, so a log that was cut back to nothing
    /// shows `no log yet` instead of its pre-truncation lines).
    private mutating func reanchor(_ handle: FileHandle, size: UInt64) {
        lines = []
        pending = ""
        sawNewline = false
        let window = UInt64(LogTailReader.windowBytes)
        let from = size > window ? size - window : 0
        let bytes = LogTailReader.read(handle, from: from, upTo: Int(min(window, size - from)))
        var text = String(decoding: bytes, as: UTF8.self)
        if from > 0 {
            // The window starts in the middle of a line, and possibly of a UTF-8 sequence: the
            // first (partial) line is dropped whole, which is what `tail -c` does with its first
            // row. A window with no newline in it at all is one line longer than the window, and
            // half of it is not worth showing.
            if let nl = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: nl)...])
            } else {
                text = ""
            }
        }
        read = size
        absorb(text, wholeFile: from == 0)
    }

    /// Read bytes the writer appended since the last tick -- no more than that.
    private mutating func consume(_ handle: FileHandle, from: UInt64, to: UInt64) {
        let bytes = LogTailReader.read(handle, from: from, upTo: Int(to - from))
        read = to
        absorb(String(decoding: bytes, as: UTF8.self), wholeFile: false)
    }

    /// Append the lines that are complete, and hold the rest back as `pending`.
    private mutating func absorb(_ text: String, wholeFile: Bool) {
        var text = pending + text
        pending = ""
        if let nl = text.lastIndex(of: "\n") {
            pending = String(text[text.index(after: nl)...])
            text = String(text[text.startIndex...nl])
            sawNewline = true
        } else if wholeFile, !sawNewline {
            // No newline anywhere in the file: it holds exactly one line, unterminated, and that
            // line is the tail. (A file that has lines keeps its unterminated last one out of the
            // panel until it is finished.)
            pending = text
            text = text.isEmpty ? "" : text + "\n"
        } else {
            pending = text
            text = ""
        }
        // `Log.tail` owns the rule for how text becomes lines (a trailing newline does not start a
        // line, a blank line between two lines is a line) -- the same rule the panel's array
        // contract was pinned to in `LogTailTests` (#118), used here on one window instead of on
        // the whole file.
        let fresh = Log.tail(of: text, lines: keep)
        guard !fresh.isEmpty else { return }
        lines.append(contentsOf: fresh)
        if lines.count > keep { lines.removeFirst(lines.count - keep) }
    }

    /// One positioned read, looped until the window is full: `read(upToCount:)` is allowed to hand
    /// back a short buffer, and a short read here would silently drop lines out of the panel.
    private static func read(_ handle: FileHandle, from: UInt64, upTo count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        do {
            try handle.seek(toOffset: from)
            var bytes: [UInt8] = []
            bytes.reserveCapacity(count)
            while bytes.count < count,
                  let chunk = try handle.read(upToCount: count - bytes.count), !chunk.isEmpty {
                bytes.append(contentsOf: chunk)
            }
            return bytes
        } catch {
            return []
        }
    }

    private static func identity(of handle: FileHandle) -> FileIdentity? {
        var st = stat()
        guard fstat(handle.fileDescriptor, &st) == 0 else { return nil }
        return FileIdentity(device: UInt64(bitPattern: Int64(st.st_dev)),
                            inode: UInt64(st.st_ino),
                            size: UInt64(max(0, st.st_size)),
                            modified: modifiedNanos(st))
    }

    private static func modifiedNanos(_ st: stat) -> Int64 {
        #if canImport(Darwin)
        let ts = st.st_mtimespec
        #else
        let ts = st.st_mtim
        #endif
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }
}
