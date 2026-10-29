# Decision: Rust, and why the option is now cheap

**Status:** decided (2026-10-30), revisitable only through the triggers in §4.
**Owns:** issue [#9](https://github.com/zzjcool/krd/issues/9). **Depends on:** #21 / #43 / #46 (`krdcore`).
**中文版:** [decision-rust.zh-CN.md](decision-rust.zh-CN.md)

## 1. The decision

Not now. But "not now" is only honest if a port would no longer be a rewrite — and as of #21 that
is true: the whole byte contract (tiles, level policy, zlib, escape assembly) and the whole input
protocol (CSI/SS3 state machine, `Event`s) live in `krdcore`, with no Apple imports, pinned by two
committed fixtures. A future port replaces that module; it does not re-derive it.

The old phrasing of this issue — "the language is 1.2×, the algorithm is 33×" — is still correct and
still gets misread: the 33× was a *product* of three levers, and two of them already shipped. This
document replaces the mental model with the measurements that exist today.

## 2. What is actually left on the table

The numbers below are from `bench/bench.py` on the reference laptop (MacBookPro18,3, 10 cores),
`main` @ `e82844d`, 16 budget checks passing. Full report: `bench/report.md`; method:
[BENCHMARK](BENCHMARK.md) §7. Frame budget is 50 ms (20 fps).

| case | encode p50 | encode p99 | p99 as % of the 50 ms budget |
|---|---:|---:|---:|
| `char` (one character) | 1.31 ms | 1.64 ms | 3.3 % |
| `line` (one line of text) | 1.44 ms | 2.52 ms | 5.0 % |
| `drag` (a dragged window) | 4.06 ms | 4.44 ms | 8.9 % |
| `gradient` | 3.57 ms | 4.01 ms | 8.0 % |
| `full` (whole screen changes) | 7.52 ms | 7.91 ms | 15.8 % |
| `ui` (list scroll) | 6.22 ms | 9.14 ms | 18.3 % |
| `photo` (hash noise) | 24.49 ms | 30.53 ms | 61.1 % |

The content that runs 20 times a second is `char`/`line`/`drag`: **≤ 5 % of the budget**. The 1.2×
that Rust is credited with was measured on the pre-#2 single-threaded encoder; applied to what is
left today it is an *upper bound*:

| case | today p99 | with a 1.2× faster encoder | saved |
|---|---:|---:|---:|
| `char` | 1.64 ms | 1.37 ms | 0.27 ms (0.5 % of the frame interval) |
| `line` | 2.52 ms | 2.10 ms | 0.42 ms (0.8 %) |
| `full` | 7.91 ms | 6.59 ms | 1.32 ms (2.6 %) |
| `photo` | 30.53 ms | 25.44 ms | 5.09 ms (10 %) |

`photo` looks like the exception, and it is exactly the case where the language does not help: this
frame is 9.68 MB of payload / 13.58 MB on the wire, zlib compresses it **~1.00×** (10.15 MB out of
10.14 MB of pixels), and a local pty tops out at 103.6 MB/s, so the case already runs at ~8 fps with
the CPU idle waiting on the pipe. The lever there is bytes-per-pixel or pixels-captured, measured in
[research-photo-bandwidth](research-photo-bandwidth.md) §0: 16-bit quantisation before zlib is
**1.57×** on the wire, capturing at ½ scale is **4.56×**, and a real photograph (not hash noise) is
6.32 MB today / 1.27 MB at 16-bit. **The next big win is fewer bytes, not a faster language.**

So the remaining upside of a port is 0.3–1.3 ms on the frames a user actually sees, i.e. 0.5–2.6 % of
the frame interval, with the worst content bounded by the wire rather than by the encoder.

## 3. What a port would actually cost

Not "rewrite krd". Replace `krdcore` behind the boundary that #21/#45 established.

### 3.1 The surface Rust would have to implement

| area | what it is today |
|---|---|
| `TileGrid` | `make(paneCols:paneRows:cellW:cellH:aspect:tileCols:tileRows:)`, `rect(_:_:)`, `extract(_:rect:)`, `dirty(previous:current:grid:)` |
| tiles | `CompressedTile`, `ScreenWriter.compress(index:rect:pixels:level:)`, `zlibCompress` (RFC1950 via libz) |
| policy | `LevelPolicy` (`level(for:)`, `observe(index:ratio:)`), `PixelFormat`, `SyncMode` |
| writer | `beginSession`/`endSession`, `resize(tiles:)`, `beginFrame`/`endFrame`/`nudge`, `emit(_:sync:)`, `clear`, `writeRaw`, `writeMouseReporting`, `writeKeyboardProtocol`, the byte counters |
| input | `InputParser` (buffer, CSI/SS3/OSC framing, UTF-8 lengths) and `Event`; `Keys`, `Keyboard.plan` (`--ime`), `Modifiers` |

The published Swift API does not have to change at all: `Package.swift` swaps which implementation
`krdcore` is, and `krd` keeps importing it.

### 3.2 The FFI boundary, and what one call costs

Swift keeps the OS half — ScreenCaptureKit, `NSApplication`, `CGEvent`/`postToPid`, termios,
`NSPasteboard`, AX — because that is the part that has to exist regardless of language. Rust is
called at four places:

| call | frequency | cost |
|---|---|---|
| `krd_encode_begin_frame(enc, out_fd)` → frames land on the tty | 1 per frame | one C call (~10 ns) plus the `write(2)` Rust does directly — the bytes never cross back |
| frame handed in as **pointer + stride** (BGRA from SCK, no copy) | 1 per frame | no copy of the 10 MB; Rust reads the buffer the capturer already produced |
| `krd_parse(p, bytes, len, cb, ctx)` → one event per keystroke/click | 1 per `read(2)` | one call + a callback per event (~100 ns each; a drag is ~60 events/s) |
| `krd_encoder_new`/`_free`, `krd_parser_new`/`_free` | 1 per session | irrelevant |

Peak-cost estimate: **< 1 % of the encode budget**, i.e. the boundary is not the reason to say no or
yes. (The one real hazard: the callback must not allocate a Swift closure per event; the event struct
is POD and copied by value.)

### 3.3 Verification that would have to be rebuilt (this is the actual cost)

- `Tests/krdcoreTests/Fixtures/selftest-80x24-17x33-l6.dump` — the Rust encoder must reproduce it
  **byte for byte** (sha256 `f18475a2…`). Same zlib, same levels, same escape order.
- `Tests/krdcoreTests/Fixtures/input-trace.dump` — the Rust parser must reproduce the canonical
  trace of the seven fed sequences.
- The two `--debug`-level parity checks (render dump, input trace) re-run against the Rust build.
- CI: a Rust toolchain, a `cargo test` job, and both fixtures running twice (Swift, Rust).
- The budget suite (`bench/budget.json`, 16 checks) as the regression gate.

That is a day of CI work plus the port, and it is the honest size of "replace a module", not the
"3-week rewrite" that the issue was trying to price.

## 4. What would change the answer (observable triggers, not dates)

1. **Encoder p99 above 8 ms** (16 % of the budget) for `line`, `char` or `drag` in the
   [BENCHMARK](BENCHMARK.md) §7 procedure, on two consecutive releases. Today: 2.52 / 1.64 / 4.44 ms.
   Not `photo` — that case is wire-bound (§2), so a faster language cannot move it.
2. **A second instance of the allocation/COW class of bug** — a bug whose fix is "copy less", not
   "compute less". #1 was the first member.
3. **A hand-written codec or fast-path deflate is being written.** That code goes to Rust or it does
   not get written well; it is also the only remaining *bandwidth* lever (#26).
4. **Multi-platform returns to the roadmap.** Then the OS half stops being "Swift by default" and the
   calculus changes entirely — with the caveat in §5 that the fragile part is the run loop, not the
   encoder.

## 5. What is explicitly not being done

- **Rust now.** Saves 0.3–1.3 ms on the frames a user sees, costs a second toolchain, a second CI
  job, two more fixtures to keep green and a boundary whose failure mode is a black screen.
- **A pure-Rust binary.** `ARCHITECTURE.md` §4 is the one part of this codebase proven fragile (one
  frame without an AppKit context), and TCC grants are bound to the code signature. A language
  change does not touch that risk, so it buys nothing the shim does not.
- **`libdeflate`-style fast deflate instead.** Declined in #8 and still true: it does not need Rust —
  a `systemLibrary` shim does it — and after #26 the interesting lever is fewer bytes, not a faster
  compressor.
- **Rewriting the OS half.** ScreenCaptureKit, CGEvent and the AX channel stay Swift whatever happens
  to the core.

Portfolio note: the option is kept open *because* `krdcore` now exists. Before #21 the same decision
would have cost a rewrite and this document would have had to argue from taste; now it argues from a
day of CI work against two fixtures that already pass.

Where the port would live is stated in `CONTRIBUTING.md` ("If a Rust core ever lands") so the answer
does not have to be re-litigated from scratch.
