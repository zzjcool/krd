# Colour-heavy full-screen motion: where the bytes go, and what can be done

**Status:** research + decision for [issue #26](https://github.com/zzjcool/krd/issues/26). No
encoder changes in this PR. Every number below is either produced by a command in §8 or traced to a
line of code.

**中文版:** [research-photo-bandwidth.zh-CN.md](research-photo-bandwidth.zh-CN.md)

---

## 0. The answer in one page

`photo` is 13.58 MB per frame on the wire: 3 bytes of pixel, plus 33 % of base64, plus zlib which on
this content compresses **nothing** (10.15 MB out of 10.14 MB of raw pixels). At 20 fps that is
271 MB/s; a local pty tops out at 103.6 MB/s, so even on this machine the case runs at 8 fps. No
compressor can help — there is nothing to compress. Only **fewer bytes per pixel**, **fewer pixels**
or **fewer frames** can.

Measured, on the reference layout (2329×1452 px, 198 tiles):

| option | wire per frame | vs today | quality | protocol change |
|---|---:|---:|---|---|
| today: `--format rgb`, zlib, base64 | 13.58 MB | 1.00× | lossless | — |
| skip zlib when it does not pay | 13.57 MB | 1.00× | lossless | none — **shipped in #53** (saves 73 % of the encode CPU) |
| 18-bit colour (6-6-6) before zlib | 10.53 MB | 1.47× | 42.3 dB (visually lossless) | none |
| **16-bit colour (5-6-5) before zlib** | **9.90 MB** | **1.57×** | 36.5 dB (banding on ramps) | none |
| 15-bit (5-5-5) | 9.00 MB | 1.72× | 35.3 dB | none |
| 12-bit (3-3-2) | 5.81 MB | 2.67× | 19.9 dB (posterised) | none |
| **capture at ½ scale** | **3.41 MB** | **4.56×** | soft (terminal upscales) | none |
| capture at ¼ scale | 0.87 MB | 17.9× | very soft | none |
| 16-bit **and** ½ scale | 2.49 MB | 5.5× | soft + banding | none |
| true RGB565 / YUV 4:2:0 on the wire | 5.1–6.8 MB | 2–2.7× | lossy | **terminal must learn a new `f=`** |
| inter-frame delta | — | — | — | **impossible: the terminal cannot composite** |
| fewer frames (adaptive fps) | 13.58 MB × fps | — | slideshow at 1.5 fps on 20 MB/s | none |

**Recommendation:** content-adaptive 16-bit quantisation per tile (§4.1), then capture-side scale
(§4.2), with fps as backpressure rather than as a solution. The first is ~40 lines in the encoder
and takes a real photograph from 6.3 MB to 1.3 MB per frame at 36.5 dB; the second is already
mechanically possible (the zoom work turned the capture rect into a parameter) and costs sharpness.
Neither needs a new protocol, a codec library, or a terminal change. Milestones in §7.

**And the case itself needs re-labelling.** The bench's `photo` is hash noise — incompressible by
construction, and *not* what a photo screen looks like. A real 2329×1452 photograph costs **6.32 MB**
today, not 13.58 MB, and 1.27 MB at 16-bit. The 259 MB/s headline is the worst case, and the doc
says which number belongs where (§3.5).

---

## 1. What is measured, and with what

All numbers on macOS 26.6.2, M1 Pro, krd at `d95386d`, reference layout
`--pane 137x44 --cell 17x33 --source 2329x1452` (198 tiles of 8×4 cells, 2329×1452 px of capture).

| layer | command | what it answers |
|---|---|---|
| L1 encoder | `krd --bench --rounds 8 --json` | per-stage milliseconds, payload and wire bytes |
| L2 wire | `python3 bench/wire.py --case photo --drain …` | what a pty (and a rate-limited pty) really carries |
| codec probe | `python3 probe/photo_codec.py …` | the same pixels under each option in §4, with the same framing |

The L1 stage split for `photo` (parallel, 198 tiles):

| stage | p50 ms | share of 24.53 ms |
|---|---:|---:|
| dedupe | 0.00 | — |
| dirty | 0.01 | — |
| extract | 1.20 | 5 % |
| zlib | 136.75 serial → **17.99 wall** | 73 % of a single thread, 73 % of the wall |
| base64 | 5.15 | 21 % |
| assemble | 1.38 | 6 % |
| **total** | **24.53** | |

Two things follow immediately: base64 is not an implementation detail to optimise (5 ms), and zlib
spends 137 ms of a core to remove 0 bytes (§2).

## 2. Where the 13.58 MB comes from

Arithmetic first, then the measurement that confirms it:

```
pixels        2329 × 1452                    = 3.38 Mpx
raw RGB       3.38 Mpx × 3 B                 = 10.14 MB        ← the frame itself
zlib          measured payload               = 10.15 MB        ← +0.01 MB: the compressor adds a header
base64        10.15 MB × 4/3                 = 13.53 MB        ← +3.38 MB, pure protocol tax
framing       198 tiles × 91 B + chunks      = 0.018 MB        ← escapes, placement, chunk headers
                                                 13.58 MB  ← matches `krd --bench --json`
```

The measured `payload` (10,150,xxx bytes) is *larger* than the raw pixels, which is the whole story:
this content is at maximum entropy, so every stage that tries to model it can only add overhead.
`bench/budget.json` says the same thing from the other side — the `photo` payload budget (20 MB) is
"content-dominated, so this only catches a format regression".

Where the bytes physically come from, in order of size:

1. **3 bytes per pixel is the format.** `f=24` is RGB888; there is no 16-bit format in the protocol
   (§3.2). 10.14 MB of the 13.58 MB is decided before any code runs.
2. **base64 is +33 %.** The APC escape is a text channel; `o=z` payloads are base64 too
   (`Sources/krd/Render.swift:278`, and the `o=z` key at `:290`). 3.38 MB per frame.
3. **zlib is +0.1 %.** On noise. On a photograph it is a real 2.2× (10.15 → 4.72 MB), which is why
   it must stay — but see §3.4 for the case where it should be skipped.
4. **framing is 0.13 %.** 198 placements and their chunk headers are not the problem, and neither is
   the write path's syscall count.

## 3. What is *not* possible, with the reason

Each of these is a question somebody will ask twice, so the answer is written down once.

### 3.1 "Send `f=24` raw, without base64"

The kitty graphics protocol carries the payload as base64 inside an APC escape; there is no
binary-transmit variant for `a=t`/`a=T` (the `t=d`/`t=f` *media* are the terminal reading a file or
shared memory, not the client sending raw bytes). krd already uses the smallest legal shape:
`f=24` (3 B/px, not `f=32`'s 4), `o=z` (compressed before encoding), and 4096-character chunks.

Even if a terminal added a raw binary channel, the win is 13.58 → 10.18 MB: **25 %**, which changes
nothing about 271 MB/s. Not worth a protocol extension, and not in krd's control.

Measured cost of not having it: base64 = 5.15 ms and 3.38 MB per frame (§1).

### 3.2 "Use RGB565 / YUV 4:2:0 on the wire"

`f=` accepts 24, 32 or 100 (PNG) — there is no 16-bit RGB and no YUV format to negotiate. A true
13.5 B/px wire would need kitty, Ghostty and Herdr/rex to grow a format **and** krd to learn it, and
the terminal would still upconvert to RGB for compositing. That is a multi-terminal protocol change;
it belongs in a different issue if it ever belongs anywhere.

What *is* available today is quantising to 16 bits and then sending that as `f=24` — same wire
format, 2 bytes/px of the entropy removed before zlib sees it. That is §4.1, and it is most of the
win of a 16-bit format with none of the deployment cost.

### 3.3 "Inter-frame delta / overwrite the same image id"

The terminal is a dumb sink: for a placement, the only operations are "here are pixels" and "delete".
It composes nothing. A delta is therefore not a smaller payload — it is an *unrenderable* one, unless
krd reconstructs the absolute frame and sends that, which is what it already does.

`a=f` (kitty's animation frames) does not help either: frames are transmitted in full up front, so it
is pre-payment, not compression.

The parts of "delta" that *are* implemented are already in the pipeline: identical tiles are never
sent (`Capturer` drops byte-identical frames; `Tile.swift`'s dirty stage compares per tile). That is
why typing costs 0.3 KB and a static screen 0 bytes — and why it saves nothing when every pixel of
every tile changes, which is the definition of this case.

### 3.4 "Use a better compressor"

Measured: zlib level 1, 6 and 9 all produce 10.15 MB on this content (the probe's `zlib1/zlib6/zlib9`
rows are byte-identical). Brotli/zstd/libdeflate would produce ~10.15 MB too: entropy is entropy.
`#8` (a Rust codec) is a *speed* project, and speed is not the constraint here — 24.53 ms of a core
for a frame that takes 100 ms to write.

The one thing worth doing on this axis is the opposite of a better compressor: **stop compressing
when it does not pay.** Try zlib, keep the result only if it is smaller than the input plus its
header; on the `photo` case that saves 137 ms of a core per frame (73 % of the encode time) and
0.01 MB. Cheap, lossless, no protocol involvement — a good M1 (§7).

### 3.5 "The bench number is a photo"

It is not. `BenchContent.noise` (`Sources/krd/Bench.swift:140-147`) is an integer hash per pixel: a
stand-in for the worst case, not for a photograph. Measured with a real 2329×1452 photograph
(`/System/Library/Desktop Pictures/Sonoma.heic`, converted with `sips`, see §8):

| content | raw | today's wire | zlib ratio |
|---|---:|---:|---:|
| hash noise (the bench's `photo`) | 10.14 MB | 13.58 MB | 1.00× |
| real photograph | 10.14 MB | 6.32 MB | 2.15× |
| smooth gradient | 10.14 MB | 0.05 MB | ~200× |

So: 271 MB/s is the *ceiling* for a worst-case screen; a video or photo-editing screen costs
126 MB/s at 20 fps today. Both are too much for a remote link, but the planning number for "a photo
app" is the second one, and the budget (§6) has to hold the first because that is what the bench
generates. A synthetic `photo` case that behaves like a photograph (smooth base + grain, ~2×
compressible) would make the bench more representative; that is a bench change, filed as a
follow-up rather than smuggled into this document.

## 4. What *is* possible, measured

All rows below are `probe/photo_codec.py` on the same pixels, with the same kitty framing, so they
are directly comparable to `krd --bench`. `wire` includes base64 and the 91 B/tile framing;
`psnr` is against the unquantised frame (sampled every 32nd row, `probe/photo_codec.py:psnr`).

### 4.1 Cheaper pixels: quantise before zlib (no protocol change)

| variant | noise: wire | vs today | photo: wire | vs today | PSNR (photo) |
|---|---:|---:|---:|---:|---:|
| today (`f=24`, zlib 6) | 13.58 MB | 1.00× | 6.32 MB | 1.00× | lossless |
| 6-6-6 (18-bit) | 10.53 MB | 1.47× | 2.98 MB | 2.12× | 42.3 dB |
| 5-6-5 (16-bit) | 9.90 MB | 1.57× | **1.27 MB** | **4.98×** | 36.5 dB |
| 5-5-5 (15-bit) | 9.00 MB | 1.72× | 0.98 MB | 6.45× | 35.3 dB |
| 3-3-2 (12-bit) | 5.81 MB | 2.67× | 0.26 MB | 24× | 19.0 dB |

For completeness, `--format rgba` costs +14 % on noise and +5 % on a photograph (zlib eats the
constant alpha plane), which is why `f=24` is the default.

Why quantisation beats a better compressor: it does not try to predict the noise, it *deletes* it.
The low bits of a photograph are where the entropy lives, and dropping them turns smooth regions
into long runs that LZ77 can finally match — a 2.15× zlib becomes a 8× one (photo: 4.72 MB payload →
0.94 MB at 5-6-5).

Quality: 42.3 dB is genuinely invisible; 36.5 dB is the "looks fine in a photo, banding visible on a
smooth sky gradient" zone; 19 dB is a 1990s GIF. Flat UI colours survive 5-6-5 well (each channel
moves by at most 4/255 and flat fields are where that is least visible), text keeps its contrast, and
photographic or gradient content bands. That is why this has to be **per tile and opt-in**, not a
global format switch: a Finder window and a video frame are different clients.

Cost: one extra quantisation pass (`bytes.translate` in the probe, ~13 lines in Swift with a 256-byte
table), double zlib if both variants are tried. Predicted better design: each tile remembers whether
its last payload was incompressible (ratio > 1.05) and quantises from then on, so the second pass
only happens on tiles that are actually noisy.

### 4.2 Fewer pixels: capture at ½ or ¼ scale

The capture rect and output size already travel as parameters (`SCStreamConfiguration.width/height`,
and the zoom work now computes both), so "capture at half resolution and let the terminal upscale the
placement" is small, protocol-clean work.

| variant | noise: wire | vs today | photo: wire | vs today |
|---|---:|---:|---:|---:|
| today (full resolution) | 13.58 MB | 1.00× | 6.32 MB | 1.00× |
| ½ scale (1164×726 px) | 3.41 MB | 4.56× | 1.48 MB | 4.27× |
| ¼ scale (582×363 px) | 0.87 MB | 17.9× | 0.41 MB | 15.4× |

It composes with §4.1 (½ scale + 5-6-5 = 2.49 MB on noise). Quality cost is straightforward
softness — and it is the same trade the zoom issue (#22) made in the other direction, so users
already understand it.

### 4.3 Fewer frames: what the pipe actually carries

`bench/wire.py`, the `photo` case, three drains (the numbers are the pty's, measured end to end):

| drain | frames delivered | effective fps | write p50 |
|---|---:|---:|---:|
| unlimited (as fast as the pty goes) | 100 frames in 12.50 s | 8.0 | 90 ms |
| 20 MB/s | 100 frames in 64.7 s | **1.55** | 618 ms |
| 5 MB/s | (arithmetic: 13.58 MB/frame) | 0.37 | — |

`late` was **100 of 100** in both measured runs: krd does not queue frames forever, it writes them
slowly and the stream falls behind. A 20 MB/s link therefore turns full-screen photo motion into
1.5 fps — usable as a slideshow, not as video. That number is the honest cost of option C, and it is
also why C alone is not the answer: at 16-bit and ½ scale the same link carries 15 fps.

## 5. What each option would print in the bench

If a chosen option landed, `krd --bench` would report (estimated from §4's bytes, same stage model):

| scenario | payload | wire | encode p50 (wall) |
|---|---:|---:|---:|
| today | 10.15 MB | 13.58 MB | 24.5 ms |
| zlib skipped when it loses | 10.15 MB | 13.57 MB | **6.5 ms** (no zlib) |
| 5-6-5 + zlib | 7.40 MB | 9.90 MB | ~42 ms (two zlib passes, or 24 ms with the remember-the-tile trick) |
| 5-6-5 at ½ scale + zlib | 1.85 MB | 2.49 MB | ~11 ms |

The encode time goes *up* for two-pass quantisation and *down* for the skip; neither is the point.
The point is 13.58 → 2.49 MB, which is the difference between "cannot" and "works on a LAN".

## 6. What this PR actually changes (no encoder changes)

- `docs/research-photo-bandwidth.md` + `.zh-CN.md` (this document).
- `probe/photo_codec.py`: the measurement tool, standard library only.
- `bench/budget.json`: a `photo` **`bytes.wire`** budget of 15,000,000 — ~10 % over today's
  13,580,155, the same "catch a large regression, not a 5 % one" rule the rest of that file follows.

  Review of the first version of this PR asked for exactly this, and the argument is worth keeping:
  the measured value *is* exactly reproducible (the `photo` frame is generated noise, no clock in
  it), so a 0.9 % ceiling would have been honest arithmetic — and it would have fired on the first
  branch that changed chunk size or tile framing, at which point somebody widens the number in the
  same commit as the change that tripped it, and the budget stops meaning anything. A ceiling with
  the same slack as its neighbours is the one that gets read instead of edited. When M1–M3 land,
  the number comes down **with** the `docs/research-photo-bandwidth.md` table in the same PR.
- `README.md` / `README.zh-CN.md`: the **Rough** row now says where the numbers live instead of
  hinting at a mystery codec.

## 7. Recommendation and milestones

**Recommendation: B (cheaper pixels), content-adaptive, then A — which turns out to mean "fewer
pixels".** Not a video codec; not a protocol extension.

- **M1 — stop wasting work (a day).** ✅ **shipped in #53** (`LevelPolicy` keeps one more state bit:
  a tile whose last compression bought nothing is sent raw, and a cheap neighbour-delta predictor
  rescues it the moment the content becomes compressible again). Measured on the `photo` case at the
  reference layout: encode p50 **9.27 → 3.18 ms** (−66 %), wire **4,757,652 → 4,755,012 B** (raw beat
  the zlib-expanded payload). Text/UI/gradient bytes are unchanged. The remaining item from this
  milestone — a second `photo` case with photographic statistics instead of hash noise — is still
  open.
- **M2 — content-adaptive 16-bit (a few days).** Per tile: keep the zlib ratio of the last frame; if
  a tile has been incompressible (> 1.05) for two frames, send it 5-6-5 from then on, and remember
  that until it compresses well again. No flag needed for the common case, `--format`-style override
  for people who want lossless. Expected: 13.58 → 9.90 MB on the worst case, 6.32 → 1.27 MB on a
  photograph, with the text path bit-identical.
- **M3 — capture scale (a few days).** `--scale 1|0.5|0.25` on the capture side, then a simple
  "if the pipe cannot keep up, drop scale before dropping fps" policy. Composes with M2.
- **M4 — only if a terminal asks for it.** A 16-bit or YUV wire format. Needs kitty/Ghostty/Herdr
  buy-in; do not start it inside krd.

**Not doing:** motion compensation, a bundled video codec, YUV on the wire, protocol extensions, a
daemon that re-encodes, or anything that breaks the "one process, stateless tiles, terminal is a
dumb image sink" model. Those are the options that look attractive on paper and cost the project its
shape.

## 8. Every number, and how to reproduce it

```bash
# the layout, the stage split, the payload/wire bytes (§1, §2)
swift build -c release
./.build/release/krd --bench --rounds 8 --pane 137x44 --cell 17x33 --source 2329x1452 --json

# the pipe ceiling and the 20 MB/s reality (§4.3)
python3 bench/wire.py --case photo --seconds 3 --drain 0  -- ./.build/release/krd --bench-wire photo --pane 137x44 --cell 17x33 --source 2329x1452
python3 bench/wire.py --case photo --seconds 3 --drain 20MB -- ./.build/release/krd --bench-wire photo --pane 137x44 --cell 17x33 --source 2329x1452

# the codec tables (§4.1, §4.2)
python3 probe/photo_codec.py --content noise
python3 probe/photo_codec.py --content gradient
sips -Z 2329 -s format bmp "/System/Library/Desktop Pictures/Sonoma.heic" --out /tmp/sonoma_full.bmp
sips -c 1452 2329 /tmp/sonoma_full.bmp --out /tmp/sonoma.bmp
python3 probe/photo_codec.py --bmp /tmp/sonoma.bmp
python3 probe/photo_codec.py --bmp /tmp/sonoma.bmp --scale 2
```

Cross-check: `probe/photo_codec.py --content noise` reports 10.15 MB payload and 13.58 MB wire for
the baseline row, which is exactly what `krd --bench --json` reports for `photo`. The probe's framing
model (`Sources/krd/Render.swift:277-302`) therefore agrees with the real one to three digits, which
is what makes its other rows worth reading.
