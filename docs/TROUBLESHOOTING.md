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

### 19. Typing Chinese/Japanese produces nothing useful

**Cause.** There is no IME integration: characters outside the US/ANSI map are posted as a Unicode
string with `virtualKey 0`, which bypasses the input method entirely.
**Fix.** Use an ASCII layout; IME support would need the kitty keyboard protocol plus a candidate
window story that terminals do not have.

### 20. With `--window`, clicks go to whatever is on top instead of the mirrored window

**Cause.** `--window` only filters the *capture*; injection is a global `CGEvent.post(tap:
.cghidEventTap)`, so the window manager decides who gets the click.
**Fix.** Keep the mirrored window frontmost, or wait for `CGEventPostToPid` (roadmap).

### 21. `KRD_Q=0` types garbage into the desktop

**Cause.** Protocol replies arrive on stdin, which is in raw mode and parsed as input; the first
byte sequence looks like Alt-`G` and the rest becomes text.
**Fix.** Only use `KRD_Q=0` with `--no-input`, or inspect `KRD_DUMP` offline.

### 22. Pressing F11 or F12 kills the process

**Cause.** The `CSI 23~`/`CSI 24~` handlers index the F-key table with `code - 11`, which is past
the end of the 12-entry array for those two codes, and Swift traps on an out-of-range index.
**Fix.** Do not press F11/F12 until the mapping is corrected (a bounds check or a 14-entry table).
Please open an issue with the terminal you used; the crash is in `InputReader.handleCSI`.

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

### 30. `idle` climbs but the picture never updates

**Cause.** `CMGetAttachment(sampleBuffer, SCStreamFrameInfo.status, …)` was tested with
`as? Int`, which silently fails on the `NSNumber` that is actually attached; every idle frame then
looks like a broken frame (and the status is lost).
**Fix.** `as? NSNumber` → `.intValue` (`Capture.swift`). `idle` = frames with no pixel buffer and a
non-zero status; `bad` = no pixel buffer and status 0.

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
