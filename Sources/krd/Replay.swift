import Foundation
import krdcore

/// Real frames, captured once and replayed forever: the only way to put a real desktop
/// workload into the benchmarks, and the only way to reproduce "it stutters when I scroll"
/// on another machine without that machine's screen.
///
/// Format, deliberately dumb so a shell can inspect it:
///
///     <dir>/manifest.jsonl   one line per frame: {"n":0,"w":2329,"h":1452,"bpp":3,"t_ms":0}
///     <dir>/000000.raw       raw pixels, exactly w*h*bpp bytes, wire format (3 = RGB)
///
/// 100 frames of the reference layout is ~1 GB, which is why the recorder stops at
/// `--record-frames` (default 60) rather than recording whatever comes.
/// The layout a recording was made with. A replay has to reproduce it exactly: `handleFrame`
/// drops every frame whose size does not match the current layout, so a guessed geometry
/// looks like "replay produced nothing" instead of "the header is missing".
struct ReplayHeader {
    var pane: (cols: Int, rows: Int)
    var cell: (w: Double, h: Double)
    var tile: (cols: Int, rows: Int)
    var source: (w: Int, h: Int)
    var format: String

    var json: String {
        String(format: "{\"header\":{\"pane\":\"%dx%d\",\"cell\":\"%gx%g\",\"tile\":\"%dx%d\",\"source\":\"%dx%d\",\"format\":\"%@\"}}",
               pane.cols, pane.rows, cell.w, cell.h, tile.cols, tile.rows,
               source.w, source.h, format)
    }
}

final class FrameRecorder {
    private let handle: FileHandle
    private let dir: String
    private let limit: Int
    private(set) var count = 0
    private let started = benchNowMs()
    private var failed = false

    init?(dir: String, limit: Int, header: ReplayHeader) {
        guard limit > 0 else { return nil }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let manifest = dir + "/manifest.jsonl"
        FileManager.default.createFile(atPath: manifest, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: manifest) else { return nil }
        self.handle = handle
        self.dir = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        self.limit = limit
        handle.write(Data((header.json + "\n").utf8))
        Log.write("record: \(header.json)\n")
    }

    var isFull: Bool { count >= limit || failed }

    func record(_ pixels: [UInt8], width: Int, height: Int, bpp: Int) {
        guard !isFull else { return }
        guard pixels.count == width * height * bpp else { failed = true; return }
        let path = String(format: "%@/%06d.raw", dir, count)
        do {
            try Data(pixels).write(to: URL(fileURLWithPath: path))
        } catch {
            failed = true
            Log.write("record: \(error)\n")
            return
        }
        let line = String(format: "{\"n\":%d,\"w\":%d,\"h\":%d,\"bpp\":%d,\"t_ms\":%.2f}\n",
                          count, width, height, bpp, benchNowMs() - started)
        handle.write(Data(line.utf8))
        count += 1
        if count == limit {
            Log.write("record: \(count) frames in \(dir) (\(width)x\(height), \(bpp) bpp)\n")
        }
    }
}

/// A recorded set, opened for replay.
struct FrameReplay {
    /// One manifest line. The frame size lives here, per line, because that is how the recorder
    /// writes it (`FrameRecorder.record`) -- and because one size for the whole recording made an
    /// intact frame look truncated (issue #133).
    struct Entry {
        let path: String
        let tMs: Double
        let width: Int
        let height: Int
        let bpp: Int

        var byteCount: Int { width * height * bpp }

        /// What this line declares, in the terms `ls -l` reports it: `4x3 px, 3 bpp = 36 B`.
        var declaredSize: String { "\(width)x\(height) px, \(bpp) bpp = \(byteCount) B" }

        var name: String { (path as NSString).lastPathComponent }
    }

    let dir: String
    let entries: [Entry]
    /// The *first* frame's size. For a recording that agrees with itself -- every recording
    /// `--record` writes in one go -- that is the recording's size. A manifest whose lines disagree
    /// is carried per entry and refused by `refusal(...)` before a frame is painted, because one grid
    /// can only render one layout.
    let width: Int
    let height: Int
    let bpp: Int
    let header: ReplayHeader?

