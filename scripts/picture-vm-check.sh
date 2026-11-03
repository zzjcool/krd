#!/bin/bash
#
# The mirror's picture checked on a REAL terminal screen, in the macOS VM, with one command -- and
# without taking a screenshot of anybody's desktop.
#
#   scripts/picture-vm-check.sh [--budget KiB] [--move] [--binary PATH] [--keep]
#
#   scripts/picture-vm-check.sh                 # 128 KiB blocks, whole picture, no move
#   scripts/picture-vm-check.sh --budget 16     # many small blocks (the 20 Mbit/s shape)
#   scripts/picture-vm-check.sh --move          # ...then shrink the picture area and check the move
#
# Why this exists (issue #257). A full repaint used to leave as ONE `?2026` block carrying every
# tile: 216 images, 2.17 MiB, 0.9 s at 20 Mbit/s. The terminal that showed the bug answered `OK` to
# every transmit and every placement (`bad=0`) and still drew only a row-major prefix of the tiles,
# so the bottom of the picture stayed the background colour -- in whole tiles. Nothing in the byte
# stream says which of those happened, and no terminal answers "what do you hold" (Rex answers
# `a=q` with `EINVAL`, kitty-style store queries are not usable here). So the picture is counted on
# the screen instead: the guest's own display, never the host's.
#
# The two tricks that make it countable:
#   * the terminal's background is painted a colour the picture never is (`#00ff00`), so "this cell
#     was never reached" is a colour, not a judgement call (probe/picture_tiles.swift counts it);
#   * the picture area is shrunk *without typing anything*: `kill -USR1 <krd>` is the panel cycle
#     (`installReportHandler`), i.e. exactly the menu opening -- the relayout that used to
#     re-transmit 2.17 MiB of unchanged pixels. With `--move` the run checks that it is now a
#     cells-only pass and that the rows the picture vacated came back to the background.
#
# What it asserts: every tile of the picture is on the screen, the transmit went out in the number
# of blocks the budget implies (not one), and with --move the move says "no pixels sent" and leaves
# no ghost behind. Non-zero exit on any of those, so it can gate a release.
set -eu

VM=krd-vm
# BatchMode + ConnectTimeout: an unattended run has to fail in seconds, never wait on a prompt.
SSH="ssh -o ConnectTimeout=5 -o BatchMode=yes $VM"
GUEST_BIN=/tmp/krd-picture-check
GUEST_LOG=/tmp/krd-picture-check.log
GUEST_PNG=/tmp/krd-picture-check.png
PNG=/tmp/krd-picture-check.png
TILES=/tmp/picture-tiles
BUDGET=128
MOVE=no
KEEP=no
BINARY=

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --budget) BUDGET=$2; shift 2 ;;
        --move) MOVE=yes; shift ;;
        --binary) BINARY=$2; shift 2 ;;
        --keep) KEEP=yes; shift ;;
        -h|--help) usage ;;
        *) die "unknown argument '$1' (try --help)" ;;
    esac
done
case "$BUDGET" in ''|*[!0-9]*) die "--budget wants a number of KiB" ;; esac
repo=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$repo/Package.swift" ] || die "$repo does not look like the repo (no Package.swift)"

cleanup() {
    if [ "$KEEP" = no ]; then
        # Ghostty owns the pane; killing it takes krd with it. `pgrep -x`, never `pgrep -f`: the
        # Ghostty command line *contains* the krd path, and a `-f` pattern matches it too -- a
        # `kill -USR1` aimed at "krd" once went to Ghostty and took the whole run down.
        $SSH 'pkill -x krd-picture-check 2>/dev/null; pkill -x Ghostty 2>/dev/null; true' || true
    fi
}
trap cleanup EXIT

say "1/6 reaching $VM"
$SSH true 2>/dev/null || die "no ssh to $VM -- start it with: tart run kraal-agent --no-graphics && ssh $VM true"

say "2/6 the binary"
if [ -z "$BINARY" ]; then
    BINARY=$repo/.build/release/krd
    [ -x "$BINARY" ] || { echo "    building release"; ( cd "$repo" && swift build -c release >/dev/null ) }
