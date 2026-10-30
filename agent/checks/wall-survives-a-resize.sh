#!/bin/sh
# A pane that is resized after the first paint must be re-laid-out, not stretched into the old grid.
#
# The failure this is written against is the classic one: the layout is recomputed from the pty, but
# the pictures already placed are left where the old rectangle put them. In a text capture that looks
# fine (the cells are re-drawn); in the decoded stream the old placements are still there, and the
# pictures that should fill the new pane sit outside it.
#
# Fails when a picture lands outside the *new* pane, when two overlap, or when a picture's pixels are
# no longer its cell box.
set -eu
KAGENT=${KAGENT:-$(cd "$(dirname "$0")/../.." && pwd)/agent/bin/kagent}
FROM=${FROM:-146x46}
TO=${TO:-100x30}
CELL=${CELL:-17x33}

"$KAGENT" --json render --target vm --pane "$FROM" --cell "$CELL" --seconds 16 --resize "8:$TO" \
    --strict-fit -- '~/bin/krd' --wall | python3 -c '
import json, sys

report = json.load(sys.stdin)
cols, rows = (int(x) for x in sys.argv[1].split("x"))
rects = report["placeholder_rects"]
problems = []
if len(report["pngs"]) < 2:
    problems.append("no frame after the resize: the stream shows only the startup paint")
for r in rects:
    if r["col1"] > cols or r["row1"] > rows:
        problems.append("picture outside the resized pane %dx%d: %s" % (cols, rows, r))
    if r["row1"] >= rows and r["col1"] >= cols:
        problems.append("picture covers the final cell of the final row: %s" % r)
for i in range(len(rects)):
    for j in range(i + 1, len(rects)):
        a, b = rects[i], rects[j]
        if not (a["col1"] < b["col0"] or b["col1"] < a["col0"]
                or a["row1"] < b["row0"] or b["row1"] < a["row0"]):
            problems.append("pictures overlap: %s %s" % (a, b))
if report["misfits"]:
    problems.append("pictures do not match their cell box: %s" % report["misfits"][:2])

for r in rects:
    print("  picture rows %d..%d cols %d..%d (%dx%d cells)"
          % (r["row0"], r["row1"], r["col0"], r["col1"], r["cols"], r["rows"]))
print("frames=%d pictures=%d misfits=%d pane=%s" % (report["frames"], len(rects),
                                                    len(report["misfits"]), sys.argv[1]))
if problems:
    for p in problems:
        print("FAIL", p)
    sys.exit(1)
' "$TO"
