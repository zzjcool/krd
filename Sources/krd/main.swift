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
    ///
    /// The default is **adaptive** (issue #73): `auto` starts at 1 and only steps down when the write
    /// side cannot keep up, so a fast link never sees a different picture, while a slow one trades
    /// sharpness for motion instead of freezing -- the failure a user can neither explain nor fix by
    /// themselves. `--scale 1` is the escape hatch that pins it.
    var scale = 1.0
    var scaleAuto = true
    /// `--scale <fraction>` was given: the value is the user's, not `auto`'s (and `--selftest` refuses
    /// it, because its sha256 is a byte contract).
    var scalePinned = false
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
    /// The landing screen: the display plus the most recently used windows, as pictures.
    ///
    /// **This is what plain `krd` starts** (design §2, phase 4). The mirror is one flag away:
    /// `--mirror`, or `--window <query>`, which asks for exactly that window and cannot mean the
    /// wall. The wall renders fully with the Screen Recording grant denied: the layout, the captions
    /// and the scroll bar are text, and a panel that cannot be captured draws its mask (design §4).
    var wall = true
    /// Where the wall's shelf and stage were, or — in a mirror this process handed the pane to — the
    /// offsets to go back to when it leaves (`--wall-at <stage>:<card>`).
    ///
    /// One flag, two readers, because it is one number: the wall that hands over, the mirror that
    /// returns, and the wall that comes back all have to agree about which page the reader was on.
    var wallAt: (stage: Int, card: Int)? = nil
    /// A failed mirror's sentence, and the status it left with (`--said <exit> <text>`), so the wall
    /// it returns to can paint the reason in its footer instead of coming back without a word.
    var said: (exit: Int32, text: String)? = nil
    /// The mirror's top bar (`--bar` / `--no-bar`). Unset means "when the wall handed the pane
    /// over": a window entered from the landing screen comes dressed as one, with the button that
    /// shrinks it back, while `krd --window <q>` typed by hand stays bare like it always was.
    var bar: Bool? = nil
    /// The wall's glyph table (`--symbols`): `emoji` unless the terminal draws `▲ ▣ ⤢` two cells
    /// wide, which would slide the bar off the column a click maps to.
    var symbols: WallSymbols = .emoji
    /// Replace ScreenCaptureKit with a desktop drawn in process. No permission, runs forever.
    var mock = false
    var mockSize: (w: Int, h: Int)? = nil
}

