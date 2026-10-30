import Foundation
import ApplicationServices
import AppKit
import CoreGraphics
import ScreenCaptureKit
import krdcore

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
    /// Capture at a fraction of the pane's pixels (`--scale 0.5`): a quarter of the bytes for half
    /// the resolution in each direction, upscaled by the terminal into the same cell box. It changes
    /// the *output* size only -- the crop (`sourceRect`) and the input mapping stay as they are.
    var scale = 1.0
    var scaleError: String? = nil
    var noInput = false
    var noQuantise = false
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
    /// Paint the pointer into the mirrored picture (see `Capturer.showsCursor`).
    ///
    /// Hidden by default: the pane already follows the local pointer, so a second pointer drawn
    /// into the picture is redundant, and every mouse move would otherwise dirty the tiles under
    /// it — a moving mouse used to be a per-frame resend. `--cursor` brings it back for the cases
    /// where the target pointer is *not* the local one (`--window` on an idle app, a recording, or
    /// a screen someone else is driving).
    var drawsCursor = false
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
    /// The TUI layer: a status line plus panels on the rows the picture does not use.
    var dev = false
    /// Force the layer off, even with `--dev` (scripts, CI, `--bench`).
    var noChrome = false
    /// Open a panel at startup, for screenshots and for `--dev --selftest` without input.
    var devPanel: String? = nil
    /// Replace ScreenCaptureKit with a desktop drawn in process. No permission, runs forever.
    var mock = false
    var mockSize: (w: Int, h: Int)? = nil
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
      --scale <f>         capture f (0 < f <= 1) of the pane's pixels per side and let the terminal
                          upscale: 0.5 is a quarter of the bytes and visibly softer text (issue #60)
      --full-frame        disable tiling, always resend the whole frame
      --ime <m>           how characters reach the target: auto (default), raw (physical keys
                          only, the target's IME composes), unicode (inject the character)
      --no-input          view only, do not inject events
      --no-quantise       never drop colour precision (default: incompressible tiles go 5-6-5)
      --clipboard <m>     clipboard bridge: off (default), in (target -> terminal via OSC 52),
                          out (Ctrl-V: terminal -> target), both
      --clipboard-paste <f>  put file <f> on the target pasteboard and post Cmd-V once
                          (for terminals that cannot answer an OSC 52 read)
      --cursor            draw the pointer into the picture (default: hidden — the pane already
                          follows the local pointer, and a drawn one dirties tiles as the mouse
                          moves; --no-cursor is still accepted and means the same as the default)
      --dry-run           parse input but only log it, never post CGEvent
      --debug             geometry + per-second stats on stderr
      --dev               TUI layer: status line + panels (stats, devices, settings, log, help)
      --no-chrome         force the TUI layer off, e.g. for scripts
      --dev-panel <name>  with --dev: open stats|devices|settings|log|help at startup
      --mock              draw the desktop in process: no screen, no permission, runs forever
      --mock-size WxH     size of the generated desktop (default 1920x1200)
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
        case "--scale":
            // The parser does not throw; an unparsable value is carried to `run()` instead of
            // silently meaning "1", because a typo here doubles the bytes on the wire.
            if let value = Double(args[safe: i + 1] ?? ""), value.isFinite, value > 0, value <= 1 {
                options.scale = value
            } else {
                options.scaleError = "--scale takes a fraction of the pane's pixels, "
                    + "0 < scale <= 1 (e.g. 0.5); got \(args[safe: i + 1] ?? "nothing")"
            }
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
        case "--no-quantise": options.noQuantise = true
        case "--cursor": options.drawsCursor = true
        case "--no-cursor": options.drawsCursor = false
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
        case "--dev": options.dev = true
        case "--dev-panel": options.devPanel = args[safe: i + 1]; i += 1
        case "--mock": options.mock = true
        case "--mock-size":
            let spec = args[safe: i + 1] ?? ""
            i += 1
            let parts = spec.split(separator: "x").compactMap { Int($0) }
            if parts.count == 2, parts[0] > 8, parts[1] > 8 { options.mockSize = (parts[0], parts[1]) }
        case "--no-chrome": options.noChrome = true
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

private extension Error {
    /// One line for the log: `SCStream -3805: Failed during stream ...`, without the NSError dump.
    var short: String {
        let ns = self as NSError
        let domain = ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" ? "SCStream" : ns.domain
        let text = ns.localizedDescription.replacingOccurrences(of: "\n", with: " ")
        return "\(domain) \(ns.code): \(text)"
    }
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
    /// Consecutive `didStopWithError` recoveries that have not produced a frame yet. Bounded, so a
    /// dead window server cannot turn the retry loop into a hot loop.
    private var streamStopAttempts = 0
    private var streamStopTimer: DispatchSourceTimer?
    /// Last `callbacks` count and when it last moved: a stream that stops delivering frames
    /// without calling `didStopWithError` is the failure this catches (issue #44).
    private var frameWatchdog: DispatchSourceTimer?
    /// Serialises in-place pans: `updateConfiguration` calls must not overlap, and a pan that
    /// arrives while one is in flight is folded into the next.
    private var panInFlight = false
    private var panPending = false
    /// The reason carried over to a restart that had to queue behind another one.
    private var pendingRestartReason: String?
    private var lastSeenCallbacks = 0
    private var lastFrameAt = Date()
    /// Set when krd asks the stream for a frame (a pan, a restart): the frame is then *owed*.
    private var expectFrameBy: Date?
    /// How long a frame we asked for may take. The probe measured p50 42 ms, max 67 ms end to end.
    private let FRAME_TIMEOUT: Double = 3
    /// When the in-flight restart started, so a restart that never returns cannot gate the
    /// watchdog forever (see `Capturer.stop`).
    private var restartStartedAt = Date()
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
    /// Frames that reached the encoder, not tiles: the number a human means by "fps".
    private var framesHandled = 0
    private var chromeSampleFrames = 0
    private var chromeSampleDelivered = 0

    private var resizeSource: DispatchSourceSignal?
    private var statsTimer: DispatchSourceTimer?
    // TUI layer (--dev). Everything below is written on the main queue at 1 Hz; the picture
    // never waits for it and the writer serializes the two.
    private let chrome = Chrome()
    private var chromeState = ChromeState()
    private var chromeMetrics = ChromeMetrics()
    private var chromeGeometry: ChromeGeometry?
    private var chromeTimer: DispatchSourceTimer?
    private var chromeDirty = true
    private var chromeSampleBytes = 0
    private var chromeSampleQueue = 0
    private var chromeSampleTiles = 0
    private var chromeSampleTime = Date()
    private var chromeToastUntil = Date()
    private var pipeSamples: [Double] = []
    private var targetLabel = "-"
    private var shareable: SCShareableContent?
    private var mock: MockDesktop?
    private var geometrySource = "-"

    private var chromeEnabled: Bool { options.dev && !options.noChrome }
    /// Wall time from capture callback to last byte out, per frame.
    private(set) var lastPipeMs = 0.0
    private var recorder: FrameRecorder?

    init(options: Options) {
        self.options = options
        if let name = options.devPanel, let panel = ChromePanel(rawValue: name) {
            chromeState.panel = panel
        }
        if let format = options.pixelFormat { writer.format = format }
        capturer.format = writer.format
        capturer.showsCursor = options.drawsCursor
        writer.resize(tiles: 0)
    }

    func run() async throws {
        // Before any branch: --bench, --selftest and the live path all go through this writer.
        writer.quantiseEnabled = !options.noQuantise
        // Diagnostics never go over the picture: they land in a file instead.
        // `--stats-json` implies stats, and stats must never land on the tty: without an
        // explicit destination they go to a temp file like `--debug` does.
        Log.configure(explicitPath: options.logPath,
                      wantsLogging: options.debug || options.logPath != nil || options.statsJSON != nil)
        if let where_ = Log.path {
            FileHandle.standardError.write(Data("krd: logging to \(where_)\n".utf8))
        }
        if let error = options.scaleError { throw DeskError.message(error) }
        // The selftest is a byte contract about framing, not about resolution: it always captures
        // at the pane's own pixel size, so `--scale` next to it is a usage error rather than a
        // silent change of the sha256 people compare against.
        if options.selftest && options.scale != 1 {
            throw DeskError.message("--selftest always captures at scale 1; drop --scale")
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
            targetLabel = "selftest"
            geometrySource = options.pane != nil ? "pane override" : "tty"
            if let cell = options.cell { TermGeometry.fallbackCell = cell }
            var geometry = TermGeometry.read()
            if let pane = options.pane { geometry.cols = pane.cols; geometry.rows = pane.rows }
            let bounds = CGRect(x: 0, y: 0, width: 1440, height: 2560)
            self.filter = nil
            useLiteralSource(bounds)
            applyLayout(geometry: geometry)
            guard let layout = currentGrid() else { throw DeskError.message("could not compute a tile layout") }
            writer.beginSession()
            startChrome()          // --dev --selftest is how the layer is tested without a screen
            try await runSelfTest(layout: layout)
            return
        }

        if options.mock {
            if let cell = options.cell { TermGeometry.fallbackCell = cell }
            let queried = TermGeometry.query()
            var geometry = queried ?? TermGeometry.read()
            // --pane is how a dev tool reproduces "it looks wrong at 137x60" without a 137x60 pane.
            if let pane = options.pane {
                geometry.cols = pane.cols
                geometry.rows = pane.rows
            }
            geometrySource = (queried != nil ? TermGeometry.lastAnswer.label
                                             : (options.cell != nil ? "--cell" : "TIOCGWINSZ")) + " · mock"
            // Nothing below this line is mocked: same tiles, same encoder, same placements, same
            // chrome. Only the pixel source is different, which is why this needs no permission.
            let size = options.mockSize ?? (w: 1920, h: 1200)
            useLiteralSource(CGRect(x: 0, y: 0, width: size.w, height: size.h))
            targetLabel = "mock \(size.w)×\(size.h)"
            self.filter = nil
            applyLayout(geometry: geometry)
            guard let layout = currentGrid() else {
                throw DeskError.message("could not compute a tile layout")
            }
            writer.beginSession()
            startChrome()
            installSignalCleanup()
            installResizeHandler()
            if options.debug || options.statsJSON != nil { startStats() }
            startInput()
            let mock = MockDesktop(width: layout.pixelW, height: layout.pixelH, bpp: layout.bpp,
                                   fps: options.fps) { [weak self] pixels, width, height in
                self?.handleFrame(pixels: pixels, width: width, height: height)
            }
            self.mock = mock
            mock.start()
            Log.write("krd: mock \(layout.pixelW)x\(layout.pixelH) px @\(options.fps) fps, "
                      + "\(layout.tilesX)x\(layout.tilesY) tiles, no capture\n")
            while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
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
        let queried = TermGeometry.query()
        let geometry = queried ?? TermGeometry.read()
        geometrySource = queried != nil
            ? TermGeometry.lastAnswer.label
            : (options.cell != nil ? "--cell" : "TIOCGWINSZ")
        if options.debug {
            // Which question the terminal answered, in the log: a picture sized from the window
            // measurement (or from a constant) is otherwise indistinguishable from a measured one.
            Log.write("krd: geometry source \(geometrySource)\n")
        }
        if geometry.pixelWidth == 0 || geometry.pixelHeight == 0 {
            // Spell out the consequence (issue #56): the picture is merely soft and the exit code is
            // 0, so "assuming a cell size" on its own is a line nobody can act on.
            let w = Int(TermGeometry.fallbackCell.w), h = Int(TermGeometry.fallbackCell.h)
            Log.write(
                "krd: terminal reports no pixel size; assuming a \(w)x\(h) px cell -> the image will be "
                + "\(geometry.cols * w)x\(geometry.rows * h) for a \(geometry.cols)x\(geometry.rows) pane; "
                + "pass --cell <w>x<h> if that is wrong\n")
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
        self.shareable = content
        targetLabel = target.reason
        applyLayout(geometry: geometry)
        guard let layout = currentGrid() else { throw DeskError.message("could not compute a tile layout") }

        let writer = self.writer
        // A stream that stops by itself is not fatal and must not be silent: restart it, at most
        // 5 times with backoff, and say so in the log each time.
        capturer.onStreamStopped = { [weak self] error in
            DispatchQueue.main.async { self?.recoverFromStoppedStream(error) }
        }
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
        startChrome()
        installSignalCleanup()
        installResizeHandler()
        installDisplayChangeHandler()
        if options.debug || options.statsJSON != nil { startStats() }

        try await capturer.start(filter: filter, sourceRect: cropForFilter(),
                                 width: layout.pixelW, height: layout.pixelH, fps: options.fps)

        startInput()

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
        startFrameWatchdog()
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
                + " -> \(layout.pixelW)x\(layout.pixelH) px in \(layout.paneCols)x\(layout.paneRows) cells"
                + (options.scale < 1 ? " (scale \(options.scale))" : "")
                + ", \(layout.tilesX)x\(layout.tilesY) tiles of \(layout.tileCols)x\(layout.tileRows) cells\n"
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

    /// Two different kinds of silence, and only one of them is a failure.
    ///
    /// **Expected frame.** When krd asks the stream for something -- a pan (`updateSource`), a
    /// restart -- a frame is owed. If none arrives within `FRAME_TIMEOUT`, the stream is not doing
    /// what it was told: restart it. This is precise, because krd knows what it asked for.
    ///
    /// **Long silence.** "No frames at all" looks like a dead stream, and in the #44 soak it was
    /// (after `-3805` the replacement stream went quiet). But on a still desktop ScreenCaptureKit
    /// sends *nothing*: measured with `probe/zoom_update_probe.swift` on macOS 26.6, 0 frames in a
    /// 1 s window while the screen sat still, and the same in a 10-minute soak (56 s gaps between
    /// sweeps). So a silence rule that assumes idle frames exist restarts a perfectly healthy stream
    /// -- the first version of this did exactly that, three times in five minutes. It is therefore
    /// opt-in: `KRD_STREAM_WATCHDOG=<seconds>` turns it on, `0` (the default) leaves it off.
    private func startFrameWatchdog() {
        let limit = Double(ProcessInfo.processInfo.environment["KRD_STREAM_WATCHDOG"] ?? "0") ?? 0
        lastFrameAt = Date()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 5)
        timer.setEventHandler { [weak self] in self?.watchFrames(limit: limit) }
        timer.resume()
        frameWatchdog = timer
    }

    private func watchFrames(limit: Double) {
        if options.debug {
            Log.write("watchdog: tick callbacks=\(capturer.callbacks) seen=\(lastSeenCallbacks) "
                + "silence=\(Int(Date().timeIntervalSince(lastFrameAt)))s restarting=\(captureRestarting)\n")
        }
        guard !cleanedUp, filter != nil else { return }
        let count = capturer.callbacks
        if count != lastSeenCallbacks {
            // Frames are flowing: the retry budget is earned back by delivery, not by a restart
            // returning without throwing, and nothing is owed any more.
            lastSeenCallbacks = count
            lastFrameAt = Date()
            expectFrameBy = nil
            if streamStopAttempts > 0 { streamStopAttempts = 0 }
            return
        }
        if captureRestarting {
            // A restart that has been "in flight" for longer than a stop plus a start can take is
            // not in flight any more, it is parked. Clear it and let the retry happen; otherwise a
            // single hung `stopCapture()` freezes the picture for the session.
            let parked = Date().timeIntervalSince(restartStartedAt)
            if parked > 12 {
                Log.write("krd: a capture restart has been parked for \(Int(parked))s; "
                    + "clearing it and trying again\n")
                captureRestarting = false
                restartPending = false
            }
            return
        }
        if let due = expectFrameBy, Date() >= due {
            expectFrameBy = nil
            let waited = Date().timeIntervalSince(due) + FRAME_TIMEOUT
            retryStream(reason: String(format: "no frame %.1fs after asking for one", waited))
            return
        }
        guard limit > 0 else { return }
        let silence = Date().timeIntervalSince(lastFrameAt)
        guard silence >= limit else { return }
        lastFrameAt = Date()
        retryStream(reason: "no frames for \(Int(silence))s")
    }

    /// Count one failed attempt and restart, or give up once the budget is spent.
    private func retryStream(reason: String) {
        streamStopAttempts += 1
        guard streamStopAttempts <= 5 else {
            frameWatchdog?.cancel()
            frameWatchdog = nil
            warnRestartOnce("krd: \(reason) and 5 restarts did not help; "
                + "the last frame stays on screen\n")
            return
        }
        Log.write("krd: \(reason); restarting the capture stream "
            + "(attempt \(streamStopAttempts)/5)\n")
        restartCapture(reason: reason)
    }

    /// The stream stopped on its own: restart it with backoff, bounded.
    ///
    /// `-3805` ("application connection being interrupted") is what a VM's window server hands
    /// back when it drops the connection under the stream; after it, `callbacks` never moves again
    /// and the picture is frozen, which is worse than an error because nothing looks wrong. Five
    /// attempts with 1, 2, 4, 8, 8 s are enough for a transient drop and bounded for a dead one.
    private func recoverFromStoppedStream(_ error: Error) {
        guard !cleanedUp else { return }
        streamStopAttempts += 1
        let attempt = streamStopAttempts
        guard attempt <= 5 else {
            warnRestartOnce("krd: capture stopped (\(error.short)); gave up after 5 restarts; "
                + "the last frame stays on screen\n")
            return
        }
        let delay = min(pow(2.0, Double(attempt - 1)), 8.0)
        Log.write("krd: capture stopped (\(error.short)); restarting in \(Int(delay))s "
            + "(attempt \(attempt)/5)\n")
        streamStopTimer?.cancel()
        frameWatchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.streamStopTimer = nil
            self?.restartCapture(reason: "the stream stopping")
        }
        timer.resume()
        streamStopTimer = timer
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
    private func filterRect(for crop: CGRect) -> CGRect {
        // Builds differ on whether a display filter wants global points; KRD_ZOOM_GLOBAL_RECT=1
        // is the escape hatch when a crop on a secondary display lands somewhere else.
        let global = ProcessInfo.processInfo.environment["KRD_ZOOM_GLOBAL_RECT"] != nil
        let origin = global ? crop.origin : CGPoint(x: crop.minX - fullRect.minX, y: crop.minY - fullRect.minY)
        return CGRect(origin: origin, size: crop.size)
    }

    private func cropForFilter() -> CGRect? {
        let crop = currentCrop()
        guard crop.width < fullRect.width - 0.5 || crop.height < fullRect.height - 0.5 else { return nil }
        return filterRect(for: crop)
    }

    private func applyLayout(geometry: TermGeometry) {
        let crop = Viewport.crop(full: fullRect, scale: zoomScale, focus: zoomFocus)
        let aspect = crop.width / max(crop.height, 1)
        // The status line owns the last row (plus whatever a panel asked for). The picture is
        // fitted into the rest, so the cell math, the mouse mapping and the tile grid all stay in
        // the same coordinate space.
        var paneGeometry = geometry
        if chromeEnabled, paneGeometry.rows > 4 {
            let panelRows = chromeState.panel?.height ?? 0
            paneGeometry.rows = max(3, paneGeometry.rows - 1 - min(panelRows, paneGeometry.rows - 4))
        }
        let layout = TileGrid.make(geometry: paneGeometry, aspect: aspect,
                                   tileCols: options.tileCols, tileRows: options.tileRows,
                                   bpp: writer.format.bytesPerPixel, scale: options.scale)
        if chromeEnabled {
            // --full-frame draws one image the size of the picture, so the chrome still fits.
            chromeGeometry = Chrome.layout(paneCols: geometry.cols, paneRows: geometry.rows,
                                           imageCols: layout.paneCols, imageRows: layout.paneRows,
                                           panel: chromeState.panel)
            chrome.invalidate()
            chromeDirty = true
        }
        stateLock.lock()
        grid = layout
        sourceRect = crop
        previousFrame = []
        // Pane pixels, not capture pixels: SGR-Pixels coordinates are the terminal's own grid, so
        // `--scale 0.5` must not move the mapping by a factor of two (issue #60).
        viewport = Viewport(pixelWidth: layout.panePixelW, pixelHeight: layout.panePixelH,
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
        panCapture()
    }

    /// Move the crop of the running stream. `SCStream.updateConfiguration` re-crops in place, so a
    /// pan costs one message instead of a stop/start cycle (issue #54): no freeze while the stream
    /// re-negotiates, and the stop path -- the one that wedged in the #44 soak -- leaves the hot
    /// path entirely. `restartCapture` is still the fallback if the update is refused.
    private func panCapture() {
        guard !cleanedUp, filter != nil, let layout = currentGrid() else { return }
        if panInFlight {                              // coalesce: one update at a time
            panPending = true
            return
        }
        panInFlight = true
        let rect = filterRect(for: currentCrop())
        let width = layout.pixelW, height = layout.pixelH
        Task { [weak self] in
            guard let self else { return }
            var result: Capturer.Update = .noStream
            do {
                result = try await self.capturer.updateSource(rect, width: width, height: height)
            } catch {
                Log.write("krd: could not move the capture window (\(error)); restarting it instead\n")
            }
            DispatchQueue.main.async {
                if result == .changed {
                    // The update owes us a frame; the watchdog checks that it arrives rather than
                    // waiting for one to be "overdue" by the silence rule, which a still screen
                    // never satisfies.
                    self.expectFrameBy = Date().addingTimeInterval(self.FRAME_TIMEOUT)
                    if self.options.debug {
                        let crop = self.currentCrop()
                        Log.write("pan: source \(Int(crop.width))x\(Int(crop.height)) pt -> "
                            + "\(width)x\(height) px (update, no restart)\n")
                    }
                } else if result == .noStream, !self.cleanedUp {
                    self.restartCapture(reason: "a refused in-place pan")
                }
                self.panInFlight = false
                if self.panPending {
                    self.panPending = false
                    self.panCapture()
                }
            }
        }
    }

    /// Restart the stream against the current filter and layout.
    ///
    /// This is the path for the triggers that really change the filter or the layout: a terminal
    /// resize, a display-set change, a recovery restart, and the fallback when an in-place pan is
    /// refused. A zoom *pan* does not come through here any more (issue #54): it re-crops the
    /// running stream with `Capturer.updateSource`. `captureRestarting` keeps two restarts from
    /// starting a stream at the same time; the loser is queued with its reason, not dropped.
    private func restartCapture(reason: String = "a restart") {
        guard let filter, let layout = currentGrid(), !cleanedUp else { return }
        if captureRestarting { restartPending = true; pendingRestartReason = reason; return }
        captureRestarting = true
        restartStartedAt = Date()
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
                self.restartCapture(reason: self.pendingRestartReason ?? reason)
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
        framesHandled += 1

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
                let plan = writer.plan(for: index)
                base[i] = ScreenWriter.compress(index: index, rect: rect,
                                                pixels: grid.extract(pixels, rect: rect),
                                                level: plan.level, quantise: plan.quantise)
            }
        }
        writer.addCompressTime(Date().timeIntervalSince(compressStart) * 1000)

        // Assembly stays serial: the escapes must reach the pty in a deterministic order.
        for case let tile? in packed {
            writer.emit(tile, sync: writer.perTileSync)
            writer.observe(index: tile.index, ratio: tile.ratio, quantisedIn: tile.isQuantised)
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
        guard !cleanedUp, filter != nil || mock != nil else { return }
        let geometry = TermGeometry.read()
        applyLayout(geometry: geometry)
        guard let layout = currentGrid(), layout.pixelW > 8, layout.pixelH > 8 else { return }
        writer.clear()
        chrome.invalidate()
        chromeDirty = true
        if let mock {
            mock.resize(width: layout.pixelW, height: layout.pixelH)
        } else {
            // Same path as a display change: one place decides whether a stream is already
            // starting, so a resize during a plug event queues instead of racing it.
            restartCapture(reason: "a terminal resize")
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

    // MARK: TUI layer

    /// Starts the 1 Hz chrome tick. Sampling is separate from drawing: the numbers refresh once
    /// a second, the bytes go out only when something actually changed.
    private func startChrome() {
        guard chromeEnabled else { return }
        chromeState.toast = "^\\ then ? for keys"
        chromeToastUntil = Date().addingTimeInterval(8)

        sampleChrome()
        drawChrome()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.sampleChrome()
            self.drawChrome()
        }
        timer.resume()
        chromeTimer = timer
    }

    /// Fill `chromeMetrics` from the same counters the `--debug` line prints, plus the rates
    /// (which the line only implies) and the switches that are otherwise invisible.
    private func sampleChrome() {
        let now = Date()
        let elapsed = max(0.001, now.timeIntervalSince(chromeSampleTime))
        let bytes = writer.totalBytes
        let tiles = writer.framesEmitted
        let dTiles = tiles - chromeSampleTiles
        let dBytes = bytes - chromeSampleBytes
        chromeSampleTime = now
        chromeSampleTiles = tiles
        chromeSampleBytes = bytes

        let layout = currentGrid()
        let cells = currentViewport()
        var m = chromeMetrics
        m.version = krdVersion
        m.target = targetLabel
        m.fpsTarget = options.fps
        m.fps = Double(framesHandled - chromeSampleFrames) / elapsed
        m.captureFps = Double(capturer.framesDelivered - chromeSampleDelivered) / elapsed
        chromeSampleFrames = framesHandled
        chromeSampleDelivered = capturer.framesDelivered
        m.mbps = Double(dBytes) / 1_048_576.0 / elapsed
        m.kbPerFrame = writer.lastFrameBytes / 1024
        m.tilesPerSec = Int(Double(dTiles) / elapsed)
        m.dirty = lastDirtyCount
        m.tilesTotal = layout?.count ?? 0
        m.clock = krdClock.string(from: now)
        let queue = ptyQueueBytes()
        m.queueBytes = queue
        if queue >= 0 {
            // Bytes written minus bytes that piled up = bytes the pty actually drained.
            let drained = max(0, dBytes - (queue - chromeSampleQueue))
            m.drainMbps = Double(drained) / 1_048_576.0 / elapsed
            chromeSampleQueue = queue
        }
        m.queueMs = queue > 0 && m.mbps > 0.01 ? Double(queue) / (m.mbps * 1_048_576) * 1000 : 0
        m.pipeMs = lastPipeMs
        pipeSamples.append(lastPipeMs)
        if pipeSamples.count > 300 { pipeSamples.removeFirst(pipeSamples.count - 300) }
        m.pipeP99Ms = pipeSamples.max() ?? 0
        m.capMs = -1                       // not measured yet: splitting it needs PTS (#52)
        m.e2eMs = lastPipeMs
        m.zlibMs = writer.lastCompressMs
        m.writeMs = writer.lastWriteMs
        m.writeMaxMs = writer.writeMaxMs
        m.writeOver5 = writer.writeOver5Ms
        m.callbacks = capturer.callbacks
        m.delivered = capturer.framesDelivered
        m.skipped = capturer.framesSkipped
        m.idle = capturer.idleFrames
        m.bad = capturer.badFrames
        m.pxW = layout?.pixelW ?? 0
        m.pxH = layout?.pixelH ?? 0
        m.cellsW = cells.cols
        m.cellsH = cells.rows
        m.cellW = layout?.cellW ?? 0
        m.cellH = layout?.cellH ?? 0
        m.format = writer.format == .rgb ? "rgb f=24" : "rgba f=32"
        m.sync = writer.syncLabel
        m.quiet = writer.quietLabel
        m.inputActive = input != nil
        m.dryRun = options.dryRun
        m.cursorDrawn = options.drawsCursor
        m.logPath = Log.path ?? "-"
        m.recording = recorderLabel()
        m.geometrySource = geometrySource
        m.envSwitches = activeEnvSwitches()
        m.devices = deviceRows()
        m.tileSpec = "\(options.tileCols)x\(options.tileRows)"
        m.mbpsHistory.append(m.mbps)
        m.latencyHistory.append(m.e2eMs)
        if m.mbpsHistory.count > 60 { m.mbpsHistory.removeFirst() }
        if m.latencyHistory.count > 60 { m.latencyHistory.removeFirst() }
        if Date() > chromeToastUntil { chromeState.toast = nil }
        // the log panel is I/O: only pay for it while it is open
        if chromeState.panel == .log { m.logTail = readLogTail() }
        chromeMetrics = m
        writer.resetWriteStats()
        chromeDirty = true
    }

    /// Bytes sitting in the pty's output buffer. sshd normally drains it at once and buffers in
    /// userspace, so this stays 0 while the picture is seconds behind — which is exactly why the
    /// status line carries a wall clock instead of pretending this is a lag meter.
    private func ptyQueueBytes() -> Int {
        var pending: Int32 = 0
        // TIOCOUTQ = _IOR('t', 115, int) = 0x40047473; the macro is not imported into Swift.
        let request: UInt = 0x4004_7473
        guard ioctl(STDOUT_FILENO, request, &pending) == 0 else { return -1 }
        return max(0, Int(pending))
    }

    private static let krdClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private var krdClock: DateFormatter { Desk.krdClock }

    /// Displays first (the active one starred), then windows: the same information `--list`
    /// prints, refreshed once a second.
    private func deviceRows() -> [String] {
        guard let content = shareable else { return [] }
        var rows: [String] = []
        let activeID = targetLabel
        for (index, display) in content.displays.enumerated() {
            let bounds = CGDisplayBounds(display.displayID)
            let active = activeID.hasPrefix("display \(index) ")
            rows.append("\(active ? "*" : " ") [\(index)] display \(Int(bounds.width))×\(Int(bounds.height)) pt")
        }
        for window in content.windows where window.frame.width > 60 {
            let app = window.owningApplication?.applicationName ?? "?"
            let title = String((window.title ?? "-").prefix(40))
            rows.append("   window \(window.windowID)  \(app) — \(title)")
        }
        return Array(rows.prefix(24))
    }

    private func startInput() {
        guard !options.noInput else { return }
        let reader = InputReader(
            viewport: { [weak self] in
                self?.currentViewport() ?? Viewport(pixelWidth: 1, pixelHeight: 1, cols: 1, rows: 1,
                                                    sourceRect: .zero)
            },
            dryRun: options.dryRun) { [weak self] in self?.shutdown() }
        reader.onChromeKey = { [weak self] byte in self?.chromeKey(byte) ?? false }
        reader.onChromeClick = { [weak self] row, col in self?.chromeClick(row: row, col: col) }
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
            Log.write("krd: accessibility trusted=\(AXIsProcessTrusted()) (clicks/keys need it; "
                      + "see System Settings > Privacy > Accessibility)\n")
        }
    }

    private func recorderLabel() -> String {
        guard let recorder else { return "off" }
        return "\(recorder.count)/\(options.recordFrames) frames"
    }

    private func activeEnvSwitches() -> String {
        let env = ProcessInfo.processInfo.environment
        let keys = ["KRD_Q", "KRD_FORMAT", "KRD_SYNC", "KRD_NOSYNC", "KRD_REAP", "KRD_DUMP",
                    "KRD_GRID", "KRD_QUADRANTS", "KRD_DELTEST", "KRD_RAWDUMP"]
        let active = keys.filter { env[$0] != nil }
        if active.isEmpty { return "none" }
        return active.map { "\($0)=\(env[$0] ?? "")" }.joined(separator: " ")
    }

    private func readLogTail(_ lines: Int = 12) -> [String] {
        guard let path = Log.path, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines)).map(String.init)
    }

    /// Draw and write, on the main queue. `ScreenWriter.writeChrome` is serialized against the
    /// tile flush, so this can never split a base64 payload.
    private func drawChrome() {
        guard chromeEnabled, chromeDirty, let geometry = chromeGeometry else { return }
        chromeDirty = false
        let bytes = chrome.draw(geometry: geometry, metrics: chromeMetrics, state: chromeState)
        writer.writeChrome(bytes)
    }

    /// `Ctrl-\` (prefix) and the byte after it. Returns true when the byte belongs to the chrome.
    private func chromeKey(_ byte: UInt8) -> Bool {
        guard chromeEnabled else { return false }
        if chromeState.prefix {
            chromeState.prefix = false
            switch byte {
            case 0x1C: chromeState.panel = nil
            case UInt8(ascii: "q"): shutdown()
            case UInt8(ascii: "?"), UInt8(ascii: "h"): chromeState.panel = .help
            case UInt8(ascii: "s"): chromeState.panel = .stats
            case UInt8(ascii: "f"): chromeState.panel = .settings
            case UInt8(ascii: "d"): chromeState.panel = .devices
            case UInt8(ascii: "l"): chromeState.panel = .log
            default: break
            }
            applyPanel()
            return true
        }
        if byte == 0x1C {
            chromeState.prefix = true
            chromeDirty = true
            return true
        }
        if byte == 0x1B, chromeState.panel != nil {
            chromeState.panel = nil
            applyPanel()
            return true
        }
        return false
    }

    private func chromeClick(row: Int, col: Int) {
        guard chromeEnabled, let geometry = chromeGeometry else { return }
        switch chrome.hitTest(row: row, col: col, geometry: geometry) {
        case .statusSegment(let id):
            switch id {
            case "stats": chromeState.panel = .stats
            case "help": chromeState.panel = .help
            case "fps": chromeState.panel = .settings
            case "target": chromeState.panel = .devices
            default: break
            }
            applyPanel()
        case .insidePanel:
            break                                   // clicks inside a panel are not forwarded
        case .outside:
            break
        }
    }

    /// A panel changes the layout: the picture keeps its rows when the panel fits underneath,
    /// and steps aside when it does not.
    private func applyPanel() {
        // The panel's rows come out of the picture, which changes the capture size. The resize
        // path already knows how to do that: re-measure, re-fit, clear, restart the stream.
        handleResize()
        chromeDirty = true
    }

    func shutdown() {
        guard !cleanedUp else { return }
        cleanedUp = true
        followTimer?.cancel()
        clipboardTimer?.cancel()
        displayTimer?.cancel()
        displayPollTimer?.cancel()
        streamStopTimer?.cancel()
        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(krdDisplayChanged, Unmanaged.passUnretained(self).toOpaque())
            displayCallbackRegistered = false
        }
        chromeTimer?.cancel()
        chromeTimer = nil
        mock?.stop()
        mock = nil
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
