#!/bin/sh
# FOUND 2026-10-31, not fixed. A reproduction, not a regression test: it fails on purpose.
#
# `--dpr N` is "device pixels per reported cell": picture *quality*. With unicode placeholders the
# terminal fits the image into the cells, so a 2x capture is sharper and still exactly the box
# (design §6.9, pinned by checks/quality-does-not-move-geometry.sh).
#
# The pixel-sized path has no fitting. It draws the image one pixel per device pixel, so a 2x
# capture is a picture twice the size of its box: it overflows the box, covers its neighbours and
# gets clipped by the pane. Measured at 80x24 with `.build/release/krd --demo --no-placeholders
# --dpr 2`: the stage's box is 40x13 cells (680x429 px) and the image it sends is 1360x858 --
# exactly 2x -- placed at the box origin, so it runs off the right edge of a 1360 px pane.
#
# What it should do: on the pixel path `dpr` is meaningless (there is no fitting to pay for it), so
# either clamp it to 1 or ask for the picture at exactly the cell box. `PaneGeometry` already knows
# whether placeholders are in play; the clamp belongs where the capture size is chosen.
#
# It is left here as a finding so `kagent prove --check agent/hunts/<this> --baseline <any ref>`
# keeps saying `not-fixed` until somebody decides which of those two is right.
set -eu
KAGENT=${KAGENT:-$(cd "$(dirname "$0")/../.." && pwd)/agent/bin/kagent}
BINARY=${BINARY:-$(cd "$(dirname "$0")/../.." && pwd)/.build/release/krd}

"$KAGENT" --json --target host render --pane 80x24 --cell 17x33 --seconds 6 --quiet \
    --run hunt-pixel-dpr -- "$BINARY" --demo --no-placeholders --dpr 2 \
    | python3 -c '
import json, sys
report = json.load(sys.stdin)
pictures = [p for p in report["pictures"] if not p.get("probe")]
overflowing = []
for p in pictures:
    col, row, cols, rows = p["cell_rect"]
    box = (cols * report["cell"]["w"], rows * report["cell"]["h"])
    native = tuple(p.get("native_px") or ())
    if native != box:
        overflowing.append((p["image"], p["cell_rect"], native, box))
print("pictures=%d overflowing=%d" % (len(pictures), len(overflowing)))
for image, rect, native, box in overflowing[:3]:
    print("  image %s at %s sends %s for a %s box" % (image, rect, native, box))
if overflowing:
    print("FAIL the pixel path drew a picture larger than its box on screen")
    sys.exit(1)
'
