#!/usr/bin/env python3
"""A/B the four plausible ways to get a tile onto the screen.

    A  magenta  row 2   a=T  (transmit+display, kshow's known-good path)
    B  red      row 12  a=T  after moving the cursor inside a 2026 block
    C  green    row 22  a=t + a=p
    D  blue     row 32  a=t + a=p, inside a 2026 block, cursor moved first

Every tile is a 128x160 solid PNG with a white 2px border so the exact
footprint is measurable from a screenshot.
"""
import base64
import os
import struct
import zlib

W, H = 128, 160
COLS, ROWS = 16, 8


def png(rgb):
    rows = bytearray()
    for y in range(H):
        rows.append(0)
        for x in range(W):
            edge = x < 2 or y < 2 or x >= W - 2 or y >= H - 2
            rows.extend(b'\xff\xff\xff' if edge else bytes(rgb))

    def ch(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))

    return (b'\x89PNG\r\n\x1a\n'
            + ch(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))
            + ch(b'IDAT', zlib.compress(bytes(rows)))
            + ch(b'IEND', b''))


def transmit(b64, ctl_first):
    out = b''
    n = len(b64)
    for i in range(0, n, 4096):
        part = b64[i:i + 4096]
        more = 0 if i + 4096 >= n else 1
        ctl = ctl_first(more) if i == 0 else 'Gm=%d' % more
        out += b'\x1b_G' + ctl.encode() + b';' + part + b'\x1b\\'
    return out


B64 = {k: base64.b64encode(png(v)) for k, v in
       (('A', (255, 0, 255)), ('B', (255, 0, 0)), ('C', (0, 200, 0)), ('D', (0, 0, 255)))}

out = b'\x1b_Ga=d,d=a\x1b\\\x1b[2J\x1b[H'
out += b'A magenta row2 a=T | B red row12 a=T+2026 | C green row22 a=t+a=p | D blue row32 a=t+a=p+2026\r\n'

# A: cursor at (2,2), single-shot transmit+display
out += b'\x1b[2;2H' + transmit(B64['A'], lambda m: f'Gf=100,a=T,q=0,C=1,i=301,c={COLS},r={ROWS},m={m}')

# B: cursor moved inside a synchronized block, then transmit+display
out += b'\x1b[?2026h\x1b[12;2H' \
    + transmit(B64['B'], lambda m: f'Gf=100,a=T,q=0,C=1,i=302,c={COLS},r={ROWS},m={m}') + b'\x1b[?2026l'

# C: transmit only, then a separate place
out += b'\x1b[22;2H' \
    + transmit(B64['C'], lambda m: f'Gf=100,a=t,q=0,i=303,m={m}') \
    + f'\x1b_Gi=303,a=p,q=0,C=1,c={COLS},r={ROWS}\x1b\\'.encode()

# D: same, wrapped in a 2026 block
out += b'\x1b[?2026h\x1b[32;2H' \
    + transmit(B64['D'], lambda m: f'Gf=100,a=t,q=0,i=304,m={m}') \
    + f'\x1b_Gi=304,a=p,q=0,C=1,c={COLS},r={ROWS}\x1b\\'.encode() + b'\x1b[?2026l'

out += b'\x1b[45;2Hdone\r\n'
os.write(os.open('/dev/tty', os.O_WRONLY | os.O_NOCTTY), out)
