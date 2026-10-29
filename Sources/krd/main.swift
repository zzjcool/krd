import Foundation
import ApplicationServices
import AppKit
import CoreGraphics
import ScreenCaptureKit

struct Options {
    var fps = 20
    var displayIndex: Int? = nil
    var windowQuery: String? = nil
    /// How much the picture is magnified: 2 shows half of the source in each direction, at twice
    /// the density. 1 (the default) fits the whole source into the pane, as before.
    var zoom = 1.0
    /// Source point the zoom is centred on (`--zoom-at x,y`, global points); the pointer when unset.
    var zoomAt: CGPoint? = nil
    /// Pan the crop when the pointer reaches the edge of the picture (`--zoom-follow`).
    var zoomFollow = false
    var noInput = false
    /// How characters reach the mirrored Mac (issue #16). `auto` presses physical keys where the
    /// terminal reports one and injects text otherwise; `raw` never injects; `unicode` injects
    /// anything that is not plain ASCII.
    var ime: IMEMode = .auto
    /// Clipboard bridge (issue #18). Off by default: silently rewriting a machine's clipboard is a
    /// surprise, and the terminal-to-target half presses keys into the mirrored app.
    var clipboard: ClipboardPolicy = .off
    /// One-shot terminal-to-target paste from a file, for terminals that cannot answer an OSC 52
    /// read (the explicit, testable half of that direction).
    var clipboardPaste: String? = nil
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
      --zoom <f>          magnify: 2 shows half the source at twice the density, cropped on
                          the capture side, so a zoomed frame costs fewer pixels, not more
      --zoom-at <x,y>     source point the zoom is centred on (global points; default: pointer)
      --zoom-follow       pan the crop when the pointer reaches the edge of the picture
      --tile <c>x<r>      dirty-tile size in cells (default 8x4; 16x8 = fewer, bigger images)
      --format <f>        wire pixel format: rgb (default, f=24) or rgba (f=32)
      --cell <w>x<h>      cell size in px when the terminal does not report it (default 8x20)
      --log <path>        write diagnostics to a file instead of over the picture
      --full-frame        disable tiling, always resend the whole frame
      --ime <m>           how characters reach the target: auto (default), raw (physical keys
                          only, the target's IME composes), unicode (inject the character)
      --no-input          view only, do not inject events
      --clipboard <m>     clipboard bridge: off (default), in (target -> terminal via OSC 52),
                          out (Ctrl-V: terminal -> target), both
      --clipboard-paste <f>  put file <f> on the target pasteboard and post Cmd-V once
                          (for terminals that cannot answer an OSC 52 read)
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

    headless (text, no frames, no Screen Recording needed):
      ax windows          list on-screen windows as text
      ax tree --app <q>   accessibility tree of one window (--pid, --window, -d, -i, --all)
      ax screen           one line per window, plus the focused element
      ax doctor           check Accessibility and the window server, change nothing
                          (`krd ax --help` for the full surface and the exit codes)

    keys: Ctrl-\\ quits (Ctrl-C is forwarded to the remote desktop)
    """
}

/// `--ime <spec>`, or a usage error: a typo must not silently pick a mode.
func parseIMESpec(_ spec: String) -> IMEMode {
    guard let mode = IMEMode(spec: spec) else {
        FileHandle.standardError.write(
            Data("krd: --ime wants auto|raw|unicode, got \"\(spec)\"\n".utf8))
        exit(2)
    }
    return mode
}

/// `--clipboard <spec>`, or a usage error: a typo must not read as "off".
func parseClipboardSpec(_ spec: String) -> ClipboardPolicy {
    guard let policy = ClipboardPolicy(spec: spec) else {
        FileHandle.standardError.write(
            Data("krd: --clipboard wants off|in|out|both (in = target to terminal, out = terminal to target), got \"\(spec)\"\n".utf8))
        exit(2)
    }
    return policy
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
        case "--zoom":
            if let value = Double(args[safe: i + 1] ?? ""), value.isFinite { options.zoom = value }
            i += 1
        case "--zoom-at":
            if let spec = args[safe: i + 1], case let parts = spec.split(separator: ","), parts.count == 2,
               let x = Double(parts[0]), let y = Double(parts[1]), x.isFinite, y.isFinite {
                options.zoomAt = CGPoint(x: x, y: y)
            }
            i += 1
        case "--zoom-follow": options.zoomFollow = true
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
        case "--ime":
            options.ime = parseIMESpec(args[safe: i + 1] ?? "")
            i += 1
        case let arg where arg.hasPrefix("--ime="):
            options.ime = parseIMESpec(String(arg.dropFirst("--ime=".count)))
        case "--clipboard":
            options.clipboard = parseClipboardSpec(args[safe: i + 1] ?? "")
            i += 1
        case "--clipboard-paste":
            options.clipboardPaste = args[safe: i + 1]
            i += 1
        // The `--flag=value` spelling too: people type it, and a flag that silently does nothing
        // when typed the natural way is worse than a usage error.
        case let arg where arg.hasPrefix("--clipboard="):
            options.clipboard = parseClipboardSpec(String(arg.dropFirst("--clipboard=".count)))
        case let arg where arg.hasPrefix("--clipboard-paste="):
            options.clipboardPaste = String(arg.dropFirst("--clipboard-paste=".count))
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

/// The display reconfiguration callback: hand the event to the session and touch nothing else.
/// It runs *while* the display set is being reconfigured, so every real decision waits for the
/// debounce.
private let krdDisplayChanged: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
    guard let userInfo else { return }
    let desk = Unmanaged<Desk>.fromOpaque(userInfo).takeUnretainedValue()
    desk.noteScreenParametersChanged(removing: flags.contains(.removeFlag))
}

final class Desk {
    private let options: Options
    private let writer = ScreenWriter()
    private let capturer = Capturer()
    private var input: InputReader?
    private var cleanedUp = false

    private var filter: SCContentFilter?
    /// The whole source (display bounds or window frame) and the part of it on screen.
    private var fullRect: CGRect = .zero
    private var sourceRect: CGRect = .zero
    private var zoomFocus: CGPoint = .zero
    /// 1 for the synthetic paths (bench/selftest/replay), `--zoom` for a live capture.
    private var zoomScale = 1.0
    private var geometry: TermGeometry?
    private var captureRestarting = false
    private var restartPending = false
    private var followTimer: DispatchSourceTimer?
    /// The display this session is attached to, and how many existed when we last looked. Both
    /// are what "the display set changed" is measured against.
    private var trackedDisplayID: CGDirectDisplayID?
    private var displayCount = 0
    private var displayCallbackRegistered = false
    /// What the last poll saw, so a change is noticed exactly once.
    private var displayFingerprint: [DisplayBox] = []
    private var displayPollTimer: DispatchSourceTimer?
    private var displayDebounce = Debounce(window: 0.5)
    private var displayTimer: DispatchSourceTimer?
    /// A restart that failed is worth one line, not one per plug event.
    private var restartFailureReported = false
    /// The `--window` target: events go to this process instead of the window manager (issue #17).
    private var windowTarget: (pid: pid_t, id: CGWindowID, name: String)?
    /// Clipboard bridge (issue #18) and the 4 Hz timer that watches the target pasteboard.
    private var clipboard: ClipboardBridge?
    private var clipboardTimer: DispatchSourceTimer?

    private let stateLock = NSLock()
    private var grid: TileGrid?
    private var reportedFrameMismatch = false
    /// Set once the first delivered frame of a `--window` mirror has been looked at (issue #24).
    private var checkedFirstWindowFrame = false
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
            let geometry = benchGeometry()
            let source = options.source ?? (w: 1440, h: 2560)
            useLiteralSource(CGRect(x: 0, y: 0, width: source.w, height: source.h))
            applyLayout(geometry: geometry)
            guard let layout = currentGrid() else { throw DeskError.message("could not compute a tile layout") }
            Bench.runStages(layout: layout, writer: writer, rounds: options.rounds,
                            serial: !options.noSerial, source: sourceRect.size, json: options.benchJSON)
        }

        if let caseName = options.benchWire {
            let geometry = benchGeometry()
            let source = options.source ?? (w: 1440, h: 2560)
            useLiteralSource(CGRect(x: 0, y: 0, width: source.w, height: source.h))
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
            useLiteralSource(bounds)
            applyLayout(geometry: geometry)
            guard let layout = currentGrid() else { throw DeskError.message("could not compute a tile layout") }
            writer.beginSession()
            try await runSelfTest(layout: layout)
            return
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        if options.listOnly {
            var text = ""
            // `content.displays` can be empty while windows are listed (macOS 26 without a
            // display-capture grant), so fall back to CoreGraphics for recognition. The index is
            // only printed when it really is the one `--display` expects.
            let shareable = content.displays.map { CGDisplayBounds($0.displayID) }
            let displayBounds = shareable.isEmpty ? WindowPick.displayBounds() : shareable
            for (index, display) in content.displays.enumerated() {
                let bounds = displayBounds[index]
                text += "[\(index)] display \(display.displayID)  \(Int(bounds.width))x\(Int(bounds.height)) pt\n"
            }
            for window in content.windows where window.frame.width > 60 {
                let app = window.owningApplication?.applicationName ?? "?"
                var line = "    window \(window.windowID)  @\(Int(window.frame.minX)),\(Int(window.frame.minY)) \(Int(window.frame.width))x\(Int(window.frame.height))  app=\(app)  title=\(window.title ?? "-")"
                // Say it here, before somebody picks it: a backdrop window captures as a black
                // frame, which looks like krd being broken (issue #24).
                if let covered = WindowPick.backdrop(layer: window.windowLayer, frame: window.frame,
                                                     displays: displayBounds) {
                    if let index = shareable.firstIndex(of: covered) {
                        line += "  (backdrop — use --display \(index))"
                    } else {
                        line += "  (backdrop — use --display <n>)"
                    }
                }
                text += line + "\n"
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

        let target = try await makeCaptureTarget(using: content)
        let filter = target.filter
        let sourceRect = target.rect
        trackedDisplayID = target.displayID
        displayCount = target.displayCount
        if let windowTarget = target.window { self.windowTarget = windowTarget }
        if options.debug {
            // Always said, not only when it fell back: `--display 1` on a one-display Mac is a
            // surprise worth one line even though nothing went wrong.
            Log.write("krd: capturing \(target.reason)\n")
        }

        self.filter = filter
        self.geometry = geometry
        zoomScale = options.zoom > 1 ? options.zoom : 1
        configureSource(rect: sourceRect)
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
                                                          source: (Int(currentCrop().width), Int(currentCrop().height)),
                                                          format: writer.format == .rgb ? "rgb" : "rgba"))
            if recorder == nil {
                Log.write("record: could not write to \(dir)\n")
            }
        }

        writer.beginSession()
        installSignalCleanup()
        installResizeHandler()
        installDisplayChangeHandler()
        if options.debug || options.statsJSON != nil { startStats() }

        try await capturer.start(filter: filter, sourceRect: cropForFilter(),
                                 width: layout.pixelW, height: layout.pixelH, fps: options.fps)

        if !options.noInput {
            let reader = InputReader(viewport: { [weak self] in self?.currentViewport() ?? Viewport(pixelWidth: 1, pixelHeight: 1, cols: 1, rows: 1, sourceRect: .zero) },
                                     dryRun: options.dryRun) { [weak self] in self?.shutdown() }
            reader.trace = options.debug
            reader.ime = options.ime
            if options.debug {
                Log.write("krd: ime \(options.ime.rawValue) (auto = keys where the terminal reports them, "
                          + "raw = keys only, unicode = inject the character)\n")
            }
            if let target = windowTarget {
                reader.targetPid = { [weak self] in self?.aliveWindowPid() }
                if options.debug {
                    Log.write("krd: window mode — events go to pid \(target.pid) (\(target.name)), "
                              + "window \(target.id); a closed window falls back to global injection\n")
                }
            }
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

        // Clipboard bridge (issue #18). `--no-input` keeps the target-to-terminal half only: the
        // other half presses keys into the mirrored machine, so it is dropped rather than trusted.
        let clipboardPolicy = options.clipboard.allowing(noInput: options.noInput)
        if options.clipboardPaste != nil, options.noInput {
            throw DeskError.message("--clipboard-paste needs input: it posts Cmd-V. Drop --no-input, "
                                    + "or use --clipboard=in to only read the target's clipboard")
        }
        if !clipboardPolicy.isOff || options.clipboardPaste != nil {
            let bridge = ClipboardBridge(policy: clipboardPolicy)
            clipboard = bridge
            input?.clipboard = clipboardPolicy
            input?.onClipboardFromTerminal = { [weak self] text in
                guard let self, let bridge = self.clipboard else { return }
                guard let bytes = bridge.setTarget(text) else {
                    Log.write("krd: clipboard: \(text.utf8.count) B from the terminal dropped "
                              + "(limit \(OSC52.maxBytes) B)\n")
                    return
                }
                self.input?.postPasteCommand()
                if self.options.debug {
                    Log.write("clipboard: \(bytes) B terminal -> target, Cmd-V posted\n")
                }
            }
            if options.debug {
                Log.write("krd: clipboard \(clipboardPolicy) (target -> terminal: "
                          + "\(clipboardPolicy.toTerminal), Ctrl-V terminal -> target: "
                          + "\(clipboardPolicy.toTarget))\n")
            }
        }
        if clipboardPolicy.toTerminal {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
            timer.setEventHandler { [weak self] in
                guard let self, let line = self.clipboard?.poll() else { return }
                if self.options.debug { Log.write(line + "\n") }
            }
            timer.resume()
            clipboardTimer = timer
        }
        if let path = options.clipboardPaste {
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            if text.isEmpty {
                Log.write("krd: --clipboard-paste \(path): no UTF-8 text read\n")
            } else if let bytes = clipboard?.setTarget(text) {
                input?.postPasteCommand()
                if options.debug {
                    Log.write("clipboard: \(bytes) B \(path) -> target, Cmd-V posted\n")
                }
            } else {
                Log.write("krd: --clipboard-paste \(path): \(text.utf8.count) B is over the "
                          + "\(OSC52.maxBytes) B limit\n")
            }
        }

        startFollow()
        if options.debug {
            let cell = geometry.cellSize
            let crop = currentCrop()
            let message = "krd: pane \(geometry.cols)x\(geometry.rows) cells, cell \(cell.w)x\(cell.h) px\n"
                + "krd: source \(Int(crop.width))x\(Int(crop.height)) pt"
                + (zoomScale > 1
                   ? " (zoom \(zoomScale) of \(Int(fullRect.width))x\(Int(fullRect.height)) centred \(Int(crop.midX)),\(Int(crop.midY)))"
                   : "")
                + " -> \(layout.pixelW)x\(layout.pixelH) px in \(layout.paneCols)x\(layout.paneRows) cells, "
                + "\(layout.tilesX)x\(layout.tilesY) tiles of \(layout.tileCols)x\(layout.tileRows) cells\n"
            Log.write(message)
        }

        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: capture target

    struct CaptureTarget {
        var filter: SCContentFilter
        /// The whole source: display bounds, or the window frame.
        var rect: CGRect
        var displayID: CGDirectDisplayID?
        var displayCount: Int
        /// One sentence for `--debug`, from `DisplayPick`.
        var reason: String
        var fellBack: Bool
        var window: (pid: pid_t, id: CGWindowID, name: String)?
    }

    /// Build what the stream should capture. Startup and every display-set change go through
    /// this one function, so "which display, and why" has exactly one implementation.
    private func makeCaptureTarget(using content: SCShareableContent? = nil) async throws -> CaptureTarget {
        let shareable: SCShareableContent
        if let given = content {
            shareable = given
        } else {
            shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }

        if let query = options.windowQuery {
            let match = shareable.windows.first { window in
                guard window.frame.width > 40, window.frame.height > 40 else { return false }
                if let id = Int(query) { return window.windowID == id }
                return (window.title ?? "").localizedCaseInsensitiveContains(query)
            }
            guard let window = match else {
                throw DeskError.message("no window matched \"\(query)\" (try --list)")
            }
            // `shareable.displays` can be empty while windows are listed (macOS 26 without a
            // display-capture grant), so fall back to CoreGraphics for recognition. The index is
            // only printed when it really is the one `--display` expects.
            let displayRects = shareable.displays.map { CGDisplayBounds($0.displayID) }
            let displayBounds = displayRects.isEmpty ? WindowPick.displayBounds() : displayRects
            if let covered = WindowPick.backdrop(layer: window.windowLayer, frame: window.frame,
                                                 displays: displayBounds) {
                // Refusing beats painting black with exit status 0: the user asked for a window and
                // the desktop layer is not one (issue #24).
                let owner = window.owningApplication?.applicationName ?? "no owning app"
                let advice = displayRects.firstIndex(of: covered).map { "krd --display \($0)" }
                    ?? "krd --display <n>  (see --list for the indices)"
                throw DeskError.message(
                    "window \(window.windowID) (\(owner), title \"\(window.title ?? "")\", layer \(window.windowLayer)) "
                    + "is the desktop backdrop, not a window — ScreenCaptureKit hands back the bare\n"
                    + "         layer, which composites to black. Mirror the whole screen instead: \(advice)")
            }
            var windowTarget: (pid: pid_t, id: CGWindowID, name: String)?
            if let app = window.owningApplication, app.processID > 0 {
                windowTarget = (app.processID, window.windowID, app.applicationName)
            }
            return CaptureTarget(filter: SCContentFilter(desktopIndependentWindow: window),
                                 rect: window.frame, displayID: nil,
                                 displayCount: shareable.displays.count,
                                 reason: "window \(window.windowID) moved to \(Int(window.frame.minX)),"
                                     + "\(Int(window.frame.minY)) \(Int(window.frame.width))x\(Int(window.frame.height))",
                                 fellBack: false, window: windowTarget)
        }

        let boxes = shareable.displays.map { DisplayBox(id: $0.displayID, bounds: CGDisplayBounds($0.displayID)) }
        guard let choice = DisplayPick.choose(requested: options.displayIndex,
                                              tracked: trackedDisplayID,
                                              displays: boxes,
                                              pointer: CGEvent(source: nil)?.location ?? .zero,
                                              main: CGMainDisplayID()),
              let display = shareable.displays.first(where: { $0.displayID == choice.display.id }) else {
            throw DeskError.message("no displays available (ScreenCaptureKit reported \(boxes.count))")
        }
        return CaptureTarget(filter: SCContentFilter(display: display, excludingWindows: []),
                             rect: choice.display.bounds, displayID: display.displayID,
                             displayCount: boxes.count, reason: choice.reason, fellBack: choice.fellBack)
    }

    // MARK: display-set changes

    /// Plug/unplug, mirroring, a resolution change and closing the lid all arrive here.
    ///
    /// The notification needs the AppKit context `run()` already has, and it fires two or three
    /// times for one physical event, so the work is debounced (see `Debounce`).
    /// The display set as CoreGraphics sees it right now. Cheap and synchronous, unlike
    /// ScreenCaptureKit's enumeration, which is only worth doing once something changed.
    private func liveDisplayFingerprint() -> [DisplayBox] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { DisplayBox(id: $0, bounds: CGDisplayBounds($0)) }
    }

    private func pollDisplays() {
        guard !cleanedUp, filter != nil else { return }
        let now = liveDisplayFingerprint()
        guard !now.isEmpty, DisplaySet.differs(now, displayFingerprint) else { return }
        let removed = now.count < displayFingerprint.count
        displayFingerprint = now
        noteScreenParametersChanged(removing: removed)
    }

    /// Called on the window server's thread for every display reconfiguration. A top-level
    /// function pointer because `CGDisplayRemoveReconfigurationCallback` only unregisters the
    /// exact pointer that was registered.
    private func installDisplayChangeHandler() {
        // `NSApplication.didChangeScreenParametersNotification` is delivered by NSApp's own run
        // loop, and krd never runs one (the main loop is async: `while true { await sleep }`).
        // Measured on macOS 26: a probe that calls NSApp.run() gets three notifications per
        // resolution change, krd gets none -- with `queue: .main` *or* `queue: nil`. The
        // CoreGraphics reconfiguration callback is the one that does not need a run loop.
        CGDisplayRegisterReconfigurationCallback(krdDisplayChanged, Unmanaged.passUnretained(self).toOpaque())
        displayCallbackRegistered = true
        // The backstop for sessions that get no callback at all (see DisplaySet): one cheap
        // read a second, and only a *changed* fingerprint starts the debounce.
        displayFingerprint = liveDisplayFingerprint()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.pollDisplays() }
        timer.resume()
        displayPollTimer = timer
    }

    /// Called on the window server's thread for every display reconfiguration.
    fileprivate func noteScreenParametersChanged(removing: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.cleanedUp else { return }
            if self.options.debug, removing {
                Log.write("krd: a display went away\n")
            }
            self.displayDebounce.note(Date())
            self.displayTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + self.displayDebounce.window)
            timer.setEventHandler { [weak self] in
                guard let self, !self.cleanedUp, self.displayDebounce.isCurrent(at: Date()) else { return }
                self.displayDebounce.reset()
                self.reconcileCaptureTarget()
            }
            timer.resume()
            self.displayTimer = timer
        }
    }

    /// One coalesced display-set change: rebuild the filter, keep the zoom honest, recompute the
    /// layout, clear, restart. Same sequence as a terminal resize, through the same restart path
    /// (so a zoom pan and a display change cannot restart the stream at the same time).
    private func reconcileCaptureTarget() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let target = try await self.makeCaptureTarget()
                let displayMoved = target.displayID != self.trackedDisplayID
                    || target.displayCount != self.displayCount
                let frameMoved = target.rect != self.fullRect
                guard displayMoved || frameMoved else { return }
                let previousCount = self.displayCount
                self.filter = target.filter
                self.trackedDisplayID = target.displayID
                self.displayCount = target.displayCount
                if let window = target.window { self.windowTarget = window }
                self.configureSource(rect: target.rect)
                if let geometry = self.geometry { self.applyLayout(geometry: geometry) }
                self.writer.clear()
                Log.write("krd: capture restarted (\(target.displayCount) display(s), was \(previousCount)): "
                    + "\(target.reason)\n")
                if self.options.debug, let layout = self.currentGrid() {
                    let crop = self.currentCrop()
                    Log.write("krd:   source \(Int(crop.width))x\(Int(crop.height)) pt"
                        + (self.zoomScale > 1 ? " (zoom \(self.zoomScale))" : "")
                        + " -> \(layout.pixelW)x\(layout.pixelH) px in \(layout.paneCols)x\(layout.paneRows) cells\n")
                }
                self.restartCapture(reason: "a display-set change")
            } catch {
                self.warnRestartOnce("krd: could not follow the display change (\(error)); "
                    + "the last frame stays on screen\n")
            }
        }
    }

    /// One line per session for capture restarts that keep failing, not one per plug event.
    private func warnRestartOnce(_ message: String) {
        guard !restartFailureReported else { return }
        restartFailureReported = true
        Log.write(message)
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
        useLiteralSource(CGRect(x: 0, y: 0, width: header.source.w, height: header.source.h))
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

    /// Geometry for the bench modes, built from the flags only.
    ///
    /// It deliberately does not read the tty. `TermGeometry.read()` prefers the terminal's
    /// own pixel report, so `--pane 137x44` plus a 2400x1290 window silently became a
    /// 118x44 / 2067x1290 picture and `--cell 17x33` was ignored -- which made the numbers
    /// depend on how big the terminal window happened to be, and made the case assertions
    /// (`one character` must dirty exactly one tile) fail for reasons that had nothing to
    /// do with the encoder. A benchmark has to measure the same picture everywhere.
    private func benchGeometry() -> TermGeometry {
        if let cell = options.cell { TermGeometry.fallbackCell = cell }
        var geometry = TermGeometry(cols: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)
        if let pane = options.pane { geometry.cols = pane.cols; geometry.rows = pane.rows }
        return geometry
    }

    /// The synthetic paths (bench, selftest, replay) define their own source rect and must
    /// reproduce a recorded layout exactly, so they never zoom.
    private func useLiteralSource(_ rect: CGRect) {
        fullRect = rect
        sourceRect = rect
        zoomFocus = CGPoint(x: rect.midX, y: rect.midY)
        zoomScale = 1
    }

    /// Remember the whole source and where the zoom looks.
    private func configureSource(rect: CGRect) {
        fullRect = rect
        let pointer = CGEvent(source: nil)?.location ?? .zero
        if let at = options.zoomAt {
            zoomFocus = at
        } else if rect.contains(pointer) {
            zoomFocus = pointer          // "zoom where I am looking" is the useful default
        } else {
            zoomFocus = CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    private func currentCrop() -> CGRect {
        stateLock.lock(); defer { stateLock.unlock() }
        return sourceRect
    }

    /// ScreenCaptureKit wants the crop relative to the filter's content: the window frame for a
    /// window filter, the display for a display filter. A full-frame capture sends nil so the
    /// terminal keeps getting exactly what it got before zoom existed.
    private func cropForFilter() -> CGRect? {
        let crop = currentCrop()
        guard crop.width < fullRect.width - 0.5 || crop.height < fullRect.height - 0.5 else { return nil }
        // Builds differ on whether a display filter wants global points; KRD_ZOOM_GLOBAL_RECT=1
        // is the escape hatch when a crop on a secondary display lands somewhere else.
        let global = ProcessInfo.processInfo.environment["KRD_ZOOM_GLOBAL_RECT"] != nil
        let origin = global ? crop.origin : CGPoint(x: crop.minX - fullRect.minX, y: crop.minY - fullRect.minY)
        return CGRect(origin: origin, size: crop.size)
    }

    private func applyLayout(geometry: TermGeometry) {
        let crop = Viewport.crop(full: fullRect, scale: zoomScale, focus: zoomFocus)
        let aspect = crop.width / max(crop.height, 1)
        let layout = TileGrid.make(geometry: geometry, aspect: aspect,
                                   tileCols: options.tileCols, tileRows: options.tileRows,
                                   bpp: writer.format.bytesPerPixel)
        stateLock.lock()
        grid = layout
        sourceRect = crop
        previousFrame = []
        viewport = Viewport(pixelWidth: layout.pixelW, pixelHeight: layout.pixelH,
                            cols: layout.paneCols, rows: layout.paneRows, sourceRect: crop)
        stateLock.unlock()
    }

    // MARK: zoom follow

    private func startFollow() {
        guard options.zoomFollow, zoomScale > 1, followTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.followPointerIfNeeded() }
        timer.resume()
        followTimer = timer
    }

    /// Pan, do not chase: the crop moves only when the pointer is inside the outer 15 % band, and
    /// then only far enough to put it back on that edge. Restarting the stream is the price of
    /// cropping on the capture side (a CPU crop would trade the bandwidth win for it).
    private func followPointerIfNeeded() {
        guard !cleanedUp, !captureRestarting, let geometry,
              let pointer = CGEvent(source: nil)?.location else { return }
        let crop = currentCrop()
        guard crop.width > 1, crop.height > 1,
              crop.width < fullRect.width - 0.5 || crop.height < fullRect.height - 0.5 else { return }
        let marginX = crop.width * 0.15, marginY = crop.height * 0.15
        var dx = 0.0, dy = 0.0
        if pointer.x < crop.minX + marginX { dx = pointer.x - (crop.minX + marginX) }
        if pointer.x > crop.maxX - marginX { dx = pointer.x - (crop.maxX - marginX) }
        if pointer.y < crop.minY + marginY { dy = pointer.y - (crop.minY + marginY) }
        if pointer.y > crop.maxY - marginY { dy = pointer.y - (crop.maxY - marginY) }
        guard dx != 0 || dy != 0 else { return }
        zoomFocus = CGPoint(x: crop.midX + dx, y: crop.midY + dy)
        applyLayout(geometry: geometry)
        restartCapture()
    }

    /// Restart the stream against the current filter and layout.
    ///
    /// One path for both triggers: a terminal resize and a display-set change (and the zoom
    /// follow, which is the same operation with a different reason). `captureRestarting` keeps
    /// two of them from starting a stream at the same time; the loser is queued, not dropped.
    private func restartCapture(reason: String = "a zoom pan") {
        guard let filter, let layout = currentGrid(), !cleanedUp else { return }
        if captureRestarting { restartPending = true; return }
        captureRestarting = true
        let crop = cropForFilter()
        Task { [weak self] in
            guard let self else { return }
            await self.capturer.stop()
            do {
                try await self.capturer.start(filter: filter, sourceRect: crop,
                                              width: layout.pixelW, height: layout.pixelH,
                                              fps: self.options.fps)
            } catch {
                self.warnRestartOnce("krd: could not restart capture after \(reason): \(error); "
                    + "the last frame stays on screen\n")
            }
            self.captureRestarting = false
            if self.restartPending {
                self.restartPending = false
                self.restartCapture()
            }
        }
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

    /// The pid events should be posted to, or nil once the target is gone.
    ///
    /// Two things can happen to a `--window` target: the app quits (pid gone) or the window closes
    /// while the app keeps running (pid alive, window gone — clicks would land on another window of
    /// that app or nowhere). Both downgrade to global injection, which the reader logs once.
    /// The window query is one entry, human-paced: a drag is tens of events per second, not thousands.
    private func aliveWindowPid() -> pid_t? {
        guard let target = windowTarget else { return nil }
        guard kill(target.pid, 0) == 0 else { return nil }
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], target.id) as? [[String: Any]]
        guard let info, !info.isEmpty else { return nil }
        return target.pid
    }

    private func handleFrame(pixels: [UInt8], width: Int, height: Int) {
        let started = benchNowMs()

        // A window mirror whose very first frame is essentially all black is almost certainly a
        // compositing layer that slipped past the layer test, not an app (issue #24). One line,
        // only with --debug: stderr lands on the picture, so this must not be a default path (§31).
        if options.debug, options.windowQuery != nil, !checkedFirstWindowFrame {
            checkedFirstWindowFrame = true
            let bpp = max(1, writer.format.bytesPerPixel)
            var black = 0, sampled = 0
            var i = 0
            while i + 2 < pixels.count {
                if pixels[i] == 0, pixels[i + 1] == 0, pixels[i + 2] == 0 { black += 1 }
                sampled += 1
                i += bpp * 17
            }
            if sampled > 0, Double(black) / Double(sampled) > 0.99 {
                Log.write("krd: the first frame of this window is 99%+ black — that window is probably "
                          + "a compositing layer (desktop/backdrop), not an app.\n"
                          + "         --list now marks those entries; mirror the screen with --display <n>\n")
            }
        }

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
        guard filter != nil, !cleanedUp else { return }
        let geometry = TermGeometry.read()
        applyLayout(geometry: geometry)
        guard let layout = currentGrid(), layout.pixelW > 8, layout.pixelH > 8 else { return }
        writer.clear()
        // Same path as a display change: one place decides whether a stream is already
        // starting, so a resize during a plug event queues instead of racing it.
        restartCapture(reason: "a terminal resize")
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
        followTimer?.cancel()
        clipboardTimer?.cancel()
        displayTimer?.cancel()
        displayPollTimer?.cancel()
        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(krdDisplayChanged, Unmanaged.passUnretained(self).toOpaque())
            displayCallbackRegistered = false
        }
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

// The headless face: `krd ax …` reads the accessibility tree and exits. It is dispatched
// before anything else so it never starts the AppKit context, the capture stream or the
// terminal modes -- it must stay usable from a plain, non-interactive ssh command.
if AXCommand.isInvocation(Array(CommandLine.arguments.dropFirst())) {
    AXCommand.run(Array(CommandLine.arguments.dropFirst(2)))
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
