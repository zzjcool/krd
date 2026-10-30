#!/bin/sh
# The wall is a layout of pictures, and every terminal it is ever drawn in has a different size. So
# the invariants have to hold at any pane, not at the one somebody tested:
#
#   * a picture is inside the pane,
#   * it never covers the scroll-bar column or the footer row (the two places the design reserves),
#   * no two pictures overlap,
#   * its pixels are exactly its cell box (the seam bug a 1:1 terminal makes visible).
#
# It also asserts the run left nothing behind: `krd` that outlives its ssh wedges ScreenCaptureKit
# for every later run, and the next person sees "the wall draws no pictures" as a product bug.
#
# Panes include the awkward ones on purpose: 30x10 has no room for a card band, 20x40 is narrow and
# tall (the cards must stack), 200x60 is wider than any display it is showing.
set -eu
KAGENT=${KAGENT:-$(cd "$(dirname "$0")/../.." && pwd)/agent/bin/kagent}
TARGET=${TARGET:-vm}
BINARY=${BINARY:-'~/bin/krd'}
SECONDS_TO_RUN=${SECONDS_TO_RUN:-14}
PANES=${PANES:-"146x46 100x30 60x20 30x10 20x40 200x60"}
CELLW=${CELLW:-17}
CELLH=${CELLH:-33}

failed=0
for pane in $PANES; do
    run="wall-fits-$pane"
    report=$("$KAGENT" --json render --target "$TARGET" --pane "$pane" --cell "${CELLW}x${CELLH}" \
        --seconds "$SECONDS_TO_RUN" --quiet --allow-empty --strict-fit --run "$run" \
        -- "$BINARY" --wall)
    printf '%s' "$report" | python3 -c '
import json, sys
pane, cw, ch = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
cols, rows = (int(x) for x in pane.split("x"))
report = json.load(sys.stdin)
pictures = [p for p in report.get("pictures", []) if not p.get("probe")]
problems = []
if not pictures:
    problems.append("no picture at all: nothing was placed in this pane")
for p in pictures:
    c, r, w, h = p["cell_rect"]
    if c < 1 or r < 1:
        problems.append("picture starts outside the pane at %d,%d" % (c, r))
    if c + w - 1 > cols:
        problems.append("columns %d..%d run past the pane width %d" % (c, c + w - 1, cols))
    if r + h - 1 > rows:
        problems.append("rows %d..%d run past the pane height %d" % (r, r + h - 1, rows))
    if c + w - 1 >= cols:
        problems.append("picture %d covers the scroll-bar column %d" % (p["image"], cols))
    if r + h - 1 >= rows:
        problems.append("picture %d covers the footer row %d" % (p["image"], rows))
    # Pixels are quality, cells are geometry: a terminal that reports its cell in points asks for
    # two device pixels per cell (`--cell-mode points`, the Rex-like default), so the expected size
    # is an integer multiple of the box -- and a fraction of it is the seam bug, not a small picture.
    native = p.get("native_px")
    if native:
        k = native[0] / (w * cw) if w and cw else 0
        if not (k >= 1 and float(k).is_integer()
                and native[1] == round(h * ch * k)):
            problems.append("picture %d is %s px for a %dx%d cell box (%.2f x)" % (
                p["image"], native, w, h, k))
for i in range(len(pictures)):
    for j in range(i + 1, len(pictures)):
        a, b = pictures[i]["cell_rect"], pictures[j]["cell_rect"]
        if not (a[0] + a[2] <= b[0] or b[0] + b[2] <= a[0]
                or a[1] + a[3] <= b[1] or b[1] + b[3] <= a[1]):
            problems.append("pictures %d and %d overlap: %s %s"
                            % (pictures[i]["image"], pictures[j]["image"], a, b))
for line in sorted({p for p in problems}):
    print("  FAIL " + line)
print("  %-8s pictures=%d misfits=%d %s" % (pane, len(pictures), len(report.get("misfits") or []),
                                            "ok" if not problems else "FAILED"))
sys.exit(1 if problems else 0)
' "$pane" "$CELLW" "$CELLH" || failed=1
done

survivors=$(ssh "${KRD_MACHINE:-krd-vm}" 'pgrep -x krd | wc -l' 2>/dev/null | tr -d ' ' || echo "?")
if [ "$survivors" != "0" ] && [ "$TARGET" = "vm" ]; then
    echo "  FAIL $survivors krd process(es) outlived the run: they wedge the next capture"
    failed=1
else
    echo "  survivors=0"
fi
exit $failed
