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
Sources/krd/
  main.swift      Options parsing, lifecycle, layout application, stats, resize, selftest
  Geometry.swift  TermGeometry (CSI 16t/14t, TIOCGWINSZ) and Viewport (cells/pixels → points)
  Tiles.swift     TileGrid: whole-cell grid, per-tile pixel rects, extraction, dirty detection
  Capture.swift   Capturer: SCStream setup, BGRA→RGBA, byte-identical frame dropping
  Render.swift    ScreenWriter: session frame, per-tile kitty escapes, KRD_DUMP
  Tile.swift      CompressedTile / PixelFormat / SyncMode / LevelPolicy (the encoding policy)
  Input.swift     InputReader: raw tty, SGR/SGR-Pixels mouse, keys → CGEvent
  Bench.swift     synthetic corpus, staged timings, JSON, --bench-wire, --stats-json
  Replay.swift    --record / --replay of real frames (raw + manifest.jsonl)
  Log.swift       File logger (never the tty)
  AXCommand.swift `krd ax …`: preflight, app resolution, budgeted tree walk, text + JSON
  AXFormat.swift  the pure half: sanitizing, pruning, one-line rendering (covered by tests)
```

Dependency direction is a straight line: `main` → `Tiles`/`Capture`/`Render`/`Input` → `Geometry`.
`krd ax` is a second root: `main` dispatches it before AppKit exists and it depends on `AXFormat`
only, so nothing in the capture or render path can be reached from it (and vice versa).
`Render` and `Input` know the terminal protocol; nothing else does. `Capture` knows ScreenCaptureKit;
nothing else does.

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
  installSignalCleanup(); installResizeHandler(); if --debug startStats()
  capturer.start(filter:sourceRect:width:height:fps:)  (width/height = layout, sourceRect = the crop)
  if !--no-input: InputReader.start()     → raw tty, ?1003h ?1002h ?1006h ?1016h
  while true { sleep 1 s }
```

`NSApplication` exists because ScreenCaptureKit on the tested macOS build delivers exactly one
frame without an AppKit context and a full stream with it (`KRD_NO_NSAPP=1` reproduces the
failure). `.accessory` keeps krd out of the Dock and the app switcher.

## 5. Frame path

```
SCStream callback (capture queue)
  └─ Capturer.stream(_:didOutputSampleBuffer:of:)
       ├─ sample attachments: status=complete|idle|blank, …  → idle vs bad vs frame
       ├─ CVPixelBuffer → vImagePermuteChannels_ARGB8888(BGRA → RGBA)
       └─ previous == rgba ? drop : keep  ← zero cost for a static desktop
          └─ Desk.handleFrame(pixels:width:height:)          (same queue)
               ├─ size != layout ? log once, drop
               ├─ dirty = TileGrid.dirty(previousFrame, pixels, grid)
               │          (or all tiles when --full-frame, or when the frame size changed)
               ├─ writer.beginFrame()   (reset counters, open the frame's ?2026h block)
               ├─ dirty.isEmpty → writer.nudge(), writer.endFrame() and return
               ├─ concurrentPerform over the dirty tiles (compression is stateless):
               │     extract(rect) → zlib(compress2, level = LevelPolicy[tile]) → CompressedTile
               └─ then, serially, per tile: writer.emit(tile)  (escape assembly only)
                    CUP → base64 chunks → a=t transmit → a=p place  … writer.endFrame() (?2026l + flush)
```

