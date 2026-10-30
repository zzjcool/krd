#!/bin/bash
#
# The landing screen (`--wall`) checked against REAL windows, in the macOS VM, with one command.
#
#   scripts/wall-vm-check.sh [COLSxROWS] [extra krd flags...]         default 137x44
#
#   scripts/wall-vm-check.sh
#   scripts/wall-vm-check.sh 100x30
#   scripts/wall-vm-check.sh 137x44 --symbols ascii
#
# Why the VM: `--wall` is text about real windows, and the only honest source of those without
# touching this desktop is the guest. Why a pty: the wall takes its geometry from TIOCGWINSZ, and
# a pipe has no winsize -- on a pipe it would lay out for 0x0 columns and you would be checking
# nothing. So the run always goes through /tmp/pty/ptywall with an exact size.
set -eu

VM=krd-vm
# BatchMode + ConnectTimeout: an unattended run has to fail in seconds, never wait on a prompt.
SSH="ssh -o ConnectTimeout=5 -o BatchMode=yes $VM"
HOST_BRIDGE=http://192.168.64.1:8899   # host /tmp -- the way into the guest
GUEST_BRIDGE=http://192.168.64.7:9911  # guest /tmp -- the way back out
GUEST_OUT=/tmp/wall-check.out          # raw bytes, guest side
RAW=/tmp/wall-check.out                # ... same name on the host, so paths are never a puzzle
PNG=/tmp/wall-check.png

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

size=137x44
if [ $# -gt 0 ]; then
    case "$1" in
        [0-9]*x[0-9]*) size=$1; shift ;;
    esac
fi
extra="$*"
cols=${size%x*}; rows=${size#*x}
case "$cols$rows" in *[!0-9]*) die "bad size '$size', want COLSxROWS (e.g. 137x44)" ;; esac
# Both glyph tables spell the footer in words (`click a card`); only the bullet and the
# separator between panels change with --symbols, so one plain-word check covers both modes.
case " $extra " in *" ascii"*) symbols=ascii ;; *) symbols=emoji ;; esac
repo=$(cd "$(dirname "$0")/.." && pwd)
# The repo is derived from $0, so a copy of this script living outside the tree would `tar -C /`
# and quietly upload the whole filesystem. Refuse instead.
[ -f "$repo/Package.swift" ] || die "$repo does not look like the repo (no Package.swift)"

say "1/7 reaching $VM"
$SSH true 2>/dev/null || die "no ssh to $VM -- start it with: tart run kraal-agent --no-graphics && ssh $VM true"

say "2/7 file bridges (host :8899, guest :9911)"
if lsof -nP -iTCP:8899 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "    host bridge up already, reusing it"
else
    # Serving /tmp is what makes the sync and the fetch one-liners. The pid file is only so the
    # next run (and a human) can tell who owns the port.
    ( cd /tmp && nohup python3 -m http.server 8899 >/tmp/krd-http-host.log 2>&1 &
      echo $! >/tmp/krd-http-host.pid )
    sleep 1
    lsof -nP -iTCP:8899 -sTCP:LISTEN >/dev/null 2>&1 \
        || die "host bridge did not come up, see /tmp/krd-http-host.log"
fi
if curl -sf -m 3 -o /dev/null "$GUEST_BRIDGE/"; then
    echo "    guest bridge up already, reusing it"
else
    # The guest's /tmp is wiped by every reboot, so this is routinely missing.
    $SSH 'cd /tmp && nohup python3 -m http.server 9911 >/tmp/krd-http-guest.log 2>&1 </dev/null &
          echo $! >/tmp/krd-http-guest.pid'
    sleep 1
    curl -sf -m 3 -o /dev/null "$GUEST_BRIDGE/" || echo "    guest bridge still down; will fetch over ssh"
fi

say "3/7 pty harness in the guest"
if $SSH 'test -x /tmp/pty/ptywall'; then
    echo "    /tmp/pty/ptywall present"
