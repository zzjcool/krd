# bench/ux — reading the chrome without a terminal

`Sources/krd/Chrome.swift` draws a *text* layer under the picture: the `--dev` status line, the
mirror's one-row bar, and five panels. Everything in it is positioned text, so it can be read as
bytes — no screenshot, no terminal emulator, no permission. `--pane` / `--cell` make the geometry
deterministic (`main.swift:900-906`), and `--mock` replaces the pixels.

Two instruments:

| | for |
|---|---|
| `bench/ux/pty-session.py` | run krd on a pty of any size, type into it at a chosen second, dump every byte it wrote |
| `rex capture -b <block> --trim` | the same bytes after a real terminal has interpreted them, which is what the user reads |

```sh
# does `Ctrl-\` then `s` open the stats panel?  (it does not — see #115)
bench/ux/pty-session.py --secs 5 --at 2 --type '\x1c' -- /tmp/ctrls.bin -- \
    .build/release/krd --mock --dev --mirror --pane 80x24 --cell 8x16 --debug --log /tmp/krd.log

grep -c bandwidth /tmp/ctrls.bin     # 0
grep '^input:' /tmp/krd.log | tail    # input: raw 1 bytes: 1c / 73 ... and the 73 was *posted*
```

```sh
# every panel, at every size a person might run — the layout is the thing under test
for sz in 40x15 80x24 137x44 200x60; do
  for p in stats devices settings log help; do
    bench/ux/pty-session.py --secs 3 -- "/tmp/$p-$sz.bin" -- \
        .build/release/krd --mock --dev --mirror --pane "$sz" --cell 8x16 --dev-panel "$p"
  done
done
```

Notes that cost time to learn:

- The pty's **pixel** size is 0x0 from `openpty`, so always pass `--cell WxH` on the krd side or the
  layout falls back to a guessed cell. Give the pty a real `--cols/--rows`: krd's `handleResize`
  re-measures with `TIOCGWINSZ` alone, so a 0x0 pty makes any panel open/close resize the picture
  to a single cell — a harness artifact that looks exactly like a bug.
- A click on the status line arrives as **pixels** because krd enables `?1016h`
  (`Sources/krd/Input.swift:329`), so an SGR report for cell (col,row) is
  `ESC[<0;<col*cellW>;<row*cellH>M` — and the coordinate is then divided by
  `TermGeometry.read().cellSize`, i.e. by the pty's own cell, not by `--cell`.
- `--dev` alone is a no-op: `options.wall` defaults to true and `chromeEnabled` requires
  `!options.wall` (`main.swift:724`). Use `--mirror` until #116 lands.
