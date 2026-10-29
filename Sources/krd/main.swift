import Foundation
import ApplicationServices
import AppKit
import CoreGraphics
import ScreenCaptureKit

struct Options {
    var fps = 20
    var displayIndex: Int? = nil
    var windowQuery: String? = nil
    var noInput = false
    /// Do not paint the pointer into the mirrored picture (see Capturer.showsCursor).
    var noCursor = false
    var selftest = false
    var bench = false
    var logPath: String? = nil
    var dryRun = false
    var listOnly = false
    var debug = false
    var fullFrame = false
    // 8x4 cells (issue #5): at 16x8 a single changed character re-sends 5.2 KB, at 8x4 it is
    // 1.6 KB, and a full-width line still gets 1.7x smaller. Below 4x2 the per-image escape
    // overhead starts to dominate the payload, so this is the knee of the curve.
    var tileCols = 8
    var tileRows = 4
    var pixelFormat: PixelFormat? = nil
    var cell: (w: Double, h: Double)? = nil
    /// Force the pane size in cells (bench/selftest only; a real run reads it from the tty).
    var pane: (cols: Int, rows: Int)? = nil

    // benchmarks (docs/BENCHMARK.md)
    /// Source aspect for --bench/--selftest: the display the tiles are fitted into.
    var source: (w: Int, h: Int)? = nil
    /// Machine-readable results on stdout instead of the human table.
    var benchJSON = false
    var benchWire: String? = nil
    var benchSeconds = 5.0
    var rounds = 30
    var noSerial = false
    var replay: String? = nil
    var record: String? = nil
    var recordFrames = 60
    var statsJSON: String? = nil
}

func usage() -> String {
    """
    krd -- macOS desktop inside a terminal pane (kitty graphics protocol)

    usage: krd [options]
      --fps <n>           capture rate cap (default 20)
      --display <i>       display index from --list (default: the one under the pointer)
      --window <q>        capture a single window: numeric id or title substring
      --tile <c>x<r>      dirty-tile size in cells (default 8x4; 16x8 = fewer, bigger images)
      --format <f>        wire pixel format: rgb (default, f=24) or rgba (f=32)
      --cell <w>x<h>      cell size in px when the terminal does not report it (default 8x20)
      --log <path>        write diagnostics to a file instead of over the picture
      --full-frame        disable tiling, always resend the whole frame
      --no-input          view only, do not inject events
      --no-cursor         do not draw the pointer into the picture (also stops a moving
                          mouse from dirtying tiles every frame)
      --dry-run           parse input but only log it, never post CGEvent
      --debug             geometry + per-second stats on stderr
      --list              list displays and windows, then exit
      -v, --version       print the version and exit

    test modes (no screen access, no terminal needed):
      --selftest          paint a synthetic pattern through the tile pipeline
      --bench             time the encoder on synthetic frames, then exit
      --bench-wire <case> emit one case at --fps to stdout, per-frame JSON on stderr
                          (bench/wire.py puts a rate-limited drain behind it)
      --json              with --bench: results on stdout, table on stderr
      --pane <c>x<r>      force the pane size in cells (bench/selftest only)
      --source <w>x<h>    source aspect for --bench/--selftest (default 1440x2560)
      --rounds <n>        measured rounds per bench case (default 30)
      --seconds <n>       duration of --bench-wire (default 5)
      --no-serial         skip the single-threaded reference run
      --record <dir>      record captured frames for --replay
      --record-frames <n> stop recording after n frames (default 60)
      --replay <dir>      feed recorded frames through the real pipeline
      --stats-json <path> per-second stats as NDJSON (implies the --debug stats)

    keys: Ctrl-\\ quits (Ctrl-C is forwarded to the remote desktop)
    """
}

