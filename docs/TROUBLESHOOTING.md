# Troubleshooting

English | [简体中文](TROUBLESHOOTING.zh-CN.md)

Every entry below is a failure this project actually hit, in the form **symptom → cause → fix**.
Section 1–4 are things that look like bugs in krd but are usually properties of the terminal or of
macOS; section 5 is how to establish facts when the screen is lying to you.

Quick orientation before you read on:

```bash
krd --selftest --no-input        # renderer works? (no permissions, no capture)
krd --list                       # Screen Recording granted? windows enumerable?
krd --debug                      # where the log is: "krd: logging to <path>"
KRD_Q=0 krd --no-input           # what is the terminal actually replying?
KRD_DUMP=/tmp/d.bin krd …        # every byte krd emits, for offline diffing
```

## 1. Protocol & terminal

### 1. Black pane, and `KRD_Q=0` reports `EINVAL: decompression failed`

**Cause.** `o=z` means RFC 1950 zlib: 2-byte header, deflate body, Adler-32 trailer. Apple's
`COMPRESSION_ZLIB` produces *raw* DEFLATE (no header, no checksum), which the terminal rejects —
and with `q=2` the error is invisible, so all you see is black.
**Fix.** Compress with the system libz: `compress2()` via the `CZlib` module, level 5
(`Render.swift`). Never `COMPRESSION_ZLIB` for this protocol.

### 1b. Black or garbled tiles on a terminal that used to work (0.1.2+)

**Cause.** Since 0.1.2 the wire format is `f=24` (RGB) instead of `f=32` (RGBA): the desktop is
opaque, so the alpha byte was dead weight (25 % of the payload). Every implementation that handles
`f=32` handles `f=24` — they differ only in bytes per pixel — but a terminal with a hand-rolled
RGB path can still get it wrong, and with `q=2` it fails silently.
**Fix.** `krd --format rgba` (or `KRD_FORMAT=rgba`) restores the old payload byte for byte. If that
fixes it, it is a terminal bug worth reporting upstream, not a krd bug.

### 2. Black pane and no error anywhere

**Cause.** `q=2` suppresses every protocol reply, including errors. This is the right default
(replies would otherwise arrive on stdin and be typed into the desktop), but it hides the reason
nothing was drawn.
**Fix.** Reproduce with `KRD_Q=0 krd --no-input` and read the replies (`OK` / `EINVAL: …` /
`ENOENT: …`). Do not use `KRD_Q=0` with input enabled.

### 3. A per-tile delete wipes the whole picture

**Cause.** Some terminals implement `a=d,i=<id>` as "drop the entire image set". Deleting the old
placement before placing the new one (the obvious scheme) turns the pane black, and on terminals
that do it literally it also flashes.
**Fix.** krd never deletes per tile: `iid = 100 + index` and `pid = 1000 + index` are fixed for the
session, so every frame overwrites the same placement. Only session teardown and an explicit
resize use `a=d,d=a`.

### 4. `a=d` inside a `?2026` block is even worse

**Cause.** Inside a synchronized-update block a delete can take out the whole batch the terminal is
holding, not just the image named.
**Fix.** If you ever need a delete, put it *outside* any `?2026h … ?2026l` block. krd only sends
`a=d,d=a` in `clear()`/`endSession()`, nowhere else.

### 5. A still picture never appears until something else prints

**Cause.** Some terminals commit a placement on the next output cycle. When nothing changes, krd
emits nothing, so the last placement may never be painted.
**Fix.** `ScreenWriter.nudge()` emits one `ESC[?25l` when a captured frame produced no dirty
tiles. (A truly static desktop emits nothing at all — that is intended, and means the previous
frame was committed by its own tile write.)

### 6. After a `kill -9`, the pane is dead: not even text shows up

