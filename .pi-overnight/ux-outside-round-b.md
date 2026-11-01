# Round B4 — outside-in: what should krd steal?

Notes only. No product source, no docs changes: everything below is analysis, and the four
proposals live as GitHub issues (#107, #108, #109, #110). Artifacts (fetched pages, extracted text,
the APC probe) are in `/tmp/krd-overnight/ux-outside/`.

## Method

1. Read the repo's own decisions first, so nothing already decided is proposed again:
   `CONTRIBUTING.md` (no dependencies / no server / never write text to the tty / no per-tile
   deletes / keep `C=1` + per-tile `?2026`), `docs/ARCHITECTURE.md` §1–§7, `docs/PROTOCOL.md`,
   `docs/design-overview.md` (the wall, `U=1` placeholders, §13 the accepted "battery" risk),
   `docs/research-terminal-remote-desktop.md`, `docs/research-ax-text-channel.md`,
   `docs/TROUBLESHOOTING.md`, and `gh issue list --state all --limit 120` (every open and closed issue).
2. Read the protocol and the implementations, not memory: kitty graphics protocol (placeholders,
   delete semantics, `q=`, quotas, animation), tmux `tmux.1` + `CHANGES` + `input.c` +
   `options-table.c`, xterm `ctlseqs` (DECSET 1004), Ghostty `image-storage-limit`, kitty's
   `FOCUS_TRACKING` mode.
3. Read the agent-facing prior art: Playwright aria snapshots, agent-browser (`--delta`,
   `diff snapshot`, `--annotate`), and the macOS-AX MCP tools already catalogued in
   `docs/research-ax-text-channel.md` §14B.
4. Verified every hook by reading the file at HEAD `a438e9c`; one claim was *measured* rather than
   inferred (the APC misparse, below).

## The four proposals

