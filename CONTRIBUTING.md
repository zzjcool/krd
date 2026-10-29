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

The demo clips live in `docs/media/` (`demo.gif` for the README, `demo.mp4` for the release page) and
are not part of the release tarball. They are a plain screen recording of a terminal pane running
`krd`, compressed with:

```bash
ffmpeg -i raw.mov -vf "scale=720:-2:flags=lanczos,fps=30" -c:v libx264 -crf 27 -pix_fmt yuv420p -an \
       -movflags +faststart docs/media/demo.mp4
ffmpeg -i raw.mov -vf "fps=10,scale=480:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
       -loop 0 docs/media/demo.gif
```

Keep the GIF under ~3 MB; anything larger makes the README slow to load.

## Reporting bugs

Include: macOS version, terminal + version, local or `ssh -t`, the exact command line, the
`--debug --log` output (redact IPs/hostnames), and whether `--selftest` draws. Security issues go to
[SECURITY.md](SECURITY.md), not the issue tracker.

## License

By submitting a pull request you agree that your contribution is licensed under the same MIT terms
as the rest of the project.
