#!/usr/bin/env python3
"""Emit a kitty-graphics-protocol image on stdout (pure stdlib, no PIL).

Works over plain SSH: the escape stream is inline (t=d style, f=100 PNG),
so nothing but the pty is needed. Usage:  python3 kshow.py [scale] [label]
"""
import sys, zlib, struct, base64, math

W, H = 480, 270
SCALE = float(sys.argv[1]) if len(sys.argv) > 1 else 1.0
HUE = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0


def hsv(h, s, v):
    i = int(h * 6) % 6
    f = h * 6 - int(h * 6)
    p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
    return [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]


def png():
    rows = bytearray()
    cx, cy = W / 2, H / 2
    for y in range(H):
        rows.append(0)
        for x in range(W):
            dx, dy = x - cx, y - cy
            r = math.hypot(dx, dy) / (W * 0.5)
            hue = (math.atan2(dy, dx) / (2 * math.pi) + HUE) % 1.0
            base = hsv(hue, min(1.0, r * 1.1), 1.0 - 0.75 * min(1.0, r * r))
            if (x // 40 + y // 40) % 2 == 0:  # checker overlay
                base = [c * 0.82 for c in base]
            if abs(r - 0.55) < 0.012 or abs(r - 0.78) < 0.012:  # rings
                base = [1.0, 1.0, 1.0]
            if x < 3 or y < 3 or x >= W - 3 or y >= H - 3:  # border
                base = [0.15, 0.15, 0.18]
            rows.extend(bytes(int(max(0.0, min(1.0, c)) * 255) for c in base))

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', zlib.compress(bytes(rows), 6)) + chunk(b'IEND', b''))


b64 = base64.b64encode(png()).decode()
out = sys.stdout
size = 4096
for i in range(0, len(b64), size):
    part = b64[i:i + size]
    more = 0 if i + size >= len(b64) else 1
    # a=T transmit+display, f=100 PNG, q=2 quiet, C=1 keep cursor,
    # c/r = display size in cells
    out.write(f"\033_Gf=100,a=T,q=2,C=1,c={int(W/8*SCALE)},r={int(H/16*SCALE)},m={more};{part}\033\\")
out.flush()
sys.stderr.write(f"sent {len(b64)} b64 bytes ({W}x{H} png) over {sys.stderr.name}\n")