fi
[ -x "$BINARY" ] || die "$BINARY is not executable"
scp -q "$BINARY" "$VM:$GUEST_BIN" || die "could not copy the binary to the guest"
printf '    binary: %s (%s bytes)\n' "$BINARY" "$(wc -c <"$BINARY" | tr -d ' ')"

say "3/6 swiftc the tile counter (host side)"
swiftc -O "$repo/probe/picture_tiles.swift" -o "$TILES" || die "probe/picture_tiles.swift did not compile"

# Full screen, because that is what makes the geometry exact: no window decoration, no padding, no
# cascade, so the picture's top-left is ((originCol-1) x cellW, (originRow-1) x cellH) measured from
# the screen's own top-left -- and the desktop behind it cannot be mistaken for the picture.
say "4/6 ghostty in the guest, running the mirror on a mock desktop"
$SSH "pkill -f Ghostty 2>/dev/null; pkill -x krd-picture-check 2>/dev/null; sleep 1; rm -f $GUEST_LOG"
# Pinned geometry, and frontmost: a window the window server cascaded (or that another app covers)
# makes the screenshot a picture of something else, which reads as "tiles missing" -- the first run
# of this script reported 17 missing tiles that were really a Safari window on top of the pane.
$SSH "open -na /Applications/Ghostty.app --args --window-width=${PANE_COLS:-141} --window-height=${PANE_ROWS:-73} \
      --font-size=9 --window-decoration=none --window-padding-x=0 --window-padding-y=0 \
      --window-position-x=0 --window-position-y=0 \
      --background=#00ff00 --foreground=#ffffff \
      -e $GUEST_BIN --mirror --mock --bar --debug --paint-budget $BUDGET --log $GUEST_LOG" \
    || die "ghostty did not start in the guest"
$SSH "osascript -e 'tell application \"Ghostty\" to activate'" >/dev/null 2>&1 || true
# The first paint is the thing under test, so wait for its own line rather than for a stopwatch.
for _ in $(seq 1 40); do
    $SSH "grep -q 'picture painted in' $GUEST_LOG" 2>/dev/null && break
    sleep 0.5
done
grid=$($SSH "grep -m1 'mirror grid' $GUEST_LOG" || true)
painted=$($SSH "grep -m1 'picture painted in' $GUEST_LOG" || true)
[ -n "$grid" ] || die "the mirror never laid out: $($SSH "tail -5 $GUEST_LOG" 2>/dev/null)"
[ -n "$painted" ] || die "the picture never finished painting (--paint-budget $BUDGET)"
printf '    %s\n    %s\n' "$grid" "$painted"

# Everything the assertions need, parsed from the one line that describes the geometry:
#   krd: mirror grid 141x37 cells at 5x12 px, pane 141x73, src ..., fit ..., origin 1,19, frame 705x444 px
# The first pair is the *picture's* cell box -- the grid the tiles partition -- not the pane's.
read -r pane_cols pane_rows <<EOF
$(printf '%s\n' "$grid" | sed -n 's/.*, pane \([0-9]*\)x\([0-9]*\),.*/\1 \2/p')
EOF
read -r box_cols box_rows cellw cellh origin_col origin_row ncols nrows <<EOF
$(printf '%s\n' "$grid" | sed -n 's/.*grid \([0-9]*\)x\([0-9]*\) cells at \([0-9]*\)x\([0-9]*\) px,.*origin \([0-9]*\),\([0-9]*\), frame \([0-9]*\)x\([0-9]*\) px.*/\1 \2 \3 \4 \5 \6 \7 \8/p')
EOF
[ -n "${cellw:-}" ] && [ -n "${origin_row:-}" ] || die "could not parse the geometry out of: $grid"
# Tiles are 8x4 cells (the defaults); the last row/column of tiles is clipped to the box.
tiles_x=$(( (box_cols + 7) / 8 ))
tiles_y=$(( (box_rows + 3) / 4 ))
ox=$(( (origin_col - 1) * cellw ))
oy=$(( (origin_row - 1) * cellh ))
printf '    geometry: %sx%s cells = %sx%s tiles at %s,%s px (%s total)\n' \
    "$box_cols" "$box_rows" "$tiles_x" "$tiles_y" "$ox" "$oy" "$(( tiles_x * tiles_y ))"

