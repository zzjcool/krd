# Dirty rectangles, re-estimated (issue #7)

**Status:** re-estimate, not a plan. **Recommendation: close #7** — the byte argument it was built on
has already been beaten by #3 + #5, and what is left is 0.3 ms of a 50 ms frame against an
implementation that collides with the invariant the whole design rests on.
**中文版:** [research-dirty-rects.zh-CN.md](research-dirty-rects.zh-CN.md)

Original note: [#7](https://github.com/zzjcool/krd/issues/7) ("dirty rectangles", written in the 16×8
tile era, before per-tile level and before 8×4).

## 1. What #7 claimed

Measured back then, on 16×8 tiles, against the merged-rectangle projection:

| dirty pattern | 16×8 tiles | merged rects | claimed gain |
|---|---|---|---|
| one character | 3900 B / 0.50 ms | 82 B / 0.03 ms | 47.6× |
| one text line | 35482 B / 4.04 ms | 6427 B / 0.59 ms | 5.5× |
| 600×400 window drag | 31912 B / 3.10 ms | 20153 B / 1.90 ms | 1.6× |

## 2. What the same content costs today

Reference geometry (137×44 cells of 17×33 px = 2329×1452 px, 198 8×4 tiles), `krd --bench --json`:

| case | #7 claim (16×8) | today, 8×4 | today, 16×8 |
|---|---|---|---|
| `char` (one character) | 3900 B / 0.50 ms | **332 B payload / 549 B wire**, p50 0.49 ms, **1 tile** | 1017 B / 1462 B, 1.26 ms |
| `line` (one line of text) | 35482 B / 4.04 ms | **1730 B payload / 2864 B wire**, p50 0.91 ms, **6 tiles** | 2618 B / 3777 B, 1.65 ms |
| `full` (whole screen) | — | 19047 B / 31362 B, 2.76 ms, 66 tiles | 14463 B / 20928 B, 2.88 ms |

So the sentence this issue was filed on — *"changing one cell still re-sends 287 KB"* — describes a
world that no longer exists. A one-character change is **549 B on the wire today**, and a text line
is **2864 B**: 20× less than the 16×8-era measurement, and **3.7× less than the merged-rectangle
projection #7 used to justify itself** (6427 B). The tile-size experiment also shows the trade-off is
already balanced: 16×8 would make `char` 2.6× *worse* and `full` 0.75× better, which is exactly the
kind of choice per-tile level (#3) now makes per tile instead of globally.

Live wire confirmation (`--bench-wire line`, steady state after the first full frame): 1731–1735 B
payload over 6 tiles per frame, matching L1.

> `drag` is deliberately absent from that table: the bench's `drag` case is noise (like `photo`),
> so today's 881 KB and #7's 31 KB are different content, not a regression.

## 3. What merging could still buy, measured

The merge would replace 8×4 tiles with a tight rectangle per dirty run. Two measured anchors:

- **per-tile wire overhead**: `char` is 549 B wire for 332 B payload → ~217 B of base64 + kitty
  escape framing per placement;
- **the first frame** (`full`, 66 tiles): 19047 B payload for 2329×1452 px, i.e. ~5.6 B per 1000 px.

| case | today | a tight merged rect (estimate) | saving |
|---|---|---|---|
| `char` | 1 tile = 136×132 px for a 17×33 px change, 549 B wire, 0.49 ms | ~130–250 B wire (the framing is the floor), ~0.2 ms | ~300–420 B, ~0.3 ms |
| `line` | 6 tiles = 192 cells, 2864 B wire, 0.91 ms | 137 cells tight = 0.71× the area, ~1.8 KB wire, ~0.65 ms | ~1.0 KB, ~0.26 ms |
| `full` / `ui` / `drag` | contiguous dirty areas | no gain: the grid is already tight | 0 |

In budget terms the whole remaining opportunity is **~0.3 ms = 0.6 % of the 50 ms frame** for text
typing, and ~1 KB off a 2.9 KB text frame. A pty moves 103.6 MB/s (measured in
[research-photo-bandwidth](research-photo-bandwidth.md) §0); even a 1 MB/s link has 50 KB per frame
interval. The bytes saved here are not on anybody's critical path — unlike the `photo` case, where
the same document measured 13.58 MB/frame and the lever is bytes *per pixel* (16-bit: 1.57×), not
rectangle shape.

Estimates above are marked as estimates on purpose: the merge changes rectangle geometry, and the
encoder has no mode that emits an arbitrary rectangle (`--tile 137x1` is the closest, and it changes
the pixel layout, so it is not a valid proxy).

## 4. Why the price is the part that collides with the design

This is #7's own finding, and nothing since has changed it: adaptive rectangles need image ids and
placements that move, and the protocol work here is a rewrite of the invariant the renderer is built
on (`ARCHITECTURE.md` §7.1: one image id + one placement id per tile, fixed for the process, never
deleted — because `a=d,i=<id>` destroys the whole image set on Herdr and rex, i.e. a black screen).

To ship it: a placement-addressed delete probe per terminal (the plan in #7 §1), an id pool with LRU
recycling and a VRAM cap, a keyframe every N frames as a safety net, and #20's unresolved question
(whether re-placing an existing placement re-orders it in front of the fixed grid) answered first.
A day of probing plus a redesign of id management, to save 0.3 ms of a 50 ms frame.

## 5. Recommendation: close

- The payload argument is settled in the "don't": 332 B per character and 1730 B per line today, below
  the merged-rect projection the issue was arguing for.
- The time argument is 0.3 ms on a 50 ms budget (0.6 %), on content that already runs at p99 1.80 ms.
- The implementation cost is concentrated exactly where the design is load-bearing (ids, placements,
  deletes, z-order), and a mistake there is a black screen, not a slow frame.

**Reopen if** one of these becomes true, rather than on a hunch:

1. a *measured* link where a 2.9 KB text frame is the bottleneck (today: 103.6 MB/s pty, so 35× headroom);
2. a terminal that demonstrably supports placement-addressed delete (`a=d,p=<pid>`) — then half of §4
   disappears and the merged-rect shape becomes cheap enough to try;
3. the codec work (#26) landing in a way that makes kitty *framing* the dominant cost of a text frame
   (today framing is 217 B against 332 B of payload, so this is a real ceiling — but 549 B/frame is
   not a problem anyone has reported).

## 6. Related

- #3 per-tile zlib level, #5 8×4 tiles — they are most of why the numbers above moved.
- [#26](research-photo-bandwidth.md) — the remaining bandwidth lever is bytes per pixel / pixels
  captured, not rectangle shape.
- [#20](https://github.com/zzjcool/krd/issues/20) — cross-frame run boundaries and re-place ordering:
  the prerequisite for any merged-rect work, currently unproven and suspended.
- [BENCHMARK](BENCHMARK.md) §7 for the measurement procedure; numbers above from `bench/report.md`
  and the commands recorded in PR #48.
