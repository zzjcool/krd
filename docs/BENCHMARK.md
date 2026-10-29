# Benchmarks: what to measure, where, and what counts as a regression

`ENCODING.md` answers "how many bytes and how many milliseconds". This document answers the
larger question: **which numbers decide whether krd is fast, which of them can be measured
honestly, and where the harness lives.** It is the plan; `ENCODING.md` stays the results table.

## 1. What exists today, and what is blind

| Harness | Measures | Blind to |
|---|---|---|
| `krd --bench` | dedupe, dirty, extract, zlib, base64, assembly; p50/p95/p99; payload + wire bytes | `write(2)`, real content, ScreenCaptureKit |
| `make bench` | all of the above + the pty harness + budget verdicts, in one report | terminal-side paint latency (see §8) |
| `--debug` stats line (1 Hz) | tiles/s, KB, MB/s, `ms[zlib, write, max, over5]`, captures/idle/bad, `pipe` | anything comparable across runs unless you add `--stats-json` |
| `probe/kbench.py` | raw pty throughput of a *foreign* Python encoder | krd itself |
| `probe/kpace.py` | backpressure at a fixed frame rate, same foreign encoder | krd itself |

The encoded payload is `0.3–1 ms` per frame for the content that runs 20 times a second, against a
50 ms frame budget — **under 2 %**. So more encoder micro-optimisation is not where the remaining
speed is. The blind spots that matter are the ones the current harness cannot see at all:

1. **Nothing measures the write path.** `flush()` blocks in `write(2)` when the terminal is behind.
   The stats line reports `write=<ms>` but only as a 1 Hz average of a number that spikes.
2. **Dirty detection and the whole-frame dedupe are unmeasured.** `TileGrid.dirty` memcmps the
   whole frame per grid pass (10.1 MB at `f=24`, 13.5 MB at `f=32`); `Capturer` does one `Array`
   equality over the same buffer before that. Both run on every delivered frame, including frames
   that end up emitting nothing.
3. **No distribution.** Best-of-6 hides the p99 that users feel as a stutter.
4. **No end-to-end number.** "Frame captured at T, last byte out at T+n" does not exist anywhere.
5. **No machine-readable output**, so "did this PR regress?" is answered by reading a table.
6. **The measured configuration is not recorded, and it is not what the docs say.** The command
   `--bench --pane 137x44 --cell 17x33` (quoted in `ENCODING.md` and `TESTING.md`) does not measure a
   137-cell-wide picture. `--bench` hardcodes a 1440×2560 source rect (aspect 0.5625), so the
   aspect-fit in `TileGrid.make` shrinks the pane to 48×44 cells / 816×1452 px / 6×11 = 66 tiles:

   ```
   $ krd --bench --pane 137x44 --cell 17x33
   krd: bench 816x1452 px, 6x11 tiles of 8x4 cells, rgb (f=24)
     one character            1        727 ...
     text repaint            66      47485 ...
   ```

   `ARCHITECTURE §6` claims the same command yields 2329×1452 px and `ENCODING.md` still says
   "66 tiles of 8×4 cells" as if that were the 137-wide layout (137×44 would cut 18×11 = 198). The
   table is internally consistent — it is the prose that names the wrong picture. A benchmark whose
   own configuration is neither printed in a machine-readable form nor asserted will always drift
   like this, and every "−66 %" in it silently refers to a frame 2.8× smaller than advertised.

## 2. The five questions a benchmark has to answer here

| # | Question | Number | Budget @ 20 fps |
|---|---|---|---|
| Q1 | How many bytes does a frame cost? | encoded + on-wire bytes/frame | payload ≤ 1 MB on the typing path; 0 on a static screen |
| Q2 | How long does the encode take? | p50 / p95 / p99 per stage | p99 ≤ 8 ms (16 % of the budget) |
| Q3 | Does the terminal keep up? | ms blocked in `write(2)`, frames abandoned | blocked p99 ≤ 5 ms |
| Q4 | How stale is the picture? | capture timestamp → last byte out | p99 ≤ 1 frame interval + encode |
| Q5 | What does it cost the Mac? | user+sys CPU per frame, CPU % at steady state | ≤ 15 % of one core at 20 fps |

Q1 is what `--bench` already does. Q2/Q3/Q4/Q5 need new instrumentation. Everything below is
organised so that each of those five numbers has exactly one owner.

## 3. Layers

Each layer is headless-capable unless stated, and each one has a different reason to exist. Do not
skip L2 to get to L3: L2 is the only layer that can run in CI and the only one that sees
backpressure.

