# Contributing

Thanks for looking. krd is small on purpose: one executable, no dependencies, one job. Patches that
keep it that way are welcome.

## Before you start

- **Scope.** krd renders a macOS desktop into a terminal pane and injects input. Rendering, the
  protocol subset, geometry, input fidelity, latency and bandwidth are in scope. So are docs and
  terminal-calibration results.
- **Out of scope, by design:** anything that runs without a human starting it (auto-start, a
  service, a listening socket, a built-in remote-access server), and an alternative remote-desktop
  protocol. krd is started by a human in an SSH session and exits with it; keep it that way.
- **No new dependencies.** `Package.swift` has exactly one target plus the system `CZlib` shim.
  Adding SwiftPM packages for something the system frameworks already do will be declined.
  Speed is not a reason on its own: the encoder is under 2 % of the 50 ms frame budget
  ([docs/BENCHMARK.md](docs/BENCHMARK.md)), so a faster compressor buys nothing a viewer can see
  (measured in #8, declined there). The one accepted mechanism, if that ever changes, is a
  `systemLibrary` target with a one-line `module.modulemap` and a **static** link, so
  `deploy.sh` still ships a single file — no vendored source trees, no SwiftPM packages.
- **Read first:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (especially §7, the rendering
  invariants), [docs/PROTOCOL.md](docs/PROTOCOL.md) (why no deletes, why `C=1`), and
  [docs/TESTING.md](docs/TESTING.md).

## Build and run

```bash
swift build -c release                  # macOS 14+, Xcode command line tools, Swift 5.9 tools
.build/release/krd --selftest           # renderer check: no permissions, no capture
.build/release/krd --list               # needs Screen Recording
./scripts/install-from-source.sh       # build from this checkout, sign, install to ~/bin/krd
```

Use a terminal that implements the kitty graphics protocol — the calibration switches below cannot
tell you anything in one that does not (Apple Terminal.app).

## The development loop: Rex and tart

Everything visual in this repo was found by running krd in a real terminal and reading what came
back, so that loop is written down as a project skill instead of being rediscovered each time:

```
.agents/skills/krd-dev/SKILL.md          # the loop, the pitfalls, the A/B protocol
.agents/skills/krd-dev/scripts/deploy-vm.sh    # build → codesign → install into the tart VM
.agents/skills/krd-dev/scripts/wall-runs.py    # read a frame's picture rectangles out of a capture
scripts/shaped-link.sh                   # a slow link in front of that VM, and krd's numbers through it
```

Short version: run the build in a **Rex** pane (`rex send` / `rex capture --format=vt`), read the
pictures' cell rectangles from the placeholder run (`U+10EEEE` survives a text capture — the pictures
do not), read krd's own numbers from `--demo`'s footer or `--debug --log`, and deploy to the tart VM
with the script (its Screen Recording grant lets it capture a real desktop). Never screenshot a
user's desktop; a locked screen makes it impossible anyway, which is why the numbers are in the text.

## What your change must pass

There is no XCTest target; the checks are protocol-level and visual, and they are reproducible:

```bash
swift build -c release
.build/release/krd --selftest --no-input                  # quadrants + sweeping bar, no tearing
KRD_GRID=1 .build/release/krd --selftest --no-input       # placement: white borders, no gaps
KRD_GRID=1 .build/release/krd --selftest --tile 8x4       # and with unusual tiles
KRD_QUADRANTS=1 .build/release/krd --selftest --no-input  # which shapes this terminal honours
KRD_DUMP=/tmp/d.bin .build/release/krd --selftest --no-input >/dev/null   # bytes, offline
```

Plus, depending on what you touched:

| Area | Also do |
|---|---|
| rendering / protocol | diff `KRD_DUMP` output before and after; confirm `KRD_Q=0` shows no `EINVAL`/`ENOENT`; try `--tile 8x4` and `--tile 32x16` |
| geometry / layout | check at two window sizes and after a live resize; `--cell 17x33` vs a terminal that reports pixels |
| input | `--dry-run --debug` and compare logged coordinates with a known cell; drag, wheel, arrow keys, Ctrl-A…Z, Alt+key |
| capture / permissions | state the macOS version and whether `--debug` logged `accessibility trusted=true` |
| anything | keep `--no-input`, `--full-frame` and `--selftest` working; they are the diagnostic path |

Report what you tested with: **terminal + version, macOS version, whether it was local or over
`ssh -t`**. A screenshot of `KRD_GRID=1` is the most useful single artifact.

## If you are adding terminal support

Work through §8 of [docs/TESTING.md](docs/TESTING.md) (calibration) and add a row to the
compatibility table in both READMEs, including what you actually verified (picture / click / drag /
keyboard) and what you did not. "Expected to work" is fine to state as long as it is labelled that
way.

## House rules for code

