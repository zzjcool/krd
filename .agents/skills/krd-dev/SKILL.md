---
name: krd-dev
description: Develop krd by driving the Rex terminal and the tart VM — run builds and screens in panes, read a TUI's text layer, measure picture grids without a screenshot, deploy to the VM. Use for any krd change that has to be seen or measured in a real terminal, and whenever a question is "does the picture fill its box".
---

# krd development: Rex as the instrument, tart as the target

krd is a terminal app whose whole point is what a *terminal* does with it. Unit tests pin the bytes,
but every real bug in this repo's history was found by running the thing in a live pane and reading
what came back. That is what this skill is for: never guess what a terminal does — measure it.

Two machines:

| where | what it is | use it for |
|---|---|---|
| this Mac | **Rex** (`rex`, `$REX_SESSION`) is the only kitty-graphics terminal available | every UI check: run krd in a Rex pane, read its text layer, capture panes, A/B flags |
| `ssh krd-vm` | a headless macOS VM (tart, `kraal-agent`, 1920×1200, Screen Recording granted) | the deployed build: real captures of a real desktop, without touching the user's desktop |

## The one rule

**Never screenshot the user's desktop.** Only the relevant window, or the VM's own screen (its
content is what krd captures with permission, so it is fair game). And on this Mac the screen is
locked most of the time anyway (`/tmp/lockcheck`-style check: `CGSSessionScreenIsLocked`), so
`screencapture` returns the lock screen — assume pixels are unavailable and measure text instead.

## Worksheet

```bash
# who am I, where is everything
rex window ls --json | head -40          # windows → layers → blocks (layout tree, real ids)
rex block ls --json                      # flat list, labels, window_id
echo "$REX_SESSION"                      # scope every command with -s "$REX_SESSION"

# run something in a pane of its own (never disturb the panes the user is looking at)
OUT=$(rex window new -s "$REX_SESSION" krd-probe --focus=false --json \
        -- sh -c 'cd ~/code/kkrt && exec .build/release/krd --wall')
B=$(echo "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["block_ids"][0])')

# type into it
rex send -s "$REX_SESSION" -b "$B" $'ssh -t krd-vm krd\n'   # \n is Return
rex send -s "$REX_SESSION" -b "$B" $'\x1c'                  # Ctrl-\ : krd's only key, it exits
rex send -s "$REX_SESSION" -b "$B" $'\x03'                   # Ctrl-C : a runaway shell command

# read it — TEXT is the instrument (no pixels, no escapes)
rex capture -s "$REX_SESSION" -b "$B" --trim
rex capture -s "$REX_SESSION" -b "$B" --format=vt > /tmp/pane.vt   # escapes + placeholders

# clean up: no probe windows left behind
rex window close -s "$REX_SESSION" krd-probe
```

What `rex capture` can and cannot see: it returns the terminal's **text buffer** (text/html/vt), so
it sees every character krd draws and *not* the pictures — but the pictures are placed on cells that
hold `U+10EEEE` (kitty unicode placeholders), and those characters *are* in the buffer. That is the
trick the whole measurement rests on:

```bash
# per row: how many placeholder cells, and which columns
python3 .agents/skills/krd-dev/scripts/wall-runs.py /tmp/pane.vt
```

Compare those rectangles with what the layout says they should be (`WallLayout`/`WallPanels`) — a
picture that does not equal its box is visible as a shorter run, an off-centre start, or a gap.

## Ask the terminal what it is

```bash
# the cell, in the unit Rex itself uses (device px for Rex: 17x33 on a 146x73 pane)
rex api call -s "$REX_SESSION" com.superlogical.terminal.size \
  '{"block_id":"block:01a18e24-1b85-700f-bc7b-e7fe9a8677cf"}'
```

krd logs its own answer too — always run the interesting case with `--debug`:

```bash
rex send -s "$REX_SESSION" -b "$B" $'ssh -t krd-vm krd --debug --log /tmp/krd.log\n'
ssh krd-vm 'cat /tmp/krd.log' | grep -aE 'wall cell|U=1|capture |scaled to|wall slot'
```

```
krd: wall cell 17x33 px, the pty's pixel size 2482x2409 - 146x73 cells, 1.0x pictures
krd: the terminal answered a U=1 placeholder: pictures are fitted into their cells
krd: capture 2431x1518 px asked, 1920x1199 px from a 1920x1200 px source
krd: wall slot 0 capture 1920x1199 px, scaled to 2431x1518 px
```