| Layer | Scope | Harness | Needs a terminal | In CI | Cost |
|---|---|---|---|---|---|
| **L0** micro | pure functions: `dirty`, `extract`, `zlibCompress`, base64, escape assembly | XCTest `measure` | no | yes | seconds |
| **L1** pipeline | the real encoder, synthetic frames, no pty | `krd --bench` (extended) | no | yes | seconds |
| **L2** wire | krd under a pty against a rate-limited drain | hidden `--bench-wire` + `bench/wire.py` | no (a pty counts) | yes | seconds |
| **L3** soak | a real session at real fps, per-second NDJSON | `--stats-json` | yes | no | minutes |
| **L4** replay | real captured frames, deterministic | `KRD_RAWDUMP` + `--replay` | no | no | minutes |

L3 is the layer people already run by eye; the only change is that its output becomes a file that
can be diffed. L4 exists because synthetic frames are the one thing every layer above shares, and
synthetic frames lie about one thing that matters: real screen content is neither uniform text nor
uniform noise.

## 4. The canonical corpus

Content classes (one generator each, in `Bench.swift`; L4 replays real ones):

| class | generator | represents |
|---|---|---|
| `text` | flat background + glyph-like strokes | editor, terminal, docs |
| `noise` | hash noise, no LZ77 matches | photo, video with dithering |
| `ui` | flat blocks with 1 px borders | Finder, browser chrome, IDE panels |
| `gradient` | smooth ramp | wallpapers, video pans (zlib's bad case) |

Cases, each of which asserts its own dirty-tile count:

| case | content | delta per frame | tiles |
|---|---|---|---|
| `char` | text | a 24×48 block moving 1 px inside one tile | exactly 1 |
| `line` | text | glyph strokes across one tile row | exactly `tilesX` |
| `full` | text | strokes across the whole frame | all |
| `photo` | noise | whole frame, reseeded | all |
| `gradient` | gradient | whole frame, reseeded | all |
| `ui` | ui | whole frame, reseeded | all |
| `drag` | noise | a 600×400 region moving | region ∩ tiles |
| `none` | text | nothing | **0** |

The assertion matters more than it looks: the first version of `char` applied its delta to the
*previous* frame, so the moving block painted over its own last position, the second round was
byte-identical, and the case measured "idle" while claiming "one character". A harness that checks
its own premise fails loudly instead of producing a plausible number.

## 5. Layer detail (as built)

### L0 — micro (`Tests/krdTests/BenchTests.swift`)

`swift test -c release --filter MicroBench`, because a debug build of the Array-heavy paths is
10–30× slower. Each benchmark also asserts the invariant it depends on, so "slower" and "wrong"
cannot look the same:

- `TileGrid.dirty`: identical buffers (0 tiles, the hot path), one 24×48 block (1 tile), all (198)
- `TileGrid.extract`: a full tile and an edge tile
- `zlibCompress` at levels 1/5/9 for text and noise — the table that justifies `LevelPolicy`
- `Data(payload).base64EncodedString()` — the `emit` round trip, so a rewrite has a number to beat
- `emit` with `discardOutput = true`

### L1 — pipeline (`krd --bench [--json]`)

`Bench.runStages` walks every case for `--rounds` measured frames plus 3 warm-up frames, and per frame
records: the whole-frame dedupe, `TileGrid.dirty`, the serial reference (once per case, outside the
timed frames — putting it inside made `total` include two compressions), the live parallel encode,
and the escape assembly with a per-tile timer that only exists when a bench asks for it.

Actual emitted schema (one line of it shown per case):

```json
{"schema": 1, "krd": "0.1.2", "build": "release",
 "machine": {"model": "MacBookPro18,3", "arch": "arm64", "cores": 10, "os": "27.0.1"},
 "config": {"pane": "137x44", "cell": "17x33", "tile": "8x4", "format": "rgb",
            "px": "2329x1452", "tiles": 198, "rounds": 30, "source": "1920x1200"},
 "cases": [{"name": "char", "content": "text", "tiles": 1,
            "bytes": {"payload": 326, "wire": 541},
            "ms": {"dedupe": {"n":30,"p50":3.37,"p95":…,"p99":…,"max":…,"mean":…},
                   "dirty": {…}, "extract": {…}, "zlib": {…}, "base64": {…},
                   "assemble": {…}, "serial": {…}, "parallel": {…}, "total": {…}}}]}
```

`config` is the effective layout, never the flag value, and `bench/check-docs.py` pins
`docs/ENCODING.md` to it. `--json` puts this on stdout and the human table on stderr.

### L2 — wire under a pty (`bench/wire.py` + `krd --bench-wire`)

`--bench-wire <case>` feeds one corpus case through the **real** `handleFrame` at `--fps`, writing
production escapes to stdout and one JSON line per frame to stderr; `bench/wire.py` runs it with a
pty on stdout and drains at a token-bucket rate. Measured by the harness: bytes, achieved MB/s,
frames, late frames, bytes after the first frame. Measured by krd: `write_ms` (blocked in
`write(2)`), `pipe_ms` (callback → last byte), `compress_ms`, payload, tiles.

That is where the interesting number lives. At 5 MB/s (a plausible SSH link) a 600×400 drag of
photo-like content blocks `write` for **2.4 s per frame** and every frame arrives late — krd keeps
its promise (no tearing, no dropped frame), it just cannot go faster than the link. On an
unlimited drain the same case blocks for 0.6 ms.

The static-screen invariant is asserted there, not observed: `wire.py --assert-zero-bytes` on the
`none` case must report `bytes_after_first_frame == 0`, and `budget.json` fails the run otherwise.

### L3 — soak (`--stats-json`)

`startStats()` already built every field; `--stats-json <path>` writes them as one NDJSON line per
second, plus `write_max_ms`, `write_over5`, `pipe_ms`. `bench/soak-report.py` turns the file into
percentiles and a verdict ("the terminal is behind; lower --fps or use --tile 16x8"). Not in CI: no
stable machine, no screen to capture.

### L4 — replay real content (`--record` / `--replay`)

```bash
krd --record /tmp/frames --record-frames 60 --fps 20     # while you work, then Ctrl-krd --replay /tmp/frames --bench                          # same frames, no screen, no TCC
```

The manifest starts with a header line carrying pane/cell/tile/source/format, so a replay rebuilds
the exact layout instead of guessing; a mismatch is a clear error, not a blank screen. Recording 60
frames of the reference layout is ~800 MB, which is why the default limit is 60 and not "everything".

## 6. Budgets, and what fails

`bench/budget.json`, checked in, machine-tolerant by construction:

| check | budget | rationale |
|---|---|---|
| `char` payload | ≤ 900 B | 2.7× headroom over 326 B |
| `char` total p99 | ≤ 3 ms | 6 % of a 50 ms frame |
| `line` payload | ≤ 12 KB | |
| `full` text payload | ≤ 120 KB | |
| `photo` payload | ≤ 20 MB | content-dominated, so this only catches a format regression |
| `photo` total p99 | ≤ 120 ms | a runner is ~2× this laptop |
| `none` payload / wire | 0 B / ≤ 64 B | a delivered frame that changed nothing |
| `none@unlimited` bytes after frame 1 | **0** | static desktop is free, per pty |
| `line@unlimited` write p99 | ≤ 10 ms | |
| `line@unlimited` late frames | ≤ 3 | |

CI runs `python3 bench/bench.py --quick --rounds 8` as a step in `.github/workflows/ci.yml`: encoder
plus two wire runs (~8 s) and the budget verdict. It does **not** compare against a committed timing
baseline — a macOS runner is not the same machine class as the laptop these come from, and a gate
that fails on runner noise is deleted within a week. Bytes, tile counts and the zero-byte invariant
are deterministic, so those are gated.

### A/B two revisions (`make bench-ab`)

The PR-facing workflow: one command, one markdown block, ready to paste.

```bash
make bench-ab                 # working tree vs origin/main (or main)
make bench-ab REF=v0.1.1      # working tree vs a tag
make bench-ab REF=HEAD        # noise floor: same code twice, expect ~0 %
make bench-ab REPS=5 ROUNDS=30
```

`bench/ab.py` builds the ref in a throwaway `git worktree` (the checkout is never stashed or
switched), builds the working tree, then runs both sides **interleaved** — before→after, then
after→before — and takes the median per case. Alternating is not decoration: on a laptop that
warms up over 60 s, a sequential before→then→after run reads as a regression on whichever side
went second.

```
### Benchmarks: `feat/tiles` (a1b2c3d) +dirty vs `main` (e5f6a7b)

MacBookPro18,3 (arm64) · 10 cores · 27.0.1

`2329x1452` px, 198 tiles of 8x4, format `rgb`, pane `137x44`, cell `17x33` · 3 runs per side,
interleaved, median shown

| case | tiles | payload | Δ | total p50 | Δ | total p99 | Δ |
|---|---:|---:|---:|---:|---:|---:|---:|
| char ⚠ | 1 | 326 B → 1.3 KB | +304.9% | 1.20 → 0.99 ms | -17.2% | 1.32 → 1.71 ms | +29.3% |
...

**Verdict: regression.** char (payload +304.9%)
```

Three guards decide whether that block is trustworthy:

1. **Both sides must carry the harness.** A ref that predates `--bench --json` is refused by
   name, not silently compared against a parsed human table: the old `--bench` also used a
   different (portrait) layout, so the numbers would be a 2.8× lie.
2. **The two layouts must match.** `px`, `tiles`, `tile`, `format`, `pane`, `cell` are compared
   before any byte is reported. A PR that changes the default tiling has no A/B — it has two
   different pictures, and the tool says so.
3. **Flags need an absolute floor as well as a relative one** (5 %, 0.2 ms, 16 B). Without it,
   `none` flapped at "p50 +30 %" on a 0.003 ms measurement.

`REF=HEAD` is the sanity check worth running once per machine: it should report ~0 % everywhere,
and the residual spread is this laptop's noise floor. If it reports more than a few percent on a
timing column, that column is not worth quoting from this machine.

## 7. Measurement hygiene (the rules that make the numbers mean something)

1. **Release build only.** Debug Swift `Array` bounds checks dominate everything measured here.
2. **Warm up 3 rounds, discard them.** First-touch page faults on a 10 MB buffer and `LevelPolicy`
   learning would otherwise land in p99 forever.
3. **Never benchmark with `--debug`.** L2 puts the stats in the harness, not on the tty.
4. **Record the configuration**: pane, cell, tile, format, machine, cores, build. It is in every
   JSON and every report; a number without it is a rumour.
5. **Plugged in.** A thermally throttled laptop halves the parallel speedup, which shows up as a
   regression in every serial/parallel column.
6. **Report the tail.** Every table has p50 and p99 or it is not comparable.
7. **Same machine for A/B**, minutes apart, same pane size.

## 8. What is deliberately not measured

**Terminal-side paint latency.** The pty tells us when the terminal *accepted* bytes, not when it
composited a frame. There is no ack in the kitty protocol for `a=t` + `a=p`. L2 measures drain time
and blocked writes; optical latency needs a camera pointed at the pane, which is a once-per-terminal
calibration, not a CI check. `--selftest`'s moving bar exists for exactly that.

**ScreenCaptureKit cost.** Only visible in a live `--debug` run as `cap=` and `pipe=`. Anything finer
needs `powermetrics`, which needs root, which this project does not ask for.

**The whole-frame dedupe on a static screen in production.** It is measured here as a 10 MB memcmp
(6.8 ms), which is the honest cost of a *delivered* frame; in production ScreenCaptureKit usually
does not deliver one at all, so the real number is lower. The benchmark deliberately does not model
that discount.

## 9. Status

| Phase | Content | State |
|---|---|---|
| P0 | `--bench --json` + stage timers + percentiles + `--source` + budgets + CI step | **done** |
| P1 | `bench/wire.py` + `--bench-wire` + the zero-byte invariant | **done** |
| P2 | `--stats-json` + `bench/soak-report.py` | **done** |
| P3 | `--record` / `--replay` + the frame-fixture header | **done** |
| P4 | `bench/ab.sh`, `bench/history/`, `bench/check-docs.py` | **done** |
| next | terminal-side pixel latency via a screen recording of `--selftest`, if it ever matters | open |

## 10. File map

```
Makefile               make bench / bench-quick / bench-wire / bench-replay / bench-ab
bench/
  bench.py             runs L1+L2, evaluates budget.json, writes bench/report.md
  wire.py              L2: pty + rate-limited drain, per-frame JSON out of krd
  compare.py           two --bench --json files -> deltas, fails on regression
  ab.py                same-machine A/B: worktree, interleaved runs, medians, markdown
  ab.sh                thin wrapper for ab.py
  soak-report.py       L3: NDJSON -> percentiles + verdict
  check-docs.py        ENCODING.md's config line vs the last run
  budget.json          the table in §6
  history/             one JSON per release
  results/             last run (gitignored)
  report.md            make bench output (gitignored)
  ab-report.md         make bench-ab output — paste this into the PR (gitignored)
Sources/krd/
  Bench.swift          corpus, percentiles, JSON, --bench-wire, --stats-json
  Replay.swift         --record / --replay
Tests/krdTests/
  BenchTests.swift     L0
docs/
  BENCHMARK.md         this document
  ENCODING.md          results, with the config line check-docs.py verifies
```
