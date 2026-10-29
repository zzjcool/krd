# Encoding: where the bytes and the milliseconds actually go

Every number here comes from `krd --bench`, which runs the real tile pipeline (extract → zlib →
base64 → escapes) on synthetic frames and needs no terminal, no screen and no permissions.
Re-run it after any change to `Render.swift`; the command that produced these tables is:

```sh
swift build -c release
.build/release/krd --bench --pane 137x44 --cell 17x33            # new defaults: 8x4 tiles, f=24
.build/release/krd --bench --pane 137x44 --cell 17x33 \
                      --tile 16x8 --format rgba                  # 0.1.1 defaults, for comparison
```

`--pane 137x44 --cell 17x33` is a 137×44-cell pane with 17×33 px cells, i.e. the 2329×1452 px
frame the original measurements were taken on. The column layout is fixed, so two runs are
directly comparable: `serial ms` compresses every dirty tile on one core, `parallel ms` uses
`DispatchQueue.concurrentPerform` (what the live path does), `bytes/frame` is the *encoded
payload* before base64 (so what actually crosses the pty is ~1.33× that).

## Results

Baseline (0.1.1: `--tile 16x8 --format rgba`) against the current defaults (`8x4`, `f=24`):

| case | 0.1.1 bytes | now bytes | Δ | 0.1.1 ms | now ms |
|---|---|---|---|---|---|
| one character (typing) | 2 132 | **727** | −66 % | 0.50 | 0.11 |
| one text line | 12 809 | **8 595** | −33 % | 0.64 | 0.28 |
| full text repaint | 35 220 | 47 485 | +35 % | 1.23 | 0.84 |
| full photo repaint | 4 065 854 | **3 556 212** | −12.5 % | 15.57 | 4.46 |
| 600×400 drag region | 1 478 503 | **1 077 640** | −27 % | 8.35 | 1.58 |

The one regression is a *full* repaint of text content: 66 tiles of 8×4 cells each pay the ~110-byte
per-image escape header, and zlib loses the cross-tile context it had at 16×8. Full repaints only
happen on resize, reconnect and the first frame, so this trades a rare +23 % for a −66 % on the
path that runs 20 times per second while typing. `--tile 16x8` is still one flag away.

Serial vs parallel compression, current defaults:

| case | serial ms | parallel ms | speedup |
|---|---|---|---|
| one text line | 1.19 | 0.28 | 4.2× |
| full text repaint | 5.88 | 0.84 | 7.0× |
| full photo repaint | 39.80 | 4.46 | 8.9× |
| 600×400 drag | 12.41 | 1.58 | 7.9× |

Compression dominated the frame budget: at 0.1.1 a full repaint spent ~80 ms of a 50 ms frame
budget on a photo, which is why a repaint used to stutter. It is now bounded by the encode half
(0.3–1 ms for a handful of tiles), and the parallel section is only reached for tiles that actually
changed.

## Why these levers and not others

**zlib level per tile (issue #3).** One level for the whole frame is always wrong: text compresses to
2 % at level 9 for twice the CPU, while sensor noise gains 1 % going 1 → 9 for six times the CPU.
`LevelPolicy` keeps the *previous* frame's ratio per tile and switches between level 9 (ratio < 7 %),
level 1 (ratio > 13 %) and 5 in between, with a 3 % hysteresis band so a tile cannot oscillate. The
first frame of every tile costs one level-5 pass; after that the per-tile choice is stable for the
lifetime of the layout.

**f=24 instead of f=32 (issue #4).** The desktop is opaque, so the alpha byte is constant. Dropping
it costs 25 % fewer raw bytes, ~12 % fewer encoded bytes on noise (the constant alpha column was
also compressible, so RGBA was getting a discount), and 10–20 % less zlib work. `--format rgba`
(or `KRD_FORMAT=rgba`) is the fallback for a terminal that does not implement RGB.

**One synchronized block per frame (issue #6).** `?2026h`/`?2026l` around the whole frame instead of
around each tile: 16 bytes per frame instead of 16 bytes × 66, and one commit instead of 66. The
memory read of the environment moved into `init` — it used to be rebuilt per tile, i.e. 66 dictionary
reads per frame for a value that cannot change.

**Capture without a full-frame copy (issue #1).** `Capturer` now alternates between two frame
buffers. Writing into a buffer that `previous` (and `Desk.previousFrame`) still references makes
`withUnsafeMutableBytes` copy all 13.5 MB first; with two buffers the one being written is uniquely
referenced by construction, so the conversion writes in place.

## Measuring a change

```sh
.build/release/krd --bench --pane 137x44 --cell 17x33 --log /tmp/bench.log; cat /tmp/bench.log
```

`--bench` prints the *best* of 6 rounds per case (so scheduler noise does not win) and exits. The
synthetic cases are fixed: flat UI with glyph-like strokes, and hash noise with no LZ77 matches at
all. If you add a case, add the row to the table above.
