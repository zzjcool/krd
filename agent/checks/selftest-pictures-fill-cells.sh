#!/bin/sh
# "Does the picture fill its box" — the question behind this repo's worst rendering bugs, asked
# mechanically.
#
# krd's selftest is a synthetic picture through the real pipeline: no screen, no permission, and a
# frame for index n that is a pure function of n. So a regression in tile geometry, chunking or the
# placeholder grid shows up here as either a misfit (pixels != cells) or no pictures at all.
#
# Fails when:
#   * nothing was decoded (the pipeline broke, not the picture)
#   * any picture's native pixels differ from its cell box (seams on a 1:1 terminal)
set -eu
KRD=${KRD:?prove sets this; run it via `kagent prove` or export KRD}
KAGENT=${KAGENT:-$(cd "$(dirname "$0")/../.." && pwd)/agent/bin/kagent}
out=$("$KAGENT" --target host --json render --pane 80x24 --cell 17x33 --seconds 6 \
        --strict-fit -- "$KRD" --selftest 2>/dev/null) || {
    echo "render failed or a picture did not match its cell box"
    echo "$out" | head -40
    exit 1
}
echo "$out" | python3 -c '
import json, sys
report = json.load(sys.stdin)
pictures = [p for p in report["pictures"] if not p.get("probe")]
misfits = report["misfits"]
print("frames=%d pictures=%d misfits=%d" % (report["frames"], len(pictures), len(misfits)))
for p in pictures[:4]:
    print("  cells=%s native=%s fit=%s" % (p["cell_rect"], p.get("native_px"), p.get("fit")))
if not pictures:
    print("no placeholder pictures: the placeholder path did not run")
    sys.exit(1)
if misfits:
    print("misfits: %s" % misfits[:3])
    sys.exit(1)
'