    /// Manifest first; everything else (a bare directory of `*.raw`) is refused on purpose,
    /// because a frame size guessed wrong costs a full black screen and an hour of confusion.
    static func open(_ dir: String) -> FrameReplay? {
        let manifest = dir + "/manifest.jsonl"
        guard let text = try? String(contentsOfFile: manifest, encoding: .utf8) else {
            return nil
        }
        var entries: [Entry] = []
        var header: ReplayHeader?
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let head = object["header"] as? [String: Any] {
                let pane = parseSize(head["pane"] as? String ?? "") ?? (0, 0)
                let cell = (head["cell"] as? String ?? "").split(separator: "x").compactMap { Double($0) }
                let tile = parseSize(head["tile"] as? String ?? "") ?? (0, 0)
                let source = parseSize(head["source"] as? String ?? "") ?? (0, 0)
                if pane.0 > 0, cell.count == 2, tile.0 > 0, source.0 > 0 {
                    header = ReplayHeader(pane: pane, cell: (cell[0], cell[1]), tile: tile,
                                          source: source, format: head["format"] as? String ?? "rgb")
                }
                continue
            }
            guard let n = object["n"] as? Int, let w = object["w"] as? Int,
                  let h = object["h"] as? Int, let b = object["bpp"] as? Int else { continue }
            let t = (object["t_ms"] as? Double) ?? Double(object["t_ms"] as? Int ?? 0)
            entries.append(Entry(path: String(format: "%@/%06d.raw", dir, n), tMs: t,
                                 width: w, height: h, bpp: b))
        }
        // Every line, not just the last one, has to be a frame someone could render.
        guard let first = entries.first,
              entries.allSatisfy({ $0.width > 0 && $0.height > 0 && $0.bpp >= 3 })
        else { return nil }
        return FrameReplay(dir: dir, entries: entries, width: first.width, height: first.height,
                           bpp: first.bpp, header: header)
    }

    func frame(_ index: Int) -> [UInt8]? {
        guard index >= 0, index < entries.count,
              let data = FileManager.default.contents(atPath: entries[index].path),
              data.count == entries[index].byteCount else { return nil }
        return [UInt8](data)
    }

    /// The first entry this layout cannot replay, in one sentence that names it: which frame, what
    /// its own manifest line declares, what is on disk, and what this build would render instead.
    ///
    /// The silence this replaces was the defect: `frame(_:)` answering `nil` became one log line, a
    /// `break`, the ordinary summary and `exit(0)`, and `handleFrame` drops a frame whose size misses
    /// the grid without a word. So the mismatch is refused before the first frame is painted, in the
    /// terms `docs/BENCHMARK.md` §5 L4 asks for ("a mismatch is a clear error, not a blank screen").
    func refusal(layoutWidth: Int, layoutHeight: Int, bpp: Int) -> String? {
        for i in entries.indices {
            if let why = refusal(i, layoutWidth: layoutWidth, layoutHeight: layoutHeight, bpp: bpp) {
                return why
            }
        }
        return nil
    }

    /// One entry's version, for the replay loop's belt and braces: the files sat still for the
    /// pre-flight above, but a recording that changed underneath the replay is not a reason to
    /// report success.
    func refusal(_ index: Int, layoutWidth: Int, layoutHeight: Int, bpp: Int) -> String? {
        guard entries.indices.contains(index) else {
            return "replay: frame \(index) does not exist (the manifest declares \(entries.count))"
        }
        let entry = entries[index]
        // `stat`, not `read`: a 1 GB recording must not be pulled through memory to learn that
        // frame 40 is short.
        guard let onDisk = (try? FileManager.default.attributesOfItem(atPath: entry.path))?[.size] as? Int else {
            return "replay: frame \(index) (\(entry.name)) is missing; "
                + "its manifest line declares \(entry.declaredSize)"
        }
        guard onDisk == entry.byteCount else {
            return "replay: frame \(index) (\(entry.name)) is \(onDisk) B "
                + "but its manifest line declares \(entry.declaredSize)"
        }
        guard entry.width == layoutWidth, entry.height == layoutHeight, entry.bpp == bpp else {
            return "replay: frame \(index) (\(entry.name)) is \(entry.width)x\(entry.height) px, \(entry.bpp) bpp "
                + "but this replay renders \(layoutWidth)x\(layoutHeight) px, \(bpp) bpp (from the manifest header); "
                + "a recording's header and its frame lines have to describe the same layout"
        }
        return nil
    }

    /// Delay between two frames, as recorded, clamped so a paused screen does not make the
    /// replay sit there for ten seconds.
    func delayMs(from index: Int) -> Double {
        guard index > 0, index < entries.count else { return 0 }
        return max(0, min(1000, entries[index].tMs - entries[index - 1].tMs))
    }
}