1. **Never write text to the tty.** Not a `print`, not a debug line, not a banner. Diagnostics go
   through `Log` to a file. A single line moves the cursor and scrolls the grid, and the picture
   shreds (see [TROUBLESHOOTING](docs/TROUBLESHOOTING.md#31-a-line-of-debug-output-destroys-the-picture)).
2. **Never send a per-tile delete.** One image id and one placement id per tile, overwritten in
   place. If a terminal needs something else, add a switch and document it.
3. **Keep `C=1` and the per-tile `?2026` block** unless you can show the replacement is atomic on
   rex, Ghostty and kitty.
4. **Keep the frozen identifier** `com.kkrt.macdesk` in `install.sh` / `deploy.sh`: TCC records the
   Screen Recording grant against it.
5. **Match the existing style**: Swift 5.9, no formatting churn, comments that explain *why* (the
   code already says what).
6. **Update both languages.** `README.md` ↔ `README.zh-CN.md`, `docs/X.md` ↔ `docs/X.zh-CN.md`.
   Every flag, default or env var you add must appear in both, spelled exactly as the code spells it.
7. **Small, focused commits** with a real message ("why", not "what"). Do not commit generated
   files, `.build/`, or dumps.

## If a Rust core ever lands

Do not start here: the decision record is [docs/decision-rust.md](docs/decision-rust.md), and it says
what has to be true first. If one of its triggers fires, this is the shape the port takes — decided
now so the first PR does not invent its own boundary.

- **Where it lives.** `Sources/krdcore-rs/` (a Cargo crate) is built as a static library and exposed
  to Swift by `Sources/krdcoreffi/` (a `systemLibrary` module map). `Sources/krdcore` stays as the
  Swift implementation, and `Package.swift` is the only place that chooses between them. `krd` imports
  `krdcore` either way; **no call site outside `Sources/krdcore` may change.**
- **What the boundary is.** The C surface is deliberately tiny, and it is the same five entry points
  the Swift module's API already implies:

  ```c
  krd_encoder *krd_encoder_new(int32_t tile_cols, int32_t tile_rows, int32_t bpp);
  void         krd_encoder_free(krd_encoder *);
  // One frame: pixels are borrowed for the duration of the call (no copy), and the escapes are
  // written to `out_fd` by Rust itself so the bytes never cross back into Swift.
  int32_t      krd_encode_frame(krd_encoder *, const uint8_t *pixels, int32_t w, int32_t h,
                                int32_t stride, int out_fd, krd_frame_stats *stats_out);
  krd_parser  *krd_parser_new(void);
  void         krd_parser_free(krd_parser *);
  // One read(2): POD events through the callback, one call per event (~100 ns), called on the
  // thread that read the bytes.
  size_t       krd_parse(krd_parser *, const uint8_t *bytes, size_t len,
                         krd_event_cb cb, void *ctx);
  ```

  The OS half — ScreenCaptureKit, `NSApplication`, `CGEvent`/`postToPid`, termios, `NSPasteboard`,
  AX — stays Swift. It is the part that is fragile and the part a language change does not improve.
- **What must not regress.** Both committed fixtures must reproduce byte for byte from the Rust build:
  `Tests/krdcoreTests/Fixtures/selftest-80x24-17x33-l6.dump` (sha256 `2e893d04…`) and
  `Tests/krdcoreTests/Fixtures/input-trace.dump`. The `--debug` parity procedure in
  [docs/TESTING.md](docs/TESTING.md) runs against both implementations, and `bench/budget.json` stays
  the regression gate.
- **What it does not buy.** A pure-Rust binary still has to answer `ARCHITECTURE.md` §4 (one frame
  without an AppKit context kills the stream) and TCC's code-signature binding. That is a separate
  decision, and the decision record says not to take it.

## Pull requests

- One concern per PR. Describe the failure you observed, the cause you found, and how you verified
  the fix (commands + what you saw).
- If the change is user-visible, say which terminal you calibrated on.
- CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs on **pull requests** (and on
  demand), not on every push: `swift build -c release`, `swift test` only if a `Tests/` directory
  exists (it does not today), and a universal `--arch arm64 --arch x86_64` build. Release tags are
  built *and* tested by `.github/workflows/release.yml` before anything is published. A red build
  is not reviewable. CI cannot draw escapes into a
  terminal, so protocol/geometry/input changes still need the manual checks above — say in the PR
  which ones you ran.

## Releases

Do not edit `VERSION` or `Sources/krd/Version.swift` by hand. Both are rewritten by
[`scripts/release.sh`](scripts/release.sh), which refuses a dirty worktree, keeps the two files in
sync, commits `chore(release): vX.Y.Z`, tags `vX.Y.Z` and pushes branch + tag:

```bash
./scripts/release.sh 0.2.0 --dry-run   # validate and print the plan
./scripts/release.sh 0.2.0             # do it
```

The tag triggers [`.github/workflows/release.yml`](.github/workflows/release.yml), which re-checks
that the tag matches `VERSION` and `Version.swift`, builds the universal binary, and publishes
`krd-vX.Y.Z-macos-universal.tar.gz` + `.sha256` to the GitHub Release. That tarball is **not** signed
with a local identity — users who care about a stable TCC grant sign it themselves (see
[docs/DEPLOY.md](docs/DEPLOY.md)).

The demo clips live in `docs/media/` (`demo.gif` for the README, `demo.mp4` for the release page,
`demo-poster.png` as its still) and are not part of the release tarball. They are a plain screen
recording of a terminal pane running `krd` — drop the dead lead-in, then compress with:

```bash
ffmpeg -i raw.mov -vf "scale=720:-2:flags=lanczos,fps=30" -c:v libx264 -crf 27 -pix_fmt yuv420p -an \
       -movflags +faststart docs/media/demo.mp4
ffmpeg -i raw.mov -vf "fps=12,scale=640:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
       -loop 0 docs/media/demo.gif
ffmpeg -ss 10.6 -i docs/media/demo.mp4 -frames:v 1 -y docs/media/demo-poster.png   # a frame where the wall is painted
```

`640` is the width the README renders at, so the GIF stays sharp on a retina screen.

Keep the GIF under ~3 MB; anything larger makes the README slow to load.

## Reporting bugs

Include: macOS version, terminal + version, local or `ssh -t`, the exact command line, the
`--debug --log` output (redact IPs/hostnames), and whether `--selftest` draws. Security issues go to
[SECURITY.md](SECURITY.md), not the issue tracker.

## License

By submitting a pull request you agree that your contribution is licensed under the same MIT terms
as the rest of the project.
