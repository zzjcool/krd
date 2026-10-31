# Architecture

English | [简体中文](ARCHITECTURE.zh-CN.md)

krd is a single Swift executable, ~3.9 kLOC in thirteen files, no dependencies outside the system
frameworks (`ScreenCaptureKit`, `CoreGraphics`, `AppKit`, `Accelerate`, `libz`). This document
describes how the pieces fit and which invariants must not be broken.

## 1. What the design is optimising for

1. **Nothing on the local side.** No client, no port, no auth of our own. Whatever bytes leave the
   Mac must be a valid terminal escape stream, because that is the only channel available.
2. **Bandwidth proportional to change.** A static desktop must cost nothing; a one-character
   change must cost kilobytes.
3. **No visible protocol artifacts.** No blinking, no half-transmitted tiles, no cursor drift, and
   no text ever written over the picture.
4. **Recoverable from abuse.** A `kill -9` in the middle of a write must not leave the pane
   permanently broken.

## 2. Source map

```
Sources/krdcore/          <- no AppKit, no CoreGraphics, no ScreenCaptureKit (issue #21)
  Tiles.swift     TileGrid: whole-cell grid, per-tile pixel rects, extraction, dirty detection
  Render.swift    ScreenWriter: session frame, per-tile kitty escapes, KRD_DUMP, zlib
  Input.swift     InputParser: the CSI/SS3 state machine, bytes -> numeric Events
  Tile.swift      CompressedTile / PixelFormat / SyncMode / LevelPolicy (the encoding policy)

Sources/krd/              <- everything that touches the OS
  main.swift      Options parsing, lifecycle, layout application, stats, resize, selftest
  Geometry.swift  TermGeometry (CSI 16t/14t, TIOCGWINSZ) and Viewport (cells/pixels → points)
  Displays.swift  DisplayPick (which display, and why) and Debounce (one action per burst)
  Capture.swift   Capturer: SCStream setup, BGRA→RGBA, byte-identical frame dropping
  Input.swift     InputReader: tty read loop, events -> CGEvent/postToPid, click counter
  Bench.swift     synthetic corpus, staged timings, JSON, --bench-wire, --stats-json
  Replay.swift    --record / --replay of real frames (raw + manifest.jsonl)
  Log.swift       File logger (never the tty)
  AXCommand.swift `krd ax …`: preflight, app resolution, budgeted tree walk, text + JSON
  AXFormat.swift  the pure half: sanitizing, pruning, one-line rendering (covered by tests)
  AXRefs.swift    refs on disk: snapshot model, anchor matching, the $TMPDIR/krd-ax store
```

Dependency direction is a straight line: `main` → `krdcore`/`Capture`/`Input` → `Geometry`.

### 2.1 Where the byte contract lives (`krdcore`)

`krdcore` is the part of krd that decides **what bytes go on the wire**: the tile grid, the dirty
scan, the zlib call, the level policy, and the ESC/APC assembly. It deliberately has no idea that a
Mac exists — no ScreenCaptureKit, no CoreGraphics, no AppKit — so it can be compiled, tested and
fuzzed anywhere.

Everything else stays in `krd`: capture (SCK), injection (`CGEvent`), the tty (`ioctl`), the
clipboard (`NSPasteboard`) and the accessibility channel. Those are the parts that need a Mac, and
they are the parts that were already hard to test; the split makes it obvious which is which.

Two consequences worth knowing:

- **The dumps are pinned.** `Tests/krdcoreTests/GoldenDumpTests` renders two frames at a fixed
  geometry (80x24 cells of 17x33 px, 8x4 tiles) with a fixed zlib level, and compares every byte
  against `Tests/krdcoreTests/Fixtures/selftest-80x24-17x33-l6.dump`. A change to the escapes, the
  tiling or the level policy fails at the first differing byte. Regenerate on purpose with
  `KRD_UPDATE_FIXTURE=1 swift test` — **without `--filter`**: a filter can skip this bundle
  entirely (Swift 5.10 prints `Executed 0 tests` for the bundle that did not match, so
  "0 failures" does not mean the fixture was rewritten), and the update run prints
  `golden fixture written: <path> (<n> B)` when it actually regenerated it.
- **`ScreenWriter` has a `sink`.** In production it is nil and bytes go to the pty; the golden test
  sets it to collect the stream in memory. `discardOutput` (bench) is unchanged: it still drops
  bytes before they would reach the dump.