`--demo` replaces the desk with a test pattern (border, coloured corners, circle, rings) and puts
the frame's numbers in the **footer** — the numbers are text, so they can be read without a
screenshot:

```
demo 146x73 · cell 17x33 · 1x · pic 143x46c 2431x1518px · U=1 · the pty's pixel size 2482x2409
```

## The VM

```bash
ssh krd-vm                         # admin@192.168.64.7, macOS 26.6.2, headless tart "kraal-agent"
ssh -t krd-vm 'stty rows 46 cols 146; ~/bin/krd --wall --debug --log /tmp/krd.log'
ssh krd-vm 'screencapture -x /tmp/vm.png' && ssh krd-vm 'base64 -i /tmp/vm.png' | base64 -d > vm.png
```

Deploy (rebuild, re-sign, install) — scripted, because a stale tarball once shipped a binary that
did not match the tree:

```bash
.agents/skills/krd-dev/scripts/deploy-vm.sh      # tar snapshot → :8899 → build → codesign → ~/bin/krd
```

The identifier must stay `com.kkrt.macdesk` (Screen Recording and Accessibility grants hang off it).

## A/B protocol when text cannot answer

If the open question is "is this rendering right", do not theorise for another round — put both
variants in front of the user and ask for one word:

```bash
rex send -s "$REX_SESSION" -b "$B" $'\x1c'                                  # stop krd
rex send -s "$REX_SESSION" -b "$B" $'ssh -t krd-vm krd --no-placeholders --cell 17x33 --dpr 2\n'
```

Then ask: *fills / still black / worse*. Each answer kills a whole branch of hypotheses, and the
flags that make the difference become the next fix.

## Pitfalls this repo paid for (read before debugging graphics)

- **kitty replies echo the request**: a `U=1` probe is answered `ESC_Gi=31,p=1;OK ESC\`, not
  `i=31;OK`. Matching the short form made accepting terminals look silent → the wall fell back to a
  path that draws the picture at half size.
- **`q=2` hides errors.** A refused image looks exactly like a picture that never arrived.
- **Two transports, two rules on asking for more pixels than the source has.** A *screenshot*
  (`SCScreenshotManager`, the wall) pads with black: the source sits at its own size in one corner
  of a bigger canvas, signature *the larger the request, the smaller the desktop*. `PanelCapture.fitted`
  caps it and `PanelRaster.rgb(_:width:height:)` does the one upscale. A *stream* (`SCStream`, the
  mirror) upscales to the request — measured 1920x1200 → 2006x1254, no dropped frames. Carrying the
  screenshot rule over to the stream is what left **nine black lines** across the display page:
  the frame was 6 % smaller than its cell box, a 1:1 terminal cannot stretch it, so every tile row
  showed a seam (TROUBLESHOOTING 23g).
- **A slept display wedges ScreenCaptureKit.** The capture call never returns, the process goes
  unkillable (`Ss+`, `kill` ignored), and the *next* krd hangs at its last log line — usually right
  after `capture … asked`. Fix: `ssh krd-vm 'pkill -9 -x krd'` **and** `caffeinate -u -t 10` before
  starting krd; a blank wall with `placeholder cells: 0` and no `wall slot` line is this.
- **Rex draws an image one image pixel per device pixel** and does not scale it into `c`/`r`. So the
  picture's pixels must equal its cells' device pixels; `c`/`r` alone do not save a wrong size.
- **The pty's `ws_xpixel` is in the same unit as the terminal's `CSI 16t` answer**, which is not
  necessarily device pixels — Rex reports device px, older answers were points. `--cell` / `--dpr`
  override; the `--demo` footer prints which number the frame used.
- **`timeout` is not installed on the VM**; use `ssh -tt` plus `stty` for a sized pty.
- **Leave nothing behind**: close probe windows (`rex window close`), delete probe images (`a=d`),
  and never leave a test krd running in a pane the user is looking at — `Ctrl-\` (`\x1c`) is the only
  key it accepts; otherwise kill it from outside the pane.
- **A stale tarball is a real incident** (it once deployed `placeholders = false` while the tree said
  `true`). Always re-tar in the same command that deploys.

## Before saying "it works"

1. `swift test` (412 tests) and `swift build -c release`.
2. Deploy to the VM with the script above.
3. Run it in a Rex pane **with `--debug`**, read the log lines, and measure the placeholder runs.
4. Report numbers, not adjectives: `stage 143x46 cells at 2431x1518 px, card 54x20 centred at 45..99`.
