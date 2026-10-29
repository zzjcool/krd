#!/usr/bin/env python3
"""What would a colour-heavy frame cost on the wire, under each option from issue #26?

The encoder benchmark (`krd --bench`) can only report what krd does *today*. This script models
the alternatives on the same pixel data and the same kitty framing, so the numbers in
docs/research-photo-bandwidth.md can be reproduced without touching Sources/krd:

    python3 probe/photo_codec.py --content noise            # the bench's `photo` class
    python3 probe/photo_codec.py --bmp /tmp/sonoma.bmp      # a real photograph
    python3 probe/photo_codec.py --bmp /tmp/sonoma.bmp --scale 2

It is deliberately the same shape as the other probes: standard library only, prints its own
narration, and nothing here is imported by krd.

Cross-check: with `--content noise` it must land within a fraction of a percent of
`krd --bench --pane 137x44 --cell 17x33 --source 2329x1452 --json` (photo: 10.15 MB payload,
13.58 MB wire). If it does not, the framing model below is wrong and every other row is suspect.

Framing model, copied from `ScreenWriter.emit` (Sources/krd/Render.swift:277-302) for one tile:

    ESC[?2026h                             8
    ESC[<row>;<col>H                     ~12
    ESC_ Gf=<24|32>,s=W,v=H,a=t,o=z,q=2,i=<id>,m=<0|1>;  ~45   (first chunk only)
    <payload in 4096-character chunks>      ESC_Gm=<0|1>; (9) before each later chunk
    ESC\\ 2 per chunk
    ESC_G i=<id>,p=<pid>,a=p,q=2,C=1,c=<cols>,r=<rows> ESC\\  ~45
    ESC[?2026l                             8

so ~91 bytes of overhead per tile plus 9 per extra chunk.
"""
import argparse
import base64
import math
import os
import struct
import sys
import time
import zlib

# The reference layout from bench/budget.json: 137x44 cells of 17x33 px, 8x4-cell tiles.
PANE = (137, 44)
CELL = (17, 33)
TILE = (8, 4)
CHUNK = 4096          # base64 characters per APC chunk (Render.swift)
TILE_OVERHEAD = 91    # bytes of escape framing per tile (measured, see docstring)
CHUNK_OVERHEAD = 9

# bytes.translate() tables do quantisation at C speed.
def quant_table(bits_per_channel):
    keep = 0xFF << (8 - bits_per_channel) & 0xFF
    return bytes((value & keep) for value in range(256))

Q565 = [quant_table(5), quant_table(6), quant_table(5)]   # r, g, b
Q666 = [quant_table(6)] * 3
Q555 = [quant_table(5)] * 3
Q332 = [quant_table(3), quant_table(3), quant_table(2)]


def layout(pane=PANE, cell=CELL, tile=TILE):
    cols, rows = pane
    tiles = math.ceil(cols / tile[0]) * math.ceil(rows / tile[1])
    return (cols * cell[0], rows * cell[1], tiles)


