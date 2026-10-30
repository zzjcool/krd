# term-probe: what a real pane says about krd's picture rectangles

Round C4 of the overnight sweep — terminal compatibility, measured in a Rex pane rather than on a
pty stub or in a unit test. Nothing here changes product source.

## Method

`krd --selftest` places every tile with `ESC[<row>;<col>H` followed by an APC whose `c=` / `r=` are
the tile's **cell** box. So the emitted byte stream is a map of where each picture went, and it is
readable without a screenshot, without a client rendering the pane, and without decoding pixels:

```bash
# one run at an exact pty size in a Rex block, stream captured to a file
rex send -s "$REX_SESSION" -b "$BLOCK" \
  "stty rows 15 cols 40; krd --selftest > /tmp/f/40x15.bin 2>/tmp/f/40x15.err"$'\n'
python3 frames.py /tmp/f/40x15.bin 40x15
```

`frames.py` splits the stream into `?2026` frames, reads every placement, and checks

1. the first (full) frame tiles its box with no **hole** and no **overlap**;
2. no placement, in no frame, falls outside that box (a row or column shifted by one shows here);
3. the **last cell of the last row** is never drawn (it would scroll the pane);
4. every row of the box is covered by the full box width.

`run-sweep.sh <cols>x<rows> <tag> [krd flags…]` is the single-run driver.

## Results (HEAD a438e9c)

39 runs: `{40x15, 60x20, 80x24, 137x44, 200x20, 20x70} x {--tile 8x4, --tile 32x16, --format rgba,
--symbols ascii, --no-quantise, --full-frame}`. All clean on (1)(2)(3)(4); `last-cell 0` in every
run. Centring is exact: 18 rows in a 70-row pane → rows 26..43; 23 cols in a 200-col pane → 88..110.

The one defect the sweep found is layout maths, filed as
[#143](https://github.com/zzjcool/krd/issues/143): `TileGrid.make` (Tiles.swift:102) clamps the
picture's box **up** to a whole tile before computing `fit`, so `--tile 32x16` on a 15-row pane draws
18 cells where the aspect says 17 (`c=18,r=15` in the placement, `fit 0.100` instead of `0.09375`),
`--tile 24x20` stretches the picture 36 %, and the default `--tile 8x4` does the same on any pane
shorter than 4 rows (`--pane 40x3` → `5x3` cells, `fit 0.025` = a 64 px box in a 48 px pane).

## What this harness cannot see

`--selftest` refuses a pinned `--scale` ("always captures at scale 1"), so `--scale 0.25` and
`--scale 0.5` produce **0 bytes** and are not covered — the live `--scale` path still needs a real
mirror run. `--selftest` also forces pixel-sized placements, so the unicode-placeholder path is
reachable only through `--mock` (where the wall/mirror text layer *was* readable: 24 rows of
`U+10EEEE` at 80x24, and no chrome at all — see the comment on #116).
