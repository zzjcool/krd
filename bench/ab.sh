#!/bin/sh
# Thin wrapper: the A/B lives in bench/ab.py (interleaved runs, medians, markdown report).
#   make bench-ab                -> working tree vs origin/main
#   make bench-ab REF=v0.1.1     -> working tree vs a tag
#   make bench-ab REF=HEAD       -> noise floor (same code twice)
# Writes bench/ab-report.md, ready to paste into a PR, and fails on > --tolerance regressions.
here=$(cd "$(dirname "$0")/.." && pwd)
exec python3 "$here/bench/ab.py" "$@"
