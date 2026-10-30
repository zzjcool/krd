#!/bin/sh
# The escape decoder is the only oracle this repo has for "what the terminal would draw", so it gets
# its own check: the committed selftest dump must decode to the four quadrant colours, at the pinned
# geometry, with the recorded frame count. A decoder that drifts silently turns every later visual
# test into a coin flip.
#
# Needs nothing: no target, no build, no permissions.
set -eu
TREE=${TREE:-$(cd "$(dirname "$0")/../.." && pwd)}
exec python3 "$TREE/agent/tests/test_vt.py"
