#!/bin/sh
# krd-cast — mirror a macOS window into a Rex floating panel shaped like that window.
#
#   krd-cast <id | app | title substring> [width fraction] [max height fraction]
#   krd-cast Chrome                     # the first targetable window of Google Chrome
#   krd-cast 103 0.7                    # window id 103, 70% of the Rex window's width
#
#   krd-cast --host krd-vm "App Store"  # the window list *and* the mirror live on krd-vm
#   KRD_HOST=krd-vm krd-cast Calendar   # the same, through the environment
#
# Without --host everything runs here. With it, the panel runs `ssh -t HOST ~/bin/krd
# --window <id>` instead of a local krd — the same shape, the same pty, the pane is still
# this Mac's — so a krd on a VM (tart, a headless Mac, a remote host) opens exactly the
# way a local one does. The window ids are the *remote* machine's, so the listing comes
# from there too; nothing about the local window list is used.
#
# The three answers this needs, and can only get from three places:
#
#   * the window's size is points (`krd --list --json` → `.frame`), and points are not
#     pixels: the panel is measured in device pixels, so the fraction maths below works
#     in px and never mixes the two;
#   * the cell is the terminal's own answer (`com.superlogical.terminal.size`), which is
#     the only place a device pixel per cell can be read;
#   * the panel is a Rex floating layer, whose `bounds` are fractions of the **window** —
#     so the pane's own size has to be scaled back up by the pane's share of the window
#     (a pane in the bottom half of a split is half the window's height), and the aspect
#     has to be solved for `h` given `w`.
#
# The aspect is the point: krd fits the picture into the cells it is given, so a panel
# with a different aspect shows black beside the frame. `h = w · paneAspect · (share_h /
# share_w) / windowAspect` makes the panel's cells the same shape as the window.
#
# Environment:
#   KRD          the local binary to cast with (default ~/bin/krd); unused with --host
#   KRD_LIST     a build with `--list --json`, if KRD predates it (issue #124)
#   KRD_HOST     same as --host
#   KRD_REMOTE   the binary on the other machine (default ~/bin/krd)
#   KRD_REMOTE_LIST  a remote build with `--list --json`, if KRD_REMOTE predates it
#   REX          the rex CLI (default: rex)
#   DRY=1        print the numbers and stop
set -eu

die() { echo "krd-cast: $*" >&2; exit 2; }