Two independent dedupe stages exist for a reason: the capture stage compares whole frames
(`previous == rgba`, an Array equality — one memcmp under the hood) and kills the truly static
case; the tile stage compares per tile, so a small change costs a small update. The capture stage
also means `dirty.isEmpty` is rare, which is why `nudge()` (see §7) is not a per-frame cost.

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
cols = clamp(cols, tileCols, geometry.cols)        // never smaller than one tile
rows = clamp(rows, tileRows, geometry.rows)
pixelW = max(2, round(cols * cellW))               // the SCStream output size
pixelH = max(2, round(rows * cellH))
```

`TileGrid.rect(tx, ty)` returns a tile's pixel rect **and** its placement footprint:

```
cx = min(tileCols, paneCols - tx*tileCols)         // cells in this tile (edge tiles are smaller)
cy = min(tileRows, paneRows - ty*tileRows)
x0 = round(tx*tileCols * cellW);  x1 = round((tx*tileCols + cx) * cellW)
y0 = round(ty*tileRows * cellH);  y1 = round((ty*tileRows + cy) * cellH)
→ (x0, y0, max(1,x1-x0), max(1,y1-y0), col: tx*tileCols+1, row: ty*tileRows+1, cols: cx, rows: cy)
```

Rounding happens only at the rect edges, so tiles tile the picture with no gaps and no overlap;
`cols`/`rows` are always whole cells, which is why no placement ever needs a sub-cell offset and
the terminal never resamples.

### Zoom: showing less at full density

Fitting the whole display into a small pane is a *choice*, not a law: `--zoom <f>` shows `1/f` of
the source and maps the pane onto that crop, so a 60x24 pane gets 1.35 px per point at `--zoom 2`
instead of 0.67 (measured on a 1512x982 pt display, 1020x792 px pane — see the `--debug` line).

```
fullRect   = display bounds, or the window frame with --window
focus      = --zoom-at x,y  |  the pointer if it is inside fullRect  |  the centre
sourceRect = Viewport.crop(full: fullRect, scale: zoom, focus: focus)      // clamped to fullRect
pixelW/H   = the pane's pixels, unchanged        // the *source* shrinks, the output does not
```

Three consequences worth knowing:

1. **The crop happens on the capture side** (`SCStreamConfiguration.sourceRect`, macOS 14+), so a
   zoomed frame copies fewer pixels than a fitted one. Nothing is upscaled on the CPU.
2. **Interaction improves, and no input code changed.** `Viewport.point(forCell:)` and
   `point(forPixel:)` already normalise against `sourceRect`, so a click maps into the crop as soon
   as the crop is right: at `--zoom 2` a cell covers half the desktop points.
3. **The output size stays the pane size.** "Zoom halves the capture dimensions" is about the
   source rect in points; `pixelW`/`pixelH` are what the terminal can display and do not move. Above
   ~2.7x on a Retina display the pane has more pixels than the crop has points, so the picture is
   slightly upscaled — full density is reached at `displayPixels / panePixels`, not at infinity.

`--zoom-follow` pans the crop when the pointer enters the outer 15 % band of the picture, and only
far enough to put it back on that edge (pan, not chase). Panning restarts the stream, because the
crop is a capture-side setting: it clears `previousFrame` (one full repaint) and takes the
`capturer.stop()`/`start()` round trip. That is the price of not paying for the full frame every
frame; `KRD_ZOOM_GLOBAL_RECT=1` exists because a display filter on a secondary display may want
global points instead of filter-relative ones.


Worked example — the configuration all the measurements use:

```
display     1920 × 1200 pt          aspect 1.6
pane        137 × 73 cells          cell 17 × 33 px
layout      cols 137, rows round(137*17/1.6/33) = 44     → picture 137 × 44 cells
pixels      round(137*17) × round(44*33) = 2329 × 1452 px
tiles       9 × 6 = 54 of 16 × 8 cells   (one tile = 272 × 264 px = 287 KB raw RGBA)
edge tiles  tile (8,5): cols 129..137 (9 cells), rows 41..44 (4 cells) → 153 × 132 px
```

`--tile c x r` only changes the tiling, never the picture: the same 2329×1452 px frame is cut
differently. Smaller tiles mean more escapes per update (fixed overhead per tile: ~120 bytes of
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
   sync block) + `?1003l ?1002l ?1006l` + `ESC[0m` + `?25h`, then switches to the alternate screen.
7. **Explicit teardown.** `endSession()`: `ESC \` + `?2026l`, delete all placements
   (`a=d,d=a`) + `2J`, then `?1003l ?1002l ?1006l ?25h ?1049l`.

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
| `--debug` | `Log.configure` + `startStats()` + `reader.trace` + geometry/accessibility lines |
| `--log <path>` | `Log.configure` only (no stats, no input trace) |
| `--dry-run` | `InputReader(dryRun:)`: parse and log, never call `CGEvent.post` |
| `--zoom <f>` | `applyLayout` → `Viewport.crop`; `Capturer.start(sourceRect:)` crops on the capture side |
| `--zoom-at <x,y>` | `configureSource`: the focus the crop is centred on, in global points |
| `--zoom-follow` | `followPointerIfNeeded`: pans the crop at the 15 % band, then restarts the stream |
| `--selftest` | `runSelfTest(layout:)`: synthetic frames (in the active `--format`) through the real `handleFrame`/`emit` |
| `--bench` | `Bench.runStages`: dedupe → dirty → extract → zlib → base64 → escapes, staged timings, `--json` |
| `--bench-wire` | `Bench.runWire`: one case at `--fps` through the real `handleFrame`, per-frame JSON on stderr |
| `--record` | `FrameRecorder` in `handleFrame`: writes raw frames + a manifest header (layout included) |
| `--replay` | `runReplay`: recorded frames through the real pipeline, at the recorded pace |
| `--stats-json` | `StatsJSONWriter` in `startStats`: one NDJSON line per second |
| `KRD_DUMP` | `ScreenWriter.flush` tees every flushed buffer to a file |
| `KRD_Q` | the `q=` field of every escape (default `2` = silent) |
| `KRD_FORMAT` | `rgb` (default, `f=24`) or `rgba` (`f=32`) |
| `KRD_SYNC` | `tile` restores one synchronized block per tile; `KRD_NOSYNC=1` disables them |
| `KRD_REAP` | repaint everything after n frames (0 = off, the default) |
| `KRD_BENCH_BUDGET_SCALE` | `bench/bench.py` only (not read by krd): multiplies `ms.*` / `write_ms.*` budgets by the machine's speed factor, never bytes ([BENCHMARK](BENCHMARK.md) §6) |

The 1 Hz stats line is one `String(format:)` in `Desk.startStats()`:

```
stats: <tiles/s> tiles/s  <dirty> dirty  <KB> KB  <MB/s>  ms[zlib=<ms> write=<ms> max=<ms> over5=<n>]  <WxH> px <CxR> cells  cap=<d>/<s>/<c> idle=<n> bad=<n> pipe=<ms>
```

`tiles/s` is the delta of `framesEmitted` (tiles, not frames), `KB` is the last frame's compressed
payload, `MB/s` is bytes written in the last second, `cap` is ScreenCaptureKit's
delivered/skipped/callback counts, `idle`/`bad` are frames without a pixel buffer split by the
status from the sample attachments (`idle` = the status says so or is absent, `bad` = it claims
`complete`), `write max`/`over5` are the worst `write(2)` block of the second and how many
frames exceeded 5 ms, and `pipe` is capture callback → last byte out. `--stats-json <path>` writes
the same numbers as one NDJSON object per second (`bench/soak-report.py` reads them).

## 10. Extension points

- **Clipboard** — `InputReader` (OSC 52 in) and `ScreenWriter` (OSC 52 out); nothing in the render
  path assumes the stream is image-only apart from the "no text" rule.
- **Another encoder** — `ScreenWriter.compress`/`emit` is the only place that knows the payload format;
  `--full-frame` already demonstrates a second path through the same session frame.

## 11. Known rough edges

Documented so the next reader does not chase ghosts:

- The two capture buffers remove the per-frame copy only while frames are being *emitted*. A frame
  dropped by the whole-frame dedupe leaves `previous` pointing at the buffer that is about to be
  rewritten, so the next emitted frame pays one 13.5 MB copy before the rotation is in phase again.
- `TileGrid.bpp` is taken from the writer at layout time; a `--format` change mid-session (there is
  none today) would invalidate the grid and the `previousFrame` it was measured against.
- `LevelPolicy` starts every tile at level 5 and needs one frame per tile to learn; after a resize
  all tiles relearn, which shows up as a slightly larger first frame.
- `Capturer.format` has to be set before `start()`; it is a plain `var`, not a constructor argument,
  because `Desk` builds the writer first.
- The `KRD_QUADRANTS` / `KRD_DELTEST` / `KRD_GRID` self-test switches still describe terminals that
  ignore `a=d`. They are kept as calibration tools even though the live path never deletes.
