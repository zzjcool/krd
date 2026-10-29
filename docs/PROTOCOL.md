# Protocol

English | [简体中文](PROTOCOL.zh-CN.md)

Everything krd says to the terminal and everything it expects back. This is a *subset* of the
[kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) plus the DEC/xterm
modes needed for input; nothing here is krd-specific invention. Bytes below are literal unless
marked with `…` or `<>`.

Notation: `ESC` = `0x1B`, `CSI` = `ESC [`, `APC` = `ESC _`, `ST` = `ESC \`. A kitty graphics
command is `APC G <key=value,…> ; <payload> ST`; the payload is base64 and may be split across
several APC commands.

## 1. Session frame

```
                                     # start of session (ScreenWriter.beginSession)
ESC \                                #   ST: close an APC a killed predecessor left open
ESC [ ? 2026 l                       #   close a dangling synchronized-update block
ESC [ ? 1003 l  ESC [ ? 1002 l  ESC [ ? 1006 l   #   mouse reporting off (in case it was left on)
ESC [ 0 m                            #   SGR reset
ESC [ ? 25 h                         #   cursor visible during setup
ESC [ ? 1049 h                       #   alternate screen (no scrollback, wheel events come to us)
ESC [ 2 J  ESC [ H                   #   clear + home
ESC [ ? 25 l                         #   hide cursor for the whole session

                                     # once stdin is known to be a tty (InputReader.start)
ESC [ ? 1003 h                       #   any-motion tracking: report motion even without a button
ESC [ ? 1002 h                       #   button-event tracking: press / drag / release
ESC [ ? 1006 h                       #   SGR encoding (unbounded coordinates)
ESC [ ? 1016 h                       #   SGR *pixels*: coordinates in device pixels, not cells
```

The first six escapes are the *heal* sequence: a pane whose parser is waiting for an `ST` shows
nothing at all (not even text) until it gets one, which is what a `kill -9` mid-`write()` leaves
behind. Re-running krd fixes such a pane automatically; by hand it is
`printf '\033\\\033[?2026l\033[?25h'`.

## 2. One tile

A tile is emitted with its own synchronized-update block and flushed on its own
(`ScreenWriter.emitTile`), so a terminal can never show a half-transferred tile:

```
ESC [ ? 2026 h                                        # begin synchronized update
ESC [ <row> ; <col> H                                 # CUP to the tile's top-left cell
ESC _ G f=32,s=<w>,v=<h>,a=t,o=z,q=<Q>,i=<iid>,m=1;<base64 chunk> ESC \
ESC _ G m=1;<base64 chunk> ESC \                      # … repeated, 4096 chars per chunk
ESC _ G m=0;<base64 chunk> ESC \                      # last chunk
ESC _ G i=<iid>,p=<pid>,a=p,q=<Q>,C=1,c=<cols>,r=<rows> ESC \
ESC [ ? 2026 l                                        # commit
```

Field by field:

| Field | Value in krd | Why |
|---|---|---|
| `f=32` | RGBA, 8 bits per channel | `Capture` already produces RGBA; no palette, no PNG |
| `s=<w>`, `v=<h>` | tile size in pixels | the tile's own rect, not the frame's |
| `a=t` | transmit only | placement is a separate command, see below |
| `o=z` | zlib-compressed payload | RFC **1950** stream (see §6.1) |
| `q=<Q>` | `2` normally | `0` = replies on, `1` = errors only, `2` = silent |
| `i=<iid>` | `100 + tileIndex` | fixed per tile for the whole session |
| `m=1` / `m=0` | more chunks / last chunk | continuation APC commands carry only `m=…;` |
| `p=<pid>` | `1000 + tileIndex` | placement id, also fixed |
| `a=p` | place | `C=1`, `c`, `r` describe the cell footprint |
| `C=1` | do not move the cursor | see §6.2 |
| `c=<cols>`, `r=<rows>` | footprint in cells | always whole cells; edge tiles are smaller |

A concrete first tile of the 137×44-cell layout (tile 0 of 9×6, 272×264 px, 16×8 cells):

```
ESC[?2026h
ESC[1;1H
ESC_Gf=32,s=272,v=264,a=t,o=z,q=2,i=100,m=1,<4096 base64 chars>ESC\
ESC_Gm=0,<remaining base64 chars>ESC\
ESC_Gi=100,p=1000,a=p,q=2,C=1,c=16,r=8ESC\
ESC[?2026l
```

`KRD_NOSYNC=1` removes the two `?2026` escapes (for terminals whose synchronized-update support
misbehaves with image placements).

## 3. Full-frame path (`--full-frame`)

One synchronized block for the whole frame, one image id (`2`) and one placement id (`2`):

```
ESC [ ? 2026 h
ESC [ 1 ; 1 H
ESC _ G f=32,s=<W>,v=<H>,a=t,o=z,q=<Q>,i=2,m=1;<chunk> ESC \
ESC _ G m=…;<chunk> ESC \        (repeated)
ESC _ G i=2,p=2,a=p,q=<Q>,C=1,c=<cols>,r=<rows> ESC \
ESC [ ? 2026 l
```

Same id-reuse rule as tiles: the previous frame is overwritten, never deleted. This path exists to
A/B the tiling against the naive version, and as a fallback if tiling ever produces artifacts.

## 4. Steady state, clear, teardown

```
no dirty tile after a captured frame:            ESC [ ? 25 l
resize or explicit clear (ScreenWriter.clear):   ESC _ G a=d,d=a ESC \   then   ESC [ 2 J
end of session (ScreenWriter.endSession):
    ESC \                                        # terminate a half-written APC first
    ESC [ ? 2026 l
    ESC _ G a=d,d=a ESC \  ESC [ 2 J             # delete every placement, clear the screen
    ESC [ ? 1003 l  ESC [ ? 1002 l  ESC [ ? 1006 l
    ESC [ ? 25 h
    ESC [ ? 1049 l                               # leave the alternate screen
```

`a=d,d=a` (delete all placements) is sent **only** at those two points, never between frames.

## 5. What krd deliberately never sends

| Not sent | Why |
|---|---|
| `a=d` per tile | terminals disagree on its scope; an id-scoped delete is a black screen on those that treat it as "drop everything" (§6.3) |
| two alternating image ids per tile | two images would then own the same cells and the stale one shows through |
| `z=` (z-index), `x`/`y`/`X`/`Y` (offsets), `t=f`/`t=t`/`t=s` (file mediums) | whole-cell `c`/`r` placement needs none of them, and file mediums do not work over SSH |
| `f=100` (PNG), `f=24` (RGB) | RGBA + zlib is cheaper in CPU than PNG, and PNG requires a second encoder |
| `a=T` (transmit and display) | it bakes the placement into the transmit command; a per-tile `a=t` + `a=p` pair is what allows fixed ids |
| unicode placeholders, `a=f` animation frames, `a=q` capability query | not used by the renderer; `a=q`/`a=f` were only probed during the feasibility study |

## 6. Why these choices

### 6.1 `o=z` needs RFC 1950 zlib, not raw DEFLATE

Apple's `COMPRESSION_ZLIB` emits a *raw* DEFLATE stream — no 2-byte zlib header, no Adler-32
trailer. A terminal that expects RFC 1950 replies
`EINVAL: decompression failed` (visible only with `KRD_Q=0`) and draws nothing: a black pane with
no other symptom. krd therefore calls the system `libz` directly:
`compress2(dst, &len, src, srclen, 5)` (`CZlib` module, level 5 fixed).

### 6.2 `C=1` on every placement

Without it, placing an image moves the cursor — in some terminals past the image, i.e. onto or
past the last row of the pane. Either the next `CUP` fights a cursor that the terminal has already
moved, or writing at the bottom row scrolls the grid, and since every tile is positioned by
absolute coordinates a scroll shifts the whole picture. `C=1` ("do not move the cursor") removes
the entire class of bug.

### 6.3 Fixed ids, no deletes

`iid = 100 + tileIndex`, `pid = 1000 + tileIndex`, both fixed for the session. Every frame
transmits into the same image and re-places it at the same cells, so the previous placement is
overwritten in place. Consequences:

- Nothing has to be deleted, so no terminal's delete semantics can hurt us. Both Herdr and rex
  treat `a=d,i=<id>` as "drop the whole image set"; a `delete`-then-`place` scheme also flashes
  black for one frame on terminals that do it literally.
- The placement set is bounded by the tile grid (54 entries in the measured layout), so nothing
  accumulates — `ScreenWriter.reapInterval` (periodic delete-all + repaint) is compiled to `0` and
  the path is dead code today.
- If a terminal ever ignores placement replacement, the symptom is a stale tile, not a black
  screen, which is much easier to diagnose.

### 6.4 One `?2026` block per tile

DEC synchronized update (`?2026h … ?2026l`) tells the terminal "do not repaint until I say so".
Wrapping each tile (rather than a whole frame) keeps the atomic unit small: the terminal sees
either the old placement or the new one, never a partially transferred image, and an interrupted
write cannot freeze a multi-tile frame in a half-applied state. Cost: two escapes per tile.

### 6.5 The `?25l` nudge

Some terminals commit a placement only on the next output cycle. krd emits `ESC[?25l` when a
captured frame produced **no** dirty tiles, so the pipe keeps moving (and the cursor stays hidden).
A completely static desktop emits nothing at all: the capture side drops byte-identical frames
before the renderer sees them.

## 7. Input: what the terminal sends

Mouse reporting is enabled only when stdin is a tty (`isatty(STDIN_FILENO) == 1`; otherwise krd
logs `krd: input DISABLED …` and leaves the mouse modes off, so the terminal does not dump
reports onto the picture).

| Mode | Meaning | What krd uses it for |
|---|---|---|
| `?1003h` | any-motion tracking | pointer movement without a button → `mouseMoved` (hover, cursor following) |
| `?1002h` | button-event tracking | press, release, **and motion while a button is down** (dragging) |
| `?1006h` | SGR encoding | `<Cb;Cx;CyM` / `…m` instead of the 8-bit legacy encoding |
| `?1016h` | SGR-Pixels (kitty extension) | coordinates in device pixels instead of cells |

Reports arrive as `ESC [ < Cb;Cx;Cy M` (press/motion) and `ESC [ < Cb;Cx;Cy m` (release),
1-based. `Cb` bits:

| Bits | Meaning |
|---|---|
| `& 3` | button: 0 left → `leftMouseDown/Up/Dragged`, 1 middle → `otherMouse*`, 2 right → `rightMouse*`. In a **motion** report `3` means "no button held" and becomes `mouseMoved` |
| `& 32` | motion (drag) |
| `& 64` | wheel; `& 3` = 0 up, 1 down, 2 left, 3 right; vertical is sent as +1/−1 line, horizontal as `wheel2` |
| `& 4`, `& 8`, `& 16` | shift / alt / ctrl held → `maskShift` / `maskAlternate` / `maskControl` on the injected event |

Every injected mouse event sets `flags` explicitly (from the bits above, empty for a plain click).
Do not let it default: `CGEvent(mouseEventSource: nil, …)` inherits the *session's* modifier state,
and `postKey()` posts `.maskControl` on Ctrl combinations, so a stale Control would turn every later
click into a Control-click — macOS shows that as a right click, and nothing drags.

### 7.1 Cell vs pixel coordinates, and the downgrade rule

A cell coordinate can never exceed the terminal's grid, so:

```
if Cx > cols || Cy > rows  →  the terminal is talking pixels  →  latch pixelMouse = true (sticky)
```

`cols`/`rows` come from `TermGeometry.lastGrid` (whatever `read()` or `query()` measured last).
Once latched, all subsequent reports are treated as pixels, even a small report from the top-left
corner. Terminals that ignore `?1016h` never trip the condition and stay on the cell mapping — so
both kinds of terminal work, and neither needs a handshake.

Mapping to screen points (`Viewport`, `sourceRect` = the captured display's `CGDisplayBounds` or the
window's frame, in global points):

```
cell  (Cx,Cy):  fx = (Cx - 0.5) / cols        fy = (Cy - 0.5) / rows      → cell centre
pixel (Px,Py):  fx = clamp(Px / pixelW, 0, 1) fy = clamp(Py / pixelH, 0, 1)
point        =  (sourceRect.minX + fx * sourceRect.width,
                 sourceRect.minY + fy * sourceRect.height)
```

Events outside the placement are dropped (`contains(cell:)` = 1…cols / 1…rows,
`contains(pixel:)` = 0…pixelWidth). This works because the picture always starts at cell (1,1) of
the pane on the alternate screen — pixel coordinates are relative to that origin.

### 7.2 Keys

| Input | Handling |
|---|---|
| `ESC [ A/B/C/D` | up / down / right / left (`Keys.up` … `Keys.left`) |
| `ESC [ H` / `ESC [ F` | Home / End |
| `ESC [ Z` | Shift-Tab |
| `ESC [ 1;…` | modifier bits: `n-1` & 1 shift, & 2 alt, & 4 ctrl, & 8 cmd |
| `ESC [ <code> ~` | 1,2,7 → Home; 3 → forward delete; 4,8 → End; 5/6 → page up/down; 11–14 → F1–F4; 15 → F5; 17–21 → F6–F10; 23,24 → F11,F12 (**currently reads past the end of the F-key table and traps — see [TROUBLESHOOTING](TROUBLESHOOTING.md#22-pressing-f11-or-f12-kills-the-process)**) |
| `ESC O A–D / H / F / P–S` | SS3 arrows, Home/End, F1–F4 |
| `0x00` | Ctrl-Space |
| `0x01`–`0x1A` | Ctrl-A … Ctrl-Z (with `maskControl`) |
| `0x1C` | **quit** (not forwarded) |
| `0x7F`, `0x08` | Backspace |
| `0x09`, `0x0A`, `0x0D` | Tab, Return |
| lone `ESC` | Esc — the reader waits 100 ms (`poll` timeout) with exactly one byte buffered |
| `ESC` + char | Alt-`char` |
| printable ASCII | US/ANSI virtual keycode from `Keys.map`; shifted symbols (`!@#$…`) press the base key with `maskShift`; uppercase likewise |
| anything else | a `CGEvent` with `virtualKey 0` and the character set via `keyboardSetUnicodeString` |

There is **no kitty keyboard protocol** handshake (`CSI > 9 u`), so modifiers alone, key release
and Cmd combinations never arrive. Alt+key does, as `ESC`+key.

## 8. Replies

With `q=2` every reply is suppressed, including errors — a black pane then has no explanation
anywhere. `KRD_Q=0` turns replies on:

```
APC G i=<iid>;OK ST                     # success
APC G i=<iid>;<ERRNO>:<text> ST         # e.g. EINVAL: decompression failed, ENOENT: ...
```

krd never parses replies. They arrive on stdin, and since stdin is in raw mode and being parsed as
input, a reply will be interpreted as keystrokes (starting with Alt-`G`) and typed into the
captured desktop. **Use `KRD_Q=0` together with `--no-input`**, or read `KRD_DUMP` offline instead.

## 9. References

- kitty graphics protocol: <https://sw.kovidgoyal.net/kitty/graphics-protocol/>
- kitty keyboard protocol (not implemented): <https://sw.kovidgoyal.net/kitty/keyboard-protocol/>
- xterm mouse tracking (`1000`/`1002`/`1003`/`1006`): `ctlseqs` in the xterm sources;
  `1016` is the kitty pixel-coordinate extension of `1006`
- DEC private mode `2026` (synchronized output): <https://gist.github.com/christianparpart/d8a62cc1ab659194337d73e399004036>
