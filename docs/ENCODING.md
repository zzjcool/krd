# Encoding: where the bytes and the milliseconds actually go

Every number here comes from `krd --bench`, which runs the real tile pipeline (dedupe → dirty →
extract → zlib → base64 → escapes) on synthetic frames and needs no terminal, no screen and no
permissions. Re-run it after any change to `Render.swift`, `Tiles.swift` or `Tile.swift`:

```sh
swift build -c release
.build/release/krd --bench --pane 137x44 --cell 17x33 --source 1920x1200
```

<!-- bench-config: 2329x1452 px, 198 tiles of 8x4, rgb -->
The configuration line above is checked by `bench/check-docs.py` against the last `make bench`
run: 2329×1452 px, 198 tiles of 8×4 cells, `rgb` (`f=24`). The `--source` flag is not optional
detail — without it `--bench` fits a portrait 1440×2560 source into the pane, and the whole table
below describes a frame 2.8× smaller than this one (that was the bug this line exists to prevent).

`make bench` runs this plus the pty harness and writes `bench/report.md`; [BENCHMARK.md](BENCHMARK.md)
explains the layers, the budgets and what is deliberately not measured.

## Results

Defaults (`--tile 8x4`, `--format rgb`), 30 rounds after 3 warm-up rounds, p50 unless said otherwise:

| case | tiles | payload | wire | dedupe | dirty | total p50 | total p99 |
|---|---:|---:|---:|---:|---:|---:|---:|
| one character (`char`) | 1 | 326 B | **541 B** | 3.4 ms | 0.9 ms | **1.2 ms** | 2.3 ms |
| one text line (`line`) | 18 | 4.8 KB | **8.1 KB** | 3.2 ms | 0.8 ms | **1.5 ms** | 2.0 ms |
| text repaint (`full`) | 198 | 53.2 KB | 88.4 KB | 0.0 ms | 0.0 ms | **7.7 ms** | 10.8 ms |
| photo repaint (`photo`) | 198 | 9.68 MB | 12.95 MB | 0.0 ms | 0.0 ms | **24.2 ms** | 30.3 ms |
| gradient repaint | 198 | 220 KB | 311 KB | 0.0 ms | 0.0 ms | 4.0 ms | 6.3 ms |
| UI repaint | 198 | 59.0 KB | 96.1 KB | 0.0 ms | 0.0 ms | 6.4 ms | 10.9 ms |
| 600×400 drag (`drag`) | 20 | 865 KB | 1.13 MB | 2.6 ms | 0.7 ms | 4.6 ms | 5.5 ms |
| idle (`none`) | 0 | **0 B** | **22 B** | **6.8 ms** | 0.0 ms | 0.0 ms | 0.2 ms |

p50 is reproducible run to run; p99 over 30 samples moves by ±30 % on a laptop that is also
running a browser, which is why `bench/budget.json` sets p99 budgets with 2× headroom and
`bench/compare.py` gates on p50.

`payload` is the encoded zlib stream; `wire` is what actually crosses the pty (base64 ×1.333 plus
~110 bytes of escape header per tile). `dedupe` is the whole-frame `Array ==` in `Capturer`,
`dirty` is `TileGrid.dirty`; both run on every delivered frame, which is why the idle row matters:
**a frame that changed nothing still costs 6.8 ms of memcmp** on a 10 MB buffer, and the payload it
produces is zero.

Per stage, from the single-threaded reference run (3 attempts, best) against the live parallel path:

| case | extract | zlib | base64 | assemble | serial total | parallel | speedup |
|---|---:|---:|---:|---:|---:|---:|---:|
| one character | 0.00 | 0.35 | 0.01 | 0.00 | 0.35 | 0.35 | 1.0× |
| one text line | 0.06 | 5.08 | 0.01 | 0.02 | 5.14 | 1.00 | 5.1× |
| text repaint | 1.20 | 56.3 | 0.08 | 0.23 | 57.5 | 8.0 | 7.2× |
| photo repaint | 1.32 | 140.0 | 5.04 | 1.30 | 141.3 | 17.6 | 8.0× |
| 600×400 drag | 0.14 | 16.7 | 0.48 | 0.14 | 16.8 | 3.1 | 5.5× |

