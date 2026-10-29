# Testing & calibration

English | [简体中文](TESTING.zh-CN.md)

There is no XCTest target in this repository: the interesting behaviour is a terminal protocol plus
a screen-capture framework, so the checks are (a) a build, (b) a synthetic picture through the real
render pipeline, and (c) a calibration routine you run inside the terminal you care about. Every
switch below exists because a specific question needed answering without guessing.

```bash
swift build -c release                 # the mechanical check
.build/release/krd --selftest          # the renderer, end to end, no permissions
```

CI ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)) does exactly the mechanical part, and
only on pull requests or on demand (not on every push); release tags get the same build plus
`swift test` from [`.github/workflows/release.yml`](../.github/workflows/release.yml):
`swift build -c release`, `swift test` only if a `Tests/` directory exists (there is none today), and a
universal `--arch arm64 --arch x86_64` build so the release path is known to work. Anything
protocol-, geometry- or input-related still has to be verified with the switches below on a real
terminal — CI has no pty to draw into and no screen to capture.

`--selftest` runs entirely offline: no ScreenCaptureKit, no TCC, no window server juggling. It
pretends the source is a 1440×2560 pt (portrait) region so the aspect-fit path is exercised, takes
the pane geometry from `TIOCGWINSZ` (or `--cell`), and pushes 40 synthetic frames through
`handleFrame` → `TileGrid.dirty` → zlib (parallel) → `emit` → base64 → the terminal, one every 250 ms.
You should see four solid quadrants with a dim checkerboard and a bright bar sweeping left to
right. Anything else is the terminal or the protocol, not the capture path.

Selftest modes end by themselves (≈10 s for the default pattern, ≈64 s for `KRD_GRID`, ≈28 s for
`KRD_QUADRANTS`). They install no signal handlers, so **Ctrl-C kills them without the cleanup
sequence**; if the pane looks broken afterwards, start krd again (it heals on entry) or run
`printf '\033\\\033[?2026l\033[?25h'`.

## 1. `--selftest`

| | |
|---|---|
| Verifies | encoder → escape → tile → placement, plus layout math and dirty detection, against this terminal |
| Needs | a terminal that implements kitty graphics; **no** permissions |
| Passes when | four quadrants fill the pane, the bar moves smoothly, no tearing or fragments |
| Fails when | nothing appears (protocol/terminal problem), or the picture is offset/fragmented (geometry or placement problem) |

Variants (combine with the env switches in the next sections):

```bash
krd --selftest --no-input              # --no-input is redundant here but harmless
krd --selftest --cell 17x33            # pin the cell size instead of trusting the pty
krd --selftest --tile 8x4              # more, smaller tiles: exposes per-tile overhead and seams
krd --selftest --fps 30 --tile 32x16   # fewer, bigger tiles
```

Duration: 40 frames × 250 ms ≈ 10 s, then `endSession()`.

### The TUI layer

`--dev` is checked the same way — the calibration pattern goes through the real pipeline and the
status line is written on the row underneath it:

```bash
make dev-mock                          # a desktop drawn in process: no permission, never stops
make dev-selftest                      # = krd --selftest --dev --pane 137x44 --cell 17x33
krd --selftest --dev --dev-panel stats # a panel pre-opened, for a screenshot or a bug report
krd --selftest --dev --pane 137x60 --cell 17x33 > /tmp/tui.bin
```

`--mock` is the one to leave running: `Capturer` is replaced by `MockDesktop`, and everything
above it — dirty rects, tile extraction, zlib, placements, the chrome — is the real code. The
frame for index `n` is a pure function of `n`, so two runs render the same sequence.

Three things to look for in the pane: the status line sits on the row directly under the picture
(never over it), opening a panel shrinks the picture instead of covering it, and `Ctrl-\\` then
`q` exits without leaving the terminal in the alternate screen. With a shell and no compiler,
`--dev-panel` is the whole test: no keystrokes needed.

## 2. `KRD_GRID=1` — tile placement

| | |
|---|---|
| Verifies | that tile *n* lands exactly on cells `(tx*tileCols+1, ty*tileRows+1)` with the right footprint |
| Passes when | every tile has a 3 px white border, no gaps, no overlaps, and the border of each tile is fully visible |
| Fails when | borders are missing on one side (overlap), doubled (gap), or the last row/column of tiles is misplaced |

```bash
KRD_GRID=1 krd --selftest --no-input
```

