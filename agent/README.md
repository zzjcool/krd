# kagent — the scaffold an agent uses to develop krd

krd is a terminal application whose bugs live in what a *terminal* does with a picture, on a machine
whose screen is usually locked. Unit tests pin the bytes; they cannot answer "does the picture fill
its box". This directory is what closes that gap: a small, boring, machine-addressable set of eyes,
hands and assertions, so an unattended run can see, act, and prove.

```
agent/
  bin/kagent              the CLI — every verb is documented by `kagent <verb> -h`
  lib/kagent/             the parts (target, perceive, act, predicates, scenarios, render)
  lib/vt.py               kitty-graphics escape stream -> pixels (no terminal, no screen)
  lib/png.py              a stdlib PNG writer
  driver/                 one Swift binary built on the target: shot, input, windows, probe
  checks/                 reproduction scripts for `kagent prove`
  scenarios/              end-to-end tests as JSON
  tests/                  the decoder's own tests
```

Nothing here is part of the product. It is build tooling that happens to need a Mac to run.

## The two machines

| target | what it is | use it for |
|---|---|---|
| `vm` (default) | the tart guest `krd-vm` | everything visual and everything that clicks. Its screen is never locked, its TCC grants are already in place, and an agent cannot disturb the person using this Mac. |
| `host` | this Mac | building, `swift test`, and `krd ax` reads. **Not** `see` (a locked screen returns the lock screen) and never `click` (it would land in whatever the user left open). |

```bash
kagent --target host doctor        # the host's own capabilities
kagent doctor                      # the VM's
```

The VM runs its **own copy** of krd at `~/bin/krd` (`kagent doctor` reports how old the *local*
`.build/release/krd` is, which is a different file). So a build in this checkout is always
`--target host`, and a run against the deployed binary is always `--target vm ... '~/bin/krd'`. A
local path with the default target fails loudly rather than turning into "0 frames decoded".

## The five capabilities

### 1. An eye

```bash
kagent see                       # JPEG + the numbers to map a point in it back to the screen
kagent see --marks               # the same, with numbered boxes on everything clickable
kagent see --marks --grid 200    # ...and a labelled grid in screen points
kagent see --window Safari       # one window (an id from `kagent windows`, or a substring)
kagent see --as before           # name the frame so `same:before` can compare later
```

`see` prints a coordinate contract and nothing else is needed:

```
point = (image_x * 1.6000 + 0, image_y * 1.6000 + 0)
```

That is `scale` and `bounds.origin`. If doing the arithmetic is a risk — it is — pass image
coordinates straight through instead: `kagent click --image 812 340`.

### 2. Text

```bash
kagent text                          # the focused app's tree, one line per node
kagent text --app Finder -i          # only things that can be acted on
kagent text --menubar                # ...plus the menu bar (where "Save As" lives)
kagent press @e12                    # AXPress: no mouse, works on an occluded window
kagent set @e14 --text "hello"       # write AXValue, then read it back
```

A text screen is a few hundred tokens where a frame is ~100 KB, and unlike pixels it can be asserted
on. Use it first; use `see` when the question is about the picture.

Refs (`@e481`) are numbered per dump, so they cannot be cross-referenced between two commands — one
`press @e481` each, in the same invocation that printed it. Roles print short (`button`), not
`AXButton`.

### 3. Hands

```bash
kagent front                         # which app and window will get the next keystroke
kagent click 812 340                 # a real click, posted as a CGEvent
kagent click --mark 4                # the element numbered 4 by `see --marks`
kagent click --mark 4 --point        # ...by its centre instead of AXPress
kagent drag 100 100 900 700          # press, glide in 24 steps, release
kagent scroll --dy 5                 # at the pointer, or `scroll 800 400 --dy 5`
kagent type "hello"                  # unicode events: works for CJK and emoji
kagent key cmd+shift+a
kagent app focus Safari
```

`click --mark` presses through Accessibility and **falls back to the centre point** when the node
refuses (`AXTextField` does not implement `AXPress`). A refusal is an answer, not a failure.

`type` sends each character as a keycode *and* a unicode string, because the two are not
interchangeable: a text field takes the string, a terminal only takes the keycode. `key` and `type`
print who received the events (`typed 14 character(s) into Terminal`), and `app focus` waits until
the app really is frontmost — `open -a` returns before that is true, and a keystroke posted in that
window goes to whatever was in front instead. A scenario that loses its characters that way fails on
a later assertion, about something else.

### 4. Assertions