The split is unambiguous: **zlib is 97–99 % of the encoder**, extraction is a handful of `memcpy`,
base64 is 5 % of a photo and noise on text, escape assembly is free. One core cannot carry a full
repaint at 20 fps (141 ms against a 50 ms frame); all ten can, with 3× margin on a photo and 6× on
text. That is the whole reason `handleFrame` compresses with `concurrentPerform`.

### Tile size and pixel format

Same picture, cut differently. `--tile` never changes what is on screen, only how it is packaged:

| case | 8×4 rgb (default) | 16×8 rgb | 8×4 rgba |
|---|---:|---:|---:|
| one character | **326 B** / 1.2 ms | 997 B / 2.0 ms | 412 B / 1.4 ms |
| one text line | **4.8 KB** / 2.0 ms | 7.4 KB / 2.9 ms | 6.3 KB / 1.9 ms |
| text repaint | 53.2 KB / 8.5 ms | **41.1 KB** / 8.6 ms | 69.0 KB / 6.5 ms |
| photo repaint | 9.68 MB / 25.9 ms | 9.68 MB / 29.5 ms | 11.4 MB / 42.1 ms |
| 600×400 drag | **1.07 MB** / 4.2 ms | 1.08 MB / 5.8 ms | 1.28 MB / 6.2 ms |

The one regression of the smaller tiles is a *full* text repaint: 198 tiles of 8×4 pay the ~110-byte
per-image escape header and zlib loses the cross-tile context it had at 16×8. Full repaints happen
on resize, reconnect and the first frame, so this trades a rare +30 % for a −67 % on the path that
runs 20 times per second while typing. `--tile 16x8` is still one flag away.

### Dropping the low bits so zlib has something to find (issue #59)

A photograph on screen is noise to zlib: 5-6-5 has no matches, so `o=z` bought ~1.00× on it. That is
the case where the encoder used to send the pixels raw. Quantising first changes what zlib *sees*:
each channel keeps 5/6/5 bits, so every byte comes from a 32- or 64-symbol alphabet, and the
entropy coder alone reaches **1.29×** on hash noise and **2.3×** on a real photograph. The wire
format does not change — the terminal still receives `f=24` with 3 bytes per pixel, it just receives
fewer of them, and it needs no new feature for that.

The decision is per tile and content-adaptive, using the ratio `LevelPolicy` already computes: a tile
whose lossless attempt bought nothing for **two consecutive frames** is quantised before zlib, and a
tile whose ratio drops back into compressible territory (or whose pixels start to look compressible)
returns to lossless on the next frame. Text and UI never reach the quantiser: their ratio is ~0.1.

Measured with `krd --bench --json --rounds 10`, three alternating runs, medians (`photo` = hash
noise, the worst case; layout as reported in the JSON `config`, 66 tiles):