Each tile gets a distinct colour derived from its index (`55 + (index*37)%200`, `55 + (index*71)%200`,
blue 200) and a white border, then the same frame is re-emitted 20 times at 200 ms intervals (so a
dropped placement shows up as a tile that disappears on a later pass), followed by a 60 s hold so
you have time to take a screenshot and count tiles. Edge tiles are legitimately smaller — with the
default 16×8 tiling and a 137-cell-wide pane the last column is 9 cells wide, the last row 4 cells
tall.

## 3. `KRD_QUADRANTS=1` — which transmission shape does this terminal honour?

| | |
|---|---|
| Verifies | the terminal's support for four ways of getting the same image on screen |
| Passes when | you can name which quadrants appeared, and it matches the shape krd actually uses (quadrant 2) |
| Fails when | none of them appear (no graphics protocol at all) |

```bash
KRD_QUADRANTS=1 krd --selftest --no-input
```

Four blocks are drawn 400 ms apart, one per quadrant (each with a 6 px black border), each with a
different protocol shape:

| Quadrant | Shape | Meaning |
|---|---|---|
| top-left | `a=T` with `i=` | transmit-and-display, id-addressed |
| top-right | `a=T` without `i=` | transmit-and-display, no id |
| bottom-left | `a=t` + `a=p` with `i=`/`p=`/`C=1`/`c`/`r` | **the shape krd uses in production** |
| bottom-right | `a=T` with `i=` inside a `?2026` block | same as top-left, synchronized |

