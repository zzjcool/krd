#!/bin/bash
#
# A slow, distant link in front of the VM -- and krd's own numbers through it.
#
#   scripts/shaped-link.sh up [--delay 80] [--rate 200]      (also: PORT=2222 in the env)
#   scripts/shaped-link.sh status
#   scripts/shaped-link.sh ssh <command...>
#   scripts/shaped-link.sh run    [--label shaped] [--secs 25] [--pane 146x46] [-- krd flags...]
#   scripts/shaped-link.sh compare [--secs 25] [-- krd flags...]     # baseline vs shaped, both tables
#   scripts/shaped-link.sh down
#
# Why a proxy and not the VM: `tart` has no shaping at all (only `--net-bridged` and
# `--net-softnet`, which are isolation, not a rate), and macOS *does* have one -- dummynet,
# `dnctl` + `pfctl`, the thing Xcode's Network Link Conditioner drives -- but it needs root and
# touches the machine's packet filter. toxiproxy is a userspace TCP proxy, so the only thing
# shaped is the ssh connection the picture bytes cross, and nothing else on this Mac notices.
#
# `probe/pipe_probe.py` is the local cousin: it drains a *pty* at a fixed rate to starve krd on
# one machine. This one puts a real TCP link (latency + bandwidth, both directions) between the
# host and the guest, which is what "krd over ssh to a VM" actually is.
#
# Two things that cost an afternoon each, encoded here so they do not cost another:
#
#   * `ssh -p` does not change the host name, and `Host krd-vm` sets `HostName`, so the shaped
#     ssh must override `HostName=127.0.0.1` -- with its own known_hosts, because the key on
#     127.0.0.1 is not the key on the bridge address.
#   * the upstream address must come from `ssh -G`, not from a document: the VM's address moved
#     (192.168.64.7 in `.agents/skills/krd-dev/SKILL.md`, 192.168.64.2 today), and a proxy
#     pointed at a dead address wedges the toxiproxy API itself -- every request then takes 25 s
#     and answers 503. `up` therefore always restarts the server.
#
# What it measures: `--stats-json`, one line per second, from the same `ChromeMetrics` the --dev
# panel draws. That tick is mirror-only by design (the wall has its own `wallTick()` since #199:
# the same `CSI 5n` probe and the same `LinkVerdict` pill in its header, but no per-second series),
# so the tables below are mirror runs. A wall is the one mode this cannot tabulate -- it is refused
# rather than reported as silence.
#
# And what the tables are not: over a plain `ssh` into a pipe nothing answers `CSI 5n`, so `rtt_ms`
# stays -1 and the verdict stays `unknown` -- the link is measured by the *bytes*, not by the
# terminal. Behind a real terminal (Rex, kitty, Ghostty) the same run also fills in `rtt_ms`.
set -u

VM=${VM:-krd-vm}
PORT=${PORT:-2222}
PROXY=${PROXY:-krdvm}
# Literal, never expanded here: the string is handed to the guest shell, which expands the tilde
# on its own `krd` -- expanding it on this side points at this Mac's home, which the VM does not have.
KRD=${KRD:-'~/bin/krd'}
STATE=${TMPDIR:-/tmp}/krd-shaped-link
API=http://127.0.0.1:8474

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

mkdir -p "$STATE"

# The guest's address as ssh actually resolves it, so a moved VM does not silently shape nothing.
guest_host=$(ssh -G "$VM" 2>/dev/null | awk '/^hostname /{print $2}')
guest_port=$(ssh -G "$VM" 2>/dev/null | awk '/^port /{print $2}')
[ -n "$guest_host" ] || die "cannot resolve $VM through ssh (is it in ~/.ssh/config?)"
guest_port=${guest_port:-22}

# Options only: the destination is passed at every call site, so `$VM` is written once per command
# rather than smuggled into a string that then has to be word-split correctly.
DIRECT="ssh -o BatchMode=yes -o ConnectTimeout=5"
SHAPED="ssh -p $PORT -o HostName=127.0.0.1 -o UserKnownHostsFile=$STATE/known_hosts -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR"

api_up() { curl -fsS --max-time 2 "$API/proxies" >/dev/null 2>&1; }

# --- subcommands -----------------------------------------------------------