```bash
kagent wait 'element:button:Save' --timeout 5
kagent wait 'window:Settings'
kagent wait 'pixel:812,340=#ff8800'
kagent verify 'element:field:Search' 'window:Safari'
kagent wait 'diff:before'            # the screen no longer matches the frame named `before`
kagent wait 'same:before'            # ...or matches it again, pixel for pixel
```

Every predicate answers three ways, and the exit code carries the difference:

| exit | meaning |
|---|---|
| 0 | satisfied |
| 1 | not satisfied |
| 2 | usage |
| 3 | the system refused (Screen Recording / Accessibility) |
| 4 | the environment is missing (no VM, no build) |
| 5 | **unknown** — could not look |

"Could not look" must never be reported as "is not there". That rule is the reason for exit 5.

Predicate strings: `element:role:text`, `noelement:…`, `window:text`, `nowindow:…`,
`pixel:x,y=#rrggbb`, `same:NAME`, `diff:NAME`, `changed`, `text:WHAT-IT-SAYS`, `frontmost:App`,
`shell:cmd`, `file:path`, `app:name`. A bare word is `element:*:word`.

`text:` is the one that reads an app's *content*: a tree dump elides long values (`value="Last
login: …"`), so a terminal's output, a log pane or a chat transcript cannot be asserted with
`element:`. `text:` searches the whole value on the target, which is how "did krd log that line"
gets answered without OCR. `frontmost:` is who will receive the next keystroke.

`same:`/`diff:` compare a **32x24 block signature** with a 1% tolerance (`--tolerance`), not an exact
hash: a blinking caret changes the hash of a screen a person would call identical, and a predicate
that fires on a caret teaches you to ignore it. `changed` with no argument means "since the last
frame this run took". The frame `see --as NAME` wrote and the `same:NAME` that reads it must live in
the same `--run` (both default to `latest`).

### 5. Pixels without a terminal

`krd` writes kitty graphics escapes; `agent/lib/vt.py` decodes them back into the picture a terminal
would draw. No screen, no permission, no terminal — which is how a rendering claim gets verified on a
locked machine, and in CI.

```bash
kagent --target host render --pane 146x46 --cell 17x33 --strict-fit -- .build/release/krd --selftest
kagent --target host render --pane 100x30 --cell 17x33 --cell-mode pixels -- .build/release/krd --selftest
kagent render --target vm --pane 146x46 --cell 17x33 -- '~/bin/krd' --wall

kagent vt render /tmp/stream.vt --png /tmp/frame      # a stream captured elsewhere
kagent vt text artifacts/<run>/vt.vt --grep demo      # the text layer: footers, status lines
kagent vt runs /tmp/pane.vt                          # placeholder cell rects, from a text capture
```

`render` runs the command on a pty sized exactly as asked, answers the terminal probes krd sends
(`U=1` placement, DSR, cell size) the way Rex does — otherwise krd measures a different code path —
and reports one line per picture:

```
frames=2  pane=2482x1518 px  pictures=4  misfits=0
picture 1  cells=[29, 2, 87, 28] native=[1479, 924] fit=exact
```

`cells` is `[col, row, cols, rows]`, and `native` is what was actually transmitted, so the comparison
is against the image the terminal was handed, not the box echoed back.

`fit` says how the two relate, and the answer depends on the transport, because the two are not
interchangeable:

| fit | meaning |
|---|---|
| `exact` | pixels == cells x cell |
| `2x`, `3x` | an integer multiple: the terminal fits the image into the cells, so this is *better*, not wrong (`--dpr`) |
| `fitted` | other size, still at least as big as the box: fine with placeholders, the terminal scales it |
| `upscaled` | smaller than the box: the bug this repo paid for, "the desktop at half size in the corner" |
| `scaled` | a pixel-sized placement that does not equal its box: seams on a 1:1 terminal |

`misfits` collects the last two, and `--strict-fit` fails on them.

`--cell-mode` is which terminal the harness pretends to be, and it changes what krd asks for:

* `points` (default) — a Retina terminal that reports its cell in points and answers `CSI 14t/16t`,
  i.e. **Rex**, so krd asks for two device pixels per cell and uses unicode placeholders.
* `pixels` — a terminal whose `TIOCGWINSZ` reports device pixels, so krd takes one pixel per cell and
  sizes every picture to its box exactly. This is the only mode in which `--selftest` fills its
  tiles: the selftest never probes for placeholders, so on a points terminal it has no device cell to
  ask for and falls back to 8x16. The first line also says how
the run ended: `exited 0` (krd finished) or `stopped at the 12.0s deadline` (`--seconds`, default 12,
is how long it gets to draw before the pty closes). A run that decodes no frame is a failed
measurement — exit 2 — unless you pass `--allow-empty`.

