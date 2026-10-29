#!/usr/bin/env python3
"""Which placement method does this terminal honour?

Places four solid-colour PNG tiles, each with a different positioning method:

    A  magenta   cursor at (1,1)          -> c/r only
    B  red       cursor at row 11         -> cursor-anchored, moved inside a 2026 block
    C  green     cursor stays at (1,1)    -> x/y offsets (cells)
    D  blue      cursor stays at (1,1)    -> X/Y offsets (pixels)

Run it inside the pane you are testing, then report which colours are visible
and where they landed.  Exits cleanly; `q`/Ctrl-C not needed.
"""
import base64
import os
import struct
import sys
import time
import zlib

W, H = 128, 160          # tile pixels
COLS, ROWS = 16, 8       # tile footprint in cells (8x20 px cells)


def png(rgb):
    rows = bytearray()
    for _ in range(H):
        rows.append(0)
        rows.extend(bytes(rgb) * W)

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))

    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(bytes(rows)))
            + chunk(b'IEND', b''))


def chunks(payload, first_ctl):
    out = b''
    n = len(payload)
    for i in range(0, n, 4096):
        part = payload[i:i + 4096]
        more = 0 if i + 4096 >= n else 1
        ctl = first_ctl(more) if i == 0 else 'Gm=%d' % more
        out += b'\x1b_G' + ctl.encode() + b';' + part + b'\x1b\\'
    return out


_out_path = os.environ.get('TILE_TEST_OUT')
tty = os.open(_out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC) if _out_path else os.open('/dev/tty', os.O_WRONLY | os.O_NOCTTY)
b64 = {name: base64.b64encode(png(rgb))
       for name, rgb in (('A', (255, 0, 255)), ('B', (255, 0, 0)),
                         ('C', (0, 255, 0)), ('D', (0, 0, 255)))}

out = b'\x1b[2J\x1b[H'
out += b'A=magenta(cursor 1,1)  B=red(cursor 11,1)  C=green(x/y cells)  D=blue(X/Y px)\r\n'

# A: the simple case -- cursor at (1,1), size given by c/r
out += b'\x1b[2;1H' + chunks(b64['A'], lambda m: f'Gf=100,a=T,q=0,C=1,i=201,c={COLS},r={ROWS},m={m}')

# B: cursor moved to row 12 inside a synchronized block
out += b'\x1b[?2026h\x1b[12;1H' \
    + chunks(b64['B'], lambda m: f'Gf=100,a=t,q=0,i=202,m={m}') \
    + f'\x1b_Gi=202,a=p,q=0,C=1,c={COLS},r={ROWS}\x1b\\'.encode() \
    + b'\x1b[?2026l'

# C: single cursor position + x/y offsets (assumed to be cells)
out += b'\x1b[1;60H' \
    + chunks(b64['C'], lambda m: f'Gf=100,a=t,q=0,i=203,m={m}') \
    + f'\x1b_Gi=203,a=p,q=0,C=1,c={COLS},r={ROWS},x=10,y=0\x1b\\'.encode()

# D: single cursor position + X/Y offsets (assumed to be pixels)
out += b'\x1b[1;90H' \
    + chunks(b64['D'], lambda m: f'Gf=100,a=t,q=0,i=204,m={m}') \
    + f'\x1b_Gi=204,a=p,q=0,C=1,c={COLS},r={ROWS},X=10,Y=0\x1b\\'.encode()

out += b'\x1b[22;1Hsent A B C D\r\n'
os.write(tty, out)
time.sleep(0.3)
