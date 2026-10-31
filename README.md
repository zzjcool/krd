# krd — your Mac's desktop, inside a terminal

English | [简体中文](README.zh-CN.md)

[![CI](https://github.com/zzjcool/krd/actions/workflows/ci.yml/badge.svg)](https://github.com/zzjcool/krd/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/zzjcool/krd?sort=semver&label=release)](https://github.com/zzjcool/krd/releases)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](#license)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](#requirements)

> **Work in progress.** krd is under active development — features are still landing and behaviour
> can change between releases. Bug reports and rough edges are welcome; see
> [CONTRIBUTING.md](CONTRIBUTING.md).

ScreenCaptureKit grabs the screen, kitty graphics escapes carry it to the terminal, and mouse and
keyboard come back on stdin and are injected with `CGEvent`. No VNC, no codec, no extra port, no
client to install — the SSH session you already have *is* the client.

<p align="center">
  <img src="docs/media/demo.gif" alt="krd: a macOS desktop painted into a terminal pane over SSH" width="640">
</p>

```bash
ssh -t host krd --fps 20        # exit with Ctrl-\
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/zzjcool/krd/main/install.sh | sh
```

The script downloads the latest release (one universal binary, Apple Silicon + Intel), verifies its
checksum, signs it locally with a stable identity and drops it in `~/bin/krd`.

```bash
curl -fsSL … | sh -s -- --prefix /usr/local/bin      # somewhere else
curl -fsSL … | sh -s -- --version v0.1.1             # a specific release
curl -fsSL … | sh -s -- --from-source                # build with Swift instead
```

Everything is explained in [docs/DEPLOY.md](docs/DEPLOY.md); the script itself is plain `sh`
([install.sh](install.sh)).

## Use

```bash
krd                          # the landing screen: the display on top, the most recent windows
                             # below, both scrolling on the right bar (the wall)
krd --mirror --fps 20        # the whole display as one picture, the old default
krd --list                   # displays and windows; backdrop entries are marked
krd --window Safari          # mirror a single window (a backdrop window is refused, not shown black)
krd --zoom 2                 # show half the screen at twice the density (crop on the capture side)
krd --zoom 3 --zoom-at 200,300   # ...centred on a source point, in global screen points
krd --zoom 2 --zoom-follow   # ...and pan when the pointer reaches the edge of the picture
# the capture scale adapts by default: 1 while the link keeps up, 0.5/0.25 when it cannot,
# so a slow link stays at 20 fps instead of freezing. --scale 1 pins it, --scale 0.5 fixes it.
krd --scale 1                # never adapt: always the pane's own pixels
krd --scale 0.5              # capture half the pixels per side and let the terminal upscale:
                             # 4x fewer bytes on colour-heavy content, visibly softer text
krd --display 1 --fps 30
krd --unfocused-fps 1        # while the pane has no focus the picture drops to this rate (the
                             # terminal reports focus with DECSET 1004: CSI I in, CSI O out):
                             # 1 fps by default, 0 freezes it — a key or a click brings it back
krd --no-input               # watch only
krd --quality 70            # how much colour the picture may lose: 100 = lossless, 80 (default) =
                            # 5-6-5 on incompressible tiles, 70 = 5-5-5, 50 = 4-4-4 everywhere
krd --quality auto          # let krd spend colour first (80->70->50), then frame rate, then scale
krd --no-quantise           # same as --quality 100 (the mirror's lossless; the wall's is
                            # --wall-quality 100)
krd --wall-quality 70       # the landing screen's pictures: 100 = lossless, 70 (default) = 5-5-5,
                            # 50 = 4-4-4. Bit depth only — the picture is still exactly its
                            # cells, so a first picture costs ~20-30 % fewer bytes on desktop-like
                            # content (measured -20.7 % at 70, -27.9 % at 50) and nothing on a flat
                            # one, with nothing cropped and no seam. Separate from --quality (the
                            # mirror's knob), and it survives a click into a window and back
krd --cursor                 # draw the target's pointer into the picture (default: hidden —
                             # a drawn pointer dirties tiles every time the mouse moves)
krd --dev                    # TUI layer: a status line and panels under the picture
krd --mock --dev             # the same, with the screen mocked: no permission needed
wall                         # the same landing screen under its own name (a symlink the
                             # installer adds: today `wall` and `krd` are the same command)
krd --symbols ascii          # one-cell-everywhere glyphs (terminals that draw ▲ two wide)
krd --debug                  # stats to a log file, never to the screen
krd --format rgba            # fall back to f=32 if the terminal rejects f=24
krd --passthrough on         # inside tmux/screen: wrap every image escape in a DCS passthrough so
                             # tmux forwards it (auto|on|off, KRD_PASSTHROUGH; default auto = on when
                             # TERM starts with tmux or screen; see TROUBLESHOOTING §1c)
krd --bench                  # time the encoder on synthetic frames, no terminal needed
make bench                   # every layer + budget verdicts -> bench/report.md
```

`--dev` adds a status line (`fps`, `MB/s`, latency) and five panels — stats, devices, settings,
log, help — reached with `Ctrl-\` then `s`/`d`/`f`/`l`/`?`, or by clicking the segment you want.
The picture keeps every row above the status line; a panel takes its rows out of the picture and
gives them back when it closes. `make dev` is the shortcut.

The `fps` segment is `delivered/target`. That slash matters under `--quality auto`: its frame-rate
rungs (`20 -> 15 -> 10`) are **targets, not floors**. The capture keeps arriving at `--fps` and the
loop declines frames so the *average* is the rung — a 20 fps capture asked for 15 draws
`draw, drop, draw, draw, drop, …`, so single gaps alternate 50/100 ms while the delivered rate is
15.0. A rung that cannot be held shows up as `11.2/15 fps` in the bar (and in `--stats`), never as a
silently mislabelled 15 (issue #140).

`--mock` swaps ScreenCaptureKit for a desktop drawn in process (`--mock-size WxH`, default
1920x1200). Tiles, dirty rects, the encoder, the placements and the chrome are all the real
code — only the pixels are synthetic, so it needs no permission and never stops. `make dev-mock`.

On the landing screen a click is the whole vocabulary: the right bar scrolls the stage and the shelf
(one click = one page, the wheel = one item), and **clicking a picture opens that window's mirror** —
krd *becomes* `krd --window <id>` (it `exec`s itself, so there is never a second screen-capture client). That
mirror wears a one-row macOS-style bar — the window's name, the live rate, **the delay we measure**
(`38 ms`: the terminal's `CSI 5n` round trip, or `— ms` when there is no measurement), the clock — and
**`[ ≡ ]`, which opens a menu of three sliders** (colour = the bit depth, quality = how eagerly the
encoder spends it, frame rate = 1…20). Each tick on a slider is a click, the change is hot, and a click
pins the axis it touches so no governor takes it back; `[ ≡ ]` again closes it. Its `[ - ]` button
(or `Ctrl-\`) shrinks it back into the wall, on the page you left it on. Pictures are centred in their box.

Exit with **`Ctrl-\`**. `Ctrl-C` is forwarded to the remote desktop, like on a real machine.
Flags, tuning knobs and the diagnostics switches: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[docs/TESTING.md](docs/TESTING.md).

### Headless: read the Mac as text

Same binary, no frames. `krd ax` walks the accessibility tree and prints it, so an agent can read
and act on windows without a picture — and without Screen Recording, which only the mirror needs.

```bash
krd ax doctor                # is Accessibility granted, does the window server answer
krd ax windows               # app, pid, window index, title, frame
krd ax tree --app Finder -d 3 -i    # one window, shallow, actionable nodes only
krd ax tree --app Finder --json     # same, for a program
krd ax tree --app Finder --diff     # only what changed since the last dump, or `unchanged`
krd ax screen                # every on-screen window, plus the focused element
```

Output is one line per node — `@e3  button  "Save"  value="hi"  [120,80 64x24]  press` — with refs
stable for the life of that dump. Text is sanitized: a window title can contain ESC sequences and
those are replaced, not printed. See
[docs/research-ax-text-channel.md](docs/research-ax-text-channel.md) for the measurements.

**Exit codes** — the same six wherever they are stated (here, `krd ax --help`, and
[docs/TROUBLESHOOTING.md §6](docs/TROUBLESHOOTING.md#6-headless-krd-ax)):

```text
exit  0  ok — and a green krd ax doctor
      2  usage: unknown flag or verb, or a missing/malformed value
      3  no Accessibility permission
      4  the accessibility API is not answering: the Mac asleep or locked, the window
         server gone, every app that could answer hung
      5  nothing matched: a query, app or ref found nothing (an empty krd ax windows list exits 0)
      6  the node refused the action, or the app read back something else

krd ax doctor exits 3 or 4 on a red diagnosis instead of 0, in text and --json alike, so
krd ax doctor && krd ax windows is a health check that cannot pass on a broken Mac.
```

`--json` is a format switch, not a second contract: text and JSON leave with the same code, and
stdout carries exactly one object in every outcome (`krd ax --json --help` still answers in text)
— `"ok": true` plus the usual fields on success, and on failure

```json
{"ok": false, "error": {"code": "environment", "exit": 4,
                         "message": "the accessibility API is not answering (cannotComplete)",
                         "next": "the Mac may be asleep or at the login window…",
                         "ax": "cannotComplete"}}
```

(pretty-printed, and `next` cut short, here: stdout gets that one object on one line)

where `code` is `usage|permission|environment|notFound|notActionable` — one token per exit code —
`exit` is that same number, and `ax` is the AXError name (`cannotComplete`) for the permission and
environment classes; codes `5` and `6` name theirs inside `message`. A consumer that used to match
on the name alone (the `error` field of the old `doctor` payload) reads `error.ax` now. The prose
stays on stderr; `press`/`set` answer
`{"ok":true,"command":"press|set","ref":"@e7","label":"…","before":"…","after":"…","elapsedMs":3}`
(`press` answers `after: null` and a `note` when the element went away, and the same `note` when
the write landed but read back unchanged; `set` fails with `6` rather than report a null read-back,
and echoes the `value` it wrote), and `krd ax --help` prints the rest.

## Requirements

- macOS 14 or newer.
- A terminal that speaks the kitty graphics protocol: **rex**, **Ghostty**, **kitty**, **WezTerm**.
  Terminal.app does not.
- One-time approval of **Screen Recording** (capture) and **Accessibility** (input) — the installer
  prints the exact prompt. Details and failure modes: [docs/DEPLOY.md](docs/DEPLOY.md).

### Terminals

| | Graphics | Keyboard protocol |
|---|---|---|
| rex | kitty | ? — run the probe |
| Ghostty | kitty | kitty (flags 15) † |
| kitty | kitty | kitty (flags 15) † |
| WezTerm | kitty | kitty (flags 15) † |
| Terminal.app | — | legacy (no answer) |

“kitty” means `Cmd` combinations, key release and repeat arrive; “legacy” means they don't, and krd
runs on the unchanged pre-0.1.3 encoding. Both are supported states. † = per the terminal's own
documentation — `python3 probe/kkeyboard.py` answers it for the terminal you are actually in.

## Status

| | |
|---|---|
| Solid | tile-dirty rendering (8×4 cells, parallel zlib, per-tile level), static screens cost 0 bytes/s, pointer following, left/middle/right click, double click, wheel, keyboard, kitty keyboard protocol (`Cmd`, repeat, release) on terminals that answer the handshake, window mode with input posted to that window's own process, display-set changes (plug/unplug, resolution, lid) restart capture in place, SSH |
| Rough | colour-heavy full-screen motion at full density: 13.58 MB/frame worst case, costed in [research-photo-bandwidth](docs/research-photo-bandwidth.md); Herdr's image-delete semantics |
| Solid (bandwidth) | colour-heavy motion is usable when you spend resolution on it: incompressible tiles drop to 5-6-5 (`Z_HUFFMAN_ONLY`, no protocol change) for **1.29×**, and `--scale 0.5` captures a quarter of the pixels for **3.98×** — together **68 MB/s at 20 fps**, inside a local pty's 103 MB/s, with pointer mapping unchanged |
| Solid (clipboard) | clipboard bridge, opt-in with `--clipboard=in|out|both`: a copy inside the mirrored
desktop becomes an OSC 52 sequence for the local terminal (`in`), and `Ctrl-V` asks the terminal
for its clipboard, puts it on the target's pasteboard and posts `Cmd-V` (`out`, needs a terminal
that answers the OSC 52 read — `--clipboard-paste <file>` is the path that always works) |
| Solid (IME/CJK) | `--ime` (`auto` / `raw` / `unicode`): physical keys go to the target so *its* input method composes
(candidate window renders in the mirrored picture); characters with no key fall back to injected
text, with a log line — see TROUBLESHOOTING §19 |
| Not yet | spanning several displays in one picture (a session follows one display at a time) |

## Docs

| | |
|---|---|
| [ARCHITECTURE](docs/ARCHITECTURE.md) | capture → tiles → protocol → injection, CLI and env vars |
| [PROTOCOL](docs/PROTOCOL.md) | every escape sequence krd sends, and why |
| [TESTING](docs/TESTING.md) | self-test, tile/placement calibration, how to test a new terminal |
| [ENCODING](docs/ENCODING.md) | where the bytes and milliseconds go, and the benchmark behind it |
| [BENCHMARK](docs/BENCHMARK.md) | the benchmark layers, the budgets, and what "fast" has to mean here |
| [research: photo bandwidth](docs/research-photo-bandwidth.md) | why colour-heavy motion costs 13.58 MB/frame and what each fix is worth, with the probe that measures it |
| [TROUBLESHOOTING](docs/TROUBLESHOOTING.md) | 47 symptoms with root causes |
| [DEPLOY](docs/DEPLOY.md) | install, permissions, signing, SSH on the far side |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).

## The mascot

<p align="center">
  <img src="docs/media/mascot.png" alt="krd's mascot: a hermit crab drawn in the terminal" width="680">
</p>

**A hermit crab** — and not just because it was the cutest sketch on the page.

`SSH` stands for *secure shell*, and a shell is exactly what a hermit crab lives in. krd brings no
client, no port and no codec of its own: it moves your Mac's desktop into the shell you already have
open. Close the shell, reconnect, switch terminals — the crab walks out with the same desktop on its
back. That is the whole product in one animal.

Everything else lines up too: the claw is a capture, one frame at a time; the eyes on stalks are the
two things it has to watch (the screen it reads, the terminal it paints into); the spiral is drawn
with the same rounded cells as the tile grid going down the wire.

It is drawn **twice from one geometry, by the terminal itself** — 24-bit half blocks for the
picture, one ASCII character per cell for the text version — so the logo is made of the same cells
the product is made of. `node docs/brand/tui/logo-tui.mjs` to see it move.

## Contact

X: [**@zzjcoo**](https://x.com/zzjcoo)

For bugs and feature requests please open an
[issue](https://github.com/zzjcool/krd/issues) — it is easier to track than a DM.

## License

MIT — see [LICENSE](LICENSE).