# The picture's top edge, measured on the screen rather than assumed from the window position: a
# window placed by the window server is clamped below the menu bar and cascaded sideways, so
# `(originRow-1) x cellH` alone is off by however much the window manager decided.
find_oy() {   # $1 = screenshot path on the host
    "$TILES" "$1" 0 0 "$tiles_x" "$tiles_y" $(( cellw * 8 )) $(( cellh * 4 )) 0 255 0 --find-y \
        | sed -n 's/^origin-y \([0-9]*\).*/\1/p' | head -1
}
# The pane's own box, as the counter found it: `origin-y N  (pane x0,y0-x1,y1, ...)`.
pane_box() {   # $1 = screenshot path on the host
    "$TILES" "$1" 0 0 "$tiles_x" "$tiles_y" $(( cellw * 8 )) $(( cellh * 4 )) 0 255 0 --find-y \
        | sed -n 's/.*(pane \([0-9]*\),\([0-9]*\)-\([0-9]*\),\([0-9]*\).*/\1 \2 \3 \4/p' | head -1
}
# A covered or off-screen pane is the one failure mode that looks exactly like missing tiles, so it
# is checked first and by name.
check_pane_visible() {   # $1 = screenshot path on the host
    read -r px0 py0 px1 py1 <<EOF
$(pane_box "$1")
EOF
    [ -n "${px1:-}" ] || die "no background-coloured pane in the screenshot: is ghostty running? ($1)"
    want_w=$(( pane_cols * cellw )); want_h=$(( pane_rows * cellh ))
    got_w=$(( px1 - px0 + 1 )); got_h=$(( py1 - py0 + 1 ))
    printf '    pane on screen: %sx%s px at %s,%s (want %sx%s)\n' "$got_w" "$got_h" "$px0" "$py0" "$want_w" "$want_h"
    slack=8
    if [ "$got_w" -lt $(( want_w - slack )) ] || [ "$got_h" -lt $(( want_h - slack )) ]; then
        die "the terminal window is covered or off-screen ($got_w x $got_h of $want_w x $want_h px) -- close other windows in the guest, or use --keep and look"
    fi
}
count_tiles() {   # $1 = screenshot path on the host, $2 = label
    "$TILES" "$1" "$ox" "$oy" "$tiles_x" "$tiles_y" \
        $(( cellw * 8 )) $(( cellh * 4 )) 0 255 0 2>&1 | tail -1 \
        | sed "s/^/$2 tiles: /"
}

say "5/6 count the tiles on the guest's screen"
$SSH "screencapture -x $GUEST_PNG" || die "screencapture failed in the guest (no display?)"
scp -q "$VM:$GUEST_PNG" "$PNG" || die "could not fetch the screenshot"
check_pane_visible "$PNG"
oy=$(find_oy "$PNG")
[ -n "${oy:-}" ] || die "the picture's top edge is not on the screen (see $PNG)"
printf '    picture top: y=%s (the log said %s px from the pane top)\n' "$oy" "$(( (origin_row - 1) * cellh ))"
first=$(count_tiles "$PNG" "first paint")
printf '    %s\n' "$first"
blocks=$(printf '%s\n' "$painted" | sed -n 's/.*painted in \([0-9]*\) blocks.*/\1/p')
case "$first" in *"missing 0 "*) ;; *) die "the picture is not whole: $first (see $PNG)" ;; esac
# A budget that cannot hold the whole picture in one block has to produce more than one: one block
# here means the budget was not applied, which is the bug this script exists to catch.
if [ "$BUDGET" -gt 0 ] && [ -n "${blocks:-}" ]; then
    estimated=$(( tiles_x * tiles_y * 12 ))     # a sent tile counts as 12 KiB until it has been sent
    if [ "$estimated" -gt "$BUDGET" ] && [ "$blocks" -lt 2 ]; then
        die "the whole picture went out in one block (--paint-budget $BUDGET): the budget is not applied"
    fi