/// `<stage>:<card>`, the wall's two scroll offsets in one flag (`--wall-at`).
///
/// Negative and non-numeric halves are refused rather than clamped: this flag is written by krd for
/// krd, so a malformed one is a bug in the hand-over, not a reader's typo to be patched over. A
/// missing value means "start where a fresh wall starts", which is the same as not passing it.
func parseWallAt(_ spec: String) -> (stage: Int, card: Int)? {
    let parts = spec.split(separator: ":")
    guard parts.count == 2, let stage = Int(parts[0]), let card = Int(parts[1]),
          stage >= 0, card >= 0 else { return nil }
    return (stage, card)
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
      --scale <f|auto>    how many pixels to capture per side, terminal upscales (issue #60).
                          auto (default) starts at 1 and steps down only while the pipe is behind,
                          so a fast link never changes and a slow one stays smooth instead of
                          freezing; 1 pins it, 0.5 is a quarter of the bytes and visibly softer
                          (--bench, --record, --replay, --selftest always capture at 1)
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
      --mirror            the whole display as one picture at --fps (the old behaviour; plain krd
                          now opens the wall: the display on top, the three most recent windows
                          below, both scrolling on the right bar)
      --bar / --no-bar    the mirror's one-row macOS bar: window name, rate, clock, and the [ - ]
                          button that shrinks it back into the wall. On by default for a window
                          the wall handed over, off for a mirror you started yourself
      --symbols <m>       the wall's glyphs: emoji (default) or ascii, for terminals that draw
                          ▲ ▣ ⤢ two cells wide
      --mock              draw the desktop in process: no screen, no permission, runs forever
      --mock-size WxH     size of the generated desktop (default 1920x1200)
      --list              list displays and windows, then exit
      -v, --version       print the version and exit

    wall internals (written by krd for krd; a reader has no reason to type them):
      --wall-at <s>:<c>   where the shelf and the stage are. A wall starts there; a mirror this
                          pane was handed to returns there when it leaves
      --said <exit> <txt> the footer sentence of a mirror that failed, carried back to the wall

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

/// Why a reproducible path ignores `--scale auto`, in one line -- or nil when the scale may adapt.
///
/// `auto` reacts to the write side; `--bench` and `--selftest` have no pipe to measure, and a
/// recording or replay whose frame size changes mid-file would be a trap: every frame is valid on its
/// own, nothing in the file marks the change, and `--replay` would feed frames that disagree with the
/// header it read at the start. A fixed `--scale 0.5` is still allowed there -- it is constant.
func adaptiveScaleRefusal(bench: Bool, selftest: Bool, recording: Bool, replay: Bool) -> String? {
    if bench { return "--bench captures at scale 1 (adaptive scaling reacts to a live pipe)" }
    if selftest { return "--selftest captures at scale 1 (its sha256 is a byte contract)" }
    if recording {
        return "--record captures at scale 1 (a frame size that changes mid-file has no marker)"
    }
    if replay { return "--replay captures at scale 1 (adaptive scaling reacts to a live pipe)" }
    return nil
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

/// `--symbols <spec>`, or a usage error: a typo must not silently pick a glyph table.
func parseSymbolsSpec(_ spec: String) -> WallSymbols {
    guard let symbols = WallSymbols(spec: spec) else {
        FileHandle.standardError.write(
            Data("krd: --symbols wants emoji|ascii, got \"\(spec)\"\n".utf8))
        exit(2)
    }
    return symbols
}

/// Does this argv[0] mean the landing screen? `install.sh` links `wall` next to `krd`, so the
/// everyday spelling is one word (`wall`, `wall --symbols ascii`) and it reaches this same parser:
/// the basename is the whole rule, and no wrapper script has to forward flags by hand.
func invokedAsWall(_ argv0: String) -> Bool {
    (argv0 as NSString).lastPathComponent == "wall"
}

/// `argv` is a parameter for the tests' sake, not for the app's: the wall-vs-mirror decision is the
/// one piece of the parse that a reader cannot check by running the binary, and it is now a default
/// plus two overrides, i.e. exactly the shape that rots silently.
func parseArguments(_ argv: [String] = CommandLine.arguments) -> Options {
    var options = Options()
    if invokedAsWall(argv.first ?? "") { options.wall = true }
    let args = Array(argv.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--fps": options.fps = max(1, Int(args[safe: i + 1] ?? "") ?? options.fps); i += 1
        case "--display": options.displayIndex = Int(args[safe: i + 1] ?? ""); i += 1
        case "--window":
            // Naming one window to mirror is a request for the mirror, never for the wall.
            options.windowQuery = args[safe: i + 1]
            options.wall = false
            i += 1
        case "--zoom":
            if let value = Double(args[safe: i + 1] ?? ""), value.isFinite { options.zoom = value }
            i += 1
        case "--scale":
            // The parser does not throw; an unparsable value is carried to `run()` instead of
            // silently meaning "1", because a typo here doubles the bytes on the wire.
            if (args[safe: i + 1] ?? "").lowercased() == "auto" {
                options.scaleAuto = true
                options.scalePinned = false
            } else if let value = Double(args[safe: i + 1] ?? ""), value.isFinite, value > 0, value <= 1 {
                options.scale = value
                options.scaleAuto = false
                options.scalePinned = true
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
        // The default since phase 4; kept because scripts and muscle memory spell it.
        case "--wall": options.wall = true
        case "--mirror": options.wall = false
        case "--bar": options.bar = true
        case "--no-bar": options.bar = false
        case "--wall-at":
            // `<stage>:<card>`. Parsed by the same function both times, so the wall that hands over
            // and the wall that comes back cannot disagree about the spelling.
            if let spec = args[safe: i + 1] { options.wallAt = parseWallAt(spec) }
            i += 1
        case "--said":
            // `<exit>` then the child's sentence as its own token: the text has spaces in it.
            if let code = Int32(args[safe: i + 1] ?? "") {
                options.said = (code, args[safe: i + 2] ?? "")
            }
            i += 2
        case "--symbols":
            options.symbols = parseSymbolsSpec(args[safe: i + 1] ?? "")
            i += 1
        // The `--flag=value` spelling too, for the same reason as `--ime=` / `--clipboard=`.
        case let arg where arg.hasPrefix("--symbols="):
            options.symbols = parseSymbolsSpec(String(arg.dropFirst("--symbols=".count)))
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
    /// Written once, in `run()` before anything starts: a reproducible path pins the scale
    /// (issue #73). Nothing else mutates it, so the closure reads are not a race.
    private var options: Options
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
    /// The scale in force right now. With `--scale auto` the governor moves this; otherwise it is
    /// `options.scale` and never changes (issue #64).
    private var effectiveScale = 1.0
    private var governor = ScaleGovernor()
    /// Frames and late frames since the last stats tick, for the `late` column.
    private var framesSinceTick = 0
    private var lateSinceTick = 0
    private var geometry: TermGeometry?
    private var captureRestarting = false
    private var restartPending = false
    /// Consecutive `didStopWithError` recoveries that have not produced a frame yet. Bounded, so a
    /// dead window server cannot turn the retry loop into a hot loop.
    private var streamStopAttempts = 0
    private var streamStopTimer: DispatchSourceTimer?
    /// Frames the *current* stream has delivered. A stream that stops before its first one names a
    /// target the window server will not hand out at all, so it is a setup failure and not an
    /// interruption worth retrying (see `recoverFromStoppedStream`).
    private var framesSinceStreamStart = 0
    /// What a failure said, kept so the wall this process returns to can repeat it. Nil for a clean
    /// exit (`Ctrl-\`), which is not a failure and has nothing to explain.
    private var failureSaid: String?
    /// The process status this desk leaves with. Handing a wall's child a non-zero code is how the
    /// wall learns to paint "the mirror stopped (exit N)" instead of a silent gap.
    private var exitStatus: Int32 = 0
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
    private var windowTarget: (pid: pid_t, id: CGWindowID, name: String, title: String)?
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
    // The wall (the default mode). `wallState != nil` *is* wall mode: no capturer, and every
    // cell of the pane belongs to `WallCanvas`, so each path that would fit or restart a mirror
    // looks at this one flag first.
    private var wallState: WallState?
    /// Wall mode as a plain `Bool`, because `chromeClick` runs on the reader thread and reads it:
    /// `wallState` is written on the main queue (every click, by `wallClick`), so reading *that*
    /// from another thread would be a race on a multi-word value. This one is written once, before
    /// `startInput()` starts the reader, and never again.
    private var wallMode = false
    private var wallCanvas: WallCanvas?
    private var wallModel = WallModel()
    private var wallTimer: DispatchSourceTimer?
    /// The pane the last wall draw was laid out for. Together with `wallModel` it is the whole
    /// answer to "would the wall look different?" — the 1 s tick emits nothing while both match.
    private var wallPane: (cols: Int, rows: Int, cellW: Double, cellH: Double)?
    /// The repaint in flight, if any. The wall captures before it paints (a slot is either a
    /// picture or a mask, and that decides what the text layer may draw), so a tick that arrives
    /// mid-capture is remembered rather than raced.
    private var wallPaintTask: Task<Void, Never>?
    /// Whether anything has ever been written to the wall's screen. Only the *first* paint is
    /// allowed to go out before the pictures do (see `drawWall`).
    private var wallPaintedOnce = false
    /// A child mirror owns the pane right now (see `mirrorInChild`).
    private var mirroring = false
    /// What the last child mirror said when it stopped, if it stopped badly. Kept until the next
    /// click so the wall a reader comes back to explains the blink they just saw.
    private var mirrorNotice: WallNotice?
    private var wallDirtyWhilePainting = false
    /// zlib level for a wall panel. Level 6 would spend ~3x the CPU to save a few percent on a
    /// picture that is only encoded when the desk changes (design §12: no frame loop to pay for).
    private static let wallPanelLevel = 3
    private var pipeSamples: [Double] = []
    private var targetLabel = "-"
    private var shareable: SCShareableContent?
    private var mock: MockDesktop?
    private var geometrySource = "-"

    /// The wall owns the whole pane, so `--dev` has no rows to take: the layer stays off even when
    /// both flags are given.
    private var chromeEnabled: Bool { options.dev && !options.noChrome && !options.wall }
    /// The mirror's own top bar (design §6.8). Independent of `--dev`: that is a diagnostic surface
    /// at the bottom, this is the window's furniture at the top.
    private var barEnabled: Bool { options.bar ?? (options.wallAt != nil) }
    /// Chrome bytes are drawn whenever *either* layer is on: one painter, one geometry, one write
    /// path, so the bar cannot end up in a different coordinate space than the status line.
    private var chromeAvailable: Bool { chromeEnabled || barEnabled }
    /// What the bar calls the window, e.g. "Terminal — admin — scroll.sh" or "display 1 · 1024×768".
    private var barTitle = ""
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
        // Wall mode is in the list for its own reason: the pane *is* the wall, so a diagnostic must
        // not reach it at all — `Log`'s fallback sink is stderr, i.e. the pane, and one line there
        // scrolls the picture off its own grid (CONTRIBUTING.md rule 1). The reader's own
        // `input:` lines are gated separately (`InputReader(forward:)`); this half catches the rest
        // (a warning, the focus seam's line, the "no physical key for this character" notice).
        Log.configure(explicitPath: options.logPath,
                      wantsLogging: options.debug || options.logPath != nil
                        || options.statsJSON != nil || options.wall)
        if let where_ = Log.path {
            // Told to the log rather than to stderr in wall mode: this one line has a `\n` in it,
            // and on the wall that newline on the last row scrolls everything.
            if options.wall {
                Log.write("krd: logging to \(where_)\n")
            } else {
                FileHandle.standardError.write(Data("krd: logging to \(where_)\n".utf8))
            }
        }
        if let error = options.scaleError { throw DeskError.message(error) }
        // The selftest is a byte contract about framing, not about resolution: it always captures
        // at the pane's own pixel size, so `--scale` next to it is a usage error rather than a
        // silent change of the sha256 people compare against.
        if options.selftest && options.scalePinned {
            throw DeskError.message("--selftest always captures at scale 1; drop --scale")
        }
        // Adaptive scaling is the default, but these four paths must not have it: they either have no
        // pipe to measure, or they write something a later run reads back. Pin them to 1 and say why,
        // because a scale that moves under a recording leaves frames whose sizes differ with nothing
        // in the file to mark it.
        if options.scaleAuto,
           let why = adaptiveScaleRefusal(bench: options.bench, selftest: options.selftest,
                                          recording: options.record != nil, replay: options.replay != nil) {
            options.scaleAuto = false
            options.scale = 1
            Log.write("krd: \(why)\n")
        }
        // One place decides the starting scale, for every path below -- live, --mock, --bench.
        // (It used to be set inside the live capture setup only, so `--mock --scale 0.5` quietly
        // drew at 1.)
        effectiveScale = options.scale
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
            barTitle = targetLabel
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

        // The wall is text and needs no grant: `CGWindowListCopyWindowInfo` hands out owner, pid,
        // bounds and window number without one (only `kCGWindowName` is withheld, and a card with
        // no title draws `window N`). This branch is therefore strictly before the first
        // `SCShareableContent` call — the one that throws when Screen Recording is denied — so a
        // wall-only session starts and renders with the grant missing.
        if options.wall, !options.listOnly {
            runWall()
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
        // The bar's title, from the same target: an app and its window, or a display and its size.
        // Not the `--debug` sentence, which is a measurement ("moved to -192,-1050") and would read
        // as noise in window furniture.
        if let window = target.window {
            let title = window.title.trimmingCharacters(in: .whitespaces)
            barTitle = title.isEmpty ? window.name : "\(window.name) — \(title)"
        } else {
            // Which display it is, in the terms the wall's caption uses (`main · 1/3`).
            let boxes = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))?
                .displays.map { CGDisplayBounds($0.displayID) } ?? []
            let index = boxes.firstIndex(of: target.rect).map { $0 + 1 } ?? 1
            barTitle = "display \(index) · \(Int(target.rect.width))×\(Int(target.rect.height))"
        }
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
            self.framesSinceStreamStart += 1
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
        // The pane may hold pictures from a process that drew here before this one (a wall this
        // mirror was entered from, a `krd` that was killed): a kitty placement outlives the process
        // that made it, and a centred picture no longer covers the whole pane, so those leftovers
        // would show around it. Same delete the wall does, for the same reason.
        writer.clear()
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
                + (options.scaleAuto ? " (scale auto, \(ScaleGovernor.show(effectiveScale)))"
                   : options.scale < 1 ? " (scale \(ScaleGovernor.show(options.scale)))" : "")
                + layout.fitNote
                + ", \(layout.tilesX)x\(layout.tilesY) tiles of \(layout.tileCols)x\(layout.tileRows) cells\n"
            Log.write(message)
        }

        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: the wall (--wall)

    /// Start the landing screen: alternate screen, resize handler, input, one enumeration and a
    /// 1 s tick. No capturer, no tile grid, no chrome rows — the wall owns every cell.
    private func runWall() {
        if let cell = options.cell {
            TermGeometry.fallbackCell = cell
        } else if options.pane == nil {
            // The pane's *cell* size, asked from the terminal itself. Over ssh the pty reports
            // `ws_xpixel/ws_ypixel = 0`, so without this the wall fitted every picture to the
            // hard-coded 8x20 fallback - a cell aspect of 0.40. Rex's real cell is 0.51 (and its
            // ANSI answers say 8x16 = 0.50), so the fit left 36% of the stage's height empty: the
            // picture looked smaller than its frame. Only the *ratio* has to be roughly right for
            // the layout, and a terminal that answers nothing keeps the fallback.
            // 150 ms per question, not the default 250: a terminal that answers does so in
            // microseconds, and this runs before the first paint, where half a second is visible.
            if let measured = TermGeometry.query(timeoutMs: 150) {
                TermGeometry.fallbackCell = measured.cellSize
                // The one number every fit in the wall depends on, and the one a reader cannot see:
                // "the picture does not reach the full width" is answered by this line plus their
                // terminal's own cell (design §6.6).
                Log.write("krd: wall cell \(Int(measured.cellSize.w))x\(Int(measured.cellSize.h)) px, "
                          + "measured from the terminal (\(TermGeometry.lastAnswer.label))\n")
            } else {
                Log.write("krd: wall cell \(Int(TermGeometry.fallbackCell.w))x"
                          + "\(Int(TermGeometry.fallbackCell.h)) px, assumed (the terminal did not answer)\n")
            }
        }
        // A size-zero viewport is what "there is no picture" means to the mouse path: no cell and
        // no pixel is inside it (`Viewport.contains`), so every report lands in `chromeClick`,
        // which routes it to the wall. Set before input starts, and never overwritten — nothing in
        // this mode calls `applyLayout`.
        stateLock.lock()
        viewport = Viewport(pixelWidth: 0, pixelHeight: 0, cols: 0, rows: 0, sourceRect: .zero)
        stateLock.unlock()
        writer.beginSession()
        // Drop every image the terminal still holds, not just the text: the pane this wall lands on
        // may be one a mirror was just exec'ed out of (the `[ - ]` button, `Ctrl-\`), and a kitty
        // placement outlives the process that made it. `beginSession`'s `2J` clears characters and
        // leaves images alone, so without this the mirror's last picture stays on top of the wall -
        // measured: after a return, Safari's window covered the cards and the captions underneath.
        writer.clear()
        installSignalCleanup()
        installResizeHandler()
        // The desk is built *before* input: `startInput()` decides the wall's key policy from
        // wall mode, and it runs on the main queue before the reader thread exists — the only
        // race-free moment to read that. The first paint stays after it, so input is installed
        // before the wall appears.
        wallCanvas = WallCanvas(symbols: options.symbols)
        // A returning mirror brings the page the reader was on, and — when it failed — the sentence
        // it failed with. Both arrive in argv because the process that knew them was replaced.
        var state = WallState()
        if let at = options.wallAt {
            state.stageStart = at.stage
            state.cardStart = at.card
        }
        wallState = state
        if let said = options.said {
            mirrorNotice = .mirrorStopped(exit: said.exit, message: said.text.isEmpty ? nil : said.text)
        }
        wallMode = true
        startInput()
        refreshWall(force: true)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.refreshWall(force: false) }
        timer.resume()
        wallTimer = timer
    }

    /// The pane the wall draws into: the tty's size, with `--pane` honoured the way the bench and
    /// the mock path honour it (how a wrong-looking wall gets reproduced at an exact size).
    private func wallGeometry() -> (cols: Int, rows: Int, cellW: Double, cellH: Double) {
        var geometry = TermGeometry.read()
        if let pane = options.pane { geometry.cols = pane.cols; geometry.rows = pane.rows }
        let cell = geometry.cellSize
        return (cols: max(1, geometry.cols), rows: max(1, geometry.rows),
                cellW: cell.w, cellH: cell.h)
    }

    /// Re-enumerate the world and repaint — but only when the wall would actually look different:
    /// the display list, the window list (order included, it is "most recently used first"), or the
    /// pane size. That comparison is also what keeps an idle wall at 0 B/s with a 1 s tick.
    private func refreshWall(force: Bool) {
        guard !cleanedUp, wallState != nil else { return }
        let pane = wallGeometry()
        let model = WallSource.model()
        guard force || model != wallModel || pane.cols != wallPane?.cols
                || pane.rows != wallPane?.rows || pane.cellW != wallPane?.cellW
                || pane.cellH != wallPane?.cellH else { return }
        wallModel = model
        wallPane = pane
        // The world can shrink under a static wall (a display unplugged, a window closed) while the
        // offsets still point past the end; clamping here is what keeps the shelf from going blank.
        // The clamp takes the layout's *effective* page size: below 28 columns `WallLayout.make`
        // shows fewer cards per page than `state.per` asks for, and clamping against the request
        // would leave the last page unreachable (the bar jumps to the layout's `maxStart`, the clamp
        // pulls it back). The layout is built from the state as it is now, then the state is
        // clamped, then `drawWall()` builds it again — two pure calls on one number, no third
        // definition of "how many cards fit".
        if let state = wallState {
            let layout = state.layout(cols: pane.cols, rows: pane.rows,
                                      displays: model.displays.count,
                                      windows: model.windows.count,
                                      stageAspect: stageAspect(model, state),
                                      cellAspect: pane.cellH / pane.cellW)
            wallState?.clamp(displays: model.displays.count, windows: model.windows.count,
                             per: layout.per)
        }
        drawWall()
    }

    /// Paint from the cached model. The click path uses this and never `refreshWall(force: true)`:
    /// a click has to be drawn against the list it was made on, and re-enumerating every window
    /// dictionary inside a click handler is not a thing to do.
    private func drawWall() {
        guard let state = wallState, let pane = wallPane else { return }
        let layout = state.layout(cols: pane.cols, rows: pane.rows,
                                  displays: wallModel.displays.count,
                                  windows: wallModel.windows.count,
                                  stageAspect: stageAspect(wallModel, state),
                                  cellAspect: pane.cellH / pane.cellW)
        let model = wallModel
        let panels = wallPanels(layout: layout, model: model, pane: pane)
        guard !panels.isEmpty else {
            // Nothing to photograph (a mock, a display whose id nobody filled in): the phase-1
            // wall, placeholders and all.
            paintWall(layout: layout, model: model, panels: [], pictures: [], failures: [:])
            return
        }
        // The first paint does not wait for pixels. ScreenCaptureKit's first call in a session can
        // take seconds - a permission round-trip through replayd, a window server that just woke up -
        // and until this line existed the wall wrote *nothing* until the capture came back, so a slow
        // first capture was an empty alternate screen with no way to tell it apart from a crash.
        // The placeholders are the phase-1 wall, they cost a few KB of text, and the picture frame
        // overwrites them a moment later. Later paints skip this: a repaint is cheap only because it
        // is one frame, and by then the previous picture is already on screen.
        if !wallPaintedOnce {
            wallPaintedOnce = true
            paintWall(layout: layout, model: model, panels: [], pictures: [], failures: [:])
        }
        // One repaint at a time: a second capture while the first is in flight would put pictures
        // from two different models on one screen.
        guard wallPaintTask == nil else {
            wallDirtyWhilePainting = true
            return
        }
        wallPaintTask = Task { [weak self] in
            let result = await WallPictures.capture(panels)
            // A plain `let` before the hop: capturing the weak binding itself into the main-actor
            // closure is what the compiler warns about, and a race here would be a wall painted
            // from a freed Desk.
            guard let desk = self else { return }
            await MainActor.run {
                desk.wallPaintTask = nil
                desk.paintWall(layout: layout, model: model, panels: panels,
                               pictures: result.pictures, failures: result.failures)
                if desk.wallDirtyWhilePainting, !desk.cleanedUp {
                    desk.wallDirtyWhilePainting = false
                    desk.refreshWall(force: true)
                }
            }
        }
    }

    /// Which panels this frame wants a picture for, from the layout and the world.
    ///
    /// Pure plumbing: the decisions (which display, which page, how big) were all made by
    /// `WallLayout` and `WallPanels`; this only supplies ids and aspects.
    /// The on-stage display's width/height, or `nil` when the model has nothing to measure (a mock,
    /// a display whose id nobody filled in). The layout uses it to give the stage band exactly the
    /// rows its picture needs (design §6.6).
    private func stageAspect(_ model: WallModel, _ state: WallState) -> Double? {
        guard state.stageStart >= 0, state.stageStart < model.displays.count else { return nil }
        let display = model.displays[state.stageStart]
        guard display.width > 0, display.height > 0 else { return nil }
        return Double(display.width) / Double(display.height)
    }

    private func wallPanels(layout: WallLayout, model: WallModel,
                            pane: (cols: Int, rows: Int, cellW: Double, cellH: Double)) -> [WallPanel] {
        var stage: PanelSource?
        if model.displays.indices.contains(layout.stageStart) {
            let display = model.displays[layout.stageStart]
            // A display with no id cannot be captured; asking for id 0 would only produce a mask.
            if display.id != 0, display.width > 0, display.height > 0 {
                stage = PanelSource(kind: .display(display.id),
                                    aspect: Double(display.width) / Double(display.height))
            }
        }
        let cards: [PanelSource?] = layout.cards.indices.map { slot in
            let index = layout.cardStart + slot
            guard model.windows.indices.contains(index) else { return nil }
            let window = model.windows[index]
            let width = window.bounds.width, height = window.bounds.height
            guard width >= 1, height >= 1 else { return nil }
            return PanelSource(kind: .window(window.windowID),
                               aspect: Double(width) / Double(height))
        }
        return WallPanels.plan(layout: layout, cellW: pane.cellW, cellH: pane.cellH,
                               stageSource: stage, cardSources: cards)
    }

    /// Paint the text, then the pictures on the cells the text was told to leave alone.
    private func paintWall(layout: WallLayout, model: WallModel, panels: [WallPanel],
                           pictures: [WallPictures.Picture], failures: [Int: PanelCaptureError]) {
        guard let canvas = wallCanvas, let pane = wallPane, let state = wallState else { return }
        var paints = WallSlotPaints()
        for panel in panels {
            paints.mark(slot: panel.slot, failures[panel.slot] == nil ? .picture : .mask)
        }
        // A frame with no pictures and a *reason* says the reason once, in the footer: four boxes
        // reading "no picture" answer "what", not "why".
        //
        // Two reasons, in this order. `Terminal.app` first, because it is the stronger statement -
        // it cannot draw a picture whatever the user grants. Then the grant: every panel denied is a
        // situation, not four independent misses, and repainting will not change it.
        if let notice = mirrorNotice { paints.notice = notice }
        if pictures.isEmpty, !panels.isEmpty {
            let program = ProcessInfo.processInfo.environment["TERM_PROGRAM"]
            if program == "Apple_Terminal" {
                paints.notice = .terminalCannotShowPictures(terminal: "Terminal")
            } else if panels.allSatisfy({ denied($0.slot, failures) }) {
                paints.notice = .screenRecordingDenied(terminal: program)
            }
        }
        writer.writeChrome(canvas.draw(cols: pane.cols, rows: pane.rows, model: model,
                                       layout: layout, focus: state.focus,
                                       cellW: pane.cellW, cellH: pane.cellH, paints: paints))
        guard !pictures.isEmpty else { return }
        // The same frame contract the tile path uses: `emitPanel` only appends, `endFrame`
        // flushes. Without the pair the pictures would sit in the writer's buffer forever - which
        // is exactly what the first live run looked like: blank panels and no bytes on the wire.
        writer.beginFrame()
        for picture in pictures {
            // `panel.rect` is the picture's own rectangle (WallPanels.make), so mask, placeholder,
            // caption and picture are one box, and the cells outside it stay unpainted.
            writer.emitPanel(id: picture.panel.imageID, placementID: picture.panel.placementID,
                             row: picture.panel.rect.row, col: picture.panel.rect.col,
                             cols: picture.panel.rect.cols, rows: picture.panel.rect.rows,
                             pixels: picture.pixels, width: picture.width,
                             height: picture.height, level: Self.wallPanelLevel,
                             // RGBA: the bars are transparent so the wall's own background shows
                             // through (design §6.6) - the mirror's tiles stay opaque RGB.
                             format: .rgba, sync: writer.perTileSync)
        }
        writer.endFrame()
    }

    /// Is this slot's failure specifically "the grant is missing"?
    ///
    /// `denied` also covers a user who declined the prompt, which is the same fix from the reader's
    /// side, so both are reported the same way. Anything else (a window that closed, a payload that
    /// would not compress) is that one slot's problem and stays a mask.
    private func denied(_ slot: Int, _ failures: [Int: PanelCaptureError]) -> Bool {
        if case .denied = failures[slot] { return true }
        return false
    }

    /// What a click on a picture does: *become* the mirror, and come back to the wall when it leaves.
    ///
    /// `execv`, not spawn-and-wait. Two live processes of one executable cannot both be
    /// ScreenCaptureKit clients: the newcomer's stream dies at once with `-3805` ("failed during
    /// stream due to application connection being interrupted"). Measured on this machine, four ways:
    /// the same child streams a window fine on its own, fails while a wall is running, fails while
    /// that wall is `SIGSTOP`ped even before it paints, and succeeds again when the very same binary
    /// is copied to another path and started there — so what collides is the executable's identity
    /// with the window server, not CPU, not the capture rate, not the tty. Replacing the image leaves
    /// exactly one client, and it is the one that paints.
    ///
    /// The cost is that nothing is left to wait for the mirror, so the mirror returns by `exec`ing
    /// the wall again. That is why the wall's offsets and a failed mirror's sentence travel in argv
    /// (`--wall-at`, `--said`): they are the state that has to survive a replaced process.
    private func enterFocus(_ focus: WallState.Focus) {
        guard let state = wallState else { return }
        let at = (stage: state.stageStart, card: state.cardStart)
        let arguments: [String]
        switch focus {
        case .display:
            // The stage is a whole display: the mirror shows the display the pointer is on, which is
            // the one the reader is looking at when they click it.
            arguments = Self.mirrorArguments(windowID: nil, cell: options.cell, at: at)
        case .window(let index):
            guard wallModel.windows.indices.contains(index) else { return }
            arguments = Self.mirrorArguments(windowID: wallModel.windows[index].windowID,
                                             cell: options.cell, at: at)
        }
        // A handed-over pane has no cursor: the wall that comes back starts on the plain grid, not
        // on a pick the reader made in a session that no longer exists.
        wallState?.focus = nil
        handOver(arguments)
    }

    /// The mirror's command line. Pure, so the one thing that can be wrong about it (a flag that
    /// silently means something else in the mirror) is a test and not a manual check.
    ///
    /// `--cell` is forwarded: a pty that reports no pixel size is exactly the case where the mirror
    /// would otherwise assume the built-in cell and draw a picture of the wrong size. `--wall-at` is
    /// where the wall was, i.e. where this process turns back into a wall.
    static func mirrorArguments(windowID: CGWindowID?, cell: (w: Double, h: Double)?,
                               at: (stage: Int, card: Int)?) -> [String] {
        var arguments = windowID.map { ["--window", String($0)] } ?? ["--mirror"]
        if let cell {
            arguments += ["--cell", "\(Int(cell.w))x\(Int(cell.h))"]
        }
        if let at {
            arguments += ["--wall-at", "\(at.stage):\(at.card)"]
        }
        return arguments
    }

    /// The wall's command line, as a mirror spells it on its way back. Pure, and the exact inverse of
    /// the parser — `wallArguments` then `parseArguments` has to be a round trip, or the reader
    /// returns to a different shelf than the one they left.
    static func wallArguments(at: (stage: Int, card: Int)?,
                              exit: Int32 = 0, said: String? = nil) -> [String] {
        var arguments = ["--wall"]
        if let at {
            arguments += ["--wall-at", "\(at.stage):\(at.card)"]
        }
        if exit != 0 {
            arguments += ["--said", String(exit), said ?? ""]
        }
        return arguments
    }

    /// Hand the pane over: stop owning it, then replace this process with the mirror.
    ///
    /// `writer.clear()` is not cleanup, it is the picture: the wall's kitty placements belong to this
    /// terminal and would stay on screen under the mirror's tiles. The alternate screen itself is
    /// left *entered* — the mirror starts with `beginSession()` a moment later, and bouncing through
    /// the main screen in between is a flash of the shell for no reason. The way *back* does leave it
    /// (`shutdown`): a terminal that keeps pictures keyed to a screen has to lose that screen, and the
    /// direction that was measured to need it is the return (TROUBLESHOOTING 23d).
    private func handOver(_ arguments: [String]) {
        guard !mirroring else { return }
        mirroring = true
        wallTimer?.cancel()
        wallTimer = nil
        input?.stop()
        input = nil
        writer.clear()
        // In the log and never on the pane: a report of "clicking that card does nothing" is
        // answerable with what was asked for plus what the mirror said on its way back.
        Log.write("krd: handing the pane to krd \(arguments.joined(separator: " "))\n")
        Self.execSelf(arguments)
        // Only on failure to exec (no image, no permission): the wall is the thing that can still be
        // shown, so it comes back with the reason in its footer.
        Log.write("krd: could not start the mirror (krd \(arguments.joined(separator: " ")))\n")
        mirrorNotice = .mirrorStopped(exit: -1, message: "could not start krd")
        mirroring = false
        resumeWall()
    }

    /// Take the pane back and put the wall on it again (only reached when `exec` failed).
    private func resumeWall() {
        writer.beginSession()
        // Same reason as `runWall`: the images in this pane belong to whatever drew before it.
        writer.clear()
        wallPaintedOnce = false
        refreshWall(force: true)
        startInput()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.refreshWall(force: false) }
        timer.resume()
        wallTimer = timer
    }

    /// Replace this process with `krd <arguments>`. Returns only when the image could not be started.
    ///
    /// `execv` on `Bundle.main.executablePath` rather than on `argv[0]`: the latter is what the shell
    /// typed (`wall`, a relative path), and after a `chdir` or with a PATH-only name it need not
    /// resolve at all.
    static func execSelf(_ arguments: [String]) {
        guard let executable = Bundle.main.executablePath ?? CommandLine.arguments.first else { return }
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv where pointer != nil { free(pointer) } }
        execv(executable, argv)
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
        var window: (pid: pid_t, id: CGWindowID, name: String, title: String)?
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
            var windowTarget: (pid: pid_t, id: CGWindowID, name: String, title: String)?
            if let app = window.owningApplication, app.processID > 0 {
                windowTarget = (app.processID, window.windowID, app.applicationName,
                                window.title ?? "")
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
            // Never a frame at all: there is no last frame to keep, so "keeping" it means a blank
            // pane that never comes back (and, under the wall, a wall stuck in `waitpid`).
            guard framesSinceStreamStart > 0 else { failCapture(reason); return }
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
        // A stream that dies before its first frame was never a stream: the filter names a window
        // that closed or minimised away, a display that went to sleep, or Screen Recording was
        // pulled. Every retry fails identically — five of them cost the reader 23 s of a frozen
        // picture — and when this process is a wall's child the wall is blocked on `waitpid` for
        // exactly that long with no way out but `Ctrl-\`. Say why and leave instead.
        guard framesSinceStreamStart > 0 else { failCapture(Self.setupFailure(error)); return }
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

    /// A capture failure no retry can fix: say it where it can be read and leave with a non-zero
    /// status.
    ///
    /// On stderr, because that is the channel whose reader knows what to do with it: the terminal
    /// shows the sentence above the shell prompt after the session is torn down, and the wall (whose
    /// child's stderr is a temp file) reads that file back and paints the line in its footer. The
    /// log gets it too, so a `--log` run explains itself.
    private func failCapture(_ message: String) {
        Log.write("krd: \(message)\n")
        FileHandle.standardError.write(Data("krd: \(message)\n".utf8))
        failureSaid = message
        exitStatus = 1
        shutdown()
    }

    /// What a mirror that never showed a frame says before it exits, in the words of the same four
    /// failure modes a wall's mask uses (`PanelCapture.classify`) — one vocabulary for both, so the
    /// footer's sentence and a card's mask can never disagree about why.
    static func setupFailure(_ error: Error) -> String {
        switch PanelCapture.classify(error) {
        case .windowGone:
            return "the window closed before it could be shown"
        case .denied:
            return "Screen Recording is off for this terminal"
        case .noPixelBuffer:
            return "the capture produced no frames"
        case .failed(let message):
            return message
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

    // MARK: adaptive scale (issue #64)

    /// One frame's worth of backpressure, from the frame path.
    ///
    /// "Late" is the causal version of "the link is losing": the *write* took longer than the
    /// interval the frame had to fit in (`1000/fps`). Two reasons it is `write_ms` and not the whole
    /// pipeline or the encoder: a slow encoder on a fast link is a different problem (and #26's
    /// answer to it is a cheaper encoder, not fewer pixels), while a full pty is where a frame
    /// actually sits — #26 measured 619 ms per write on a 20 MB/s link. Using the whole frame's
    /// duration instead would also call a *content-limited* stream late: a photo repaint that only
    /// happens twice a second takes longer than 50 ms to encode on any machine.
    ///
    /// Called on the frame thread, which is serial, so the governor needs no lock of its own.
    private func noteFrame(writeMs: Double) {
        guard options.scaleAuto else { return }
        framesSinceTick += 1
        let late = writeMs > 1000.0 / Double(max(options.fps, 1))
        if late { lateSinceTick += 1 }
        let now = benchNowMs() / 1000.0
        if let change = governor.observe(at: now, late: late) {
            DispatchQueue.main.async { [weak self] in self?.applyScaleChange(change) }
        } else {
            governor.settle(at: now)
        }
    }

    /// Step the capture resolution in place: the same `updateSource` a pan uses (#57), so the stream
    /// is not torn down and the terminal never loses its picture (issue #64).
    private func applyScaleChange(_ change: ScaleGovernor.Change) {
        guard options.scaleAuto, let geometry, change.to != effectiveScale else { return }
        effectiveScale = change.to
        applyLayout(geometry: geometry)
        Log.write("krd: \(change.line)\n")
        panCapture()
    }

    private func applyLayout(geometry: TermGeometry) {
        let crop = Viewport.crop(full: fullRect, scale: zoomScale, focus: zoomFocus)
        let aspect = crop.width / max(crop.height, 1)
        // The status line owns the last row (plus whatever a panel asked for). The picture is
        // fitted into the rest, so the cell math, the mouse mapping and the tile grid all stay in
        // the same coordinate space.
        // The rows the mirror's own bar owns at the top of the pane, and the rest: the picture may
        // use what is left after the bar and the chrome, and its block is centred in that area
        // (design §6.7). Slice of the same subtraction whether or not either is on.
        let barRows = barEnabled ? 1 : 0
        var pictureRows = max(1, geometry.rows - barRows)
        if chromeEnabled, pictureRows > 4 {
            let panelRows = chromeState.panel?.height ?? 0
            pictureRows = max(3, pictureRows - 1 - min(panelRows, pictureRows - 4))
        }
        var paneGeometry = geometry
        paneGeometry.rows = pictureRows
        let area = (top: 1 + barRows, left: 1, cols: geometry.cols, rows: pictureRows)
        // The source's own size, so the grid never asks for a box bigger than the source
        // (issue #69: ScreenCaptureKit pads that with black instead of upscaling).
        let layout = TileGrid.make(geometry: paneGeometry, aspect: aspect,
                                   tileCols: options.tileCols, tileRows: options.tileRows,
                                   bpp: writer.format.bytesPerPixel, scale: effectiveScale,
                                   source: Viewport.layoutSource(crop: crop, full: fullRect),
                                   area: area)
        // `chromeAvailable`, not `chromeEnabled`: the bar alone is enough reason to lay the chrome
        // out (a handed-over mirror runs `--bar` with no `--dev`), and gating on the `--dev` flag
        // here left `chromeGeometry` nil, so `drawChrome` bailed and the bar never appeared. Caught
        // by `testAMockMirrorDrawsItsBar`; the merge of #76 is where this gate regressed.
        if chromeAvailable {
            // --full-frame draws one image the size of the picture, so the chrome still fits.
            chromeGeometry = Chrome.layout(paneCols: geometry.cols, paneRows: geometry.rows,
                                           imageCols: layout.originCol - 1 + layout.paneCols,
                                           imageRows: barRows + pictureRows,
                                           bar: barRows > 0, dev: chromeEnabled,
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
                            cols: layout.paneCols, rows: layout.paneRows, sourceRect: crop,
                            originCol: layout.originCol, originRow: layout.originRow,
                            originPixelX: (layout.originCol - 1) * Int(layout.cellW.rounded()),
                            originPixelY: (layout.originRow - 1) * Int(layout.cellH.rounded()))
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
        // The budget and the frame count belong to one stream: a restart that does deliver frames
        // must not be given up on because of the failures that came before it.
        framesSinceStreamStart = 0
        let crop = cropForFilter()
        Task { [weak self] in
            guard let self else { return }
            await self.capturer.stop()
            do {
                try await self.capturer.start(filter: filter, sourceRect: crop,
                                              width: layout.pixelW, height: layout.pixelH,
                                              fps: self.options.fps)
            } catch {
                // A restart that throws before any frame arrived is the setup failure again (the
                // window is gone, the grant was pulled): one sentence beats a blank pane. Hopped to
                // the main queue because `failCapture` tears the session down, and that is the
                // queue every other teardown runs on.
                guard self.framesSinceStreamStart > 0 else {
                    let message = Desk.setupFailure(error)
                    DispatchQueue.main.async { self.failCapture(message) }
                    self.captureRestarting = false
                    return
                }
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
    /// Which window the window server would deliver a click at `point` to: the first on-screen window
    /// whose bounds contain it, since the list comes back front to back.
    private func topmostWindow(at point: CGPoint) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        for entry in list {
            // Only normal app windows: the Dock's own 1920x1200 window sits at layer 20 and would
            // swallow every hit test otherwise.
            guard let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let number = entry[kCGWindowNumber as String] as? Int,
                  (entry[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
                  let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double else { continue }
            if CGRect(x: x, y: y, width: w, height: h).contains(point) {
                return CGWindowID(number)
            }
        }
        return nil
    }

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
        let emittedBefore = writer.framesEmitted

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
        defer {
            lastPipeMs = benchNowMs() - started
            // A deduped frame writes nothing, so it says nothing about the pipe (issue #64).
            if writer.framesEmitted != emittedBefore {
                noteFrame(writeMs: writer.lastWriteMs)
            }
        }
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
                                 row: grid.originRow, col: grid.originCol,
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
        // The wall has no picture to re-fit: the pane changed size, so the canvas forgets its
        // previous grid (the next draw is a full repaint at the new width) and the model is re-read.
        // The guard below would no-op here — a wall session has no filter and no mock.
        if wallState != nil {
            wallCanvas?.invalidate()
            refreshWall(force: true)
            return
        }
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
            // Frames the write side could not keep up with, since the previous tick (issue #64).
            let late = self.lateSinceTick
            let seen = self.framesSinceTick
            self.lateSinceTick = 0
            self.framesSinceTick = 0
            let line = String(
                format: "stats: %d tiles/s  %d dirty  %d KB  %.2f MB/s  ms[zlib=%.0f write=%.0f max=%.0f over5=%d]  %dx%d px %dx%d cells  cap=%d/%d/%d idle=%d bad=%d pipe=%.1f late=%d/%d\n",
                tiles,
                self.lastDirtyCount,
                writer.lastFrameBytes / 1024,
                mbps,
                writer.lastCompressMs, writer.lastWriteMs, writer.writeMaxMs, writer.writeOver5Ms,
                layout?.pixelW ?? 0, layout?.pixelH ?? 0,
                layout?.paneCols ?? 0, layout?.paneRows ?? 0,
                capturer.framesDelivered, capturer.framesSkipped, capturer.callbacks,
                capturer.idleFrames, capturer.badFrames,
                self.lastPipeMs, late, frames
            )
            Log.write(line)
            statsJSON?.write(tiles: tiles, dirty: self.lastDirtyCount, kb: writer.lastFrameBytes / 1024,
                             mbps: mbps, zlibMs: writer.lastCompressMs, writeMs: writer.lastWriteMs,
                             writeMaxMs: writer.writeMaxMs, writeOver5: writer.writeOver5Ms,
                             px: (layout?.pixelW ?? 0, layout?.pixelH ?? 0),
                             cells: (layout?.paneCols ?? 0, layout?.paneRows ?? 0),
                             delivered: capturer.framesDelivered, skipped: capturer.framesSkipped,
                             callbacks: capturer.callbacks, idle: capturer.idleFrames,
                             bad: capturer.badFrames, pipeMs: self.lastPipeMs,
                             late: late, frames: seen, scale: self.effectiveScale)
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
        guard chromeAvailable else { return }
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
        m.scale = effectiveScale
        m.scaleAuto = options.scaleAuto
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
        m.title = barTitle
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
        // Read once, here: `startInput()` runs on the main queue before `reader.start()` starts the
        // reader thread, so this is the only race-free moment to ask whether the desk is a wall.
        let wallMode = self.wallMode
        let reader = InputReader(
            viewport: { [weak self] in
                self?.currentViewport() ?? Viewport(pixelWidth: 1, pixelHeight: 1, cols: 1, rows: 1,
                                                    sourceRect: .zero)
            },
            // Nothing is injected in wall mode either: there is no remote desktop behind a wall.
            // That half is `forward:`, not `dryRun:` — `dryRun` still *logs* what it would have
            // posted (`input: key code=12`), and that log goes to the pane, which is the wall.
            // Measured in a pty session: one keypress scrolled the whole picture.
            dryRun: options.dryRun, forward: !wallMode) { [weak self] in self?.shutdown() }
        // The wall has no keyboard vocabulary — every key belongs to a remote desktop that does not
        // exist in this mode (design §1/§5) — so nothing is delegated to the chrome's prefix state
        // either. `WallInput.consumes` is that policy, in `WallCanvas.swift`: it says no to every
        // byte except `0x1C`, which `Input.swift` takes as "leave" after this closure is done and
        // which is the only key a wall still owes the user.
        reader.onChromeKey = { [weak self] byte in
            guard !wallMode else { return WallInput.consumes(byte) }
            return self?.chromeKey(byte) ?? false
        }
        reader.onChromeClick = { [weak self] row, col, wheel in
            self?.chromeClick(row: row, col: col, isWheel: wheel)
        }
        reader.trace = options.debug
        reader.ime = options.ime
        if options.debug {
            Log.write("krd: ime \(options.ime.rawValue) (auto = keys where the terminal reports them, "
                      + "raw = keys only, unicode = inject the character)\n")
        }
        if let target = windowTarget {
            reader.targetPid = { [weak self] in self?.aliveWindowPid() }
            reader.targetWindow = { [weak self] in self?.windowTarget?.id }
            reader.topmostWindow = { [weak self] point in self?.topmostWindow(at: point) }
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
        guard chromeAvailable, chromeDirty, let geometry = chromeGeometry else { return }
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

    /// The wall consumes every click on the pane: the whole pane is text, so "outside the picture"
    /// is the normal case there, and a cell the wall does not know is swallowed rather than
    /// forwarded to the remote desktop (design §8: the route decision is "inside the picture
    /// rect", and the wall has no picture at all).
    private func chromeClick(row: Int, col: Int, isWheel: Bool) {
        if wallMode {
            // A wheel report is not a click: it scrolls the shelf it is over instead of entering
            // the card under the cursor (a two-finger scroll used to enter a window by accident).
            // This closure runs on the *reader* thread (`InputReader.onChromeClick`), while the
            // wall's 1 s tick, `handleResize()` and `shutdown()` all own the desk on the main
            // queue. Mutating `wallState` and repainting from here would race that tick on the
            // canvas's previous-cell grid and on the shelf offsets, so the wall branch only hops:
            // after this line everything the wall owns is touched by exactly one thread.
            let wheel = isWheel ? 1 : 0
            DispatchQueue.main.async { [weak self] in
                self?.wallClick(row: row, col: col, wheel: wheel)
            }
            return
        }
        guard chromeAvailable, let geometry = chromeGeometry else { return }
        switch chrome.hitTest(row: row, col: col, geometry: geometry) {
        case .statusSegment(let id):
            // The bar's one control: a click on `[ - ]` (or on the traffic lights, which is what a
            // red one does) shrinks this window back into the wall. Same path as `Ctrl-\`, so the
            // two ways out cannot drift.
            if id == "shrink" {
                shutdown()
                return
            }
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

    /// The wall half of `chromeClick`, on the main queue — the same queue as the 1 s tick, so the
    /// model, the canvas and the offsets are never read and written from two threads (see the hop
    /// in `chromeClick` for the whole reason).
    /// A click on a wall cell, or — when `wheel` is non-zero — a wheel notch over it.
    ///
    /// The wheel only carries a direction here, not a distance: one notch is one display or one
    /// card, because a page per notch makes a trackpad flick skip most of the shelf.
    private func wallClick(row: Int, col: Int, wheel: Int = 0) {
        guard var state = wallState, let pane = wallPane else { return }
        let displays = wallModel.displays.count
        let windows = wallModel.windows.count
        let layout = state.layout(cols: pane.cols, rows: pane.rows,
                                  displays: displays, windows: windows,
                                  stageAspect: stageAspect(wallModel, state),
                                  cellAspect: pane.cellH / pane.cellW)
        // nil = header, the divider, the gap column, a dead end of the bar, a shelf with nothing to
        // scroll: those cells belong to the wall too, so the gesture ends here.
        let action = wheel == 0 ? layout.action(row: row, col: col)
                                : layout.wheelAction(row: row, col: col, direction: wheel)
        guard let action else { return }
        state.apply(action, displays: displays, windows: windows, per: layout.per)
        wallState = state
        switch action {
        case .enterStage(let index): enterFocus(.display(index))
        case .enterCard(let index): enterFocus(.window(index))
        default: break
        }
        drawWall()
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
        // The wall's 1 s tick holds the desk (and the model) alive: without this, a torn-down wall
        // keeps enumerating the window server and painting into a session that is already gone.
        wallTimer?.cancel()
        wallTimer = nil
        mock?.stop()
        mock = nil
        input?.restore()
        // A mirror this pane was handed to becomes the wall again: `exec`, for the same reason the
        // hand-over was an `exec` (one ScreenCaptureKit client per executable).
        //
        // `endSession()` still runs first, and that is the fix for a measured bug, not politeness:
        // the mirror's tiles are kitty placements in *this* alternate screen, and a terminal may key
        // them to that screen and keep showing them after the wall's `a=d,d=a` has been answered
        // (Rex did: the shelf painted, the mirror's last picture floated on top of the cards for
        // good). Leaving the alternate screen before the exec tears down the screen the pictures
        // were attached to; the wall builds a new one. The price is one frame of the shell between
        // the two modes — the alternative was a picture no delete could remove.
        if let at = options.wallAt {
            writer.endSession()
            Self.execSelf(Self.wallArguments(at: at, exit: exitStatus, said: failureSaid))
        }
        writer.endSession()
        exit(exitStatus)
    }
}

enum DeskError: Error, LocalizedError, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): return text
        }
    }

    /// Our own sentence *is* the description. Without this, `localizedDescription` on a `DeskError`
    /// is Foundation's "The operation couldn't be completed. (krd.DeskError error 0.)", and every
    /// place that reports an error to the reader through `localizedDescription` (a restart's log
    /// line, `PanelCapture.classify`'s last bucket) would lose the one thing that was said.
    var errorDescription: String? { description }
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
        // A mirror that never started still owes the reader their wall back: same sentence, same
        // footer, instead of an exit that leaves them looking at a terminal that is no longer krd's.
        if let at = options.wallAt {
            Desk.execSelf(Desk.wallArguments(at: at, exit: 1, said: "\(error)"))
        }
        exit(1)
    }
}
RunLoop.main.run()
