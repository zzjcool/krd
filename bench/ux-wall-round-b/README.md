# Round B — the landing wall, experienced in a pane

Notes and the measuring rig for the wall review at `a438e9c`. Nothing here ships; the
issues are #112 (a `⤢` control with no action), #113 (captions under the box, not the
picture) and #114 (`--mock` cannot reach the wall).

## How to look at the wall without a screen grant

`--mock` does **not** open the wall at this commit: `Desk.run()` takes the mock branch
(`Sources/krd/main.swift:896`) before the wall branch (`:941`), so `krd --mock --dev`
starts the *mirror* with a generated desktop (log: `mirror grid 77x24 cells … mock
616x384 px @20 fps`). The way to the wall is `--demo`, which replaces the pictures with
`DemoPicture` and the model with `WallSource.demoModel()` (1 display, 4 windows):

```sh
.build/release/krd --demo --debug --log /tmp/krd.log
```

## The rig

`pane-shot.sh <COLSxROWS>` resizes a Rex pane through the terminal's own block method and
prints the text buffer with every `U+10EEEE` placeholder as `.`, so a picture's exact cells
are readable as text — no screenshot, no desktop captured.

```sh
export REX_SESSION=…                                   # the session the pane lives in
OUT=$(rex window new -s "$REX_SESSION" krd-ux-wall --focus=false --json \
        -- sh -c "cd $PWD && exec .build/release/krd --demo")
BLOCK=$(printf '%s' "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["block_ids"][0])')
echo "$BLOCK" > /tmp/krd-wall-block
./bench/ux-wall-round-b/pane-shot.sh 137x44           # resize + dump, pictures as dots
rex window close -s "$REX_SESSION" krd-ux-wall
```

`rex resize` is not implemented in this Rex build; the block method is:

```sh
rex api call -s "$REX_SESSION" block.method \
  "{\"block_id\":\"$BLOCK\",\"method\":\"resize\",\"args\":{\"columns\":137,\"rows\":44}}"
```

Mouse clicks go in as SGR 1006 reports, which is what krd's reader parses; `1`-based cells:

```sh
rex send -b "$BLOCK" $'\x1b[<0;133;31M\x1b[<0;133;31m'   # left click at col 133, row 31
rex send -b "$BLOCK" $'\x1b[<65;60;34M'                  # one wheel notch down at (60,34)
```

That works: clicking the bar's `▼` at row 41 of a 137×44 pane moves the page from
`1–3 / 4` to `2–4 / 4`. Clicking `⤢` on row 31 changes nothing, three times running.

## What a `--demo` wall cannot show

`--demo` fixes the model, so these are unreachable from it and were **not** judged:

* **a mask and its one-word reason** (`closed` / `denied` / `no stream`) — needs a real
  capture to fail; the demo path never calls `PanelCapture`;
* **the footer's notice sentence** (`no picture — grant Screen Recording to …`), which only
  draws when a real capture fails;
* **CJK / emoji / very long titles**, `window N` for a title the grant withholds, and two
  displays — `demoModel()`'s four titles are ASCII and fit any card;
* **more than four windows**, so the last-page arithmetic (`cardStart` 1 vs 2, a partial
  page) is only exercised at `per = 3` with one page of overlap.

## Numbers kept from the session (cell 8×16, pictures as cells)

| pane | stage picture | share of width | card box | card picture | caption starts at |
|---|---|---|---|---|---|
| 200×60 | 122×38 | 62 % | 63×15 | 53×15 / 40×15 / 30×15 | 1 / 68 / 135 (pictures 6 / 79 / 151) |
| 137×44 | 86×27 | 64 % | 36×10 | 36×10 / 27×10 / 20×10 | 1 / 47 / 93 (pictures 4 / 55 / 104) |
| 100×30 | 54×17 | 55 % | 24×7 | — | — |
| 80×24 | 42×13 | 54 % | 25×4 | 14×4 / 11×4 / 8×4 | 1 / 27 / 53 (pictures 6 / 34 / 61) |
| 60×20 | 32×10 | 55 % | 11×3 | — | 1 / 13 / 25 |
| 40×15 | 32×10 | 84 % | *(no band)* | — | band header still says `1–3 / 4`, `⤢ 3` |

The caption column is the *box's* left edge in every row of that table; the picture is
centred inside the box, which is #113.

`--symbols ascii` lays out the same columns (`* krd … | … D Demo Display - 2560x1600 | main
| 1/1`, `w recent 1-3 / 4 … > 3`), so nothing was filed about the symbol tables.

## What worked, so it is not re-litigated

* paging to both ends with the bar's `▼` and the wheel, and the segment turning into a
  plain `│` line once there is nothing to scroll;
* a page kept across a resize (`2–4 / 4` stayed, the thumb moved to its new row);
* the bar's caps (`╷`/`╵`) landing on the four rows §6 asks for; the lower `▼` one row
  above the footer;
* `▶`-free bar, `⤢`/`▣`/`▲▼` all one cell in both symbol tables;
* at 40×15 the divider is dropped and the band header moves up into its place, as §6.5 says.
