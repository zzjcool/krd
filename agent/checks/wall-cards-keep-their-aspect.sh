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
display=$("$KAGENT" --json see --max-width 200 --quiet)
render=$("$KAGENT" --json render --target vm --pane "$PANE" --cell "$CELL" --seconds "${SECONDS_TO_RUN:-14}" --quiet --allow-empty -- \
          '~/bin/krd' --wall)

printf '%s\n%s\n%s\n' "$windows" "$display" "$render" | python3 -c '
import json, sys

# Three JSON documents were concatenated; decode them in one pass with an absolute offset. Slicing
# on a decoded length instead is off by however much whitespace was skipped, and it silently worked
# for two documents and broke for three.
raw = sys.stdin.read()
decoder = json.JSONDecoder()
offset, documents = 0, []
while True:
    while offset < len(raw) and raw[offset].isspace():
        offset += 1
    if offset >= len(raw):
        break
    document, offset = decoder.raw_decode(raw, offset)
    documents.append(document)
if len(documents) != 3:
    raise SystemExit("expected windows, a frame and a render report; got %d document(s)"
                     % len(documents))
windows, screen, render = documents

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

# The stage shows the display, so the display is one of the shapes to match against -- otherwise a
# 1.6 display would be quietly matched to whatever window happened to be closest.
shapes = []
bounds = screen.get("bounds") or {}
if bounds.get("height"):
    shapes.append((bounds["width"] / bounds["height"],
                   "display %dx%d" % (bounds["width"], bounds["height"])))
for w in windows["windows"]:
    _, _, width, height = w["rect"]
    if height:
        shapes.append((width / height, "%s %dx%d" % (w["app"], width, height)))

# The stage is the display; the cards are the windows. Both are fitted to the source aspect, so a
# card matches *some* window and the stage matches the display it was captured from.
#
# The aspect to compare is the picture, not the box around it: a card is as tall as its picture
# needs, capped by the band, so a capped card is slightly wider than its source and lets the
# letterboxing show. Comparing the box would call that a bug; the content size (`native_px`) is what
# "the window is not stretched" actually means.
by_image = {p["image"]: p for p in render["pictures"]}
matched = 0
for r in rects:
    picture = by_image.get(r["image"]) or {}
    native = picture.get("native_px")
    aspect = (native[0] / native[1]) if native and native[1] else \
        (r["cols"] * cell_w) / (r["rows"] * cell_h)
    best = min(shapes, key=lambda s: abs(s[0] - aspect), default=None)
    if best and abs(best[0] - aspect) / best[0] < 0.02:
        matched += 1
        print("  %s %dx%d cells = %.3f -> %s (%.3f)" % (
            "stage" if best[1].startswith("display") else "card",
            r["cols"], r["rows"], aspect, best[1], best[0]))
    else:
        problems.append("picture %s is %dx%d cells with content aspect %.3f, no window matches it"
                        % (r["image"], r["cols"], r["rows"], aspect))

print("pictures=%d matched=%d misfits=%d" % (len(rects), matched, len(render["misfits"])))
if problems:
    for p in problems:
        print("FAIL", p)
    sys.exit(1)
' "$PANE" "$CELL"
