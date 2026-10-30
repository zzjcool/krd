---
name: kagent
description: See and operate a real Mac and verify krd's rendering without a screen — capture the tart VM's desktop, click/type/drag by element or by point, assert on pixels or the accessibility tree, and decode krd's escape stream back into the picture it drew. Use for any krd change that has to be seen, clicked, or measured, and for any unattended bug hunt or fix.
---

# kagent: eyes and hands for an agent working on krd

`agent/bin/kagent` is the entry point. Everything below is a command it really has; run
`agent/bin/kagent <verb> -h` before inventing a flag. The full reference is
[`agent/README.md`](../../../agent/README.md), the workflow is [`docs/AGENT.md`](../../../docs/AGENT.md).

## Start here

```bash
agent/bin/kagent doctor            # every capability, measured. Fix anything red first.
```

`doctor` prints one line per capability: `target`, `hand (CGEvents)`, `eye (screen capture)`,
`text (Accessibility)`, `windows`, `pixels (escape decoder)`, `krd build`, `terminal instrument`.
Exit 0 means the whole chain works; a red `hand` means Accessibility is missing and **nothing you
click will happen**, so stop instead of testing against a dead machine.

## The four moves

```bash
# look — a JPEG plus the coordinate contract, or numbered boxes on everything clickable
agent/bin/kagent see --marks --grid 200
# read — the accessibility tree as lines (cheap, and assertable)
agent/bin/kagent text -i -d 6
# act — by mark number (AXPress, falls back to the centre), by point, or by ref
agent/bin/kagent click --mark 4
agent/bin/kagent type "hello" ; agent/bin/kagent key cmd+shift+a
# assert — three outcomes, and exit 5 means "could not look", not "not there"
agent/bin/kagent wait 'element:button:Save' --timeout 5
agent/bin/kagent verify 'pixel:812,340=#ff8800'
```

`see` prints `point = (image_x * S + x0, image_y * S + y0)`. If you would rather not do the
arithmetic, `click --image X Y` uses the last frame's contract for you.

Named frames make change assertions exact:

```bash
agent/bin/kagent see --as closed
agent/bin/kagent click 12 10
agent/bin/kagent wait 'diff:closed'          # something drew
agent/bin/kagent key escape
agent/bin/kagent wait 'same:closed'          # ...and the screen came back, pixel for pixel
```

## Rendering without a terminal

This is the only honest way to answer "does the picture fill its box" when the screen is locked, and
it runs in CI:

```bash
agent/bin/kagent render --pane 146x46 --cell 17x33 --strict-fit -- .build/release/krd --selftest
agent/bin/kagent render --target vm --pane 146x46 --cell 17x33 -- '~/bin/krd' --wall
```

Read the report, not the PNG: `misfits: 0` means every picture's pixels equal its cell box
(`--strict-fit` fails otherwise — that is the 1:1-terminal seam bug), and `placeholder_rects` is the
card geometry in cells. The PNGs are for when the numbers surprise you.

`--terminal rex` (the default) answers the `U=1`/DSR/cell-size probes the way Rex does. Without it
krd takes its fallback transport and you measure a path no user is on.

## Scenarios and proof

```bash
agent/bin/kagent run agent/scenarios/screen-changes-and-restores.json
agent/bin/kagent prove --check agent/checks/<repro>.sh --baseline HEAD
```

`run` writes `artifacts/<scenario>-<stamp>/{report.json,report.md,*.jpg,transcript.jsonl}`.
`prove` builds the baseline in a throwaway worktree and reports `fixed` / `not-a-bug` / `not-fixed` /
`regressed` from two exit codes. `fixed` is the only verdict that counts.

## Rules that keep a run honest

- **Never** `see`/`click`/`type` on `--target host`: the user's screen is locked and the pointer is
  theirs. The VM is the default for that reason.
- One scenario at a time per target — one pointer, one focus.
- Exit 5 (`unknown`) is a real answer. A permission failure must never read as a product bug.
- A hung `krd` on the VM (`Ss+`, ignores `kill`) wedges ScreenCaptureKit for every later run:
  `ssh krd-vm 'pkill -9 -x krd'`, then `caffeinate -u -t 10`.
- After editing `agent/driver/*.swift`, run `kagent doctor --fix`; a stale driver is silent.
- Leave no probe windows, no scrolling `krd`, and no half-written scenario behind.

## Before saying it works

```bash
swift build -c release && swift test
agent/bin/kagent selftest
agent/bin/kagent render --pane 80x24 --cell 17x33 --strict-fit -- .build/release/krd --selftest
agent/bin/kagent run agent/scenarios/screen-changes-and-restores.json
```

Report numbers, not adjectives: `frames=23 pictures=168 misfits=0`, `card 87x28 cells at rows 2..29`.
