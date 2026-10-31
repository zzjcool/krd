#!/usr/bin/env python3
"""Does text written over kitty unicode-placeholder cells hide the picture there - and does OSC 22
change the pointer? (docs/design-ui-v2.zh-CN.md §4.2: a menu drawn over the mirror's picture.)

    python3 probe/placeholder_overlay.py [hold-seconds] [osc22-after-seconds] [restore-after-seconds]

Draws one solid magenta picture as a 40x12-cell U=1 placement, then writes three patches over
cells of it: A text on a dark background, B background-only spaces, C plain spaces (default
background). After [osc22-after-seconds] (default 6) it sends OSC 22 `pointer`. After
[restore-after-seconds] (default: never) it writes patch A's cells back as placeholders - the
picture is not sent again - which is how a closed menu gives the picture back. It holds for
[hold-seconds] (default 30) so the screen can be captured, then deletes the picture and restores
the terminal.

Read the result from pixels, not from the text buffer (the buffer always shows the overlay text):
a terminal that hides the picture under overwritten cells shows no magenta inside A, B and C.
"""
import base64
import os
import re
import select
import sys
import termios
import time
import tty
import zlib

HOLD = float(sys.argv[1]) if len(sys.argv) > 1 else 30.0
OSC22_AFTER = float(sys.argv[2]) if len(sys.argv) > 2 else 6.0
RESTORE_AFTER = float(sys.argv[3]) if len(sys.argv) > 3 else None
IMAGE_ID = 42                       # < 256, so the id travels as a 256-colour foreground
COLS, ROWS = 40, 12                 # the placement, in cells
TOP, LEFT = 3, 5                    # 1-based screen cell of its top-left corner
# kitty's rowcolumn-diacritics.txt, first 41 entries (enough for 40 columns and 12 rows)
DIACRITICS = [0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A,
              0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357, 0x035B, 0x0363, 0x0364, 0x0365,
              0x0366, 0x0367, 0x0368, 0x0369, 0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F,
              0x0483, 0x0484, 0x0485, 0x0486, 0x0487, 0x0592, 0x0593, 0x0594, 0x0595, 0x0597,
              0x0598]
PLACEHOLDER = "\U0010EEEE"
# Patches, in placement-relative cells: (row, col, width, sgr, text)
PATCHES = {
    "A": (4, 8, 19, "48;2;30;30;46;38;2;230;230;230", " OVERLAY TEXT HERE "),
    "B": (8, 20, 10, "48;2;30;30;46", " " * 10),
    "C": (1, 30, 6, "0", " " * 6),
}

fd = os.open("/dev/tty", os.O_RDWR)
saved = termios.tcgetattr(fd)
tty.setraw(fd)


def write(s):
    data = s.encode("utf-8")
    while data:
        data = data[os.write(fd, data):]


def cell_px():
    write("\x1b[16t")
    buf, end = b"", time.time() + 2
    while time.time() < end and not re.search(rb"\x1b\[6;\d+;\d+t", buf):
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            buf += os.read(fd, 1024)
    m = re.search(rb"\x1b\[6;(\d+);(\d+)t", buf)
    return (int(m.group(2)), int(m.group(1))) if m else (8, 16)


try:
    write("\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J")
    cw, ch = cell_px()
    width, height = COLS * cw, ROWS * ch                    # the picture is exactly its cells
    pixels = bytes((255, 0, 255)) * (width * height)
    data = base64.b64encode(zlib.compress(pixels)).decode()
    chunks = [data[i:i + 4096] for i in range(0, len(data), 4096)]
    out = []
    for i, chunk in enumerate(chunks):
        more = int(i < len(chunks) - 1)
        head = (f"a=t,i={IMAGE_ID},f=24,s={width},v={height},o=z,q=2,m={more}" if i == 0
                else f"m={more}")
        out.append(f"\x1b_G{head};{chunk}\x1b\\")
    out.append(f"\x1b_Ga=p,U=1,i={IMAGE_ID},c={COLS},r={ROWS},q=2\x1b\\")
    out.append("\x1b[?2026h")
    for r in range(ROWS):
        first = PLACEHOLDER + chr(DIACRITICS[r]) + chr(DIACRITICS[0])
        out.append(f"\x1b[{TOP + r};{LEFT}H\x1b[38;5;{IMAGE_ID}m" + first
                   + PLACEHOLDER * (COLS - 1) + "\x1b[0m")
    for name, (r, c, w, sgr, text) in PATCHES.items():
        out.append(f"\x1b[{TOP + r};{LEFT + c}H\x1b[0;{sgr}m{text}\x1b[0m")
    legend = (f"cell {cw}x{ch}px  picture {width}x{height}px at row {TOP} col {LEFT}  "
              f"A=text B=bg-only C=default-bg")
    out.append(f"\x1b[{TOP + ROWS + 1};{LEFT}H{legend}")
    out.append("\x1b[?2026l")
    write("".join(out))
    events = [(OSC22_AFTER, "osc22")]
    if RESTORE_AFTER is not None:
        events.append((RESTORE_AFTER, "restore"))
    start = time.time()
    for at, what in sorted(events):
        time.sleep(max(0.0, at - (time.time() - start)))
        if what == "osc22":
            write("\x1b]22;pointer\x1b\\" + f"\x1b[{TOP + ROWS + 2};{LEFT}HOSC 22 pointer sent")
        else:
            r, c, w, _, _ = PATCHES["A"]
            # Explicit row and column on the first cell: its left neighbour's column is only
            # inferred, and a restored run must not depend on how the terminal infers it.
            cells = PLACEHOLDER + chr(DIACRITICS[r]) + chr(DIACRITICS[c]) + PLACEHOLDER * (w - 1)
            write(f"\x1b[?2026h\x1b[{TOP + r};{LEFT + c}H\x1b[0;38;5;{IMAGE_ID}m{cells}\x1b[0m"
                  f"\x1b[{TOP + ROWS + 3};{LEFT}Hpatch A restored as placeholders\x1b[?2026l")
    time.sleep(max(0.0, HOLD - (time.time() - start)))
finally:
    write("\x1b]22;default\x1b\\\x1b_Ga=d,d=I,i=%d,q=2\x1b\\\x1b[0m\x1b[H\x1b[2J\x1b[?25h\x1b[?1049l"
          % IMAGE_ID)
    termios.tcsetattr(fd, termios.TCSAFLUSH, saved)
