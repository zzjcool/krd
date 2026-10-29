#!/usr/bin/env python3
"""Find out how this terminal implements image / placement deletion.

Draws four solid blocks, then tries each delete form in turn, narrating on screen.
Just watch for ten seconds and note which colours survive each step.

    STEP 1  four blocks: magenta(901) red(902) green(903) blue(904)
    STEP 2  a=d,i=902        -> does ONLY red go, or everything?
    STEP 3  a=d,i=903,p=3    -> does only green go?
    STEP 4  (done)
"""
import base64
import os
import struct
import sys
import time
import zlib

W, H = 160, 100
COLS, ROWS = 20, 5
BLOCKS = [((255, 0, 255), 2, 901), ((255, 0, 0), 9, 902),
          ((0, 255, 0), 16, 903), ((0, 128, 255), 23, 904)]


def png(rgb):
    rows = bytearray()
    for _ in range(H):
        rows.append(0)
        rows.extend(bytes(rgb) * W)

    def ch(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))

    return (b'\x89PNG\r\n\x1a\n'
            + ch(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))
            + ch(b'IDAT', zlib.compress(bytes(rows)))
            + ch(b'IEND', b''))


def chunks(b64, ctl):
    out = b''
    n = len(b64)
    for i in range(0, n, 4096):
        part = b64[i:i + 4096]
        more = 0 if i + 4096 >= n else 1
        out += b'\x1b_G' + (ctl(more) if i == 0 else f'Gm={more}').encode() + b';' + part + b'\x1b\\'
    return out


tty = os.open('/dev/tty', os.O_WRONLY | os.O_NOCTTY)


def write(data):
    os.write(tty, data)


def nudge(seconds):
    """Some terminals only commit placements on a later output cycle."""
    end = time.time() + seconds
    while time.time() < end:
        write(b'\x1b[?25l')
        time.sleep(0.15)


def label(row, text):
    # plain text, far below the blocks so it never sits on top of them
    write(f'\x1b[{row};1H\x1b[0m{text}\x1b[K'.encode())


write(b'\x1b[2J\x1b[H')
for rgb, row, cid in BLOCKS:
    b64 = base64.b64encode(png(rgb))
    write(f'\x1b[{row};2H'.encode())
    write(chunks(b64, lambda m, cid=cid: f'Gf=100,a=T,q=2,C=1,i={cid},p={cid - 900},c={COLS},r={ROWS},m={m}'))

label(34, 'STEP 1: 4 blocks (magenta 901 / red 902 / green 903 / blue 904)')
nudge(4)

label(35, 'STEP 2: a=d,i=902  (deleting red)')
write(b'\x1b_Ga=d,i=902\x1b\\')
nudge(4)

label(36, 'STEP 3: a=d,i=903,p=3  (deleting green by placement id)')
write(b'\x1b_Gi=903,a=d,p=3\x1b\\')
nudge(4)

label(37, 'STEP 4: done -- note which colours survived each step')
nudge(20)
