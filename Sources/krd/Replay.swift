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
    private var count = 0
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
    struct Entry {
        let path: String
        let tMs: Double
    }

    let dir: String
    let entries: [Entry]
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
        var width = 0, height = 0, bpp = 0
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
            width = w; height = h; bpp = b
            let t = (object["t_ms"] as? Double) ?? Double(object["t_ms"] as? Int ?? 0)
            entries.append(Entry(path: String(format: "%@/%06d.raw", dir, n), tMs: t))
        }
        guard !entries.isEmpty, width > 0, height > 0, bpp >= 3 else { return nil }
        return FrameReplay(dir: dir, entries: entries, width: width, height: height, bpp: bpp, header: header)
    }

    func frame(_ index: Int) -> [UInt8]? {
        guard index >= 0, index < entries.count,
              let data = FileManager.default.contents(atPath: entries[index].path),
              data.count == width * height * bpp else { return nil }
        return [UInt8](data)
    }

    /// Delay between two frames, as recorded, clamped so a paused screen does not make the
    /// replay sit there for ten seconds.
    func delayMs(from index: Int) -> Double {
        guard index > 0, index < entries.count else { return 0 }
        return max(0, min(1000, entries[index].tMs - entries[index - 1].tMs))
    }
}
