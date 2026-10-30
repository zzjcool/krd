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
krd --fps 20                 # mirror the display the pointer is on
krd --list                   # displays and windows; backdrop entries are marked
krd --window Safari          # mirror a single window (a backdrop window is refused, not shown black)
krd --zoom 2                 # show half the screen at twice the density (crop on the capture side)
krd --zoom 3 --zoom-at 200,300   # ...centred on a source point, in global screen points
krd --zoom 2 --zoom-follow   # ...and pan when the pointer reaches the edge of the picture
krd --display 1 --fps 30
krd --no-input               # watch only
krd --cursor                 # draw the target's pointer into the picture (default: hidden —
                             # a drawn pointer dirties tiles every time the mouse moves)
krd --dev                    # TUI layer: a status line and panels under the picture
krd --mock --dev             # the same, with the screen mocked: no permission needed
krd --debug                  # stats to a log file, never to the screen
krd --format rgba            # fall back to f=32 if the terminal rejects f=24
krd --bench                  # time the encoder on synthetic frames, no terminal needed
make bench                   # every layer + budget verdicts -> bench/report.md
```

`--dev` adds a status line (`fps`, `MB/s`, latency) and five panels — stats, devices, settings,
log, help — reached with `Ctrl-\` then `s`/`d`/`f`/`l`/`?`, or by clicking the segment you want.
The picture keeps every row above the status line; a panel takes its rows out of the picture and
gives them back when it closes. `make dev` is the shortcut.

`--mock` swaps ScreenCaptureKit for a desktop drawn in process (`--mock-size WxH`, default
1920x1200). Tiles, dirty rects, the encoder, the placements and the chrome are all the real
code — only the pixels are synthetic, so it needs no permission and never stops. `make dev-mock`.

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
krd ax screen                # every on-screen window, plus the focused element
```

Output is one line per node — `@e3  button  "Save"  value="hi"  [120,80 64x24]  press` — with refs
stable for the life of that dump. Exit codes: `0` ok, `2` usage, `3` no Accessibility permission,
`4` window server unreachable, `5` nothing matched. Text is sanitized: a window title can contain
ESC sequences and those are replaced, not printed. See
[docs/research-ax-text-channel.md](docs/research-ax-text-channel.md) for the measurements.

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
| Rough | colour-heavy full-screen motion: 13.58 MB/frame worst case, costed in [research-photo-bandwidth](docs/research-photo-bandwidth.md) — the cheap fix is 16-bit tiles plus a smaller capture, not a codec; Herdr's image-delete semantics |
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

## Contact

X: [**@zzjcoo**](https://x.com/zzjcoo)

For bugs and feature requests please open an
[issue](https://github.com/zzjcool/krd/issues) — it is easier to track than a DM.

## License

MIT — see [LICENSE](LICENSE).