fi

if [ "$MOVE" = yes ]; then
    say "6/6 shrink the picture area (a panel) and check the move"
    before=$($SSH "grep -c 'picture moved to row' $GUEST_LOG" || true)
    # `pgrep -x`, not `-f`: see the note in cleanup(). The binary is named after this script so an
    # exact match cannot pick up a stray krd from an earlier run.
    pid=$($SSH "pgrep -x krd-picture-check" || true)
    [ -n "$pid" ] || die "no krd process to signal in the guest"
    $SSH "kill -USR1 $pid" || die "could not signal krd"
    for _ in $(seq 1 20); do
        moved=$($SSH "grep -c 'picture moved to row' $GUEST_LOG" || true)
        [ "${moved:-0}" -gt "${before:-0}" ] && break
        sleep 0.5
    done
    $SSH "grep 'picture moved to row' $GUEST_LOG" | tail -1 | sed 's/^/    /'
    $SSH "grep -m1 'mirror grid' $GUEST_LOG" >/dev/null
    # The move re-lays the picture out; read the *new* origin out of the log's last layout line.
    grid=$($SSH "grep 'mirror grid' $GUEST_LOG" | tail -1)
    read -r origin_col origin_row <<EOF
$(printf '%s\n' "$grid" | sed -n 's/.*origin \([0-9]*\),\([0-9]*\),.*/\1 \2/p')
EOF
    logged_oy=$(( (origin_row - 1) * cellh ))
    old_oy=$oy
    $SSH "screencapture -x $GUEST_PNG" || die "screencapture failed in the guest"
    scp -q "$VM:$GUEST_PNG" "$PNG" || die "could not fetch the screenshot"
    check_pane_visible "$PNG"
    oy=$(find_oy "$PNG")
    [ -n "${oy:-}" ] || die "the moved picture is not on the screen (see $PNG)"
    # Measured, not derived: the window sits wherever the window server put it, so the log's origin
    # is a cell offset inside the pane, not a screen coordinate. Comparing the two is what catches
    # "the picture did not move at all" (they would be equal when the pane is at y=0).
    printf '    picture top after the move: y=%s (was %s; the log says %s px from the pane top)\n' \
        "$oy" "$old_oy" "$logged_oy"
    after=$(count_tiles "$PNG" "after the move")
    printf '    %s\n' "$after"
    case "$after" in *"missing 0 "*) ;; *) die "the moved picture is not whole: $after (see $PNG)" ;; esac
    # The rows the old box covered and the new one does not -- from the new picture's bottom edge to
    # the old one's -- must be the background again. A picture that moved up leaves `U+10EEEE` cells
    # behind and those keep drawing their image, so this is the one place a "moved" picture ghosts.
    height=$(( old_oy - oy ))
    if [ "$height" -gt 0 ]; then
        y0=$(( oy + nrows ))
        ghost=$("$TILES" "$PNG" 0 "$y0" 1 1 "$ncols" "$height" 0 255 0 2>&1 | tail -1)
        printf '    vacated band (%s px from y=%s): %s\n' "$height" "$y0" "$ghost"
        case "$ghost" in *"missing 1 "*) ;; *) die "the vacated band still carries the old picture: $ghost" ;; esac
    fi
    case "$($SSH "grep 'picture moved to row' $GUEST_LOG" | tail -1)" in
        *"no pixels sent"*) ;;
        *) die "the move re-sent pixels: a panel open must not re-transmit an unchanged picture" ;;
    esac
fi

say "ok: the picture is whole -- $painted"
printf '    screenshot : %s\n    guest log  : %s:%s\n' "$PNG" "$VM" "$GUEST_LOG"
[ "$KEEP" = no ] || printf '    --keep: ghostty and krd left running in the guest\n'
