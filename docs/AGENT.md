# Working on krd as an agent

English | [简体中文](AGENT.zh-CN.md)

This is the playbook for an unattended run on this repository. It assumes the reader cannot see a
screen, cannot use a mouse, and will be judged on what it left on disk.

The constraint that shapes everything: krd's bugs are in what a *terminal* does with a picture, and
the Mac that has the terminal is the one whose screen is usually locked. `swift test` pins bytes; it
cannot answer "does the picture fill its box". So the repository ships a scaffold that turns every
question into something measurable on a machine where measurement is still possible:
[`agent/`](../agent/README.md).

```bash
agent/bin/kagent doctor        # all green before you start, or the run is not worth starting
```

## The map

| where | what it is | an agent may | an agent must not |
|---|---|---|---|
| this checkout | the code | edit, build, `swift test`, `kagent --target host` reads | `see`/`click` on `host` — the screen is locked and the pointer belongs to a person |
| `ssh krd-vm` | headless tart guest, 1920x1200, TCC already granted | `kagent` with the default `--target vm`: capture, click, type, read AX | leave a `krd` or a probe window running |
| a Rex pane on the host | kitty-graphics terminal | `rex capture` for the text layer | take the user's focus, or close their windows |
| `artifacts/` | run output | write, read, delete | commit |

`kagent` defaults to the VM for exactly this reason. `--target host` is for reads and builds.

## What a claim has to look like

Three sentences decide whether a run was useful:

1. **What you saw**, with the number in it: `stage 143x46 cells at 2431x1518 px, card 54x20 centred
   at 45..99`. Not "the picture looks right".
2. **How you saw it**: the command, and the arm (VM capture / decoded escape stream / AX tree /
   live Rex pane). A screenshot of the VM and a decoded frame are different evidence.
3. **What would have made it fail**: the check, and what it returned on the code *before* the change.

If any of the three is missing, the work is not finished. This is the same rule the repo already
applies to prose: numbers, not adjectives.

## Workflow 1 — reproduce a UI bug

```bash
agent/bin/kagent doctor
agent/bin/kagent app focus "<the app>"
agent/bin/kagent see --marks --grid 200          # look; note the mark numbers
agent/bin/kagent text -i -d 6                    # read; the same elements as refs
agent/bin/kagent trace -n 20                     # what the last commands did
```

Then make it *small*. The reproduction is a script in `agent/checks/`, not a paragraph:

```sh
#!/bin/sh
# fails on the buggy build, passes on the fixed one; `prove` sets $KRD
"$KAGENT" --target host render --pane 80x24 --cell 17x33 --seconds 6 --strict-fit -- \
    "$KRD" --selftest
```

The test for "is this a real reproduction" is the baseline arm:

```bash
agent/bin/kagent prove --check agent/checks/<name>.sh --baseline HEAD
```

`not-a-bug` means the check proves nothing yet — not that the bug is absent.

## Workflow 2 — verify a rendering change

Rendering questions are answered from the escape stream, never from a screenshot:

```bash
agent/bin/kagent --target host render --pane 146x46 --cell 17x33 --strict-fit -- .build/release/krd --selftest
agent/bin/kagent render --target vm --pane 146x46 --cell 17x33 -- '~/bin/krd' --wall
```

Read the report, not the PNG, first:

- `misfits: 0` — every picture's pixels equal its cell box. Non-zero is the seam bug.
- `placeholder_rects` — the card geometry in cells, which is what a layout claim is about.
- `frames` — a renderer that drew nothing also draws nothing wrong.

The PNGs are there for the case where the numbers are surprising and a person wants to see it.

For the terminal's *text* layer (what `rex capture` can see), the placeholder cells are the map:

```bash
rex capture -s "$REX_SESSION" -b "$B" --format=vt > /tmp/pane.vt
agent/bin/kagent vt runs /tmp/pane.vt
```

## Workflow 3 — hunting bugs

Hunting is not "read the code until something looks wrong". It is a loop with a stop condition.

1. **Pick a surface**, not a bug: the wall layout, the capture path, input decoding, the quality
   governor, one flag. A hunt that is allowed to wander finds nothing.
2. **Read the contract** — the doc, the tests, and the log lines that the code promises. Most bugs in
   this repo were a disagreement between two of those.
3. **Make the machine disagree with the contract**, on the VM or in a decoded stream, at the geometry
   the contract names.
4. **If you cannot reproduce it, say `inconclusive` and move on.** A bug report without a failing
   command is a hypothesis, and the next agent will pay for it.
5. **Write the reproduction into `agent/checks/`** before touching the code, and confirm it fails on
   `HEAD`.
6. **Fix the invariant, not the symptom.** One change at a time; if the diff touches tests or golden
   fixtures, justify it in the same commit message or revert it.
7. **Prove it** (Workflow 4).

Surfaces worth hunting, in the order this repo has historically paid out:

| surface | ask | instrument |
|---|---|---|
| picture geometry | is the picture exactly its cell box, at every layout? | `render --strict-fit` |
| transport choice | did the terminal's answer select the path the code thinks it did? | `kagent render --terminal rex` + `--debug` log |
| input | does a click/drag/scroll land where the layout says? | `kagent drag` + `same:`/`diff:` |
| capture | does a zoom/scale/quality change move the picture instead of sharpening it? | `render` with the flag, compare `cell_box_px` and `native_px` |
| wall layout | do cards keep their aspect and their slot? | `vt runs` rectangles vs the layout |
| chrome | do panels and the status line survive a resize? | two `render`s at different `--pane` |