def read_bmp(path):
    """Minimal BMP reader: 24 or 32 bpp, bottom-up, 4-byte aligned rows. -> (w, h, rgb)"""
    data = open(path, "rb").read()
    if data[:2] != b"BM":
        sys.exit("%s: not a BMP" % path)
    offset = struct.unpack_from("<I", data, 10)[0]
    width, height = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0]
    if bpp not in (24, 32):
        sys.exit("%s: %d bpp is not supported (24 or 32)" % (path, bpp))
    bottom_up = height > 0
    height = abs(height)
    stride = ((width * bpp // 8) + 3) & ~3
    out = bytearray(width * height * 3)
    for y in range(height):
        src_y = height - 1 - y if bottom_up else y
        row = data[offset + src_y * stride: offset + src_y * stride + width * bpp // 8]
        # BMP is BGR(A); the wire is RGB(A). Swapping is the only per-pixel work here.
        out[y * width * 3:(y + 1) * width * 3] = bytes(
            b for px in range(0, len(row), bpp // 8)
            for b in (row[px + 2], row[px + 1], row[px])
        )
    return width, height, out


def synth(kind, width, height):
    if kind == "noise":
        return width, height, bytearray(os.urandom(width * height * 3))
    if kind == "gradient":
        row = bytes((x * 255) // max(width - 1, 1) for x in range(width))
        return width, height, bytearray((row + bytes(width)) * height)[: width * height * 3]
    if kind == "ui":
        out = bytearray(width * height * 3)
        block = bytes([240, 240, 240]) * (width // 2)
        for y in range(height):
            line = block if (y // 48) % 2 == 0 else bytes([250, 250, 255]) * (width // 2)
            out[y * width * 3:(y + 1) * width * 3] = line[: width * 3]
        return width, height, out
    sys.exit("unknown content %r" % kind)


def planes(rgb):
    return rgb[0::3], rgb[1::3], rgb[2::3]


def interleave(pr, pg, pb):
    out = bytearray(len(pr) * 3)
    out[0::3] = pr
    out[1::3] = pg
    out[2::3] = pb
    return out


def to_rgba(rgb):
    pr, pg, pb = planes(rgb)
    out = bytearray(len(pr) * 4)
    out[0::4] = pr
    out[1::4] = pg
    out[2::4] = pb
    out[3::4] = b"\xff" * len(pr)
    return out


def quantise(rgb, tables):
    pr, pg, pb = planes(rgb)
    return interleave(pr.translate(tables[0]), pg.translate(tables[1]), pb.translate(tables[2]))


def shrink(rgb, width, height, factor):
    """Nearest-neighbour subsample: what "capture at 1/f scale" looks like to zlib.

    A real ScreenCaptureKit downscale filters instead of dropping pixels, which compresses
    slightly better -- so these rows are the pessimistic end of the estimate.
    """
    out_w, out_h = width // factor, height // factor
    out = bytearray(out_w * out_h * 3)
    for y in range(out_h):
        row = rgb[(y * factor) * width * 3:((y * factor) + 1) * width * 3]
        picked = bytearray()
        for channel in range(3):
            picked += row[channel::3 * factor]
        out[y * out_w * 3:(y + 1) * out_w * 3] = picked
    return out_w, out_h, out


def psnr(original, variant, width, height, sample_every=32):
    """Peak signal-to-noise in dB, sampled: a full 3.4 Mpx error loop in Python is not worth it.

    Every 32nd row is a fair sample here because the error of a quantiser does not depend on y.
    """
    step = width * 3 * sample_every
    mse = 0
    count = 0
    for start in range(0, len(original), step):
        a = original[start:start + width * 3]
        b = variant[start:start + width * 3]
        for x, y in zip(a, b):
            d = x - y
            mse += d * d
            count += 1
    if not count or mse == 0:
        return float("inf")
    mse /= count
    return 10 * math.log10((255.0 * 255.0) / mse)


def wire_bytes(payload, bpp, tiles):
    """Same framing as ScreenWriter.emit: base64, 4096-char chunks, ~91 B per tile."""
    encoded = base64.b64encode(payload)
    chunks = max(1, math.ceil(len(encoded) / CHUNK))
    return len(encoded), len(encoded) + tiles * TILE_OVERHEAD + (chunks - 1) * CHUNK_OVERHEAD, chunks


def measure(rgb, width, height, label, level, tiles, quant=None):
    data = quantise(rgb, quant) if quant else rgb
    started = time.perf_counter()
    payload = zlib.compress(bytes(data), level) if level else bytes(data)
    encode_ms = (time.perf_counter() - started) * 1000
    b64, wire, chunks = wire_bytes(payload, len(data) // (width * height), tiles)
    return {
        "label": label,
        "payload": len(payload),
        "wire": wire,
        "chunks": chunks,
        "encode_ms": encode_ms,
        "raw": len(data),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--bmp", help="real content: a 24/32-bpp BMP")
    parser.add_argument("--content", default="noise", choices=["noise", "gradient", "ui"])
    parser.add_argument("--scale", type=int, default=1, help="capture at 1/scale (fewer pixels)")
    parser.add_argument("--pane", default="137x44")
    parser.add_argument("--cell", default="17x33")
    args = parser.parse_args()

    pixel_w, pixel_h, tiles = layout(
        tuple(int(v) for v in args.pane.split("x")), tuple(int(v) for v in args.cell.split("x")))
    factor = max(1, args.scale)

    if args.bmp:
        width, height, rgb = read_bmp(args.bmp)
        if (width, height) != (pixel_w, pixel_h):
            print("# %s is %dx%d, the pane wants %dx%d -- scaling not applied, ratios are what matter"
                  % (args.bmp, width, height, pixel_w, pixel_h))
            pixel_w, pixel_h = width, height
        content = os.path.basename(args.bmp)
    else:
        width, height, rgb = synth(args.content, pixel_w, pixel_h)
        content = args.content + " (synthetic)"

    if factor > 1:
        width, height, rgb = shrink(rgb, width, height, factor)

    print("# content: %s, frame %dx%d px = %.2f MB raw RGB, %d tiles of 8x4 cells"
          % (content, width, height, width * height * 3 / 1e6, tiles))
    if factor > 1:
        print("# captured at 1/%d scale: the terminal upscales the placement to the same cells"
              % factor)

    rows = [
        ("rgba zlib6 b64 (--format rgba)", 6, None, None),
        ("rgb  zlib6 b64 (today)", 6, None, None),
        ("rgb  zlib1 b64", 1, None, None),
        ("rgb  zlib9 b64", 9, None, None),
        ("rgb  no-zlib b64", 0, None, None),
        ("rgb666 zlib1 b64", 1, None, Q666),
        ("rgb565 zlib6 b64", 6, None, Q565),
        ("rgb555 zlib6 b64", 6, None, Q555),
        ("rgb332 zlib6 b64", 6, None, Q332),
    ]
    rgb_wire = to_rgba(rgb)
    base = None
    print()
    print("%-32s %10s %10s %9s %9s %8s  %9s"
          % ("variant", "payload", "wire", "vs today", "MB/s@20", "ms py", "psnr"))
    for label, level, _, quant in rows:
        data = rgb_wire if label.startswith("rgba") else rgb
        got = measure(data, width, height, label, level, tiles, quant)
        base = base or got["wire"]
        quality = "-"
        if quant:
            quality = "%.1f dB" % psnr(rgb, quantise(rgb, quant), width, height)
        print("%-32s %9.2fMB %9.2fMB %8.2fx %8.1f %8.1f  %9s"
              % (label, got["payload"] / 1e6, got["wire"] / 1e6, base / got["wire"],
                 got["wire"] * 20 / 1e6, got["encode_ms"], quality))

    print()
    print("# same content, fewer pixels (issue #26 option: show less, or send fewer pixels)")
    for step in (2, 4):
        sw, sh, small = shrink(rgb, width, height, step)
        got = measure(small, sw, sh, "scale %d" % step, 6, tiles)
        print("%-32s %9.2fMB %9.2fMB %8.2fx %8.1f %8.1f  %9s (%dx%d px)"
              % ("rgb zlib6 b64 at 1/%d scale" % step, got["payload"] / 1e6, got["wire"] / 1e6,
                 base / got["wire"], got["wire"] * 20 / 1e6, got["encode_ms"], "-", sw, sh))

    print()
    print("# note: ms are CPython's, not krd's. Use them for ratios between rows only; the")
    print("#       Swift stage split comes from `krd --bench --json` (see the document).")


if __name__ == "__main__":
    main()
