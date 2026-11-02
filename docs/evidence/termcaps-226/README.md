# What two real terminals answered (issue #226)

Raw evidence behind the table in [TESTING §9](../../TESTING.md#what-the-batch-answers-in-real-terminals-issue-226).
Two terminals, both driven by a script with no human in the loop and **no Apple Events**: a `.command`
file handed to Terminal.app with `open -a`, and the Ghostty binary's own `-e` form. Nothing here
needed an Automation prompt, a Screen Recording grant or a TCC change.

| file | what it is |
|---|---|
| `ghostty-1.4.0-krd.json` | `krd --dump-termcaps` in Ghostty 1.4.0 — the batch's raw bytes and the parsed `TermCaps`, plus the `U=1`/`a=f` probe's own replies |
| `ghostty-1.4.0-krd-run2.json` | the same, a second run (checks that the answers are stable; `reads` is 7 both times) |
| `ghostty-1.4.0-termcaps.json` | `python3 probe/termcaps.py --json` in the same window — the questions krd does *not* ask (`DECRQM` for every mode, `a=q`, `a=f`, the vendor strings, glyph widths) |
| `ghostty-1.4.0-kprobe4.txt` | `python3 probe/kprobe4.py` — an independent kitty-protocol probe: a real PNG `a=t`, every placement form, `a=f` |
| `ghostty-1.4.0-product-log.txt` | the start-up lines `krd --wall --mock` printed for the same window: 2027, the two `OSC`s, `?2031`, `U=1`, the cell. They are the values the product acted on, and they agree with the dump |
| `ghostty-1.4.0-scheme-2031.txt` | `scheme-2031.py`'s answer — `?996n` → `?997;2n` (light) while `OSC 11` says `#282C34` (dark), and `?2031h` sends no report at enable time. The machine's macOS appearance is Light (`defaults read -g AppleInterfaceStyle` → key absent), which is where the terminal's "light" comes from while its theme stays dark |
| `terminal-488-krd.json` | `krd --dump-termcaps` in Apple Terminal 488 (macOS 27.0) |
| `terminal-488-termcaps.json` | `probe/termcaps.py` there |
| `terminal-488-kprobe4.txt` | `probe/kprobe4.py` there — every answer silent, which is the "no graphics at all" case |
| `terminal-488-product-log.txt` | the same start-up lines, taken from `krd --wall --mock` in Terminal.app |
| `scheme-2031.py` | the 12-line probe behind the `?997`/`?2031h` observation (kept so the claim can be re-run, not just read) |

## How they were produced

The probe reads stdin, so the whole experiment is "run krd in the terminal, let it write a file":

```bash
# Ghostty: the app's own binary, `-e` is its "run this command" form. No `open` needed, and the
# window closes (and the app quits) when the script ends.
/Applications/Ghostty.app/Contents/MacOS/ghostty -e /bin/bash /tmp/capture.sh ghostty

# Terminal.app: a `.command` file handed to the app. LaunchServices starts the app; nothing is
# typed and no automation permission is involved.
open -a Terminal /tmp/capture-terminal.command
```

`capture.sh` was, per terminal, in this order:

```bash
"$KRD" --dump-termcaps "/tmp/krd226/$NAME-krd.json"                       # the product's own batch
python3 probe/termcaps.py --json "/tmp/krd226/$NAME-termcaps.json"        # everything else
python3 probe/kprobe4.py > "/tmp/krd226/$NAME-kprobe4.txt"                # independent graphics probe
"$KRD" --wall --mock --log "/tmp/krd226/$NAME-wall.log" --fps 5 < /dev/tty &   # the product acting on the answers
sleep 4; kill -TERM $!
```

`< /dev/tty` matters: a background job in a non-interactive shell gets `/dev/null` for stdin, and a
krd without a tty asks nothing (the first attempt of this capture did exactly that and reported
`input DISABLED`, which is a property of the harness and not of the terminal).

`krd` was the release build of the branch this table landed on; the window sizes are those the
terminals happened to open (151×55 cells for Ghostty, 80×24 for Terminal.app), which is why the
`CSI 16t`/`14t` numbers differ between the two runs of the *same* terminal in the table's prose.