host=
case ${1:-} in
    --host) [ $# -ge 2 ] || die "--host needs a host name"; host=$2; shift 2 ;;
    --host=*) host=${1#--host=}; shift ;;
esac
host=${host:-${KRD_HOST:-}}
query=${1:-}
[ -n "$query" ] || die "usage: krd-cast [--host HOST] <id|app|title substring> [width] [max height]"
want_w=${2:-0.62}
max_h=${3:-0.90}
max_w=0.94

KRD=${KRD:-$HOME/bin/krd}
KRD_LIST=${KRD_LIST:-$KRD}
# Single-quoted: bash/zsh/sh all expand a bare `~` even inside ${var:-~}, which
# turned the remote path into this machine's $HOME and sent ssh looking for a file
# that exists only here.
KRD_REMOTE=${KRD_REMOTE:-'~/bin/krd'}
# The listing may need a different build than the cast, exactly like KRD_LIST;
# a machine whose `~/bin/krd` predates `--list --json` sets this to the newer one.
KRD_REMOTE_LIST=${KRD_REMOTE_LIST:-$KRD_REMOTE}
REX=${REX:-rex}
session=${REX_SESSION:?REX_SESSION is not set — run this inside a Rex pane}
block=${REX_BLOCK:-}
[ -n "$block" ] || die "REX_BLOCK is not set — run this inside a Rex pane"

command -v jq >/dev/null || die "jq is required"
command -v "$REX" >/dev/null || die "$REX is not on PATH"

# The block execs its command from the login shell's directory, not this one, so a local
# path has to be absolute; a remote one is expanded by the remote shell (`~/bin/krd`).
abs() { case $1 in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$(pwd)" "$1" ;; esac; }
if [ -n "$host" ]; then
    command -v ssh >/dev/null || die "ssh is required with --host"
    ssh_probe="ssh -o BatchMode=yes -o ConnectTimeout=10 $host"
else
    KRD=$(abs "$KRD")
    KRD_LIST=$(abs "$KRD_LIST")
    [ -x "$KRD" ] || die "KRD=$KRD is not executable"
fi

# 1. Which window, and how big is it.
#
#    `--list --json` is the machine-readable half of `--list` (issue #124) and the only
#    listing that says `targetable` and a frame without parsing prose. A build from before
#    #124 **ignores the flag and prints the text listing anyway**, so pick the first binary
#    that really answers JSON — the one asked for, the casting one, or a dev build beside
#    this script — and parse the text columns only if none does. Over ssh there is just the
#    remote one, and the list is the *remote* machine's windows.
list_json() {
    if [ -n "$host" ]; then
        $ssh_probe "$KRD_REMOTE_LIST --list --json"
    else
        "$KRD_LIST" --list --json
    fi
}
list_text() {
    if [ -n "$host" ]; then
        $ssh_probe "$KRD_REMOTE_LIST --list"
    else
        "$KRD_LIST" --list
    fi
}

json=
if json=$(list_json 2>/dev/null) && printf '%s' "$json" | jq -e '.windows' >/dev/null 2>&1; then
    :
else
    json=
    # An unreachable host and an old build both end up here; say which one it was.
    [ -z "$host" ] || $ssh_probe 'exit 0' >/dev/null 2>&1 ||
        die "cannot reach $host over ssh (ssh -o BatchMode=yes $host 'exit 0' failed)"
fi

win=; win_w=; win_h=; app=
if [ -n "$json" ]; then
    # One window, four lines: id, width, height, app. A newline per value keeps the app
    # name in one piece (a title may hold spaces, tabs, even a glob).
    vals=$(printf '%s' "$json" | jq -r --arg q "$query" '
        [ .windows[] | select(.targetable)
          | select((.id | tostring) == $q
                   or (.title | ascii_downcase | contains($q | ascii_downcase))
                   or (.app   | ascii_downcase | contains($q | ascii_downcase))) ]
        | if length == 0 then empty else .[0] | .id, .frame[2], .frame[3], .app end')
    win=$(printf '%s\n' "$vals" | sed -n 1p)
    win_w=$(printf '%s\n' "$vals" | sed -n 2p)
    win_h=$(printf '%s\n' "$vals" | sed -n 3p)
    app=$(printf '%s\n' "$vals" | sed -n 4p)
else
    # The text columns: `    window 103  @-1509,950 1512x949  app=Google Chrome  title=…`
    line=$(list_text | grep -i -e "$query" | grep -v '(backdrop' | head -1) || true
    if [ -n "${line:-}" ]; then
        win=$(printf '%s' "$line" | awk '{print $2}')
        frame=$(printf '%s' "$line" | awk '{print $4}')
        win_w=${frame%%x*}; win_h=${frame#*x}
        app=$(printf '%s' "$line" | sed -e 's/.*  app=//' -e 's/  title=.*//')
    fi
fi
[ -n "$win" ] || die "no targetable window matched \"$query\" (try: krd${host:+ @$host} --list)"
case $win_w$win_h in
    ''|*[!0-9]*) die "could not read a frame for window $win (\"${win_w}x${win_h}\")" ;;
esac

# 2. The pane's own cell, in device pixels — the only place a device pixel per cell can be
#    read — plus the pane's share of its window. `bounds` are fractions of the **window**,
#    so a pane that is not the whole window (the bottom half of a split, or a block inside
#    another floating layer) must be scaled back up: using the pane's own aspect as the
#    window's made the panel exactly 2x too tall in the bottom half of a 0.5 split, which
#    krd answered by centring the picture and leaving 28 rows of black above and below.
size=$("$REX" api call -s "$session" com.superlogical.terminal.size "{\"block_id\":\"$block\"}") ||
    die "the terminal did not answer com.superlogical.terminal.size"
cols=$(printf '%s' "$size" | jq -r .columns)
rows=$(printf '%s' "$size" | jq -r .rows)
cell_w=$(printf '%s' "$size" | jq -r .cell_width_px)
cell_h=$(printf '%s' "$size" | jq -r .cell_height_px)

view=$("$REX" session inspect "$session" --json) || die "could not read the session layout"
share=$(printf '%s' "$view" | jq -r --arg b "$block" '
    [ .windows[] as $w
      | $w.layers[] as $l
      | ($l.layout | .. | objects | select(.block_id? == $b)) as $n
      | "\($w.window_id) \($n.rect[2] * $l.bounds[2]) \($n.rect[3] * $l.bounds[3])" ][0] // empty')
[ -n "$share" ] || die "block $block is not in the session layout"
set -- $share
target_window=$1; share_w=$2; share_h=$3
pane_w=$((cols * cell_w))
pane_h=$((rows * cell_h))

# 3. Solve `h` for `w` so the panel's cells have the window's aspect. Point and pixel
#    aspects are the same number (one scale factor cancels), so points are enough:
#
#        h = want_w · paneAspect · (share_h / share_w) / windowAspect
#
#    ...then shrink the pair (never stretch one side) until it fits the unit square.
#    A 45:1 menu bar and a 1:3 tall window both end up with the right shape, so the fit
#    inside the panel stays 1:1 and krd has no black to draw beside the frame.
read -r bounds_w bounds_h panel_cols panel_rows <<EOF
$(LC_ALL=C awk -v want="$want_w" -v pw="$pane_w" -v ph="$pane_h" -v W="$win_w" -v H="$win_h" \
      -v wmax="$max_w" -v hmax="$max_h" -v cw="$cell_w" -v ch="$cell_h" \
      -v sw="$share_w" -v sh="$share_h" -v c="$cols" -v r="$rows" 'BEGIN {
    a = W / H; p = (pw / ph) * (sh / sw);
    w = want; h = w * p / a;
    if (h > hmax) { h = hmax; w = h * a / p }
    if (w > wmax) { w = wmax; h = w * p / a }
    pc = int(w * c / sw + 0.5); pr = int(h * r / sh + 0.5);
    printf "%.3f %.3f %d %d\n", w, h, pc, pr
}')
EOF
[ "$panel_rows" -ge 3 ] || die "a panel with this window's aspect (${win_w}x${win_h} pt) is ${panel_cols}x${panel_rows} cells — too small to mirror; cast it with krd --window $win instead"
bounds_x=$(LC_ALL=C awk -v w="$bounds_w" 'BEGIN { printf "%.3f", (1 - w) / 2 }')
bounds_y=$(LC_ALL=C awk -v h="$bounds_h" 'BEGIN { printf "%.3f", (1 - h) / 2 }')

# 4. One floating layer, one block, the mirror directly as the block's program:
#    `shell: none` so the pane runs krd (or ssh) itself and not a shell around it.
#    `ssh -t` because krd needs a pty, and the block *is* the pty.
if [ -n "$host" ]; then
    command=$(jq -nc --arg h "$host" --arg bin "$KRD_REMOTE" --arg id "$win" \
                    '["ssh", "-t", $h, $bin, "--window", $id]')
else
    command=$(jq -nc --arg bin "$KRD" --arg id "$win" '[$bin, "--window", $id]')
fi

echo "krd-cast: window $win ($app) ${win_w}x${win_h} pt${host:+ on $host}" \
     "(pane ${cols}x${rows} of a ${share_w}x${share_h} share)" \
     "-> panel ${bounds_w}x${bounds_h}, ${panel_cols}x${panel_rows} cells" \
     "running $(printf '%s' "$command" | jq -r 'join(" ")')"
[ -z "${DRY:-}" ] || exit 0
payload=$(jq -nc --arg w "$target_window" --arg label "${app:-window-$win}" \
                 --argjson bounds "[$bounds_x, $bounds_y, $bounds_w, $bounds_h]" \
                 --argjson command "$command" \
                 '{window_id: $w, bounds: $bounds, focus: true,
                   layout: {block: {flavor: "com.superlogical.terminal.shell",
                                    label: $label,
                                    options: {command: $command, shell: "none"}}}}')

layer=$(printf '%s' "$payload" | "$REX" api call -s "$session" session.new_layer -) ||
    die "session.new_layer failed"
layer_id=$(printf '%s' "$layer" | jq -r .layer_id)
layer_block=$(printf '%s' "$layer" | jq -r '.block_ids[0]')

# 5. Settle the height. Rex turns `bounds` into whole cells by truncation, on a content
#    area that is not the row count a tiled pane reports (a window keeps rows of chrome of
#    its own), so the fraction that yields N rows cannot be computed from outside — it is
#    measured, and bisected because the map is a staircase: 0.194 gave 26 rows, 0.209 gave
#    29, 0.202 gave 27. Without this the panel has the right *shape* and the wrong size,
#    and krd centres the picture in it, leaving the spare rows black above and below.
measure() {
    "$REX" api call -s "$session" com.superlogical.terminal.size \
        "{\"block_id\":\"$layer_block\"}" | jq -r '.columns, .rows' | paste -sd' ' -
}
h_low=0; h_high=0; tries=0; got_cols=0; got_rows=0
while [ "$tries" -lt 6 ]; do
    sleep 0.4
    read -r got_cols got_rows <<EOF
$(measure)
EOF
    [ "${got_rows:-0}" -eq "$panel_rows" ] && break
    [ "${got_rows:-0}" -ge 3 ] || break
    tries=$((tries + 1))
    if [ "$(LC_ALL=C awk -v g="$got_rows" -v w="$panel_rows" 'BEGIN{print (g < w) ? 1 : 0}')" = 1 ]; then
        h_low=$bounds_h
    else
        h_high=$bounds_h
    fi
    bounds_h=$(LC_ALL=C awk -v lo="$h_low" -v hi="$h_high" -v h="$bounds_h" \
                    -v w="$panel_rows" -v g="$got_rows" -v hmax="$max_h" 'BEGIN {
        if (lo > 0 && hi > 0) v = (lo + hi) / 2          # both sides known: bisect
        else v = h * w / g                               # first step: proportional
        if (v > hmax) v = hmax
        if (v < 0.05) v = 0.05
        printf "%.4f", v }')
    bounds_y=$(LC_ALL=C awk -v h="$bounds_h" 'BEGIN { printf "%.4f", (1 - h) / 2 }')
    fix=$(jq -nc --arg l "$layer_id" --argjson b "[$bounds_x, $bounds_y, $bounds_w, $bounds_h]" \
                 '{layer_id: $l, bounds: $b}')
    printf '%s' "$fix" | "$REX" api call -s "$session" session.resize_layer - >/dev/null ||
        { echo "krd-cast: could not resize the layer, leaving ${got_cols}x${got_rows}" >&2; break; }
done
echo "krd-cast: panel ${got_cols}x${got_rows} cells, picture wants ${panel_cols}x${panel_rows}; layer $layer_id"