## Workflow 4 — proving a fix

```bash
agent/bin/kagent prove --check agent/checks/<name>.sh --baseline <ref-before-the-change>
make test
agent/bin/kagent selftest
agent/bin/kagent run agent/scenarios/<the nearest scenario>.json
```

`prove` builds the baseline in a throwaway worktree and runs the check against both binaries:

| verdict | what it means | what to do |
|---|---|---|
| `fixed` | fails before, passes after | done |
| `not-a-bug` | passed before | your check does not reproduce anything |
| `not-fixed` | still fails | the patch did not address it |
| `regressed` | passed before, fails now | the patch made it worse |

The artifacts (`artifacts/<name>/before.txt`, `after.txt`, `state.json`) are the review request.
Paste the two exit codes into the pull request; do not describe the fix as "verified" without them.

## Regressions: what else has to stay true

A patch is not verified by its own check. In this repo the mechanical floor is:

```bash
swift build -c release
swift test                                   # 45 test files
agent/bin/kagent selftest                    # the scaffold's own tests
agent/bin/kagent run agent/scenarios/screen-changes-and-restores.json
python3 bench/bench.py --quick               # budgets, ~2 minutes
```

A scenario that fails after a patch is either a regression or a scenario that encoded the old
behaviour. Both are worth a sentence — but the second one is a change to the test, and changing a
test to make a patch pass is the one thing that is never allowed silently.

## Autonomy rules

These are not style preferences; each one has already cost a run.

1. **Never touch the user's desktop.** No `see`/`click`/`type` on `host`. No closing windows. No
   `screencapture` of the whole screen "just to check".
2. **One scenario at a time per target.** The pointer and the focus are single-owner.
3. **Clean up**: delete probe windows, `pkill -9 -x krd` if you started one and it hung, leave
   `artifacts/` alone.
4. **Leave nothing running** on the VM. A hung `krd` wedges ScreenCaptureKit for every later run and
   is indistinguishable from a product bug.
5. **Write state to files as you go** — `artifacts/<run>/transcript.jsonl` does it for free, and
   `state.json` for a finding. A run that dies mid-way should still be readable by the next one.
6. **Cap the loop.** Three attempts per finding, then record `inconclusive` and stop. An unattended
   loop that keeps trying is a loop that keeps paying.
7. **Say `unknown` when you could not look.** Exit code 5 exists so that a permission problem never
   reads as a product bug.
8. **Do not grade your own work in the same context that wrote it.** Re-read the evidence (the
   transcript, before/after exits) rather than the summary of it.

## Known traps

| trap | what it looks like | what to do |
|---|---|---|
| a slept display wedges ScreenCaptureKit | `krd` prints nothing after `wall cell`, stays `Ss+`, ignores `kill` | `pkill -9 -x krd`, then `caffeinate -u -t 10` before the next run |
| a stale driver | `kagent` answers "unknown verb" or "no such file" | `kagent doctor --fix` (rebuilds on source-hash change) |
| Chrome/Electron content is not in the AX tree | `kagent text --app Chrome` returns a nearly empty tree | use `see`, or a CDP route; do not conclude the UI is empty |
| AX frames are in points, captures in pixels | a click off by the backing scale | `kagent see` prints `image_to_point`; use `click --image`, or `--mark` |
| the harness answers like a terminal | a decoded stream shows a different transport than the real one | `--terminal rex` is the faithful default; `--terminal none` measures the fallback on purpose |
| the menu bar clock | a `same:` assertion fails once a minute | crop the clock (`--rect 0,30,...`) or compare a named snapshot taken inside the same second |
| `app focus` returns before the app is frontmost | typing "works" (exit 0) and the screen never changes | `app focus` now waits and `type`/`key` print the receiver; assert `frontmost:App` before typing |
| a Finder sheet left open by an earlier run | synthetic keys vanish, a `wait` on a window title times out | `ssh krd-vm 'pkill -x Finder'`; scenarios should not depend on a modal sheet |
| a terminal ignores `type` | characters never appear, no error | fixed: `type` posts a keycode as well as a unicode string — a terminal reads only the keycode |
| `krd ax find` matcher | `element:` cannot see past a `value="…"` elision | use `text:<query>`, which searches the full value on the target |
| the harness stops answering the terminal | krd measures an invented 8x16 cell; pictures are half size, every check still green | `kagent selftest` prints `the pty answers u1=… cellsize=…`; a zero there is the harness, not the product |
| `--selftest` on a points terminal | tiles 64x64 inside a 136x132 box: soft, but in the right place | the selftest is a wire test and does not probe for geometry; run it with `--cell-mode pixels`, or give krd `--cell` |
| "the picture is bigger than its box" | a 2x image for a 1x box looks like overflow | krd sends `c=`/`r=`, so the terminal scales the image into the cell rect: pixels are quality, cells are geometry. Measure the ink, not the transmit header |

## Two scenarios that are known to pass

```bash
kagent run agent/scenarios/terminal-types-and-reads-back.json   # typing, a keycode, and reading text back
kagent run agent/scenarios/finder-navigates-and-returns.json    # a real app, a state change, and a restore
```

They are the floor, not the ceiling: a bug hunt starts by copying the nearest one and changing what
it asserts.

## Where the numbers live

- `agent/README.md` — every verb and flag.
- [`TESTING.md`](TESTING.md) — the product's own calibration switches.
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — the failures this project has already paid for.
- `artifacts/<run>/transcript.jsonl` — what this run actually did.