cmd_up() {
  delay=80; rate=200
  while [ $# -gt 0 ]; do
    case $1 in
      --delay) delay=${2:?--delay needs ms}; shift 2 ;;
      --rate)  rate=${2:?--rate needs KB/s};  shift 2 ;;
      *) die "unknown option for up: $1" ;;
    esac
  done
  have toxiproxy-server || die "toxiproxy is not installed: brew install toxiproxy"
  have toxiproxy-cli    || die "toxiproxy-cli is not installed: brew install toxiproxy"

  # Always a fresh server: a proxy whose upstream is unreachable wedges the API (25 s, 503), and
  # there is no way to unwedge it from the outside. The server holds nothing worth keeping.
  pkill -f toxiproxy-server 2>/dev/null
  sleep 1
  nohup toxiproxy-server >"$STATE/toxiproxy.log" 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do api_up && break; sleep 0.3; done
  api_up || die "toxiproxy-server did not come up (see $STATE/toxiproxy.log)"

  toxiproxy-cli create -l "127.0.0.1:$PORT" -u "$guest_host:$guest_port" "$PROXY" >/dev/null \
    || die "could not create the proxy"
  # Direction is a flag here, not a value: -d/--downstream is the default (guest -> host, the
  # direction the pictures travel), -u/--upstream is the other one. `-d downstream` is an error.
  [ "$delay" = 0 ] || {
    toxiproxy-cli toxic add -t latency -a "latency=$delay" "$PROXY" >/dev/null || die "latency (down)"
    toxiproxy-cli toxic add -u -t latency -a "latency=$delay" "$PROXY" >/dev/null || die "latency (up)"
  }
  [ "$rate" = 0 ] || {
    toxiproxy-cli toxic add -t bandwidth -a "rate=$rate" "$PROXY" >/dev/null || die "bandwidth (down)"
    toxiproxy-cli toxic add -u -t bandwidth -a "rate=$rate" "$PROXY" >/dev/null || die "bandwidth (up)"
  }
  say "shaped link up: 127.0.0.1:$PORT -> $guest_host:$guest_port (delay ${delay}ms, ${rate} KB/s each way)"
  $SHAPED "$VM" 'true' || die "the shaped ssh does not work (check $STATE/known_hosts)"
  cmd_status
}

cmd_down() {
  toxiproxy-cli delete "$PROXY" >/dev/null 2>&1
  pkill -f toxiproxy-server 2>/dev/null
  say "shaped link down (proxy removed, server stopped)"
}

cmd_status() {
  if api_up; then
    toxiproxy-cli inspect "$PROXY" 2>/dev/null || say "no proxy named $PROXY"
  else
    say "toxiproxy-server is not running"
    return 0
  fi
  # The link's own numbers, so a run's krd numbers have something to be attributed to.
  rtt=""
  for _ in 1 2 3; do
    t=$( { /usr/bin/time -p $SHAPED "$VM" true >/dev/null; } 2>&1 | awk '/^real/{print $2}')
    rtt="$rtt ${t:-?}"
  done
  printf 'ssh round trip (3x):%s s\n' "$rtt"
  secs=$( { /usr/bin/time -p $SHAPED "$VM" 'dd if=/dev/zero bs=64k count=32 2>/dev/null' >/dev/null; } 2>&1 \
          | awk '/^real/{print $2}')
  printf '2 MiB guest -> host: %s s (%s KB/s)\n' "${secs:-?}" \
         "$(awk -v s="${secs:-0}" 'BEGIN{ if (s>0) printf "%.0f", 2048/s; else print "n/a" }')"
}

cmd_ssh() { exec $SHAPED "$VM" "$@"; }

# table <ndjson> <title> -- one line per sampled second, the way the run actually went.
table() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, title = sys.argv[1], sys.argv[2]
rows = []
for line in open(path, errors="replace"):
    line = line.strip()
    if line.startswith("{"):
        try:
            rows.append(json.loads(line))
        except ValueError:
            pass
print(f"== {title}  ({len(rows)} s)")
if not rows:
    print("   no samples -- did krd run? (--wall writes no --stats-json, see the header)")
    raise SystemExit
print("    t   fps   MB/s  scale  qual   KB  write_ms  pipe_p99  late")
for r in rows:
    print(f"{r['t']:5.0f} {r['fps']:5.1f} {r['mbps']:6.3f}  {r['scale']:5.2f} "
          f"{r['quality']:5d} {r['kb']:4d}  {r['write_ms']:8.1f}  {r['pipe_p99_ms']:8.1f} {r['late']:5d}")
scales = sorted({round(r["scale"], 3) for r in rows})
quals = sorted({r["quality"] for r in rows})
import statistics as st
cells = rows[-1]["cells"]
print(f"   cells {cells[0]}x{cells[1]}  "
      f"mean fps {st.mean([r['fps'] for r in rows]):.2f}  "
      f"mean {st.mean([r['mbps'] for r in rows]):.3f} MB/s  scales {scales}  quality {quals}  "
      f"late {sum(r['late'] for r in rows)}/{sum(r['frames'] for r in rows)}")
