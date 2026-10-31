# The landing screen: your displays, and the three windows you used last

English | [简体中文](design-overview.zh-CN.md)

**Status:** v8 · Mockup: [media/overview-mockup.html](media/overview-mockup.html)
(`#wins=7&others=1` default · `#start=4` scrolled to the end · `#wins=14&others=2&per=4` many windows ·
`#fail=1` what a failed capture looks like).

## 1. At a glance

```
▪ krd    7 windows · 3 displays · most recently used first       ╷
┌────────────────────────────────────────────────────────┐   ▲
│                                                        │   █
│        main display: fitted, bars left transparent      │   │
│                                                        │   │
└────────────────────────────────────────────────────────┘   ▼
🖥 Built-in — 1512×982 · main · 1/3                          ╵
────────────────────────────────────────────────────────    
▣ recent    1–3 / 7                                  ⤢ 3   ╷
┌──────────────┬──────────────┬──────────────┐             ▲
│    Safari    │    Xcode     │   Terminal   │             │
└──────────────┴──────────────┴──────────────┘             ▼
▣ Safari — Apple…  ▣ Xcode — kkrt…  ▣ Terminal — ~/code…
▪ click a card · scroll with the right bar · 0 B/s still   4 panels · ~28 KB
```

- **Top:** the stage. **One display at a time, filling the stage**; the rest are reached by scrolling the
  right-edge bar.
- **Bottom:** the most recently used windows, same bar, with `⤢` a control you click to switch 2 / 3 / 4 per
  row, and the band holding as many rows of them as fit.
- **Right edge:** one **bar as tall as the pane**, in two segments - the upper one for displays, the lower one
  for windows. `▲` at the top, `▼` at the bottom, a `█` thumb in between; click a plain cell to jump there.
  **No more little `◀ ▶` triangles.**
- One caption row under each panel (`🖥 name - resolution`, `▣ app - title`); picture and caption both enter.
- After entering, a `⬅ 🖥 back` row. **No keyboard vocabulary**: every key belongs to the remote desktop;
  `Ctrl-\\` is the only exception.

## 2. Why three

- A readable card needs 24–44 cells; three fit a 137-cell pane comfortably, four start truncating captions.
- With "most recently used" ordering, the one you want is nearly always on the first page; scrolling is the
  fallback, not the path.
- **One display at a time** (see §6.6): the number of displays must not change the cost, and must not squeeze
  every one of them into a slit.
- So the capture count is 1 display + one page of windows - **four** at 137×44 (≈28 KB), seven on a pane whose
  band holds two rows of three - and it stays that whether there are 20 windows or 5 displays: the cost follows
  the pane's page size, never the desk.

## 3. Where the order comes from (measured)

`CGWindowListCopyWindowInfo(.optionOnScreenOnly, .excludeDesktopElements)` on a real machine:

```
  5  layer 0  pid 67529  Rex Beta       Settings - Developer          103x112
  7  layer 0  pid 93439  WindowManager  Gesture Blocking Overlay      149x155
  8  layer 0  pid 26465  WeChat         Weixin                        149x155
 22  layer 0  pid 40544  Brave Browser  2026…                        1452x1050
```

- It returns **front-to-back z order** — "most recently raised". Windows' own "recently used" list uses the
  same source.
- **The trap:** the system inserts `WindowManager Gesture Blocking Overlay`, which is **also layer 0** and comes
  in pairs with the real window. So the filter can only be "**the owner is a regular app** (a Dock icon)";
  filtering by layer or size misses it.
- **Not strict MRU:** a window raised without activation still moves forward. A free approximation, good enough.
- Strict MRU would mean keeping our own ledger, but `NSWorkspace.didActivateApplicationNotification` is **not
  delivered to krd** — it never runs NSApp's run loop (see the screen-parameter note in `ARCHITECTURE.md`).
  Doing it properly needs a background thread whose only job is a CFRunLoop; the cost is out of proportion.
- Order, owner, bounds and PID **need no Screen Recording grant**; **only the title does**. Without it, the
  caption's second line degrades to "window N".

## 4. Pictures, or masks

**Pictures by default.** A mask is not the low-resource default; it is the **fallback for a failed capture**
(the window just closed, the grant was refused, no pixel buffer):

- A mask occupies **exactly the panel's rectangle**, so going picture ↔ mask never moves the layout.
- A mask draws `👁 name / W×H cells`, and clicking it does the same thing as clicking the picture.
- A mask says **why** it is a mask, in one word, where the picture would be: `closed` (the window went
  away), `denied` (Screen Recording), `no stream` (the window server refuses that window - `-3805`),
  `no pixels`, `failed`. Every cause draws the same rectangle, so without that word "no picture" is all
  a reader can report - and "no picture" was the question, not the answer (`PanelCaptureError.maskLabel`).
- Because only a page of windows is on screen (three at 137×44, up to nine on a tall pane), "everything open" is
  bounded **by the layout itself** — no need to save resources by drawing nothing.

## 5. Interaction

| input | action |
|---|---|
| click a window card (or its caption) | enter that window (single-window mirror, 20 fps) |
| click the display on the stage | mirror the whole screen |
| click `▲` / `▼` in the upper segment | previous / next display |
| click `▲` / `▼` in the lower segment | previous / next page of windows (one page = `per × cardRowCount`) |
| click a `│` in the middle | jump proportionally (the `█` thumb shows where you are) |
| click `⤢` | cycle the row width 2 → 3 → 4 → 2 cards per row; only the widths this pane can honour are offered (a card never falls under `minCardCols`), and a width that drops out of the list is skipped |
| click `⬅ 🖥 back` | return to the landing screen |
| any key | forwarded to the remote desktop |

