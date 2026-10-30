#!/bin/sh
# A wall card must be the shape of the window it shows. The bug this catches shipped twice: a card
# sized by its slot instead of by its picture, which is invisible in a text capture (the cells are
# right) and obvious to a person (the window is stretched).
#
# Runs against the deployed build on the VM, because that is the only place a real ScreenCaptureKit
# desktop exists. Fails when:
#   * a picture leaves the pane, overlaps another, or covers the final cell of the final row
#   * a picture's pixels are not its cell box (the seam bug)
#   * no card's aspect matches any on-screen window's aspect within 2%
set -eu
KAGENT=${KAGENT:-$(cd "$(dirname "$0")/../.." && pwd)/agent/bin/kagent}
PANE=${PANE:-146x46}
CELL=${CELL:-17x33}

windows=$("$KAGENT" --json windows)
render=$("$KAGENT" --json render --target vm --pane "$PANE" --cell "$CELL" --seconds 9 -- \
          '~/bin/krd' --wall)

printf '%s\n%s\n' "$windows" "$render" | python3 -c '
import json, sys

lines = sys.stdin.read().strip().splitlines()
# Two JSON documents were concatenated with a newline; split on the boundary line.
raw = "\n".join(lines)
decoder = json.JSONDecoder()
windows, index = decoder.raw_decode(raw)
render, _ = decoder.raw_decode(raw[index:].lstrip())

cols, rows = (int(x) for x in sys.argv[1].split("x"))
cell = (int(x) for x in sys.argv[2].split("x"))
cell_w, cell_h = cell

problems = []
rects = render["placeholder_rects"]
if not rects:
    problems.append("no pictures: the wall drew nothing")
for r in rects:
    if r["col1"] > cols or r["row1"] > rows:
        problems.append("picture outside the pane: %s" % r)
    if r["row1"] >= rows and r["col1"] >= cols:
        problems.append("picture covers the final cell of the final row: %s" % r)
for i in range(len(rects)):
    for j in range(i + 1, len(rects)):
        a, b = rects[i], rects[j]
        if not (a["col1"] < b["col0"] or b["col1"] < a["col0"]
                or a["row1"] < b["row0"] or b["row1"] < a["row0"]):
            problems.append("pictures overlap: %s %s" % (a, b))
if render["misfits"]:
    problems.append("pictures do not match their cell box: %s" % render["misfits"][:2])

shapes = []
for w in windows["windows"]:
    _, _, width, height = w["rect"]
    if height:
        shapes.append((width / height, "%s %dx%d" % (w["app"], width, height)))

# The stage is the display; the cards are the windows. Both are fitted to the source aspect, so a
# card matches *some* window and the stage matches the display it was captured from.
matched = 0
for r in rects:
    aspect = (r["cols"] * cell_w) / (r["rows"] * cell_h)
    best = min(shapes, key=lambda s: abs(s[0] - aspect), default=None)
    if best and abs(best[0] - aspect) / best[0] < 0.02:
        matched += 1
        print("  card %dx%d cells = %.3f -> %s (%.3f)" % (r["cols"], r["rows"], aspect,
                                                          best[1], best[0]))
    else:
        problems.append("card %dx%d cells has aspect %.3f, no window matches it"
                        % (r["cols"], r["rows"], aspect))

print("pictures=%d matched=%d misfits=%d" % (len(rects), matched, len(render["misfits"])))
if problems:
    for p in problems:
        print("FAIL", p)
    sys.exit(1)
' "$PANE" "$CELL"