PY
}

# cmd_run <direct|shaped> <label> <secs> <pane> <krd flags...>
cmd_run_link() {
  link=$1; label=$2; secs=$3; pane=$4; shift 4
  cols=${pane%x*}; rows=${pane#*x}
  case "$cols$rows" in *[!0-9]*) die "bad --pane '$pane', want COLSxROWS" ;; esac
  case " $* " in *" --wall "*) die "--wall writes no --stats-json (runWall has no diagnostics tick); use the default --mirror" ;; esac

  case $link in
    direct) remote="ssh -o BatchMode=yes -o ConnectTimeout=5" ;;
    shaped) remote=$SHAPED ;;
  esac

  guest_log=/tmp/krd-$label.log
  guest_json=/tmp/krd-$label.ndjson
  $DIRECT "$VM" "pkill -x krd; rm -f $guest_log $guest_json; true" >/dev/null 2>&1
  sleep 1
  # A slept display wedges ScreenCaptureKit and the *next* krd hangs at its last log line.
  $DIRECT "$VM" 'caffeinate -u -t 5 >/dev/null 2>&1 & true' >/dev/null 2>&1

  say "running $KRD $* in the VM over the $link link for ${secs}s ($pane)"
  # `-tt` for the same reason wall-vm-check.sh needs a pty: krd takes its geometry from
  # TIOCGWINSZ, and without a tty the pane is 77x24 no matter what `stty` was asked for. `</dev/null`
  # keeps ssh from eating the caller's stdin once it has a tty of its own.
  # The discard is on the *host* side on purpose: redirecting inside the guest would mean the
  # picture never crosses the link, and then the link would have nothing to be slow about.
  $remote -tt "$VM" "stty rows $rows cols $cols; $KRD $* --log $guest_log --stats-json $guest_json" \
    >/dev/null 2>&1 </dev/null &
  runner=$!
  sleep "$secs"
  $DIRECT "$VM" 'pkill -x krd' >/dev/null 2>&1
  # Bounded: an ssh still draining its pty buffer through a 200 KB/s link can outlive krd, and an
  # unattended tool that waits on that forever is worse than one that drops the socket.
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$runner" 2>/dev/null || break; sleep 0.2; done
  kill "$runner" 2>/dev/null
  wait "$runner" 2>/dev/null

  $DIRECT "$VM" "cat $guest_json 2>/dev/null" >"$STATE/$label.ndjson"
  $DIRECT "$VM" "cat $guest_log 2>/dev/null" >"$STATE/$label.log"
  table "$STATE/$label.ndjson" "$label ($link)"
  printf '   raw: %s\n' "$STATE/$label.ndjson"
}

cmd_run() {
  label=shaped; secs=25; pane=146x46; link=shaped
  while [ $# -gt 0 ]; do
    case $1 in
      --label) label=${2:?--label needs a name}; shift 2 ;;
      --secs)  secs=${2:?--secs needs a number};  shift 2 ;;
      --pane)  pane=${2:?--pane needs COLSxROWS}; shift 2 ;;
      --direct) link=direct; shift ;;
      --) shift; break ;;
      *) die "unknown option for run: $1" ;;
    esac
  done
  [ $# -gt 0 ] || set -- --mirror --fps 20
  cmd_run_link "$link" "$label" "$secs" "$pane" "$@"
}

cmd_compare() {
  secs=25; pane=146x46
  while [ $# -gt 0 ]; do
    case $1 in
      --secs) secs=${2:?--secs needs a number}; shift 2 ;;
      --pane) pane=${2:?--pane needs COLSxROWS}; shift 2 ;;
      --) shift; break ;;
      *) die "unknown option for compare: $1" ;;
    esac
  done
  [ $# -gt 0 ] || set -- --mirror --fps 20
  api_up || die "the shaped link is not up -- run: scripts/shaped-link.sh up"
  cmd_run_link direct baseline "$secs" "$pane" "$@"
  echo
  # Longer by default: on a starved link the governor needs ~20 s before it reaches `scale`.
  cmd_run_link shaped shaped "$((secs + 5))" "$pane" "$@"
}

# --- dispatch --------------------------------------------------------------

cmd=${1:-}
[ $# -gt 0 ] && shift
case $cmd in
  up)      cmd_up "$@" ;;
  down)    cmd_down ;;
  status)  cmd_status ;;
  ssh)     cmd_ssh "$@" ;;
  run)     cmd_run "$@" ;;
  compare) cmd_compare "$@" ;;
  -h|--help|help|'')
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "unknown subcommand '$cmd' (try --help)" ;;
esac