func parseArguments() -> Options {
    var options = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--fps": options.fps = max(1, Int(args[safe: i + 1] ?? "") ?? options.fps); i += 1
        case "--display": options.displayIndex = Int(args[safe: i + 1] ?? ""); i += 1
        case "--window": options.windowQuery = args[safe: i + 1]; i += 1
        case "--tile":
            if let spec = args[safe: i + 1], case let parts = spec.split(separator: "x"), parts.count == 2 {
                options.tileCols = max(2, Int(parts[0]) ?? options.tileCols)
                options.tileRows = max(1, Int(parts[1]) ?? options.tileRows)
            }
            i += 1
        case "--cell":
            if let spec = args[safe: i + 1], case let parts = spec.split(separator: "x"), parts.count == 2,
               let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 {
                options.cell = (w, h)
            }
            i += 1
        case "--format":
            switch (args[safe: i + 1] ?? "").lowercased() {
            case "rgb", "f=24", "24": options.pixelFormat = .rgb
            case "rgba", "f=32", "32": options.pixelFormat = .rgba
            default: break
            }
            i += 1
        case "--pane":
            if let spec = args[safe: i + 1], case let parts = spec.split(separator: "x"), parts.count == 2,
               let c = Int(parts[0]), let r = Int(parts[1]), c > 1, r > 1 {
                options.pane = (c, r)
            }
            i += 1
        case "--full-frame": options.fullFrame = true
        case "--no-input": options.noInput = true
        case "--no-cursor": options.noCursor = true
        case "--selftest": options.selftest = true
        case "--bench": options.bench = true
        case "--json": options.benchJSON = true
        case "--bench-wire":
            options.benchWire = args[safe: i + 1]
            i += 1
        case "--source":
            if let spec = args[safe: i + 1], let size = parseSize(spec) { options.source = (size.0, size.1) }
            i += 1
        case "--rounds":
            if let n = Int(args[safe: i + 1] ?? ""), n > 0 { options.rounds = n }
            i += 1
        case "--seconds":
            if let n = Double(args[safe: i + 1] ?? ""), n > 0 { options.benchSeconds = n }
            i += 1
        case "--no-serial": options.noSerial = true
        case "--record":
            options.record = args[safe: i + 1]
            i += 1
        case "--record-frames":
            if let n = Int(args[safe: i + 1] ?? ""), n > 0 { options.recordFrames = n }
            i += 1
        case "--replay":
            options.replay = args[safe: i + 1]
            i += 1
        case "--stats-json":
            options.statsJSON = args[safe: i + 1]
            i += 1
        case "--log":
            options.logPath = args[safe: i + 1]
            i += 1
        case "--dry-run": options.dryRun = true
        case "--debug": options.debug = true
        case "--list": options.listOnly = true
        case "-v", "--version": print("krd \(krdVersion)"); exit(0)
        case "-h", "--help": print(usage()); exit(0)
        default: break
        }
        i += 1
    }
    return options
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// "137x44" -> (137, 44). Used by --pane, --source and the replay header.
func parseSize(_ spec: String) -> (Int, Int)? {
    let parts = spec.split(separator: "x")
    guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else { return nil }
    return (w, h)
}

final class Desk {
    private let options: Options
    private let writer = ScreenWriter()
    private let capturer = Capturer()
    private var input: InputReader?
    private var cleanedUp = false

    private var filter: SCContentFilter?
    private var sourceRect: CGRect = .zero

    private let stateLock = NSLock()
    private var grid: TileGrid?
    private var reportedFrameMismatch = false
    private var viewport = Viewport(pixelWidth: 1, pixelHeight: 1, cols: 1, rows: 1, sourceRect: .zero)
    private var previousFrame: [UInt8] = []
    private var lastDirtyCount = 0

    private var resizeSource: DispatchSourceSignal?
    private var statsTimer: DispatchSourceTimer?
    /// Wall time from capture callback to last byte out, per frame.
    private(set) var lastPipeMs = 0.0
    private var recorder: FrameRecorder?

    init(options: Options) {
        self.options = options
        if let format = options.pixelFormat { writer.format = format }
        capturer.format = writer.format
        capturer.showsCursor = !options.noCursor
        writer.resize(tiles: 0)
    }