| issue | title | prior art it steals from | cost | confidence |
|---|---|---|---|---|
| [#107](https://github.com/zzjcool/krd/issues/107) | feat: work inside tmux — DCS-passthrough the graphics APCs | kitty's own rationale for `U=1` ("…tmux, vim, weechat…"); tmux `allow-passthrough` (3.3, default off), `input.c` ESC-doubling inside DCS; bicat / `mpv --vo=kitty` nested-tmux support | ~50–70 LOC in `krdcore` + 15 plumbing + 4 doc files | high (protocol + source), **not** verified in a live tmux (none on this box) |
| [#109](https://github.com/zzjcool/krd/issues/109) | feat: hear the terminal — parse graphics replies (`q=1`) | kitty "Suppressing responses" (`q=1` = errors only); kitty/Ghostty image quotas; krd's own `PROTOCOL.md` §8 admission | ~60 LOC parser + 25 filter + fixtures | high — the misparse is **measured** (`apc-probe/out.txt`) |
| [#108](https://github.com/zzjcool/krd/issues/108) | feat(ax): `krd ax tree --diff`, `unchanged` when nothing did | agent-browser `snapshot --delta` / `diff snapshot`; Playwright aria snapshots as a comparable serialization; mediar "tree diff after each action" | ~120 LOC (one new pure file + tests) | high — the anchor chains it needs are already on disk |
| [#110](https://github.com/zzjcool/krd/issues/110) | feat: idle the picture when the pane loses focus | xterm DECSET 1004 + `CSI I`/`CSI O`; kitty `FOCUS_TRACKING`; tmux `focus-events`; the vim/htop/lazygit pattern | ~70–110 LOC | high (small, fail-safe design), payoff depends on the desktop animating |

Human-facing: #107, #109, #110. Agent-facing: #108 (and #109 indirectly — a silent refusal is the
agent's most expensive failure mode).

### The one measured claim

`Sources/krdcore/Input.swift:113` switches on `buffer[1]` for CSI / SS3 / OSC and falls through to
`default:` at `:152`, where `ESC` + char becomes Alt+char. APC (`ESC _`) has no case, so a kitty
graphics reply is parsed as keystrokes. A five-line harness around the real parser (sources copied
verbatim, no product change):

```
ok             : 13 B -> 11 events
   text("_", maskAlternate) | text("G") | text("i") | text("=") | text("1") | text("0") | text("0")
 | text(";") | text("O") | text("K") | text("\\", maskAlternate)
```

That is `PROTOCOL.md` §8's warning, confirmed: with `KRD_Q=0` and input enabled, every reply is typed
into the remote desktop — one reply per image, per frame.

## Considered and rejected

| idea | why not |
|---|---|
| **kitty animation** (`a=f` frames, `a=a` client-driven pacing, `a=c` frame composition) | The protocol added it because "client driven animations are not sufficient … especially over SSH" — true for *video*, which krd cannot afford anyway (`#26` closed, 259 MB/s on photo content). For a desktop the delta channel is already krd's tile diff; terminal-side playback would add a second frame state machine, a new stuck-frame failure mode, and no visible win. |
| **`z=` z-index, relative placements (`P`,`Q`, kitty 0.31)** | Overlays would be the only use, and text over a `U=1` picture is a hole in the picture (`Chrome.swift:9-10` already forbids it). Relative placements exist for hosts that scroll images; krd pins whole cells. |
| **`a=q` as a startup handshake** | It answers "is graphics supported" and the kitty version — neither changes a decision. The one thing krd needs to know (`U=1` support) is not answerable by `a=q`, which is why the 1×1 placeholder probe exists (`design-overview.md` §6.9). Superseded in spirit by #109, which *listens* instead of asking. |
| **`t=t` / `t=s` mediums (temp file, shared memory)** | Requires a shared filesystem / a local client. desktui advertises 15× from shm; unavailable through ssh (`research-terminal-remote-desktop.md` §3.1). |
| **per-tile deletes, delete-then-place** | Forbidden (`CONTRIBUTING.md` §2) and empirically hazardous (Herdr/rex treat `a=d,i=` as drop-all). Fixed ids already bound the store; nothing to reap. |
| **MCP server for `krd ax`** | Needs a host process and breaks "started by a human in an ssh session" — the repo rejected it in `research-ax-text-channel.md` §7. #108's `--diff`/`--delta` is exactly the shape an external MCP adapter would wrap. |
| **`krd ax watch` (AXObserver push)** | Long-running, out of scope by the same paragraph. Pull-with-a-baseline gets most of the value without a daemon. |
| **Annotated picture (`--marks`, agent-browser's `[N]` overlay)** | With `U=1` a label cell replaces a placeholder cell, so the picture gets a hole exactly where the label is. agent-browser composites its own raster; krd deliberately has no scaler/compositor (`design-overview.md` §6.6). Would need a gutter or a second screen — a bigger design change than it looks. |
| **A tmux capability query from inside krd** | There is no terminal-side query for "will you forward an APC"; `TERM` + an explicit flag is the honest signal (and the reply channel doesn't exist yet — #109). |
| **VideoToolbox/HEVC, an RFB server, ttyd-style web client** | All need a codec, a listener or an alternative protocol: out of scope by `CONTRIBUTING.md`, and `#26` is closed. |
| **OSC 9;4 progress / OSC 2 title as a "which pane" hint** | Real but tiny; tmux gates titles behind `allow-set-title`, and it would not survive as a standalone issue. |
| **`reapInterval` (periodic delete-all + repaint)** | Dead code by design (`PROTOCOL.md` §6.3); the placement set is bounded by the tile grid. |

## Honest limits of this round

- No tmux on this machine, so #107's evidence is the protocol, tmux's own source/man page and krd's
  code — not a pane capture. The verification recipe is in the issue.
- #110's payoff depends on the remote desktop actually animating while the pane is unfocused; the
  issue states the mechanism and the counters to read rather than a fabricated number.
- `docs/PROTOCOL.md` §5 still says "unicode placeholders … not used by the renderer" while
  `Render.swift:471-600` and `design-overview.md` §6.9 say they are the default. That is a docs
  drift worth a separate one-line fix (not filed: below the bar for an issue of its own).