An end with nothing further is dimmed and inert - no dead cells that swallow clicks.

**The pointer is answered before it is pressed.** A mouse *move* used to be thrown away (`InputReader`
only routed a press), so the wall could not tell a reader what they were aiming at: a card, the
stage, or a gap. Now every report — move, press, release — asks the same click table
(`WallLayout.action` → `WallState.focus(atRow:col:)`), and the item under the pointer is drawn in
reverse video on its caption row, with its box in the accent colour where a box exists (a card whose
picture arrived has no box left to colour, and a masked slot has only the box, so the caption is the
one signal both of them can show). A press deepens it: the box stays accent and the app name
reverses, which is the only feedback there is before the mirror takes the pane.

Two numbers decided the shape. A hover repaint is **39-97 B** measured on a 120x34 wall
(`WallHoverTests` pins the 600 B budget from `docs/design-ui-v2.zh-CN.md` §5), and it must not
re-send pictures: the first implementation did, and crossing four cards cost 18 KB per move because
`paintWall` re-emitted every kitty image. A pointer-only paint therefore reuses the slot states of
the frame already on screen (`wallLastPaints`) and sends text alone. Moving within the same item
costs 0 B — no report, no paint.

## 6. The bar on the right

There is exactly one shape of scroll control that works in a terminal: **big, on the edge, always in the same
place**.

- **One cell wide, as tall as the pane**, pinned to the right edge; content always gives up 2 cells
  (the bar plus one of padding).
- **Two segments**: the upper one spans the stage, the lower one spans the cards, separated by `╵`/`╷`.
  Because the position is fixed, "scroll the windows" is always the same place - no hunting.
- **Inside a segment**: `▲` on the first cell, `▼` on the last, `│` between with one `█` thumb whose position is
  current / total.
- Clicking a `│` jumps proportionally; `▲`/`▼` moves one step (one screenful when `scroll = page`).
- **A segment only three rows tall has one cell between its arrows**, and one cell cannot hold a position:
  the `█` is drawn there whatever page you are on, so a click on it keeps that page. The bar answers for the
  cell it is drawn on - a cell that says "you are here" must not jump to the start.
- With a single display, or fewer windows than fit, the segment becomes one continuous dim `│` and **draws no grey
  arrows** - an arrow that cannot do anything is a lie about where the live cells are. Nothing to scroll should
  not look clickable (that is what `WallCanvas.drawSegment` does).
- **The bar never touches the final cell of the final row.** Writing it arms pending-wrap, the next byte scrolls
  the grid and every placement is one row off (`Chrome.swift:459-463` exists for exactly this; a change confined
  to that one cell is dropped entirely, `:464`). So the lower `▼` stops one row above the footer, and the footer
  row belongs to no segment.

Why not `◀ ▶`: they are one cell by one cell in a terminal, and a mouse takes several tries to hit them. The bar
is 20+ cells tall, and the thumb doubles as "where am I in this list".

## 6.5 Layout (the row budget)

Top to bottom: header 1 row → stage (`stageH + 1` caption) → **divider 1 row** → card band header 1
row → the card section (`cardH` picture rows + 1 caption row, holding a page of `per × cardRowCount`
cards) → one blank row → footer 1 row.

The divider came out of review: without it the stage caption, the band header and the tops of the
cards arrive as three dense rows in a row ("too crowded"). One dim rule is cheaper than a blank row -
it says where a section ends, which a blank row does not. It is also the first thing dropped: below
20 rows there is no divider (`dividerRow` is empty) because in a pane that short a row of rule is
worth less than a row of picture.