    func run() async throws {
        // Diagnostics never go over the picture: they land in a file instead.
        // `--stats-json` implies stats, and stats must never land on the tty: without an
        // explicit destination they go to a temp file like `--debug` does.
        Log.configure(explicitPath: options.logPath,
                      wantsLogging: options.debug || options.logPath != nil || options.statsJSON != nil)
        if let where_ = Log.path {
            FileHandle.standardError.write(Data("krd: logging to \(where_)\n".utf8))
        }
        // --selftest never touches ScreenCaptureKit: no TCC prompt, no window juggling.
        if let dir = options.replay, options.bench {
            try await runReplay(dir: dir, discard: true)
            return
        }
        if options.bench {
            if let cell = options.cell { TermGeometry.fallbackCell = cell }
            var geometry = TermGeometry.read()
            if let pane = options.pane { geometry.cols = pane.cols; geometry.rows = pane.rows }
            let source = options.source ?? (w: 1440, h: 2560)
            self.sourceRect = CGRect(x: 0, y: 0, width: source.w, height: source.h)
            applyLayout(geometry: geometry)
            guard let layout = currentGrid() else { throw DeskError.message("could not compute a tile layout") }
            Bench.runStages(layout: layout, writer: writer, rounds: options.rounds,
                            serial: !options.noSerial, source: sourceRect.size, json: options.benchJSON)
        }

        if let caseName = options.benchWire {
            if let cell = options.cell { TermGeometry.fallbackCell = cell }
            var geometry = TermGeometry.read()
            if let pane = options.pane { geometry.cols = pane.cols; geometry.rows = pane.rows }
            let source = options.source ?? (w: 1440, h: 2560)
            self.sourceRect = CGRect(x: 0, y: 0, width: source.w, height: source.h)
            applyLayout(geometry: geometry)
            guard let layout = currentGrid() else { throw DeskError.message("could not compute a tile layout") }
            writer.beginSession()
            Bench.runWire(layout: layout, writer: writer, caseName: caseName, fps: options.fps,
                          seconds: options.benchSeconds, source: sourceRect.size) { pixels, w, h in
                self.handleFrame(pixels: pixels, width: w, height: h)
            }
        }

        if let dir = options.replay {
            try await runReplay(dir: dir, discard: false)
            return
        }

        if options.selftest {
            if let cell = options.cell { TermGeometry.fallbackCell = cell }
            var geometry = TermGeometry.read()
            if let pane = options.pane { geometry.cols = pane.cols; geometry.rows = pane.rows }
            let bounds = CGRect(x: 0, y: 0, width: 1440, height: 2560)
            self.filter = nil
            self.sourceRect = bounds
            applyLayout(geometry: geometry)
            guard let layout = currentGrid() else { throw DeskError.message("could not compute a tile layout") }
            writer.beginSession()
            try await runSelfTest(layout: layout)
            return
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        if options.listOnly {
            var text = ""
            for (index, display) in content.displays.enumerated() {
                let bounds = CGDisplayBounds(display.displayID)
                text += "[\(index)] display \(display.displayID)  \(Int(bounds.width))x\(Int(bounds.height)) pt\n"
            }
            for window in content.windows where window.frame.width > 60 {
                let app = window.owningApplication?.applicationName ?? "?"
                text += "    window \(window.windowID)  @\(Int(window.frame.minX)),\(Int(window.frame.minY)) \(Int(window.frame.width))x\(Int(window.frame.height))  app=\(app)  title=\(window.title ?? "-")\n"
            }
            FileHandle.standardOutput.write(Data(text.utf8))
            exit(0)
        }

        if let cell = options.cell { TermGeometry.fallbackCell = cell }
        // Prefer the terminal's own answer: sshd ptys report no pixel size at all.
        let geometry = TermGeometry.query() ?? TermGeometry.read()
        if geometry.pixelWidth == 0 || geometry.pixelHeight == 0 {
            Log.write(
                "krd: terminal reports no pixel size; assuming a \(Int(TermGeometry.fallbackCell.w))x\(Int(TermGeometry.fallbackCell.h)) px cell (override with --cell)\n")
        }

        let filter: SCContentFilter
        let sourceRect: CGRect

        if let query = options.windowQuery {
            let match = content.windows.first { window in
                guard window.frame.width > 40, window.frame.height > 40 else { return false }
                if let id = Int(query) { return window.windowID == id }
                return (window.title ?? "").localizedCaseInsensitiveContains(query)
            }
            guard let window = match else {
                throw DeskError.message("no window matched \"\(query)\" (try --list)")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            sourceRect = window.frame
        } else {
            let mainID = CGMainDisplayID()
            let pointer = CGEvent(source: nil)?.location ?? .zero
            let underPointer: CGDirectDisplayID? = content.displays
                .first { CGDisplayBounds($0.displayID).contains(pointer) }?.displayID
            let preferred: CGDirectDisplayID = underPointer ?? mainID
            let display: SCDisplay
            if let index = options.displayIndex, index < content.displays.count {
                display = content.displays[index]
            } else if let direct = content.displays.first(where: { $0.displayID == preferred }) {
                display = direct
            } else if let first = content.displays.first {
                display = first
            } else {
                throw DeskError.message("no displays available")
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            sourceRect = CGDisplayBounds(display.displayID)
        }

        self.filter = filter
        self.sourceRect = sourceRect
        applyLayout(geometry: geometry)
        guard let layout = currentGrid() else { throw DeskError.message("could not compute a tile layout") }

        let writer = self.writer
        capturer.onFrame = { [weak self] pixels, width, height in
            guard let self else { return }
            self.handleFrame(pixels: pixels, width: width, height: height)
        }

        if let dir = options.record {
            recorder = FrameRecorder(dir: dir, limit: options.recordFrames,
                                     header: ReplayHeader(pane: (layout.paneCols, layout.paneRows),
                                                          cell: (layout.cellW, layout.cellH),
                                                          tile: (layout.tileCols, layout.tileRows),
                                                          source: (Int(sourceRect.width), Int(sourceRect.height)),
                                                          format: writer.format == .rgb ? "rgb" : "rgba"))
            if recorder == nil {
                Log.write("record: could not write to \(dir)\n")
            }
        }

        writer.beginSession()
        installSignalCleanup()
        installResizeHandler()
        if options.debug || options.statsJSON != nil { startStats() }

        try await capturer.start(filter: filter, width: layout.pixelW, height: layout.pixelH, fps: options.fps)

        if !options.noInput {
            let reader = InputReader(viewport: { [weak self] in self?.currentViewport() ?? Viewport(pixelWidth: 1, pixelHeight: 1, cols: 1, rows: 1, sourceRect: .zero) },
                                     dryRun: options.dryRun) { [weak self] in self?.shutdown() }
            reader.trace = options.debug
            let active = reader.start()
            input = reader
            if options.debug {
                Log.write("krd: input active=\(active)\n")
            }
            if options.debug {
                let trusted = AXIsProcessTrusted()
                Log.write(
                    "krd: accessibility trusted=\(trusted) (clicks/keys need it; see System Settings > Privacy > Accessibility)\n")
            }
        }

        if options.debug {
            let cell = geometry.cellSize
            let message = "krd: pane \(geometry.cols)x\(geometry.rows) cells, cell \(cell.w)x\(cell.h) px\n"
                + "krd: source \(Int(sourceRect.width))x\(Int(sourceRect.height)) pt -> \(layout.pixelW)x\(layout.pixelH) px in \(layout.paneCols)x\(layout.paneRows) cells, "
                + "\(layout.tilesX)x\(layout.tilesY) tiles of \(layout.tileCols)x\(layout.tileRows) cells\n"
            Log.write(message)
        }

        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: replay

    /// Feed recorded frames through the real pipeline. With `--bench` the output is discarded
    /// and only the summary is printed; without it the frames are painted into the terminal at
    /// the recorded pace, which is how a "it stutters when I scroll" report gets reproduced.
    private func runReplay(dir: String, discard: Bool) async throws {
        guard let replay = FrameReplay.open(dir), let header = replay.header else {
            throw DeskError.message("no usable manifest.jsonl in \(dir) (record one with --record <dir>)")
        }
        TermGeometry.fallbackCell = header.cell
        var geometry = TermGeometry.read()
        geometry.cols = header.pane.cols
        geometry.rows = header.pane.rows
        geometry.pixelWidth = 0                     // make cellSize return the header's cell
        geometry.pixelHeight = 0
        self.sourceRect = CGRect(x: 0, y: 0, width: header.source.w, height: header.source.h)
        applyLayout(geometry: geometry)
        guard let layout = currentGrid() else { throw DeskError.message("could not compute a tile layout") }
        guard layout.pixelW == replay.width, layout.pixelH == replay.height else {
            throw DeskError.message("replay is \(replay.width)x\(replay.height) px but the header layout "
                                    + "computes \(layout.pixelW)x\(layout.pixelH) (tile \(header.tile.cols)x\(header.tile.rows))")
        }
        // A bpp mismatch would read past the end of every frame buffer (`extract` uses the
        // grid's bpp), so it has to be refused before the first frame, not diagnosed after a
        // crash deep inside memcpy.
        guard layout.bpp == replay.bpp else {
            throw DeskError.message("replay frames are \(replay.bpp) bpp but this build renders \(layout.bpp) bpp "
                                    + "(the recording was made with --format \(header.format)); replay with "
                                    + (replay.bpp == 4 ? "--format rgba" : "--format rgb"))
        }
        writer.resize(tiles: layout.count)
        writer.discardOutput = discard
        writer.beginSession()

        var payload: [Double] = [], zlib: [Double] = [], writes: [Double] = []
        var wire: [Double] = [], wall: [Double] = []
        for i in 0..<replay.entries.count {
            guard let pixels = replay.frame(i) else {
                Log.write("replay: frame \(i) is missing or truncated, stopping\n")
                break
            }
            let t0 = benchNowMs()
            handleFrame(pixels: pixels, width: replay.width, height: replay.height)
            wall.append(benchNowMs() - t0)
            payload.append(Double(writer.lastFrameBytes))
            wire.append(Double(writer.lastWireBytes))
            zlib.append(writer.lastCompressMs)
            writes.append(writer.lastWriteMs)
            if !discard {
                let delay = replay.delayMs(from: i)
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000)) }
            }
        }
        writer.endSession()

        let bytes = payload.reduce(0, +)
        let wireBytes = wire.reduce(0, +)
        let wallSeconds = wall.reduce(0, +) / 1000
        var text = "krd: replay \(dir) — \(replay.entries.count) frames, \(replay.width)x\(replay.height) px, "
            + "\(layout.tilesX)x\(layout.tilesY) tiles\n"
        // `%s` needs a C string; a Swift `String` passed to it is an NSString and
        // strlen() on an object header is a segfault. Bench.pad does the same job safely.
        text += "  " + Bench.pad("", 10, left: true) + " "
            + Bench.pad("p50", 10) + " " + Bench.pad("p95", 10) + " "
            + Bench.pad("p99", 10) + " " + Bench.pad("max", 10) + "\n"
        func row(_ name: String, _ p: Percentiles) {
            text += String(format: "  %-10s %10.2f %10.2f %10.2f %10.2f\n",
                           (name as NSString).utf8String!, p.p50, p.p95, p.p99, p.max)
        }
        text += "  " + Bench.pad("bytes", 10, left: true) + " " + Bench.pad("\(Int(Percentiles(payload).p50))", 10)
            + " " + Bench.pad("\(Int(Percentiles(payload).p95))", 10)
            + " " + Bench.pad("\(Int(Percentiles(payload).p99))", 10)
            + " " + Bench.pad("\(Int(Percentiles(payload).max))", 10) + "\n"
        row("zlib ms", Percentiles(zlib))
        row("write ms", Percentiles(writes))
        row("wall ms", Percentiles(wall))
        if wallSeconds > 0 {
            text += String(format: "  wire %.1f MB/s over %.2f s of frame time (%@ payload, %@ on the wire)\n",
                           Double(wireBytes) / 1_048_576.0 / wallSeconds, wallSeconds,
                           String(format: "%.1f MB", Double(bytes) / 1_048_576.0) as NSString,
                           String(format: "%.1f MB", Double(wireBytes) / 1_048_576.0) as NSString)
        }
        FileHandle.standardOutput.write(Data(text.utf8))
        exit(0)
    }

    // MARK: selftest

    /// Paint a synthetic pattern through the real tile pipeline -- no ScreenCaptureKit,
    /// no permissions, no window juggling. Four solid quadrants plus a moving bar make
    /// it obvious which tiles arrived and whether the placement lands where we asked.
    private func runSelfTest(layout: TileGrid) async throws {
        let w = layout.pixelW, h = layout.pixelH
        let bpp = layout.bpp
        let quadrants: [(UInt8, UInt8, UInt8)] = [(255, 0, 255), (255, 255, 0), (0, 255, 255), (255, 128, 0)]
        Log.write("krd: selftest \(w)x\(h) px, \(layout.tilesX)x\(layout.tilesY) tiles\n")
        if ProcessInfo.processInfo.environment["KRD_QUADRANTS"] != nil {
            let half = (w: w / 2, h: h / 2)
            let palette: [(UInt8, UInt8, UInt8)] = [(255, 0, 255), (255, 255, 0), (0, 255, 255), (255, 255, 255)]
            let colsHalf = layout.paneCols / 2, rowsHalf = layout.paneRows / 2
            for v in 0..<4 {
                var px = [UInt8](repeating: 255, count: half.w * half.h * bpp)
                let c = palette[v]
                for y in 0..<half.h {
                    for x in 0..<half.w {
                        let o = (y * half.w + x) * bpp
                        let edge = x < 6 || y < 6 || x >= half.w - 6 || y >= half.h - 6
                        px[o] = edge ? 0 : c.0
                        px[o + 1] = edge ? 0 : c.1
                        px[o + 2] = edge ? 0 : c.2
                    }
                }
                writer.emitVariant(v, id: 900 + v,
                                   row: 1 + (v / 2) * rowsHalf + 1, col: 1 + (v % 2) * colsHalf + 1,
                                   pixels: px, width: half.w, height: half.h,
                                   cols: colsHalf, rows: rowsHalf)
                try await Task.sleep(nanoseconds: 400_000_000)
            }
            Log.write("krd: quadrants drawn: 0=aT+id 1=aT noid 2=a=t+a=p 3=aT+2026\n")
            try await Task.sleep(nanoseconds: 6_000_000_000)
            if ProcessInfo.processInfo.environment["KRD_DELTEST"] != nil {
                // one lone delete, in its own write, outside any synchronized block
                writer.write("\u{1B}_Ga=d,i=901\u{1B}\\")
                Log.write("krd: sent lone delete for 901\n")
            }
            try await Task.sleep(nanoseconds: 20_000_000_000)
            writer.endSession()
            return
        }
        if ProcessInfo.processInfo.environment["KRD_GRID"] != nil {
            // Each tile gets its own colour and a white border, so a screenshot can be
            // checked for misplacement without any guessing.
            var px = [UInt8](repeating: 0, count: w * h * bpp)
            for ty in 0..<layout.tilesY {
                for tx in 0..<layout.tilesX {
                    let r = layout.rect(tx, ty)
                    let index = ty * layout.tilesX + tx
                    let col = (UInt8(55 + (index * 37) % 200), UInt8(55 + (index * 71) % 200), UInt8(200))
                    for y in r.y..<(r.y + r.h) {
                        for x in r.x..<(r.x + r.w) {
                            let o = (y * w + x) * bpp
                            let border = x - r.x < 3 || y - r.y < 3 || (r.x + r.w - x) <= 3 || (r.y + r.h - y) <= 3
                            px[o] = border ? 255 : col.0
                            px[o + 1] = border ? 255 : col.1
                            px[o + 2] = border ? 255 : col.2
                            if bpp == 4 { px[o + 3] = 255 }
                        }
                    }
                }
            }
            for pass in 0..<20 {
                handleFrame(pixels: px, width: w, height: h)
                writer.write("\u{1B}[1;1H\u{1B}[0m ")
                try await Task.sleep(nanoseconds: 200_000_000)
                if pass == 0 {
                    Log.write("krd: grid drawn \(layout.tilesX)x\(layout.tilesY) tiles\n")
                }
            }
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return
        }
        for pass in 0..<40 {
            var px = [UInt8](repeating: 0, count: w * h * bpp)
            px.withUnsafeMutableBufferPointer { buf in
                for y in 0..<h {
                    for x in 0..<w {
                        let q = (y >= h / 2 ? 2 : 0) + (x >= w / 2 ? 1 : 0)
                        let c = quadrants[q]
                        let dim: UInt8 = ((x / 32 + y / 32) % 2 == 0) ? 255 : 190
                        let bar = abs(x - (pass * w / 40)) < 8 ? 1.0 : 0.0
                        let o = (y * w + x) * bpp
                        buf[o] = bar > 0 ? 255 : c.0
                        buf[o + 1] = bar > 0 ? 255 : c.1
                        buf[o + 2] = bar > 0 ? 255 : c.2
                        if bpp == 4 { buf[o + 3] = bar > 0 ? 255 : dim }
                    }
                }
            }
            handleFrame(pixels: px, width: w, height: h)
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        writer.endSession()
        Log.write("krd: selftest done, \(writer.framesEmitted) frames, \(writer.totalBytes) bytes\n")
        exit(0)
    }

    // MARK: layout

    private func applyLayout(geometry: TermGeometry) {
        let aspect = sourceRect.width / max(sourceRect.height, 1)
        let layout = TileGrid.make(geometry: geometry, aspect: aspect,
                                   tileCols: options.tileCols, tileRows: options.tileRows,
                                   bpp: writer.format.bytesPerPixel)
        stateLock.lock()
        grid = layout
        previousFrame = []
        viewport = Viewport(pixelWidth: layout.pixelW, pixelHeight: layout.pixelH,
                            cols: layout.paneCols, rows: layout.paneRows, sourceRect: sourceRect)
        stateLock.unlock()
    }

    private func currentGrid() -> TileGrid? {
        stateLock.lock(); defer { stateLock.unlock() }
        return grid
    }

    private func currentViewport() -> Viewport {
        stateLock.lock(); defer { stateLock.unlock() }
        return viewport
    }

    // MARK: frame handling

    private func handleFrame(pixels: [UInt8], width: Int, height: Int) {
        let started = benchNowMs()
        // capture callback -> last byte out: the number that is actually felt (Q4 in
        // docs/BENCHMARK.md). `defer` so every early return is measured too.
        defer { lastPipeMs = benchNowMs() - started }
        guard let grid = currentGrid() else { return }
        guard width == grid.pixelW, height == grid.pixelH else {
            if !reportedFrameMismatch {
                reportedFrameMismatch = true
                Log.write(
                    "krd: dropping frames: got \(width)x\(height), layout expects \(grid.pixelW)x\(grid.pixelH)\n")
            }
            return
        }

        // Recording happens before the dirty pass, i.e. it captures exactly the frames the
        // pipeline would render (post-dedupe, post-resize).
        if let recorder, !recorder.isFull {
            recorder.record(pixels, width: width, height: height, bpp: grid.bpp)
        }

        let dirty: [Int]
        if options.fullFrame || previousFrame.count != pixels.count || writer.reapIfNeeded() {
            dirty = Array(0..<grid.count)
        } else {
            dirty = TileGrid.dirty(previous: previousFrame, current: pixels, grid: grid)
        }
        stateLock.lock()
        previousFrame = pixels
        lastDirtyCount = dirty.count
        stateLock.unlock()

        writer.resize(tiles: grid.count)
        writer.beginFrame()
        guard !dirty.isEmpty else {
            writer.nudge()
            writer.endFrame()               // the frame's synchronized block must still be closed
            return
        }

        if options.fullFrame {
            writer.emitFullFrame(rgba: pixels, width: width, height: height,
                                 cols: grid.paneCols, rows: grid.paneRows)
            writer.endFrame()
            return
        }

        // Compressing a dirty tile is >90 % of the frame budget and touches no shared state, so
        // the dirty tiles of a frame go through zlib concurrently. On a full repaint that is the
        // difference between ~477 ms and ~75 ms for 54 tiles (see issue #2).
        let compressStart = Date()
        var packed = [CompressedTile?](repeating: nil, count: dirty.count)
        packed.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: dirty.count) { i in
                let index = dirty[i]
                let rect = grid.rect(index % grid.tilesX, index / grid.tilesX)
                let level = writer.level(for: index)
                base[i] = ScreenWriter.compress(index: index, rect: rect,
                                                pixels: grid.extract(pixels, rect: rect),
                                                level: level)
            }
        }
        writer.addCompressTime(Date().timeIntervalSince(compressStart) * 1000)

        // Assembly stays serial: the escapes must reach the pty in a deterministic order.
        for case let tile? in packed {
            writer.emit(tile, sync: writer.perTileSync)
            writer.observe(index: tile.index, ratio: tile.ratio)
        }
        writer.endFrame()
    }