`vt text` prints what a text capture would show, pictures as `#`, which is how a footer or a status
line is read back without a screenshot.

`--strict-fit` fails when `native` is not exactly `cells x cell`. That inequality is the seam bug
this repo paid for twice: a 1:1 terminal leaves slivers between tiles whose pixels differ from their
cell box.

## The checks that exist today

Each is a shell script that fails with a sentence, and each was written against a real failure mode:

| check | what it refuses to accept |
|---|---|
| `decoder-golden.sh` | the decoder drifting from krd's chunking, `U=1` placeholders, or `a=d` deletes |
| `selftest-pictures-fill-cells.sh` | a tile whose pixels are not its cell box (the 1:1 seam bug) |
| `wall-cards-keep-their-aspect.sh` | a card whose cell aspect does not match its window's pixel aspect |
| `wall-survives-a-resize.sh` | a relayout that leaves the old placements behind |
| `wall-fits-any-pane.sh` | a picture outside the pane, over the scroll bar or footer, or overlapping another |
| `demo-note-tells-the-truth.sh` | krd's own debug footer claiming pixels that are not its cells x cell |

```bash
for check in agent/checks/*.sh; do sh "$check" || echo "FAILED $check"; done
```

## Scenarios

A scenario is JSON, because the two people who read it are a model and a reviewer.

```json
{
  "name": "the Apple menu changes the screen, Escape restores it",
  "steps": [
    {"do": "app focus Finder"},
    {"sleep": 0.8},
    {"do": "see --rect 0,30,1920,1170 --as closed"},
    {"do": "click 12 10"},
    {"expect": "diff:closed", "timeout": 5},
    {"do": "key escape"},
    {"expect": "same:closed", "timeout": 5}
  ]
}
```

```bash
kagent run agent/scenarios/screen-changes-and-restores.json
```

Each step is either a command (the same strings the CLI takes, so the two cannot drift) or an
expectation. Steps fail fast; the run writes `report.json`, `report.md`, every frame and the
transcript into `artifacts/<scenario>-<stamp>/`. A scenario that leaves a directory like that behind
is a bug report.

## The loop: hunting, fixing, proving

```bash
kagent doctor                       # 1. is anything broken *before* I start?
kagent see --marks                  # 2. look
kagent text                         #    ...and read
# 3. write the reproduction as a script that fails, in agent/checks/
kagent prove --check agent/checks/the-bug.sh --baseline HEAD
# 4. fix it
# 5. prove again: before fails, after passes
make test && kagent selftest && kagent run agent/scenarios/<the nearest one>.json
```

`prove` builds the baseline in a throwaway git worktree and runs your check against **both**
binaries. The verdict says what actually happened:

| verdict | meaning |
|---|---|
| `fixed` | fails before, passes after |
| `not-a-bug` | passed before: the check does not reproduce anything |
| `not-fixed` | still fails |
| `regressed` | passed before, fails now |

Evidence lands in `artifacts/<name>/{before.txt,after.txt,state.json}`. A patch is not "done"
because the check it was written against passes — it is done when the *baseline* arm fails.

## What this scaffold cannot do (say so, do not work around it)

- **Chrome / Electron web content is not in the AX tree.** `AXEnhancedUserInterface` and
  `AXManualAccessibility` cannot be set on this OS. For those windows, use pixels, or CDP.
- **A slept display wedges ScreenCaptureKit.** The capture call never returns, the process becomes
  unkillable, and every later `krd` hangs at its last log line. `kagent doctor` reports a wedged
  process; the fix is `pkill -9 -x krd` and `caffeinate -u -t 10` before starting again.
- **Pixels and Accessibility are not one atomic snapshot.** They are collected at different times.
  After an unverified action, re-read; do not replay the action to resolve a disagreement.
- **One pointer, one focus.** A desktop is a single-owner resource: two agents clicking at once
  produce a result neither can explain. One scenario at a time per target.
- **The host's screen is locked.** `see` on `host` returns the lock screen. That is not a bug in the
  scaffold; it is the reason the VM exists.

## Artifacts and hygiene

`artifacts/` is gitignored and is the only place a run writes. Frames are JPEG (or PNG with
`--format png`), transcripts are JSONL, and nothing embeds image bytes in a log. `kagent trace`
prints the tail. Delete the directory freely: nothing depends on it surviving.

The driver is built on the target once per source revision (`~/.kagent/driver.sha` tracks it). After
editing `agent/driver/*.swift`, run `kagent doctor --fix` — a stale driver that silently lacks a
verb is the failure mode this cache exists to make impossible to hit unnoticed.