| | wire | encode p50 |
|---|---:|---:|
| skip zlib (issue #53, today's `main`) | 4,755,012 B | 3.20 ms |
| **5-6-5 then Huffman-only zlib (this)** | **3,686,632 B (−22.5 %)** | **6.03 ms** |

`drag` (noise, but only part of the screen) moves with it: 1,198,117 → 1,105,258 B (−7.8 %),
2.70 → 2.80 ms. Text/UI/gradient are byte-identical, and their p50 does not move.

The cost is 36.5 dB PSNR: banding on smooth ramps, invisible on photographs and video. `--no-quantise`
keeps the encoder strictly lossless and gets the `photo` case back to the skip-zlib numbers. The
trade is only worth taking because bytes, not CPU, are what limits a photo screen: at 20 fps the
lossless path asks for ~95 MB/s against a local pty that tops out at 103.6 MB/s
([research-photo-bandwidth](research-photo-bandwidth.md) §0).

## Why these levers and not others

**zlib level per tile (issue #3).** One level for the whole frame is always wrong: text compresses
to 2 % at level 9 for twice the CPU, while sensor noise gains 1 % going 1 → 9 for six times the CPU.
`LevelPolicy` keeps the *previous* frame's ratio per tile and switches between level 9 (ratio < 7 %),
level 1 (ratio > 13 %) and 5 in between, with a 3 % hysteresis band so a tile cannot oscillate. The
first frame of every tile costs one level-5 pass; after that the per-tile choice is stable for the
lifetime of the layout.

**f=24 instead of f=32 (issue #4).** The desktop is opaque, so the alpha byte is constant. Dropping
it costs 25 % fewer raw bytes, 13 % fewer encoded bytes on noise — the constant alpha column was
compressible too, so RGBA was getting a discount — and 44 % less zlib wall time on a photo repaint
(34.5 ms → 19.3 ms parallel). `--format rgba` is the fallback for a terminal that does not implement
RGB.

**One synchronized block per frame (issue #6).** `?2026h`/`?2026l` around the whole frame instead of
around each tile: 16 bytes per frame instead of 16 bytes × 198, and one commit instead of 198. The
memory read of the environment moved into `init` — it used to be rebuilt per tile.

**Capture without a full-frame copy (issue #1).** `Capturer` alternates between two frame buffers.
Writing into a buffer that `previous` (and `Desk.previousFrame`) still references makes
`withUnsafeMutableBytes` copy all 10 MB first; with two buffers the one being written is uniquely
referenced by construction, so the conversion writes in place.

**What is *not* worth optimising.** Base64 and escape assembly together are 6 ms on a 13 MB payload
and 0.02 ms on a typed character. A faster base64 would be invisible; the numbers above say so, and
that is the point of measuring it.

## The capture size comes from the source, not the pane (issue #69)

`--window` used to size the capture from the pane's box (`cols × cellW × rows × cellH`) whatever the
source was. ScreenCaptureKit does not upscale a window into a box larger than the window: it draws the
window 1:1 in the top-left and **pads the rest with black**. On a 1024×678 window in a 70×24 pane
(1190×792 px box) that was 31.8 % of the frame, and because the pointer was mapped across the whole
padded box, a click near the picture's right edge was sent ~143 pt to its left — which is why the
window felt unoperable.

The rule now:

- `f = min(boxW / srcW, boxH / srcH)` — the picture is as large as the pane allows (see the next
  section for why `f` is not clamped at 1) while the *capture* stays `min(f, 1)`, because asking for
  more pixels than the source has is what gets padded;
- the frame is `src × min(f, 1)`, which has the source's aspect by construction, so there is nothing
  to pad;
- the placement box is `c = ceil(pxW / cellW)`, `r = ceil(pxH / cellH)`, anchored at the pane's
  top-left; the cells it does not reach are left to the terminal's background (krd does not paint
  them);
- the pointer uses **that same box** — `Viewport` is built from the placement cells, not from the
  pane — so a click in the leftover cells is outside the picture and is dropped, not guessed.

A source larger than the box is still downscaled into it, so this changes nothing for a full-screen
capture; `--scale` multiplies the fitted size, and `--display` follows the same rule (a pane wider than
the display no longer asks for pixels the display does not have).

Measured (macOS 26.6, `--window 530` = a 1024×678 Safari window, share of black pixels in the first
recorded frame):

| pane | before: frame | before: black | after: frame | after: black |
|---|---|---:|---|---:|
| 70×24 | 1190×792 | 31.6 % | 1024×678 (61×21 cells) | 7.5 % |
| 88×30 | 1496×990 | 56.6 % | 1024×678 (61×21 cells) | 7.5 % |
| 60×20 | 1020×660 | 8.9 % | 997×660 (59×20 cells) | 6.8 % |
| 70×24 at `--scale 0.5` | 595×396 | 7.0 % | 512×339 (61×21 cells) | 6.4 % |

The black that is left is the page's own dark UI: the same runs against a light page measure 0.2 %, and
the padding was visible as a band — the last row and the last column of the before frames are 100 %
black, of the after frames 0–6 %.

Clicking was checked against a control rather than by eye: the "New Tab" button of that window, at the
pixel where it sits in the picture, opened a tab in six of six runs (panes 70×24, 30×12 and 88×30, at
scale 1 and 0.5) and in none of the same six clicks on the previous build. In the 88×30 pane the old
mapping sent that pixel to `(1022,247)` instead of `(1316,255)` — the 294 pt that made the window
unusable there.

Clicks in `--window` mode were also broken for a second, unrelated reason on macOS 26:
`CGEvent.postToPid` delivers keyboard events but drops **mouse** events (Safari and TextEdit both
ignore them silently), so the mirrored window could not be clicked at all. Mouse events now go through
the global tap while the mirrored window is the one on top at the pointer, and through the pid only
when it is covered (issue #17's case).

## Where the picture goes: `fit` vs `--scale` (issue #71)

Two independent decisions, one each:

- **`fit = min(boxW/srcW, boxH/srcH)`** is how large the picture is *on screen*, relative to the
  source's own points. It **may exceed 1**: a 1024x678 window in an 88x30 pane (1496x990 px) is drawn
  at 1.46x and fills the pane. That enlargement costs no bytes — the terminal does it.
- **captured pixels = `srcW × min(fit, 1) × --scale`** is how many pixels we *send*. Never more than
  the source has (ScreenCaptureKit pads a box that is too large instead of upscaling it, #69, and a
  display mirror must not start capturing more because the pane grew), and `--scale` only ever takes
  pixels away.

So `--scale` buys bandwidth and nothing else. At `--scale 0.5` the frame is half as wide *in the same
cells* — measured 512x339 px in 61x21 cells, with the placement bytes identical to scale 1 — and the
terminal stretches it back by 2x. `--debug` prints that stretch factor, because it is the number that
explains why a low scale looks soft:

```
krd: source 1024x678 pt -> 512x339 px in 61x21 cells (scale 0.5)
     (the terminal stretches x2.04: 512x339 px in 61x21 cells)
```

The pointer is mapped against the **placement** — the cell box the picture occupies — because that is
what an SGR-Pixels coordinate addresses. When the source's aspect leaves cells over (a wide pane for
a tall window), those cells stay the terminal's and a click there is ignored instead of being mapped
into the window.

## Capture scale: `--scale` (issue #60)

`--scale 0.5` asks the capturer for half as many pixels in each direction (`SCStreamConfiguration.
width/height` = the source × `min(fit, 1)` × the scale) and lets the terminal upscale the image back
into the same cell box. Nothing else moves:

- the **crop** (`sourceRect`) is unchanged — this is not zoom;
- the **placement box** (`c=8,r=4` per tile, the same cells) is unchanged, so the picture still fills
  the pane exactly: `--record` gives 1020×627 raw frames at scale 1 and 510×314 at 0.5, while the
  escape stream carries `c=8,r=4` placements and 136×132 / 68×66 px images in the two runs;
- the **pointer mapping** is unchanged, because SGR-Pixels coordinates address the *placement* (the
  cell box the picture occupies), not the image's pixels. Clicked at the same terminal pixel, TextEdit's caret lands at the same offset at both
  scales (86 and 948 for two points), and a deliberately doubled pixel lands somewhere else;

The cost is resolution: at 0.5 a 13-point glyph is described by half as many pixels per side, so text
gets visibly soft — the terminal's upscale is not a substitute for real pixels. It is a trade, not a
free win. The *default* is adaptive (below): 1 while the link keeps up, and it only steps down
when the write side cannot keep up -- so what a user has to opt into is nothing.

Measured (macOS 26.6 VM, pane 60×19 cells of 17×33 px, the still desktop; `--bench` for the pinned
813-tile photo layout):

| | scale 1 | scale 0.5 | scale 0.25 |
|---|---:|---:|---:|
| capture pixels | 1020×627 | 510×314 | 255×157 |
| `--bench` photo wire | 13.57 MB | 3.41 MB (**3.98×**) | 0.86 MB (**15.7×**) |
| live bytes/s (desktop) | 3.08 MB/s | 1.02 MB/s | 0.23 MB/s |
| CPU (`ps %cpu`) | 17.5 % | 8.4 % | 3.9 % |
| `bad` frames | 0 | 0 | 0 |

The live ratio is 3.2× rather than 3.98× because a still desktop's bytes are mostly per-frame framing
and the tiles that change; the bench number is the clean one. An automatic "drop the scale before the
frame rate" policy is deliberately *not* here: the flag and the numbers come first.

## Capture scale: `--scale auto` (issue #64)

`--scale auto` starts at 1 and moves down the ladder `1 → 0.5 → 0.25` while the **write side** cannot
keep up, then back up when it can. **It is the default** (issue #73): a user does not know the flag,
and the two failures are not symmetric -- a softer picture is understandable, a frozen one is a bug
report they cannot act on. A fast link never leaves 1, so nothing changes for the picture anyone
already has; `--scale 1` pins it, `--scale 0.4` fixes any value.

`--bench`, `--selftest`, `--record` and `--replay` pin it to 1 and say so once
(`krd: --record captures at scale 1 (...)`). They either have no pipe to measure, or they produce
something a later run reads back: a recording whose frame size changed mid-file has every frame valid
on its own and **nothing in the file marks the change**, and `--replay` would then feed frames that
disagree with the header it read at the start. A fixed `--scale 0.5` is still allowed there, because
it is constant.

**The signal is backpressure, not encoder time.** A frame is *late* when it took longer to come out
than the interval it has to fit in (`write_ms > 1000/fps`, and `--stats-json` reports the ratio per
second as `late`/`frames`). That is the causal version of "the link is losing": when the pty cannot
take the bytes, `write(2)` is where the frame sits, so the write's own duration crosses the budget
and stays there (#26 measured 619 ms per write on a 20 MB/s link while
the encoder kept producing 20 fps). Encoder time says nothing about that — a fast machine on a slow
link has cheap frames and a broken picture; and the *whole* frame's duration is not it either, because
a photo repaint that only happens twice a second takes longer than 50 ms to encode on any machine.

| | down | up |
|---|---|---|
| condition | > 50 % of frames late | < 5 % of frames late |
| window | 3 s (≥ 6 samples) | 10 s (≥ 20 samples), the whole window observed |
| after a change | 5 s minimum dwell, both directions | same |

**Why asymmetric.** Going down spends quality the user can see but understands (a softer picture,
which is strictly better than a picture that stutters). Going up spends a risk: if the link cannot
carry scale 1 after all, the next few seconds stutter *at the moment the user asked for nothing*.
So the downgrade is a majority vote over a short window and the upgrade is near-unanimity over a long
one — it is much harder to come back up than to fall down.

**Why that alone still flaps, and what the backoff adds.** On a link that carries 0.5 easily and 1
only at 2 fps, "quiet at 0.5 for 10 s" is true a few seconds after every probe, so thresholds alone
give a 10-second cycle — up, stutter, down, up… To stop that, an upgrade that is undone within 20 s
counts as a **failed probe** and multiplies the quiet window it will demand next time by 3 (capped at
300 s): 10 s, 30 s, 90 s. A probe that survives 20 s resets the penalty. The end state on such a link
is "mostly at 0.5, one probe every few minutes", which is what a person would do by hand.

A scale change goes through the same in-place `updateSource` as a pan (#57): the stream is not
restarted, so the picture never goes black and the frame watchdog is not involved. The log line is
`krd: pipe is behind; scale 1 -> 0.5` (or `pipe has headroom; scale 0.5 -> 1`), and `--debug`'s
`pan:` line shows the update that carried it. The pointer mapping is unaffected at every level for
the reason #60 gives: the viewport is built from the pane's pixels, not the captured ones.

`--fps` is deliberately *not* touched: lowering the frame rate is a different promise (fewer, sharper
frames) and the user should be the one to make it.

## Measuring a change

```sh
make bench                      # everything + bench/report.md, budget verdicts included
make bench-encode               # the tables above, straight from the binary
.build/release/krd --bench --json --rounds 30 --pane 137x44 --cell 17x33 --source 1920x1200 \
  > /tmp/before.json            # machine-readable, for compare.py / ab.sh
make bench-ab REF=main          # same-machine A/B, writes bench/ab-report.md (paste into the PR)
```

`--bench` prints the table, `--bench --json` prints JSON and moves the table to stderr. Warm-up is
always 3 rounds and the reported distribution is p50/p95/p99/max over `--rounds` frames, because a
best-of-6 hides the p99 that a user actually feels as a stutter.

The synthetic cases are fixed and each one asserts its own dirty-tile count: `char` must dirty
exactly one tile, `line` one tile row, `none` nothing. A harness bug then fails the run instead of
quietly producing a plausible-looking number. If you add a case, add the row to the table above and
a budget to `bench/budget.json`.
