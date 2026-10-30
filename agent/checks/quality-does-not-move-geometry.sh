#!/bin/sh
# `--dpr` is picture *quality*: more device pixels per cell, the same cells. If raising it moves a
# picture or changes its cell rectangle, then quality and geometry are entangled, and every layout
# measurement becomes a function of how good the terminal is.
#
# It also pins the other half of the same rule: pixels are allowed to be a multiple of the cell box
# (the terminal fits the image into its cells), and are NOT allowed to be smaller than it -- an
# upscaled picture is where a 1:1 terminal shows seams.
set -eu
KAGENT=${KAGENT:-$(cd "$(dirname "$0")/../.." && pwd)/agent/bin/kagent}
BINARY=${BINARY:-$(cd "$(dirname "$0")/../.." && pwd)/.build/release/krd}
PANE=${PANE:-100x30}
CELLW=${CELLW:-17}
CELLH=${CELLH:-33}

for dpr in 1 2 3; do
    "$KAGENT" --json --target host render --pane "$PANE" --cell "${CELLW}x${CELLH}" --seconds 6 \
        --quiet --strict-fit --run "dpr-$dpr" -- "$BINARY" --demo --dpr "$dpr" \
        | python3 -c '
import json, sys
dpr, cw, ch = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
report = json.load(sys.stdin)
pictures = [p for p in report["pictures"] if not p.get("probe")]
problems = []
if report["misfits"]:
    problems.append("dpr %s: %d picture(s) do not match their cell box: %s" % (dpr, len(report["misfits"]), report["misfits"][:1]))
for p in pictures:
    c, r, w, h = p["cell_rect"]
    want = (w * cw * int(dpr), h * ch * int(dpr))
    got = tuple(p.get("native_px") or ())
    if got != want:
        problems.append("dpr %s: %s is %s px, expected %s (cells %s x cell %dx%d x dpr)" % (dpr, p["image"], got, want, p["cell_rect"], cw, ch))
for line in problems:
    print("  FAIL " + line)
print("  dpr %s  pictures=%d  cells=%s  %s" % (dpr, len(pictures), [p["cell_rect"] for p in pictures][:1],
                                               "ok" if not problems else "FAILED"))
sys.exit(1 if problems else 0)
' "$dpr" "$CELLW" "$CELLH" || exit 1
done
