#!/usr/bin/env python3
"""Proves `agent/lib/vt.py` against the byte stream `krd` itself reproduces.

A plain script on purpose: the repo has no Python toolchain, an agent may run this on a machine
with nothing installed, and `python3 agent/tests/test_vt.py` has to work there. One line per
check; the exit code is the verdict.

Run: python3 agent/tests/test_vt.py
"""

import base64
import hashlib
import os
import re
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "agent", "lib"))

import png  # noqa: E402
import vt  # noqa: E402

FIXTURE = os.path.join(ROOT, "Tests", "krdcoreTests", "Fixtures", "selftest-80x24-17x33-l6.dump")
RENDER = os.path.join(ROOT, "Sources", "krdcore", "Render.swift")
CELL_W, CELL_H, COLS, ROWS = 17, 33, 80, 24
PANE = (COLS * CELL_W, ROWS * CELL_H)          # 1360x792, the geometry GoldenDumpTests pins
PLACEHOLDER = "\U0010EEEE".encode("utf-8")

_failed = []
_checks = 0


def check(name, ok, detail=""):
    global _checks
    _checks += 1
    if not ok:
        _failed.append(name)
    print("%s %-52s %s" % ("ok  " if ok else "FAIL", name, detail))


def decode(data, **kw):
    d = vt.Decoder(**kw)
    d.feed(data)
    return d


def rgb(w, h, fn):
    return b"".join(bytes(fn(x, y)) for y in range(h) for x in range(w))


def transmit(iid, w, h, pixels, compressed=True):
    payload = zlib.compress(pixels) if compressed else pixels
    head = ("\x1b_Gf=24,s=%d,v=%d,a=t%s,q=2,i=%d,m=0;" % (w, h, ",o=z" if compressed else "", iid))
    return head.encode() + base64.b64encode(payload) + b"\x1b\\"


def place(iid, cols, rows, pid=0, hold_cursor=True, extra=""):
    return ("\x1b_Gi=%d,p=%d,a=p,q=2%s,c=%d,r=%d%s\x1b\\"
            % (iid, pid, ",C=1" if hold_cursor else "", cols, rows, extra)).encode()


# -- 0. the diacritic table is imported, not guessed ------------------------------------------
# Render.swift's placeholderDiacritics is the authority for the row encoding; if someone edits
# it, the copy in vt.py has to move with it or the placeholder path quietly paints row 0.
#
# Found, not addressed by line number: the array used to sit on line 456, and a base that grew by
# 150 lines above it turned this check into a comparison against an unrelated line of code. A test
# that locates its subject survives the file moving around it.
source = open(RENDER, encoding="utf-8").read()
anchor = source.find("placeholderDiacritics")
opening = source.find("= [", anchor)          # the array literal, not the `[Character]` type in front
end = source.find("]", opening) if opening > 0 else len(source)
block = source[opening:end if end > 0 else len(source)]
want = tuple(int(cp, 16) for cp in re.findall(r"\\u\{([0-9A-Fa-f]+)\}", block))
check("0. DIACRITICS == Render.swift", want == vt.DIACRITICS and len(want) == 256,
      "%d codepoints, first=U+%04X" % (len(vt.DIACRITICS), vt.DIACRITICS[0]))

# -- 1. the committed fixture ----------------------------------------------------------------
raw = open(FIXTURE, "rb").read()
d1 = decode(raw, cell_w=CELL_W, cell_h=CELL_H, cols=COLS, rows=ROWS)
frames = d1.frames()
check("1. two frames", len(frames) == 2, "frames=%d" % len(frames))
f0, f1 = frames[0], frames[-1]
print("     frame0 %r sha256=%s" % (f0, hashlib.sha256(f0.rgb).hexdigest()))
print("     frame1 %r sha256=%s" % (f1, hashlib.sha256(f1.rgb).hexdigest()))
check("1. pane is 1360x792", (f0.width, f0.height) == PANE == (f1.width, f1.height),
      "%dx%d" % (f0.width, f0.height))
check("1. frame0 places all 60 tiles", f0.images == 60 == f0.placements, "images=%d" % f0.images)
# The moving bar leaves x<8 and arrives at x~680, dirtying tiles in columns 0, 4 and 5: three
# of the grid's ten columns, times its six rows - the dirty-only path, exercised.
check("1. frame1 redraws only the dirty tiles", f1.images == 18, "images=%d of 60" % f1.images)
check("1. 78 placements over 60 live image ids",
      (len(d1.placements()), len(d1.images())) == (78, 60),
      "placements=%d images=%d" % (len(d1.placements()), len(d1.images())))
