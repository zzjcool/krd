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
krd --display 1 --fps 30
krd --no-input               # watch only
krd --no-cursor              # no pointer in the picture, and a moving mouse stops dirtying tiles
krd --debug                  # stats to a log file, never to the screen
krd --format rgba            # fall back to f=32 if the terminal rejects f=24
krd --bench                  # time the encoder on synthetic frames, no terminal needed
make bench                   # every layer + budget verdicts -> bench/report.md
```

Exit with **`Ctrl-\`**. `Ctrl-C` is forwarded to the remote desktop, like on a real machine.
Flags, tuning knobs and the diagnostics switches: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[docs/TESTING.md](docs/TESTING.md).

## Requirements

- macOS 14 or newer.
- A terminal that speaks the kitty graphics protocol: **rex**, **Ghostty**, **kitty**, **WezTerm**.
  Terminal.app does not.
- One-time approval of **Screen Recording** (capture) and **Accessibility** (input) — the installer
  prints the exact prompt. Details and failure modes: [docs/DEPLOY.md](docs/DEPLOY.md).

## Status

| | |
|---|---|
| Solid | tile-dirty rendering (8×4 cells, parallel zlib, per-tile level), static screens cost 0 bytes/s, pointer following, left/middle/right click, double click, wheel, keyboard, window mode, SSH |
| Rough | colour-heavy full-screen motion (no codec yet), Herdr's image-delete semantics |
| Not yet | kitty keyboard protocol (`Cmd` combinations, key release), clipboard, IME input, multi-display hot switch |

## Docs

| | |
|---|---|
| [ARCHITECTURE](docs/ARCHITECTURE.md) | capture → tiles → protocol → injection, CLI and env vars |
| [PROTOCOL](docs/PROTOCOL.md) | every escape sequence krd sends, and why |
| [TESTING](docs/TESTING.md) | self-test, tile/placement calibration, how to test a new terminal |
| [ENCODING](docs/ENCODING.md) | where the bytes and milliseconds go, and the benchmark behind it |
| [BENCHMARK](docs/BENCHMARK.md) | the benchmark layers, the budgets, and what "fast" has to mean here |
| [TROUBLESHOOTING](docs/TROUBLESHOOTING.md) | 36 symptoms with root causes |
| [DEPLOY](docs/DEPLOY.md) | install, permissions, signing, SSH on the far side |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).

## Contact

X: [**@zzjcoo**](https://x.com/zzjcoo)

For bugs and feature requests please open an
[issue](https://github.com/zzjcool/krd/issues) — it is easier to track than a DM.

## License

MIT — see [LICENSE](LICENSE).
