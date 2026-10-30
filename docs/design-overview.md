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
- **Bottom:** the three most recently used windows, same bar, with `⤢` switching 2 / 3 / 4 per screen.
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
- So the capture count is 1 display + 3 visible windows = **four**, ≈28 KB - and it stays four whether there are
  20 windows or 5 displays.

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
- Because only three windows are on screen, "everything open" is bounded **by the layout itself** — no need to
  save resources by drawing nothing.

## 5. Interaction

| input | action |
|---|---|
| click a window card (or its caption) | enter that window (single-window mirror, 20 fps) |
| click the display on the stage | mirror the whole screen |
| click `▲` / `▼` in the upper segment | previous / next display |
| click `▲` / `▼` in the lower segment | previous / next group of windows (one screenful) |
| click a `│` in the middle | jump proportionally (the `█` thumb shows where you are) |
| click `⤢` | cycle 2 → 3 → 4 windows per screen |
| click `⬅ 🖥 back` | return to the landing screen |
| any key | forwarded to the remote desktop |

An end with nothing further is dimmed and inert - no dead cells that swallow clicks.

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
row → cards (`cardH + 1` caption) → one blank row → footer 1 row.

The divider came out of review: without it the stage caption, the band header and the tops of the
cards arrive as three dense rows in a row ("too crowded"). One dim rule is cheaper than a blank row -
it says where a section ends, which a blank row does not. It is also the first thing dropped: below
20 rows there is no divider (`dividerRow` is empty) because in a pane that short a row of rule is
worth less than a row of picture.

- Content width `content = cols - 2` (bar plus padding); `winW = floor((content - (per-1)) / per)` -
  137 columns / 3 → 43 cells, and the card's height follows from its width at a 1.62 aspect (→ 13 rows).
- Between two cards: `cardGap = max(1, content / 45)` cells - 3 at 137 columns, 1 on a 60-column pane. One
  cell was the first version and read as the cards touching; the gap scales with the width because air on a
  narrow pane is paid for with a card (`per` drops from 4 to 3 at 60 columns if the gap is 3). At 137 columns
  the 3-cell gap costs the cards one row (44×14 → 43×13) and gives it to the stage, which grows 23 → 24.
- The stage takes the remaining rows: `mainH = rows - (5 or 6) - winRows - 1` (6 when there is a
  divider). At 137x44 that is **stage 23 + cards 14** - one row of picture less than before the rule.
- Whole-cell placement only; never the last cell of the last row (autowrap pushes the whole picture up).
- Every truncation and pad goes through `DisplayWidth` (CJK and emoji are wide). `⤢ ▣ ▲ ▼` are
  East-Asian-Ambiguous, so `--symbols ascii` (`> w ^ v < . '`) exists and both modes must lay out the same
  columns.
- **Measured correction:** `🖥` (U+1F5A5, no VS16) is **1 cell** in `TextWidth.swift`'s table, not 2 - it has no
  default emoji presentation and terminals generally draw it narrow. The earlier revision called it wide; that
  was wrong.

## 6.6 How a display and a window fit their cells

**Fit, always: keep the aspect, never crop, never stretch.** The picture shrinks to the largest size that fits its
cells and **the cells left over stay transparent** (`f=32`, alpha 0), so the wall's own background shows through: a
card reads as a window lying on the wall, not a window in a frame.

| case | handling |
|---|---|
| landscape (16:10 / 1.54) | the height fills the stage's rows and the width is ~72 cells centred (137×44 at 17×33 cells); ~30 cells of transparency on each side |
| portrait (1200×1920) | still height-bound, the picture is simply narrow (~29 cells), centred |
| window card | the card rect **never changes** (43×13 cells at 137×44); the picture fits inside at the window's own aspect, the rest is transparent |
| rounded corners | every picture's own corners are cut to a radius of **one twenty-fourth of its short side** (`PanelImage.cornerRadius`), and the pixels outside the arc keep alpha 0 - so a display or a window reads as an object lying on the wall instead of a rectangle cut out of it. macOS rounds its windows anyway, so the card pictures lose nothing; the stage is where it shows |
| one height per row | the cards of a page are drawn at **one height** - the tallest one every picture can reach without cropping, i.e. the widest window's (`WallPanels.sharedCardHeight`, then `PanelImage.fit(maxHeight:)`). Per-window fitting left a 16:9 card shorter than a square one, so the row's top and bottom edges disagreed ("窗口的最高高度需要保持一致"). The cost is that one wide window shortens its neighbours while it is on the page; the alternative would be cropping, which the design rules out |
| the maths | `pixelAspect = w/h`; `availW = cols×cellW`, `availH = rows×cellH`; if `availW/availH > aspect` then `w = availH×aspect/cellW`, else `h = availW/aspect/cellH`; then centre |
| order | the menu-bar display first (`kCGDisplayIsMain`), then by `bounds.origin.x`, left to right |
| capture | **only the one on stage**: three displays + three windows = 4 panels, the same cost as a single display |

Why not cover: cover throws content away, and the display's own shape *is* information - no menu bar, no Dock, and the
reader cannot tell which display they are looking at. Fitting costs only the bars, and transparent bars cost nothing in
meaning: they are not decoration on the wall, they *are* the wall.

Why not a colour: two versions tried. Black read as a frame around every picture; then "the picture's own edge colour",
which was technically defensible but still a guess at a background the terminal already has - a light window got a light
bar on a dark wall, a bright stripe. Transparency lets the wall answer that question itself, and it follows the
terminal's theme for free.

The cost: one alpha channel per panel, 1.18 MB → 1.28 MB for a whole wall (+8%, the cleared area compresses well), and
the terminal has to blend `f=32` alpha (kitty, Ghostty and WezTerm do). A terminal that ignores alpha shows those cells
black, i.e. the first version.

Transparency has one thing that has to be right: **the cells under a picture must be cleared first**. Whatever is
transparent shows what is underneath, so a placeholder box or an older picture left in those cells would show through
the bars. `WallCanvas`'s `.picture` branch now writes spaces over the whole rect (spaces only, no visible glyph, so the
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
- **No windows** → `▣ recent   no windows`; the display strip remains.
- **Tiny pane** → 3 → 2 → 1 per screen; smaller still hides `⤢` and the position counter, leaving `◀ ▶`.
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
