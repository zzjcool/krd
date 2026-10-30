#!/usr/bin/env python3
"""Print the picture rectangles a krd frame put on a pane, from a Rex VT capture.

krd paints pictures on cells that hold kitty unicode placeholders (U+10EEEE), and those characters
survive `rex capture --format=vt` even though the pictures themselves do not. So the text buffer is a
map of where every picture is: read the runs, one per row, and compare them with the layout.

    rex capture -s "$REX_SESSION" -b "$B" --format=vt > /tmp/pane.vt
    python3 wall-runs.py /tmp/pane.vt

Rex's buffer stores the per-row diacritic as its own cell, which splits one picture into two runs
(`(45,46)` then `(47,100)` above). The runs are therefore summed per row, and the *span* is what
matters: 45..99 is a 54-cell picture starting at column 45.
"""

import re
import sys

PLACEHOLDER = chr(0x10EEEE)
ESC_CSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
ESC_APC = re.compile(r"\x1b_G.*?\x1b\\", re.S)


def runs(line: str) -> list[tuple[int, int]]:
    out, start = [], None
    for col, ch in enumerate(line):
        if ch == PLACEHOLDER:
            if start is None:
                start = col
        elif start is not None:
            out.append((start, col))
            start = None
    if start is not None:
        out.append((start, len(line)))
    return out


def main(path: str) -> int:
    raw = open(path, "rb").read().decode("utf-8", "replace")
    clean = ESC_APC.sub("", ESC_CSI.sub("", raw))
    lines = clean.split("\n")

    rows = {i: runs(line) for i, line in enumerate(lines)}
    rows = {i: r for i, r in rows.items() if r}
    if not rows:
        print("no placeholder cells: this frame is on the pixel path "
              "(--no-placeholders), so the pictures are invisible to a text capture")
    else:
        total = 0
        for row in sorted(rows):
            cells = sum(end - start for start, end in rows[row])
            first = min(start for start, _ in rows[row])
            last = max(end for _, end in rows[row])
            total += cells
            print(f"row {row:3d}  cells {cells:4d}  cols {first:4d}..{last - 1:4d}")
        print(f"total {total} cells in {len(rows)} rows")

    for line in lines:
        if "demo " in line:
            print("footer:", line.strip())
            break
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "/dev/stdin"))
