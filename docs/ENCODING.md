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