**Cause.** The process died in the middle of an APC (`ESC _ G …`). The terminal's parser is waiting
for the `ST` terminator, so every later byte is swallowed — the session looks broken, not the app.
**Fix.** krd heals on start: `beginSession()` writes `ESC \` (closes the dangling APC) +
`ESC[?2026l` (closes a dangling sync block) + `?1003l ?1002l ?1006l ESC[0m ?25h` before switching
to the alternate screen. Manually: `printf '\033\\\033[?2026l\033[?25h'`. Avoid `kill -9`;
Ctrl-\\ or `kill` (SIGTERM) run the cleanup path.

### 7. Tiles land in the wrong place, or everything scrolls after a few frames

**Cause.** Missing `C=1`: placing an image moves the cursor, in some terminals onto/past the last
row, and a write at the bottom row scrolls the grid. Since every tile is positioned by absolute
`CUP`, a scroll shifts the whole picture.
**Fix.** `C=1` on every placement command (`ScreenWriter.emit`, `emitFullFrame`).

### 8. One tile keeps showing stale content

**Cause.** Rotating image ids per frame (an old scheme) leaves two images owning the same cells;
whichever the terminal considers "on top" may be the stale one.
**Fix.** One image id **and** one placement id per tile, reused forever (§3). If you see this on a
new terminal, it is that terminal's placement-replacement semantics; report it with
`KRD_QUADRANTS=1` output.

### 9. `?2026` breaks image placement on a particular terminal

**Cause.** Synchronized-update support is uneven; a terminal may defer, reorder or drop graph
commands issued inside a block.
**Fix.** `KRD_NOSYNC=1 krd` drops the per-tile wrapper (you lose per-tile atomicity, nothing else).
If that fixes it, the terminal's `?2026` handling is the bug — note it in the compatibility table.

## 2. Geometry & layout

### 10. Picture has the wrong aspect ratio, or is tiny in a big pane

**Cause.** `TIOCGWINSZ` returned `0` for `ws_xpixel`/`ws_ypixel` (typical for sshd-created ptys and
for panes that have not been laid out yet), so the cell size had to be guessed.
**Fix.** Three-level fallback: `CSI 16 t` + `CSI 14 t` query (250 ms) → `TIOCGWINSZ` on stdout,
stdin, `/dev/tty` → `--cell <w>x<h>` (default `8x20`). If your terminal answers neither query,
pass the real cell size explicitly, e.g. `--cell 17x33`.

### 11. Startup hangs: no output at all, process sits there

**Cause.** `c_cc[0]` and `c_cc[1]` are **`VEOF`/`VEOL` on macOS**, not `VMIN`/`VTIME`. Writing them
by index leaves the fd in blocking mode and the first `read()` never returns.
**Fix.** Use `p[Int(VMIN)]` / `p[Int(VTIME)]` (as `Geometry.query()` and `InputReader.start()` do),
or avoid blocking reads entirely — the input loop uses `poll()` with a 100 ms timeout.

### 12. Over SSH the pane is 80×24 and the picture is squashed

**Cause.** No tty on stdin: `sshd` allocates one only with `-t`, and without it geometry falls back
to 80×24 while input is disabled.
**Fix.** `ssh -t user@host ~/bin/krd …`. Always. (`ssh host krd` is the mistake; krd prints an
explicit warning about it.)

### 13. After resizing the window the picture is blurry or off-centre

**Cause.** The resize path re-measures with `TermGeometry.read()` only — no CSI query — so on a pty
that reports no pixel size it falls back to `--cell`, which may not match the new cell size.
**Fix.** Pass `--cell` for such terminals, or resize before relying on pixel precision. A
`SIGWINCH` still triggers re-layout, `writer.clear()` and a stream restart at the new size; the
layout is never left stale, only possibly under-informed.

## 3. Input

### 14. Keys and clicks do nothing, and the log says `input DISABLED`

**Cause.** stdin is not a tty (see 12). krd deliberately leaves mouse reporting off in that case,
otherwise the terminal's own reports would be echoed onto the picture as text.
**Fix.** `ssh -t`. Locally, run krd in a real terminal, not with stdin redirected from a file or a
pipe.

### 15. Clicks land one cell off / cannot hit small controls

**Cause.** The terminal ignores `?1016h` (SGR-Pixels) and keeps sending cell coordinates; one cell
is ~17×33 px, far too coarse for a 12-point button.
**Fix.** Nothing to fix in krd — it maps both coordinate systems correctly (see
[PROTOCOL](PROTOCOL.md#71-cell-vs-pixel-coordinates-and-the-downgrade-rule)). Switch to a terminal
that implements `?1016h` (rex, Ghostty, kitty) if you need pixel precision.

### 16. `--dry-run` garbles the picture

**Cause.** `--dry-run` only stops `CGEvent` posting; the trace still goes through `Log`, and without
`--debug`/`--log` the log handle is stderr — i.e. the pty, on top of the tiles.
**Fix.** `krd --dry-run --debug` (file log) or `--dry-run --log /tmp/krd.log`, then read the file.

### 17. Ctrl-C does not stop it

**Cause.** By design: Ctrl-C is forwarded to the remote desktop, exactly like a real keyboard.
Signals are disabled on the tty (`ISIG` off) so the byte reaches us.
**Fix.** Ctrl-\\ quits. Or `kill <pid>` from another session (SIGTERM/SIGHUP/SIGINT are handled and
run the cleanup).

### 18. A click turns into a right click and nothing drags

**Cause.** A stale Control modifier on the injected events. `postKey()` posts `.maskControl` on
Ctrl combinations (Ctrl-C, Ctrl-<letter>), and `CGEvent(mouseEventSource: nil, …)` inherits the
*session's* modifier state — so once any Ctrl combination has been sent, every following click is a
Control-click, which macOS renders as a right click (context menu) and refuses to drag.
**Fix.** (Fixed in 0.1.1.) `postMouse`/`postScroll` now set `event.flags` explicitly from the SGR
button code, so a plain click carries no modifiers. If you are on an older build: right-click and
drag are simply unusable after a Ctrl chord — restart krd and avoid Ctrl keys.

### 18b. Right-click / middle-click / double-click / modifier-clicks

**Cause.** Older builds only mapped button 0 and never set `clickState`.
**Fix.** (Since 0.1.1.) Button bits map to `leftMouse*` / `otherMouse*` (middle) / `rightMouse*`,
`clickState` is derived from "same spot within 0.5 s" (so double and triple click work), the
modifier bits `& 4`/`& 8`/`& 16` become Shift/Option/Control on the event, and horizontal wheel
(`& 64` with `& 3` = 2/3) goes out as `wheel2`. What still does not exist: drag-and-drop between
apps, force/pressure events, and any input method (see 19).

### 19. Typing Chinese/Japanese/Korean produces nothing useful

**Cause.** Two different things, and they need opposite fixes:

1. A character that arrives with no physical key is injected with `keyboardSetUnicodeString`
   (`virtualKey 0`). No keycode reaches the target, so the target's input method never sees a
   keystroke: no composition, no candidate window — and apps that read *keycodes* (Electron,
   Terminal.app, most custom text views) receive nothing at all.
2. A character only arrives *with* a key when your terminal reports one (the kitty protocol's
   alternate-key field) and that key exists on your local layout.

**Fix.** `--ime`:

| mode | behaviour |
|---|---|
| `auto` (default) | press the physical key when the terminal reported one, inject the character otherwise; the log says when it had to inject |
| `raw` | physical keys only — text with no key is **dropped**, so a composition never gets half-injected text in the middle of it (Korean jamo → syllable) |
| `unicode` | inject anything that is not plain ASCII: krd's old behaviour, and the right answer when you already composed the character locally |

For **IME input, turn the local input method off** and let the mirrored Mac's IME compose: the keys
then travel raw, the candidate window renders inside the mirrored picture (which you are already
looking at), and Space/arrows/numerals confirm and pick candidates. If the log says

    krd: this character has no key on the local layout, so krd injects it as text …

then your local IME composed it before it ever reached krd — that is the `auto` fallback, and
`--ime=raw` would have dropped it instead. `--ime=raw` on a terminal that does not answer the
keyboard-protocol handshake leaves only ASCII typable, which is the trade-off, not a bug.

### 20. With `--window`, clicks go to whatever is on top instead of the mirrored window

**Cause (fixed in #17).** `--window` used to filter the *capture* only: injection was a global
`CGEvent.post(tap: .cghidEventTap)`, so the window manager decided who got the click and a
half-covered window lost every one of them.

**Fix.** In window mode krd posts to the owning process with `CGEventPostToPid` — mouse, wheel and
keys alike — so a click reaches the mirrored window whatever is in front of it. The coordinates stay
screen points and come from the window's own frame, which is what the target app hit-tests with.

Two things worth knowing:

- If the app quits or the mirrored window closes, there is no pid to post to. krd says so once
  (`the mirrored window is gone (no pid) — falling back to global injection`) and the clicks go to
  whatever is in front again; restart with `--window <id>` to re-attach.
- `--debug` logs the pid actually used (`window mode — events go to pid 1234`, then
  `posting to pid 1234 (window mode)` and `pid 1234 <- 1 at 804,298`), so "where did that click go"
  is answerable instead of guesswork.

### 21. `KRD_Q=0` types garbage into the desktop

**Cause.** Protocol replies arrive on stdin, which is in raw mode and parsed as input; the first
byte sequence looks like Alt-`G` and the rest becomes text.
**Fix.** Only use `KRD_Q=0` with `--no-input`, or inspect `KRD_DUMP` offline.

### 22. Pressing F11 or F12 kills the process

**Cause.** (0.1.2 and earlier.) The `CSI 23~`/`CSI 24~` handlers indexed the F-key table with
`code - 11` — indices 12 and 13 of a 12-entry array. Swift traps on an out-of-range index and the
trap is not catchable, so neither `input.restore()` nor `writer.endSession()` ran: the pane stayed
in the alternate screen with raw mode on, which `reset` clears.
**Fix.** `ESC [ <n> ~` is now one `[Int: CGKeyCode]` table (`Keys.numbered`, `Input.swift`), with a
row for every code F1–F14 needs and no row for the holes in the numbering (16, 22), so an unknown
number is ignored and no subscript can run past the end. `ESC O P–S` is built from the same table,
so the two spellings of F1–F4 cannot disagree; the parser decision and the table are pinned in
`Tests/krdTests/InputTests.swift`.

## 4. ScreenCaptureKit & permissions

### 23. One frame, then the stream stops forever

**Cause.** `SCStreamConfiguration.queueDepth = 1` stalls the stream on this macOS generation: the
first frame is delivered, then no more callbacks arrive and nothing is logged.
**Fix.** `queueDepth = 3` (`Capture.swift`).

### 24. The stream dies silently

**Cause.** `SCStream(delegate: nil)` — the stream can stop without any notification path.
**Fix.** The capturer is the delegate and implements `stream(_:didStopWithError:)`, which logs
`capture stopped: <error>`. Check the log file before assuming the picture "just stopped".

### 25. ScreenCaptureKit delivers exactly one frame, then nothing (no error)

**Cause.** No `NSApplication` context. Verified on the tested macOS build: without an AppKit
context a stream yields one frame; with it, a full stream.
**Fix.** `main.swift` creates `NSApplication.shared` and `setActivationPolicy(.accessory)` before
anything else. `KRD_NO_NSAPP=1` reproduces the failure on purpose.

### 26. `-3801 user declined`, or the permission is gone after a rebuild

**Cause.** TCC records Screen Recording against the **code signature**. Ad-hoc signing
(`codesign -s -`) yields a new cdhash on every build, so the OS sees a different app and the old
grant no longer matches.
**Fix.** Install to a fixed path and sign with a stable identity — `install.sh` does that by
default (or `KRD_SIGN_IDENTITY="Apple Development: …" ./install.sh`). Keep the identifier `com.kkrt.macdesk`
frozen — changing it creates a new TCC record and requires a new approval.

### 26b. After an update the remote binary dies instantly: `Killed: 9`, exit 137, no output

**Cause.** The new binary was written **in place** over the old one (`cat > ~/bin/krd`, `cp krd
~/bin/krd`, or any script that does the same). Truncating a file reuses its inode, and AMFI keeps
the previous binary's dynamic code-signing validation result cached per vnode: the new bytes are
valid (`codesign -v` passes, and the same bytes run fine from `/tmp`) but the first exec is killed
by the kernel, silently.
**Fix.** Replace, never truncate: `rm ~/bin/krd` and copy again, or write `~/bin/krd.new` and
`mv` it into place. `deploy.sh` / `install.sh` do this since 0.1.2 — if you copied by hand, that is
the whole bug. Repro that tells the two apart without guessing:

```bash
cp ~/bin/krd /tmp/krd2 && /tmp/krd2 --version   # works  -> the file is fine
~/bin/krd --version                            # killed -> the inode is the problem
log show --last 1m --style compact --predicate 'senderImagePath CONTAINS "AMFI"' | grep krd
#   AMFI: '/private/tmp/krd2' is adhoc signed.
#   AMFI: code signature validation failed.
```

### 27. Clicks and keys are ignored, capture works

**Cause.** Accessibility (event injection) was never granted. `AXIsProcessTrusted()` is logged with
`--debug`; capture and injection are two separate TCC grants.
**Fix.** System Settings → Privacy & Security → Accessibility → add the installed binary (`+`);
or run krd once from the Mac's own GUI terminal so macOS can prompt.

### 28. `--list` prints nothing / errors out

**Cause.** `--list` enumerates through ScreenCaptureKit, so it needs Screen Recording too.
**Fix.** Treat `--list` as the first-run permission check: run it from the target Mac's own GUI
terminal, approve the prompt, verify it prints displays and windows.

### 29. The picture goes black while the Mac is locked or asleep

**Cause.** A locked session yields no screen content to ScreenCaptureKit; the stream keeps running
with black/empty frames.
**Fix.** Unlock the Mac. Do not unattended-restart krd expecting a picture while the session is
locked; screen sharing of a locked session is not a supported mode.

### 29b. `--window` shows a black frame: that "window" is the desktop

**Cause.** The desktop, the wallpaper and the per-display backstop are windows to ScreenCaptureKit
but not *content*: a `SCContentFilter` built for one of them returns the bare backdrop layer, i.e.
an all-black frame with exit status 0 and nothing said. Measured on a 480×306 frame:

| target | distinct colours | bytes in 3 s |
|---|---|---|
| `--window <Finder, empty title>` | **24** (146 846 of 146 880 px are `(0,0,0)`) | 1 KB |
| `--window <Terminal>` | 1664 | 829 KB |
| `--display 1` | normal | normal |

**Fix.** `--list` marks those entries `(backdrop — use --display <n>)`, and `--window` now refuses
them instead of painting black:

```
krd: window 19 (Finder, title "", layer -2147483603) is the desktop backdrop, not a window —
         ScreenCaptureKit hands back the bare layer, which composites to black.
         Mirror the whole screen instead: krd --display 0
```

The test is deliberately conservative: a window layer at or below the desktop-icon level **and**
filling (90 % of) a display. A real app is layer 0, the menu bar 24, the screen-share shield at the
top — none of them qualify, and a low-layer window that only covers a strip of the screen is still
mirrored normally. With `--debug`, a window mirror whose first frame is 99 %+ black also logs a
hint, for a compositing layer that slipped through.

### 30. `idle` climbs but the picture never updates

**Cause.** The frame status was read with `CMGetAttachment(sampleBuffer, SCStreamFrameInfo.status, …)`,
which never returns it: ScreenCaptureKit puts the frame info in the buffer's *sample attachments*
(`CMSampleBufferGetSampleAttachmentsArray`). Every read was therefore nil, and the `?? 0` after it
turned "no status" into "status 0 = complete" — so a static screen booked every idle frame as a
bad one and `idle` never moved (issue #25).
**Fix.** Read `status` from the sample attachments (`Capture.swift`) and keep the three states
apart: no pixel buffer and status **complete** (or a buffer that cannot be read) → `bad`; no pixel
buffer with any other status, or no status at all → `idle`. `bad` is now the only genuine error,
and the first one logs the status plus the attachment keys it actually carried.

## 5. Diagnostics

### 31. A line of debug output destroys the picture

**Cause.** Writing text to the pty moves the cursor; a line on the last row scrolls the grid, and
absolute placement positions then point at the wrong places. The picture shreds into fragments.
**Fix.** `Log` writes to a file, never to the tty (`--debug` → `$TMPDIR/krd-<pid>.log`,
`--log <path>` to choose). Never add a `print()`/`FileHandle.standardOutput` debug line to the
render path.

### 32. `screencapture -x` does not show what you think it shows

**Cause.** `-x` captures the main display only; multi-display setups need `-D <n>`. `-l <windowid>`
can return a blank or uncomposited image for some GPUI-rendered windows.
**Fix.** Use `-D` for other displays, and prefer krd's own `KRD_DUMP` (bytes actually sent) over a
screenshot when debugging the protocol.

### 33. A colour check "proves" the wrong thing: screenshots are colour-managed

**Cause.** A pure `(255,0,255)` tile can read back as `(243,12,246)` after capture, encoding and
re-composition. Exact equality fails on hardware that is doing its job.
**Fix.** Compare with a tolerance of at least ±60 per channel.

### 34. …and exact colour matching has already cost a whole debugging round

**Cause.** "The tile is not there" was concluded from a colour mismatch that was really colour
management (33), and a fix was attempted for a bug that did not exist.
**Fix.** Never use exact colour matching as the only evidence that something was drawn. Use
structural markers: `KRD_GRID=1` gives every tile a white border, so tile *geometry* is what you
measure; `KRD_DUMP` shows what was actually sent.

### 35. You need to know whether the renderer or the capture is broken

**Cause.** Most black-screen reports are ambiguous: no pixels, wrong protocol, or no permission.
**Fix.** Split the pipeline: `krd --selftest --no-input` exercises the whole tile/encoder/writer
path with synthetic pixels and needs no permission at all. If selftest draws, the renderer is fine
and the problem is capture/permission; if it does not, the problem is the terminal or the protocol.
Then use `KRD_GRID=1` (placement), `KRD_QUADRANTS=1` (which transmission shape your terminal
honours), `KRD_Q=0` (errors), `KRD_DUMP` (bytes). Full descriptions in [TESTING.md](TESTING.md).

### 36. How to see what krd logged over SSH

**Fix.** Always pass an explicit path so you know where it is:
`ssh -t host ~/bin/krd --fps 20 --debug --log ~/krd.log`, then from another session
`ssh host tail -f ~/krd.log`. The 1 Hz `stats:` line tells you whether frames arrive at all
(`tiles/s 0` with `dirty 0` = nothing changed or nothing captured; see
[ARCHITECTURE](ARCHITECTURE.md#9-diagnostics-wiring) for every field).

## 6. Headless (`krd ax`)

### 37. `krd ax` says "no Accessibility permission"

**Cause.** The grant is recorded against the code signature, per binary, and an ad-hoc rebuild
changes the cdhash — a binary that was granted yesterday is a stranger today. It is also possible
that the pane lists a *different* copy of krd (the one in `~/.build/`, not `~/bin/`).
**Fix.** `krd ax doctor` prints the exact path it is asking about. Grant that one: System Settings →
Privacy & Security → Accessibility → `+` → the path (`Cmd-Shift-G`). If it is already listed,
remove it with `−` and add it again, or start over with
`tccutil reset Accessibility com.kkrt.macdesk`. `krd ax --prompt` opens the dialog for you.
Note that `krd ax` needs Accessibility only; Screen Recording belongs to the mirror.

### 38. `krd ax` is granted but still answers `cannotComplete`

**Cause.** The process has no window-server connection yet, or there is nothing to talk to. In an
ssh (Background) session the *first* accessibility call always fails this way and succeeds after
the window server has been touched; krd warms up before probing, so a failure that reaches you is
real: the Mac is asleep, at the login window, or every candidate app is hung.
**Fix.** Wake/unlock the Mac and re-run. `krd ax doctor` separates the two cases: it prints whether
the first call failed and whether the retry succeeded, plus the frontmost app it managed to read.
If the retry succeeds, the earlier failure was just startup and can be ignored.

### 39. `krd ax tree` shows the window frame but not the page inside it

**Cause.** Chromium and Electron do not build a renderer accessibility tree until an assistive
client asks for one, and on macOS 27 the two attributes that used to ask
(`AXManualAccessibility`, `AXEnhancedUserInterface`) are not settable — measured on Chrome. The
result is a correct-looking tree of window buttons with no `AXWebArea` underneath.
**Fix.** Do not trust a small tree as "the app is simple". For browsers use CDP
(`--remote-debugging-port`) or launch with `--force-renderer-accessibility`; for Electron apps the
same flag applies. Details and measurements: [research-ax-text-channel.md](research-ax-text-channel.md) §5.3.

### 40. `--zoom 2` still shows the whole desktop

**Cause.** `SCStreamConfiguration.sourceRect` is what crops the capture, and it is relative to the
filter's content — the display for a display filter, the window frame for `--window`. On a
*secondary* display some builds want global points instead, so a crop computed relative to the
display origin can land somewhere else (or be ignored entirely on a very old macOS).
**Fix.** Check the `--debug` line first: it prints `source <w>x<h> pt (zoom <f> of <W>x<H> centred
<x>,<y>)`. If the crop rectangle is right but the picture is not, try
`KRD_ZOOM_GLOBAL_RECT=1`. If the crop is wrong, `--zoom-at` is being given points from another
coordinate space (it takes global screen points, the same space as `CGEvent.location`).

### 41. `--zoom-follow` stutters while dragging

**Cause.** By design: panning moves the crop, and the crop is a *capture-side* setting, so the
stream has to be restarted (`capturer.stop()` + `start()`) and the next frame is a full repaint.
**Fix.** Nothing to fix — use `--zoom-at` for a fixed view when smooth panning matters, or zoom out
one step so the pointer stays inside the visible rect for the whole drag. If the restart fails, the
log says `krd: could not restart capture after a zoom pan: …` and the picture keeps the old crop.

### 42. `krd ax press @e7` says the ref is stale, or "no snapshot holds @e7"

**Cause.** A ref names one node of one dump. It stops working when the node changed (retitled, or
its window was rebuilt), when the app restarted (refs do not survive a restart; pid reuse is caught
too), or when the dump that printed it is gone — `$TMPDIR/krd-ax` keeps the last 16 dumps per window,
and rebooting empties `$TMPDIR`.
**Fix.** Re-dump and use the ref that dump prints. Pressing a stale ref is *supposed* to fail: the
alternative is acting on whatever now sits at that path. `krd ax press @e7 --snapshot <generation>`
pins a specific dump when several windows are in play, and `--app <name>` narrows a ref to one app.

### 43. `krd ax press` says the node "does not answer press"

**Cause.** The node has no `AXPress` action. Static text and containers have none, and a menu item or
checkbox whose window is not focused reports itself as `enabled=false` — `AXPress` is accepted and
does nothing, which the read-back then shows (`before` and `after` identical).
**Fix.** `krd ax tree` lists the actions each node does have (`press`, `showmenu`, `confirm`, `pick`,
…). Focus the window first (bring it to the front, or press something in it), then retry. A node with
no actions at all cannot be driven this way — fall back to the picture.

### 44. `krd ax set` writes, then fails with "reads back something else"

**Cause.** The app accepted `AXValue` and normalised it: a number field clamped the value, a search
field reformatted it, a rich text field wrapped it in its own attributes.
**Fix.** Nothing is broken — the exit code is `6` and the line above it shows what the app now holds.
Read that value and act on *it*; `krd ax tree --app … | grep <your text>` confirms it from a fresh
dump. If the field is genuinely read-only, `AXUIElementIsAttributeSettable` says so up front and the
write is refused before anything is sent.

### 45. A copy in the mirrored desktop never reaches my terminal, or `Ctrl-V` does nothing

**Cause.** Three separate things, and the log line says which:

1. The bridge is off. `--clipboard` defaults to `off` on purpose — a mirror that silently rewrites a
   machine's clipboard is a surprise. `--clipboard=in` is target → terminal, `out` is terminal →
   target, `both` is both.
2. Your terminal does not implement *writing* OSC 52, so `in` sends the sequence and nothing happens.
   Rex, Ghostty, kitty and WezTerm do; Terminal.app does not.
3. Your terminal does not implement *reading* OSC 52 (the `ESC ] 52 ; c ; ? ST` request), so `Ctrl-V`
   has nothing to paste. That is not silent: after 0.8 s the log gets
   `krd: this terminal did not answer the OSC 52 read, so Ctrl-V has nothing to paste.` and the
   fallback is `--clipboard-paste <file>` — that path only needs the target's pasteboard and a
   `Cmd-V`, no terminal cooperation.

**Fix.** `--debug` prints one line per sync (`clipboard: 1234 B target -> terminal (OSC 52)`,
`clipboard: 5678 B terminal -> target, Cmd-V posted`) and never the content, so "which half is
missing" is answerable without guessing. If the line says `dropped (limit 2097152 B)`, the clip was
over 2 MB — that is deliberate: the terminal decodes the whole payload before pasting anything, and
krd shares that stdout with the frames. Only text is bridged; images are not.

### 46. The picture stays at the old shape after plugging in / unplugging a display

**Cause.** A session is attached to one display; the geometry of the captured frame is only
recomputed when the stream is rebuilt, and the trigger for that is either the CoreGraphics
reconfiguration callback (GUI-launched krd) or a 2 Hz fingerprint poll (everything else — the
callback is not delivered to a process in an ssh session).
**Fix.** Nothing to do — a change is picked up within about a second, and `--debug` shows both
lines: `krd: capturing …` when the target is chosen, `krd: capture restarted (N display(s), was M):
…` when the stream is rebuilt (with the new `source … -> … px` underneath). If the display you were
mirroring is gone, the log says which one it followed instead. If neither line appears, the capture
never started (`krd ax doctor` is the wrong tool here — check `--debug` for `no displays
available`).

### 47. The picture freezes after a while; the log says `capture stopped`

**Cause.** ScreenCaptureKit handed back `-3805 Failed during stream due to application connection
being interrupted` — the window server dropped the stream under krd (a VM console that goes away, a
display sleep, a screen-recording permission change). Every counter keeps moving and `bad` stays 0,
so nothing looks wrong except the frozen picture: a 30-minute soak found it frozen for 19 of its 30
minutes (issue #44).
**Fix.** Since #44 krd notices and restarts the stream itself, up to five times with 1-2-4-8-8 s
backoff, and every attempt is a log line:

```
krd: capture stopped (SCStream 3805: Failed during stream due to application connection being
     interrupted); restarting in 1s (attempt 1/5)
```

If it says `gave up after 5 restarts`, the window server connection is gone for good: restart krd
(and for a VM, check the console is actually up). `probe/soak.py` is how you watch this over 30
minutes — it fails the run when `callbacks` stops advancing for a minute, which is what a frozen
stream looks like from outside, and it writes a stack sample (`<work>/sample.txt`) the first time
that happens.

If the picture freezes with **no** `capture stopped` line at all, you are seeing the quiet variant
(no error callback, frames just stop). krd's frame watchdog restarts the stream after 15 s of
silence — `KRD_STREAM_WATCHDOG=<seconds>` changes that, `0` turns it off — and the state of that
investigation is in [TESTING §11](TESTING.md#11-soak-thirty-minutes-with-every-feature-on).