check("1. no anomalies in a real stream", d1.anomalies == [], "%d" % len(d1.anomalies))

QUADRANTS = {(10, 10): (255, 0, 255), (1000, 10): (255, 255, 0),
             (10, 700): (0, 255, 255), (1000, 700): (255, 128, 0)}   # GoldenDumpTests.swift:36-38
for (x, y), want in sorted(QUADRANTS.items()):
    check("1. frame0 px(%d,%d) == %s" % (x, y, want), f0.probe(x, y) == want,
          "got %s" % (f0.probe(x, y),))
for (x, y), want in sorted(QUADRANTS.items()):
    check("1. last frame px(%d,%d) == %s" % (x, y, want), f1.probe(x, y) == want,
          "got %s" % (f1.probe(x, y),))
png_bytes = f0.png_bytes()
check("1. frame0.png_bytes() is a 1360x792 PNG",
      png_bytes[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", png_bytes[16:24]) == PANE,
      "%d B" % len(png_bytes))

# -- 2. m=1 chunking must not change a pixel -------------------------------------------------
# Take a real transmit body out of the fixture and cut its base64 into three, the way
# Render.swift's 4096-character loop does on a tile that will not fit in one APC.
ctl, b64 = re.search(rb"\x1b_G(f=[^;]*);([^\x1b]*)\x1b\\", raw).groups()
ctl = ctl.replace(b",m=0", b"")
cut1, cut2 = len(b64) // 3, 2 * len(b64) // 3
tail = place(100, 8, 4, pid=1000) + b"\x1b[?2026l"
whole = b"\x1b[?2026h\x1b_G" + ctl + b",m=0;" + b64 + b"\x1b\\" + tail
split = (b"\x1b[?2026h" + b"\x1b_G" + ctl + b",m=1;" + b64[:cut1] + b"\x1b\\"
         + b"\x1b_Gm=1;" + b64[cut1:cut2] + b"\x1b\\"
         + b"\x1b_Gm=0;" + b64[cut2:] + b"\x1b\\" + tail)
wa, sa = decode(whole, cell_w=CELL_W, cell_h=CELL_H), decode(split, cell_w=CELL_W, cell_h=CELL_H)
check("2. chunked image bytes are identical",
      wa.images()[100].pixels == sa.images()[100].pixels,
      "%d B" % len(wa.images()[100].pixels))
check("2. chunked frame is byte-identical", wa.frames()[0].rgb == sa.frames()[0].rgb,
      "sha256=%s" % hashlib.sha256(sa.frames()[0].rgb).hexdigest())
trickle = vt.Decoder(cell_w=CELL_W, cell_h=CELL_H)
for i in range(len(split)):
    trickle.feed(split[i:i + 1])       # one byte per call: no sequence may straddle a boundary
check("2. one-byte-at-a-time feed agrees",
      trickle.frames()[0].rgb == sa.frames()[0].rgb
      and trickle.images()[100].pixels == sa.images()[100].pixels)

# -- 3. f=32: alpha is composited, not dropped ------------------------------------------------
rgba = bytes([255, 0, 0, 255,       # 0,0 opaque red
              0, 255, 0, 0,         # 1,0 fully transparent
              0, 0, 255, 128,       # 0,1 half alpha
              255, 255, 255, 255])  # 1,1 opaque white
d3 = decode(b"\x1b[?2026h\x1b_Gf=32,s=2,v=2,a=t,i=7,m=0;" + base64.b64encode(rgba)
            + b"\x1b\\" + place(7, 1, 1, pid=70) + b"\x1b[?2026l",
            cell_w=CELL_W, cell_h=CELL_H)
img3, f3 = d3.images()[7], d3.frames()[0]
check("3. RGBA keeps 4 channels", (img3.channels, len(img3.pixels)) == (4, 16),
      "%dx%d ch=%d %d B" % (img3.w, img3.h, img3.channels, len(img3.pixels)))
# Nearest-neighbour into one 17x33 cell: x<9 takes source column 0, y<17 takes source row 0.
check("3. opaque pixel survives", f3.probe(0, 0) == (255, 0, 0), "got %s" % (f3.probe(0, 0),))
check("3. transparent pixel leaves the canvas black", f3.probe(10, 0) == (0, 0, 0),
      "got %s" % (f3.probe(10, 0),))
check("3. a=128 composites over black, not dropped", f3.probe(0, 20) == (0, 0, 128),
      "got %s" % (f3.probe(0, 20),))
check("3. fitted to the cell rect", (f3.width, f3.height) == (CELL_W, CELL_H)
      and f3.probe(16, 32) == (255, 255, 255), "%dx%d" % (f3.width, f3.height))

# -- 4. U=1 placeholder grid ------------------------------------------------------------------
PH_W, PH_H, IID = 2 * CELL_W, CELL_H, 0x112233         # 34x33 px into 2x1 cells
PH_PIX = rgb(PH_W, PH_H, lambda x, y: (10 + x * 7 % 200, 20 + y * 5 % 200, 30 + (x + y) % 200))
AT_COL, AT_ROW = 5, 3                                  # 1-based cell of the grid's top-left
X0, Y0 = (AT_COL - 1) * CELL_W, (AT_ROW - 1) * CELL_H


def grid(rows, colour=(17, 34, 51), marks=None):
    """The invisible cells: `rows` lines of two placeholder cells, row diacritic on the first."""
    out = b""
    for line in range(rows):
        mark = chr(vt.DIACRITICS[marks[line] if marks else line]).encode("utf-8")
        out += ("\x1b[%d;%dH\x1b[38;2;%d;%d;%dm" % ((AT_ROW + line, AT_COL) + colour)).encode()
        out += PLACEHOLDER + mark + PLACEHOLDER + b"\x1b[39m"
    return out


head = (b"\x1b[?2026h" + transmit(IID, PH_W, PH_H, PH_PIX))
virt = place(IID, 2, 1, pid=2000, extra=",U=1")
# The cursor is at 1,1 when `a=p` arrives and at row 3, col 5 when the cells are written. Trust
# the cursor and the image lands at 0,0; trust the cells and it lands where a terminal paints it.
d4 = decode(head + virt + grid(1) + b"\x1b[?2026l", cell_w=CELL_W, cell_h=CELL_H)
p4, f4 = d4.placements()[0], d4.frames()[0]
check("4. Frame.cells counts the placeholder cells", f4.cells == 2, "cells=%d" % f4.cells)
check("4. rect comes from the grid, not the stale cursor",
      (p4.col, p4.row, p4.cols, p4.rows) == (AT_COL, AT_ROW, 2, 1), "%r" % (p4,))
check("4. pixel origin is the grid's cell rect", (X0, Y0) == (68, 66), "%s" % ((X0, Y0),))
check("4. image pixels land at the origin", f4.probe(X0, Y0) == tuple(PH_PIX[0:3]),
      "got %s" % (f4.probe(X0, Y0),))
check("4. image pixels land at the far corner",
      f4.probe(X0 + PH_W - 1, Y0 + PH_H - 1) == tuple(PH_PIX[-3:]),
      "got %s" % (f4.probe(X0 + PH_W - 1, Y0 + PH_H - 1),))
check("4. no anomalies", d4.anomalies == [], "%d" % len(d4.anomalies))
check("4. frame is the drawn extent", (f4.width, f4.height) == (X0 + PH_W, Y0 + PH_H),
      "%dx%d" % (f4.width, f4.height))
# A grid with no `a=p` still paints: the cells are the only truth a terminal has.
d4b = decode(head + grid(1) + b"\x1b[?2026l", cell_w=CELL_W, cell_h=CELL_H)
f4b = d4b.frames()[0]
check("4. grid without a placement derives its own rect",
      f4b.cells == 2 and f4b.probe(X0, Y0) == tuple(PH_PIX[0:3])
      and len(d4b.placements()) == 1 and d4b.placements()[0].unicode_placeholder,
      "%r" % (d4b.placements()[0],))
# Two rows: the row diacritic is what says which slice of the image belongs in the second line.
TALL_PIX = rgb(PH_W, 2 * CELL_H, lambda x, y: (40 + x % 100, 50 + y % 100, 60 + (x + y) % 100))
tall = (b"\x1b[?2026h" + transmit(IID, PH_W, 2 * CELL_H, TALL_PIX)
        + place(IID, 2, 2, pid=2001, extra=",U=1") + grid(2) + b"\x1b[?2026l")
d4c = decode(tall, cell_w=CELL_W, cell_h=CELL_H)
f4c, p4c = d4c.frames()[0], d4c.placements()[0]
check("4. a two-row grid maps the row diacritic",
      (p4c.cols, p4c.rows) == (2, 2) and f4c.cells == 4
      and f4c.probe(X0, Y0) == tuple(TALL_PIX[0:3])
      and f4c.probe(X0, Y0 + CELL_H) == tuple(TALL_PIX[PH_W * 3 * CELL_H:PH_W * 3 * CELL_H + 3]),
      "%r cells=%d" % (p4c, f4c.cells))
check("4. a two-row grid raises no anomaly", d4c.anomalies == [], "%d" % len(d4c.anomalies))
broken = decode(b"\x1b[?2026h" + transmit(IID, PH_W, 2 * CELL_H, TALL_PIX)
                + place(IID, 2, 2, pid=2002, extra=",U=1") + grid(2, marks=[0, 2])
                + b"\x1b[?2026l", cell_w=CELL_W, cell_h=CELL_H)
check("4. a wrong row diacritic is reported", len(broken.anomalies) == 1, broken.anomalies[:1])

# -- 5. cursor rules --------------------------------------------------------------------------
ONE = rgb(1, 1, lambda x, y: (255, 255, 255))
cur = decode(b"\x1b[1;1H" + transmit(1, 1, 1, ONE) + transmit(2, 1, 1, ONE)
             + b"\x1b[?2026h" + place(1, 2, 1, pid=11, hold_cursor=False)   # cursor -> (1, 3)
             + place(2, 1, 1, pid=12) + b"\x1b[?2026l", cell_w=CELL_W, cell_h=CELL_H)
got = [(p.col, p.row) for p in cur.placements()]
check("5. a placement without C=1 moves the cursor", got == [(1, 1), (3, 1)], "%s" % (got,))
held = decode(b"\x1b[2;2H" + transmit(1, 1, 1, ONE) + transmit(2, 1, 1, ONE)
              + b"\x1b[?2026h" + place(1, 2, 1, pid=11) + place(2, 1, 1, pid=12)
              + b"\x1b[?2026l", cell_w=CELL_W, cell_h=CELL_H)
check("5. C=1 leaves the anchor where ESC[r;cH put it",
      [(p.col, p.row) for p in held.placements()] == [(2, 2), (2, 2)],
      "%s" % ([(p.col, p.row) for p in held.placements()],))
# The three cursor forms krd writes: ESC[r;cH, ESC[H (1,1) and ESC[r;H (row r, column 1).
cups = decode(b"\x1b[7;9H\x1b[H" + transmit(1, 1, 1, ONE) + transmit(2, 1, 1, ONE)
              + b"\x1b[?2026h" + place(1, 1, 1, pid=13) + b"\x1b[3;H" + place(2, 1, 1, pid=14)
              + b"\x1b[?2026l", cell_w=CELL_W, cell_h=CELL_H)
check("5. ESC[H is 1,1 and ESC[r;H is row r, column 1",
      [(p.col, p.row) for p in cups.placements()] == [(1, 1), (1, 3)],
      "%s" % ([(p.col, p.row) for p in cups.placements()],))

# krd's diagnostic shapes (`emitVariant`, Render.swift:653) draw with `a=T` in the transmit
# command itself, with no `a=p` to follow - and variant 1 sends no id at all.
tdraw = decode(b"\x1b[2;3H" + transmit(1, 1, 1, ONE).replace(b"a=t", b"a=T").replace(
    b",m=0;", b",C=1,c=2,r=1,m=0;") + b"\x1b[?2026h\x1b[?2026l", cell_w=CELL_W, cell_h=CELL_H)
check("5. a=T draws where it transmits", tdraw.frames()[0].probe(2 * CELL_W, CELL_H) == (255, 255, 255)
      and len(tdraw.placements()) == 1, "%r" % (tdraw.placements(),))
noid = decode(b"\x1b[?2026h" + transmit(1, 1, 1, ONE).replace(b"a=t", b"a=T").replace(
    b"i=1,m=0;", b",C=1,c=1,r=1,m=0;") + b"\x1b[?2026l", cell_w=CELL_W, cell_h=CELL_H)
check("5. a=T without i= still gets placed",
      noid.frames()[0].probe(0, 0) == (255, 255, 255) and len(noid.images()) == 1
      and min(noid.images()) > 1 << 24, "%r" % (list(noid.images()),))

# -- 6. ESC[2J wipes the canvas ---------------------------------------------------------------
RED = rgb(1, 1, lambda x, y: (255, 0, 0))
BLUE = rgb(1, 1, lambda x, y: (0, 0, 255))
cleared = decode(transmit(1, 1, 1, RED) + b"\x1b[?2026h" + place(1, 1, 1, pid=11)
                 + b"\x1b[?2026l" + b"\x1b[2J" + transmit(2, 1, 1, BLUE)
                 + b"\x1b[?2026h" + b"\x1b[2;1H" + place(2, 1, 1, pid=22) + b"\x1b[?2026l",
                 cell_w=CELL_W, cell_h=CELL_H)
before, after = cleared.frames()
check("6. the pre-clear frame is red at 0,0", before.probe(0, 0) == (255, 0, 0))
check("6. ESC[2J clears the canvas, not the image store",
      after.probe(0, 0) == (0, 0, 0) and after.probe(0, CELL_H) == (0, 0, 255)
      and len(cleared.images()) == 2, "%dx%d" % (after.width, after.height))

# -- 7. determinism ---------------------------------------------------------------------------
again = decode(raw, cell_w=CELL_W, cell_h=CELL_H, cols=COLS, rows=ROWS)
check("7. same bytes -> same frame hashes",
      [hashlib.sha256(f.rgb).hexdigest() for f in again.frames()]
      == [hashlib.sha256(f.rgb).hexdigest() for f in frames],
      hashlib.sha256(f0.rgb).hexdigest()[:16])
check("7. and the same placements",
      [(p.image_id, p.col, p.row, p.cols, p.rows) for p in again.placements()]
      == [(p.image_id, p.col, p.row, p.cols, p.rows) for p in d1.placements()])

# -- 8. the two documented refusals -----------------------------------------------------------
# png.py writes filter-0 rows and nothing else, so the file it produces is checkable by hand.
small = rgb(CELL_W, CELL_H, lambda x, y: (x * 15 % 256, y * 7 % 256, (x * y) % 256))
blob = png.write_png_bytes(CELL_W, CELL_H, small)
idat = blob[blob.index(b"IDAT") + 4:blob.index(b"IEND") - 8]
rows = zlib.decompress(idat)
check("8. png.write_png_bytes writes filter-0 rows",
      blob[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", blob[16:24]) == (CELL_W, CELL_H)
      and len(rows) == CELL_H * (CELL_W * 3 + 1)
      and all(rows[y * (CELL_W * 3 + 1)] == 0 for y in range(CELL_H))
      and rows[1:1 + 32] == small[:32],
      "%d B, IDAT %d B" % (len(blob), len(idat)))
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".png-roundtrip.png")
png.write_rgb(path, CELL_W, CELL_H, small)
written = open(path, "rb").read()
os.unlink(path)
check("8. png.write_rgb writes the same bytes it returns", written == blob, "%d B" % len(written))
d8 = decode(b"\x1b[?2026h\x1b_Gf=100,a=t,i=9,m=0;" + base64.b64encode(blob)
            + b"\x1b\\" + place(9, 1, 1, pid=90) + transmit(10, 1, 1, RED)
            + place(10, 1, 1, pid=91) + b"\x1b[?2026l", cell_w=CELL_W, cell_h=CELL_H)
# f=100 is refused on purpose (module docstring): the PNG stays out of `images()` and the
# anomaly names it, while the rest of the frame - the tile at 17,0 - still decodes.
check("8. f=100 is refused with a named anomaly",
      any("f=100" in a for a in d8.anomalies) and 9 not in d8.images()
      and any("image 9" in a for a in d8.anomalies), d8.anomalies[0])
check("8. the rest of that frame still decodes", d8.frames()[0].probe(CELL_W, 0) == (255, 0, 0),
      "%r" % (d8.frames()[0],))

print("\n%d checks, %d failed" % (_checks, len(_failed)))
if _failed:
    for name in _failed:
        print("FAILED: %s" % name)
    sys.exit(1)
