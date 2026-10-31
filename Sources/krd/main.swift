import Foundation
import ApplicationServices
import AppKit
import CoreGraphics
import ScreenCaptureKit
import krdcore

struct Options {
    var fps = 20
    /// The rate the picture drops to while the terminal reports focus-out (`CSI O`, DECSET 1004): the
    /// pane is in the background, so nobody is looking at it. `0` freezes the picture instead.
    ///
    /// The default is 1 rather than 0 on purpose (issue #110): a focus-in report can be lost (a
    /// multiplexer that ate it, a terminal that stopped answering), and a rate of 0 would then leave
    /// the pane dead with no way back but a restart. At 1 fps a lost report costs one frame a second
    /// until the next keystroke, which is also what wakes it (`InputReader.onFocus`).
    var unfocusedFps = 1
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
    /// How much colour the encoder may drop (`--quality`, 0...100, default 80 = adaptive 5-6-5).
    /// `--no-quantise` is kept as an alias for 100 so old command lines keep meaning the same thing.
    var quality = QualityBudget.default
    /// `--quality auto`: let `QualityGovernor` spend colour, then frame rate, before the resolution
    /// governor is allowed to take anything.
    var qualityAuto = false
    /// Whether `--quality` (or `--no-quantise`) was typed. The selftest's sha256 is a byte contract,
    /// so naming a lossy rung next to it is a usage error -- the default must keep working.
    var qualityPinned = false
    /// How much colour the **landing screen's** pictures may lose (`--wall-quality`, 0...100, default
    /// 70 = 5-5-5). Separate from `--quality` on purpose (issue #88): the mirror's number answers a
    /// per-frame question and its ladder moves it as the pipe falls behind, while the wall paints once
    /// per change and the reader is waiting for *a* picture, over the same link that then carries it.
    /// One knob, one axis: bits per pixel. Never a smaller picture (see `QualityBudget.wall`).
    var wallQuality = QualityBudget.wall
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
    /// Device pixels per reported pixel for the *pictures* (see `runWall`): a terminal may report
    /// its geometry in points and still draw images 1:1 in device pixels. 0 = decide from the
    /// geometry source (2 when only ANSI answers were available, 1 when the pty reported pixels).
    var dpr: Double? = nil
    /// Draw the wall's pictures as kitty *unicode placeholders* (`U=1`): the terminal then fits the
    /// image into the picture's cell rectangle, so no estimate of the cell's pixel size can put the
    /// desktop in the corner (`emitPanelAsPlaceholder`). `nil` = ask the terminal once at startup
    /// (`TermGeometry.supportsPlaceholders`), which is the default: guessing is what this replaces.
    var placeholders: Bool? = nil
    /// Draw a test pattern instead of the desk: no window server, no Screen Recording grant, and the
    /// picture's own border is the measurement (`DemoPicture`, TROUBLESHOOTING 23f).
    var demo = false
    /// `--square`: no rounded corners on the wall's pictures (they are rounded by default).
    var square = false
    /// Force the pane size in cells (bench/selftest only; a real run reads it from the tty).
    var pane: (cols: Int, rows: Int)? = nil
    /// Wrap every graphics APC in tmux's DCS passthrough envelope (`--passthrough`, issue #107).
    /// `auto` (the default) means "when `TERM` says the pane is a multiplexer", which is off for a
    /// normal terminal, so the byte contract is untouched unless someone is really in tmux.
    /// See `TmuxPassthrough.resolve` for the precedence against `KRD_PASSTHROUGH`.
    var passthrough: PassthroughMode = .auto
    /// Whether `--passthrough` was typed. Only then does it beat `KRD_PASSTHROUGH`, so a shell
    /// profile that sets the variable cannot be overridden by the default.
    var passthroughPinned = false

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

/// A command line krd refuses: one sentence for stderr, and the documented "usage" status.
///
/// `parseArguments` throws this instead of calling `exit(2)` itself, so the failure is a value a unit
/// test can name (`--nonsense`, `--fps` with nothing after it) instead of a process that has to be
/// spawned in a pty to be observed. Exactly one place turns it into a diagnostic and a status: the
/// top of `main`. It mirrors `AXOptions.parse`'s `AXFailure.usage`, so the binary's two flag parsers
/// finally agree that unknown input is an error (issue #122).
struct UsageError: Error, Equatable, CustomStringConvertible {
    /// What the process leaves with: the documented "usage" code (README), shared with `krd ax`'s
    /// `AXExit.usage` so the two flag parsers cannot drift about which status a usage error is.
    static let status = AXExit.usage.rawValue

    let message: String

    init(_ message: String) { self.message = message }

    var description: String { message }
}

/// `<stage>:<card>`, the wall's two scroll offsets in one flag (`--wall-at`).
///
/// Negative and non-numeric halves are refused rather than clamped: this flag is written by krd for
/// krd, so a malformed one is a bug in the hand-over, not a reader's typo to be patched over.
/// `parseArguments` turns that nil into a usage error naming the flag, like every other malformed
/// value, so a broken hand-over stops before it can paint the wrong page.
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
      --unfocused-fps <n> the rate the picture drops to while the terminal reports focus-out
                          (DECSET 1004, default 1): any key, click or wheel brings the full rate
                          back; 0 freezes the picture instead; terminals that never report focus
                          (tmux without `set -g focus-events on`) behave exactly as before
      --display <i>       display index from --list (default: the one under the pointer)
      --window <q>        capture a single window: numeric id or title substring
      --zoom <f>          magnify: 2 shows half the source at twice the density, cropped on
                          the capture side, so a zoomed frame costs fewer pixels, not more
      --zoom-at <x,y>     source point the zoom is centred on (global points; default: pointer)
      --zoom-follow       pan the crop when the pointer reaches the edge of the picture
      --tile <c>x<r>      dirty-tile size in cells (default 8x4; 16x8 = fewer, bigger images)
      --format <f>        wire pixel format: rgb (default, f=24) or rgba (f=32)
      --cell <w>x<h>      pin the cell size in px: it beats the terminal's own answer (default:
                          measure with CSI 16t / ws_xpixel, else 8x16)
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
      --quality <0-100|auto>
                          how much colour the picture may lose: 100 keeps every pixel, 80 (the
                          default) is 5-6-5 on tiles that proved incompressible, 70 is 5-5-5 and
                          50 is 4-4-4 for everything. Values in between round down to the next
                          rung (79 is 80). Bit depth is the axis: on a photograph 70 costs 1.48x
                          and 50 costs 1.69x less than 100 (docs/ENCODING.md). Only the mirror
                          path encodes pixels: the landing screen has its own knob
                          (--wall-quality) and --full-frame ignores both. 'auto' is the default:
                          it spends colour first (80 -> 70 -> 50), then frame rate
                          (20 -> 15 -> 10), and only then lets --scale auto take resolution.
                          The frame-rate rungs are targets, not floors: the capture keeps
                          arriving at --fps and the loop declines frames so the *average* is the
                          rung, so 15 fps out of a 20 fps capture really is 15.0 fps. The
                          delivered rate is the number --stats and the --dev bar print next to
                          the target, so a rung that cannot be held is visible, not implied
                          Give a number to pin it (--quality 80 is then exactly the old behaviour)
      --no-quantise       same as --quality 100 (pinned, no ladder). It is the MIRROR's lossless:
                          the wall's is --wall-quality 100, and --no-quantise does not set it
      --wall-quality <0-100|auto>
                          how much colour the landing screen's pictures may lose (issue #88): 100
                          is the old lossless wall, 70 (the default) is 5-5-5 and 50 is 4-4-4, on
                          every panel. Bit depth only: the picture is still exactly its cells,
                          never a smaller picture in the same box, so nothing is cropped and no
                          seam appears. 'auto' is the default rung - the wall captures once per
                          change, so there is no ladder to climb and nothing to adapt to
      --clipboard <m>     clipboard bridge: off (default), in (target -> terminal via OSC 52),
                          out (Ctrl-V: terminal -> target), both
      --clipboard-paste <f>  put file <f> on the target pasteboard and post Cmd-V once
                          (for terminals that cannot answer an OSC 52 read)
      --cursor            draw the pointer into the picture (default: hidden — the pane already
                          follows the local pointer, and a drawn one dirties tiles as the mouse
                          moves; --no-cursor is still accepted and means the same as the default)
      --dpr <n>           device pixels per reported cell, i.e. picture quality (default: 2 when
                          the terminal answered CSI 16t/14t in points, 1 when the pty reported pixels)
      --demo             draw a test pattern instead of the desk (no capture, no permission)
      --square           square corners on the wall's pictures (default: rounded)
      --placeholders      force kitty unicode placeholders (U=1); --no-placeholders forces the
                          pixel-sized placement. Default: one probe at startup, then the answer
      --passthrough <m>   wrap every graphics APC in tmux's DCS passthrough envelope, for a pane
                          inside a multiplexer: auto (default), on or off. auto wraps when TERM is
                          tmux-* or screen-*, which is how the multiplexer names itself over ssh;
                          `on` is for a server that forces TERM=xterm. Needs tmux >= 3.3 with
                          `set -g allow-passthrough on`, and one level of nesting only.
                          KRD_PASSTHROUGH=on|off|auto is the same switch
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
      --list              list displays and windows, then exit (--list --json: one object)
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
      --json              with --bench: results on stdout, table on stderr; with --list: one object
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

/// The same four paths must not let the quality ladder adapt either: they either have no live pipe to
/// react to, or they write bytes a later run compares against. Kept separate from the scale refusal
/// because the two levers can be pinned independently.
func adaptiveQualityRefusal(bench: Bool, selftest: Bool, recording: Bool, replay: Bool) -> String? {
    if bench { return "--bench runs at --quality 80 (the ladder reacts to a live pipe)" }
    if selftest { return "--selftest runs at --quality 80 (its sha256 is a byte contract)" }
    if recording { return "--record runs at --quality 80 (a bit depth that changes mid-file has no marker)" }
    if replay { return "--replay runs at --quality 80 (the ladder reacts to a live pipe)" }
    return nil
}

/// `--ime <spec>`, or a usage error: a typo must not silently pick a mode.
func parseIMESpec(_ spec: String) throws -> IMEMode {
    guard let mode = IMEMode(spec: spec) else {
        throw UsageError("--ime wants auto|raw|unicode, got \"\(spec)\"")
    }
    return mode
}

/// `--passthrough <spec>`, or a usage error: a typo must not silently pick a mode.
func parsePassthroughSpec(_ spec: String) throws -> PassthroughMode {
    guard let mode = PassthroughMode(spec: spec) else {
        throw UsageError("--passthrough wants auto|on|off, got \"\(spec)\"")
    }
    return mode
}

/// `--clipboard <spec>`, or a usage error: a typo must not read as "off".
func parseClipboardSpec(_ spec: String) throws -> ClipboardPolicy {
    guard let policy = ClipboardPolicy(spec: spec) else {
        throw UsageError("--clipboard wants off|in|out|both "
            + "(in = target to terminal, out = terminal to target), got \"\(spec)\"")
    }
    return policy
}

/// `--quality <0-100>`, or a usage error. Silent clamping would be the worst answer here: a user who
/// types 150 means "as good as possible" and a user who types 5 means "as small as possible", and an
/// assumption about which is a lie either way.
func parseQualitySpec(_ spec: String) throws -> (budget: QualityBudget, auto: Bool) {
    if spec.lowercased() == "auto" { return (.default, true) }
    guard let value = Int(spec), (0...100).contains(value) else {
        throw UsageError("--quality wants 0...100 or auto, got \"\(spec)\"")
    }
    return (QualityBudget(value), false)
}

/// `--wall-quality <0-100|auto>`, or a usage error: same grammar as `--quality`, one difference.
///
/// The wall has no quality ladder -- it captures once per change rather than once per frame, so there
/// is no write rate to react to and nothing to climb down. `auto` therefore resolves to the default
/// rung (`QualityBudget.wall`, 5-5-5) instead of to a governor: it is the honest spelling of "krd
/// decides" for a knob whose only other answer is a fixed number.
func parseWallQualitySpec(_ spec: String) throws -> QualityBudget {
    if spec.lowercased() == "auto" { return .wall }
    guard let value = Int(spec), (0...100).contains(value) else {
        throw UsageError("--wall-quality wants 0...100 or auto, got \"\(spec)\"")
    }
    return QualityBudget(value)
}

/// `--symbols <spec>`, or a usage error: a typo must not silently pick a glyph table.
func parseSymbolsSpec(_ spec: String) throws -> WallSymbols {
    guard let symbols = WallSymbols(spec: spec) else {
        throw UsageError("--symbols wants emoji|ascii, got \"\(spec)\"")
    }
    return symbols
}

/// Does this argv[0] mean the landing screen? `install.sh` links `wall` next to `krd`, so the
/// everyday spelling is one word (`wall`, `wall --symbols ascii`) and it reaches this same parser:
/// the basename is the whole rule, and no wrapper script has to forward flags by hand.
func invokedAsWall(_ argv0: String) -> Bool {
    (argv0 as NSString).lastPathComponent == "wall"
}

/// The token after a flag that takes one: present, and not itself an option.
///
/// Both halves are the defect of issue #122. A value-taking flag at the end of the line used to read
/// `args[safe: i + 1] ?? ""` (`--fps` meant 20, `--window` meant nil) and `--fps --wall` used to read
/// the *next flag* as the value (`"--wall"` also meant 20): either way the parse succeeded, the
/// mirror started, and a typo streamed the desktop instead of printing one line. `-1` and `-0.5`
/// still reach their parsers — those are numbers, not options — so the test is the long-option
/// prefix plus the two short options this binary knows.
func value(_ flag: String, _ args: [String], _ i: inout Int) throws -> String {
    guard i + 1 < args.count else { throw UsageError("\(flag) needs a value") }
    let token = args[i + 1]
    if token.hasPrefix("--") || token == "-h" || token == "-v" {
        throw UsageError("\(flag) needs a value (got the option \"\(token)\")")
    }
    i += 1
    return token
}

/// `value` parsed as an integer in `min...max`, or a usage error naming the flag and what was typed.
func intValue(_ flag: String, _ args: [String], _ i: inout Int,
              wants: String, min: Int = .min, max: Int = .max) throws -> Int {
    let spec = try value(flag, args, &i)
    guard let number = Int(spec), number >= min, number <= max else {
        throw UsageError("\(flag) wants \(wants), got \"\(spec)\"")
    }
    return number
}

/// `value` parsed as a finite double in `(above, atMost]`, or a usage error naming the flag and what
/// was typed.
func doubleValue(_ flag: String, _ args: [String], _ i: inout Int, wants: String,
                 above: Double = -.infinity, atMost: Double = .infinity) throws -> Double {
    let spec = try value(flag, args, &i)
    guard let number = Double(spec), number.isFinite, number > above, number <= atMost else {
        throw UsageError("\(flag) wants \(wants), got \"\(spec)\"")
    }
    return number
}