Why this is *not* written in Rust, and what would change that: [decision-rust](decision-rust.md).

The extraction changed no bytes: `--selftest --pane 80x24 --cell 17x33` with `KRD_DUMP` produced
identical dumps from the pre-refactor and post-refactor binaries (118 087 bytes,
sha256 `f18475a2596aeeab522fb3037bed0ab4c90d99d325dff4346599abaf9123aa11`), and `otool -L` is
unchanged.
Dependency direction is a straight line: `main` → `Tiles`/`Capture`/`Render`/`Input` → `Geometry`.
`krd ax` is a second root: `main` dispatches it before AppKit exists and it depends on `AXFormat`
only, so nothing in the capture or render path can be reached from it (and vice versa).
`Render` and `Input` know the terminal protocol; nothing else does. `Capture` knows ScreenCaptureKit;
nothing else does.

### 2.2 Where the input contract lives (`krdcore/Parser`)

The other half of the core (issue #45) is the CSI/SS3 state machine: `Sources/krdcore/Input.swift`
turns bytes into `Event`s that carry **plain numbers** — `key(code, mods, phase)`,
`press(key, mods, phase)`, `text(char, mods)`, `mouse(button, x, y, wheel, release, motion, mods)`,
`osc(body)`, `keyboardFlags(n)`. `Sources/krd/Input.swift` keeps what needs a Mac: the tty read loop,
the `CGEvent` injection, the cell-vs-pixel latch, the `Viewport` transform, the click counter and the
clipboard.

Why the boundary sits there: a mouse report can only be mapped to a point with the tty geometry
(`Viewport`, which needs CoreGraphics), and a kitty key report can only be turned into a character
with the IME policy. Both are decisions about *this machine*, not about the bytes.

The input trace is pinned the same way the dump is: `Tests/krdcoreTests/ParserTraceTests` feeds the
seven sequences (plain keys, kitty `CSI u` with modifiers and release, a drag, a double click, the
wheel, `Ctrl-V`, an OSC 52 reply) and compares the parser's canonical trace against
`Tests/krdcoreTests/Fixtures/input-trace.dump`. Regenerate with `KRD_UPDATE_FIXTURE=1 swift test` —
**never with `--filter`** (see §2.1).

The refactor itself was checked at the CLI level too: the same fed sequence, run through the
pre-refactor and post-refactor binaries with `--debug --dry-run --clipboard=out`, produced an
identical 45-line input trace (and each binary reproduced its own trace across runs).

## 3. Threads

| Work | Where |
|---|---|
| `RunLoop.main.run()` | main thread; `NSApplication` context lives here |
| frame callbacks (`handleFrame`) | `krd.capture` serial queue, `qos: .userInteractive` |
| stdin parsing | one detached thread (`InputReader.loop`) |
| stats timer (1 Hz) | main queue (`DispatchSource.makeTimerSource`) |
| signal sources (`SIGTERM`/`SIGHUP`/`SIGINT`) | global queue → `shutdown()` |
| `SIGWINCH` | global queue → main queue after 50 ms → `handleResize()` |

Shared state (`grid`, `viewport`, `previousFrame`, `lastDirtyCount`) is behind one `NSLock` in
`Desk`. `ScreenWriter` is deliberately lock-free: in steady state it has exactly one producer, the
capture queue. The two exceptions are the `?1003h/?1002h/?1006h/?1016h` write at input start (a direct
`write(2)` on the static helper, not through the writer) and `writer.clear()` during a resize,
which can interleave with an in-flight tile; the worst case is one extra full repaint.

## 4. Startup

```
NSApplication.shared + setActivationPolicy(.accessory)   (skipped if KRD_NO_NSAPP is set)
parseArguments()
Desk.run():
  Log.configure(--log / --debug)          → prints one "krd: logging to <path>" line on stderr
  if --selftest:                          → layout, beginSession, runSelfTest, return  (no SCK, no TCC)
  SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
  if --list:                              → print displays/windows, exit(0)
  geometry = TermGeometry.query() ?? TermGeometry.read()
  filter + fullRect                       → one window, or one display
  configureSource(rect)                   → zoom focus: --zoom-at, else the pointer, else the centre
  applyLayout(geometry)                   → Viewport.crop(full, zoom, focus) → TileGrid + Viewport
  writer.beginSession()                   → heal, alt screen, home, hide cursor
  installSignalCleanup(); installResizeHandler(); installDisplayChangeHandler()
  if --debug startDiagnostics()
  capturer.start(filter:sourceRect:width:height:fps:)  (width/height = layout, sourceRect = the crop)
  if !--no-input: InputReader.start()     → raw tty, ?1003h ?1002h ?1006h ?1016h
  while true { sleep 1 s }
```

`NSApplication` exists because ScreenCaptureKit on the tested macOS build delivers exactly one
frame without an AppKit context and a full stream with it (`KRD_NO_NSAPP=1` reproduces the
failure). `.accessory` keeps krd out of the Dock and the app switcher.

### Display-set changes (issue #19)

A session is started against one display, so plugging, unplugging, mirroring, rotating or
resizing a display has to rebuild the stream instead of painting a stale geometry. One function
decides what to capture -- `makeCaptureTarget()`, used by startup *and* by every change -- and one
path restarts the stream (`restartCapture`), shared with the terminal resize and the zoom follow,
so two of them can never start a stream at the same time.

Two things had to be measured before this worked, and both are why the code looks the way it does:

1. **No AppKit notification.** `NSApplication.didChangeScreenParametersNotification` is posted by
   NSApp's run loop, and krd never runs one (the main loop is async: `while true { await sleep }`).
   A probe that calls `NSApp.run()` gets three notifications per resolution change; krd got none,
   with `queue: .main` *or* `queue: nil`.
2. **No CoreGraphics callback either, over ssh.** `CGDisplayRegisterReconfigurationCallback` is
   registered anyway (it is the fast path for a GUI-launched krd), but it is not delivered to a
   process outside the Aqua session -- measured: the same probe got zero callbacks from `ssh`.

So the backstop is a **fingerprint poll at 2 Hz**: `CGGetActiveDisplayList` plus `CGDisplayBounds`,
sorted by display id (`DisplaySet.fingerprint`, so a reordered list is not a change). Measured end
to end on the VM: resolution change -> one restart line 0.70 s later. Every trigger (poll, callback)
only *notes* the event; a 500 ms trailing debounce (`Debounce`) collapses the burst -- `NSApp.run()`
fires 3 notifications for one lid close, and the poll can see a change twice while it settles.

### Stream liveness

`SCStream` can stop without anyone asking: `didStopWithError` with `-3805` ("application connection
being interrupted") after a few restarts, or — worse — no callback at all, frames just stop. Both
were found by the 30-minute soak ([TESTING §11](TESTING.md#11-soak-thirty-minutes-with-every-feature-on)).

- `didStopWithError` restarts the stream, at most five times with 1-2-4-8-8 s backoff, one log line
  per attempt.
- **A frame we asked for is owed.** After a pan (`updateSource`) or a restart, a watchdog checks
  that a frame arrives within 3 s (the probe measured p50 42 ms) and restarts the stream if not. That
  is precise, because krd knows what it asked for.
- **Silence on its own means nothing** and this is measured, not assumed: on a still desktop
  ScreenCaptureKit sends *no* frames at all (0 frames in a 1 s window, and 56 s gaps between pointer
  sweeps in a 10-minute soak). An earlier version of this watchdog took "no frames for 15 s" as
  death and restarted a healthy stream three times in five minutes. The long-silence rule is
  therefore opt-in: `KRD_STREAM_WATCHDOG=<seconds>`, default `0` (off).
- `Capturer.stop()` gives up after 2 s. `stopCapture()` on an already-dead stream never calls back on
  macOS 26, and `restartCapture` awaits it before clearing "a restart is in flight", so a single hung
  stop would wedge every later restart. The retry budget is earned back by *frames arriving*, not by
  a restart returning without throwing.

Which display is chosen is a pure function (`DisplayPick.choose`, covered by `DisplayPickTests`):
`--display <i>` wins while that index exists; otherwise the display the session is already on wins
(the pointer wandering onto another screen is *not* a reason to move); only if it is gone does the
pointer's display take over, and that is logged (`krd: capturing display 2 is gone; following the
pointer to display 1`). A restart that keeps failing is reported once per session, and the last
frame stays on screen.

## 5. Frame path

```
SCStream callback (capture queue)
  └─ Capturer.stream(_:didOutputSampleBuffer:of:)
       ├─ sample attachments: status=complete|idle|blank, …  → idle vs bad vs frame
       ├─ CVPixelBuffer → vImagePermuteChannels_ARGB8888(BGRA → RGBA)
       └─ every frame is handed on (the swap above is what keeps that copy-free)
          └─ Desk.handleFrame(pixels:width:height:)          (same queue)
               ├─ size != layout ? log once, drop
               ├─ scan = TileGrid.diff(previousFrame, pixels, grid)
               │          (one pass: "identical to the last frame" *and* the dirty tiles;
               │           or all tiles when --full-frame, or when the frame size changed)
               ├─ scan.identical → count it as skipped, emit nothing at all, return  ← zero cost
               ├─ writer.beginFrame()   (reset counters, open the frame's ?2026h block)
               ├─ dirty.isEmpty → writer.nudge(), writer.endFrame() and return
               │          (unreachable while `diff` reports the tiles honestly: a frame that is not
               │           identical has at least one dirty tile)
               ├─ concurrentPerform over the dirty tiles (compression is stateless):
               │     extract(rect) → zlib(compress2, level = LevelPolicy[tile]) → CompressedTile
               └─ then, serially, per tile: writer.emit(tile)  (escape assembly only)
                    CUP → base64 chunks → a=t transmit → a=p place  … writer.endFrame() (?2026l + flush)
```

There is **one** dedupe stage, not two (issue #95). `TileGrid.diff` scans the frame once — one
`memcmp` per row, then the tile columns of a row that differs — and answers both questions from
that pass: "is this frame identical to the last one" (the truly static case, which emits nothing at
all) and "which tiles changed" (so a small change costs a small update). It used to be two reads of
the same 10 MB, the first an `Array` equality (element-wise for `UInt8`, 4.1 ms at 2329x1452) and
the second a per-tile `memcmp`; the two answers could only agree by accident. The scan is 0.22 ms
per delivered frame, including the ones that emit nothing.

A frame whose dimensions differ from the current layout is dropped and logged once
(`krd: dropping frames: got WxH, layout expects WxH`) — that message means a resize raced the
stream, not a capture bug.

## 6. Layout math

`TileGrid.make(geometry:aspect:tileCols:tileRows:)`:

```
cols = geometry.cols
rows = round(cols * cellW / aspect / cellH)        // aspect = sourceRect.width / height
if rows > geometry.rows { rows = geometry.rows
                          cols = round(rows * cellH * aspect / cellW) }
cols = min(max(1, cols), geometry.cols)            // the picture's box: the pane and the aspect,
rows = min(max(1, rows), geometry.rows)            //   never the tile size (issue #143)
pixelW = max(2, round(cols * cellW * scale))       // the SCStream output size
pixelH = max(2, round(rows * cellH * scale))
```

The box is a function of the pane, the cell and the source's aspect - **`--tile` does not enter it**
(issue #143). It used to be clamped up to at least one whole tile *before* the fit, which for a pane
shorter or narrower than the tile (or a picture smaller than one tile) made the box **bigger than
the pane**: the fit then came out larger than the pane can hold, the clamp after it could only trim
the *cells*, and the picture kept a frame that was not its aspect. Measured on a 40x15 pane with a
1440x2560 source: `--tile 32x16` drew 18 cells where the aspect says 17, `--tile 24x20` stretched the
picture 36 % wide, and `--tile 8x4` on a 40x3 pane (no flag at all) 48 %. A box smaller than one tile
needs nothing special - `rect` sizes the single tile that is there to the cells that exist. Two
invariants follow - `boxCols <= paneCols` and `boxRows <= paneRows` - and the tile floor violated
both; the mouse mapping and the tile grid take them for granted.

`TileGrid.rect(tx, ty)` returns a tile's pixel rect **and** its placement footprint:

```
cx = min(tileCols, paneCols - tx*tileCols)         // cells in this tile (edge tiles are smaller)
cy = min(tileRows, paneRows - ty*tileRows)
x0 = round(tx*tileCols * cellW * scale);  x1 = round((tx*tileCols + cx) * cellW * scale)
y0 = round(ty*tileRows * cellH * scale);  y1 = round((ty*tileRows + cy) * cellH * scale)
→ (x0, y0, max(1,x1-x0), max(1,y1-y0), col: originCol+tx*tileCols, row: originRow+ty*tileRows,
   cols: cx, rows: cy)
```

`originCol`/`originRow` (`make(area:)`) are `1, 1` unless the picture is smaller than the space it was
given: then the block is **centred** in that area and every placement moves with it (design §6.7). The
same two numbers go into `Viewport`, so a click in the margin is not forwarded and a click on the
picture maps to the right source point.

Rounding happens only at the rect edges, so tiles tile the picture with no gaps and no overlap;
`cols`/`rows` are always whole cells, which is why no placement ever needs a sub-cell offset and
the terminal never resamples.

Those edges are `cells x cell` and nothing else, so a tile's pixel rect **is** that tile's own cell
box (`x1 - x0` at its own boundaries, never a proportion of the frame). That is the half a terminal
cannot forgive: one that draws an image pixel per device pixel has no way to stretch the difference,
so a tile image a pixel short of its box shows as a column of background at that tile's edge (issue
#86). `scale` shrinks the rects and the frame by the same factor - a transport that cannot stretch
that back asks `make(fillsCells:)` for the cell box itself. A placeholder grid is such a transport,
so `--scale < 1` never shortens a placeholder frame.

### Zoom: showing less at full density

Fitting the whole display into a small pane is a *choice*, not a law: `--zoom <f>` shows `1/f` of
the source and maps the pane onto that crop, so a 60x24 pane gets 1.35 px per point at `--zoom 2`
instead of 0.67 (measured on a 1512x982 pt display, 1020x792 px pane — see the `--debug` line).

```
fullRect   = display bounds, or the window frame with --window
focus      = --zoom-at x,y  |  the pointer if it is inside fullRect  |  the centre
sourceRect = Viewport.crop(full: fullRect, scale: zoom, focus: focus)      // clamped to fullRect
pixelW/H   = the crop's points x min(fit, 1) x --scale   // the *source* shrinks, so the output does
```

Three consequences worth knowing:

1. **The crop happens on the capture side** (`SCStreamConfiguration.sourceRect`, macOS 14+), so a
   zoomed frame copies fewer pixels than a fitted one. Nothing is upscaled on the CPU.
2. **Interaction improves, and no input code changed.** `Viewport.point(forCell:)` and
   `point(forPixel:)` already normalise against `sourceRect`, so a click maps into the crop as soon
   as the crop is right: at `--zoom 2` a cell covers half the desktop points.
3. **The output shrinks with the crop.** `pixelW`/`pixelH` are bounded by the *crop's* points, not by
   the window's and not by the pane's cells: at `--zoom 2` a 1024x678 pt window captures 512x339 pt,
   so the stream is 512x339 px and the terminal stretches that into the pane. Handing the layout the
   full frame's size instead asks ScreenCaptureKit for 1024x678 px out of a 512x339 pt crop — a 2x
   upscale at four times the bytes for no extra detail (fixed in #73, visible in `--debug` as
   `source 512x339 pt -> 512x339 px`). What the terminal does with those pixels is still its own
   choice, which is why the picture keeps filling the pane either way.

`--zoom-follow` pans the crop when the pointer enters the outer 15 % band of the picture, and only
far enough to put it back on that edge (pan, not chase). A pan calls `SCStream.updateConfiguration`
with the new `sourceRect` (`Capturer.updateSource`) instead of stopping and starting the stream: the
picture keeps coming, no re-negotiation, and the stop/start path stays off the hot path entirely.
It still clears `previousFrame` (the new crop is a new picture, so one full repaint), and the first
frame after an update can still be the *old* crop because it was already in flight — measured in
`probe/zoom_update_probe.swift`: it settles within one or two frames, p50 42 ms end to end, and a
pan must count as stream activity so the frame watchdog does not read it as silence.
A pan that asks for the rect the stream already has is skipped (`Capturer.Update.unchanged`): the
crop is clamped at the display edge, so a pointer parked in a corner would otherwise send the same
configuration four times a second, and an unchanged configuration produces no frame — which a caller
waiting for one reads as a dead stream.
`KRD_ZOOM_GLOBAL_RECT=1` exists because a display filter on a secondary display may want global
points instead of filter-relative ones. Startup (`--zoom` / `--zoom-at`), a terminal resize and a
display-set change still restart the stream: their filter or layout genuinely changes.


Worked example — the configuration all the measurements use:

```
display     1920 × 1200 pt          aspect 1.6
pane        137 × 73 cells          cell 17 × 33 px
layout      cols 137, rows round(137*17/1.6/33) = 44     → picture 137 × 44 cells
pixels      round(137*17) × round(44*33) = 2329 × 1452 px
tiles       9 × 6 = 54 of 16 × 8 cells   (one tile = 272 × 264 px = 287 KB raw RGBA)
edge tiles  tile (8,5): cols 129..137 (9 cells), rows 41..44 (4 cells) → 153 × 132 px
```

`--tile c x r` only changes the tiling, never the picture: the same 2329x1452 px frame is cut
differently, and the box and the fit it came from do not move with the tile size (#143). Smaller
tiles mean more escapes per update (fixed overhead per tile: ~120 bytes of
control plus one flush) and smaller worst-case latency per change; bigger tiles mean fewer, larger
updates.

## 7. Rendering invariants

These are not style choices; each one fixed a specific failure. Byte-level detail in
[PROTOCOL.md](PROTOCOL.md).

1. **One image id and one placement id per tile, fixed for the process lifetime** (`100+index`,
   `1000+index`). A frame overwrites the previous placement of the same tile. Nothing is ever
   deleted per tile, so no terminal can implement `a=d` badly enough to hurt us.
2. **Never write text to the tty.** `Log` goes to a file. One line of diagnostics moves the cursor;
   a line at the bottom scrolls the grid, and every tile is positioned by absolute coordinates, so
   a scroll shreds the picture. (`--debug` writes a file for exactly this reason.)
3. **`C=1` on every placement** — the cursor must not move when an image is placed; otherwise the
   terminal advances it into (and past) the picture and later positions drift or scroll.
4. **One `?2026h … ?2026l` block per tile** (`KRD_NOSYNC=1` drops it), so a terminal can never
   repaint a half-transmitted tile.
5. **`nudge()`** (`ESC[?25l`) is emitted when a captured frame produced no dirty tiles: some
   terminals only commit a placement on the next output cycle, and this keeps the pipe moving
   while re-asserting the hidden cursor.
6. **Heal on entry.** `beginSession()` starts with `ESC \` (closes a dangling APC left by a killed
   predecessor, which would otherwise swallow every later byte) + `?2026l` (closes a dangling
   sync block) + the four mouse resets `?1016l ?1006l ?1002l ?1003l` (`ScreenWriter.mouseReset`,
   the enable list of PROTOCOL §7 reversed) + `ESC[0m` + `?25h`, then switches to the alternate
   screen.
7. **Explicit teardown.** `endSession()`: `ESC \` + `?2026l`, delete all placements
   (`a=d,d=a`) + `2J`, then the same `mouseReset` + `?25h ?1049l`.

## 8. Resize and shutdown

`SIGWINCH` → 50 ms delay (terminals update `winsize` asynchronously) → `handleResize()`:
re-measure with `TermGeometry.read()`, rebuild the layout, `writer.clear()`, stop and restart the
stream at the new pixel size. Note that this path uses `read()` only (no CSI query), so on a pty
that reports no pixel size it falls back to `--cell`.

Shutdown (`SIGTERM`, `SIGHUP`, `SIGINT`, Ctrl-\\, or a fatal error in `run()`) is idempotent
(`cleanedUp` flag): restore termios, `endSession()`, `exit(0)`. It does not run on `kill -9`,
which is why §7.6 exists.

## 9. Diagnostics wiring

| Switch | Code path |
|---|---|
| `--debug` | `Log.configure` + `startDiagnostics()` + `reader.trace` + geometry/accessibility lines |
| `--log <path>` | `Log.configure` only (no stats, no input trace) |
| `--dry-run` | `InputReader(dryRun:)`: parse and log, never call `CGEvent.post` |
| `--zoom <f>` | `applyLayout` → `Viewport.crop`; `Capturer.start(sourceRect:)` crops on the capture side |
| `--zoom-at <x,y>` | `configureSource`: the focus the crop is centred on, in global points |
| `--zoom-follow` | `followPointerIfNeeded`: pans the crop at the 15 % band, then `Capturer.updateSource` (`updateConfiguration`, no restart) |
| `--selftest` | `runSelfTest(layout:)`: synthetic frames (in the active `--format`) through the real `handleFrame`/`emit` |
| `--bench` | `Bench.runStages`: dedupe → dirty → extract → zlib → base64 → escapes, staged timings, `--json` |
| `--bench-wire` | `Bench.runWire`: one case at `--fps` through the real `handleFrame`, per-frame JSON on stderr |
| `--record` | `FrameRecorder` in `handleFrame`: writes raw frames + a manifest header (layout included) |
| `--replay` | `runReplay`: recorded frames through the real pipeline, at the recorded pace |
| `--stats-json` | `StatsJSONWriter` in `startDiagnostics`: one NDJSON line per second, from the panel's own `ChromeMetrics` |
| `KRD_DUMP` | `ScreenWriter.flush` tees every flushed buffer to a file |
| `KRD_Q` | the `q=` field of every escape (default `2` = silent) |
| `KRD_FORMAT` | `rgb` (default, `f=24`) or `rgba` (`f=32`) |
| `KRD_SYNC` | `tile` restores one synchronized block per tile; `KRD_NOSYNC=1` disables them |
| `KRD_REAP` | repaint everything after n frames (0 = off, the default) |
| `KRD_BENCH_BUDGET_SCALE` | `bench/bench.py` only (not read by krd): multiplies `ms.*` / `write_ms.*` budgets by the machine's speed factor, never bytes ([BENCHMARK](BENCHMARK.md) §6) |
| `--mock` | `MockDesktop` instead of `Capturer`: synthetic frames through the real `handleFrame`, no permission |
| `--mock-size` | size of the generated desktop, default `1920x1200` |
| `--dev` | `Chrome` + `startChrome()`: the TUI layer, one row reserved and a panel on demand |
| `--dev-panel` | `ChromeState.panel` set before the first layout, for screenshots and pty tests |
| `--no-chrome` | forces the layer off, so `--dev` can live in a wrapper script |
| `krd` (no flags) | `WallSource` + `WallCanvas` + `WallPictures` + `runWall()`: the landing screen, one display on stage and three recent windows below, as pictures. A click on one turns this process into `krd --window <id>` (`Desk.handOver`, `execv` — a second live process of one executable is not allowed to stream, see design §12 P3b) and `Ctrl-\` in that mirror `exec`s the wall back with its offsets in argv (`--wall-at`, `--said`). `--mirror` selects the old whole-display path, `--window <q>` implies it |
| `--symbols <m>` | `WallSymbols`: `emoji` (default) or `ascii` glyphs for the wall |

One 1 Hz tick samples everything (`Desk.startDiagnostics()`), and three renderers read that one
snapshot: the `--debug` line, the `--dev` panel and `--stats-json`. One tick rather than one per
renderer because rates are *deltas over an interval* — two timers over the same counters halve the
interval and print half the rate (issue #52).

```
stats: <tiles/s> tiles/s  <dirty> dirty  <KB> KB  <MB/s>  ms[cap=<ms> pipe=<ms>(p99 <ms>) zlib=<ms> write=<ms> max=<ms> over5=<n>]  <WxH> px <CxR> cells  delivered=<n>/s skipped=<n>/s idle=<n>/s bad=<n>  input=<ms> late=<n>/<n>
```

`tiles/s` is the delta of `framesEmitted` (tiles, not frames), `KB` is the last frame's compressed
payload, `MB/s` is bytes written in the last second, `delivered`/`skipped`/`idle` are per second and
come from ScreenCaptureKit's own frames (`idle` = no pixel buffer and the status says so, `bad` =
it claims `complete` but has no pixels), `write max`/`over5` are the worst `write(2)` block of the
second and how many frames exceeded 5 ms, and `late` counts frames the loop declined because
`--quality auto` had lowered the target rate.

`cap` and `pipe` are the split that answers "was it the capture or the write":

- `cap = ScreenCaptureKit callback − PTS`: how old the frame's *content* already was when it reached
  us, measured in host time (`CMSampleBufferGetPresentationTimeStamp` and `benchNowMs()` share a
  clock base). Measured on real frames it is usually ~0–10 ms — the compositor is prompt — and it
  grows only when ScreenCaptureKit coalesces updates. It is slightly *negative* for frames presented
  ahead of the callback (−10…+10 ms at 20 fps), which clamps to 0: those are timely frames, not
  unmeasured ones.
- `pipe = callback → last byte written`: everything we do with the frame.
- `e2e = cap + pipe` is the number the status bar prints as `frame` — or as `pipe` when `cap` is `—`,
  since with no capture half to add the sum *is* the pipe half.

`cap` is `—` (and `-1` in JSON) when there is no timestamp to measure against: `--mock` and
`--replay` have none, and a zero there would read as "a very fast capture" rather than "not
measured".

`--stats-json <path>` writes the same numbers as one NDJSON object per second
(`bench/soak-report.py` reads them); the writer takes the panel's `ChromeMetrics` struct, so the
two cannot drift.

**The round trip (`CSI 5n`).** `write(2)` blocking only fires after sshd's userspace buffer is full,
so a slow link stays invisible until seconds of picture have piled up. The probe writes 4 bytes
(`RTTProbe`, `Sources/krdcore/RTTProbe.swift`) every couple of seconds; a VT terminal answers
`CSI 0n`, `InputParser` emits `.statusReport`, and `InputReader` timestamps the arrival — so the round
trip is measured to the input thread's clock rather than to the 1 Hz tick. The answer queues behind
the picture, which is the point: the number includes the backlog a person feels.

Both signals feed the quality governor, and they are not interchangeable: `writeMs` says "our writes
are blocking now" (free, per frame, late), the round trip says "the far end is this far behind"
(4 bytes per probe, includes queueing, early). Downgrade needs either; upgrade needs both quiet. A
terminal that never answers switches the probe off after three misses and the governor keeps working
on write latency alone — the numbers stay `—`, never `0`. `KRD_RTT_BUDGET_MS` (default 250) is the
threshold, `KRD_NO_RTT=1` disables the probe.

**The report bundle.** `kill -USR2 <krd>` writes `$TMPDIR/krd-report.txt`: a one-line verdict naming
the bigger half of the delay, the current numbers, the last 300 samples of every series (cap, pipe,
zlib, write, input), the active `KRD_*` switches, the geometry and the last 200 log lines. The point
is that a session which is too slow to read is still diagnosable from another terminal — the whole
workflow is `ssh host pkill -USR2 krd` and then read the file it names in the log. `kill -USR1`
cycles the panel, for the same reason.

### The TUI layer (`--dev`)

`Chrome.swift` is a separate layer over the picture: a status line on the last reserved row and
five panels (stats, devices, settings, log, help). It is off unless `--dev`, and with it off the
process behaves byte for byte as before — no timer, no text write, the geometry untouched.

The hard part is not drawing; it is coexisting with the placement layer:

1. **A placement lands at the cursor.** Every tile escape moves the cursor first
   (`ScreenWriter.emit`), precisely so that text written anywhere else cannot drag the picture
   along. Chrome text moves the cursor too; the explicit move is what makes that harmless.
2. **Text never goes above the picture.** `ChromeGeometry.imageRows` comes from `TileGrid`, so
   the chrome cannot guess wrong.
3. **No newline, ever** — and never the final cell of the final row, which arms the pending-wrap
   and scrolls the grid on the next byte. Every write is `ESC[row;colH` + bytes.
4. **Chrome bytes are serialized against the tile flush** (`ScreenWriter.writeLock`), so a UI tick
   cannot split a base64 payload.
5. **A panel's rows come out of the picture**, before the aspect fit: the layout re-fits, the
   capture restarts at the new size, exactly like a resize. A panel is never floated over tiles.

The status line is the only thing that runs at a fixed rate (1 Hz), and it costs text bytes:
~60 B/s against the 20–50 KB/s the picture needs. That is why this is a text layer and not an
in-frame overlay.

## 10. Extension points

- **Clipboard** — `InputReader` (OSC 52 in) and `ScreenWriter` (OSC 52 out); nothing in the render
  path assumes the stream is image-only apart from the "no text" rule.
- **Another encoder** — `ScreenWriter.compress`/`emit` is the only place that knows the payload format;
  `--full-frame` already demonstrates a second path through the same session frame.

## 11. Known rough edges

Documented so the next reader does not chase ghosts:

- The two capture buffers remove the per-frame copy only while frames are being *emitted*.
  `Capturer.previous` now advances on every callback, but a static screen still keeps
  `Desk.previousFrame` pinned to a buffer that is about to be rewritten, so the next emitted frame
  pays one 13.5 MB copy before the rotation is in phase again.
- `TileGrid.bpp` is taken from the writer at layout time; a `--format` change mid-session (there is
  none today) would invalidate the grid and the `previousFrame` it was measured against.
- `LevelPolicy` starts every tile at level 5 and needs one frame per tile to learn; after a resize
  all tiles relearn, which shows up as a slightly larger first frame.
- `Capturer.format` has to be set before `start()`; it is a plain `var`, not a constructor argument,
  because `Desk` builds the writer first.
- The `KRD_QUADRANTS` / `KRD_DELTEST` / `KRD_GRID` self-test switches still describe terminals that
  ignore `a=d`. They are kept as calibration tools even though the live path never deletes.
