#!/bin/sh
# Regenerate Sources/krd/WidthTable.swift from libghostty's Unicode tables.
#
#   scripts/gen-widths.sh [path to a libghostty checkout]
#
# Default path: /tmp/krd-spike/ghostty, where the v1.4.0 spike built it:
#
#   git clone --depth 1 --branch v1.4.0 https://github.com/ghostty-org/ghostty
#   cd ghostty && zig build -Demit-lib-vt -Doptimize=ReleaseFast
#
# The table is committed, so a normal build needs neither Zig nor the checkout — this script is only
# run when the terminal's own tables move (a new Unicode version, a new libghostty tag). It fails
# loudly rather than writing a shorter table, because a silently truncated width table renders text
# at the wrong column and nothing else in the build would notice.
set -eu

GHOSTTY_VT_DIR="${1:-${GHOSTTY_VT_DIR:-/tmp/krd-spike/ghostty}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Sources/krd/WidthTable.swift"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LIB="$GHOSTTY_VT_DIR/zig-out/lib/libghostty-vt.a"
INC="$GHOSTTY_VT_DIR/include"
if [ ! -f "$LIB" ] || [ ! -f "$INC/ghostty/vt/unicode.h" ]; then
    echo "gen-widths: no libghostty-vt build at $GHOSTTY_VT_DIR" >&2
    echo "gen-widths: expected $LIB and $INC/ghostty/vt/unicode.h" >&2
    echo "gen-widths: build it with: zig build -Demit-lib-vt -Doptimize=ReleaseFast" >&2
    exit 1
fi

cc -O2 -I"$INC" "$ROOT/scripts/gen-widths.c" "$LIB" -o "$TMP/gen-widths"

# The tag the table was made from, so the header can name it and a reviewer can check it.
TAG="$(git -C "$GHOSTTY_VT_DIR" describe --tags --always 2>/dev/null || echo unknown)"
"$TMP/gen-widths" > "$TMP/WidthTable.swift"

# Refuse to install a table that lost a set: an empty `wide` compiles fine and draws every CJK
# glyph in one cell.
for set in wide zero widens vsBase; do
    if ! grep -q "static let $set: \[UInt32\] = \[$" "$TMP/WidthTable.swift"; then
        echo "gen-widths: $set is missing from the generated table" >&2
        exit 1
    fi
done

mv "$TMP/WidthTable.swift" "$OUT"
printf 'gen-widths: wrote %s (%s bytes) from libghostty-vt %s\n' \
    "${OUT#$ROOT/}" "$(wc -c < "$OUT" | tr -d ' ')" "$TAG"
