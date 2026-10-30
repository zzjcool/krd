#!/usr/bin/env python3
"""Check a krd frame stream against its declared pane: does the grid fill its box exactly?

krd places each tile with `ESC[<row>;<col>H` (1-based) and an APC carrying `c=<cols>,r=<rows>`,
so the byte stream itself says where every picture went.

usage: frames.py <stream.bin> <paneCols>x<paneRows>
Checks:
  1. the first (full) frame tiles its bbox with no hole and no overlap;
  2. no placement, in any frame, falls outside that bbox (a shifted row/column shows up here);
  3. nothing is placed on the last cell of the last row (CLAUDE/Chrome rule: it would scroll);
  4. prints the bbox, so it can be compared with the layout math (fit + centred origin).
"""
import re
import sys

SYNC = re.compile(rb"\x1b\[\?2026h(.*?)\x1b\[\?2026l", re.S)
CUP = re.compile(rb"\x1b\[(\d+);(\d+)H")
EVENT = re.compile(rb"\x1b\[(\d+);(\d+)H|\x1b_G([^\x1b]*)\x1b\\")


def frames(path):
    data = open(path, "rb").read()
    blocks = SYNC.findall(data)
    return blocks if blocks else [data]


def placements(block):
    out, pos = [], (1, 1)
    for m in EVENT.finditer(block):
        if m.group(1) is not None:
            pos = (int(m.group(1)), int(m.group(2)))
        else:
            kv = dict(p.split("=", 1) for p in m.group(3).decode("latin1").split(",") if "=" in p)
            if kv.get("a") == "p":
                out.append((pos[0] - 1, pos[1] - 1, int(kv.get("c", 1)), int(kv.get("r", 1)), kv.get("i")))
    return out


def grid_of(ev, cols, rows):
    g = {}
    for r0, c0, c, r, i in ev:
        for y in range(r0, r0 + r):
            for x in range(c0, c0 + c):
                g[(y, x)] = g.get((y, x), 0) + 1
    return g


def main(argv):
    path = argv[1]
    cols, rows = (int(v) for v in argv[2].split("x"))
    fs = frames(path)
    all_ev = [e for f in fs for e in placements(f)]
    if not all_ev:
        print(f"{path}: NO PLACEMENTS (pixel path? no frame?)")
        return 2
    top = min(e[0] for e in all_ev); bot = max(e[0] + e[3] - 1 for e in all_ev)
    left = min(e[1] for e in all_ev); right = max(e[1] + e[2] - 1 for e in all_ev)
    bw, bh = right - left + 1, bot - top + 1
    first = placements(fs[0])
    g = grid_of(first, cols, rows)
    want = [(y, x) for y in range(top, bot + 1) for x in range(left, right + 1)]
    holes = [p for p in want if p not in g]
    over = [p for p in want if g.get(p, 0) > 1]
    outside = [(y, x) for (y, x), n in g.items() if y < top or y > bot or x < left or x > right]
    last = g.get((rows - 1, cols - 1), 0)
    short_rows = []
    for y in range(top, bot + 1):
        run = sum(1 for x in range(left, right + 1) if g.get((y, x)))
        if run != bw:
            short_rows.append((y, run))
    verdict = "OK" if not (holes or over or outside or last or short_rows) else "DEFECT"
    print(f"{verdict} {argv[2]:>7}  bbox {bw}x{bh} at r{top}..{bot} c{left}..{right}"
          f"  first-frame placements {len(first)}  frames {len(fs)}  last-cell {last}"
          + (f"  holes {len(holes)} {holes[:4]}" if holes else "")
          + (f"  overlap {len(over)} {over[:4]}" if over else "")
          + (f"  OUTSIDE {len(outside)} {outside[:4]}" if outside else "")
          + (f"  short-rows {short_rows[:4]}" if short_rows else ""))
    return 0 if verdict == "OK" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