After the four blocks there is a 6 s hold, then — only with `KRD_DELTEST=1` — a single lone
`ESC_Ga=d,i=901ESC\` **outside** any synchronized block, then a 20 s hold.

`KRD_DELTEST=1` answers a different question: does this terminal's `a=d,i=<id>` remove only that
image, or the whole image set? Watch the top-left block (id 900): it must survive while the block
with id 901 disappears. If everything vanishes, this terminal is one of the reasons krd never sends
per-tile deletes (see [PROTOCOL §6.3](PROTOCOL.md#63-fixed-ids-no-deletes)).

## 4. `KRD_Q=0` — see the protocol's replies

| | |
|---|---|
| Verifies | that the payload you send is actually accepted (`OK`), and why not if it is not |
| Passes when | no `EINVAL`/`ENOENT` anywhere |
| Fails when | `EINVAL: decompression failed` → the zlib framing is wrong (raw DEFLATE instead of RFC 1950) |

Default is `q=2` in every escape (all replies suppressed). `KRD_Q=0` lets them through,
`KRD_Q=1` lets errors through only. The value is written verbatim into the `q=` field, so any value
the protocol defines works.

Replies arrive on **stdin**, which is also the input source, so a reply gets parsed as keystrokes
(Alt-`G`, then the rest as text). Always combine with `--no-input`:

```bash
KRD_Q=0 krd --selftest --no-input      # watch replies in the pane, nothing is typed into the desktop
```

## 5. `--bench` — the encoder, without a terminal

`krd --bench` runs the real tile pipeline (dedupe → dirty → extract → zlib → base64 → escapes) on
synthetic frames and prints bytes and milliseconds per case, with p50/p99 over `--rounds` frames. It
exits by itself and needs no tty, so it is the way to compare two builds:

```sh
swift build -c release
.build/release/krd --bench --pane 137x44 --cell 17x33 --source 1920x1200
```

`--source` is not optional decoration: without it `--bench` fits a portrait 1440×2560 source into
the pane, so `--pane 137x44` measures a 48-column picture. Whatever the effective layout is, the
harness prints it and `bench/check-docs.py` fails when `docs/ENCODING.md` quotes a different one.

The whole suite (encoder + pty harness + budget verdicts + `bench/report.md`) is one command:

```sh
make bench            # or: make bench-quick
```

Related switches: `--json` (machine-readable on stdout, table on stderr), `--bench-wire <case>`
(per-frame JSON on stderr, used by `bench/wire.py`), `--record <dir>` / `--replay <dir>` (real
frames), `--stats-json <path>` (per-second NDJSON during a live run). Layers, budgets and what is
deliberately *not* measured: [BENCHMARK.md](BENCHMARK.md). Current numbers and the reasoning behind
them: [ENCODING.md](ENCODING.md).

## 6. `KRD_DUMP=<path>` — every byte, offline

| | |
|---|---|
| Verifies | exactly what was sent, independent of what the screen shows |
| Passes when | the dump contains the session frame, then one `?2026h` per frame, and per dirty tile: CUP, `f=24,…,a=t,…,i=<100+n>`, 4096-char chunks, the `a=p` placement; then `?2026l` |
| Fails when | you can count the bytes yourself — that is the point |

```bash
KRD_DUMP=/tmp/krd-dump.bin krd --selftest --no-input > /dev/null
xxd /tmp/krd-dump.bin | head -40
wc -c /tmp/krd-dump.bin
```

The file is truncated at first use and receives every flushed buffer, including the heal sequence
and the `2J` clear, so it is a faithful transcript. Comparing two dumps (e.g. `--tile 16x8` vs
`--full-frame`) is the fastest way to see a protocol change. Redirect stdout to `/dev/null` when you
only want the dump — otherwise the same escapes also go to the terminal.

## 7. `--dry-run` — input parsing without consequences

| | |
|---|---|
| Verifies | that a click or key is decoded into the coordinates/keycode you expect, before anything is injected |
| Passes when | the log lines show plausible cell/px coordinates and the mapped screen point |
| Fails when | nothing is logged (stdin is not a tty, or `--no-input` is on) |

```bash
krd --dry-run --debug              # trace goes to $TMPDIR/krd-<pid>.log, path printed on stderr
krd --dry-run --log /tmp/input.log # or straight to a known file
```

`--dry-run` alone is a trap: without `--debug`/`--log` the trace goes to stderr — i.e. onto the
picture, where each line moves the cursor and scrolling shreds the tiles. Lines to look at:

```
input: raw 6 bytes: 1b 5b 3c 30 3b 31 …
input: mouse px(437,812) -> (1204,733) type=1
input: key code=0 flags=256
```

`raw …` proves the terminal sent something; the mapping line proves the geometry is right; if the
first line exists and the second does not, the event was outside the placement (click outside the
picture) or the parser dropped it.

## 8. The other switches

| Switch | Verifies |
|---|---|
| `KRD_NOSYNC=1` | whether the per-tile `?2026h/?2026l` wrapper is what breaks placement on a given terminal |
| `KRD_NO_NSAPP=1` | reproduces "ScreenCaptureKit delivers one frame then stops" (no AppKit context) — a control, not a feature |
| `--full-frame` | the non-tiled path: one image id, one `?2026` block per frame; use it to tell a tiling bug from a protocol bug |
| `--log <path>` | file logging without the stats timer and input tracing |
| `--debug` | stats timer + geometry dump + input trace + `AXIsProcessTrusted()` |
| `--list` | Screen Recording permission and the display/window enumeration, before touching any pixels |
| `-v`, `--version` | that the binary in your hand is the one you think: compare it with the `VERSION` file and the release tag (`scripts/release.sh` keeps both in sync) |

`stats:` line, once per second with `--debug` (field-by-field in
[ARCHITECTURE §9](ARCHITECTURE.md#9-diagnostics-wiring)):

```
stats: 113 tiles/s  1 dirty  8 KB  3.88 MB/s  ms[zlib=1 write=0 max=3 over5=0]  2329x1452 px 137x44 cells  cap=120/4/124 idle=3 bad=0 pipe=4.1
```

Reading it: `tiles/s 0` and `dirty 0` for several seconds = nothing changed (or nothing arrives);
`idle` growing = the capture side is alive but the screen is static; `bad` growing = the capture is
contradicting itself (a frame that says `complete` but carries no usable image), which is a real
capture/buffer problem rather than a quiet screen; `write` in the tens of ms regularly = the
terminal is not keeping up with the byte rate, lower `--fps` or use bigger tiles.

## 9. Calibrating a new terminal

Run this once per terminal you intend to support, in order, and record the answers in the
compatibility table of the README:

1. `krd --selftest --no-input` — graphics protocol at all? (quadrants + sweeping bar)
2. `KRD_GRID=1 krd --selftest --no-input` — placement exact? (white borders, no gaps/overlap)
3. `KRD_QUADRANTS=1 krd --selftest --no-input` — which transmission shapes work? (quadrant table)
4. `KRD_QUADRANTS=1 KRD_DELTEST=1 krd --selftest --no-input` — does `a=d,i=` delete one image or all?
5. `KRD_Q=0 krd --selftest --no-input` — any `EINVAL`/`ENOENT`?
6. `krd --list` then `krd --fps 20 --debug` — capture works, stats nonzero, picture tracks the screen
7. `krd --dry-run --debug` — mouse reports: cells or pixels? (compare a click on a known cell with
   the logged point; if `px(...)` shows up, the terminal honours `?1016h`)
8. `krd --fps 20 --debug` + `--dry-run` — move the pointer without clicking: does the remote cursor
   follow? If it does not, the terminal ignores `?1003h` (any-motion tracking); clicks and drags
   still work, hover does not

## 10. Independent cross-checks (`probe/`)

Pure-Python scripts, standard library only, no Swift and no krd involved. They are the fastest way
to decide "is this the terminal or is this krd?" — each one prints its own narration:

| Script | Question |
|---|---|
| `probe/kprobe4.py` | capability matrix for one terminal: `a=q`, `a=t` PNG, `a=p` with `c/r`, `x/y`, `X/Y`, `z`, `a=f`, `o=z`, raw `f=24`, file mediums, chunking, deletes |
| `probe/kshow.py` | draw one PNG through the plain `t=d` inline path (the known-good baseline) |
| `probe/tile_test.py` | which positioning method lands where (c/r only, cursor-anchored, `x/y`, `X/Y`) |
| `probe/tile_ab.py` | A/B the four plausible ways to get a tile on screen, with white borders |
| `probe/rex_delete_probe.py` | image vs placement delete semantics (`a=d,i=`, `a=d,i=,p=`) |
| `probe/kclick.py` | maps clicks back to image pixels by hit-testing a known placement rect |
| `probe/kdrag.py` | press/drag/release + wheel through `?1002h ?1006h`, no retransmission |
| `probe/kbench.py`, `probe/kpace.py` | pipe throughput and backpressure at a fixed frame rate |
| `probe/sck_probe.swift` | `CGPreflightScreenCaptureAccess()`, `CGPreflightPostEventAccess()`, display/window enumeration (run on the target Mac to see whether TCC is the problem) |
| `probe/ax_probe.swift` | what a headless client can read: the AX warm-up trap, window list without Screen Recording, per-window node counts and walk timing, pruned vs raw size (read-only) |
| `probe/display_probe.swift` | which display-change mechanism fires: `now`, `list`, `set <i>` (a real resolution change), `watch [--appkit]` printing CoreGraphics callbacks and AppKit notifications for 10 s |
| `probe/photo_codec.py` | what a colour-heavy frame would cost under each option of issue #26 (16-bit quantisation, fewer pixels, no zlib) with the same kitty framing, so its baseline row reproduces `krd --bench`'s `photo` bytes |

```bash
python3 probe/kprobe4.py > /tmp/p4.log 2>&1 ; cat /tmp/p4.log
swift probe/sck_probe.swift   # on the machine being viewed
swift probe/ax_probe.swift    # best over ssh: the first AX call fails there until warm-up
swift probe/display_probe.swift watch          # ssh: no events at all (that is issue #19)
swift probe/display_probe.swift watch --appkit # a GUI terminal: 3 notifications per change
```

## 11. Soak: thirty minutes with every feature on

Eleven features landed in one run (#15 keyboard protocol, #16 `--ime`, #17 pid-targeted input, #18
clipboard bridge, #19 display-set changes, #22 `--zoom`, #24 backdrop refusal, #25 idle-frame stats,
#27/#28 `krd ax`, #31 CI budgets). Each was reviewed and tested alone, so the thing nobody had done
is the combination over time — and every one of them added something that can only misbehave slowly:
a pasteboard poll, a display timer, a stream restart per pan, a snapshot file per dump.

```bash
swift build -c release
scp .build/release/krd target:/tmp/krd-soak && scp probe/soak.py target:/tmp/
ssh target 'cd /tmp && python3 soak.py --minutes 30 --binary /tmp/krd-soak \
             --work /tmp/krd-soak --out /tmp/krd-soak/report.json'
