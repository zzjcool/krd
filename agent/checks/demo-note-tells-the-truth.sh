#!/bin/sh
# `--demo` prints one line of arithmetic — the pane, the cell, and the stage's cells and pixels — so a
# person can answer "why does the picture not fill its box" without a screenshot. A debug line that
# is itself wrong is worse than none: it is the number every other measurement gets checked against.
#
# This reads that line back out of the escape stream (the text layer, not a screenshot) and asserts
# the pixels it claims are the cells it claims multiplied by the cell size it claims.
set -eu
KAGENT=${KAGENT:-$(cd "$(dirname "$0")/../.." && pwd)/agent/bin/kagent}
BINARY=${BINARY:-$(cd "$(dirname "$0")/../.." && pwd)/.build/release/krd}
CELLW=${CELLW:-17}
CELLH=${CELLH:-33}
PANES=${PANES:-"100x30 120x40 80x24 146x73"}

failed=0
for pane in $PANES; do
    cols=${pane%x*}
    rows=${pane#*x}
    run="demo-note-$pane"
    "$KAGENT" --target host render --pane "$pane" --cell "${CELLW}x${CELLH}" --seconds 5 \
        --keep-stream --quiet --run "$run" -- "$BINARY" --demo >/dev/null
    "$KAGENT" vt text "artifacts/$run/vt.vt" --grep 'demo ' | python3 -c '
import re, sys
line = sys.stdin.read().strip()
cols, rows, cw, ch = (int(x) for x in sys.argv[1:5])
found = re.search(r"pic (\d+)x(\d+)c (\d+)x(\d+)px", line)
if not found:
    # The note is elided when it does not fit the pane ("pic 31x10c 5…"); that is honest, not a lie.
    print("  %dx%d  elided: %s" % (cols, rows, line.split("|", 1)[-1][-40:]))
    sys.exit(0)
cells_w, cells_h, px_w, px_h = (int(x) for x in found.groups())
want = (cells_w * cw, cells_h * ch)
if (px_w, px_h) != want:
    print("  %dx%d  FAIL claims %dx%d px for %dx%d cells, which is %dx%d"
          % (cols, rows, px_w, px_h, cells_w, cells_h, want[0], want[1]))
    sys.exit(1)
print("  %dx%d  pic %dx%dc = %dx%d px  ok" % (cols, rows, cells_w, cells_h, px_w, px_h))
' "$cols" "$rows" "$CELLW" "$CELLH" || failed=1
done
exit $failed