    // MARK: lifecycle

    private func installResizeHandler() {
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.handleResize() }
        }
        source.resume()
        resizeSource = source
    }

    private func handleResize() {
        guard let filter = self.filter, !cleanedUp else { return }
        let geometry = TermGeometry.read()
        applyLayout(geometry: geometry)
        guard let layout = currentGrid(), layout.pixelW > 8, layout.pixelH > 8 else { return }
        writer.clear()
        let capturer = self.capturer
        Task {
            await capturer.stop()
            try? await capturer.start(filter: filter, width: layout.pixelW, height: layout.pixelH, fps: options.fps)
        }
        if options.debug {
            Log.write("resize: \(layout.pixelW)x\(layout.pixelH) in \(layout.paneCols)x\(layout.paneRows) cells\n")
        }
    }

    private func installSignalCleanup() {
        for sig in [SIGTERM, SIGHUP, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in self?.shutdown() }
            source.resume()
            signalSources.append(source)
        }
    }

    private var signalSources: [DispatchSourceSignal] = []

    private func startStats() {
        let writer = self.writer
        let capturer = self.capturer
        let statsJSON = StatsJSONWriter(path: options.statsJSON)
        var lastBytes = 0
        var lastFrames = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let bytes = writer.totalBytes
            let frames = writer.framesEmitted
            let layout = self.currentGrid()
            let tiles = frames - lastFrames
            let mbps = Double(bytes - lastBytes) / 1_048_576.0
            let line = String(
                format: "stats: %d tiles/s  %d dirty  %d KB  %.2f MB/s  ms[zlib=%.0f write=%.0f max=%.0f over5=%d]  %dx%d px %dx%d cells  cap=%d/%d/%d idle=%d bad=%d pipe=%.1f\n",
                tiles,
                self.lastDirtyCount,
                writer.lastFrameBytes / 1024,
                mbps,
                writer.lastCompressMs, writer.lastWriteMs, writer.writeMaxMs, writer.writeOver5Ms,
                layout?.pixelW ?? 0, layout?.pixelH ?? 0,
                layout?.paneCols ?? 0, layout?.paneRows ?? 0,
                capturer.framesDelivered, capturer.framesSkipped, capturer.callbacks,
                capturer.idleFrames, capturer.badFrames,
                self.lastPipeMs
            )
            Log.write(line)
            statsJSON?.write(tiles: tiles, dirty: self.lastDirtyCount, kb: writer.lastFrameBytes / 1024,
                             mbps: mbps, zlibMs: writer.lastCompressMs, writeMs: writer.lastWriteMs,
                             writeMaxMs: writer.writeMaxMs, writeOver5: writer.writeOver5Ms,
                             px: (layout?.pixelW ?? 0, layout?.pixelH ?? 0),
                             cells: (layout?.paneCols ?? 0, layout?.paneRows ?? 0),
                             delivered: capturer.framesDelivered, skipped: capturer.framesSkipped,
                             callbacks: capturer.callbacks, idle: capturer.idleFrames,
                             bad: capturer.badFrames, pipeMs: self.lastPipeMs)
            writer.resetWriteStats()
            lastBytes = bytes
            lastFrames = frames
        }
        timer.resume()
        statsTimer = timer
    }

    func shutdown() {
        guard !cleanedUp else { return }
        cleanedUp = true
        input?.restore()
        writer.endSession()
        exit(0)
    }
}

enum DeskError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

// ScreenCaptureKit only behaves on this macOS build when an AppKit application
// context exists (verified: 1 frame without it, a full stream with it).
if ProcessInfo.processInfo.environment["KRD_NO_NSAPP"] == nil {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
}

let options = parseArguments()
// Hold the Desk in a variable: run() installs closures that capture it weakly, and a
// temporary would be a "weak reference will always be nil" trap.
let desk = Desk(options: options)
Task {
    do {
        try await desk.run()
    } catch {
        Log.write("krd: \(error)\n")
        exit(1)
    }
}
RunLoop.main.run()