```

Exit code 0 is PASS. A short run (`--minutes 2 --interval 10`) is the smoke test used while changing
the script. It samples RSS (`ps -o rss=`), fds (`lsof`), threads (`ps -M`) and the `krd ax` state
directory every 30 s, keeps `--stats-json` on, and pokes the paths that only leak over time:

| stressor | every | what it exercises |
|---|---|---|
| `pbcopy`, 16 B … 8 KB of random text | 60 s | pasteboard `changeCount` poll → OSC 52 encode → write (#18) |
| `krd ax tree --app Finder` | 60 s | one snapshot file per dump, pruned to 16 per window (#28) |
| a pointer sweep, corner to corner, as SGR mouse reports on the pty | 60–120 s | pointer following and `--zoom-follow`, i.e. a capture-stream restart per pan (#22) |
| (passive) | 2 Hz | the display-set fingerprint poll from #19 |

### What it found

Three runs on `kraal-agent` (macOS 26.6.2, M1 Pro VM), same flags
(`--zoom 2 --zoom-follow --clipboard=in --pane 60x24 --cell 17x33`):

| run | build | memory / fds / threads | picture |
|---|---|---|---|
| A, 30 min | `cadf25e` | flat: RSS 31.3 → 31.6 MB, fds 25–26, threads 13→14, `krd ax` 72 KB (16 snapshots, pruned), stats gap 1.0 s | **frozen from 10 min**, for the remaining 19 |
| B, 30 min | A + restart on `didStopWithError` | flat: RSS 31.2 → 31.5 MB, fds 25–27, threads 13→15, `krd ax` 72 KB | restored once, then frozen for 19 min |
| C, 12 min | B + a bounded `stopCapture()` + the frame watchdog | flat: RSS 31.3 → 31.6 MB, fds 19–25, threads ≤15, `krd ax` 52 KB | restored by the restart at 10 min, then the whole main queue wedged at 11 min |

**Nothing leaks.** Four runs, two of them a full 30 minutes, with 12–30 pasteboard writes, the same
number of `krd ax` snapshot dumps and 12–15 capture-stream restarts each: RSS moves by 0.3–0.4 MB,
fds by one or two, threads come back down after each restart, and the snapshot directory stops
growing at exactly 16 files. That is the answer to issue #44's question.

What breaks instead is delivery, at ~10 minutes into a run with restarts:

```
krd: capture stopped: Error Domain=com.apple.ScreenCaptureKit.SCStreamErrorDomain Code=-3805
     "Failed during stream due to application connection being interrupted"
