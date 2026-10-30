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
│        main display: one panel filling the stage        │   │
│                                                        │   │
└────────────────────────────────────────────────────────┘   ▼
🖥 Built-in — 1512×982 · main · 1/3                          ╵
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

- A readable card needs 24–44 cells; three fit a 137-cell pane exactly, four start truncating captions.
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

Top to bottom: header 1 row → stage (`stageH + 1` caption) → card band header 1 row → cards
(`cardH + 1` caption) → one blank row → footer 1 row.

- Content width `content = cols - 2` (bar plus padding); `winW = floor((content - (per-1)) / per)` -
  137 columns / 3 → 44 cells, and the card's height follows from its width at a 1.62 aspect (→ 14 rows).
- The stage takes the remaining rows: `mainH = rows - 4 - winRows - 1 - 1`.
- Whole-cell placement only; never the last cell of the last row (autowrap pushes the whole picture up).
- Every truncation and pad goes through `DisplayWidth` (CJK and emoji are wide). `⤢ ▣ ▲ ▼` are
  East-Asian-Ambiguous, so `--symbols ascii` (`> w ^ v < . '`) exists and both modes must lay out the same
  columns.
- **Measured correction:** `🖥` (U+1F5A5, no VS16) is **1 cell** in `TextWidth.swift`'s table, not 2 - it has no
  default emoji presentation and terminals generally draw it narrow. The earlier revision called it wide; that
  was wrong.

## 6.6 How a display fills the stage

| case | handling |
|---|---|
| landscape (16:9 / 16:10 / 1.54) | **fill the width, crop the bottom, anchor top** - 0.57 of the content survives and the menu bar always does |
| portrait (1200×1920) | filling the width would keep only 0.23 → **fill the height, centre horizontally**, black on both sides |
| the rule | `surviving fraction = display aspect / stage aspect`; crop only when `>= 0.5`, otherwise centre |
| order | the menu-bar display first (`kCGDisplayIsMain`), then by `bounds.origin.x`, left to right |
| capture | **only the one on stage**: three displays + three windows = 4 panels, the same cost as a single display |

Give up a panel rather than show an 8-cell-wide thumbnail. One at a time plus scrolling is the only arrangement
where "each one is legible" and "the cost is bounded" are both true.

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
   `main.swift:1754-1755); the bar has to return real actions instead of inheriting that default. Note also that a
   wheel report over chrome takes the same branch (only `!motion` is checked), so the bar must ignore wheel
   explicitly.
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

- **P0 measure three things** (the whole budget rests on them):
  1. `SCScreenshotManager.captureImage` one-shot latency, display vs window, and whether N calls in a row degrade;
  2. whether **N concurrent `SCStream`s are viable in one process** (today's `Capturer` is written as a
     single-stream object, and issue #44 records how fragile streams are);
  3. whether SCK scales or refuses when each stream is configured at a **different size** (the card's pixel size).
  The answer decides between "four small streams" and "one big stream plus CPU cropping".
- **P1** `WindowOrder` + `WallLayout` + the text layer (text cards and empty frames first, opt-in `--start wall`).
- **P2** single-panel capture → compress → cache → dedupe → mask fallback.
- **P3** everything open + scrolling + `⤢` + the mouse hit map.
- **P4** flip the default + docs (README both languages, ARCHITECTURE, TROUBLESHOOTING) + `bench/budget.json`.

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
