#!/bin/sh
# krd has two ways to put a picture on a terminal: unicode placeholders (`U=1`, the default) and a
# pixel-sized placement. They are separate code paths that compute the same geometry, and the only
# reason to trust either is that they say the same thing.
#
# If they disagree, one of them is lying about where the picture is, and every later measurement
# inherits the lie -- which is exactly how "the card is in the wrong place" becomes unreproducible.
set -eu
KAGENT=${KAGENT:-$(cd "$(dirname "$0")/../.." && pwd)/agent/bin/kagent}
BINARY=${BINARY:-$(cd "$(dirname "$0")/../.." && pwd)/.build/release/krd}
PANE=${PANE:-100x30}
CELL=${CELL:-17x33}

geometry() {
    "$KAGENT" --json --target host render --pane "$PANE" --cell "$CELL" --seconds 8 --quiet \
        --run "transport-$1" -- "$BINARY" --demo "$2" \
        | python3 -c '
import json, sys
report = json.load(sys.stdin)
pictures = [p for p in report["pictures"] if not p.get("probe")]
print(json.dumps(sorted((p["cell_rect"], p.get("native_px")) for p in pictures)))
'
}

placeholders=$(geometry placeholders --placeholders)
pixels=$(geometry pixels --no-placeholders)
printf '  placeholders %s\n  pixel-sized  %s\n' "$placeholders" "$pixels"
if [ "$placeholders" != "$pixels" ]; then
    echo "  FAIL the two transports disagree about where the pictures are"
    exit 1
fi
count=$(printf '%s' "$placeholders" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
if [ "$count" -lt 2 ]; then
    echo "  FAIL only $count picture(s): this pane should hold a stage and three cards"
    exit 1
fi
echo "  identical: $count pictures, same cells and same pixels on both paths"