```

krd used to log that line and keep running: `callbacks` never moved again, `delivered` froze, `bad`
stayed 0, RSS/fds/threads stayed flat, and the stats timer kept writing. **From the outside — and
from every number this soak was written to watch — nothing looked wrong.** That is why run A's first
verdict was PASS while the picture had been frozen for 19 of its 30 minutes; the `frames` rule below
exists because of it.

### What changed because of it

- `didStopWithError` now restarts the stream, up to five times with 1-2-4-8-8 s backoff, and logs
  each attempt (`krd: capture stopped (SCStream -3805: …); restarting in 1s (attempt 1/5)`).
- `Capturer.stop()` gives up after 2 s. `stopCapture()` on a stream that has already died never
  calls back on this build, and `restartCapture` awaits it before clearing "a restart is in flight",
  so one hung stop wedged every later restart — including the one that repairs the picture. Run C
  still freezes because of the *next* thing:
- **Still open:** after that recovery the main queue wedges (the watchdog's own 5 s tick stops
  appearing in the log, threads drop to 8, the picture freezes) while the process stays alive. Next
  step is the stack sample `probe/soak.py` now takes automatically the first time `callbacks` stands
  still for a minute (`<work>/sample.txt`), which says whether it is blocked in a `SCStream` call or
  behind the capture queue's `write(2)`.

### Verdict rules, and why they are shaped that way

| rule | threshold | why |
|---|---|---|
| RSS | peak − baseline < 10 MB | the issue's number; a leak that fits in 10 MB over 30 min is not the leak we fear |
| fds | the second half sets no new maximum beyond +2 | a *rising maximum* is the leak signature; `lsof` catching a transient descriptor is not |
| threads | same | SCK worker threads appear and disappear with stream restarts, so the count moves up and down legitimately |
| `krd ax` state | < 64 MB | 16 snapshots per window is the design; the runs sat at 72 KB and stopped at exactly 16 files |
| stats cadence | no gap > 5 s | a blocked write or a stuck callback shows up here first |
| **frames** | `callbacks` must not stand still for 60 s | a static screen is *not* silence (SCK sends `.idle` frames at the refresh rate), so a minute without a callback means the stream, not the content |

The last row is the lesson of this exercise, and the reason the script also reports `saw N OSC 52`
and `N transmits` next to the memory numbers: a soak that only measures growth cannot tell "stable"
from "stopped working".

### What it does not cover

- `--window` mode (#17) captures one window instead of a display, so pid-targeted input is idle
  here; so is `--ime` (nothing is typed).
- The content is a mostly-static VM desktop: the encoder is barely exercised. For an encode soak,
  point `--extra` at something that animates.
- A single-display VM cannot test the unplug path from #19 (that has its own test and probe).
- 30 minutes is not a day, and this VM's ScreenCaptureKit is clearly less reliable than a real
  Mac's: `-3805` after ten minutes of restarts may be a VM artefact. The watchdog and the restart
  are what make that difference survivable either way.