**Seven rows of display to three of shelf.** `stageH = round(0.7 × budget)` and the card band takes
`budget - stageH - 1` (the -1 is the band's own caption row), where `budget = rows - 6`, or `rows - 5`
in a pane too short for the divider. A band that cannot reach `minCardRows` is dropped and its rows go
to the stage instead of showing a two-row strip. Before this the cards took their ideal height first
and the stage got the leftovers: on a 240×44 pane that was 23 rows of cards against 14 rows of
display, so the desktop arrived as a small picture in the middle of an empty wall ("桌面缩在一角，其余
全黑"). On top of the split the stage's aspect still caps it - a taller pane hands the rows a 16:10
picture cannot use back to the card section, which spends them on more *rows* of the same previews
(118×73 with a 17×33 cell: stage 37, section 29 + 1; 137×73 on an 8×16 cell: 42 + 24 + 1).

- **`per` is cards per row.** A page holds `per × cardRowCount`, where a card is as tall as its slot
  width makes it (`cardRows = winW / (1.62 × cellAspect)`, floored at `minCardRows` and capped by the
  band) and `cardRowCount = (cardH + 1) / (cardRows + 1)` - a row of cards is its picture plus the
  caption directly under it, and the section owns `cardH` picture rows plus one caption row. So the
  same page holds three windows at 137×44 (where the band is exactly one preview tall) and six at
  118×73. `capacity = per × cardRowCount` is what the bar's `▼` steps by, what the title range prints
  (`1–6 / 7`) and what the thumb's track is measured against.
- **The `⤢ N` at the band header's right end is a real control.** Its three cells are `WallLayout.bandTail`, the
  same rectangle `action(row:col:)` answers for, so the glyph can never be drawn where a click does not land. A
  click cycles the row width through the widths this pane honours (`perChoices(paneCols:)`), and `capacity` -
  hence the page, the bar's thumb track and the `1–N / M` range - follows it. A cycle does not move the page
  start: only when the wider row leaves fewer than `capacity` windows after it does the layout pull the page
  back. Where the control has no second row width to cycle to, or its number needs a second digit that three
  cells cannot spell, it is not drawn - a control that cannot act, or cannot say what it would do, is not drawn
  at all. When the pane is too short for a card band the header prints `no room` in place of the range instead
  of naming cards nobody can see (a pane with no *window* at all says `no windows`). It is **dim**, the same
  weight as the footer's live `⬅ 🖥 back`: weight alone does not say whether a cell answers - what does is that
  a control which cannot act here draws no glyph of its own, the way a dead bar segment keeps only its plain
  `│` instead of arrows.
- **A card is one slot of `per`, whatever the page holds.** A page of one used to blow its card up to
  the whole band - a 115×29 box around an 11-row picture, reported as "the preview is much too big,
  three to a row is enough" ("窗口的预览可以再小一点…一排可以显示三个窗口"). The slot's width decides the
  height, the caption sits directly under the picture, and the row is centred in the band (§6.7).
- Rows are filled left to right, `per` at a time; the next row starts one caption row lower, so a page
  of six reads as two rows of three pictures, each with its label under it. The stack of rows is
  centred in the section too, with the leftover section rows split above and below it rather than
  pooled under the last row (an odd one goes to the bottom, §6.7).
- Content width `content = cols - 2` (bar plus padding); the slot is
  `winW = floor((content - (per-1) × gap) / per)` - 137 columns / 3 → 43 cells, 118 columns / 3 → 37.
  A card narrower than `minCardCols` (8) is not drawn at all, so a narrow pane shows fewer per row
  instead of a strip of slivers.
- Between two cards: `cardGap = max(1, content / 45)` cells - 3 at 137 columns, 1 on a 60-column pane. One
  cell was the first version and read as the cards touching; the gap scales with the width because air on a
  narrow pane is paid for with a card (`per` drops from 4 to 3 at 60 columns if the gap is 3).
- The stage takes the rest of the budget: 137×44 is **stage 27 + a section of 11 rows** (10 picture rows
  and the caption row), which is what the pinned layout table in `WallLayoutTests` asserts.
- Whole-cell placement only; never the last cell of the last row (autowrap pushes the whole picture up).
- Every truncation and pad goes through `DisplayWidth` (CJK and emoji are wide). `⤢ ▣ ▲ ▼` are narrow
  enough that a pane can be laid out on one cell per symbol, so `--symbols ascii` (`> w ^ v < . '`) exists and
  both modes must lay out the same columns.
- The numbers are **libghostty's own table** (`WidthTable.swift`, generated by `scripts/gen-widths.sh` from
  `ghostty_unicode_grapheme_width`), not a hand-written EastAsianWidth list. The hand-written one was wrong in
  both directions on the terminals krd is tested against: `☰` (U+2630) and a flag (two regional indicators) are
  **2 cells** in Ghostty 1.4.0 and Rex and the old table said 1, so every column after one of them was off by
  one - silently, and only for the glyphs nobody had thought about. Measured, both terminals, both 2027 modes
  (`docs/design-ui-v2.zh-CN.md` §2.3).
- **Measured correction:** `🖥` (U+1F5A5, no VS16) is **1 cell**: it has no default emoji presentation and
  terminals draw it narrow. The earlier revision called it wide; that was wrong, and so was "East-Asian
  Ambiguous means wide" for the symbols above.

## 6.6 How a display and a window fit their cells

**Fit, always: keep the aspect, never crop, never stretch.** The picture shrinks to the largest size that fits its
band, and **the panel *is* that picture**: the image is exactly the fitted pixels, placed on exactly the cells the fit
measured, and the cells the band has over are **not painted at all** - the wall's own background is what shows there, so
a card reads as a window lying on the wall, not a window in a frame.

| case | handling |
|---|---|
| landscape (16:10 / 1.54) | the width fills the stage's columns and **the band is exactly the rows the aspect gives** (`WallLayout.make(stageAspect:)`: 42 of a 137×73 pane's rows on an 8×16 cell); the rows a tall pane has over go to the card section, which shows more rows of the same previews (§6.5) |
| pixels are quality, cells are geometry | with unicode placeholders the terminal fits the image into the picture's cells (§6.9), so the capture is asked for at `pane.dpr` device pixels per **reported** cell - 2 on a terminal that answers in points, 1 on one that answers in device pixels - and `--dpr N` overrides it (both axes share the factor, capped at 4096 px a side). The pixel-sized path (`--no-placeholders`) has no fitting, so there the picture *must* be asked for in device pixels - and a terminal that reports its cell in points makes that number unavailable, which is why that path takes `--cell` and why placeholders are the default |
| where the cell size comes from | one `PaneGeometry` snapshot: the pty's `ws_xpixel` when it has one, else the terminal's own `CSI 16t`/`14t` answer, else the 8×16 fallback (an 8×20 cell belongs to the CRT era, and its 2.5 aspect against a real 2.0 left 36% of the stage empty). Measured at start and re-measured on every resize (`PaneGeometry.measure`) |
| portrait (1200×1920) | still height-bound, the picture is simply narrow (~29 cells), centred |
| window card | the card rect is the layout's and the picture fits inside it at the window's own aspect: 43×13 cells at 137×44, 37×12 at 118×73 (a 17×33 cell), where the section inherits the rows the stage does not need and spends them on a second row of the same slots. A picture never resizes its own card |
| corners | **rounded**, a fortieth of the short side (`--square` for square). The first revision was square ("把圆角边框去掉吧") because a cut corner is a hole that the terminal fills with its own background: a rounded picture read as a frame around a smaller picture. The frame was the *other* bug - ScreenCaptureKit pads with black instead of upscaling (`PanelCapture.fitted`), so the picture's pixels held a desktop in one corner. With the picture equal to its cells the corner hole is inside the picture and shows the wall the picture lies on, which is what a window looks like. This is the only alpha in a wall image; the mirror's tiles stay opaque RGB |
| one height per row | the cards of a page are drawn at **one height** - the tallest one every picture can reach without cropping, i.e. the widest window's (`WallPanels.sharedCardHeight`, then `PanelImage.fit(maxHeight:)`). Per-window fitting left a 16:9 card shorter than a square one, so the row's top and bottom edges disagreed ("窗口的最高高度需要保持一致"). The cost is that one wide window shortens its neighbours while it is on the page; the alternative would be cropping, which the design rules out |
| the maths | one direction, **cells → pixels**: `availW = cols×cellW`, `availH = rows×cellH`; if `availW/availH > aspect` then the height is the constraint, else the width; the result is rounded to whole **cells** (`PanelImage.fit`), and the picture's pixels are then exactly those cells × the cell (`86×27 cells at 8×16 px = 688×432 px`, not one pixel more), with no offset inside the panel. Rounding the other way - fit in pixels, re-derive the cells - left the picture up to half a cell larger than its box, which a 1:1 terminal shows as a gap and a scaling one hides as a 1-2% stretch |
| order | the menu-bar display first (`kCGDisplayIsMain`), then by `bounds.origin.x`, left to right |
| capture | **only the one on stage**: three displays + one page of windows - 4 panels on a 137×44 pane, 7 on a 118×73 one, where a page is six. The cost follows the pane's page size, never how many windows exist |

