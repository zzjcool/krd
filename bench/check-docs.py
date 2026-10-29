#!/usr/bin/env python3
"""Fail when the configuration the docs quote is not the configuration the bench ran.

The bug this exists for: `--bench --pane 137x44` was documented next to "2329x1452 px", but
the aspect-fit in TileGrid.make cut the pane to 48 columns, so every number in the table
described a frame 2.8x smaller than the prose claimed. A doc line that the harness can check
is the only fix that stays fixed.

    python3 bench/check-docs.py [bench/results/last-encode.json]

Looks for `<!-- bench-config: ... -->` in docs/ENCODING.md and compares it with the run.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "bench", "results", "last-encode.json")
    if not os.path.exists(path):
        print("check-docs: %s missing, run `make bench` first" % path, file=sys.stderr)
        return 2
    with open(path) as handle:
        encode = json.load(handle)
    config = encode["config"]
    expected = "%s px, %d tiles of %s, %s" % (
        config["px"], config["tiles"], config["tile"], config["format"])

    doc = os.path.join(ROOT, "docs", "ENCODING.md")
    with open(doc) as handle:
        text = handle.read()
    marker = "<!-- bench-config:"
    found = [line.strip() for line in text.splitlines() if marker in line]
    if not found:
        print("check-docs: docs/ENCODING.md has no %s ... --> line" % marker, file=sys.stderr)
        print("check-docs: add:  %s %s -->" % (marker, expected), file=sys.stderr)
        return 1
    stated = found[0].split(marker, 1)[1].split("-->")[0].strip()
    if stated != expected:
        print("check-docs: ENCODING.md says   %s" % stated, file=sys.stderr)
        print("check-docs: the last run was  %s" % expected, file=sys.stderr)
        return 1
    print("check-docs: OK — %s" % expected)
    return 0


if __name__ == "__main__":
    sys.exit(main())