/// `argv` is a parameter for the tests' sake, not for the app's: the wall-vs-mirror decision is the
/// one piece of the parse that a reader cannot check by running the binary, and it is now a default
/// plus two overrides, i.e. exactly the shape that rots silently.
func parseArguments(_ argv: [String] = CommandLine.arguments) throws -> Options {
    var options = Options()
    if invokedAsWall(argv.first ?? "") { options.wall = true }
    let args = Array(argv.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--fps":
            // Parseable but out of range keeps the old normalisation (`--fps 0` was 1, not an
            // error); what used to be silent was a value that was not a number at all.
            options.fps = max(1, try intValue("--fps", args, &i, wants: "a whole number"))
        case "--unfocused-fps":
            // Unlike `--fps`, 0 is a documented rate here: it means "freeze the picture". Negative
            // values keep the old shape of normalisation (clamped, not refused) for the same reason.
            options.unfocusedFps = max(0, try intValue("--unfocused-fps", args, &i,
                                                       wants: "a whole number"))
        case "--display":
            // Any integer is a parse; out-of-range is a live display set, which `DisplayPick`
            // already explains and falls back from -- not a typo to refuse here.
            options.displayIndex = try intValue("--display", args, &i,
                                                wants: "a display index from --list")
        case "--window":
            // Naming one window to mirror is a request for the mirror, never for the wall.
            options.windowQuery = try value("--window", args, &i)
            options.wall = false
        case "--zoom":
            // As with `--fps`: a parseable value keeps its old meaning (`zoomScale` treats anything
            // below 1 as 1), so only "not a number" is refused.
            options.zoom = try doubleValue("--zoom", args, &i, wants: "a number")
        case "--scale":
            // A *range* miss is carried to `run()` instead of silently meaning "1", because a typo
            // here doubles the bytes on the wire. A missing value has no fraction to carry, so that
            // half is this parser's usage error (issue #122).
            let spec = try value("--scale", args, &i)
            if spec.lowercased() == "auto" {
                options.scaleAuto = true
                options.scalePinned = false
            } else if let value = Double(spec), value.isFinite, value > 0, value <= 1 {
                options.scale = value
                options.scaleAuto = false
                options.scalePinned = true
            } else {
                options.scaleError = "--scale takes a fraction of the pane's pixels, "
                    + "0 < scale <= 1 (e.g. 0.5); got \(spec)"
            }
        case "--zoom-at":
            let spec = try value("--zoom-at", args, &i)
            let parts = spec.split(separator: ",")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]),
                  x.isFinite, y.isFinite else {
                throw UsageError("--zoom-at wants <x>,<y> in global points, got \"\(spec)\"")
            }
            options.zoomAt = CGPoint(x: x, y: y)
        case "--zoom-follow": options.zoomFollow = true
        case "--tile":
            let spec = try value("--tile", args, &i)
            let parts = spec.split(separator: "x")
            guard parts.count == 2, let cols = Int(parts[0]), let rows = Int(parts[1]) else {
                throw UsageError("--tile wants <cols>x<rows>, got \"\(spec)\"")
            }
            options.tileCols = max(2, cols)
            options.tileRows = max(1, rows)
        case "--cell":
            let spec = try value("--cell", args, &i)
            let parts = spec.split(separator: "x")
            guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else {
                throw UsageError("--cell wants <width>x<height> in pixels, got \"\(spec)\"")
            }
            options.cell = (w, h)
        case "--demo": options.demo = true
        case "--square": options.square = true
        case "--no-placeholders": options.placeholders = false
        case "--placeholders": options.placeholders = true
        case "--dpr":
            options.dpr = try doubleValue("--dpr", args, &i,
                                          wants: "a device-pixel ratio above 0 and at most 4",
                                          above: 0, atMost: 4)
        case "--format":
            let spec = try value("--format", args, &i)
            switch spec.lowercased() {
            case "rgb", "f=24", "24": options.pixelFormat = .rgb
            case "rgba", "f=32", "32": options.pixelFormat = .rgba
            default: throw UsageError("--format wants rgb or rgba, got \"\(spec)\"")
            }
        case "--pane":
            let spec = try value("--pane", args, &i)
            let parts = spec.split(separator: "x")
            guard parts.count == 2, let c = Int(parts[0]), let r = Int(parts[1]), c > 1, r > 1 else {
                throw UsageError("--pane wants <cols>x<rows> (at least 2x2), got \"\(spec)\"")
            }
            options.pane = (c, r)
        case "--full-frame": options.fullFrame = true
        case "--no-input": options.noInput = true
        case "--no-quantise": options.quality = QualityBudget(100); options.qualityPinned = true
        case "--quality":
            let parsed = try parseQualitySpec(value("--quality", args, &i))
            options.quality = parsed.budget
            options.qualityAuto = parsed.auto
            options.qualityPinned = true
        // The other `--flag=value` spellings are handled the same way, so this one has to be too:
        // a user who types `--quality=70` means it.
        case let arg where arg.hasPrefix("--quality="):
            let parsed = try parseQualitySpec(String(arg.dropFirst("--quality=".count)))
            options.quality = parsed.budget
            options.qualityAuto = parsed.auto
            options.qualityPinned = true
        // The wall's own knob (issue #88), with both spellings for the same reason as `--quality=`:
        // a flag that silently does nothing when typed the natural way is worse than a usage error.
        case "--wall-quality":
            options.wallQuality = try parseWallQualitySpec(value("--wall-quality", args, &i))
        case let arg where arg.hasPrefix("--wall-quality="):
            options.wallQuality = try parseWallQualitySpec(String(arg.dropFirst("--wall-quality=".count)))
        case "--cursor": options.drawsCursor = true
        case "--no-cursor": options.drawsCursor = false
        case "--selftest": options.selftest = true
        case "--bench": options.bench = true
        case "--json": options.benchJSON = true
        case "--bench-wire":
            options.benchWire = try value("--bench-wire", args, &i)
        case "--source":
            let spec = try value("--source", args, &i)
            guard let size = parseSize(spec) else {
                throw UsageError("--source wants <width>x<height>, got \"\(spec)\"")
            }
            options.source = (size.0, size.1)
        case "--rounds":
            options.rounds = try intValue("--rounds", args, &i,
                                          wants: "a positive number of rounds", min: 1)
        case "--seconds":
            options.benchSeconds = try doubleValue("--seconds", args, &i,
                                                   wants: "a positive number of seconds", above: 0)
        case "--no-serial": options.noSerial = true
        case "--record":
            options.record = try value("--record", args, &i)
        case "--record-frames":
            options.recordFrames = try intValue("--record-frames", args, &i,
                                                wants: "a positive number of frames", min: 1)
        case "--replay":
            options.replay = try value("--replay", args, &i)
        case "--stats-json":
            options.statsJSON = try value("--stats-json", args, &i)
        case "--log":
            options.logPath = try value("--log", args, &i)
        case "--dry-run": options.dryRun = true
        case "--ime":
            options.ime = try parseIMESpec(value("--ime", args, &i))
        case let arg where arg.hasPrefix("--ime="):
            options.ime = try parseIMESpec(String(arg.dropFirst("--ime=".count)))
        case "--passthrough":
            options.passthrough = try parsePassthroughSpec(value("--passthrough", args, &i))
            options.passthroughPinned = true
        case let arg where arg.hasPrefix("--passthrough="):
            options.passthrough = try parsePassthroughSpec(String(arg.dropFirst("--passthrough=".count)))
            options.passthroughPinned = true
        case "--clipboard":
            options.clipboard = try parseClipboardSpec(value("--clipboard", args, &i))
        case "--clipboard-paste":
            options.clipboardPaste = try value("--clipboard-paste", args, &i)
        // The `--flag=value` spelling too: people type it, and a flag that silently does nothing
        // when typed the natural way is worse than a usage error.
        case let arg where arg.hasPrefix("--clipboard="):
            options.clipboard = try parseClipboardSpec(String(arg.dropFirst("--clipboard=".count)))
        case let arg where arg.hasPrefix("--clipboard-paste="):
            options.clipboardPaste = String(arg.dropFirst("--clipboard-paste=".count))
        case "--debug": options.debug = true
        case "--dev": options.dev = true
        case "--dev-panel": options.devPanel = try value("--dev-panel", args, &i)
        case "--mock": options.mock = true
        case "--mock-size":
            let spec = try value("--mock-size", args, &i)
            let parts = spec.split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 8, parts[1] > 8 else {
                throw UsageError("--mock-size wants <width>x<height> above 8x8, got \"\(spec)\"")
            }
            options.mockSize = (parts[0], parts[1])
        case "--no-chrome": options.noChrome = true
        // The default since phase 4; kept because scripts and muscle memory spell it.
        case "--wall": options.wall = true
        case "--mirror": options.wall = false
        case "--bar": options.bar = true
        case "--no-bar": options.bar = false
        case "--wall-at":
            // `<stage>:<card>`. Parsed by the same function both times, so the wall that hands over
            // and the wall that comes back cannot disagree about the spelling.
            let spec = try value("--wall-at", args, &i)
            guard let at = parseWallAt(spec) else {
                throw UsageError("--wall-at wants <stage>:<card>, got \"\(spec)\"")
            }
            options.wallAt = at
        case "--said":
            // `<exit>` then the child's sentence as its own token: the text has spaces in it, and it
            // can begin with `--` (the sentence of a refused `--selftest --scale` does), so it is
            // the one value this parser does not test for "looks like an option".
            guard i + 2 < args.count, let code = Int32(args[i + 1]) else {
                throw UsageError("--said needs <exit> <text> (the failed mirror's status and its sentence)")
            }
            options.said = (code, args[i + 2])
            i += 2
        case "--symbols":
            options.symbols = try parseSymbolsSpec(value("--symbols", args, &i))
        // The `--flag=value` spelling too, for the same reason as `--ime=` / `--clipboard=`.
        case let arg where arg.hasPrefix("--symbols="):
            options.symbols = try parseSymbolsSpec(String(arg.dropFirst("--symbols=".count)))
        case "--list": options.listOnly = true
        case "-v", "--version": print("krd \(krdVersion)"); exit(0)
        case "-h", "--help": print(usage()); exit(0)
        default:
            // Every unknown token used to land here and be dropped (`default: break`): a default
            // `Options` came back and `krd --nonsense` went on to paint -- and stream -- the
            // desktop. A typo must not start a capture, so it is a usage error, spelled like the
            // one `krd ax` already prints.
            if args[i].hasPrefix("-") {
                throw UsageError("unknown option \"\(args[i])\" (try `krd --help`)")
            }
            throw UsageError("unexpected argument \"\(args[i])\" (try `krd --help`)")
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
    /// `internal`, not `private`, together with the five chrome members below: `PanelWheelRealPathTests`
    /// drives the wheel the way the product does -- reader decision, then `chromeClick`, then the hop
    /// to the main queue, then `scrollPanel` -- and that needs the state `applyLayout`/the 1 Hz tick
    /// would otherwise leave behind. Nothing outside this module can reach any of it.
    let writer = ScreenWriter()
    /// The mascot card shown until the first frame lands (see LoadingView).
    private var loading: LoadingView?
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
    /// Whether the one line about a placeholder grid refusing to lose pixels has been written.
    private var reportedScaleRefusal = false
    /// `--quality auto`: colour first, then frame rate. Resolution stays `ScaleGovernor`'s, and this
    /// governor has to say `handOver` before that one may act.
    private var qualityGovernor = QualityGovernor()
    /// Frames per second the loop is currently allowing. `--fps` is the capture target; this is what
    /// the encoder actually runs at when the governor has taken a step.
    private var effectiveFps = 20
    /// Which of the capture's frames the current rung lets through. A deadline carried across
    /// frames rather than a last-draw mark, because a mark quantises every rung down to a multiple
    /// of the capture period: 15 fps out of a 20 fps capture was 10 fps (issue #140).
    private var frameGate = FrameGate(fps: 20)
    /// Whether the terminal says this pane has the focus (`CSI I` / `CSI O`, DECSET 1004, issue
    /// #110). Written on the input thread and read on the capture queue, so it lives under
    /// `stateLock` exactly like `viewport` and `previousFrame` do.
    ///
    /// `true` by default, and that is the whole compatibility story: a terminal that never reports
    /// focus (or a multiplexer that swallows the reports) never moves this flag, so nothing about
    /// the picture changes.
    private var focused = true
    /// Bumped on every real transition, so the capture queue can *notice* one without taking the
    /// lock on every frame's worth of decisions: a frame that sees a new generation is the first
    /// frame of the new rate, and it re-arms the gate and drops the previous frame (issue #110
    /// point 5). Counted, not a timestamp: a transition is an event, not a duration.
    private var focusGeneration = 0
    /// The generation the capture queue last acted on. Owned by that queue alone, so no lock.
    private var lastFocusGeneration = 0
    /// The menu's frame-rate track was used: hold the rate the click asked for.
    ///
    /// `--fps` is the *capture* cadence and nothing gates frames for it; only the quality governor's
    /// rung does, and only while `--quality auto` is in charge. A rate the user picked has to be held
    /// the same way (`governed` in `handleFrame`), or the slider reads as doing nothing on a link that
    /// delivers faster than the capture (issue #87).
    private var fpsPinned = false
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
    /// The last frame size we logged, so a steady stream logs one line instead of sixty a second.
    private var loggedFrameSize: (Int, Int)?
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
    /// Frames ScreenCaptureKit handed us (`captureFps` is this one's rate), and of those, the ones
    /// that changed nothing. Both used to live on `Capturer`; they moved here with the decision
    /// that produces them, which is the one scan in `handleFrame` (issue #95). Drawn frames are
    /// `framesHandled` above, so `skipped` counts no-ops and `delivered` counts callbacks that got
    /// past the frame-rate governor — three different numbers, as they were before.
    private var framesSkipped = 0
    private var framesDelivered = 0
    private var chromeSampleFrames = 0
    private var chromeSampleDelivered = 0

    private var resizeSource: DispatchSourceSignal?
    /// The `SIGWINCH` stream's trailing edge (issue #89). Main queue only.
    private var resizeBurst = ResizeCoalescer()
    /// The pane the mirror's current picture was laid out for, i.e. what `handleResize` last built
    /// a grid from. `nil` until the first resize: a picture that was never re-fitted has no claim
    /// to "the pane did not move".
    private var mirrorPane: ResizePane?
    private var statsTimer: DispatchSourceTimer?
    // TUI layer (--dev). Everything below is written on the main queue at 1 Hz; the picture
    // never waits for it and the writer serializes the two.
    private let chrome = Chrome()
    var chromeState = ChromeState()
    var chromeMetrics = ChromeMetrics()
    /// The log panel's offset into the log file, kept across ticks so a tick reads what the writer
    /// added instead of the whole file (#90).
    private var logTail = LogTailReader()
    var chromeGeometry: ChromeGeometry?
    private var chromeTimer: DispatchSourceTimer?
    /// The single 1 Hz tick that samples rates and feeds the panel, the log line and the JSON.
    private var diagnosticsTimer: DispatchSourceTimer?
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
    /// Draw the mirror's tiles as unicode placeholders (design §6.9): the terminal fits each tile into
    /// its cells, so a tile's pixel count is sharpness and `--scale`/`--quality` stop moving the
    /// picture. Decided once, from `--placeholders` or from one probe of the terminal.
    private var placeholderTiles = false
    /// `placeholderTiles` *and* a terminal that draws one image pixel per device pixel: the frame has
    /// to be the picture's cell box there (`Desk.placeholderNeedsCellBox`, issue #86). Read by
    /// `applyLayout`, which is also what a resize and a scale change go through.
    private var placeholderFillsCells = false
    private var wallCanvas: WallCanvas?
    private var wallModel = WallModel()
    private var wallTimer: DispatchSourceTimer?
    /// The notifications that can move the window list (issue #141). The wall enumerates when one of
    /// them fires, and not otherwise — the 1 s timer below never touches the window server.
    private var wallWatch: WallWatch?
    /// The bounded-staleness poll (issue #169 review). Every `WallSource.pollInterval` seconds it
    /// takes a *fingerprint* of the window list and enumerates only when the fingerprint moved.
    /// This is the one trigger that can see a window opening or closing inside the app that is
    /// already frontmost — AppKit posts nothing for that — so it is what turns "stale until the next
    /// unrelated system event" into "stale for at most `WallSource.pollInterval`".
    private var wallPollTimer: DispatchSourceTimer?
    /// The first-paint deadline (issue #169 gate). A wall that shows nothing is worse than a stale
    /// card, and two of five real-mode runs emitted no frame inside 11 s — so the one thing the wall
    /// must never do silently, it also refuses to *keep* doing: if no frame has gone out by
    /// `WallSource.firstPaintDeadline`, say so in the log and paint again.
    private var wallFirstPaintTimer: DispatchSourceTimer?
    /// The fingerprint the last enumeration was taken against. `nil` = nothing enumerated yet.
    /// Both the poll and the wall's own input ask *this* whether the world moved, so the click path
    /// can afford to resync before it hit-tests a window id.
    private var wallFingerprint: WallFingerprint?
    /// Every window-server enumeration this session made. The count is the point of issue #141: an
    /// idle wall must not add to it, and `--debug --log` prints it so a probe can read it back.
    private var wallEnumerations = 0
    /// `--demo`'s window list is four constants (`WallSource.demoModel`): it cannot move, so its
    /// fingerprint is a constant and the poll costs a comparison instead of a window-server call.
    private static let demoFingerprint = WallFingerprint(windows: WallSource.demoModel().windows.count,
                                                          ids: 0, frontmost: 0, displays: [])
    /// The pane the last wall draw was laid out for. Together with `wallModel` it is the whole
    /// answer to "would the wall look different?".
    /// One snapshot of the pane this wall draws into: the layout and every capture size come from
    /// it, and nothing else may measure the terminal (design §6.9).
    private var wallPane: PaneGeometry?
    /// The transport the wall's pictures actually use, decided once: `--placeholders` if given,
    /// otherwise by probing the terminal (see `TermGeometry.supportsPlaceholders`).
    private var wallPlaceholders = false
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
    /// Recent timings, newest captured each second. Percentiles rather than averages: a stutter is a
    /// p99, and the mean is exactly what hides one (see `Series`). `cap` and `pipe` are the exception:
    /// they are fed by the frame path, one sample per *frame* (issue #91, see `recordFrameLatency`).
    private var capSeries = Series()
    private var pipeSeries = Series()
    private var zlibSeries = Series()
    private var writeSeries = Series()
    /// The one rate definition (`Rates`), sampled by the diagnostics timer and read by both
    /// renderers, so the panel and `--stats-json` cannot disagree about what `tiles/s` means.
    /// The DSR round-trip probe (issue #52): 4 bytes every couple of seconds, answered by the
    /// terminal over the same connection the picture goes down.
    private var rttProbe = RTTProbe()
    private var rttRepliesSeen = 0
    private var lastRates = Rates()
    private var rateCounters = Rates.Counters()
    private var rateSampleAt = Double(0)
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
        writer.quality = options.quality
        // A multiplexer consumes an APC body itself, so the graphics escapes have to go out inside
        // its passthrough envelope (`--passthrough`, issue #107). Decided once, here, before the
        // first byte and by the same rule for every path -- and off for a normal terminal, which
        // is what keeps the dump and the golden fixtures byte-identical.
        let passthrough = TmuxPassthrough.resolve(
            flag: options.passthroughPinned ? options.passthrough : nil,
            env: ProcessInfo.processInfo.environment)
        // Set on the sink itself, not just the writer: the geometry probe (`a=t` and friends)
        // writes before a frame exists, and it is the probe that must survive tmux (issue #107).
        GraphicsAPC.passthrough = passthrough.on
        writer.passthrough = passthrough.on
        if passthrough.on || options.debug {
            // A log line, not stderr: inside a pane a line of text scrolls the picture off its own
            // grid (CONTRIBUTING.md rule 1), and `Log` is a file whenever logging is configured.
            Log.write("krd: passthrough \(passthrough.on ? "on" : "off") (\(passthrough.why))\n")
        }
        effectiveFps = options.fps
        frameGate = FrameGate(fps: options.fps)
        // Focus reporting (`?1004`, issue #110) is asked for only by a session that reads input and
        // has a remote desktop to read it for. Set once, here, before any `beginSession()`: the heal
        // runs first and has to know whether it owns `?1004`, so a late decision would leave the
        // pane in a mode the teardown does not reset. A session that reads no input, or the wall,
        // never asks for a mode whose whole purpose is sending bytes to a reader that does not
        // exist -- and `--selftest`'s sha256 is a byte contract that depends on it.
        ScreenWriter.focusReporting = !options.noInput && !options.wall
        if options.qualityAuto {
            qualityGovernor = QualityGovernor(start: .init(quality: options.quality.value,
                                                           fps: options.fps))
        }
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
        // Same contract, same reason: `--quality 50` would change every byte the hash covers while
        // still printing a hash. Reported the way the other usage errors are (`--ime`, `--symbols`),
        // not thrown: a thrown error here reaches only the log, and a usage error the user cannot
        // see is a usage error that will be reported as "the hash changed".
        // `--quality 80` is the default and therefore the hash everyone already has; anything else
        // that can quantise -- including `auto`, which is a moving target -- would change it.
        let pinnedLossy = options.qualityPinned
            && (options.qualityAuto || (options.quality.isLossy && options.quality != .default))
        if options.selftest && pinnedLossy {
            FileHandle.standardError.write(
                Data("krd: --selftest checks a lossless byte contract; drop --quality or use --quality 100\n".utf8))
            exit(2)
        }
        // Adaptive scaling is the default, but these four paths must not have it: they either have no
        // pipe to measure, or they write something a later run reads back. Pin them to 1 and say why,
        // because a scale that moves under a recording leaves frames whose sizes differ with nothing
        // in the file to mark it.
        // Colour before resolution, by default. `--scale auto` has always been the default (issue
        // #64), so leaving the quality ladder opt-in meant a plain `krd` on a slow link took the
        // *worst* lever first -- softer text -- and never tried the cheap one. `--quality <n>` and
        // `--no-quantise` pin it, which is also how "exactly as before" is spelled now.
        if !options.qualityPinned {
            options.qualityAuto = true
            if let why = adaptiveQualityRefusal(bench: options.bench, selftest: options.selftest,
                                                recording: options.record != nil,
                                                replay: options.replay != nil) {
                options.qualityAuto = false
                Log.write("krd: \(why)\n")
            }
        }
        if options.scaleAuto,
           let why = adaptiveScaleRefusal(bench: options.bench, selftest: options.selftest,
                                          recording: options.record != nil, replay: options.replay != nil) {
            options.scaleAuto = false
            options.scale = 1
            Log.write("krd: \(why)\n")
        }

        // Tiles as unicode placeholders: the terminal fits each tile into its cells, so a tile's
        // pixel count is sharpness and `--scale`/`--quality` stop being able to *move* the picture
        // (design §6.9). `--bench` and `--selftest` are byte contracts and must not see a probe's
        // escape, so they keep the pixel-sized path; nothing else needs to.
        // `--list` is excluded for the same reason: a listing paints nothing, so it owes the
        // terminal neither the capability query nor the `ESC _ G a=d,d=i,i=31 ESC \` cleanup that
        // goes with it — stdout is the listing, and nothing else (issue #124). `listsOnly` keeps
        // `--list --replay`/`--list --mock` out of that: they still paint.
        if let forced = options.placeholders {
            placeholderTiles = forced && !(options.bench || options.selftest)
        } else if !(options.bench || options.selftest || options.wall || Self.listsOnly(options)) {
            // `--wall` is excluded because it never reads `placeholderTiles`: the wall's pictures are
            // `wallPlaceholders`, probed in `runWall`. Asking here was 600 ms of dead time in front of
            // the wall's first byte, on a terminal that may not answer at all (issue #99).
            placeholderTiles = TermGeometry.supportsPlaceholders() == true
        }
        let deviceCell = Self.cellIsInDevicePixels(options)
        if Self.scaleNeedsPixelPlacements(placeholdersForced: options.placeholders,
                                          pinnedScale: options.scalePinned ? options.scale : nil,
                                          deviceCell: deviceCell) {
            placeholderTiles = false
            Log.write("krd: --scale \(String(format: "%g", options.scale)) on a terminal that draws one image "
                      + "pixel per device pixel:\n"
                      + "         pixel placements, because a placeholder grid cannot stretch a smaller "
                      + "frame into its cells\n")
        }
        // ...and the other half of the same question: on that terminal the frame has to *be* the
        // cells, because a short one is a seam at every tile column (issue #86). See the helper for
        // why a terminal that stretches its images keeps `--scale`.
        placeholderFillsCells = Self.placeholderNeedsCellBox(placeholders: placeholderTiles,
                                                             deviceCell: deviceCell)
        if options.debug || options.placeholders != nil {
            Log.write("krd: tiles as \(placeholderTiles ? "unicode placeholders (U=1)" : "pixel-sized placements")\n")
        }
        // One place decides the starting scale, for every path below -- live, --mock, --bench.
        // (It used to be set inside the live capture setup only, so `--mock --scale 0.5` quietly
        // drew at 1.)
        //
        // A frame that has to be the cell box has no pixels to give away, so the scale in force is 1
        // - what the debug line and the status bar report, and what `TileGrid.make(fillsCells:)`
        // enforces. When a scale below 1 survives the transport switch only because `--placeholders`
        // was typed, it is said out loud instead of being applied halfway.
        let scaleClampedByPlaceholders = placeholderFillsCells && options.scale < 0.999
        effectiveScale = scaleClampedByPlaceholders ? 1 : options.scale
        if scaleClampedByPlaceholders {
            Log.write("krd: --scale \(String(format: "%g", options.scale)) is not applied: a placeholder frame on "
                      + "this terminal is the picture's cell box,\n"
                      + "         and fewer pixels than that is a seam at every tile column. "
                      + "--no-placeholders captures at \(String(format: "%g", options.scale))\n")
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
            barTitle = targetLabel
            self.filter = nil
            applyLayout(geometry: geometry)
            guard let layout = currentGrid() else {
                throw DeskError.message("could not compute a tile layout")
            }
            writer.beginSession()
            startChrome()
            installSignalCleanup()
            installReportHandler()
            installResizeHandler()
            startDiagnostics()
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

        // The one call that throws when Screen Recording is denied. On the listing path both
        // formats answer the same failure class and the same exit code (#123, #157: `--json` is a
        // format, not a second contract): `--list --json` prints the one documented object on
        // stdout, `--list` prints prose on stderr, and both leave 3 (no grant) or 4 (the Mac did
        // not answer). Every other path — the wall, the mirror — keeps the behaviour it had: the
        // error goes to the handler at the bottom of `main`.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            guard options.listOnly else { throw error }
            // `CGPreflight` is the question "is this binary granted?" — false means the throw *is*
            // the missing grant, true means the Mac did not answer. The advice follows the answer:
            // telling an already-granted machine to grant again is the one thing a caller cannot
            // act on.
            let granted = CGPreflightScreenCaptureAccess()
            let message = "\(error)".split(whereSeparator: \.isNewline).joined(separator: " ")
            let output = ListOutput.failure(
                code: granted ? "environment" : "permission",
                exit: granted ? AXExit.environment.rawValue : AXExit.permission.rawValue,
                message: message,
                next: granted
                    ? "the Mac did not answer its window list (asleep, at the login window, or the "
                        + "window server is gone); retry when it is awake, `krd ax doctor` says which"
                    : "grant Screen Recording to this binary in System Settings > Privacy & Security "
                        + "> Screen Recording, then re-run")
            if options.benchJSON {
                FileHandle.standardOutput.write(Data(output.stdout.utf8))
            }
            FileHandle.standardError.write(Data(output.stderr.utf8))
            exit(output.exit)
        }

        if options.listOnly {
            // `content.displays` can be empty while windows are listed (macOS 26 without a
            // display-capture grant), so fall back to CoreGraphics for recognition. The index is
            // only printed when it really is the one `--display` expects.
            let shareable = content.displays.map { CGDisplayBounds($0.displayID) }
            let displayBounds = shareable.isEmpty ? WindowPick.displayBounds() : shareable
            let displays = content.displays.enumerated().map { index, display -> ListDisplay in
                let bounds = displayBounds[index]
                return ListDisplay(index: index, id: display.displayID,
                                   width: Int(bounds.width), height: Int(bounds.height),
                                   main: CGDisplayIsMain(display.displayID) != 0)
            }
            let windows = content.windows.filter { $0.frame.width > 60 }.map { window -> ListWindow in
                let frame = window.frame
                let centre = CGPoint(x: frame.midX, y: frame.midY)
                // Two display questions, two answers: the text hint names the display a backdrop
                // *covers* (resolved through the shareable list, exactly as before issue #124),
                // the JSON field names the display the frame's centre is on. Conflating them
                // would change the hint on a window whose centre is not on the display it covers.
                let covered = WindowPick.backdrop(layer: window.windowLayer, frame: frame,
                                                  displays: displayBounds)
                return ListWindow(
                    id: window.windowID,
                    app: window.owningApplication?.applicationName ?? "?",
                    title: window.title ?? "-",
                    frame: frame,
                    // Resolved against the shareable list only: when it is empty the CoreGraphics
                    // fallback's order is advisory (Windows.swift), so those indices neither
                    // index `displays[]` nor mean what `--display` means — `null` says so.
                    display: shareable.firstIndex { $0.contains(centre) },
                    backdropDisplay: covered.flatMap { shareable.firstIndex(of: $0) },
                    targetable: covered == nil)
            }
            // `--json` is the one format switch the parser has today (`options.benchJSON`, set by
            // `case "--json"`); `--list` reads it as "the listing, as one object".
            let listing = options.benchJSON
                ? ListOutput.json(displays: displays, windows: windows)
                : ListOutput.text(displays: displays, windows: windows)
            FileHandle.standardOutput.write(Data(listing.utf8))
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
        // Nothing is on screen yet: the first frame is a full capture away. The mascot fills that
        // window, in plain ANSI, and the first frame takes it away (`handleFrame`).
        let card = LoadingView(paneCols: layout.paneCols, paneRows: layout.paneRows) { [writer] in
            writer.write($0)
        }
        card.start()
        loading = card
        startChrome()
        installSignalCleanup()
        installReportHandler()
        installResizeHandler()
        installDisplayChangeHandler()
        startDiagnostics()

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
                   : effectiveScale < 1 ? " (scale \(ScaleGovernor.show(effectiveScale)))" : "")
                + layout.fitNote
                + ", \(layout.tilesX)x\(layout.tilesY) tiles of \(layout.tileCols)x\(layout.tileRows) cells\n"
            Log.write(message)
        }

        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: the wall (--wall)

    /// Ask the terminal for its cell size again and adopt the answer when the pty still reports no
    /// pixel size (which is the ssh case, and the one where krd has nothing else to go on).
    ///
    /// Called from the resize handler, so a pane that is resized after the first paint (or whose
    /// first answer timed out) ends up with the geometry the terminal actually has rather than with
    /// the one guessed at startup.
    private func remeasureWallPane() {
        guard let pane = wallPane else { return }
        // The grid is cheap (an ioctl); the *cell* is what a resize can change and what a terminal
        // may only answer once its pane has been laid out - so it is re-asked here, not per tick.
        let fresh = PaneGeometry.measure(cell: options.cell, grid: options.pane,
                                         dpr: options.dpr) { Log.write($0) }
        guard fresh != pane else { return }
        wallPane = fresh
        // No refresh here: the only caller is `handleResize`, which clears the screen and forces its
        // own enumeration on the next line. That is what makes one resize enumerate exactly once
        // (issue #169 review: it was three — this one, `handleResize`'s, and the paint redo's).
    }

    /// Start the landing screen: alternate screen, resize handler, one paint, the probes, input and a
    /// 1 s tick. No capturer, no tile grid, no chrome rows — the wall owns every cell.
    ///
    /// The order is paint → probe → input (issue #99). Both terminal probes are round trips a terminal
    /// is free never to answer (500 ms for the cell query, 600 ms for `U=1`), and they used to run
    /// before the first byte, so `--wall` showed an empty alternate screen for ~1.7 s.
    private func runWall() {
        // One measurement, one log line: the grid, the cell, and where the cell came from. Every
        // fit in this wall is computed from this value, so a picture that does not fill its cells
        // is answered by this line plus the reader's terminal - never by a guess somewhere else.
        //
        // `askTerminal: false`: the `CSI 16t`/`14t` query waits behind the first paint (issue #99).
        // The assumed cell is the same one that query times out to, so a terminal that never answers
        // ends up with exactly this pane and no repaint (`probeBehindTheFirstPaint`).
        let pane = PaneGeometry.measure(cell: options.cell, grid: options.pane,
                                        dpr: options.dpr, askTerminal: false) { Log.write($0) }
        wallPane = pane
        WallPictures.demo = options.demo
        WallPictures.square = options.square
        WallPictures.quality = options.wallQuality
        // One line, because this knob moves a byte count nobody can see: `--wall-quality 100` is how a
        // reader (or a bench) asks for the pre-#88 wall back, so the log says which rung is in force.
        Log.write("krd: wall pictures at --wall-quality \(options.wallQuality.value) "
                  + "(\(options.wallQuality.label))\n")
        // Pictures: kitty unicode placeholders when the terminal accepts them, else pixel-sized
        // placements. The transport is *provisional* here (issue #99): the probe is a round trip, so
        // the first frame takes the conservative pixel path, which is exactly what a terminal that
        // never answers `U=1` gets anyway. A terminal that accepts it answers in ~1 ms, i.e. before
        // that frame's capture has finished, and `probeBehindTheFirstPaint` re-lays-out once.
        wallPlaceholders = options.placeholders ?? false
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
        // The desk is built *before* input: `startInput()` decides the wall's key policy from wall
        // mode, and it runs on the main queue before the reader thread exists — the only race-free
        // moment to read that. The first paint is *also* before it now (issue #99): the frame must not
        // wait for a probe a terminal may never answer, and the probes must run before the mouse is
        // live (`TermGeometry.ask` reads stdin, so a probe under a live reader steals its bytes).
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
        // Paint at the assumed cell on the provisional transport, *then* ask the terminal: on a silent
        // terminal neither probe can move anything, and on one that answers the answer arrives before
        // this frame's capture has finished (issue #99).
        refreshWall(force: true)
        probeBehindTheFirstPaint()
        startInput()
        startWallTriggers()
    }

    /// The two terminal probes that used to run before the wall's first byte (issue #99), moved behind
    /// it.
    ///
    /// `PaneGeometry.measure` (`CSI 16t`/`14t`, up to 500 ms) and `supportsPlaceholders` (`U=1`, up to
    /// 600 ms) are both questions a terminal is free never to answer, and `runWall` paid for them with
    /// an empty alternate screen. So the first frame went out at the assumed cell on the pixel path,
    /// and this asks with a wall already on screen: on Rex/kitty both answers arrive in ~1 ms, the
    /// stale capture is dropped by the `desk.wallPane == pane` guard in `drawWall`, and the frame is
    /// captured again once — with the real cell and the real transport.
    ///
    /// Still before `startInput()`: a probe that runs while the reader thread is live eats the bytes
    /// the reader is waiting for.
    ///
    /// A terminal that does not answer changes nothing, and this repaints nothing: the query times out
    /// to `fallbackCell` - the cell the first paint already used - and the memoised `U=1` verdict is
    /// "no answer", i.e. the pixel path that frame was already drawn on.
    private func probeBehindTheFirstPaint() {
        // The pane the first frame was laid out for. Post-paint, so a grid `refreshWall` adopted from
        // the pty is already in it: only a *cell* that moved is news here.
        guard let drawn = wallPane else { return }
        let signed = PaneGeometry.measure(cell: options.cell, grid: options.pane,
                                          dpr: options.dpr) { Log.write($0) }
        let wasPlaceholders = wallPlaceholders
        // `--placeholders`/`--no-placeholders` force the transport and send no probe bytes for it (that
        // has always been the deal); the cell query still runs, because only `--cell` beats it.
        if let forced = options.placeholders {
            wallPlaceholders = forced
            Log.write("krd: pictures as \(forced ? "unicode placeholders (U=1)" : "pixel-sized placements") (forced)\n")
        } else {
            switch TermGeometry.supportsPlaceholders() {
            case .some(true):
                wallPlaceholders = true
                Log.write("krd: the terminal answered a U=1 placeholder: pictures are fitted into their cells\n")
            case .some(false):
                wallPlaceholders = false
                Log.write("krd: the terminal refused U=1: pictures are drawn at their own pixel size\n")
            case .none:
                wallPlaceholders = false
                Log.write("krd: the terminal did not answer the U=1 probe: pixel-sized pictures\n")
            }
        }
        let moved = WallProbeOutcome(paneMoved: drawn.paintsDifferently(from: signed),
                                     transportMoved: wallPlaceholders != wasPlaceholders)
        if moved.paneMoved { wallPane = signed }
        guard moved.needsRepaint else { return }
        // One line, because the repaint is a whole frame: which of the two answers was late is the
        // difference between "the cell was wrong" and "the pictures were on the wrong transport".
        let what = moved.paneMoved
            ? (moved.transportMoved ? "cell and transport" : "cell")
            : "transport"
        Log.write("krd: the probe moved the wall's \(what); repainting the first frame\n")
        refreshWall(force: true)
    }

    /// Everything that can move the window list, in one place: the 1 s grid tick, the 2 s staleness
    /// poll, and the system's own notifications. One definition, so `handOver` cannot stop two of the
    /// three and leave the wall enumerating for a pane a child mirror owns.
    private func startWallTriggers() {
        startWallTimer()
        startWallWatch()
        startWallPoll()
        startFirstPaintWatchdog()
    }

    private func stopWallTriggers() {
        wallTimer?.cancel()
        wallTimer = nil
        wallPollTimer?.cancel()
        wallPollTimer = nil
        wallWatch?.stop()
        wallWatch = nil
        wallFirstPaintTimer?.cancel()
        wallFirstPaintTimer = nil
    }

    /// The bounded-staleness poll (issue #169 review): `nil` is not the answer for "a window closed
    /// inside the frontmost app", because nothing announces it. So the wall asks a *fingerprint* of
    /// the world — a window count, a sum of window ids, the frontmost app, the display ids — at a
    /// low rate, and pays for a real enumeration only when the answer moved. The staleness bound is
    /// exactly `WallSource.pollInterval` seconds, and an idle wall pays one fingerprint per interval
    /// (measured and logged) instead of one enumeration per second.
    private func startWallPoll() {
        wallPollTimer?.cancel()
        let interval = WallSource.pollInterval
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.refreshWall(force: false, trigger: .poll) }
        timer.resume()
        wallPollTimer = timer
    }

    /// The one deadline the wall sets for itself: a frame must exist shortly after the session
    /// starts, or the pane is an empty alternate screen that looks exactly like a crash.
    ///
    /// This is a log line plus a repaint, not a retry loop: `drawWall` is idempotent, and a paint that
    /// fails for a real reason (no grant, a window that closed) still leaves the placeholders and the
    /// footer's notice on the pane. The timer fires once, 1.5 s in, and says what it found.
    private func startFirstPaintWatchdog() {
        wallFirstPaintTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + WallSource.firstPaintDeadline)
        timer.setEventHandler { [weak self] in
            guard let self, !self.cleanedUp, self.wallState != nil else { return }
            guard !self.wallPaintedOnce else { return }
            Log.write("krd: wall had painted nothing "
                      + "\(WallSource.firstPaintDeadline) s after start; painting again\n")
            self.drawWall()
        }
        timer.resume()
        wallFirstPaintTimer = timer
    }

    /// The wall's 1 s timer. Only the *grid* is its business (an ioctl, no query): what the timer
    /// used to do was enumerate the window server once a second to discover it had nothing to say
    /// (issue #141). The list is now driven by `startWallWatch()` and by `refreshWall(force: true)`;
    /// this handler can only relayout.
    private func startWallTimer() {
        wallTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.wallTick() }
        timer.resume()
        wallTimer = timer
    }

    /// Subscribe to the notifications that can move the window list. One subscription per wall
    /// session: `handOver`/`shutdown` stop it, `resumeWall` starts it again.
    private func startWallWatch() {
        let watch = WallWatch()
        watch.start { [weak self] in self?.refreshWall(force: false, trigger: .world) }
        wallWatch = watch
    }

    /// The 1 s tick: adopt a grid the pty changed without a `SIGWINCH`, and repaint from the cached
    /// model. No window server call happens here — that is the whole difference to the old tick.
    private func wallTick() {
        guard !cleanedUp, wallState != nil, let drawn = wallPane else { return }
        // The grid can change without a resize report (an ssh client that resizes its own pty), so
        // it is re-read every tick - an ioctl, no query. The *cell* is not: it is re-measured on a
        // resize only (`remeasureWallPane`), because a terminal that answers `CSI 16t` late is not
        // something to ask once a second.
        let pty = paneFromTTY(drawn)
        switch WallRefresh.tick(drawn: drawn, pty: pty, pinned: options.pane != nil) {
        case .idle:
            return
        case .relayout(let cols, let rows):
            // A grid moves the layout and the band's capacity, never the world: `clampAndDraw`
            // re-clamps the page offsets against the cached counts, which is the same arithmetic a
            // resize goes through.
            let pane = drawn.with(cols: cols, rows: rows)
            wallPane = pane
            clampAndDraw(model: wallModel, pane: pane)
        }
    }

    /// The pty's grid as a `PaneGeometry`, falling back to the one the wall drew for. `read()` is an
    /// ioctl; nothing here allocates a model.
    private func paneFromTTY(_ stored: PaneGeometry) -> PaneGeometry {
        let tty = TermGeometry.read()
        return options.pane == nil && (tty.cols != stored.cols || tty.rows != stored.rows)
            ? stored.with(cols: tty.cols, rows: tty.rows) : stored
    }

    /// Re-enumerate the world and repaint — but only when the wall would actually look different:
    /// the display list, the window list (order included, it is "most recently used first"), or the
    /// pane size. That comparison is also what keeps an idle wall at 0 B/s.
    ///
    /// Called by the triggers and never by the timer: `force` is the wall asking itself (the first
    /// paint, a return from a mirror, a resize), `.world` is a notification the system posted.
    private func refreshWall(force: Bool, trigger: WallTrigger = .explicit) {
        guard !cleanedUp, wallState != nil else { return }
        guard trigger.enumerates, let stored = wallPane else { return }
        let pane = paneFromTTY(stored)
        // The gate (issue #169 review): a trigger that fired does not mean the world moved. The poll
        // and the wall's own input pay for an enumeration only when the fingerprint says so — that
        // is what makes the poll cheap enough to bound staleness with, and what lets a click resync
        // before it hit-tests a window id. `.world` and `.explicit` skip the gate on purpose: a
        // notification can precede the window it announces, and the wall asking itself is a request.
        //
        // The fingerprint is taken **only for the gated triggers** (issue #169 gate): taking it
        // before every enumeration put a window-server round trip in front of the *first paint*,
        // where it can only be a way for the wall to show nothing. So a gated trigger pays it first,
        // and an enumerating trigger reads its baseline *after* the paint it caused.
        let gated = trigger.gatesOnFingerprint
        let fingerprint = gated ? (options.demo ? Self.demoFingerprint : timedFingerprint()) : nil
        if let fingerprint, !force,
           !WallRefresh.shouldEnumerate(trigger, now: fingerprint, drawn: wallFingerprint) {
            return
        }
        if let fingerprint { wallFingerprint = fingerprint }
        // The one enumeration in the wall, and it is counted: an idle wall's count must not move.
        let model = options.demo ? WallSource.demoModel() : WallSource.model()
        wallEnumerations += 1
        if options.debug {
            Log.write("krd: wall enumeration \(wallEnumerations) (trigger "
                      + "\(trigger)" + (force ? " forced" : "") + ")\n")
        }
        guard WallRefresh.needsRepaint(current: model, drawn: wallModel, pane: pane,
                                       drawnPane: wallPane, force: force) else {
            if !gated { wallFingerprint = options.demo ? Self.demoFingerprint : timedFingerprint() }
            return
        }
        wallModel = model
        wallPane = pane
        clampAndDraw(model: model, pane: pane)
        // The poll's baseline, taken *after* the paint was started: a fingerprint in front of a paint
        // is an extra window-server round trip on the wall's slowest path, and the first paint is the
        // one place it could mean "no wall at all".
        if !gated { wallFingerprint = options.demo ? Self.demoFingerprint : timedFingerprint() }
    }

    /// `WallSource.fingerprint()` with its own cost on the debug log. "Well under the old 1.24 ms per
    /// second" is a claim about a number, so the number is printed rather than asserted — a probe
    /// reads it back and a reviewer can check it against the rate.
    private func timedFingerprint() -> WallFingerprint {
        guard options.debug else { return WallSource.fingerprint() }
        let started = DispatchTime.now().uptimeNanoseconds
        let fingerprint = WallSource.fingerprint()
        let micros = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000
        Log.write(String(format: "krd: wall fingerprint %.1f us\n", micros))
        return fingerprint
    }

    /// Clamp the state against this model and pane, then paint. Both callers of a repaint go
    /// through here — the enumeration path and the relayout path — so there is one definition of
    /// how many cards fit.
    private func clampAndDraw(model: WallModel, pane: PaneGeometry) {
        // The world can shrink under a static wall (a display unplugged, a window closed) while the
        // offsets still point past the end; clamping here is what keeps the shelf from going blank.
        // The clamp takes the layout's *effective page size*: below 28 columns `WallLayout.make`
        // shows fewer cards per row than `state.per` asks for, and a tall band holds more than one
        // row of them, so clamping against the request would leave the last page unreachable (the
        // bar jumps to the layout's `maxStart`, the clamp pulls it back). The layout is built from
        // the state as it is now, then the state is clamped, then `drawWall()` builds it again —
        // two pure calls on one number, no third definition of "how many cards fit".
        if let state = wallState {
            let layout = state.layout(cols: pane.cols, rows: pane.rows,
                                      displays: model.displays.count,
                                      windows: model.windows.count,
                                      stageAspect: stageAspect(model, state),
                                      cellAspect: pane.cellAspect)
            wallState?.clamp(displays: model.displays.count, windows: model.windows.count,
                             capacity: layout.capacity)
        }
        drawWall()
    }

    /// Paint from the cached model. The click path uses this and never `refreshWall(force: true)`:
    /// a click has to be drawn against the list it was made on, and re-enumerating every window
    /// dictionary inside a click handler is not a thing to do.
    private func drawWall() {
        guard let state = wallState, let pane = wallPane else {
            // Silence here was the worst kind: the wall would sit on an alternate screen with nothing
            // in it and no line anywhere saying why. Every other early return in the paint path says
            // its reason (issue #169 gate: "any failure must log").
            Log.write("krd: wall paint skipped, no \(wallState == nil ? "state" : "pane")\n")
            return
        }
        let layout = state.layout(cols: pane.cols, rows: pane.rows,
                                  displays: wallModel.displays.count,
                                  windows: wallModel.windows.count,
                                  stageAspect: stageAspect(wallModel, state),
                                  cellAspect: pane.cellAspect)
        // The layout clamps both offsets to what this pane and this model can show, so its answer is
        // the page the reader is about to see. Write it back: `⤢` changes the page size without
        // touching the model or the pane, and `refreshWall` returns before its own clamp while those
        // two stand still, so a step made after a row-width click would otherwise start from the page
        // the state remembers rather than the one on screen (`WallState.adopt`).
        wallState?.adopt(layout)
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
            // The flag tracks a frame that actually went out, not an attempt: set before the paint it
            // would make one failed write permanent (`paintWall` reports whether it wrote).
            wallPaintedOnce = paintWall(layout: layout, model: model, panels: [],
                                        pictures: [], failures: [:])
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
                // A frame whose world moved while it was being captured is dropped, not painted
                // (issue #169 gate): painting it would show a stale picture and *then* cost a second
                // capture and paint to correct it — that second whole capture is exactly what put the
                // staleness bound at 3.0 s instead of 2.5 s. One capture of the model the desk holds
                // now is both cheaper and fresher.
                guard desk.wallModel == model, desk.wallPane == pane, !desk.cleanedUp else {
                    if !desk.cleanedUp {
                        Log.write("krd: wall dropped a stale frame (the world moved during its capture)\n")
                        desk.wallDirtyWhilePainting = false
                        desk.drawWall()
                    }
                    return
                }
                if !result.failures.isEmpty {
                    // A mask is a picture that did not happen: say which slot and why, once per frame,
                    // or "the card is a grey box" has no answer anywhere (issue #169 gate).
                    let reasons = result.failures
                        .sorted { $0.key < $1.key }
                        .map { "\($0.key):\($0.value.maskLabel)" }
                        .joined(separator: " ")
                    Log.write("krd: wall capture failed for \(result.failures.count) panel(s) - \(reasons)\n")
                }
                desk.paintWall(layout: layout, model: model, panels: panels,
                               pictures: result.pictures, failures: result.failures)
                if desk.wallDirtyWhilePainting, !desk.cleanedUp {
                    desk.wallDirtyWhilePainting = false
                    // A repaint, not a re-enumeration: everyone who can set this flag already read
                    // the world (a trigger enumerated, `wallTick` adopted the grid, a click resynced),
                    // and `drawWall` paints the model the desk holds now. This used to be
                    // `refreshWall(force: true)` — the *third* enumeration of a single resize (#169).
                    desk.drawWall()
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
                            pane: PaneGeometry) -> [WallPanel] {
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
        // One rule for both transports: capture at `pane.dpr` device pixels per *reported* cell, i.e.
        // at the pane's real resolution when the terminal answered in points (`dpr` 2) and 1:1 when it
        // answered in device pixels. With placeholders that number is quality - the terminal fits the
        // image into the cells either way, but a 1x capture on a 2x pane is a screenshot upscaled by
        // the terminal, which reads as soft - and on the pixel-sized path it *is* the geometry, so it
        // has to be the same number. `--dpr` overrides both.
        let scale = options.dpr ?? pane.dpr
        let cell = pane.pictureCell(scale: scale)
        return WallPanels.plan(layout: layout, cellW: cell.w, cellH: cell.h,
                               stageSource: stage, cardSources: cards)
    }

    /// Integer when the number is one, otherwise one decimal: the footer has room for a number, not
    /// for a float's opinion of it.
    private static func trim(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    /// Paint the text, then the pictures on the cells the text was told to leave alone.
    @discardableResult
    private func paintWall(layout: WallLayout, model: WallModel, panels: [WallPanel],
                           pictures: [WallPictures.Picture], failures: [Int: PanelCaptureError]) -> Bool {
        guard let canvas = wallCanvas, let pane = wallPane, let state = wallState else {
            Log.write("krd: wall frame not written (canvas, pane or state missing)\n")
            return false
        }
        var paints = WallSlotPaints()
        for panel in panels {
            if let failure = failures[panel.slot] {
                paints.mark(slot: panel.slot, .mask)
                paints.maskReasons[panel.slot] = failure.maskLabel
            } else {
                paints.mark(slot: panel.slot, .picture)
                if panel.slot > 0 { paints.cardPictureCells[panel.slot] = panel.rect }
            }
        }
        if options.demo {
            // One line that answers "why does the picture not fill its box" without a screenshot:
            // the pane, the cell it was measured at, the quality factor, the stage's cells and
            // pixels, and which transport the pictures went out on.
            let scale = options.dpr ?? pane.dpr
            let cell = "cell \(Self.trim(pane.cellW))x\(Self.trim(pane.cellH))"
            let stage = panels.first { $0.slot == 0 }.map {
                "pic \($0.rect.cols)x\($0.rect.rows)c \($0.fit.contentWidth)x\($0.fit.contentHeight)px"
            } ?? "no stage"
            let dot = options.symbols.dot
            paints.demoNote = "demo \(pane.cols)x\(pane.rows) \(dot) \(cell) \(dot) "
                + "\(Self.trim(scale))x \(dot) \(stage) \(dot) "
                + "\(wallPlaceholders ? "U=1" : "a=p") \(dot) \(pane.source)"
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
        let text = canvas.draw(cols: pane.cols, rows: pane.rows, model: model,
                               layout: layout, focus: state.focus,
                               cellW: pane.cellW, cellH: pane.cellH, paints: paints)
        // The canvas answers with no bytes when the frame it was asked for is the frame already on
        // the pane (its own diff). That is the normal idle answer, not a failure — but a *first*
        // paint that produced no bytes is a wall with nothing on it, and the caller needs to know.
        let wrote = !text.isEmpty
        writer.writeChrome(text)
        guard !pictures.isEmpty else { return wrote }
        // The same frame contract the tile path uses: `emitPanel` only appends, `endFrame`
        // flushes. Without the pair the pictures would sit in the writer's buffer forever - which
        // is exactly what the first live run looked like: blank panels and no bytes on the wire.
        writer.beginFrame()
        for picture in pictures {
            // `panel.rect` is the picture's own rectangle (WallPanels.make), so mask, placeholder,
            // caption and picture are one box, and the cells outside it stay unpainted.
            // With placeholders the terminal fits the image into this exact cell rectangle, so the
            // picture lands where the layout says whatever the terminal claims its cell is. The
            // pixel-sized path stays behind the flag: it is the only way to tell which of the two
            // misbehaved when a terminal refuses placeholders.
            let bytes: Int
            if wallPlaceholders {
                bytes = writer.emitPanelAsPlaceholder(id: picture.panel.imageID,
                                                      placementID: picture.panel.placementID,
                                                      row: picture.panel.rect.row,
                                                      col: picture.panel.rect.col,
                                                      cols: picture.panel.rect.cols,
                                                      rows: picture.panel.rect.rows,
                                                      pixels: picture.pixels, width: picture.width,
                                                      height: picture.height, level: Self.wallPanelLevel,
                                                      paneCols: pane.cols, paneRows: pane.rows,
                                                      format: .rgba, sync: writer.perTileSync)
            } else {
                bytes = writer.emitPanel(id: picture.panel.imageID, placementID: picture.panel.placementID,
                                         row: picture.panel.rect.row, col: picture.panel.rect.col,
                                         cols: picture.panel.rect.cols, rows: picture.panel.rect.rows,
                                         pixels: picture.pixels, width: picture.width,
                                         height: picture.height, level: Self.wallPanelLevel,
                                         // RGBA: the bars are transparent so the wall's own background shows
                                         // through (design §6.6) - the mirror's tiles stay opaque RGB.
                                         format: .rgba, sync: writer.perTileSync)
            }
            // The landing screen's own unit of cost (issue #88): one line per panel, saying how many
            // pixels it was and how many bytes zlib made of them at this `--wall-quality`. `--demo`
            // is what makes the number reproducible without a desktop - same pattern, same path, same
            // encoder - and `--wall-quality 100` beside it is the before/after pair.
            if options.demo || options.debug, bytes > 0 {
                // `bytes` is the zlib payload, not the whole wire (the escapes and the placeholder
                // grid are the transport's), so the line says payload.
                Log.write("krd: wall slot \(picture.panel.slot) picture "
                          + "\(picture.width)x\(picture.height) px -> \(bytes) B payload "
                          + "at --wall-quality \(options.wallQuality.value) "
                          + "(\(options.wallQuality.label))\n")
            }
        }
        writer.endFrame()
        return true
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
            arguments = Self.mirrorArguments(windowID: nil, cell: nil, at: at,
                                             sticky: Self.stickyArguments(options))
        case .window(let index):
            guard wallModel.windows.indices.contains(index) else { return }
            arguments = Self.mirrorArguments(windowID: wallModel.windows[index].windowID,
                                             cell: nil, at: at,
                                             sticky: Self.stickyArguments(options))
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
                               at: (stage: Int, card: Int)?, sticky: [String] = []) -> [String] {
        var arguments = windowID.map { ["--window", String($0)] } ?? ["--mirror"]
        if let cell {
            arguments += ["--cell", "\(Int(cell.w))x\(Int(cell.h))"]
        }
        if let at {
            arguments += ["--wall-at", "\(at.stage):\(at.card)"]
        }
        return arguments + sticky
    }

    /// The wall's command line, as a mirror spells it on its way back. Pure, and the exact inverse of
    /// the parser — `wallArguments` then `parseArguments` has to be a round trip, or the reader
    /// returns to a different shelf than the one they left.
    static func wallArguments(at: (stage: Int, card: Int)?,
                              exit: Int32 = 0, said: String? = nil,
                              sticky: [String] = []) -> [String] {
        var arguments = ["--wall"]
        if let at {
            arguments += ["--wall-at", "\(at.stage):\(at.card)"]
        }
        if exit != 0 {
            arguments += ["--said", String(exit), said ?? ""]
        }
        return arguments + sticky
    }

    /// Whether a pinned `--scale` below 1 has to abandon placeholders.
    ///
    /// WHY: a placeholder grid draws one image pixel per device pixel, so it cannot stretch a
    /// smaller frame into its cells - measured on Rex with `--scale 0.8`: 15x10 tiles each occupying
    /// 80 % of its slot, i.e. 14 vertical seams and 9 horizontal ones. A *pixel* placement (`a=p`
    /// with `c`/`r`) is scaled by that terminal, which is what `--scale` always assumed. Pure, so the
    /// one decision is a test rather than a screenshot.
    static func scaleNeedsPixelPlacements(placeholdersForced: Bool?, pinnedScale: Double?,
                                          deviceCell: Bool) -> Bool {
        guard placeholdersForced == nil, let pinnedScale, pinnedScale < 0.999, deviceCell else {
            return false
        }
        return true
    }

    /// Whether this run is *only* a listing: the one path that paints nothing, so it owes the
    /// terminal neither the placeholder capability query nor the `ESC _ G a=d,d=i,i=31 ESC \`
    /// cleanup that follows it (issue #124: `krd --list | awk` used to get `_Ga=d,...` as its first
    /// field). Pure, so the guard is a test rather than a hexdump.
    ///
    /// `--list` *riding on* `--replay` or `--mock` still paints those frames, so the probe stays:
    /// the exclusion is about the path that exits after printing, not about the flag.
    static func listsOnly(_ options: Options) -> Bool {
        options.listOnly && options.replay == nil && !options.mock
    }

    /// Whether the placeholder transport has to be given the picture's whole cell box (issue #86).
    ///
    /// WHY this is a second question and not part of `scaleNeedsPixelPlacements`: a placeholder grid
    /// drawn one image pixel per device pixel cannot stretch a smaller frame back into its cells, so
    /// there the frame *is* the cell box and `--scale` has no pixels to give away (a short tile is a
    /// column of background at its right edge - measured on Rex as 14 vertical seams at `--scale
    /// 0.8`). A terminal whose cell arrived in *points* draws the image at its own size and scales it
    /// into the cells, so `--scale` stays what it always was there: bandwidth, not geometry
    /// (`ScaleTransportTests.testATerminalThatStretchesKeepsPlaceholders`). Pure, so the one decision
    /// is a test rather than a screenshot.
    static func placeholderNeedsCellBox(placeholders: Bool, deviceCell: Bool) -> Bool {
        placeholders && deviceCell
    }

    /// Whether the cell reached us in *device* pixels - the pty answered `ws_xpixel`, or the operator
    /// said `--cell`. That is the terminal that draws an image one image pixel per device pixel.
    static func cellIsInDevicePixels(_ options: Options) -> Bool {
        if options.cell != nil { return true }
        let pty = TermGeometry.read()
        return pty.pixelWidth > 0 && pty.pixelHeight > 0
    }

    /// The flags that say *how the picture is drawn*, which both pages of one pane have to agree on.
    ///
    /// WHY this exists: a hand-over is a new process, so every flag not in its `argv` is a default
    /// again - and only `--cell`, `--wall-at`, `--said` and `--window` were carried. A reader who
    /// started `krd --scale 0.8 --quality 70` because the link was slow got the cheap wall and then
    /// clicked into the display page, which is the page that *streams* at 20 fps and forgot both
    /// settings. The flags here are the ones the two modes read the same way; anything that means
    /// something only on one page (`--zoom`, `--dev`, `--demo`) stays where it was typed.
    static func stickyArguments(_ options: Options) -> [String] {
        var arguments: [String] = []
        if let cell = options.cell {
            arguments += ["--cell", "\(Int(cell.w))x\(Int(cell.h))"]
        }
        if options.scalePinned {
            arguments += ["--scale", String(format: "%g", options.scale)]
        }
        if options.qualityAuto {
            arguments += ["--quality", "auto"]
        } else if options.qualityPinned {
            arguments += ["--quality", String(options.quality.value)]
        }
        // The wall's own rung travels for the same reason (issue #88): it is a decision about *this
        // pane's* link, typed once, and a click into a picture and back is a new process. `auto`
        // equals the default, so an untyped knob needs no flag - the guard is the value, not a
        // pinned bit.
        if options.wallQuality != QualityBudget.wall {
            arguments += ["--wall-quality", String(options.wallQuality.value)]
        }
        if options.fps != Options().fps {
            arguments += ["--fps", String(options.fps)]
        }
        if let dpr = options.dpr {
            arguments += ["--dpr", String(format: "%g", dpr)]
        }
        if let placeholders = options.placeholders {
            arguments.append(placeholders ? "--placeholders" : "--no-placeholders")
        }
        if options.square { arguments.append("--square") }
        if options.drawsCursor { arguments.append("--cursor") }
        // Diagnostics follow their file, never the picture: without `--log` the hand-over leaves
        // `--debug` behind, because the next process's stderr *is* the picture - the mirror's first
        // `frame ... px` line landed across the reader's screen the moment it was carried blindly.
        if let path = options.logPath {
            arguments += ["--log", path]
            if options.debug { arguments.append("--debug") }
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
        // The child owns the pane: a trigger landing after `exec` would enumerate for a wall that is
        // no longer on screen.
        stopWallTriggers()
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
        startWallTriggers()
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
        // No frame is coming: the card must not keep looping behind the error.
        if let card = loading { card.stop(); loading = nil }
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

    /// A replay that cannot honour the recording, said where a reader can see it -- the log (so
    /// `--log` explains itself), stderr (so a terminal and a CI job both read it) -- and `exit(1)`.
    ///
    /// Not a `throw`: a thrown `DeskError` reaches only the log (measured on `cd9ac5d`: `--selftest
    /// --scale 0.5` exits 1 with nothing on stdout or stderr), which main.swift already notes next to
    /// the `--quality` refusal. A replay that stops without a word is the failure this module exists
    /// to refuse, so every refusal in `runReplay` leaves through here.
    ///
    /// Both destinations, nothing said twice: `Log` has a file only when `--debug`/`--log`/
    /// `--stats-json`/wall mode gave it one, and its sink *is* stderr otherwise (see the body).
    private func failReplay(_ message: String) -> Never {
        Log.write("krd: \(message)\n")
        // `Log`'s sink is stderr unless `--debug`/`--log`/`--stats-json`/wall mode gave it a file --
        // and without a file the write above already reached the reader, so writing both would print
        // the sentence twice (measured with `--replay --mirror`).
        if Log.path != nil { FileHandle.standardError.write(Data("krd: \(message)\n".utf8)) }
        exit(1)
    }

    // MARK: replay

    /// Feed recorded frames through the real pipeline. With `--bench` the output is discarded
    /// and only the summary is printed; without it the frames are painted into the terminal at
    /// the recorded pace, which is how a "it stutters when I scroll" report gets reproduced.
    private func runReplay(dir: String, discard: Bool) async throws {
        guard let replay = FrameReplay.open(dir), let header = replay.header else {
            failReplay("no usable manifest.jsonl in \(dir) (record one with --record <dir>)")
        }
        TermGeometry.fallbackCell = header.cell
        TermGeometry.pinnedCell = header.cell     // the recording's cell beats a stray --cell
        var geometry = TermGeometry.read()
        geometry.cols = header.pane.cols
        geometry.rows = header.pane.rows
        geometry.pixelWidth = 0                     // make cellSize return the header's cell
        geometry.pixelHeight = 0
        useLiteralSource(CGRect(x: 0, y: 0, width: header.source.w, height: header.source.h))
        applyLayout(geometry: geometry)
        guard let layout = currentGrid() else { failReplay("could not compute a tile layout") }
        // A bpp mismatch would read past the end of every frame buffer (`extract` uses the
        // grid's bpp), so it has to be refused before the first frame, not diagnosed after a
        // crash deep inside memcpy.
        guard layout.bpp == replay.bpp else {
            failReplay("replay frames are \(replay.bpp) bpp but this build renders \(layout.bpp) bpp "
                        + "(the recording was made with --format \(header.format)); replay with "
                        + (replay.bpp == 4 ? "--format rgba" : "--format rgb"))
        }
        // Every manifest line declares its own frame (issue #133), so the size check is per entry
        // rather than per recording, and it subsumes the "header layout vs frame size" guard that
        // used to live here -- with the difference that this sentence names the frame, the size its
        // own line declares and the size the header renders, where that one could only compare two
        // numbers. A missing file, a short file, or a frame from another layout is one sentence on
        // stderr and exit 1, before anything is painted. Until this existed the loop below answered
        // `nil` with one log line and a `break`, then printed the ordinary summary -- counting the
        // *declared* frames -- and exited 0: measured on cd9ac5d, a valid two-frame recording painted
        // nothing, reported "2 frames" with `bytes 0`, and not one word on stderr.
        if let refusal = replay.refusal(layoutWidth: layout.pixelW, layoutHeight: layout.pixelH,
                                        bpp: layout.bpp) {
            failReplay(refusal)
        }
        writer.resize(tiles: layout.count)
        writer.discardOutput = discard
        writer.beginSession()

        var payload: [Double] = [], zlib: [Double] = [], writes: [Double] = []
        var wire: [Double] = [], wall: [Double] = []
        for i in 0..<replay.entries.count {
            guard let pixels = replay.frame(i) else {
                // The pre-flight cannot see this one coming: a `.raw` with mode 000 passes `stat` and
                // fails the read. The session is live here, so hand the terminal back before saying so.
                writer.endSession()
                failReplay(replay.refusal(i, layoutWidth: layout.pixelW, layoutHeight: layout.pixelH,
                                          bpp: layout.bpp)
                           ?? "replay frame \(i) (\(replay.entries[i].name)) could not be read, "
                           + "although its size still matches its manifest line")
            }
            let t0 = benchNowMs()
            handleFrame(pixels: pixels, width: layout.pixelW, height: layout.pixelH)
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
        var text = "krd: replay \(dir) — \(replay.entries.count) frames, \(layout.pixelW)x\(layout.pixelH) px, "
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
                writer.writeAPC("Ga=d,i=901")   // same sink, so it is enveloped like the rest
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
        guard options.scaleAuto || options.qualityAuto else { return }
        framesSinceTick += 1
        let target = options.qualityAuto ? effectiveFps : options.fps
        // `writeMs` only fires once sshd has stopped reading, i.e. after seconds of picture have
        // piled up in its userspace buffer. The round trip sees the same congestion earlier, because
        // its own answer queues behind those bytes (issue #52).
        let rttLate = rttProbe.lastMs > rttBudgetMs
        // One rule, kept in `krdcore` so a test can feed it a synthetic timeline (issue #93). A frame
        // whose `write` blocked for 2.5 s is **one** late frame but **2.5 s** of wall clock, and the
        // ladder has to see the seconds: counting frames, the burst of fast frames that follows the
        // hang diluted it to ~2.5 % of a 3 s window, so a link that froze the picture nine times in
        // 34 s never left the top rung. `span` is that blocked time, floored at the frame interval.
        let sample = QualityGovernor.frameSample(writeMs: writeMs, targetFps: target, rttLate: rttLate)
        let late = sample.late
        if late { lateSinceTick += 1 }
        let now = benchNowMs() / 1000.0
        // Colour and frame rate first: they are cheap to give up and cheap to take back, and they
        // do not touch the capture stream. Resolution is the last lever and belongs to the other
        // governor, which must wait until this ladder has nothing left (see `QualityGovernor`).
        if options.qualityAuto {
            if let change = qualityGovernor.observe(at: now, late: late, span: sample.span) {
                DispatchQueue.main.async { [weak self] in self?.applyQualityChange(change) }
            } else {
                qualityGovernor.settle(at: now)
            }
        }
        guard options.scaleAuto, !options.qualityAuto || qualityGovernor.handOver else { return }
        if let change = governor.observe(at: now, late: late) {
            DispatchQueue.main.async { [weak self] in self?.applyScaleChange(change) }
        } else {
            governor.settle(at: now)
        }
    }

    /// A quality rung, applied in place: no reconfiguration, no teardown, the next frame is simply
    /// encoded at the new ceiling and the loop allows the new frame rate.
    ///
    /// Setting `writer.quality` rebuilds `LevelPolicy`, so the per-tile levels and the quantisation
    /// guard start over. That is deliberate: the measured ratios were for a different bit depth, and
    /// carrying them across would make the first frames after a step compare apples to oranges.
    private func applyQualityChange(_ change: QualityGovernor.Change) {
        guard options.qualityAuto else { return }
        writer.quality = QualityBudget(change.to.quality)
        effectiveFps = change.to.fps
        // A new rung owes a frame at once (the picture should not wait a period to get the better
        // rate), and carries its deadline from there.
        frameGate = FrameGate(fps: change.to.fps)
        chromeDirty = true
        Log.write("krd: \(change.line)\n")
    }

    /// Step the capture resolution in place: the same `updateSource` a pan uses (#57), so the stream
    /// is not torn down and the terminal never loses its picture (issue #64).
    private func applyScaleChange(_ change: ScaleGovernor.Change) {
        guard options.scaleAuto, let geometry, change.to != effectiveScale else { return }
        // With placeholders the frame's pixels *are* the picture's cells (design §6.9), so fewer of
        // them leave the cells short - and a terminal that draws 1:1 shows that as a seam at every
        // tile row (TROUBLESHOOTING 23g). A placeholder transport spends frame rate and colour,
        // never resolution.
        guard !placeholderTiles else {
            if !reportedScaleRefusal {
                reportedScaleRefusal = true
                Log.write("krd: --scale auto stays at 1 while tiles are placeholders - fewer pixels than "
                          + "the cells would show as seams; --no-placeholders lets it step down\n")
            }
            return
        }
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
        // (design §6.7). Slice of the same subtraction whether or not either is on. Who gives up the
        // room -- the panel or the picture -- is `Chrome.pictureRows`' decision, one function away,
        // because it is the number the tests can ask about (#118).
        let barRows = barEnabled ? 1 : 0
        let pictureRows = Chrome.pictureRows(paneRows: geometry.rows, bar: barRows > 0,
                                             panel: chromeState.panel, chrome: chromeEnabled)
        // The cell is the *terminal's* (issue #146), so `geometry` reaches the grid unmodified: the rows
        // the bar and the panels own go in as the picture's box (`rows:`), never folded into a copy of
        // the geometry. Dividing the pty's pixel height by `pictureRows` is what built a 33.46 px cell
        // out of a 33 px one, i.e. a frame 20 px taller than the cells it is drawn on.
        let area = (top: 1 + barRows, left: 1, cols: geometry.cols, rows: pictureRows)
        // The source's own size, so the grid never asks for a box bigger than the source
        // (issue #69: ScreenCaptureKit pads that with black instead of upscaling).
        let layout = TileGrid.make(geometry: geometry, rows: pictureRows, aspect: aspect,
                                   tileCols: options.tileCols, tileRows: options.tileRows,
                                   bpp: writer.format.bytesPerPixel, scale: effectiveScale,
                                   fillsCells: placeholderFillsCells,
                                   source: Viewport.layoutSource(crop: crop, full: fullRect),
                                   area: area)
        // `chromeAvailable`, not `chromeEnabled`: the bar alone is enough reason to lay the chrome
        // out (a handed-over mirror runs `--bar` with no `--dev`), and gating on the `--dev` flag
        // here left `chromeGeometry` nil, so `drawChrome` bailed and the bar never appeared. Caught
        // by `testAMockMirrorDrawsItsBar`; the merge of #76 is where this gate regressed.
        // One line that makes the mirror's geometry answerable without a screenshot: the pane, the
        // cell, the source, and what the fit made of them. "The display page is smaller than the
        // pane" has to be diagnosable by reading a number, not by looking at a picture.
        Log.write("krd: mirror grid \(layout.paneCols)x\(layout.paneRows) cells at "
                  + "\(Int(geometry.cellSize.w))x\(Int(geometry.cellSize.h)) px, "
                  + "pane \(geometry.cols)x\(geometry.rows), src "
                  + "\(Int(layout.sourceW))x\(Int(layout.sourceH)) px, "
                  + "fit \(String(format: "%.3f", layout.fit)), "
                  + "origin \(layout.originCol),\(layout.originRow), "
                  + "frame \(layout.pixelW)x\(layout.pixelH) px\n")
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
        // Any grid rebuild that is *not* a resize has to forget the pane the resize path remembers
        // (issue #89): a pan, a zoom, a `--scale` step, a display change and a panel all re-lay out
        // from `self.geometry`, and the picture is then no longer "the pane we last fitted". Leaving
        // `mirrorPane` at its old value would let the next `SIGWINCH` claim "the pane did not move"
        // and skip the re-layout that used to heal exactly this. `handleResize` sets it again right
        // after this call, so a resize still remembers its own pane.
        mirrorPane = nil
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

    // MARK: focus (issue #110)

    /// A focus report from the terminal (`CSI O` / `CSI I`, DECSET 1004), called on the input
    /// thread -- directly by the reader, and again by it for every human input event, because any
    /// key, click or wheel means the person is here whatever the terminal last reported (I5).
    ///
    /// One line per *real* transition and nothing else (I6): a terminal that repeats its report --
    /// some do on every resize, and every keystroke arrives here too -- must neither fill the log
    /// nor reset the gate, so the early return is the common path and costs no log and no bump.
    private func noteFocus(_ on: Bool) {
        stateLock.lock()
        if on == focused { stateLock.unlock(); return }
        focused = on
        focusGeneration += 1
        // The rate in the line is the *target*, not a measurement: `--unfocused-fps` already capped
        // by the rung in force, so `--fps 20 --unfocused-fps 30` says 20 and not the other way
        // round. Computed under the same lock that saw the transition, so it cannot disagree with
        // it; written after the unlock, because `Log.write` is I/O and the capture queue wants this
        // lock.
        let rate = on ? effectiveFps : min(effectiveFps, options.unfocusedFps)
        stateLock.unlock()
        if on {
            Log.write("krd: pane focused again; the picture is back at \(rate) fps\n")
        } else {
            Log.write("krd: pane unfocused; the picture is at \(rate) fps\n")
        }
    }

    /// The rate the picture is allowed to run at right now (issue #110).
    ///
    /// Focused, that is the rung the governor has taken the loop to (`effectiveFps`, which *is*
    /// `--fps` unless `--quality auto` stepped down). Unfocused, the cap multiplies it **down** --
    /// `min`, never a replacement -- so a session already at the 10 fps rung does not speed up to
    /// `--unfocused-fps` while the pane is in the background. `--unfocused-fps 0` falls out of the
    /// same expression as a frozen picture. Read under `stateLock`: the input thread writes it.
    private var targetFps: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return focused ? effectiveFps : min(effectiveFps, options.unfocusedFps)
    }

    /// `focused` as one reading, for the panel and the JSON (both on the main queue).
    private var isFocused: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return focused
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
        if let card = loading { card.stop(); loading = nil }
        let started = benchNowMs()
        // A frame-rate step -- the governor's rung, or the cap a focus-out puts on it -- is enforced
        // here, before anything is encoded: the capture still delivers at `--fps`
        // (ScreenCaptureKit's cadence is not worth reconfiguring mid-stream), and the frames the loop
        // declines cost no zlib, no bytes and no `dirty` pass. `FrameGate.tookFrame` is called
        // *below*, once the frame is known to change something: a frame that changes nothing must not
        // consume the frame-rate slot (#95).
        //
        // A rung and a focus cap are the **same mechanism** (issue #110): a target rate with an
        // owed-frame deadline. So the cap goes through this gate and never around it (#140, I3), and
        // a focus transition is exactly "the target changed", which is what re-arms it.
        stateLock.lock()
        let focusChanged = focusGeneration != lastFocusGeneration
        if focusChanged {
            lastFocusGeneration = focusGeneration
            // A new rate means a full repaint: while the pane was throttled or frozen the picture on
            // screen is a patchwork of skipped changes, and a dirty-tile diff against the last frame
            // we *did* draw would leave the rest of it stale (issue #110 point 5).
            previousFrame = []
        }
        stateLock.unlock()
        if focusChanged {
            // A fresh gate owes a frame at once, so the new rate starts at the next captured frame --
            // at most one `--fps` period, 50 ms at 20 fps -- instead of waiting out the deadline the
            // *other* rate set. That is what makes focus-in immediate (issue #110 point 4).
            frameGate = FrameGate(fps: max(1, targetFps))
            // The governors are re-armed too: the frames that arrived while the pane was throttled
            // were judged against a rate nobody was watching, and a resume must not read them as a
            // pipe that lost ground and spend a rung on them. `settle(at:)` is the public re-arm
            // they have (it releases the upgrade backoff); the rung itself is untouched, because
            // focus only ever multiplies the rate down -- `--fps` and `--quality auto` keep the rung
            // they had.
            let now = benchNowMs() / 1000.0
            qualityGovernor.settle(at: now)
            governor.settle(at: now)
        }
        let target = targetFps
        // `--unfocused-fps 0`: the picture is frozen. Nothing draws, which is the one rate the gate
        // cannot express -- its period is finite, and a window of infinity is not a deadline. Every
        // counter below stays where it is, as if no frame had arrived.
        if target == 0 { return }
        // `--quality auto` at the top rung is `target == options.fps`, so a fast link still gates
        // nothing at all; any rate below `--fps`, from whichever of the two sources, is gated.
        //
        // `fpsPinned` is the menu's frame-rate track (issue #87): a rate the *user* clicked is a
        // third source, and it is one even when `options.fps` was moved to the same number -- the
        // capture stream is not reconfigured mid-flight, so without the gate the loop would keep
        // delivering at the old cadence and the slider would read as doing nothing. A focus cap
        // still multiplies it down (`targetFps`), never around it.
        let gated = fpsPinned || target < options.fps
        if gated, !frameGate.owesFrame(at: started) { return }
        // Frames ScreenCaptureKit delivered to us, i.e. what `captureFps` is the rate of -- counted
        // here, before the layout guards, so it stays a different number from `framesHandled`
        // ("drawn") and from `framesSkipped` ("delivered, and changed nothing"), #95.
        framesDelivered += 1
        // One line per *change* of frame size, not per frame: whether the stream is delivering the
        // pixels the grid slices. A frame smaller than `pixelW x pixelH` is the black-seam bug -
        // tiles sliced proportionally out of a smaller frame, placed 1:1 on cells they cannot fill.
        if let g = grid, width != loggedFrameSize?.0 || height != loggedFrameSize?.1 {
            loggedFrameSize = (width, height)
            Log.write("krd: frame \(width)x\(height) px, grid wants \(g.pixelW)x\(g.pixelH) px "
                      + "(\(g.paneCols)x\(g.paneRows) cells of \(g.cellW)x\(g.cellH) px, "
                      + "\(g.tilesX)x\(g.tilesY) tiles, \(g.count) total)\n")
        }
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
        var dedupedFrame = false
        defer {
            // A frame that changed nothing writes nothing, so it says nothing about the pipe
            // (issue #64). Those frames used to never reach this function at all (#95).
            if !dedupedFrame { lastPipeMs = benchNowMs() - started }
            // Both halves of the `frame` row go into their series **here**, once per frame
            // (issue #91): the 1 Hz tick only reads them. `capturer.lastCapMs` is this frame's own
            // age of capture — the capture queue is serial, and it was set just before `onFrame`.
            recordFrameLatency(capMs: capturer.lastCapMs, pipeMs: dedupedFrame ? nil : lastPipeMs)
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

        // **One scan, both questions** (issue #95). "Is this frame identical to the last one" and
        // "which tiles changed" come out of the same pass over the pixels: the capture callback
        // used to answer the first with a whole-frame `Array ==` before delivering (4.06–4.34 ms
        // at 2329x1452, element-wise for `UInt8`) and this function answered the second by reading
        // the same 10 MB again (0.47–0.51 ms). A still screen — what a blinking cursor or an idle
        // window produces — was 4.5 ms of scanning per delivered frame and is now one memcmp row
        // scan (~0.22 ms).
        let scan = TileGrid.diff(previous: previousFrame, current: pixels, grid: grid)
        if scan.identical {
            // Byte-for-byte the same frame: emit nothing at all, not even the nudge below. This is
            // the path `Capturer`'s `prev == rgba` used to take, before it ever got here.
            dedupedFrame = true
            framesSkipped += 1
            return
        }
        // **`framesHandled` counts frames that reached the encoder**, not callbacks (`Rates.fps`,
        // the panel's `frames x/y fps` row and `framesTotal` all mean "drawn"), so it advances here
        // and not above the identical check — a frame that changed nothing is not handled.
        framesHandled += 1
        if gated { frameGate.tookFrame(at: started) }

        // Recording happens before the tile pass, i.e. it captures exactly the frames the
        // pipeline would render (post-dedupe, post-resize).
        if let recorder, !recorder.isFull {
            recorder.record(pixels, width: width, height: height, bpp: grid.bpp)
        }

        // `repaintNeeded`: a clear that landed between `beginFrame` and `endFrame` was committed
        // after the frame it interrupted (see `ScreenWriter.clear`), so the pane has had no
        // placements since that commit. The dirty pass would re-send only the tiles that changed and
        // leave the rest of the picture blank.
        let dirty: [Int]
        if options.fullFrame || previousFrame.count != pixels.count || writer.reapIfNeeded()
            || writer.repaintNeeded {
            dirty = Array(0..<grid.count)
        } else {
            dirty = scan.dirty          // the tiles the scan above already found
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
            if placeholderTiles {
                // One picture for the whole pane: the same transport, one image id (2), placed on the
                // picture's cells. `--full-frame` exists for benchmarking and for terminals that
                // dislike many small images, so it has to be able to say the same thing.
                writer.emitPanelAsPlaceholder(id: 2, placementID: 2,
                                              row: grid.originRow, col: grid.originCol,
                                              cols: grid.paneCols, rows: grid.paneRows,
                                              pixels: pixels, width: width, height: height,
                                              level: writer.level(for: 0),
                                              paneCols: TermGeometry.lastGrid.cols,
                                              paneRows: TermGeometry.lastGrid.rows)
            } else {
                writer.emitFullFrame(rgba: pixels, width: width, height: height,
                                     row: grid.originRow, col: grid.originCol,
                                     cols: grid.paneCols, rows: grid.paneRows)
            }
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
                                                pixels: grid.extract(pixels, rect: rect), plan: plan)
            }
        }
        writer.addCompressTime(Date().timeIntervalSince(compressStart) * 1000)

        // Assembly stays serial: the escapes must reach the pty in a deterministic order.
        for case let tile? in packed {
            if placeholderTiles {
                writer.emitTileAsPlaceholder(tile, sync: writer.perTileSync)
            } else {
                writer.emit(tile, sync: writer.perTileSync)
            }
            writer.observe(index: tile.index, ratio: tile.ratio, quantisedIn: tile.isQuantised)
        }
        writer.endFrame()
    }

    // MARK: lifecycle

    private func installResizeHandler() {
        signal(SIGWINCH, SIG_IGN)
        // The source itself runs on the *main* queue now, not on a global one that hops here: a
        // `SIGWINCH` and the `asyncAfter` that used to carry it both ended up on the main queue
        // anyway, and `resizeBurst` is a main-queue value that a second thread must not mutate.
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // A trailing edge, not one handler run per event (issue #89). The deadline restarts on
            // every arrival and only the work item that still owns the newest token relayouts, so a
            // drag of N `SIGWINCH`es is **one** re-layout, at the pane the drag ended on — the
            // handler reads `TermGeometry` when it runs, never when the event arrived. What this
            // replaces was worse than one run per event: each run deleted every placement (`clear`),
            // re-laid out and restarted the stream -- 40 clears and 4,564 tile transmissions for a
            // 1.4 s drag (`bench/loop-resize-storm.py`).
            let now = ResizeCoalescer.now()
            let arrival = self.resizeBurst.arrive(at: now)
            DispatchQueue.main.asyncAfter(deadline: .now() + (arrival.fireAt - now)) { [weak self] in
                guard let self,
                      let collapsed = self.resizeBurst.fire(token: arrival.token,
                                                            at: ResizeCoalescer.now())
                else { return }
                self.handleResize(burst: collapsed)
            }
        }
        source.resume()
        resizeSource = source
    }

    /// `burst` is how many `SIGWINCH`es the coalescer collapsed into this run (`1` for a single
    /// resize). It decides nothing — it is logged, so the number in the log is the number that was
    /// measured. `force` is a caller that is not a signal and cannot be "unchanged" (`applyPanel`,
    /// whose change is the panel rather than the pane): it skips the shortcut below.
    private func handleResize(burst: Int = 1, force: Bool = false) {
        // The wall has no picture to re-fit: the pane changed size, so the canvas forgets its
        // previous grid (the next draw is a full repaint at the new width) and the model is re-read.
        // The guard below would no-op here — a wall session has no filter and no mock.
        if wallState != nil {
            // Re-*measure*, not just re-fit. The cell size was asked once at startup, and a terminal
            // that answered late (or was still laying the pane out) left the wall fitting every
            // picture to a guess for the rest of the session - "没有响应式". A resize is exactly the
            // moment the terminal has a fresh answer to give, and it is where a font change lands.
            remeasureWallPane()
            wallCanvas?.invalidate()
            // Drop every placement, not just the text. A picture is an object the terminal owns and
            // keeps attached to the cell it was placed on; after a resize a terminal may keep the
            // old one there, so the wall would show the old picture under the new one ("缩放的时候
            // 不支持"). One escape, and the repaint below re-transmits every panel anyway - so this
            // cannot lose anything, it can only remove what would otherwise be stale.
            writer.clear()
            refreshWall(force: true)
            return
        }
        guard !cleanedUp, filter != nil || mock != nil else { return }
        let geometry = TermGeometry.read()
        // Did the pane move at all? A `SIGWINCH` that answers with the grid the picture is already
        // fitted to (a terminal's second report for one drag, a drag out and back) has nothing to
        // do, and everything below is destructive: `clear` deletes every placement, the restart
        // tears the stream down, and the repaint re-sends every tile -- to draw the picture that is
        // already on screen. `drawn == nil` is the first resize of a session, which cannot claim
        // "unchanged" and therefore relayouts.
        let pane = ResizePane(cols: geometry.cols, rows: geometry.rows,
                             cellW: geometry.cellSize.w, cellH: geometry.cellSize.h)
        if ResizePlan.decide(drawn: mirrorPane, now: pane, force: force) == .skip {
            if options.debug {
                Log.write("resize: \(pane.cols)x\(pane.rows) unchanged, nothing to repaint\n")
            }
            return
        }
        applyLayout(geometry: geometry)
        guard let layout = currentGrid(), layout.pixelW > 8, layout.pixelH > 8 else { return }
        // Only once the layout exists: a pane that came out degenerate must be retried by the next
        // report, not remembered as done.
        mirrorPane = pane
        if burst > 1, options.debug {
            Log.write("resize: \(burst) SIGWINCHes coalesced into one relayout at "
                      + "\(layout.pixelW)x\(layout.pixelH)\n")
        }
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

    /// `kill -USR1` cycles the panel (the same cycle `Tab` does), `kill -USR2` writes the report
    /// bundle. Both exist so a session that is *stuck* can be inspected without touching the
    /// terminal that has no room left for text (issue #52).
    private func installReportHandler() {
        signal(SIGUSR1, SIG_IGN)
        let cycle = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        cycle.setEventHandler { [weak self] in
            guard let self, self.chromeAvailable else { return }
            let all = ChromePanel.allCases
            let index = all.firstIndex(of: self.chromeState.panel ?? .stats) ?? 0
            self.chromeState.panel = all[(index + 1) % all.count]
            // Same rule as `openPanel`: a different panel starts at its own end, not at the window
            // the previous one was left scrolled to (#118).
            self.chromeState.panelOffset = nil
            // ...and the same relayout `openPanel` does, forced for the same reason (issue #89): the
            // panel's rows come out of the picture while the pane stays put. This handler used to
            // leave the grid alone, which was invisible only because the next `SIGWINCH` -- even a
            // same-size duplicate -- used to re-lay out unconditionally. Now that a duplicate is a
            // no-op, the cycle has to say what it changed.
            self.applyPanel()
            self.drawChrome()
        }
        cycle.resume()
        signalSources.append(cycle)

        signal(SIGUSR2, SIG_IGN)
        let report = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        report.setEventHandler { [weak self] in self?.writeReport() }
        report.resume()
        signalSources.append(report)
    }

    /// One attachable file: what the numbers are now, where each series has been, the switches that
    /// were on, and the tail of the log. `ssh host pkill -USR2 krd` is the whole workflow, so the
    /// path is fixed rather than per-pid.
    func writeReport() {
        // Fresh numbers: the report may be asked for between ticks, or in a mode that never sampled.
        sampleRates()
        sampleChrome()
        let m = chromeMetrics
        let verdict: String
        if m.capMs < 0 {
            verdict = "capture age not measured (mock/replay, or no frame yet) — \(Int(m.pipeMs)) ms is all we do with a frame"
        } else if m.capP99Ms > m.pipeP99Ms * 2 {
            verdict = "the *capture* is the delay: cap p99 \(Int(m.capP99Ms)) ms vs pipe p99 \(Int(m.pipeP99Ms)) ms"
        } else if m.rttAvailable, m.rttP99Ms > rttBudgetMs, m.rttP99Ms > m.pipeP99Ms * 2 {
            verdict = "the *link* is the delay: rtt p99 \(Int(m.rttP99Ms)) ms vs pipe p99 \(Int(m.pipeP99Ms)) ms — our writes are not what is slow"
        } else if m.pipeP99Ms > m.capP99Ms * 2 {
            verdict = "our *write* path is the delay: pipe p99 \(Int(m.pipeP99Ms)) ms vs cap p99 \(Int(m.capP99Ms)) ms"
        } else {
            verdict = "both halves are of the same order: cap p99 \(Int(m.capP99Ms)) ms, pipe p99 \(Int(m.pipeP99Ms)) ms"
        }

        func series(_ name: String, _ s: Series, decimals: Int = 1) -> String {
            guard !s.isEmpty else { return "\(name): (no samples)\n" }
            let values = s.all.map { String(format: "%.\(decimals)f", $0) }.joined(separator: " ")
            return String(format: "%@: n=%d p50=%.1f p99=%.1f max=%.1f\n  %@\n",
                          name, s.count, s.percentile(0.5), s.percentile(0.99), s.max, values)
        }

        var out = ""
        out += "krd \(krdVersion) report\n"
        out += "pid \(getpid())  \(ISO8601DateFormatter().string(from: Date()))  host \(Host.current().localizedName ?? "-")\n"
        out += "\n== the question\n\(verdict)\n"
        out += "cap = ScreenCaptureKit callback − PTS; pipe = callback → last byte written; e2e = cap + pipe.\n"
        out += "rtt = the terminal's own answer to CSI 5n, so it includes whatever is still queued for the picture.\n"
        out += "\n== now\n"
        out += "target \(m.target)\(m.title.isEmpty ? "" : " (\(m.title))")\n"
        out += "frame \(Series.show(m.e2eMs)) ms (cap \(m.capLabel) + pipe \(Series.show(m.pipeMs)))"
            + ", p99 cap \(m.capP99Label) pipe \(Series.show(m.pipeP99Ms))"
            + ", pipe max \(Series.show(m.pipeMaxMs))"
            + ", input \(Series.show(m.inputMs)) ms, rtt \(m.rttLabel) (p99 \(m.rttP99Label))\n"
        out += String(format: "geometry %dx%d px, %dx%d cells of %gx%g (%@), scale %.3g%@\n",
                      m.pxW, m.pxH, m.cellsW, m.cellsH, m.cellW, m.cellH, m.geometrySource,
                      m.scale, m.scaleAuto ? " auto" : "")
        out += "encoder \(m.format), q\(m.quality) \(m.qualityLabel), sync \(m.sync) q=\(m.quiet), tiles \(m.tileSpec)\n"
        out += String(format: "rates %.2f fps of %d, capture %.1f/s, %d tiles/s, %.2f MB/s, %d KB/frame, skipped %.0f/s idle %.0f/s\n",
                      m.fps, m.fpsTarget, m.captureFps, m.tilesPerSec, m.mbps, m.kbPerFrame,
                      m.skippedPerSec, m.idlePerSec)
        out += String(format: "counters frames %d, delivered %d, skipped %d, idle %d, bad %d, callbacks %d\n",
                      m.framesTotal, m.delivered, m.skipped, m.idle, m.bad, m.callbacks)
        out += "switches \(m.envSwitches)\n"
        out += "input \(m.inputActive ? "active" : "off")\(m.dryRun ? ", dry-run" : ""), cursor \(m.cursorDrawn ? "drawn" : "hidden")\n"
        out += "log \(m.logPath)\n"
        if !m.recording.isEmpty { out += "recording \(m.recording)\n" }
        out += "\n== series (oldest first)\n"
        let latency = frameLatencySnapshot()
        out += series("cap", latency.cap)
        out += series("pipe", latency.pipe)
        out += series("zlib", zlibSeries, decimals: 2)
        out += series("write", writeSeries, decimals: 2)
        out += series("input", inputSeriesSnapshot())
        if m.rttAvailable { out += series("rtt", rttProbe.series) } else { out += "rtt: (not measured)\n" }
        out += "\n== last \(Log.recentLines.count) log lines\n"
        out += Log.recentLines.joined(separator: "\n") + "\n"

        let target = NSTemporaryDirectory() + "krd-report.txt"
        do {
            try out.write(toFile: target, atomically: true, encoding: .utf8)
            Log.write("krd: report written to \(target) — \(verdict)\n")
        } catch {
            Log.write("krd: could not write the report to \(target): \(error)\n")
        }
    }

    /// The input series lives in `InputReader` (it is measured where the bytes are read), but the
    /// report wants it next to the others.
    private func inputSeriesSnapshot() -> Series { input?.inputSamples ?? Series() }

    /// `KRD_RTT_BUDGET_MS`, default 250: a round trip longer than a quarter second is felt as lag
    /// even when nothing is blocking yet.
    private var rttBudgetMs: Double {
        if let raw = ProcessInfo.processInfo.environment["KRD_RTT_BUDGET_MS"], let v = Double(raw) {
            return v
        }
        return 250
    }

    /// Ask the terminal how far away it is, when the mirror is live and the answer can mean anything.
    ///
    /// Off for every path with a byte contract (`--selftest`, `--record`, `--replay`, `--bench`: a
    /// probe is 4 bytes nobody asked for), for `--mock` (no terminal to answer), and for
    /// `KRD_NO_RTT=1`. A terminal that does not implement DSR turns the probe off after a few misses.
    private var rttEnabled: Bool {
        if ProcessInfo.processInfo.environment["KRD_NO_RTT"] != nil { return false }
        return !options.mock && !options.bench && !options.selftest
            && options.record == nil && options.replay == nil
    }

    private func probeRoundTrip() {
        guard rttEnabled else { return }
        let now = benchNowMs() / 1000
        // The answer, if one arrived since the last tick. Its timestamp is the input thread's, so
        // the round trip is accurate even though this runs at 1 Hz.
        if let input, input.statusReplies != rttRepliesSeen {
            rttRepliesSeen = input.statusReplies
            if let ms = rttProbe.reply(at: input.lastStatusReplyAt) {
                Log.write(String(format: "krd: rtt %.1f ms (CSI 5n round trip)\n", ms))
            }
        }
        if rttProbe.due(at: now), writer.writeControl("\u{1B}[5n") {
            rttProbe.sent(at: now)
        }
        if rttProbe.expire(at: now) {
            if rttProbe.unavailable {
                Log.write("krd: no answer to CSI 5n after \(rttProbe.misses) tries — the terminal does not implement DSR, so the rtt measurements stop here (write latency still counts)\n")
            } else {
                Log.write("krd: probe unanswered (CSI 5n) — retrying\n")
            }
        }
    }

    /// The one 1 Hz diagnostics tick: sample once, then feed every consumer from that snapshot --
    /// the panel, the `--debug` line and `--stats-json`.
    ///
    /// One timer rather than one per renderer, because rates are *deltas over an interval*: two
    /// timers sampling the same counters would each see half the interval and print half the rate.
    private func startDiagnostics() {
        let statsJSON = StatsJSONWriter(path: options.statsJSON)
        probeRoundTrip()
        sampleRates()
        sampleChrome()
        if chromeAvailable { drawChrome() }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.probeRoundTrip()
            self.sampleRates()
            self.sampleChrome()
            if self.chromeAvailable { self.drawChrome() }
            self.emitDiagnostics(json: statsJSON)
        }
        timer.resume()
        diagnosticsTimer = timer
    }

    /// The `--debug` line and `--stats-json`, both read from the panel's own metrics: one schema,
    /// two renderers (issue #52's acceptance test).
    private func emitDiagnostics(json: StatsJSONWriter?) {
        let m = chromeMetrics
        // Frames the write side could not keep up with, since the previous tick (issue #64).
        let late = lateSinceTick
        let seen = framesSinceTick
        lateSinceTick = 0
        framesSinceTick = 0
        if options.debug {
            let line = String(
                format: "stats: %d tiles/s  %d dirty  %d KB  %.2f MB/s  "
                    + "ms[cap=%.1f pipe=%.1f(p99 %.1f max %.1f) zlib=%.0f write=%.0f max=%.0f over5=%d]  "
                    + "%dx%d px %dx%d cells  delivered=%d/s skipped=%d/s idle=%d/s bad=%d  "
                    + "input=%.1f rtt=%.1f late=%d/%d\n",
                m.tilesPerSec, m.dirty, m.kbPerFrame, m.mbps,
                m.capMs, m.pipeMs, m.pipeP99Ms, m.pipeMaxMs, m.zlibMs, m.writeMs, m.writeMaxMs, m.writeOver5,
                m.pxW, m.pxH, m.cellsW, m.cellsH,
                Int(m.captureFps.rounded()), Int(m.skippedPerSec.rounded()),
                Int(m.idlePerSec.rounded()), m.bad, m.inputMs,
                m.rttAvailable ? m.rttMs : -1, late, seen)
            Log.write(line)
        }
        json?.write(m, late: late, frames: seen)
        writer.resetWriteStats()
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
        // No timer here: `startDiagnostics()` samples once a second and draws the panel from that
        // same snapshot. Two timers meant two sets of deltas, and "tiles/s" printed by the panel was
        // not the one printed by `--debug` (issue #52).
    }

    /// Turn the counters into rates, once per tick, from one snapshot pair.
    ///
    /// Called only by `startDiagnostics()`: two callers would consume the deltas twice and halve
    /// every rate in the process.
    @discardableResult
    private func sampleRates() -> Rates {
        let now = benchNowMs() / 1000.0
        let current = Rates.Counters(frames: framesHandled, delivered: framesDelivered,
                                     tiles: writer.framesEmitted, bytes: writer.totalBytes,
                                     skipped: framesSkipped, idle: capturer.idleFrames)
        if rateSampleAt > 0 {
            lastRates = Rates(previous: rateCounters, current: current, seconds: now - rateSampleAt)
        }
        rateCounters = current
        rateSampleAt = now
        return lastRates
    }

    /// The `frame` row's two series, fed by the frame path and read by the 1 Hz tick.
    ///
    /// **One sample per frame, not one per second** (issue #91). `pipe` used to enter its ring once a
    /// second, from `sampleChrome()` pushing a single `lastPipeMs`: that is the p99 of 20 fps worth of
    /// work seen through a 1 Hz keyhole. A frame that blocked for 1,368 ms reported `pipe_ms 0.30`
    /// and `pipe_p99 0.36` in the same tick whose `write_max_ms` said 1367.86, and `pipe_p99` never
    /// left 0.40 ms for a whole run. `Series` is a ring either way, so the honest version costs one
    /// append per frame where it used to cost a property store per frame plus a sample per second.
    ///
    /// Written on the capture queue and read on the main queue (`sampleChrome`, `writeReport`), so
    /// it goes through the same `stateLock` the grid and the previous frame already use for that
    /// handoff.
    private func recordFrameLatency(capMs: Double, pipeMs: Double?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        // `cap >= 0` is "there is a presentation timestamp to measure against"; `--mock`, `--replay`
        // and `--selftest` have none and must leave the series empty rather than record a zero.
        if capMs >= 0 { capSeries.add(capMs) }
        // `nil` = a frame that changed nothing: it wrote nothing, so it says nothing about the pipe
        // (issue #64). It still says how old the capture already was, hence `cap` above.
        if let pipeMs { pipeSeries.add(pipeMs) }
    }

    /// A copy of the two series for the tick and the report, taken under the same lock that
    /// `recordFrameLatency` writes them with.
    private func frameLatencySnapshot() -> (cap: Series, pipe: Series) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (capSeries, pipeSeries)
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
        // The current target, not the configured one: `x/y fps` is a comparison, and while the pane
        // is unfocused the picture really is being held at the cap, so showing `--fps` there would
        // make a deliberate throttle read as a pipe that cannot keep up (issue #110). Focus only
        // ever multiplies the rate down, so with the focus the row means exactly what it always did:
        // the governor's rung under `--quality auto`, `--fps` otherwise.
        let focusedNow = isFocused
        m.focused = focusedNow
        m.fpsTarget = focusedNow
            ? (options.qualityAuto ? effectiveFps : options.fps)
            : min(options.qualityAuto ? effectiveFps : options.fps, options.unfocusedFps)
        // Rates come from `sampleRates()`, which owns the one definition of what `fps`, `tiles/s`,
        // `MB/s` and the two starvation rates mean (issue #52).
        m.fps = lastRates.fps
        m.captureFps = lastRates.captureFps
        m.mbps = lastRates.mbps
        m.skippedPerSec = lastRates.skippedPerSec
        m.idlePerSec = lastRates.idlePerSec
        m.scale = effectiveScale
        m.scaleAuto = options.scaleAuto
        chromeSampleFrames = framesHandled
        chromeSampleDelivered = framesDelivered
        m.kbPerFrame = writer.lastFrameBytes / 1024
        m.quality = writer.quality.value
        m.qualityLabel = writer.quality.label
        // The menu's three tracks read these (issue #87): which half of `--quality` is set, and
        // whether a governor still owns the axis -- a slider whose value walks back needs to say so.
        m.qualityEager = writer.quality.eager
        m.qualityGoverned = options.qualityAuto
        m.quantisedTiles = writer.quantisedTiles
        m.skippedTiles = writer.skippedTiles
        m.tilesPerSec = Int(lastRates.tilesPerSec.rounded())
        m.dirty = lastDirtyCount
        m.tilesTotal = layout?.count ?? 0
        m.framesTotal = framesHandled
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
        // The split: `cap` is how old the frame already was when ScreenCaptureKit handed it over,
        // `pipe` is everything we do with it until the last byte is out. `e2e` is their sum, and it
        // is the only number that answers "was it the capture or the write" (issue #52).
        let capNow = capturer.lastCapMs
        // The two series were filled by the frame path, one sample per frame (issue #91). The tick
        // reads them; it must not add to them, which is what made `pipe p99` a 1 Hz average.
        let latency = frameLatencySnapshot()
        m.capMs = capNow
        m.capP99Ms = capNow >= 0 && !latency.cap.isEmpty ? latency.cap.percentile(0.99) : -1
        m.pipeMs = lastPipeMs
        m.pipeP99Ms = latency.pipe.isEmpty ? 0 : latency.pipe.percentile(0.99)
        // A p99 over 300 frames is the 4th-worst of them, so *one* 1,368 ms frame cannot move it —
        // `max` is the readout that shows a single hiccup (issue #91).
        m.pipeMaxMs = latency.pipe.isEmpty ? 0 : latency.pipe.max
        zlibSeries.add(writer.lastCompressMs)
        writeSeries.add(writer.lastWriteMs)
        m.e2eMs = capNow >= 0 ? capNow + lastPipeMs : lastPipeMs
        m.zlibMs = writer.lastCompressMs
        m.zlibP99Ms = zlibSeries.isEmpty ? 0 : zlibSeries.percentile(0.99)
        m.writeMs = writer.lastWriteMs
        m.writeMaxMs = writer.writeMaxMs
        m.writeOver5 = writer.writeOver5Ms
        m.callbacks = capturer.callbacks
        m.delivered = framesDelivered
        m.skipped = framesSkipped
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
        m.rttMs = rttProbe.lastMs
        m.rttP99Ms = rttProbe.p99Ms
        m.rttAvailable = rttEnabled && rttProbe.isMeasuring
        m.inputMs = input?.lastInputMs ?? 0
        m.inputP99Ms = input?.inputP99Ms ?? 0
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
        // the log panel is I/O: only pay for it while it is open, and only for the bytes the writer
        // added since the last tick (`LogTailReader`, #90)
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
        // The other half of the chord the reader owes the chrome (#115): while the prefix is armed,
        // the next key is the chrome's, whether it is a control byte or a printable one. Asked from
        // the reader thread, which is where `chromeKey` set it — one writer, one reader, one thread.
        reader.chromePrefixArmed = { [weak self] in self?.chromeState.prefix ?? false }
        reader.onChromeClick = { [weak self] row, col, wheel in
            self?.chromeClick(row: row, col: col, wheel: wheel)
        }
        // The reader asks this before the viewport guards: a chrome region is not "the cells the
        // picture does not cover" (#118). Wall mode has no chrome at all (`chromeAvailable` is
        // false there), so every wall click keeps taking the outside-the-picture path, which is
        // what it was built on.
        reader.chromeOwns = { [weak self] row, col in
            self?.chromeOwns(row: row, col: col) ?? false
        }
        // Focus reports (`CSI I` / `CSI O`, DECSET 1004, issue #110) are about the *picture*, never
        // about the desktop: the reader hands them straight here, on the reader thread, and
        // `noteFocus` is the one place that decides what a transition means. It is also called for
        // every human input event, so a lost `CSI I` still wakes the picture on the next keystroke.
        reader.onFocus = { [weak self] on in self?.noteFocus(on) }
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
                    "KRD_PASSTHROUGH",
                    "KRD_GRID", "KRD_QUADRANTS", "KRD_DELTEST", "KRD_RAWDUMP"]
        let active = keys.filter { env[$0] != nil }
        if active.isEmpty { return "none" }
        return active.map { "\($0)=\(env[$0] ?? "")" }.joined(separator: " ")
    }

    /// The last twelve lines of the log, newest last: what the log panel shows. The reader keeps its
    /// own offset into the file, so a tick costs what was written since the last one and not what the
    /// session has written so far -- the whole-file read here was 220 ms per second at a 19 MB log
    /// (#90).
    private func readLogTail() -> [String] {
        logTail.update(path: Log.path)
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
    ///
    /// Runs on the *reader* thread (`InputReader.onChromeKey`), which is also the only writer of
    /// `chromeState.prefix` — the flag `InputReader.chromePrefixArmed` hands back to the reader. Not
    /// `private`: the chord is one table, and `DevChordTests` drives this exact function rather than
    /// a copy of it (#115).
    func chromeKey(_ byte: UInt8) -> Bool {
        guard chromeEnabled else { return false }
        if chromeState.prefix {
            chromeState.prefix = false
            switch byte {
            case 0x1C: openPanel(nil)
            case UInt8(ascii: "q"): shutdown()
            case UInt8(ascii: "?"), UInt8(ascii: "h"): openPanel(.help)
            case UInt8(ascii: "s"): openPanel(.stats)
            case UInt8(ascii: "f"): openPanel(.settings)
            case UInt8(ascii: "d"): openPanel(.devices)
            case UInt8(ascii: "l"): openPanel(.log)
            default: break
            }
            return true
        }
        if byte == 0x1C {
            chromeState.prefix = true
            chromeDirty = true
            return true
        }
        if byte == 0x1B, chromeState.panel != nil {
            openPanel(nil)
            return true
        }
        return false
    }

    /// Show `panel` (nil closes). Opening, switching or closing a panel starts its scroll at the
    /// panel's own end: a reader who reopens the stats panel expects its first row, not the window
    /// they left behind -- and a log that has been scrolled back to the top would otherwise stay
    /// pinned to old lines forever (#118).
    private func openPanel(_ panel: ChromePanel?) {
        chromeState.panel = panel
        chromeState.panelOffset = nil
        applyPanel()
    }

    /// The wall consumes every click on the pane: the whole pane is text, so "outside the picture"
    /// is the normal case there, and a cell the wall does not know is swallowed rather than
    /// forwarded to the remote desktop (design §8: the route decision is "inside the picture
    /// rect", and the wall has no picture at all).
    func chromeClick(row: Int, col: Int, wheel: Int) {
        if wallMode {
            // A wheel report is not a click: it scrolls the shelf it is over instead of entering
            // the card under the cursor (a two-finger scroll used to enter a window by accident).
            // This closure runs on the *reader* thread (`InputReader.onChromeClick`), while the
            // wall's 1 s tick, `handleResize()` and `shutdown()` all own the desk on the main
            // queue. Mutating `wallState` and repainting from here would race that tick on the
            // canvas's previous-cell grid and on the shelf offsets, so the wall branch only hops:
            // after this line everything the wall owns is touched by exactly one thread.
            DispatchQueue.main.async { [weak self] in
                self?.wallClick(row: row, col: col, wheel: wheel)
            }
            return
        }
        guard chromeAvailable, let geometry = chromeGeometry else { return }
        if options.debug {
            Log.write("chrome: click wall=\(wallMode ? 1 : 0) row=\(row) col=\(col) wheel=\(wheel) "
                      + "hit=\(chrome.hitTest(row: row, col: col, geometry: geometry))\n")
        }
        switch chrome.route(row: row, col: col, geometry: geometry) {
        case .status(let id):
            // A notch is not a click, even when it lands on a segment: a two-finger scroll over the
            // bar used to take whatever the segment does, and one of them shrinks the mirror back
            // into the wall (#118).
            guard wheel == 0 else { return }
            // The bar's one control: a click on `[ - ]` (or on the traffic lights, which is what a
            // red one does) shrinks this window back into the wall. Same path as `Ctrl-\`, so the
            // two ways out cannot drift.
            if id == "shrink" {
                shutdown()
                return
            }
            // The menu's three sliders (issue #87). The same button closes it: a menu with no way
            // out but a key would be a keyboard control, and this one has to work on a page that
            // has no `--dev` chord table at all.
            if id == "menu" {
                openPanel(chromeState.panel == .menu ? nil : .menu)
                return
            }
            // A tick on one of the tracks: `rung:colour:2`, `rung:fps:11`, … Applied on the main
            // queue -- this closure runs on the *reader* thread (`InputReader.onChromeClick`) while
            // `applyRung` writes the writer's quality and the frame gate.
            if let rung = ChromeAxis.parse(id) {
                DispatchQueue.main.async { [weak self] in
                    self?.applyRung(rung.axis, rung.step)
                }
                return
            }
            switch id {
            case "stats": openPanel(.stats)
            case "help": openPanel(.help)
            case "fps": openPanel(.settings)
            case "target": openPanel(.devices)
            default: break
            }
        case .panel:
            // The wheel over a panel is how the rows its box cannot hold are reached (#118): one
            // notch is one row, clamped at both ends. A click inside a panel is still not forwarded
            // anywhere -- it is not a picture cell and there is no control under it.
            guard wheel != 0 else { return }
            // …and the hop is the wall's, for the same reason: this closure runs on the *reader*
            // thread, while the window arithmetic reads `chromeMetrics` and the repaint writes the
            // pty, both of which the main queue owns.
            DispatchQueue.main.async { [weak self] in
                self?.scrollPanel(by: wheel < 0 ? -1 : 1)
            }
        case .picture:
            break
        }
    }

    /// One click on a tick in the menu's three tracks (issue #87), on the main queue.
    ///
    /// Colour and quality are the two halves of `--quality` and both are **hot**: `writer.quality`
    /// is rebuilt in place, so the next frame is encoded at the new ceiling and nothing restarts.
    /// They also **pin** it -- `qualityPinned` is exactly how `--quality <n>` already says "do not
    /// adapt", and a governor that took the value back within a rung interval would make the slider
    /// look broken ("a number that walks back by itself after the drag is the worst of the
    /// options"). The frame-rate track pins the same way and is held by `frameGate`.
    ///
    /// The values are clamped by construction: `ChromeAxis` owns the rungs, so a step is always one
    /// of `QualityBudget`'s documented bit depths or inside `--fps`'s 1…20.
    private func applyRung(_ axis: ChromeAxis, _ step: Int) {
        switch axis {
        case .colour:
            options.quality = QualityBudget(ChromeAxis.colourValue(step: step),
                                            eager: options.quality.eager)
            writer.quality = options.quality
            options.qualityPinned = true
            options.qualityAuto = false
            Log.write("krd: menu colour \(step) -> q\(options.quality.value) \(options.quality.label)"
                      + "\(options.quality.eager ? " eager" : "") (pinned: no governor)\n")
        case .quality:
            options.quality = QualityBudget(options.quality.value, eager: step == 1)
            writer.quality = options.quality
            options.qualityPinned = true
            options.qualityAuto = false
            Log.write("krd: menu quality \(step) -> q\(options.quality.value)"
                      + "\(options.quality.eager ? " eager" : " guarded") (pinned: no governor)\n")
        case .fps:
            let fps = ChromeAxis.fpsValue(step: step)
            options.fps = fps
            effectiveFps = fps
            frameGate = FrameGate(fps: fps)
            fpsPinned = true
            Log.write("krd: menu fps \(step) -> \(fps) fps (held by the frame gate)\n")
        }
        // Repaint now, not on the next 1 Hz tick: a slider that answers a second late reads as a
        // click that missed.
        chromeDirty = true
        drawChrome()
    }

    /// Whether the chrome owns a cell, asked from the *reader* thread (`InputReader.chromeOwns`).
    ///
    /// It reads two things and nothing else: `chromeAvailable` (fixed before the reader starts) and
    /// `chromeGeometry` (a value type the main queue replaces wholesale), plus — for the status line
    /// and the bar only — the cell grid. The panel arm is a rectangle out of the geometry
    /// (`Chrome.panelRect`), so a repaint or a resize on the main queue can never turn a panel cell
    /// into "nobody's" half way through this question.
    func chromeOwns(row: Int, col: Int) -> Bool {
        guard chromeAvailable, let geometry = chromeGeometry else { return false }
        return chrome.route(row: row, col: col, geometry: geometry) != .picture
    }

    /// One wheel notch inside an open panel, on the main queue: move the window a row and repaint
    /// now. The clamp is `Chrome.panelWindow`'s, the same call the drawer makes, so the last notch
    /// lands on the panel's last row rather than on an empty window. The box does not change size,
    /// so there is no relayout -- but the repaint cannot wait for the 1 Hz chrome tick either: a
    /// scroll that arrives up to a second late reads as a dropped notch.
    private func scrollPanel(by rows: Int) {
        guard let panel = chromeState.panel, let geometry = chromeGeometry else { return }
        let inside = geometry.panelInsideRows
        if options.debug {
            // What the notch is about to do, next to what it did with: the window the drawer
            // clamped to, the row it wants, and the offset that was stored before this notch (#118).
            let (current, total, last) = Chrome.panelWindow(panel, chromeMetrics, inside: inside,
                                                            requested: chromeState.panelOffset)
            Log.write("chrome: scroll panel=\(panel.rawValue) inside=\(inside) current=\(current) "
                      + "total=\(total) wanted=\(min(max(0, current + rows), last)) stored="
                      + "\(chromeState.panelOffset.map(String.init) ?? "nil")\n")
        }
        // A log scrolled back onto its last line is at the end again, and the stored `nil` is what
        // keeps it there: the tail is re-read every second, so a window pinned to the old last row
        // would stop showing the newest line -- in the panel whose job is to show it. `nil` means
        // "wherever this panel is read from", which for a log is the end (#118).
        chromeState.panelOffset = Chrome.panelScroll(panel, chromeMetrics, inside: inside,
                                                    requested: chromeState.panelOffset, by: rows)
        chromeDirty = true
        drawChrome()
    }

    /// The wall half of `chromeClick`, on the main queue — the same queue as the 1 s tick, so the
    /// model, the canvas and the offsets are never read and written from two threads (see the hop
    /// in `chromeClick` for the whole reason).
    /// A click on a wall cell, or — when `wheel` is non-zero — a wheel notch over it.
    ///
    /// The wheel only carries a direction here, not a distance: one notch is one display or one
    /// card, because a page per notch makes a trackpad flick skip most of the shelf.
    private func wallClick(row: Int, col: Int, wheel: Int = 0) {
        // Resync before the gesture (issue #169 review). A click hit-tests a *window id* out of the
        // cached model, and `enterFocus(.window)` hands that id to a mirror: a window that closed
        // since the last enumeration would be hit-tested dead, and the mirror would be exec'd with an
        // id the window server no longer has. The fingerprint gate is what makes that affordable on
        // the input path — an unchanged world costs one fingerprint and no enumeration, and the card
        // under the cursor is still the card on screen.
        refreshWall(force: false, trigger: .input)
        guard var state = wallState, let pane = wallPane else { return }
        let displays = wallModel.displays.count
        let windows = wallModel.windows.count
        let layout = state.layout(cols: pane.cols, rows: pane.rows,
                                  displays: displays, windows: windows,
                                  stageAspect: stageAspect(wallModel, state),
                                  cellAspect: pane.cellAspect)
        // nil = header, the divider, the gap column, a dead end of the bar, a shelf with nothing to
        // scroll: those cells belong to the wall too, so the gesture ends here.
        let action = wheel == 0 ? layout.action(row: row, col: col)
                                : layout.wheelAction(row: row, col: col, direction: wheel)
        guard let action else { return }
        state.apply(action, displays: displays, windows: windows, capacity: layout.capacity)
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
        //
        // Two things on top of plain `handleResize()` (issue #89):
        //  * it is forced, because the *pane did not move* — what moved is `chromeState.panel`, and
        //    the picture's rows follow it. The resize path's "nothing changed" shortcut is about the
        //    pane and must never swallow this call (a skipped `applyLayout` here leaves
        //    `chromeGeometry` sized for the old panel: a panel that never appears, or a picture
        //    squeezed into rows that are no longer taken).
        //  * it runs on the main queue: `chromeKey` reaches `openPanel` from the input reader's
        //    thread, and everything below this hop (`writer`, `grid`, `mirrorPane`,
        //    `restartCapture`) is main-queue state.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.applyPanel() }
            return
        }
        handleResize(force: true)
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
        diagnosticsTimer?.cancel()
        diagnosticsTimer = nil
        // The wall's 1 s tick holds the desk (and the model) alive: without this, a torn-down wall
        // keeps enumerating the window server and painting into a session that is already gone.
        stopWallTriggers()
        mock?.stop()
        mock = nil
        // The card is a 110 ms timer of its own: without this it keeps clearing rows after
        // `endSession()` has handed the terminal back, i.e. it paints over the user's shell.
        loading?.stop()
        loading = nil
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
            Self.execSelf(Self.wallArguments(at: at, exit: exitStatus, said: failureSaid,
                                             sticky: Self.stickyArguments(options)))
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

// The one place a command line krd refuses becomes a diagnostic and a status: one line on stderr
// (never stdout, which is the picture stream -- CONTRIBUTING rule 1) and the documented "usage"
// status, the same pair `krd ax` prints for the same class of mistake.
let options: Options
do {
    options = try parseArguments()
} catch {
    // A usage refusal asked for in JSON answers in the same envelope as every other failure
    // (#123, #124): one object, `--json` read from the raw argv because the parser is exactly what
    // failed. Without the flag this stays the byte-identical line it has always been.
    if AXCommand.wantsJSON(Array(CommandLine.arguments)) {
        let output = ListOutput.usageFailure("\(error)")
        FileHandle.standardOutput.write(Data(output.stdout.utf8))
        FileHandle.standardError.write(Data(output.stderr.utf8))
        exit(output.exit)
    }
    FileHandle.standardError.write(Data("krd: \(error)\n".utf8))
    exit(UsageError.status)
}
// `--cell` is a *pin*, not a fallback (issue #146): the one thing an operator knows and a terminal
// does not is its own cell - a `CSI 16t` answered in points or a pty that reports 0 for `ws_xpixel`
// is exactly why the flag exists. Set once, from the one parsed `Options`, before any path reads a
// geometry; `--replay` overrides it with the recording's own cell.
TermGeometry.pinnedCell = options.cell
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
            Desk.execSelf(Desk.wallArguments(at: at, exit: 1, said: "\(error)",
                                             sticky: Desk.stickyArguments(options)))
        }
        exit(1)
    }
}
RunLoop.main.run()