Why not cover: cover throws content away, and the display's own shape *is* information - no menu bar, no Dock, and the
reader cannot tell which display they are looking at.

Why not bars in the image at all (three versions tried, all measured): black bars read as a frame around every picture;
"the picture's own edge colour" was a guess at a background the terminal already has (a light window got a light bar on a
dark wall); and transparent bars (`f=32`, alpha 0) are only invisible on a terminal that blends alpha into the *cell
background*. **Rex paints a transparent image pixel black** - it does not let the wall through - so a stage whose
picture filled 64% of a panel-sized canvas arrived as a picture with a black ring, reported as "the display is smaller
than its frame, and the capture resolution must be wrong". It was not: the pixels were exactly the fitted size. The
fix is to stop shipping a canvas at all. The image is the picture, the placement is the fitted cells, and the cells
between the picture and its band are simply not painted - which is what the mirror has always done with the cells its
letterbox leaves over, and nobody has ever reported those as a bug.

**The band is the picture, never a box the picture sits in.** A tall pane's row budget used to give the stage more rows
than a 16:10 picture can use (53 against 42 at 137×73), and because a caption hangs one row under its picture, that
slack showed up as wall *between* the picture and the divider - reported as "the display is smaller than its frame",
right after the black ring. `WallLayout.make(stageAspect:cellAspect:)` now sizes the stage band from the picture and
gives the rows it does not need to the card section, which spends them on **more rows of the same slots** (`per` is the
reader's number and does not move): at 118×73 with a 17×33 cell that is two rows of three 37×12 previews instead of one
row with 18 rows of empty wall under it (issue #83), and at 137×73 on an 8×16 cell the section is 25 rows, which holds
one row of 43×13 previews because a second one would need 28. What it never does is stretch the picture to fill a
band - a stretched desktop is a worse lie than a letterboxed one, and the aspect is the one thing the wall knows for
certain.

The cells under a picture still have to be cleared first: the placeholder box and any older placement live in the same
cells. `WallCanvas`'s `.picture` branch writes spaces over the picture's rect (spaces only, no visible glyph, so the
"no text under a placement" rule still holds) before the picture is emitted.

Why a window's aspect must not reshape its card: **the layout being fixed** is the whole value of this screen - if
cards resized to their windows, the second click would miss.

Give up a panel rather than show an 8-cell-wide thumbnail. One at a time plus scrolling is the only arrangement
where "each one is legible" and "the cost is bounded" are both true.

## 6.7 The picture is centred (the mirror)

**The block is centred in the space it was given, not pinned to the corner.** A window whose own pixels are fewer
than the pane's (a 98×111 panel in a 137×44 pane), or a display taller than the pane's aspect, used to leave all the
slack on the right and bottom. That reads as a rendering bug, not as a margin: the eye checks the frame first, and one
sided slack fails the check ("不管是窗口还是桌面，这里应该需要居中").

| | |
|---|---|
| the area | the pane, minus the mirror's bar (1 row, §6.8), minus the `--dev` status line and panel rows. The picture is fitted into what is left (§6.6's rule) and centred inside it |
| a spare cell | an odd leftover row or column goes right/bottom, the way every layout rounds |
| the slack | stays the terminal's own background: the mirror never paints it, and the session's `ESC[2J` cleared it at the start. A resize clears again (`handleResize` → `writer.clear()`), so nothing stale can survive a shrink |
| the mouse | the same origin is subtracted in **both** directions: `Viewport.originCol/originRow` for SGR cells, `originPixelX/Y` for SGR-Pixels. Without it every click lands a few cells up and to the left of the pointer |
| the code | `TileGrid.make(area:)` → `originRow/originCol`, used by `rect()` (which is what a tile's placement is) and by `--full-frame`'s single image |

The wall is not affected: its panels are placed by `WallLayout` with their own rects, which is why the wall never had
this bug.

## 6.8 The mirror wears a bar

A mirror the **wall handed over** (`--wall-at`) gets one row of macOS window furniture at the top:

```
 ●  ●  ●   Terminal — admin — scroll.sh            18 fps  ·  1.8 MB/s  20:07:17  [ - ]
```

* reversed end to end, so it reads as furniture and not as picture;
* the title is the window's app and title, or `display 1 · 1440×2560`;
* `[ - ]` (and the traffic lights, which is what a red one does) **shrinks the window back into the wall**, on the
  page it was clicked from. It runs the same path as `Ctrl-\`: `shutdown()` → `exec` the wall with `--wall-at`;
* narrow panes drop the rate and then the clock; **the button is never dropped** — a bar without it is decoration
  pretending to be a control;
* on by default only for a handed-over mirror. `krd --window <q>` typed by hand stays bare (it never came from a
  shelf, and a status bar would be a new thing to explain); `--bar` / `--no-bar` overrides either way.

It is not the `--dev` line: that one is a measurement (`pipe 54 ms`) and lives at the bottom. Both can be on at once,
and the bar costs the picture exactly one row.

## 6.9 The picture is placed by cells, never by pixels

**The terminal fits the picture into the picture's cells.** The wall's pictures travel as kitty *unicode
placeholders* (`U=1`): a transmit (`a=t`, no placement), a virtual placement on the picture's own cell rectangle
(`a=p,U=1,c=…,r=…`), and a grid of invisible `U+10EEEE` cells - one per cell of the rectangle, with the image id in
the foreground colour and a combining diacritic on the first cell of each row, which is enough for the rest of the row
(the protocol lets a cell inherit "the cell to its left, column + 1").

Why this replaced the pixel-sized placement: a `c`/`r` placement plus an image asks the terminal to *scale*, and a
terminal may answer `CSI 16t` in points while drawing one image pixel per device pixel. Then a picture sized to its
box arrives at half the box's width, anchored top-left, and the rest of the identical box shows the terminal's
background - the report that produced this section (`外面是全宽了，桌面还是靠左`). With `U=1` the image is "fit to the
specified rectangle, its aspect ratio preserved" (kitty, §Unicode placeholders): the cell rectangle is the layout's
own, so nothing has to be estimated.

| | |
|---|---|
| the cells | `WallPanels`' `fit.cellRect` - the same rectangle `WallLayout` gave the picture, which is also the caption's parent cell (§6.6) |
| the pixels | **quality only.** With placeholders the capture is asked for at one reported pixel per cell (`--dpr` overrides); a big pane's full device resolution would blow a terminal's image budget, and a refused image used to read as "the picture is smaller" |
| the pixel path | `--no-placeholders`. There the image *must* be asked for in device pixels, so `PaneGeometry.dpr` is 2 when the terminal answered in points |
| the probe | once at startup: a 1×1 image transmitted with `q=2` (silent) and placed as a placeholder with `q=0`. `OK` → placeholders, `E…` or no answer → the pixel path. One log line says which, because a terminal that ignores `U=1` draws missing-glyph boxes over the picture's cells |
| one snapshot | `PaneGeometry` - grid, cell, dpr, source - is measured once at start and once per resize. The layout, every capture size and the mouse mapping all read *it*; nothing else may measure the terminal |
| the mirror too | the mirror's tiles travel the same way (`emitTileAsPlaceholder`): one transmit, one virtual placement on the tile's cells, one grid over them - so the interactive page and the preview are one channel, and `--scale` / `--quality` become what they always claimed to be, *sharpness*, instead of knobs that move the picture. Measured on the VM at 100x30, 2.6 s of the same stream: 113 tiles as placeholders = 704 KB against 96 tiles as placements = 612 KB - the grid costs ~2-4 % and only for the tiles that were dirty. `--bench` and `--selftest` keep the placement path, because their numbers are byte contracts |
| the frame is the cell box | the mirror's frame is `cols x cellW` by `rows x cellH` (times `--scale`), never the source's own pixel count. A terminal drawing one image pixel per device pixel cannot stretch a frame that is a few percent smaller into cells that are a few percent bigger: the shortfall comes back as a **seam at every tile row** - measured as nine black lines across a 118x38-cell display page, where a 1920x1200 frame sat under a 2006x1254 cell box (§TROUBLESHOOTING 23g). Each **tile's** rect is a cell box too, from the same arithmetic: a proportional slice of the frame is right only while the frame is exactly `cols x cellW`, and off by a rounding - or by the whole `--scale` - otherwise (issue #86). `make(fillsCells:)` is where the placeholder path asks for the box itself, so on a terminal that draws one image pixel per device pixel a placeholder frame can never be smaller than the cells it is drawn on; a terminal whose cell arrived in *points* scales the image into the box itself, and there `--scale` still takes pixels away (`--mock --placeholders --scale 0.8` on a 137x44 pane: `frame 877x550 px` under a 1096x688 box) |
| two transports, two rules on pixels | a **stream** request above the source's pixels comes back **upscaled** (1920x1200 display, 2006x1254 asked, 2006x1254 delivered, no dropped frames), so the mirror asks for the cells' pixels. A **screenshot** request above them comes back **padded with black**, so the wall caps its request at the source (`PanelCapture.fitted`) and does exactly one upscale itself (`PanelRaster`). Do not carry one rule over to the other |
| `--scale` picks its own transport | a placeholder grid draws one image pixel per device pixel, so it cannot stretch a *smaller* frame back into the picture's cells; a **pixel placement** (`a=p` with `c`/`r`) is scaled by the terminal, which is what `--scale` always assumed. So a pinned `--scale < 1` on a terminal whose cell arrived in device pixels switches to pixel placements and says so in one log line. Measured at 0.8 on Rex: the placeholder path drew the picture as 15x10 tiles each at 80 % of its slot - 14 vertical seams and 9 horizontal ones ("画面被割裂") - while the pixel path filled the same cells, softer, at 30 KB/s against 111 KB/s at full scale. `--scale auto` never steps down while placeholders are on: the governors spend frame rate and colour there, not resolution. A frame that survives as placeholders on a terminal that draws one image pixel per device pixel is therefore never smaller than its cells: there `--placeholders --scale 0.8` keeps the cell box and says in the log that the scale was not applied. On a points-cell terminal the scale is kept and is real - 877x550 px of a 1096x688 box |

`--demo` draws a test pattern instead of the desk (`DemoPicture`): no window server, no grant, a fixed
model, and the footer prints the measurement. It exists because every bug above was invisible in code and
obvious on a screen that needed a VM and a human - the pattern's own border is the measurement
(TROUBLESHOOTING 23f).

The geometry has exactly one direction: **cells → pixels**. The old code fitted in pixels, rounded to cells, then
derived pixels again (`originX/originY`, `pixelWidth/Height`, a per-tick `ioctl`, a mutable fallback cell); the two
roundings could disagree, and every "the box is right but the picture is not" report was one of those disagreements.

## 7. Entering is today's code path

`focus(window)` is today's `--window` (pid-targeted injection, alive-window fallback, backdrop refusal);
`focus(display)` is today's default. A session started with `--window` / `--display` must stay byte-identical.

## 8. Code seams

1. **`WindowOrder`** (pure): `[CGWindowList dictionaries] → [windows]`, filter + order. Testable directly with
   a dictionary fixture — put that `Gesture Blocking Overlay` pair into the test.
2. **`WallLayout`** (pure): `(pane, displays, windows, per, start) → [rows, picture rects, caption rects, hit
   map]`. The rects answer both "where the picture goes" and "where the text goes" — which is why masks and
   future versions cannot break the layout.
3. **`PanelDriver`**: ticks for the visible panels (main 2 s / other displays 5 s / windows 3 s, staggered), a
   cached last frame per panel, per-panel dedupe, an overall capture budget.
4. **`ScreenWriter`**: panels are placements, captions and headers are text; **text is never written over a cell
   a placement covers** (the rule lives at `Chrome.swift:9-10`, enforced structurally by drawing only rows
   `>= chromeTop` — there is no runtime assertion).
5. **Mouse already exists** (recon result, contrary to this document's earlier assumption): the SGR 1006 parse is
   `krdcore/Input.swift:176-243`, the cell-vs-pixel decision `krd/Input.swift:256-281`, `onChromeClick(cy, cx)`
   already delivers **1-based row/col**, and `Chrome.hitTest` is there (`Chrome.swift:206`). `?1002/?1003/?1006/?1016`
   are enabled today (`Render.swift:117-122`). **So the wall needs a policy, not a parser**: widen `hitTest`'s
   return from `ChromeHit` into the wall's `Action`.

   **The routing test is "inside the picture rect", not "inside the chrome area"**: `viewport.contains(cell:)` true
   → mapped and injected as a remote click (`Input.swift:282`, `Geometry.swift:64-75`); false → `onChromeClick` and
   a `return`, **never converted into a remote click** (`Input.swift:277-280`). That gives one hard constraint:
   **the picture must never cover the bar's column**, or clicking the bar becomes a click on the remote desktop.
   Conversely, when the picture is narrower than the pane, the leftover columns already land in the chrome branch,
   which is safe.

   **But today's `chromeClick` swallows clicks that hit no control** (`.outside` → `break`,
   `main.swift:1754-1755); the bar has to return real actions instead of inheriting that default. A wheel report
   over chrome takes the same branch (only `!motion` is checked), so the wall interprets it itself:
   **one notch = one display or one card** (`WallLayout.wheelAction(row:col:direction:)`), because a drag is a
   continuous gesture and a page per notch makes a trackpad flick jump from the first window to the last. The bar's
   `▲`/`▼` stay "one click, one page". A shelf with nothing to scroll returns `nil`, so the notch is swallowed by the
   wall instead of moving something else.
6. **`Desk`**: `wall / focus` plus the transition; `focus` uses today's `restartCapture`.

**The biggest seam is placement**: nothing today can put an image at an arbitrary cell rect. `TileGrid.rect`
hardwires the origin to `col = 1, row = 1` (`Tiles.swift:52-61`), ids derive from `tile.index`
(`Render.swift:282-283`), and `emitVariant` takes `row/col/cols/rows` but is diagnostic only (`f=32`, flushes
itself, no id policy). The wall needs exactly that one new path - *rect + stable id + batched send* - and it is the
bulk of P2.

**The capture side is harder than assumed (recon):**

- There is **no one-shot capture anywhere** (`SCScreenshotManager` / `CGWindowListCreateImage`: zero hits); it is
  100% `SCStream`, and **one session owns one `Capturer` and one stream** (`Capture.swift:9-12,60-63`).
- Scaling happens inside SCK (`config.width/height` can just be the card's pixel size, `Capture.swift:51-52`); krd
  has no scaler of its own (`vImageScale`/`CGContext`/`CGImage`: zero hits, the only transform is one BGRA→RGB
  channel flip, `Capture.swift:140-161`). So "capture at the card's pixel size" is free - provided a second stream
  can exist.
- `handleFrame` **accepts exactly one size** and drops anything else (`main.swift:1349-1356`). The wall's four
  panels differ in size, so today's single-stream path cannot be reused as is.
- A dead stream is only reported and retried five times **with the stale filter** (`Capture.swift:66-70`,
  `main.swift:929-953,1271-1287`), and there is **no window→display fallback** (`reconcileCaptureTarget` runs only
  on display changes). → when a window closes, that panel draws a **mask**; §4's fallback finally has a real
  reason.

Restart-path facts already hit once (do not relearn them):

- `handleResize` / `restartCapture` are no-ops while `filter == nil` (`main.swift:1429`, `1272`);
- a transition may call `handleResize` **or** `restartCapture`, never both — the second lands in
  `restartPending` (`main.swift:1273`, `1291`);
- `makeCaptureTarget` needs a new `windowID:` parameter (`options` is `let`);
- `TileGrid.make` cannot express 0 rows (`Tiles.swift:39-40`) and traps on `aspect == 0` (`:34`).

## 9. Bandwidth (measured with this repo's bench)

`.build/release/krd --bench --json`, 2329×1452 px (3.38 MP), wire bytes including base64:

| content | per MP | the landing screen (stage 0.81 + 3 × 0.06 = 0.99 MP) |
|---|---|---|
| UI (flat, text) | 28.6 KB | ≈ 28 KB |
| gradient wallpaper | 92 KB | ≈ 91 KB |
| photo / video | 3.83 MB | ≈ 3.8 MB |

- Entry ≈ **28 KB**, four captures (five when a shelf shows four cards); more displays or more windows do not
  change it. After that each tick re-captures only what changed (≈2–4 KB).
- When nothing moves, **per-panel dedupe → 0 B/s**. That zero holds for the **text layer** only: the mirror frame
  path still emits `nudge` (6 B) plus the sync wrapper (16 B) even with no dirty tiles. The wall ticks panels
  instead of streaming frames, so it avoids that entirely.
- Scrolling one step captures only the 1–3 newly revealed panels (a display switch captures the whole stage);
  the rest are re-emitted from cache, not re-captured.
- For scale: a full-screen 20 fps mirror is ≈1.9 MB/s of UI content, ≈259 MB/s of photo content.

## 10. Fallbacks

- **No Screen Recording** → captions lose their title, but order and sizes are unaffected; entering produces the
  permission error at `main.swift:506`.
- **One panel fails to capture** → that panel draws a mask, the layout does not move, clicking retries.
- **No windows** → `▣ recent    no windows`; the display strip remains.
- **Pane too short for a card band** → no card is drawn at all, so the band header says
  `▣ recent    no room` in place of the range (a range would name cards the pane does not draw) and draws
  no `⤢`.
- **Tiny pane** → the row width drops 3 → 2 (and to 1 on the narrowest panes) as the pane narrows; below
  two honoured widths the `⤢` is gone as well (there is nowhere to cycle to), a two-digit row width is never
  drawn, and the bar's own arrows are what scrolls.
- **`--mock`** → a fixed fake window list, `MockCanvas` still frames (`Mock.swift:157`), no screen and no
  permission needed; `KRD_DUMP` captures the bytes.

## 11. Tests

1. `WindowOrder`: a realistically shaped fixture (the `Gesture Blocking Overlay` pair, layer-0 system windows, a
   window without a title, a 100×100 helper window) → assert the filter and the order.
2. `WallLayout`: mask and picture share one rect, whole cells, width clamping, `1–3 / 7` and page count, a
   partial last page, never the last cell of the last row.
3. Symbol width: both `emoji` and `ascii`, a width assertion per symbol, and both modes laying out identical
   columns.
4. Hit map: card / caption / arrows / `⤢` / back row each map to their action; everything is `nil` in `focus`.
5. `--window` / `--display` with `KRD_DUMP` stays byte-identical to today. Two golden fixtures already exist
   (`Fixtures/selftest-80x24-17x33-l6.dump`, `Fixtures/input-trace.dump`); the wall's text layer should become the
   third — regenerate with `KRD_UPDATE_FIXTURE` and **never with `--filter`** (Swift 5.10 silently runs 0 tests).
6. `--mock` snapshots at 137×44 and 60×24, plus one real `ssh -t` run.

## 12. Phases

- **P0 done (measured 2026-10-30 in the tart VM `kraal-agent`)** — all three have answers:
  1. **one-shot capture exists and is fast**: `SCScreenshotManager.captureImage`, display 1920×1200 →
     **25.9 ms**, windows 877×499 → **19.4 ms**, 702×679 → **28.7 ms**, 360×180 → **18.3 ms**;
     **a whole wall's four panels = 92.4 ms**, once, not per frame. Five in a row do not degrade.
  2. **four concurrent `SCStream`s work**: one display + three windows in one process, 10 fps target,
     **23/23/22/22 frames** in 2.3 s - no stream starved, none stepped on the others. So "four small
     streams" is a real fallback, but the wall does not need it.
  3. **SCK scales, it never stretches**: a 1920×1200 display asked for 1200×300 returns 1200×300 with
     the content in **x∈[0,480)** (= 300×1.6) and pure black elsewhere, **anchored top-left**; asking
     for 400×250 (the same aspect) fills the box. So: **ask in the content's own aspect and SCK hands
     back 1:1 content**; black padding only appears when the aspects disagree.
  **Verdict: the wall takes four one-shot captures, no streams.** No frame loop, no dedupe, no stream
  lifecycle: when the 1 s tick sees the model change, capture (~92 ms), compress, place. `Capture.swift`
  and its single-stream logic are untouched - P2 adds a parallel path, it does not rework the mirror.

- **P1** `WindowOrder` + `WallLayout` + the text layer (text cards and empty frames first, opt-in `--start wall`).
- **P2 done (2026-10-30)**: `PanelImage` (fit + transparent composite, pure and tested),
  `WallPanels` (the plan), `PanelCapture` (one-shot, typed failures), `WallPictures` (shoot → sample
  → compose), `Render.emitPanel` (the tile wire shape with caller-owned ids) and the canvas's three
  slot states (placeholder / picture / mask). Measured at 137×44: **4 pictures, 1.18 MB**, once; the
  mirror path's bytes and golden dumps are unchanged. No dedupe: the wall only repaints when the
  model changes, so a cache waits until CPU is actually the bottleneck.
- **P3 done (2026-10-30)**: every section open, the right bar (two segments, wheel = one item, bar = one
  page), the mouse hit map, one height per card row, a divider between the stage and the cards, a 3-cell gap.
- **P3b done (2026-10-30)**: clicking a picture turns this process *into* `krd --window <id>` (`execv`, not
  spawn), and `Ctrl-\` inside that mirror `exec`s the wall back, on the page it was left on.
  **Why not a child process** (the first attempt, which shipped for an hour): two live processes of one
  executable cannot both be ScreenCaptureKit clients — the newcomer's stream dies at once with `-3805`
  ("failed during stream due to application connection being interrupted"). Measured four ways on the dev
  Mac: the same child streams fine alone, fails while a wall runs, fails while that wall is `SIGSTOP`ped
  before it paints, and works again when the same binary is copied to another path and started there. What
  collides is the executable's identity with the window server, so the fix is to leave exactly one client.
  The price of `exec` is that nothing is left to wait for the mirror, so the shelf (`--wall-at <s>:<c>`) and
  a failed mirror's sentence (`--said <exit> <text>`) travel in argv — the only state that survives a
  replaced process — and the wall a reader returns to shows the reason in its footer instead of a silent
  gap. A stream that dies *before its first frame* exits at once with that sentence (it names a target that
  will never open) rather than spending five retries behind a frozen pane.
  A kitty placement also outlives the process that made it, so **every session starts by deleting every
  image in it** (`ScreenWriter.clear()`) - and a mirror on its way back *leaves* the alternate screen before
  the exec, because a terminal may keep pictures keyed to the screen they were placed on and go on drawing
  them after the delete has been answered (measured in Rex; Ghostty does not). Leaving costs one frame of
  the shell between the two modes and is the only thing that was observed to work: the wall then builds a
  fresh screen. Without this the mirror's last picture sat on top of the wall's cards, which the reader
  reports as "the resolution changed" (TROUBLESHOOTING 23d).
- **P4 done (2026-10-30)**: plain `krd` opens the wall. `--mirror` (or `--window <query>`, which asks for one
  window and so cannot mean the wall) takes the old default back; `wall` stays a symlink and `--wall` still
  parses, because scripts spell it. `--list`, `--selftest`, `--bench`, `--mock` keep their own paths - they are
  checked before the wall branch, and `--list` is the one that would otherwise have been swallowed.

## 13. What would change the answer

- Practice shows z order is far from "what I used last" (full-screen apps, several Spaces) → keep our own MRU
  ledger.
- Three is not enough; most of the time is spent scrolling → 4–5 per screen, or a compact index of the remaining
  windows under the cards.
- Five ticks a second become visible in CPU or battery → other displays and windows drop to 5–10 s, or stop
  ticking while unfocused.
- Maximum saving is wanted → the big panel falls back to a mask (same rect, so it toggles without moving).

## 14. Open questions

2. Default 3 per screen, or derive it from the pane (`cols / 40`)?
3. Without Screen Recording, is `kCGWindowName` absent or empty?
4. Which windows to filter: browser popovers, Electron helper windows, `Dock` / Control Centre.
5. The real cost of one `CGWindowList` call per second (expected microseconds).
6. With several displays, is MRU global or per display? (z order is naturally global.)