elif [ -f /tmp/ptywall.swift ]; then
    $SSH "mkdir -p /tmp/pty && curl -s $HOST_BRIDGE/ptywall.swift -o /tmp/pty/ptywall.swift \
          && cd /tmp/pty && swiftc -O ptywall.swift -o ptywall" >/dev/null \
        || die "could not rebuild /tmp/pty/ptywall in the guest"
    echo "    rebuilt /tmp/pty/ptywall from the host copy"
else
    die "/tmp/ptywall.swift is missing on the host; rebuild the pty harness before checking"
fi

say "4/7 sync $repo -> ~/krd, then build"
tar -C "$repo" -cf /tmp/krd-src.tar --exclude=.build --exclude=.git --exclude=.pi-subagents .
# `tar -m` and the find-touch are load bearing, not belt and braces: tar restores each file's
# archived mtime, and Swift's incremental build compares those with the guest's build products.
# Without forcing the mtimes forward, a synced edit looks older than the binary already there and
# the build silently skips it -- you then "verify" yesterday's krd.
$SSH "mkdir -p ~/krd && curl -s $HOST_BRIDGE/krd-src.tar | tar xmf - -C ~/krd" \
    || die "sync to ~/krd failed"
if build_log=$($SSH 'find ~/krd/Sources -name "*.swift" -exec touch {} + && cd ~/krd && swift build 2>&1'); then
    build_rc=0
else
    build_rc=$?
fi
# `swift build 2>&1 | tail -1` prints "Build complete!" and says nothing about an error above it.
# So: the whole log is grepped and the binary has to exist before this counts as a build.
if [ "$build_rc" -ne 0 ] || printf '%s\n' "$build_log" | grep -q 'error:'; then
    printf '%s\n' "$build_log" | tail -25 >&2
    die "the guest build failed (log above)"
fi
$SSH 'test -x ~/krd/.build/debug/krd' \
    || die "the build reported success but ~/krd/.build/debug/krd is not there"
printf '    build: %s\n' "$(printf '%s\n' "$build_log" | tail -1)"

say "5/7 run the wall on a ${cols}x${rows} pty"
wall_cmd="cd ~/krd && ./.build/debug/krd --wall --no-input --cell 17x33${extra:+ $extra}"
$SSH "/tmp/pty/ptywall $cols $rows \"$wall_cmd\" > $GUEST_OUT" || die "the pty run failed"

say "6/7 pull the raw bytes and judge them"
if ! curl -sf -m 10 -o "$RAW" "$GUEST_BRIDGE/wall-check.out" || [ ! -s "$RAW" ]; then
    echo "    guest bridge did not serve the capture; falling back to ssh cat"
    $SSH "cat $GUEST_OUT" >"$RAW" || die "could not fetch $GUEST_OUT"
fi
bytes=$(wc -c <"$RAW" | tr -d ' ')
[ "$bytes" -gt 0 ] || die "the wall painted nothing ($RAW is empty)"
header=no; if grep -qa 'krd' "$RAW"; then header=yes; fi
footer=no; if grep -qa 'click a card' "$RAW"; then footer=yes; fi
# Distinct SGR sequences are the cheapest honest signal that styles survived the run.
esc=$(printf '\033')
sgr=$(grep -ao "$esc\[[0-9;]*m" "$RAW" | sort -u | wc -l | tr -d ' ')
printf '    bytes        : %s\n' "$bytes"
printf '    header "krd" : %s\n' "$header"
printf '    footer       : %s (phrase "click a card", %s glyphs)\n' "$footer" "$symbols"
printf '    distinct SGR : %s\n' "$sgr"
printf '    raw bytes    : %s\n' "$RAW"

say "7/7 screenshot for the record"
# For the record only -- the pty bytes above are the authority, so a guest without screencapture
# (or without a display) must never fail the run.
if $SSH 'screencapture -x /tmp/wall.png' >/dev/null 2>&1 \
   && curl -sf -m 10 -o "$PNG" "$GUEST_BRIDGE/wall.png"; then
    printf '    screenshot   : %s\n' "$PNG"
else
    printf '    screenshot   : unavailable (ignored; the pty capture is the verdict)\n'
fi

[ "$header" = yes ] || die "the header word 'krd' is missing: the wall is not painting its header"
say "ok: the wall painted $bytes bytes, header present, screenshot: $PNG"
