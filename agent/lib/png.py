"""The smallest PNG writer that is still a PNG: 8-bit RGB, one filter-0 row at a time.

Why hand-rolled: `krd`'s decoders run where nothing may be installed (stdlib-only agents,
CI images without Pillow), and a frame is not worth a dependency. There is deliberately no
reader here - the one consumer that needs to read `f=100` payloads (`vt.py`) lives next to
the kitty command that carries them, so the size accounting of a PNG stays in one file.

A PNG of N rows is N+1 bytes of filter byte plus N rows of pixels, zlib-compressed, cut into
IDAT chunks. Filter 0 ("none") is 1/255th larger than an adaptive filter would be and the
only reason to pick it: the bytes are predictable, so two runs of the same frame hash equal.
"""

import struct
import zlib


def _chunk(kind, body):
    return (struct.pack(">I", len(body)) + kind + body
            + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF))


def write_png_bytes(width, height, rgb_bytes):
    """Encode `width * height * 3` packed RGB bytes as an 8-bit truecolour PNG."""
    w, h = int(width), int(height)
    if w <= 0 or h <= 0:
        raise ValueError("png: %dx%d is not a picture" % (w, h))
    stride = w * 3
    if len(rgb_bytes) != stride * h:
        raise ValueError("png: want %d B for %dx%d RGB, got %d"
                         % (stride * h, w, h, len(rgb_bytes)))
    raw = bytearray(stride * h + h)
    for y in range(h):
        # One filter byte per row: index of the row's pixels shifts by one per row.
        raw[y * (stride + 1)] = 0
        raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)] = rgb_bytes[y * stride:(y + 1) * stride]
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", ihdr)
            + _chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + _chunk(b"IEND", b""))


def write_rgb(path, width, height, rgb_bytes):
    """Write the same bytes `write_png_bytes` returns to `path`."""
    data = write_png_bytes(width, height, rgb_bytes)
    with open(path, "wb") as fh:
        fh.write(data)
    return len(data)
